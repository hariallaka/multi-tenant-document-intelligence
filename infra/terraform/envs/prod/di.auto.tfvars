# DeployEz config layer: cell placement for prod. Changes deploy through the
# pipeline only. See scripts/onboard-tenant.md for placement rules.
#
# Regional budget (australiaeast, limit 20):
#   General cells 4 x 2 = 8, Confidential 1 x 2 = 2, Restricted 1,
#   Overflow (General 2, Confidential 1) = 3, Dedicated elsewhere = 5, reserve 1.

di_cells = {
  "prod-gen-a" = {
    zone = "general"
    members = {
      "di-prod-gen-a1" = { weight = 1 }
      "di-prod-gen-a2" = { weight = 1 }
    }
  }
  "prod-gen-b" = {
    zone = "general"
    members = {
      "di-prod-gen-b1" = { weight = 3 } # TPS raised to 45 via support ticket
      "di-prod-gen-b2" = { weight = 1 }
    }
  }
  "prod-gen-c" = {
    zone = "general"
    members = {
      "di-prod-gen-c1" = { weight = 1 }
      "di-prod-gen-c2" = { weight = 1 }
    }
  }
  "prod-gen-d" = {
    zone = "general"
    members = {
      "di-prod-gen-d1" = { weight = 1 }
      "di-prod-gen-d2" = { weight = 1 }
    }
  }
  "prod-conf-a" = {
    zone = "confidential"
    members = {
      "di-prod-conf-a1" = { weight = 1 }
      "di-prod-conf-a2" = { weight = 1 }
    }
  }
  "prod-res-t005" = {
    zone = "restricted" # Dedicated resource for one Restricted tenant; never overflows
    members = {
      "di-prod-res-t005" = { weight = 1 }
    }
  }
}

di_overflow = {
  general = {
    "di-prod-ovf-gen-1" = { weight = 1 }
    "di-prod-ovf-gen-2" = { weight = 1 }
  }
  confidential = {
    "di-prod-ovf-conf-1" = { weight = 1 }
  }
}

# Dedicated DI accounts in this region that other stacks own.
dedicated_di_count = 5

di_tenants = {
  "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "prod-gen-a", tier = "standard", overflow = true, modelPrefix = "t001-" }
  "3f1c0d8e-0000-0000-0000-000000000002" = { cell = "prod-gen-b", tier = "gold", overflow = true, modelPrefix = "t002-" }
  "3f1c0d8e-0000-0000-0000-000000000003" = { cell = "prod-conf-a", tier = "standard", overflow = false, modelPrefix = "t003-" } # custom models not replicated to overflow
  "3f1c0d8e-0000-0000-0000-000000000004" = { cell = "prod-conf-a", tier = "standard", overflow = true, modelPrefix = "t004-" }
  "3f1c0d8e-0000-0000-0000-000000000005" = { cell = "prod-res-t005", tier = "gold", overflow = false, modelPrefix = "t005-" }
}
