data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                          = local.key_vault_name
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  tags                          = local.tags

  network_acls {
    bypass         = "None"
    default_action = "Deny"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${local.key_vault_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = local.pe_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.key_vault_name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.dns_zone_ids["vaultcore"]]
  }
}

# APIM resolves the signing-key named values with its managed identity.
resource "azurerm_role_assignment" "apim_kv" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = local.apim_principal_id
  principal_type       = "ServicePrincipal"

  depends_on = [terraform_data.apim_guardrails]
}

# The pipeline identity (WIF) writes the bootstrap secrets.
resource "azurerm_role_assignment" "deployer_kv" {
  count                = var.bootstrap_signing_keys ? 1 : 0
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Initial HMAC keys: 32 random bytes, base64. Ephemeral + write-only, so the key
# material is never stored in Terraform state or plan files. value_wo_version is
# fixed; rotation happens out of band and Terraform never rewrites the value.
ephemeral "random_bytes" "signing" {
  for_each = var.bootstrap_signing_keys ? toset(local.signing_secrets) : toset([])
  length   = 32
}

resource "azurerm_key_vault_secret" "signing" {
  #checkov:skip=CKV_AZURE_41:Rotated by scripts/rotate-signing-key.sh with 24 h overlap; an expiry would break in-flight tickets.
  for_each         = var.bootstrap_signing_keys ? toset(local.signing_secrets) : toset([])
  name             = each.key
  key_vault_id     = azurerm_key_vault.this.id
  content_type     = "application/octet-stream;base64"
  value_wo         = ephemeral.random_bytes.signing[each.key].base64
  value_wo_version = 1

  depends_on = [azurerm_role_assignment.deployer_kv, azurerm_private_endpoint.key_vault]

  # Losing a signing key invalidates every in-flight result ticket.
  lifecycle {
    prevent_destroy = true
  }
}
