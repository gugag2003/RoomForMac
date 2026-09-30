# Release notes

Each release has one Markdown file named after its version: `release-notes/0.1.0.md` for the tag `v0.1.0`. Write it by hand on the default branch and commit it before you push the tag. Once a version is released, never edit its file.

The same file is used three times:

- It is the body of the GitHub release (`gh release create --notes-file`).
- `scripts/make-appcast.sh` copies it next to the update archive, and Sparkle embeds it in the appcast. It is what an installed copy shows in its update window.
- `scripts/release-preflight.sh` checks it before anything is built.

## Writing one

1. Copy the template: `cp release-notes/TEMPLATE.md release-notes/X.Y.Z.md`.
2. Replace each placeholder line ("Replace this line …") with real bullets. Keep both sections, and write "None." under Fixes when there is nothing to list.
3. Leave the closing paragraph exactly as the template has it.
4. Commit the file to the default branch, then tag.

Style:

- Plain Markdown: the two `##` headings, bullets, links and emphasis. No title (the update window and the release page show the version themselves), no raw HTML and no images.
- One sentence per bullet. Say what changed for the person using the app, in plain words.
- English only.
- Never tell people to paste Terminal commands. Point to the Open Anyway guide on the site instead.
- Name no other vendor's product. Do not name the cleaning engine's project in the bullets: the closing paragraph credits it.
- Keep it short. Sparkle shows the notes in a small window.

## The closing paragraph

Every file ends with the paragraph from `TEMPLATE.md`. It states four things:

- RoomForMac is free software under the GPL, version 3.
- The Corresponding Source for the release is the attached `-source.tar.gz` file.
- Sparkle's source is at `https://github.com/sparkle-project/Sparkle/tree/2.10.0`.
- The cleaning engine is Mole, credited in `NOTICE`, and RoomForMac is not affiliated with it.

The preflight looks for the paragraph's first sentence, "RoomForMac is free software under the GNU General Public License, version 3." Line breaks inside the sentence do not matter. When Sparkle is upgraded, the tag in that URL moves in `TEMPLATE.md` in the same change. Files of released versions keep the tag they shipped with.

## What the preflight checks

`scripts/release-preflight.sh` refuses a release when its notes file:

- does not exist (a dry run with no file for its version checks `TEMPLATE.md` instead and says so);
- is empty;
- contains `TODO`;
- lacks the closing paragraph's first sentence;
- still contains a placeholder line from the template (not checked on `TEMPLATE.md` itself).
