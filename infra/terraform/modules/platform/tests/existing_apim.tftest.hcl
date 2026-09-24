# Guardrails on the existing APIM instance. Providers are mocked; the default mock
# is a private Standard v2 instance (inbound private endpoint, public access disabled,
# outbound VNet integration into apim_vnet_id).
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
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Disabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
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

run "private_standard_v2_passes" {
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

run "injected_premium_v2_passes" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "PremiumV2"
        public_access  = "Enabled"
        vnet_type      = "Internal"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
      }
    }
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

run "standard_v2_only_allowed_when_listed" {
  command = plan

  variables {
    allowed_apim_skus = ["PremiumV2"]
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "apim_in_other_region_rejected" {
  command = plan

  variables {
    location = "australiasoutheast"
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "redis_waits_for_dns_and_uses_private_endpoint" {
  command = plan

  assert {
    condition     = azurerm_redis_cache.this.public_network_access_enabled == false && azurerm_private_endpoint.redis.private_service_connection[0].subresource_names[0] == "redisCache"
    error_message = "Redis must be private and reached through its private endpoint."
  }

  assert {
    condition     = azurerm_redis_cache.this.sku_name == "Standard" && azurerm_redis_cache.this.family == "C" && azurerm_redis_cache.this.non_ssl_port_enabled == false && azurerm_redis_cache.this.minimum_tls_version == "1.2"
    error_message = "Azure Cache for Redis must be Standard C by default, TLS 1.2 only, with the non-TLS port closed."
  }

  assert {
    condition     = azurerm_private_dns_zone.this["redis"].name == "privatelink.redis.cache.windows.net"
    error_message = "Azure Cache for Redis resolves through privatelink.redis.cache.windows.net."
  }

  assert {
    condition     = contains(keys(azurerm_private_dns_zone_virtual_network_link.this), "redis-apim")
    error_message = "The Redis private DNS zone must be linked to the APIM VNet."
  }
}

run "premium_redis_gets_zones" {
  command = plan

  variables {
    redis_sku_name = "Premium"
    redis_zones    = ["1", "2"]
  }

  assert {
    condition     = azurerm_redis_cache.this.family == "P" && length(azurerm_redis_cache.this.zones) == 2
    error_message = "A Premium cache uses family P and the requested zones."
  }
}

run "basic_redis_rejected" {
  command = plan

  variables {
    redis_sku_name = "Basic"
  }

  expect_failures = [var.redis_sku_name]
}

run "public_access_rejected" {
  command = plan

  # Standard v2 with its public gateway still enabled.

  override_data {
    target = data.azapi_resource.apim
    values = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Enabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
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
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Disabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip"
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "no_vnet_integration_rejected" {
  command = plan

  # Private inbound, but no outbound VNet integration: APIM could not reach the DI private endpoints.

  override_data {
    target = data.azapi_resource.apim
    values = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Disabled"
        vnet_type      = "None"
        vnet_subnet_id = null
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "vnet_integration_into_other_vnet_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Disabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-other/subnets/snet"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}

run "basic_v2_rejected" {
  command = plan

  override_data {
    target = data.azapi_resource.apim
    values = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "BasicV2"
        public_access  = "Disabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
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
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "Premium"
        public_access  = "Disabled"
        vnet_type      = "Internal"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "SystemAssigned"
        principal_id   = "00000000-0000-0000-0000-000000000002"
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
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim"
      location = "Australia East"
      output = {
        sku            = "StandardV2"
        public_access  = "Disabled"
        vnet_type      = "External"
        vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-apim/subnets/snet-apim-integration"
        public_ip_id   = null
        gateway_url    = "https://apim.azure-api.net"
        identity_type  = "None"
        principal_id   = null
      }
    }
  }

  expect_failures = [terraform_data.apim_guardrails]
}
