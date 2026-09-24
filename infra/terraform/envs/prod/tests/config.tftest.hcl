# Plans this environment's committed tfvars against mocked providers, so the
# DeployEz config is checked against every guardrail without Azure access.
# The existing APIM instance is mocked as a private Standard v2 instance
# (inbound private endpoint, public access disabled, outbound VNet integration).
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
      vault_uri = "https://kv.vault.azure.net/"
    }
  }
}

# Real azapi provider with dummy credentials: in a plan it validates bodies against
# the embedded ARM schemas without calling Azure. Mock providers can't host the
# ephemeral listKeys action. The APIM lookup is replaced by override_data below.
provider "azapi" {
  subscription_id            = "00000000-0000-0000-0000-000000000000"
  tenant_id                  = "00000000-0000-0000-0000-000000000000"
  client_id                  = "00000000-0000-0000-0000-000000000000"
  client_secret              = "not-a-secret"
  skip_provider_registration = true
}

override_data {
  target = module.platform.data.azapi_resource.apim
  values = {
    id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
    location = "Australia East"
    output = {
      sku            = "StandardV2"
      public_access  = "Disabled"
      vnet_type      = "External"
      vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-prod/providers/Microsoft.Network/virtualNetworks/vnet-apim-prod/subnets/snet-apim-integration"
      public_ip_id   = null
      gateway_url    = "https://apim.azure-api.net"
      identity_type  = "SystemAssigned"
      principal_id   = "00000000-0000-0000-0000-000000000002"
    }
  }
}

run "config_passes_guardrails" {
  command = plan

  assert {
    condition     = output.regional_di_count == 7
    error_message = "Expected 7 DI accounts: 2 general + 3 critical + 1 general overflow + 1 critical overflow."
  }

  assert {
    condition     = length([for k, a in output.di_accounts : k if a.cell == "prod-general"]) == 2 && length([for k, a in output.di_accounts : k if a.cell == "prod-critical"]) == 3
    error_message = "The general pool must have 2 DI accounts and the critical pool 3."
  }

  assert {
    condition     = length([for k, a in output.di_accounts : k if a.cell == "overflow-general"]) == 1 && length([for k, a in output.di_accounts : k if a.cell == "overflow-critical"]) == 1
    error_message = "Each zone needs its own overflow pool."
  }

  assert {
    condition     = output.pool_capacity["prod-general"].spill_at_per_s == 27 && output.pool_capacity["prod-general"].overflow_target == "pool-overflow-general"
    error_message = "General pool must spill to pool-overflow-general at 27 calls/s (90% of 30)."
  }

  assert {
    condition     = output.pool_capacity["prod-critical"].spill_at_per_s == 40 && output.pool_capacity["prod-critical"].overflow_target == "pool-overflow-critical"
    error_message = "Critical pool must spill to pool-overflow-critical at 40 calls/s (90% of 45)."
  }

  assert {
    condition     = alltrue([for t in jsondecode(output.tenant_cell_map) : t.overflow])
    error_message = "Every tenant is expected to be overflow-enabled."
  }
}
