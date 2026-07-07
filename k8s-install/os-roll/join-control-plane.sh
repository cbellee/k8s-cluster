#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 6 ]]; then
  echo "Usage: $0 <source-control-plane> <target-control-plane> <endpoint> <target-control-plane-ip> [cri-socket] [user]" >&2
  exit 2
fi

source_cp="$1"
target_cp="$2"
endpoint="$3"
target_cp_ip="$4"
cri_socket="${5:-unix:///run/containerd/containerd.sock}"
user_name="${6:-ubuntu}"

join_cmd="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${source_cp}" "sudo kubeadm token create --print-join-command")"
join_cmd="$(awk -v endpoint="${endpoint}:6443" '{ $3=endpoint; print }' <<< "${join_cmd}")"
cert_key="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${source_cp}" "sudo kubeadm init phase upload-certs --upload-certs | tail -n 1" | tr -d '\r')"

if [[ -z "${cert_key}" ]]; then
  echo "Unable to fetch kubeadm certificate key from ${source_cp}" >&2
  exit 1
fi

ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${target_cp}" \
  "sudo ${join_cmd} --control-plane --certificate-key=${cert_key} --node-name=${target_cp} --cri-socket=${cri_socket} --apiserver-advertise-address=${target_cp_ip} --ignore-preflight-errors=all --v=5"

ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${target_cp}" \
  "mkdir -p /home/${user_name}/.kube && sudo cp /etc/kubernetes/admin.conf /home/${user_name}/.kube/config && sudo chown ${user_name}:${user_name} /home/${user_name}/.kube/config"
