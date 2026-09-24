# Platform settings for nonprod. Placeholder IDs: replace from DeployEz.
subscription_id = "00000000-0000-0000-0000-000000000000"
environment     = "nonprod"
location        = "australiaeast" # must match the APIM instance's region
name_prefix     = "daas-di-np"
unique_suffix   = "x7n"

# Existing APIM Standard v2 instance (Premium v2 is not yet available in australiaeast).
# It must be private, or the plan fails:
#   inbound:  a private endpoint on the gateway, publicNetworkAccess = Disabled, no public IP
#   outbound: VNet integration into apim_vnet_id (subnet delegated to Microsoft.Web/serverFarms),
#             so APIM reaches the DI, Key Vault and Redis private endpoints.
# To move to Premium v2 later, point apim_name at the new instance; nothing else changes.
allowed_apim_skus = ["StandardV2", "PremiumV2"]

apim_name                = "apim-daas-np"                                                                                                                              # TODO: existing instance
apim_resource_group_name = "rg-apim-np"                                                                                                                                # TODO
apim_vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-np/providers/Microsoft.Network/virtualNetworks/vnet-apim-np" # TODO: APIM VNet integration VNet

# Private endpoints for DI, Key Vault and Redis. Either reuse a subnet that APIM can reach
# through its VNet integration (set existing_pe_subnet_id; not the delegated integration
# subnet itself), or let Terraform create a spoke peered to the APIM VNet.
# existing_pe_subnet_id = "/subscriptions/.../virtualNetworks/vnet-apim-np/subnets/snet-pe"
vnet_address_space = ["10.61.0.0/26"]
pe_subnet_prefix   = "10.61.0.0/27"

# Hub-owned private DNS zones (already linked to the APIM VNet by the hub team):
# existing_private_dns_zone_ids = {
#   cognitiveservices = "/subscriptions/<hub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
# }

# Azure Cache for Redis: the APIM external cache holding the overflow counters.
# Standard C1: primary + replica with an SLA. Use Premium (P1) with redis_zones for zone redundancy.
redis_sku_name = "Standard"
redis_capacity = 1

# Redis authentication (option A): Entra ID is enabled on the cache for every client
# except APIM, whose external cache needs an access key. The key is read at apply time
# and never stored in Terraform state. Rotate: see scripts/rotate-redis-key.md.
redis_apim_key    = "primary"
redis_key_version = "1"

# Entra principals that may read/write the cache directly (none needed by the gateway).
# redis_entra_access = {
#   "daas-ops" = { object_id = "<entra object id>", access_policy = "Data Reader" }
# }

entra_tenant_id   = "00000000-0000-0000-0000-000000000000"
gateway_audience  = "api://di-gateway-nonprod"
dispatcher_app_id = "00000000-0000-0000-0000-00000000d15b"
# gateway_host    = "di.internal.example" # defaults to the instance's gateway host

di_name_suffix = "-x7n"

tags = {
  costCentre = "daas"
  owner      = "daas-platform"
}
