#!/usr/bin/env python3
"""Add the Dell XPS 16 DA16260 to ipu-bridge's upside-down sensor DMI table.

The OV08X40 (ACPI HID OVTI08F4) in this laptop is mounted rotated 180 degrees,
but the firmware's SSDB reports 0, so libcamera shows the image upside down.
ipu-bridge has a DMI quirk table for exactly this; this model is not in it.

Usage: patch_ipu_bridge.py <ipu-bridge.c> <product-name>
Exit codes: 0 patched, 3 already present upstream (nothing to do), 1 error.
"""
import re
import sys

path, product = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

if f'"{product}"' in src:
    print(f"ipu-bridge already lists {product!r}; no patch needed")
    sys.exit(3)

table = re.search(r"static const struct dmi_system_id upside_down_sensor_dmi_ids\[\] = \{", src)
if not table:
    sys.exit("upside_down_sensor_dmi_ids table not found; source layout changed")

term = re.compile(r"\n(\t\{\s*\}\s*(?:/\*[^*]*\*/)?\s*\n\};)")
m = term.search(src, table.end())
if not m:
    sys.exit("terminating entry of upside_down_sensor_dmi_ids not found")

entry = (
    "\n\t{\n"
    f"\t\t/* {product} (Panther Lake): OV08X40 mounted upside down, SSDB says 0 */\n"
    "\t\t.matches = {\n"
    '\t\t\tDMI_EXACT_MATCH(DMI_SYS_VENDOR, "Dell Inc."),\n'
    f'\t\t\tDMI_EXACT_MATCH(DMI_PRODUCT_NAME, "{product}"),\n'
    "\t\t},\n"
    '\t\t.driver_data = "OVTI08F4",\n'
    "\t},"
)
src = src[: m.start()] + entry + src[m.start():]
open(path, "w", encoding="utf-8").write(src)
print(f"ipu-bridge: added upside-down quirk for {product!r}")
