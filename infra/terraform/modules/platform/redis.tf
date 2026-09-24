# Azure Managed Redis as the APIM external cache, used by the Analyze policy's
# per-tenant overflow counters (cache-lookup-value / cache-store-value, external).
resource "azurerm_managed_redis" "this" {
  name                      = local.redis_name
  location                  = var.location
  resource_group_name       = azurerm_resource_group.this.name
  sku_name                  = var.redis_sku_name
  high_availability_enabled = true
  public_network_access     = "Disabled"
  tags                      = local.tags

  default_database {
    # APIM's external cache connects with a connection string. The key stays in
    # Terraform state and APIM, never in the repo. See README verification points.
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    clustering_policy                  = "EnterpriseCluster"
    eviction_policy                    = "VolatileLRU"
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
    private_connection_resource_id = azurerm_managed_redis.this.id
    subresource_names              = ["redisEnterprise"]
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
  description       = "Overflow counters for the DI gateway"
  redis_cache_id    = azurerm_managed_redis.this.id
  connection_string = "${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port},password=${azurerm_managed_redis.this.default_database[0].primary_access_key},ssl=True,abortConnect=False"

  depends_on = [azurerm_private_endpoint.redis, terraform_data.apim_guardrails]
}
