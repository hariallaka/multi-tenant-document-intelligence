resource "azurerm_private_dns_zone" "this" {
  for_each            = local.zones_to_create
  name                = each.value
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# APIM must resolve <di>.cognitiveservices.azure.com, the vault and Redis to
# their private endpoints, so every zone created here is linked to its VNet.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each             = local.dns_links
  name                 = "link-${var.name_prefix}-${each.value.vnet}"
  private_dns_zone_id  = azurerm_private_dns_zone.this[each.value.zone].id
  virtual_network_id   = each.value.vnet == "apim" ? var.apim_vnet_id : azurerm_virtual_network.this[0].id
  registration_enabled = false
  tags                 = local.tags
}
