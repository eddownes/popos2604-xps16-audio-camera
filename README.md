# Audio + webcam fixes for the Dell XPS 16 (DA16260) on Pop!_OS 26.04 COSMIC

Speakers, microphones and the built-in webcam of the **Dell XPS 16 DA16260**
(Intel Core Ultra Series 3 / "Panther Lake") don't work out of the box on
**Pop!_OS 26.04 LTS (COSMIC)** with kernel **7.2.x**. This repo fixes all of
it with one script, and documents why each fix is needed.

**Status: verified working** on an XPS 16 DA16260, Pop!_OS 26.04 LTS,
kernel `7.2.15-76070215-generic`, libcamera 0.7.0, PipeWire 1.6.11,
WirePlumber 0.5.13, Firefox 160 (November 2026).

| Symptom on a fresh install | Cause | Fix in this repo |
|---|---|---|
| No sound; only "Dummy Output" | The camera's `intel_cvs` driver grabs the GPIO the four speaker amps need at boot | `audio`: load `intel_cvs` after the amps |
| Webcam image upside down | Sensor is mounted rotated 180° but firmware says 0°; this model is missing from the kernel's quirk table | `rotation`: patched `ipu-bridge` (DKMS) |
| Webcam black/green, cut off, or PipeWire crashes (sound drops too) | Sensor's 1928x1088 binned mode is rejected by the IPU7 firmware; the bad frames crash libcamera | `sensor-mode`: patched `ov08x40` (DKMS) |
| Firefox can't see the camera; ~40 "ipu7" cameras in app pickers | Firefox's PipeWire camera is off by default; raw IPU7 nodes are exposed | `desktop`: Firefox pref + WirePlumber rule |

The details are in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

---

## Quick start (fresh install)

1. Install Pop!_OS 26.04 COSMIC and **fully update it first**, then reboot:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   ```

   ```bash
   sudo reboot
   ```

2. Start **Firefox once** and close it. This creates the profile the
   installer configures. (If you skip this, run `./install.sh --only desktop`
   later.)

3. Get this repo and run the installer **as your normal user** (it asks for
   your sudo password when needed):

   ```bash
   sudo apt install -y git
   ```

   ```bash
   git clone https://github.com/eddownes/popos2604-xps16-audio-camera.git
   ```

   ```bash
   cd popos2604-xps16-audio-camera && ./install.sh
   ```

4. **Reboot.**

5. Check everything:

   ```bash
   ./tools/verify.sh --capture
   ```

   All lines should say `PASS`.

6. In apps, choose the camera named **"Built-in Front Camera"**.

Keep the cloned folder: you need it for re-running after a kernel series
change and for uninstalling.

## What the installer does

`install.sh` needs internet access. It:

- installs `dkms`, `linux-headers-$(uname -r)`, `curl`, `python3`, `gcc`,
  `make` and `libcamera-tools` if missing;
- **audio** — installs `/etc/modprobe.d/xps16-delay-intel-cvs.conf`
  (blacklists auto-loading of `intel_cvs`),
  `/usr/local/sbin/xps16-load-cvs-after-audio` and
  `xps16-load-cvs-after-audio.service` (waits up to 30 s for the four
  CS35L56/57 amps to bind, then loads `intel_cvs`);
- **rotation** — downloads `ipu-bridge.c` for **your running kernel's
  upstream version** from kernel.org, adds a DMI quirk for
  `"XPS 16 DA16260"`, and installs it as DKMS package `xps16-ipu-bridge`;
- **sensor-mode** — downloads `ov08x40.c` the same way, disables the 2-lane
  1928x1088 mode, and installs it as DKMS package `xps16-ov08x40`;
- **desktop** — adds `~/.config/wireplumber/wireplumber.conf.d/50-xps16-camera.conf`
  (hides raw `ipu7` nodes) and appends a marked block to each Firefox
  profile's `user.js` (PipeWire camera on, 1920x1080 default);
- runs `update-initramfs -u` (Pop!_OS's `kernelstub` copies it to the ESP).

If upstream already contains a fix (the quirk entry exists, or the broken
mode is gone), that module is **skipped** automatically and the stock driver
is used.

### Options

```text
./install.sh                     everything
./install.sh --only audio        one component; repeat --only for more:
                                 audio | rotation | sensor-mode | desktop
./install.sh --build-only        download, patch and compile into ./build only;
                                 changes nothing on the system
./install.sh --force             run on a model other than DA16260 (see below)
```

## Kernel updates

The DKMS modules rebuild automatically for every new kernel in the **same
upstream series** (`7.2.x`), because they are restricted with
`BUILD_EXCLUSIVE_KERNEL="^7\.2\."`. Driver sources barely change within a
stable series.

When Pop!_OS moves to a **new series** (for example 7.3), DKMS will skip
these modules and the stock drivers load instead. The camera will then be
upside down or crash again unless the new kernel already has the fixes.
After that update, re-run the installer so it fetches the new source:

```bash
./install.sh --only rotation --only sensor-mode
```

then reboot and run `./tools/verify.sh`.

## When can I remove this?

Each workaround can go once your kernel has the upstream fix. Check after
major kernel updates:

| Component | Upstream fix to look for | How to check | Remove with |
|---|---|---|---|
| audio | "media: i2c: cvs: Get the wake IRQ without claiming the GPIO" | `./uninstall.sh --only audio`, reboot: if `aplay -l` still shows `sof-soundwire` with Speaker, it's fixed | — |
| rotation | `"XPS 16 DA16260"` in `ipu-bridge.c`'s `upside_down_sensor_dmi_ids` | `./install.sh --build-only` prints "upstream already has this fix" | `./uninstall.sh --only rotation` |
| sensor-mode | ov08x40 2-lane 1928x1088 mode removed (linux-media, Sept 2026) | same as above | `./uninstall.sh --only sensor-mode` |
| desktop | not a bug; keep it | — | `./uninstall.sh --only desktop` |

Always reboot after uninstalling and run `./tools/verify.sh`.

## Uninstall

```bash
./uninstall.sh
```

or one piece at a time with `--only` (same names as above). Reboot afterwards.

## Other models

The fixes are specific to hardware IDs, not just this model:

- **audio** applies to any laptop with CS35L56/57 SoundWire amps *and*
  `intel_cvs` sharing a GPIO (Dell XPS 14/16 Panther Lake family).
- **rotation** adds a quirk for the exact DMI product name
  `XPS 16 DA16260`. On another model you'd need to edit `PRODUCT_EXPECTED`
  in `install.sh`, and only if that model's image is upside down.
- **sensor-mode** applies to any Panther Lake laptop with an OV08X40 on
  2 CSI-2 lanes (kernel log: `bind Intel CVS nlanes is 2`).

`--force` lets the installer run on other models; use it only if you've
checked the above.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Quick checks:

```bash
./tools/verify.sh
```

```bash
journalctl -b -u xps16-load-cvs-after-audio
```

```bash
journalctl -k -b | grep -iE 'cs35l56|intel_cvs|ipu7|ov08x40'
```

## What *not* to do on this setup

These were tried while working this out and are **not** needed. Some make
things worse. Details are in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md#what-didnt-work).

- Don't install Intel's out-of-tree `intel-ipu7-dkms` / camHAL / `icamerasrc`
  hardware-ISP stack. It conflicts with the in-tree ISYS driver on 7.x kernels.
- Don't blacklist `ov08x40` / `intel_ipu7` or force a module load order for
  the camera. The in-tree async registration works.
- Don't set `LIBCAMERA_SOFTISP_MODE=cpu`. The CPU debayer overflows on this
  sensor; the default GPU path is the one that works.
- Don't add a `v4l2loopback` / `v4l2-relayd` virtual camera. It isn't needed
  once the sensor mode is fixed, and it ran at 1–8 fps here.

## License

MIT for the scripts and docs in this repo; see [LICENSE](LICENSE). The
kernel sources the installer downloads and patches are GPL-2.0, from
kernel.org.
