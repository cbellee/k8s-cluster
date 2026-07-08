#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   source ./scripts/load-env.sh
#   ./scripts/bootstrap_flux.sh

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
: "${GITHUB_OWNER:?GITHUB_OWNER must be set}"

if ! command -v flux >/dev/null 2>&1; then
  echo "flux CLI not found. Install it first: curl -s https://fluxcd.io/install.sh | sudo bash" >&2
  exit 127
fi

REPO_NAME="${REPO_NAME:-k8s-cluster}"
BRANCH="${BRANCH:-main}"
CLUSTER_PATH="${CLUSTER_PATH:-gitops/clusters/kube-cluster-01}"

flux check --pre

flux bootstrap github \
  --owner="$GITHUB_OWNER" \
  --repository="$REPO_NAME" \
  --branch="$BRANCH" \
  --path="$CLUSTER_PATH" \
  --personal

flux get all -A
