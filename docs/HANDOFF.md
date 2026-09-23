# Handoff: build the `di-gateway` repo

Paste this file's contents into Claude Code as the first message (or save it as `HANDOFF.md` in an empty repo and say "follow HANDOFF.md"). The full design, including the reference APIM policies and Terraform, is in `docs/design.md`. Treat that document as the source of truth.

## Goal

Create a deployable repository for a shared, multi-tenant Azure AI Document Intelligence (S0) service fronted by Azure API Management. It must:

1. Prevent 429s through per-tenant admission control.
2. Contain noisy tenants, with circuit-breaker failover and capped, zone-specific overflow.
3. Spread the first request across a tenant's home cell, not a single resource.
4. Keep async results pinned to the accepting resource via signed, tenant-bound result tickets.

## Hard constraints (do not relax)

- **Network:** private endpoints only. Set `public_network_access_enabled = false` on every DI account, and never create public DI endpoints.
- **Authentication:** `local_auth_enabled = false`. APIM reaches DI with its managed identity only. No API keys anywhere.
- **Secrets:** none in the repo. Signing keys are Key Vault references. The pipeline authenticates with Workload Identity Federation (OIDC), not client secrets.
- **Zones:** each zone (General, Confidential) has its own overflow pool. Restricted tenants get no overflow.
- **Resource types:** APIM backends and pools use `azapi_resource` (`Microsoft.ApiManagement/service/backends`). Pin the provider versions and the ARM API version.
- **IaC conventions:** follow the team's existing DeployEz conventions (config-driven Terraform, Azure DevOps pipelines). If a DeployEz template repo or module layout exists, ask for it and match it rather than inventing a new structure.

## Target layout (adjust to DeployEz conventions if they differ)

```
di-gateway/
├── README.md                     # purpose, architecture summary, how to onboard a tenant
├── CLAUDE.md                     # repo conventions for future Claude Code sessions
├── docs/
│   └── design.md                 # copy of the design spec (provided)
├── apim/
│   ├── policies/
│   │   ├── api-di-v1.xml         # API-level policy (design §APIM policy set, 1)
│   │   ├── op-analyze.xml        # Analyze operation (2)
│   │   └── op-result.xml         # Result operation (3)
│   └── openapi/di-v1.yaml        # POST /documentModels/{modelId}/analyze, GET /results/{ticket}
├── infra/terraform/
│   ├── modules/di-gateway/
│   │   ├── versions.tf           # azurerm + azapi pinned
│   │   ├── variables.tf
│   │   ├── locals.tf
│   │   ├── di_accounts.tf        # cognitive accounts, private endpoints, RBAC
│   │   ├── apim_backends.tf      # single backends with circuit breakers
│   │   ├── apim_pools.tf         # cell pools + per-zone overflow pools
│   │   ├── apim_api.tf           # API, operations, policies loaded from apim/policies
│   │   ├── named_values.tf       # tenant-cell-map (zone derived), di-host-map, signing keys
│   │   ├── checks.tf             # guardrails (see below)
│   │   └── outputs.tf
│   └── envs/
│       ├── nonprod/{main.tf,backend.tf,di.auto.tfvars}
│       └── prod/{main.tf,backend.tf,di.auto.tfvars}
├── pipelines/
│   └── azure-pipelines.yml       # fmt → validate → tflint → checkov → plan → approval → apply
├── tests/
│   ├── policy/                   # unit tests for ticket sign/verify logic (C# or Python port)
│   └── load/                     # the six load-test scenarios from the design, as scripts
└── scripts/
    └── onboard-tenant.md         # runbook: placement rules, 80% budget, promotion to Dedicated
```

## Build steps

1. Scaffold the layout. Copy the Terraform and policy XML from `docs/design.md` into the files above, splitting by concern.
2. Wire `apim_api.tf` to load the policy XML with `file()` or `templatefile()`, and to create the two operations.
3. Add `checks.tf` with these guardrails:
   - Every tenant references an existing cell.
   - Overflow-enabled tenants have an overflow pool in their zone, and none are Restricted.
   - Total DI accounts per region, including Dedicated, stay at or below 20.
   - Pool member count stays at or below 30.
4. Write example `di.auto.tfvars` for nonprod and prod using placeholder tenant IDs.
5. Write the pipeline:
   - Use WIF service connection placeholders.
   - Require a manual approval before prod apply.
   - Publish the plan as an artifact.
6. Add `tests/policy`: port the HMAC ticket build/verify logic and test it for round-trip, tampered signature, wrong tenant, and previous-key acceptance.
7. Add `tests/load` scripts matching the six scenarios in the design (§Security, observability, capacity and testing).
8. Write the README and CLAUDE.md.
9. Run `terraform fmt`, `terraform validate` and `tflint` locally and fix issues before finishing.

## Known points to verify (do not assume; flag in README if unresolved)

- Which `azapi` API version validates `circuitBreaker` and `pool` for backends. Pin to the latest GA version that does.
- Whether `HMACSHA256`, `Regex` and `Func` are allowed in APIM policy expressions on the chosen tier.
- How a fully tripped pool surfaces in APIM: a 503 response, or `on-error`. Adjust the retry condition to match.
- APIM tier and networking: Premium VNet-injected, or v2 with VNet integration, with line-of-sight to the DI private endpoints.
- Whether the 20-resource limit is per subscription per region or per region only.
- An external Redis cache must be attached to APIM for the overflow counters.

## Out of scope for this pass (stub only, with TODO)

- The batch dispatcher service (AKS + Service Bus + Redis token buckets). Create `dispatcher/README.md` describing its contract from the design.
- The custom-model copy pipeline. Create `scripts/model-copy/README.md` describing the replication gate.

## Done when

- `terraform validate` passes for both envs.
- The policy tests pass.
- The pipeline YAML lints.
- The README lists any unresolved verification points.
