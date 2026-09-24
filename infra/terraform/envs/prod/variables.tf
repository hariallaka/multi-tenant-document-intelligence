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

variable "apim_name" {
  description = "Existing APIM Premium v2 instance."
  type        = string
}

variable "apim_resource_group_name" {
  description = "Resource group of the existing APIM instance."
  type        = string
}

variable "apim_vnet_id" {
  description = "VNet the APIM instance is injected into."
  type        = string
}

variable "require_private_apim" {
  description = "Fail the plan if the APIM instance is reachable from the internet."
  type        = bool
  default     = true
}

variable "existing_pe_subnet_id" {
  description = "Existing PE subnet reachable from APIM, or null to create a peered spoke."
  type        = string
  default     = null
}

variable "vnet_address_space" {
  description = "Spoke VNet address space (when existing_pe_subnet_id is null)."
  type        = list(string)
  default     = []
}

variable "pe_subnet_prefix" {
  description = "Spoke PE subnet prefix (when existing_pe_subnet_id is null)."
  type        = string
  default     = null
}

variable "create_reverse_peering" {
  description = "Create the APIM VNet -> spoke peering as well."
  type        = bool
  default     = true
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
