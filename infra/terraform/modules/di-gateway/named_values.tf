# Maps are stored as base64(JSON): the policies drop named values into XML
# attributes and C# string literals, where raw JSON quotes would break parsing.
# Named values are limited to 4,096 characters; see checks.tf.
resource "azurerm_api_management_named_value" "tenant_cell_map" {
  name                = "tenant-cell-map"
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = "tenant-cell-map"
  value               = base64encode(jsonencode(local.tenant_cell_map))
}

resource "azurerm_api_management_named_value" "di_host_map" {
  name                = "di-host-map"
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = "di-host-map"
  value               = base64encode(jsonencode(local.di_host_map))
}

resource "azurerm_api_management_named_value" "plain" {
  for_each = {
    "entra-tenant-id"     = var.entra_tenant_id
    "di-gateway-audience" = var.gateway_audience
    "dispatcher-app-id"   = var.dispatcher_app_id
    "gateway-host"        = var.gateway_host
  }
  name                = each.key
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = each.key
  value               = each.value
}

# Signing keys are Key Vault references resolved by the APIM managed identity.
# Versionless IDs let APIM pick up rotations (scripts/rotate-signing-key.sh).
resource "azurerm_api_management_named_value" "signing" {
  for_each = {
    "result-signing-key"      = var.signing_secret_id
    "result-signing-key-prev" = var.signing_secret_prev_id
  }
  name                = each.key
  api_management_name = var.apim_name
  resource_group_name = local.apim_rg_name
  display_name        = each.key
  secret              = true

  value_from_key_vault {
    secret_id = each.value
  }
}
