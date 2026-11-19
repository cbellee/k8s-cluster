# Cilium Gateway API installation and blue application pilot

## Outcome

Configured on 19 November 2026 after the
[Cilium upgrade and kube-proxy removal](./cilium-upgrade.md):

- Gateway API v1.6.3 standard CRDs installed.
- Cilium 1.20.5 Gateway API controller enabled.
- HTTPS application access at `https://colourserver-blue.gateway`.
- TLS terminated by Cilium Envoy using a cert-manager certificate.
- BGP advertisement through the generated Gateway LoadBalancer Service and
  MikroTik DNS integration (initially through Service annotations).
- macOS browser trust established by importing the internal CA and correcting
  the application certificate's TLS usage.

The operator confirmed the application worked, then confirmed browser trust
worked after the certificate correction. Existing ingress-nginx resources and
the blue application's original LoadBalancer access were left unchanged.

Commands assume Bash and the repository root unless identified as Mac commands.
These activities are complete; use the steps as a record or for a deliberate
reinstallation, not as instructions to rerun everything.

## Architecture

```text
Browser: https://colourserver-blue.gateway
  |
  +-- MikroTik DNS -> Gateway LoadBalancer IP
  |
  +-- MikroTik route learned through BGP
        |
        +-- Cilium node -> per-node Envoy (TLS termination)
              |
              +-- HTTPRoute -> default/colourserver-blue:80
                    |
                    +-- blue colour server pod
```

Gateway API supplies the configuration objects; Cilium supplies the controller,
eBPF integration and Envoy data plane:

| Resource | Purpose in this pilot |
| --- | --- |
| `GatewayClass/cilium` | Selects controller `io.cilium/gateway-controller` |
| `Gateway` | HTTPS listener, hostname, certificate reference and Service metadata |
| `HTTPRoute` | Routes `/` to the existing blue Service on port 80 |
| `Certificate` | Requests a server certificate from `ClusterIssuer/internal-ca` |

The Certificate, Gateway and HTTPRoute are all named
`colourserver-blue-gateway` in namespace `default`. The certificate Secret is
`colourserver-blue-gateway-tls`.

The backend is the existing Service, not the Deployment directly. Its
LoadBalancer type does not prevent Gateway API from using it as a backend.
The Gateway provides a separate address and entry point.

## Prerequisites

- Cilium 1.20.5 healthy on all six nodes.
- `kubeProxyReplacement: true`.
- L7 proxy enabled (`l7Proxy: true`, the chart default).
- Working Cilium LoadBalancer IPAM and BGP peering with MikroTik.
- cert-manager and a ready `internal-ca` ClusterIssuer.
- Blue colour server Deployment and Service in `default`.
- Clients using MikroTik DNS, or a resolver forwarding the relevant names to it.

The default Gateway proxy path uses iptables TPROXY and its kernel modules.
Removing kube-proxy does **not** mean iptables can be removed or flushed.

Check existing components:

```bash
cilium status --wait
kubectl get clusterissuer internal-ca
kubectl -n default get deployment colourserver-blue-deployment
kubectl -n default get service colourserver-blue
```

## 1. Install Gateway API CRDs

Installed the v1.6.3 **standard** bundle:

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

Verify the required definitions:

```bash
kubectl wait --for=condition=Established --timeout=60s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/grpcroutes.gateway.networking.k8s.io \
  crd/referencegrants.gateway.networking.k8s.io \
  crd/backendtlspolicies.gateway.networking.k8s.io \
  crd/tlsroutes.gateway.networking.k8s.io
```

All must report `condition met`. The installed bundle annotation was checked and
reported `v1.6.3`.

Installing CRDs alone does not install a controller or change application
routing. No old TLSRoutes existed, so the experimental-channel compatibility
path described in the Cilium 1.20 upgrade guide was not needed.

## 2. Enable Cilium's Gateway controller

Added this to the canonical
[Cilium values](../ansible/cilium/cilium-values.yaml):

```yaml
gatewayAPI:
  enabled: true
```

The file retains BGP, kube-proxy replacement, the explicit API endpoint, existing
IPAM settings and Hubble configuration. The chart version stays at 1.20.5.

The updated chart was rendered before application. GatewayClass creation is
conditional on discovery of the Gateway API; offline `helm template` checks
must represent the installed APIs:

```bash
helm template cilium cilium \
  --repo https://helm.cilium.io \
  --version 1.20.5 \
  --namespace kube-system \
  --api-versions gateway.networking.k8s.io/v1 \
  --api-versions gateway.networking.k8s.io/v1/GatewayClass \
  --values tf-k8s-cluster/ansible/cilium/cilium-values.yaml
```

Apply the values, then restart the operator and agents as directed by the Cilium
installation guide. Restarting agents can briefly disrupt proxy-handled traffic.

```bash
helm upgrade cilium cilium \
  --repo https://helm.cilium.io \
  --namespace kube-system \
  --version 1.20.5 \
  --reset-values \
  --values tf-k8s-cluster/ansible/cilium/cilium-values.yaml \
  --wait --timeout 10m

kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m

kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m

cilium status --wait
kubectl get gatewayclass
```

The `cilium` GatewayClass must show `ACCEPTED=True`; this was verified before
preparing the pilot.

## 3. Prepare the application resources

The complete manifest is
[blue-gateway.yaml](../../gitops/apps/colour-server/blue-gateway.yaml).
It is included in the
[apps kustomization](../../gitops/apps/kustomization.yaml).
The manifest now uses HTTPRoute DNS discovery; deploy the updated DNS controller
and RBAC as described in [Route-aware DNS migration](#route-aware-dns-migration)
before applying that change. The original pilot steps below record the earlier
Service-annotation setup.

### Certificate

The Certificate requests `colourserver-blue.gateway` from
`ClusterIssuer/internal-ca`, storing the result in
`colourserver-blue-gateway-tls`.

Specify TLS server usage explicitly:

```yaml
usages:
  - digital signature
  - key encipherment
  - server auth
```

The original pilot omitted `server auth`. Its hostname and CA signature verified
with OpenSSL, but its served certificate lacked the explicit TLS Web Server
Authentication extended key usage. macOS Chrome still marked the connection
untrusted. Adding `server auth`, applying the manifest and reissuing the
certificate resolved the browser problem.

The explicit Certificate avoids depending on cert-manager's optional Gateway
annotation integration.

### Gateway

The Gateway selects class `cilium` and listens on HTTPS port 443 for
`colourserver-blue.gateway`. It references the certificate Secret above and
accepts routes only from the same namespace.

Metadata for Cilium's generated LoadBalancer Service is configured under
`spec.infrastructure`:

```yaml
infrastructure:
  labels:
    bgp: public
  annotations:
    dns.mikrotik/enabled: "true"
    dns.mikrotik/hostname: colourserver-blue.gateway
    dns.mikrotik/comment: "Cilium Gateway pilot for colour server blue"
```

Both pieces matter:

- The existing [BGP advertisement](../../gitops/platform/cilium-bgp/cilium-bgp-advertisement.yaml)
  selects Services labeled `bgp: public` and advertises their LoadBalancer IPs.
- The [MikroTik DNS controller](../../mikrotik-dns-controller/main.go) watches
  annotated LoadBalancer Services. It does not need Gateway/HTTPRoute watching
  for the original pilot because the Gateway propagates these annotations to its
  Service. The later route-aware migration removes this annotation block.

Cilium allocates an IP from the existing `172.16.0.0/16` pool. The pilot address
observed during certificate troubleshooting was `172.16.0.2`; discover its current
address rather than hard-coding that historical allocation.

### HTTPRoute and backend

The HTTPRoute attaches to the Gateway's `https` listener and routes `PathPrefix`
`/` for the pilot hostname to Service `colourserver-blue`, port `80`.

Service ports are used in `backendRefs`, not Deployment/container names. Since
all resources and the backend are in `default`, no cross-namespace
`ReferenceGrant` is needed.

The original [blue application](../../gitops/apps/colour-server/blue.yaml) remains
unchanged, including its original hostname
`colourserver-blue.internal.bellee.net` and LoadBalancer access.

## 4. Validate and apply the pilot

Before application, both server-side dry-run and the apps Kustomize build passed:

```bash
kubectl apply --dry-run=server \
  -f gitops/apps/colour-server/blue-gateway.yaml

kubectl kustomize gitops/apps
```

Apply:

```bash
kubectl apply -f gitops/apps/colour-server/blue-gateway.yaml
```

Verify:

```bash
kubectl -n default get certificate,gateway,httproute
kubectl -n default describe certificate colourserver-blue-gateway
kubectl -n default describe gateway colourserver-blue-gateway
kubectl -n default describe httproute colourserver-blue-gateway
kubectl -n default get service -l bgp=public
```

Expected conditions:

- Certificate: `Ready=True`.
- Gateway: `Accepted=True`, `Programmed=True`, and an assigned address.
- HTTPRoute: `Accepted=True` and `ResolvedRefs=True` for its parent.

Open `https://colourserver-blue.gateway` from a client using the appropriate DNS
resolver. The operator confirmed the blue application loaded successfully.

Commit/push the manifest and kustomization change so Flux retains the resources.
Do not rely only on a manual apply if GitOps manages the same application.

## 5. Trust the internal CA on a Mac

Trust the **root CA**, not the individual website certificate. Importing the CA
allows certificates issued by that CA to authenticate websites on the Mac.
Only do this on devices intended to trust the cluster's internal PKI.

### Export the public root certificate

The [root CA Certificate](../../gitops/tls/root-ca-certificate.yaml) stores its
certificate and key in Secret `cert-manager/internal-ca`.
Export **only the public certificate**:

```bash
kubectl -n cert-manager get secret internal-ca \
  -o jsonpath='{.data.tls\.crt}' |
  openssl base64 -d -A > internal-ca.crt

openssl x509 -in internal-ca.crt \
  -noout -subject -issuer -dates -fingerprint -sha256
```

Never export or transfer `tls.key`. Keep the exported certificate out of source
control unless there is a deliberate PKI distribution policy.

### Copy to the Mac

Run on the Mac, replacing `<linux-host>` with the reachable Linux hostname or IP.
This assumes the certificate was exported from the repository root:

```bash
scp chris@<linux-host>:/home/chris/repos/k8s-cluster/internal-ca.crt ~/Downloads/

openssl x509 -in ~/Downloads/internal-ca.crt \
  -noout -fingerprint -sha256
```

Compare the fingerprint through a trusted channel with the original export.
Do not rely on the CA's common name alone; a renewed CA can have the same name.
Do not bypass SSH host-key warnings to transfer it.

### Import into Keychain Access

1. Open **Keychain Access** and select the **System** keychain.
2. Use **File -> Import Items** to import `internal-ca.crt`.
3. Open the imported `internal-ca` certificate and expand **Trust**.
4. Set **Secure Sockets Layer (SSL)** to **Always Trust**.
5. Close the window and authenticate.
6. Fully quit Chrome or Safari, then reopen the browser.

Firefox may require a separate CA import under **Settings -> Privacy & Security
-> Certificates -> View Certificates -> Authorities**.

The pilot ultimately worked with browser trust after the explicit `server auth`
certificate correction. Importing the root alone did not correct the original
leaf certificate's missing usage.

## Troubleshooting

### Separate DNS, routing and certificate failures

On the client:

```bash
nslookup colourserver-blue.gateway
```

Retrieve the current Gateway address:

```bash
kubectl -n default get gateway colourserver-blue-gateway \
  -o jsonpath='{.status.addresses[0].value}{"\n"}'
```

To bypass DNS while retaining hostname/SNI and certificate verification, replace
`<gateway-ip>` with that address and use the exported CA:

```bash
curl --cacert internal-ca.crt \
  --resolve colourserver-blue.gateway:443:<gateway-ip> \
  https://colourserver-blue.gateway/
```

Do not use `curl -k` as evidence that certificate trust is correct.

### Inspect the served certificate

```bash
openssl s_client -connect <gateway-ip>:443 \
  -servername colourserver-blue.gateway </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -dates \
    -ext subjectAltName,extendedKeyUsage
```

Expect the SAN `DNS:colourserver-blue.gateway` and extended usage
`TLS Web Server Authentication`. A valid chain in OpenSSL alone does not prove
every browser-specific certificate requirement or client trust setting is met.

If a Certificate change has been applied, inspect its issuance events and the
served certificate to confirm reissuance and Envoy's updated certificate before
testing again.

### VS Code reported invalid YAML properties

The multi-document manifest initially produced editor errors asking the Gateway
and HTTPRoute for `issuerRef` and `secretName`. Kubernetes server-side validation
passed: VS Code was incorrectly applying the cert-manager Certificate schema to
all three documents.

Added a `yaml-language-server: $schema=...` directive to each document, selecting
the appropriate Certificate, Gateway or HTTPRoute schema from the CRDs catalog.
Editor diagnostics then reported no errors, and server-side validation still
passed. These comments affect editor validation only; no cluster reapplication
is needed solely for schema hints.

## Operational notes

- This pilot is HTTPS-only; no HTTP port 80 listener or redirect was created.
- Existing ingress-nginx and other application entry points are unchanged.
- Gateway TLS terminates at Envoy; the backend hop is HTTP on Service port 80.
- Gateway API CRDs, the enabled controller and `internal-ca` must exist before
  Flux reconciles these app resources. The CRDs were installed manually during
  this activity; declarative CRD lifecycle/dependency management is a follow-up.
- For a shared Gateway, use the route-aware discovery described below so each
  application owns its DNS opt-in rather than maintaining every hostname on the
  Gateway Service.
- Check CA and leaf expiry and plan trusted CA distribution/rotation separately.
  Importing the current CA on a Mac does not automatically trust a replacement CA.

## Route-aware DNS migration

The DNS controller has been extended in source to watch HTTPRoutes, Gateways and
Namespace labels in addition to Services. These code changes do not deploy an
image automatically from a local edit. Follow the
[controller rollout instructions](../../mikrotik-dns-controller/README.md#roll-out-the-route-aware-controller).

The updated pilot:

- Retains `Gateway.spec.infrastructure.labels.bgp: public`.
- Removes the generated Service DNS annotation block shown in the historical
  setup above.
- Annotates the HTTPRoute with `dns.mikrotik/enabled: "true"` and the same comment.
- Uses `HTTPRoute.spec.hostnames` as the DNS names and the accepted/programmed
  Gateway's IPv4 address as their destination.

Deploy RBAC and the new controller image before applying/reconciling the pilot
change. First allow adoption of the existing Service record. Keeping the comment
unchanged permits safe legacy adoption. Do not have the old controller and new
discovery mechanism independently manage the same hostname during rollout.

The new controller requires current acceptance/reference status and listener
hostname/namespace compatibility. It coalesces same-address claims and preserves
records on conflicts. Deletion or opt-out withdraws a record only when no other
resource still claims it; only records marked as controller-owned are deleted.
Wildcard route hostnames and non-IPv4 Gateway addresses are logged and skipped.

## References

- [Cilium 1.20 Gateway API installation](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/)
- [Gateway API v1.6.3 standard bundle](https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml)
- [Gateway API concepts](https://gateway-api.sigs.k8s.io/concepts/api-overview/)
