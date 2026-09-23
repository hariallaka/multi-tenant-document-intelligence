# DI gateway: multi-tenant Document Intelligence behind APIM

A shared Azure AI Document Intelligence (S0, API v4.0) service for many tenants, fronted by an
internal Azure API Management gateway. The full design is in [`docs/design.md`](docs/design.md),
which is the source of truth. [`docs/HANDOFF.md`](docs/HANDOFF.md) is the build brief.

The gateway:

1. **Prevents 429s** with per-tenant admission control (`rate-limit-by-key`, `quota-by-key`).
2. **Contains noisy tenants.** Circuit breakers fail over within the tenant's cell, then to a
   capped overflow pool for the tenant's zone. Restricted tenants never overflow.
3. **Spreads the first request across a cell**: a weighted APIM pool of 2–3 DI resources.
4. **Pins async results** to the accepting resource with signed, tenant-bound result tickets.

## Architecture

```
tenant app ──Entra token──▶ APIM (Premium, internal VNet) ──MI──▶ pool-<cell>            ─▶ DI a1, a2 (PE)
                               │  api-di-v1.xml: auth, tenant       └─(final retry)─▶ pool-overflow-<zone> ─▶ DI ovf (PE)
                               │  op-analyze.xml: limits, routing, sign result URL
                               │  op-result.xml: verify ticket ─▶ single backend <key> (no pool, no retry)
                               ├─ named values: tenant-cell-map, di-host-map, signing keys (Key Vault refs)
                               └─ external cache: Azure Managed Redis (overflow counters)
```

| Component | Terraform | Notes |
| --- | --- | --- |
| Resource group, spoke VNet, APIM subnet and PE subnet with NSGs | `modules/platform/network.tf` | Optional peering to the hub |
| Private DNS zones for cognitiveservices, vaultcore, redis and azure-api.net | `modules/platform/dns.tf` | Pass hub-owned zone IDs in `existing_private_dns_zone_ids` |
| APIM Premium, internal VNet mode, system-assigned identity | `modules/platform/apim.tf` | TLS 1.0/1.1 disabled |
| Key Vault (RBAC, private endpoint) and bootstrap signing keys | `modules/platform/keyvault.tf` | Keys are ephemeral and write-only, so they are never stored in state |
| Azure Managed Redis as the APIM external cache | `modules/platform/redis.tf` | Stores the overflow counters |
| Log Analytics, APIM and Key Vault diagnostics | `modules/platform/monitoring.tf` | |
| DI accounts: no public access, no local auth, private endpoint, RBAC | `modules/di-gateway/di_accounts.tf` | One per cell or overflow member |
| APIM backends with circuit breakers | `modules/di-gateway/apim_backends.tf` | `azapi`, `Microsoft.ApiManagement/service/backends@2024-05-01` |
| Cell pools and one overflow pool per zone | `modules/di-gateway/apim_pools.tf` | |
| API `di-v1`, two operations and three policies | `modules/di-gateway/apim_api.tf` | XML loaded from `apim/policies` |
| Named values | `modules/di-gateway/named_values.tf` | |
| Guardrails | `modules/di-gateway/checks.tf` | Plan fails on a violation |

`modules/di-gateway` is standalone. If the landing zone already provides APIM, Key Vault,
Redis and the network, call it directly with those IDs and drop `modules/platform`.

## Repository layout

```
apim/policies/          api-di-v1.xml, op-analyze.xml, op-result.xml
apim/openapi/di-v1.yaml tenant-facing contract
infra/terraform/
  modules/platform/     landing-zone pieces the gateway needs
  modules/di-gateway/   DI accounts, backends, pools, API, named values, guardrails (+ tests/)
  envs/{nonprod,prod}/  main.tf, variables.tf, backend.tf, platform.auto.tfvars, di.auto.tfvars (+ tests/)
pipelines/              azure-pipelines.yml + templates/terraform-env.yml
tests/policy/           Python port of the ticket HMAC logic + policy/Terraform consistency tests
tests/load/             k6 scripts for the six design load tests
scripts/                onboard-tenant.md, rotate-signing-key.sh, model-copy/ (stub)
dispatcher/             batch dispatcher contract (stub)
```

## Configuration (DeployEz layer)

Each environment has two config files:

- `platform.auto.tfvars`: subscription, region, address space, APIM SKU, identities.
- `di.auto.tfvars`: `di_cells`, `di_overflow`, `di_tenants` and `dedicated_di_count`.
  Onboarding a tenant changes only this file; see [`scripts/onboard-tenant.md`](scripts/onboard-tenant.md).

All IDs in the committed tfvars are placeholders. The tenant IDs are fake GUIDs, and the
subscription, Entra tenant, state account and service connections are marked `TODO`.

## Guardrails (plan fails)

- Every tenant references an existing cell.
- Overflow-enabled tenants have an overflow pool in their zone, and none are Restricted.
- DI accounts per region, including `dedicated_di_count`, stay at or below 20.
- No pool has more than 30 members.
- No DI member appears in two pools. Cell names can't collide with overflow pool names.
- `tenant-cell-map` and `di-host-map` stay within the 4,096-character named-value limit.
- Variable validation covers zones, tiers, pool weights, GUID tenant keys and overflow zones.

## Local checks

```bash
cd infra/terraform/envs/prod && terraform init -backend=false && terraform validate && terraform test
cd ../../modules/di-gateway   && terraform init -backend=false && terraform test   # guardrail tests, mocked providers
cd ../../../.. && tflint --init && for d in infra/terraform/{modules/di-gateway,modules/platform,envs/nonprod,envs/prod}; do tflint --config=$PWD/.tflint.hcl --chdir=$d; done
checkov -d infra/terraform --framework terraform
python3 -m pytest tests/policy
```

Commit provider lock files from a machine with registry access:
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64`
in each `envs/*` directory. They are not committed yet, because this repo was scaffolded
without access to the Terraform registry.

## Pipeline

`pipelines/azure-pipelines.yml` runs these stages:

1. **Validate:** fmt, validate, tflint, checkov, terraform test, then the policy tests.
2. **nonprod:** plan (published as an artifact), then apply.
3. **prod:** plan (published as an artifact), then a manual approval (ManualValidation), then
   apply to the `di-gateway-prod` environment.

Authentication uses Workload Identity Federation service connections (`addSpnToEnvironment`
exposes an OIDC token, with no client secret). The agent pool must have private line of sight
to Key Vault, because Terraform writes the bootstrap signing keys through its private endpoint.

## Deliberate changes from the reference in `docs/design.md`

| Change | Why |
| --- | --- |
| `tenant-cell-map` and `di-host-map` named values hold **base64(JSON)**, decoded in the policy | Raw JSON quotes placed inside `value="{{...}}"` attributes would break the policy XML |
| Guardrails are `lifecycle.precondition`s, not `check` blocks | `check` blocks only warn; the handoff wants the plan to fail |
| Added `modules/platform` | The request was to deploy every required component; the design assumed the landing zone provides APIM, Key Vault, Redis and the network |
| `di_name_suffix` on account names and subdomains | DI subdomains are globally unique. Backend keys stay the bare member names so tickets survive resource replacement |
| Azure Managed Redis instead of Azure Cache for Redis | Azure Cache for Redis is being retired for new deployments |
| `enable_diagnostics` flag | Diagnostic-setting `for_each` cannot depend on IDs that are only known after apply |
| Added a guardrail against a DI member appearing in two pools | `merge()` would otherwise silently collapse duplicates, and could share overflow across zones |

## Verification points

Resolved:

- [x] **azapi API version:** `2024-05-01` is the latest GA version whose schema includes both
  `circuitBreaker` and `pool`. Both backend bodies were checked against azapi v2.12.0's
  embedded schema, and a malformed body is rejected.

Still open (validate in nonprod before rollout):

- [ ] Whether `HMACSHA256`, `Regex`, `Func` and `Convert.FromBase64String` are allowed in policy
  expressions on the chosen tier.
- [ ] How a fully tripped pool surfaces: a 503 `context.Response`, or `on-error`. Adjust the
  Analyze retry condition and the API `on-error` source check to match.
- [ ] Whether retried `forward-request`s land on a different member (load test 3,
  `tests/load/queries.kql`).
- [ ] **APIM tier:** this repo deploys classic Premium in internal VNet mode. Premium v2 with
  VNet integration is the alternative (design open decision).
- [ ] Whether the 20-resource DI limit is per subscription per region, or per region only
  (confirm with Microsoft). The guardrail counts per region.
- [ ] **External cache authentication:** APIM connects to Redis with a connection string that
  contains an access key. The key lives in Terraform state and APIM, never in the repo. Move to
  Entra auth for the external cache if APIM supports it for Azure Managed Redis, then set
  `access_keys_authentication_enabled = false`. Also confirm the `EnterpriseCluster` policy
  works with APIM's cache client.
- [ ] `buffer-request-body` memory at the 50 MB inline cap under concurrent load.
- [ ] Counter accuracy of `rate-limit-by-key` across your gateway unit count (keep the 80% margin).
- [ ] Per-tier limits (standard 10/5 s, gold 30/5 s) and the 200,000/day quota are hard-coded
  in `op-analyze.xml` from the reference. Set them from onboarding data.
- [ ] **DeployEz conventions:** the layout follows the handoff's target layout. If a DeployEz
  template repo or module layout exists, align this repo to it.
- [ ] RBAC propagation: on a first apply, APIM may take a few minutes to resolve the Key Vault
  named values after its role grant. Re-run the apply if the named-value step fails once.

## Out of scope (stubs)

- Batch dispatcher (AKS, Service Bus, Redis token buckets): [`dispatcher/README.md`](dispatcher/README.md)
- Custom-model copy pipeline and replication gate: [`scripts/model-copy/README.md`](scripts/model-copy/README.md)
- Alerts from the observability table (429 rate, breaker trips via Event Grid, overflow share).
  The logs are in place; the alert rules are not.
