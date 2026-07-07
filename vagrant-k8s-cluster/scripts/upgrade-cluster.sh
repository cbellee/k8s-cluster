#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY="$ANSIBLE_DIR/inventory/hosts.ini"

CONTROL_PLANES=(kube-cp-01 kube-cp-02 kube-cp-03)
WORKERS=(kube-wk-01 kube-wk-02 kube-wk-03)

UPGRADE_OS=false
K8S_TARGET_VERSION=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--upgrade-os] [--upgrade-k8s vX.Y.Z]

Examples:
  $(basename "$0") --upgrade-os
  $(basename "$0") --upgrade-k8s v1.36.2
  $(basename "$0") --upgrade-os --upgrade-k8s v1.36.2
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-os)
      UPGRADE_OS=true
      shift
      ;;
    --upgrade-k8s)
      K8S_TARGET_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$UPGRADE_OS" == "false" && -z "$K8S_TARGET_VERSION" ]]; then
  echo "Nothing to do. Choose --upgrade-os and/or --upgrade-k8s."
  exit 1
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
fi

CP_ENDPOINT_ALIAS="${CP_ENDPOINT_ALIAS:-kube-cluster-01}"
DEFAULT_CP_ENDPOINT_NODE="${CP_ENDPOINT_NODE:-kube-cp-01}"
DEFAULT_CP_ENDPOINT_IP="${CP_ENDPOINT_IP:-192.168.89.10}"

node_ip() {
  case "$1" in
    kube-cp-01) echo "192.168.89.10" ;;
    kube-cp-02) echo "192.168.89.11" ;;
    kube-cp-03) echo "192.168.89.12" ;;
    kube-wk-01) echo "192.168.89.20" ;;
    kube-wk-02) echo "192.168.89.21" ;;
    kube-wk-03) echo "192.168.89.22" ;;
    *)
      echo "Unknown node: $1" >&2
      exit 1
      ;;
  esac
}

kctl() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@kube-cp-01 "kubectl $*"
}

refresh_endpoint_alias() {
  local endpoint_node="$1"
  local endpoint_ip
  endpoint_ip="$(node_ip "$endpoint_node")"

  echo "Refreshing endpoint alias $CP_ENDPOINT_ALIAS -> $endpoint_node ($endpoint_ip)"
  (
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/refresh-hosts.yml \
      -e "cp_endpoint_alias=$CP_ENDPOINT_ALIAS cp_endpoint_node=$endpoint_node cp_endpoint_ip=$endpoint_ip"
  )
}

wait_node_ready() {
  local node="$1"
  echo "Waiting for node $node to be Ready"
  kctl "wait --for=condition=Ready node/$node --timeout=15m"

  echo "Waiting for Cilium pod on $node"
  kctl "wait -n kube-system --for=condition=Ready pod --field-selector spec.nodeName=$node -l k8s-app=cilium --timeout=15m"
}

force_delete_terminating_pods() {
  local node="$1"
  echo "Force deleting lingering terminating pods on $node"
  local pods
  pods="$(kctl "get pods -A --field-selector spec.nodeName=$node -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}{" "}{.metadata.name}{"\\n"}{end}'")"
  if [[ -n "$pods" ]]; then
    while IFS=' ' read -r ns pod; do
      [[ -z "$ns" || -z "$pod" ]] && continue
      kctl "delete pod -n $ns $pod --grace-period=0 --force || true"
    done <<< "$pods"
  fi

  # Known failure mode observed during control-plane drain: stuck CoreDNS termination.
  local coredns
  coredns="$(kctl "get pods -n kube-system -l k8s-app=kube-dns --field-selector spec.nodeName=$node -o name || true")"
  if [[ -n "$coredns" ]]; then
    while IFS= read -r podref; do
      [[ -z "$podref" ]] && continue
      kctl "delete -n kube-system $podref --grace-period=0 --force || true"
    done <<< "$coredns"
  fi
}

drain_node() {
  local node="$1"
  echo "Draining $node"
  if ! kctl "drain $node --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=8m"; then
    force_delete_terminating_pods "$node"
    kctl "drain $node --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=8m"
  fi
}

uncordon_node() {
  local node="$1"
  kctl "uncordon $node || true"
}

replace_vm_and_rejoin_worker() {
  local node="$1"
  drain_node "$node"

  (
    cd "$ROOT_DIR"
    vagrant destroy -f "$node"
    vagrant up "$node"
  )

  (
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/kube-dependencies.yml --limit "$node"
    ansible-playbook -i "$INVENTORY" playbooks/join-worker-node.yml -e "target_node=$node"
  )

  wait_node_ready "$node"
  uncordon_node "$node"
}

replace_vm_and_rejoin_control_plane() {
  local node="$1"
  local endpoint_node=""

  for candidate in "${CONTROL_PLANES[@]}"; do
    if [[ "$candidate" != "$node" ]]; then
      endpoint_node="$candidate"
      break
    fi
  done

  if [[ -z "$endpoint_node" ]]; then
    echo "No healthy alternate control plane endpoint found"
    exit 1
  fi

  refresh_endpoint_alias "$endpoint_node"
  drain_node "$node"

  # Ensure stale API object does not block node re-registration.
  kctl "delete node $node --ignore-not-found=true"

  (
    cd "$ROOT_DIR"
    vagrant destroy -f "$node"
    vagrant up "$node"
  )

  (
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/kube-dependencies.yml --limit "$node"
    ansible-playbook -i "$INVENTORY" playbooks/join-control-plane-node.yml -e "target_node=$node"
  )

  wait_node_ready "$node"
}

upgrade_k8s_version() {
  local target="$1"
  local channel
  channel="$(echo "$target" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')"

  echo "Upgrading packages to Kubernetes channel $channel"
  (
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/upgrade-k8s-packages.yml -e "k8s_channel=$channel"
  )

  echo "Upgrading primary control plane to $target"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@kube-cp-01 "sudo kubeadm upgrade apply -y $target"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@kube-cp-01 "sudo systemctl restart kubelet"

  for node in kube-cp-02 kube-cp-03; do
    echo "Upgrading additional control plane: $node"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$node" "sudo kubeadm upgrade node"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$node" "sudo systemctl restart kubelet"
  done

  for node in "${WORKERS[@]}"; do
    echo "Upgrading worker: $node"
    drain_node "$node"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$node" "sudo kubeadm upgrade node"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$node" "sudo systemctl restart kubelet"
    uncordon_node "$node"
  done
}

if [[ "$UPGRADE_OS" == "true" ]]; then
  echo "Starting rolling OS replacement for workers"
  for node in "${WORKERS[@]}"; do
    replace_vm_and_rejoin_worker "$node"
  done

  echo "Starting rolling OS replacement for control planes"
  for node in kube-cp-02 kube-cp-03 kube-cp-01; do
    replace_vm_and_rejoin_control_plane "$node"
  done

  refresh_endpoint_alias "$DEFAULT_CP_ENDPOINT_NODE"
fi

if [[ -n "$K8S_TARGET_VERSION" ]]; then
  upgrade_k8s_version "$K8S_TARGET_VERSION"
fi

echo "Final verification"
kctl "get nodes -o wide"
kctl "get pods -n kube-system -o wide | egrep 'cilium|coredns' || true"
kctl "-n kube-system exec etcd-kube-cp-01 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key endpoint health || true"

echo "Upgrade workflow completed."
