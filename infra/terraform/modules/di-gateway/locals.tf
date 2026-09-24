locals {
  # Workload zones. A zone never shares DI resources or overflow with another zone.
  zones = ["general", "critical", "confidential", "restricted"]

  apim_rg_name = coalesce(var.apim_resource_group_name, var.rg_name)

  # Pinned ARM API version for APIM backends. 2024-05-01 is the latest GA version
  # whose schema carries both circuitBreaker and pool (checked against azapi v2.12.0).
  apim_backends_type = "Microsoft.ApiManagement/service/backends@2024-05-01"

  policy_dir = coalesce(var.policy_dir, "${path.module}/../../../../apim/policies")

  cell_members = merge([
    for cell, c in var.di_cells : {
      for name, m in c.members : name => { cell = cell, zone = c.zone, weight = m.weight }
    }
  ]...)

  overflow_members = merge([
    for zone, members in var.di_overflow : {
      for name, m in members : name => { cell = "overflow-${zone}", zone = zone, weight = m.weight }
    }
  ]...)

  all_members = merge(local.cell_members, local.overflow_members)

  # Declared member count, before merge() collapses duplicate keys (see checks.tf).
  declared_member_count = (
    sum(concat([0], [for c in var.di_cells : length(c.members)])) +
    sum(concat([0], [for z in var.di_overflow : length(z)]))
  )

  regional_di_count = length(local.all_members) + var.dedicated_di_count

  di_host = { for name, _ in local.all_members : name => "${name}${var.di_name_suffix}.cognitiveservices.azure.com" }

  # Zone is derived from the cell, never declared on the tenant. lookup() keeps
  # a bad cell reference from crashing plan before checks.tf can report it.
  tenant_cell_map = {
    for k, t in var.di_tenants : k => merge(t, { zone = try(var.di_cells[t.cell].zone, "unknown") })
  }

  di_host_map = { for name, host in local.di_host : host => name }

  # Pool Analyze capacity (sum of member TPS). The Analyze policy spills to the
  # zone overflow pool at overflow_threshold_pct of this. Keys: cell name, or overflow-<zone>.
  pool_capacity = merge(
    { for cell, c in var.di_cells : cell => { tps = sum([for m in c.members : m.tps]) } },
    { for zone, m in var.di_overflow : "overflow-${zone}" => { tps = sum([for x in m : x.tps]) } },
  )

  pool_sizes = merge(
    { for cell, c in var.di_cells : "pool-${cell}" => length(c.members) },
    { for zone, m in var.di_overflow : "pool-overflow-${zone}" => length(m) },
  )

  base_tags = merge(var.tags, { platform = "daas-di" })
}
