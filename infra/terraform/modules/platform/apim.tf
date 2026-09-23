# Classic Premium APIM (stv2) injected into the spoke in Internal mode: the
# gateway has only a private IP and has line-of-sight to the DI private endpoints.
# The public IP is required by stv2 for management-plane traffic only.
resource "azurerm_public_ip" "apim" {
  name                = "pip-${local.apim_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = local.apim_name
  zones               = var.apim_zones
  tags                = local.tags
}

resource "azurerm_api_management" "this" {
  #checkov:skip=CKV_AZURE_174:Internal VNet mode exposes no public gateway; Azure rejects publicNetworkAccess=Disabled at creation. Disable post-create if required.
  name                 = local.apim_name
  location             = var.location
  resource_group_name  = azurerm_resource_group.this.name
  publisher_name       = var.publisher_name
  publisher_email      = var.publisher_email
  sku_name             = var.apim_sku_name
  zones                = var.apim_zones
  virtual_network_type = "Internal"
  public_ip_address_id = azurerm_public_ip.apim.id
  min_api_version      = "2021-08-01"
  tags                 = local.tags

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  identity {
    type = "SystemAssigned"
  }

  protocols {
    http2_enabled = true
  }

  security {
    backend_ssl30_enabled  = false
    backend_tls10_enabled  = false
    backend_tls11_enabled  = false
    frontend_ssl30_enabled = false
    frontend_tls10_enabled = false
    frontend_tls11_enabled = false
  }

  timeouts {
    create = "3h"
    update = "3h"
  }

  depends_on = [azurerm_subnet_network_security_group_association.apim]
}
