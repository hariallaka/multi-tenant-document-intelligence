# Plans this environment's committed tfvars against mocked providers, so the
# DeployEz config is checked against every guardrail without Azure access.
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
      object_id = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "azurerm_api_management" {
    defaults = {
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim"
      private_ip_addresses = ["10.0.0.4"]
      identity             = [{ type = "SystemAssigned", principal_id = "00000000-0000-0000-0000-000000000002", tenant_id = "00000000-0000-0000-0000-000000000000", identity_ids = [] }]
    }
  }

  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
      vault_uri = "https://kv.vault.azure.net/"
    }
  }
}

mock_provider "azapi" {}

run "config_passes_guardrails" {
  command = plan

  assert {
    condition     = output.regional_di_count <= 20
    error_message = "Regional DI budget exceeded."
  }
}
