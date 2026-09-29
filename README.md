# RoomForMac

A calm, native macOS cleaner — Smart Clean, Uninstaller, the Terrain disk explorer and live Status — built on the open-source [Mole](https://github.com/tw93/mole) engine.

> Status: in development. Design: `docs/superpowers/specs/2026-09-25-roomformac-design.md`. Plans: `docs/superpowers/plans/`.

## Requirements

- RoomForMac runs on macOS 26 or later.
- Building the app needs Xcode 27.0 or later. CI builds it with Xcode 27.0.
- Homebrew tools: `brew bundle --file Brewfile` (Go, bats-core, shellcheck, shfmt, coreutils, parallel and XcodeGen).

## Building the app

```bash
brew bundle --file Brewfile
git submodule update --init
xcodegen generate              # writes RoomForMac.xcodeproj from project.yml
open RoomForMac.xcodeproj      # then run the RoomForMac scheme (⌘R)
```

Or build from Terminal:

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS build
```

- **The first build also builds the engine**, which takes about a minute. Later builds reuse `build/engine` and rebuild it only when `vendor/mole`, `patches/mole/`, `scripts/build-engine.sh` or `scripts/lib/engine-inputs.sh` change.
- **Never run two engine builds at once.** `scripts/build-engine.sh` and `bats scripts/tests` always re-clone `build/engine-src`, and an app build does too when it has to rebuild the engine. Let one finish before you start another.
- **The Xcode project is generated, not committed.** Run `xcodegen generate` again after pulling a change to `project.yml`.
- **The engine is embedded in the app.** Its scripts go in `RoomForMac.app/Contents/Resources/engine`, and its two Go tools in `Contents/Helpers`. The app never runs a `mo` installed elsewhere.

### Signing

Until you create the stable signing identity, builds are signed ad hoc. macOS ties an ad-hoc app's Full Disk Access and Automation grants to that one build, so every rebuild loses them. Create the identity once, and click **Always Allow** when macOS asks whether `codesign` may use the key:

```bash
scripts/make-signing-identity.sh
```

[`docs/signing.md`](docs/signing.md) explains what the identity is for, how to back it up and how to check a signed build.

### Tests

```bash
# Unit tests: Swift Testing, hosted in the app. They never trigger a system prompt.
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test

# Bundle checks on a universal Release build
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 \
    bats scripts/tests/app_bundle.bats

# UI smoke tests (need Automation Mode, see below)
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS \
    -only-testing:RoomForMacUITests test

# Lint the build scripts, as CI does
shellcheck scripts/*.sh scripts/lib/*.sh
shfmt -d -i 4 -ci -sr scripts/*.sh scripts/lib/*.sh
```

**UI tests need Automation Mode.** Run `automationmodetool` to see its state. If it says the Mac requires user authentication, do one of the following:

- Start the UI tests while you are at the Mac, and approve the password or Touch ID prompt.
- Allow Automation Mode without authentication: `sudo automationmodetool enable-automationmode-without-authentication`. This lets any local process drive the UI while it is on. Undo it with `sudo automationmodetool disable-automationmode-without-authentication`.

Without Automation Mode, the run fails after about 90 seconds with "Timed out while enabling automation mode." That is a limit of the Mac, not a test failure. GitHub's macOS runners have Automation Mode enabled, so CI runs the UI tests.

### Debug launch arguments

Debug builds accept two launch arguments. Release builds ignore both.

- `-RFMUITestScenario onboarding`, `onboarded` or `engine-broken` starts the app the way the UI tests do: scripted permissions, and preferences in a separate suite that is wiped at launch. In `onboarding` and `onboarded` the engine's services are scripted too: Smart Clean scans three canned sections, the Uninstaller lists four sample apps (one of them a Homebrew cask, one shown as running), and Status plays canned snapshots every 2 seconds. Nothing on the Mac is scanned, quit or removed, `status-go` never starts, no notification is posted, no log is written, and the menu-bar extra stays off. `engine-broken` shows the Reinstall card.
- `-RFMForceMoveStep YES` shows the Move to Applications step, which Debug builds otherwise skip because they run from DerivedData.

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS \
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

## License

GPL-3.0 — see `LICENSE` and `NOTICE`. RoomForMac is an independent project, not affiliated with or endorsed by Mole.
