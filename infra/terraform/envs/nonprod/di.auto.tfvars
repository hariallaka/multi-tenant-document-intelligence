# DeployEz config layer: cell placement for nonprod (load-test topology).
# One cell per zone plus one overflow member per zone: enough to exercise
# failover, zone-specific overflow and Restricted isolation (design load tests 1-6).

di_cells = {
  "np-gen-a" = {
    zone = "general"
    members = {
      "di-np-gen-a1" = { weight = 1 }
      "di-np-gen-a2" = { weight = 1 }
    }
  }
  "np-conf-a" = {
    zone = "confidential"
    members = {
      "di-np-conf-a1" = { weight = 1 }
      "di-np-conf-a2" = { weight = 1 }
    }
  }
  "np-res-t905" = {
    zone = "restricted"
    members = {
      "di-np-res-t905" = { weight = 1 }
    }
  }
}

di_overflow = {
  general = {
    "di-np-ovf-gen-1" = { weight = 1 }
  }
  confidential = {
    "di-np-ovf-conf-1" = { weight = 1 }
  }
}

di_tenants = {
  "3f1c0d8e-0000-0000-0000-000000000901" = { cell = "np-gen-a", tier = "standard", overflow = true, modelPrefix = "t901-" }
  "3f1c0d8e-0000-0000-0000-000000000902" = { cell = "np-gen-a", tier = "gold", overflow = true, modelPrefix = "t902-" }
  "3f1c0d8e-0000-0000-0000-000000000903" = { cell = "np-conf-a", tier = "standard", overflow = true, modelPrefix = "t903-" }
  "3f1c0d8e-0000-0000-0000-000000000905" = { cell = "np-res-t905", tier = "standard", overflow = false, modelPrefix = "t905-" }
}
