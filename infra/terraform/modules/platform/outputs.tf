output "resource_group_name" {
  description = "Resource group holding the gateway platform (and the DI accounts)."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Region."
  value       = azurerm_resource_group.this.location
}

output "pe_subnet_id" {
  description = "Private endpoint subnet."
  value       = azurerm_subnet.pe.id
}

output "cognitiveservices_dns_zone_id" {
  description = "privatelink.cognitiveservices.azure.com zone ID."
  value       = local.dns_zone_ids["cognitiveservices"]
}

output "apim_id" {
  description = "APIM resource ID."
  value       = azurerm_api_management.this.id
}

output "apim_name" {
  description = "APIM name."
  value       = azurerm_api_management.this.name
}

output "apim_gateway_host" {
  description = "Default internal gateway host (<name>.azure-api.net)."
  value       = "${azurerm_api_management.this.name}.azure-api.net"
}

output "apim_private_ip_addresses" {
  description = "Private IPs of the internal gateway."
  value       = azurerm_api_management.this.private_ip_addresses
}

# Consumers must not create policies that read these until APIM can resolve them,
# so the outputs wait for the RBAC grant, the external cache and the secrets.
output "apim_principal_id" {
  description = "APIM system-assigned identity object ID."
  value       = azurerm_api_management.this.identity[0].principal_id
  depends_on  = [azurerm_role_assignment.apim_kv, azurerm_api_management_redis_cache.this]
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
  value       = "${azurerm_api_management.this.id}/loggers/azuremonitor"
  depends_on  = [azurerm_monitor_diagnostic_setting.apim]
}
