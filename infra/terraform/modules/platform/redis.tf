# Azure Cache for Redis as the APIM external cache. Required: the Analyze policy keeps
# per-pool, per-second call counters here (cache-lookup-value / cache-store-value,
# caching-type="external") and spills to the zone overflow pool at the threshold.
#
# Authentication (option A, see README "Redis authentication"):
#   - Microsoft Entra ID is enabled on the cache (aad-enabled). Every client other than
#     APIM authenticates with Entra, through the access policy assignments below.
#   - APIM's external cache only accepts a connection string, so APIM alone uses an
#     access key. The key is read at apply time through an ephemeral listKeys call and
#     written to APIM through a write-only sensitive_body: it is never stored in
#     Terraform state, plan files or the repo.
#
# The cache and APIM registration use azapi, not azurerm: azurerm_redis_cache and
# azurerm_api_management_redis_cache both keep the access key in state.
resource "azapi_resource" "redis" {
  type      = "Microsoft.Cache/redis@2024-11-01"
  name      = local.redis_name
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags

  body = merge(
    {
      properties = {
        sku = {
          name     = var.redis_sku_name
          family   = var.redis_sku_name == "Premium" ? "P" : "C"
          capacity = var.redis_capacity
        }
        redisVersion        = "6"
        minimumTlsVersion   = "1.2"
        enableNonSslPort    = false
        publicNetworkAccess = "Disabled"
        # Keys stay on for APIM only; see the header.
        disableAccessKeyAuthentication = false
        redisConfiguration = {
          "aad-enabled" = "true"
          # Counters carry a 2 s TTL; evict only keys that have one.
          "maxmemory-policy" = "volatile-lru"
        }
      }
    },
    var.redis_sku_name == "Premium" && length(var.redis_zones) > 0 ? { zones = var.redis_zones } : {},
  )

  response_export_values = {
    host_name = "properties.hostName"
    ssl_port  = "properties.sslPort"
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
    private_connection_resource_id = azapi_resource.redis.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.dns_zone_ids["redis"]]
  }
}

# Entra ID data access for clients other than APIM (e.g. operators, the dispatcher).
resource "azapi_resource" "redis_entra_access" {
  for_each  = var.redis_entra_access
  type      = "Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01"
  name      = each.key
  parent_id = azapi_resource.redis.id

  body = {
    properties = {
      accessPolicyName = each.value.access_policy
      objectId         = each.value.object_id
      objectIdAlias    = each.key
    }
  }
}

# Access key for APIM, read at apply time only. Ephemeral: never persisted.
ephemeral "azapi_resource_action" "redis_keys" {
  type        = "Microsoft.Cache/redis@2024-11-01"
  resource_id = azapi_resource.redis.id
  action      = "listKeys"
  method      = "POST"

  response_export_values = {
    primary   = "primaryKey"
    secondary = "secondaryKey"
  }
}

# APIM external cache. The connection string goes in the write-only sensitive_body;
# Terraform re-sends it only when sensitive_body_version changes, i.e. when
# redis_apim_key or redis_key_version changes (key rotation, see README).
resource "azapi_resource" "apim_cache" {
  type      = "Microsoft.ApiManagement/service/caches@2024-05-01"
  name      = "external-cache"
  parent_id = local.apim_id

  body = {
    properties = {
      description     = "Per-pool capacity counters for DI overflow routing"
      useFromLocation = "default"
      resourceId      = "https://management.azure.com${azapi_resource.redis.id}"
    }
  }

  sensitive_body = {
    properties = {
      connectionString = "${local.redis_name}.redis.cache.windows.net:6380,password=${var.redis_apim_key == "secondary" ? ephemeral.azapi_resource_action.redis_keys.output.secondary : ephemeral.azapi_resource_action.redis_keys.output.primary},ssl=True,abortConnect=False"
    }
  }

  sensitive_body_version = {
    "properties.connectionString" = "${var.redis_apim_key}-${var.redis_key_version}"
  }

  # APIM connects as soon as the cache is registered, so the private endpoint and the
  # privatelink.redis.cache.windows.net link to the APIM VNet must exist first.
  depends_on = [
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.this,
    terraform_data.apim_guardrails,
  ]
}
