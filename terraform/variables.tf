# file delle variabili di terraform
# tipi variabili in terraform: string, number, bool, list, map, set, object, tuple, ed any
# le variabili hanno questa gerarchia
#     max) -var o --var-file override di tutto
#     1) varibili d'ambiente
#     2) terraform.tfvars (o variables.tf etc)
#     3) *.auto.tfvars



variable "resourcegroupname" {
  # default - A default value which then makes the variable optional.
  # type - This argument specifies what value types are accepted for the variable.
  # description - This specifies the input variable's documentation.
  # validation - A block to define validation rules, usually in addition to type constraints.
  # sensitive - Limits Terraform UI output when the variable is used in configuration.
  # nullable - Specify if the variable can be null within the module
  type        = string
  description = "Name of the resource group"
}

variable "vnetname" {
  type        = string
  description = "Name of the VNET"
}

