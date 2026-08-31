#!/usr/bin/env python3
"""Assert an .icns carries the large representations App Store Connect needs.

ASC reads the store icon from the bundle's AppIcon.icns. actool writes one that
stops at 256, so without the iconutil rebuild in embed-full-appicon.sh the
listing gets a 256px image and upscales it. This turns that into a build
failure instead of a soft logo nobody notices until review.
"""
import struct
import sys

# icns element types for the two sizes that matter to the store listing.
REQUIRED = {"ic09": "512x512", "ic10": "1024x1024 (512x512@2x)"}


def elements(path):
    data = open(path, "rb").read()
    if data[:4] != b"icns":
        sys.exit(f"{path} is not an icns file")
    total = struct.unpack(">I", data[4:8])[0]
    offset, found = 8, set()
    while offset < total:
        found.add(data[offset:offset + 4].decode("latin1"))
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length <= 0:
            break
        offset += length
    return found


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: verify-appicon-icns.py <path to .icns>")
    found = elements(sys.argv[1])
    missing = [f"{t} ({REQUIRED[t]})" for t in sorted(REQUIRED) if t not in found]
    if missing:
        sys.exit(
            "AppIcon.icns is missing " + ", ".join(missing)
            + " -- App Store Connect would upscale a small icon."
        )
    print("AppIcon.icns carries the 512 and 1024 representations")


if __name__ == "__main__":
    main()
