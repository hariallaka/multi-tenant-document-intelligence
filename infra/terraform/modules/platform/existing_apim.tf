# The APIM Premium v2 instance already exists and is owned outside this repo.
# Terraform only reads it and adds APIs, backends, named values, the external
# cache and diagnostics to it. The azapi read exposes the network settings that
# the azurerm data source does not (publicNetworkAccess, virtualNetworkType).
data "azapi_resource" "apim" {
  type      = "Microsoft.ApiManagement/service@2024-05-01"
  name      = var.apim_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.apim_resource_group_name}"

  response_export_values = {
    sku             = "sku.name"
    public_access   = "properties.publicNetworkAccess"
    vnet_type       = "properties.virtualNetworkType"
    public_ip_id    = "properties.publicIpAddressId"
    gateway_url     = "properties.gatewayUrl"
    identity_type   = "identity.type"
    principal_id    = "identity.principalId"
    private_ip_list = "properties.privateIPAddresses"
  }
}

locals {
  apim_id           = data.azapi_resource.apim.id
  apim_sku          = try(data.azapi_resource.apim.output.sku, "")
  apim_public       = try(data.azapi_resource.apim.output.public_access, "Enabled")
  apim_vnet_type    = try(data.azapi_resource.apim.output.vnet_type, "None")
  apim_public_ip_id = try(data.azapi_resource.apim.output.public_ip_id, null)
  apim_identity     = try(data.azapi_resource.apim.output.identity_type, "None")
  apim_principal_id = try(data.azapi_resource.apim.output.principal_id, null)
  apim_gateway_host = trimprefix(try(data.azapi_resource.apim.output.gateway_url, "https://${var.apim_name}.azure-api.net"), "https://")
}

# Fail the plan if the existing instance does not match what the design relies on.
resource "terraform_data" "apim_guardrails" {
  input = local.apim_id

  lifecycle {
    precondition {
      condition     = local.apim_sku == "PremiumV2"
      error_message = "APIM ${var.apim_name} must be on the Premium v2 tier (found ${local.apim_sku})."
    }

    precondition {
      condition     = !var.require_private_apim || ((local.apim_public == "Disabled" || local.apim_vnet_type == "Internal") && local.apim_public_ip_id == null)
      error_message = "APIM ${var.apim_name} is reachable from the internet (publicNetworkAccess=${local.apim_public}, virtualNetworkType=${local.apim_vnet_type}). The gateway must be private: VNet injection in Internal mode, or public network access disabled with a private endpoint, and no public IP."
    }

    precondition {
      condition     = strcontains(local.apim_identity, "SystemAssigned") && local.apim_principal_id != null
      error_message = "APIM ${var.apim_name} needs a system-assigned managed identity: it authenticates to DI and reads the signing keys from Key Vault with it."
    }
  }
}
