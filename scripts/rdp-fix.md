# RDP Fix: Mac to Ubuntu Host (XRDP)

Date: 2026-07-08
Host: cb-ubuntu-pc

## Problem
RDP from Mac to this Ubuntu host failed after login.

## Symptoms
- TCP connection to port 3389 succeeded.
- XRDP authentication succeeded for user `chris`.
- Session immediately disconnected after login.
- XRDP logs repeatedly showed:
  - `login was successful - creating session`
  - `Xorg server closed connection`
  - `Session on display 10 has finished`

## Root Cause
Network reachability and authentication were working. The failure was in desktop session startup for XRDP.

This host was effectively Wayland-only for GNOME session descriptors (no usable Xorg desktop session entries for XRDP), and GNOME shell session startup under XRDP was failing. XRDP therefore created the session and then terminated it immediately.

## Fix Applied
Installed and switched XRDP to an XFCE session (stable with XRDP on this host):

```bash
sudo apt-get install -y xfce4 xfce4-goodies dbus-x11
printf 'xfce4-session\n' > "$HOME/.xsession"
chmod 644 "$HOME/.xsession"
sudo systemctl restart xrdp xrdp-sesman
```

## Verification
- `systemctl is-active xrdp` => `active`
- `systemctl is-active xrdp-sesman` => `active`
- Mac RDP login now succeeds and desktop stays connected.

## Notes
- An earlier attempt to use GNOME session packages alone was not sufficient.
- XFCE is the known-good fallback for XRDP on this host.

## One-Command Script
Use this script to apply the same fix quickly:

```bash
./rdp-fix.sh
```
