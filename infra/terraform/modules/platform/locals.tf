locals {
  tags = merge(var.tags, { platform = "daas-di", environment = var.environment })

  create_network = var.existing_pe_subnet_id == null
  pe_subnet_id   = local.create_network ? azurerm_subnet.pe[0].id : var.existing_pe_subnet_id

  private_dns_zones = {
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    vaultcore         = "privatelink.vaultcore.azure.net"
    redis             = "privatelink.redis.cache.windows.net"
  }

  zones_to_create = { for k, z in local.private_dns_zones : k => z if !contains(keys(var.existing_private_dns_zone_ids), k) }

  # Every created zone is linked to the APIM VNet, and to the spoke when there is one.
  # Keys are static so for_each never depends on apply-time IDs.
  dns_links = merge(
    { for k, _ in local.zones_to_create : "${k}-apim" => { zone = k, vnet = "apim" } },
    local.create_network ? { for k, _ in local.zones_to_create : "${k}-spoke" => { zone = k, vnet = "spoke" } } : {},
  )

  dns_zone_ids = merge(
    { for k, z in azurerm_private_dns_zone.this : k => z.id },
    var.existing_private_dns_zone_ids,
  )

  key_vault_name  = substr("kv-${replace(var.name_prefix, "-", "")}${var.unique_suffix}", 0, 24)
  redis_name      = "redis-${var.name_prefix}-${var.unique_suffix}"
  signing_secrets = ["result-signing-key", "result-signing-key-prev"]
}
