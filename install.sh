#!/bin/bash
# Installer for Borderless Fullscreen.
# Copies the right script + .desktop launcher for your session type.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo: sudo ./install.sh" >&2
  exit 1
fi

# ---- detect session type (best-effort, for display only) ------------------
detected="${XDG_SESSION_TYPE:-}"
if [ -z "$detected" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then detected="wayland"; fi
if [ -z "$detected" ] && [ -n "${DISPLAY:-}" ]; then detected="x11"; fi
if [ -z "$detected" ]; then detected="unknown"; fi

echo "Detected session type: $detected"
echo
echo "Which version do you want to install?"
echo "  [x] Xorg / X11"
echo "  [w] Wayland"
read -r -p "Choice [x/w]: " ans
ans="${ans,,}"

case "$ans" in
  x|xorg|x11)
    install -m 755 borderless-fullscreen.sh /usr/bin/borderless-fullscreen.sh
    install -m 644 borderless-fullscreen.desktop /usr/share/applications/borderless-fullscreen.desktop
    echo "Installed X11 version."
    ;;
  w|wayland)
    install -m 755 borderless-fullscreen-wayland.sh /usr/bin/borderless-fullscreen-wayland.sh
    install -m 644 borderless-fullscreen-wayland.desktop /usr/share/applications/borderless-fullscreen-wayland.desktop
    echo "Installed Wayland version."
    echo "Note: the Wayland version only works on XWayland windows (wmctrl is X11-only)."
    ;;
  *)
    echo "Aborted: unrecognized choice '$ans'." >&2
    exit 1
    ;;
esac

# ---- icon (optional) ------------------------------------------------------
if [ -f icon-bf.png ]; then
  install -m 644 icon-bf.png /usr/share/icons/icon-bf.png
  echo "Installed icon."
else
  echo "Warning: icon-bf.png not found; the menu entry will use a fallback icon."
fi

# ---- make uninstaller runnable -------------------------------------------
if [ -f uninstall.sh ]; then
  chmod +x uninstall.sh 2>/dev/null || true
fi

echo
echo "Installed successfully. Launch 'Borderless Fullscreen' from the application menu,"
echo "or run it from a terminal:"
case "$ans" in
  x|xorg|x11) echo "  borderless-fullscreen.sh" ;;
  w|wayland)  echo "  borderless-fullscreen-wayland.sh" ;;
esac
