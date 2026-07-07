variable "router_hosturl" {
  description = "RouterOS API/REST endpoint, for example https://192.168.88.1"
  type        = string
}

variable "router_username" {
  description = "RouterOS username"
  type        = string
}

variable "router_password" {
  description = "RouterOS password"
  type        = string
  sensitive   = true
}

variable "router_ca_certificate" {
  description = "Path to CA certificate file for RouterOS TLS, empty to skip"
  type        = string
  default     = ""
}

variable "router_insecure" {
  description = "Disable TLS certificate verification"
  type        = bool
  default     = true
}

variable "bgp_instance_name" {
  description = "RouterOS BGP instance name"
  type        = string
  default     = "bgp-1"
}

variable "bgp_instance_as" {
  description = "Local router ASN"
  type        = string
  default     = "64512"
}

variable "bgp_instance_router_id" {
  description = "Router ID for the BGP instance"
  type        = string
  default     = "192.168.88.1"
}

variable "bgp_template_name" {
  description = "RouterOS BGP template name"
  type        = string
  default     = "k8s-cluster-template"
}

variable "workers" {
  description = "Worker iBGP peers"
  type = map(object({
    address = string
    asn     = string
  }))
  default = {
    kube-wk-01 = { address = "192.168.89.20", asn = "64512" }
    kube-wk-02 = { address = "192.168.89.21", asn = "64512" }
    kube-wk-03 = { address = "192.168.89.22", asn = "64512" }
  }
}

variable "manage_control_plane_peers" {
  description = "Whether to also create iBGP peers for control-plane nodes"
  type        = bool
  default     = false
}

variable "control_planes" {
  description = "Control-plane iBGP peers"
  type = map(object({
    address = string
    asn     = string
  }))
  default = {
    kube-cp-01 = { address = "192.168.89.10", asn = "64512" }
    kube-cp-02 = { address = "192.168.89.11", asn = "64512" }
    kube-cp-03 = { address = "192.168.89.12", asn = "64512" }
  }
}
