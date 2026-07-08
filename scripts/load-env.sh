#!/usr/bin/env bash
set -euo pipefail

# Source this script to export variables from a .env file into your current shell.
# Usage:
#   source ./scripts/load-env.sh
#   source ./scripts/load-env.sh ./.env

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script must be sourced, not executed." >&2
  echo "Use: source ./scripts/load-env.sh [path-to-env-file]" >&2
  exit 1
fi

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Env file not found: $ENV_FILE" >&2
  return 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "Loaded env vars from $ENV_FILE"
