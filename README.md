# RoomForMac

A calm, native macOS cleaner — Smart Clean, Uninstaller, the Terrain disk explorer and live Status — built on the open-source [Mole](https://github.com/tw93/mole) engine.

> Status: in development. Design: `docs/superpowers/specs/2026-09-25-roomformac-design.md`. Plans: `docs/superpowers/plans/`.

## Download

The website, https://gugag2003.github.io/RoomForMac/, has the download and the guide below. The latest disk image is also always at https://github.com/gugag2003/RoomForMac/releases/latest/download/RoomForMac.dmg. If that link answers 404, no release has been published yet: build from source, as described further down.

Open the disk image and drag RoomForMac to Applications. RoomForMac is signed with its own certificate and is not notarized by Apple, so macOS blocks the first launch until you approve it once, in System Settings › Privacy & Security › **Open Anyway**. The [Open Anyway guide](https://gugag2003.github.io/RoomForMac/open-anyway/) shows the three steps, and the disk image's window shows them too. After that RoomForMac keeps itself up to date (see "Updates" below).

## Requirements

- RoomForMac runs on macOS 26 or later.
- Building the app needs Xcode 27.0 or later. CI builds it with Xcode 27.0.
- Homebrew tools: `brew bundle --file Brewfile` (Go, bats-core, shellcheck, shfmt, actionlint, coreutils, parallel and XcodeGen).

## Building the app

```bash
brew bundle --file Brewfile
git submodule update --init
xcodegen generate              # writes RoomForMac.xcodeproj from project.yml
open RoomForMac.xcodeproj      # then run the RoomForMac scheme (⌘R)
```

Or build from Terminal:

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS,arch=arm64 build
```

To try the latest code, install it as the development copy:

```bash
scripts/dev-app.sh --open
```

- **There is one development copy**, `~/Applications/RoomForMac Dev.app`, and it is the only RoomForMac that Spotlight and Launchpad list. The script builds Debug into `~/Library/Developer/Xcode/DerivedData/RoomForMac-dev.noindex`, which Spotlight skips, and replaces the copy once the build succeeds, quitting it first if it runs.
- **Older builds are removed.** Every other RoomForMac bundle under `~/Library/Developer/Xcode/DerivedData` (Xcode's own ⌘R builds, the UI-test runner) is a build product that Spotlight lists, so the script deletes it unless it is running; Xcode makes it again on its next build. `--keep-others` keeps them. A folder whose name ends in `.noindex` is never touched, so build into one when you script a build of your own.
- Arguments after `--` go to the app: `scripts/dev-app.sh --open -- -RFMUITestScenario onboarded`.

- **The first build also builds the engine**, which takes about a minute. Later builds reuse `build/engine` and rebuild it only when `vendor/mole`, `patches/mole/`, `scripts/build-engine.sh` or `scripts/lib/engine-inputs.sh` change.
- **Never run two engine builds at once.** `scripts/build-engine.sh` and `bats scripts/tests` always re-clone `build/engine-src`, and an app build does too when it has to rebuild the engine. Let one finish before you start another.
- **The Xcode project is generated, not committed.** Run `xcodegen generate` again after pulling a change to `project.yml`.
- **The engine is embedded in the app.** Its scripts go in `RoomForMac.app/Contents/Resources/engine`, and its two Go tools in `Contents/Helpers`. The app never runs a `mo` installed elsewhere.
- **The first build fetches Sparkle**, the app's only third-party package (2.10.0, pinned), with Swift Package Manager, so it needs the network once. Sparkle is embedded in `RoomForMac.app/Contents/Frameworks`. A build phase, "Prepare Sparkle", removes its XPC services and signs its nested code with the app's identity.

### Signing

Until you create the stable signing identity, builds are signed ad hoc. macOS ties an ad-hoc app's Full Disk Access and Automation grants to that one build, so every rebuild loses them. Create the identity once, and click **Always Allow** when macOS asks whether `codesign` may use the key:

```bash
scripts/make-signing-identity.sh
```

[`docs/signing.md`](docs/signing.md) explains what the identity is for, how to back it up, how the Release build's hardened runtime and entitlements work, and how to check a signed build.

### Tests

```bash
# Unit tests: Swift Testing, hosted in the app. They never trigger a system prompt.
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS,arch=arm64 test

# Bundle checks and the release gate on a universal Release build.
# Leave out --adhoc when the build is signed with your identity (Config/Local.xcconfig).
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Release/RoomForMac.app
APP="$APP" EXPECT_UNIVERSAL=1 EXPECT_HARDENED=1 bats scripts/tests/app_bundle.bats
scripts/check-release-app.sh "$APP" --adhoc

# The appcast tests with Sparkle's real tools (any build above fetched Sparkle)
SPARKLE_BIN="$PWD/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    bats scripts/tests/release_archives.bats

# UI smoke tests (need Automation Mode, see below)
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS,arch=arm64 \
    -only-testing:RoomForMacUITests test

# Lint the scripts and workflows, as CI does
shellcheck scripts/*.sh scripts/lib/*.sh scripts/tests/*.bash
shfmt -d -i 4 -ci -sr scripts/*.sh scripts/lib/*.sh scripts/tests/*.bash
actionlint
PYTHONPYCACHEPREFIX="$TMPDIR/pycache" python3 -m py_compile scripts/dsstore-layout.py
for script in scripts/*.swift scripts/lib/*.swift; do swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 "$script"; done
```

**Some checks are skipped unless you opt in.** `build_engine.bats` and `app_bundle.bats` run `status-go --json`, which asks Finder for the disk's free space, so macOS may ask whether Terminal may control Finder. So that no test raises a prompt, both skip that check unless `RFM_ALLOW_PROMPTS=1` is set. CI sets it. Set it yourself only when you want the check and can answer a prompt: `RFM_ALLOW_PROMPTS=1 bats scripts/tests`. Some bats files need tools of their own, all present on a Mac with Xcode: `make_dmg.bats` needs `python3`, `ditto`, `xattr`, `sips`, `tiffutil`, `codesign` and `clang` (it stubs `hdiutil`, so no test mounts an image), `check_release_app.bats` needs `clang`, and `workflows.bats` needs `ruby`. The files that build a test app skip with a message without `clang`, and `workflows.bats` skips without `ruby`. `release_archives.bats` runs its real-Sparkle test only when `SPARKLE_BIN` names Sparkle's `bin` folder, as in the `SPARKLE_BIN=` command of the test commands.

**UI tests need Automation Mode.** Run `automationmodetool` to see its state. If it says the Mac requires user authentication, do one of the following:

- Start the UI tests while you are at the Mac, and approve the password or Touch ID prompt.
- Allow Automation Mode without authentication: `sudo automationmodetool enable-automationmode-without-authentication`. This lets any local process drive the UI while it is on. Undo it with `sudo automationmodetool disable-automationmode-without-authentication`.

Without Automation Mode, the run fails after about 90 seconds with "Timed out while enabling automation mode." That is a limit of the Mac, not a test failure. GitHub's macOS runners have Automation Mode enabled, so CI runs the UI tests.

### Debug launch arguments

Debug builds accept three launch arguments. Release builds ignore all three.

- `-RFMUITestScenario onboarding`, `onboarded` or `engine-broken` starts the app the way the UI tests do: scripted permissions, and preferences in a separate suite that is wiped at launch. In `onboarding` and `onboarded` the engine's services are scripted too: Smart Clean scans three canned sections, the Uninstaller lists four sample apps (one of them a Homebrew cask, one shown as running), and Status plays canned snapshots every 2 seconds. Nothing on the Mac is scanned, quit or removed, `status-go` never starts, no notification is posted, no log is written, and the menu-bar extra stays off. `engine-broken` shows the Reinstall card.
- `-RFMForceMoveStep YES` shows the Move to Applications step, which Debug builds otherwise skip because they run from DerivedData.
- `-RFMEnableUpdater YES` lets a Debug build check for updates. Without it a Debug build never does, so a development copy cannot replace itself with a release. `yes`, `true` and `1` work too, in any case. The build still needs what every copy needs (see "Updates" below): to sit in `/Applications` or `~/Applications`, and to carry an update public key, which it does once `RFM_SPARKLE_PUBLIC_KEY` is set in `Config/Distribution.xcconfig`.

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS,arch=arm64 \
    -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/RoomForMac.app --args -RFMUITestScenario onboarding
```

## Using the app

### Menu-bar extra and launch at login

- **The menu-bar extra** appears once onboarding is done. When RoomForMac starts with onboarding already done, the item shows at once, and its panel reads "Starting…" until the engine check has passed, or says that RoomForMac needs to be reinstalled when the check fails. Otherwise, as right after onboarding, the item appears as soon as the check has passed. Its panel shows CPU, memory and disk gauges, the free space, the health line, **Quick Scan** (opens the window on Smart Clean and starts a scan), **Open RoomForMac** and **Quit RoomForMac**. It is on by default. Turn it off in Settings → General → **Show RoomForMac in the menu bar**, or ⌘-drag it out of the menu bar.
- **Closing the window** leaves RoomForMac running while the extra is shown, and the Dock icon stays. Click the Dock icon or **Open RoomForMac** to bring the window back. Without the extra, closing the last window quits the app.
- **Launch at login** is **Open RoomForMac at login**, in Settings → General and in onboarding's Extras step. It registers RoomForMac with `SMAppService.mainApp`, only from a copy installed in `/Applications` or `~/Applications`. When the extra is on, a login launch opens no window when macOS marks it as a login launch (manual check U5), so RoomForMac starts in the menu bar. Any other launch opens the window.
- **Status numbers are live** only while the Status section is on screen or the panel is open. The status tool is paused about 30 seconds after the last of them goes away, and after 5 minutes paused it quits. RoomForMac reads the free space itself: when the section appears or the panel opens, every minute while either shows it, and after every cleanup or uninstall; never for the menu-bar icon alone.

### Notifications

Settings → General → **Notify me when a scan or cleanup finishes**, also offered in onboarding's Extras step. With it on and notifications allowed, RoomForMac posts one when a Smart Clean scan finishes, when a cleanup ends and when an uninstall ends, but only while another app is in front. Notifications hold counts and sizes, never a file or app name, and clicking one opens the matching section. Turning the switch on asks macOS for permission if it has not asked yet.

### Updates

RoomForMac updates itself with [Sparkle](https://sparkle-project.org) 2. Once onboarding is done it checks for a new version about once a day, through a feed of GitHub release assets, and Sparkle shows its own alert when one is ready. A check sends only the request itself: GitHub sees your IP address, the app's name and its version. No system profile is collected. The website's privacy page says the same.

- **Check now:** RoomForMac → **Check for Updates…**, in the app menu after About. It is there with the window closed, and when the engine check has failed, because an update is what repairs a broken copy.
- **Settings → General → Updates**, the last section, has **Check for updates automatically**, **Download and install updates automatically**, **Check Now** and the time of the last check. Automatic download is off until you turn it on.
- **A copy outside Applications gets no updates.** Sparkle cannot replace a copy that runs from a disk image, from Downloads or from a translocated location, so Settings then says "Move RoomForMac to your Applications folder to get updates." A copy in `/Applications` or `~/Applications` updates.
- **An update never restarts RoomForMac in the middle of a cleanup or an uninstall.** The restart waits until the run has ended.
- **No RoomForMac notification announces an update**, and the menu-bar panel has no update item.
- **Development builds never update** (see the launch arguments above; Settings says "Development builds don't check for updates."), and neither does a build without an update public key ("Updates aren't set up in this build.").

### Logs and diagnostics

Every engine run of Smart Clean and the Uninstaller leaves a record in `~/Library/Logs/RoomForMac/engine.log`: the command, how it ended, how many events of each kind arrived, and the last 64 KiB of its output. Status's long-running tool is not logged. The file rotates at 1 MiB, keeping `engine.1.log` to `engine.4.log`, and only your account can read the folder. **Show details** and **Copy diagnostics** on a problem card read this log. It holds file paths, so it never leaves the Mac unless you paste it somewhere. The engine keeps its own logs in `~/Library/Logs/mole`, which RoomForMac leaves alone. Smart Clean never offers either folder.

## Building the engine

```bash
git submodule update --init
scripts/build-engine.sh        # → build/engine
bats scripts/tests             # engine build checks
swift test --package-path Packages/MoleEngine   # MoleEngine unit tests
RFM_ENGINE_DIR="$PWD/build/engine" swift test --package-path Packages/MoleEngine   # and its integration suite
```

The integration suite runs the engine only in a temporary fake home folder, never on your own files, and takes several minutes.

## Changing the engine patches

```bash
scripts/mole-patches.sh start  # build/mole-work: pinned Mole with every patch applied as a commit
# edit, then: scripts/mole-patches.sh test tests/<file>.bats ; commit inside build/mole-work
scripts/mole-patches.sh export # rewrite patches/mole/*.patch
```

The host protocol is documented in `docs/engine-protocol.md`.

## Releasing

A release is one pushed tag and one approval: GitHub Actions builds, signs, checks and packages the app, publishes the GitHub release and deploys the site. [`docs/releasing.md`](docs/releasing.md) covers the one-time setup, each release, dry runs, rollbacks, key rotation and what to do when something fails.

## License

GPL-3.0 — see `LICENSE` and `NOTICE`. RoomForMac is an independent project, not affiliated with or endorsed by Mole.

## Third-party software

RoomForMac bundles [Sparkle](https://sparkle-project.org) 2.10.0 for software updates, under the MIT license, with the notices of the components Sparkle itself carries. The complete text is [`ThirdParty/Sparkle/LICENSE`](ThirdParty/Sparkle/LICENSE), and Settings → About lists it as **Updates License (Sparkle)**. `NOTICE` and `CREDITS.md` credit Sparkle and the cleaning engine.
