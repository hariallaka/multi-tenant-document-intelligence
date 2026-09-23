locals {
  tags = merge(var.tags, { platform = "daas-di", environment = var.environment })

  private_dns_zones = {
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    vaultcore         = "privatelink.vaultcore.azure.net"
    redis             = "privatelink.redis.azure.net"
  }

  zones_to_create = { for k, z in local.private_dns_zones : k => z if !contains(keys(var.existing_private_dns_zone_ids), k) }

  dns_zone_ids = merge(
    { for k, z in azurerm_private_dns_zone.this : k => z.id },
    var.existing_private_dns_zone_ids,
  )

  apim_name       = "apim-${var.name_prefix}-${var.unique_suffix}"
  key_vault_name  = substr("kv-${replace(var.name_prefix, "-", "")}${var.unique_suffix}", 0, 24)
  redis_name      = "amr-${var.name_prefix}-${var.unique_suffix}"
  signing_secrets = ["result-signing-key", "result-signing-key-prev"]
}
