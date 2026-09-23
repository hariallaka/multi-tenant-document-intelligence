# Custom-model copy pipeline (stub)

> TODO: not implemented in this pass. This describes the contract the pipeline must meet.

Failover and overflow only work for custom models if **the same model ID exists on every
pool member** the tenant can be routed to (design, correction 6).

## Replication targets

For a tenant with `modelPrefix = "t001-"` in cell `prod-gen-a`:

- every member of `prod-gen-a` (from `di_cells`), and
- if `overflow = true`, every member of the tenant's zone overflow pool (from `di_overflow`).

The `di_accounts` Terraform output lists each backend key with its host, cell and zone.

## Flow

1. The tenant trains or composes the model on the **source** member (first member of its cell),
   with a model ID starting with its prefix.
2. For each target member: call DI `documentModels:authorizeCopy` on the target, then
   `documentModels/{modelId}:copyTo` on the source with the authorisation, and poll the operation.
   All calls use Entra (workload identity); local auth is disabled on every account.
3. **Replication gate:** list models on every target; fail if any target lacks the model ID or
   its `createdDateTime` or description differs from the source.
4. If the gate fails for overflow targets only, the promotion pipeline sets the tenant's
   `overflow = false` in `di.auto.tfvars` (through a PR) rather than leave an unreplicated route.

## Limits to respect

- 500 neural and 5,000 template models per resource.
- Model management: 5 requests/s per resource. Copy sequentially per target.
