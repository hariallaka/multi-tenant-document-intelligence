# ---------------------------------------------------------------------------
# DeployEz config layer: cells, overflow pools and tenants (see di.auto.tfvars)
# ---------------------------------------------------------------------------

variable "di_cells" {
  description = "Home cells. Each cell is one APIM pool of DI resources in one workload zone (general, critical, confidential, restricted). Member keys are stable backend keys (e.g. di-prod-gen-1)."
  type = map(object({
    zone    = string
    members = map(object({ weight = number }))
  }))

  validation {
    condition     = alltrue([for c in var.di_cells : contains(local.zones, c.zone)])
    error_message = "Cell zone must be one of: general, critical, confidential, restricted."
  }

  validation {
    condition     = alltrue(flatten([for c in var.di_cells : [for m in c.members : m.weight >= 1 && m.weight <= 100 && floor(m.weight) == m.weight]]))
    error_message = "Pool member weight must be a whole number between 1 and 100."
  }

  validation {
    condition     = alltrue([for c in var.di_cells : length(c.members) >= 1])
    error_message = "Every cell needs at least one member."
  }
}

variable "di_overflow" {
  description = "Optional overflow pools, keyed by zone. Each zone's pool is its own (never shared); Restricted never gets one."
  type        = map(map(object({ weight = number })))
  default     = {}

  validation {
    condition     = alltrue([for z in keys(var.di_overflow) : contains(local.zones, z) && z != "restricted"])
    error_message = "Overflow pools may only be defined for the general, critical and confidential zones."
  }

  validation {
    condition     = alltrue(flatten([for z in var.di_overflow : [for m in z : m.weight >= 1 && m.weight <= 100 && floor(m.weight) == m.weight]]))
    error_message = "Pool member weight must be a whole number between 1 and 100."
  }
}

variable "di_tenants" {
  description = "Tenant client ID (Entra app ID) => placement. Zone is derived from the cell."
  type = map(object({
    cell        = string
    tier        = string
    overflow    = bool
    modelPrefix = string
  }))

  validation {
    condition     = alltrue([for k, _ in var.di_tenants : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", k))])
    error_message = "di_tenants keys must be Entra client IDs (GUIDs)."
  }

  validation {
    condition     = alltrue([for t in var.di_tenants : contains(["standard", "gold"], t.tier)])
    error_message = "Tenant tier must be standard or gold (the tiers the Analyze policy implements)."
  }

  validation {
    condition     = alltrue([for t in var.di_tenants : !startswith(t.modelPrefix, "prebuilt-")])
    error_message = "modelPrefix must not start with prebuilt-."
  }
}

# ---------------------------------------------------------------------------
# Landing zone inputs
# ---------------------------------------------------------------------------

variable "location" {
  description = "Azure region for the DI accounts and private endpoints."
  type        = string
}

variable "rg_name" {
  description = "Resource group for DI accounts and private endpoints."
  type        = string
}

variable "apim_resource_group_name" {
  description = "Resource group of the APIM instance. Null means the same as rg_name."
  type        = string
  default     = null
}

variable "pe_subnet_id" {
  description = "Subnet for DI private endpoints."
  type        = string
}

variable "dns_zone_id" {
  description = "Private DNS zone ID for privatelink.cognitiveservices.azure.com."
  type        = string
}

variable "apim_id" {
  description = "Resource ID of the APIM instance (Premium v2, private)."
  type        = string
}

variable "apim_name" {
  description = "Name of the APIM instance."
  type        = string
}

variable "apim_principal_id" {
  description = "Object ID of the APIM system-assigned managed identity (granted Cognitive Services User on every DI account)."
  type        = string
}

variable "signing_secret_id" {
  description = "Versionless Key Vault secret ID for result-signing-key (base64)."
  type        = string
}

variable "signing_secret_prev_id" {
  description = "Versionless Key Vault secret ID for result-signing-key-prev (base64)."
  type        = string
}

# ---------------------------------------------------------------------------
# Gateway identity named values
# ---------------------------------------------------------------------------

variable "entra_tenant_id" {
  description = "Entra directory ID used by validate-azure-ad-token."
  type        = string
}

variable "gateway_audience" {
  description = "App ID URI of the gateway app registration (di-gateway-audience)."
  type        = string
}

variable "dispatcher_app_id" {
  description = "Client ID of the batch dispatcher workload identity, the only caller allowed to set x-daas-tenant."
  type        = string
}

variable "gateway_host" {
  description = "Host tenants call, used to build result URLs (e.g. di.internal.example)."
  type        = string
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

variable "di_name_suffix" {
  description = "Suffix appended to DI account names and custom subdomains to make them globally unique. Backend keys stay the bare member names."
  type        = string
  default     = ""
}

variable "dedicated_di_count" {
  description = "DI accounts in this region that are managed outside this module (Dedicated / promoted tenants). Counted against the regional limit."
  type        = number
  default     = 0
}

variable "regional_di_limit" {
  description = "Maximum DI (S0) resources per region. Not adjustable by Microsoft."
  type        = number
  default     = 20
}

variable "max_pool_members" {
  description = "Maximum backends per APIM pool."
  type        = number
  default     = 30
}

variable "di_role_definition_name" {
  description = "Role granted to the APIM identity on each DI account. Replace with a custom analyze-only role when one exists."
  type        = string
  default     = "Cognitive Services User"
}

variable "enable_diagnostics" {
  description = "Send DI resource logs to log_analytics_workspace_id and log per-tenant API diagnostics to apim_logger_id. A static flag, because the IDs are often unknown until apply."
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Workspace for DI resource logs and metrics. Required when enable_diagnostics is true."
  type        = string
  default     = null
}

variable "apim_logger_id" {
  description = "APIM logger for per-tenant API diagnostics (e.g. <apim_id>/loggers/azuremonitor). Required when enable_diagnostics is true."
  type        = string
  default     = null
}

variable "policy_dir" {
  description = "Directory containing api-di-v1.xml, op-analyze.xml and op-result.xml."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to DI accounts and private endpoints."
  type        = map(string)
  default     = {}
}
