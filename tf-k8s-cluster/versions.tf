terraform {
  required_version = ">= 1.6.0"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.9"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
