#!/usr/bin/env bash
# popos2604-xps16-audio-camera — make speakers, microphones and the webcam work
# on a Dell XPS 16 DA16260 (Intel Panther Lake) running Pop!_OS 26.04 COSMIC.
#
# Run as your normal user; sudo is used only where needed. See README.md.
#
#   ./install.sh                     install everything, then reboot
#   ./install.sh --only audio        just one component (repeatable):
#                                    audio | rotation | sensor-mode | desktop | zoom
#   ./install.sh --build-only        download + patch + compile the kernel
#                                    modules in ./build, change nothing
#   ./install.sh --force             allow a machine that isn't a DA16260
set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TAG=popos2604-xps16-audio-camera
PRODUCT_EXPECTED="XPS 16 DA16260"
KREL=$(uname -r)
WORK="$REPO_DIR/build/$KREL"
KSRC_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$TAG" "$*"; }
warn() { printf '\033[1;33m[%s] warning:\033[0m %s\n' "$TAG" "$*" >&2; }
die()  { printf '\033[1;31m[%s] error:\033[0m %s\n' "$TAG" "$*" >&2; exit 1; }

COMPONENTS=()
BUILD_ONLY=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) COMPONENTS+=("${2:?--only needs a component}"); shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ ${#COMPONENTS[@]} -eq 0 ]] && COMPONENTS=(audio rotation sensor-mode desktop zoom)
for c in "${COMPONENTS[@]}"; do
  case "$c" in audio|rotation|sensor-mode|desktop|zoom) ;; *) die "unknown component: $c" ;; esac
done
want() { local c; for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }

[[ $EUID -eq 0 ]] && die "run as your normal user, not root (sudo is used where needed)"

# ---------------------------------------------------------------- preflight
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
if [[ "$PRODUCT" != "$PRODUCT_EXPECTED" ]]; then
  if [[ $FORCE -eq 1 ]]; then
    warn "this is a '$PRODUCT', not a '$PRODUCT_EXPECTED'; continuing because of --force"
  else
    die "this is a '$PRODUCT', not a '$PRODUCT_EXPECTED'. Use --force if you know the same fixes apply (see README)."
  fi
fi
. /etc/os-release
[[ "${VERSION_ID:-}" == "26.04" ]] || warn "tested on Pop!_OS 26.04; this is ${PRETTY_NAME:-unknown}"

# Upstream kernel version for the running kernel, e.g. 7.2.15-76070215-generic -> 7.2.15
KVER=${KREL%%-*}
IFS=. read -r KMAJ KMIN KPATCH <<<"$KVER"
KTAG="v$KMAJ.$KMIN"; [[ -n "${KPATCH:-}" && "$KPATCH" != 0 ]] && KTAG="$KTAG.$KPATCH"
log "Machine: $PRODUCT   Kernel: $KREL (upstream $KTAG)"

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  warn "Secure Boot is enabled. DKMS modules must be signed with an enrolled MOK key."
  warn "Ubuntu's dkms signs them automatically; you may be asked to enroll the key at the next boot."
fi

# ---------------------------------------------------------------- helpers
fetch_kernel_file() {   # $1 = path in kernel tree, $2 = destination
  curl -sfL --retry 3 "$KSRC_BASE/$1?h=$KTAG" -o "$2" ||
    die "could not download $1 for $KTAG from kernel.org"
  grep -q 'MODULE_LICENSE' "$2" || die "downloaded $1 doesn't look like kernel source"
}

# Build a single-file module as a DKMS package. Args:
#   $1 dkms package name  $2 module name (file stem)  $3 kernel path  $4 patch script
#   $5... extra args for the patch script
# Returns 0 if built (and installed unless --build-only), 3 if not needed.
build_module() {
  local pkg=$1 mod=$2 kpath=$3 patcher=$4; shift 4
  local dir="$WORK/$pkg"
  rm -rf "$dir"; mkdir -p "$dir"
  log "[$pkg] downloading $kpath ($KTAG)"
  fetch_kernel_file "$kpath" "$dir/$mod.c"
  set +e
  python3 -I "$REPO_DIR/lib/$patcher" "$dir/$mod.c" "$@"
  local rc=$?
  set -e
  if [[ $rc -eq 3 ]]; then
    log "[$pkg] upstream already has this fix for $KTAG — skipping (stock module is fine)"
    return 3
  fi
  [[ $rc -eq 0 ]] || die "[$pkg] patching failed"

  cat > "$dir/Makefile" <<EOF
obj-m := $mod.o
KVER ?= \$(shell uname -r)
all:
	\$(MAKE) -C /lib/modules/\$(KVER)/build M=\$(CURDIR) modules
clean:
	\$(MAKE) -C /lib/modules/\$(KVER)/build M=\$(CURDIR) clean
EOF
  # Source is from upstream $KMAJ.$KMIN.x; only build for that series.
  cat > "$dir/dkms.conf" <<EOF
PACKAGE_NAME="$pkg"
PACKAGE_VERSION="$KVER"
BUILT_MODULE_NAME[0]="$mod"
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make KVER=\${kernelver}"
CLEAN="make clean"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_KERNEL="^$KMAJ\\.$KMIN\\."
EOF
  log "[$pkg] test-compiling against $KREL"
  make -s -C "$dir" >"$dir/build.log" 2>&1 || { tail -20 "$dir/build.log"; die "[$pkg] compile failed (log: $dir/build.log)"; }
  make -s -C "$dir" clean >/dev/null 2>&1 || true

  if [[ $BUILD_ONLY -eq 1 ]]; then
    log "[$pkg] built OK (build-only: not installed)"
    return 0
  fi

  # Remove any older version of this package (and the names used before this repo existed).
  local old
  for old in $(dkms status 2>/dev/null | awk -F'[/,: ]+' -v p="$pkg" '$1==p {print $2}' | sort -u); do
    sudo dkms remove -m "$pkg" -v "$old" --all >/dev/null 2>&1 || true
    sudo rm -rf "/usr/src/$pkg-$old"
  done
  sudo rm -rf "/usr/src/$pkg-$KVER"
  sudo cp -r "$dir" "/usr/src/$pkg-$KVER"
  sudo dkms add -m "$pkg" -v "$KVER" >/dev/null
  sudo dkms install -m "$pkg" -v "$KVER" -k "$KREL" --force
  local loaded
  loaded=$(modinfo -n "$mod" 2>/dev/null)
  [[ "$loaded" == *updates/dkms* ]] || die "[$pkg] installed, but '$mod' still resolves to $loaded"
  log "[$pkg] installed: $loaded"
}

remove_legacy() {  # names used while this setup was first worked out
  local p
  for p in ipu-bridge-xps16/1.0 ov08x40-xps16/1.0; do
    if dkms status "${p%/*}" 2>/dev/null | grep -q .; then
      log "removing earlier DKMS package $p"
      sudo dkms remove -m "${p%/*}" -v "${p#*/}" --all >/dev/null 2>&1 || true
      sudo rm -rf "/usr/src/${p%/*}-${p#*/}"
    fi
  done
}

# ---------------------------------------------------------------- packages
NEED_PKGS=(curl python3 make gcc dkms "linux-headers-$KREL")
want desktop && NEED_PKGS+=(libcamera-tools)
want zoom && NEED_PKGS+=(v4l2loopback-dkms gstreamer1.0-pipewire gstreamer1.0-plugins-good gstreamer1.0-tools v4l-utils)
MISSING=()
for p in "${NEED_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  [[ $BUILD_ONLY -eq 1 ]] && die "missing packages for building: ${MISSING[*]}"
  log "installing: ${MISSING[*]}"
  sudo apt-get update
  sudo apt-get install -y "${MISSING[@]}"
fi

mkdir -p "$WORK"
CHANGED_INITRAMFS=0

# Remove the earlier hand-made packages BEFORE installing: they install the
# same module file names (updates/dkms/ipu-bridge.ko, ov08x40.ko), so removing
# them afterwards would delete the new modules too.
if [[ $BUILD_ONLY -eq 0 ]] && { want rotation || want sensor-mode; }; then
  remove_legacy
fi

# ---------------------------------------------------------------- rotation
if want rotation; then
  if build_module xps16-ipu-bridge ipu-bridge drivers/media/pci/intel/ipu-bridge.c \
       patch_ipu_bridge.py "$PRODUCT_EXPECTED"; then CHANGED_INITRAMFS=1; fi
fi

# ---------------------------------------------------------------- sensor mode
if want sensor-mode; then
  if build_module xps16-ov08x40 ov08x40 drivers/media/i2c/ov08x40.c patch_ov08x40.py; then
    CHANGED_INITRAMFS=1
  fi
fi

if [[ $BUILD_ONLY -eq 1 ]]; then
  log "build-only finished; nothing on the system was changed. Output: $WORK"
  exit 0
fi

# ---------------------------------------------------------------- audio
if want audio; then
  log "[audio] installing intel_cvs delayed-load workaround"
  sudo install -m 0644 "$REPO_DIR/files/audio/xps16-delay-intel-cvs.conf" /etc/modprobe.d/xps16-delay-intel-cvs.conf
  sudo install -m 0755 "$REPO_DIR/files/audio/xps16-load-cvs-after-audio" /usr/local/sbin/xps16-load-cvs-after-audio
  sudo install -m 0644 "$REPO_DIR/files/audio/xps16-load-cvs-after-audio.service" /etc/systemd/system/xps16-load-cvs-after-audio.service
  sudo systemctl daemon-reload
  sudo systemctl enable xps16-load-cvs-after-audio.service
  CHANGED_INITRAMFS=1
fi

# ---------------------------------------------------------------- desktop
if want desktop; then
  log "[desktop] hiding raw ipu7 nodes in WirePlumber"
  install -D -m 0644 "$REPO_DIR/files/desktop/50-xps16-camera.conf" \
    "$HOME/.config/wireplumber/wireplumber.conf.d/50-xps16-camera.conf"
  systemctl --user restart wireplumber 2>/dev/null || true

  log "[desktop] enabling Firefox's PipeWire camera"
  found=0
  for base in "$HOME/.config/mozilla/firefox" "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox"; do
    [[ -f "$base/profiles.ini" ]] || continue
    while IFS= read -r rel; do
      prof="$base/$rel"; [[ -d "$prof" ]] || continue
      ujs="$prof/user.js"
      if [[ -f "$ujs" ]] && grep -q ">>> $TAG >>>" "$ujs"; then
        sed -i "/>>> $TAG >>>/,/<<< $TAG <<</d" "$ujs"
      fi
      cat "$REPO_DIR/files/desktop/firefox-user.js" >> "$ujs"
      log "[desktop]   $ujs"; found=1
    done < <(sed -n 's/^Path=//p' "$base/profiles.ini")
  done
  [[ $found -eq 1 ]] || warn "no Firefox profile yet. Start Firefox once, close it, then run: ./install.sh --only desktop"
  pgrep -x firefox >/dev/null && warn "Firefox is running; restart it for the camera setting to apply"
fi

# ---------------------------------------------------------------- zoom
if want zoom; then
  log "[zoom] installing the \"Zoom Camera\" virtual camera for V4L2-only apps"
  sudo install -m 0644 "$REPO_DIR/files/zoom/xps16-zoom-camera-modprobe.conf" /etc/modprobe.d/xps16-zoom-camera.conf
  sudo install -m 0644 "$REPO_DIR/files/zoom/xps16-zoom-camera-modules-load.conf" /etc/modules-load.d/xps16-zoom-camera.conf
  sudo install -m 0755 "$REPO_DIR/files/zoom/xps16-camera-relay" /usr/local/bin/xps16-camera-relay
  install -D -m 0644 "$REPO_DIR/files/zoom/xps16-camera-relay.service" \
    "$HOME/.config/systemd/user/xps16-camera-relay.service"
  # The WirePlumber rule that hides this device from PipeWire is in the desktop component.
  want desktop || install -D -m 0644 "$REPO_DIR/files/desktop/50-xps16-camera.conf" \
    "$HOME/.config/wireplumber/wireplumber.conf.d/50-xps16-camera.conf"
  if [[ ! -e /dev/video42 ]]; then
    sudo modprobe -r v4l2loopback 2>/dev/null || true
    sudo modprobe v4l2loopback || warn "could not load v4l2loopback now; it loads at the next boot"
  fi
  systemctl --user daemon-reload
  systemctl --user enable xps16-camera-relay.service
  [[ -e /dev/video42 ]] && systemctl --user restart xps16-camera-relay.service || true
  CHANGED_INITRAMFS=1
fi

# ---------------------------------------------------------------- finish
if [[ $CHANGED_INITRAMFS -eq 1 ]]; then
  log "updating initramfs"
  sudo update-initramfs -u
fi
log "Done. Reboot, then run ./tools/verify.sh"
