# DI gateway: multi-tenant Document Intelligence behind APIM

A shared Azure AI Document Intelligence (S0, API v4.0) service for internal workloads, fronted by
an **existing, private Azure API Management Standard v2** instance (Premium v2 also works; it isn't
yet available in Australia East). Neither APIM nor DI is reachable
from the internet. The design is in [`docs/design.md`](docs/design.md), and
[`docs/HANDOFF.md`](docs/HANDOFF.md) is the original build brief. This README describes the
deployment profile this repo implements, which narrows the design to two pools (see
[Deployment profile](#deployment-profile)).

## Architecture

```
                 private network only (no public IP, no public endpoint)
┌──────────────┐   ┌───────────────────────────────────────────┐   ┌────────────────────────────────────┐
│ internal app │──▶│ APIM Standard v2 (existing, private)       │──▶│ pool-prod-general    2 × DI S0      │
│ Entra token  │   │  api-di-v1.xml  auth, tenant → pool       │   │ pool-prod-critical   3 × DI S0      │
└──────────────┘   │  op-analyze.xml limits, count pool load:  │   ├──── at ≥ 90% of pool capacity ─────┤
                   │    < 90%  → home pool                     │──▶│ pool-overflow-general   1 × DI S0   │
                   │    ≥ 90%  → zone overflow pool            │   │ pool-overflow-critical  1 × DI S0   │
                   │  op-result.xml  signed ticket → 1 member  │   └────────────────────────────────────┘
                   │  managed identity ─▶ DI (no keys)        │     each DI: public access off,
                   └───────────────────────────────────────────┘     local auth off, private endpoint
   inbound: private endpoint, public access disabled · outbound: VNet integration
                        │ named values ─▶ Key Vault (PE)
                        │ external cache ─▶ Azure Cache for Redis (PE): per-pool, per-second counters
                        └ logs ─▶ Log Analytics
```

## Deployment profile

| Decision | This repo |
| --- | --- |
| APIM | **Existing Standard v2 instance** (Premium v2 also accepted), read by Terraform and never created or reconfigured (only APIs, backends, named values, the external cache and a diagnostic setting are added to it) |
| APIM exposure | **Private only.** Inbound through a private endpoint with public network access disabled, and no public IP. Outbound through VNet integration into `apim_vnet_id`. The plan fails otherwise (`require_private_apim`) |
| Pools | **general**: 2 DI resources. **critical**: 3 DI resources. They share nothing |
| Overflow | **Active at 90%.** One overflow pool per zone (`pool-overflow-general`, `pool-overflow-critical`, 1 DI each). When a pool reaches 90% of its capacity, further requests go to its zone's overflow pool instead of being rejected |
| DI exposure | Private endpoints only, `public_network_access_enabled = false`, `local_auth_enabled = false` |
| Authentication | APIM authenticates to DI and Key Vault with its managed identity: no DI keys and no secrets in the repo. **One exception:** APIM authenticates to Redis with an access key that's never stored in Terraform state; see [Redis authentication](#redis-authentication-option-a) |
| Overflow counters | **Azure Cache for Redis** (Azure Managed Redis can't be used here), private endpoint only, same region as APIM and DI. **Entra ID authentication enabled** for every client; APIM alone uses an access key (option A) |

### Overflow at 90% capacity

S0 defaults per DI resource: **15 Analyze (POST)/s** and **50 Get-result/s**. A pool's capacity
is the sum of its members' `tps`.

| Pool | DI | Analyze capacity | Spills to overflow at (90%) | Overflow target |
| --- | --- | --- | --- | --- |
| `pool-prod-general` | 2 | 30/s | 27 calls in a second | `pool-overflow-general` |
| `pool-prod-critical` | 3 | 45/s | 40 calls in a second | `pool-overflow-critical` |
| `pool-overflow-general` | 1 | 15/s | takes spill up to 13/s | none |
| `pool-overflow-critical` | 1 | 15/s | takes spill up to 13/s | none |

How it works (`apim/policies/op-analyze.xml`):

1. For every Analyze call, APIM reads the home pool's counter for the current second from the
   external Redis cache. The cache is shared, so every gateway unit sees the same count.
2. **Below 90%:** the home pool serves the request, and the counter goes up by one.
3. **At or above 90%:** if the tenant has `overflow = true`, the request goes to the zone's
   overflow pool instead. The gateway does not reject it.
4. **The overflow pool has its own limits.** It takes spill only up to 90% of its own capacity,
   and one tenant may use at most 50% of it per second (`overflow_tenant_share_pct`), so one hot
   tenant can't take all of it.
5. **When both are busy:** the request goes to the home pool anyway. The gateway never rejects on
   pool capacity; DI's own limits apply, and the circuit breakers and retries below handle any 429.
6. **Retries:** attempts 1 and 2 go to the chosen pool (skipping tripped members), and attempt 3
   goes to the other pool (home ↔ overflow).
7. **Logging:** every Analyze response carries `x-daas-pool` with the pool that served it. It is
   logged in APIM diagnostics, so you can see how often each tenant spills.

Settings in `di.auto.tfvars`:

- `overflow_threshold_pct` (90) sets where spill starts.
- `overflow_tenant_share_pct` (50) caps each tenant's share of an overflow pool.
- `tps` and `weight` per member: raise both after a TPS increase (e.g. `tps = 45, weight = 3`).
- `overflow = true/false` per tenant.

The counters are approximate. Increments aren't atomic, so under heavy concurrency a pool can
briefly go a little over 90% before the spill starts. The 10% headroom and the circuit breakers
absorb this.

### Redis (external cache)

Redis holds the per-pool, per-second counters that trigger overflow. The policy uses
`caching-type="external"`, so the counters always live in Redis and never in APIM's built-in cache.

| Item | Setting |
| --- | --- |
| Service | Azure Cache for Redis, Standard C1 by default (`modules/platform/redis.tf`, deployed with `azapi`), registered as the APIM external cache. Premium with `redis_zones` for zone redundancy |
| Network | Public access disabled, private endpoint in the PE subnet. APIM reaches it over VNet integration on TLS port 6380 (the non-TLS port is closed); the integration subnet's NSG must allow that outbound |
| DNS | `privatelink.redis.cache.windows.net` linked to the APIM VNet. The cache is registered only after the link exists |
| Region | Same as APIM and DI (plan fails otherwise). Each Analyze call makes 2–4 Redis round trips |
| TLS | Minimum TLS 1.2 |
| Load | About 4 operations per Analyze call. At the gateway's full capacity (~100 calls/s) that's ~400 ops/s, well within Standard C1 |
| Data | Counters only, with a 2 s TTL. Nothing persistent; losing Redis loses nothing but the current second's counts |
| Auth | Entra ID enabled on the cache. APIM uses an access key, read at apply time and never stored in Terraform state; see below |

**If Redis is unavailable,** counter reads come back empty, so every pool looks below 90% and
nothing spills. Requests still go to the home pools, and the circuit breakers and retries still
apply. Overflow resumes when Redis recovers. Confirm in nonprod that a Redis outage produces cache
misses rather than failed requests on your tier (open verification point below).

### Redis authentication (option A)

**Requirement:** use Microsoft Entra ID for Redis authentication.

**Constraint:** APIM's external cache (`Microsoft.ApiManagement/service/caches`) accepts only a
`connectionString`. Its ARM schema from 2022 through `2025-09-01-preview` has no identity or
auth-type setting, so APIM itself can't authenticate with Entra.

**Chosen: option A.**

| Client | Authentication |
| --- | --- |
| Everyone except APIM (operators, future services) | **Microsoft Entra ID.** `aad-enabled` is on for the cache; grant access with `redis_entra_access` (Data Owner, Data Contributor or Data Reader) |
| APIM external cache | **Access key**, the only one in use. Read at apply time through an ephemeral `listKeys` call and written to APIM through a write-only `sensitive_body`, so it is **never stored in Terraform state, plan files or the repo** |

This is why the cache and its APIM registration use `azapi` instead of azurerm: both
`azurerm_redis_cache` and `azurerm_api_management_redis_cache` keep the key in state.

**Key rotation** without downtime: move APIM to the other key (`redis_apim_key`), apply, then
regenerate the old one. If a key was regenerated while APIM was using it, bump
`redis_key_version` and apply. See [`scripts/rotate-redis-key.md`](scripts/rotate-redis-key.md).

Options considered: B (no Redis, counters in APIM's built-in cache, no keys at all) and C (Entra
only, access keys disabled: APIM couldn't connect, so overflow would stop working).

### Other controls that still apply

1. **Per-tenant contract limits.** `rate-limit-by-key` on the caller's Entra client ID (standard:
   10 calls/5 s, gold: 30 calls/5 s) and a daily `quota-by-key`. These cap one tenant's
   contracted volume and are the **only** place the gateway returns 429 on its own. Pool capacity
   never causes a gateway 429. Raise a tenant's tier (or the tier limits) if it needs more.
2. **Pool isolation.** General and critical workloads use different DI resources and different
   overflow pools, so a general surge cannot throttle critical work.
3. **Weighted spread.** Each pool round-robins across its members by weight from the first request.
4. **Circuit breaker and retry.** A member that returns 429 or 5xx trips for 10 s, or for DI's
   `Retry-After`, and the retry lands on another member or pool.
5. **2 s polling floor.** Result GETs are limited to one per result every 2 s. GETs are often the
   binding limit: `GET/s = POST/s × processing seconds ÷ 2` must stay under 80% of 50 per resource.
6. **Result pinning.** A result GET goes to the one DI resource that accepted the job, whether it
   was a home or an overflow member, via a signed, tenant-bound ticket. GETs never go through a
   pool, because a different member would return 404.

If overflow is used regularly (see `x-daas-pool` in the logs), the pool needs more capacity:
raise member TPS through a support ticket, add a member, or add an overflow member.

## What Terraform deploys

| Component | Terraform | Notes |
| --- | --- | --- |
| Existing APIM lookup and guardrails (Standard v2 or Premium v2, private, VNet-integrated, managed identity) | `modules/platform/existing_apim.tf` | `azapi` read of `Microsoft.ApiManagement/service` |
| Resource group for DI and supporting resources | `modules/platform/network.tf` | APIM stays in its own resource group |
| PE subnet: an existing one, or a spoke VNet + PE subnet + NSG peered with the APIM VNet | `modules/platform/network.tf` | `existing_pe_subnet_id` switches between the two |
| Private DNS zones for cognitiveservices, vaultcore and redis, linked to the APIM VNet | `modules/platform/dns.tf` | Or pass hub-owned zone IDs |
| Key Vault (RBAC, private endpoint) and bootstrap signing keys | `modules/platform/keyvault.tf` | Keys are ephemeral and write-only, never stored in state |
| Azure Cache for Redis (Entra ID enabled), its Entra access policy assignments, and the APIM external cache registration | `modules/platform/redis.tf` | `azapi`, so the access key never enters Terraform state. **Required:** holds the per-pool, per-second counters that trigger overflow |
| Log Analytics, and diagnostic settings for APIM and Key Vault | `modules/platform/monitoring.tf` | |
| 7 DI accounts (2 general, 3 critical, 1 general overflow, 1 critical overflow): no public access, no local auth, private endpoint, `Cognitive Services User` for APIM | `modules/di-gateway/di_accounts.tf` | |
| APIM backends with circuit breakers | `modules/di-gateway/apim_backends.tf` | `azapi`, `backends@2024-05-01` |
| `pool-<env>-general`, `pool-<env>-critical`, `pool-overflow-general`, `pool-overflow-critical` | `modules/di-gateway/apim_pools.tf` | |
| API `di-v1`, two operations and three policies | `modules/di-gateway/apim_api.tf` | XML from `apim/policies` |
| Named values: tenant map, host map, pool capacity map, overflow thresholds, signing keys (Key Vault refs), identities | `modules/di-gateway/named_values.tf` | |
| Guardrails | `modules/di-gateway/checks.tf` | Plan fails on a violation |

### Prerequisites on the existing APIM instance

- **Tier:** Standard v2 (`sku.name = StandardV2`) or Premium v2, in the same subscription and
  region as `location`. `allowed_apim_skus` controls which tiers are accepted.
- **Private inbound:** an inbound private endpoint on the gateway, then public network access
  set to Disabled (Azure only allows disabling it once a private endpoint exists). No public IP.
  Clients resolve the gateway through a `privatelink.azure-api.net` zone owned by your network
  team; this repo doesn't manage the inbound endpoint.
- **Outbound VNet integration:** the instance is integrated with a subnet of `apim_vnet_id`
  delegated to `Microsoft.Web/serverFarms`. This is how APIM reaches the DI, Key Vault and Redis
  private endpoints. (On Premium v2, VNet injection in Internal mode also works.)
- **Identity:** a system-assigned managed identity. Terraform grants it `Cognitive Services User`
  on each DI account and `Key Vault Secrets User` on the vault.
- **Network:** `apim_vnet_id` is the VNet APIM integrates with. APIM must reach the PE subnet,
  either because the subnet is in that VNet (not the delegated integration subnet itself) or
  through the peering Terraform creates. NSGs and route tables on the integration subnet must
  allow outbound 443 (DI, Key Vault) and 6380 (Redis) to it.
- **DNS:** APIM must resolve `*.cognitiveservices.azure.com`, `*.vault.azure.net` and
  `*.redis.cache.windows.net` to the private endpoints. Terraform links the zones it creates to the
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
scripts/                onboard-tenant.md, rotate-signing-key.sh, rotate-redis-key.md, model-copy/ (stub)
dispatcher/             batch dispatcher contract (stub)
```

## Configuration

Each environment has two config files:

- `platform.auto.tfvars`: subscription, region, the existing APIM instance (name, resource
  group, VNet), the PE subnet or spoke address space, and identities.
- `di.auto.tfvars`: the two pools (`di_cells`), the overflow pools (`di_overflow`), the thresholds and `di_tenants`.
  Onboarding a workload changes only this file; see [`scripts/onboard-tenant.md`](scripts/onboard-tenant.md).

A tenant is an Entra client ID assigned to a pool:

```hcl
di_tenants = {
  "<client id>" = { cell = "prod-general",  tier = "standard", overflow = true, modelPrefix = "t001-" }
  "<client id>" = { cell = "prod-critical", tier = "gold",     overflow = true, modelPrefix = "t101-" }
}
```

Nonprod mirrors prod's topology (2 + 3, plus 1 + 1 overflow). S0 is billed per page, so the extra resources cost
nothing when idle, and load tests stay representative. All IDs in the committed tfvars are
placeholders marked `TODO`.

## Guardrails (plan fails)

- **Existing APIM:** it is Standard v2 or Premium v2 (per `allowed_apim_skus`); private (public
  access disabled, or Internal injection on Premium v2) with no public IP; VNet-integrated into
  `apim_vnet_id`; and has a system-assigned identity.
- Every tenant references an existing pool.
- Overflow-enabled tenants have an overflow pool in their zone, and none are Restricted.
- DI accounts per region, including `dedicated_di_count`, stay at or below 20.
- No pool has more than 30 members. No DI member appears in two pools.
- `tenant-cell-map`, `di-host-map` and `pool-capacity-map` stay within the 4,096-character named-value limit.
- `overflow_threshold_pct` is 50–100; member `tps` is 1–1000.
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

The Terraform tests use mocked providers, including a mocked private Standard v2 instance, so
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
| Existing APIM **Standard v2**, read-only in Terraform | Premium v2 isn't yet available in Australia East. Standard v2 stays private through an inbound private endpoint and outbound VNet integration instead of VNet injection |
| Two pools (general 2, critical 3), each with its own overflow pool | Requested deployment profile |
| Overflow triggered at 90% of pool capacity, not after the pool is exhausted | Requested: requests spill to overflow before throttling instead of being rejected. The design only used overflow on the final retry after 429s |
| The per-tenant overflow cap is a share of overflow capacity per second (50%) | Replaces the design's fixed 30 calls / 10 s; it scales with the overflow pool's size |
| Added a `critical` workload zone | It is isolated from general exactly as Confidential is |
| `tenant-cell-map` and `di-host-map` stored as base64(JSON) | Raw JSON quotes placed inside `value="{{...}}"` attributes would break the policy XML |
| Guardrails are `precondition`s, not `check` blocks | `check` blocks only warn |
| `di_name_suffix` on DI account names and subdomains | DI subdomains are globally unique. Backend keys stay the bare member names |
| Azure Cache for Redis (not Azure Managed Redis) | Azure Managed Redis can't be used in this environment. Microsoft has announced Azure Cache for Redis's retirement (2028); confirm new caches can still be created in your subscription |

## Verification points

Resolved:

- [x] **azapi API version:** `2024-05-01` is the latest GA version whose schema includes both
  `circuitBreaker` and `pool`. Both backend bodies validate against azapi v2.12.0's embedded schema.

Still open (validate in nonprod before rollout):

- [ ] **Standard v2 features:** confirm that backend pools, circuit breakers, `rate-limit-by-key`,
  `quota-by-key`, the external cache, `authentication-managed-identity` and Key Vault named values
  behave on your Standard v2 instance as the policies expect.
- [ ] **Standard v2 network properties:** confirm the instance reports `publicNetworkAccess =
  Disabled` and a `virtualNetworkConfiguration.subnetResourceId` in `apim_vnet_id`. The guardrail
  reads both.
- [ ] Whether `HMACSHA256`, `Regex`, `Func` and `Convert.FromBase64String` are allowed in policy
  expressions on Standard v2.
- [ ] **Standard v2 limits:** capacity scales to 10 units, and it has a lower SLA than Premium v2
  with no zone redundancy or multi-region. Size units for peak gateway throughput. Every request
  also makes 2–4 cache calls to Redis for the overflow counters, so keep Redis in the same region.
- [ ] How a fully tripped pool surfaces: a 503 `context.Response`, or `on-error`. Adjust the
  Analyze retry condition and the API `on-error` source check to match.
- [ ] Whether retries land on a different member (load test 3, `tests/load/queries.kql`).
- [ ] Whether the built-in `azuremonitor` logger exists on the instance. It is used by the API
  diagnostic for per-tenant logging.
- [ ] **External cache authentication:** option A is implemented (Entra ID on the cache; APIM uses
  an access key that's never stored in state). Recheck when upgrading the APIM API version: if the
  caches resource gains a managed-identity setting, switch APIM to it and disable access keys.
- [ ] **Write-only values:** on the first apply, confirm APIM's external cache shows as connected
  (the connection string comes from an ephemeral `listKeys` call and `sensitive_body`, which need
  Terraform 1.11+ and azapi 2.x).
- [ ] **Redis outage behaviour:** confirm what APIM does on your tier when the external cache
  is unreachable (cache miss or policy error), and that Analyze keeps working (see
  [Redis](#redis-external-cache)).
- [ ] **Overflow routing:** load test 4 must show spill starting near 90% (`x-daas-pool` in the
  logs), and APIM Standard v2 must accept `cache-lookup-value` with `default-value` against the
  external cache. Check how far counters overshoot under your gateway unit count.
- [ ] Per-tier limits (standard 10/5 s, gold 30/5 s) and the 200,000/day quota are hard-coded in
  `op-analyze.xml`. They are the only gateway-side 429s left; set them from onboarding data.
- [ ] Whether the 20-resource DI limit is per subscription per region, or per region only.
- [ ] **DeployEz conventions:** align the layout if a template repo exists.
- [ ] RBAC propagation: on a first apply, APIM may need a few minutes to resolve the Key Vault
  named values after its role grant. Re-run the apply if the named-value step fails once.

## Out of scope (stubs)

- Batch dispatcher (AKS, Service Bus, Redis token buckets): [`dispatcher/README.md`](dispatcher/README.md)
- Custom-model copy pipeline and replication gate: [`scripts/model-copy/README.md`](scripts/model-copy/README.md).
  Custom models must exist on **every** member of a tenant's pool **and** its zone's overflow pool,
  or a request that retries or spills to another member fails.
- Alert rules (429 rate per DI resource, breaker trips, pool saturation). The logs are in place;
  the alert rules are not.
