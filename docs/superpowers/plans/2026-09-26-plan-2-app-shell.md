# Plan 2 — App Shell, Design System, Onboarding & Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A RoomForMac.app that builds from `project.yml`, embeds and verifies the patched engine, and shows the Alpine Moss design system. The app runs the full eight-screen onboarding for every approval, offers Settings → General, Permissions and About, and has a sidebar shell ready for Plan 3's features.

**Architecture:** XcodeGen generates one macOS app target, `RoomForMac`. It links the local `MoleEngine` package from Plan 1 and has two test targets:
- `RoomForMacTests`: app-hosted Swift Testing unit tests.
- `RoomForMacUITests`: an XCUITest smoke test.

Build phases handle the engine:
- They rebuild `build/engine` only when its inputs change.
- They generate the expected engine version as Swift.
- They copy the engine into `Contents/Resources/engine`, with its two Go binaries in `Contents/Helpers`, and sign those binaries with the app's identity.

Every system interaction goes behind an injected protocol or closure:
- Full Disk Access probes, Apple-event permission checks, notifications, login items, moving the app, and relaunch.
- Unit tests and the UI smoke test drive the app with scripted fakes and never trigger a real prompt.

**Tech Stack:** Swift 6 (Xcode 27.0 / Swift 6.4 locally), SwiftUI with the macOS 26 Liquid Glass APIs, Swift Testing, XCTest (UI tests only), XcodeGen 2.46, bash 3.2 + bats-core for scripts, Core Image (backdrop blur), CoreText (wordmark paths), ServiceManagement, UserNotifications, CoreServices (Apple events).

**Spec:** `docs/superpowers/specs/2026-09-25-roomformac-design.md` (§3.2–3.3, §5.6, §6, §10, §11; §12 signing half). Plan 1 (`docs/superpowers/plans/2026-09-25-plan-1-engine.md`) is done, and its Global Constraints and Environment notes also apply here. The research behind this plan (spikes S1, S2, S5-signing, bundling) is summarised in the **Rulings** section below.

**Status:** Not started. Branch `plan2/app-shell`, based on `main` at `7a99b38`.

## Global Constraints

- **Platform:** macOS 26.0 deployment target (`LSMinimumSystemVersion` 26.0). Universal Release builds (`ARCHS = $(ARCHS_STANDARD)` → arm64 + x86_64). Swift 6 language mode (`SWIFT_VERSION = 6.0`). SwiftUI. Unit tests use Swift Testing (`import Testing`); only UI tests use XCTest.
- **Project generation:** the project is generated from `project.yml` by XcodeGen 2.46. Git ignores `RoomForMac.xcodeproj/`, `RoomForMac/Info.plist`, `RoomForMac/RoomForMac.entitlements`, `RoomForMac/Generated/` and `Config/Local.xcconfig`.
- **Dependencies:** none from third parties. The app links only `MoleEngine`, through `packages: MoleEngine: path: Packages/MoleEngine`. The unit-test target does **not** link the package again.
- **Identity:**
  - Bundle ID `com.roomformac.app`; UserDefaults domain is the bundle ID.
  - Helper tool identifiers are `com.roomformac.app.engine.<tool>`.
  - URL scheme `roomformac`.
  - Product and display name `RoomForMac`.
  - `LSApplicationCategoryType` is `public.app-category.utilities`.
- **Security settings:** no App Sandbox (`EngineEnvironment.current()` must see the real home). Hardened runtime **off**. No `com.apple.security.automation.apple-events` entitlement: it is not needed while hardened runtime is off, and must be added if Plan 6 turns hardened runtime on.
- **Signing settings live only in `Config/Signing.xcconfig`** (`CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM =`, `CODE_SIGN_IDENTITY = -`, `ENABLE_HARDENED_RUNTIME = NO`, then `#include? "Local.xcconfig"`). Neither the `settings:` of `project.yml` nor any target `settings:` may set `CODE_SIGN_*` or `DEVELOPMENT_TEAM`, because they would silently override the xcconfig.
- **Engine:**
  - Scripts, `lib`, `host-bin`, `VERSION` and Mole's `LICENSE` go in `RoomForMac.app/Contents/Resources/engine/`.
  - `analyze-go` and `status-go` go in `Contents/Helpers/`, with relative symlinks `engine/bin/<tool>` → `../../../Helpers/<tool>`.
  - The app never uses a system-installed `mo` and has **no runtime override** of the engine location. `RFM_ENGINE_DIR` is a build setting only.
- **Info.plist `NSAppleEventsUsageDescription`, verbatim:** `RoomForMac asks Finder for your disk's free space and, if needed, to move apps to the Trash. It asks System Events which apps are running before a cleanup and to remove the login items of apps you uninstall.`
- **Color tokens (spec §11.1), exact:**

  | Token | Light | Dark |
  |---|---|---|
  | `canvas` | `#F1F0E5` | `#1C2119` |
  | `surface` | `#FCFBF2` | `#262D22` |
  | `text` | `#333B2D` | `#F1F0E5` |
  | `textSecondary` | `text` at 65% opacity | `text` at 65% opacity |
  | `action` | `#586440` | `#ADB591` |
  | `onAction` | `#FCFBF2` | `#1C2119` |
  | `moss` | `#ADB591` | `#7E8866` |
  | `grass` | `#B3915D` | `#C9A877` |
  | `clay` | `#A8563F` | `#C97A5F` |

  Measured WCAG contrast (light): `action` on `canvas` = 5.54, `onAction` on `action` = 6.11. The spec's "≈ 5.6 / ≈ 6.4" were approximations; tests pin 5.54 and 6.11.
- **Typography:** SF Pro for UI. SF Pro Rounded with `monospacedDigit()` for sizes, counters and gauges. The large-number hero style is 44–56 pt.
- **Liquid Glass (spike S1):**
  - Allowed from macOS 26.0: `glassEffect(_:in:)`, `Glass.regular/.clear/.identity`, `.tint(_:)`, `.interactive(_:)`, `GlassEffectContainer(spacing:)`, `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)`, `glassEffectTransition(_:)`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` and `backgroundExtensionEffect()`.
  - **Banned:** `.buttonStyle(.glass(_:))`, `GlassButtonStyle(_:)`, and any API newer than 26.0 without `#available`.
  - Write result-builder closures with `@ViewBuilder` (never `@ContentBuilder`, which exists only in SDK 27).
  - Do not add `.glassEffect()` to the sidebar: macOS 26 already draws it as glass.
- **Motion:** hover uses `spring(response: 0.3, dampingFraction: 0.7)` to scale 1.02. Section crossfades take 0.8 s. The Ken Burns drift is a 60 s loop, at most 8% scale.
- **Accessibility:**
  - Reduce Transparency: solid `surface` cards and a solid `canvas` backdrop with no blur.
  - Reduce Motion: no drift or idle motion, and crossfades (`.materialize`) instead of morphs.
  - Every control has a VoiceOver label, and every interactive element has an `accessibilityIdentifier` from `AccessibilityID` (Task 7).
- **Strings:** every user-facing string goes through the String Catalog `RoomForMac/Resources/Localizable.xcstrings`, via `Text("literal")`, `LocalizedStringKey`, `LocalizedStringResource` or `String(localized:)`. English only. There are no string-concatenated sentences.
- **Trademark:** "Mole" never appears in branding. Mole is credited as the engine only in About, `NOTICE` and `CREDITS.md`.
- **Photos:** only public domain, CC0 or CC BY (credited). None are bundled until the owner picks them. Until then, `BackdropScene` falls back to palette gradients.
- **Tests never trigger system prompts:**
  - When hosted by XCTest (`RuntimeMode.unitTestHost`), the app starts no engine check, no permission check and no polling.
  - Unit tests call `UNUserNotificationCenter`, `SMAppService`, `AEDeterminePermissionToAutomateTarget` and `NSWorkspace` only through injected closures.
  - The UI smoke test uses `-RFMUITestScenario`, which is honoured only in DEBUG builds.
- **Blocking Apple-event calls:** run only on a GCD queue through `BlockingCall.run(deadline:)`, never on the Swift cooperative pool. Deadlines are 3 s for passive checks and 120 s for requests that may prompt.
- **Scripts:** bash 3.2 compatible, `set -euo pipefail`, clean under `shellcheck` and `shfmt -d -i 4 -ci -sr`. In bats tests, a `[[ ]]` that is not the last statement ends with `|| return 1`, and CI audits `scripts/tests/*.bats`.
- **Engine builds:** never run two engine builds at once. `scripts/build-engine.sh`, `bats scripts/tests`, and an Xcode build that triggers `ensure-engine.sh` all re-clone `build/engine-src`.
- **Commits:** conventional commit subjects; every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Rulings (decisions this plan takes on the owner's behalf)

Each ruling lists what it costs if wrong. The spec is the authority, and these rulings deviate from it only where research showed the spec cannot be met as written.

1. **Bundle ID `com.roomformac.app`.** The spec names none. *If wrong:* changing it after the first public release resets every user's TCC grants and preferences. Confirm it before Plan 6 ships.
2. **Go binaries live in `Contents/Helpers`, with symlinks in `engine/bin`** (spec §4.2 says `Resources/engine/`). Apple's bundle-placement guidance puts helper tools in `Helpers`, and misplaced code can break notarization later. This was verified end to end with the real engine: strict `codesign --verify --deep` passes, and `EngineInstallation` needs no change. *If wrong:* a one-script change.
3. **The engine is built by stamp check, not on every build.** `scripts/ensure-engine.sh` rebuilds `build/engine` only when `vendor/mole`'s commit, `patches/mole/*` or `scripts/build-engine.sh` changed, which it records as a new `builder_sha256` key in `VERSION`. `scripts/embed-engine.sh` then copies it. The handoff's idea of running `build-engine.sh` into the app would rebuild Go for about a minute on every build. *If wrong:* a stale engine, but the launch check compares `VERSION` with the generated expectation.
4. **One signing identity, `RoomForMac Self-Signed`, used for local and release builds** (spec §3.3, §12: "one stable self-signed certificate"). `scripts/make-signing-identity.sh` creates it and the owner runs it. Until then builds are ad-hoc, and FDA and Automation grants reset on every rebuild. *If wrong:* the owner would need a second identity for releases; grants made on dev builds would then not carry over.
5. **`GlassButton` uses the system glass button styles.** Primary is `.glassProminent` tinted `action`, secondary is `.glass`, destructive is `.glassProminent` tinted `clay`. Only controls that must morph (the Scan button, onboarding dots) use `.buttonStyle(.plain)` with `.glassEffect(.regular.tint(action).interactive(), in:)`. `glassEffectID` morphs only work on `glassEffect` views. This deviates from spec §11.4's literal `.regular.tint(action).interactive()` on every primary button. *If wrong:* one component to change.
6. **The backdrop blur is computed once per image** (Core Image Gaussian, radius 40) and cached. It is not recomputed every frame. The onboarding "blur → focus" crossfades the blurred and sharp images. *If wrong:* a visual difference only.
7. **App-hosted unit tests with a test-host guard**, not a fourth local package (spec §4.1 lists only three). *If wrong:* the logic could move to a package later without API change.
8. **Scenes:**
   - `Window("RoomForMac", id: "main")` is the single main window; a `WindowGroup` would duplicate it when opened from the menu bar.
   - A `Settings` scene.
   - Onboarding is shown inside the main window, so "Start first scan" can hand off to Smart Clean in one view hierarchy.
   - The `MenuBarExtra` scene and its Settings toggle belong to Plan 3.
9. **Sidebar in this plan:** Smart Clean, Uninstaller, Status, each with a placeholder detail view. Terrain (Plan 4) is outside M2 and gets no placeholder.
10. **Onboarding reasons follow the engine's real Apple-event use** (research, V7).
    - **System Events:** it lists running apps on every Smart Clean scan and run, and removes login items during uninstall.
    - **Finder:** it reports the exact free space in Status, and is a fallback for moving apps to the Trash.

    Spec §6 gave other reasons. Plan 3 must not start `StatusService` or a scan before onboarding is complete; `AppModel.isOnboarded` exposes this.
11. **Full Disk Access is detected with a list of probe files**, not "the user's `TCC.db`". The user `TCC.db` does not exist on macOS 27. `open()` returning EPERM or EACCES means denied, success means granted, and ENOENT means no evidence.
12. **What counts as installed:** anything under `/Applications/` or `~/Applications/`. A standard user cannot write `/Applications`, so the Move step offers `~/Applications`. If that fails too, it tells the user to drag the app. DEBUG builds skip the Move step unless the launch argument `-RFMForceMoveStep YES` is passed.
13. **Mole's `LICENSE` ships in the engine.** `build-engine.sh` copies `vendor/mole/LICENSE` into `$OUT/LICENSE`. GPL-3.0 requires it, and research found it missing. About shows it next to RoomForMac's `LICENSE`, `NOTICE` and `CREDITS.md`.
14. **CI:** a new `app` job on `runs-on: xcode-27` matches the local Xcode 27.0. The `macos-26` image has only Xcode 26.6 and SDK 26.5. The engine job stays on `macos-26`. CI still cannot run until the owner fixes Actions billing or makes the repository public. *If wrong:* change one label.
15. **No app icon, wordmark asset or photos are bundled in this plan.**
    - The wordmark is drawn from CoreText glyph outlines of "RoomForMac" in SF Pro Rounded Semibold.
    - The app icon arrives with Plan 6 branding.
    - Backdrops use palette gradients until the owner picks photos.

## Review Focus

These are the five input classes or failure modes most likely to bite a real user that the spec implies but does not spell out. Each line names the test that pins it.

1. **A missing, stale or unrunnable engine in the bundle.** Examples: a build from the Xcode window with no Homebrew on `PATH`, a helper killed at exec because it was quarantined or left unsigned, or a `VERSION` from an older build. Expected: a blocking "Reinstall RoomForMac" card with details and Copy diagnostics, never a crash or a failure later at first scan. Pinned in Task 3: `EngineHealthCheck` with a missing file, a mismatched `VERSION`, and a self-test that exits non-zero or is killed by a signal.
2. **Permission probes that hang or give no answer.** Examples: System Events not running (`-600`), an Apple-event permission call that never returns, FDA probe files absent (ENOENT on macOS 27). Expected: "unknown" and a responsive UI; never a false "granted". Pinned in Tasks 8 and 9: the `BlockingCall` deadline, FDA ENOENT → `.unknown`, and the OSStatus mapping.
3. **Relaunching or quitting mid-onboarding.** Examples: the relaunch after "Move to Applications", the relaunch after granting FDA, or quitting at step 5. Expected: the next launch resumes at the saved step, and never restarts from Welcome or skips FDA. Pinned in Task 11: `OnboardingFlow` restores the persisted step.
4. **Running from somewhere other than Applications.** Examples: a DMG, a translocated path, `~/Downloads`, or a standard user who cannot write `/Applications`, with an older copy already installed (running or not). Expected: correct classification; never overwrite a running copy; offer `~/Applications`, then "drag it yourself". Pinned in Task 10: `AppLocation.classify` and `AppMover` with an existing destination, a running destination and an unwritable folder.
5. **Accessibility or appearance changing while the app runs.** Examples: Reduce Motion, Reduce Transparency or Dark Mode toggled mid-session. Expected: drift and idle motion stop at once, glass falls back to solid surfaces, and the tokens swap. Pinned in Tasks 4–6: `GlassSurfacePolicy`, the `Motion` policy, the dark `Palette` values and the `KenBurns` pause.

---

## File Structure

```
project.yml                                   XcodeGen definition (Task 1)
Config/Signing.xcconfig                       signing defaults + #include? "Local.xcconfig" (Task 1)
Brewfile                                      + brew "xcodegen" (Task 1)
CREDITS.md                                    Mole credit + photo credits section (Task 14)
scripts/
  build-engine.sh                             + builder_sha256 key, + copies Mole LICENSE (Task 2)
  ensure-engine.sh                            stamp check → build-engine.sh (Task 2)
  engine-expectation.sh                       VERSION → RoomForMac/Generated/EngineExpectation.swift (Task 2)
  embed-engine.sh                             copy engine, move Mach-O to Helpers, sign (Task 2)
  make-signing-identity.sh                    stable self-signed identity (Task 16)
  tests/build_engine.bats                     + builder_sha256 and LICENSE checks (Task 2)
  tests/app_bundle.bats                       checks a built RoomForMac.app (Task 2)
  tests/signing_identity.bats                 argument handling of make-signing-identity.sh (Task 16)
RoomForMac/
  App/
    RoomForMacApp.swift                       @main; scenes; runtime-mode switch (Task 1, 7)
    RuntimeMode.swift                         normal / unitTestHost / uiTest(scenario) (Task 1)
    AppDependencies.swift                     composition root: live + DEBUG scenarios (Task 7, 15)
    AppPreferences.swift                      typed UserDefaults wrapper (Task 7)
    AppModel.swift                            engine phase, onboarding flag, sidebar selection (Task 7)
    SidebarSection.swift                      Smart Clean / Uninstaller / Status (Task 7)
    RootView.swift                            engine problem | onboarding | split view (Task 7)
    AccessibilityID.swift                     every accessibility identifier (Task 7)
  DesignSystem/
    Palette.swift                             tokens, dynamic colors, WCAG contrast (Task 4)
    Typography.swift                          hero numerals, rounded digits (Task 4)
    Motion.swift                              springs, durations, reduce-motion policy (Task 4)
    GlassButton.swift                         primary / secondary / destructive (Task 5)
    GlassCard.swift                           glass card + Reduce Transparency fallback (Task 5)
    MorphingGlass.swift                       glassEffect + glassEffectID helper for morphs (Task 5)
    GlassDots.swift                           onboarding progress dots (Task 5)
    Wordmark.swift                            CoreText glyph path + stroke-draw animation (Task 5)
    Backdrop/BackdropScene.swift              scene → resource name + fallback gradient (Task 6)
    Backdrop/KenBurns.swift                   60 s drift math (Task 6)
    Backdrop/BackdropImageLoader.swift        load + pre-blur + cache (Task 6)
    Backdrop/BackdropView.swift               wash, drift, crossfade, a11y fallbacks (Task 6)
  Engine/
    EngineHealthCheck.swift                   §10 launch integrity check (Task 3)
    EngineProblem.swift                       problem cases + expectation values (Task 3)
    ErrorPresentation.swift                   any Error → title/message/details/diagnostics (Task 3)
    EngineProblemView.swift                   blocking "Reinstall RoomForMac" card (Task 3)
  Features/
    Permissions/
      PermissionID.swift  PermissionState.swift  PermissionChecking.swift       (Task 8)
      PermissionCenter.swift  BlockingCall.swift  SystemSettingsLink.swift      (Task 8)
      FullDiskAccessChecker.swift  AutomationChecker.swift  AppleEventPermission.swift (Task 9)
      NotificationChecker.swift  LoginItemChecker.swift                         (Task 9)
      AppLocation.swift  AppLocationChecker.swift  AppMover.swift  Relauncher.swift (Task 10)
      PermissionCard.swift                    reusable card + state chip (Task 12)
      ScriptedPermissionChecker.swift         DEBUG fake for UI tests (Task 15)
    Onboarding/
      OnboardingStep.swift  OnboardingChoices.swift  OnboardingFlow.swift        (Task 11)
      OnboardingView.swift  OnboardingScaffold.swift                             (Task 12)
      Steps/WelcomeStep.swift  FreeToExploreStep.swift  MoveToApplicationsStep.swift  FullDiskAccessStep.swift (Task 12)
      Steps/AutomationStep.swift  AdminAccessStep.swift  ExtrasStep.swift  ReadyStep.swift (Task 13)
    Settings/
      SettingsView.swift  GeneralSettingsView.swift  PermissionsSettingsView.swift (Task 14)
      AboutView.swift  LegalDocument.swift                                        (Task 14)
    SmartClean/SmartCleanPlaceholderView.swift                                    (Task 7)
    Uninstaller/UninstallerPlaceholderView.swift                                  (Task 7)
    Status/StatusPlaceholderView.swift                                            (Task 7)
  Generated/EngineExpectation.swift           git-ignored, written by engine-expectation.sh (Task 2)
  Resources/
    Localizable.xcstrings                     String Catalog (Task 1; grows every task)
    Assets.xcassets/                          AccentColor = action (Task 1, 4)
    Backgrounds/README.md                     how photos are added; empty until chosen (Task 6)
RoomForMacTests/                              Swift Testing, app-hosted (every task)
  Support/TemporaryDirectory.swift  Support/FakeEngineRunner.swift  Support/EngineLayout.swift (Task 3)
RoomForMacUITests/
  OnboardingSmokeTests.swift  EngineProblemSmokeTests.swift                     (Task 15)
.github/workflows/ci.yml                      + app job (Task 17)
README.md                                     + building and running the app, signing (Task 17)
```

---

## Tasks

The task text below is the requirements contract. The **Interfaces** blocks are binding: names, types and signatures must match across tasks exactly.

### Task 1: XcodeGen project, app skeleton and test-host guard

**Files:**
- Create: `project.yml`, `Config/Signing.xcconfig`, `RoomForMac/App/RoomForMacApp.swift`, `RoomForMac/App/RuntimeMode.swift`, `RoomForMac/Resources/Localizable.xcstrings`, `RoomForMac/Resources/Assets.xcassets/{Contents.json,AccentColor.colorset/Contents.json}`, `RoomForMacTests/RuntimeModeTests.swift`, `RoomForMacUITests/LaunchSmokeTests.swift`
- Modify: `.gitignore`, `Brewfile`

**Interfaces:**
- Consumes: nothing from earlier tasks. Links `MoleEngine` (Plan 1).
- Produces:
  ```swift
  enum UITestScenario: String, Sendable, CaseIterable {
      case onboarding = "onboarding"        // fresh install, scripted permissions that grant on request
      case onboarded = "onboarded"          // onboarding already completed
      case engineBroken = "engine-broken"   // engine health check reports a problem
  }
  enum RuntimeMode: Equatable, Sendable {
      case normal
      case unitTestHost
      case uiTest(UITestScenario)
      static let scenarioArgument = "-RFMUITestScenario"
      static func detect(environment: [String: String], arguments: [String], isDebugBuild: Bool) -> RuntimeMode
      static var current: RuntimeMode { get }   // detect(ProcessInfo env, args, isDebugBuild: #if DEBUG)
  }
  ```
  - Schemes: `RoomForMac` (builds the app; tests `RoomForMacTests` + `RoomForMacUITests`) and `RoomForMacUnit` (tests `RoomForMacTests` only; parallelizable false).
  - Targets: `RoomForMac`, `RoomForMacTests` (`bundle.unit-test`, host = app), `RoomForMacUITests` (`bundle.ui-testing`).

**Requirements:**
- `project.yml` follows the verified probe layout from the research (XcodeGen 2.46).
  - `options`: `bundleIdPrefix: com.roomformac`, deployment target macOS 26.0, `createIntermediateGroups: true`, `developmentLanguage: en`.
  - `configFiles` for Debug and Release point to `Config/Signing.xcconfig`.
  - Project `settings.base`: `SWIFT_VERSION: "6.0"`, `MARKETING_VERSION: "0.1.0"`, `CURRENT_PROJECT_VERSION: "1"`, `DEAD_CODE_STRIPPING: YES`, `ENABLE_USER_SCRIPT_SANDBOXING: NO`, `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`, `SWIFT_EMIT_LOC_STRINGS: YES`. **No `CODE_SIGN_*` and no `DEVELOPMENT_TEAM` anywhere in `project.yml`.**
  - The app target:
    - `PRODUCT_BUNDLE_IDENTIFIER: com.roomformac.app`, `PRODUCT_NAME: RoomForMac`, `ARCHS: $(ARCHS_STANDARD)`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`.
    - `info:` generates `RoomForMac/Info.plist` with: `CFBundleDisplayName` RoomForMac; `LSApplicationCategoryType` `public.app-category.utilities`; `LSMinimumSystemVersion` `$(MACOSX_DEPLOYMENT_TARGET)`; `CFBundleShortVersionString` `$(MARKETING_VERSION)`; `CFBundleVersion` `$(CURRENT_PROJECT_VERSION)`; `NSAppleEventsUsageDescription` (verbatim from Global Constraints); `CFBundleURLTypes` (`CFBundleURLName` `com.roomformac.app`, scheme `roomformac`).
    - Also these usage descriptions, which are only shown when FDA is skipped:
      - `NSDownloadsFolderUsageDescription`: "RoomForMac looks for unfinished downloads it can clean up."
      - `NSDesktopFolderUsageDescription`: "RoomForMac measures what fills your Desktop."
      - `NSDocumentsFolderUsageDescription`: "RoomForMac measures what fills your Documents folder."
      - `NSRemovableVolumesUsageDescription`: "RoomForMac measures what fills your external drives."
      - `NSNetworkVolumesUsageDescription`: "RoomForMac measures what fills network drives you choose."
    - `entitlements:` generates `RoomForMac/RoomForMac.entitlements` with `properties: {}` and no sandbox.
  - `sources`: `RoomForMac` with `excludes: [Generated]`, plus `RoomForMac/Generated/EngineExpectation.swift` with `optional: true`. Task 2 adds the script phases.
- `Config/Signing.xcconfig`, verbatim:
  ```
  CODE_SIGN_STYLE = Manual
  DEVELOPMENT_TEAM =
  CODE_SIGN_IDENTITY = -
  ENABLE_HARDENED_RUNTIME = NO
  #include? "Local.xcconfig"
  ```
- `.gitignore` adds `RoomForMac.xcodeproj/`, `RoomForMac/Info.plist`, `RoomForMac/RoomForMac.entitlements`, `RoomForMac/Generated/`, `Config/Local.xcconfig` and `.superpowers/`. `Brewfile` adds `brew "xcodegen"`.
- `RuntimeMode.detect`:
  - `-RFMUITestScenario <raw>` with a known raw value and `isDebugBuild == true` gives `.uiTest(scenario)`.
  - Otherwise, an environment containing `XCTestConfigurationFilePath` gives `.unitTestHost`.
  - Otherwise `.normal`. An unknown scenario value, or any scenario in a non-DEBUG build, is ignored (`.normal`).
- `RoomForMacApp`:
  - In `.unitTestHost` it shows a single `WindowGroup { Color.clear }` scene and constructs nothing else.
  - Otherwise it shows a `Window("RoomForMac", id: "main")` with a temporary `Text("RoomForMac")`, and a `Settings` scene with a temporary `Text("Settings")`. Task 7 replaces both.
- Tests:
  - `RuntimeModeTests` covers every branch of `detect`, including unknown scenario, release build and precedence (a scenario wins over `XCTestConfigurationFilePath`).
  - `LaunchSmokeTests` (XCTest) launches the app and asserts a window exists. It runs only when Automation Mode is available; see Task 15.
- Verify: `xcodegen generate` succeeds, then `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test` passes, and `xcodebuild -showBuildSettings -scheme RoomForMac | grep -E 'CODE_SIGN_IDENTITY|PRODUCT_BUNDLE_IDENTIFIER|SWIFT_VERSION|ENABLE_HARDENED_RUNTIME'` shows `-`, `com.roomformac.app`, `6.0`, `NO`.

### Task 2: Engine build phases, bundle layout and bundle checks

**Files:**
- Create: `scripts/ensure-engine.sh`, `scripts/engine-expectation.sh`, `scripts/embed-engine.sh`, `scripts/tests/app_bundle.bats`, `RoomForMacTests/EmbeddedEngineTests.swift`
- Modify: `scripts/build-engine.sh`, `scripts/tests/build_engine.bats`, `project.yml`

**Interfaces:**
- Consumes: Task 1's `project.yml`, targets and schemes.
- Produces:
  - `build/engine/VERSION` gains `builder_sha256=<sha256 of scripts/build-engine.sh>`. `build/engine/LICENSE` is a copy of `vendor/mole/LICENSE`.
  - `RoomForMac/Generated/EngineExpectation.swift` (git-ignored, regenerated every build, rewritten only when the content changes):
    ```swift
    // Generated by scripts/engine-expectation.sh from build/engine/VERSION. Do not edit.
    enum EngineExpectation {
        static let moleTag = "V1.56.0"
        static let moleCommit = "<40-hex>"
        static let patchesSHA256 = "<64-hex or none>"
        static let patchCount = 5
    }
    ```
  - Built app layout: `Contents/Resources/engine/{mole,VERSION,LICENSE,bin/*.sh,lib/**,host-bin/sudo}`, `Contents/Helpers/{analyze-go,status-go}`, and symlinks `engine/bin/{analyze-go,status-go}` → `../../../Helpers/<tool>`.
  - Each helper is signed with the app's identity as `com.roomformac.app.engine.<tool>`.
  - `scripts/tests/app_bundle.bats` reads `APP=/path/to/RoomForMac.app` from the environment and skips with a message when it is unset.

**Requirements:**
- `build-engine.sh`:
  - Writes `builder_sha256` into `VERSION`, after `patch_count`.
  - Copies `$VENDOR/LICENSE` to `$OUT/LICENSE`.
  - `build_engine.bats` gains two tests: "VERSION records the builder hash" and "engine ships Mole's license" (`cmp` with `vendor/mole/LICENSE`).
- `ensure-engine.sh`:
  - Use the verified research version: stamp compare of `mole_commit`, `patches_sha256` and `builder_sha256`.
  - Export `PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`.
  - With `RFM_NO_ENGINE_BUILD=1` it errors instead of building.
  - Its runtime is about 0.1 s when the engine is up to date.
- `engine-expectation.sh`:
  - Reads `mole_tag`, `mole_commit`, `patches_sha256` and `patch_count` from `$RFM_ENGINE_DIR/VERSION`.
  - Writes `$SCRIPT_OUTPUT_FILE_0` only when the content changed (`cmp -s`), and fails clearly if a key is missing.
  - Values are emitted as Swift string or integer literals. Escape nothing, and reject values containing `"` or `\`.
- `embed-engine.sh`:
  - Use the verified research version: fingerprint stamp, `ditto`, move Mach-O to `Helpers`, symlink, sign with `EXPANDED_CODE_SIGN_IDENTITY` and `--identifier "${PRODUCT_BUNDLE_IDENTIFIER}.engine.$name"`, add `--options runtime` only with hardened runtime, and `touch` the declared output.
- `project.yml`, on the app target:
  - Setting `RFM_ENGINE_DIR: $(SRCROOT)/build/engine`.
  - `preBuildScripts` "Prepare engine", running `"${SRCROOT}/scripts/ensure-engine.sh" && "${SRCROOT}/scripts/engine-expectation.sh"`, with `basedOnDependencyAnalysis: false` and output `$(SRCROOT)/RoomForMac/Generated/EngineExpectation.swift`.
  - `postBuildScripts` "Embed engine", running `"${SRCROOT}/scripts/embed-engine.sh"`, with `basedOnDependencyAnalysis: false` and output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/engine/VERSION`.
- `app_bundle.bats` implements every check listed in the research:
  - strict deep verify;
  - `lipo -archs` of the app executable and helpers is `x86_64 arm64` when `EXPECT_UNIVERSAL=1`;
  - the helper identifiers start with `com.roomformac.app.engine.`;
  - the helpers' `Authority` equals the app's (or both are ad-hoc);
  - the symlinks point into `../../../Helpers/`;
  - `cmp build/engine/VERSION` against the bundled `VERSION`;
  - the bundled `engine/LICENSE` equals `vendor/mole/LICENSE`;
  - `status-go --json` exits 0 and prints `"cpu"`.
- `EmbeddedEngineTests` (app-hosted Swift Testing):
  - `EngineInstallation.bundled()` succeeds, and its `root.path` ends with `RoomForMac.app/Contents/Resources/engine`.
  - `installation.version.moleTag == EngineExpectation.moleTag`, and the same for commit, patch hash and count.
  - The helper at `Bundle.main.bundleURL/Contents/Helpers/status-go` exists and is executable.
- Verify:
  - `shellcheck` and `shfmt` are clean on the new scripts.
  - `bats scripts/tests/build_engine.bats` is green.
  - An `xcodebuild … -scheme RoomForMacUnit test` run is green.
  - A Release build (`-configuration Release -destination "generic/platform=macOS"`) followed by `APP=<path> EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats` is green.
  - A second no-op build prints "Engine already embedded" and "Engine is up to date".

### Task 3: Engine health check, error presentation and the blocking problem card

**Files:**
- Create: `RoomForMac/Engine/EngineProblem.swift`, `RoomForMac/Engine/EngineHealthCheck.swift`, `RoomForMac/Engine/ErrorPresentation.swift`, `RoomForMac/Engine/EngineProblemView.swift`, `RoomForMacTests/Support/TemporaryDirectory.swift`, `RoomForMacTests/Support/EngineLayout.swift`, `RoomForMacTests/Support/FakeEngineRunner.swift`, `RoomForMacTests/EngineHealthCheckTests.swift`, `RoomForMacTests/ErrorPresentationTests.swift`

**Interfaces:**
- Consumes: `EngineExpectation` (Task 2, generated). From `MoleEngine`: `EngineInstallation`, `EngineVersion`, `EngineRunning`, `EngineCommand`, `EngineEnvironment`, `EngineError`, `MoleRunner`.
- Produces:
  ```swift
  struct EngineFingerprint: Sendable, Equatable {
      var moleTag: String; var moleCommit: String; var patchesSHA256: String; var patchCount: Int
      init(moleTag: String, moleCommit: String, patchesSHA256: String, patchCount: Int)
      init(_ version: EngineVersion)
      static var expected: EngineFingerprint { get }   // from EngineExpectation
  }
  enum EngineProblem: Error, Sendable, Equatable {
      case installationInvalid(String)                                   // EngineError.installationInvalid message
      case versionMismatch(expected: EngineFingerprint, found: EngineFingerprint)
      case selfTestFailed(tool: String, detail: String)                  // tool = "analyze-go" | "status-go"
  }
  struct EngineHealthCheck: Sendable {
      init(expected: EngineFingerprint = .expected,
           runner: any EngineRunning = MoleRunner(),
           environment: EngineEnvironment = .current(),
           selfTestTimeout: Duration = .seconds(10),
           locate: @escaping @Sendable () throws -> EngineInstallation = { try EngineInstallation.bundled() })
      func run() async -> Result<EngineInstallation, EngineProblem>
  }
  struct ErrorPresentation: Sendable, Equatable {
      var title: String; var message: String; var details: String
      init(_ error: any Error)
      func diagnostics(appVersion: String, osVersion: String) -> String
  }
  struct EngineProblemView: View { init(problem: EngineProblem) }
  ```
  Test support in `RoomForMacTests/Support`:
  - `TemporaryDirectory`: creates a unique directory, exposes `url`, removes it on `deinit`; a class.
  - `EngineLayout.make(in:version:)`: writes the seven required files plus `VERSION`, executable where needed. It returns the root `URL`, and each `version` key is written verbatim.
  - `FakeEngineRunner: EngineRunning`: scripted responses per executable last path component (`[String: Result<[String], EngineError>]`), and records the commands.

**Requirements:**
- `run()` checks in order:
  1. `locate()`: an `EngineError.installationInvalid(m)` becomes `.installationInvalid(m)`, and any other error becomes `.installationInvalid(String(describing: error))`.
  2. The fingerprint must equal `expected`, otherwise `.versionMismatch`.
  3. A self-test runs `analyzeBinary` then `statusBinary` with arguments `["-h"]`, `environment.variables(for: installation)`, `.stdout` output and `selfTestTimeout`, collected through `runner.collect`. Any thrown error becomes `.selfTestFailed(tool:detail:)`, with `detail` from `ErrorPresentation(error).details`.

  It returns the installation on success.
- `ErrorPresentation` maps, in plain language:
  - `EngineProblem` (each case: title "RoomForMac needs to be reinstalled", with a case-specific message);
  - `EngineError` (each case: `timedOut` gives "The engine took too long", `cancelled` gives "Stopped", `nonZeroExit` and `terminatedBySignal` put `stderrTail` in `details`, `launchFailed` names the executable, `malformedOutput` gives "The engine returned something unexpected");
  - `DecodingError`;
  - `CocoaError` (file errors name the path);
  - any other error.

  `diagnostics` returns a multi-line string with the title, message, details, `App <appVersion>`, `macOS <osVersion>` and the expected engine fingerprint. It contains no user file paths beyond what `details` already holds.
- `EngineProblemView`:
  - A full-window `GlassCard` over the `canvas` color, titled "Reinstall RoomForMac", with the message.
  - A "Show details" disclosure with `details` in a monospaced, selectable text.
  - A **Copy diagnostics** `GlassButton(.secondary)` that writes to `NSPasteboard.general`, and an **Open download page** `GlassButton(.primary)` that opens `https://github.com/gugag2003/RoomForMac/releases`.
  - Accessibility identifiers come from `AccessibilityID.engineProblem*` (Task 7 defines the enum). This task adds `engineProblemCard`, `engineProblemDetails` and `engineProblemCopy` to a file `RoomForMac/App/AccessibilityID.swift` that Task 7 extends.
  - Because Tasks 4–5 are not done yet, this task uses plain SwiftUI styling. Task 5 swaps in `GlassCard`/`GlassButton`, and its brief says so.
- Tests (Swift Testing, using the fakes):
  - a healthy layout with a matching version → `.success`;
  - a missing `bin/clean.sh` → `.installationInvalid("missing bin/clean.sh")`;
  - a different `patches_sha256` → `.versionMismatch` carrying both fingerprints;
  - analyze self-test `nonZeroExit(code: 2, stderrTail: "boom")` → `.selfTestFailed(tool: "analyze-go", …)` whose detail contains "boom";
  - status self-test `terminatedBySignal(9, …)` → `.selfTestFailed(tool: "status-go", …)`;
  - self-test commands use `-h` and the environment from `variables(for:)`;
  - `ErrorPresentation` title and message for every `EngineError` case;
  - `diagnostics` contains the app version, the macOS version and the expected fingerprint.

### Task 4: Design tokens — palette, typography, motion

**Files:**
- Create: `RoomForMac/DesignSystem/Palette.swift`, `RoomForMac/DesignSystem/Typography.swift`, `RoomForMac/DesignSystem/Motion.swift`, `RoomForMacTests/PaletteTests.swift`, `RoomForMacTests/MotionTests.swift`
- Modify: `RoomForMac/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` (the `action` light and dark values)

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  struct RGB: Sendable, Equatable {
      var red: Double; var green: Double; var blue: Double; var opacity: Double   // 0...1
      init(hex: UInt32, opacity: Double = 1)
      var relativeLuminance: Double { get }                // WCAG 2.x
  }
  enum Palette {
      enum Token: String, CaseIterable, Sendable { case canvas, surface, text, textSecondary, action, onAction, moss, grass, clay }
      struct Swatch: Sendable, Equatable { var light: RGB; var dark: RGB }
      static func swatch(_ token: Token) -> Swatch
      static func color(_ token: Token) -> Color           // dynamic: NSColor(name:dynamicProvider:) on appearance
      static func contrastRatio(_ a: RGB, _ b: RGB) -> Double
      static var canvas: Color { get }  // one static per token: canvas, surface, text, textSecondary, action, onAction, moss, grass, clay
  }
  enum Typography {
      static let heroSizes: ClosedRange<CGFloat> = 44...56
      static func hero(size: CGFloat = 48) -> Font        // clamps to heroSizes; .system(size:, weight: .semibold, design: .rounded).monospacedDigit()
      static let numeral: Font                             // .system(.title2, design: .rounded).monospacedDigit()
      static let caption: Font                             // .system(.caption, design: .default)
  }
  enum Motion {
      static let hover: Animation                          // .spring(response: 0.3, dampingFraction: 0.7)
      static let hoverScale: CGFloat                       // 1.02
      static let sectionCrossfade: Duration                // .milliseconds(800)
      static let driftPeriod: Duration                     // .seconds(60)
      static let driftMaxScaleIncrease: CGFloat            // 0.08
      static let staggerStep: Duration                     // .milliseconds(30)
      static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation?   // nil when reduceMotion
      static func glassTransition(reduceMotion: Bool) -> GlassEffectTransition        // .materialize when reduceMotion, else .matchedGeometry
  }
  ```

**Requirements:**
- Swatches are the exact hex values from Global Constraints. `textSecondary` is `text` with `opacity` 0.65 in both appearances.
- `Palette.color` resolves light or dark from `NSAppearance.bestMatch(from: [.aqua, .darkAqua])`, where high-contrast variants map to their base appearance.
- `AccentColor` has the `action` light and dark values.
- Tests:
  - every token's light and dark hex;
  - contrast `action`/`canvas` (light) = 5.54 and `onAction`/`action` (light) = 6.11, both ±0.01 and both ≥ 4.5;
  - dark `action`/`canvas` ≥ 4.5;
  - `Palette.color(.canvas)` resolved under `NSAppearance(named: .darkAqua)` gives `#1C2119`, checked via `NSColor(...).usingColorSpace(.sRGB)` inside `appearance.performAsCurrentDrawingAppearance`;
  - `Typography.hero(size: 80)` clamps to 56 (expose the clamp as `static func heroSize(_:) -> CGFloat` and test that);
  - `Motion.animation(_:reduceMotion: true) == nil`;
  - `Motion.glassTransition(reduceMotion:)` for both values; compare with `==` if `GlassEffectTransition` is not Equatable, otherwise test through a small `enum GlassTransitionKind`, which the task may add.

### Task 5: Glass components — GlassButton, GlassCard, MorphingGlass, GlassDots, Wordmark

**Files:**
- Create: `RoomForMac/DesignSystem/GlassButton.swift`, `RoomForMac/DesignSystem/GlassCard.swift`, `RoomForMac/DesignSystem/MorphingGlass.swift`, `RoomForMac/DesignSystem/GlassDots.swift`, `RoomForMac/DesignSystem/Wordmark.swift`, `RoomForMacTests/GlassComponentTests.swift`, `RoomForMacTests/WordmarkTests.swift`
- Modify: `RoomForMac/Engine/EngineProblemView.swift` (switch to `GlassCard`/`GlassButton`)

**Interfaces:**
- Consumes: `Palette`, `Motion`, `Typography` (Task 4).
- Produces:
  ```swift
  enum GlassProminence: Sendable, CaseIterable { case primary, secondary, destructive }
  struct GlassButton<Label: View>: View {
      init(_ prominence: GlassProminence = .primary, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label)
  }
  extension GlassButton where Label == Text {
      init(_ titleKey: LocalizedStringKey, prominence: GlassProminence = .primary, action: @escaping @MainActor () -> Void)
  }
  enum GlassSurfacePolicy: Sendable, Equatable { case glass, solid
      static func resolve(reduceTransparency: Bool) -> GlassSurfacePolicy }
  struct GlassCard<Content: View>: View {
      init(cornerRadius: CGFloat = 20, padding: CGFloat = 20, @ViewBuilder content: () -> Content)
  }
  extension View {
      /// Liquid Glass that can morph between views sharing `id` inside one GlassEffectContainer.
      func morphingGlass<ID: Hashable & Sendable, S: Shape>(id: ID, in namespace: Namespace.ID, shape: S, tint: Color? = Palette.action, interactive: Bool = true) -> some View
  }
  struct GlassDots: View { init(count: Int, current: Int) }    // current clamped to 0..<count
  struct WordmarkShape: Shape {
      init(text: String = "RoomForMac", fontName: String? = nil, size: CGFloat = 64) // nil → SF Pro Rounded Semibold via NSFont.systemFont(ofSize:weight:) + .rounded descriptor
      func path(in rect: CGRect) -> Path
      static func glyphPath(text: String, font: CTFont) -> CGPath   // unscaled outline, origin at baseline
  }
  struct AnimatedWordmark: View { init(progress: Double) }    // trims the stroke 0...1, then fills in as progress → 1
  ```

**Requirements:**
- `GlassButton` styling per prominence:
  - `.primary`: `.buttonStyle(.glassProminent).tint(Palette.action)`.
  - `.secondary`: `.buttonStyle(.glass)`.
  - `.destructive`: `.buttonStyle(.glassProminent).tint(Palette.clay)`.

  All use `.controlSize(.large)` and `.buttonBorderShape(.capsule)`. Hover scales to `Motion.hoverScale` with `Motion.hover`, and not at all under Reduce Motion (read `accessibilityReduceMotion`).
- `GlassCard`:
  - `.glass` → `.glassEffect(.regular, in: .rect(cornerRadius:))`.
  - `.solid` → `.background(Palette.surface, in: .rect(cornerRadius:))`.
  - The policy comes from `accessibilityReduceTransparency`.
- `morphingGlass` applies `.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)`, then `.glassEffectID(id, in: namespace)`, then `.glassEffectTransition(Motion.glassTransition(reduceMotion:))`. Under Reduce Transparency it uses a solid `surface` fill in the same shape.
- `GlassDots`: one `GlassEffectContainer(spacing: 8)` of `count` dots, 8 pt each. The current dot is a 24 pt capsule that morphs between positions with a `glassEffectID("current")`. Accessibility label: "Step \(current + 1) of \(count)".
- `WordmarkShape`:
  - Glyph outlines come from `CTFontCreatePathForGlyph` for each glyph of `CTLineCreateWithAttributedString`, positioned by the run's glyph positions.
  - The path is flipped to SwiftUI's coordinate space and scaled to fit `rect` while keeping its aspect ratio.
  - `AnimatedWordmark` strokes with `trim(from: 0, to: progress)` in `Palette.text`, and fades the fill in over the last 20% of progress.
- `EngineProblemView` is updated to use `GlassCard` and `GlassButton`.
- Tests:
  - `GlassSurfacePolicy.resolve` for both inputs.
  - `GlassDots` clamps `current`: expose `static func clampedIndex(_ current: Int, count: Int) -> Int` and test it.
  - `WordmarkShape.glyphPath` for "RoomForMac" is non-empty; its bounding box width is > 4× its height; `path(in:)` fits inside the rect (±0.5 pt); two calls return equal bounding boxes (deterministic).
  - Each component renders through `ImageRenderer` without crashing and produces a non-nil `cgImage` at 300×120, in both light and dark `colorScheme`.

### Task 6: Backdrops — scenes, Ken Burns drift, pre-blurred loader, BackdropView

**Files:**
- Create: `RoomForMac/DesignSystem/Backdrop/BackdropScene.swift`, `RoomForMac/DesignSystem/Backdrop/KenBurns.swift`, `RoomForMac/DesignSystem/Backdrop/BackdropImageLoader.swift`, `RoomForMac/DesignSystem/Backdrop/BackdropView.swift`, `RoomForMac/Resources/Backgrounds/README.md`, `RoomForMacTests/BackdropTests.swift`
- Modify: `project.yml` (add `RoomForMac/Resources/Backgrounds` as a folder reference: `type: folder`, `buildPhase: resources`)

**Interfaces:**
- Consumes: `Palette`, `Motion` (Task 4).
- Produces:
  ```swift
  enum BackdropScene: String, CaseIterable, Sendable {
      case onboarding, smartClean, uninstaller, terrain, status
      var resourceName: String { get }          // "backdrop-<rawValue>"
      var fallbackColors: [Palette.Token] { get } // two or three tokens for a gradient
  }
  enum KenBurns {
      static func scale(at time: TimeInterval) -> CGFloat       // 1.0 ... 1.0 + Motion.driftMaxScaleIncrease, period Motion.driftPeriod
      static func offset(at time: TimeInterval, in size: CGSize) -> CGSize  // small pan, |dx|,|dy| ≤ 2% of size
  }
  struct BackdropImages: @unchecked Sendable { let sharp: CGImage; let blurred: CGImage }
  final class BackdropImageLoader: @unchecked Sendable {
      static let shared: BackdropImageLoader
      init(bundle: Bundle = .main, blurRadius: Double = 40, subdirectory: String = "Backgrounds")
      func images(for scene: BackdropScene) -> BackdropImages?   // nil when no resource; cached per scene; thread-safe (NSLock)
      static func blur(_ image: CGImage, radius: Double) -> CGImage?  // CIGaussianBlur on clampedToExtent, cropped to the original extent
  }
  struct BackdropView: View {
      init(scene: BackdropScene, focus: Double = 0)   // focus 0 = fully blurred, 1 = sharp (onboarding focus pull)
  }
  ```

**Requirements:**
- `images(for:)` looks for `resourceName` with the extensions `heic`, then `jpg`, then `png` in `subdirectory`.
- `BackdropView` layers:
  - the image: blurred at opacity `1 - focus`, sharp at opacity `focus`, `aspectFill`;
  - or, with no resource, a `LinearGradient` of the fallback tokens;
  - a `Palette.canvas` wash at 40% opacity.

  It applies `.backgroundExtensionEffect()`. Ken Burns drift runs in `TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion))`. The view crossfades on scene change with `.transition(.opacity)` and `.animation(.easeInOut(duration: 0.8), value: scene)`. Under Reduce Transparency it is a solid `Palette.canvas`, with no image and no blur.
- `Backgrounds/README.md` explains:
  - the naming (`backdrop-onboarding.heic` and so on);
  - the size (about 2560 px wide);
  - the conversion (`sips -s format heic --resampleWidth 2560 in.jpg --out backdrop-<scene>.heic`);
  - the licence rule (public domain, CC0 or CC BY only, credited in `CREDITS.md`);
  - that no photos ship until the owner picks them.
- Tests:
  - `KenBurns.scale` stays within [1.0, 1.08] across 0...120 s in 0.5 s steps, and has the same value at t and t+60;
  - `offset` stays within 2% of size;
  - `resourceName` for every scene;
  - the loader returns nil for a bundle without the resource;
  - with a generated 64×64 PNG written to a temp directory and loaded through `Bundle(url:)` (a temp `.bundle` directory containing `Backgrounds/backdrop-status.png`), the loader returns images of the original size, and a second call returns the cached instance (`===` on a class wrapper, or equal `CGImage` references);
  - `blur` output keeps the input's width and height.

### Task 7: App shell — preferences, AppModel, sidebar, RootView, placeholders

**Files:**
- Create: `RoomForMac/App/AppPreferences.swift`, `RoomForMac/App/AppModel.swift`, `RoomForMac/App/SidebarSection.swift`, `RoomForMac/App/RootView.swift`, `RoomForMac/App/AppDependencies.swift`, `RoomForMac/Features/SmartClean/SmartCleanPlaceholderView.swift`, `RoomForMac/Features/Uninstaller/UninstallerPlaceholderView.swift`, `RoomForMac/Features/Status/StatusPlaceholderView.swift`, `RoomForMacTests/AppPreferencesTests.swift`, `RoomForMacTests/AppModelTests.swift`
- Modify: `RoomForMac/App/RoomForMacApp.swift`, `RoomForMac/App/AccessibilityID.swift`

**Interfaces:**
- Consumes:
  - `EngineHealthCheck`, `EngineProblem`, `EngineProblemView` (Task 3);
  - `BackdropView`, `BackdropScene` (Task 6);
  - `GlassCard`, `GlassButton` (Task 5);
  - `RuntimeMode`, `UITestScenario` (Task 1).
- Produces:
  ```swift
  struct AppPreferences {
      init(defaults: UserDefaults)
      var onboardingCompleted: Bool            // key "onboarding.completed", default false
      var onboardingStep: String?              // key "onboarding.step" (raw OnboardingStep; Task 11 wraps it)
      var analyticsEnabled: Bool               // key "analytics.enabled", default true
      var notificationsWanted: Bool            // key "notifications.wanted", default false
      func lastKnownState(for permission: String) -> String?        // key "permissions.lastKnown.<permission>"
      func setLastKnownState(_ state: String?, for permission: String)
  }
  enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
      case smartClean, uninstaller, status
      var id: String { get }
      var title: LocalizedStringResource { get }   // "Smart Clean", "Uninstaller", "Status"
      var systemImage: String { get }              // "sparkles", "trash", "gauge.with.dots.needle.67percent"
      var backdrop: BackdropScene { get }
  }
  enum EnginePhase: Equatable, Sendable { case checking, ready(EngineInstallation), broken(EngineProblem) }
  @MainActor
  struct AppDependencies {
      var preferences: AppPreferences
      var engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
      var openURL: @MainActor (URL) -> Void
      static func live(defaults: UserDefaults = .standard) -> AppDependencies
      static func forScenario(_ scenario: UITestScenario) -> AppDependencies   // DEBUG only; Task 15 fills permission fakes
  }
  @MainActor @Observable
  final class AppModel {
      init(dependencies: AppDependencies)
      let dependencies: AppDependencies
      private(set) var engine: EnginePhase          // starts .checking
      var selection: SidebarSection                 // default .smartClean
      private(set) var isOnboarded: Bool            // from preferences
      var pendingFirstScan: Bool                    // Plan 3's Smart Clean consumes and clears it
      func start() async                            // runs engineCheck once; later calls are no-ops
      func completeOnboarding(startFirstScan: Bool) // persists, sets selection = .smartClean, sets pendingFirstScan
  }
  struct RootView: View { init(model: AppModel) }
  enum AccessibilityID {
      static let sidebar = "sidebar"
      static func sidebarRow(_ section: SidebarSection) -> String    // "sidebar.<rawValue>"
      static func placeholder(_ section: SidebarSection) -> String   // "placeholder.<rawValue>"
      static let engineProblemCard = "engineProblem.card"
      static let engineProblemDetails = "engineProblem.details"
      static let engineProblemCopy = "engineProblem.copy"
      static let checkingEngine = "engine.checking"
      // Tasks 12–14 append onboarding.* and settings.* identifiers
  }
  ```

**Requirements:**
- `RootView` precedence:
  - `.checking` → a centred `ProgressView` with the label "Checking RoomForMac…" (identifier `checkingEngine`).
  - `.broken` → `EngineProblemView`.
  - Not onboarded → `OnboardingView` (Task 12). Until Task 12 lands, a placeholder `Text` with identifier `onboarding.placeholder`; Task 12 replaces it.
  - Otherwise, a `NavigationSplitView` with:
    - a sidebar `List(SidebarSection.allCases, selection:)` using `Label(title, systemImage:)`, with `navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)`;
    - a detail showing the placeholder view for the selection;
    - `BackdropView(scene: selection.backdrop)` behind everything (`.background { … .ignoresSafeArea() }`);
    - `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`.
- Placeholders: a `ContentUnavailableView` inside a `GlassCard`, carrying the section title, its symbol, and "Coming in the next update." with identifier `placeholder(section)`.
- `RoomForMacApp`:
  - Builds `AppModel` from `AppDependencies.live()`, or `.forScenario(s)` in `.uiTest(s)`.
  - Main window: `Window("RoomForMac", id: "main") { RootView(model:).task { await model.start() } }` with `.windowStyle(.hiddenTitleBar)`, `.windowToolbarStyle(.unified)`, `.defaultSize(width: 1100, height: 720)` and `.windowBackgroundDragBehavior(.enabled)`.
  - The `Settings` scene shows a placeholder until Task 14.
  - `.unitTestHost` is unchanged from Task 1.
- `AppDependencies.live` wires `engineCheck` to `EngineHealthCheck().run()`, and `openURL` to `NSWorkspace.shared.open`.
- Tests:
  - `AppPreferences` defaults and round-trips on a `UserDefaults(suiteName: UUID().uuidString)!` that is removed afterwards.
  - `AppModel.start` → `.ready` for success and `.broken` for failure.
  - `start` twice runs the check once, counted through a closure.
  - `completeOnboarding(startFirstScan: true)` persists, sets `isOnboarded`, `selection` and `pendingFirstScan`.
  - `SidebarSection` titles, symbols and backdrops.

### Task 8: Permission core — IDs, states, checking protocol, center, blocking calls, Settings links

**Files:**
- Create: `RoomForMac/Features/Permissions/PermissionID.swift`, `PermissionState.swift`, `PermissionChecking.swift`, `PermissionCenter.swift`, `BlockingCall.swift`, `SystemSettingsLink.swift`, `RoomForMacTests/PermissionCenterTests.swift`, `RoomForMacTests/BlockingCallTests.swift`

**Interfaces:**
- Consumes: `AppPreferences` (Task 7) for last-known states.
- Produces:
  ```swift
  enum PermissionID: String, Sendable, CaseIterable, Codable {
      case moveToApplications, fullDiskAccess, automationFinder, automationSystemEvents, notifications, launchAtLogin
      var title: LocalizedStringResource { get }   // "Applications folder", "Full Disk Access", "Finder", "System Events", "Notifications", "Open at login"
  }
  enum PermissionState: Sendable, Equatable {
      case granted, denied, notDetermined, requiresApproval, unknown(String), notApplicable
      var isGranted: Bool { get }                 // granted or notApplicable
      var storageValue: String { get }            // "granted" | "denied" | "notDetermined" | "requiresApproval" | "unknown:<reason>" | "notApplicable"
      init?(storageValue: String)
  }
  protocol PermissionChecking: Sendable {
      var id: PermissionID { get }
      func currentState() async -> PermissionState   // never shows UI
      func request() async -> PermissionState        // may prompt, open System Settings, or move the app
  }
  @MainActor @Observable
  final class PermissionCenter {
      init(checkers: [any PermissionChecking], preferences: AppPreferences? = nil,
           sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
      private(set) var states: [PermissionID: PermissionState]
      func state(_ id: PermissionID) -> PermissionState        // .notDetermined when unknown id / not yet checked
      func hasChecker(_ id: PermissionID) -> Bool
      func refresh(_ id: PermissionID) async
      func refreshAll() async
      func request(_ id: PermissionID) async
      func poll(_ id: PermissionID, every interval: Duration = .seconds(1)) async   // loops until granted or the Task is cancelled
  }
  enum BlockingCall {
      static func run<T: Sendable>(deadline: Duration, queue: DispatchQueue = .global(qos: .userInitiated),
                                   _ work: @escaping @Sendable () -> T) async -> T?   // nil when the deadline passes first
      static let passiveDeadline: Duration   // .seconds(3)
      static let promptDeadline: Duration    // .seconds(120)
  }
  enum SystemSettingsLink: Sendable, CaseIterable {
      case fullDiskAccess, automation, appManagement, loginItems, notifications
      var url: URL { get }
  }
  ```

**Requirements:**
- `SystemSettingsLink.url` values:
  - `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`
  - `…?Privacy_Automation`
  - `…?Privacy_AppBundles`
  - `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
  - `x-apple.systempreferences:com.apple.Notifications-Settings.extension`
- `PermissionCenter` stores every state it learns through `preferences?.setLastKnownState`. For `automationFinder` and `automationSystemEvents`, when the fresh state is `.unknown`, `state(_:)` returns the stored last known state if there is one.
- `poll` stops as soon as the state `isGranted`, and never throws. On cancellation it returns.
- `BlockingCall.run` resumes a checked continuation exactly once. Use a lock-guarded `Bool` shared by the work item and a deadline timer on the same queue (`asyncAfter`). The work runs on `queue`, never on the cooperative pool.
- Tests (with a `FakeChecker` actor-backed struct that returns scripted states in order):
  - `refresh` stores states;
  - `request` updates state;
  - `poll` makes exactly 3 checks for the script `[.denied, .denied, .granted]`, using an injected `sleep` that records durations of 1 s;
  - `poll` returns on cancellation;
  - last-known fallback for Automation `.unknown`;
  - storage round-trip for every state;
  - `BlockingCall` returns the value for fast work, and nil for work that sleeps 1 s against a 100 ms deadline (in under 0.5 s);
  - every `SystemSettingsLink.url` equals its exact string.

### Task 9: Live permission checkers — Full Disk Access, Automation, Notifications, Login item

**Files:**
- Create: `RoomForMac/Features/Permissions/FullDiskAccessChecker.swift`, `AutomationChecker.swift`, `AppleEventPermission.swift`, `NotificationChecker.swift`, `LoginItemChecker.swift`, `RoomForMacTests/FullDiskAccessCheckerTests.swift`, `RoomForMacTests/AutomationCheckerTests.swift`, `RoomForMacTests/NotificationAndLoginCheckerTests.swift`

**Interfaces:**
- Consumes: `PermissionID`, `PermissionState`, `PermissionChecking`, `BlockingCall`, `SystemSettingsLink` (Task 8).
- Produces:
  ```swift
  struct FullDiskAccessProbe: Sendable {
      enum Result: Sendable, Equatable { case granted, denied, indeterminate }
      var candidates: [String]
      init(home: String = NSHomeDirectory())       // the four research paths, system TCC.db first
      init(candidates: [String])
      func check() -> Result                       // open(O_RDONLY|O_NONBLOCK|O_CLOEXEC); never reads
  }
  struct FullDiskAccessChecker: PermissionChecking {
      init(probe: FullDiskAccessProbe = .init(), openSettings: @escaping @MainActor @Sendable (URL) -> Void)
      // currentState: granted→.granted, denied→.denied, indeterminate→.unknown("no probe file")
      // request: opens SystemSettingsLink.fullDiskAccess, returns currentState()
  }
  enum AppleEventPermission {
      static func determine(bundleIdentifier: String, askUserIfNeeded: Bool) -> Int32   // AEDeterminePermissionToAutomateTarget(typeWildCard, typeWildCard)
      static func state(forStatus status: Int32) -> PermissionState
      // 0 → .granted, -1743 → .denied, -1744 → .notDetermined, -600 → .unknown("not running"), other → .unknown("OSStatus \(status)")
  }
  struct AutomationChecker: PermissionChecking {
      enum Target: String, Sendable, CaseIterable { case finder, systemEvents
          var bundleIdentifier: String { get }   // "com.apple.finder", "com.apple.systemevents"
          var applicationURL: URL { get }        // /System/Library/CoreServices/Finder.app, …/System Events.app
          var permissionID: PermissionID { get } }
      init(target: Target,
           determine: @escaping @Sendable (String, Bool) -> Int32 = AppleEventPermission.determine,
           isRunning: @escaping @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
           launchHidden: @escaping @Sendable (URL) async -> Bool,
           openSettings: @escaping @MainActor @Sendable (URL) -> Void)
      static func live(_ target: Target, openSettings: @escaping @MainActor @Sendable (URL) -> Void) -> AutomationChecker
      // currentState: passive determine (ask false) via BlockingCall.passiveDeadline; nil → .unknown("timed out")
      // request: if !isRunning → launchHidden(applicationURL) then wait ≤ 2 s (poll isRunning every 100 ms);
      //          determine(ask: true) via BlockingCall.promptDeadline; if result is .denied → openSettings(.automation)
  }
  struct NotificationChecker: PermissionChecking {
      init(authorizationStatus: @escaping @Sendable () async -> UNAuthorizationStatus,
           requestAuthorization: @escaping @Sendable () async throws -> Bool)
      static func live() -> NotificationChecker     // UNUserNotificationCenter.current(); never called in unit tests
      static func state(for status: UNAuthorizationStatus) -> PermissionState
      // .authorized/.provisional/.ephemeral → .granted, .denied → .denied, .notDetermined → .notDetermined, @unknown → .unknown
  }
  struct LoginItemChecker: PermissionChecking {
      init(status: @escaping @Sendable () -> SMAppService.Status,
           register: @escaping @Sendable () throws -> Void,
           unregister: @escaping @Sendable () throws -> Void,
           openLoginItemsSettings: @escaping @Sendable () -> Void)
      static func live() -> LoginItemChecker         // SMAppService.mainApp
      static func state(for status: SMAppService.Status) -> PermissionState
      // .enabled → .granted, .notRegistered → .notDetermined, .requiresApproval → .requiresApproval, .notFound → .unknown("unavailable in this build")
      func disable() async -> PermissionState
      // request: register (error code 12 kSMErrorAlreadyRegistered counts as success); then if .requiresApproval → openLoginItemsSettings
  }
  ```

**Requirements:**
- `AutomationChecker.live` supplies `launchHidden` through `NSWorkspace.shared.openApplication(at:configuration:)`, with `activates = false`, `hides = true` and `addsToRecentItems = false`. It returns whether the launch succeeded.
- Tests (no real AE, notification or SMAppService calls):
  - FDA probe: with temp files, a readable file → `.granted`; a file with mode 000 (EACCES when not root) → `.denied`; a missing path → `.indeterminate`; the order matters (the first readable file wins); the default candidates list starts with the system TCC.db.
  - `FullDiskAccessChecker.request` calls `openSettings` with `SystemSettingsLink.fullDiskAccess.url`.
  - Every `AppleEventPermission.state(forStatus:)` mapping.
  - `AutomationChecker`: passive check passes `ask == false`; request passes `ask == true`; not running → `launchHidden` called once with the target's URL; a denied request → `openSettings(.automation)`; a `determine` that blocks for 5 s against an injected short deadline gives `.unknown("timed out")`. The checker takes `passiveDeadline` and `promptDeadline` initializer parameters, defaulting to the `BlockingCall` constants, so tests can shorten them.
  - Notification mapping for every status, and `request` returning granted and denied.
  - Login item: mapping for every status; `request` calls `register` then, on `.requiresApproval`, `openLoginItemsSettings`; `register` throwing error code 12 is treated as success; `disable` calls `unregister`.

### Task 10: App location, Move to Applications and relaunch

**Files:**
- Create: `RoomForMac/Features/Permissions/AppLocation.swift`, `AppLocationChecker.swift`, `AppMover.swift`, `Relauncher.swift`, `RoomForMacTests/AppLocationTests.swift`, `RoomForMacTests/AppMoverTests.swift`

**Interfaces:**
- Consumes: `PermissionChecking`, `PermissionID.moveToApplications`, `PermissionState` (Task 8).
- Produces:
  ```swift
  enum AppLocation: Sendable, Equatable {
      case installed                    // under /Applications/ or ~/Applications/
      case outsideApplications          // anywhere else (Downloads, DerivedData, a DMG volume)
      case translocated(original: URL?) // Gatekeeper App Translocation
      static func classify(bundleURL: URL, home: String, isTranslocated: Bool, originalURL: URL?) -> AppLocation
      static func current(bundle: Bundle = .main) -> AppLocation   // uses Translocation.isTranslocated / originalURL
  }
  enum Translocation {
      static func isTranslocated(_ url: URL) -> Bool            // dlsym SecTranslocateIsTranslocatedURL; fallback: path contains "/AppTranslocation/"
      static func originalURL(for url: URL) -> URL?             // dlsym SecTranslocateCreateOriginalPathForURL
  }
  enum AppMoveError: Error, Sendable, Equatable {
      case destinationIsRunning(URL)
      case notWritable(URL)
      case failed(String)
  }
  struct AppMover: Sendable {
      init(fileManager: @escaping @Sendable () -> FileManager = { .default },
           isRunning: @escaping @Sendable (URL) -> Bool,                       // an app at this exact bundle URL is running
           trashItem: @escaping @Sendable (URL) throws -> Void)
      static func live() -> AppMover
      static func candidateDirectories(home: String) -> [URL]                    // [/Applications, ~/Applications]
      func move(appAt source: URL, toFirstWritableOf directories: [URL]) throws -> URL   // returns the new bundle URL
      static func stripQuarantine(at url: URL) throws                            // removexattr com.apple.quarantine recursively
  }
  struct Relauncher: Sendable {
      static func command(waitingFor pid: Int32, thenOpen appURL: URL) -> (executable: String, arguments: [String])
      // ("/bin/sh", ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"", "sh", "\(pid)", appURL.path])
      init(spawn: @escaping @Sendable (String, [String]) throws -> Void, terminate: @escaping @MainActor @Sendable () -> Void)
      static func live() -> Relauncher
      @MainActor func relaunch(at appURL: URL) throws
  }
  struct AppLocationChecker: PermissionChecking {
      init(location: @escaping @Sendable () -> AppLocation, bypass: Bool,
           mover: AppMover, relauncher: Relauncher, home: String = NSHomeDirectory(),
           bundleURL: @escaping @Sendable () -> URL = { Bundle.main.bundleURL })
      // id = .moveToApplications
      // currentState: bypass → .notApplicable; .installed → .granted; otherwise .notDetermined
      // request: move to the first writable candidate; on success relaunch (does not return in production); errors map to .denied with the reason kept via lastError
      var lastError: AppMoveError? { get }   // backed by a class box, since the struct is Sendable
  }
  ```

**Requirements:**
- `move`:
  1. For each directory: the destination is `directory/<source name>`. If it exists and `isRunning(destination)` → `destinationIsRunning`. If it exists and is not running → `trashItem(destination)`.
  2. If the source's volume is read-only (`URLResourceValues.volumeIsReadOnly`), copy; otherwise move.
  3. `stripQuarantine(new)` and return.
  4. A directory that is not writable (`isWritableFile(atPath:)` false, or creation fails) is skipped. If every directory fails → `notWritable(last directory)`.
  5. `~/Applications` is created if missing.
- DEBUG bypass: `AppDependencies.live` passes `bypass: true` unless the launch arguments contain `-RFMForceMoveStep YES`. In release, `bypass` is false.
- Tests:
  - `classify` for:
    - `/Applications/RoomForMac.app` → installed;
    - `~/Applications/RoomForMac.app` → installed;
    - `~/Downloads/RoomForMac.app` → outside;
    - `/Volumes/RoomForMac/RoomForMac.app` → outside;
    - translocated → `.translocated(original:)`;
    - `/Applications/Utilities/RoomForMac.app` → installed;
    - `/ApplicationsBackup/RoomForMac.app` → outside (a prefix match must respect path components).
  - `Translocation.isTranslocated` is false for a temp path.
  - `AppMover` in temp directories, with fake `isRunning` and a fake `trashItem` that moves the item into a temp "Trash" folder:
    - a plain move;
    - an existing destination that is not running is trashed, then replaced;
    - an existing running destination → `destinationIsRunning`;
    - the first directory unwritable (chmod 555) → falls through to the second;
    - all unwritable → `notWritable`;
    - the quarantine xattr, set with `setxattr` on the source bundle and a nested file, is gone after the move.
  - `Relauncher.command` is exactly the tuple above, and `relaunch` calls `spawn` then `terminate`.
  - `AppLocationChecker` states for bypass, installed and outside. `request` success calls `relaunch`; failure keeps `lastError` and returns `.denied`.

### Task 11: Onboarding flow model — steps, choices, persistence, summary

**Files:**
- Create: `RoomForMac/Features/Onboarding/OnboardingStep.swift`, `OnboardingChoices.swift`, `OnboardingFlow.swift`, `RoomForMacTests/OnboardingFlowTests.swift`

**Interfaces:**
- Consumes: `AppPreferences` (Task 7), `PermissionCenter`, `PermissionID`, `PermissionState` (Task 8).
- Produces:
  ```swift
  enum OnboardingStep: String, CaseIterable, Codable, Sendable {
      case welcome, freeToExplore, moveToApplications, fullDiskAccess, automation, adminAccess, extras, ready
      var isSkippable: Bool { get }        // every step except .welcome and .ready
  }
  struct OnboardingChoices: Equatable, Sendable {
      var notifications = false; var launchAtLogin = false; var analytics = true
  }
  struct PermissionSummaryItem: Identifiable, Equatable, Sendable {
      let id: PermissionID; let title: LocalizedStringResource; let granted: Bool
  }
  @MainActor @Observable
  final class OnboardingFlow {
      init(preferences: AppPreferences, permissions: PermissionCenter, needsMoveStep: Bool)
      private(set) var step: OnboardingStep           // restored from preferences.onboardingStep when valid for `steps`, else .welcome
      let steps: [OnboardingStep]                     // all cases, minus .moveToApplications when !needsMoveStep
      var choices: OnboardingChoices                  // analytics defaults from preferences.analyticsEnabled
      var index: Int { get }                          // position of step in steps
      var canGoBack: Bool { get }                     // index > 0
      func next()                                     // advances; persists step; no-op on .ready
      func back()                                     // no-op at index 0; persists
      func skip()                                     // same as next() for skippable steps; no-op otherwise
      func summary() -> [PermissionSummaryItem]       // fullDiskAccess, automationFinder, automationSystemEvents, notifications, launchAtLogin (+ moveToApplications when needed)
      func finish(apply: (OnboardingChoices) async -> Void) async   // applies choices, sets onboardingCompleted, clears onboardingStep, writes analyticsEnabled
  }
  ```

**Requirements:**
- Every change of `step` writes `preferences.onboardingStep = step.rawValue`. A new `OnboardingFlow` built on the same preferences resumes at that step. This covers the relaunch after Move and after FDA (Review Focus 3). A stored `moveToApplications` with `needsMoveStep == false` resumes at the next step in `steps`.
- `summary().granted` uses `PermissionCenter.state(_:).isGranted`. For `notifications` and `launchAtLogin`, an item is included only when the matching choice is on.
- Tests:
  - order with and without the move step;
  - `next`/`back` bounds;
  - `skip` on welcome is a no-op;
  - resume at a persisted step;
  - resume from a stale `moveToApplications`;
  - resume from garbage in preferences → `.welcome`;
  - `finish` persists completion and the analytics choice, clears the step, and calls `apply` exactly once with the choices;
  - `summary` reflects the scripted permission states and choices.

### Task 12: Onboarding UI, part 1 — scaffold, Welcome, Free to explore, Move, Full Disk Access, PermissionCard

**Files:**
- Create: `RoomForMac/Features/Onboarding/OnboardingView.swift`, `OnboardingScaffold.swift`, `Steps/WelcomeStep.swift`, `Steps/FreeToExploreStep.swift`, `Steps/MoveToApplicationsStep.swift`, `Steps/FullDiskAccessStep.swift`, `RoomForMac/Features/Permissions/PermissionCard.swift`, `RoomForMacTests/OnboardingViewTests.swift`
- Modify: `RoomForMac/App/RootView.swift` (show `OnboardingView`), `RoomForMac/App/AppDependencies.swift` (live permission checkers, `needsMoveStep`, `loginItem`), `RoomForMac/App/AppModel.swift` (`permissions`, `onboardingFlow`), `RoomForMac/App/AccessibilityID.swift`

**Interfaces:**
- Consumes:
  - `OnboardingFlow`, `OnboardingStep` (Task 11);
  - `PermissionCenter` (Task 8);
  - the live checkers (Tasks 9–10);
  - `GlassButton`, `GlassCard`, `GlassDots`, `morphingGlass`, `AnimatedWordmark` (Task 5);
  - `BackdropView` (Task 6);
  - `AppModel` (Task 7).
- Produces:
  ```swift
  struct OnboardingView: View { init(model: AppModel, flow: OnboardingFlow) }   // permissions come from model.permissions
  struct OnboardingScaffold<Content: View>: View {
      init(flow: OnboardingFlow, primaryTitle: LocalizedStringKey, primaryAction: @escaping @MainActor () -> Void,
           @ViewBuilder content: () -> Content)   // GlassDots, Back, Skip (when skippable), primary button
  }
  struct PermissionCard: View {
      init(id: PermissionID, state: PermissionState, title: LocalizedStringKey, reason: LocalizedStringKey,
           actionTitle: LocalizedStringKey, action: @escaping @MainActor () -> Void)
  }
  struct PermissionChip: View { init(state: PermissionState) }   // "Allowed" / "Not yet" / "Denied" / "Needs approval" / "Unknown" / "Not needed"
  // AppDependencies (Task 7) gains these stored properties, and every initializer sets them:
  //   var permissionCheckers: [any PermissionChecking]  // live(): FDA, Automation×2, Notifications, LoginItem, AppLocation
  //   var needsMoveStep: Bool                            // live(): AppLocation.current() != .installed && !bypass
  //   var loginItem: LoginItemChecker?                   // live(): the same LoginItemChecker that is in permissionCheckers
  // AppModel (Task 7) gains:
  //   let permissions: PermissionCenter                  // built in init from dependencies.permissionCheckers + preferences
  //   private(set) var onboardingFlow: OnboardingFlow?   // created in init when !isOnboarded; nil after completeOnboarding
  extension AccessibilityID {
      static let onboardingPrimary = "onboarding.primary"; static let onboardingBack = "onboarding.back"; static let onboardingSkip = "onboarding.skip"
      static func onboardingStep(_ step: OnboardingStep) -> String      // "onboarding.step.<rawValue>"
      static func permissionCard(_ id: PermissionID) -> String          // "permission.card.<rawValue>"
      static func permissionAction(_ id: PermissionID) -> String        // "permission.action.<rawValue>"
      static func permissionChip(_ id: PermissionID) -> String          // "permission.chip.<rawValue>"
  }
  ```

**Requirements:**
- `OnboardingView` shows the current step inside `OnboardingScaffold` over `BackdropView(scene: .onboarding, focus:)`. Focus is 0 while Welcome animates in and 1 afterwards; under Reduce Motion it is 1 immediately. The view switches steps with a `.transition(.opacity)`, or a slide under normal motion.
- **Welcome** (spec §6 screen 1):
  - The backdrop resolves from blur into focus over 1.6 s, then softens (focus → 0.3).
  - `AnimatedWordmark` draws over 2.0 s.
  - The CTA is "Get started".
  - Under Reduce Motion, everything is shown in its final state.
- **Free to explore:**
  - Copy "Unlimited scans and previews".
  - A 1 GB meter (a capsule bar in `moss`, with a `grass` fill animating 0 → 1 over 1.2 s) labelled "1 GB of free cleanup, once".
  - The line "Upgrade once for unlimited cleanup — every future version included."
  - The line "No account, no card."
- **Move to Applications** (only when `flow.steps` contains it):
  - The app icon (`NSApp.applicationIconImage`) glides 120 pt toward an `Image(systemName: "folder")` labelled Applications.
  - The primary button "Move and relaunch" calls `permissions.request(.moveToApplications)`.
  - On `.denied`, it shows the `AppLocationChecker.lastError` message and "Drag RoomForMac into your Applications folder, then open it from there." with a **Reveal in Finder** button.
- **Full Disk Access:**
  - A `PermissionCard` for `.fullDiskAccess` with the reason "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete."
  - The action is "Open Settings", which calls `request`.
  - A looping mini-animation of a toggle turning on (a SwiftUI `Toggle` driven by a timer; static under Reduce Motion).
  - `.task { await permissions.poll(.fullDiskAccess) }`, and a refresh on `NSApplication.didBecomeActiveNotification`.
  - Once granted, the card morphs to a checkmark and the primary button reads "Continue".
  - After returning from Settings with the state still not granted, a "Turned it on? Relaunch RoomForMac" link calls `Relauncher.live().relaunch(at: Bundle.main.bundleURL)`.
  - A "Why?" `DisclosureGroup` explains, in plain words, what breaks without it: incomplete scans, Trash size shown as zero, separate prompts for Downloads and other apps' data, and apps that cannot be moved to the Trash.
- `PermissionCard`: a `GlassCard` with title, reason, a `PermissionChip`, and a `GlassButton` for the action, hidden when granted. The chip colours come from tokens: granted `moss`, denied `clay`, others `textSecondary`.
- Tests: `PermissionChip` label text for every state (expose `static func label(for:) -> LocalizedStringResource`), and each step view renders through `ImageRenderer` with a flow built on scripted fakes.

### Task 13: Onboarding UI, part 2 — Automation, Admin access, Extras, Ready

**Files:**
- Create: `RoomForMac/Features/Onboarding/Steps/AutomationStep.swift`, `Steps/AdminAccessStep.swift`, `Steps/ExtrasStep.swift`, `Steps/ReadyStep.swift`, `RoomForMacTests/OnboardingFinishTests.swift`
- Modify: `RoomForMac/Features/Onboarding/OnboardingView.swift`, `RoomForMac/App/AccessibilityID.swift`

**Interfaces:**
- Consumes: Task 12's scaffold, `PermissionCard`, `PermissionChip` and `OnboardingView`; `OnboardingFlow.finish`, `summary` and `choices` (Task 11); `AppModel.completeOnboarding` (Task 7).
- Produces:
  ```swift
  enum OnboardingApply {
      /// Applies Extras choices: requests notifications if chosen; registers or unregisters the login item.
      static func apply(_ choices: OnboardingChoices, permissions: PermissionCenter, loginItem: LoginItemChecker?) async
      // notifications on → permissions.request(.notifications); launchAtLogin on → permissions.request(.launchAtLogin);
      // launchAtLogin off → loginItem?.disable() when the current state is .granted
  }
  extension AccessibilityID {
      static let extrasNotifications = "onboarding.extras.notifications"; static let extrasLaunchAtLogin = "onboarding.extras.launchAtLogin"
      static let extrasAnalytics = "onboarding.extras.analytics"; static let readyStartScan = "onboarding.ready.startScan"
      static func summaryChip(_ id: PermissionID) -> String     // "onboarding.summary.<rawValue>"
  }
  ```

**Requirements:**
- **Finder & System Events:** two `PermissionCard`s, with reasons from Ruling 10:
  - Finder: "Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails."
  - System Events: "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall."

  Each "Allow" triggers `request` at that moment. Chips: Allowed / Not yet / Denied → with "Open Settings".
- **Admin access:**
  - An illustration built from SF Symbols (`lock.shield` in a glass circle), no password field anywhere.
  - Copy: "RoomForMac only asks for your password when you pick system-level items, and macOS draws that prompt, never us. Nothing is requested now."
  - Plus: "System-level items arrive in a later update." (admin is Plan 7).
- **Extras:**
  - Toggles: "Notify me when a cleanup finishes" (notifications), "Open RoomForMac at login" (launchAtLogin), "Share anonymous usage data" (analytics, on by default).
  - The analytics toggle has a one-line description, "Counts and sizes in ranges. Never file names, paths or app names.", and a "What we collect" disclosure listing the §8 events in plain words.
- **Ready:**
  - Summary chips from `flow.summary()` (granted ✓ / skipped •).
  - A **Start first scan** button built with `morphingGlass` in the `action` tint. It calls `await flow.finish { await OnboardingApply.apply($0, …) }` then `model.completeOnboarding(startFirstScan: true)`.
  - A secondary "Not now" calls the same with `startFirstScan: false`.
- Tests:
  - `OnboardingApply` with fakes: notifications requested only when chosen; the login item registered when chosen and unregistered otherwise.
  - The finish path: completion persisted and `AppModel.isOnboarded` true.

### Task 14: Settings — General, Permissions, About; legal documents and credits

**Files:**
- Create: `RoomForMac/Features/Settings/SettingsView.swift`, `GeneralSettingsView.swift`, `PermissionsSettingsView.swift`, `AboutView.swift`, `LegalDocument.swift`, `CREDITS.md`, `RoomForMacTests/SettingsTests.swift`
- Modify: `RoomForMac/App/RoomForMacApp.swift` (Settings scene), `project.yml` (bundle `LICENSE`, `NOTICE` and `CREDITS.md` as resources), `RoomForMac/App/AccessibilityID.swift`

**Interfaces:**
- Consumes: `PermissionCenter`, `PermissionCard` (Tasks 8, 12); `LoginItemChecker`, `NotificationChecker` (Task 9); `AppModel` and its `EnginePhase` (Task 7); `AppPreferences` (Task 7).
- Produces:
  ```swift
  enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
      case license, notice, credits, moleLicense
      var id: String { get }
      var title: LocalizedStringResource { get }     // "RoomForMac License", "Notice", "Credits", "Engine License (Mole)"
      func url(in bundle: Bundle) -> URL?             // LICENSE, NOTICE, CREDITS.md in Resources; engine/LICENSE for moleLicense
      func text(in bundle: Bundle) -> String?
  }
  struct AboutInfo: Equatable, Sendable {
      let appVersion: String; let build: String; let engine: EngineFingerprint?
      init(bundle: Bundle, engine: EngineFingerprint?)
      var engineLine: String { get }   // "Engine V1.56.0 (239c90d, 5 patches)" or "Engine unavailable"
  }
  struct SettingsView: View { init(model: AppModel) }   // TabView: General, Permissions, About; uses model.permissions and model.dependencies.loginItem
  ```

**Requirements:**
- **General:**
  - "Open RoomForMac at login", bound to `LoginItemChecker` (register or unregister, with `.requiresApproval` showing "Approve in System Settings").
  - "Notifications", showing the state with a button to request or open Settings.
  - A note that the menu-bar extra arrives with Status (Plan 3).
- **Permissions:**
  - The same `PermissionCard`s as onboarding for FDA, Finder, System Events and Notifications, plus Move to Applications when the location is not installed.
  - `refreshAll()` on appear and on `didBecomeActive`.
- **About:**
  - App name, `AboutInfo` version and build, and `engineLine`.
  - "RoomForMac is built on the open-source Mole engine by tw93 (GPL-3.0)."
  - A link to `https://github.com/tw93/mole`.
  - A list of the `LegalDocument`s, each opening a sheet with the monospaced text.
  - The photo credits come from `CREDITS.md`.
- `CREDITS.md` has these sections:
  - Engine: "Mole by tw93, GPL-3.0, https://github.com/tw93/mole".
  - Photography: "None bundled yet. Every photo will be public domain, CC0 or CC BY, credited here with title, author, source, licence and whether it was modified."
  - Fonts: "SF Pro and SF Pro Rounded, system fonts, not redistributed."
- `project.yml`: add `- path: LICENSE`, `- path: NOTICE` and `- path: CREDITS.md`, each with `buildPhase: resources`, to the app target's sources.
- Tests:
  - `LegalDocument.url(in: .main)` exists for all four in the hosted app, and each `text` is non-empty.
  - `AboutInfo.engineLine` for a known fingerprint and for nil.
  - Settings tabs render through `ImageRenderer`.

### Task 15: DEBUG scenarios and UI smoke tests

**Files:**
- Create: `RoomForMac/Features/Permissions/ScriptedPermissionChecker.swift`, `RoomForMacUITests/OnboardingSmokeTests.swift`, `RoomForMacUITests/EngineProblemSmokeTests.swift`, `RoomForMacTests/ScenarioTests.swift`
- Modify: `RoomForMac/App/AppDependencies.swift` (`forScenario`), `RoomForMacUITests/LaunchSmokeTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–14.
- Produces:
  ```swift
  #if DEBUG
  struct ScriptedPermissionChecker: PermissionChecking {
      init(id: PermissionID, initial: PermissionState, afterRequest: PermissionState)
  }
  #endif
  // AppDependencies.forScenario(_:) — DEBUG only:
  //   .onboarding:   in-memory UserDefaults suite "RoomForMac.UITest" wiped at launch; engineCheck → .success(bundled);
  //                  checkers scripted: FDA .denied→.granted, Finder/System Events .notDetermined→.granted,
  //                  notifications .notDetermined→.granted, login item .notDetermined→.granted; needsMoveStep false
  //   .onboarded:    same, but onboardingCompleted = true
  //   .engineBroken: engineCheck → .failure(.versionMismatch(expected: .expected, found: <tag "V0.0.0">))
  ```

**Requirements:**
- The scenario `UserDefaults` suite is removed at launch (`removePersistentDomain(forName:)`) so every UI test starts clean. The scenario never touches `UserDefaults.standard`.
- `OnboardingSmokeTests`:
  - Launch with `["-RFMUITestScenario", "onboarding"]`.
  - For each step, assert `onboarding.step.<raw>` exists, press the permission actions where present (chips turn "Allowed"), then press `onboarding.primary`.
  - On Ready, assert the summary chips, press `readyStartScan`, and assert `sidebar` and `placeholder.smartClean` exist.
- `EngineProblemSmokeTests`: `engine-broken` → `engineProblem.card` exists and `engineProblem.copy` is hittable.
- `LaunchSmokeTests`: the `onboarded` scenario → `sidebar` exists; clicking each `sidebar.<raw>` row shows its placeholder.
- UI tests need Automation Mode. `setUpWithError` does not detect it; if it is off, the run fails with "Timed out while enabling automation mode", which the implementer reports as an environment limit, not a code failure. Unit `ScenarioTests` covers `forScenario` without launching: dependencies for each scenario have the scripted states and the right `engineCheck` result.
- Verify:
  - `xcodebuild … -scheme RoomForMacUnit test` is green.
  - `xcodebuild … -scheme RoomForMac test -only-testing:RoomForMacUITests` is attempted; report its result.

### Task 16: Stable signing identity script and docs

**Files:**
- Create: `scripts/make-signing-identity.sh`, `scripts/tests/signing_identity.bats`, `docs/signing.md`
- Modify: `README.md` (link to `docs/signing.md`)

**Interfaces:**
- Consumes: `Config/Signing.xcconfig` (Task 1); `app_bundle.bats` (Task 2), which checks helper authority.
- Produces:
  - `scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]`
  - Defaults: `NAME="RoomForMac Self-Signed"`, `DIR=~/.roomformac/signing`, the login keychain.
  - Exit codes: 0 ok; 1 no identity (`--check`); 2 ambiguous or bad usage.

**Requirements:**
- Use the S5 research draft:
  - `/usr/bin/openssl` pinned;
  - a CN-only subject;
  - `basicConstraints = critical, CA:false`;
  - `keyUsage = critical, digitalSignature`;
  - `extendedKeyUsage = critical, codeSigning`;
  - `-days 7300`;
  - `pkcs12` with `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`;
  - `security import -x -T /usr/bin/codesign`;
  - no trust settings;
  - the find-identity parse without `-v`;
  - the restore path (reuse existing `key.pem`/`cert.pem` in DIR);
  - refusing a DIR inside the repository;
  - the probe-sign of a copy of `/usr/bin/true` with a check that the DR contains `certificate leaf = H"<sha1>"`;
  - writing `Config/Local.xcconfig` (`CODE_SIGN_IDENTITY = <NAME>`) only when it is absent, with a warning if it is not git-ignored;
  - printing the two `gh secret set RFM_SIGNING_P12_BASE64 / RFM_SIGNING_P12_PASSWORD` commands without running them.
- The script is designed so its tests never touch the real keychain. Every external tool is invoked through a variable (`OPENSSL`, `SECURITY`, `CODESIGN`), overridable from the environment.
- `signing_identity.bats` uses stub executables on those variables:
  - `--help` exits 0 and prints usage;
  - an unknown flag → 2;
  - `--dir` inside the repo → 2 with a message;
  - `--check` with a stub `security` printing zero identities → 1, one → 0 and prints `<SHA1> "<name>"`, two → 2;
  - a second creation with an existing identity of the same name → refused.
- `docs/signing.md`:
  - what the identity is for (stable TCC grants);
  - how to create it (one command; click **Always Allow**);
  - backing up `~/.roomformac/signing`;
  - removing old FDA entries from ad-hoc builds;
  - the verification commands (`codesign -d -r-` and the stability test);
  - the fallbacks if Xcode rejects the identity (re-sign with `codesign` after build);
  - the security note (anyone with the key can sign code that inherits users' grants).

### Task 17: CI app job, README, roadmap and handoff updates

**Files:**
- Modify: `.github/workflows/ci.yml`, `README.md`, `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md`, `docs/superpowers/plans/2026-09-26-mvp-handoff.md`

**Interfaces:**
- Consumes: the schemes (Task 1), `app_bundle.bats` (Task 2) and the UI tests (Task 15).
- Produces: a CI job `app` with `name: RoomForMac app`, `runs-on: xcode-27` and `timeout-minutes: 60`. It does not depend on the `engine` job: engine artifacts are not shared across jobs, so it builds its own engine through `ensure-engine.sh`.

**Requirements:**
- Steps of the `app` job:
  1. checkout with `submodules: recursive`;
  2. `actions/setup-go@v5` (same config as the engine job);
  3. `brew install xcodegen bats-core`;
  4. `xcodegen generate`;
  5. `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`;
  6. a Release build to `build/DerivedData` with `-destination "generic/platform=macOS"`;
  7. `APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats`;
  8. UI tests `xcodebuild … -scheme RoomForMac -only-testing:RoomForMacUITests test`. GitHub's runner images enable Automation Mode.
- The `engine` job gains the `bats scripts/tests/signing_identity.bats` run as part of "Engine build checks" (`bats scripts/tests` already covers it).
- `on.push.branches` gains `main-mrvlfl`, because it is GitHub's default branch.
- `README.md` gains a "Building the app" section:
  - `brew bundle`;
  - `git submodule update --init`;
  - `xcodegen generate`;
  - `open RoomForMac.xcodeproj`, or `xcodebuild -scheme RoomForMac build`;
  - the first build builds the engine (about a minute);
  - signing (link to `docs/signing.md`);
  - UI tests need Automation Mode.
- The roadmap status line marks Plan 2 done and Plan 3 next. The handoff's Step 1 is marked done, with a pointer to this plan.
- Verify: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'` parses. The local sequence (engine steps, then `xcodegen generate`, the unit scheme, the Release build and `app_bundle.bats`) passes. Record the UI test result.

---

## Done when

- `xcodegen generate && xcodebuild -scheme RoomForMacUnit test` passes on this Mac, with every unit test green and no warnings.
- A Release build is universal, passes `app_bundle.bats`, and launches. On a first launch, onboarding appears, and the `onboarding` UI scenario walks through all steps to the Smart Clean placeholder.
- A broken or mismatched engine shows the blocking Reinstall card.
- Settings shows General, Permissions (live) and About with the engine line and all four legal documents.
- `scripts/make-signing-identity.sh` exists with its bats tests. `docs/signing.md` holds the owner's checklist.
- `ci.yml` has the `app` job. The roadmap and handoff are updated.
- The owner's manual checklist is in the final summary: signing identity, the S2/S5/TCC checks on a signed build, Automation Mode for UI tests, photos, and CI billing.
