# main.tf è l'entrypoint del codice terraform da eseguire
# terraform controlla i file
#     - providers.tf (dove trova la dichiarazione dei provider da utilizzare)
#     - output.tf (contiene le variabili che devono essere usate come output)
#     - variables.tf (contiene le variabili da usare sulle varie risorse, più info nel file)
# controlla le cartelle
#     - modules (dove possono essere creati dei moduli da eseguire)
# terraform init scarica i bin necessary
# terraform plan capisce cosa va eseguito e genera un .tfstate
# terraform apply applica le modifiche
# terraform destroy distrugge
# terraform fmt formatta i file tf

provider "azurerm" {

  features {}
}

