# The APIM instance (Standard v2 or Premium v2) already exists and is owned outside
# this repo. Terraform only reads it and adds APIs, backends, named values, the
# external cache and diagnostics to it. The azapi read exposes the network settings
# that the azurerm data source does not (publicNetworkAccess, virtualNetworkType,
# the VNet subnet).
#
# Private topologies the guardrails accept:
#   Standard v2: inbound private endpoint + publicNetworkAccess = Disabled, and
#                outbound VNet integration (virtualNetworkType = External, subnet
#                delegated to Microsoft.Web/serverFarms) into apim_vnet_id.
#   Premium v2:  the same, or VNet injection in Internal mode into apim_vnet_id.
data "azapi_resource" "apim" {
  type      = "Microsoft.ApiManagement/service@2024-05-01"
  name      = var.apim_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.apim_resource_group_name}"

  response_export_values = {
    sku             = "sku.name"
    public_access   = "properties.publicNetworkAccess"
    vnet_type       = "properties.virtualNetworkType"
    vnet_subnet_id  = "properties.virtualNetworkConfiguration.subnetResourceId"
    public_ip_id    = "properties.publicIpAddressId"
    gateway_url     = "properties.gatewayUrl"
    identity_type   = "identity.type"
    principal_id    = "identity.principalId"
    private_ip_list = "properties.privateIPAddresses"
  }
}

locals {
  apim_id             = data.azapi_resource.apim.id
  apim_sku            = try(data.azapi_resource.apim.output.sku, "")
  apim_public         = try(data.azapi_resource.apim.output.public_access, "Enabled")
  apim_vnet_type      = try(data.azapi_resource.apim.output.vnet_type, "None")
  apim_vnet_subnet_id = try(data.azapi_resource.apim.output.vnet_subnet_id, null)
  apim_public_ip_id   = try(data.azapi_resource.apim.output.public_ip_id, null)
  apim_identity       = try(data.azapi_resource.apim.output.identity_type, "None")
  apim_principal_id   = try(data.azapi_resource.apim.output.principal_id, null)
  apim_location       = lower(replace(try(data.azapi_resource.apim.location, ""), " ", ""))
  apim_gateway_host   = trimprefix(try(data.azapi_resource.apim.output.gateway_url, "https://${var.apim_name}.azure-api.net"), "https://")

  # APIM reaches the DI, Key Vault and Redis private endpoints through this subnet
  # (VNet integration on Standard v2, integration or injection on Premium v2).
  apim_outbound_in_vnet = (
    local.apim_vnet_type != "None" &&
    local.apim_vnet_subnet_id != null &&
    startswith(lower(coalesce(local.apim_vnet_subnet_id, "-")), "${lower(var.apim_vnet_id)}/subnets/")
  )
}

# Fail the plan if the existing instance does not match what the design relies on.
resource "terraform_data" "apim_guardrails" {
  input = local.apim_id

  lifecycle {
    precondition {
      condition     = contains(var.allowed_apim_skus, local.apim_sku)
      error_message = "APIM ${var.apim_name} is on tier ${local.apim_sku}; allowed: ${join(", ", var.allowed_apim_skus)}. Backend pools, circuit breakers and VNet connectivity need Standard v2 or Premium v2."
    }

    precondition {
      condition     = !var.require_private_apim || ((local.apim_public == "Disabled" || local.apim_vnet_type == "Internal") && local.apim_public_ip_id == null)
      error_message = "APIM ${var.apim_name} is reachable from the internet (publicNetworkAccess=${local.apim_public}, virtualNetworkType=${local.apim_vnet_type}). The gateway must be private: an inbound private endpoint with public network access disabled (Standard v2 or Premium v2), or VNet injection in Internal mode (Premium v2), and no public IP."
    }

    precondition {
      condition     = local.apim_outbound_in_vnet
      error_message = "APIM ${var.apim_name} has no outbound VNet connectivity into apim_vnet_id (virtualNetworkType=${local.apim_vnet_type}, subnet=${coalesce(local.apim_vnet_subnet_id, "none")}). Enable VNet integration (Standard v2) or injection (Premium v2) into ${var.apim_vnet_id} so the gateway can reach the DI private endpoints."
    }

    # Every Analyze call makes 2-4 round trips to the Redis counters, so APIM, Redis and
    # DI must share a region.
    precondition {
      condition     = local.apim_location == lower(replace(var.location, " ", ""))
      error_message = "APIM ${var.apim_name} is in ${local.apim_location}, but location is ${var.location}. Deploy Redis and DI in the APIM instance's region."
    }

    precondition {
      condition     = strcontains(local.apim_identity, "SystemAssigned") && local.apim_principal_id != null
      error_message = "APIM ${var.apim_name} needs a system-assigned managed identity: it authenticates to DI and reads the signing keys from Key Vault with it."
    }
  }
}
