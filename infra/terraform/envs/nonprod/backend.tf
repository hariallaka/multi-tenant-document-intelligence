# Remote state in the platform state account; Entra auth through the pipeline's
# WIF service connection (no storage keys). Placeholders are replaced by DeployEz.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-nonprod"   # TODO: DeployEz state RG
    storage_account_name = "sttfstatenonprodxxxx" # TODO: DeployEz state account
    container_name       = "tfstate"
    key                  = "di-gateway/nonprod.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
  }
}
