#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/bootstrap"
OS_ROLL_DIR="${SCRIPT_DIR}/os-roll"
TARGET_OS="Ubuntu 26.04 LTS"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
SSH_USER="ubuntu"
VAGRANT_PROVIDER="libvirt"
DRY_RUN=false
AUTO_APPROVE=false
ALLOW_CP1_ENDPOINT_RISK=false
PRESERVE_OLD_VM=true
DOWNLOAD_BOX_IF_MISSING=true
BACKUP_ONLY=false

BACKUP_DIR="${SCRIPT_DIR}/backups"

WORKERS=(k8s-wk-01 k8s-wk-02 k8s-wk-03)
CONTROL_PLANES=(k8s-cp-02 k8s-cp-03 k8s-cp-01)

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  local cmd="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: ${cmd}"
  else
    eval "${cmd}"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "${AUTO_APPROVE}" == "true" ]]; then
    log "Auto-approve: ${prompt}"
    return 0
  fi

  read -r -p "${prompt} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) fail "Stopped by operator." ;;
  esac
}

require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required commands: ${missing[*]}"
  fi
}

parse_hosts_var() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "${BOOTSTRAP_DIR}/hosts.ini" | tail -n 1
}

parse_vagrant_var() {
  local key="$1"
  awk -F= -v key="${key}" '$1 ~ "^" key "[ \t]*$" {gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/\047/, "", $2); print $2}' "${BOOTSTRAP_DIR}/Vagrantfile" | tail -n 1
}

node_ip_from_inventory() {
  local node="$1"
  awk -v node="${node}" '$1 == node {for (i = 1; i <= NF; i++) if ($i ~ /^ansible_host=/) {split($i, a, "="); print a[2]}}' "${BOOTSTRAP_DIR}/hosts.ini" | tail -n 1
}

wait_for_ssh() {
  local host="$1"
  local tries=60
  local i

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: skipping SSH readiness check for ${host}."
    return 0
  fi

  for ((i = 1; i <= tries; i++)); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "echo ssh-ready" >/dev/null 2>&1; then
      log "SSH is ready on ${host}."
      return 0
    fi
    sleep 5
  done

  fail "Timed out waiting for SSH on ${host}."
}

wait_for_vm_shutdown() {
  local node="$1"
  local tries=36
  local i

  for ((i = 1; i <= tries; i++)); do
    if virsh domstate "${node}" 2>/dev/null | grep -qiE 'shut off|shutoff'; then
      log "${node} is powered off."
      return 0
    fi
    sleep 5
  done

  log "Graceful shutdown timed out for ${node}; forcing power off."
  run_cmd "virsh destroy ${node}"

  for ((i = 1; i <= 12; i++)); do
    if virsh domstate "${node}" 2>/dev/null | grep -qiE 'shut off|shutoff'; then
      log "${node} is powered off after forced stop."
      return 0
    fi
    sleep 5
  done

  fail "Timed out waiting for ${node} to shut down."
}

node_exists() {
  local node="$1"
  kubectl get node "${node}" >/dev/null 2>&1
}

is_node_ready() {
  local node="$1"
  local ready
  ready="$(kubectl get node "${node}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
  [[ "${ready}" == "True" ]]
}

snapshot_vm() {
  local node="$1"
  local snap_name="pre-ubuntu-2604-${node}-$(date '+%Y%m%d%H%M%S')"
  run_cmd "virsh snapshot-create-as --domain ${node} --name ${snap_name} --description 'Pre Ubuntu 26.04 LTS rolling replacement for ${node}'"
}

etcd_snapshot() {
  local source_cp="$1"
  local label="$2"
  local remote_file="/tmp/etcd-${label}-$(date '+%Y%m%d%H%M%S').db"
  local local_dir="${BACKUP_DIR}/${source_cp}"
  local local_file="${local_dir}/$(basename "${remote_file}")"
  run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key snapshot save ${remote_file}\""
  run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo chmod 0644 ${remote_file}\""
  run_cmd "mkdir -p ${local_dir}"
  run_cmd "scp -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp}:${remote_file} ${local_file}"
  run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo rm -f ${remote_file}\""
  log "Saved etcd snapshot to ${local_file}"
}

etcd_health() {
  local source_cp="$1"
  run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key endpoint health\""
}

backup_cilium_state() {
  local backup_root="${BACKUP_DIR}/cilium"
  local ts
  local has_helm=false

  ts="$(date '+%Y%m%d%H%M%S')"
  run_cmd "mkdir -p ${backup_root}"

  if command -v helm >/dev/null 2>&1; then
    has_helm=true
  fi

  if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    log "Backing up Cilium runtime state."

    if [[ "${has_helm}" == "true" ]] && helm -n kube-system status cilium >/dev/null 2>&1; then
      run_cmd "helm -n kube-system get values cilium -a > ${backup_root}/cilium-values-${ts}.yaml"
      run_cmd "helm -n kube-system get manifest cilium > ${backup_root}/cilium-manifest-${ts}.yaml"
    else
      log "Helm release metadata for Cilium not available; skipping helm backup files."
    fi

    run_cmd "kubectl get ciliumbgppeerconfigs,ciliumbgpclusterconfigs,ciliumbgpadvertisements,ciliumloadbalancerippools -A -o yaml > ${backup_root}/cilium-crs-${ts}.yaml"
    run_cmd "kubectl -n kube-system get ds cilium -o yaml > ${backup_root}/cilium-daemonset-${ts}.yaml"

    log "Cilium backup saved under ${backup_root}"
  else
    log "Cilium daemonset not found; skipping Cilium backup."
  fi
}

pick_source_cp() {
  local target_cp="$1"
  local cp

  for cp in "${CONTROL_PLANES[@]}"; do
    if [[ "${cp}" != "${target_cp}" ]] && is_node_ready "${cp}"; then
      echo "${cp}"
      return 0
    fi
  done

  fail "Unable to pick a healthy source control-plane for ${target_cp}."
}

pick_ready_cp() {
  local cp
  for cp in "${CONTROL_PLANES[@]}"; do
    if is_node_ready "${cp}"; then
      echo "${cp}"
      return 0
    fi
  done

  fail "Unable to find a Ready control-plane node for backup operations."
}

ensure_vagrant_box() {
  local image_name
  image_name="$(parse_vagrant_var IMAGE)"

  if [[ -z "${image_name}" ]]; then
    fail "Unable to parse IMAGE from ${BOOTSTRAP_DIR}/Vagrantfile"
  fi

  if vagrant box list | awk '{print $1" "$2}' | grep -qE "^${image_name} \(${VAGRANT_PROVIDER},"; then
    log "Vagrant box ${image_name} (${VAGRANT_PROVIDER}) already present."
    return 0
  fi

  if [[ "${DOWNLOAD_BOX_IF_MISSING}" != "true" ]]; then
    fail "Vagrant box ${image_name} (${VAGRANT_PROVIDER}) is missing. Pre-download it or enable auto-download."
  fi

  confirm "Vagrant box ${image_name} (${VAGRANT_PROVIDER}) is missing. Download now?"
  run_cmd "cd ${BOOTSTRAP_DIR} && vagrant box add --provider=${VAGRANT_PROVIDER} ${image_name}"
}

verify_cp_endpoint_resolution() {
  local cp_endpoint
  local cp_endpoint_ip
  local cp1_ip
  local resolved_ip

  cp_endpoint="$(parse_hosts_var cp_endpoint)"
  cp_endpoint_ip="$(parse_hosts_var cp_endpoint_ip)"
  cp1_ip="$(node_ip_from_inventory k8s-cp-01)"

  resolved_ip="$(getent ahostsv4 "${cp_endpoint}" | awk '{print $1; exit}' || true)"

  [[ -n "${cp_endpoint}" ]] || fail "cp_endpoint is empty in hosts.ini"
  [[ -n "${cp_endpoint_ip}" ]] || fail "cp_endpoint_ip is empty in hosts.ini"
  [[ -n "${cp1_ip}" ]] || fail "Unable to parse k8s-cp-01 IP from hosts.ini"
  [[ -n "${resolved_ip}" ]] || fail "Unable to resolve cp_endpoint ${cp_endpoint}"

  if [[ "${resolved_ip}" == "${cp1_ip}" && "${ALLOW_CP1_ENDPOINT_RISK}" != "true" ]]; then
    fail "cp_endpoint ${cp_endpoint} resolves to k8s-cp-01 (${cp1_ip}). Move endpoint first, or pass --allow-cp1-endpoint-risk to override."
  fi

  if [[ "${resolved_ip}" != "${cp_endpoint_ip}" ]]; then
    fail "cp_endpoint ${cp_endpoint} resolves to ${resolved_ip}, but cp_endpoint_ip is ${cp_endpoint_ip}. Align them before running."
  fi
}

replace_vm() {
  local node="$1"
  local preserved_name
  local up_timeout=1800

  if [[ "${PRESERVE_OLD_VM}" == "true" ]]; then
    preserved_name="${node}-pre2604-$(date '+%Y%m%d%H%M%S')"
    confirm "Shutdown and preserve existing VM ${node} as ${preserved_name} before replacement?"
    run_cmd "virsh shutdown ${node} || true"
    if [[ "${DRY_RUN}" != "true" ]]; then
      wait_for_vm_shutdown "${node}"
    fi

    if command -v virt-clone >/dev/null 2>&1; then
      run_cmd "virt-clone --original ${node} --name ${preserved_name} --auto-clone"
      run_cmd "virsh autostart --disable ${preserved_name} || true"
      log "Preserved offline rollback VM: ${preserved_name}"
    else
      fail "virt-clone is required for --preserve-old-vm. Install it or re-run with --no-preserve-old-vm."
    fi
  fi

  confirm "Replace VM ${node} now? This destroys and recreates the VM from Vagrant."
  run_cmd "cd ${BOOTSTRAP_DIR} && vagrant destroy -f ${node}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    run_cmd "cd ${BOOTSTRAP_DIR} && timeout ${up_timeout} vagrant up ${node}"
  else
    if ! (cd "${BOOTSTRAP_DIR}" && timeout "${up_timeout}" vagrant up "${node}"); then
      log "vagrant up for ${node} failed or timed out after ${up_timeout}s."
      run_cmd "virsh domstate ${node} || true"
      run_cmd "virsh domiflist ${node} || true"
      run_cmd "virsh net-dhcp-leases vagrant_mgmt_network | grep -i ${node} || true"
      fail "Unable to complete vagrant up for ${node}. Check VM console (VNC/virt-manager) for guest networking/boot issues."
    fi
  fi
}

apply_dependencies() {
  local node="$1"
  run_cmd "cd ${BOOTSTRAP_DIR} && ansible-playbook -i hosts.ini --ssh-common-args='-o StrictHostKeyChecking=no' ./kube-dependencies.yml --limit ${node}"
}

verify_node_ready() {
  local node="$1"
  run_cmd "kubectl wait --for=condition=Ready node/${node} --timeout=10m"
}

remove_etcd_member() {
  local source_cp="$1"
  local target_cp="$2"
  local member_id

  if [[ "${DRY_RUN}" == "true" ]]; then
    run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key member list | grep ', ${target_cp},' | cut -d, -f1 | tr -d ' '\""
    run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key member remove <member-id-for-${target_cp}>\""
    return 0
  fi

  member_id="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${source_cp}" \
    "sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key member list | grep ', ${target_cp},' | cut -d, -f1 | tr -d ' '" || true)"

  if [[ -z "${member_id}" ]]; then
    log "No etcd member found for ${target_cp}. Continuing."
    return 0
  fi

  run_cmd "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${source_cp} \"sudo etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key member remove ${member_id}\""
}

replace_worker() {
  local worker="$1"
  local source_cp="$2"

  confirm "Start worker replacement for ${worker}?"
  snapshot_vm "${worker}"
  etcd_snapshot "${source_cp}" "${worker}"

  if node_exists "${worker}"; then
    run_cmd "kubectl cordon ${worker}"
    run_cmd "kubectl drain ${worker} --ignore-daemonsets --delete-emptydir-data --timeout=15m"
    run_cmd "kubectl delete node ${worker}"
  else
    log "${worker} already absent from Kubernetes; skipping cordon/drain/delete for resume."
  fi

  replace_vm "${worker}"
  wait_for_ssh "${worker}"
  run_cmd "${OS_ROLL_DIR}/check-node-os.sh ${worker} '${TARGET_OS}' ${SSH_USER}"
  apply_dependencies "${worker}"
  run_cmd "${OS_ROLL_DIR}/join-worker.sh ${source_cp} ${worker} ${CRI_SOCKET} ${SSH_USER}"
  verify_node_ready "${worker}"
  run_cmd "kubectl uncordon ${worker}"
}

replace_control_plane() {
  local cp_node="$1"
  local source_cp
  local cp_endpoint
  local cp_node_ip

  source_cp="$(pick_source_cp "${cp_node}")"
  cp_endpoint="$(parse_hosts_var cp_endpoint)"
  cp_node_ip="$(node_ip_from_inventory "${cp_node}")"

  [[ -n "${cp_node_ip}" ]] || fail "Unable to parse IP for ${cp_node} from hosts.ini"

  confirm "Start control-plane replacement for ${cp_node}?"
  snapshot_vm "${cp_node}"
  etcd_snapshot "${source_cp}" "${cp_node}"

  if node_exists "${cp_node}"; then
    run_cmd "kubectl cordon ${cp_node} || true"
    run_cmd "kubectl drain ${cp_node} --ignore-daemonsets --delete-emptydir-data --force --timeout=15m || true"

    remove_etcd_member "${source_cp}" "${cp_node}"
    run_cmd "kubectl delete node ${cp_node}"
  else
    log "${cp_node} already absent from Kubernetes; skipping cordon/drain/member-remove/delete for resume."
  fi

  replace_vm "${cp_node}"
  wait_for_ssh "${cp_node}"
  run_cmd "${OS_ROLL_DIR}/check-node-os.sh ${cp_node} '${TARGET_OS}' ${SSH_USER}"
  apply_dependencies "${cp_node}"
  run_cmd "${OS_ROLL_DIR}/join-control-plane.sh ${source_cp} ${cp_node} ${cp_endpoint} ${cp_node_ip} ${CRI_SOCKET} ${SSH_USER}"

  verify_node_ready "${cp_node}"
  etcd_health "${source_cp}"
}

audit_os() {
  local node
  for node in "${WORKERS[@]}" "${CONTROL_PLANES[@]}"; do
    run_cmd "${OS_ROLL_DIR}/check-node-os.sh ${node} '${TARGET_OS}' ${SSH_USER}"
  done
}

prechecks() {
  local vagrant_image_line
  local cp_endpoint_ip
  local cp1_ip

  require_cmd kubectl virsh vagrant ansible-playbook ssh awk sed grep scp getent

  [[ -f "${BOOTSTRAP_DIR}/hosts.ini" ]] || fail "Missing ${BOOTSTRAP_DIR}/hosts.ini"
  [[ -f "${BOOTSTRAP_DIR}/Vagrantfile" ]] || fail "Missing ${BOOTSTRAP_DIR}/Vagrantfile"
  [[ -x "${OS_ROLL_DIR}/check-node-os.sh" ]] || fail "Missing executable ${OS_ROLL_DIR}/check-node-os.sh"
  [[ -x "${OS_ROLL_DIR}/join-worker.sh" ]] || fail "Missing executable ${OS_ROLL_DIR}/join-worker.sh"
  [[ -x "${OS_ROLL_DIR}/join-control-plane.sh" ]] || fail "Missing executable ${OS_ROLL_DIR}/join-control-plane.sh"

  kubectl get nodes >/dev/null

  vagrant_image_line="$(grep -E '^IMAGE\s*=\s*' "${BOOTSTRAP_DIR}/Vagrantfile" || true)"
  if [[ "${vagrant_image_line}" != *"26.04"* ]] && [[ "${vagrant_image_line}" != *"2604"* ]]; then
    fail "Vagrantfile IMAGE does not appear to target Ubuntu 26.04. Update IMAGE before running."
  fi

  cp_endpoint_ip="$(parse_hosts_var cp_endpoint_ip)"
  cp1_ip="$(node_ip_from_inventory k8s-cp-01)"

  if [[ -z "${cp_endpoint_ip}" || -z "${cp1_ip}" ]]; then
    fail "Unable to parse cp_endpoint_ip or k8s-cp-01 IP from hosts.ini"
  fi

  if [[ "${cp_endpoint_ip}" == "${cp1_ip}" && "${ALLOW_CP1_ENDPOINT_RISK}" != "true" ]]; then
    fail "cp_endpoint_ip still points to k8s-cp-01 (${cp1_ip}). Move endpoint first, or pass --allow-cp1-endpoint-risk to override."
  fi

  if [[ "${PRESERVE_OLD_VM}" == "true" ]]; then
    require_cmd virt-clone
  fi

  ensure_vagrant_box
  verify_cp_endpoint_resolution
}

prechecks_backup_only() {
  require_cmd kubectl ssh awk sed grep scp
  kubectl get nodes >/dev/null
}

run_backup_only_mode() {
  local source_cp

  source_cp="$(pick_ready_cp)"
  confirm "Run backup-only mode (Cilium + etcd snapshot export) now?"

  backup_cilium_state
  etcd_snapshot "${source_cp}" "preflight"
  etcd_health "${source_cp}"

  log "Backup-only mode completed. Backups are under ${BACKUP_DIR}."
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --dry-run                     Print actions only, no changes
  --yes                         Auto-approve all checkpoints
  --bootstrap-dir <path>        Path to bootstrap folder
  --target-os <name>            Required OS string (default: Ubuntu 26.04 LTS)
  --no-preserve-old-vm          Skip keeping an offline rollback clone before replace
  --no-box-download             Fail if Vagrant box is missing instead of downloading it
  --backup-only                 Create Cilium + etcd backups and exit
  --workers <csv>               Worker order (default: k8s-wk-01,k8s-wk-02,k8s-wk-03)
  --control-planes <csv>        Control-plane order (default: k8s-cp-02,k8s-cp-03,k8s-cp-01)
  --allow-cp1-endpoint-risk     Allow replacing k8s-cp-01 while endpoint still points to it
  -h, --help                    Show this help
EOF
}

split_csv_to_array() {
  local csv="$1"
  local -n out_arr=$2
  IFS=',' read -r -a out_arr <<< "${csv}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      AUTO_APPROVE=true
      shift
      ;;
    --bootstrap-dir)
      BOOTSTRAP_DIR="$2"
      shift 2
      ;;
    --target-os)
      TARGET_OS="$2"
      shift 2
      ;;
    --no-preserve-old-vm)
      PRESERVE_OLD_VM=false
      shift
      ;;
    --no-box-download)
      DOWNLOAD_BOX_IF_MISSING=false
      shift
      ;;
    --backup-only)
      BACKUP_ONLY=true
      shift
      ;;
    --workers)
      split_csv_to_array "$2" WORKERS
      shift 2
      ;;
    --control-planes)
      split_csv_to_array "$2" CONTROL_PLANES
      shift 2
      ;;
    --allow-cp1-endpoint-risk)
      ALLOW_CP1_ENDPOINT_RISK=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

log "Starting rolling Ubuntu 26.04 LTS replacement workflow."
if [[ "${BACKUP_ONLY}" == "true" ]]; then
  prechecks_backup_only
  run_backup_only_mode
  exit 0
fi

prechecks

confirm "Run preflight backups and health checks now?"
backup_cilium_state
run_cmd "kubectl get nodes -o wide"
run_cmd "kubectl get pods -A"
run_cmd "kubectl get --raw='/readyz?verbose'"

for worker in "${WORKERS[@]}"; do
  source_cp="$(pick_source_cp "${worker}")"
  replace_worker "${worker}" "${source_cp}"
  run_cmd "kubectl get node ${worker} -o wide"
  run_cmd "kubectl get pods -A"
done

for cp in "${CONTROL_PLANES[@]}"; do
  replace_control_plane "${cp}"
  run_cmd "kubectl get node ${cp} -o wide"
  run_cmd "kubectl get --raw='/readyz?verbose'"
done

audit_os
run_cmd "kubectl get nodes -o wide"
run_cmd "kubectl get pods -A"

log "Completed rolling Ubuntu 26.04 LTS replacement workflow."
