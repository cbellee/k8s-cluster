ROUTER_ID='192.168.88.1'
ROUTER_AS='64512'

/routing/bgp/instances/add name=bgp-1 as=$ROUTER_AS router-id=$ROUTER_ID routing-table=main
/routing/bgp/template/add name=k8s-cluster-template as=$ROUTER_AS output.redistribute=connected,static output.default-originate=always
/routing/bgp/connection/add name=peer-to-k8s-wk-01 instance=bgp-1 template=k8s-cluster-template remote.address=192.168.88.60 remote.as=$ROUTER_AS local.role=ibgp
/routing/bgp/connection/add name=peer-to-k8s-wk-02 instance=bgp-1 template=k8s-cluster-template remote.address=192.168.88.61 remote.as=$ROUTER_AS local.role=ibgp
/routing/bgp/connection/add name=peer-to-k8s-wk-03 instance=bgp-1 template=k8s-cluster-template remote.address=192.168.88.62 remote.as=$ROUTER_AS local.role=ibgp
