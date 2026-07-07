locals {
  peers = merge(
    var.workers,
    var.manage_control_plane_peers ? var.control_planes : {}
  )
}

resource "routeros_routing_bgp_instance" "k8s" {
  name      = var.bgp_instance_name
  as        = var.bgp_instance_as
  router_id = var.bgp_instance_router_id
}

resource "routeros_routing_bgp_template" "k8s" {
  name = var.bgp_template_name
  as   = var.bgp_instance_as

  output {
    default_originate = "always"
    redistribute      = "connected,static"
  }
}

resource "routeros_routing_bgp_connection" "k8s_peers" {
  for_each = local.peers

  name     = "peer-to-${each.key}"
  as       = var.bgp_instance_as
  instance = routeros_routing_bgp_instance.k8s.name
  templates = [
    routeros_routing_bgp_template.k8s.name,
  ]

  local {
    role = "ibgp"
  }

  remote {
    address = each.value.address
    as      = each.value.asn
  }
}
