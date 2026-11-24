#!/usr/bin/env python3
"""Disable the OV08X40 2-lane 1928x1088 2x2-binned mode.

On Panther Lake (IPU7) the ISYS firmware rejects every frame of this mode
(kernel log: "error group 3 code 18"). The driver still returns the buffers as
done with only one line written and the rest left as 0xffff. libcamera's
software ISP indexes lookup tables with those values and aborts, taking
PipeWire down with it (black/green video, audio drops). The same fix was posted
to linux-media in Sept 2026 ("media: i2c: ov08x40: ... binned mode").

Usage: patch_ov08x40.py <ov08x40.c>
Exit codes: 0 patched, 3 mode already absent (nothing to do), 1 error.
"""
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARKER = "popos2604-xps16: 2-lane 1928x1088"
if MARKER in src:
    print("ov08x40: already patched; nothing to do")
    sys.exit(3)

modes = re.search(r"static const struct ov08x40_mode supported_modes\[\] = \{", src)
if not modes:
    sys.exit("supported_modes table not found; source layout changed")
end = src.find("\n};", modes.end())
table = src[modes.end():end]

# Find each top-level { ... }, entry in the table and pick the 2-lane 1928x1088 one.
target = None
depth = 0
start = None
for i, ch in enumerate(table):
    if ch == "{":
        if depth == 0:
            start = i
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0 and start is not None:
            block = table[start:i + 1]
            if (re.search(r"\.width\s*=\s*1928\b", block)
                    and re.search(r"\.height\s*=\s*1088\b", block)
                    and re.search(r"\.lanes\s*=\s*2\b", block)):
                target = (start, i + 1)
            start = None

if target is None:
    print("ov08x40: no 2-lane 1928x1088 mode present; no patch needed")
    sys.exit(3)

s, e = target
# include the trailing comma
if table[e:e + 1] == ",":
    e += 1
line_start = table.rfind("\n", 0, s) + 1
new_table = (
    table[:line_start]
    + "#if 0 /* popos2604-xps16: 2-lane 1928x1088 binned mode is rejected by IPU7 ISYS */\n"
    + table[line_start:e]
    + "\n#endif"
    + table[e:]
)
src = src[:modes.end()] + new_table + src[end:]
open(path, "w", encoding="utf-8").write(src)
print("ov08x40: disabled the 2-lane 1928x1088 binned mode")
