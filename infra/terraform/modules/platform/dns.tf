resource "azurerm_private_dns_zone" "this" {
  for_each            = local.zones_to_create
  name                = each.value
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each             = local.zones_to_create
  name                 = "link-${var.name_prefix}"
  private_dns_zone_id  = azurerm_private_dns_zone.this[each.key].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}

# Internal-mode APIM has no public DNS; resolve the gateway and management
# endpoints to the private IP inside the spoke.
resource "azurerm_private_dns_zone" "apim" {
  count               = var.create_apim_dns_zone ? 1 : 0
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  count                = var.create_apim_dns_zone ? 1 : 0
  name                 = "link-${var.name_prefix}"
  private_dns_zone_id  = azurerm_private_dns_zone.apim[0].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_a_record" "apim" {
  for_each            = var.create_apim_dns_zone ? toset([local.apim_name, "${local.apim_name}.management", "${local.apim_name}.scm"]) : toset([])
  name                = each.value
  private_dns_zone_id = azurerm_private_dns_zone.apim[0].id
  ttl                 = 300
  records             = azurerm_api_management.this.private_ip_addresses
  tags                = local.tags
}
