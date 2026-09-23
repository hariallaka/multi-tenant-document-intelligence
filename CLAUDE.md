# CLAUDE.md

Shared, multi-tenant Azure AI Document Intelligence behind an internal APIM gateway.
`docs/design.md` is the source of truth. Read it before changing policies or routing.

## Hard constraints (never relax)

- DI accounts: `public_network_access_enabled = false`, `local_auth_enabled = false`,
  private endpoints only. APIM reaches DI with its managed identity. No API keys anywhere.
- No secrets in the repo. Signing keys are Key Vault references. Pipelines use WIF (OIDC).
- Overflow is per zone (`pool-overflow-general`, `pool-overflow-confidential`). Restricted never overflows.
- APIM backends and pools use `azapi_resource` pinned to `Microsoft.ApiManagement/service/backends@2024-05-01`
  (`local.apim_backends_type`). Provider versions are pinned in `envs/*/main.tf`.
- The Result operation targets a single backend: never a pool, never a retry.
- Backend keys are stable member names (e.g. `di-prod-gen-a1`), never hostnames.

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
(cd infra/terraform/modules/di-gateway && terraform init -backend=false && terraform test)
for e in nonprod prod; do (cd infra/terraform/envs/$e && terraform init -backend=false && terraform validate && terraform test); done
for d in infra/terraform/{modules/di-gateway,modules/platform,envs/nonprod,envs/prod}; do tflint --config=$PWD/.tflint.hcl --chdir=$d; done
checkov -d infra/terraform --framework terraform --quiet
python3 -m pytest tests/policy
```
