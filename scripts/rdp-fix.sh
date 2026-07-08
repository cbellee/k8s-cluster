#!/usr/bin/env bash
set -euo pipefail

# Install a stable XRDP desktop session and switch user startup to XFCE.
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies dbus-x11

printf 'xfce4-session\n' > "$HOME/.xsession"
chmod 644 "$HOME/.xsession"

sudo systemctl restart xrdp xrdp-sesman

printf 'xrdp: %s\n' "$(systemctl is-active xrdp)"
printf 'xrdp-sesman: %s\n' "$(systemctl is-active xrdp-sesman)"
printf '.xsession: %s\n' "$(cat "$HOME/.xsession")"
