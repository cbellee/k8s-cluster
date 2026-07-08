#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default nodes used by this Terraform stack.
VMS=(
  kube-cp-01
  kube-cp-02
  kube-cp-03
  kube-wk-01
  kube-wk-02
  kube-wk-03
)

MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

cd "$TF_DIR"

echo "Checking libvirt domain state..."
for vm in "${VMS[@]}"; do
  state="$(virsh domstate "$vm" 2>/dev/null || true)"
  if [[ "$state" != "running" ]]; then
    echo "Starting $vm (state was: ${state:-unknown})"
    virsh start "$vm" >/dev/null
  else
    echo "$vm already running"
  fi
done

echo "Waiting for Kubernetes nodes to become Ready..."
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {count++} END {print count+0}')"

  if [[ "$not_ready" -eq 0 ]]; then
    echo "All nodes are Ready."
    kubectl get nodes -o wide
    exit 0
  fi

  echo "Attempt $attempt/$MAX_ATTEMPTS: $not_ready node(s) not Ready yet"
  kubectl get nodes --no-headers || true
  sleep "$SLEEP_SECONDS"
done

echo "Timed out waiting for all nodes to become Ready." >&2
kubectl get nodes -o wide || true
exit 1
