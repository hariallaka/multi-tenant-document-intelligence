# One Single backend per DI resource, named by its stable backend key. The Result
# operation targets these directly (pinned, no pool); pools reference them by ID.
resource "azapi_resource" "di_backend" {
  for_each  = local.all_members
  type      = local.apim_backends_type
  name      = each.key
  parent_id = var.apim_id

  body = {
    properties = {
      description = "DI ${each.key} (cell ${each.value.cell})"
      type        = "Single"
      protocol    = "http"
      url         = "https://${local.di_host[each.key]}/documentintelligence"
      tls         = { validateCertificateChain = true, validateCertificateName = true }
      circuitBreaker = {
        rules = [{
          name = "throttle-or-fault"
          failureCondition = {
            count    = 1
            interval = "PT10S"
            statusCodeRanges = [
              { min = 429, max = 429 },
              { min = 500, max = 503 }
            ]
          }
          tripDuration     = "PT10S" # fallback when DI sends no Retry-After
          acceptRetryAfter = true
        }]
      }
    }
  }

  depends_on = [azurerm_private_endpoint.di, azurerm_role_assignment.apim_di]
}
