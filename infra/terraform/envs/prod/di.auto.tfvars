# DeployEz config layer: DI pools for prod. Changes deploy through the pipeline only.
# See scripts/onboard-tenant.md for placement rules.
#
# Routing (apim/policies/op-analyze.xml): APIM counts Analyze calls per pool per
# second. Below overflow_threshold_pct (90%) of a pool's capacity the pool serves the
# request. At or above it, requests are sent to that zone's overflow pool instead of
# being rejected. Overflow pools sit idle until then.
#
#   pool                    DI   Analyze TPS   spills at (90%)
#   pool-prod-general          2        30          27/s  -> pool-overflow-general
#   pool-prod-critical         3        45          40/s  -> pool-overflow-critical
#   pool-overflow-general    1        15          stops taking spill at 13/s
#   pool-overflow-critical   1        15          stops taking spill at 13/s
#
# Pools never share DI resources, and general and critical each have their own
# overflow pool. One tenant may use at most 50% of an overflow pool per second
# (overflow_tenant_share_pct). If a pool and its overflow are both busy, requests still
# go to the home pool; circuit breakers and retries handle any 429 there.
#
# DI S0 is billed per page, not per resource, so idle overflow accounts cost nothing,
# and nonprod mirrors prod's topology.

overflow_threshold_pct    = 90
overflow_tenant_share_pct = 50

di_cells = {
  "prod-general" = {
    zone = "general"
    members = {
      "di-prod-gen-1" = { weight = 1, tps = 15 }
      "di-prod-gen-2" = { weight = 1, tps = 15 }
    }
  }
  "prod-critical" = {
    zone = "critical"
    members = {
      "di-prod-crit-1" = { weight = 1, tps = 15 }
      "di-prod-crit-2" = { weight = 1, tps = 15 }
      "di-prod-crit-3" = { weight = 1, tps = 15 } # after a TPS increase: tps = 45, weight = 3
    }
  }
}

# One overflow pool per zone. They are never shared between general and critical.
di_overflow = {
  general = {
    "di-prod-ovf-gen-1" = { weight = 1, tps = 15 }
  }
  critical = {
    "di-prod-ovf-crit-1" = { weight = 1, tps = 15 }
  }
}

# Tenant client ID => pool. overflow = true lets the tenant spill to its zone's
# overflow pool at 90%. Custom models must be copied to the overflow account as well
# (scripts/model-copy/README.md); a tenant whose models are not replicated needs
# overflow = false.
di_tenants = {
  "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "prod-general", tier = "standard", overflow = true, modelPrefix = "t001-" }
  "3f1c0d8e-0000-0000-0000-000000000002" = { cell = "prod-general", tier = "standard", overflow = true, modelPrefix = "t002-" }
  "3f1c0d8e-0000-0000-0000-000000000003" = { cell = "prod-general", tier = "gold", overflow = true, modelPrefix = "t003-" }
  "3f1c0d8e-0000-0000-0000-000000000101" = { cell = "prod-critical", tier = "gold", overflow = true, modelPrefix = "t101-" }
  "3f1c0d8e-0000-0000-0000-000000000102" = { cell = "prod-critical", tier = "gold", overflow = true, modelPrefix = "t102-" }
}
