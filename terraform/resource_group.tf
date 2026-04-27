resource "azurerm_resource_group" "myResourceGroup" {
  name     = var.resourcegroupname
  location = "westus2"
}