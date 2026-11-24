#!/usr/bin/env bash
# popos2604-xps16-audio-camera — remove what install.sh added.
#
#   ./uninstall.sh                  remove everything
#   ./uninstall.sh --only rotation  remove one component (repeatable):
#                                   audio | rotation | sensor-mode | desktop
#
# Use --only once your kernel ships the upstream fix for that component
# (see README.md, "When can I remove this?").
set -Eeuo pipefail
TAG=popos2604-xps16-audio-camera
log() { printf '\033[1;32m[%s]\033[0m %s\n' "$TAG" "$*"; }

COMPONENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) COMPONENTS+=("${2:?}"); shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ ${#COMPONENTS[@]} -eq 0 ]] && COMPONENTS=(audio rotation sensor-mode desktop)
want() { local c; for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }
[[ $EUID -eq 0 ]] && { echo "run as your normal user" >&2; exit 1; }

INITRAMFS=0
remove_dkms() {
  local pkg=$1 v
  for v in $(dkms status 2>/dev/null | awk -F'[/,: ]+' -v p="$pkg" '$1==p {print $2}' | sort -u); do
    log "removing DKMS $pkg/$v"
    sudo dkms remove -m "$pkg" -v "$v" --all || true
    sudo rm -rf "/usr/src/$pkg-$v"
  done
  INITRAMFS=1
}

want rotation    && remove_dkms xps16-ipu-bridge
want sensor-mode && remove_dkms xps16-ov08x40

if want audio; then
  log "removing intel_cvs delayed-load workaround"
  sudo systemctl disable xps16-load-cvs-after-audio.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/xps16-load-cvs-after-audio.service \
             /usr/local/sbin/xps16-load-cvs-after-audio \
             /etc/modprobe.d/xps16-delay-intel-cvs.conf
  sudo systemctl daemon-reload
  INITRAMFS=1
fi

if want desktop; then
  log "removing WirePlumber and Firefox settings"
  rm -f "$HOME/.config/wireplumber/wireplumber.conf.d/50-xps16-camera.conf"
  for ujs in "$HOME"/.config/mozilla/firefox/*/user.js "$HOME"/.mozilla/firefox/*/user.js \
             "$HOME"/snap/firefox/common/.mozilla/firefox/*/user.js; do
    [[ -f "$ujs" ]] && sed -i "/>>> $TAG >>>/,/<<< $TAG <<</d" "$ujs"
  done
  systemctl --user restart wireplumber 2>/dev/null || true
  # user.js only sets prefs at startup; prefs.js keeps the last values.
  log "Firefox: reset media.webrtc.camera.allow-pipewire in about:config if you want it off again"
fi

[[ $INITRAMFS -eq 1 ]] && sudo update-initramfs -u
log "Done. Reboot to finish."
