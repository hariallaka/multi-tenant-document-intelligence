# One pool per cell: the Analyze operation's first and second attempts.
resource "azapi_resource" "cell_pool" {
  for_each  = var.di_cells
  type      = local.apim_backends_type
  name      = "pool-${each.key}"
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI cell ${each.key} (${each.value.zone})"
      type        = "Pool"
      pool = {
        services = [
          for name, m in each.value.members : {
            id       = azapi_resource.di_backend[name].id
            priority = 1
            weight   = m.weight
          }
        ]
      }
    }
  }
}

# One overflow pool per zone, reached only from the Analyze final retry.
# General and Confidential never share members; Restricted has none (variables.tf).
resource "azapi_resource" "overflow_pool" {
  for_each  = var.di_overflow
  type      = local.apim_backends_type
  name      = "pool-overflow-${each.key}"
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI ${each.key} overflow, reached only from the Analyze retry path"
      type        = "Pool"
      pool = {
        services = [
          for name, m in each.value : {
            id       = azapi_resource.di_backend[name].id
            priority = 1
            weight   = m.weight
          }
        ]
      }
    }
  }
}
