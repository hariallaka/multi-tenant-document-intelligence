# CLAUDE.md

Shared, multi-tenant Azure AI Document Intelligence behind an existing, private APIM Standard v2
instance (Premium v2 also accepted). `docs/design.md` is the source of truth for policies and routing. The README's
"Deployment profile" records where this repo narrows it: the APIM instance already exists (Standard v2: inbound private endpoint + outbound VNet integration),
there are two pools (general 2 DI, critical 3 DI), each with its own zone overflow pool, and
requests spill to overflow at 90% of pool capacity instead of being rejected.

## Hard constraints (never relax)

- DI accounts: `public_network_access_enabled = false`, `local_auth_enabled = false`,
  private endpoints only. APIM reaches DI with its managed identity. No API keys anywhere.
- No secrets in the repo. Signing keys are Key Vault references. Pipelines use WIF (OIDC).
- The APIM instance itself is never created or reconfigured by Terraform (it only adds APIs, backends,
  named values, the external cache and a diagnostic setting). It is read in `modules/platform/existing_apim.tf`,
  and the plan must fail unless it is Standard v2 or Premium v2, private (public access disabled or Internal
  injection), without a public IP and VNet-integrated into `apim_vnet_id`. Never add a public IP.
- Pools never share DI resources. Overflow is per zone (`pool-overflow-<zone>`); Restricted never overflows.
- The gateway never returns 429 because of pool capacity: at `overflow-threshold-pct` it spills to overflow,
  and when both pools are busy it still forwards to the home pool. Only per-tenant contract limits reject.
  The routing port in `tests/policy/routing.py` must match `op-analyze.xml`.
- Overflow counters use `caching-type="external"` (the Azure Cache for Redis external cache), never the
  built-in cache. APIM, Redis and DI must be in the same region (guardrail).
- APIM backends and pools use `azapi_resource` pinned to `Microsoft.ApiManagement/service/backends@2024-05-01`
  (`local.apim_backends_type`). Provider versions are pinned in `envs/*/main.tf`.
- The Result operation targets a single backend: never a pool, never a retry.
- Backend keys are stable member names (e.g. `di-prod-gen-1`), never hostnames.

## Conventions

- Config lives in `envs/<env>/di.auto.tfvars` (cells, overflow, tenants) and `platform.auto.tfvars`.
  Tenant onboarding changes only `di.auto.tfvars`; see `scripts/onboard-tenant.md`.
- Named values that hold JSON are stored as base64 and decoded in the policy expression.
- A guardrail is a `precondition` in `modules/di-gateway/checks.tf` with a matching run in
  `modules/di-gateway/tests/guardrails.tftest.hcl`.
- Changing the ticket format in `apim/policies/op-*.xml` means updating `tests/policy/ticket.py`.
  `tests/policy/test_policy_xml.py` pins the shared building blocks.
- Every `{{named-value}}` a policy references must be created in `named_values.tf` (tested).
- `count` and `for_each` must not depend on apply-time values (use static flags such as `enable_diagnostics`).

## Before committing

```bash
terraform fmt -recursive infra/terraform
for d in modules/platform modules/di-gateway envs/nonprod envs/prod; do (cd infra/terraform/$d && terraform init -backend=false && terraform validate && terraform test); done
for d in infra/terraform/{modules/di-gateway,modules/platform,envs/nonprod,envs/prod}; do tflint --config=$PWD/.tflint.hcl --chdir=$d; done
checkov -d infra/terraform --framework terraform --quiet
python3 -m pytest tests/policy
```
