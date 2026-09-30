# Releasing RoomForMac

A release is one pushed tag `vX.Y.Z` and one approval. GitHub Actions then builds a universal Release app, signs it with the stable self-signed identity, checks it, packages it, publishes the GitHub release and deploys the site. This page is for the owner: the one-time setup, each release, and what to do when something goes wrong. Every command runs from the repository root.

Nothing here can run until the repository is public (One-time setup, step C1): GitHub Actions is blocked by billing on the private repository, and Pages and anonymous release downloads need a public one.

## How it fits together

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | every push to the default branch, every pull request | tests, lint, and the release gate on an ad-hoc build |
| `release.yml` | a pushed tag `vX.Y.Z`; **Run workflow** with a version is a dry run | `build`, `publish`, `pages`, `fixture` |
| `pages.yml` | a push to the default branch that changes `site/`, `scripts/stage-site.sh` or `Config/Distribution.xcconfig` | deploys the site alone |

The jobs of `release.yml`:

1. **`build`** (environment `release`, so it waits for your approval; the only job that holds secrets; read-only token): preflight, temporary signing keychain, the `token-fixture` hook, the engine, the universal Release build, `scripts/check-release-app.sh`, the DMG, the update and source archives, the appcast, `latest.json` and `SHA256SUMS`. It uploads them as the artifact `release-files`.
2. **`publish`** (write token, no secrets): uploads the six assets to a **draft** release, publishes it as the latest, and checks that the live feed serves the new build number. Because the assets are attached before the release goes public, `releases/latest/download/*` never points at a release without its files.
3. **`pages`** deploys the site, with the new `latest.json`.
4. **`fixture`** opens a pull request with the release's token fixture. It runs only when the `token-fixture` hook wrote files, which cannot happen before Plan 5.

A release publishes exactly these files:

| Asset | For |
|---|---|
| `RoomForMac.dmg` | people: the disk image with the drag-to-Applications window and the Open Anyway steps |
| `RoomForMac-X.Y.Z.tar.xz` | Sparkle: the update archive (Sparkle mounts a DMG update with the deprecated `hdiutil`; a tarball avoids that) |
| `RoomForMac-X.Y.Z-source.tar.gz` | the GPL's Corresponding Source: the superproject at the tag plus `vendor/mole` at its pinned commit, which GitHub's own archives leave out |
| `appcast.xml` | the update feed |
| `latest.json` | the site's download page |
| `SHA256SUMS` | integrity |

The DMG is not signed: a self-signed signature gains nothing with Gatekeeper. What people download is covered by `SHA256SUMS`, and what Sparkle installs by its EdDSA signature on the `tar.xz` (the appcast carries it).

## The identifiers that never change

Decide these before v1.0. Changing one after a public release strands or resets every installed copy. `scripts/tests/distribution.bats` pins them, so a change needs a deliberate test edit.

| Identifier | Value | Where | If it changes |
|---|---|---|---|
| Bundle ID | `com.roomformac.RoomForMac` | `project.yml` | macOS sees another app, and Sparkle cannot update one into the other |
| Designated requirement | `identifier "com.roomformac.RoomForMac" and certificate leaf = H"<sha1>"` | `Config/signing-identity.sha1` | every user grants Full Disk Access and Automation again |
| Feed URL | `https://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml` | `RFM_FEED_URL` | installed copies stop finding updates |
| EdDSA public key | the value of `RFM_SPARKLE_PUBLIC_KEY` | `Config/Distribution.xcconfig` | rotatable only while the certificate stays the same ("Rotating the update key") |
| Build numbers | `X*1000000 + Y*1000 + Z`, strictly increasing | `scripts/lib/version.sh` | installed copies refuse an update whose number is smaller |
| Release asset names | the six above | the release scripts | the site's download link, the feed and `latest.json` break |
| DMG volume name | `RoomForMac`, never a version | `RFM_DMG_VOLUME_NAME`; the committed `packaging/dmg/DS_Store` names it | the committed window layout no longer matches |
| URL scheme | `roomformac` | `project.yml` | the thanks page can no longer open the app |

Tags are strict `vX.Y.Z`, with Y and Z at most 999. `MARKETING_VERSION` is `X.Y.Z` and `CFBundleVersion` is the build number, so 0.1.0 is build 1000 and 1.2.3 is build 1002003. Both come from the tag, so nothing else needs setting. Local builds keep `project.yml`'s 0.1.0 (build 1).

## One-time setup

Do these in order. Each needs your accounts, your keychain or your eyes, so no agent can do them for you.

### A. On your Mac

**1. Confirm the decisions that are hard to undo,** before the first public release:

- the feed URL on GitHub releases, for the life of every installed copy, and `tar.xz` updates;
- hardened runtime on in Release, with library validation off for Sparkle;
- the build-number scheme above, and the Icon Composer format for the app icon;
- the bundle ID `com.roomformac.RoomForMac`;
- whether 1.0 may ship before Plan 5. It may: the token-fixture hook is skipped until Plan 5 adds it and makes it required.

**2. Create the signing identity and back it up** (`docs/signing.md`):

```bash
scripts/make-signing-identity.sh --check     # exit 1 until it exists: "no identity named …"
scripts/make-signing-identity.sh             # click Always Allow in the codesign dialog
```

Back up `~/.roomformac/signing` in the password manager, then remove the grants that ad-hoc builds left (`docs/signing.md`, "Remove grants left by ad-hoc builds").

**3. Commit the certificate fingerprint.** It is public by nature, and the release gate pins the designated requirement to it:

```bash
scripts/make-signing-identity.sh --check | cut -d' ' -f1 > Config/signing-identity.sha1
git add Config/signing-identity.sha1 && git commit -m "chore(release): pin the signing certificate fingerprint"
```

**4. Create the update-signing key.** Build the app once, so that Swift Package Manager fetches Sparkle and its tools:

```bash
xcodegen generate
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS,arch=arm64 \
    -derivedDataPath build/DerivedData build
scripts/make-update-keys.sh                  # click Always Allow in the keychain dialog
git add Config/Distribution.xcconfig && git commit -m "chore(updates): add the Sparkle public key"
```

The script keeps the key in your login keychain (`generate_keys --account roomformac`), exports the seed to `~/.roomformac/updates/ed25519.key` (mode 0600, outside the repository) and writes the public key into `Config/Distribution.xcconfig`. It never overwrites a non-empty public key. `scripts/make-update-keys.sh --check` reads the keychain and says whether the two agree. Back up `~/.roomformac/updates` next to `~/.roomformac/signing`: **losing both strands every user** ("Losing keys").

### B. Checks by eye and by hand

Each follows the task that builds the thing it checks. The commands below use one shell variable, the Release app:

```bash
APP=build/DerivedData/Build/Products/Release/RoomForMac.app
```

**1. Hardened runtime with your identity (M3; blocks v1.0).** Build Release, run the release gate, install the app in `~/Applications`, launch it with `open` and run a Smart Clean scan:

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build
scripts/check-release-app.sh "$APP"
mkdir -p ~/Applications && ditto "$APP" ~/Applications/RoomForMac.app
open ~/Applications/RoomForMac.app
```

Settings → Permissions must still show Full Disk Access, Finder and System Events granted, and no new Automation prompt may appear. If anything fails, tell the plan owner: Plan 6's Ruling 5 has a fallback (hardened runtime off in Release, the two entitlements dropped).

**2. The app icon.** Open `RoomForMac/Resources/AppIcon.icon` in Icon Composer (Xcode › Open Developer Tool) and check Default, Dark and Clear/Tinted, and the Dock at small sizes. Approve it, or replace the SVG layers and export again with `swift scripts/export-app-icon.swift "$APP" .`.

**3. The privacy page.** Fill the `[OWNER: …]` placeholders in `site/privacy/index.html` (the controller's name and a contact address). This is required before v1.0, when the site is staged with `--strict`. `grep -rn '\[OWNER:' site` prints nothing when it is done.

**4. The DMG window.** Build a disk image and open it in Finder on macOS 26 and on 27, in light and dark mode:

```bash
scripts/make-dmg.sh "$APP" build/RoomForMac.dmg
open build/RoomForMac.dmg
```

The background must fill the window, the icons sit on the arrow, there are no scroll bars, the toolbar is hidden and the volume icon shows. If it is wrong, regenerate `packaging/dmg/DS_Store` with option B in `packaging/dmg/README.md`. Eject the image afterwards.

**5. The update rehearsal** (before the first release, and after every Sparkle bump or change to the updater or the signing scripts):

```bash
scripts/rehearse-update.sh prepare build/rehearsal && scripts/rehearse-update.sh check build/rehearsal
```

Then follow `build/rehearsal/CHECKLIST.md` (V3, V4 in the app, V5, V6 with and without the quarantine cleanup, V7, V8 and V10) on macOS 27 **and** 26, and record the results in the plan's As built notes. If V6 shows a Gatekeeper, "damaged" or App Management dialog, stop before the first public release.

**6. The UI smoke tests,** with Automation Mode as the README describes, now including the "Check for Updates…" check.

### C. GitHub

In this order, before the first release.

**1. Scan the history for secrets, then make the repository public.** The scan looks for key files by name and for private-key and base64 material by content. It must print nothing. A hit is either a test fixture, which is fine, or a real secret, in which case the repository must not go public until the history is rewritten:

```bash
git log --all --name-only --pretty=format: | sort -u | grep -E '(^|/)(identity\.p12(\.base64|\.password)?|key\.pem|ed25519\.key)$'
git log --all -p | grep -nE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|^\+[A-Za-z0-9+/]{60,}={0,2}$' | cut -c1-100
gh repo edit gugag2003/RoomForMac --visibility public --accept-visibility-change-consequences
```

Do this after Plan 6 has merged: it also unblocks CI, which has never run (every run so far ended in `startup_failure`), and it needs the Node 24 actions this plan moved `ci.yml` to. Then check that CI turns green on the default branch.

**2. The default branch.** Rename `main-mrvlfl` to `main` (Settings › General › Default branch), or keep it. Both point at the same commit. `ci.yml` and `pages.yml` accept both. The `github-pages` rule in step 3 must name whichever is the default, and `release-preflight.sh` checks tags against it.

**3. Pages.** Settings › Pages › Build and deployment › Source: **GitHub Actions**. Then Settings › Environments › `github-pages` › Deployment branches and tags: keep the default branch and **add the tag rule `v*`**, because the release's `pages` job runs on a tag.

**4. The `release` environment.** Settings › Environments › New environment `release`:

- Required reviewers: yourself, with "Prevent self-review" off.
- Deployment branches and tags: "Selected branches and tags", with the tag rule `v*` and the default branch (for dry runs).

Then add its three secrets, and delete any repository-level copy of them (`gh secret list` must show none):

```bash
gh secret set RFM_SIGNING_P12_BASE64   --env release --repo gugag2003/RoomForMac < ~/.roomformac/signing/identity.p12.base64
gh secret set RFM_SIGNING_P12_PASSWORD --env release --repo gugag2003/RoomForMac < ~/.roomformac/signing/identity.p12.password
gh secret set SPARKLE_ED_PRIVATE_KEY   --env release --repo gugag2003/RoomForMac < ~/.roomformac/updates/ed25519.key
gh secret list --repo gugag2003/RoomForMac
gh secret list --env release --repo gugag2003/RoomForMac
```

The first list, the repository's, must not name these three. The second must name all of them.

**5. Settings › Actions › General.**

- Workflow permissions: **Read repository contents**. The workflows grant the rest, job by job.
- Leave "Allow GitHub Actions to create and approve pull requests" off until Plan 5's fixture hook exists. Before then the `fixture` job never runs.
- Optionally turn on **immutable releases** (Settings › General › Releases).

## Each release

**1. Write the notes** on the default branch, from the template:

```bash
cp release-notes/TEMPLATE.md release-notes/X.Y.Z.md
```

Fill in "What's new" and "Fixes", and keep the closing paragraph: RoomForMac is GPL-3.0, the Corresponding Source is the attached `-source.tar.gz`, Sparkle's source is at the 2.10.0 tag, and the engine is credited as in `NOTICE`. The preflight refuses notes that are missing, empty, still hold the unfinished-work marker that `release-notes/README.md` names, or lack that paragraph's first sentence. Commit and push them.

**2. Optionally rehearse** (do this for any change to signing, Sparkle or the DMG): `scripts/release-preflight.sh --dry-run X.Y.Z` on your Mac, then a dry run on GitHub ("Dry runs").

**3. Tag and push:**

```bash
DEFAULT="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
git switch "$DEFAULT" && git pull --ff-only
git tag -a vX.Y.Z -m "RoomForMac X.Y.Z"
git push origin vX.Y.Z
```

The preflight refuses a tag that is not strict `vX.Y.Z`, is not on the default branch's history, is not the newest strict tag, or is not above every published tag.

**4. Approve.** Actions › Release › the run › **Review deployments** › `release` › Approve.

**5. Watch** `build`, `publish` and `pages`. The `publish` job ends by fetching the live feed, and it fails unless the feed serves the new build number within 5 minutes.

**6. Check the feed as Sparkle sees it:**

```bash
curl -sIL https://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml | grep -iE '^(HTTP|location|content-type)'
curl -sL https://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml | grep -E 'sparkle:(version|shortVersionString)'
curl -sIL https://github.com/gugag2003/RoomForMac/releases/latest/download/RoomForMac.dmg | grep -iE '^HTTP'
```

Expect two `302` answers and a `200`, all on https, then one `sparkle:version` per release (the newest ten) with the new build number, then the same redirects for the DMG. The redirect chain is what `curl` shows. That Sparkle follows both redirects and parses the `application/octet-stream` answer is proved only by the first real update (step 7).

**7. For the first two releases,** also:

- **A clean-Mac walkthrough** on macOS 26 and 27, or a second user account: download the DMG with Safari, drag RoomForMac to Applications, do Open Anyway. Note the exact order of the dialogs and any extra prompt, and report differences, so the site's guide and the DMG background can be corrected.
- **The first real update:** release `0.1.1` the same way, and on the machine from the walkthrough choose RoomForMac › Check for Updates…. It must install 0.1.1 with no prompt beyond Sparkle's own alert, and Full Disk Access must survive.

**8. Merge the fixture pull request** the `fixture` job opened, and approve its CI run. This applies only once Plan 5's hook exists.

## Dry runs

A dry run builds everything and publishes nothing: no tag, no release, no site.

1. Actions › Release › **Run workflow** › version `X.Y.Z` (no `v`) › Run, then approve the `release` deployment. Pick a version above the latest published release: the dry run builds the appcast on top of the published one, and `scripts/make-appcast.sh` refuses a build number that is not above every one it already lists. Before the first release, `0.1.0` works. Only the `build` job runs, with `release-preflight.sh --dry-run`, which skips the tag, branch, published-tag, visibility and repository checks but not the notes check. It uses `release-notes/X.Y.Z.md` when it exists and `release-notes/TEMPLATE.md` otherwise, and says which.
2. Download the artifact `release-files` (kept for 7 days) and check: the six files are there, the DMG opens, and `appcast.xml` has an item pointing at `…/releases/download/vX.Y.Z/RoomForMac-X.Y.Z.tar.xz`. For the very first dry run that is the only item.
3. Before a change to the updater, the signing scripts or the DMG, also run the update rehearsal (One-time setup, B5): a dry run does not test an update.

## Rollback

There is no rollback to a lower version. Sparkle refuses a downgrade: an installed copy accepts an update only when its build number is higher. A bad release is fixed by a higher one:

1. Fix the problem, or revert the change, on the default branch.
2. Write `release-notes/X.Y.Z.md` for the next version and release it as described in "Each release".

Never delete or edit a published release or its assets, and never move its tag. Installed copies, the feed's history (each appcast keeps every earlier item byte for byte) and the immutable-releases setting all depend on them. Never switch to a version scheme that yields smaller build numbers.

## A failed release

| Where it failed | What exists | What to do |
|---|---|---|
| `build`, or you declined the approval | nothing public | Re-run the failed jobs. If the fix needs a new commit, move the tag (below). |
| `publish`, before "Publish as latest" | at most a draft | Re-run `publish`. The step "Replace a leftover draft" deletes the draft for the tag and starts clean. To start over by hand, delete the draft in the GitHub UI (Releases › the draft › Delete), or run `gh release delete vX.Y.Z --yes`. |
| `publish`, at "Check the live feed" | a public release | Do not re-run: a published release for the tag fails the job, and is never touched. Fetch the feed as in "Each release", step 6. If it serves the new build number, the check only gave up too early. If it does not, wait and look again. If it stays wrong, fix forward with a higher version. |
| `pages` | a public release, a stale site | Re-run `pages`, or run the **Pages** workflow by hand: it stages the site with the latest release's `latest.json`. |
| `fixture` | a public release | Fix the hook (Plan 5's) and re-run the job. |

A workflow run with a tag that has no release yet can be re-run any number of times. To move a tag when **nothing was published** for it:

```bash
git push origin :refs/tags/vX.Y.Z      # delete the remote tag
git tag -d vX.Y.Z
# fix, commit and push to the default branch, then tag and push again ("Each release", step 3)
```

## Rotating the update key

Rotate when the seed is lost or has leaked. `scripts/make-update-keys.sh` refuses to overwrite a non-empty `RFM_SPARKLE_PUBLIC_KEY` (exit 2, pointing here), so this is a manual act. Change the key in one release and never the certificate in the same release: Sparkle accepts a change of one, not of both.

1. Make the new key, in a new keychain account, and export its seed. Build the app once first, so that Sparkle's tools exist:

   ```bash
   source scripts/lib/sparkle.sh
   BIN="$(sparkle_bin "$PWD")"
   mv ~/.roomformac/updates ~/.roomformac/updates.old
   mkdir -m 700 ~/.roomformac/updates
   "$BIN/generate_keys" --account roomformac-2                                   # prints the new public key
   "$BIN/generate_keys" --account roomformac-2 -x ~/.roomformac/updates/ed25519.key
   chmod 600 ~/.roomformac/updates/ed25519.key
   ```

2. Put the printed public key into `RFM_SPARKLE_PUBLIC_KEY` in `Config/Distribution.xcconfig`, by hand, and commit it. An xcconfig file reads `//` as the start of a comment, even inside a value, so write every `//` in the key as `/$()/`, as `scripts/make-update-keys.sh` does (about one key in a hundred has one). Check that the keychain and the file agree:

   ```bash
   scripts/make-update-keys.sh --account roomformac-2 --check      # exit 0
   ```

3. Replace the secret:

   ```bash
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo gugag2003/RoomForMac < ~/.roomformac/updates/ed25519.key
   ```

4. Rehearse it first: V5 in `build/rehearsal/CHECKLIST.md` does exactly this with throwaway keys.
5. Release the next version as usual. It carries the new public key and is signed with the new seed and the same certificate. Installed copies hold the old key, so the EdDSA check fails for them, and they accept the update through the code-signing check, which passes because the certificate is the same.
6. Back up `~/.roomformac/` again. Delete `~/.roomformac/updates.old` when you no longer need the old seed.

**Never turn on `SUVerifyUpdateBeforeExtraction`** (or `SURequireSignedFeed`). With it on, Sparkle accepts a changed EdDSA key only through a Developer ID-signed disk image and a Team ID, which RoomForMac does not have, so a lost seed would strand every user.

## Losing keys

| You lose | Consequence | What to do |
|---|---|---|
| The update-signing seed only | Survivable. New updates cannot be signed with the old key, but the certificate still vouches for a new one. | Rotate the key (above). |
| The certificate only (`~/.roomformac/signing` and its keychain copy) | Survivable. The EdDSA signature still validates updates. The designated requirement changes, so users grant Full Disk Access and Automation again, once. | Make a new identity (`docs/signing.md`), commit its new fingerprint to `Config/signing-identity.sha1`, replace the two signing secrets, and release. |
| Both | Every user is stranded: updates stop verifying, and they must download and install by hand. | Prevention only. Back up `~/.roomformac/` in the password manager whenever a key changes. |

A leaked seed is rotated at once. A leaked certificate cannot be revoked: `docs/signing.md`, "Security", says what a replacement costs.

## Moving to a custom domain

1. Buy the domain. Set it in Settings › Pages › Custom domain, add the DNS records Pages shows (apex A and AAAA records to GitHub's addresses, or a `www` CNAME to `gugag2003.github.io`), wait for verification and tick **Enforce HTTPS**.
2. Change **only** `RFM_SITE_URL` in `Config/Distribution.xcconfig`, and the literal that `scripts/tests/distribution.bats` pins for it. `pages.yml` redeploys the site, because that file is on its path filter.
3. Update the README's Download links.

Never change `RFM_FEED_URL` for this: the feed is a release asset and does not move. Copies already installed keep the `github.io` address as their download page (`RFMSiteURL`), which GitHub redirects to the domain.

## Leaving GitHub

`RFM_FEED_URL` stops working only if the repository is deleted, made private, or renamed and the old name taken by someone else. If the project ever leaves GitHub:

1. While the feed still works, ship an update whose `RFM_FEED_URL` points at the new host. That is a deliberate edit of `Config/Distribution.xcconfig` and of the literal `distribution.bats` pins for it.
2. Keep the repository public, and keep publishing `appcast.xml` as a release asset, with an item that leads to that update, for as long as copies with the old URL exist.
3. Never delete the repository, make it private, or abandon its name.

## Moving to Developer ID later

This outline is its own project (spec §15); Plan 6 leaves it ready:

1. Join the Apple Developer Program and make a Developer ID Application certificate. The designated requirement then carries a Team ID, so users grant Full Disk Access and Automation again once, and `Config/signing-identity.sha1` and the requirement `scripts/check-release-app.sh` checks change with it. EdDSA still accepts the update across the change. Do not rotate the EdDSA key in the same release.
2. Sign with secure timestamps: replace `--timestamp=none` with `--timestamp` in every script that signs. `grep -rn 'timestamp=none' scripts docs` finds them, among them `scripts/embed-engine.sh`, `scripts/prepare-sparkle.sh` and `docs/signing.md`'s fallback.
3. Notarize and staple the app and the disk image (`xcrun notarytool submit … --wait`, then `xcrun stapler staple`). The Open Anyway guide, the DMG background text and the site page then become unnecessary.
4. Turn library validation back on: drop `com.apple.security.cs.disable-library-validation` from `project.yml`, since the app and Sparkle then share a Team ID, and update the entitlement check in `check-release-app.sh` and `app_bundle.bats`.
5. Then consider `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed`, and a Homebrew cask.

## The secrets inventory

| Name | Kind | Holds | Read by |
|---|---|---|---|
| `RFM_SIGNING_P12_BASE64` | secret of the environment `release` | the signing identity as PKCS#12, in base64 | `build`, through `scripts/import-signing-identity.sh` |
| `RFM_SIGNING_P12_PASSWORD` | secret of the environment `release` | its password | `build`, the same script |
| `SPARKLE_ED_PRIVATE_KEY` | secret of the environment `release` | the update-signing seed, in base64 | `build`, through `scripts/make-appcast.sh`, on standard input |
| `RFM_FIXTURE_TOKEN_KEY` | secret of the environment `release`, reserved | Plan 5's token-fixture key | the `token-fixture` hook step of `build`; empty until Plan 5 |
| `RFM_FIXTURE_TOKEN_URL` | variable, not a secret | Plan 5's fixture endpoint | the same step; empty until Plan 5 |
| `github.token` | issued per run | permissions granted job by job | `publish`, `pages`, `fixture` |

The rules, which `scripts/tests/workflows.bats` pins:

- Only `build` names the environment `release` or reads a secret. `publish`, `pages` and `fixture` see only `github.token`.
- `ci.yml` and `pages.yml` read no secret. No workflow uses `pull_request_target`, so a fork's pull request never sees one.
- Scripts read secrets from environment variables, never from arguments or files in the repository, and never print them. `set -x` is banned in any script that sees one. The exceptions are the `security` options that have no other channel (`create-keychain -p`, `unlock-keychain -p`, `set-key-partition-list -k`, `import -P`), which run only on an ephemeral runner or a throwaway keychain.
- There are no repository-level secrets.

## Keeping current

- **Each release:** notes, tag, approve, check the live feed. Once Plan 5 exists, also merge the fixture pull request and approve its CI run.
- **Sparkle:** bump its security fixes in one change: `exactVersion` in `project.yml`, `SPARKLE_VERSION` in `scripts/lib/sparkle.sh`, `ThirdParty/Sparkle/LICENSE` (verbatim from the new tag), and the Sparkle tag named in `release-notes/TEMPLATE.md`. Then re-run the rehearsal's `check`.
- **Actions and the runner:** keep the pinned action SHAs in `release.yml` and `pages.yml` (the same pin in both: `workflows.bats` fails when `pages.yml` pins a commit that `release.yml` does not), the action majors in `ci.yml` and the `xcode-27` runner label current. If `xcode-27` disappears, fall back to `macos-26`, subject to Plan 2 Ruling 14, and change the label in `.github/actionlint.yaml` too (`workflows.bats` fails when a workflow uses a runner label that file does not list).
- **Backups:** back up `~/.roomformac/` whenever a key changes.

## Things the scripts enforce that you may trip over

- `scripts/make-appcast.sh` verifies each new appcast item under `RFM_SPARKLE_PUBLIC_KEY` (through `scripts/lib/ed25519-verify.swift`) and refuses a build number that the feed already lists. A wrong seed therefore fails the `build` job, not a user's update.
- Release hooks in `scripts/release-hooks/` may not be symlinks; `scripts/release-hook.sh` refuses one.
- `scripts/stage-site.sh` needs `python3` (it parses `latest.json`). `pages.yml` leaves pre-releases out of the site's download link.
- Sparkle is embedded by Xcode itself, and "Prepare Sparkle" only removes its XPC services and signs its nested code. Release also sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO` so no `get-task-allow` reaches the Release build.
- CI and the release workflows have never run: the repository is private and every Actions run ended in `startup_failure`. Make the repository public (C1) or fix Actions billing before you expect any workflow to work.

## Still unverified (owner)

Steps A2–A4 (identity, fingerprint, the real update key), spike S-0 and check M3 (Xcode accepts the self-signed identity with hardened runtime on; Sparkle loads; Apple events still work), B2 (the icon's look), B4 (the DMG in Finder), B5 (the real update rehearsal), C1 (the secret scan) and the UI tests in Automation Mode. Two claims on the site are also unverified: that the Open Anyway button stays available for about an hour, and that permissions persist across updates under the self-signed identity. Check both on the clean-Mac walkthrough and correct the site if they differ.
