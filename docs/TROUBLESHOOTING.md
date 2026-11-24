# Troubleshooting

Start with:

```bash
./tools/verify.sh --capture
```

Each `FAIL` line maps to a section below.

## "only N of 4 speaker amps bound" / no sound card

1. Is the boot service there and did it run?

   ```bash
   systemctl status xps16-load-cvs-after-audio
   ```

   ```bash
   journalctl -b -u xps16-load-cvs-after-audio
   ```

   It should say `cs35l56 amps bound: 4 ... loading intel_cvs`.
2. Did `intel_cvs` load early anyway (for example from the initramfs)?

   ```bash
   journalctl -k -b | grep -E 'intel_cvs|spk-id'
   ```

   If `Failed to get spk-id-gpios` appears before the service ran, rebuild
   the initramfs (`sudo update-initramfs -u`) and reboot.
3. Amps bound but no card? Look for SOF errors:

   ```bash
   journalctl -k -b | grep -iE 'sof|sdw|tplg'
   ```

   You need `firmware-sof-signed` and `linux-firmware`; both are on Pop!_OS
   by default.

## Image upside down ("sensor rotation is '0'")

The patched `ipu-bridge` isn't loaded.

```bash
modinfo -n ipu_bridge
```

```bash
dkms status
```

`modinfo` should point into `updates/dkms/`. If DKMS shows the package as
not built for your kernel (new kernel series), re-run
`./install.sh --only rotation` and reboot.

## Black/green video, PipeWire crashes, "sensor still offers the broken 1928x1088 mode"

The patched `ov08x40` isn't loaded. Same checks as above with `ov08x40`, then
`./install.sh --only sensor-mode` and reboot. Confirm:

```bash
journalctl -k -b | grep -c 'error group 3 code 18'
```

It should print `0`.

If PipeWire *did* crash, restart it and fully restart Firefox:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## "PipeWire has no libcamera camera"

```bash
journalctl --user -b | grep -iE 'libcamera|No valid pipeline'
```

- `No valid pipeline for sensor 'ov08x40'` after `intel_cvs` was reloaded at
  runtime → reboot.
- `libspa-0.2-libcamera` is part of Pop!_OS's PipeWire; check it is
  installed with `dpkg -l | grep libspa-0.2-libcamera`.

## Firefox doesn't list the camera

- `about:config` → `media.webrtc.camera.allow-pipewire` must be `true`.
  If not, run `./install.sh --only desktop` and restart Firefox.
- Pick **"Built-in Front Camera"**.

## Picture is cut off on one website

The site asked for a non-16:9 size (for example 3840x1080). That's expected;
see [HOW-IT-WORKS.md](HOW-IT-WORKS.md#3-crashes-blackgreen-video-cut-off-picture).
Video-call sites (Meet, Zoom, Teams) use 16:9 and show the full view.

## Image looks soft or washed out near windows

That's the libcamera software ISP with no tuning file for this sensor
(`ov08x40.yaml` not found, using `uncalibrated.yaml`). It's not something
this repo fixes.

## After a kernel update

```bash
dkms status
```

If the `xps16-*` packages aren't `installed` for the new kernel (new upstream
series, e.g. 7.2 → 7.3):

```bash
./install.sh --only rotation --only sensor-mode
```

The installer skips any fix the new kernel already includes.

## Secure Boot

If Secure Boot is on, DKMS modules must be signed with a Machine Owner Key.
Ubuntu's `dkms` signs them with `/var/lib/shim-signed/mok/MOK.der` and asks
you to enroll it at the next boot (blue MOK Manager screen → Enroll MOK). If
you skip enrollment, the patched modules won't load and the stock ones are
used.
