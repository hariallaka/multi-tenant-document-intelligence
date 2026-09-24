# Guardrails on the existing APIM instance. Providers are mocked.
#   cd infra/terraform/modules/platform && terraform init -backend=false && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000001"
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

variables {
  environment              = "nonprod"
  location                 = "australiaeast"
  name_prefix              = "daas-di-t"
  unique_suffix            = "t1"
  apim_name                = "apim"
  apim_resource_group_name = "rg-apim"
  apim_vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim"
  vnet_address_space       = ["10.0.0.0/26"]
  pe_subnet_prefix         = "10.0.0.0/27"
}

run "private_premium_v2_passes" {
  command = plan

  assert {
    condition     = output.apim_gateway_host == "apim.azure-api.net"
    error_message = "Gateway host should come from the existing instance."
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.spoke_to_apim) == 1 && length(azurerm_virtual_network_peering.apim_to_spoke) == 1
    error_message = "A created spoke must be peered both ways with the APIM VNet."
  }

  assert {
    condition     = length([for k, l in azurerm_private_dns_zone_virtual_network_link.this : k if endswith(k, "-apim") && l.virtual_network_id == var.apim_vnet_id]) == 3
    error_message = "Every created private DNS zone must be linked to the APIM VNet."
  }
}

run "existing_pe_subnet_skips_spoke" {
  command = plan

  variables {
    existing_pe_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-pe"
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_virtual_network_peering.spoke_to_apim) == 0
    error_message = "No spoke or peering when an existing PE subnet is given."
  }

  assert {
    condition     = output.pe_subnet_id == var.existing_pe_subnet_id
    error_message = "Private endpoints must use the existing subnet."
  }
}

run "public_apim_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      output = {
        sku           = "PremiumV2"
        public_access = "Enabled"
        vnet_type     = "External"
        public_ip_id  = null
        gateway_url   = "https://apim.azure-api.net"
        identity_type = "SystemAssigned"
        principal_id  = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "public_ip_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      output = {
        sku           = "PremiumV2"
        public_access = "Disabled"
        vnet_type     = "Internal"
        public_ip_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip"
        gateway_url   = "https://apim.azure-api.net"
        identity_type = "SystemAssigned"
        principal_id  = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "classic_premium_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      output = {
        sku           = "Premium"
        public_access = "Disabled"
        vnet_type     = "Internal"
        public_ip_id  = null
        gateway_url   = "https://apim.azure-api.net"
        identity_type = "SystemAssigned"
        principal_id  = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "missing_managed_identity_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      output = {
        sku           = "PremiumV2"
        public_access = "Disabled"
        vnet_type     = "Internal"
        public_ip_id  = null
        gateway_url   = "https://apim.azure-api.net"
        identity_type = "None"
        principal_id  = null
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}
