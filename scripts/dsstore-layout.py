#!/usr/bin/env python3
"""Read the Finder window layout out of a .DS_Store file. Read-only, stdlib only.

    python3 scripts/dsstore-layout.py <DS_Store> [--records]

Prints one JSON object:

    {"volume": "RoomForMac", "background": "/.background.tiff",
     "window": "{{200, 120}, {660, 400}}", "icons": {"RoomForMac.app": [165, 120]}}

volume and background come from the alias record Finder keeps for the window's
background picture (the "backgroundImageAlias" of the "icvp" record of "."): the
name of the volume and the path on it. Finder finds the picture again by that
name and path, so a layout made for another volume name draws no background.
window is the WindowBounds string of the "bwsp" record. icons maps each item's
name to the position of its "Iloc" record. A field the file does not hold is an
empty string, or absent from icons. --records adds a "records" list with every
record in the file, values decoded.

The file format is a buddy allocator holding a B-tree of records (Mark Mentovai's
notes, and the ds_store and mac_alias Python packages, describe it). This reader
follows only what it needs, and refuses anything it does not understand.

Exit status: 0 done; 1 the file is not a readable .DS_Store; 2 usage error.
"""

import datetime
import json
import plistlib
import struct
import sys

MAX_DEPTH = 16
MAX_RECORDS = 100000


class LayoutError(Exception):
    """The file is not a .DS_Store this reader understands."""


class Cursor:
    """Sequential big-endian reads over bytes, refusing to run past the end."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, size):
        if size < 0 or self.pos + size > len(self.data):
            raise LayoutError("the file is truncated or damaged")
        chunk = self.data[self.pos : self.pos + size]
        self.pos += size
        return chunk

    def unpack(self, fmt):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))


class Store:
    """The buddy allocator: numbered blocks, and a table of contents."""

    def __init__(self, data):
        self.data = data
        if len(data) < 36:
            raise LayoutError("too short to be a .DS_Store file")
        magic1, magic2, offset, size, offset2 = struct.unpack(">I4sIII", data[:20])
        if magic1 != 1 or magic2 != b"Bud1":
            raise LayoutError("not a .DS_Store file (no Bud1 header)")
        if offset != offset2:
            raise LayoutError("the header names two different root blocks")
        root = Cursor(self.raw(offset, size))
        (count, _unknown) = root.unpack(">II")
        slots = ((count + 255) // 256) * 256
        self.addresses = list(root.unpack(">%uI" % slots))[:count]
        self.toc = {}
        (entries,) = root.unpack(">I")
        for _ in range(entries):
            (name_length,) = root.unpack(">B")
            name = root.take(name_length)
            (block_id,) = root.unpack(">I")
            self.toc[name] = block_id

    def raw(self, offset, size):
        start = offset + 4
        if size < 0 or start + size > len(self.data):
            raise LayoutError("a block lies outside the file")
        return self.data[start : start + size]

    def block(self, block_id):
        if block_id >= len(self.addresses) or self.addresses[block_id] == 0:
            raise LayoutError("a record refers to a block that does not exist")
        address = self.addresses[block_id]
        return Cursor(self.raw(address & ~0x1F, 1 << (address & 0x1F)))


def read_record(cursor):
    """One record: (item name, four-letter code, type, value)."""
    (name_length,) = cursor.unpack(">I")
    name = cursor.take(2 * name_length).decode("utf-16-be")
    code = cursor.take(4).decode("latin-1")
    kind = cursor.take(4).decode("latin-1")
    if kind == "bool":
        (value,) = cursor.unpack(">?")
    elif kind in ("long", "shor"):
        (value,) = cursor.unpack(">I")
    elif kind == "blob":
        (length,) = cursor.unpack(">I")
        value = cursor.take(length)
    elif kind == "ustr":
        (length,) = cursor.unpack(">I")
        value = cursor.take(2 * length).decode("utf-16-be")
    elif kind == "type":
        value = cursor.take(4).decode("latin-1")
    elif kind in ("comp", "dutc"):
        (value,) = cursor.unpack(">Q")
    else:
        raise LayoutError("unknown record type %r" % kind)
    return name, code, kind, value


def walk(store, block_id, depth, seen):
    """Yield every record under a B-tree node, in file order."""
    if depth > MAX_DEPTH or block_id in seen:
        raise LayoutError("the record tree is damaged")
    seen.add(block_id)
    node = store.block(block_id)
    (right_most, count) = node.unpack(">II")
    if count > MAX_RECORDS:
        raise LayoutError("the record tree is damaged")
    if right_most:
        for _ in range(count):
            (child,) = node.unpack(">I")
            for record in walk(store, child, depth + 1, seen):
                yield record
            yield read_record(node)
        for record in walk(store, right_most, depth + 1, seen):
            yield record
    else:
        for _ in range(count):
            yield read_record(node)


def read_records(data):
    store = Store(data)
    if b"DSDB" not in store.toc:
        raise LayoutError("the file has no DSDB record tree")
    superblock = store.block(store.toc[b"DSDB"])
    (root_node, _levels, _records, _nodes, _page) = superblock.unpack(">IIIII")
    return list(walk(store, root_node, 0, set()))


def parse_alias(blob):
    """(volume name, path on the volume) from an old-style Mac alias record."""
    if len(blob) < 150:
        raise LayoutError("the background alias is too short")
    _appinfo, size, version = struct.unpack(">4shh", blob[:8])
    if version != 2:
        raise LayoutError("unsupported alias version %d" % version)
    fixed = struct.unpack(">h28pI2shI64pII4s4shhI2s10s", blob[8:150])
    volume = fixed[1].decode("mac_roman", "replace")
    extras = {}
    cursor = Cursor(blob[: max(size, 150)])
    cursor.pos = 150
    while cursor.pos + 4 <= len(cursor.data):
        tag, length = cursor.unpack(">hh")
        if tag == -1:
            break
        value = cursor.take(length + (length & 1))[:length]
        extras[tag] = value
    if 15 in extras:
        (units,) = struct.unpack(">H", extras[15][:2])
        volume = extras[15][2 : 2 + 2 * units].decode("utf-16-be")
    path = ""
    if 18 in extras:
        path = extras[18].decode("utf-8", "replace")
        mount = extras.get(19, b"").decode("utf-8", "replace")
        if len(mount) > 1 and path.startswith(mount + "/"):
            path = path[len(mount) :]
    elif 2 in extras:
        parts = extras[2].decode("utf-8", "replace").split(":")
        path = "/" + "/".join(parts[1:])
    return volume, path


def load_plist(blob):
    try:
        value = plistlib.loads(blob)
    except Exception:
        return None
    return value if isinstance(value, dict) else None


def jsonable(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    return value


def describe(records):
    """The layout summary, and the records with their values decoded."""
    layout = {"volume": "", "background": "", "window": "", "icons": {}}
    decoded = []
    for name, code, kind, value in records:
        shown = value
        if kind == "blob":
            if code == "Iloc" and len(value) >= 8:
                x, y = struct.unpack(">ii", value[:8])
                layout["icons"][name] = [x, y]
                shown = [x, y]
            elif code in ("bwsp", "icvp"):
                plist = load_plist(value)
                if plist is not None:
                    shown = plist
                if name == "." and plist is not None and code == "bwsp":
                    layout["window"] = str(plist.get("WindowBounds", ""))
                if name == "." and plist is not None and code == "icvp":
                    alias = plist.get("backgroundImageAlias")
                    if isinstance(alias, bytes):
                        layout["volume"], layout["background"] = parse_alias(alias)
        decoded.append(
            {"name": name, "code": code, "type": kind, "value": jsonable(shown)}
        )
    return layout, decoded


def main(argv):
    arguments = argv[1:]
    if arguments in (["-h"], ["--help"]):
        print(__doc__.strip().split("\n\n")[0])
        print("Usage: dsstore-layout.py <DS_Store> [--records]")
        return 0
    show_records = "--records" in arguments
    paths = [item for item in arguments if item != "--records"]
    if len(paths) != 1 or paths[0].startswith("-"):
        print("Usage: dsstore-layout.py <DS_Store> [--records]", file=sys.stderr)
        return 2
    try:
        with open(paths[0], "rb") as handle:
            data = handle.read()
        layout, decoded = describe(read_records(data))
    except (OSError, LayoutError, struct.error, UnicodeDecodeError) as problem:
        print("error: %s: %s" % (paths[0], problem), file=sys.stderr)
        return 1
    if show_records:
        layout["records"] = decoded
    print(json.dumps(layout))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
