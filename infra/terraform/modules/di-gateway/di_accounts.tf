resource "azurerm_cognitive_account" "di" {
  #checkov:skip=CKV2_AZURE_22:Customer-managed keys are not in the design baseline; add customer_managed_key if Confidential/Restricted policy requires it.
  for_each                      = local.all_members
  name                          = "${each.key}${var.di_name_suffix}"
  location                      = var.location
  resource_group_name           = var.rg_name
  kind                          = "FormRecognizer"
  sku_name                      = "S0"
  custom_subdomain_name         = "${each.key}${var.di_name_suffix}" # required for Entra auth and private endpoint
  local_auth_enabled            = false                              # keys disabled; also enforce via Azure Policy
  public_network_access_enabled = false

  identity { type = "SystemAssigned" } # for urlSource reads from staged Blob

  network_acls {
    default_action = "Deny"
  }

  tags = merge(local.base_tags, { cell = each.value.cell, zone = each.value.zone, backend_key = each.key })
}

resource "azurerm_private_endpoint" "di" {
  for_each            = local.all_members
  name                = "pe-${each.key}"
  location            = var.location
  resource_group_name = var.rg_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_cognitive_account.di[each.key].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }

  tags = local.base_tags
}

resource "azurerm_role_assignment" "apim_di" {
  for_each             = local.all_members
  scope                = azurerm_cognitive_account.di[each.key].id
  role_definition_name = var.di_role_definition_name
  principal_id         = var.apim_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_diagnostic_setting" "di" {
  for_each                   = var.enable_diagnostics ? local.all_members : {}
  name                       = "diag-${each.key}"
  target_resource_id         = azurerm_cognitive_account.di[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  lifecycle {
    precondition {
      condition     = var.log_analytics_workspace_id != null
      error_message = "enable_diagnostics requires log_analytics_workspace_id."
    }
  }
}
