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

## Flux CLI quick guide

Commands use the current kubeconfig context. Check it with
`kubectl config current-context` before making changes.

### Check status or watch a rollout

```bash
flux get all -A
flux get sources git -A
flux get helmreleases -A
flux get kustomizations -A --watch
```

Look for `READY=True`, `SUSPENDED=False`, and the expected Git revision.
Press Ctrl+C to stop watching.

### Apply pushed Git changes immediately

Flux reads the remote repository, not local edits: commit and push first.

```bash
flux reconcile kustomization platform -n flux-system --with-source
flux reconcile kustomization apps -n flux-system
```

`--with-source` fetches the latest source before applying manifests. Apps depend
on platform health, so fix platform failures first. For TLS manifests, use
`flux reconcile kustomization tls -n flux-system --with-source`.
For cluster composition changes, reconcile the `flux-system` Kustomization.

### Reconcile a Helm release

After Flux has applied the HelmRelease values from Git, trigger its Helm action:

```bash
flux reconcile helmrelease grafana -n monitoring
flux get helmreleases -n monitoring
```

Add `--with-source` to refresh the release's chart source too; this does not
fetch updated HelmRelease values from this repository.

### Diagnose a failure

```bash
flux get kustomizations -A --status-selector ready=false
flux logs --all-namespaces --level=error --since=10m
flux logs --kind=HelmRelease --name=grafana -n monitoring --since=10m
kubectl -n monitoring describe helmrelease grafana
```

Logs can contain historical failures; compare timestamps with current status.
After fixing the cause of an exhausted Helm retry count, reset and retry:

```bash
flux reconcile helmrelease grafana -n monitoring --reset
```

### Pause and resume reconciliation

For temporary Helm troubleshooting:

```bash
flux suspend helmrelease grafana -n monitoring
flux resume helmrelease grafana -n monitoring
```

To pause manifest application instead, use
`flux suspend kustomization apps -n flux-system`, then the corresponding
`flux resume kustomization apps -n flux-system`.
Suspending a Kustomization does not stop existing HelmReleases or workloads.
Parent GitOps reconciliation may overwrite manual suspension; declare
`spec.suspend: true` in Git if the pause must persist, and remove it to resume.

### Roll back or remove a resource

- **Rollback:** revert the relevant Git commit, push, then reconcile the owning
  Kustomization. Manual `helm rollback` is not durable under Flux management.
- **Removal:** remove the resource from its Kustomize resources, commit and
  push. With pruning enabled, Flux deletes it; deleting a HelmRelease triggers
  Helm uninstall. Check persistent data retention before removing workloads.

## Grafana dashboard metrics

The Kubernetes dashboards expect a `node` label on kubelet/cAdvisor metrics.
The Prometheus HelmRelease adds it through the node scrape jobs' relabel rules.
The API-server scrape job uses `job_name: apiserver` to match that dashboard's
selectors. Queries for older data must use the previous
`job="kubernetes-api-servers"` label.
CoreDNS targets in `kube-system/kube-dns` are selectively relabeled to
`job="coredns"` for the CoreDNS dashboard; other Service scrape jobs are unchanged.
Grafana's Prometheus datasource sets `timeInterval: 1m` to match Prometheus'
scrape interval, so `$__rate_interval` uses a sufficiently long window.
Keep these intervals aligned when changing scrape frequency.

After pushing changes, reconcile `platform`, then the `prometheus` and `grafana`
HelmReleases in `monitoring`. Allow several scrapes before refreshing dashboards.
Persistent-volume panels can still show **No data** when the storage provider
does not expose `kubelet_volume_stats_*` metrics, or no supported PVC is mounted
on the selected node. Installing dashboards does not supply these metrics.

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

## Grafana Gateway API migration

[`platform/monitoring/grafana-gateway.yaml`](./platform/monitoring/grafana-gateway.yaml)
exposes `https://grafana.internal.bellee.net` using Cilium, an internal-CA
Certificate, and an HTTP-to-HTTPS 308 redirect. The HTTPS HTTPRoute owns DNS,
retaining the old Service's comment for DNS record adoption. The generated
Gateway Service has `bgp: public`; the Grafana backend becomes ClusterIP and no
longer reserves `172.16.0.10`. Grafana's public root URL uses HTTPS and session
cookies are secure; TLS terminates at the Gateway, not the backend.

Before pushing the cutover, stage the new resources:

```bash
kubectl apply -f gitops/platform/monitoring/grafana-gateway.yaml
kubectl -n monitoring wait certificate/grafana-gateway --for=condition=Ready --timeout=2m
kubectl -n monitoring wait gateway/grafana-gateway --for=condition=Programmed --timeout=2m
kubectl -n monitoring get httproute grafana grafana-http-redirect -o yaml
GATEWAY_IP=$(kubectl -n monitoring get gateway grafana-gateway -o jsonpath='{.status.addresses[0].value}')
curl --fail --cacert internal-ca.crt \
  --resolve "grafana.internal.bellee.net:443:$GATEWAY_IP" \
  https://grafana.internal.bellee.net/api/health
curl --head --resolve "grafana.internal.bellee.net:80:$GATEWAY_IP" \
  http://grafana.internal.bellee.net/
```

Verify both routes have current `Accepted=True` and `ResolvedRefs=True` parent
conditions. While the old Service still claims the hostname, DNS conflicts
are expected and the existing record is preserved. After committing/pushing,
Flux upgrades Grafana, changes its Service to ClusterIP, and removes the old
Service DNS claim. Verify DNS resolves to the new Gateway IP and test login,
dashboards and Grafana Live over HTTPS. Clients caching `172.16.0.10` must
refresh DNS; that old address stops serving Grafana when the Service changes.
Allow for a brief cutover interruption.

Grafana currently has persistence disabled. The configuration change rolls
its pod, so export any non-provisioned dashboards/settings before rollout;
ephemeral database contents may be lost.

If staging fails, do not push the cutover. To roll back after cutover, restore
the old HelmRelease Service/configuration values and disable the HTTPS
HTTPRoute's DNS opt-in so it no longer competes with the restored LoadBalancer.
Verify DNS and access again.
