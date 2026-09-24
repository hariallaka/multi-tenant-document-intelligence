output "resource_group_name" {
  description = "Resource group holding the DI accounts and supporting resources."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Region."
  value       = azurerm_resource_group.this.location
}

output "pe_subnet_id" {
  description = "Subnet for the DI private endpoints."
  value       = local.pe_subnet_id
  depends_on  = [azurerm_subnet_network_security_group_association.pe, azurerm_virtual_network_peering.apim_to_spoke]
}

output "cognitiveservices_dns_zone_id" {
  description = "privatelink.cognitiveservices.azure.com zone ID."
  value       = local.dns_zone_ids["cognitiveservices"]
  depends_on  = [azurerm_private_dns_zone_virtual_network_link.this]
}

# APIM outputs wait for the guardrails, so nothing is added to an instance that
# fails them.
output "apim_id" {
  description = "Existing APIM resource ID."
  value       = local.apim_id
  depends_on  = [terraform_data.apim_guardrails]
}

output "apim_name" {
  description = "Existing APIM name."
  value       = var.apim_name
}

output "apim_resource_group_name" {
  description = "Existing APIM resource group."
  value       = var.apim_resource_group_name
}

output "apim_gateway_host" {
  description = "Gateway host from the existing instance (resolved privately by your DNS)."
  value       = local.apim_gateway_host
}

# Consumers must not create policies that read these until APIM can resolve them,
# so the outputs wait for the RBAC grant, the external cache and the secrets.
output "apim_principal_id" {
  description = "APIM system-assigned identity object ID."
  value       = local.apim_principal_id
  depends_on  = [terraform_data.apim_guardrails, azurerm_role_assignment.apim_kv, azurerm_api_management_redis_cache.this]
}

output "signing_secret_id" {
  description = "Versionless Key Vault secret ID for result-signing-key."
  value       = "${azurerm_key_vault.this.vault_uri}secrets/result-signing-key"
  depends_on  = [azurerm_key_vault_secret.signing, azurerm_role_assignment.apim_kv]
}

output "signing_secret_prev_id" {
  description = "Versionless Key Vault secret ID for result-signing-key-prev."
  value       = "${azurerm_key_vault.this.vault_uri}secrets/result-signing-key-prev"
  depends_on  = [azurerm_key_vault_secret.signing, azurerm_role_assignment.apim_kv]
}

output "key_vault_name" {
  description = "Key Vault holding the signing keys."
  value       = azurerm_key_vault.this.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID."
  value       = azurerm_log_analytics_workspace.this.id
}

output "apim_logger_id" {
  description = "Built-in azuremonitor logger, used by the API diagnostic."
  value       = "${local.apim_id}/loggers/azuremonitor"
  depends_on  = [azurerm_monitor_diagnostic_setting.apim]
}
