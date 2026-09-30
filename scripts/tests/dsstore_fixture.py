#!/usr/bin/env python3
"""Write a small synthetic .DS_Store for make_dmg.bats. A helper of that file only.

    python3 dsstore_fixture.py OUT [--volume NAME] [--background PATH]
                                   [--icon NAME X Y]... [--no-icons] [--no-alias]
                                   [--window BOUNDS] [--tree]

The layout has one B-tree leaf holding the records Finder keeps for a disk image
window: "bwsp" (window bounds), "icvp" (the background alias) and "vSrn" on ".",
and an "Iloc" per icon. It is written from the same format notes as
scripts/dsstore-layout.py, so it proves the reader's logic and error handling,
not that Finder accepts the file: the first real dmgbuild layout does that.
--tree writes the same records as a two-level tree (an internal node, a child on
its left and a right-most child), to cover the walk over child blocks.

Defaults: volume RoomForMac, background /.background.tiff, icons
RoomForMac.app at 165 120 and Applications at 495 120, window {{200, 120}, {660, 400}}.
"""

import plistlib
import struct
import sys


def alias_record(volume, path):
    name = path.rsplit("/", 1)[-1]
    fixed = struct.pack(
        ">h28pI2shI64pII4s4shhI2s10s",
        0,
        volume.encode("mac_roman", "replace"),
        3600000000,
        b"H+",
        5,
        2,
        name.encode("utf-8"),
        16,
        3600000001,
        b"\0\0\0\0",
        b"\0\0\0\0",
        -1,
        -1,
        0,
        b"\0\0",
        b"\0" * 10,
    )
    extras = b""
    units = volume.encode("utf-16-be")
    tagged = [
        (0, volume.encode("utf-8")),
        (2, (volume + ":" + path[1:].replace("/", ":")).encode("utf-8")),
        (15, struct.pack(">H", len(volume)) + units),
        (18, path.encode("utf-8")),
        (19, ("/Volumes/" + volume).encode("utf-8")),
    ]
    for tag, value in tagged:
        extras += struct.pack(">hh", tag, len(value)) + value
        if len(value) & 1:
            extras += b"\0"
    extras += struct.pack(">hh", -1, 0)
    body = fixed + extras
    return struct.pack(">4shh", b"\0\0\0\0", 8 + len(body), 2) + body


def record(name, code, kind, payload):
    units = name.encode("utf-16-be")
    return (
        struct.pack(">I", len(name))
        + units
        + code.encode("latin-1")
        + kind.encode("latin-1")
        + payload
    )


def blob(data):
    return struct.pack(">I", len(data)) + data


def build_records(options):
    records = []
    folder = []
    if options["window"] is not None:
        bounds = plistlib.dumps(
            {"WindowBounds": options["window"], "ShowToolbar": False, "ShowSidebar": False},
            fmt=plistlib.FMT_BINARY,
        )
        folder.append(record(".", "bwsp", "blob", blob(bounds)))
    view = {"backgroundType": 2, "iconSize": 128.0, "showIconPreview": False}
    if options["alias"]:
        view["backgroundImageAlias"] = alias_record(
            options["volume"], options["background"]
        )
    folder.append(
        record(".", "icvp", "blob", blob(plistlib.dumps(view, fmt=plistlib.FMT_BINARY)))
    )
    folder.append(record(".", "vSrn", "long", struct.pack(">I", 1)))
    records.append((".", folder))
    for name, x, y in options["icons"]:
        iloc = struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000)
        records.append((name, [record(name, "Iloc", "blob", blob(iloc))]))
    records.sort(key=lambda item: item[0].lower())
    return [chunk for _, chunks in records for chunk in chunks]


def block_bytes(data, size):
    if len(data) > size:
        raise SystemExit("fixture block overflow")
    return data.ljust(size, b"\0")


def build_file(options):
    records = build_records(options)
    leaf = struct.pack(">II", 0, len(records)) + b"".join(records)
    blocks = {}
    # Block numbers and where they live (offsets are relative to file offset 4).
    blocks[0] = (0, 5, b"Bud1")
    dsdb = struct.pack(">IIIII", 2, 1 if options["tree"] else 0, len(records), 1, 4096)
    blocks[1] = (32, 5, dsdb)
    if options["tree"]:
        # Node 2 is an internal node: child 4 holds the first two records, then
        # comes the internal record, and the right-most child 5 holds the rest.
        node2 = struct.pack(">II", 5, 1) + struct.pack(">I", 4) + records[2]
        blocks[2] = (4096, 12, node2)
        blocks[4] = (8192, 12, struct.pack(">II", 0, 2) + b"".join(records[:2]))
        blocks[5] = (
            12288,
            12,
            struct.pack(">II", 0, len(records) - 3) + b"".join(records[3:]),
        )
    else:
        blocks[2] = (4096, 12, leaf)
    top = max(blocks) + 1
    addresses = [0] * top
    for number, (offset, log2, _) in blocks.items():
        addresses[number] = offset | log2
    addresses.append(2048 | 11)
    count = len(addresses)
    table = struct.pack(">II", count, 0)
    padded = addresses + [0] * (((count + 255) // 256) * 256 - count)
    table += struct.pack(">%uI" % len(padded), *padded)
    table += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    table += b"".join(struct.pack(">I", 0) for _ in range(32))
    root = block_bytes(table, 2048)
    size = 4 + (16384 if options["tree"] else 8192)
    image = bytearray(size)
    image[0:4] = struct.pack(">I", 1)
    image[4:8] = b"Bud1"
    image[8:20] = struct.pack(">III", 2048, 2048, 2048)
    image[4 + 2048 : 4 + 2048 + 2048] = root
    image[4 + 32 : 4 + 32 + len(dsdb)] = dsdb
    for number, (offset, log2, payload) in blocks.items():
        if number in (0, 1):
            continue
        image[4 + offset : 4 + offset + len(payload)] = payload
    return bytes(image)


def main(argv):
    if len(argv) < 2 or argv[1].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    options = {
        "volume": "RoomForMac",
        "background": "/.background.tiff",
        "icons": [("RoomForMac.app", 165, 120), ("Applications", 495, 120)],
        "alias": True,
        "window": "{{200, 120}, {660, 400}}",
        "tree": False,
    }
    out = argv[1]
    custom_icons = []
    arguments = argv[2:]
    while arguments:
        flag = arguments.pop(0)
        if flag == "--volume":
            options["volume"] = arguments.pop(0)
        elif flag == "--background":
            options["background"] = arguments.pop(0)
        elif flag == "--icon":
            custom_icons.append((arguments.pop(0), int(arguments.pop(0)), int(arguments.pop(0))))
        elif flag == "--no-icons":
            options["icons"] = []
        elif flag == "--no-alias":
            options["alias"] = False
        elif flag == "--window":
            options["window"] = arguments.pop(0)
        elif flag == "--tree":
            options["tree"] = True
        else:
            print("unknown option " + flag, file=sys.stderr)
            return 2
    options["icons"] = options["icons"] + custom_icons
    with open(out, "wb") as handle:
        handle.write(build_file(options))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
