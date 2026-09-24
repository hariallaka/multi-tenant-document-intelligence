variable "environment" {
  description = "Environment name (nonprod, prod)."
  type        = string

  validation {
    condition     = contains(["nonprod", "prod"], var.environment)
    error_message = "environment must be nonprod or prod."
  }
}

variable "location" {
  description = "Azure region for the DI accounts and supporting resources. Must be the APIM instance's region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names, e.g. daas-di-prod."
  type        = string
}

variable "unique_suffix" {
  description = "Short lowercase alphanumeric suffix for globally unique names (Key Vault, Redis)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.unique_suffix))
    error_message = "unique_suffix must be 2-6 lowercase alphanumeric characters."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Existing APIM instance (Standard v2 or Premium v2)
# ---------------------------------------------------------------------------

variable "apim_name" {
  description = "Name of the existing APIM instance (Standard v2 or Premium v2)."
  type        = string
}

variable "apim_resource_group_name" {
  description = "Resource group of the existing APIM instance."
  type        = string
}

variable "allowed_apim_skus" {
  description = "APIM tiers the gateway may run on. Both v2 tiers support backend pools, circuit breakers, VNet integration and inbound private endpoints."
  type        = list(string)
  default     = ["StandardV2", "PremiumV2"]

  validation {
    condition     = length(var.allowed_apim_skus) > 0 && alltrue([for s in var.allowed_apim_skus : contains(["StandardV2", "PremiumV2"], s)])
    error_message = "allowed_apim_skus may only contain StandardV2 and PremiumV2."
  }
}

variable "apim_identity_id" {
  description = "Resource ID of a user-assigned managed identity attached to APIM. APIM then uses it (not its system-assigned identity) for DI and Key Vault, and the role assignments go to it. Null uses the system-assigned identity."
  type        = string
  default     = null

  validation {
    condition     = var.apim_identity_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.apim_identity_id))
    error_message = "apim_identity_id must be a user-assigned managed identity resource ID (/subscriptions/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>)."
  }
}

variable "apim_vnet_id" {
  description = "VNet APIM sends outbound traffic through: its VNet integration VNet (Standard v2) or its integration/injection VNet (Premium v2). Private DNS zones are linked to it so APIM resolves the DI private endpoints."
  type        = string
}

variable "require_private_apim" {
  description = "Fail the plan unless the APIM instance is private (public network access disabled with an inbound private endpoint, or Internal VNet injection on Premium v2) and has no public IP."
  type        = bool
  default     = true
}

variable "enable_apim_diagnostics" {
  description = "Add a diagnostic setting on the APIM instance that sends gateway logs to this module's Log Analytics workspace."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Network for the private endpoints
# ---------------------------------------------------------------------------

variable "existing_pe_subnet_id" {
  description = "Existing subnet for the DI, Key Vault and Redis private endpoints, reachable from APIM. Null creates a spoke VNet with a PE subnet peered to apim_vnet_id."
  type        = string
  default     = null
}

variable "vnet_address_space" {
  description = "Address space of the spoke VNet created when existing_pe_subnet_id is null."
  type        = list(string)
  default     = []
}

variable "pe_subnet_prefix" {
  description = "Prefix of the PE subnet created when existing_pe_subnet_id is null."
  type        = string
  default     = null
}

variable "create_reverse_peering" {
  description = "Also create the APIM VNet -> spoke peering (needs Network Contributor on the APIM VNet). Disable when the network team owns that side."
  type        = bool
  default     = true
}

variable "dns_servers" {
  description = "Custom DNS servers for the spoke (e.g. hub DNS resolver). Empty uses Azure DNS."
  type        = list(string)
  default     = []
}

variable "existing_private_dns_zone_ids" {
  description = "Private DNS zone IDs owned by the hub, keyed by cognitiveservices, vaultcore, redis. Zones not listed are created here and linked to the APIM VNet (and the spoke, if created)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.existing_private_dns_zone_ids) : contains(["cognitiveservices", "vaultcore", "redis"], k)])
    error_message = "existing_private_dns_zone_ids keys must be cognitiveservices, vaultcore or redis."
  }
}

# ---------------------------------------------------------------------------
# Redis (APIM external cache for overflow counters)
# ---------------------------------------------------------------------------

variable "redis_sku_name" {
  description = "Azure Cache for Redis tier. Standard (replicated, SLA) or Premium (adds zone redundancy). Basic has no replica or SLA and is not allowed."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.redis_sku_name)
    error_message = "redis_sku_name must be Standard or Premium."
  }
}

variable "redis_capacity" {
  description = "Cache size within the tier: C0-C6 for Standard, P1-P5 for Premium. The counters need very little memory; size for connections and throughput."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_capacity >= 0 && var.redis_capacity <= 6 && floor(var.redis_capacity) == var.redis_capacity
    error_message = "redis_capacity must be a whole number between 0 and 6."
  }
}

variable "redis_zones" {
  description = "Availability zones for a Premium cache. Ignored for Standard."
  type        = list(string)
  default     = []
}

variable "redis_apim_key" {
  description = "Which Redis access key APIM's connection string uses. Switch to rotate keys without downtime (see README)."
  type        = string
  default     = "primary"

  validation {
    condition     = contains(["primary", "secondary"], var.redis_apim_key)
    error_message = "redis_apim_key must be primary or secondary."
  }
}

variable "redis_key_version" {
  description = "Bump after regenerating the key APIM uses, so Terraform re-sends the connection string. The key itself is never stored in state."
  type        = string
  default     = "1"
}

variable "redis_entra_access" {
  description = "Entra ID principals granted data access to Redis (alias => { object_id, access_policy }). APIM is not listed: it uses the access key."
  type = map(object({
    object_id     = string
    access_policy = optional(string, "Data Contributor")
  }))
  default = {}

  validation {
    condition     = alltrue([for p in var.redis_entra_access : contains(["Data Owner", "Data Contributor", "Data Reader"], p.access_policy)])
    error_message = "access_policy must be Data Owner, Data Contributor or Data Reader."
  }
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
