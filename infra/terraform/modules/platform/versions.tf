terraform {
  required_version = ">= 1.11.0" # ephemeral resources and write-only attributes

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
