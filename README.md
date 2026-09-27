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

- `-RFMUITestScenario onboarding`, `onboarded` or `engine-broken` starts the app the way the UI tests do: scripted permissions, and preferences in a separate suite that is wiped at launch.
- `-RFMForceMoveStep YES` shows the Move to Applications step, which Debug builds otherwise skip because they run from DerivedData.

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS \
    -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/RoomForMac.app --args -RFMUITestScenario onboarding
```

## Building the engine

```bash
git submodule update --init
scripts/build-engine.sh        # → build/engine
bats scripts/tests             # engine build checks
```

## Changing the engine patches

```bash
scripts/mole-patches.sh start  # build/mole-work: pinned Mole with every patch applied as a commit
# edit, then: scripts/mole-patches.sh test tests/<file>.bats ; commit inside build/mole-work
scripts/mole-patches.sh export # rewrite patches/mole/*.patch
```

The host protocol is documented in `docs/engine-protocol.md`.

## License

GPL-3.0 — see `LICENSE` and `NOTICE`. RoomForMac is an independent project, not affiliated with or endorsed by Mole.
