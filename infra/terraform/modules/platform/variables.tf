variable "environment" {
  description = "Environment name (nonprod, prod)."
  type        = string

  validation {
    condition     = contains(["nonprod", "prod"], var.environment)
    error_message = "environment must be nonprod or prod."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names, e.g. daas-di-prod."
  type        = string
}

variable "unique_suffix" {
  description = "Short lowercase alphanumeric suffix for globally unique names (APIM, Key Vault, Redis)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.unique_suffix))
    error_message = "unique_suffix must be 2-6 lowercase alphanumeric characters."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space of the gateway spoke VNet."
  type        = list(string)
}

variable "apim_subnet_prefix" {
  description = "Prefix for the APIM subnet (/27 or larger for Premium VNet injection)."
  type        = string
}

variable "pe_subnet_prefix" {
  description = "Prefix for the private endpoint subnet (DI, Key Vault, Redis)."
  type        = string
}

variable "hub_vnet_id" {
  description = "Hub VNet to peer with (spoke side only; the hub side is owned by the landing zone). Null skips peering."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Custom DNS servers for the spoke (e.g. hub DNS resolver). Empty uses Azure DNS."
  type        = list(string)
  default     = []
}

variable "existing_private_dns_zone_ids" {
  description = "Private DNS zone IDs owned by the hub, keyed by cognitiveservices, vaultcore, redis. Zones not listed are created here and linked to the spoke."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.existing_private_dns_zone_ids) : contains(["cognitiveservices", "vaultcore", "redis"], k)])
    error_message = "existing_private_dns_zone_ids keys must be cognitiveservices, vaultcore or redis."
  }
}

variable "create_apim_dns_zone" {
  description = "Create an azure-api.net private zone with records for the internal APIM gateway. Disable when the hub resolves APIM."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# APIM
# ---------------------------------------------------------------------------

variable "apim_sku_name" {
  description = "APIM SKU. Premium_<units> for classic VNet injection (internal mode)."
  type        = string
  default     = "Premium_1"

  validation {
    condition     = can(regex("^Premium_[0-9]+$", var.apim_sku_name))
    error_message = "The design requires internal VNet injection, which needs a Premium_<units> SKU."
  }
}

variable "apim_zones" {
  description = "Availability zones for APIM units. Empty for none."
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

# ---------------------------------------------------------------------------
# Redis (APIM external cache for overflow counters)
# ---------------------------------------------------------------------------

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU."
  type        = string
  default     = "Balanced_B1"
}

# ---------------------------------------------------------------------------
# Monitoring and Key Vault
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 90
}

variable "bootstrap_signing_keys" {
  description = "Create the initial result-signing keys. Values are ephemeral and write-only, so they never enter state. Rotation is done by scripts/rotate-signing-key.sh."
  type        = bool
  default     = true
}
