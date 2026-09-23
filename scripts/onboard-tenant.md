# Runbook: onboard a tenant

Placement is decided once, at onboarding, by committed peak TPS. It lands in
`infra/terraform/envs/<env>/di.auto.tfvars` and deploys through the pipeline, never by hand.

## 1. Collect from the tenant

| Input | Used for |
| --- | --- |
| Entra client ID of the calling app (or apps) | `di_tenants` key; the gateway's tenant identity |
| Zone: General, Confidential or Restricted | Which cells are eligible |
| Peak Analyze TPS (not average) | Cell budget |
| Average pages per document and processing time | GET budget |
| Prebuilt or custom models | Model prefix, replication, overflow eligibility |
| Daily volume | `quota-by-key` (currently 200,000/day for all tiers) |

## 2. Choose the tier

| Tier | Gateway limit (op-analyze.xml) | Typical peak |
| --- | --- | --- |
| standard | 10 calls / 5 s (2 TPS average) | ≤ 2 TPS |
| gold | 30 calls / 5 s (6 TPS average) | ≤ 6 TPS |

A tenant above gold needs a new tier in the policy, or promotion to Dedicated.

## 3. Place the tenant (80% budget rule)

For each cell in the tenant's (environment, zone):

- **Analyze budget:** sum of committed peaks + this tenant's peak ≤ 0.8 × cell Analyze TPS.
  Cell Analyze TPS is the sum of member TPS (15 per member by default, or the approved increase).
- **GET budget:** for each member, `(POST/s × avg processing s) ÷ 2` ≤ 0.8 × 50.
  GET is often the binding limit for large, slow documents.

Pick the cell with the most headroom that passes both checks.

**No cell fits:**
1. If the regional budget allows (the `regional_di_count` output plus 2 ≤ 20), add a cell of
   2 members to `di_cells`.
2. Otherwise promote the tenant to Dedicated (step 5).

**Restricted** tenants always get a Dedicated cell (`zone = "restricted"`, one or more members)
with `overflow = false`.

## 4. Set overflow

`overflow = true` only if **all** of these hold:

- The tenant's zone is General or Confidential, and `di_overflow` has a pool for that zone.
- The tenant uses prebuilt models only, **or** its custom models are replicated to every
  member of its cell **and** its zone's overflow pool (see `scripts/model-copy/README.md`).

The guardrails in `modules/di-gateway/checks.tf` fail the plan for Restricted or zone-less overflow.

## 5. Promote to Dedicated

Promote when the tenant's overflow share exceeds its cap for 15 minutes (the overflow-by-zone
alert), or when it does not fit any cell. Add a single-member cell for the tenant and move
its `di_tenants` entry to it. Dedicated resources managed by another stack count against the
regional limit through `dedicated_di_count`.

## 6. Add the entry and deploy

```hcl
# infra/terraform/envs/prod/di.auto.tfvars
di_tenants = {
  # ...
  "<entra client id>" = { cell = "prod-gen-c", tier = "standard", overflow = true, modelPrefix = "t006-" }
}
```

- `modelPrefix` is unique per tenant; the gateway only allows `prebuilt-*` or models with this prefix.
- Open a PR. The pipeline runs fmt, validate, tflint, checkov, guardrail tests and plan.
  The plan should show only the `tenant-cell-map` named value changing.
- After approval, apply. Give the tenant the gateway host and audience, and tell them to:
  poll no more often than every 2 s, honour `Retry-After`, send documents over 50 MB as
  `urlSource`, and ramp load gradually.
