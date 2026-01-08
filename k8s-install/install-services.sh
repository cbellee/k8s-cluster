# install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# install openebs
helm repo add openebs https://openebs.github.io/openebs
helm repo update

# install OpenEBS without replicated volume support
helm install openebs --namespace openebs openebs/openebs --set engines.replicated.mayastor.enabled=false --create-namespace

# delete existing storageclass installed by Helm chart
kubectl delete openebs-hostpath

# create a directory for openebs default storage class
mkdir /mnt/vmm/openebs

# create default storageclass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    openebs.io/cas-type: local
    cas.openebs.io/config: |
      - name: StorageType
        value: "hostpath"
      - name: BasePath
        value: "/mnt/vmm/openebs/"
provisioner: openebs.io/local
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

cd ./harbor
kubectl create secret tls internal-bellee-cert-secret --cert=../ca/internal_bellee_net.pem --key=../ca/star.internal.bellee.net.key -n harbor-internal
kubectl create secret tls internal-bellee-cert-secret --cert=../ca/internal_bellee_net.pem --key=../ca/star.internal.bellee.net.key -n monitoring
cd ..

# install harbor private registry
helm upgrade harbor-internal \
    --namespace harbor-internal \
    --set expose.type=loadBalancer \
    --set expose.tls.auto.commonName=registry \
    --set expose.tls.enabled=true \
    --set expose.tls.secret.secretName=internal-bellee-cert-secret \
    --set expose.tls.certSource=secret \
    --set externalURL=https://registry.internal.bellee.net \
    --create-namespace .

# expose harbor externally to the cluster (uses Cilium LoadBalancer + iBGP)
#kubectl expose service harbor-internal-portal --namespace harbor-internal --type=LoadBalancer --target-port=80 --name=harbor-internal-portal-ext  
#kubectl expose service harbor-internal-registry --namespace harbor-internal --type=LoadBalancer --target-port=5000 --name=harbor-internal-registry-ext  

# install prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create ns monitoring
helm install prometheus prometheus-community/prometheus --namespace monitoring

# expose promoetheus externally to the cluster (uses Cilium LoadBalancer + iBGP)
kubectl expose service prometheus-server --namespace monitoring --type=LoadBalancer --target-port=9090 --name=prometheus-server-ext

# install grafana
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install grafana grafana/grafana --namespace monitoring

# expose grafana externally to the cluster (uses Cilium LoadBalancer + iBGP)
kubectl expose service grafana --namespace monitoring --type=LoadBalancer --target-port=3000 --name=grafana-ext

# get login password
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
# username: admin