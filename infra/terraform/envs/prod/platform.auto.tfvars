# Platform settings for prod. Placeholder IDs: replace from DeployEz.
subscription_id = "00000000-0000-0000-0000-000000000000"
environment     = "prod"
location        = "australiaeast" # must match the APIM instance's region
name_prefix     = "daas-di-prod"
unique_suffix   = "x7p"

# Existing APIM Premium v2 instance. It must be private (VNet injection in Internal
# mode, or public network access disabled) with no public IP; the plan fails otherwise.
apim_name                = "apim-daas-prod"                                                                                                                                # TODO: existing instance
apim_resource_group_name = "rg-apim-prod"                                                                                                                                  # TODO
apim_vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-prod/providers/Microsoft.Network/virtualNetworks/vnet-apim-prod" # TODO

# Private endpoints for DI, Key Vault and Redis. Either reuse a subnet that APIM can
# reach (set existing_pe_subnet_id), or let Terraform create a spoke peered to the APIM VNet.
# existing_pe_subnet_id = "/subscriptions/.../virtualNetworks/vnet-apim-prod/subnets/snet-pe"
vnet_address_space = ["10.60.0.0/26"]
pe_subnet_prefix   = "10.60.0.0/27"

# Hub-owned private DNS zones (already linked to the APIM VNet by the hub team):
# existing_private_dns_zone_ids = {
#   cognitiveservices = "/subscriptions/<hub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
# }

redis_sku_name = "Balanced_B0"

entra_tenant_id   = "00000000-0000-0000-0000-000000000000"
gateway_audience  = "api://di-gateway-prod"
dispatcher_app_id = "00000000-0000-0000-0000-00000000d15a"
# gateway_host    = "di.internal.example" # defaults to the instance's gateway host

di_name_suffix = "-x7p"

tags = {
  costCentre = "daas"
  owner      = "daas-platform"
}
