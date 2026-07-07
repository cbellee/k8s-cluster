#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <host> [expected-os] [user]" >&2
  exit 2
fi

host="$1"
expected_os="${2:-Ubuntu 26.04 LTS}"
user_name="${3:-ubuntu}"

actual_os="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${user_name}@${host}" "if command -v lsb_release >/dev/null 2>&1; then lsb_release -ds; else . /etc/os-release; echo \"\${PRETTY_NAME}\"; fi" | tr -d '\r' | sed 's/^"//; s/"$//')"

echo "${host}: ${actual_os}"

if [[ "${actual_os}" != "${expected_os}" ]]; then
  echo "OS check failed for ${host}. Expected: ${expected_os}. Got: ${actual_os}" >&2
  exit 1
fi
