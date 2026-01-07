# install CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

cilium version

helm repo add cilium https://helm.cilium.io/
helm repo update

# install Cilium with Helm
# enable bgp & prometheus metrics
CILIUM_VERSION=1.18.5

helm upgrade --install cilium cilium/cilium --version $CILIUM_VERSION \
  --namespace kube-system \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set kubeProxyReplacement=true \
  --set reuse-values=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enableOpenMetrics=true \
  --set bgpControlPlane.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction}"

# add bgp configuration
k apply -f ./cilium-bgp-peer-config.yaml
k apply -f ./cilium-ip-pool.yaml
k apply -f ./cilium-bgp-advertisement.yaml
k apply -f ./cilium-bgp-cluster-config.yaml

# add test deployments
k apply -f ./colour-server-green.yaml
k apply -f ./colour-server-blue.yaml

# test service advertisement
GREEN_SERVICE_IP=$(k get svc -o json | jq '.items[] | select(.metadata.name == "colourserver-green")'.status.loadBalancer.ingress[0].ip -r)
BLUE_SERVICE_IP=$(k get svc -o json | jq '.items[] | select(.metadata.name == "colourserver-blue")'.status.loadBalancer.ingress[0].ip -r)

curl $GREEN_SERVICE_IP:80
curl $BLUE_SERVICE_IP:80
