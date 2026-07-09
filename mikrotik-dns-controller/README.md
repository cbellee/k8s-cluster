# MikroTik DNS Controller for Kubernetes

A custom Kubernetes controller that automatically manages DNS entries on a MikroTik RouterOS device based on LoadBalancer services in your cluster.

## How It Works

This controller watches for Kubernetes services and automatically creates/updates/deletes static DNS entries on your MikroTik router. Here's the workflow:

```
┌─────────────────────┐
│  Kubernetes Service │
│  (LoadBalancer)     │
└──────────┬──────────┘
           │
           │ annotated with:
           │ dns.mikrotik/enabled: "true"
           │ dns.mikrotik/hostname: "example.internal.bellee.net"
           │
           ▼
┌────────────────────────────────────┐
│  MikroTik DNS Controller Pod       │
│  - Watches for service changes     │
│  - Extracts external IP            │
│  - Uses go-routeros/routeros v3    │
└────────────────┬───────────────────┘
                 │
                 │ MikroTik Binary Protocol
                 │ (TCP port 8728/8729)
                 │
                 ▼
        ┌───────────────────┐
        │  MikroTik Router  │
        │  /ip/dns/static/  │
        └───────────────────┘
```

## Features

- ✅ **Automatic DNS Management**: Creates DNS entries when LoadBalancer services get external IPs
- ✅ **Service Annotation Driven**: Uses Kubernetes annotations to configure behavior per-service
- ✅ **Auto-Update**: Changes external IP? DNS updates automatically
- ✅ **Auto-Delete**: Service deleted? DNS entry cleaned up automatically
- ✅ **RBAC Secured**: Minimal permissions, watches services only
- ✅ **Error Recovery**: Automatically retries failed API calls
- ✅ **Namespace Agnostic**: Watches services across all namespaces

## Prerequisites

1. **Kubernetes Cluster** with LoadBalancer (Cilium BGP or similar)
2. **MikroTik RouterOS v6+** with:
   - API service enabled (port 8728 for unencrypted, 8729 for SSL)
   - User with permissions to manage `/ip/dns/static` entries
   - Network connectivity on API ports
3. **Network Access** from cluster to MikroTik API (TCP port 8728 or 8729)

**Important**: MikroTik API uses a custom **binary protocol**, not HTTP REST. This controller uses the [go-routeros](https://github.com/go-routeros/routeros) library (v3.0.1+) which handles the binary protocol transparently.

## Installation

### Step 1: Build the Docker Image

Automated option: this repository includes a GitHub Actions workflow at `.github/workflows/mikrotik-dns-controller-image.yml` that builds and publishes `ghcr.io/cbellee/mikrotik-dns-controller` on pushes to `main` when files under `mikrotik-dns-controller/` change.

```bash
cd mikrotik-dns-controller

# Build locally
docker build -t mikrotik-dns-controller:latest .

# Or push to your registry
docker build -t your-registry/mikrotik-dns-controller:latest .
docker push your-registry/mikrotik-dns-controller:latest
```

### Step 2: Configure MikroTik Credentials

Edit `k8s/deployment.yaml` and update the secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mikrotik-credentials
  namespace: mikrotik-dns-controller
type: Opaque
stringData:
  host: "192.168.88.1"           # Your MikroTik IP
  username: "admin"              # MikroTik username
  password: "YOUR_PASSWORD"      # MikroTik password
  insecure: "true"               # Set to "false" if using valid SSL cert
```

### Step 3: Create Docker Registry Secret

If pushing to a private registry (e.g., ghcr.io), create an image pull secret:

```bash
# First login locally (one-time)
docker login ghcr.io

# Create Kubernetes secret from your local config
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_USERNAME \
  --docker-email=your-email@example.com \
  -n mikrotik-dns-controller \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json
```

The deployment already includes `imagePullSecrets: [ghcr-secret]`, so this enables authentication.

### Step 4: Deploy RBAC and Controller

```bash
# Create namespace, RBAC, and service account
kubectl apply -f k8s/rbac.yaml

# Deploy the controller
kubectl apply -f k8s/deployment.yaml

# Verify deployment
kubectl get pods -n mikrotik-dns-controller
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller
```

## Usage

### Annotate Your Services

Add annotations to LoadBalancer services to enable DNS management:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # Enable automatic DNS management
    dns.mikrotik/enabled: "true"
    # Hostname to create in MikroTik DNS
    dns.mikrotik/hostname: "my-app.internal.bellee.net"
    # Optional: Custom comment (default: "Managed by Kubernetes MikroTik DNS Controller")
    dns.mikrotik/comment: "My application service"
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

### Example: Colour Servers

Update your existing services:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: colourserver-green
  namespace: default
  labels:
    bgp: public
  annotations:
    dns.mikrotik/enabled: "true"
    dns.mikrotik/hostname: "colourserver-green.internal.bellee.net"
spec:
  type: LoadBalancer
  selector:
    app: colourserver-green
  ports:
  - port: 80
    targetPort: 80
```

Apply it:

```bash
kubectl apply -f k8s/example-services.yaml
```

Watch the controller logs:

```bash
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller
```

You should see:

```
Adding/updating DNS entry: colourserver-green.internal.bellee.net -> 172.16.0.0
Successfully synced service default/colourserver-green to MikroTik DNS
```

### Verify DNS Entry

On the MikroTik router, check the static DNS entries:

```
[admin@MikroTik] /ip/dns/static> print
Flags: X - disabled; D - dynamic
 #   NAME                           ADDRESS         TTL COMMENT
 0   colourserver-green.int...      172.16.0.0              Managed by Kubernetes...
 1   colourserver-blue.internal...  172.16.0.1              Managed by Kubernetes...
```

Or test DNS resolution:

```bash
nslookup colourserver-green.internal.bellee.net 192.168.88.1
```

## Annotations Reference

| Annotation | Required | Values | Example |
|---|---|---|---|
| `dns.mikrotik/enabled` | Yes | `"true"` or `"yes"` | `dns.mikrotik/enabled: "true"` |
| `dns.mikrotik/hostname` | Yes (if enabled) | Fully qualified hostname | `dns.mikrotik/hostname: "my-app.internal.bellee.net"` |
| `dns.mikrotik/comment` | No | Text description | `dns.mikrotik/comment: "My app for X"` |

## Architecture & Code Overview

### main.go
- Loads configuration from environment variables
- Creates Kubernetes and MikroTik clients
- Starts the service watcher loop
- Handles graceful shutdown

### mikrotik.go
- `MikroTikClient`: Wrapper around `routeros.Client` for MikroTik API
- Uses **binary socket protocol** (not HTTP) on port 8728/8729
- `AddDNSEntry()`: Creates or updates static DNS entry via `/ip/dns/static/add` or `/ip/dns/static/set`
- `RemoveDNSEntry()`: Deletes DNS entry via `/ip/dns/static/remove`
- `findDNSEntry()`: Searches DNS entries via `/ip/dns/static/print`
- All communication handled by go-routeros which abstracts the MikroTik protocol
- Parses `proto.Sentence` responses with `List` field (slice of `proto.Pair` with Key/Value strings)

### Service Watcher (main.go)
- `ServiceReconciler`: Watches service events
- Processes Added/Modified/Deleted events
- Calls MikroTik API based on service state
- Implements retry logic for failed operations

### Control Flow

```
Watch Event (service changed)
    │
    ├─ Check annotations for enabled flag
    │  └─ If disabled or missing → skip
    │
    ├─ Check Service Type
    │  └─ If not LoadBalancer → skip
    │
    ├─ Extract External IP
    │  └─ If empty → skip (wait for IP assignment)
    │
    ├─ Get hostname from annotation
    │  └─ If missing → skip
    │
    └─ Call MikroTik API
       └─ AddDNSEntry() for Added/Modified events
       └─ RemoveDNSEntry() for Deleted events
```

## Troubleshooting

### Pod won't start - Authentication failed

Check the secret configuration:

```bash
kubectl get secret -n mikrotik-dns-controller mikrotik-credentials -o yaml
```

Verify credentials work outside cluster:

```bash
curl -k -u admin:password https://192.168.88.1:8729/rest/interface
```

### Service has no external IP

Make sure your LoadBalancer is configured (e.g., Cilium BGP):

```bash
kubectl get svc
# Should show external IP in EXTERNAL-IP column
```

### DNS entry not showing up in MikroTik

Check controller logs:

```bash
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller
```

Common issues:
- Service doesn't have LoadBalancer type
- Annotation is missing or misspelled
- Service has no external IP yet
- MikroTik API credentials are wrong

### Check MikroTik API Connectivity

**Note**: MikroTik API uses binary protocol, not HTTP. To verify connectivity:

```bash
# From controller pod:
kubectl logs -n mikrotik-dns-controller deployment/mikrotik-dns-controller

# Should show:
# "Connected to MikroTik successfully"
# "Successfully synced service..."

# Verify DNS entries on router:
ssh -l belstarr 192.168.88.1 "/ip dns static print"
```

**Important**: Do NOT attempt HTTP requests to 8728/8729. They use MikroTik's binary protocol.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MIKROTIK_HOST` | Required | MikroTik router IP or hostname |
| `MIKROTIK_USERNAME` | Required | API username |
| `MIKROTIK_PASSWORD` | Required | API password |
| `MIKROTIK_INSECURE` | `false` | Skip SSL verification (set to `true` for self-signed certs) |

## Performance & Scaling

- **Single Replica**: Designed for single controller instance (watching API)
- **Memory Usage**: ~64-128 MB average
- **API Calls**: One per service state change (low frequency)
- **Latency**: 1-5 seconds from service external IP to DNS entry creation

## Security Considerations

1. **Secrets**: MikroTik credentials stored as Kubernetes Secret
   - Consider using `sealed-secrets` or `external-secrets` for production
   
2. **RBAC**: Controller only reads services (watch permission)
   - Cannot modify services or other resources
   
3. **Network**: Ensure firewall allows cluster → MikroTik API access
   - Default ports: 8728 (plain) or 8729 (SSL)

4. **SSL**: Use `MIKROTIK_INSECURE=false` with valid certificates in production
   - Note: `MIKROTIK_INSECURE=true` still uses encrypted protocol via routeros (port 8729 default)
   - False disables TLS verification; set to false and verify your certificates in production

## Building for Production

### Multi-arch Image

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t your-registry/mikrotik-dns-controller:latest \
  --push .
```

### Private Registry

First, create the image pull secret:

```bash
# Login to your registry
docker login your-registry.io

# Create Kubernetes secret
kubectl create secret docker-registry regcred \
  --docker-server=your-registry.io \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD \
  --docker-email=your-email@example.com \
  -n mikrotik-dns-controller
```

Then update deployment to reference it:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
      - name: regcred
      containers:
      - image: your-registry/mikrotik-dns-controller:v1.0.0
```

## Testing

### Local Testing

```bash
# Build
go build -o mikrotik-dns-controller .

# Test configuration
export MIKROTIK_HOST=192.168.88.1
export MIKROTIK_USERNAME=admin
export MIKROTIK_PASSWORD=password
export MIKROTIK_INSECURE=true

# Run locally (requires kubectl access)
./mikrotik-dns-controller
```

### Integration Testing

```bash
# Deploy example services
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/example-services.yaml

# Watch logs
kubectl logs -n mikrotik-dns-controller -f deployment/mikrotik-dns-controller

# Check MikroTik
ssh admin@192.168.88.1
/ip/dns/static> print
```

## Limitations

- Only manages static DNS entries (not dynamic DNS)
- Requires LoadBalancer service type
- One controller instance recommended (no leader election yet)
- No automatic conflict resolution for duplicate hostnames

## Implementation Details

### MikroTik Binary Protocol

This controller communicates with MikroTik using the binary API protocol (not REST):

- **Protocol**: MikroTik proprietary binary format
- **Encoding**: Length-prefixed words with key=value pairs
- **Port**: 8728 (unencrypted) or 8729 (TLS encrypted)
- **Library**: [go-routeros/routeros v3.0.1+](https://github.com/go-routeros/routeros)

Example API call structure:
```go
reply, err := conn.RunContext(ctx,
  "/ip/dns/static/add",           // API path
  "=name=example.com",             // name attribute
  "=address=192.168.1.1",          // address attribute
  "=comment=My DNS entry",          // comment attribute
)
// Parses proto.Sentence.List ([]proto.Pair) responses
```

### Response Parsing

MikroTik returns `proto.Sentence` objects where:
- `Sentence.List`: Array of `proto.Pair` with `Key` and `Value` string fields
- `Sentence.Tag`: Optional transaction identifier
- `Sentence.Word`: Command word (e.g., ".tag", ".done", ".ret")

## Future Enhancements

- [ ] Leader election for HA setup
- [ ] Webhook validation for annotations
- [ ] Metrics exposure (Prometheus)
- [ ] Support for DNS record types (A, AAAA, etc.)
- [ ] Automatic TTL management
- [ ] Service deletion protection
- [ ] Custom DNS zones support

## License

MIT

## Contributing

Feel free to extend and customize this controller for your needs!
