# Resource group for the DI accounts and the gateway's supporting resources.
# The APIM instance stays in its own resource group.
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name_prefix}"
  location = var.location
  tags     = local.tags
}

# Spoke for the private endpoints, created only when no existing PE subnet is given.
resource "azurerm_virtual_network" "this" {
  count               = local.create_network ? 1 : 0
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  dns_servers         = var.dns_servers
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = length(var.vnet_address_space) > 0 && var.pe_subnet_prefix != null
      error_message = "Set vnet_address_space and pe_subnet_prefix, or pass existing_pe_subnet_id."
    }
  }
}

resource "azurerm_subnet" "pe" {
  count                             = local.create_network ? 1 : 0
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this[0].name
  address_prefixes                  = [var.pe_subnet_prefix]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled"
}

# Private endpoints accept only private traffic (APIM's VNet arrives through the
# peering, which the VirtualNetwork tag covers) on the ports their services use.
resource "azurerm_network_security_group" "pe" {
  count               = local.create_network ? 1 : 0
  name                = "nsg-${var.name_prefix}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-VNet-To-PrivateEndpoints"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "6380"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = var.pe_subnet_prefix
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  count                     = local.create_network ? 1 : 0
  subnet_id                 = azurerm_subnet.pe[0].id
  network_security_group_id = azurerm_network_security_group.pe[0].id
}

# Line of sight between APIM (injected into apim_vnet_id) and the private endpoints.
resource "azurerm_virtual_network_peering" "spoke_to_apim" {
  count                        = local.create_network ? 1 : 0
  name                         = "peer-${var.name_prefix}-to-apim"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.this[0].name
  remote_virtual_network_id    = var.apim_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "apim_to_spoke" {
  count                        = local.create_network && var.create_reverse_peering ? 1 : 0
  name                         = "peer-apim-to-${var.name_prefix}"
  resource_group_name          = split("/", var.apim_vnet_id)[4]
  virtual_network_name         = split("/", var.apim_vnet_id)[8]
  remote_virtual_network_id    = azurerm_virtual_network.this[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  use_remote_gateways          = false
}
