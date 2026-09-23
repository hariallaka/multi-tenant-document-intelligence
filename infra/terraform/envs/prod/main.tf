terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.6.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "2.12.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

# The pipeline authenticates with Workload Identity Federation (ARM_USE_OIDC,
# ARM_CLIENT_ID, ARM_TENANT_ID, ARM_OIDC_TOKEN set by the service connection).
provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}

module "platform" {
  source = "../../modules/platform"

  environment                   = var.environment
  location                      = var.location
  name_prefix                   = var.name_prefix
  unique_suffix                 = var.unique_suffix
  vnet_address_space            = var.vnet_address_space
  apim_subnet_prefix            = var.apim_subnet_prefix
  pe_subnet_prefix              = var.pe_subnet_prefix
  hub_vnet_id                   = var.hub_vnet_id
  dns_servers                   = var.dns_servers
  existing_private_dns_zone_ids = var.existing_private_dns_zone_ids
  create_apim_dns_zone          = var.create_apim_dns_zone
  apim_sku_name                 = var.apim_sku_name
  apim_zones                    = var.apim_zones
  publisher_name                = var.publisher_name
  publisher_email               = var.publisher_email
  redis_sku_name                = var.redis_sku_name
  tags                          = var.tags
}

module "di_gateway" {
  source = "../../modules/di-gateway"

  di_cells    = var.di_cells
  di_overflow = var.di_overflow
  di_tenants  = var.di_tenants

  location               = module.platform.location
  rg_name                = module.platform.resource_group_name
  pe_subnet_id           = module.platform.pe_subnet_id
  dns_zone_id            = module.platform.cognitiveservices_dns_zone_id
  apim_id                = module.platform.apim_id
  apim_name              = module.platform.apim_name
  apim_principal_id      = module.platform.apim_principal_id
  signing_secret_id      = module.platform.signing_secret_id
  signing_secret_prev_id = module.platform.signing_secret_prev_id

  entra_tenant_id   = var.entra_tenant_id
  gateway_audience  = var.gateway_audience
  dispatcher_app_id = var.dispatcher_app_id
  gateway_host      = coalesce(var.gateway_host, module.platform.apim_gateway_host)

  di_name_suffix             = var.di_name_suffix
  dedicated_di_count         = var.dedicated_di_count
  enable_diagnostics         = true
  log_analytics_workspace_id = module.platform.log_analytics_workspace_id
  apim_logger_id             = module.platform.apim_logger_id
  tags                       = merge(var.tags, { environment = var.environment })
}

output "apim_gateway_host" {
  description = "Internal gateway host."
  value       = module.platform.apim_gateway_host
}

output "apim_private_ip_addresses" {
  description = "Gateway private IPs."
  value       = module.platform.apim_private_ip_addresses
}

output "key_vault_name" {
  description = "Key Vault holding the result signing keys."
  value       = module.platform.key_vault_name
}

output "di_accounts" {
  description = "DI accounts by backend key."
  value       = module.di_gateway.di_accounts
}

output "tenant_cell_map" {
  description = "Rendered tenant-cell-map."
  value       = module.di_gateway.tenant_cell_map
}

output "regional_di_count" {
  description = "DI accounts counted against the regional limit."
  value       = module.di_gateway.regional_di_count
}
