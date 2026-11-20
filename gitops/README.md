# Flux GitOps Bootstrap

This folder contains a minimal Flux GitOps scaffold for this repository.

## Session Notes

For a summary of today's infrastructure and GitOps changes, see:

- [CHANGES-2026-07-09.md](../CHANGES-2026-07-09.md)

## Current Scope

Flux bootstrap points at this cluster entrypoint:

- `gitops/clusters/kube-cluster-01/kustomization.yaml`

That entrypoint composes two layers:

- `gitops/platform/kustomization.yaml`
- `gitops/apps/kustomization.yaml`

Current layer content:

- Platform: Cilium BGP resources under `gitops/platform/cilium-bgp/`
- Apps: Colour server manifests under `gitops/apps/colour-server/`

Note: Keep Flux-managed manifests under `gitops/` so Kustomize path restrictions are satisfied.

## Recommended Layout

- `gitops/clusters/<cluster-name>/`: per-cluster composition and overrides
- `gitops/platform/`: cluster services, networking, policy, observability
- `gitops/apps/`: application workloads

Keep cluster files small and use them to compose reusable layers.

## Prerequisites

Install and configure:

- `kubectl` with context set to this cluster
- `flux` CLI
- GitHub token with repo write access

Quick checks:

```bash
kubectl config current-context
flux --version
flux check --pre
```

## Bootstrap

Option A: Run helper script

```bash
export GITHUB_TOKEN=<token>
export GITHUB_OWNER=<your-github-user-or-org>
./gitops/scripts/bootstrap_flux.sh
```

Optional environment overrides:

- `REPO_NAME` (default: `k8s-cluster`)
- `BRANCH` (default: `main`)
- `CLUSTER_PATH` (default: `gitops/clusters/kube-cluster-01`)

Option B: Run bootstrap command directly

```bash
flux bootstrap github \
  --owner=<your-github-user-or-org> \
  --repository=k8s-cluster \
  --branch=main \
  --path=gitops/clusters/kube-cluster-01 \
  --personal
```

## Verify Reconciliation

```bash
flux get all -A
kubectl get kustomizations -A
kubectl get gitrepositories -A
```

## Migration Strategy

1. Keep Terraform/Ansible as day-0 provisioning.
2. Move day-2 Kubernetes resources into GitOps Kustomizations.
3. Replace imperative install scripts with declarative manifests/Helm releases.
4. Add encrypted secrets with SOPS when secret management is migrated.

## Photo Gateway API migration

The photo stack uses the Cilium Gateway in
[`apps/photo-stack/photo-gateway.yaml`](./apps/photo-stack/photo-gateway.yaml):

- `photo.internal.bellee.net` retains its hostname and internal-CA HTTPS.
- `/api` routes to `photo-api:8080`; `/` routes to `photo-spa:80`, without
  rewriting paths.
- HTTP redirects to HTTPS with status 308.
- The generated LoadBalancer Service retains `bgp: public`.
- The HTTPS HTTPRoute owns MikroTik DNS discovery. Its comment intentionally
  matches the old nginx Service comment so legacy DNS records can be adopted.
- A separate `photo-gateway-tls` Secret is issued by an explicit Certificate.
  The old `photo-spa-tls` Certificate is owned by the Ingress and can be
  garbage-collected when Flux prunes that Ingress.
- The nginx-specific 100 MiB request-body cap is removed. Gateway defaults and
  backend limits apply; this configuration does not enforce an equivalent cap.

The nginx controller remains installed, but no longer advertises the photo
hostname through its Service annotations. Its eventual removal is separate.
The photo API's independent LoadBalancer/DNS configuration is unchanged.

### Staged live rollout

These are operator steps; editing these files does not perform the migration.
Stage the Gateway **before pushing the final GitOps changes**, so the old
Ingress can continue serving traffic until the replacement is verified:

1. Confirm the route-aware MikroTik DNS controller is deployed and healthy
   (see [controller rollout](../mikrotik-dns-controller/README.md#roll-out-the-route-aware-controller)).
2. From the repository root, create only the new Gateway resources:

   ```bash
   kubectl apply -f gitops/apps/photo-stack/photo-gateway.yaml
   kubectl -n photo wait certificate/photo-gateway --for=condition=Ready --timeout=2m
   kubectl -n photo wait gateway/photo-gateway --for=condition=Programmed --timeout=2m
   kubectl -n photo get httproute photo photo-http-redirect -o yaml
   ```

   Both routes must have current `Accepted=True` and `ResolvedRefs=True` parent
   conditions. While both nginx and the Gateway claim the same hostname at
   different addresses, the DNS controller deliberately logs a conflict and
   leaves the existing DNS record unchanged.
3. Test the new Gateway directly, without changing DNS:

   ```bash
   GATEWAY_IP=$(kubectl -n photo get gateway photo-gateway -o jsonpath='{.status.addresses[0].value}')
   curl --fail --cacert internal-ca.crt \
     --resolve "photo.internal.bellee.net:443:$GATEWAY_IP" \
     https://photo.internal.bellee.net/
   curl --head --resolve "photo.internal.bellee.net:80:$GATEWAY_IP" \
     http://photo.internal.bellee.net/
   ```

   Verify the SPA, a known API endpoint and a representative upload through the
   Gateway. Confirm the HTTP response is a 308 redirect to HTTPS.
4. Commit/push the final manifests and reconcile Flux. The platform HelmRelease
   removes the nginx Service DNS annotations; the accepted HTTPS HTTPRoute
   becomes the sole DNS claimant. The apps Kustomization prunes `photo/photo-spa`
   Ingress. Keep the nginx controller available during DNS cache expiry.
5. Verify the hostname resolves to the Gateway address through the cluster's
   MikroTik resolver, repeat the SPA/API/upload checks without `--resolve`, and
   confirm `kubectl get ingress -A` no longer lists the photo Ingress.

If staging fails, leave the original Ingress and nginx DNS claim in place and
do not push the cutover. After cutover, rollback requires restoring the old
Ingress and nginx Service DNS annotations and disabling the HTTPRoute DNS
opt-in, so only one address is claimed. Verify DNS and HTTPS again.
