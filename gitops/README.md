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
