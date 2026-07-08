#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   export GITHUB_TOKEN=<token-with-repo-scope>
#   export GITHUB_OWNER=<github-user-or-org>
#   ./gitops/scripts/bootstrap_flux.sh

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
: "${GITHUB_OWNER:?GITHUB_OWNER must be set}"

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
