# vagrant-k8s-cluster

A standalone Vagrant + Ansible solution to:

- Create a new multi-node Kubernetes cluster on QEMU/libvirt.
- Use Cilium as the default and authoritative CNI.
- Optionally perform rolling upgrades for:
  - Node OS replacement (Ubuntu 26.04-based VM recreation).
  - Kubernetes version upgrade.

This folder is intentionally isolated from the existing `k8s-install` solution.

## What is codified from the rollout lessons

This implementation bakes in the operational learnings from the previous upgrade effort:

- Cilium-first readiness checks:
  - Node replacement is not considered complete until both:
    - Kubernetes node is `Ready`.
    - Cilium pod on that node is `Ready`.
- Control-plane endpoint alias choreography:
  - During control-plane replacement, the endpoint alias is remapped to a healthy non-target control-plane node before join.
- Drain fallback for stuck terminating pods:
  - If drain fails, the workflow force-deletes lingering terminating pods (including CoreDNS edge cases seen previously) and retries drain.
- Ubuntu 26.04 bootstrap guardrails:
  - Base image and apt source handling aligned with resolved bootstrap issues.
- containerd + kubeadm defaults:
  - `containerd.io`, `SystemdCgroup=true`, kubeadm-based join/init flows.

## Project layout

- `Vagrantfile`: VM definitions and host bootstrap.
- `.env.example`: environment overrides for image, networking, versions, sizing.
- `hosts`: static host entries copied into guests at provision time.
- `ansible/inventory/hosts.ini`: inventory, endpoint alias, version defaults.
- `ansible/playbooks/kube-dependencies.yml`: base node config + containerd + Kubernetes packages.
- `ansible/playbooks/bootstrap-cluster.yml`: kubeadm init/join and Cilium install.
- `ansible/cilium/cilium-values.yaml`: canonical full Cilium values (captured from the prior working cluster).
- `ansible/cilium/bgp/`: templated Cilium BGP and LB IPAM manifests.
- `ansible/playbooks/refresh-hosts.yml`: endpoint alias refresh for rolling control-plane work.
- `ansible/playbooks/join-worker-node.yml`: worker join for single-node replacement.
- `ansible/playbooks/join-control-plane-node.yml`: control-plane join for single-node replacement.
- `ansible/playbooks/upgrade-k8s-packages.yml`: channel-based package upgrades.
- `scripts/create-cluster.sh`: full fresh-cluster creation workflow.
- `scripts/upgrade-cluster.sh`: rolling OS and/or Kubernetes upgrades.

## Prerequisites

Install these on the host:

- QEMU/KVM + libvirt.
- Vagrant + vagrant-libvirt plugin.
- Ansible.
- SSH key at `~/.ssh/id_rsa.pub`.
- Network bridge configured (default: `br0`) and reachable cluster subnet.

## Configuration

1. Copy environment template:

```bash
cd /home/chris/repos/k8s-cluster/vagrant-k8s-cluster
cp .env.example .env
```

2. Adjust `.env` to match your host and desired cluster shape.

Key values:

- `IMAGE` (default `bento/ubuntu-26.04`)
- `BRIDGE`, `GATEWAYIP`, `DNS0IP`
- `DISKPATH`
- `CP_ENDPOINT_ALIAS`, `CP_ENDPOINT_NODE`, `CP_ENDPOINT_IP`
- `K8S_VERSION`, `K8S_CHANNEL`, `CILIUM_VERSION`
- per-node CPU/RAM/IP settings

3. If you changed node IPs or names, update:

- `hosts`
- `ansible/inventory/hosts.ini`

## Create a new cluster

Run:

```bash
cd /home/chris/repos/k8s-cluster/vagrant-k8s-cluster
./scripts/create-cluster.sh
```

Workflow performed:

1. `vagrant up` creates all nodes.
2. Ansible installs dependencies (`kube-dependencies.yml`).
3. kubeadm initializes and joins all nodes (`bootstrap-cluster.yml`).
4. Cilium is installed via Helm with cluster-specific defaults:
  - Full values are applied from `ansible/cilium/cilium-values.yaml`.
  - The pod IPAM pool is set from inventory via `cilium_cluster_pool_ipv4_cidr`.
5. On fresh clusters (or when explicitly reconciling), Cilium BGP and LB IPAM resources are rendered from inventory variables and applied when enabled.
6. Validation checks node status and Cilium rollout.
7. The primary control-plane admin kubeconfig is copied back to the VM host and pointed at the primary control-plane IP for immediate `kubectl` access.

Rerun safety defaults:

- If Cilium is already installed, bootstrap will not reconcile Helm values unless `cilium_reconcile_existing=true`.
- If Cilium is already installed, bootstrap will not reconcile BGP CRs unless `cilium_bgp_reconcile_existing=true`.

### Cilium BGP integration

By default on a fresh cluster, bootstrap applies templated Cilium BGP resources after Cilium rollout:

- `CiliumBGPPeerConfig`
- `CiliumLoadBalancerIPPool`
- `CiliumBGPAdvertisement`
- `CiliumBGPClusterConfig`

These are driven by inventory variables in `ansible/inventory/hosts.ini`, including:

- `cilium_bgp_enabled`
- `cilium_cluster_pool_ipv4_cidr`
- `cilium_reconcile_existing`
- `cilium_bgp_reconcile_existing`
- `cilium_bgp_local_asn`
- `cilium_bgp_peer_asn`
- `cilium_bgp_peer_address`
- `cilium_lb_ip_pool_cidr`

Set `cilium_bgp_enabled=false` to skip applying BGP resources during bootstrap.
If Cilium is already installed, set `cilium_bgp_reconcile_existing=true` to apply or update BGP resources on rerun.
Use a non-overlapping CIDR for `cilium_lb_ip_pool_cidr` relative to pod and service CIDRs.

## Upgrade an existing cluster

Use one script for either or both upgrade paths:

```bash
cd /home/chris/repos/k8s-cluster/vagrant-k8s-cluster
./scripts/upgrade-cluster.sh [--upgrade-os] [--upgrade-k8s vX.Y.Z]
```

Examples:

```bash
# OS rolling replacement only
./scripts/upgrade-cluster.sh --upgrade-os

# Kubernetes upgrade only
./scripts/upgrade-cluster.sh --upgrade-k8s v1.36.2

# Combined OS replacement + Kubernetes upgrade
./scripts/upgrade-cluster.sh --upgrade-os --upgrade-k8s v1.36.2
```

### OS rolling replacement behavior

Workers first, then control planes (`cp-02`, `cp-03`, `cp-01`):

1. Drain node with timeout.
2. If drain blocks, force-delete terminating pods and retry.
3. Destroy/recreate VM with Vagrant.
4. Re-apply node dependencies.
5. Re-join node using kubeadm join flow.
6. Wait for node `Ready` and Cilium pod `Ready` on that node.

Control-plane-specific safety:

- Before each control-plane replacement, endpoint alias is repointed to a healthy non-target control-plane node using `refresh-hosts.yml`.
- After OS replacement cycle, endpoint alias is restored to default.

### Kubernetes upgrade behavior

1. Derives channel from target version (for example `v1.36.2` -> `1.36`).
2. Upgrades packages from the selected channel on all nodes.
3. Runs `kubeadm upgrade apply` on `kube-cp-01`.
4. Runs `kubeadm upgrade node` on remaining control planes.
5. Drains each worker, runs `kubeadm upgrade node`, restarts kubelet, uncordons.

## Validation commands

Use these after create/upgrade:

```bash
ssh ubuntu@kube-cp-01 "kubectl get nodes -o wide"
ssh ubuntu@kube-cp-01 "kubectl -n kube-system get pods -o wide"
ssh ubuntu@kube-cp-01 "kubectl -n kube-system rollout status ds/cilium --timeout=10m"
ssh ubuntu@kube-cp-01 "kubectl get --raw='/readyz?verbose'"
```

## Troubleshooting

- Endpoint alias join failures:
  - Re-run endpoint mapping refresh with a healthy non-target control-plane node.
- Drain hangs on terminating pods:
  - The upgrade script includes force-delete fallback automatically.
- `vagrant-libvirt` warning about `libvirt_ip_command`:
  - Known non-blocking plugin warning in this environment.
- Node rejoin metadata oddities (AGE/role labels):
  - Verify labels and taints on control-plane nodes, then re-apply if needed.

## Notes and constraints

- This solution assumes the same cluster naming convention:
  - `kube-cp-01..03`, `kube-wk-01..03`
- This automation is designed for this lab/cluster pattern.
- Cilium behavior is now deterministic via the checked-in values file.
- If your existing cluster Cilium config changes, refresh this file before rebuilding new clusters.
- For production-grade use, add:
  - full etcd member reconciliation checks
  - CI validation pipeline
  - backup/restore checkpoints before each control-plane replacement
