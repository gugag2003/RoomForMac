# The RoomForMac disk image

`scripts/make-dmg.sh` builds `RoomForMac.dmg` in CI and on the owner's Mac. It needs no Finder, no AppleScript and no Python package: the window layout is a committed file, and the script copies it into every image. This folder holds that file and everything it is made from.

| File | What it is |
|---|---|
| `DS_Store` | Finder's window layout for the image: window size, icon positions, and the background picture. It is the `.DS_Store` of the finished image, without the dot so Git does not ignore it. |
| `background.png`, `background@2x.png` | The window background at 660 × 400 and 1320 × 800 pixels. Drawn by `scripts/make-dmg-background.swift`. |
| `background.tiff` | Both pictures in one file. Finder picks the 2x picture on a Retina display. It is stored in the image as `/.background.tiff`. |
| `dmgbuild-settings.py` | The layout as dmgbuild reads it. Used only to make `DS_Store` (Option A). |
| `dmgbuild-requirements.txt` | dmgbuild 1.6.7, ds_store 1.3.3 and mac_alias 2.2.3, pinned with hashes. |

The volume icon comes from `packaging/icon/VolumeIcon.icns`, which `scripts/export-app-icon.swift` writes.

## Names that never change

The volume is called **RoomForMac**, in every release and forever, and the background is the hidden file **`/.background.tiff`** at its root.

Finder does not store the picture inside `DS_Store`. It stores an alias made of the volume's name and the picture's path, and looks the picture up again by them. If the volume were called `RoomForMac 0.2.0`, or the picture lived elsewhere, the alias would point at nothing and Finder would draw a plain white window.

`scripts/make-dmg.sh` reads the volume name and the path back out of `DS_Store` (`scripts/dsstore-layout.py`) and refuses a layout made for anything else, and so does `scripts/tests/make_dmg.bats`. The name itself is `RFM_DMG_VOLUME_NAME` in `Config/Distribution.xcconfig`. Never change any of these names.

## Regenerating the background

Change the pictures only in `scripts/make-dmg-background.swift`. Then, from the repository root:

```bash
swift scripts/make-dmg-background.swift packaging/dmg
tiffutil -cathidpicheck packaging/dmg/background.png packaging/dmg/background@2x.png -out packaging/dmg/background.tiff
```

Open both PNGs (Quick Look is enough) and read the three steps at each size. The script refuses to write a card whose text would pass y = 360 points, because Finder's window bounds include the title bar and can clip the bottom of the picture.

`DS_Store` only needs regenerating when the window size or the icon positions change. They live in two places that must agree, `Geometry` in the Swift script (where the arrow is drawn) and `dmgbuild-settings.py`. `scripts/tests/make_dmg.bats` compares them.

Commit the two PNGs and the TIFF together.

## Regenerating the layout

### Option A: dmgbuild (the usual way)

Eject any mounted volume named `RoomForMac` in Finder first, then:

```bash
scripts/make-dmg-layout.sh
```

The script needs the network once, for pip, and Python 3.10 or later (`PYTHON3=/opt/homebrew/bin/python3 scripts/make-dmg-layout.sh` chooses one). It creates `build/dmgbuild-venv` (git-ignored) and installs the pinned packages with `--require-hashes`. It builds a throwaway image with `dmgbuild-settings.py` and copies the `.DS_Store` out of it. It replaces `packaging/dmg/DS_Store` only after `dsstore-layout.py` shows the volume `RoomForMac`, the background `/.background.tiff`, and the icons at (165, 120) and (495, 120).

dmgbuild mounts its throwaway image the ordinary way, so a `RoomForMac` volume may flash on the desktop while it runs. Nothing else in this folder runs dmgbuild, CI never does, and nothing from it ships.

`dmgbuild-requirements.txt` is generated, never edited by hand. To make it, or to update a pin, download the wheels and write the file again (this and the venv are the only steps that need the network):

```bash
rm -rf build/dmgbuild-download && mkdir -p build/dmgbuild-download
python3 -m pip download --only-binary :all: --no-deps --dest build/dmgbuild-download \
    dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
{
    echo '# dmgbuild and the two packages it needs, pinned with hashes for pip --require-hashes.'
    echo '# Generated as packaging/dmg/README.md describes. Used only by scripts/make-dmg-layout.sh.'
    python3 - build/dmgbuild-download << 'PY'
import hashlib
import pathlib
import sys

for wheel in sorted(pathlib.Path(sys.argv[1]).glob("*.whl")):
    name, version = wheel.name.split("-")[:2]
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    print(f"{name}=={version} \\\n    --hash=sha256:{digest}")
PY
} > packaging/dmg/dmgbuild-requirements.txt
```

### Option B: by hand in Finder

Use this if dmgbuild's layout renders wrongly on a new macOS. It takes ten minutes. In the commands below, `APP` is the path of a built `RoomForMac.app`.

1. Build a read-write image with the background in place:

   ```bash
   rm -rf build/dmg-hand && mkdir -p build/dmg-hand/stage
   ditto "$APP" build/dmg-hand/stage/RoomForMac.app
   ln -s /Applications build/dmg-hand/stage/Applications
   cp packaging/dmg/background.tiff build/dmg-hand/stage/.background.tiff
   hdiutil create -ov -volname RoomForMac -fs HFS+ -srcfolder build/dmg-hand/stage -format UDRW build/dmg-hand/rw.dmg
   hdiutil attach -readwrite build/dmg-hand/rw.dmg
   ```

   This attach is meant to show up in Finder, so it has no `-nobrowse`. The volume is `/Volumes/RoomForMac`.
2. In Finder, open the volume and choose View › as Icons, then View › Hide Sidebar, Hide Toolbar, Hide Status Bar and Hide Path Bar.
3. Press Command-Shift-Period to show hidden files. Press Command-J. Set Icon size 128, Text size 12, Label position Bottom, and Background to Picture. Drag `.background.tiff` from the window onto the picture well. Press Command-Shift-Period again to hide the hidden files.
4. Size the window to the picture: 660 × 400 points, no scroll bars. Drag `RoomForMac.app` so its icon sits at the left end of the arrow, and `Applications` at the right end.
5. Close the window, wait a few seconds for Finder to write the file, then copy it out and eject:

   ```bash
   cp /Volumes/RoomForMac/.DS_Store packaging/dmg/DS_Store
   hdiutil detach /Volumes/RoomForMac
   python3 scripts/dsstore-layout.py packaging/dmg/DS_Store
   ```

   The last command must show `"volume": "RoomForMac"`, `"background": "/.background.tiff"` and a position for both `RoomForMac.app` and `Applications`. Positions you placed by hand differ a little from (165, 120) and (495, 120), which `make-dmg.sh` accepts.

## Checking it by eye

Automated checks cannot see Finder. After any change to this folder, and on every new major macOS, build an image from a Release build (`APP` is its `RoomForMac.app`) and open it:

```bash
scripts/make-dmg.sh "$APP" build/RoomForMac.dmg
open build/RoomForMac.dmg
```

Check, in light and in dark mode: the picture fills the window with no scroll bars, the toolbar and sidebar are hidden, the icons sit at the ends of the arrow, all three steps are readable and none is cut off at the bottom, and the volume shows the app icon. Then eject it.

## If Finder draws a white window

1. `python3 scripts/dsstore-layout.py packaging/dmg/DS_Store` must print `"volume": "RoomForMac"` and `"background": "/.background.tiff"`. Anything else means the layout was made while another volume was mounted under that name: eject it and run Option A again.
2. `hdiutil attach -nobrowse -readonly -mountpoint /tmp/check build/RoomForMac.dmg`, then `ls -A /tmp/check`. It must list `.DS_Store`, `.VolumeIcon.icns` and `.background.tiff`. `hdiutil detach /tmp/check` when done.
3. If both are right and the window is still plain, use Option B.
