#!/bin/bash
# Force a windowed application into borderless / regular fullscreen on X11.
# Tuned for Cinnamon/Muffin on Linux Mint (X11 session).
set -uo pipefail

# ---- sanity checks ---------------------------------------------------------
if [ "${XDG_SESSION_TYPE:-}" != "x11" ] && [ -z "${DISPLAY:-}" ]; then
  zenity --error --text "This script requires an X11 session (DISPLAY is not set)." 2>/dev/null
  exit 1
fi

for cmd in wmctrl xdotool xrandr xprop zenity; do
  command -v "$cmd" >/dev/null 2>&1 || {
    zenity --error --text "Missing dependency: $cmd" 2>/dev/null
    exit 1
  }
done

# ---- helper: parse xrandr --listmonitors -----------------------------------
# Emits lines: "NAME W H X Y PRIMARY"  (PRIMARY is 1 or 0)
list_monitors() {
  local line idx name geo rest g w h x y primary
  while IFS= read -r line; do
    [[ "$line" =~ ^Monitors: ]] && continue
    [ -z "$line" ] && continue
    read -r idx name geo rest <<<"$line"
    [ -z "${geo:-}" ] && continue

    primary=0
    [[ "$name" == +* ]] && primary=1
    name="${name#+}"; name="${name#\*}"

    # geo is like: 1920/344x1080/194+0+0
    # strip the /NNN mm suffixes -> 1920x1080+0+0
    g=$(printf '%s' "$geo" | sed -E 's#/[0-9]+##g')
    [[ "$g" =~ ^([0-9]+)x([0-9]+)\+([0-9-]+)\+([0-9-]+)$ ]] || continue
    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"
    x="${BASH_REMATCH[3]}"
    y="${BASH_REMATCH[4]}"
    printf '%s %s %s %s %s %s\n' "$name" "$w" "$h" "$x" "$y" "$primary"
  done < <(xrandr --listmonitors 2>/dev/null)
}

# ---- collect visible windows (id + title) ----------------------------------
declare -a ids=() titles=()
while read -r wid; do
  [ -z "$wid" ] && continue
  title=$(xdotool getwindowname "$wid" 2>/dev/null) || continue
  [ -z "$title" ] && continue
  ids+=("$wid")
  titles+=("$title")
done < <(xdotool search --onlyvisible --name '' 2>/dev/null)

if [ ${#ids[@]} -eq 0 ]; then
  zenity --error --text "No visible windows found." 2>/dev/null
  exit 1
fi

# ---- let the user pick a window --------------------------------------------
choice=$(zenity --list --title "Select Window" \
  --text "Select a window to force into fullscreen:" \
  --column "Window" "${titles[@]}" 2>/dev/null) || exit 0
[ -z "${choice:-}" ] && exit 0

wid=""
for i in "${!titles[@]}"; do
  if [ "${titles[$i]}" = "$choice" ]; then
    wid="${ids[$i]}"
    break
  fi
done
[ -z "$wid" ] && { zenity --error --text "Window not found." 2>/dev/null; exit 1; }

# ---- let the user pick the mode --------------------------------------------
mode=$(zenity --list --title "Fullscreen Mode" \
  --text "Select fullscreen mode:" \
  --column "Mode" "Borderless Fullscreen" "Regular Fullscreen" 2>/dev/null) || exit 0
[ -z "${mode:-}" ] && exit 0

# ---- geometry: which monitor is the window on? -----------------------------
geom=$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || {
  zenity --error --text "Could not read window geometry." 2>/dev/null
  exit 1
}
eval "$geom"   # sets X, Y, WIDTH, HEIGHT

cx=$((X + WIDTH / 2))
cy=$((Y + HEIGHT / 2))

mon_x=0; mon_y=0; mon_w=0; mon_h=0

# 1) monitor containing the window center
while read -r mname mw mh mx my mprimary; do
  [ -z "${mw:-}" ] && continue
  if (( cx >= mx && cx < mx + mw && cy >= my && cy < my + mh )); then
    mon_x=$mx; mon_y=$my; mon_w=$mw; mon_h=$mh
    break
  fi
done < <(list_monitors)

# 2) primary monitor
if [ "${mon_w:-0}" -eq 0 ] || [ "${mon_h:-0}" -eq 0 ]; then
  while read -r mname mw mh mx my mprimary; do
    [ -z "${mw:-}" ] && continue
    if [ "$mprimary" = "1" ]; then
      mon_x=$mx; mon_y=$my; mon_w=$mw; mon_h=$mh
      break
    fi
  done < <(list_monitors)
fi

# 3) first monitor
if [ "${mon_w:-0}" -eq 0 ] || [ "${mon_h:-0}" -eq 0 ]; then
  read -r _ mon_w mon_h mon_x mon_y _ < <(list_monitors | head -1)
fi

# 4) whole virtual screen as last resort
if [ "${mon_w:-0}" -eq 0 ] || [ "${mon_h:-0}" -eq 0 ]; then
  read -r mon_w mon_h < <(xdotool getdisplaygeometry 2>/dev/null)
  mon_x=0; mon_y=0
fi

# normalize to safe integers
mon_w=${mon_w:-0}; mon_h=${mon_h:-0}
mon_x=${mon_x:-0}; mon_y=${mon_y:-0}

# ---- apply -----------------------------------------------------------------
apply_fullscreen() {
  wmctrl -i -r "$wid" -b remove,maximized_vert,maximized_horz 2>/dev/null || true
  wmctrl -i -r "$wid" -b add,fullscreen 2>/dev/null || true
}

apply_borderless() {
  # 0. clear maximized/fullscreen so the WM doesn't override our resize
  wmctrl -i -r "$wid" -b remove,fullscreen 2>/dev/null || true
  wmctrl -i -r "$wid" -b remove,maximized_vert,maximized_horz 2>/dev/null || true

  # 1. strip decorations FIRST so resize isn't eaten by the frame
  xprop -id "$wid" -f _MOTIF_WM_HINTS 32c \
    -set _MOTIF_WM_HINTS "0x2, 0x0, 0x0, 0x0, 0x0" 2>/dev/null || true

  # 2. clear fixed-size hints (games often set these)
  xprop -id "$wid" -remove WM_NORMAL_HINTS 2>/dev/null || true

  # 3. move to the monitor origin BEFORE resize
  xdotool windowmove --sync "$wid" "$mon_x" "$mon_y"

  # 4. resize twice — Muffin sometimes re-applies geometry asynchronously
  xdotool windowsize --sync "$wid" "$mon_w" "$mon_h"
  sleep 0.15
  xdotool windowsize --sync "$wid" "$mon_w" "$mon_h"

  # 5. if the app refused the resize, fall back to EWMH fullscreen
  read -r w h < <(xdotool getwindowgeometry --shell "$wid" 2>/dev/null |
                  awk -F= '/^WIDTH=/{W=$2} /^HEIGHT=/{H=$2} END{print W+0, H+0}')
  if [ "${w:-0}" -ne "$mon_w" ] || [ "${h:-0}" -ne "$mon_h" ]; then
    wmctrl -i -r "$wid" -b add,fullscreen 2>/dev/null || true
    sleep 0.15
  fi

  # 6. keep it on top
  wmctrl -i -r "$wid" -b add,above 2>/dev/null || true
}

case "$mode" in
  "Borderless Fullscreen") apply_borderless ;;
  "Regular Fullscreen")    apply_fullscreen ;;
  *) exit 0 ;;
esac
