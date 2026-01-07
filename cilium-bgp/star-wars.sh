k create ns star-wars

kubectl create -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/minikube/http-sw-app.yaml -n star-wars

k -n kube-system exec cilium-dc57g -- cilium-dbg endpoint list

kubectl exec xwing -n star-wars -- curl -s -XPOST deathstar.star-wars.svc.cluster.local/v1/request-landing 
kubectl exec tiefighter -n star-wars -- curl -s -XPOST deathstar.star-wars.svc.cluster.local/v1/request-landing 

# add policy
cat <<EOF | k create -n star-wars -f -
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "rule1"
spec:
  description: "L3-L4 policy to restrict deathstar access to empire ships only"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
  - fromEndpoints:
    - matchLabels:
        org: empire
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
EOF

k -n kube-system exec cilium-l5xcc -- cilium-dbg endpoint list