# DeployEz config layer: DI pools for nonprod. Changes deploy through the pipeline only.
# See scripts/onboard-tenant.md for placement rules.
#
# Two pools, each fronted by the APIM gateway:
#
#   pool-np-general   2 DI (S0)   Analyze 2 x 15 = 30 TPS -> admit <= 24 TPS (80%)
#                                 GET     2 x 50 = 100/s  -> keep  <= 80/s
#   pool-np-critical  3 DI (S0)   Analyze 3 x 15 = 45 TPS -> admit <= 36 TPS (80%)
#                                 GET     3 x 50 = 150/s  -> keep  <= 120/s
#
# The pools never share DI resources, so a general-workload surge cannot throttle
# critical workloads. Within a pool, a throttled (429) member trips its circuit
# breaker and APIM retries on another member. The critical pool keeps 2 healthy
# members (30 TPS) with one tripped.
#
# DI S0 is billed per page, not per resource, so nonprod mirrors prod's topology.

di_cells = {
  "np-general" = {
    zone = "general"
    members = {
      "di-np-gen-1" = { weight = 1 }
      "di-np-gen-2" = { weight = 1 }
    }
  }
  "np-critical" = {
    zone = "critical"
    members = {
      "di-np-crit-1" = { weight = 1 }
      "di-np-crit-2" = { weight = 1 }
      "di-np-crit-3" = { weight = 1 } # raise a weight if that member gets a TPS increase
    }
  }
}

# No overflow pools: each pool absorbs its own bursts. To add burst capacity later,
# add a zone-specific pool here (e.g. critical = { "di-np-ovf-crit-1" = { weight = 1 } })
# and set overflow = true on the tenants that may use it.
di_overflow = {}

# Tenant client ID => pool. Sum of committed peaks per pool must stay within its 80% budget.
#   general:  t001 2 + t002 2 + t003 6 = 10 TPS of 24
#   critical: t101 6 + t102 6          = 12 TPS of 36
di_tenants = {
  "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "np-general", tier = "standard", overflow = false, modelPrefix = "t001-" }
  "3f1c0d8e-0000-0000-0000-000000000002" = { cell = "np-general", tier = "standard", overflow = false, modelPrefix = "t002-" }
  "3f1c0d8e-0000-0000-0000-000000000003" = { cell = "np-general", tier = "gold", overflow = false, modelPrefix = "t003-" }
  "3f1c0d8e-0000-0000-0000-000000000101" = { cell = "np-critical", tier = "gold", overflow = false, modelPrefix = "t101-" }
  "3f1c0d8e-0000-0000-0000-000000000102" = { cell = "np-critical", tier = "gold", overflow = false, modelPrefix = "t102-" }
}
