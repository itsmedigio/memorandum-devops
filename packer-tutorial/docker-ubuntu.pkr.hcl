packer {
  required_plugins { 
    docker = { # per questo tutorial uso il plugin docker di hashicorp
      version = ">= 0.0.7"
      source  = "github.com/hashicorp/docker"
    }
  }
}

# qua puoi dichiarare variabili (simili a come vengono fatte in terraform)
# anche se vengono specificati dei valori nel pkrvars, qua vengono dichiarate, quindi il pkrvars è un "override"
# ha comunque priorità quanto passato da CLI tramite --var-file o -var

variable "my_name" {
  type    = string
  default = "Provide your name on pkrvars file!"
}

#source nomedellasource, displayname

source "docker" "ubuntu-xenial" {
  image  = "ubuntu:xenial" # immagine e tag docker
  commit = true
}

source "docker" "ubuntu-bionic" {
  image  = "ubuntu:bionic"
  commit = true
}

build { # blocco build, dove decido cosa fare della base (in questo caso le due immagini ubuntu)
  name = "learn-packer"
  sources = [
    "source.docker.ubuntu-xenial",
    "source.docker.ubuntu-bionic"
  ]

  # i vari provisioner fanno azioni sulla mcchina, per esempio shell esegue script etc

  provisioner "shell" {
    inline = [
      "echo \"using name: ${var.my_name}\""
    ]
  }

  provisioner "shell" {
    inline = [
      "echo Adding file to Docker Container",
      "echo \"Ciao da ${var.my_name}\" > hello_world.txt",
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "ENV_VAR=hello world",
    ]
    inline = ["echo $ENV_VAR"]
  }


provisioner "shell" {
    inline = ["uname -a > version.txt"]
}

# i post processor sono delle azioni che vengono eseguit dopo la build, esempio docker-tag

post-processor "docker-tag" {
  repository = "docker.io/itsmedigio/ubuntu"
  tags       = ["packer-xenial"]
  only       = ["docker.ubuntu-xenial"]
}

post-processor "docker-tag" {
  repository = "docker.io/itsmedigio/ubuntu"
  tags       = ["packer-bionic"]
  only       = ["docker.ubuntu-bionic"]
}
}



