# Platform (landing zone) settings for prod. Placeholder IDs: replace from DeployEz.
subscription_id = "00000000-0000-0000-0000-000000000000"
environment     = "prod"
location        = "australiaeast"
name_prefix     = "daas-di-prod"
unique_suffix   = "x7p"

vnet_address_space = ["10.60.0.0/24"]
apim_subnet_prefix = "10.60.0.0/27"
pe_subnet_prefix   = "10.60.0.64/26"

# hub_vnet_id = "/subscriptions/<hub-sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<hub-vnet>"
# existing_private_dns_zone_ids = {
#   cognitiveservices = "/subscriptions/<hub-sub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
# }

apim_sku_name   = "Premium_2"
apim_zones      = ["1", "2"]
publisher_name  = "DaaS Platform"
publisher_email = "daas-platform@example.com"
redis_sku_name  = "Balanced_B1"

entra_tenant_id   = "00000000-0000-0000-0000-000000000000"
gateway_audience  = "api://di-gateway-prod"
dispatcher_app_id = "00000000-0000-0000-0000-00000000d15a"
# gateway_host    = "di.internal.example" # set once the custom domain is bound

di_name_suffix = "-x7p"

tags = {
  costCentre = "daas"
  owner      = "daas-platform"
}
