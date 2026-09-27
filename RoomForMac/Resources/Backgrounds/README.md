# Backdrop photos

This folder holds the landscape photos behind RoomForMac's windows (spec §11.3). No photos ship until the owner picks them. Until then, each surface draws a gradient of palette colors (`BackdropScene.fallbackColors`), and a scene keeps its gradient until its photo is added here.

## Names

| Surface | Scene | File |
|---|---|---|
| Onboarding | Fitz Roy / Laguna de los Tres at sunrise | `backdrop-onboarding.heic` |
| Smart Clean | Yosemite Valley from Tunnel View | `backdrop-smartClean.heic` |
| Uninstaller | Cerro Torre / Fitz Roy massif | `backdrop-uninstaller.heic` |
| Terrain | Half Dome | `backdrop-terrain.heic` |
| Status | Torres del Paine | `backdrop-status.heic` |

- The name is `backdrop-<scene>`, where `<scene>` is the `BackdropScene` case. Names are case-sensitive: `smartClean` has a capital C.
- The app looks for `.heic` first, then `.jpg`, then `.png`.

## Size and format

- About 2560 px wide, landscape. The app scales anything larger down to 2560 px on its longest side when it loads it, so bigger files only make the app heavier.
- Convert to HEIC, which keeps the bundle small:

  ```bash
  sips -s format heic --resampleWidth 2560 in.jpg --out backdrop-<scene>.heic
  ```

- Do not blur or darken the file. The app blurs each photo once when it loads it (Gaussian, radius 40) so onboarding can pull it into focus, and it lays a 40% canvas wash over it for legibility.
- With Reduce Transparency on, no photo is shown at all.

## Licence rule

- Only public domain, CC0 or CC BY photos. No CC BY-SA, NC or ND licences, and no sites with their own "free to use" licence.
- Check the licence on the photo's own page before adding it.
- Credit every photo in `CREDITS.md` with its title, author, source link, licence and licence link, and the edits made (crop, resize, colour grade). CC BY requires this; for public domain and CC0 photos it is a courtesy.

## How the folder is bundled

`project.yml` adds this folder as a folder reference, so its files land in `RoomForMac.app/Contents/Resources/Backgrounds/` under the same names. This README is copied along with them. A photo dropped in here is picked up by the next build without running `xcodegen generate` again.
