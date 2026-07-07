# Quick Start Guide

This guide walks you through building and deploying the MikroTik DNS Controller.

**Status**: ✅ Verified working with go-routeros v3.0.1 and MikroTik binary protocol

## 5-Minute Setup

### 1. Build & Push Docker Image

```bash
cd /home/chris/repos/k8s-cluster/mikrotik-dns-controller

# Build
docker build -t ghcr.io/cbellee/mikrotik-dns-controller:latest .

# Push to registry
docker push ghcr.io/cbellee/mikrotik-dns-controller:latest
```

### 2. Setup Docker Registry Secret

Before deploying, create a secret for image pulls:

```bash
# Login to ghcr.io (one-time setup)
docker login ghcr.io

# Create Kubernetes secret
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=cbellee \
  --docker-email=user@example.com \
  -n mikrotik-dns-controller \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json
```

### 3. Update Deployment with MikroTik Credentials

Edit `k8s/deployment.yaml` and update the secret with your MikroTik details:

```yaml
stringData:
  host: "192.168.88.1"                          # Your MikroTik IP
  username: "admin"                             # MikroTik user
  password: "your-actual-password-here"         # MikroTik password
  insecure: "true"                              # true = skip SSL verification
```

### 4. Deploy to Cluster

```bash
# Deploy RBAC + Service Account + Namespace
kubectl apply -f k8s/rbac.yaml

# Deploy the controller
kubectl apply -f k8s/deployment.yaml

# Verify it's running
kubectl get pods -n mikrotik-dns-controller
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller
```

You should see:
```
2026/07/07 14:21:28 Connecting to MikroTik at 192.168.88.1...
2026/07/07 14:21:28 Connected to MikroTik successfully
2026/07/07 14:21:28 Connected to Kubernetes successfully
2026/07/07 14:21:28 Starting service watcher...
```

### Technology Stack

- **MikroTik API**: Binary protocol (not REST) via [go-routeros/routeros v3.0.1](https://github.com/go-routeros/routeros)
- **Kubernetes**: Watches services using client-go library
- **Protocol**: Length-prefixed binary words on TCP 8728/8729

### 5. Update Your Services

Add annotations to your LoadBalancer services:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: colourserver-green
  annotations:
    dns.mikrotik/enabled: "true"
    dns.mikrotik/hostname: "colourserver-green.internal.bellee.net"
spec:
  type: LoadBalancer
  # ... rest of spec
```

Apply and watch the magic:

```bash
kubectl apply -f your-service.yaml

# Watch controller logs
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller
```

You should see:

```
2026/07/07 14:21:28 Adding/updating DNS entry: colourserver-blue.internal.bellee.net -> 172.16.0.0
2026/07/07 14:21:28 Successfully synced service default/colourserver-blue to MikroTik DNS
2026/07/07 14:21:28 Adding/updating DNS entry: colourserver-green.internal.bellee.net -> 172.16.0.1
2026/07/07 14:21:28 Successfully synced service default/colourserver-green to MikroTik DNS
```

### 6. Verify DNS Entries

**On the MikroTik router:**

```bash
ssh -l belstarr 192.168.88.1
/ip/dns/static> print

Columns: NAME, TYPE, ADDRESS, TTL
 #  NAME                                    TYPE  ADDRESS         TTL
15  colourserver-blue.internal.bellee.net   A     172.16.0.0      1d
16  colourserver-green.internal.bellee.net  A     172.16.0.1      1d
```

**Test DNS resolution:**

```bash
nslookup colourserver-blue.internal.bellee.net 192.168.88.1
Server:         192.168.88.1
Address:        192.168.88.1#53

Non-authoritative answer:
Name:   colourserver-blue.internal.bellee.net
Address: 172.16.0.0
```

Done! 🎉

## How to Use as a Learning Resource

This controller demonstrates several key Kubernetes controller patterns:

### 1. **Watch Pattern** (main.go)
```go
watcher, err := sr.kubeClient.CoreV1().Services("").Watch(ctx, metav1.ListOptions{})
for event := range watcher.ResultChan() {
    // Handle service events
}
```

Shows how to watch for resource changes in Kubernetes.

### 2. **Event Reconciliation** (main.go)
```go
switch event.Type {
case watch.Added, watch.Modified:
    sr.reconcileService(ctx, service)
case watch.Deleted:
    sr.deleteService(ctx, service)
}
```

Demonstrates the standard reconciliation pattern - reacting to state changes.

### 3. **Annotation-Driven Configuration** (main.go)
```go
hostname, ok := annotations[annotationHostname]
if !ok || hostname == "" {
    return nil  // Skip if annotation missing
}
```

Shows how to use Kubernetes annotations to configure per-resource behavior.

### 4. **External API Integration** (mikrotik.go)
```go
conn, err := routeros.DialTimeout("192.168.88.1:8728", username, password, 30*time.Second)
reply, err := conn.RunContext(ctx, "/ip/dns/static/add", "=name=example.com", "=address=1.2.3.4")
for _, sentence := range reply.Re {
    for _, pair := range sentence.List {  // proto.Sentence.List contains []proto.Pair
        if pair.Key == "name" {
            name := pair.Value  // access Key and Value fields
        }
    }
}
```

Demonstrates binary protocol API interaction using go-routeros library which handles MikroTik's proprietary protocol transparently.

### 5. **RBAC Least Privilege** (k8s/rbac.yaml)
```yaml
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch"]  # Minimal permissions
```

Shows how to create secure RBAC policies with minimum required permissions.

### 6. **In-Cluster Configuration** (main.go)
```go
config, err := rest.InClusterConfig()
clientset, err := kubernetes.NewForConfig(config)
```

Shows how to authenticate to Kubernetes API from within a pod.

## Directory Structure Explained

```
mikrotik-dns-controller/
├── main.go              # Entry point + ServiceReconciler (watcher logic)
├── mikrotik.go          # MikroTikClient (external API integration)
├── go.mod / go.sum      # Go dependencies
├── Dockerfile           # Multi-stage build for production
├── .gitignore
├── README.md            # Full documentation
├── QUICKSTART.md        # This file
└── k8s/
    ├── rbac.yaml        # RBAC + ServiceAccount + Namespace
    ├── deployment.yaml  # Secrets + Deployment manifest
    └── example-services.yaml  # Example services with annotations
```

## Key Code Sections to Study

### Service Watcher Loop (main.go, ~20 lines)
Shows the core watch-reconcile-act pattern.

### Reconciliation Logic (main.go, ~40 lines)
Shows how to extract data and call external APIs.

### MikroTik Client with Binary Protocol (mikrotik.go, ~150 lines)
Shows go-routeros integration, sentence parsing, and API command execution.

### RBAC Definition (k8s/rbac.yaml, ~25 lines)
Shows minimal permission granting.

## Extending the Controller

### Add Support for Ingress

Replace service watcher with ingress watcher:
```go
watcher, err := sr.kubeClient.NetworkingV1().Ingresses("").Watch(ctx, metav1.ListOptions{})
```

### Add Metrics

Import Prometheus client:
```go
import "github.com/prometheus/client_golang/prometheus"

dnsEntriesCreated := prometheus.NewCounterVec(...)
```

### Add Validation Webhook

Create a validating admission webhook to catch annotation typos:
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
```

### Add Leader Election

For HA, add go-client's `leaderelection` package to ensure only one controller reconciles.

### Modify MikroTik API Calls

The go-routeros library provides many more commands:
```go
// Add DHCP lease
reply, err := conn.RunContext(ctx, "/ip/dhcp-server/lease/add", "=address=10.0.0.5", ...)

// List interfaces
reply, err := conn.RunContext(ctx, "/interface/print")

// Add firewall rule
reply, err := conn.RunContext(ctx, "/ip/firewall/nat/add", "=chain=srcnat", ...)
```

## Testing Locally

Without MikroTik:

```bash
# Build
go build -o mikrotik-dns-controller .

# Mock MikroTik with a fake API server
go test -v ./...
```

With real MikroTik:

```bash
export MIKROTIK_HOST=192.168.88.1
export MIKROTIK_USERNAME=admin
export MIKROTIK_PASSWORD=password
export MIKROTIK_INSECURE=true

# Run locally (requires kubectl access)
./mikrotik-dns-controller
```

## Production Checklist

- [ ] Use private container registry (verified: ghcr.io image push working)
- [ ] Set `MIKROTIK_INSECURE=false` with valid certs (or `true` for self-signed in lab)
- [ ] Use `kubectl-sealed-secrets` for password storage
- [ ] Add resource requests/limits (current: 50m CPU/64Mi memory requests)
- [ ] Enable RBAC auditing
- [ ] Monitor logs with centralized logging (ELK, Loki, etc.)
- [ ] Add alerts on error rate
- [ ] Test disaster recovery
- [ ] Document runbook for troubleshooting
- [ ] Verify DNS entries visible on router via SSH
- [ ] Test nslookup resolution from clients

## Troubleshooting

### "Connection refused" on MikroTik
- Verify port 8728/8729 is open on router
- Check API service is enabled in `/ip/services`
- Confirm network connectivity: `ping 192.168.88.1`

### DNS entries not appearing
- Check controller logs: `kubectl logs -n mikrotik-dns-controller deployment/mikrotik-dns-controller`
- Verify service has LoadBalancer type and external IP
- Check annotations: `kubectl get svc -A -o jsonpath='{.items[*].metadata.annotations}'`

### Authentication failed
- Verify credentials in secret: `kubectl get secret -n mikrotik-dns-controller mikrotik-credentials -o yaml`
- Test credentials on router: `ssh -l username 192.168.88.1`

## Need Help?

See [README.md](./README.md) for:
- Full documentation
- Troubleshooting guide
- Architecture details (binary protocol, go-routeros)
- Performance tuning
- Security considerations
- MikroTik API protocol details
