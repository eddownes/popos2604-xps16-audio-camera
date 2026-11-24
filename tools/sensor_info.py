#!/usr/bin/env python3
"""Print the OV08X40 sensor's rotation control and the frame sizes it offers.

Usage: sensor_info.py /dev/v4l-subdevN
Prints "rotation <deg>" and one "size WxH" line per mode, using raw V4L2
ioctls so no extra packages (v4l-utils) are needed.
"""
import fcntl
import os
import struct
import sys


def iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("V") << 8) | nr


VIDIOC_QUERY_EXT_CTRL = iowr(103, 232)
VIDIOC_SUBDEV_G_FMT = iowr(4, 88)
VIDIOC_SUBDEV_ENUM_FRAME_SIZE = iowr(74, 64)
V4L2_CID_CAMERA_SENSOR_ROTATION = 0x009A0923

fd = os.open(sys.argv[1], os.O_RDWR)

q = bytearray(232)
struct.pack_into("I", q, 0, V4L2_CID_CAMERA_SENSOR_ROTATION)
try:
    fcntl.ioctl(fd, VIDIOC_QUERY_EXT_CTRL, q)
    print("rotation", struct.unpack_from("q", q, 64)[0])  # default_value
except OSError:
    print("rotation unknown")

fmt = bytearray(88)
struct.pack_into("II", fmt, 0, 1, 0)  # ACTIVE, pad 0
fcntl.ioctl(fd, VIDIOC_SUBDEV_G_FMT, fmt)
code = struct.unpack_from("I", fmt, 16)[0]

i = 0
while True:
    e = bytearray(64)
    struct.pack_into("III", e, 0, i, 0, code)
    struct.pack_into("I", e, 28, 1)  # which = ACTIVE
    try:
        fcntl.ioctl(fd, VIDIOC_SUBDEV_ENUM_FRAME_SIZE, e)
    except OSError:
        break
    min_w, _max_w, min_h, _max_h = struct.unpack_from("IIII", e, 12)
    print(f"size {min_w}x{min_h}")
    i += 1
