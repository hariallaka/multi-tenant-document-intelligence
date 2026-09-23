variable "subscription_id" {
  description = "Target subscription."
  type        = string
}

variable "environment" {
  description = "nonprod or prod."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "unique_suffix" {
  description = "Suffix for globally unique names."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

variable "vnet_address_space" {
  description = "Spoke VNet address space."
  type        = list(string)
}

variable "apim_subnet_prefix" {
  description = "APIM subnet prefix."
  type        = string
}

variable "pe_subnet_prefix" {
  description = "Private endpoint subnet prefix."
  type        = string
}

variable "hub_vnet_id" {
  description = "Hub VNet to peer with, or null."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Custom DNS servers for the spoke."
  type        = list(string)
  default     = []
}

variable "existing_private_dns_zone_ids" {
  description = "Hub-owned private DNS zone IDs (cognitiveservices, vaultcore, redis)."
  type        = map(string)
  default     = {}
}

variable "create_apim_dns_zone" {
  description = "Create an azure-api.net private zone for the internal gateway."
  type        = bool
  default     = true
}

variable "apim_sku_name" {
  description = "APIM SKU (Premium_<units>)."
  type        = string
  default     = "Premium_1"
}

variable "apim_zones" {
  description = "Availability zones for APIM."
  type        = list(string)
  default     = []
}

variable "publisher_name" {
  description = "APIM publisher name."
  type        = string
}

variable "publisher_email" {
  description = "APIM publisher email."
  type        = string
}

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU."
  type        = string
  default     = "Balanced_B1"
}

variable "entra_tenant_id" {
  description = "Entra directory ID."
  type        = string
}

variable "gateway_audience" {
  description = "App ID URI of the gateway app registration."
  type        = string
}

variable "dispatcher_app_id" {
  description = "Client ID of the dispatcher workload identity."
  type        = string
}

variable "gateway_host" {
  description = "Host tenants call. Null uses <apim>.azure-api.net."
  type        = string
  default     = null
}

variable "di_name_suffix" {
  description = "Suffix for globally unique DI subdomains."
  type        = string
  default     = ""
}

variable "dedicated_di_count" {
  description = "Dedicated DI accounts in this region managed elsewhere."
  type        = number
  default     = 0
}

variable "di_cells" {
  description = "Home cells (DeployEz config)."
  type = map(object({
    zone    = string
    members = map(object({ weight = number }))
  }))
}

variable "di_overflow" {
  description = "Overflow pools by zone (DeployEz config)."
  type        = map(map(object({ weight = number })))
  default     = {}
}

variable "di_tenants" {
  description = "Tenant placement (DeployEz config)."
  type = map(object({
    cell        = string
    tier        = string
    overflow    = bool
    modelPrefix = string
  }))
}
