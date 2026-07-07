provider "routeros" {
  hosturl        = var.router_hosturl
  username       = var.router_username
  password       = var.router_password
  ca_certificate = var.router_ca_certificate
  insecure       = var.router_insecure
}
