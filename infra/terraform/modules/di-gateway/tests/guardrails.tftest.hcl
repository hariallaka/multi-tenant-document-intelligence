# Plan-only tests for the placement guardrails and rendered named values.
# Providers are mocked, so no Azure credentials are needed:
#   cd infra/terraform/modules/di-gateway && terraform init -backend=false && terraform test

mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  location               = "australiaeast"
  rg_name                = "rg-test"
  pe_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pe"
  dns_zone_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
  apim_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test"
  apim_name              = "apim-test"
  apim_principal_id      = "11111111-1111-1111-1111-111111111111"
  signing_secret_id      = "https://kv-test.vault.azure.net/secrets/result-signing-key"
  signing_secret_prev_id = "https://kv-test.vault.azure.net/secrets/result-signing-key-prev"
  entra_tenant_id        = "22222222-2222-2222-2222-222222222222"
  gateway_audience       = "api://di-gateway-test"
  dispatcher_app_id      = "33333333-3333-3333-3333-333333333333"
  gateway_host           = "di.internal.example"

  di_cells = {
    "t-gen-a"  = { zone = "general", members = { "di-t-gen-a1" = { weight = 1 }, "di-t-gen-a2" = { weight = 3 } } }
    "t-conf-a" = { zone = "confidential", members = { "di-t-conf-a1" = { weight = 1 }, "di-t-conf-a2" = { weight = 1 } } }
    "t-res-a"  = { zone = "restricted", members = { "di-t-res-a1" = { weight = 1 } } }
  }
  di_overflow = {
    general      = { "di-t-ovf-gen-1" = { weight = 1 } }
    confidential = { "di-t-ovf-conf-1" = { weight = 1 } }
  }
  di_tenants = {
    "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "t-gen-a", tier = "standard", overflow = true, modelPrefix = "t001-" }
    "3f1c0d8e-0000-0000-0000-000000000003" = { cell = "t-conf-a", tier = "gold", overflow = true, modelPrefix = "t003-" }
    "3f1c0d8e-0000-0000-0000-000000000005" = { cell = "t-res-a", tier = "standard", overflow = false, modelPrefix = "t005-" }
  }
}

run "valid_config_plans" {
  command = plan

  assert {
    condition     = length(azurerm_cognitive_account.di) == 7
    error_message = "Expected 7 DI accounts (5 cell members + 2 overflow)."
  }

  assert {
    condition     = alltrue([for a in azurerm_cognitive_account.di : a.public_network_access_enabled == false && a.local_auth_enabled == false])
    error_message = "Every DI account must have public access and local auth disabled."
  }

  assert {
    condition     = length(azapi_resource.cell_pool) == 3 && length(azapi_resource.overflow_pool) == 2
    error_message = "Expected one pool per cell and one overflow pool per zone."
  }

  assert {
    condition     = azapi_resource.overflow_pool["general"].name == "pool-overflow-general" && azapi_resource.overflow_pool["confidential"].name == "pool-overflow-confidential"
    error_message = "Overflow pool names must match the policy's pool-overflow-<zone> convention."
  }

  assert {
    condition     = jsondecode(base64decode(azurerm_api_management_named_value.tenant_cell_map.value))["3f1c0d8e-0000-0000-0000-000000000003"].zone == "confidential"
    error_message = "tenant-cell-map must carry the zone derived from the tenant's cell."
  }

  assert {
    condition     = jsondecode(base64decode(azurerm_api_management_named_value.di_host_map.value))["di-t-gen-a1.cognitiveservices.azure.com"] == "di-t-gen-a1"
    error_message = "di-host-map must map DI hostnames to stable backend keys."
  }

  assert {
    condition     = alltrue([for n in azurerm_api_management_named_value.signing : n.secret == true])
    error_message = "Signing keys must be secret Key Vault references."
  }

  assert {
    condition     = output.regional_di_count == 7
    error_message = "Regional count should equal gateway-managed accounts when dedicated_di_count is 0."
  }
}

run "name_suffix_changes_hosts_not_backend_keys" {
  command = plan

  variables {
    di_name_suffix = "-x1"
  }

  assert {
    condition     = azurerm_cognitive_account.di["di-t-gen-a1"].custom_subdomain_name == "di-t-gen-a1-x1"
    error_message = "Suffix must apply to the DI subdomain."
  }

  assert {
    condition     = jsondecode(base64decode(azurerm_api_management_named_value.di_host_map.value))["di-t-gen-a1-x1.cognitiveservices.azure.com"] == "di-t-gen-a1"
    error_message = "Backend key must stay the bare member name so tickets survive resource replacement."
  }
}

run "tenant_with_unknown_cell_fails" {
  command = plan

  variables {
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000009" = { cell = "t-gen-zz", tier = "standard", overflow = false, modelPrefix = "t009-" }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "restricted_tenant_with_overflow_fails" {
  command = plan

  variables {
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000005" = { cell = "t-res-a", tier = "standard", overflow = true, modelPrefix = "t005-" }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "overflow_without_zone_pool_fails" {
  command = plan

  variables {
    di_overflow = {
      general = { "di-t-ovf-gen-1" = { weight = 1 } }
    }
  }

  # t003 is confidential with overflow = true, but no confidential pool exists.
  expect_failures = [terraform_data.guardrails]
}

run "regional_limit_fails" {
  command = plan

  variables {
    dedicated_di_count = 14 # 7 + 14 = 21 > 20
  }

  expect_failures = [terraform_data.guardrails]
}

run "pool_member_limit_fails" {
  command = plan

  variables {
    max_pool_members  = 1
    regional_di_limit = 100
  }

  expect_failures = [terraform_data.guardrails]
}

run "member_shared_across_pools_fails" {
  command = plan

  variables {
    di_overflow = {
      general      = { "di-t-gen-a1" = { weight = 1 } } # already a member of t-gen-a
      confidential = { "di-t-ovf-conf-1" = { weight = 1 } }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "restricted_overflow_pool_rejected" {
  command = plan

  variables {
    di_overflow = {
      general    = { "di-t-ovf-gen-1" = { weight = 1 } }
      restricted = { "di-t-ovf-res-1" = { weight = 1 } }
    }
  }

  expect_failures = [var.di_overflow]
}

run "unknown_tier_rejected" {
  command = plan

  variables {
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "t-gen-a", tier = "platinum", overflow = false, modelPrefix = "t001-" }
    }
  }

  expect_failures = [var.di_tenants]
}

run "general_and_critical_pools_plan" {
  command = plan

  variables {
    di_cells = {
      "t-general"  = { zone = "general", members = { "di-t-gen-1" = { weight = 1 }, "di-t-gen-2" = { weight = 1 } } }
      "t-critical" = { zone = "critical", members = { "di-t-crit-1" = { weight = 1 }, "di-t-crit-2" = { weight = 1 }, "di-t-crit-3" = { weight = 1 } } }
    }
    di_overflow = {}
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "t-general", tier = "standard", overflow = false, modelPrefix = "t001-" }
      "3f1c0d8e-0000-0000-0000-000000000101" = { cell = "t-critical", tier = "gold", overflow = false, modelPrefix = "t101-" }
    }
    apim_resource_group_name = "rg-apim"
  }

  assert {
    condition     = length(azapi_resource.cell_pool["t-critical"].body.properties.pool.services) == 3 && length(azapi_resource.cell_pool["t-general"].body.properties.pool.services) == 2
    error_message = "Expected a 2-member general pool and a 3-member critical pool."
  }

  assert {
    condition     = length(azapi_resource.overflow_pool) == 0
    error_message = "No overflow pools were configured."
  }

  assert {
    condition     = azurerm_api_management_api.di_v1.resource_group_name == "rg-apim" && azurerm_cognitive_account.di["di-t-crit-1"].resource_group_name == "rg-test"
    error_message = "APIM objects go to the APIM resource group; DI accounts to rg_name."
  }
}

run "critical_overflow_without_pool_fails" {
  command = plan

  variables {
    di_cells = {
      "t-critical" = { zone = "critical", members = { "di-t-crit-1" = { weight = 1 } } }
    }
    di_overflow = {}
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000101" = { cell = "t-critical", tier = "gold", overflow = true, modelPrefix = "t101-" }
    }
  }

  expect_failures = [terraform_data.guardrails]
}

run "capacity_map_and_thresholds_rendered" {
  command = plan

  variables {
    di_cells = {
      "t-general"  = { zone = "general", members = { "di-t-gen-1" = {}, "di-t-gen-2" = { weight = 3, tps = 45 } } }
      "t-critical" = { zone = "critical", members = { "di-t-crit-1" = {}, "di-t-crit-2" = {}, "di-t-crit-3" = {} } }
    }
    di_overflow = {
      general  = { "di-t-ovf-gen-1" = {} }
      critical = { "di-t-ovf-crit-1" = {}, "di-t-ovf-crit-2" = {} }
    }
    di_tenants = {
      "3f1c0d8e-0000-0000-0000-000000000001" = { cell = "t-general", tier = "standard", overflow = true, modelPrefix = "t001-" }
      "3f1c0d8e-0000-0000-0000-000000000101" = { cell = "t-critical", tier = "gold", overflow = true, modelPrefix = "t101-" }
    }
    overflow_threshold_pct = 90
  }

  assert {
    condition = jsondecode(base64decode(azurerm_api_management_named_value.pool_capacity_map.value)) == {
      "t-general"         = { tps = 60 }
      "t-critical"        = { tps = 45 }
      "overflow-general"  = { tps = 15 }
      "overflow-critical" = { tps = 30 }
    }
    error_message = "pool-capacity-map must hold summed member TPS per pool, keyed by cell and overflow-<zone>."
  }

  assert {
    condition     = azurerm_api_management_named_value.plain["overflow-threshold-pct"].value == "90" && azurerm_api_management_named_value.plain["overflow-tenant-share-pct"].value == "50"
    error_message = "Threshold named values must be rendered."
  }

  assert {
    condition     = output.pool_capacity["t-general"].spill_at_per_s == 54 && output.pool_capacity["t-critical"].overflow_target == "pool-overflow-critical"
    error_message = "Spill point is 90% of pool TPS; the target is the zone's overflow pool."
  }

  assert {
    condition     = azapi_resource.overflow_pool["critical"].name == "pool-overflow-critical" && length(azapi_resource.overflow_pool["critical"].body.properties.pool.services) == 2
    error_message = "The critical overflow pool must hold its own two members."
  }
}

run "threshold_out_of_range_rejected" {
  command = plan

  variables {
    overflow_threshold_pct = 120
  }

  expect_failures = [var.overflow_threshold_pct]
}
