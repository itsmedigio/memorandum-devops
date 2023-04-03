# Create a virtual network

resource "azurerm_virtual_network" "vnet" {
  address_space       = ["10.0.0.0/16"]
  location            = "westus2"
  tags = {
    Environment = "Terraform Getting Started"
    Team        = "DevOps"
     }
}
