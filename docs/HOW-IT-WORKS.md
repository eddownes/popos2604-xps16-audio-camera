# How it works

The diagnosis behind each fix, with the log lines that identify the problem.
Hardware referred to:

| Part | ID | Driver |
|---|---|---|
| Audio DSP | Intel HD Audio `8086:e428` | `sof-audio-pci-intel-ptl` (SOF, SoundWire) |
| Codec (jack, mics) | Cirrus CS42L45, SoundWire link 0, part `0x4245` | `snd_soc_sdca_class` |
| Speaker amps ×4 | Cirrus CS35L57, SoundWire links 2+3, part `0x3557` | `cs35l56` |
| Camera ISP | Intel Panther Lake IPU7 `8086:b05d` | `intel_ipu7`, `intel_ipu7_isys` (staging) |
| Camera sensor | OmniVision OV08X40, ACPI `OVTI08F4`, 2 CSI-2 lanes | `ov08x40` |
| Camera ownership | Intel CVS, ACPI `INTC10E1` (via USB-IO bridge) | `intel_cvs` |
| Bridge | — | `ipu_bridge` (builds sensor fwnodes from ACPI SSDB) |

## 1. No sound

**Symptom:** `aplay -l` says `no soundcards found`; PipeWire only has
"Dummy Output".

**Log:**

```text
cs35l56 sdw:0:2:01fa:3557:01:2: error -EBUSY: Failed to get spk-id-gpios
cs35l56 sdw:0:2:01fa:3557:01:2: probe with driver cs35l56 failed with error -16
...(same for all four amps)
```

**Cause:** the four amps read a *speaker ID* GPIO at probe time, to choose
the right tuning file (`cs35l57-b2-dsp1-misc-10280dba-spkid0*.bin`). On this
board that pin is **GPIO 20**, which is also the Intel CVS *wake* line.
`intel_cvs` requests it with `devm_gpiod_get()` and keeps it. If `intel_cvs`
probes first, which it does on a normal boot, every amp gets `-EBUSY` and
never retries. The `sof_sdw` machine driver then never creates the card.
With the amps unbound, the result is no card at all, not a card missing
only its speakers.

Proof (`/sys/kernel/debug/gpio` with intel_cvs loaded):

```text
gpio-20  (                    |wake                ) in  lo IRQ ACTIVE LOW
```

Unbinding `intel_cvs`, re-probing the amps, and rebinding `intel_cvs` creates
the `sof-soundwire` card at once.

**Upstream fix:** "media: i2c: cvs: Get the wake IRQ without claiming the
GPIO" (Cc: stable). It wasn't in Pop!_OS's 7.2.15 kernel.

**Workaround here:** blacklist `intel_cvs` auto-loading, and have a oneshot
service load it once `/sys/bus/soundwire/drivers/cs35l56/` has 4 devices
(within about 1 s of boot in practice, 30 s timeout). The amps only *read*
the GPIO during probe and release it, so `intel_cvs` can take it afterwards
and the camera still works. The camera's async v4l2 notifier completes when
`intel_cvs` arrives later.

> Don't unbind/rebind `intel_cvs` at runtime as a "quick fix". It
> re-registers the sensor without recreating its `/dev/v4l-subdev*` node, and
> libcamera then fails with "No valid pipeline for sensor 'ov08x40'" until
> reboot.

## 2. Upside-down image

**Check:**

```bash
python3 tools/sensor_info.py /dev/v4l-subdevN   # the ov08x40 subdev
```

`rotation 0` means not fixed; `rotation 180` means fixed.

**Cause:** libcamera rotates the image according to the sensor's
`V4L2_CID_CAMERA_SENSOR_ROTATION`. `ipu_bridge` fills that from the ACPI SSDB
`degree` field, which Dell set to 0 even though the module is mounted
upside down. The kernel has `upside_down_sensor_dmi_ids[]` in
`drivers/media/pci/intel/ipu-bridge.c` for exactly this. It covers the XPS 13
9340/9350, XPS 14 9440, XPS 16 9640, DA14250, DA16250 and the Panther Lake
"Dell Pro 14 Premium PA14260" (`OVTI08F4`). It does **not** include the XPS 16
DA16260, as of mainline in November 2026.

**Fix here:** the same kind of entry, `DMI_PRODUCT_NAME "XPS 16 DA16260"` →
`OVTI08F4`, in a DKMS-built `ipu-bridge`. See `lib/patch_ipu_bridge.py`.

## 3. Crashes, black/green video, cut-off picture

This one took the longest. Several symptoms turned out to have one cause.

**Symptoms seen:**
- Firefox shows solid green or black video;
- PipeWire core-dumps (`pipewire.service: Main process exited, code=dumped,
  status=6/ABRT`), so **audio briefly drops** too;
- `cam` crashes at almost any size except the native modes;
- some sizes "work" but show only part of the picture.

**Log (user journal):**

```text
INFO Camera camera.cpp:1215 configuring streams: (0) 854x480-ABGR8888/sRGB
/usr/include/c++/15/array:210: ... std::array<unsigned int, 64> ... Assertion '__n < this->size()' failed.
```

or, in the CPU debayer, `std::array<double, 1024>`.

**Kernel log at the same time:**

```text
intel_ipu7_isys.isys intel_ipu7.isys.40:         error group 3 code 18 details [0 0]
```

**Cause:** the OV08X40 driver offers a 2-lane **1928x1088 2x2-binned** mode.
On IPU7 the ISYS firmware rejects every frame in this mode (error group 3,
code 18, a frame-dimension rejection). The driver still completes the buffer
as if it were fine. Capturing the raw Bayer stream directly shows it:

```text
row 0     valid 10-bit data
rows 1..1087   all 0xffff (65535)
```

libcamera's software ISP uses pixel values as indexes into lookup tables:
the 64-bin statistics histogram (10-bit value >> 4) and the 1024-entry
debayer table. 65535 overflows both, and the C++ assertion aborts the
process. In a desktop session that process is **PipeWire**, which runs the
libcamera SPA plugin.

libcamera's simple pipeline picks this mode for any requested size at or below
1928x1088, which covers nearly everything a browser asks for. It only avoided
the crash at sizes larger than that (3840x2160, 3840x1080). Those use the full
3856x2176 mode, which works.

**Fix here:** remove that one entry from `supported_modes[]` in
`drivers/media/i2c/ov08x40.c` (see `lib/patch_ov08x40.py`). The same change
was posted to linux-media in September 2026 ("media: i2c: ov08x40: ...",
patch 2/2, which says the binned mode "does not deliver usable frames" on
IPU7). With only the full mode left:

- every size works, with no crashes and no code-18 errors;
- libcamera's **GPU** software ISP *scales* the full frame to the requested
  size, so 1280x720 and 1920x1080 show the whole field of view;
- the GPU debayer took about 9 ms per 4K frame here, about 30 fps at 1280x720.

**Remaining limitation:** a page that asks for an unusual aspect ratio, such
as 3840x1080 (32:9), gets the full width but only part of the height. That's
the shape requested, not a bug. Video-call sites use 16:9 sizes.

## 4. Desktop integration

- **Firefox:** `media.webrtc.camera.allow-pipewire` is off by default, so
  Firefox only looks at V4L2 devices, and the raw `ipu7` nodes give nothing
  usable. With it on, Firefox uses the PipeWire camera portal and sees the
  libcamera camera ("Built-in Front Camera"). Defaulting to 1920x1080 keeps
  pages that ask for no size from getting an odd one.
- **WirePlumber:** the IPU7 ISYS exposes about 40 `/dev/video*` capture
  nodes, all named "ipu7". They show up in every app's camera picker and
  never produce a picture. The rule hides devices with
  `device.product.name = "ipu7"`.

## What didn't work

Recorded so nobody repeats it:

| Attempt | Result |
|---|---|
| Intel `intel-ipu7-dkms` + camHAL + `icamerasrc` (hardware ISP) | PSYS can't coexist with the in-tree ISYS on 7.x ([intel/ipu7-drivers#63](https://github.com/intel/ipu7-drivers/issues/63)); not needed |
| Blacklisting `ov08x40`/`intel_ipu7` and forcing a modprobe order (older Ubuntu/CachyOS approach) | Unnecessary on 7.2: registration completes. The blacklist would only break things |
| Unbinding/rebinding `intel_cvs` at runtime | Fixes audio for that session, breaks the camera until reboot |
| `LIBCAMERA_SOFTISP_MODE=cpu` for PipeWire | Still crashed (debayer LUT overflow) |
| `v4l2loopback` + `v4l2-relayd` 1280x720 virtual camera from the full mode | Picture fine, but 1–8 fps inside the service; never found why. Not needed after the sensor-mode fix |

## References

- [Upstream DMI quirk for Dell XPS upside-down sensors](http://www.mail-archive.com/linuxtv-commits@linuxtv.org/msg48338.html)
- [linux-media: ov08x40 patch 2/2 (binned mode)](https://ratatoskr.run/linux-media/2026/09/17514489/t) and [1/2](https://ratatoskr.run/linux-media/2026/09/17514488)
- [omarchy-pkgs PR #147: carries the CVS wake-IRQ fix](https://github.com/omacom/omarchy-pkgs/pull/147)
- [Kernel docs: CS35L54/56/57/63 drivers](https://docs.kernel.org/sound/codecs/cs35l56.html)
- [Red Hat bug 2415297: SoftISP crop behaviour](https://bugzilla.redhat.com/show_bug.cgi?id=2415297)
- [CachyOS: IPU7 on Panther Lake Dell XPS guide](https://github.com/CachyOS/linux-cachyos/issues/804)
