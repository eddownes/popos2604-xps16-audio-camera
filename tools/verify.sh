#!/usr/bin/env bash
# popos2604-xps16-audio-camera — check that audio and the camera work.
# No root needed. Run after the reboot that follows ./install.sh.
#   ./tools/verify.sh            checks only
#   ./tools/verify.sh --capture  also grabs 20 frames at 1280x720 with `cam`
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf() { printf '  ---- %s\n' "$*"; }

echo "Machine: $(cat /sys/class/dmi/id/product_name 2>/dev/null)   Kernel: $(uname -r)"

echo "Audio"
amps=$(ls -d /sys/bus/soundwire/drivers/cs35l56/sdw:* 2>/dev/null | wc -l)
[[ $amps -ge 4 ]] && ok "$amps CS35L56/57 speaker amps bound" || bad "only $amps of 4 speaker amps bound (see 'journalctl -k | grep cs35l56')"
grep -q sofsoundwire /proc/asound/cards 2>/dev/null && ok "sof-soundwire sound card present" || bad "no sof-soundwire sound card"
if systemctl is-enabled xps16-load-cvs-after-audio.service >/dev/null 2>&1; then
  inf "$(journalctl -b -u xps16-load-cvs-after-audio --no-pager -o cat 2>/dev/null | grep 'amps bound' | tail -1)"
fi

echo "Camera — kernel"
[[ -d /sys/module/intel_cvs ]] && ok "intel_cvs loaded" || bad "intel_cvs not loaded"
for m in ipu_bridge ov08x40; do
  f=$(modinfo -n $m 2>/dev/null)
  case "$f" in *updates/dkms*) ok "$m: patched DKMS module ($f)";;
               "") bad "$m: module not found";;
               *) inf "$m: stock module ($f) — fine only if your kernel already has the fix";; esac
done
sub=""
for s in /sys/class/video4linux/v4l-subdev*; do
  [[ "$(cat "$s/name" 2>/dev/null)" == ov08x40* ]] && sub=/dev/$(basename "$s")
done
if [[ -z "$sub" ]]; then
  bad "no ov08x40 sensor subdevice (sensor didn't register)"
else
  out=$(python3 -I "$HERE/sensor_info.py" "$sub" 2>&1)
  rot=$(sed -n 's/^rotation //p' <<<"$out")
  [[ "$rot" == 180 ]] && ok "sensor reports rotation 180 (image will be upright)" || bad "sensor rotation is '$rot', expected 180"
  if grep -q '^size 1928x1088' <<<"$out"; then
    bad "sensor still offers the broken 1928x1088 mode"
  else
    ok "broken 1928x1088 mode is gone (modes: $(sed -n 's/^size //p' <<<"$out" | tr '\n' ' '))"
  fi
fi
n18=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'error group 3 code 18')
[[ $n18 -eq 0 ]] && ok "no IPU7 'error group 3 code 18' frame rejections this boot" || bad "$n18 IPU7 frame rejections this boot"

echo "Camera — desktop"
WP=$(wpctl status 2>/dev/null)
if grep -q 'ov08x40.*\[libcamera\]' <<<"$WP"; then ok "PipeWire has the libcamera camera"; else bad "PipeWire has no libcamera camera"; fi
nraw=$(grep -c 'ipu7' <<<"$WP")
[[ $nraw -eq 0 ]] && ok "raw ipu7 nodes hidden" || inf "$nraw raw ipu7 entries visible (desktop component not installed?)"
if [[ $(journalctl --user -b --no-pager 2>/dev/null | grep -c "Assertion '__n < this->size()' failed") -gt 0 ]]; then
  bad "libcamera crashed this boot (see README troubleshooting)"
else
  ok "no libcamera crashes this boot"
fi

echo "Camera — Zoom (V4L2-only apps)"
if [[ -e /dev/video42 ]] && [[ "$(cat /sys/class/video4linux/video42/name 2>/dev/null)" == "Zoom Camera" ]]; then
  ok "virtual camera /dev/video42 \"Zoom Camera\" present"
  if systemctl --user is-active --quiet xps16-camera-relay.service; then
    ok "camera relay service running"
  else
    bad "camera relay service not running (systemctl --user status xps16-camera-relay)"
  fi
  grep -q 'Zoom Camera' <<<"$WP" && bad "Zoom Camera is visible in PipeWire (it would loop back)" || ok "Zoom Camera hidden from PipeWire"
else
  inf "zoom component not installed"
fi

if [[ "${1:-}" == "--capture" ]]; then
  echo "Capture test"
  if command -v cam >/dev/null; then
    d=$(mktemp -d)
    if timeout 25 cam -c1 -C20 -s width=1280,height=720,pixelformat=ABGR8888 -F"$d/f-#.bin" >"$d/log" 2>&1; then
      ok "captured $(ls "$d"/f-* 2>/dev/null | wc -l) frames at 1280x720"
    else
      bad "cam capture failed (log: $d/log)"
    fi
  else
    inf "install libcamera-tools for the capture test"
  fi
  if [[ -e /dev/video42 ]] && command -v gst-launch-1.0 >/dev/null; then
    if timeout 20 gst-launch-1.0 -q v4l2src device=/dev/video42 num-buffers=60 ! fakesink >/dev/null 2>&1; then
      ok "read 60 frames from the Zoom Camera"
    else
      bad "could not read from the Zoom Camera"
    fi
  fi
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
