#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY="$ANSIBLE_DIR/inventory/hosts.ini"
PRIMARY_CP="$(awk '/^\[primary_control_plane\]/{getline; print $1; exit}' "$INVENTORY")"
PRIMARY_CP_IP="$(awk '/^\[primary_control_plane\]/{getline; for (i = 1; i <= NF; i++) if ($i ~ /^ansible_host=/) {split($i, a, "="); print a[2]; exit}}' "$INVENTORY")"

if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
fi

echo "[1/4] Creating VMs with Vagrant/libvirt"
cd "$ROOT_DIR"
vagrant up

echo "[2/4] Installing node dependencies"
cd "$ANSIBLE_DIR"
ansible-playbook -i "$INVENTORY" playbooks/kube-dependencies.yml

echo "[3/4] Initializing Kubernetes and Cilium"
ansible-playbook -i "$INVENTORY" playbooks/bootstrap-cluster.yml

echo "[4/4] Validating cluster health"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$PRIMARY_CP" "kubectl get nodes -o wide"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$PRIMARY_CP" "kubectl -n kube-system rollout status ds/cilium --timeout=10m"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$PRIMARY_CP" "kubectl -n kube-system get pods -l k8s-app=cilium -o wide"

echo "[5/5] Exporting kubeconfig to VM host"
mkdir -p "$HOME/.kube"
cp "$HOME/.kube/config" "$HOME/.kube/config.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
ssh -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@"$PRIMARY_CP_IP" "cat /home/ubuntu/.kube/config" > "$HOME/.kube/config"
kubectl config set-cluster kubernetes --server="https://$PRIMARY_CP_IP:6443" >/dev/null

echo "Cluster creation completed successfully."
