terraform {
  required_providers {
    # nome con cui è referenziato nel codice
    azurerm = {
      source  = "hashicorp/azurerm" # nome del provider nel formato registry/nomeprovider
      version = "~> 3.0.2"
    }

    # possono essere dichiarati ed usati più providers
  }

  required_version = ">= 1.1.0"
}
