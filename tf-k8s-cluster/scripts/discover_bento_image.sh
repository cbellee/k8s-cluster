#!/usr/bin/env bash
set -euo pipefail

root="${HOME}/.vagrant.d/boxes"
if [[ ! -d "$root" ]]; then
  printf '{"path":""}\n'
  exit 0
fi

path="$({
  find "$root" -type f \( -name 'box.img' -o -name 'box_*.img' -o -name '*.qcow2' \) 2>/dev/null \
    | grep -E 'ubuntu-26\.04.*/libvirt' \
    | head -n 1
} || true)"

if [[ -n "$path" && -f "$path" ]]; then
  printf '{"path":"%s"}\n' "$path"
else
  printf '{"path":""}\n'
fi
