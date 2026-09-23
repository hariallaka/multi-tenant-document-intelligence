# Platform (landing zone) settings for nonprod. Nonprod has its own subscription and DI budget.
subscription_id = "00000000-0000-0000-0000-000000000000"
environment     = "nonprod"
location        = "australiaeast"
name_prefix     = "daas-di-np"
unique_suffix   = "x7n"

vnet_address_space = ["10.61.0.0/24"]
apim_subnet_prefix = "10.61.0.0/27"
pe_subnet_prefix   = "10.61.0.64/26"

apim_sku_name   = "Premium_1"
apim_zones      = []
publisher_name  = "DaaS Platform"
publisher_email = "daas-platform@example.com"
redis_sku_name  = "Balanced_B0"

entra_tenant_id   = "00000000-0000-0000-0000-000000000000"
gateway_audience  = "api://di-gateway-nonprod"
dispatcher_app_id = "00000000-0000-0000-0000-00000000d15b"

di_name_suffix = "-x7n"

tags = {
  costCentre = "daas"
  owner      = "daas-platform"
}
