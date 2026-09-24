# DI gateway: multi-tenant Document Intelligence behind APIM

A shared Azure AI Document Intelligence (S0, API v4.0) service for internal workloads, fronted by
an **existing, private Azure API Management Premium v2** instance. Neither APIM nor DI is reachable
from the internet. The design is in [`docs/design.md`](docs/design.md), and
[`docs/HANDOFF.md`](docs/HANDOFF.md) is the original build brief. This README describes the
deployment profile this repo implements, which narrows the design to two pools (see
[Deployment profile](#deployment-profile)).

## Architecture

```
                    private network only (no public IP, no public endpoint)
┌──────────────┐    ┌──────────────────────────────────────────┐    ┌───────────────────────────────┐
│ internal app │──▶│ APIM Premium v2 (existing, VNet-injected) │    │ pool-prod-general  (2 × DI S0) │
│ Entra token  │    │  api-di-v1.xml   auth, tenant → pool      │──▶│   di-prod-gen-1, -2          │
└──────────────┘    │  op-analyze.xml  limits, retry in pool    │    ├───────────────────────────────┤
                    │  op-result.xml   signed ticket → 1 member │──▶│ pool-prod-critical (3 × DI S0) │
                    │  managed identity ─▶ DI (no keys)        │    │   di-prod-crit-1, -2, -3      │
                    └──────────────────────────────────────────┘    └───────────────────────────────┘
                              │  named values ─▶ Key Vault (PE)      each DI: public access off,
                              │  external cache ─▶ Managed Redis (PE)  local auth off, private endpoint
                              └─ logs ─▶ Log Analytics
```

## Deployment profile

| Decision | This repo |
| --- | --- |
| APIM | **Existing Premium v2 instance**, read by Terraform and never created or modified (only APIs, backends, named values, the external cache and a diagnostic setting are added to it) |
| APIM exposure | **Private only.** The plan fails unless the instance is VNet-injected in Internal mode or has public network access disabled, and has no public IP (`require_private_apim`) |
| Pools | **general**: 2 DI resources. **critical**: 3 DI resources. They share nothing |
| Overflow | None configured. Each pool absorbs its own bursts. The module still supports zone-specific overflow pools if you add them later |
| DI exposure | Private endpoints only, `public_network_access_enabled = false`, `local_auth_enabled = false` |

### How the pools prevent throttling

S0 defaults per DI resource: **15 Analyze (POST)/s** and **50 Get-result/s**. The gateway admits
at most 80% of a pool's capacity, so short bursts and approximate balancing don't cause 429s.

| Pool | Members | Analyze capacity | Admitted (80%) | GET capacity | GET kept under | One member down |
| --- | --- | --- | --- | --- | --- | --- |
| general | 2 | 30 TPS | 24 TPS | 100/s | 80/s | 15 TPS on 1 member |
| critical | 3 | 45 TPS | 36 TPS | 150/s | 120/s | 30 TPS on 2 members (still above most critical demand) |

The controls are layered:

1. **Per-tenant admission.** `rate-limit-by-key` on the caller's Entra client ID (standard:
   10 calls/5 s, gold: 30 calls/5 s) and a daily `quota-by-key`. A tenant over its limit gets
   429 at the gateway before any DI resource sees the load.
2. **Pool isolation.** General and critical workloads call different DI resources, so a general
   surge cannot throttle critical work.
3. **Weighted spread.** Each pool round-robins across its members by weight from the first request.
   Raise a member's `weight` when Microsoft approves a TPS increase for it.
4. **Circuit breaker and retry within the pool.** A member that returns 429 or 5xx trips for 10 s,
   or for DI's `Retry-After`. APIM retries the request up to twice in the same pool, skipping
   tripped members. With 3 members, the critical pool can absorb a throttled member and a retry.
5. **2 s polling floor.** Result GETs are limited to one per result every 2 s. GETs are often the
   binding limit: `GET/s = POST/s × processing seconds ÷ 2` must stay under 80% of 50 per resource.
6. **Result pinning.** A result GET goes to the one DI resource that accepted the job, via a
   signed, tenant-bound ticket. Pool round-robin is never used for GETs, because a different
   member would return 404.

If a pool still runs hot, raise member TPS through a support ticket (then raise its `weight`),
add a member (up to the 20-per-region limit), or add an overflow pool for that zone.

## What Terraform deploys

| Component | Terraform | Notes |
| --- | --- | --- |
| Existing APIM lookup and guardrails (Premium v2, private, managed identity) | `modules/platform/existing_apim.tf` | `azapi` read of `Microsoft.ApiManagement/service` |
| Resource group for DI and supporting resources | `modules/platform/network.tf` | APIM stays in its own resource group |
| PE subnet: an existing one, or a spoke VNet + PE subnet + NSG peered with the APIM VNet | `modules/platform/network.tf` | `existing_pe_subnet_id` switches between the two |
| Private DNS zones for cognitiveservices, vaultcore and redis, linked to the APIM VNet | `modules/platform/dns.tf` | Or pass hub-owned zone IDs |
| Key Vault (RBAC, private endpoint) and bootstrap signing keys | `modules/platform/keyvault.tf` | Keys are ephemeral and write-only, never stored in state |
| Azure Managed Redis registered as the APIM external cache | `modules/platform/redis.tf` | Used by the overflow counters in the Analyze policy |
| Log Analytics, and diagnostic settings for APIM and Key Vault | `modules/platform/monitoring.tf` | |
| 5 DI accounts: no public access, no local auth, private endpoint, `Cognitive Services User` for APIM | `modules/di-gateway/di_accounts.tf` | |
| APIM backends with circuit breakers | `modules/di-gateway/apim_backends.tf` | `azapi`, `backends@2024-05-01` |
| `pool-<env>-general` and `pool-<env>-critical` | `modules/di-gateway/apim_pools.tf` | |
| API `di-v1`, two operations and three policies | `modules/di-gateway/apim_api.tf` | XML from `apim/policies` |
| Named values: tenant map, host map, signing keys (Key Vault refs), identities | `modules/di-gateway/named_values.tf` | |
| Guardrails | `modules/di-gateway/checks.tf` | Plan fails on a violation |

### Prerequisites on the existing APIM instance

- **Tier:** Premium v2 (`sku.name = PremiumV2`), in the same subscription and region as `location`.
- **Private:** VNet-injected in Internal mode, or public network access disabled with an inbound
  private endpoint. No public IP.
- **Identity:** a system-assigned managed identity. Terraform grants it `Cognitive Services User`
  on each DI account and `Key Vault Secrets User` on the vault.
- **Network:** `apim_vnet_id` is the VNet APIM is injected into. APIM must reach the PE subnet,
  either because the subnet is in that VNet or through the peering Terraform creates. NSGs and
  route tables on the APIM subnet must allow outbound 443 (DI, Key Vault) and 10000 (Redis) to it.
- **DNS:** APIM must resolve `*.cognitiveservices.azure.com`, `*.vault.azure.net` and
  `*.redis.azure.net` to the private endpoints. Terraform links the zones it creates to the
  APIM VNet. If the hub owns the zones, it must link them.
- **Deploying identity:** Contributor on the DI resource group, API Management Service
  Contributor on the APIM instance, and User Access Administrator (or RBAC Administrator)
  for the role assignments. Network Contributor on the APIM VNet is needed only for
  `create_reverse_peering`.

## Repository layout

```
apim/policies/          api-di-v1.xml, op-analyze.xml, op-result.xml
apim/openapi/di-v1.yaml tenant-facing contract
infra/terraform/
  modules/platform/     existing-APIM lookup, network for PEs, DNS, Key Vault, Redis, logs (+ tests/)
  modules/di-gateway/   DI accounts, backends, pools, API, named values, guardrails (+ tests/)
  envs/{nonprod,prod}/  main.tf, variables.tf, backend.tf, platform.auto.tfvars, di.auto.tfvars (+ tests/)
pipelines/              azure-pipelines.yml + templates/terraform-env.yml
tests/policy/           Python port of the ticket HMAC logic + policy/Terraform consistency tests
tests/load/             k6 scripts for the six design load tests
scripts/                onboard-tenant.md, rotate-signing-key.sh, model-copy/ (stub)
dispatcher/             batch dispatcher contract (stub)
```

## Configuration

Each environment has two config files:

- `platform.auto.tfvars`: subscription, region, the existing APIM instance (name, resource
  group, VNet), the PE subnet or spoke address space, and identities.
- `di.auto.tfvars`: the two pools (`di_cells`), `di_overflow` (empty) and `di_tenants`.
  Onboarding a workload changes only this file; see [`scripts/onboard-tenant.md`](scripts/onboard-tenant.md).

A tenant is an Entra client ID assigned to a pool:

```hcl
di_tenants = {
  "<client id>" = { cell = "prod-general",  tier = "standard", overflow = false, modelPrefix = "t001-" }
  "<client id>" = { cell = "prod-critical", tier = "gold",     overflow = false, modelPrefix = "t101-" }
}
```

Nonprod mirrors prod's 2 + 3 topology. S0 is billed per page, so the extra resources cost
nothing when idle, and load tests stay representative. All IDs in the committed tfvars are
placeholders marked `TODO`.

## Guardrails (plan fails)

- **Existing APIM:** it is Premium v2, private (Internal injection or public access disabled,
  and no public IP), and has a system-assigned identity.
- Every tenant references an existing pool.
- Overflow-enabled tenants have an overflow pool in their zone, and none are Restricted.
- DI accounts per region, including `dedicated_di_count`, stay at or below 20.
- No pool has more than 30 members. No DI member appears in two pools.
- `tenant-cell-map` and `di-host-map` stay within the 4,096-character named-value limit.
- Variable validation covers zones (general, critical, confidential, restricted), tiers, weights
  and GUID tenant keys.

## Local checks

```bash
for d in modules/platform modules/di-gateway envs/nonprod envs/prod; do
  (cd infra/terraform/$d && terraform init -backend=false && terraform validate && terraform test)
done
tflint --init && for d in infra/terraform/{modules/di-gateway,modules/platform,envs/nonprod,envs/prod}; do tflint --config=$PWD/.tflint.hcl --chdir=$d; done
checkov -d infra/terraform --framework terraform
python3 -m pytest tests/policy
```

The Terraform tests use mocked providers, including a mocked private Premium v2 instance, so
they need no Azure access. Commit provider lock files from a machine with registry access:
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64`
in each `envs/*` directory.

## Pipeline

`pipelines/azure-pipelines.yml` runs these stages:

1. **Validate:** fmt, validate, tflint, checkov, terraform test, then the policy tests.
2. **nonprod:** plan (published as an artifact), then apply.
3. **prod:** plan (published as an artifact), then a manual approval, then apply.

Authentication uses Workload Identity Federation service connections, with no client secrets.
Because Key Vault and Redis have no public endpoint, the agent pool must run inside the private
network: Terraform writes the bootstrap signing keys through Key Vault's private endpoint.

## Deliberate changes from `docs/design.md`

| Change | Why |
| --- | --- |
| Existing APIM Premium v2, read-only in Terraform | The instance already exists; the design assumed Premium or v2 |
| Two pools (general 2, critical 3) and no overflow | Requested deployment profile. The design's cells, zones and overflow remain supported by the module |
| Added a `critical` workload zone | It is isolated from general exactly as Confidential is |
| `tenant-cell-map` and `di-host-map` stored as base64(JSON) | Raw JSON quotes placed inside `value="{{...}}"` attributes would break the policy XML |
| Guardrails are `precondition`s, not `check` blocks | `check` blocks only warn |
| `di_name_suffix` on DI account names and subdomains | DI subdomains are globally unique. Backend keys stay the bare member names |
| Azure Managed Redis | Azure Cache for Redis is being retired for new deployments |

## Verification points

Resolved:

- [x] **azapi API version:** `2024-05-01` is the latest GA version whose schema includes both
  `circuitBreaker` and `pool`. Both backend bodies validate against azapi v2.12.0's embedded schema.

Still open (validate in nonprod before rollout):

- [ ] **Premium v2 features:** confirm that backend pools, circuit breakers, `rate-limit-by-key`,
  `quota-by-key`, the external cache and `authentication-managed-identity` behave on your
  Premium v2 instance as the policies expect.
- [ ] **Premium v2 network properties:** confirm how your instance reports its private mode
  (`virtualNetworkType = Internal` for injection, or `publicNetworkAccess = Disabled` with a
  private endpoint). The guardrail accepts either.
- [ ] Whether `HMACSHA256`, `Regex`, `Func` and `Convert.FromBase64String` are allowed in policy
  expressions on Premium v2.
- [ ] How a fully tripped pool surfaces: a 503 `context.Response`, or `on-error`. Adjust the
  Analyze retry condition and the API `on-error` source check to match.
- [ ] Whether retries land on a different member (load test 3, `tests/load/queries.kql`).
- [ ] Whether the built-in `azuremonitor` logger exists on the instance. It is used by the API
  diagnostic for per-tenant logging.
- [ ] **External cache authentication:** APIM connects to Redis with a connection string that
  contains an access key. The key lives in Terraform state and APIM, never in the repo. Switch
  to Entra auth if APIM supports it for Azure Managed Redis. The cache is only used by the
  overflow logic, so you can drop Redis while overflow stays off; see `modules/platform/redis.tf`.
- [ ] Per-tier limits (standard 10/5 s, gold 30/5 s) and the 200,000/day quota are hard-coded in
  `op-analyze.xml`. Set them from onboarding data, keeping each pool's committed total at or
  below 80% of its capacity.
- [ ] Whether the 20-resource DI limit is per subscription per region, or per region only.
- [ ] **DeployEz conventions:** align the layout if a template repo exists.
- [ ] RBAC propagation: on a first apply, APIM may need a few minutes to resolve the Key Vault
  named values after its role grant. Re-run the apply if the named-value step fails once.

## Out of scope (stubs)

- Batch dispatcher (AKS, Service Bus, Redis token buckets): [`dispatcher/README.md`](dispatcher/README.md)
- Custom-model copy pipeline and replication gate: [`scripts/model-copy/README.md`](scripts/model-copy/README.md).
  Custom models must exist on **every** member of a tenant's pool, or failover within the pool fails.
- Alert rules (429 rate per DI resource, breaker trips, pool saturation). The logs are in place;
  the alert rules are not.
