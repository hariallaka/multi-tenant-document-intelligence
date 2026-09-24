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

  environment   = var.environment
  location      = var.location
  name_prefix   = var.name_prefix
  unique_suffix = var.unique_suffix

  # Existing APIM Standard v2 / Premium v2 instance (not managed here).
  apim_name                = var.apim_name
  allowed_apim_skus        = var.allowed_apim_skus
  apim_identity_id         = var.apim_identity_id
  apim_resource_group_name = var.apim_resource_group_name
  apim_vnet_id             = var.apim_vnet_id
  require_private_apim     = var.require_private_apim

  existing_pe_subnet_id         = var.existing_pe_subnet_id
  vnet_address_space            = var.vnet_address_space
  pe_subnet_prefix              = var.pe_subnet_prefix
  create_reverse_peering        = var.create_reverse_peering
  dns_servers                   = var.dns_servers
  existing_private_dns_zone_ids = var.existing_private_dns_zone_ids
  redis_sku_name                = var.redis_sku_name
  redis_capacity                = var.redis_capacity
  redis_zones                   = var.redis_zones
  redis_apim_key                = var.redis_apim_key
  redis_key_version             = var.redis_key_version
  redis_entra_access            = var.redis_entra_access
  tags                          = var.tags
}

module "di_gateway" {
  source = "../../modules/di-gateway"

  di_cells    = var.di_cells
  di_overflow = var.di_overflow
  di_tenants  = var.di_tenants

  overflow_threshold_pct    = var.overflow_threshold_pct
  overflow_tenant_share_pct = var.overflow_tenant_share_pct

  location                 = module.platform.location
  rg_name                  = module.platform.resource_group_name
  pe_subnet_id             = module.platform.pe_subnet_id
  dns_zone_id              = module.platform.cognitiveservices_dns_zone_id
  apim_id                  = module.platform.apim_id
  apim_name                = module.platform.apim_name
  apim_resource_group_name = module.platform.apim_resource_group_name
  apim_principal_id        = module.platform.apim_principal_id
  apim_identity_client_id  = module.platform.apim_identity_client_id
  # Static (from tfvars), so count/for_each never depend on the APIM lookup.
  use_user_assigned_identity = var.apim_identity_id != null
  signing_secret_id          = module.platform.signing_secret_id
  signing_secret_prev_id     = module.platform.signing_secret_prev_id

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
  description = "Gateway host of the existing APIM instance."
  value       = module.platform.apim_gateway_host
}

output "redis_name" {
  description = "Azure Cache for Redis holding the overflow counters."
  value       = module.platform.redis_name
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

output "pool_capacity" {
  description = "Pool capacity, spill point and overflow target."
  value       = module.di_gateway.pool_capacity
}
