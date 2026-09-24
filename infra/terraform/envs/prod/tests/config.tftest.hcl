# Plans this environment's committed tfvars against mocked providers, so the
# DeployEz config is checked against every guardrail without Azure access.
# The existing APIM instance is mocked as a private Premium v2 instance.
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

mock_provider "azapi" {
  mock_data "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      output = {
        sku           = "PremiumV2"
        public_access = "Disabled"
        vnet_type     = "Internal"
        public_ip_id  = null
        gateway_url   = "https://apim.azure-api.net"
        identity_type = "SystemAssigned"
        principal_id  = "00000000-0000-0000-0000-000000000002"
      }
    }
  }
}

run "config_passes_guardrails" {
  command = plan

  assert {
    condition     = output.regional_di_count == 5
    error_message = "Expected 5 DI accounts: 2 general + 3 critical."
  }

  assert {
    condition     = length([for k, a in output.di_accounts : k if a.zone == "general" && a.cell == "prod-general"]) == 2
    error_message = "The general pool must have 2 DI accounts."
  }

  assert {
    condition     = length([for k, a in output.di_accounts : k if a.zone == "critical" && a.cell == "prod-critical"]) == 3
    error_message = "The critical pool must have 3 DI accounts."
  }

  assert {
    condition     = alltrue([for t in jsondecode(output.tenant_cell_map) : t.overflow == false])
    error_message = "No overflow pools are configured, so no tenant may be overflow-enabled."
  }
}
