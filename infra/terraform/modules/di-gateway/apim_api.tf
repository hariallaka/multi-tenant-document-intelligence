resource "azurerm_api_management_api" "di_v1" {
  name                  = "di-v1"
  api_management_name   = var.apim_name
  resource_group_name   = local.apim_rg_name
  revision              = "1"
  display_name          = "Document Intelligence v1"
  description           = "Shared Document Intelligence gateway. Tenants authenticate with Entra tokens; the gateway routes to the tenant's home cell."
  path                  = "di/v1"
  protocols             = ["https"]
  subscription_required = false # tenant identity comes from the Entra token, not a subscription key
}

resource "azurerm_api_management_api_operation" "analyze" {
  operation_id        = "analyze"
  api_name            = azurerm_api_management_api.di_v1.name
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = "Analyze document"
  method              = "POST"
  url_template        = "/documentModels/{modelId}/analyze"
  description         = "Routes to the tenant's pool; above the overflow threshold, to the zone overflow pool. Returns 202 with a signed result URL."

  template_parameter {
    name     = "modelId"
    type     = "string"
    required = true
  }

  response {
    status_code = 202
    description = "Accepted. Operation-Location holds a signed, tenant-bound gateway result URL."
  }

  response {
    status_code = 429
    description = "Tenant limit reached or cell exhausted. Honour Retry-After."
  }
}

resource "azurerm_api_management_api_operation" "result" {
  operation_id        = "result"
  api_name            = azurerm_api_management_api.di_v1.name
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = "Get analyze result"
  method              = "GET"
  url_template        = "/results/{ticket}"
  description         = "Verifies the signed ticket and forwards to the DI resource that accepted the job. No pool, no retry."

  template_parameter {
    name     = "ticket"
    type     = "string"
    required = true
  }

  response {
    status_code = 200
    description = "Analyze result (status running, succeeded or failed)."
  }

  response {
    status_code = 404
    description = "Unknown, tampered or other-tenant ticket."
  }
}

# Policies reference named values ({{...}}) that must exist before APIM accepts
# the XML, and backend IDs that set-backend-service resolves at runtime.
locals {
  # With a user-assigned identity, APIM must be told which identity to request the
  # DI token as. The policy file keeps the system-assigned form; Terraform adds
  # client-id (read from a named value) when use_user_assigned_identity is set.
  msi_tag_system = "<authentication-managed-identity resource=\"https://cognitiveservices.azure.com\" />"
  msi_tag_user   = "<authentication-managed-identity resource=\"https://cognitiveservices.azure.com\" client-id=\"{{apim-identity-client-id}}\" />"
  api_policy_raw = file("${local.policy_dir}/api-di-v1.xml")
  api_policy_xml = var.use_user_assigned_identity ? replace(local.api_policy_raw, local.msi_tag_system, local.msi_tag_user) : local.api_policy_raw
}

resource "azurerm_api_management_api_policy" "di_v1" {
  api_name            = azurerm_api_management_api.di_v1.name
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  xml_content         = local.api_policy_xml

  lifecycle {
    precondition {
      condition     = strcontains(local.api_policy_raw, local.msi_tag_system)
      error_message = "api-di-v1.xml must contain exactly ${local.msi_tag_system}; the user-assigned identity switch rewrites that tag."
    }
  }

  depends_on = [
    azurerm_api_management_named_value.tenant_cell_map,
    azurerm_api_management_named_value.plain,
    azurerm_api_management_named_value.identity_client_id,
  ]
}

resource "azurerm_api_management_api_operation_policy" "analyze" {
  api_name            = azurerm_api_management_api.di_v1.name
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  operation_id        = azurerm_api_management_api_operation.analyze.operation_id
  xml_content         = file("${local.policy_dir}/op-analyze.xml")

  depends_on = [
    azurerm_api_management_api_policy.di_v1,
    azurerm_api_management_named_value.di_host_map,
    azurerm_api_management_named_value.pool_capacity_map,
    azurerm_api_management_named_value.plain,
    azurerm_api_management_named_value.signing,
    azapi_resource.cell_pool,
    azapi_resource.overflow_pool,
  ]
}

resource "azurerm_api_management_api_operation_policy" "result" {
  api_name            = azurerm_api_management_api.di_v1.name
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  operation_id        = azurerm_api_management_api_operation.result.operation_id
  xml_content         = file("${local.policy_dir}/op-result.xml")

  depends_on = [
    azurerm_api_management_api_policy.di_v1,
    azurerm_api_management_named_value.signing,
    azapi_resource.di_backend,
  ]
}

# Per-tenant attribution: DI logs carry no tenant, so APIM logs x-daas-tenant.
resource "azurerm_api_management_api_diagnostic" "di_v1" {
  count                    = var.enable_diagnostics ? 1 : 0
  identifier               = "azuremonitor"
  api_name                 = azurerm_api_management_api.di_v1.name
  api_management_name      = var.apim_name
  resource_group_name      = local.apim_rg_name
  api_management_logger_id = var.apim_logger_id
  sampling_percentage      = 100
  always_log_errors        = true
  log_client_ip            = true
  verbosity                = "information"

  frontend_response {
    headers_to_log = ["x-daas-tenant", "x-daas-pool", "Retry-After"]
  }

  backend_response {
    headers_to_log = ["Retry-After", "apim-request-id"]
  }

  lifecycle {
    precondition {
      condition     = var.apim_logger_id != null
      error_message = "enable_diagnostics requires apim_logger_id."
    }
  }
}
