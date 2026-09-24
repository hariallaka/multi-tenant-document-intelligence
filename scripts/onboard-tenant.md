# Runbook: onboard a workload (tenant)

A tenant is an internal application, identified by its Entra client ID, assigned to one pool.
Placement is decided at onboarding by committed **peak** TPS. It lands in
`infra/terraform/envs/<env>/di.auto.tfvars` and deploys through the pipeline, never by hand.

## 1. Collect from the workload owner

| Input | Used for |
| --- | --- |
| Entra client ID of the calling app | `di_tenants` key; the gateway's tenant identity |
| Workload class: general or critical | Which pool |
| Peak Analyze TPS (not average) | Pool budget |
| Average pages per document and processing time | GET budget |
| Prebuilt or custom models | Model prefix and replication |
| Daily volume | `quota-by-key` (currently 200,000/day for all tiers) |

## 2. Choose the pool

| Pool | Members | Planning budget (80%) | Spills to overflow at (90%) | Use for |
| --- | --- | --- | --- | --- |
| `<env>-general` | 2 | 24 Analyze TPS, 80 GET/s | 27/s → `pool-overflow-general` | Everything not business-critical |
| `<env>-critical` | 3 | 36 Analyze TPS, 120 GET/s | 40/s → `pool-overflow-critical` | Workloads that must not be throttled by others |

The pools share no DI resources, and each has its own overflow pool, so placing a workload in
critical protects it from general traffic.

## 3. Choose the tier

| Tier | Gateway limit (op-analyze.xml) | Typical peak |
| --- | --- | --- |
| standard | 10 calls / 5 s (2 TPS average) | ≤ 2 TPS |
| gold | 30 calls / 5 s (6 TPS average) | ≤ 6 TPS |

A workload above gold needs a new tier in the policy, or a dedicated pool.

## 4. Check the budget (plan at 80%, spill at 90%)

Plan each pool so committed peaks fit in 80% of its capacity. Overflow at 90% is burst headroom,
not planned capacity. If a pool relies on overflow every day, grow the pool.

For the chosen pool:

- **Analyze budget:** sum of committed peaks + this workload's peak ≤ the pool's budget above
  (0.8 × members × 15 TPS, or the approved per-member TPS).
- **GET budget:** `(POST/s × avg processing s) ÷ 2` for the pool ≤ its GET budget above.
  GET is often the binding limit for large, slow documents.

The comment at the top of `di.auto.tfvars` keeps a running total per pool; update it.

**The pool is full:**
1. Ask Microsoft for a TPS increase on the pool's members (support ticket with usage evidence),
   then raise each member's `weight` to match (e.g. 3 for 45 TPS).
2. Or add a member to the pool (`di_cells.<pool>.members`), within the 20-per-region limit
   (the `regional_di_count` output).
3. Or add a member to the zone's overflow pool (`di_overflow.<zone>`) to raise burst headroom.

Check how often a pool spills: in APIM gateway logs, `x-daas-pool` holds the pool that served
each request (`tests/load/queries.kql`: spill-rate).

## 5. Overflow and custom models

Set `overflow = true` (the default in this repo) so the workload spills to its zone's overflow
pool at 90% instead of competing for a saturated pool. Set it to `false` only if the workload
must never run on the overflow account.

Custom models must exist on **every** member of the workload's pool **and** its zone's overflow
pool under the same model ID, or a request that spills or retries elsewhere fails. See
`scripts/model-copy/README.md`. Until a model is replicated, use `overflow = false`.

## 6. Add the entry and deploy

```hcl
# infra/terraform/envs/prod/di.auto.tfvars
di_tenants = {
  # ...
  "<entra client id>" = { cell = "prod-critical", tier = "gold", overflow = true, modelPrefix = "t103-" }
}
```

- `modelPrefix` is unique per workload; the gateway only allows `prebuilt-*` or models with this prefix.
- Open a PR. The pipeline runs fmt, validate, tflint, checkov, guardrail tests and plan.
  The plan should show only the `tenant-cell-map` named value changing.
- After approval, apply. Give the workload the gateway host and audience, and tell them to:
  poll no more often than every 2 s, honour `Retry-After`, send documents over 50 MB as
  `urlSource`, and ramp load gradually.
