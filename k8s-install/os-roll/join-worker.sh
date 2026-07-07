#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <source-control-plane> <target-worker> [cri-socket] [user]" >&2
  exit 2
fi

source_cp="$1"
target_worker="$2"
cri_socket="${3:-unix:///run/containerd/containerd.sock}"
user_name="${4:-ubuntu}"

join_cmd="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${source_cp}" "sudo kubeadm token create --print-join-command")"

ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${target_worker}" \
  "sudo ${join_cmd} --node-name=${target_worker} --cri-socket=${cri_socket} --ignore-preflight-errors=all --v=5"
