# Azure Cache for Redis as the APIM external cache. Required: the Analyze policy keeps
# per-pool, per-second call counters here (cache-lookup-value / cache-store-value,
# caching-type="external") and spills to the zone overflow pool at the threshold.
# APIM reaches it over its VNet integration through the private endpoint on the TLS
# port (6380); the non-TLS port stays closed.
resource "azurerm_redis_cache" "this" {
  name                          = local.redis_name
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  sku_name                      = var.redis_sku_name
  family                        = var.redis_sku_name == "Premium" ? "P" : "C"
  capacity                      = var.redis_capacity
  zones                         = var.redis_sku_name == "Premium" ? var.redis_zones : null
  redis_version                 = "6"
  minimum_tls_version           = "1.2"
  non_ssl_port_enabled          = false
  public_network_access_enabled = false
  tags                          = local.tags

  # APIM's external cache connects with a connection string, so access keys stay
  # enabled. The key lives in Terraform state and APIM, never in the repo.
  access_keys_authentication_enabled = true

  redis_configuration {
    # Counters carry a 2 s TTL; evict only keys that have one.
    maxmemory_policy = "volatile-lru"
  }
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-${local.redis_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = local.pe_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.redis_name}"
    private_connection_resource_id = azurerm_redis_cache.this.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.dns_zone_ids["redis"]]
  }
}

resource "azurerm_api_management_redis_cache" "this" {
  name              = "external-cache"
  api_management_id = local.apim_id
  cache_location    = "default"
  description       = "Per-pool capacity counters for DI overflow routing"
  redis_cache_id    = azurerm_redis_cache.this.id
  # host:6380,password=...,ssl=True,abortConnect=False (sensitive).
  connection_string = azurerm_redis_cache.this.primary_connection_string

  # APIM connects as soon as the cache is registered, so the private endpoint and the
  # privatelink.redis.cache.windows.net link to the APIM VNet must exist first.
  depends_on = [
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.this,
    terraform_data.apim_guardrails,
  ]
}
