# MikroTik DNS Controller for Kubernetes

A custom Kubernetes controller that manages MikroTik RouterOS DNS entries from
opted-in LoadBalancer Services and HTTPRoutes attached to ready Gateways.

## How It Works

This controller watches Services, Gateways, HTTPRoutes and Namespace labels,
reconciles an initial full inventory, and retries router failures. Existing
Service annotations continue to work. HTTPRoutes supply concrete hostnames;
accepted parent Gateways supply IPv4 addresses.

The original Service flow is:

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
- ✅ **Gateway API**: Opted-in HTTPRoute hostnames resolve to accepted parent Gateway addresses
- ✅ **Safe Cleanup**: Shared hostname claims and persistent controller ownership markers
- ✅ **RBAC Secured**: Read-only access to Services, Namespaces, Gateways and HTTPRoutes
- ✅ **Error Recovery**: Automatically retries failed API calls
- ✅ **Namespace Agnostic**: Watches services across all namespaces

## Prerequisites

1. **Kubernetes Cluster** with LoadBalancer (Cilium BGP or similar)
2. **MikroTik RouterOS v6+** with:
   - API service enabled (port 8728 for unencrypted, 8729 for SSL)
   - User with permissions to manage `/ip/dns/static` entries
   - Network connectivity on API ports
3. **Network Access** from cluster to MikroTik API (TCP port 8728 or 8729)
4. **Gateway API v1 CRDs** for `Gateway` and `HTTPRoute` to enable route discovery.
   If both are absent, the controller explicitly logs Service-only mode. Restart
   it after installing the CRDs. Partial installations, API errors and missing
   RBAC fail startup rather than using a partial inventory for deletion.

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
Synced DNS hostname colourserver-green.internal.bellee.net -> 172.16.0.0 (Service/default/colourserver-green)
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

### HTTPRoute discovery

Opt in on the HTTPRoute, not on the Gateway's generated Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: blue
  namespace: default
  annotations:
    dns.mikrotik/enabled: "true"
    dns.mikrotik/comment: "Blue application through Cilium Gateway"
spec:
  parentRefs:
    - name: shared-gateway
      sectionName: https
  hostnames:
    - blue.gateway
  rules:
    - backendRefs:
        - name: colourserver-blue
          port: 80
```

`dns.mikrotik/hostname` is **not used on HTTPRoutes**: `spec.hostnames` is the
source of DNS names. Multiple concrete names are supported. A Gateway listener
hostname is a constraint, not an independently published record.

Publication requires current-generation HTTPRoute `Accepted=True` and
`ResolvedRefs=True` status for a declared parent, current Gateway
`Accepted=True`/`Programmed=True` status, and a matching accepted/programmed
HTTP/HTTPS listener. Parent namespace, section and port, listener hostname
intersection, allowed route kinds, and `allowedRoutes.namespaces`
(`Same`, `All`, or label `Selector`) are checked. Namespace label changes also
trigger reconciliation.

For Gateway discovery, only `IPAddress` IPv4 addresses are supported.
Wildcard/omitted route hostnames and Gateway hostname/IPv6 addresses are
explicitly logged and skipped. A concrete name can match a wildcard listener.
If accepted parents produce different IPv4 addresses, publication is considered
a conflict: no arbitrary address is selected.

### Ownership, duplicate hostnames and deletion

- Services and routes are reconciled together. Multiple resources can claim the
  same hostname/address; deleting one does not remove another's record.
- Different addresses for one name, or duplicate RouterOS records for that name,
  are logged and left unchanged. This version maintains one record per name;
  it does not implement DNS round-robin across Gateways.
- New/adopted records have comments prefixed with `[k8s-mikrotik-dns] `.
  The original description follows the prefix.
- Only marked records with no remaining desired claimant are deleted. This
  handles opt-out, rename, route/Gateway removal, lost acceptance and restarts.
- Unmarked legacy records are adopted only if their existing comment exactly
  matches a current claimant's expected comment. Other unmarked records are
  preserved, including manual DNS entries. Retain the old comment during
  migration; inspect and resolve mismatches manually rather than deleting records.
- First let the new controller adopt legacy records while their old Service
  opt-ins still exist. Legacy records whose resources disappeared before
  adoption cannot be safely identified for automatic cleanup.
- Run one controller instance managing this router inventory. The ownership
  prefix is not a multi-cluster partition or leader-election mechanism.

Watch events enqueue full reconciliation; a one-minute refresh detects router
drift. API failures are returned and retried with rate limiting. Unchanged
records are not rewritten.

### Roll out the route-aware controller

The new binary must be published/deployed; editing manifests alone does not
upgrade the running image.

1. Install Gateway API CRDs if absent.
2. Apply/reconcile the updated RBAC **before** rolling out the new image:

   ```bash
   kubectl apply -f gitops/platform/mikrotik-dns-controller/rbac.yaml
   ```

3. Build and publish the image using the existing workflow or the build commands
   above. Prefer an immutable image tag in the deployment. If using the existing
   `latest` tag, wait for the image build to succeed before restarting:

   ```bash
   kubectl -n mikrotik-dns-controller rollout restart deployment/mikrotik-dns-controller
   kubectl -n mikrotik-dns-controller rollout status deployment/mikrotik-dns-controller --timeout=5m
   kubectl -n mikrotik-dns-controller logs deployment/mikrotik-dns-controller --tail=100
   ```

   A Running pod alone does not prove cache sync or DNS reconciliation succeeded.
   Verify successful sync logs and router records. Wait for old controller pods
   to terminate before switching discovery ownership.

4. Apply/reconcile the updated
   [pilot](../gitops/apps/colour-server/blue-gateway.yaml). It removes DNS
   annotations from `Gateway.spec.infrastructure` and adds opt-in/comment
   annotations to the HTTPRoute. The existing comment is retained for adoption.
   The `bgp: public` Service label stays in place.
5. Verify the generated Service no longer has DNS opt-in annotations, the route
   is accepted, and `colourserver-blue.gateway` resolves to the current Gateway
   address through MikroTik DNS. Test a new route hostname or Gateway address
   change before relying on the new discovery path for production.

Apply the RBAC/controller rollout before route opt-in changes when managing
these resources through Flux as well. If the generated Service retains old DNS
annotations, remove those stale annotations after checking its owner and the
route's successful DNS claim.

## Annotations Reference

| Annotation | Required | Values | Example |
|---|---|---|---|
| `dns.mikrotik/enabled` | Yes, on Service or HTTPRoute | `"true"` or `"yes"` | `dns.mikrotik/enabled: "true"` |
| `dns.mikrotik/hostname` | Services only, if enabled | Concrete hostname; HTTPRoutes use `spec.hostnames` | `dns.mikrotik/hostname: "my-app.internal.bellee.net"` |
| `dns.mikrotik/comment` | No | Text description | `dns.mikrotik/comment: "My app for X"` |

## Architecture & Code Overview

### main.go
- Loads configuration from environment variables
- Creates Kubernetes and MikroTik clients
- Starts the shared informer reconciliation loop
- Handles graceful shutdown

### mikrotik.go
- `MikroTikClient`: Wrapper around `routeros.Client` for MikroTik API
- Uses **binary socket protocol** (not HTTP) on port 8728/8729
- `ListDNSEntries()`: Reads the RouterOS inventory, including ownership comments
- `SetDNSEntry()`: Creates or updates a record using its RouterOS ID
- `DeleteDNSEntry()`: Deletes an owned orphan using its RouterOS ID
- All communication handled by go-routeros which abstracts the MikroTik protocol
- Parses `proto.Sentence` responses with `List` field (slice of `proto.Pair` with Key/Value strings)

### controller.go and gateway.go
- Shared informers relist/reconnect and enqueue one serialized reconciliation
- Service and route claims are resolved against a shared DNS inventory
- Gateway acceptance, listener constraints and namespace selection are checked
- Ownership survives process restarts in RouterOS comments

### Control Flow

```
Watch Event (Service, HTTPRoute, Gateway or Namespace changed)
    │
    ├─ Check annotations for enabled flag
    │  └─ If disabled or missing → skip
    │
    ├─ Collect opted-in Service and accepted HTTPRoute claims
    ├─ Resolve Gateway/listener constraints and addresses
    ├─ Coalesce shared names and detect conflicting addresses
    │
    └─ Reconcile RouterOS inventory
       ├─ Create/update desired records
       └─ Delete only owned records with no remaining claim
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
# "DNS inventory caches synced; starting reconciliation"
# "Synced DNS hostname ..."

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
- **API Calls**: One inventory read per reconciliation, plus changed records
- **Refresh**: Watch events plus a one-minute inventory refresh

## Security Considerations

1. **Secrets**: MikroTik credentials stored as Kubernetes Secret
   - Consider using `sealed-secrets` or `external-secrets` for production
   
2. **RBAC**: Controller reads Services, Namespaces, Gateways and HTTPRoutes
   - Cannot modify Kubernetes resources
   
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
