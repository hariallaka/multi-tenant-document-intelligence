output "di_accounts" {
  description = "Backend key => DI account ID, endpoint host and pool."
  value = {
    for k, m in local.all_members : k => {
      id   = azurerm_cognitive_account.di[k].id
      host = local.di_host[k]
      cell = m.cell
      zone = m.zone
    }
  }
}

output "cell_pool_ids" {
  description = "Cell name => APIM pool backend ID."
  value       = { for k, p in azapi_resource.cell_pool : k => p.id }
}

output "overflow_pool_ids" {
  description = "Zone => APIM overflow pool backend ID."
  value       = { for k, p in azapi_resource.overflow_pool : k => p.id }
}

output "api_id" {
  description = "APIM API ID for di-v1."
  value       = azurerm_api_management_api.di_v1.id
}

output "tenant_cell_map" {
  description = "Rendered tenant-cell-map (plain JSON, before base64)."
  value       = jsonencode(local.tenant_cell_map)
}

output "regional_di_count" {
  description = "DI accounts counted against the regional limit (gateway + dedicated)."
  value       = local.regional_di_count
}

output "pool_capacity" {
  description = "Pool => Analyze TPS capacity, and the per-second count at which traffic spills to overflow."
  value = {
    for k, v in local.pool_capacity : k => {
      tps             = v.tps
      spill_at_per_s  = floor(v.tps * var.overflow_threshold_pct / 100)
      overflow_target = startswith(k, "overflow-") ? null : (contains(keys(var.di_overflow), try(var.di_cells[k].zone, "")) ? "pool-overflow-${var.di_cells[k].zone}" : null)
    }
  }
}
