"""Write 128-byte EDID 1.4 blocks that look like the monitors in layout.nix.

The identity fields (made up) carry what KWin keys on (`edidIdentifier`:
vendor, product code, serial number, week, year, model year) and what GNOME
keys on (product-name and serial-string descriptors), so both compositors
match them as they would real hardware. One detailed timing per monitor: the
mode the layout asks for, at exactly 60.000 Hz.

usage: python3 edid.py OUTDIR
"""

import os
import sys


def pnp(code):
    a, b, c = (ord(ch) - 64 for ch in code)
    v = (a << 10) | (b << 5) | c
    return bytes([v >> 8, v & 0xFF])


def dtd(clock_khz, ha, hb, hfp, hsw, va, vb, vfp, vsw, hmm, vmm):
    c = clock_khz // 10
    return bytes(
        [
            c & 0xFF,
            c >> 8,
            ha & 0xFF,
            hb & 0xFF,
            ((ha >> 8) << 4) | (hb >> 8),
            va & 0xFF,
            vb & 0xFF,
            ((va >> 8) << 4) | (vb >> 8),
            hfp & 0xFF,
            hsw & 0xFF,
            ((vfp & 0xF) << 4) | (vsw & 0xF),
            ((hfp >> 8) << 6) | ((hsw >> 8) << 4) | ((vfp >> 4) << 2) | (vsw >> 4),
            hmm & 0xFF,
            vmm & 0xFF,
            ((hmm >> 8) << 4) | (vmm >> 8),
            0,
            0,
            0x1E,  # digital separate sync, both polarities positive
        ]
    )


def text(tag, s):
    body = s.encode("ascii")[:13]
    if len(body) < 13:
        body += b"\n" + b" " * (12 - len(body))
    return bytes([0, 0, 0, tag, 0]) + body


def dummy():
    return bytes([0, 0, 0, 0x10, 0]) + bytes(13)


def edid(vendor, product, serial, week, year, name, serial_str, timing, cm=(53, 30)):
    b = bytearray()
    b += bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
    b += pnp(vendor)
    b += product.to_bytes(2, "little")
    b += serial.to_bytes(4, "little")
    b += bytes([week, year - 1990, 1, 4])
    b += bytes([0xA5, cm[0], cm[1], 120, 0x2E])  # digital 8bpc DP, size in cm, gamma 2.2, RGB, sRGB
    b += bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])  # sRGB-ish chromaticity
    b += bytes([0x21, 0x08, 0x00])  # 640x480@60, 800x600@60, 1024x768@60
    b += bytes([1, 1] * 8)  # no standard timings
    descs = [timing, text(0xFC, name)]
    descs.append(text(0xFF, serial_str) if serial_str else dummy())
    descs.append(dummy())
    for d in descs:
        b += d
    b += bytes([0])  # no extensions
    b += bytes([(256 - sum(b) % 256) % 256])
    assert len(b) == 128
    return bytes(b)


# CTA-861 1080p60 and 2160p60 timings: 148.5 MHz / (2200 * 1125) and
# 594 MHz / (4400 * 2250), both exactly 60.000 Hz.
fhd = dtd(148500, 1920, 280, 88, 44, 1080, 45, 4, 5, 531, 299)
uhd = dtd(594000, 3840, 560, 176, 88, 2160, 90, 8, 10, 1429, 804)

monitors = {
    # KWin: "EXA 4097 16843009 10 2019 0", GNOME: Example 22 / EX22A0000001
    "left.bin": edid("EXA", 4097, 16843009, 10, 2019, "Example 22", "EX22A0000001", fhd),
    # KWin: "EXA 4098 16843009 20 2019 0", GNOME: Example 24 / EX24A0000002
    "center.bin": edid("EXA", 4098, 16843009, 20, 2019, "Example 24", "EX24A0000002", fhd),
    # KWin: "EXT 8193 16843009 0 2020 0", GNOME: Example-TV / 0x01010101
    # (week 0 = no week given; no serial-string descriptor, as on the TV)
    "tv.bin": edid("EXT", 8193, 16843009, 0, 2020, "Example-TV", None, uhd, cm=(143, 80)),
}

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name, blob in monitors.items():
    with open(os.path.join(out, name), "wb") as f:
        f.write(blob)
