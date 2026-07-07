output "managed_peers" {
  value = {
    for name, peer in routeros_routing_bgp_connection.k8s_peers : name => {
      connection_name = peer.name
      remote_address  = local.peers[name].address
    }
  }
}
