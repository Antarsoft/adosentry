resource "azurerm_resource_group" "main" {
  name     = "rg-contoso-prod"
  location = var.location
  tags     = local.tags
}
