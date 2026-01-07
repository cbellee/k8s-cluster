crds=(ciliumbgpadvertisements.cilium.io
ciliumbgpclusterconfigs.cilium.io
ciliumbgpnodeconfigoverrides.cilium.io
ciliumbgpnodeconfigs.cilium.io
ciliumbgppeerconfigs.cilium.io
ciliumbgppeeringpolicies.cilium.io
ciliumcidrgroups.cilium.io                   
ciliumclusterwidenetworkpolicies.cilium.io
ciliumendpoints.cilium.io
ciliumexternalworkloads.cilium.io
ciliumidentities.cilium.io
ciliuml2announcementpolicies.cilium.io
ciliumloadbalancerippools.cilium.io
ciliumnetworkpolicies.cilium.io
ciliumnodeconfigs.cilium.io
ciliumnodes.cilium.io
ciliumpodippools.cilium.io)

# Check if the CRDs are installed
for crd in "${crds[@]}"; do
  if kubectl get crd "$crd" > /dev/null 2>&1; then
    echo "CRD $crd is installed"
    kubectl delete crd "$crd"
  else
    echo "CRD $crd is not installed"
  fi
done