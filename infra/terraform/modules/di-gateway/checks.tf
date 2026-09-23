# Guardrails. These are lifecycle preconditions (not check blocks) so a bad
# config fails the plan instead of producing a warning.
resource "terraform_data" "guardrails" {
  input = {
    cells   = keys(var.di_cells)
    tenants = keys(var.di_tenants)
    members = keys(local.all_members)
  }

  lifecycle {
    # Every tenant references an existing cell.
    precondition {
      condition     = alltrue([for t in var.di_tenants : contains(keys(var.di_cells), t.cell)])
      error_message = "A tenant in di_tenants references an undefined cell: ${join(", ", [for k, t in var.di_tenants : "${k} -> ${t.cell}" if !contains(keys(var.di_cells), t.cell)])}."
    }

    # Overflow-enabled tenants have an overflow pool in their own zone, and none are Restricted.
    precondition {
      condition = alltrue([
        for t in var.di_tenants :
        !t.overflow || (
          try(var.di_cells[t.cell].zone, "") != "restricted" &&
          contains(keys(var.di_overflow), try(var.di_cells[t.cell].zone, ""))
        )
      ])
      error_message = "An overflow-enabled tenant has no overflow pool in its zone, or is in the Restricted zone: ${join(", ", [for k, t in var.di_tenants : k if t.overflow && (try(var.di_cells[t.cell].zone, "") == "restricted" || !contains(keys(var.di_overflow), try(var.di_cells[t.cell].zone, "")))])}."
    }

    # Total DI accounts per region, including Dedicated, stay at or below the regional limit.
    precondition {
      condition     = local.regional_di_count <= var.regional_di_limit
      error_message = "Regional DI budget exceeded: ${length(local.all_members)} gateway accounts + ${var.dedicated_di_count} dedicated = ${local.regional_di_count} > ${var.regional_di_limit}."
    }

    # Pool member count stays at or below the APIM pool limit.
    precondition {
      condition     = alltrue([for n in values(local.pool_sizes) : n <= var.max_pool_members])
      error_message = "An APIM pool exceeds ${var.max_pool_members} members: ${join(", ", [for p, n in local.pool_sizes : "${p}=${n}" if n > var.max_pool_members])}."
    }

    # A DI resource belongs to exactly one pool (no member shared between cells or zones).
    precondition {
      condition     = local.declared_member_count == length(local.all_members)
      error_message = "A DI member key appears in more than one cell or overflow pool. Member keys must be unique; overflow is never shared across zones."
    }

    # Pool names derive from cell names; a cell called overflow-<zone> would collide.
    precondition {
      condition     = alltrue([for c in keys(var.di_cells) : !startswith(c, "overflow-")])
      error_message = "Cell names must not start with overflow- (reserved for zone overflow pools)."
    }

    # APIM named values are limited to 4,096 characters.
    precondition {
      condition     = length(base64encode(jsonencode(local.tenant_cell_map))) <= 4096
      error_message = "tenant-cell-map exceeds the 4,096-character named-value limit. Move the map to the external cache (design: Risks)."
    }

    precondition {
      condition     = length(base64encode(jsonencode(local.di_host_map))) <= 4096
      error_message = "di-host-map exceeds the 4,096-character named-value limit."
    }
  }
}
