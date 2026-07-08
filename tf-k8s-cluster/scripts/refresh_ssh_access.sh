#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="$TF_DIR/ansible/inventory/hosts.ini"
KEY_PATH="${1:-$HOME/.ssh/id_rsa.pub}"
ANSIBLE_USER="${ANSIBLE_USER:-ubuntu}"

if [[ ! -f "$INVENTORY" ]]; then
  echo "Inventory not found: $INVENTORY" >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "SSH public key not found: $KEY_PATH" >&2
  echo "Usage: $0 [path-to-public-key]" >&2
  exit 1
fi

IPS=(
  192.168.89.10
  192.168.89.11
  192.168.89.12
  192.168.89.20
  192.168.89.21
  192.168.89.22
)

echo "Removing stale known_hosts entries..."
for ip in "${IPS[@]}"; do
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true
done

echo "Scanning current host keys..."
for ip in "${IPS[@]}"; do
  ssh-keyscan -H "$ip" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
done

echo "Checking Ansible connectivity..."
ansible all -i "$INVENTORY" -u "$ANSIBLE_USER" -b -m ping

PUB_KEY_CONTENT="$(cat "$KEY_PATH")"

echo "Installing SSH key for user $ANSIBLE_USER on all nodes..."
ansible all -i "$INVENTORY" -u "$ANSIBLE_USER" -b -m authorized_key -a "user=$ANSIBLE_USER state=present key='$PUB_KEY_CONTENT'"

echo "Done. SSH access was refreshed across all nodes."
