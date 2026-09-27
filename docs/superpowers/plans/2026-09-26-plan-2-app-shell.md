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

**Status:** Written, cross-checked, and revised with the preflight rulings C1–C4 and R1–R8. With all 17 tasks applied in a scratch copy, the app builds with no warnings and 367 unit tests pass in 47 suites (214 after Task 9, 308 after Task 13, 349 after Task 14). Execution has not started. Branch `plan2/app-shell`, based on `main` at `7a99b38`.

## Global Constraints

- **Platform:** macOS 26.0 deployment target (`LSMinimumSystemVersion` 26.0). Universal Release builds (`ARCHS = $(ARCHS_STANDARD)` → arm64 + x86_64). Swift 6 language mode (`SWIFT_VERSION = 6.0`). SwiftUI. Unit tests use Swift Testing (`import Testing`); only UI tests use XCTest.
- **Project generation:** the project is generated from `project.yml` by XcodeGen 2.46. Git ignores `RoomForMac.xcodeproj/`, `RoomForMac/Info.plist`, `RoomForMac/RoomForMac.entitlements`, `RoomForMac/Generated/` and `Config/Local.xcconfig`.
- **Dependencies:** none from third parties. The app links only `MoleEngine`, through `packages: MoleEngine: path: Packages/MoleEngine`. The unit-test target does **not** link the package again.
- **Identity:**
  - Bundle ID `com.roomformac.RoomForMac` (Ruling 1); UserDefaults domain is the bundle ID. The test bundles are `com.roomformac.RoomForMac.tests` and `.uitests`, and `CFBundleURLName` is the bundle ID.
  - Helper tool identifiers are `com.roomformac.RoomForMac.engine.<tool>`.
  - URL scheme `roomformac`.
  - Product and display name `RoomForMac`.
  - `LSApplicationCategoryType` is `public.app-category.utilities`.
- **Security settings:** no App Sandbox (`EngineEnvironment.current()` must see the real home). Hardened runtime **off**. No `com.apple.security.automation.apple-events` entitlement: it is not needed while hardened runtime is off, and must be added if Plan 6 turns hardened runtime on.
- **Signing settings live only in `Config/Signing.xcconfig`** (`CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM =`, `CODE_SIGN_IDENTITY = -`, `ENABLE_HARDENED_RUNTIME = NO`, then `#include? "Local.xcconfig"`). Neither the `settings:` of `project.yml` nor any target `settings:` may set `CODE_SIGN_*` or `DEVELOPMENT_TEAM`, because they would silently override the xcconfig.
- **Engine:**
  - Scripts, `lib`, `host-bin`, `VERSION` and Mole's `LICENSE` go in `RoomForMac.app/Contents/Resources/engine/`.
  - `analyze-go` and `status-go` go in `Contents/Helpers/`, with relative symlinks `engine/bin/<tool>` → `../../../Helpers/<tool>`.
  - The app never uses a system-installed `mo` and has **no runtime override** of the engine location. `RFM_ENGINE_DIR` is a build setting only.
- **Info.plist `NSAppleEventsUsageDescription`, verbatim:** `RoomForMac asks Finder to move apps to the Trash if the usual way fails. It asks System Events which apps are running before a cleanup and to remove the login items of apps you uninstall.` (Ruling 10.)
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

1. **Bundle ID `com.roomformac.RoomForMac`.** The spec names none. Tasks 1–13 were written with `com.roomformac.app`; the controller revised it after Task 13, before Task 14 (the text of Tasks 1–13 keeps the old ID), because an ID ending in `.app` makes UTI classify folders named after it as application bundles (for example Sparkle's cache and `~/Library/Caches/<id>`; Sparkle PR #2882, reproduced locally). The helpers are `com.roomformac.RoomForMac.engine.<tool>`, the test bundles `com.roomformac.RoomForMac.tests` and `.uitests`, and `CFBundleURLName` is the bundle ID. *If wrong:* changing it after the first public release resets every user's TCC grants and preferences. Confirm it before Plan 6 ships.
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
    - **Finder:** only the engine's rare fallback for moving apps to the Trash. Plan 3's Status will run `status-go` with an `osascript` stub, so it never asks Finder for free space, which would send a Finder Apple event every 2 minutes and tie a prompt to Status (research C6); it will read the free space itself with `volumeAvailableCapacityForImportantUsage`. The Finder card's reason is "Moves apps to the Trash if the usual way fails." This was revised after Task 13, before Task 14; the text of Tasks 1–13 quotes the earlier copy.

    Spec §6 gave other reasons. Plan 3 must not start `StatusService` or a scan before onboarding is complete; `AppModel.isOnboarded` exposes this.
11. **Full Disk Access is detected with a list of probe files**, not "the user's `TCC.db`". The user `TCC.db` does not exist on macOS 27. `open()` returning EPERM or EACCES means denied, success means granted, and ENOENT means no evidence.
12. **What counts as installed:** anything under `/Applications/` or `~/Applications/`. A standard user cannot write `/Applications`, so the Move step offers `~/Applications`. If that fails too, it tells the user to drag the app. DEBUG builds skip the Move step unless the launch argument `-RFMForceMoveStep YES` is passed.
13. **Mole's `LICENSE` ships in the engine.** `build-engine.sh` copies `vendor/mole/LICENSE` into `$OUT/LICENSE`. GPL-3.0 requires it, and research found it missing. About shows it next to RoomForMac's `LICENSE`, `NOTICE` and `CREDITS.md`.
14. **CI:** a new `app` job on `runs-on: xcode-27` matches the local Xcode 27.0. The `macos-26` image has only Xcode 26.6 and SDK 26.5. The engine job stays on `macos-26`. CI still cannot run until the owner fixes Actions billing or makes the repository public. *If wrong:* change one label.
15. **No app icon, wordmark asset or photos are bundled in this plan.**
    - The wordmark is drawn from CoreText glyph outlines of "RoomForMac" in SF Pro Rounded Semibold.
    - The app icon arrives with Plan 6 branding.
    - Backdrops use palette gradients until the owner picks photos.
16. **`EngineExpectation.swift` joins the sources in Task 2, not Task 1.** XcodeGen adds an `optional: true` file reference even when the file is missing, and the build then fails with "Build input file cannot be found" until a script phase declares the file as its output. Task 1 keeps `excludes: [Generated]`, and Task 2 adds the entry together with its "Prepare engine" phase. *If wrong:* nothing; Task 1 builds.
17. **Task 3 adds `AccessibilityID.engineProblemDownload`** (`"engineProblem.download"`) for the "Open download page" button, because every interactive element needs an identifier. *If wrong:* one constant.
18. **Task 10 owns the DEBUG Move-step bypass decision.** It provides `AppLocationChecker.bypassesMoveStepInThisBuild` and `live(bypass:)`. Task 12's `AppDependencies.live` computes it once and uses it for both the checker and `needsMoveStep`. *If wrong:* one call site.
19. **Ready hides the scaffold's primary button.** Task 13 adds an internal `OnboardingScaffold.primaryHidden(_:)`, so Ready shows only its morphing **Start first scan** (and "Not now"). The UI test presses `onboarding.ready.startScan`. *If wrong:* a visual difference only.
20. **The login item is registered only once the app is installed.** `OnboardingApply.apply` requests `.launchAtLogin` only when the Move state is `.granted` or `.notApplicable`, or when there is no Move checker, because research §1.4 says to register only from /Applications. *If wrong:* a user who skipped the Move step gets no login item until they move the app and toggle it in Settings.

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
project.yml                                   XcodeGen definition (Task 1; edited by Tasks 2, 6, 14)
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
    RoomForMacApp.swift                       @main; scenes; runtime-mode switch (Task 1, 7, 14)
    RuntimeMode.swift                         normal / unitTestHost / uiTest(scenario) (Task 1)
    AppDependencies.swift                     composition root: live + DEBUG scenarios (Task 7, 12, 15)
    AppPreferences.swift                      typed UserDefaults wrapper (Task 7)
    AppModel.swift                            engine phase, onboarding flag, sidebar selection (Task 7, 12)
    SidebarSection.swift                      Smart Clean / Uninstaller / Status (Task 7)
    RootView.swift                            engine problem | onboarding | split view (Task 7, 12)
    AccessibilityID.swift                     every accessibility identifier (Task 3; rewritten by 7; appended by 12, 13, 14)
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
    EngineProblemView.swift                   blocking "Reinstall RoomForMac" card (Task 3, 5)
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
      OnboardingView.swift  OnboardingScaffold.swift                             (Task 12, 13)
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
  Support/TemporaryDefaults.swift                                               (Task 7)
  Support/FakeChecker.swift                                                     (Task 8)
  Support/Locked.swift                                                          (Task 9)
  Support/AppMoveFixtures.swift                                                 (Task 10)
  Support/FakeLoginService.swift                                                (Task 13)
RoomForMacUITests/
  LaunchSmokeTests.swift                                                        (Task 1, 15)
  UITestSupport.swift  OnboardingSmokeTests.swift  EngineProblemSmokeTests.swift (Task 15)
.github/workflows/ci.yml                      + app job (Task 17)
docs/signing.md                               create, back up and verify the signing identity (Task 16)
README.md                                     + building and running the app, signing (Task 16, 17)
```

---

## Tasks

The task text below is the requirements contract. The **Interfaces** blocks are binding: names, types and signatures must match across tasks exactly.

### Task 1: XcodeGen project, app skeleton and test-host guard

**Files:**
- Create: `project.yml`, `Config/Signing.xcconfig`, `RoomForMac/App/RoomForMacApp.swift`, `RoomForMac/App/RuntimeMode.swift`, `RoomForMac/Resources/Localizable.xcstrings`, `RoomForMac/Resources/Assets.xcassets/{Contents.json,AccentColor.colorset/Contents.json}`, `RoomForMacTests/RuntimeModeTests.swift`, `RoomForMacUITests/LaunchSmokeTests.swift`
- Create (added by this section): `RoomForMacTests/AppBundleInfoTests.swift`. It checks the generated Info.plist, and that the host app is not sandboxed, from inside the hosted app.
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
  - (internal to this task) The entry point in `RoomForMac/App/RoomForMacApp.swift`:
    ```swift
    @main enum RoomForMacLauncher {
        enum Entry: Equatable, Sendable { case testHost, app }
        static func entry(for mode: RuntimeMode) -> Entry   // .testHost only for .unitTestHost
        @MainActor static func main()                       // UnitTestHostApp.main() or RoomForMacApp.main()
    }
    struct UnitTestHostApp: App   // one WindowGroup { Color.clear }, nothing else
    struct RoomForMacApp: App     // the real scenes; Task 7 fills them in
    ```
  - Note for Task 7: `SceneBuilder` cannot branch on a runtime value. SDK 27 offers only `buildOptional` for `#available`, and no `buildEither`. So the test-host switch lives in `RoomForMacLauncher`, not in `RoomForMacApp.body`. Task 7 edits `struct RoomForMacApp` only. `RoomForMacApp` is never constructed in `.unitTestHost`, so its `init()` can read `RuntimeMode.current` and build `AppModel` without a test-host branch.

**Interface issue:** the skeleton's `- path: RoomForMac/Generated/EngineExpectation.swift` / `optional: true` source cannot land in Task 1. XcodeGen adds the file reference even when the file is missing. Until a build phase declares that file as an output, every build fails with `error: Build input file cannot be found: '…/RoomForMac/Generated/EngineExpectation.swift'. Did you forget to declare this file as an output of a script phase or custom build rule which produces it?` (reproduced in scratch). Smallest fix: Task 1 keeps `excludes: [Generated]` on the `RoomForMac` source. Task 2 adds the `optional: true` entry in the same edit as its "Prepare engine" phase, which declares that file as its output.

**Requirements:**
- `project.yml` follows the verified probe layout from the research (XcodeGen 2.46).
  - `options`: `bundleIdPrefix: com.roomformac`, deployment target macOS 26.0, `createIntermediateGroups: true`, `developmentLanguage: en`.
  - `configFiles` for Debug and Release point to `Config/Signing.xcconfig`.
  - Project `settings.base`: `SWIFT_VERSION: "6.0"`, `MARKETING_VERSION: "0.1.0"`, `CURRENT_PROJECT_VERSION: "1"`, `DEAD_CODE_STRIPPING: YES`, `ENABLE_USER_SCRIPT_SANDBOXING: NO`, `LOCALIZATION_PREFERS_STRING_CATALOGS: YES`, `SWIFT_EMIT_LOC_STRINGS: YES`.
  - **No `CODE_SIGN_*` and no `DEVELOPMENT_TEAM` anywhere in `project.yml`**, not even in comments, so `grep -nE 'CODE_SIGN|DEVELOPMENT_TEAM' project.yml` prints nothing.
  - The app target:
    - `PRODUCT_BUNDLE_IDENTIFIER: com.roomformac.app`, `PRODUCT_NAME: RoomForMac`, `ARCHS: $(ARCHS_STANDARD)`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`. It depends on the `MoleEngine` package product.
    - `info:` generates `RoomForMac/Info.plist` with:
      - `CFBundleDisplayName` RoomForMac;
      - `LSApplicationCategoryType` `public.app-category.utilities`;
      - `LSMinimumSystemVersion` `$(MACOSX_DEPLOYMENT_TARGET)`;
      - `CFBundleShortVersionString` `$(MARKETING_VERSION)`;
      - `CFBundleVersion` `$(CURRENT_PROJECT_VERSION)`;
      - `NSAppleEventsUsageDescription` (verbatim from Global Constraints);
      - `CFBundleURLTypes` (`CFBundleURLName` `com.roomformac.app`, scheme `roomformac`).
    - Also these usage descriptions, which are only shown when FDA is skipped:
      - `NSDownloadsFolderUsageDescription`: "RoomForMac looks for unfinished downloads it can clean up."
      - `NSDesktopFolderUsageDescription`: "RoomForMac measures what fills your Desktop."
      - `NSDocumentsFolderUsageDescription`: "RoomForMac measures what fills your Documents folder."
      - `NSRemovableVolumesUsageDescription`: "RoomForMac measures what fills your external drives."
      - `NSNetworkVolumesUsageDescription`: "RoomForMac measures what fills network drives you choose."
    - These Info.plist strings are English literals in `project.yml`. Localizing them later needs an `InfoPlist.xcstrings`, not `Localizable.xcstrings`.
    - `entitlements:` generates `RoomForMac/RoomForMac.entitlements` with `properties: {}` (an empty `<dict/>`) and no sandbox.
  - `sources`: `RoomForMac` with `excludes: [Generated]`. The `optional: true` entry for `RoomForMac/Generated/EngineExpectation.swift` moves to Task 2 (see **Interface issue**), which also adds the script phases.
  - The test targets:
    - `RoomForMacTests` (`bundle.unit-test`) depends on the app target, so XcodeGen sets `TEST_HOST` and `BUNDLE_LOADER`. It has no package dependency: `MoleEngine` resolves through the host app.
    - `RoomForMacUITests` (`bundle.ui-testing`) depends on the app target.
    - Both use `GENERATE_INFOPLIST_FILE: YES`, with bundle IDs `com.roomformac.app.tests` and `com.roomformac.app.uitests`.
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
  - `-RFMUITestScenario <raw>` with a known raw value and `isDebugBuild == true` gives `.uiTest(scenario)`. The raw value is the argument right after the flag.
  - Otherwise, an environment containing `XCTestConfigurationFilePath` gives `.unitTestHost`.
  - Otherwise `.normal`.
  - An unknown scenario value, a flag with no value after it, or any scenario in a non-DEBUG build is ignored. Detection then falls through to the XCTest check, which gives `.normal` outside XCTest.
- Entry point:
  - `RoomForMacLauncher` is `@main`.
  - In `.unitTestHost` it runs `UnitTestHostApp`: a single `WindowGroup { Color.clear }` scene, and nothing else is constructed.
  - Otherwise it runs `RoomForMacApp`: a `Window("RoomForMac", id: "main")` with a temporary `Text("RoomForMac")`, and a `Settings` scene with a temporary `Text("Settings")`. Task 7 replaces both.
- Strings: `Localizable.xcstrings` (source language `en`) holds `RoomForMac` (with `shouldTranslate: false`) and `Settings`, the only keys in this task's views.
- Tests:
  - `RuntimeModeTests` covers every branch of `detect`: each known scenario, unknown scenario, missing or misplaced value, release build, and precedence (a scenario wins over `XCTestConfigurationFilePath`). It also covers the stable raw values, that the hosted tests themselves see `RuntimeMode.current == .unitTestHost`, and `RoomForMacLauncher.entry(for:)`.
  - `AppBundleInfoTests` checks the built app's Info.plist values (bundle ID, display name, category, minimum system, URL scheme, the Apple-events reason verbatim, the five folder reasons) and that the process is not sandboxed.
  - `LaunchSmokeTests` (XCTest) launches the app with `-RFMUITestScenario onboarded` and asserts a window exists. It runs only when Automation Mode is available; see Task 15.
- Verify:
  - `xcodegen generate` succeeds.
  - `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test` passes with no compiler warnings.
  - `xcodebuild -showBuildSettings -scheme RoomForMac` shows `CODE_SIGN_IDENTITY = -`, `PRODUCT_BUNDLE_IDENTIFIER = com.roomformac.app`, `SWIFT_VERSION = 6.0` and `ENABLE_HARDENED_RUNTIME = NO`. A `Config/Local.xcconfig` still overrides the identity.
  - A universal Release build passes a strict `codesign --verify --deep`.

- [ ] **Step 1: Add XcodeGen to the toolchain**

`Brewfile` (whole file; only the header comment and the last line change):
```ruby
# Toolchain for building and testing RoomForMac and its engine.
brew "go"
brew "bats-core"
brew "shellcheck"
brew "shfmt"
brew "coreutils" # gtimeout, used by Mole's run_with_timeout
brew "parallel"  # lets Mole's scripts/test.sh run bats files in parallel
brew "xcodegen"  # generates RoomForMac.xcodeproj from project.yml
```

Run: `brew bundle --file Brewfile && xcodegen --version`
Expected: `Homebrew Bundle complete!`, then `Version: 2.46.0`. This task was verified with 2.46.0. A newer 2.x is fine if Step 9 prints the same settings.

- [ ] **Step 2: Ignore the generated and per-developer files**

`.gitignore` (whole file; the first seven lines are unchanged):
```gitignore
.DS_Store
/build/
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcuserstate

# Generated by XcodeGen from project.yml, or by the engine build phase
RoomForMac.xcodeproj/
RoomForMac/Info.plist
RoomForMac/RoomForMac.entitlements
RoomForMac/Generated/

# Per-developer signing override, included by Config/Signing.xcconfig
Config/Local.xcconfig

# Local working files of the superpowers workflow
.superpowers/
```

- [ ] **Step 3: Write the signing defaults**

`Config/Signing.xcconfig` (verbatim):
```
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM =
CODE_SIGN_IDENTITY = -
ENABLE_HARDENED_RUNTIME = NO
#include? "Local.xcconfig"
```

`#include?` skips a missing file silently, so builds are ad-hoc (`-`) until Task 16's script writes `Config/Local.xcconfig`. Every signing and team setting lives here. A `settings:` entry in `project.yml`, at project or target level, would silently override this file and its `Local.xcconfig` (research V6).

- [ ] **Step 4: Write `project.yml`**

```yaml
# XcodeGen 2.46 project definition; run `xcodegen generate` after any change.
# RoomForMac.xcodeproj, RoomForMac/Info.plist and RoomForMac/RoomForMac.entitlements
# are generated from this file and git-ignored.
#
# Signing lives only in Config/Signing.xcconfig. Add no signing or team settings
# here, at project or target level: they would silently override that file and
# the per-developer Config/Local.xcconfig it includes.
name: RoomForMac
options:
  bundleIdPrefix: com.roomformac
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
  developmentLanguage: en

configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig

settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    DEAD_CODE_STRIPPING: YES
    ENABLE_USER_SCRIPT_SANDBOXING: NO
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
    SWIFT_EMIT_LOC_STRINGS: YES

packages:
  MoleEngine:
    path: Packages/MoleEngine

targets:
  RoomForMac:
    type: application
    platform: macOS
    deploymentTarget: "26.0"
    sources:
      # RoomForMac/Generated/ holds build-phase output; it is never picked up from this folder.
      - path: RoomForMac
        excludes:
          - Generated
    info:
      path: RoomForMac/Info.plist
      properties:
        CFBundleDisplayName: RoomForMac
        LSApplicationCategoryType: public.app-category.utilities
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NSAppleEventsUsageDescription: RoomForMac asks Finder for your disk's free space and, if needed, to move apps to the Trash. It asks System Events which apps are running before a cleanup and to remove the login items of apps you uninstall.
        NSDownloadsFolderUsageDescription: RoomForMac looks for unfinished downloads it can clean up.
        NSDesktopFolderUsageDescription: RoomForMac measures what fills your Desktop.
        NSDocumentsFolderUsageDescription: RoomForMac measures what fills your Documents folder.
        NSRemovableVolumesUsageDescription: RoomForMac measures what fills your external drives.
        NSNetworkVolumesUsageDescription: RoomForMac measures what fills network drives you choose.
        CFBundleURLTypes:
          - CFBundleURLName: com.roomformac.app
            CFBundleURLSchemes: [roomformac]
    entitlements:
      path: RoomForMac/RoomForMac.entitlements
      properties: {}
    dependencies:
      - package: MoleEngine
        product: MoleEngine
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.roomformac.app
        PRODUCT_NAME: RoomForMac
        ARCHS: $(ARCHS_STANDARD)
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    scheme:
      testTargets:
        - RoomForMacTests
        - RoomForMacUITests
      gatherCoverageData: false

  RoomForMacTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "26.0"
    sources:
      - path: RoomForMacTests
    dependencies:
      - target: RoomForMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.roomformac.app.tests
        GENERATE_INFOPLIST_FILE: YES

  RoomForMacUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "26.0"
    sources:
      - path: RoomForMacUITests
    dependencies:
      - target: RoomForMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.roomformac.app.uitests
        GENERATE_INFOPLIST_FILE: YES

schemes:
  RoomForMacUnit:
    build:
      targets:
        RoomForMac: all
        RoomForMacTests: [test]
    test:
      config: Debug
      gatherCoverageData: false
      targets:
        - name: RoomForMacTests
          parallelizable: false
```

Notes:
- The app's `sources` has no `RoomForMac/Generated/EngineExpectation.swift` entry yet (see **Interface issue**). Task 2 adds it with the phase that writes the file.
- `RoomForMac/Info.plist` and `RoomForMac/RoomForMac.entitlements` are generated inside the `RoomForMac` source folder. XcodeGen keeps both out of Copy Bundle Resources on its own.
- `.xcstrings` and `.xcassets` files under `RoomForMac/` go to the Resources phase automatically.
- XcodeGen's macOS application preset sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. With no icon set in the catalog, `actool` stays silent (verified). The icon arrives with Plan 6 (Ruling 15).
- `xcodegen generate` also creates a `MoleEngine` scheme for the local package. Nothing uses it.

- [ ] **Step 5: Add the String Catalog and the asset catalog**

`RoomForMac/Resources/Localizable.xcstrings`:
```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "RoomForMac" : {
      "shouldTranslate" : false
    },
    "Settings" : {

    }
  },
  "version" : "1.0"
}
```

`RoomForMac/Resources/Assets.xcassets/Contents.json`:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`RoomForMac/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:
```json
{
  "colors" : [
    {
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

About these files:
- The catalog lists exactly the keys this task's views use: `Window("RoomForMac", …)` and `Text("RoomForMac")` share one key, plus `Text("Settings")`. An `xcodebuild` build leaves the file byte-for-byte unchanged (verified).
- English is the source language, so nothing is compiled out of the catalog yet. Later tasks add their keys as they add `Text("…")` literals.
- `AccentColor` is Xcode's empty template slot. Task 4 writes the `action` light and dark values into it. While it is empty, `actool` writes no `Assets.car` and prints no warning.

- [ ] **Step 6: Write a temporary entry point**

`RoomForMac/App/RoomForMacApp.swift`:
```swift
import SwiftUI

/// Temporary entry point so the app target compiles before the runtime-mode tests exist.
/// The runtime-mode launcher replaces it later in this task.
@main
struct RoomForMacApp: App {
    var body: some Scene {
        Window("RoomForMac", id: "main") {
            Text("RoomForMac")
                .frame(minWidth: 480, minHeight: 320)
        }
        Settings {
            Text("Settings")
                .frame(width: 320, height: 160)
        }
    }
}
```

This lets the app target compile on its own, so Step 10 fails in the test target for the right reason. Step 12 replaces this file.

- [ ] **Step 7: Write the UI smoke test**

`RoomForMacUITests/LaunchSmokeTests.swift`:
```swift
import XCTest

/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while
/// enabling automation mode", an environment limit rather than a code failure.
final class LaunchSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsAWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-RFMUITestScenario", "onboarded"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
```

- XcodeGen refuses to generate while a target's source folder is missing (`Target "RoomForMacUITests" has a missing source directory`). Git keeps no empty folders, so both test folders need a file before Step 9.
- The scenario argument keeps this launch away from live engine and permission checks once Task 7 wires them in. Task 15 extends this test.

- [ ] **Step 8: Write the failing unit tests**

`RoomForMacTests/RuntimeModeTests.swift`:
```swift
import Testing
@testable import RoomForMac

@Suite("Runtime mode")
struct RuntimeModeTests {
    private let executable = "/Applications/RoomForMac.app/Contents/MacOS/RoomForMac"
    private let hostedByXCTest = ["XCTestConfigurationFilePath": "/tmp/RoomForMacTests.xctestconfiguration"]

    @Test func aPlainLaunchIsNormal() {
        let mode = RuntimeMode.detect(environment: ["HOME": "/Users/test"], arguments: [executable], isDebugBuild: true)
        #expect(mode == .normal)
    }

    @Test func theXCTestConfigurationMeansUnitTestHost() {
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: [executable], isDebugBuild: true) == .unitTestHost)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: [executable], isDebugBuild: false) == .unitTestHost)
    }

    @Test(arguments: UITestScenario.allCases)
    func aKnownScenarioInADebugBuildIsAUITest(_ scenario: UITestScenario) {
        let arguments = [executable, RuntimeMode.scenarioArgument, scenario.rawValue]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: true) == .uiTest(scenario))
    }

    @Test func aScenarioWinsOverTheUnitTestHost() {
        let arguments = [executable, "-RFMUITestScenario", "engine-broken"]
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: true) == .uiTest(.engineBroken))
    }

    @Test func anUnknownScenarioIsIgnored() {
        let arguments = [executable, "-RFMUITestScenario", "everything-granted"]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: true) == .unitTestHost)
    }

    @Test func aScenarioIsIgnoredInAReleaseBuild() {
        let arguments = [executable, "-RFMUITestScenario", "onboarding"]
        #expect(RuntimeMode.detect(environment: [:], arguments: arguments, isDebugBuild: false) == .normal)
        #expect(RuntimeMode.detect(environment: hostedByXCTest, arguments: arguments, isDebugBuild: false) == .unitTestHost)
    }

    @Test func theScenarioValueMustFollowTheFlag() {
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "-RFMUITestScenario"], isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "onboarding", "-RFMUITestScenario"], isDebugBuild: true) == .normal)
        #expect(RuntimeMode.detect(environment: [:], arguments: [executable, "onboarding"], isDebugBuild: true) == .normal)
    }

    @Test func theLaunchContractIsStable() {
        #expect(RuntimeMode.scenarioArgument == "-RFMUITestScenario")
        #expect(UITestScenario.allCases.map(\.rawValue) == ["onboarding", "onboarded", "engine-broken"])
    }

    @Test func theseTestsRunInsideTheUnitTestHost() {
        #expect(RuntimeMode.current == .unitTestHost)
    }

    @Test func onlyTheUnitTestHostRunsTheEmptyHostApp() {
        #expect(RoomForMacLauncher.entry(for: .unitTestHost) == .testHost)
        #expect(RoomForMacLauncher.entry(for: .normal) == .app)
        for scenario in UITestScenario.allCases {
            #expect(RoomForMacLauncher.entry(for: .uiTest(scenario)) == .app)
        }
    }
}
```

`RoomForMacTests/AppBundleInfoTests.swift`:
```swift
import Foundation
import Testing

/// The unit tests run inside RoomForMac.app, so `Bundle.main` is the built app.
@Suite("App bundle")
struct AppBundleInfoTests {
    private func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    @Test func identity() {
        #expect(Bundle.main.bundleIdentifier == "com.roomformac.app")
        #expect(Bundle.main.bundleURL.lastPathComponent == "RoomForMac.app")
        #expect(info("CFBundleDisplayName") == "RoomForMac")
        #expect(info("LSApplicationCategoryType") == "public.app-category.utilities")
        #expect(info("LSMinimumSystemVersion") == "26.0")
    }

    @Test func urlScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleURLName"] as? String == "com.roomformac.app")
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["roomformac"])
    }

    @Test func appleEventsReasonIsVerbatim() {
        #expect(info("NSAppleEventsUsageDescription") == """
            RoomForMac asks Finder for your disk's free space and, if needed, to move apps to the Trash. \
            It asks System Events which apps are running before a cleanup and to remove the login items \
            of apps you uninstall.
            """)
    }

    @Test func folderReasonsForWhenFullDiskAccessIsSkipped() {
        #expect(info("NSDownloadsFolderUsageDescription") == "RoomForMac looks for unfinished downloads it can clean up.")
        #expect(info("NSDesktopFolderUsageDescription") == "RoomForMac measures what fills your Desktop.")
        #expect(info("NSDocumentsFolderUsageDescription") == "RoomForMac measures what fills your Documents folder.")
        #expect(info("NSRemovableVolumesUsageDescription") == "RoomForMac measures what fills your external drives.")
        #expect(info("NSNetworkVolumesUsageDescription") == "RoomForMac measures what fills network drives you choose.")
    }

    @Test func theAppIsNotSandboxed() {
        #expect(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil)
        #expect(!NSHomeDirectory().contains("/Library/Containers/"))
    }
}
```

`AppBundleInfoTests` pins `project.yml`. It passes as soon as its target compiles, and it breaks if someone edits a reason, the URL scheme or the bundle ID by accident. It does not check versions, which change with every release.

- [ ] **Step 9: Generate the project and check the settings that must not drift**

Run: `xcodegen generate && xcodebuild -list -project RoomForMac.xcodeproj`
Expected: `Created project at …/RoomForMac.xcodeproj`. The listing shows targets `RoomForMac`, `RoomForMacTests`, `RoomForMacUITests` and schemes `MoleEngine`, `RoomForMac`, `RoomForMacUnit`.

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2> /dev/null \
    | grep -E '^ *(CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|PRODUCT_BUNDLE_IDENTIFIER|SWIFT_VERSION|ENABLE_HARDENED_RUNTIME|ENABLE_USER_SCRIPT_SANDBOXING) ='
```
Expected:
```
    CODE_SIGN_IDENTITY = -
    CODE_SIGN_STYLE = Manual
    ENABLE_HARDENED_RUNTIME = NO
    ENABLE_USER_SCRIPT_SANDBOXING = NO
    PRODUCT_BUNDLE_IDENTIFIER = com.roomformac.app
    SWIFT_VERSION = 6.0
```

Next, check that a per-developer `Local.xcconfig` still wins, and that `project.yml` holds no signing key. This only reads settings; nothing is signed, so the identity does not need to exist.
```bash
if [[ ! -e Config/Local.xcconfig ]]; then
    printf 'CODE_SIGN_IDENTITY = RoomForMac Self-Signed\n' > Config/Local.xcconfig
    xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2> /dev/null \
        | grep -E '^ *CODE_SIGN_IDENTITY ='
    rm Config/Local.xcconfig
fi
grep -nE 'CODE_SIGN|DEVELOPMENT_TEAM' project.yml || echo "project.yml has no signing keys"
```
Expected:
```
    CODE_SIGN_IDENTITY = RoomForMac Self-Signed
project.yml has no signing keys
```

Run:
```bash
git check-ignore RoomForMac.xcodeproj RoomForMac/Info.plist RoomForMac/RoomForMac.entitlements \
    RoomForMac/Generated/EngineExpectation.swift Config/Local.xcconfig .superpowers/notes.md
```
Expected: all six paths printed back, one per line.

- [ ] **Step 10: Run the unit tests to verify they fail**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`
Expected: `** TEST FAILED **` (exit 65). The app target builds, and the test target stops compiling with:
```
RuntimeModeTests.swift:10:20: error: cannot find 'RuntimeMode' in scope
RuntimeModeTests.swift:19:22: error: cannot find 'UITestScenario' in scope
RuntimeModeTests.swift:20:59: error: cannot find type 'UITestScenario' in scope
```

- [ ] **Step 11: Write `RuntimeMode`**

`RoomForMac/App/RuntimeMode.swift`:
```swift
import Foundation

/// A scripted situation a UI test launches the app into, with
/// `-RFMUITestScenario <raw value>`. Honoured only in DEBUG builds.
enum UITestScenario: String, Sendable, CaseIterable {
    /// A fresh install; scripted permissions that grant when requested.
    case onboarding = "onboarding"
    /// Onboarding is already complete.
    case onboarded = "onboarded"
    /// The engine health check reports a problem.
    case engineBroken = "engine-broken"
}

/// How this process was started. The app builds its scenes and dependencies from it.
enum RuntimeMode: Equatable, Sendable {
    /// Started by the user.
    case normal
    /// Hosting the app-hosted unit tests: no engine check, permission check or polling.
    case unitTestHost
    /// Started by a UI test with a scripted scenario (DEBUG builds only).
    case uiTest(UITestScenario)

    static let scenarioArgument = "-RFMUITestScenario"

    /// XCTest sets this variable in the environment of the app that hosts unit tests.
    private static let testConfigurationVariable = "XCTestConfigurationFilePath"

    /// A known scenario after `scenarioArgument` wins in DEBUG builds. Otherwise the
    /// XCTest variable means `.unitTestHost`. Unknown scenarios, and any scenario in
    /// a release build, are ignored.
    static func detect(environment: [String: String], arguments: [String], isDebugBuild: Bool) -> RuntimeMode {
        if isDebugBuild, let scenario = scenario(in: arguments) {
            return .uiTest(scenario)
        }
        if environment[testConfigurationVariable] != nil {
            return .unitTestHost
        }
        return .normal
    }

    static var current: RuntimeMode {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let process = ProcessInfo.processInfo
        return detect(environment: process.environment, arguments: process.arguments, isDebugBuild: isDebugBuild)
    }

    /// The known scenario named by the argument right after `scenarioArgument`.
    private static func scenario(in arguments: [String]) -> UITestScenario? {
        guard let flag = arguments.firstIndex(of: scenarioArgument), flag + 1 < arguments.endIndex else {
            return nil
        }
        return UITestScenario(rawValue: arguments[flag + 1])
    }
}
```

- [ ] **Step 12: Replace the entry point with the test-host guard**

`RoomForMac/App/RoomForMacApp.swift` (whole file):
```swift
import SwiftUI

/// The process entry point. While XCTest hosts the unit tests it runs an empty app,
/// so hosted tests never build the real app's model, engine check or permission checks.
@main
enum RoomForMacLauncher {
    enum Entry: Equatable, Sendable {
        case testHost
        case app
    }

    static func entry(for mode: RuntimeMode) -> Entry {
        mode == .unitTestHost ? .testHost : .app
    }

    @MainActor
    static func main() {
        switch entry(for: .current) {
        case .testHost:
            UnitTestHostApp.main()
        case .app:
            RoomForMacApp.main()
        }
    }
}

/// The only scene of the unit-test host process. It constructs nothing else.
struct UnitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}

/// RoomForMac itself. The window and Settings contents are placeholders for now.
struct RoomForMacApp: App {
    var body: some Scene {
        Window("RoomForMac", id: "main") {
            Text("RoomForMac")
                .frame(minWidth: 480, minHeight: 320)
        }
        Settings {
            Text("Settings")
                .frame(width: 320, height: 160)
        }
    }
}
```

- `App.main()` is `@MainActor`, so the launcher's `main()` is too. Swift 6 accepts a `@MainActor static func main()` on a `@main` type.
- `RuntimeMode.current` reads the environment once per call and holds no global state.

- [ ] **Step 13: Run the unit tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`
Expected: `✔ Test run with 15 tests in 2 suites passed` and `** TEST SUCCEEDED **`. That is 10 tests in "Runtime mode", where the scenario test runs 3 cases, and 5 in "App bundle".

To run one suite, add `-only-testing:RoomForMacTests/RuntimeModeTests` (`10 tests in 1 suite`) or `-only-testing:RoomForMacTests/AppBundleInfoTests` (`5 tests in 1 suite`).

The output also contains lines that are not compiler diagnostics:
- `--- xcodebuild: WARNING: Using the first of multiple matching destinations`. The app is universal, so "My Mac" matches as both arm64 and x86_64, and xcodebuild takes the first, arm64.
- `appintentsmetadataprocessor[…] warning: Metadata extraction skipped, no AppIntents.framework dependency found`. Every app without App Intents prints it.
- `[Connection] Unable to get synchronousRemoteObjectProxy, error: … com.apple.linkd.autoShortcut`. This is system log noise from the test host.

To check for real warnings, match only compiler and build-system diagnostics, which start with a path or with `warning:` / `error:`:

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | grep -E '^(/.*: )?(warning|error): '`
Expected: no output (exit 1). The same filter prints the three errors of Step 10.

- [ ] **Step 14: Check a universal Release build**

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build | grep '^\*\*'
APP=build/DerivedData/Build/Products/Release/RoomForMac.app
lipo -archs "$APP/Contents/MacOS/RoomForMac"
codesign --verify --deep --strict "$APP" && echo "signature verified"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|CodeDirectory|Signature)'
codesign -d --entitlements - --xml "$APP" 2> /dev/null | plutil -p -
plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$APP/Contents/Info.plist"
```
Expected:
```
** BUILD SUCCEEDED **
x86_64 arm64
signature verified
Identifier=com.roomformac.app
CodeDirectory v=20400 size=… flags=0x2(adhoc) hashes=… location=embedded
Signature=adhoc
{
  "com.apple.security.get-task-allow" => true
}
roomformac
```
- `flags=0x2(adhoc)` without `runtime` means hardened runtime is off.
- The entitlements have no `com.apple.security.app-sandbox`. Xcode adds `get-task-allow` to local builds on its own.
- `build/` is already git-ignored.

Optional manual look: `open build/DerivedData/Build/Products/Release/RoomForMac.app`. One window titled "RoomForMac" shows the text "RoomForMac", and ⌘, opens a Settings window reading "Settings". Quit with ⌘Q.

- [ ] **Step 15: Build the UI tests, and run them when Automation Mode allows**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS build-for-testing | grep '^\*\*'`
Expected: `** TEST BUILD SUCCEEDED **` (after the multiple-destinations note on stderr). `LaunchSmokeTests` compiles under Swift 6.

Run: `automationmodetool`
- If it prints a line containing `DOES NOT REQUIRE`, or you are at the Mac and can approve a password or Touch ID prompt, run the UI test.
  - Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS test -only-testing:RoomForMacUITests/LaunchSmokeTests`
  - Expected: `** TEST SUCCEEDED **`.
- Otherwise skip it, and record "LaunchSmokeTests not run: Automation Mode needs authentication". This Mac prints `This device requires user authentication to enable Automation Mode.` Running the test anyway fails after about 90 s with `Timed out while enabling automation mode.` (exit 65). That is an environment limit, not a code failure. GitHub's runners have Automation Mode enabled (Task 17).

- [ ] **Step 16: Commit**

```bash
git add .gitignore Brewfile project.yml Config/Signing.xcconfig \
    RoomForMac/App/RoomForMacApp.swift RoomForMac/App/RuntimeMode.swift \
    RoomForMac/Resources/Localizable.xcstrings RoomForMac/Resources/Assets.xcassets \
    RoomForMacTests/RuntimeModeTests.swift RoomForMacTests/AppBundleInfoTests.swift \
    RoomForMacUITests/LaunchSmokeTests.swift
git status --short
```
Expected:
```
M  .gitignore
M  Brewfile
A  Config/Signing.xcconfig
A  RoomForMac/App/RoomForMacApp.swift
A  RoomForMac/App/RuntimeMode.swift
A  RoomForMac/Resources/Assets.xcassets/AccentColor.colorset/Contents.json
A  RoomForMac/Resources/Assets.xcassets/Contents.json
A  RoomForMac/Resources/Localizable.xcstrings
A  RoomForMacTests/AppBundleInfoTests.swift
A  RoomForMacTests/RuntimeModeTests.swift
A  RoomForMacUITests/LaunchSmokeTests.swift
A  project.yml
```
None of `RoomForMac.xcodeproj/`, `RoomForMac/Info.plist` or `RoomForMac/RoomForMac.entitlements` appears, because they are ignored.

```bash
git commit -m "feat(app): XcodeGen project, app skeleton and test-host guard" \
    -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

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
- Script contracts (internal to this task; the Verify steps and Task 17's CI rely on these messages):
  - `scripts/ensure-engine.sh` checks `${RFM_ENGINE_DIR:-build/engine}`. It prints `Engine is up to date: <dir>` and exits 0, or rebuilds with `ENGINE_OUT=<dir> scripts/build-engine.sh`. With `RFM_NO_ENGINE_BUILD=1`, a missing or stale engine gives `error: <dir> is missing or stale; run scripts/build-engine.sh` and exit 1.
  - `scripts/engine-expectation.sh` reads `$RFM_ENGINE_DIR/VERSION` and writes `$SCRIPT_OUTPUT_FILE_0`. It prints `Engine expectation unchanged` or `Engine expectation updated: <tag>, <n> patches`. A missing key or a bad value is an `error:` line naming the key, exit 1, and no output file.
  - `scripts/embed-engine.sh` reads Xcode's `RFM_ENGINE_DIR`, `TARGET_BUILD_DIR`, `UNLOCALIZED_RESOURCES_FOLDER_PATH`, `CONTENTS_FOLDER_PATH`, `DERIVED_FILE_DIR`, `CODE_SIGNING_ALLOWED`, `EXPANDED_CODE_SIGN_IDENTITY`, `ENABLE_HARDENED_RUNTIME` and `PRODUCT_BUNDLE_IDENTIFIER`. It prints `Engine already embedded`, or `Embedded <tool>` once per helper. Its stamp is `$DERIVED_FILE_DIR/embed-engine.stamp`.
  - `scripts/tests/app_bundle.bats` also reads `EXPECT_UNIVERSAL=1`, and `RFM_ENGINE_DIR` (default `build/engine`) for the `VERSION` comparison.

**Interface issue:** Task 1 is told to list `RoomForMac/Generated/EngineExpectation.swift` (`optional: true`) in the app's `sources`. Until a script phase declares that file as its output, every build fails with `error: Build input file cannot be found: '…/RoomForMac/Generated/EngineExpectation.swift'. Did you forget to declare this file as an output of a script phase…` (reproduced with Task 1's draft `project.yml` in scratch). Smallest fix: Task 1 keeps only `excludes: [Generated]`, and this task adds the optional source entry together with the "Prepare engine" phase that produces it. Step 13 does that and also works if Task 1 already added the entry.

**Requirements:**
- `build-engine.sh`:
  - Writes `builder_sha256` into `VERSION`, on the line after `patch_count`. `VERSION` stays the last file written, so an interrupted build never looks complete to `ensure-engine.sh`.
  - Copies `$VENDOR/LICENSE` to `$OUT/LICENSE`.
  - `build_engine.bats` gains two tests: "VERSION records the builder hash" and "engine ships Mole's license" (`cmp` with `vendor/mole/LICENSE`).
  - `build_engine.bats` also covers the two "Prepare engine" scripts against the engine it has just built. None of these tests starts a second engine build.
    - `ensure-engine.sh`: up to date; stale without `builder_sha256`; stale with another builder hash; refuses a missing engine under `RFM_NO_ENGINE_BUILD=1`.
    - `engine-expectation.sh`: exact output that type-checks with `swiftc`; unchanged file keeps its mtime; a missing key fails; a `"`, a `\` or a non-numeric `patch_count` fails.
- `ensure-engine.sh`:
  - Use the verified research version: stamp compare of `mole_commit`, `patches_sha256` and `builder_sha256`.
  - Two changes from the research version. It checks `${RFM_ENGINE_DIR:-$ROOT/build/engine}` (the directory Xcode embeds from) and builds into it through `ENGINE_OUT`. It also fails with the `git submodule update --init` hint when `vendor/mole` is not checked out; otherwise `git -C vendor/mole` would read RoomForMac's own `HEAD`.
  - Export `PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`.
  - With `RFM_NO_ENGINE_BUILD=1` it errors instead of building.
  - Its runtime is about 0.1 s when the engine is up to date.
- `engine-expectation.sh`:
  - Reads `mole_tag`, `mole_commit`, `patches_sha256` and `patch_count` from `$RFM_ENGINE_DIR/VERSION`. When a key repeats, the last one wins, as in `EngineVersion`.
  - Writes `$SCRIPT_OUTPUT_FILE_0` only when the content changed (`cmp -s`), and fails clearly if a key is missing or empty.
  - Values are emitted as Swift string or integer literals. Escape nothing: reject values containing `"` or `\`, and a `patch_count` that is not all digits.
- `embed-engine.sh`:
  - Use the verified research version: fingerprint stamp, `ditto`, move Mach-O to `Helpers`, symlink, sign with `EXPANDED_CODE_SIGN_IDENTITY` and `--identifier "${PRODUCT_BUNDLE_IDENTIFIER}.engine.$name"`, add `--options runtime` only with hardened runtime, and `touch` the declared output.
  - Two additions. The fingerprint also covers `PRODUCT_BUNDLE_IDENTIFIER` and the destination, so a changed identifier re-signs. The skip also requires `Contents/Helpers` to exist.
- `project.yml`, on the app target:
  - Setting `RFM_ENGINE_DIR: $(SRCROOT)/build/engine`.
  - `preBuildScripts` "Prepare engine", running `"${SRCROOT}/scripts/ensure-engine.sh" && "${SRCROOT}/scripts/engine-expectation.sh"`, with `basedOnDependencyAnalysis: false` and output `$(SRCROOT)/RoomForMac/Generated/EngineExpectation.swift`.
  - `postBuildScripts` "Embed engine", running `"${SRCROOT}/scripts/embed-engine.sh"`, with `basedOnDependencyAnalysis: false` and output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/engine/VERSION`.
  - The optional source `RoomForMac/Generated/EngineExpectation.swift`, listed once (see the Interface issue).
  - Relies on Task 1's `ENABLE_USER_SCRIPT_SANDBOXING: NO`. With sandboxing on, the copy into the app fails with `Operation not permitted`.
- `app_bundle.bats` implements every check listed in the research:
  - strict deep verify;
  - `lipo -archs` of the app executable and helpers is `x86_64 arm64` when `EXPECT_UNIVERSAL=1`;
  - the helper identifiers are exactly `com.roomformac.app.engine.<tool>`;
  - the helpers' `Authority` lines equal the app's (or both are ad-hoc);
  - the symlinks point into `../../../Helpers/`;
  - `cmp build/engine/VERSION` against the bundled `VERSION`;
  - the bundled `engine/LICENSE` equals `vendor/mole/LICENSE`;
  - `status-go --json` exits 0 and prints `"cpu"`.

  It also checks that `Contents/Helpers` holds exactly the two tools and that no Mach-O file is left under `Contents/Resources`. An `APP` that is not a bundle fails `setup_file` instead of skipping.
- `EmbeddedEngineTests` (app-hosted Swift Testing):
  - `EngineInstallation.bundled()` succeeds, and its `root.path` ends with `RoomForMac.app/Contents/Resources/engine`.
  - `installation.version.moleTag == EngineExpectation.moleTag`, and the same for commit, patch hash and count.
  - The helper at `Bundle.main.bundleURL/Contents/Helpers/status-go` exists and is executable.
  - `engine/bin/<tool>` is a symlink to `../../../Helpers/<tool>` for both tools.
  - Both tools start from the app process: `-h` through `MoleRunner`, with the environment from `variables(for:)`, prints usage starting `Usage: mo `. `-h` exits before any disk scan or Apple event, so the test never triggers a prompt. `--json` would ask Finder for free space.
- Never run two engine builds at once (Global Constraints). Let each `bats scripts/tests/build_engine.bats` run finish before starting an `xcodebuild`, and the reverse: a stale engine makes the Xcode build run `build-engine.sh`, and both re-clone `build/engine-src`.
- Verify:
  - `shellcheck` and `shfmt` are clean on the new scripts.
  - `bats scripts/tests/build_engine.bats` is green.
  - An `xcodebuild … -scheme RoomForMacUnit test` run is green.
  - A Release build (`-configuration Release -destination "generic/platform=macOS"`) followed by `APP=<path> EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats` is green.
  - A second no-op build prints "Engine already embedded" and "Engine is up to date".

All commands run from the repository root.

- [ ] **Step 1: Write the failing engine build checks** — replace `scripts/tests/build_engine.bats`

The first six tests are unchanged. The ten new ones cover the builder hash, the license and the two "Prepare engine" scripts. Those scripts only read the engine that `setup_file` built, so the file still builds the engine once.

```bash
#!/usr/bin/env bats
# Engine build checks. Builds once per file into a temporary output directory,
# then checks the two Xcode "Prepare engine" scripts against that engine.

setup_file() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ENGINE_OUT="$BATS_FILE_TMPDIR/engine"
    export ROOT ENGINE_OUT
    if ! "$ROOT/scripts/build-engine.sh" > "$BATS_FILE_TMPDIR/build.log" 2>&1; then
        cat "$BATS_FILE_TMPDIR/build.log" >&2
        return 1
    fi
}

@test "engine contains the scripts, libraries and Go binaries RoomForMac runs" {
    [ -x "$ENGINE_OUT/mole" ]
    [ -x "$ENGINE_OUT/bin/clean.sh" ]
    [ -x "$ENGINE_OUT/bin/uninstall.sh" ]
    [ -f "$ENGINE_OUT/lib/core/common.sh" ]
    [ -x "$ENGINE_OUT/bin/analyze-go" ]
    [ -x "$ENGINE_OUT/bin/status-go" ]
}

@test "Go binaries are universal" {
    run lipo -archs "$ENGINE_OUT/bin/analyze-go"
    [[ "$output" == *arm64* && "$output" == *x86_64* ]] || return 1
    run lipo -archs "$ENGINE_OUT/bin/status-go"
    [[ "$output" == *arm64* && "$output" == *x86_64* ]]
}

@test "the host sudo shim always fails" {
    run "$ENGINE_OUT/host-bin/sudo" -n true
    [ "$status" -eq 1 ]
}

@test "VERSION records the pinned Mole release and patch set" {
    run cat "$ENGINE_OUT/VERSION"
    [[ "$output" == *"mole_tag=V1.56.0"* ]] || return 1
    [[ "$output" == *"mole_commit=239c90d"* ]] || return 1
    [[ "$output" == *"patch_count="* ]]
}

@test "the status binary prints a JSON snapshot" {
    run "$ENGINE_OUT/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}

@test "patched engine ships the host integration helpers" {
    [ -f "$ENGINE_OUT/lib/core/host.sh" ]
    grep -q '^mole_selection_allows()' "$ENGINE_OUT/lib/core/host.sh"
    grep -q '^mole_auth_disabled()' "$ENGINE_OUT/lib/core/sudo.sh"
}

@test "VERSION records the builder hash" {
    local builder
    builder="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"
    run grep -A 1 '^patch_count=' "$ENGINE_OUT/VERSION"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "builder_sha256=$builder" ]
}

@test "engine ships Mole's license" {
    cmp "$ROOT/vendor/mole/LICENSE" "$ENGINE_OUT/LICENSE"
}

@test "ensure-engine accepts an engine built from the current inputs" {
    run env RFM_ENGINE_DIR="$ENGINE_OUT" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "Engine is up to date: $ENGINE_OUT" ]
}

@test "ensure-engine treats an engine without builder_sha256 as stale" {
    mkdir "$BATS_TEST_TMPDIR/old"
    grep -v '^builder_sha256=' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/old/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/old" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]]
}

@test "ensure-engine treats an engine from another build script as stale" {
    mkdir "$BATS_TEST_TMPDIR/other"
    sed 's/^builder_sha256=.*/builder_sha256=0000/' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/other/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/other" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]]
}

@test "ensure-engine refuses to build a missing engine when builds are off" {
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/none" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]] || return 1
    [ ! -e "$BATS_TEST_TMPDIR/none" ]
}

@test "engine-expectation writes the engine's VERSION as Swift" {
    local out="$BATS_TEST_TMPDIR/Generated/EngineExpectation.swift"
    run env RFM_ENGINE_DIR="$ENGINE_OUT" SCRIPT_OUTPUT_FILE_0="$out" "$ROOT/scripts/engine-expectation.sh"
    [ "$status" -eq 0 ]
    value() { sed -n "s/^$1=//p" "$ENGINE_OUT/VERSION"; }
    cat > "$BATS_TEST_TMPDIR/expected.swift" << SWIFT
// Generated by scripts/engine-expectation.sh from build/engine/VERSION. Do not edit.
enum EngineExpectation {
    static let moleTag = "$(value mole_tag)"
    static let moleCommit = "$(value mole_commit)"
    static let patchesSHA256 = "$(value patches_sha256)"
    static let patchCount = $(value patch_count)
}
SWIFT
    diff "$BATS_TEST_TMPDIR/expected.swift" "$out"
    xcrun swiftc -parse-as-library -typecheck "$out"
}

@test "engine-expectation rewrites the Swift file only when VERSION changes" {
    local out="$BATS_TEST_TMPDIR/EngineExpectation.swift" before
    mkdir "$BATS_TEST_TMPDIR/engine"
    cp "$ENGINE_OUT/VERSION" "$BATS_TEST_TMPDIR/engine/VERSION"
    export RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$out"
    "$ROOT/scripts/engine-expectation.sh"
    touch -t 200001010000 "$out"
    before="$(stat -f %m "$out")"
    run "$ROOT/scripts/engine-expectation.sh"
    [ "$output" = "Engine expectation unchanged" ]
    [ "$(stat -f %m "$out")" = "$before" ]
    sed -i '' 's/^patch_count=.*/patch_count=42/' "$RFM_ENGINE_DIR/VERSION"
    run "$ROOT/scripts/engine-expectation.sh"
    [[ "$output" == "Engine expectation updated"* ]] || return 1
    grep -qx '    static let patchCount = 42' "$out"
}

@test "engine-expectation fails clearly when VERSION lacks a key" {
    mkdir "$BATS_TEST_TMPDIR/engine"
    grep -v '^patches_sha256=' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/engine/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$BATS_TEST_TMPDIR/out.swift" \
        "$ROOT/scripts/engine-expectation.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no patches_sha256"* ]] || return 1
    [ ! -e "$BATS_TEST_TMPDIR/out.swift" ]
}

@test "engine-expectation rejects values it would have to escape" {
    local bad
    mkdir "$BATS_TEST_TMPDIR/engine"
    for bad in 'mole_tag=V1"56' 'mole_commit=239c\n90d' 'patch_count=5x'; do
        {
            grep -v "^${bad%%=*}=" "$ENGINE_OUT/VERSION"
            printf '%s\n' "$bad"
        } > "$BATS_TEST_TMPDIR/engine/VERSION"
        run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$BATS_TEST_TMPDIR/out.swift" \
            "$ROOT/scripts/engine-expectation.sh"
        [ "$status" -eq 1 ]
        [[ "$output" == *"${bad%%=*}"* ]] || return 1
    done
    [ ! -e "$BATS_TEST_TMPDIR/out.swift" ]
}
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `bats scripts/tests/build_engine.bats`
Expected: FAIL. `1..16`: tests 1–6 `ok`, tests 7–16 `not ok`.
- 7: `[ "${lines[1]}" = "builder_sha256=…" ]` failed, because `VERSION` has no builder line.
- 8: `cmp: …/engine/LICENSE: No such file or directory`.
- 9–16: the scripts do not exist yet. bats also prints `BW01: run's command … exited with code 127`.

The engine build inside `setup_file` takes about a minute.

- [ ] **Step 3: Record the builder hash and ship Mole's license** — modify `scripts/build-engine.sh`

Find:
```bash
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, VERSION
```
Replace with:
```bash
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, LICENSE, VERSION
```

Find:
```bash
chmod +x "$OUT/host-bin/sudo"

cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$patches_sha
patch_count=${#patches[@]}
VERSION
```
Replace with:
```bash
chmod +x "$OUT/host-bin/sudo"

# GPL-3.0: the engine ships with Mole's license text.
cp "$VENDOR/LICENSE" "$OUT/LICENSE"

# VERSION is written last, so an interrupted build never looks complete to
# scripts/ensure-engine.sh. builder_sha256 lets it notice edits to this script.
builder_sha="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"
cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$patches_sha
patch_count=${#patches[@]}
builder_sha256=$builder_sha
VERSION
```

The complete file after the change:

```bash
#!/bin/bash
# Build the patched Mole engine that RoomForMac bundles.
#
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, LICENSE, VERSION
# Source:  build/engine-src: pinned Mole with patches/mole applied (kept for tests)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/mole"
PATCH_DIR="$ROOT/patches/mole"
SRC="$ROOT/build/engine-src"
OUT="${ENGINE_OUT:-$ROOT/build/engine}"
GIT_ID=(-c user.name="RoomForMac Build" -c user.email="build@roomformac.invalid")

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in git go lipo shasum; do
    command -v "$tool" > /dev/null 2>&1 || die "$tool is required (brew bundle --file Brewfile)"
done
[[ -e "$VENDOR/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"

commit="$(git -C "$VENDOR" rev-parse HEAD)"
tag="$(git -C "$VENDOR" describe --tags --exact-match 2> /dev/null || echo untagged)"

rm -rf "$SRC"
mkdir -p "$ROOT/build"
git clone --quiet --no-local "$(git -C "$VENDOR" rev-parse --absolute-git-dir)" "$SRC"
git -C "$SRC" checkout --quiet --detach "$commit"

patches=()
for patch in "$PATCH_DIR"/*.patch; do
    if [[ -f "$patch" ]]; then
        patches+=("$patch")
    fi
done
patches_sha="none"
if [[ ${#patches[@]} -gt 0 ]]; then
    git -C "$SRC" "${GIT_ID[@]}" am --quiet --3way "${patches[@]}"
    patches_sha="$(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
fi

build_universal() {
    local name="$1" package="$2" arch
    for arch in arm64 amd64; do
        (cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w" -o "bin/$name.$arch" "$package")
    done
    lipo -create -output "$SRC/bin/$name" "$SRC/bin/$name.arm64" "$SRC/bin/$name.amd64"
    rm -f "$SRC/bin/$name.arm64" "$SRC/bin/$name.amd64"
}
build_universal analyze-go ./cmd/analyze
build_universal status-go ./cmd/status

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/host-bin"
cp "$SRC/mole" "$OUT/mole"
cp "$SRC"/bin/*.sh "$OUT/bin/"
cp "$SRC/bin/analyze-go" "$SRC/bin/status-go" "$OUT/bin/"
cp -R "$SRC/lib" "$OUT/lib"
chmod +x "$OUT/mole" "$OUT"/bin/*

cat > "$OUT/host-bin/sudo" << 'SHIM'
#!/bin/bash
# RoomForMac runs the engine without administrator access. Every sudo call
# fails at once, so neither a password prompt nor a cached ticket is used.
exit 1
SHIM
chmod +x "$OUT/host-bin/sudo"

# GPL-3.0: the engine ships with Mole's license text.
cp "$VENDOR/LICENSE" "$OUT/LICENSE"

# VERSION is written last, so an interrupted build never looks complete to
# scripts/ensure-engine.sh. builder_sha256 lets it notice edits to this script.
builder_sha="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"
cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$patches_sha
patch_count=${#patches[@]}
builder_sha256=$builder_sha
VERSION

printf 'Engine ready: %s (%s, %d patches)\n' "$OUT" "$tag" "${#patches[@]}"
```

- [ ] **Step 4: Write `scripts/ensure-engine.sh`**

```bash
#!/bin/bash
# Xcode "Prepare engine" phase, step 1: make sure the engine matches the
# pinned Mole commit, patches/mole and scripts/build-engine.sh, and rebuild it
# only when one of them changed. About 0.1 s when nothing changed.
#
#   RFM_ENGINE_DIR       engine directory (default build/engine; Xcode sets it)
#   RFM_NO_ENGINE_BUILD  1 = fail instead of building a missing or stale engine

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${RFM_ENGINE_DIR:-$ROOT/build/engine}"
# Xcode started from the Dock has no Homebrew on PATH, and build-engine.sh
# needs go from there.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ -e "$ROOT/vendor/mole/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"

expected_commit="$(git -C "$ROOT/vendor/mole" rev-parse HEAD)"
patches=()
for patch in "$ROOT"/patches/mole/*.patch; do
    if [[ -f "$patch" ]]; then
        patches+=("$patch")
    fi
done
expected_sha="none"
if [[ ${#patches[@]} -gt 0 ]]; then
    expected_sha="$(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
fi
expected_builder="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"

value() { sed -n "s/^$1=//p" "$ENGINE/VERSION" 2> /dev/null || true; }
current="$(value mole_commit) $(value patches_sha256) $(value builder_sha256)"
if [[ "$current" == "$expected_commit $expected_sha $expected_builder" ]]; then
    echo "Engine is up to date: $ENGINE"
    exit 0
fi
if [[ "${RFM_NO_ENGINE_BUILD:-0}" == "1" ]]; then
    die "$ENGINE is missing or stale; run scripts/build-engine.sh"
fi
echo "Engine is missing or stale; building it (about a minute)"
ENGINE_OUT="$ENGINE" "$ROOT/scripts/build-engine.sh"
```

- [ ] **Step 5: Write `scripts/engine-expectation.sh`**

```bash
#!/bin/bash
# Xcode "Prepare engine" phase, step 2: write the engine this build expects,
# read from $RFM_ENGINE_DIR/VERSION, to $SCRIPT_OUTPUT_FILE_0 as Swift. The
# app's launch check compares the bundled engine with it.
#
# The file is rewritten only when its content changes, so a no-op build
# compiles nothing.

set -euo pipefail

version_file="${RFM_ENGINE_DIR:?}/VERSION"
out="${SCRIPT_OUTPUT_FILE_0:?}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ -f "$version_file" ]] || die "no engine at ${RFM_ENGINE_DIR}; run scripts/build-engine.sh"

# The value of key $1. The last one wins, as in MoleEngine's EngineVersion.
# Values become Swift literals unescaped, so quotes and backslashes are refused.
value() {
    local found
    found="$(sed -n "s/^$1=//p" "$version_file" | tail -n 1)"
    [[ -n "$found" ]] || die "$version_file has no $1"
    case "$found" in
        *'"'* | *\\*) die "$1 in $version_file contains a quote or a backslash: $found" ;;
    esac
    printf '%s\n' "$found"
}

tag="$(value mole_tag)"
commit="$(value mole_commit)"
patches_sha="$(value patches_sha256)"
count="$(value patch_count)"
case "$count" in
    *[!0-9]*) die "patch_count in $version_file is not a number: $count" ;;
esac

mkdir -p "$(dirname "$out")"
tmp="$(mktemp "$out.XXXXXX")"
chmod 644 "$tmp"
cat > "$tmp" << SWIFT
// Generated by scripts/engine-expectation.sh from build/engine/VERSION. Do not edit.
enum EngineExpectation {
    static let moleTag = "$tag"
    static let moleCommit = "$commit"
    static let patchesSHA256 = "$patches_sha"
    static let patchCount = $count
}
SWIFT
if cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    echo "Engine expectation unchanged"
else
    mv -f "$tmp" "$out"
    echo "Engine expectation updated: $tag, $count patches"
fi
```

The header comment names `build/engine/VERSION` whatever `RFM_ENGINE_DIR` is, so the generated file matches the Interfaces block exactly. `mktemp` creates the temporary file next to the output, so the final `mv` is atomic.

- [ ] **Step 6: Make the scripts executable, lint them and run the checks**

```bash
chmod +x scripts/ensure-engine.sh scripts/engine-expectation.sh
shellcheck scripts/*.sh && shfmt -d -i 4 -ci -sr scripts/*.sh scripts/tests/*.bats
python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats
```
Expected: no output from `shellcheck` and `shfmt`, then `bats-assertion-audit-ok files=1`.

Run: `bats scripts/tests/build_engine.bats`
Expected: PASS, `1..16` and all 16 `ok`, in about a minute.

Run: `RFM_NO_ENGINE_BUILD=1 scripts/ensure-engine.sh`
Expected: `error: …/build/engine is missing or stale; run scripts/build-engine.sh` and exit 1. The `build/engine` left by Plan 1 has no `builder_sha256`, and the first Xcode build in Step 14 rebuilds it. If you already rebuilt `build/engine` after Step 3, the output is `Engine is up to date: …/build/engine` instead.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-engine.sh scripts/ensure-engine.sh scripts/engine-expectation.sh scripts/tests/build_engine.bats
git commit -F - << 'EOF'
build: stamp-check the engine and generate its expected version

build-engine.sh now records builder_sha256 in VERSION and ships Mole's
LICENSE with the engine. ensure-engine.sh rebuilds build/engine only when
the pinned commit, the patches or the build script changed, and
engine-expectation.sh writes the expected VERSION as Swift for the
launch check.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

- [ ] **Step 8: Write the failing app-hosted engine test** — `RoomForMacTests/EmbeddedEngineTests.swift`

The unit tests are hosted in `RoomForMac.app`, so `Bundle.main` is the app. The test target does not link `MoleEngine`: `import MoleEngine` resolves through the host app, as the research probe verified.

```swift
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// The engine that the "Embed engine" build phase put into the test host,
/// which is this build's RoomForMac.app, checked from inside the app process.
@Suite("Embedded engine")
struct EmbeddedEngineTests {
    @Test func theBundledEngineLivesInTheAppResources() throws {
        let installation = try EngineInstallation.bundled()
        #expect(installation.root.path.hasSuffix("RoomForMac.app/Contents/Resources/engine"))
    }

    @Test func theBundledEngineIsTheOneThisBuildExpects() throws {
        let version = try EngineInstallation.bundled().version
        #expect(version.moleTag == EngineExpectation.moleTag)
        #expect(version.moleCommit == EngineExpectation.moleCommit)
        #expect(version.patchesSHA256 == EngineExpectation.patchesSHA256)
        #expect(version.patchCount == EngineExpectation.patchCount)
    }

    @Test func theStatusHelperIsAnExecutableInContentsHelpers() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/status-go")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test(arguments: ["analyze-go", "status-go"])
    func engineBinLinksTheToolToContentsHelpers(tool: String) throws {
        let installation = try EngineInstallation.bundled()
        let link = installation.root.appending(path: "bin/\(tool)")
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(tool)")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == "../../../Helpers/\(tool)")
        #expect(link.resolvingSymlinksInPath().path == helper.resolvingSymlinksInPath().path)
    }

    /// `-h` prints usage and exits 0 without touching the disk or sending
    /// Apple events, so this proves the signed helper starts from the app.
    @Test(arguments: ["analyze-go", "status-go"])
    func theToolStartsFromTheApp(tool: String) async throws {
        let installation = try EngineInstallation.bundled()
        let command = EngineCommand(
            executable: installation.root.appending(path: "bin/\(tool)"),
            arguments: ["-h"],
            environment: EngineEnvironment.current().variables(for: installation),
            output: .stdout,
            timeout: .seconds(10)
        )
        let usage = String(decoding: try await MoleRunner().collect(command), as: UTF8.self)
        #expect(usage.hasPrefix("Usage: mo "))
    }
}
```

- [ ] **Step 9: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/EmbeddedEngineTests`
Expected: FAIL at compile time: `EmbeddedEngineTests.swift:17:36: error: cannot find 'EngineExpectation' in scope`, the same error for lines 18–20, then `** TEST FAILED **`. If Task 1's `project.yml` already lists the optional `RoomForMac/Generated/EngineExpectation.swift` source, the build fails earlier, with `Build input file cannot be found: '…/RoomForMac/Generated/EngineExpectation.swift'`. The cause is the same: nothing generates the file yet.

- [ ] **Step 10: Write the bundle checks** — `scripts/tests/app_bundle.bats`

```bash
#!/usr/bin/env bats
# Checks a built RoomForMac.app: the embedded engine, its helpers' signatures
# and the architectures. Run it after a build:
#
#   APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 \
#       bats scripts/tests/app_bundle.bats
#
# Without APP every test is skipped, so `bats scripts/tests` still passes.

setup_file() {
    if [[ -z "${APP:-}" ]]; then
        skip "set APP=/path/to/RoomForMac.app to check a built app"
    fi
    if [[ ! -d "$APP/Contents" ]]; then
        echo "APP=$APP is not an app bundle" >&2
        return 1
    fi
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    APP="${APP%/}"
    ENGINE="$APP/Contents/Resources/engine"
    HELPERS="$APP/Contents/Helpers"
    SOURCE_ENGINE="${RFM_ENGINE_DIR:-$ROOT/build/engine}"
    export ROOT APP ENGINE HELPERS SOURCE_ENGINE
}

# "adhoc" for an ad-hoc signature, otherwise the certificate chain.
signer() {
    local info
    info="$(codesign --display --verbose=2 "$1" 2>&1)" || return 1
    if grep -qx 'Signature=adhoc' <<< "$info"; then
        echo adhoc
    else
        grep '^Authority=' <<< "$info"
    fi
}

@test "the app passes strict deep signature verification" {
    run codesign --verify --deep --strict --verbose=2 "$APP"
    [ "$status" -eq 0 ]
}

@test "the app and the engine helpers are universal" {
    if [[ "${EXPECT_UNIVERSAL:-0}" != "1" ]]; then
        skip "set EXPECT_UNIVERSAL=1 to check a Release build"
    fi
    local binary
    for binary in "$APP/Contents/MacOS/RoomForMac" "$HELPERS/analyze-go" "$HELPERS/status-go"; do
        run lipo -archs "$binary"
        [ "$status" -eq 0 ]
        [ "$output" = "x86_64 arm64" ]
    done
}

@test "Contents/Helpers holds exactly the two Go tools" {
    run ls "$HELPERS"
    [ "$status" -eq 0 ]
    [ "$output" = $'analyze-go\nstatus-go' ]
}

@test "each helper is signed as com.roomformac.app.engine.<tool>" {
    local tool
    for tool in analyze-go status-go; do
        run codesign --display --verbose=2 "$HELPERS/$tool"
        [ "$status" -eq 0 ]
        grep -qx "Identifier=com.roomformac.app.engine.$tool" <<< "$output"
    done
}

@test "the helpers are signed by the app's identity" {
    local app_signer tool
    app_signer="$(signer "$APP")"
    [ -n "$app_signer" ]
    for tool in analyze-go status-go; do
        [ "$(signer "$HELPERS/$tool")" = "$app_signer" ]
    done
}

@test "engine/bin links each Go tool into Contents/Helpers" {
    local tool
    for tool in analyze-go status-go; do
        [ -L "$ENGINE/bin/$tool" ]
        [ "$(readlink "$ENGINE/bin/$tool")" = "../../../Helpers/$tool" ]
        [ -x "$ENGINE/bin/$tool" ]
    done
}

@test "no Mach-O code is left in Contents/Resources" {
    local file
    while IFS= read -r -d '' file; do
        if lipo -archs "$file" > /dev/null 2>&1; then
            echo "Mach-O in Resources: $file" >&2
            return 1
        fi
    done < <(find "$APP/Contents/Resources" -type f -print0)
}

@test "the bundled VERSION is the engine this build embedded" {
    cmp "$SOURCE_ENGINE/VERSION" "$ENGINE/VERSION"
}

@test "the bundled engine ships Mole's license" {
    cmp "$ROOT/vendor/mole/LICENSE" "$ENGINE/LICENSE"
}

@test "the bundled status tool prints a JSON snapshot" {
    run "$ENGINE/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}
```

`signer` prints `adhoc` for an ad-hoc signature, which has no `Authority` lines. Otherwise it prints the certificate chain. With the stable identity from Task 16, the comparison checks that the app and its helpers share that chain.

- [ ] **Step 11: Run the bundle checks to verify they fail**

Run: `bats scripts/tests/app_bundle.bats`
Expected: `1..10`, every test `ok … # skip set APP=/path/to/RoomForMac.app to check a built app`.

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`: the app target compiles, and only the test target refers to `EngineExpectation`. If the Interface issue applies, this fails with `Build input file cannot be found` instead. In that case skip the next command, since Step 16 runs it.

Run: `APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats`
Expected: FAIL.
- `ok`: 1 (strict verify) and 7 (no Mach-O in `Resources`); nothing is embedded yet.
- `not ok`: 2–6 and 8–10, because there is no `Contents/Helpers` and no `Contents/Resources/engine`.

- [ ] **Step 12: Write `scripts/embed-engine.sh`**

```bash
#!/bin/bash
# Xcode "Embed engine" phase of the RoomForMac target. Xcode signs the app
# after every build phase, so this runs before the app's CodeSign step.
#
#   $RFM_ENGINE_DIR (build/engine)  ->  Contents/Resources/engine
#   engine/bin Mach-O tools         ->  Contents/Helpers, symlinked back into engine/bin
#
# Each tool is signed with the identity Xcode signs the app with, as
# <bundle id>.engine.<tool>. Contents/Helpers belongs to this phase.

set -euo pipefail

src="${RFM_ENGINE_DIR:?}"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/engine"
helpers="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH:?}/Helpers"
stamp="${DERIVED_FILE_DIR:?}/embed-engine.stamp"

if [[ ! -f "$src/VERSION" ]]; then
    echo "error: no engine at $src; run scripts/build-engine.sh" >&2
    exit 1
fi

# Skip when neither the engine, the signing inputs, the destination nor this
# script changed, so a no-op build leaves the signed bundle alone.
fingerprint="$({
    (cd "$src" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %z %m %p %Y')
    echo "${CODE_SIGNING_ALLOWED:-} ${EXPANDED_CODE_SIGN_IDENTITY:-} ${ENABLE_HARDENED_RUNTIME:-}"
    echo "${PRODUCT_BUNDLE_IDENTIFIER:-} $dest"
    cat "$0"
} | shasum -a 256)"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" && -f "$dest/VERSION" && -d "$helpers" ]]; then
    echo "Engine already embedded"
    exit 0
fi

rm -rf "$dest" "$helpers"
mkdir -p "$dest" "$helpers"
/usr/bin/ditto --norsrc --noextattr --noacl "$src" "$dest"

while IFS= read -r -d '' file; do
    if ! /usr/bin/lipo -archs "$file" > /dev/null 2>&1; then
        continue # a script: stays in Resources, sealed as a resource
    fi
    if [[ "$(dirname "$file")" != "$dest/bin" ]]; then
        echo "error: Mach-O outside engine/bin: $file" >&2
        exit 1
    fi
    name="$(basename "$file")"
    mv "$file" "$helpers/$name"
    ln -s "../../../Helpers/$name" "$file"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
        flags=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?}" --timestamp=none
            --identifier "${PRODUCT_BUNDLE_IDENTIFIER:?}.engine.$name")
        if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
            flags+=(--options runtime)
        fi
        /usr/bin/codesign "${flags[@]}" "$helpers/$name"
    fi
    echo "Embedded $name"
done < <(find "$dest" -type f -perm -u+x -print0)

# VERSION is this phase's declared output. Xcode re-signs the app only when a
# declared output changes, and ditto keeps the source mtime, so touch it.
touch "$dest/VERSION"
mkdir -p "$(dirname "$stamp")"
echo "$fingerprint" > "$stamp"
```

Run: `chmod +x scripts/embed-engine.sh && shellcheck scripts/embed-engine.sh && shfmt -d -i 4 -ci -sr scripts/embed-engine.sh`
Expected: no output.

- [ ] **Step 13: Add the engine phases to `project.yml`**

Make three edits in the `RoomForMac` target.

First, make its `sources` read exactly as below. If Task 1 already lists the second entry, keep one copy.
```yaml
    sources:
      - path: RoomForMac
        excludes:
          - Generated
      # Written by the "Prepare engine" phase before compiling; git-ignored.
      - path: RoomForMac/Generated/EngineExpectation.swift
        optional: true
```

Second, append to the target's `settings: base:`, after `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`:
```yaml
        # Build scripts only: where build/engine lives. The app never reads it.
        RFM_ENGINE_DIR: $(SRCROOT)/build/engine
```

Third, insert these two keys after the target's `settings:` block and before its `scheme:` key:
```yaml
    preBuildScripts:
      # Rebuilds build/engine only when its inputs changed (~0.1 s otherwise),
      # then records the engine this build expects as Swift.
      - name: Prepare engine
        script: '"${SRCROOT}/scripts/ensure-engine.sh" && "${SRCROOT}/scripts/engine-expectation.sh"'
        shell: /bin/bash
        showEnvVars: false
        basedOnDependencyAnalysis: false
        outputFiles:
          - $(SRCROOT)/RoomForMac/Generated/EngineExpectation.swift
    postBuildScripts:
      # Copies build/engine into the app, moves the Go tools to Contents/Helpers
      # and signs them. Runs before Xcode signs the app.
      - name: Embed engine
        script: '"${SRCROOT}/scripts/embed-engine.sh"'
        shell: /bin/bash
        showEnvVars: false
        basedOnDependencyAnalysis: false
        outputFiles:
          - $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/engine/VERSION
```

Do not add `CODE_SIGN_*` or `DEVELOPMENT_TEAM` anywhere. The phases sign with whatever `Config/Signing.xcconfig` resolves to.

Run: `xcodegen generate && grep -E 'name = "(Prepare engine|Embed engine)"' RoomForMac.xcodeproj/project.pbxproj`
Expected: `Created project at …/RoomForMac.xcodeproj`, then the two lines `name = "Embed engine";` and `name = "Prepare engine";`. XcodeGen places "Prepare engine" before `Sources` and "Embed engine" after `Frameworks`.

- [ ] **Step 14: Run the engine test to verify it passes**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/EmbeddedEngineTests`
Expected: PASS. Plan 1's `build/engine` has no builder hash, so this first build also rebuilds the engine (a minute or two). The log shows, in order:
```
Engine is missing or stale; building it (about a minute)
Engine ready: …/build/engine (V1.56.0, 5 patches)
Engine expectation updated: V1.56.0, 5 patches
Embedded analyze-go
Embedded status-go
```
It ends with `✔ Suite "Embedded engine" passed`, `✔ Test run with 5 tests in 1 suite passed` (7 test cases) and `** TEST SUCCEEDED **`. If `build/engine` was rebuilt after Step 3, the first line is `Engine is up to date: …/build/engine` instead, and there is no `Engine ready` line.

- [ ] **Step 15: Run the whole unit scheme**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`
Expected: `** TEST SUCCEEDED **`, with the "Embedded engine" suite and Task 1's suites all passing. This build changes nothing, so the phases print `Engine is up to date: …/build/engine`, `Engine expectation unchanged` and `Engine already embedded`.
- Xcode adds the note `Run script build phase 'Prepare engine' will be run during every build because the option to run the script phase "Based on dependency analysis" is unchecked`, and the same for "Embed engine". This is intended.
- The only `warning:` line is `appintentsmetadataprocessor … Metadata extraction skipped, no AppIntents.framework dependency found`, from Xcode's own tooling.

- [ ] **Step 16: Build Release and check the bundle**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build`
Expected: `Engine is up to date: …`, `Engine expectation unchanged`, `Embedded analyze-go`, `Embedded status-go`, then `** BUILD SUCCEEDED **`.

Run: `APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats`
Expected: PASS, `1..10` and all 10 `ok`. `status-go --json` asks Finder for the startup disk's free space. On a desktop Mac the terminal may therefore be asked once for permission to control Finder, and the test passes whatever the answer. Rosetta is not needed: the check only reads the x86_64 slices with `lipo`.

Run the same Release build command a second time.
Expected: `Engine is up to date: …`, `Engine expectation unchanged`, `Engine already embedded`, no `CodeSign …/RoomForMac.app` step, and `** BUILD SUCCEEDED **`.

Run: `codesign --verify --deep --strict --verbose=2 build/DerivedData/Build/Products/Release/RoomForMac.app && time scripts/ensure-engine.sh`
Expected: `valid on disk`, `satisfies its Designated Requirement`, then `Engine is up to date: …/build/engine` in about 0.15 s total.

- [ ] **Step 17: Lint everything and check the working tree**

```bash
shellcheck scripts/*.sh && shfmt -d -i 4 -ci -sr scripts/*.sh scripts/tests/*.bats
python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats
git status --short
```
Expected:
- `bats-assertion-audit-ok files=2`.
- `git status` lists only ` M project.yml`, `?? RoomForMacTests/EmbeddedEngineTests.swift`, `?? scripts/embed-engine.sh` and `?? scripts/tests/app_bundle.bats`.
- `build/` and `RoomForMac/Generated/` are git-ignored.

- [ ] **Step 18: Commit**

```bash
git add project.yml scripts/embed-engine.sh scripts/tests/app_bundle.bats RoomForMacTests/EmbeddedEngineTests.swift
git commit -F - << 'EOF'
build: embed the engine in RoomForMac.app and check the bundle

Two build phases wire the engine into the app. "Prepare engine" runs the
stamp check and writes EngineExpectation.swift. "Embed engine" copies
build/engine into Contents/Resources/engine, moves the Go tools to
Contents/Helpers behind relative symlinks and signs them with the app's
identity as com.roomformac.app.engine.<tool>. app_bundle.bats checks a
built app, and EmbeddedEngineTests checks the engine from inside it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 3: Engine health check, error presentation and the blocking problem card

**Files:**
- Create: `RoomForMac/Engine/EngineProblem.swift`, `RoomForMac/Engine/EngineHealthCheck.swift`, `RoomForMac/Engine/ErrorPresentation.swift`, `RoomForMac/Engine/EngineProblemView.swift`, `RoomForMacTests/Support/TemporaryDirectory.swift`, `RoomForMacTests/Support/EngineLayout.swift`, `RoomForMacTests/Support/FakeEngineRunner.swift`, `RoomForMacTests/EngineHealthCheckTests.swift`, `RoomForMacTests/ErrorPresentationTests.swift`
- Create (added; the Requirements below already put it in this task, and Task 7 lists it under Modify): `RoomForMac/App/AccessibilityID.swift`
- Modify (added; the String Catalog grows every task): `RoomForMac/Resources/Localizable.xcstrings`

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
- Added by this task (internal to this task; later tasks may use them but nothing depends on them yet):
  ```swift
  extension EngineFingerprint {
      var summary: String { get }   // "tag=V1.56.0 commit=<40-hex> patches_sha256=<hex> patch_count=5"; data, not prose
  }
  extension ErrorPresentation {
      static func appVersion(info: [String: Any]?) -> String   // "0.1.0 (1)"; "?" for a missing key
      static func osVersion(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String   // "27.0.1"
  }
  extension EngineProblemView {
      static let downloadPage: URL  // https://github.com/gugag2003/RoomForMac/releases
  }
  // Exact test-support signatures:
  final class TemporaryDirectory: Sendable { let url: URL; init() throws }
  enum EngineLayout {
      static let requiredFiles: [String]            // mirrors MoleEngine's internal list (7 paths)
      static let executableFiles: Set<String>       // mirrors MoleEngine's internal list (5 paths)
      static func make(in directory: URL, version: [String: String]) throws -> URL   // root = directory/engine
      static func version(for fingerprint: EngineFingerprint) -> [String: String]   // the four VERSION keys
  }
  final class FakeEngineRunner: EngineRunning {
      init(responses: [String: Result<[String], EngineError>] = [:])   // an unscripted executable exits 0 with no output
      var commands: [EngineCommand] { get }                          // every command received, in order
  }
  ```

**Interface issue:** Global Constraints require an `accessibilityIdentifier` from `AccessibilityID` on every interactive element, but the skeleton's `AccessibilityID` has none for the "Open download page" button. Smallest fix: this task adds `static let engineProblemDownload = "engineProblem.download"`, and Task 7's `AccessibilityID` block keeps it. (`engineProblemDetails` goes on the `DisclosureGroup`, which is the interactive element.)

**Requirements:**
- `run()` checks in this order and stops at the first failure:
  1. `locate()`. An `EngineError.installationInvalid(m)` becomes `.installationInvalid(m)`. Any other error becomes `.installationInvalid(String(describing: error))`.
  2. `EngineFingerprint(installation.version)` must equal `expected`, otherwise `.versionMismatch(expected:found:)`. Nothing runs after a mismatch.
  3. A self-test runs `analyzeBinary`, then `statusBinary`. Each is `EngineCommand(executable:, arguments: ["-h"], environment: environment.variables(for: installation), output: .stdout, timeout: selfTestTimeout)`, collected through `runner.collect`. Any thrown error becomes `.selfTestFailed(tool:detail:)`, with `detail` from `ErrorPresentation(error).details`. The status tool does not run once the analyzer has failed.
  4. Each self-test runs in an unstructured `Task` that `run()` awaits. `MoleRunner` ends a cancelled stream without an error (research: MoleEngine API §9), so a self-test cut short by a cancelled caller would read as a pass. The unstructured task is not cancelled with the caller, and `selfTestTimeout` still bounds it.

  It returns the installation on success.
- `ErrorPresentation(_:)` matches the error in the order of this table. In the details column, "/" means a new line; each detail line is trimmed, and empty lines are dropped.

  | Error | `title` | `message` | `details` |
  |---|---|---|---|
  | `EngineProblem.installationInvalid(m)` | RoomForMac needs to be reinstalled | Some files RoomForMac needs are missing or damaged. | `m` |
  | `EngineProblem.versionMismatch(e, f)` | RoomForMac needs to be reinstalled | The engine inside RoomForMac doesn't match this version of the app. | `Expected: <e.summary>` / `Found: <f.summary>` |
  | `EngineProblem.selfTestFailed(tool, d)` | RoomForMac needs to be reinstalled | Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged. | `tool` / `d` |
  | `EngineError.installationInvalid(m)` | as `EngineProblem.installationInvalid(m)` | | |
  | `EngineError.launchFailed(exe, reason)` | The engine couldn't start | RoomForMac couldn't start `<last path component of exe>`. | `exe` / `reason` |
  | `EngineError.nonZeroExit(code, tail)` | The engine ran into a problem | It stopped with error code `<code>`. | `Exit code <code>` / `tail` |
  | `EngineError.terminatedBySignal(sig, tail)` | The engine stopped unexpectedly | macOS ended it before it finished. | `Signal <sig>` / `tail` |
  | `EngineError.timedOut` | The engine took too long | RoomForMac stopped it after waiting too long. Try again. | `timedOut` |
  | `EngineError.cancelled`, `CancellationError` | Stopped | The engine was stopped before it finished. | `cancelled` |
  | `EngineError.malformedOutput(m)` | The engine returned something unexpected | RoomForMac couldn't read the engine's answer. | `m` |
  | `DecodingError` | The engine returned something unexpected | RoomForMac couldn't read the engine's answer. | `<coding.path>: <debugDescription>` |
  | `CocoaError` where `isFileError` | RoomForMac couldn't use a file | RoomForMac couldn't use the file at `<path>`. With no path: RoomForMac couldn't use a file it needs. | `NSCocoaErrorDomain <code>` / `localizedDescription` |
  | anything else | Something went wrong | Its `LocalizedError.errorDescription`, else: RoomForMac ran into an unexpected problem. | `<domain> <code>` / `String(describing: error)` |

  - `DecodingError` is matched before `CocoaError`, because a `DecodingError` also bridges to `NSCocoaErrorDomain`.
  - The signal and exit code stay in `details` even when the stderr tail is empty. A helper killed at exec therefore still shows "Signal 9".
  - Every title, message and label goes through `String(localized:)`. Engine output, paths and fingerprints are data and are interpolated as is.
- `diagnostics(appVersion:osVersion:)` returns these lines: "RoomForMac diagnostics", "Title: …", "Message: …", "Details:", the details, "App <appVersion>", "macOS <osVersion>" and "Expected engine: <`EngineFingerprint.expected.summary`>". Every label is localized. It adds no file paths of its own; only `details` can carry one.
- `EngineProblemView`:
  - A full-window card, titled "Reinstall RoomForMac", with the message. Until Tasks 4–5 land it uses plain SwiftUI styling: `Color(nsColor: .windowBackgroundColor)` behind a card filled with `.fill.tertiary` (corner radius 20), and `.bordered` and `.borderedProminent` buttons. Task 5 swaps in `Palette.canvas`, `GlassCard` and `GlassButton`, and its brief says so.
  - A "Show details" `DisclosureGroup` showing `details` in a monospaced, selectable `Text` inside a `ScrollView` that is at most 180 pt tall.
  - A **Copy diagnostics** button (secondary; `GlassButton(.secondary)` from Task 5 on). It writes `diagnostics(appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary), osVersion: ErrorPresentation.osVersion())` to `NSPasteboard.general`, then reads "Copied" for 2 s.
  - An **Open download page** button (primary; `GlassButton(.primary)` from Task 5 on). It opens `https://github.com/gugag2003/RoomForMac/releases` through `@Environment(\.openURL)`.
  - Accessibility identifiers:
    - `engineProblemCard` on the card, which is an `.accessibilityElement(children: .contain)`;
    - `engineProblemDetails` on the disclosure;
    - `engineProblemCopy` and `engineProblemDownload` on the buttons.

    This task creates `RoomForMac/App/AccessibilityID.swift` with these four constants, and Task 7 extends it.
  - A `#Preview` of a version mismatch.
- Tests (Swift Testing, using the fakes):
  - a healthy layout with a matching version → `.success`;
  - a missing `bin/clean.sh` → `.installationInvalid("missing bin/clean.sh")`, and no self-test runs;
  - a locator that throws another error → `.installationInvalid(String(describing:))`;
  - a different `patches_sha256` → `.versionMismatch` carrying both fingerprints, and no self-test runs;
  - analyze self-test `nonZeroExit(code: 2, stderrTail: "boom")` → `.selfTestFailed(tool: "analyze-go", …)` whose detail contains "boom", and status never runs;
  - status self-test `terminatedBySignal(9, …)` → `.selfTestFailed(tool: "status-go", …)`;
  - self-test commands use `-h`, `.stdout`, the timeout and the environment from `variables(for:)`, analyzer first;
  - a cancelled caller with a runner that, like `MoleRunner`, ends silently on cancellation still gets `.selfTestFailed`, never `.success`;
  - `EngineFingerprint.expected` equals the generated `EngineExpectation`;
  - `ErrorPresentation` title and message for every `EngineProblem` and `EngineError` case, `CancellationError`, `DecodingError`, a file `CocoaError` with and without a path, a `LocalizedError`, and an unknown error;
  - `diagnostics` contains the app version, the macOS version and the expected fingerprint, and no home or bundle path of its own;
  - `appVersion(info:)` and `osVersion(_:)` formatting.
- The String Catalog gains this task's 37 keys, synced from the build (Step 13).

The self-test in point 4 is the only place in this task where the order of events matters. Everything else is a pure function of its inputs, so the tests inject `locate`, the runner and the environment and never touch the real bundle, the pasteboard or a real engine.

- [ ] **Step 1: Write the test support**

`RoomForMacTests/Support/TemporaryDirectory.swift`
```swift
import Foundation

/// A unique directory under the temporary folder, removed when the last reference goes away.
/// Store it in a suite property so it outlives every use inside a test.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "rfm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
```

`RoomForMacTests/Support/EngineLayout.swift`
```swift
import Foundation
@testable import RoomForMac

/// A fake engine directory that passes `EngineInstallation(root:)`.
enum EngineLayout {
    /// Mirrors MoleEngine's internal `EngineInstallation.requiredFiles`.
    static let requiredFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go",
        "lib/core/common.sh", "lib/core/host.sh", "host-bin/sudo",
    ]
    /// Mirrors MoleEngine's internal `EngineInstallation.executableFiles`.
    static let executableFiles: Set<String> = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go", "host-bin/sudo",
    ]

    /// Writes the seven required files and a `VERSION` with one `key=value` line per entry,
    /// verbatim and sorted by key, into `directory/engine`. Returns that root.
    static func make(in directory: URL, version: [String: String]) throws -> URL {
        let root = directory.appending(path: "engine")
        for relative in requiredFiles {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = executableFiles.contains(relative) ? 0o755 : 0o644
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/bash\nexit 0\n".utf8),
                attributes: [.posixPermissions: permissions]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let text = version.keys.sorted().map { "\($0)=\(version[$0] ?? "")\n" }.joined()
        try text.write(to: root.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        return root
    }

    /// The four `VERSION` keys that `EngineVersion` reads, for `fingerprint`.
    static func version(for fingerprint: EngineFingerprint) -> [String: String] {
        [
            "mole_tag": fingerprint.moleTag,
            "mole_commit": fingerprint.moleCommit,
            "patches_sha256": fingerprint.patchesSHA256,
            "patch_count": String(fingerprint.patchCount),
        ]
    }
}
```

`RoomForMacTests/Support/FakeEngineRunner.swift`
```swift
import Foundation
import MoleEngine
import Synchronization

/// Answers each command with a scripted result, chosen by the executable's last path
/// component ("analyze-go", "status-go", …), and records every command it receives.
/// An executable with no script exits 0 with no output.
final class FakeEngineRunner: EngineRunning {
    private let responses: [String: Result<[String], EngineError>]
    private let recorded = Mutex<[EngineCommand]>([])

    init(responses: [String: Result<[String], EngineError>] = [:]) {
        self.responses = responses
    }

    /// Every command received, in order.
    var commands: [EngineCommand] {
        recorded.withLock { $0 }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(command) }
        let response = responses[command.executable.lastPathComponent] ?? .success([])
        return AsyncThrowingStream { continuation in
            switch response {
            case .success(let lines):
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}
```

Suites keep a `TemporaryDirectory` in a stored property. Swift Testing makes a fresh suite instance for each test and keeps it alive for the whole test, so the directory cannot be removed early. A local `let` could be released after its last use.

- [ ] **Step 2: Write the failing presentation tests**

`RoomForMacTests/ErrorPresentationTests.swift`
```swift
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Error presentation")
struct ErrorPresentationTests {
    // MARK: Engine problems

    @Test func anInvalidInstallationAsksForAReinstall() {
        let presentation = ErrorPresentation(EngineProblem.installationInvalid("missing bin/clean.sh"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Some files RoomForMac needs are missing or damaged.")
        #expect(presentation.details == "missing bin/clean.sh")
    }

    @Test func aVersionMismatchShowsBothFingerprints() {
        let expected = EngineFingerprint(moleTag: "V1.56.0", moleCommit: "aaa", patchesSHA256: "bbb", patchCount: 5)
        let found = EngineFingerprint(moleTag: "V0.0.0", moleCommit: "ccc", patchesSHA256: "none", patchCount: 0)
        let presentation = ErrorPresentation(EngineProblem.versionMismatch(expected: expected, found: found))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "The engine inside RoomForMac doesn't match this version of the app.")
        #expect(presentation.details == """
        Expected: tag=V1.56.0 commit=aaa patches_sha256=bbb patch_count=5
        Found: tag=V0.0.0 commit=ccc patches_sha256=none patch_count=0
        """)
    }

    @Test func aFailedSelfTestNamesTheTool() {
        let presentation = ErrorPresentation(EngineProblem.selfTestFailed(tool: "status-go", detail: "Signal 9"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged.")
        #expect(presentation.details == "status-go\nSignal 9")
    }

    // MARK: Engine errors, one test per case

    @Test func engineInstallationInvalid() {
        let presentation = ErrorPresentation(EngineError.installationInvalid("not executable: bin/status-go"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Some files RoomForMac needs are missing or damaged.")
        #expect(presentation.details == "not executable: bin/status-go")
    }

    @Test func engineLaunchFailedNamesTheExecutable() {
        let error = EngineError.launchFailed(executable: "/Applications/RoomForMac.app/Contents/Resources/engine/bin/status-go", reason: "failed(13)")
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "The engine couldn't start")
        #expect(presentation.message == "RoomForMac couldn't start status-go.")
        #expect(presentation.details == "/Applications/RoomForMac.app/Contents/Resources/engine/bin/status-go\nfailed(13)")
    }

    @Test func engineNonZeroExitKeepsTheStderrTail() {
        let presentation = ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: "rm: /x: Operation not permitted\n"))
        #expect(presentation.title == "The engine ran into a problem")
        #expect(presentation.message == "It stopped with error code 2.")
        #expect(presentation.details == "Exit code 2\nrm: /x: Operation not permitted")
    }

    @Test func engineTerminatedBySignalKeepsTheStderrTail() {
        let presentation = ErrorPresentation(EngineError.terminatedBySignal(15, stderrTail: "stopping"))
        #expect(presentation.title == "The engine stopped unexpectedly")
        #expect(presentation.message == "macOS ended it before it finished.")
        #expect(presentation.details == "Signal 15\nstopping")
    }

    @Test func engineTerminatedBySignalWithoutOutputStillNamesTheSignal() {
        #expect(ErrorPresentation(EngineError.terminatedBySignal(9, stderrTail: "")).details == "Signal 9")
    }

    @Test func engineTimedOut() {
        let presentation = ErrorPresentation(EngineError.timedOut)
        #expect(presentation.title == "The engine took too long")
        #expect(presentation.message == "RoomForMac stopped it after waiting too long. Try again.")
        #expect(presentation.details == "timedOut")
    }

    @Test func engineCancelled() {
        let presentation = ErrorPresentation(EngineError.cancelled)
        #expect(presentation.title == "Stopped")
        #expect(presentation.message == "The engine was stopped before it finished.")
        #expect(presentation.details == "cancelled")
    }

    @Test func engineMalformedOutput() {
        let presentation = ErrorPresentation(EngineError.malformedOutput("no JSON array in output"))
        #expect(presentation.title == "The engine returned something unexpected")
        #expect(presentation.message == "RoomForMac couldn't read the engine's answer.")
        #expect(presentation.details == "no JSON array in output")
    }

    // MARK: Other errors

    @Test func taskCancellationReadsAsStopped() {
        #expect(ErrorPresentation(CancellationError()) == ErrorPresentation(EngineError.cancelled))
    }

    @Test func decodingErrorsAreUnexpectedAnswers() throws {
        struct Level: Decodable { let path: String }
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(Level.self, from: Data(#"{"path": 5}"#.utf8))
        }
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "The engine returned something unexpected")
        #expect(presentation.message == "RoomForMac couldn't read the engine's answer.")
        #expect(presentation.details.hasPrefix("path: "))
    }

    @Test func fileErrorsNameThePath() {
        let error = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/private/tmp/roomformac-engine-1/events.ndjson"])
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "RoomForMac couldn't use a file")
        #expect(presentation.message == "RoomForMac couldn't use the file at /private/tmp/roomformac-engine-1/events.ndjson.")
        #expect(presentation.details.hasPrefix("NSCocoaErrorDomain 257\n"))
    }

    @Test func fileErrorsWithoutAPathStillExplain() {
        let presentation = ErrorPresentation(CocoaError(.fileWriteOutOfSpace))
        #expect(presentation.title == "RoomForMac couldn't use a file")
        #expect(presentation.message == "RoomForMac couldn't use a file it needs.")
    }

    @Test func anyOtherErrorIsSomethingWentWrong() {
        struct Unexpected: Error {}
        let presentation = ErrorPresentation(Unexpected())
        #expect(presentation.title == "Something went wrong")
        #expect(presentation.message == "RoomForMac ran into an unexpected problem.")
        #expect(presentation.details.contains("Unexpected"))
    }

    @Test func aLocalizedErrorKeepsItsOwnDescription() {
        struct Described: LocalizedError {
            var errorDescription: String? { "The disk is not mounted." }
        }
        let presentation = ErrorPresentation(Described())
        #expect(presentation.title == "Something went wrong")
        #expect(presentation.message == "The disk is not mounted.")
    }

    // MARK: Diagnostics

    @Test func diagnosticsCarryTheVersionsAndTheExpectedEngine() {
        let presentation = ErrorPresentation(EngineProblem.selfTestFailed(tool: "analyze-go", detail: "Exit code 2\nboom"))
        let report = presentation.diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.0")
        let expected = EngineFingerprint.expected
        #expect(report.contains("RoomForMac needs to be reinstalled"))
        #expect(report.contains(presentation.message))
        #expect(report.contains("analyze-go\nExit code 2\nboom"))
        #expect(report.contains("App 0.1.0 (1)"))
        #expect(report.contains("macOS 27.0.0"))
        #expect(report.contains(expected.moleTag))
        #expect(report.contains(expected.moleCommit))
        #expect(report.contains(expected.patchesSHA256))
        #expect(report.contains("patch_count=\(expected.patchCount)"))
    }

    @Test func diagnosticsAddNoPathsOfTheirOwn() {
        let report = ErrorPresentation(EngineError.timedOut).diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.0")
        #expect(!report.contains(NSHomeDirectory()))
        #expect(!report.contains(Bundle.main.bundlePath))
    }

    @Test func versionsAreFormattedForTheReport() {
        #expect(ErrorPresentation.appVersion(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]) == "0.1.0 (1)")
        #expect(ErrorPresentation.appVersion(info: nil) == "? (?)")
        #expect(ErrorPresentation.osVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == "27.0.1")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ErrorPresentationTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The first error is `RoomForMacTests/Support/EngineLayout.swift:38:42: error: cannot find type 'EngineFingerprint' in scope`. The compiler may stop there, before it reports the missing `ErrorPresentation`.

- [ ] **Step 4: Write the fingerprint and the problem cases**

`RoomForMac/Engine/EngineProblem.swift`
```swift
import MoleEngine

/// The four `VERSION` values that identify one engine build.
struct EngineFingerprint: Sendable, Equatable {
    var moleTag: String
    var moleCommit: String
    var patchesSHA256: String
    var patchCount: Int

    init(moleTag: String, moleCommit: String, patchesSHA256: String, patchCount: Int) {
        self.moleTag = moleTag
        self.moleCommit = moleCommit
        self.patchesSHA256 = patchesSHA256
        self.patchCount = patchCount
    }

    init(_ version: EngineVersion) {
        self.init(
            moleTag: version.moleTag,
            moleCommit: version.moleCommit,
            patchesSHA256: version.patchesSHA256,
            patchCount: version.patchCount
        )
    }

    /// The engine this build of the app was made with, generated from build/engine/VERSION.
    static var expected: EngineFingerprint {
        EngineFingerprint(
            moleTag: EngineExpectation.moleTag,
            moleCommit: EngineExpectation.moleCommit,
            patchesSHA256: EngineExpectation.patchesSHA256,
            patchCount: EngineExpectation.patchCount
        )
    }

    /// One line of key=value data for details and diagnostics. It is data, not prose, so it is
    /// not localized.
    var summary: String {
        "tag=\(moleTag) commit=\(moleCommit) patches_sha256=\(patchesSHA256) patch_count=\(patchCount)"
    }
}

/// Why the bundled engine cannot be used. Any of these blocks the app behind "Reinstall RoomForMac".
enum EngineProblem: Error, Sendable, Equatable {
    /// A required file is missing or not executable, or `VERSION` is unreadable.
    /// Carries the `EngineError.installationInvalid` message.
    case installationInvalid(String)
    /// `VERSION` in the bundle is not the one this build was made with.
    case versionMismatch(expected: EngineFingerprint, found: EngineFingerprint)
    /// A helper could not run `-h`. `tool` is "analyze-go" or "status-go".
    case selfTestFailed(tool: String, detail: String)
}
```

- [ ] **Step 5: Write the error presentation**

`RoomForMac/Engine/ErrorPresentation.swift`
```swift
import Foundation
import MoleEngine

/// Plain-language text for any error: a title and message for the card, and technical
/// `details` for "Show details" and "Copy diagnostics".
struct ErrorPresentation: Sendable, Equatable {
    var title: String
    var message: String
    var details: String

    init(_ error: any Error) {
        switch error {
        case let problem as EngineProblem:
            self = Self.presenting(problem)
        case let engineError as EngineError:
            self = Self.presenting(engineError)
        case is CancellationError:
            self = Self.presenting(EngineError.cancelled)
        case let decodingError as DecodingError:
            // Checked before CocoaError: a DecodingError also bridges to NSCocoaErrorDomain.
            self = Self.presenting(decodingError)
        case let cocoaError as CocoaError where cocoaError.isFileError:
            self = Self.presentingFileError(cocoaError)
        default:
            self = Self.presentingUnknown(error)
        }
    }

    private init(title: String, message: String, details: String) {
        self.title = title
        self.message = message
        self.details = details
    }

    /// A report to paste into a bug report. It adds no file paths of its own: only `details`
    /// can carry one.
    func diagnostics(appVersion: String, osVersion: String) -> String {
        [
            String(localized: "RoomForMac diagnostics"),
            String(localized: "Title: \(title)"),
            String(localized: "Message: \(message)"),
            String(localized: "Details:"),
            details,
            String(localized: "App \(appVersion)"),
            String(localized: "macOS \(osVersion)"),
            String(localized: "Expected engine: \(EngineFingerprint.expected.summary)"),
        ].joined(separator: "\n")
    }

    /// "0.1.0 (1)" from `CFBundleShortVersionString` and `CFBundleVersion`.
    static func appVersion(info: [String: Any]?) -> String {
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    /// "27.0.1".
    static func osVersion(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - Mappings

    private static func presenting(_ problem: EngineProblem) -> ErrorPresentation {
        let title = String(localized: "RoomForMac needs to be reinstalled")
        switch problem {
        case .installationInvalid(let reason):
            return ErrorPresentation(
                title: title,
                message: String(localized: "Some files RoomForMac needs are missing or damaged."),
                details: reason
            )
        case .versionMismatch(let expected, let found):
            return ErrorPresentation(
                title: title,
                message: String(localized: "The engine inside RoomForMac doesn't match this version of the app."),
                details: lines(
                    String(localized: "Expected: \(expected.summary)"),
                    String(localized: "Found: \(found.summary)")
                )
            )
        case .selfTestFailed(let tool, let detail):
            return ErrorPresentation(
                title: title,
                message: String(localized: "Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged."),
                details: lines(tool, detail)
            )
        }
    }

    private static func presenting(_ error: EngineError) -> ErrorPresentation {
        switch error {
        case .installationInvalid(let reason):
            return presenting(EngineProblem.installationInvalid(reason))
        case .launchFailed(let executable, let reason):
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return ErrorPresentation(
                title: String(localized: "The engine couldn't start"),
                message: String(localized: "RoomForMac couldn't start \(name)."),
                details: lines(executable, reason)
            )
        case .nonZeroExit(let code, let stderrTail):
            return ErrorPresentation(
                title: String(localized: "The engine ran into a problem"),
                message: String(localized: "It stopped with error code \(Int(code))."),
                details: lines(String(localized: "Exit code \(Int(code))"), stderrTail)
            )
        case .terminatedBySignal(let signal, let stderrTail):
            return ErrorPresentation(
                title: String(localized: "The engine stopped unexpectedly"),
                message: String(localized: "macOS ended it before it finished."),
                details: lines(String(localized: "Signal \(Int(signal))"), stderrTail)
            )
        case .timedOut:
            return ErrorPresentation(
                title: String(localized: "The engine took too long"),
                message: String(localized: "RoomForMac stopped it after waiting too long. Try again."),
                details: String(describing: error)
            )
        case .cancelled:
            return ErrorPresentation(
                title: String(localized: "Stopped"),
                message: String(localized: "The engine was stopped before it finished."),
                details: String(describing: error)
            )
        case .malformedOutput(let reason):
            return ErrorPresentation(
                title: String(localized: "The engine returned something unexpected"),
                message: String(localized: "RoomForMac couldn't read the engine's answer."),
                details: reason
            )
        }
    }

    private static func presenting(_ error: DecodingError) -> ErrorPresentation {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found), .dataCorrupted(let found):
            context = found
        @unknown default:
            return presentingUnknown(error)
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return ErrorPresentation(
            title: String(localized: "The engine returned something unexpected"),
            message: String(localized: "RoomForMac couldn't read the engine's answer."),
            details: path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        )
    }

    private static func presentingFileError(_ error: CocoaError) -> ErrorPresentation {
        let message = if let path = error.filePath ?? error.url?.path {
            String(localized: "RoomForMac couldn't use the file at \(path).")
        } else {
            String(localized: "RoomForMac couldn't use a file it needs.")
        }
        return ErrorPresentation(
            title: String(localized: "RoomForMac couldn't use a file"),
            message: message,
            details: lines("\(CocoaError.errorDomain) \(error.errorCode)", error.localizedDescription)
        )
    }

    private static func presentingUnknown(_ error: any Error) -> ErrorPresentation {
        let nsError = error as NSError
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "RoomForMac ran into an unexpected problem.")
        return ErrorPresentation(
            title: String(localized: "Something went wrong"),
            message: message,
            details: lines("\(nsError.domain) \(nsError.code)", String(describing: error))
        )
    }

    /// Joins non-empty pieces of technical text, one per line, without trailing whitespace.
    private static func lines(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
```

Once an error is boxed in `any Error`, a `CocoaError` is stored as an `NSError`, and `case let cocoaError as CocoaError` still matches it. A `DecodingError` bridges to `NSCocoaErrorDomain` too (codes 4864 and 4865), which is why it is matched first.

- [ ] **Step 6: Run the presentation tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ErrorPresentationTests`
Expected: `✔ Test run with 20 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 7: Write the failing health-check tests**

`RoomForMacTests/EngineHealthCheckTests.swift`
```swift
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Engine health check")
struct EngineHealthCheckTests {
    static let fingerprint = EngineFingerprint(
        moleTag: "V1.56.0",
        moleCommit: String(repeating: "a", count: 40),
        patchesSHA256: String(repeating: "b", count: 64),
        patchCount: 5
    )
    let temporary: TemporaryDirectory
    let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/rfm-test")

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func makeRoot(version: [String: String] = EngineLayout.version(for: EngineHealthCheckTests.fingerprint)) throws -> URL {
        try EngineLayout.make(in: temporary.url, version: version)
    }

    func healthCheck(root: URL, runner: any EngineRunning = FakeEngineRunner()) -> EngineHealthCheck {
        EngineHealthCheck(
            expected: Self.fingerprint,
            runner: runner,
            environment: environment,
            selfTestTimeout: .seconds(3),
            locate: { try EngineInstallation(root: root) }
        )
    }

    @Test func aHealthyEngineIsReady() async throws {
        let root = try makeRoot()
        let installation = try await healthCheck(root: root).run().get()
        #expect(installation.root == root)
        #expect(EngineFingerprint(installation.version) == Self.fingerprint)
    }

    @Test func aMissingScriptMeansReinstall() async throws {
        let root = try makeRoot()
        try FileManager.default.removeItem(at: root.appending(path: "bin/clean.sh"))
        let runner = FakeEngineRunner()
        let result = await healthCheck(root: root, runner: runner).run()
        #expect(result == .failure(.installationInvalid("missing bin/clean.sh")))
        #expect(runner.commands.isEmpty)
    }

    @Test func anyOtherLocatorErrorIsDescribed() async {
        struct NoResources: Error {}
        let check = EngineHealthCheck(
            expected: Self.fingerprint,
            runner: FakeEngineRunner(),
            environment: environment,
            locate: { throw NoResources() }
        )
        #expect(await check.run() == .failure(.installationInvalid("NoResources()")))
    }

    @Test func aDifferentPatchSetIsAVersionMismatch() async throws {
        var version = EngineLayout.version(for: Self.fingerprint)
        version["patches_sha256"] = String(repeating: "c", count: 64)
        let runner = FakeEngineRunner()
        let result = await healthCheck(root: try makeRoot(version: version), runner: runner).run()

        var found = Self.fingerprint
        found.patchesSHA256 = String(repeating: "c", count: 64)
        #expect(result == .failure(.versionMismatch(expected: Self.fingerprint, found: found)))
        #expect(runner.commands.isEmpty)
    }

    @Test func anAnalyzerThatExitsNonZeroFailsTheSelfTest() async throws {
        let runner = FakeEngineRunner(responses: ["analyze-go": .failure(.nonZeroExit(code: 2, stderrTail: "boom"))])
        let result = await healthCheck(root: try makeRoot(), runner: runner).run()

        guard case .failure(.selfTestFailed(let tool, let detail)) = result else {
            Issue.record("expected selfTestFailed, got \(result)")
            return
        }
        #expect(tool == "analyze-go")
        #expect(detail.contains("boom"))
        #expect(runner.commands.count == 1)
    }

    @Test func aStatusToolKilledBySignalFailsTheSelfTest() async throws {
        let killed = EngineError.terminatedBySignal(9, stderrTail: "")
        let runner = FakeEngineRunner(responses: ["status-go": .failure(killed)])
        let result = await healthCheck(root: try makeRoot(), runner: runner).run()

        #expect(result == .failure(.selfTestFailed(tool: "status-go", detail: ErrorPresentation(killed).details)))
        #expect(runner.commands.map(\.executable.lastPathComponent) == ["analyze-go", "status-go"])
    }

    @Test func theSelfTestAsksEachToolForHelpWithTheEngineEnvironment() async throws {
        let root = try makeRoot()
        let runner = FakeEngineRunner()
        _ = await healthCheck(root: root, runner: runner).run()

        let installation = try EngineInstallation(root: root)
        let expected = [installation.analyzeBinary, installation.statusBinary].map { executable in
            EngineCommand(
                executable: executable,
                arguments: ["-h"],
                environment: environment.variables(for: installation),
                output: .stdout,
                timeout: .seconds(3)
            )
        }
        #expect(runner.commands == expected)
    }

    @Test func cancellingTheCallerNeverTurnsAFailingSelfTestIntoAPass() async throws {
        let check = healthCheck(root: try makeRoot(), runner: SilentWhenCancelledRunner())
        let running = Task { await check.run() }
        running.cancel()
        let result = await running.value

        guard case .failure(.selfTestFailed(let tool, _)) = result else {
            Issue.record("expected selfTestFailed, got \(result)")
            return
        }
        #expect(tool == "analyze-go")
    }

    @Test func theExpectedFingerprintIsTheGeneratedOne() {
        #expect(EngineFingerprint.expected == EngineFingerprint(
            moleTag: EngineExpectation.moleTag,
            moleCommit: EngineExpectation.moleCommit,
            patchesSHA256: EngineExpectation.patchesSHA256,
            patchCount: EngineExpectation.patchCount
        ))
    }
}

/// Behaves like `MoleRunner` under cancellation: a cancelled consumer sees the stream end
/// without an error. Uncancelled, every command fails after 50 ms, killed by signal 9.
private struct SilentWhenCancelledRunner: EngineRunning {
    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                try? await Task.sleep(for: .milliseconds(50))
                continuation.finish(throwing: EngineError.terminatedBySignal(9, stderrTail: ""))
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    work.cancel()
                }
            }
        }
    }
}
```

- [ ] **Step 8: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/EngineHealthCheckTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The errors include `RoomForMacTests/EngineHealthCheckTests.swift:25:84: error: cannot find type 'EngineHealthCheck' in scope` and `cannot find 'EngineHealthCheck' in scope`.

- [ ] **Step 9: Write the health check**

`RoomForMac/Engine/EngineHealthCheck.swift`
```swift
import Foundation
import MoleEngine

/// The launch integrity check (spec §10): the engine files are present, `VERSION` matches the
/// build, and both Go helpers actually run.
struct EngineHealthCheck: Sendable {
    private let expected: EngineFingerprint
    private let runner: any EngineRunning
    private let environment: EngineEnvironment
    private let selfTestTimeout: Duration
    private let locate: @Sendable () throws -> EngineInstallation

    init(
        expected: EngineFingerprint = .expected,
        runner: any EngineRunning = MoleRunner(),
        environment: EngineEnvironment = .current(),
        selfTestTimeout: Duration = .seconds(10),
        locate: @escaping @Sendable () throws -> EngineInstallation = { try EngineInstallation.bundled() }
    ) {
        self.expected = expected
        self.runner = runner
        self.environment = environment
        self.selfTestTimeout = selfTestTimeout
        self.locate = locate
    }

    func run() async -> Result<EngineInstallation, EngineProblem> {
        let installation: EngineInstallation
        do {
            installation = try locate()
        } catch let EngineError.installationInvalid(message) {
            return .failure(.installationInvalid(message))
        } catch {
            return .failure(.installationInvalid(String(describing: error)))
        }

        let found = EngineFingerprint(installation.version)
        guard found == expected else {
            return .failure(.versionMismatch(expected: expected, found: found))
        }

        let variables = environment.variables(for: installation)
        let tools = [("analyze-go", installation.analyzeBinary), ("status-go", installation.statusBinary)]
        for (tool, executable) in tools {
            let command = EngineCommand(
                executable: executable,
                arguments: ["-h"],
                environment: variables,
                output: .stdout,
                timeout: selfTestTimeout
            )
            do {
                try await Self.selfTest(command, runner: runner)
            } catch {
                return .failure(.selfTestFailed(tool: tool, detail: ErrorPresentation(error).details))
            }
        }
        return .success(installation)
    }

    /// Runs one self-test in an unstructured task so cancelling the caller cannot cut it short:
    /// `MoleRunner` ends a cancelled stream without an error, which would read as a pass.
    /// `selfTestTimeout` still bounds it.
    private static func selfTest(_ command: EngineCommand, runner: any EngineRunning) async throws {
        let run = Task {
            _ = try await runner.collect(command)
        }
        try await run.value
    }
}
```

- [ ] **Step 10: Run the health-check tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/EngineHealthCheckTests`
Expected: `✔ Test run with 9 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

`cancellingTheCallerNeverTurnsAFailingSelfTestIntoAPass` pins point 4 of the Requirements. If `selfTest` awaited `runner.collect(command)` directly, this test would fail with `Issue recorded`, because `run()` would return `.success`.

- [ ] **Step 11: Write the accessibility identifiers and the problem card**

`RoomForMac/App/AccessibilityID.swift`
```swift
/// Every accessibility identifier the app sets, so views and UI tests share one spelling.
enum AccessibilityID {
    static let engineProblemCard = "engineProblem.card"
    static let engineProblemDetails = "engineProblem.details"
    static let engineProblemCopy = "engineProblem.copy"
    static let engineProblemDownload = "engineProblem.download"
}
```

`RoomForMac/Engine/EngineProblemView.swift`
```swift
import AppKit
import SwiftUI

/// The blocking "Reinstall RoomForMac" card shown when the launch check fails.
/// Plain SwiftUI styling for now; Task 5 swaps in `GlassCard`, `GlassButton` and `Palette.canvas`.
struct EngineProblemView: View {
    static let downloadPage = URL(string: "https://github.com/gugag2003/RoomForMac/releases")!

    private let presentation: ErrorPresentation
    @State private var showsDetails = false
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    init(problem: EngineProblem) {
        presentation = ErrorPresentation(problem)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            card
                .frame(maxWidth: 540)
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Reinstall RoomForMac")
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityAddTraits(.isHeader)

            Text(presentation.message)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Show details", isExpanded: $showsDetails) {
                ScrollView {
                    Text(presentation.details)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
            }
            .accessibilityIdentifier(AccessibilityID.engineProblemDetails)

            HStack {
                Button(action: copyDiagnostics) {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy diagnostics", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.engineProblemCopy)

                Spacer()

                Button("Open download page") {
                    openURL(Self.downloadPage)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.engineProblemDownload)
            }
            .controlSize(.large)
        }
        .padding(24)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.engineProblemCard)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copyDiagnostics() {
        let report = presentation.diagnostics(
            appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary),
            osVersion: ErrorPresentation.osVersion()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        copied = true
    }
}

#Preview("Version mismatch") {
    EngineProblemView(problem: .versionMismatch(
        expected: .expected,
        found: EngineFingerprint(moleTag: "V0.0.0", moleCommit: "0000000", patchesSHA256: "none", patchCount: 0)
    ))
    .frame(width: 900, height: 600)
}
```

`Text(presentation.message)` and `Text(presentation.details)` take a `String`, so they show it verbatim. `ErrorPresentation` has already localized it. Every literal in the view (`Text("Reinstall RoomForMac")`, `DisclosureGroup("Show details", …)`, the `Label` and `Button` titles) is a `LocalizedStringKey`.

- [ ] **Step 12: Run the whole unit scheme**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-3.log" | tail -n 20
grep -E '(RoomForMac/Engine/|AccessibilityID\.swift).*(warning|error):' "$TMPDIR/rfm-task-3.log"
```
Expected: the log ends with `** TEST SUCCEEDED **`, and the `grep` prints nothing, so there are no warnings in this task's files. The Swift Testing summary counts this task's 29 tests plus those of Tasks 1–2. The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 13: Sync the String Catalog**

`xcodebuild` writes the strings each source file uses into `.stringsdata` files, but only the Xcode editor copies them into `Localizable.xcstrings`. This step does that copy from the command line, using the app target's files from the build in Step 12.

Run:
```bash
OBJROOT=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null | awk '$1 == "OBJROOT" { print $3; exit }')
find "$OBJROOT" -path '*/RoomForMac.build/Objects-normal/*' -name '*.stringsdata' \
    -exec xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --stringsdata {} +
git diff --stat RoomForMac/Resources/Localizable.xcstrings
```
Expected: `xcstringstool` prints nothing and exits 0. The diff adds these 37 keys, and every key that earlier tasks added stays:
`App %@`, `Copied`, `Copy diagnostics`, `Details:`, `Exit code %lld`, `Expected engine: %@`, `Expected: %@`, `Found: %@`, `It stopped with error code %lld.`, `Message: %@`, `Open download page`, `Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged.`, `Reinstall RoomForMac`, `RoomForMac couldn't read the engine's answer.`, `RoomForMac couldn't start %@.`, `RoomForMac couldn't use a file`, `RoomForMac couldn't use a file it needs.`, `RoomForMac couldn't use the file at %@.`, `RoomForMac diagnostics`, `RoomForMac needs to be reinstalled`, `RoomForMac ran into an unexpected problem.`, `RoomForMac stopped it after waiting too long. Try again.`, `Show details`, `Signal %lld`, `Some files RoomForMac needs are missing or damaged.`, `Something went wrong`, `Stopped`, `The engine couldn't start`, `The engine inside RoomForMac doesn't match this version of the app.`, `The engine ran into a problem`, `The engine returned something unexpected`, `The engine stopped unexpectedly`, `The engine took too long`, `The engine was stopped before it finished.`, `Title: %@`, `macOS %@`, `macOS ended it before it finished.`

The `-path` pattern matches only the app target (`…/RoomForMac.build/Objects-normal/…`). The test target (`RoomForMacTests.build`) and the `MoleEngine` package are left out.

- [ ] **Step 14: Commit**

```bash
git add RoomForMac/Engine/EngineProblem.swift RoomForMac/Engine/EngineHealthCheck.swift \
    RoomForMac/Engine/ErrorPresentation.swift RoomForMac/Engine/EngineProblemView.swift \
    RoomForMac/App/AccessibilityID.swift RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/Support/TemporaryDirectory.swift RoomForMacTests/Support/EngineLayout.swift \
    RoomForMacTests/Support/FakeEngineRunner.swift \
    RoomForMacTests/EngineHealthCheckTests.swift RoomForMacTests/ErrorPresentationTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'EOF'
feat(app): engine launch check, error presentation and reinstall card

EngineHealthCheck locates the bundled engine, compares its VERSION with
the generated expectation and runs both Go helpers with -h. Each
self-test runs in its own task so a cancelled caller cannot turn it into
a pass. ErrorPresentation maps every engine, decoding and file error to
plain language, and EngineProblemView is the blocking "Reinstall
RoomForMac" card with details and Copy diagnostics.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

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
- Additions (internal to this task). Later tasks may use them but do not depend on them:
  ```swift
  extension RGB {                                          // declared inside `struct RGB`
      init(red: Double, green: Double, blue: Double, opacity: Double = 1)
      var hex: UInt32 { get }                              // 0xRRGGBB, each channel rounded to 8 bits
      func composited(over background: RGB) -> RGB         // background counts as opaque
      var nsColor: NSColor { get }                         // NSColor(srgbRed:green:blue:alpha:)
  }
  extension Palette.Swatch { func rgb(isDark: Bool) -> RGB }
  extension Palette {
      static let secondaryTextOpacity: Double              // 0.65
      static func isDark(_ appearance: NSAppearance) -> Bool   // bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
  extension Typography {
      static let defaultHeroSize: CGFloat                  // 48; `hero(size:)` defaults to it
      static func heroSize(_ size: CGFloat) -> CGFloat     // clamp to heroSizes; NaN → defaultHeroSize
  }
  enum GlassTransitionKind: Sendable, Equatable, CaseIterable {
      case matchedGeometry, materialize
      var transition: GlassEffectTransition { get }
  }
  extension Motion { static func glassTransitionKind(reduceMotion: Bool) -> GlassTransitionKind }
  ```

**Requirements:**
- Swatches are the exact hex values from Global Constraints. `textSecondary` is `text` with `opacity` 0.65 in both appearances.
- `Palette.color(token)` returns one cached `Color(nsColor:)` per token. It wraps `NSColor(name: "RoomForMac.<token>", dynamicProvider:)`, which picks the dark swatch when `NSAppearance.bestMatch(from: [.aqua, .darkAqua])` is `.darkAqua`. High-contrast and vibrant variants therefore map to their base appearance. The static accessors (`Palette.canvas` … `Palette.clay`) return `color(_:)` of their token.
- `contrastRatio(a, b)` is the WCAG 2.x ratio, 1...21. `a` is the foreground: if it is translucent, it is composited over `b` first. For two opaque colors the order does not matter.
- `AccentColor` has the `action` light (`#586440`) and dark (`#ADB591`) values, in sRGB.
- `Typography.heroSize(_:)` clamps to `heroSizes`, and NaN gives 48. `hero(size:)` uses the clamped size.
- `Motion.animation(_:reduceMotion:)` returns nil under Reduce Motion, otherwise the animation unchanged. `Motion.glassTransition(reduceMotion:)` returns `.materialize` under Reduce Motion, otherwise `.matchedGeometry`.
- `GlassEffectTransition` is `Sendable` but not `Equatable` (spike S1, A.2). So the task adds `GlassTransitionKind`, and `glassTransition(reduceMotion:)` returns `glassTransitionKind(reduceMotion:).transition`.
- Tests (Swift Testing, app-hosted):
  - every token's light and dark hex, and its opacity;
  - contrast `action`/`canvas` (light) = 5.54 and `onAction`/`action` (light) = 6.11, both ±0.01 and both ≥ 4.5;
  - dark `action`/`canvas` ≥ 4.5, and `onAction`/`clay` ≥ 4.5 in both appearances, because destructive buttons put text on `clay`;
  - `Palette.color(.canvas)` resolved under `NSAppearance(named: .darkAqua)` gives `#1C2119`, checked via `NSColor(...).usingColorSpace(.sRGB)` inside `appearance.performAsCurrentDrawingAppearance`. The same check runs for every token in both appearances, for both high-contrast appearances, and for every static accessor;
  - every token resolved through SwiftUI (`Color.resolve(in:)` with `colorScheme` `.light` and `.dark`);
  - `NSColor(named: "AccentColor", bundle: .main)` resolves to `action` in both appearances;
  - `Typography.hero(size: 80)` clamps to 56, through `heroSize(_:)`;
  - `Motion.animation(_:reduceMotion: true) == nil`;
  - `Motion.glassTransition(reduceMotion:)` for both values, through `GlassTransitionKind`. The `GlassEffectTransition` values themselves are compared by their reflected description.

**Measured, not pinned:** in light mode, `textSecondary` (65% `text`) reaches only 3.83:1 on `canvas` and 4.00:1 on `surface`. That passes WCAG AA for large text (3:1) but not for body text (4.5:1). In dark mode it reaches 6.78 and 6.15. The spec fixes 65%, so this task keeps it. The owner's design pass should decide whether to raise it or to use `textSecondary` only for large or non-essential text. No test pins either number.

**Why the Typography tests live in `PaletteTests.swift`:** the file list gives Typography no test file of its own. They form a nested suite inside `PaletteTests`, so `-only-testing:RoomForMacTests/PaletteTests` runs them too.

- [ ] **Step 1: Write the failing palette and typography tests** — `RoomForMacTests/PaletteTests.swift`

The SwiftUI resolution test is `@MainActor` on purpose. `Color.resolve(in:)` on an AppKit-backed color waits for the main thread (`UpdateGroup.syncMain`). In an app-hosted run, XCTest holds the main thread while it waits for Swift Testing. Called from a nonisolated test, it therefore hangs the whole run; a `sample` of the stuck host showed exactly that while this plan was written. The `NSColor` checks are not affected.

```swift
import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// Spec §11.1, one row per token: light hex, dark hex, opacity in both.
private let specSwatches: [SpecSwatch] = [
    SpecSwatch(token: .canvas, light: 0xF1F0E5, dark: 0x1C2119),
    SpecSwatch(token: .surface, light: 0xFCFBF2, dark: 0x262D22),
    SpecSwatch(token: .text, light: 0x333B2D, dark: 0xF1F0E5),
    SpecSwatch(token: .textSecondary, light: 0x333B2D, dark: 0xF1F0E5, opacity: 0.65),
    SpecSwatch(token: .action, light: 0x586440, dark: 0xADB591),
    SpecSwatch(token: .onAction, light: 0xFCFBF2, dark: 0x1C2119),
    SpecSwatch(token: .moss, light: 0xADB591, dark: 0x7E8866),
    SpecSwatch(token: .grass, light: 0xB3915D, dark: 0xC9A877),
    SpecSwatch(token: .clay, light: 0xA8563F, dark: 0xC97A5F),
]

struct SpecSwatch: Sendable, CustomTestStringConvertible {
    var token: Palette.Token
    var light: UInt32
    var dark: UInt32
    var opacity: Double = 1
    var testDescription: String { token.rawValue }
}

@Suite("Palette and typography")
struct PaletteTests {
    @Suite("RGB")
    struct RGBValues {
        @Test func hexSplitsIntoChannels() {
            let rgb = RGB(hex: 0x586440, opacity: 0.5)
            #expect(rgb.red == Double(0x58) / 255)
            #expect(rgb.green == Double(0x64) / 255)
            #expect(rgb.blue == Double(0x40) / 255)
            #expect(rgb.opacity == 0.5)
            #expect(rgb.hex == 0x586440)
        }

        @Test func bitsAboveTheColorAreIgnored() {
            #expect(RGB(hex: 0xFF58_6440) == RGB(hex: 0x586440))
        }

        @Test func relativeLuminanceFollowsWCAG() {
            #expect(RGB(hex: 0x000000).relativeLuminance == 0)
            #expect(abs(RGB(hex: 0xFFFFFF).relativeLuminance - 1) < 1e-12)
            // 0x80 = 0.50196 → ((0.50196 + 0.055) / 1.055)^2.4 = 0.21586
            #expect(abs(RGB(hex: 0x808080).relativeLuminance - 0.21586) < 0.00001)
            // Below the threshold the curve is linear: 0x0A → (10/255) / 12.92
            #expect(abs(RGB(hex: 0x0A0A0A).relativeLuminance - 10.0 / 255 / 12.92) < 1e-12)
        }

        @Test func compositingMixesOverTheBackground() {
            let half = RGB(hex: 0x000000, opacity: 0.5).composited(over: RGB(hex: 0xFFFFFF))
            #expect(half == RGB(red: 0.5, green: 0.5, blue: 0.5))
        }
    }

    @Suite("Swatches")
    struct Swatches {
        @Test func specCoversEveryToken() {
            #expect(Palette.Token.allCases.count == 9)
            #expect(Set(specSwatches.map(\.token)) == Set(Palette.Token.allCases))
        }

        @Test(arguments: specSwatches)
        func swatchMatchesTheSpec(_ spec: SpecSwatch) {
            let swatch = Palette.swatch(spec.token)
            #expect(swatch.light.hex == spec.light)
            #expect(swatch.dark.hex == spec.dark)
            #expect(swatch.light.opacity == spec.opacity)
            #expect(swatch.dark.opacity == spec.opacity)
        }

        @Test func secondaryTextIsTextAt65Percent() {
            let text = Palette.swatch(.text)
            let secondary = Palette.swatch(.textSecondary)
            #expect(secondary.light == RGB(hex: text.light.hex, opacity: 0.65))
            #expect(secondary.dark == RGB(hex: text.dark.hex, opacity: 0.65))
        }
    }

    @Suite("Contrast")
    struct Contrast {
        @Test func blackOnWhiteIs21InEitherOrder() {
            let black = RGB(hex: 0x000000)
            let white = RGB(hex: 0xFFFFFF)
            #expect(abs(Palette.contrastRatio(black, white) - 21) < 1e-9)
            #expect(Palette.contrastRatio(white, black) == Palette.contrastRatio(black, white))
            #expect(Palette.contrastRatio(white, white) == 1)
        }

        @Test func translucentForegroundIsCompositedFirst() {
            // Black at 50 % over white is gray 0.5: 1.05 / (0.21404 + 0.05) = 3.977.
            let ratio = Palette.contrastRatio(RGB(hex: 0x000000, opacity: 0.5), RGB(hex: 0xFFFFFF))
            #expect(abs(ratio - 3.977) < 0.001)
        }

        @Test func lightActionOnCanvas() {
            let ratio = Palette.contrastRatio(Palette.swatch(.action).light, Palette.swatch(.canvas).light)
            #expect(abs(ratio - 5.54) <= 0.01)
            #expect(ratio >= 4.5)
        }

        @Test func lightOnActionOnAction() {
            let ratio = Palette.contrastRatio(Palette.swatch(.onAction).light, Palette.swatch(.action).light)
            #expect(abs(ratio - 6.11) <= 0.01)
            #expect(ratio >= 4.5)
        }

        @Test func darkActionOnCanvas() {
            #expect(Palette.contrastRatio(Palette.swatch(.action).dark, Palette.swatch(.canvas).dark) >= 4.5)
        }

        @Test(arguments: [false, true])
        func onActionOnClayForDestructiveButtons(isDark: Bool) {
            let onAction = Palette.swatch(.onAction).rgb(isDark: isDark)
            let clay = Palette.swatch(.clay).rgb(isDark: isDark)
            #expect(Palette.contrastRatio(onAction, clay) >= 4.5)
        }
    }

    @Suite("Dynamic colors")
    struct DynamicColors {
        @Test func canvasResolvesToItsDarkValueUnderDarkAqua() throws {
            #expect(try resolved(Palette.color(.canvas), in: .darkAqua).hex == 0x1C2119)
        }

        @Test(arguments: Palette.Token.allCases)
        func tokenFollowsTheAppearance(_ token: Palette.Token) throws {
            let swatch = Palette.swatch(token)
            let light = try resolved(Palette.color(token), in: .aqua)
            let dark = try resolved(Palette.color(token), in: .darkAqua)
            #expect(light.hex == swatch.light.hex)
            #expect(dark.hex == swatch.dark.hex)
            #expect(abs(light.opacity - swatch.light.opacity) < 0.001)
            #expect(abs(dark.opacity - swatch.dark.opacity) < 0.001)
        }

        /// SwiftUI resolves an AppKit-backed color on the main thread. Off the main
        /// actor this call waits for the main thread, which XCTest is holding while it
        /// waits for Swift Testing, and the test run hangs.
        @MainActor
        @Test(arguments: Palette.Token.allCases)
        func swiftUIResolvesTheTokenPerColorScheme(_ token: Palette.Token) {
            var light = EnvironmentValues()
            light.colorScheme = .light
            var dark = EnvironmentValues()
            dark.colorScheme = .dark
            let swatch = Palette.swatch(token)
            let resolvedLight = Palette.color(token).resolve(in: light)
            let resolvedDark = Palette.color(token).resolve(in: dark)
            #expect(rgb(resolvedLight).hex == swatch.light.hex)
            #expect(rgb(resolvedDark).hex == swatch.dark.hex)
            #expect(abs(Double(resolvedDark.opacity) - swatch.dark.opacity) < 0.001)
        }

        @Test func highContrastAppearancesUseTheirBaseValues() throws {
            #expect(try resolved(Palette.color(.canvas), in: .accessibilityHighContrastAqua).hex == 0xF1F0E5)
            #expect(try resolved(Palette.color(.canvas), in: .accessibilityHighContrastDarkAqua).hex == 0x1C2119)
            #expect(Palette.isDark(try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))))
            #expect(!Palette.isDark(try #require(NSAppearance(named: .accessibilityHighContrastAqua))))
        }

        @Test func staticAccessorsMatchTheirTokens() throws {
            let accessors: [(Color, Palette.Token)] = [
                (Palette.canvas, .canvas), (Palette.surface, .surface), (Palette.text, .text),
                (Palette.textSecondary, .textSecondary), (Palette.action, .action),
                (Palette.onAction, .onAction), (Palette.moss, .moss), (Palette.grass, .grass),
                (Palette.clay, .clay),
            ]
            for (color, token) in accessors {
                let swatch = Palette.swatch(token)
                #expect(try resolved(color, in: .aqua).hex == swatch.light.hex, "\(token.rawValue)")
                #expect(try resolved(color, in: .darkAqua).hex == swatch.dark.hex, "\(token.rawValue)")
            }
        }

        @Test func sameTokenGivesTheSameColor() {
            #expect(Palette.color(.action) == Palette.color(.action))
            #expect(Palette.action == Palette.color(.action))
        }

        @Test func accentColorIsAction() throws {
            let accent = try #require(NSColor(named: "AccentColor", bundle: .main))
            #expect(try resolved(accent, in: .aqua).hex == 0x586440)
            #expect(try resolved(accent, in: .darkAqua).hex == 0xADB591)
        }
    }

    @Suite("Typography")
    struct TypographyScale {
        @Test func heroRangeIsTheSpecRange() {
            #expect(Typography.heroSizes == 44...56)
            #expect(Typography.defaultHeroSize == 48)
        }

        @Test(arguments: zip(
            [80, 57, 56, 50, 44, 43, 0, -12, .infinity] as [CGFloat],
            [56, 56, 56, 50, 44, 44, 44, 44, 56] as [CGFloat]
        ))
        func heroSizeClamps(_ requested: CGFloat, _ expected: CGFloat) {
            #expect(Typography.heroSize(requested) == expected)
        }

        @Test func heroSizeOfNaNIsTheDefault() {
            #expect(Typography.heroSize(.nan) == 48)
        }

        @Test func heroFontIsRoundedSemiboldWithMonospacedDigits() {
            #expect(Typography.hero(size: 52) == .system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
            #expect(Typography.hero(size: 80) == Typography.hero(size: 56))
            #expect(Typography.hero() == Typography.hero(size: 48))
            #expect(Typography.hero(size: 50) != Typography.hero(size: 56))
        }

        @Test func numeralAndCaptionStyles() {
            #expect(Typography.numeral == .system(.title2, design: .rounded).monospacedDigit())
            #expect(Typography.caption == .system(.caption, design: .default))
        }
    }
}

/// SwiftUI's resolved sRGB components as an `RGB`.
private func rgb(_ resolved: Color.Resolved) -> RGB {
    RGB(
        red: Double(resolved.red),
        green: Double(resolved.green),
        blue: Double(resolved.blue),
        opacity: Double(resolved.opacity)
    )
}

/// `color` resolved the way AppKit draws it in `appearance`, as sRGB.
private func resolved(_ color: Color, in appearance: NSAppearance.Name) throws -> RGB {
    try resolved(NSColor(color), in: appearance)
}

private func resolved(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> RGB {
    let appearance = try #require(NSAppearance(named: appearanceName))
    var srgb: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        srgb = color.usingColorSpace(.sRGB)
    }
    let components = try #require(srgb)
    return RGB(
        red: components.redComponent,
        green: components.greenComponent,
        blue: components.blueComponent,
        opacity: components.alphaComponent
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/PaletteTests`
Expected: FAIL to compile — `PaletteTests.swift: error: cannot find type 'Palette' in scope`, `error: cannot find type 'RGB' in scope`, then `Testing cancelled because the build failed.` and `** TEST FAILED **`.

- [ ] **Step 3: Write the palette** — `RoomForMac/DesignSystem/Palette.swift`

```swift
import AppKit
import SwiftUI

/// An sRGB color. Every component is in 0...1.
struct RGB: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `hex` is `0xRRGGBB`. Bits above the low 24 are ignored.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// The channels as `0xRRGGBB`, each rounded to 8 bits. Opacity is not part of it.
    var hex: UInt32 {
        func byte(_ channel: Double) -> UInt32 {
            UInt32((min(max(channel, 0), 1) * 255).rounded())
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// WCAG 2.x relative luminance of the channels. Opacity is ignored here;
    /// `Palette.contrastRatio` composites a translucent color first.
    var relativeLuminance: Double {
        0.2126 * Self.linearized(red) + 0.7152 * Self.linearized(green) + 0.0722 * Self.linearized(blue)
    }

    /// This color painted over `background`, which counts as opaque.
    func composited(over background: RGB) -> RGB {
        let alpha = min(max(opacity, 0), 1)
        func mix(_ top: Double, _ bottom: Double) -> Double {
            top * alpha + bottom * (1 - alpha)
        }
        return RGB(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue)
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    /// sRGB transfer function, inverted. 0.04045 is the WCAG 2.2 threshold; no
    /// 8-bit channel lies between it and the older 0.03928.
    private static func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

/// The Alpine Moss color tokens (spec §11.1). Views use the dynamic colors
/// (`Palette.canvas`, `Palette.color(.action)`); tests and contrast checks use
/// the swatches.
enum Palette {
    enum Token: String, CaseIterable, Sendable {
        case canvas, surface, text, textSecondary, action, onAction, moss, grass, clay
    }

    struct Swatch: Sendable, Equatable {
        var light: RGB
        var dark: RGB

        func rgb(isDark: Bool) -> RGB {
            isDark ? dark : light
        }
    }

    /// `textSecondary` is `text` at this opacity, in both appearances.
    static let secondaryTextOpacity = 0.65

    static func swatch(_ token: Token) -> Swatch {
        switch token {
        case .canvas:
            return Swatch(light: RGB(hex: 0xF1F0E5), dark: RGB(hex: 0x1C2119))
        case .surface:
            return Swatch(light: RGB(hex: 0xFCFBF2), dark: RGB(hex: 0x262D22))
        case .text:
            return Swatch(light: RGB(hex: 0x333B2D), dark: RGB(hex: 0xF1F0E5))
        case .textSecondary:
            var text = swatch(.text)
            text.light.opacity = secondaryTextOpacity
            text.dark.opacity = secondaryTextOpacity
            return text
        case .action:
            return Swatch(light: RGB(hex: 0x586440), dark: RGB(hex: 0xADB591))
        case .onAction:
            return Swatch(light: RGB(hex: 0xFCFBF2), dark: RGB(hex: 0x1C2119))
        case .moss:
            return Swatch(light: RGB(hex: 0xADB591), dark: RGB(hex: 0x7E8866))
        case .grass:
            return Swatch(light: RGB(hex: 0xB3915D), dark: RGB(hex: 0xC9A877))
        case .clay:
            return Swatch(light: RGB(hex: 0xA8563F), dark: RGB(hex: 0xC97A5F))
        }
    }

    /// A color that follows the appearance it is drawn in. It is built once per
    /// token, so SwiftUI sees the same value on every body evaluation.
    static func color(_ token: Token) -> Color {
        dynamicColors[token] ?? Color(nsColor: makeDynamicColor(token))
    }

    /// Dark Aqua and its high-contrast and vibrant variants are dark; everything
    /// else is light.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// WCAG 2.x contrast ratio, 1...21. `a` is the foreground: when it is
    /// translucent it is composited over `b` (taken as opaque) first. The order
    /// of two opaque colors does not matter.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let foreground = a.opacity < 1 ? a.composited(over: b) : a
        let lighter = max(foreground.relativeLuminance, b.relativeLuminance)
        let darker = min(foreground.relativeLuminance, b.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static var canvas: Color { color(.canvas) }
    static var surface: Color { color(.surface) }
    static var text: Color { color(.text) }
    static var textSecondary: Color { color(.textSecondary) }
    static var action: Color { color(.action) }
    static var onAction: Color { color(.onAction) }
    static var moss: Color { color(.moss) }
    static var grass: Color { color(.grass) }
    static var clay: Color { color(.clay) }

    private static let dynamicColors: [Token: Color] = Dictionary(
        uniqueKeysWithValues: Token.allCases.map { ($0, Color(nsColor: makeDynamicColor($0))) }
    )

    private static func makeDynamicColor(_ token: Token) -> NSColor {
        let swatch = swatch(token)
        return NSColor(name: "RoomForMac.\(token.rawValue)") { appearance in
            swatch.rgb(isDark: Palette.isDark(appearance)).nsColor
        }
    }
}
```

- [ ] **Step 4: Write the type styles** — `RoomForMac/DesignSystem/Typography.swift`

```swift
import SwiftUI

/// Type styles (spec §11.2). UI text uses SF Pro through the system text
/// styles. Sizes, counters and gauges use SF Pro Rounded with monospaced
/// digits, so numbers do not jitter while they count.
enum Typography {
    /// The large-number hero style stays within 44–56 pt.
    static let heroSizes: ClosedRange<CGFloat> = 44...56
    static let defaultHeroSize: CGFloat = 48

    /// `size` clamped to `heroSizes`. NaN gives `defaultHeroSize`.
    static func heroSize(_ size: CGFloat) -> CGFloat {
        guard !size.isNaN else { return defaultHeroSize }
        return min(max(size, heroSizes.lowerBound), heroSizes.upperBound)
    }

    /// The hero numeral, for example the reclaimable size above the Clean button.
    static func hero(size: CGFloat = defaultHeroSize) -> Font {
        .system(size: heroSize(size), weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// Sizes and counters inside cards and lists.
    static let numeral: Font = .system(.title2, design: .rounded).monospacedDigit()

    /// Small print: credits, footnotes, chip labels.
    static let caption: Font = .system(.caption, design: .default)
}
```

- [ ] **Step 5: Run the tests; only the accent color should fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/PaletteTests`
Expected: FAIL with exactly one issue: `✘ Test accentColorIsAction() recorded an issue … Expectation failed: NSColor(named: "AccentColor", bundle: .main)`, then `✘ Test run with 25 tests in 6 suites failed … with 1 issue`. Task 1's `AccentColor` has no value, so actool writes no `Assets.car`. If the colorset holds only a light value, the dark check fails instead. Every other test passes. A stale `Assets.car` in DerivedData can hide this failure, but that only happens if an earlier build gave `AccentColor` a value.

- [ ] **Step 6: Give `AccentColor` the `action` values** — replace `RoomForMac/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x40",
          "green" : "0x64",
          "red" : "0x58"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x91",
          "green" : "0xB5",
          "red" : "0xAD"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/PaletteTests`
Expected: PASS — `✔ Test run with 25 tests in 6 suites passed` and `** TEST SUCCEEDED **`. The built app now contains `Contents/Resources/Assets.car`.

- [ ] **Step 8: Write the failing motion tests** — `RoomForMacTests/MotionTests.swift`

```swift
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Motion")
struct MotionTests {
    @Test func hoverIsTheSpecSpring() {
        #expect(Motion.hover == .spring(response: 0.3, dampingFraction: 0.7))
        #expect(Motion.hoverScale == 1.02)
    }

    @Test func timings() {
        #expect(Motion.sectionCrossfade == .milliseconds(800))
        #expect(Motion.driftPeriod == .seconds(60))
        #expect(Motion.driftMaxScaleIncrease == 0.08)
        #expect(Motion.staggerStep == .milliseconds(30))
    }

    @Test func reduceMotionDropsTheAnimation() {
        #expect(Motion.animation(Motion.hover, reduceMotion: true) == nil)
        #expect(Motion.animation(.easeInOut(duration: 0.8), reduceMotion: true) == nil)
    }

    @Test func normalMotionKeepsTheAnimation() {
        #expect(Motion.animation(Motion.hover, reduceMotion: false) == Motion.hover)
        #expect(Motion.animation(.linear(duration: 1), reduceMotion: false) == .linear(duration: 1))
    }

    @Test(arguments: [
        (false, GlassTransitionKind.matchedGeometry),
        (true, GlassTransitionKind.materialize),
    ])
    func glassMorphsUnlessReduceMotion(reduceMotion: Bool, expected: GlassTransitionKind) {
        #expect(Motion.glassTransitionKind(reduceMotion: reduceMotion) == expected)
    }

    /// `GlassEffectTransition` is not Equatable, so this compares the reflected
    /// values. It fails loudly (first expectation) if a future SDK makes the
    /// two cases print alike, rather than passing without checking anything.
    @Test func glassTransitionReturnsTheKindsTransition() {
        let materialize = String(reflecting: GlassEffectTransition.materialize)
        let matchedGeometry = String(reflecting: GlassEffectTransition.matchedGeometry)
        #expect(materialize != matchedGeometry)
        #expect(String(reflecting: Motion.glassTransition(reduceMotion: true)) == materialize)
        #expect(String(reflecting: Motion.glassTransition(reduceMotion: false)) == matchedGeometry)
        #expect(String(reflecting: GlassTransitionKind.materialize.transition) == materialize)
        #expect(String(reflecting: GlassTransitionKind.matchedGeometry.transition) == matchedGeometry)
    }
}
```

- [ ] **Step 9: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/MotionTests`
Expected: FAIL to compile — `MotionTests.swift: error: cannot find 'Motion' in scope`, `error: cannot find 'GlassTransitionKind' in scope`, `error: cannot find type 'GlassTransitionKind' in scope`, then `** TEST FAILED **`.

- [ ] **Step 10: Write the motion policy** — `RoomForMac/DesignSystem/Motion.swift`

```swift
import SwiftUI

/// The two ways a glass shape can change between views. `GlassEffectTransition`
/// is not `Equatable` (spike S1), so policies return this and tests compare it.
enum GlassTransitionKind: Sendable, Equatable, CaseIterable {
    /// Shapes with the same `glassEffectID` morph into each other.
    case matchedGeometry
    /// Shapes appear and disappear in place instead of morphing: the Reduce Motion crossfade.
    case materialize

    var transition: GlassEffectTransition {
        switch self {
        case .matchedGeometry: .matchedGeometry
        case .materialize: .materialize
        }
    }
}

/// Timing and the Reduce Motion policy (spec §11.4, §11.5). Views read
/// `accessibilityReduceMotion` from the environment and pass it in, so a
/// change in System Settings applies on the next body evaluation.
enum Motion {
    /// Hover response for glass controls.
    static let hover: Animation = .spring(response: 0.3, dampingFraction: 0.7)
    /// A hovered glass control grows to this scale.
    static let hoverScale: CGFloat = 1.02
    /// Crossfade between sidebar sections and their backdrops.
    static let sectionCrossfade: Duration = .milliseconds(800)
    /// One full Ken Burns drift loop.
    static let driftPeriod: Duration = .seconds(60)
    /// The drift zooms to at most 1 + this.
    static let driftMaxScaleIncrease: CGFloat = 0.08
    /// Delay between items that appear one after another.
    static let staggerStep: Duration = .milliseconds(30)

    /// `animation`, or no animation at all under Reduce Motion. The result goes
    /// straight into `withAnimation(_:_:)` or `.animation(_:value:)`.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Morphs normally; a crossfade under Reduce Motion.
    static func glassTransitionKind(reduceMotion: Bool) -> GlassTransitionKind {
        reduceMotion ? .materialize : .matchedGeometry
    }

    /// The transition for `.glassEffectTransition(_:)`.
    static func glassTransition(reduceMotion: Bool) -> GlassEffectTransition {
        glassTransitionKind(reduceMotion: reduceMotion).transition
    }
}
```

- [ ] **Step 11: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/MotionTests`
Expected: PASS — `✔ Test run with 6 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | grep -E '(error|warning):|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v appintentsmetadataprocessor`
Expected: PASS — one `✔ Test run with … tests in … suites passed` line and `** TEST SUCCEEDED **`. The run includes this task's 31 tests in 7 suites plus the earlier tasks' tests. There are no `error:` or `warning:` lines: the new files compile cleanly in Swift 6 mode.

- [ ] **Step 12: Commit**

```bash
git add RoomForMac/DesignSystem/Palette.swift RoomForMac/DesignSystem/Typography.swift RoomForMac/DesignSystem/Motion.swift RoomForMac/Resources/Assets.xcassets/AccentColor.colorset/Contents.json RoomForMacTests/PaletteTests.swift RoomForMacTests/MotionTests.swift
git commit -F - <<'EOF'
feat(design): add palette, typography and motion tokens

The Alpine Moss colors resolve per appearance through dynamic NSColors,
and AccentColor carries the action values. Tests pin the WCAG contrast
of action on canvas (5.54) and onAction on action (6.11). Typography
clamps the hero numeral to 44-56 pt. Motion drops animations and swaps
glass morphs for materialize under Reduce Motion.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: Glass components — GlassButton, GlassCard, MorphingGlass, GlassDots, Wordmark

**Files:**
- Create: `RoomForMac/DesignSystem/GlassButton.swift`, `RoomForMac/DesignSystem/GlassCard.swift`, `RoomForMac/DesignSystem/MorphingGlass.swift`, `RoomForMac/DesignSystem/GlassDots.swift`, `RoomForMac/DesignSystem/Wordmark.swift`, `RoomForMacTests/GlassComponentTests.swift`, `RoomForMacTests/WordmarkTests.swift`
- Modify: `RoomForMac/Engine/EngineProblemView.swift` (switch to `GlassCard`/`GlassButton`), `RoomForMac/Resources/Localizable.xcstrings` (the new keys, synced from the build in Step 14)

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
- Internal to this task (other tasks may call them, but nothing outside this task depends on them yet):
  ```swift
  extension GlassProminence { var tintToken: Palette.Token? { get } }   // .action / nil / .clay
  enum GlassHover { static func scale(isHovered: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat }
  extension View {
      /// Regular glass in `shape`, or a solid `surface` fill with a hairline edge when `.solid`.
      func glassSurface(_ policy: GlassSurfacePolicy, in shape: some Shape) -> some View
  }
  extension GlassDots {
      static let dotSize: CGFloat            // 8
      static let currentWidth: CGFloat       // 24
      static func clampedIndex(_ current: Int, count: Int) -> Int
      static func stepLabel(current: Int, count: Int) -> LocalizedStringResource   // "Step \(current + 1) of \(count)"
  }
  extension WordmarkShape {
      var aspectRatio: CGFloat { get }                                   // outline width / height; 1 when empty
      static func defaultFont(size: CGFloat) -> CTFont                   // SF Pro Rounded Semibold
      static func fitted(_ outline: CGPath, in rect: CGRect) -> Path     // flip to y-down, aspect-fit, centre
  }
  extension AnimatedWordmark: Animatable {                               // declared on the struct
      var animatableData: Double { get set }                             // nonisolated; the progress
      static func fillOpacity(progress: Double) -> Double                // 0 until 0.8, linear to 1 at 1.0
  }
  extension EngineProblemView { static let downloadPage: URL }           // https://github.com/gugag2003/RoomForMac/releases
  // RoomForMacTests (test support, in GlassComponentTests.swift; Task 12's render tests may reuse it):
  enum RenderCheck {
      @MainActor static func image(of view: some View, scheme: ColorScheme, size: CGSize = CGSize(width: 300, height: 120)) -> CGImage?
  }
  ```

**Requirements:**
- `GlassButton` styling per prominence:
  - `.primary`: `.buttonStyle(.glassProminent).tint(Palette.action)`.
  - `.secondary`: `.buttonStyle(.glass)`.
  - `.destructive`: `.buttonStyle(.glassProminent).tint(Palette.clay)`.

  The mapping lives in `GlassProminence.tintToken`. The label on tinted glass is `Palette.onAction`, because the system's own label colour is not guaranteed to contrast with the dark-mode `action` (`#ADB591`, a light green). All three use `.controlSize(.large)` and `.buttonBorderShape(.capsule)`. Hover scales to `Motion.hoverScale` with `Motion.hover`. It does not scale at all under Reduce Motion (read `accessibilityReduceMotion`) or when the button is disabled. `GlassHover.scale` holds that rule.
- `GlassCard`:
  - `.glass` → `.glassEffect(.regular, in: .rect(cornerRadius:))`.
  - `.solid` → `.background(Palette.surface, in: .rect(cornerRadius:))`, plus a 1 pt `Palette.text` stroke at 12% opacity. `surface` on `canvas` is about 1.07:1, so without the edge a solid card disappears into the solid Reduce Transparency backdrop.
  - The policy comes from `accessibilityReduceTransparency` through `GlassSurfacePolicy.resolve`. `View.glassSurface(_:in:)` applies it, so later glass shapes (Task 13's glass circle) reuse one fallback.
- `morphingGlass` applies, in order:
  1. `.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)`;
  2. `.glassEffectID(id, in: namespace)`;
  3. `.glassEffectTransition(Motion.glassTransition(reduceMotion:))`.

  Under Reduce Transparency it fills the same shape solid. The fill is `tint` when one is given, otherwise `surface`. **Tightened:** the skeleton said `surface` always. But the Start first scan button (Task 13) and the current onboarding dot are tinted `action` with `onAction` content. On a `surface` fill that content becomes `#FCFBF2` on `#FCFBF2` (1:1).
- `GlassDots`:
  - One `GlassEffectContainer(spacing: 8)` holds an `HStack(spacing: 10)` of `count` dots, 8 pt each. At 10 pt apart, the resting dots do not merge at rest.
  - The current dot is a 24 × 8 pt `morphingGlass` capsule, tinted `action` and not interactive. It morphs between positions with `glassEffectID("current")`. The resting dots carry `glassEffectID("dot-<index>")`.
  - Changes of `current` animate with `Motion.hover`. Under Reduce Motion they use a 0.25 s ease-in-out instead; the `.materialize` transition makes that a crossfade.
  - Under Reduce Transparency the resting dots are solid `moss`, because `surface` dots would vanish on `canvas`.
  - Accessibility: one element labelled "Step \(current + 1) of \(count)" (`stepLabel`), hidden when `count == 0`. `current` is clamped by `clampedIndex` (`0..<count`, and 0 when `count <= 0`). A negative `count` draws no dots.
- `WordmarkShape`:
  - Glyph outlines come from `CTFontCreatePathForGlyph` for each glyph of `CTLineCreateWithAttributedString`, positioned by the run's glyph positions.
  - Each run uses its own font, so characters CoreText substitutes from a fallback font still draw. Blank glyphs such as spaces are skipped.
  - `path(in:)` flips the outline to SwiftUI's coordinate space and scales it to fit `rect` while keeping its aspect ratio. The result is centred.
  - An empty outline or an empty rect gives an empty `Path`.
- `AnimatedWordmark`:
  - It strokes `WordmarkShape()` with `trim(from: 0, to: progress)` in `Palette.text` (1.5 pt, round caps and joins), and fades the fill in over the last 20% of progress.
  - It is `Animatable` over `progress`, so a `withAnimation(.linear(duration: 2)) { progress = 1 }` in Task 12 animates the fill on its own curve rather than over the whole two seconds.
  - Its size follows `aspectRatio(shape.aspectRatio, contentMode: .fit)`. Accessibility: one header element labelled "RoomForMac".
- `EngineProblemView` is updated to use `GlassCard` and `GlassButton`. Its interface (`init(problem:)`), the four `AccessibilityID.engineProblem*` identifiers, the copy and open actions, the `#Preview` and the Task 3 layout rules are unchanged:
  - a full-window `Palette.canvas` background;
  - a `GlassCard(cornerRadius: 24, padding: 28)` at most 540 pt wide, titled "Reinstall RoomForMac", with the message;
  - a "Show details" `DisclosureGroup` with monospaced, selectable `details` in a `ScrollView` at most 180 pt tall;
  - **Copy diagnostics** as `GlassButton(.secondary)`. It copies `diagnostics(appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary), osVersion: ErrorPresentation.osVersion())` and then reads "Copied" for 2 s;
  - **Open download page** as `GlassButton(.primary)`;
  - the identifiers:
    - `engineProblemCard` on the card, which is an `.accessibilityElement(children: .contain)`;
    - `engineProblemDetails` on the `DisclosureGroup`;
    - `engineProblemCopy` and `engineProblemDownload` on the two buttons.
- Nothing in this task uses `.buttonStyle(.glass(_:))`, `GlassButtonStyle(_:)`, `@ContentBuilder`, or any API newer than macOS 26.0 (Step 13 greps for them).
- Tests:
  - `GlassSurfacePolicy.resolve` for both inputs.
  - `GlassProminence.tintToken` for every case.
  - `GlassHover.scale` for hover, no hover, Reduce Motion and disabled.
  - `GlassDots` clamps `current`, through `static func clampedIndex(_ current: Int, count: Int) -> Int` (nine cases, including `count` 0 and negative). `stepLabel` is one-based.
  - `WordmarkShape.glyphPath` for "RoomForMac":
    - it is non-empty, and its bounding box width is > 4× its height;
    - two calls return equal bounding boxes (deterministic).
  - The default font is SF Pro Rounded Semibold.
  - `WordmarkShape.path(in:)`:
    - it fits inside the rect (±0.5 pt) and fills its width or its height, at three rects (wide, tall, offset);
    - it keeps the outline's aspect ratio;
    - it is upright, checked on a "T";
    - a named font works, and empty text, blank text and a zero rect give an empty path.
  - `AnimatedWordmark.fillOpacity` at seven progress values. `animatableData` is the clamped progress.
  - Each component renders through `ImageRenderer` without crashing and produces a non-nil `cgImage` at 300×120, in both light and dark `colorScheme`:
    - the three `GlassButton` prominences;
    - `GlassCard`;
    - a `morphingGlass` capsule;
    - `GlassDots`, 8 dots and empty;
    - `AnimatedWordmark` at progress 0, 0.5 and 1;
    - a filled `WordmarkShape`.

    `EngineProblemView` renders at 800×600 in both schemes.

A test run of this task may print `Compiler failed to build request` from the test host after the last test. It appeared in the scratch runs after glass was rendered offscreen. It is not a failure; only `** TEST FAILED **` or a `✘` line is.

- [ ] **Step 1: Write the failing glass component tests**

`RoomForMacTests/GlassComponentTests.swift`
```swift
import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// Renders a view offscreen at a fixed size and colour scheme, at scale 1.
enum RenderCheck {
    @MainActor
    static func image(
        of view: some View,
        scheme: ColorScheme,
        size: CGSize = CGSize(width: 300, height: 120)
    ) -> CGImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 1
        return renderer.cgImage
    }
}

@Suite("Glass components")
@MainActor
struct GlassComponentTests {
    @Test func surfacePolicyFollowsReduceTransparency() {
        #expect(GlassSurfacePolicy.resolve(reduceTransparency: false) == .glass)
        #expect(GlassSurfacePolicy.resolve(reduceTransparency: true) == .solid)
    }

    @Test func prominenceTintsWithPaletteTokens() {
        #expect(GlassProminence.primary.tintToken == .action)
        #expect(GlassProminence.secondary.tintToken == nil)
        #expect(GlassProminence.destructive.tintToken == .clay)
    }

    @Test func hoverScalesOnlyWhenHoveredEnabledAndMotionIsAllowed() {
        #expect(GlassHover.scale(isHovered: true, isEnabled: true, reduceMotion: false) == Motion.hoverScale)
        #expect(GlassHover.scale(isHovered: false, isEnabled: true, reduceMotion: false) == 1)
        #expect(GlassHover.scale(isHovered: true, isEnabled: true, reduceMotion: true) == 1)
        #expect(GlassHover.scale(isHovered: true, isEnabled: false, reduceMotion: false) == 1)
    }

    @Test(arguments: [
        (-3, 8, 0), (0, 8, 0), (5, 8, 5), (7, 8, 7), (8, 8, 7), (42, 8, 7), (0, 1, 0), (2, 0, 0), (-1, -4, 0),
    ])
    func dotsClampTheCurrentStep(current: Int, count: Int, expected: Int) {
        #expect(GlassDots.clampedIndex(current, count: count) == expected)
    }

    @Test func dotsAnnounceTheStepOneBased() {
        #expect(String(localized: GlassDots.stepLabel(current: 0, count: 8)) == "Step 1 of 8")
        #expect(String(localized: GlassDots.stepLabel(current: 7, count: 8)) == "Step 8 of 8")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func componentsRender(scheme: ColorScheme) throws {
        let samples: [(String, AnyView)] = [
            ("primary button", AnyView(GlassButton("Get started") {})),
            ("secondary button", AnyView(GlassButton("Not now", prominence: .secondary) {})),
            ("destructive button", AnyView(GlassButton(.destructive) {} label: { Label("Delete", systemImage: "trash") })),
            ("card", AnyView(GlassCard { Text(verbatim: "620 MB of 1 GB free cleanup left") })),
            ("morphing glass", AnyView(MorphingGlassSample())),
            ("dots", AnyView(GlassDots(count: 8, current: 3))),
            ("dots, empty", AnyView(GlassDots(count: 0, current: 0))),
        ]
        for (name, view) in samples {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme), "\(name) did not render")
            #expect(image.width == 300, "\(name)")
            #expect(image.height == 120, "\(name)")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func engineProblemViewRenders(scheme: ColorScheme) throws {
        let view = EngineProblemView(problem: .installationInvalid("missing bin/clean.sh"))
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: CGSize(width: 800, height: 600)))
        #expect(image.width == 800)
        #expect(image.height == 600)
    }
}

/// A morphing capsule needs a namespace, which only a view can own.
private struct MorphingGlassSample: View {
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer {
            Text(verbatim: "Scan")
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .morphingGlass(id: "scan", in: namespace, shape: .capsule)
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/GlassComponentTests`
Expected: the test target does not compile, and the run ends `** TEST FAILED **`. The errors include `error: cannot find 'GlassSurfacePolicy' in scope`, `error: cannot find 'GlassProminence' in scope` and `error: cannot find 'GlassHover' in scope`.

- [ ] **Step 3: Write `GlassButton`**

`RoomForMac/DesignSystem/GlassButton.swift`
```swift
import SwiftUI

/// How loudly a `GlassButton` asks to be pressed.
enum GlassProminence: Sendable, CaseIterable {
    case primary, secondary, destructive

    /// The token the prominent glass is tinted with; nil means the untinted
    /// `.glass` style. Labels on tinted glass use `onAction`.
    var tintToken: Palette.Token? {
        switch self {
        case .primary: .action
        case .secondary: nil
        case .destructive: .clay
        }
    }
}

/// The hover response shared by every glass control.
enum GlassHover {
    /// `Motion.hoverScale` while hovered, otherwise 1. Disabled controls and
    /// Reduce Motion never scale.
    static func scale(isHovered: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        isHovered && isEnabled && !reduceMotion ? Motion.hoverScale : 1
    }
}

/// The one button every screen uses. It keeps the system glass button styles,
/// so keyboard focus, press, disabled and default-action handling stay native.
/// Controls that must morph use `morphingGlass` instead (Ruling 5).
struct GlassButton<Label: View>: View {
    private let prominence: GlassProminence
    private let action: @MainActor () -> Void
    private let label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    init(
        _ prominence: GlassProminence = .primary,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.prominence = prominence
        self.action = action
        self.label = label()
    }

    var body: some View {
        styledButton
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .scaleEffect(GlassHover.scale(isHovered: isHovered, isEnabled: isEnabled, reduceMotion: reduceMotion))
            .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var styledButton: some View {
        if let tint = prominence.tintToken {
            Button(action: action) {
                label.foregroundStyle(Palette.onAction)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.color(tint))
        } else {
            Button(action: action) { label }
                .buttonStyle(.glass)
        }
    }
}

extension GlassButton where Label == Text {
    init(
        _ titleKey: LocalizedStringKey,
        prominence: GlassProminence = .primary,
        action: @escaping @MainActor () -> Void
    ) {
        self.init(prominence, action: action) { Text(titleKey) }
    }
}
```

- [ ] **Step 4: Write `GlassCard` and the surface policy**

`RoomForMac/DesignSystem/GlassCard.swift`
```swift
import SwiftUI

/// Whether glass surfaces draw as Liquid Glass or as solid `surface` fills.
enum GlassSurfacePolicy: Sendable, Equatable {
    case glass, solid

    /// Reduce Transparency turns every glass surface solid (spec §11.5).
    static func resolve(reduceTransparency: Bool) -> GlassSurfacePolicy {
        reduceTransparency ? .solid : .glass
    }
}

/// The one card every screen uses: regular glass in a rounded rectangle, or a
/// solid `surface` card with a hairline edge under Reduce Transparency.
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(cornerRadius: CGFloat = 20, padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .glassSurface(
                GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency),
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

extension View {
    /// Regular glass in `shape`, or a solid `surface` fill with a hairline edge
    /// (so the card still separates from a solid `canvas`) when `policy` is `.solid`.
    @ViewBuilder
    func glassSurface(_ policy: GlassSurfacePolicy, in shape: some Shape) -> some View {
        switch policy {
        case .glass:
            glassEffect(.regular, in: shape)
        case .solid:
            background(Palette.surface, in: shape)
                .overlay(shape.stroke(Palette.text.opacity(0.12), lineWidth: 1))
        }
    }
}
```

- [ ] **Step 5: Write `morphingGlass`**

`RoomForMac/DesignSystem/MorphingGlass.swift`
```swift
import SwiftUI

extension View {
    /// Liquid Glass that can morph between views sharing `id` inside one GlassEffectContainer.
    ///
    /// Use it for controls that change shape (Scan button → progress ring, the
    /// current onboarding dot, Start first scan). Wrap a tappable one in
    /// `Button { … } label: { … }.buttonStyle(.plain)`; the glass handles the
    /// press response. Under Reduce Motion the morph becomes a `.materialize`
    /// crossfade. Under Reduce Transparency the shape is filled solid: with
    /// `tint` when there is one, so an `onAction` label stays readable, else
    /// with `surface`.
    func morphingGlass<ID: Hashable & Sendable, S: Shape>(
        id: ID,
        in namespace: Namespace.ID,
        shape: S,
        tint: Color? = Palette.action,
        interactive: Bool = true
    ) -> some View {
        modifier(MorphingGlassModifier(id: id, namespace: namespace, shape: shape, tint: tint, interactive: interactive))
    }
}

private struct MorphingGlassModifier<ID: Hashable & Sendable, S: Shape>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        switch GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            content
                .glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(Motion.glassTransition(reduceMotion: reduceMotion))
        case .solid:
            content
                .background(tint ?? Palette.surface, in: shape)
        }
    }
}
```

- [ ] **Step 6: Write `GlassDots`**

`RoomForMac/DesignSystem/GlassDots.swift`
```swift
import SwiftUI

/// Onboarding progress: one glass dot per step, with the current step drawn as
/// a wider capsule that morphs from dot to dot (spec §6, "glass dots in a
/// GlassEffectContainer that morph between steps").
struct GlassDots: View {
    static let dotSize: CGFloat = 8
    static let currentWidth: CGFloat = 24

    private let count: Int
    private let current: Int

    @Namespace private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(count: Int, current: Int) {
        self.count = max(0, count)
        self.current = Self.clampedIndex(current, count: count)
    }

    /// `current` clamped to `0..<count`; 0 when there are no steps.
    static func clampedIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current, 0), count - 1)
    }

    /// The VoiceOver label, "Step 3 of 8" for index 2 of 8.
    static func stepLabel(current: Int, count: Int) -> LocalizedStringResource {
        "Step \(current + 1) of \(count)"
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { index in
                    if index == current {
                        Color.clear
                            .frame(width: Self.currentWidth, height: Self.dotSize)
                            .morphingGlass(id: "current", in: namespace, shape: .capsule, tint: Palette.action, interactive: false)
                    } else {
                        restingDot(index)
                    }
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Motion.hover, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.stepLabel(current: current, count: count)))
        .accessibilityHidden(count == 0)
    }

    @ViewBuilder
    private func restingDot(_ index: Int) -> some View {
        let dot = Color.clear.frame(width: Self.dotSize, height: Self.dotSize)
        switch GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            dot
                .glassEffect(.regular, in: .circle)
                .glassEffectID("dot-\(index)", in: namespace)
        case .solid:
            dot.background(Palette.moss, in: .circle)
        }
    }
}
```

- [ ] **Step 7: Run the glass component tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/GlassComponentTests`
Expected: `✔ Test run with 7 tests in 1 suite passed`, then `** TEST SUCCEEDED **`. `dotsClampTheCurrentStep` reports 9 test cases, and each render test reports 2. The compiler prints no warnings for the new files. At this point `engineProblemViewRenders` still renders Task 3's plain view; Step 12 swaps it.

- [ ] **Step 8: Write the failing wordmark tests**

`RoomForMacTests/WordmarkTests.swift`
```swift
import AppKit
import CoreText
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Wordmark")
@MainActor
struct WordmarkTests {
    private static let font = WordmarkShape.defaultFont(size: 64)

    @Test func defaultFontIsSFProRoundedSemibold() throws {
        let name = CTFontCopyFullName(Self.font) as String
        #expect(name.localizedCaseInsensitiveContains("rounded"), "\(name)")
        let traits = CTFontCopyTraits(Self.font) as NSDictionary
        let weight = try #require(traits[kCTFontWeightTrait as String] as? Double)
        #expect(abs(weight - NSFont.Weight.semibold.rawValue) < 0.01, "\(weight)")
    }

    @Test func outlineIsAWideNonEmptyPath() {
        let outline = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font)
        let box = outline.boundingBoxOfPath
        #expect(!outline.isEmpty)
        #expect(box.width > 4 * box.height, "\(box)")
    }

    @Test func outlineIsDeterministic() {
        let first = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font).boundingBoxOfPath
        let second = WordmarkShape.glyphPath(text: "RoomForMac", font: Self.font).boundingBoxOfPath
        #expect(first == second)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(WordmarkShape().path(in: rect).boundingRect == WordmarkShape().path(in: rect).boundingRect)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 300, height: 120),
        CGRect(x: 10, y: 20, width: 120, height: 300),
        CGRect(x: -40, y: 5, width: 1000, height: 40),
    ])
    func pathFitsTheRectKeepingItsAspectRatio(rect: CGRect) {
        let box = WordmarkShape().path(in: rect).cgPath.boundingBoxOfPath
        #expect(box.minX >= rect.minX - 0.5, "\(box) in \(rect)")
        #expect(box.maxX <= rect.maxX + 0.5, "\(box) in \(rect)")
        #expect(box.minY >= rect.minY - 0.5, "\(box) in \(rect)")
        #expect(box.maxY <= rect.maxY + 0.5, "\(box) in \(rect)")
        #expect(abs(box.width - rect.width) <= 0.5 || abs(box.height - rect.height) <= 0.5, "\(box) in \(rect)")
        #expect(abs(box.width / box.height - WordmarkShape().aspectRatio) < 0.01)
    }

    @Test func pathIsFlippedUpright() {
        // "T" in SwiftUI's y-down space: the bar's left end is near the top
        // edge; the bottom-left corner is empty.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = WordmarkShape(text: "T").path(in: rect)
        let box = path.cgPath.boundingBoxOfPath
        let topLeft = CGPoint(x: box.minX + box.width * 0.08, y: box.minY + box.height * 0.04)
        let bottomLeft = CGPoint(x: box.minX + box.width * 0.08, y: box.maxY - box.height * 0.04)
        #expect(path.contains(topLeft))
        #expect(!path.contains(bottomLeft))
    }

    @Test func namedFontAndDegenerateInputs() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(!WordmarkShape(fontName: "Helvetica-Bold").path(in: rect).isEmpty)
        #expect(WordmarkShape(text: "").path(in: rect).isEmpty)
        #expect(WordmarkShape(text: "   ").path(in: rect).isEmpty)
        #expect(WordmarkShape().path(in: .zero).isEmpty)
        #expect(WordmarkShape(text: "").aspectRatio == 1)
    }

    @Test(arguments: [(-1.0, 0.0), (0.0, 0.0), (0.5, 0.0), (0.8, 0.0), (0.9, 0.5), (1.0, 1.0), (2.0, 1.0)])
    func fillFadesInOverTheLastFifth(progress: Double, expected: Double) {
        #expect(abs(AnimatedWordmark.fillOpacity(progress: progress) - expected) < 1e-9)
    }

    @Test func animatableDataIsTheClampedProgress() {
        var wordmark = AnimatedWordmark(progress: 1.7)
        #expect(wordmark.animatableData == 1)
        wordmark.animatableData = 0.25
        #expect(wordmark.animatableData == 0.25)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func wordmarkRenders(scheme: ColorScheme) throws {
        for progress in [0.0, 0.5, 1.0] {
            let image = try #require(RenderCheck.image(of: AnimatedWordmark(progress: progress), scheme: scheme))
            #expect(image.width == 300)
            #expect(image.height == 120)
        }
        let shape = try #require(RenderCheck.image(of: WordmarkShape().fill(Palette.text), scheme: scheme))
        #expect(shape.width == 300)
    }
}
```

- [ ] **Step 9: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/WordmarkTests`
Expected: `error: cannot find 'WordmarkShape' in scope` (the compiler may stop before it reports `AnimatedWordmark`), then `** TEST FAILED **`.

- [ ] **Step 10: Write the wordmark**

`RoomForMac/DesignSystem/Wordmark.swift`
```swift
import AppKit
import CoreText
import SwiftUI

/// The "RoomForMac" wordmark as a shape, built from CoreText glyph outlines
/// (Ruling 15: no wordmark asset until Plan 6 branding).
struct WordmarkShape: Shape {
    let text: String
    let fontName: String?
    let size: CGFloat

    /// `fontName` nil means SF Pro Rounded Semibold.
    init(text: String = "RoomForMac", fontName: String? = nil, size: CGFloat = 64) {
        self.text = text
        self.fontName = fontName
        self.size = size
    }

    func path(in rect: CGRect) -> Path {
        Self.fitted(Self.glyphPath(text: text, font: font), in: rect)
    }

    /// Width divided by height of the outline, for `aspectRatio(_:contentMode:)`; 1 when empty.
    var aspectRatio: CGFloat {
        let box = Self.glyphPath(text: text, font: font).boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return 1 }
        return box.width / box.height
    }

    private var font: CTFont {
        if let fontName {
            return CTFontCreateWithName(fontName as CFString, size, nil)
        }
        return Self.defaultFont(size: size)
    }

    /// SF Pro Rounded Semibold at `size`.
    static func defaultFont(size: CGFloat) -> CTFont {
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let rounded = system.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: rounded, size: size)
        else { return system as CTFont }
        return font as CTFont
    }

    /// The unscaled outline of `text` set in `font`, in CoreText coordinates
    /// (y up), with the origin at the start of the baseline.
    static func glyphPath(text: String, font: CTFont) -> CGPath {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let outline = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let runFont = Self.runFont(of: run) ?? font
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                // Spaces and other blank glyphs have no outline.
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let position = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                outline.addPath(glyph, transform: position)
            }
        }
        return outline.copy() ?? outline
    }

    /// `outline` flipped into SwiftUI's y-down space, scaled to fit `rect`
    /// with its aspect ratio kept, and centred.
    static func fitted(_ outline: CGPath, in rect: CGRect) -> Path {
        let box = outline.boundingBoxOfPath
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(outline).applying(transform)
    }

    /// CoreText substitutes a fallback font for characters `font` lacks; the
    /// run's own font draws them.
    private static func runFont(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        return CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() ? (value as! CTFont) : nil
    }
}

/// The wordmark drawing itself in: the outline strokes on as `progress` goes
/// 0 → 1, and the fill fades in over the last 20%. Animate `progress` with
/// `withAnimation`; the view interpolates it frame by frame.
struct AnimatedWordmark: View, Animatable {
    private var progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 0 until 80% progress, then linear to 1 at 100%.
    static func fillOpacity(progress: Double) -> Double {
        min(max((progress - 0.8) / 0.2, 0), 1)
    }

    var body: some View {
        let shape = WordmarkShape()
        ZStack {
            shape
                .fill(Palette.text)
                .opacity(Self.fillOpacity(progress: progress))
            shape
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(shape.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("RoomForMac"))
        .accessibilityAddTraits(.isHeader)
    }
}
```

- [ ] **Step 11: Run the wordmark tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/WordmarkTests`
Expected: `✔ Test run with 9 tests in 1 suite passed`, then `** TEST SUCCEEDED **`.

- [ ] **Step 12: Switch `EngineProblemView` to the glass components**

Replace the whole file. Only the containers and colours change:
- The window background becomes `Palette.canvas`.
- Task 3's `.fill.tertiary` card becomes `GlassCard(cornerRadius: 24, padding: 28)`.
- Its `.bordered` and `.borderedProminent` buttons become `GlassButton(.secondary)` and `GlassButton(.primary)`.
- The warning icon becomes `Palette.clay` and the message `Palette.textSecondary`.

Everything else stays as Task 3 wrote it:
- `init(problem:)`, the texts, the 540 pt card and the 180 pt details `ScrollView`;
- the four identifiers, with `engineProblemDetails` on the `DisclosureGroup`, not on the `ScrollView` inside it (that view only exists while the group is open);
- the copy action, built from `ErrorPresentation.appVersion(info:)` and `ErrorPresentation.osVersion()` and followed by the 2 s "Copied" label;
- the open action and the `#Preview`.

`RoomForMac/Engine/EngineProblemView.swift`
```swift
import AppKit
import SwiftUI

/// The blocking "Reinstall RoomForMac" card shown when the launch check fails
/// (spec §10). It fills the window; nothing else in the app is reachable.
struct EngineProblemView: View {
    static let downloadPage = URL(string: "https://github.com/gugag2003/RoomForMac/releases")!

    private let presentation: ErrorPresentation
    @State private var showsDetails = false
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    init(problem: EngineProblem) {
        presentation = ErrorPresentation(problem)
    }

    var body: some View {
        ZStack {
            Palette.canvas
                .ignoresSafeArea()
            card
                .frame(maxWidth: 540)
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        GlassCard(cornerRadius: 24, padding: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text("Reinstall RoomForMac")
                        .font(.title2.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.clay)
                }
                .accessibilityAddTraits(.isHeader)

                Text(presentation.message)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Show details", isExpanded: $showsDetails) {
                    ScrollView {
                        Text(presentation.details)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                }
                .accessibilityIdentifier(AccessibilityID.engineProblemDetails)

                HStack {
                    GlassButton(.secondary) {
                        copyDiagnostics()
                    } label: {
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy diagnostics", systemImage: "doc.on.doc")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.engineProblemCopy)

                    Spacer()

                    GlassButton("Open download page", prominence: .primary) {
                        openURL(Self.downloadPage)
                    }
                    .accessibilityIdentifier(AccessibilityID.engineProblemDownload)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.engineProblemCard)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copyDiagnostics() {
        let report = presentation.diagnostics(
            appVersion: ErrorPresentation.appVersion(info: Bundle.main.infoDictionary),
            osVersion: ErrorPresentation.osVersion()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        copied = true
    }
}

#Preview("Version mismatch") {
    EngineProblemView(problem: .versionMismatch(
        expected: .expected,
        found: EngineFingerprint(moleTag: "V0.0.0", moleCommit: "0000000", patchesSHA256: "none", patchCount: 0)
    ))
    .frame(width: 900, height: 600)
}
```

`GlassButton`'s `@ViewBuilder label:` takes the `if copied` switch as it is, so the copy button keeps Task 3's `Label`s. `.controlSize(.large)` is gone from the `HStack` because `GlassButton` sets it itself.

- [ ] **Step 13: Run the whole unit scheme and the API guards**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`
Expected: `** TEST SUCCEEDED **`. The Swift Testing summary includes `Glass components` (7 tests) and `Wordmark` (9 tests) next to the suites of Tasks 1–4.

Run: `grep -nE 'buttonStyle\(\.glass\(|GlassButtonStyle\(|@ContentBuilder|accessibilityPrefersCrossFadeTransitions' RoomForMac/DesignSystem/{GlassButton,GlassCard,MorphingGlass,GlassDots,Wordmark}.swift RoomForMac/Engine/EngineProblemView.swift`
Expected: no output and exit status 1. None of the banned or post-26.0 APIs is used.

Run: `for arch in arm64 x86_64; do xcrun swiftc -typecheck -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$arch-apple-macos26.0" -swift-version 6 RoomForMac/DesignSystem/*.swift && echo "$arch ok"; done`
Expected: `arm64 ok` and `x86_64 ok` with no diagnostics. The design system type-checks alone for both slices of the universal build at the 26.0 deployment target.

- [ ] **Step 14: Add the new strings to the String Catalog**

`xcodebuild` does not update `Localizable.xcstrings` (only the Xcode IDE does), so sync the catalog from the `.stringsdata` files that the Step 13 build left for the app target:

```bash
OBJ=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null \
    | awk '/Build settings for action .* and target RoomForMac:/ { t = 1 } t && $1 == "OBJECT_FILE_DIR_normal" { print $3; exit }')
xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --skip-marking-strings-stale --stringsdata "$OBJ"/*/*.stringsdata
git diff RoomForMac/Resources/Localizable.xcstrings
```

Expected: the diff adds `"Step %lld of %lld"`, with an `en` value `Step %1$lld of %2$lld` in state `new`. It also adds any of `"RoomForMac"`, `"Reinstall RoomForMac"`, `"Show details"`, `"Copied"`, `"Copy diagnostics"` and `"Open download page"` that Tasks 1 and 3 have not added already. The diff removes no key and marks none stale. `--skip-marking-strings-stale` keeps the sync from marking other tasks' entries stale.

- [ ] **Step 15: Commit**

```bash
git add RoomForMac/DesignSystem/GlassButton.swift RoomForMac/DesignSystem/GlassCard.swift \
    RoomForMac/DesignSystem/MorphingGlass.swift RoomForMac/DesignSystem/GlassDots.swift \
    RoomForMac/DesignSystem/Wordmark.swift RoomForMac/Engine/EngineProblemView.swift \
    RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/GlassComponentTests.swift RoomForMacTests/WordmarkTests.swift
git commit -F - <<'EOF'
feat(design): glass button, card, morphing glass, dots and wordmark

GlassButton keeps the system glass button styles (Ruling 5). GlassCard,
morphingGlass and GlassDots fall back to solid fills under Reduce
Transparency and to crossfades under Reduce Motion. The wordmark is drawn
from CoreText glyph outlines. The engine problem card now uses them.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

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
- Internal to this task (used by `BackdropView` and `BackdropTests` only; no other task may depend on them). They are declared inside the types and listed as extensions here for readability:
  ```swift
  extension KenBurns {
      struct Pose: Equatable, Sendable { var scale: CGFloat; var offset: CGSize; static let rest: Pose }  // rest = 1.0, .zero
      static var period: TimeInterval { get }                                              // Motion.driftPeriod in seconds
      static func pose(at time: TimeInterval, in size: CGSize, reduceMotion: Bool) -> Pose // .rest under Reduce Motion
  }
  extension BackdropImageLoader {
      enum Entry: Sendable { case photo(BackdropImages), noPhoto; var images: BackdropImages? { get } }
      static let fileExtensions: [String]                        // ["heic", "jpg", "png"]
      static let maxPixelSize: Int                               // 2560
      func cachedEntry(for scene: BackdropScene) -> Entry?       // no disk access; nil until the scene was loaded
      static func decode(_ url: URL) -> CGImage?                 // upright, ≤ maxPixelSize, decoded immediately
  }
  extension BackdropView {
      static let washOpacity: Double                             // 0.4
      static let driftFrameInterval: TimeInterval                // 1/30 s
      init(scene: BackdropScene, focus: Double, loader: BackdropImageLoader)   // tests pass a fixture loader
  }
  struct BackdropLayer: View {                                   // one scene's photo pair, or its fallback gradient
      let scene: BackdropScene; let images: BackdropImages?; let focus: Double
      static func clampedFocus(_ focus: Double) -> Double        // 0...1
  }
  ```

**Requirements:**
- `BackdropScene`:
  - `resourceName` is `backdrop-<rawValue>`, so `backdrop-smartClean` keeps its capital C.
  - `fallbackColors` has two or three distinct tokens per scene, never `clay` (destructive only) or a text token (`text`, `textSecondary`, `onAction`), and no two scenes share a gradient.
- `KenBurns`:
  - `scale` is 1.0 at the start of each loop and 1.0 + `Motion.driftMaxScaleIncrease` (1.08) halfway through, eased by a cosine, with period `Motion.driftPeriod` (60 s).
  - `offset` is at most 2% of `size` on each axis, and at most half of the margin the current zoom adds past each edge (`(scale − 1) / 4` of the size), so a drifting backdrop never shows its edge.
  - `pose(at:in:reduceMotion:)` returns `.rest` under Reduce Motion, so the drift stops at once (Review Focus 5, "the `KenBurns` pause").
- `BackdropImageLoader`:
  - `images(for:)` looks for `resourceName` with the extensions `heic`, then `jpg`, then `png` in `subdirectory`. A file that fails to decode is skipped, and the next extension is tried.
  - Decoding goes through `CGImageSourceCreateThumbnailAtIndex`, which applies the EXIF orientation, caps the longest side at `maxPixelSize` (2560) and decodes immediately (`kCGImageSourceShouldCacheImmediately`), so nothing decodes lazily on the main thread at draw time.
  - `blur` keeps the input's size, and its edges stay opaque. It uses one shared `CIContext` (`CIContext` is `Sendable` in SDK 27) and keeps the input's RGB color space, falling back to sRGB.
  - Results, including "no photo", are cached per scene under the `NSLock`. The disk work runs outside the lock. When two threads load the same scene at once, the first stored result wins, so callers always get the same `CGImage` instances.
- `BackdropView` layers, from the bottom:
  - A solid `Palette.canvas`.
  - The picture:
    - If the scene has a photo, the blurred image at full opacity, with the sharp image over it at opacity `focus`, both `aspectFill`. At `focus` 0 only the blurred image shows, and at 1 only the sharp one. The skeleton's "blurred at `1 − focus`" pair would let the canvas show through mid-fade (25% at `focus` 0.5), so the blurred layer stays opaque.
    - Otherwise, a `LinearGradient` of the fallback tokens, from top leading to bottom trailing.
  - A `Palette.canvas` wash at 40% opacity.

  The picture:
  - drifts with `KenBurns.pose` inside `TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion))`;
  - is clipped to the view;
  - applies `.backgroundExtensionEffect()`.

  The drift clock starts when the view is first created, so the first loop starts from rest. It restarts when Reduce Motion is turned off, so the backdrop does not jump.
- Loading and crossfade:
  - Photos load off the main thread: `.task(id: scene)` runs `images(for:)` in a detached task. On this Mac, decoding a 2560 × 1707 HEIC took about 0.3 s and blurring it about 0.07 s. The first blur in a process can take up to 0.7 s while Core Image sets up.
  - The view then swaps the displayed layer (`.id(scene)`, `.transition(.opacity)`) under `.animation(.easeInOut(duration: Motion.sectionCrossfade / .seconds(1)), value:)`, keyed on the *displayed* scene rather than the requested one. The 0.8 s crossfade therefore runs once, from the old photo straight to the new one.
  - A scene the loader already holds shows at once when the view is created, with no fade-in from canvas.
- Under Reduce Transparency, the view is a solid `Palette.canvas`: no image, no blur, no drift, no extension effect.
- The backdrop is decorative: `.allowsHitTesting(false)` and `.accessibilityHidden(true)`. Callers place it with `.background { BackdropView(…).ignoresSafeArea() }`. It has no user-facing strings.
- `project.yml` adds `RoomForMac/Resources/Backgrounds` as a folder reference, and excludes `Resources/Backgrounds` from the `RoomForMac` group source.
  - Without the exclude, XcodeGen 2.46 adds the folder a second time as a group, and Copy Bundle Resources copies every file twice: once flat into `Contents/Resources`, and once into `Contents/Resources/Backgrounds`. This was checked on a generated project.
  - With the folder reference, a photo dropped into the folder is copied by the next incremental build without regenerating, as verified.
- `Backgrounds/README.md` explains:
  - the naming, for all five scenes: `backdrop-onboarding.heic`, `backdrop-smartClean.heic` and so on;
  - the size (about 2560 px wide);
  - the conversion (`sips -s format heic --resampleWidth 2560 in.jpg --out backdrop-<scene>.heic`, which was verified: a 4000 px JPEG became a 2560 × 1707 HEIC);
  - the licence rule (public domain, CC0 or CC BY only, credited in `CREDITS.md`);
  - that no photos ship until the owner picks them.
- Tests (`RoomForMacTests/BackdropTests.swift`, one top-level suite `BackdropTests` with nested suites, so `-only-testing:RoomForMacTests/BackdropTests` runs them all):
  - `resourceName` for every scene; the `fallbackColors` rules;
  - `KenBurns.scale` stays within [1.0, 1.08] across 0...120 s in 0.5 s steps and has the same value at t and t+60; it is 1.0 at 0 s and 1.08 at 30 s;
  - `offset` stays within 2% of size and within half the zoom margin, for three window sizes;
  - `pose` is `.rest` under Reduce Motion;
  - the loader returns nil for a bundle without the resource;
  - with a generated 64×64 PNG in a temporary `.bundle` directory containing `Backgrounds/backdrop-status.png`, loaded through `Bundle(url:)`, the loader returns images of the original size, and a second call returns the same `CGImage` references (`===`);
  - the extension order: `jpg` wins over `png`, and `heic` wins over `jpg`. The HEIC test runs only when this Mac can encode HEIC;
  - a 3000 × 1000 photo loads as 2560 × 853;
  - `blur` output keeps the input's width and height, keeps its corners opaque, and softens a hard black/white edge;
  - the hosting app bundles `Contents/Resources/Backgrounds` as a folder;
  - `BackdropView` renders through `ImageRenderer` for every scene in light and dark;
  - `BackdropLayer` shows the blurred image at `focus` 0 and the sharp one at 1, and stays opaque at 0.5;
  - a scene without a photo draws an opaque gradient;
  - a cached photo shows under the wash, and with `_accessibilityReduceTransparency` set the view renders exactly the `canvas` pixel.

- [ ] **Step 1: Write the failing scene and drift tests**

Create `RoomForMacTests/BackdropTests.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import RoomForMac

@Suite("Backdrops")
struct BackdropTests {
    @Test func scenesAreTheFiveSurfacesInOrder() {
        #expect(BackdropScene.allCases == [.onboarding, .smartClean, .uninstaller, .terrain, .status])
    }

    @Test func resourceNamesPrefixTheRawValue() {
        #expect(BackdropScene.onboarding.resourceName == "backdrop-onboarding")
        #expect(BackdropScene.smartClean.resourceName == "backdrop-smartClean")
        #expect(BackdropScene.uninstaller.resourceName == "backdrop-uninstaller")
        #expect(BackdropScene.terrain.resourceName == "backdrop-terrain")
        #expect(BackdropScene.status.resourceName == "backdrop-status")
    }

    @Test(arguments: BackdropScene.allCases)
    func fallbackGradientUsesTwoOrThreeBackgroundTokens(_ scene: BackdropScene) {
        let tokens = scene.fallbackColors
        #expect((2...3).contains(tokens.count))
        #expect(Set(tokens).count == tokens.count)
        #expect(Set(tokens).isDisjoint(with: [.text, .textSecondary, .onAction, .clay]))
    }

    @Test func everySceneHasItsOwnGradient() {
        #expect(Set(BackdropScene.allCases.map(\.fallbackColors)).count == BackdropScene.allCases.count)
    }

    @Test func driftScaleStaysWithinEightPercentAndLoopsEverySixtySeconds() {
        for step in 0...240 {
            let time = Double(step) * 0.5
            let scale = KenBurns.scale(at: time)
            #expect(scale >= 1.0 && scale <= 1.08 + 1e-9, "scale \(scale) at \(time) s")
            #expect(abs(KenBurns.scale(at: time + 60) - scale) < 1e-9, "no loop at \(time) s")
        }
    }

    @Test func driftStartsAtRestAndPeaksHalfwayThroughTheLoop() {
        #expect(KenBurns.scale(at: 0) == 1.0)
        #expect(abs(KenBurns.scale(at: 30) - 1.08) < 1e-9)
        #expect(KenBurns.offset(at: 0, in: CGSize(width: 1100, height: 720)) == .zero)
    }

    @Test(arguments: [CGSize(width: 1100, height: 720), CGSize(width: 2560, height: 1440), CGSize(width: 320, height: 900)])
    func panStaysWithinTwoPercentAndNeverUncoversAnEdge(_ size: CGSize) {
        for step in 0...240 {
            let time = Double(step) * 0.5
            let offset = KenBurns.offset(at: time, in: size)
            // How far the zoomed backdrop reaches past each edge, as a fraction of the size.
            let margin = (KenBurns.scale(at: time) - 1) / 2
            #expect(abs(offset.width) <= size.width * 0.02 + 1e-9, "dx \(offset.width) at \(time) s")
            #expect(abs(offset.height) <= size.height * 0.02 + 1e-9, "dy \(offset.height) at \(time) s")
            #expect(abs(offset.width) <= size.width * margin + 1e-9, "left or right edge shows at \(time) s")
            #expect(abs(offset.height) <= size.height * margin + 1e-9, "top or bottom edge shows at \(time) s")
        }
    }

    @Test func reduceMotionHoldsTheRestingPose() {
        let size = CGSize(width: 1100, height: 720)
        for time in [0.0, 12.5, 30, 47.25, 90] {
            #expect(KenBurns.pose(at: time, in: size, reduceMotion: true) == .rest)
        }
        let moving = KenBurns.pose(at: 20, in: size, reduceMotion: false)
        #expect(moving.scale == KenBurns.scale(at: 20))
        #expect(moving.offset == KenBurns.offset(at: 20, in: size))
        #expect(moving != .rest)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: FAIL to compile with `cannot find 'BackdropScene' in scope` and `cannot find type 'BackdropScene' in scope`, then `** TEST FAILED **`. No `KenBurns` error is reported yet; both types arrive in Step 3.

- [ ] **Step 3: Write the scene list and the drift math**

`RoomForMac/DesignSystem/Backdrop/BackdropScene.swift`:

```swift
/// The landscape behind each surface (spec §11.3).
///
/// Photos are looked up by `resourceName` in the app's `Backgrounds` folder. None ship until the owner
/// picks them, so every scene also names the palette tokens of the gradient drawn in their place.
enum BackdropScene: String, CaseIterable, Sendable {
    /// Fitz Roy and Laguna de los Tres at sunrise, Patagonia.
    case onboarding
    /// Yosemite Valley from Tunnel View.
    case smartClean
    /// Cerro Torre and the Fitz Roy massif, Patagonia.
    case uninstaller
    /// Half Dome, Yosemite.
    case terrain
    /// Torres del Paine, Patagonia.
    case status

    /// The photo's file name inside `Backgrounds/`, without its extension: `backdrop-smartClean`.
    var resourceName: String { "backdrop-\(rawValue)" }

    /// The fallback gradient, from top leading to bottom trailing.
    ///
    /// Only background tokens appear: `clay` is kept for destructive confirmations and the text tokens
    /// for text. Each scene gets its own mix so sections still look different without photos.
    var fallbackColors: [Palette.Token] {
        switch self {
        case .onboarding: [.grass, .moss, .canvas]     // first light on the spires, down to the lake
        case .smartClean: [.canvas, .moss, .action]    // pale sky over a green valley floor
        case .uninstaller: [.surface, .moss, .grass]   // ice and granite above dry steppe
        case .terrain: [.grass, .action]               // warm granite into dark forest
        case .status: [.canvas, .grass, .moss]         // pale sky, tan steppe, olive scrub
        }
    }
}
```

`RoomForMac/DesignSystem/Backdrop/KenBurns.swift`:

```swift
import CoreGraphics
import Foundation

/// The slow backdrop drift (spec §11.3): one loop every `Motion.driftPeriod`, zooming from 1.0 up to
/// 1.0 + `Motion.driftMaxScaleIncrease` and back while panning a little.
///
/// Pure math, so it can be tested. `BackdropView` feeds it the time from a `TimelineView`.
enum KenBurns {
    /// One frame of the drift: how much to scale the backdrop and how far to move it.
    struct Pose: Equatable, Sendable {
        var scale: CGFloat
        var offset: CGSize

        /// No zoom and no pan: where every loop starts, and where Reduce Motion holds the backdrop.
        static let rest = Pose(scale: 1, offset: .zero)
    }

    /// The loop length in seconds.
    static var period: TimeInterval { Motion.driftPeriod / .seconds(1) }

    /// 1.0 at the start of each loop, 1.0 + `Motion.driftMaxScaleIncrease` halfway through, eased in between.
    static func scale(at time: TimeInterval) -> CGFloat {
        1 + Motion.driftMaxScaleIncrease * (1 - cos(phase(at: time))) / 2
    }

    /// A pan along one loop of a cardioid.
    ///
    /// It reaches at most 2% of `size` on each axis. It never moves further than half of the margin the
    /// current zoom adds past each edge, so the backdrop's edge never comes into view.
    static func offset(at time: TimeInterval, in size: CGSize) -> CGSize {
        let reach = (scale(at: time) - 1) / 4
        let angle = phase(at: time)
        return CGSize(width: size.width * reach * cos(angle), height: size.height * reach * sin(angle))
    }

    /// The pose to draw: the drift, or `.rest` under Reduce Motion so the backdrop stops at once.
    static func pose(at time: TimeInterval, in size: CGSize, reduceMotion: Bool) -> Pose {
        guard !reduceMotion else { return .rest }
        return Pose(scale: scale(at: time), offset: offset(at: time, in: size))
    }

    /// The angle through the current loop, 0 ..< 2π.
    private static func phase(at time: TimeInterval) -> CGFloat {
        CGFloat(time.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
    }
}
```

`Motion.driftPeriod / .seconds(1)` uses the standard library's `Duration / Duration -> Double`. Do not add a `Duration` extension: other tasks may add their own, and two app-target extensions with the same member do not compile.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: `✔ Test run with 8 tests in 1 suite passed`, then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Append the failing loader tests**

Append to `RoomForMacTests/BackdropTests.swift`. The file-private helpers `PhotoBundle` and `TestImage` are shared with Step 10's tests. `PhotoBundle` deletes its folder when it is released, so, like Task 3's `TemporaryDirectory` and Task 7's `TemporaryDefaults`, it lives as long as the test: the loader suite keeps it in a stored property, and Step 10's one photo test holds it with `withExtendedLifetime`.

```swift
extension BackdropTests {
    @Suite("Image loader")
    struct Loader {
        /// Held by the suite so the bundle folder outlives every use inside a test.
        private let fixture: PhotoBundle

        init() throws {
            fixture = try PhotoBundle()
        }

        @Test func aBundleWithoutPhotosHasNoImages() throws {
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            for scene in BackdropScene.allCases {
                #expect(loader.images(for: scene) == nil)
            }
        }

        @Test func loadsAPhotoAtItsSizeWithABlurredCopy() throws {
            try fixture.add("backdrop-status.png", TestImage.solid(width: 64, height: 64, red: 0.2, green: 0.5, blue: 0.3))
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            let images = try #require(loader.images(for: .status))
            #expect(images.sharp.width == 64 && images.sharp.height == 64)
            #expect(images.blurred.width == 64 && images.blurred.height == 64)
            #expect(images.sharp !== images.blurred)
            #expect(loader.images(for: .onboarding) == nil)
        }

        @Test func aSecondCallReturnsTheCachedImages() throws {
            try fixture.add("backdrop-status.png", TestImage.solid(width: 64, height: 64, red: 0.2, green: 0.5, blue: 0.3))
            let loader = BackdropImageLoader(bundle: try fixture.bundle())
            #expect(loader.cachedEntry(for: .status) == nil)
            let first = try #require(loader.images(for: .status))
            let second = try #require(loader.images(for: .status))
            #expect(first.sharp === second.sharp)
            #expect(first.blurred === second.blurred)
            #expect(loader.cachedEntry(for: .status)?.images?.sharp === first.sharp)
        }

        @Test func prefersJPEGOverPNG() throws {
            try fixture.add("backdrop-terrain.png", TestImage.solid(width: 64, height: 64, red: 1, green: 0, blue: 0))
            try fixture.add("backdrop-terrain.jpg", TestImage.solid(width: 32, height: 32, red: 0, green: 1, blue: 0))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .terrain))
            #expect(images.sharp.width == 32)
        }

        @Test(.enabled(if: TestImage.canWriteHEIC))
        func prefersHEICOverJPEG() throws {
            try fixture.add("backdrop-terrain.jpg", TestImage.solid(width: 32, height: 32, red: 0, green: 1, blue: 0))
            try fixture.add("backdrop-terrain.heic", TestImage.solid(width: 48, height: 48, red: 0, green: 0, blue: 1))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .terrain))
            #expect(images.sharp.width == 48)
        }

        @Test func scalesLargePhotosDownToTheMaximumSize() throws {
            try fixture.add("backdrop-smartClean.png", TestImage.solid(width: 3000, height: 1000, red: 0.5, green: 0.5, blue: 0.5))
            let images = try #require(BackdropImageLoader(bundle: try fixture.bundle()).images(for: .smartClean))
            #expect(images.sharp.width == BackdropImageLoader.maxPixelSize)
            #expect(abs(images.sharp.height - 853) <= 1)
        }

        @Test func blurKeepsTheSize() throws {
            let image = TestImage.solid(width: 64, height: 40, red: 0.2, green: 0.5, blue: 0.3)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 40))
            #expect(blurred.width == 64)
            #expect(blurred.height == 40)
        }

        @Test func blurKeepsTheEdgesOpaque() throws {
            let image = TestImage.solid(width: 64, height: 40, red: 1, green: 0, blue: 0)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 40))
            let corner = TestImage.pixel(blurred, x: 0, y: 0)
            #expect(corner.alpha == 255)
            #expect(corner.red > 245 && corner.green < 10 && corner.blue < 10)
        }

        @Test func blurSoftensAHardEdge() throws {
            let image = TestImage.blackAndWhiteHalves(width: 64, height: 40)
            let blurred = try #require(BackdropImageLoader.blur(image, radius: 8))
            #expect(TestImage.pixel(image, x: 31, y: 20).red == 0)
            let edge = TestImage.pixel(blurred, x: 31, y: 20)
            #expect(edge.red > 40 && edge.red < 215, "red \(edge.red) at the black side of the edge")
        }

        /// Pins the folder reference in `project.yml`: a plain group would copy the photos flat into Resources.
        @Test func theAppBundlesTheBackgroundsFolder() throws {
            let folder = try #require(Bundle.main.resourceURL).appending(path: "Backgrounds")
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}

/// A throwaway `.bundle` directory with a `Backgrounds` folder, removed when released.
/// Keep it alive for the whole test: in a suite property, or with `withExtendedLifetime`.
private final class PhotoBundle {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "BackdropTests-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: root.appending(path: "Backgrounds"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func bundle() throws -> Bundle {
        try #require(Bundle(url: root))
    }

    /// Writes `image` as `Backgrounds/<fileName>`, encoded by the file name's extension.
    func add(_ fileName: String, _ image: CGImage) throws {
        let url = root.appending(path: "Backgrounds/\(fileName)")
        let type = try #require(UTType(filenameExtension: url.pathExtension))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination), "could not write \(fileName)")
    }
}

/// Small generated images and a pixel reader.
private enum TestImage {
    struct Pixel: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    /// Whether this Mac can encode HEIC; some virtual machines cannot.
    static let canWriteHEIC: Bool = {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, solid(width: 48, height: 48, red: 0, green: 0, blue: 1), nil)
        return CGImageDestinationFinalize(destination)
    }()

    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Black on the left half, white on the right.
    static func blackAndWhiteHalves(width: Int, height: Int) -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
    }

    /// The pixel at `x` from the left and `y` from the top, converted to 8-bit sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = bitmap(width: image.width, height: image.height, data: buffer.baseAddress)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        // A bitmap context stores its top row first.
        let index = (y * image.width + x) * 4
        return Pixel(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2], alpha: bytes[index + 3])
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = bitmap(width: width, height: height, data: nil)
        body(context)
        return context.makeImage()!
    }

    private static func bitmap(width: Int, height: Int, data: UnsafeMutableRawPointer?) -> CGContext {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: FAIL to compile with `cannot find 'BackdropImageLoader' in scope`. There are also knock-on errors inside the `#expect` macros, such as `generic parameter 'some StringProtocol' could not be inferred`.

- [ ] **Step 7: Write the loader**

`RoomForMac/DesignSystem/Backdrop/BackdropImageLoader.swift`:

```swift
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// A backdrop photo and its blurred copy. The blur is computed once when the photo loads (Ruling 6),
/// never per frame.
struct BackdropImages: @unchecked Sendable {
    let sharp: CGImage
    let blurred: CGImage
}

/// Loads backdrop photos from a bundle, blurs each one once, and keeps both for the life of the loader.
///
/// Safe to call from any thread. Decoding a 2560 px HEIC and blurring it takes long enough to drop
/// frames, so `BackdropView` calls `images(for:)` off the main thread.
final class BackdropImageLoader: @unchecked Sendable {
    /// What the loader knows about one scene.
    enum Entry: Sendable {
        case photo(BackdropImages)
        case noPhoto

        var images: BackdropImages? {
            if case .photo(let images) = self { images } else { nil }
        }
    }

    static let shared = BackdropImageLoader()

    /// File extensions tried for each scene, in order.
    static let fileExtensions = ["heic", "jpg", "png"]

    /// The longest side a photo keeps once loaded. Larger files are scaled down as they are decoded.
    static let maxPixelSize = 2560

    /// One Core Image context for every blur. `CIContext` is thread-safe and costly to create.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private let bundle: Bundle
    private let blurRadius: Double
    private let subdirectory: String
    private let lock = NSLock()
    private var entries: [BackdropScene: Entry] = [:]   // guarded by `lock`

    init(bundle: Bundle = .main, blurRadius: Double = 40, subdirectory: String = "Backgrounds") {
        self.bundle = bundle
        self.blurRadius = blurRadius
        self.subdirectory = subdirectory
    }

    /// The photo pair for `scene`, or nil when the bundle has no photo for it. Loads on the first call
    /// and returns the same images on every later call.
    func images(for scene: BackdropScene) -> BackdropImages? {
        if let entry = cachedEntry(for: scene) {
            return entry.images
        }
        let loaded = load(scene)
        return lock.withLock {
            // Two threads can load the same scene at once. Keep the first result so callers always
            // get the same instances.
            if let earlier = entries[scene] {
                return earlier.images
            }
            entries[scene] = loaded
            return loaded.images
        }
    }

    /// What is already known about `scene`, without touching the disk: nil until it has been loaded.
    func cachedEntry(for scene: BackdropScene) -> Entry? {
        lock.withLock { entries[scene] }
    }

    /// A Gaussian blur that keeps the image's size and opaque edges.
    ///
    /// The input is extended past its edges first (`clampedToExtent`), so the blur does not fade the
    /// border to transparent, and the result is cropped back to the original extent.
    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else {
            return nil
        }
        let keepsColorSpace = image.colorSpace?.model == .rgb
        guard let colorSpace = keepsColorSpace ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Decodes the image at `url` now, upright and at most `maxPixelSize` on its longest side.
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func load(_ scene: BackdropScene) -> Entry {
        for fileExtension in Self.fileExtensions {
            guard
                let url = bundle.url(forResource: scene.resourceName, withExtension: fileExtension, subdirectory: subdirectory),
                let sharp = Self.decode(url),
                let blurred = Self.blur(sharp, radius: blurRadius)
            else {
                continue
            }
            return .photo(BackdropImages(sharp: sharp, blurred: blurred))
        }
        return .noPhoto
    }
}
```

- [ ] **Step 8: Add the Backgrounds folder**

Create `RoomForMac/Resources/Backgrounds/README.md`. It also keeps the otherwise empty folder in git; XcodeGen fails on a source path that does not exist.

````markdown
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
````

In `project.yml`, change the app target's `sources` so the folder is excluded from the `RoomForMac` group and added back as a folder reference. Leave everything else in `project.yml` as it is.

Find:

```yaml
    sources:
      - path: RoomForMac
        excludes:
          - Generated
      # Written by the "Prepare engine" phase before compiling; git-ignored.
      - path: RoomForMac/Generated/EngineExpectation.swift
        optional: true
```

Replace with:

```yaml
    sources:
      - path: RoomForMac
        excludes:
          - Generated
          - Resources/Backgrounds
      # Written by the "Prepare engine" phase before compiling; git-ignored.
      - path: RoomForMac/Generated/EngineExpectation.swift
        optional: true
      - path: RoomForMac/Resources/Backgrounds
        type: folder
        buildPhase: resources
```

Check the generated project: `xcodegen generate && grep -n 'Backgrounds\|README' RoomForMac.xcodeproj/project.pbxproj`. Expected: one `PBXFileReference` for `Backgrounds` with `lastKnownFileType = folder` and `path = RoomForMac/Resources/Backgrounds`, one `Backgrounds in Resources` build file, and no line for `README.md`.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: `✔ Test run with 18 tests in 2 suites passed`, then `** TEST SUCCEEDED **`.
- If `theAppBundlesTheBackgroundsFolder()` fails, the `project.yml` change is missing: without it, `README.md` lands flat in `Contents/Resources`.
- The first blur takes about 0.7 s while Core Image sets up its Metal context.

- [ ] **Step 10: Append the failing view tests**

Append to `RoomForMacTests/BackdropTests.swift`:

```swift

extension BackdropTests {
    @MainActor
    @Suite("Backdrop view")
    struct Rendering {
        @Test(arguments: BackdropScene.allCases, [ColorScheme.light, .dark])
        func rendersEveryScene(_ scene: BackdropScene, in colorScheme: ColorScheme) {
            let renderer = ImageRenderer(content: BackdropView(scene: scene)
                .frame(width: 300, height: 200)
                .environment(\.colorScheme, colorScheme))
            #expect(renderer.cgImage != nil)
        }

        @Test func focusIsClampedToZeroThroughOne() {
            #expect(BackdropLayer.clampedFocus(-0.5) == 0)
            #expect(BackdropLayer.clampedFocus(0.3) == 0.3)
            #expect(BackdropLayer.clampedFocus(1.7) == 1)
        }

        @Test func focusFadesFromTheBlurredPhotoToTheSharpOne() throws {
            let images = BackdropImages(
                sharp: TestImage.solid(width: 60, height: 40, red: 1, green: 0, blue: 0),
                blurred: TestImage.solid(width: 60, height: 40, red: 0, green: 0, blue: 1)
            )
            let blurred = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 0))
            #expect(blurred.blue > 200 && blurred.red < 50)
            let sharp = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 1))
            #expect(sharp.red > 200 && sharp.blue < 50)
            let halfway = try centerPixel(of: BackdropLayer(scene: .status, images: images, focus: 0.5))
            #expect(halfway.red > 60 && halfway.blue > 60)
            #expect(halfway.alpha == 255, "the canvas shows through mid-fade")
        }

        @Test func aSceneWithoutAPhotoDrawsAnOpaqueGradient() throws {
            let pixel = try centerPixel(of: BackdropLayer(scene: .terrain, images: nil, focus: 0))
            #expect(pixel.alpha == 255)
        }

        @Test func aLoadedPhotoShowsUnderTheWashAndReduceTransparencyHidesIt() throws {
            let fixture = try PhotoBundle()
            // The bundle folder must outlive the last render, not just the last use of `fixture`.
            try withExtendedLifetime(fixture) {
                try fixture.add("backdrop-status.png", TestImage.solid(width: 60, height: 40, red: 1, green: 0, blue: 0))
                let loader = BackdropImageLoader(bundle: try fixture.bundle())
                _ = try #require(loader.images(for: .status))
                let canvas = try centerPixel(of: Palette.canvas)

                let washed = try centerPixel(of: BackdropView(scene: .status, focus: 1, loader: loader))
                #expect(washed.red > washed.green + 100, "the photo is not showing")
                #expect(washed.green > 40, "the canvas wash is missing")

                // `_accessibilityReduceTransparency` is the settable twin of the read-only
                // `accessibilityReduceTransparency`, the same switch SwiftUI previews use.
                let solid = try centerPixel(of: BackdropView(scene: .status, focus: 1, loader: loader)
                    .environment(\._accessibilityReduceTransparency, true))
                #expect(solid == canvas)
            }
        }

        /// Renders `view` at 60 × 40 points in the light appearance, whatever the Mac's own appearance is.
        private func centerPixel(of view: some View) throws -> TestImage.Pixel {
            let renderer = ImageRenderer(content: view.frame(width: 60, height: 40).environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return TestImage.pixel(image, x: image.width / 2, y: image.height / 2)
        }
    }
}
```

- [ ] **Step 11: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: FAIL to compile with `cannot find 'BackdropLayer' in scope` and `cannot find 'BackdropView' in scope`. A knock-on `cannot infer key path type from context` error comes from the `.environment` calls on the missing view.

- [ ] **Step 12: Write the view**

`RoomForMac/DesignSystem/Backdrop/BackdropView.swift`:

```swift
import SwiftUI

/// The full-window landscape behind a surface (spec §11.3): the scene's photo, or its fallback gradient,
/// under a canvas wash, drifting slowly, and crossfading when the scene changes.
///
/// Place it with `.background { BackdropView(scene: …).ignoresSafeArea() }`. `focus` pulls the photo from
/// fully blurred (0) to sharp (1); callers animate it.
///
/// - Reduce Transparency: a solid canvas, with no photo and no blur.
/// - Reduce Motion: no drift.
struct BackdropView: View {
    /// Opacity of the canvas wash over the picture, for legibility.
    static let washOpacity = 0.4

    /// The drift redraws at most this often.
    static let driftFrameInterval: TimeInterval = 1.0 / 30.0

    private let scene: BackdropScene
    private let focus: Double
    private let loader: BackdropImageLoader

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Shown?
    @State private var driftStart = Date()

    init(scene: BackdropScene, focus: Double = 0) {
        self.init(scene: scene, focus: focus, loader: .shared)
    }

    /// Tests pass a loader over a fixture bundle.
    init(scene: BackdropScene, focus: Double, loader: BackdropImageLoader) {
        self.scene = scene
        self.focus = focus
        self.loader = loader
        // A scene loaded before (by an earlier backdrop, say) shows at once instead of fading in again.
        _shown = State(initialValue: loader.cachedEntry(for: scene).map { Shown(scene: scene, images: $0.images) })
    }

    var body: some View {
        ZStack {
            Palette.canvas
            if !reduceTransparency {
                drift
                Palette.canvas.opacity(Self.washOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scene) { await show(scene) }
        .onChange(of: reduceMotion) { _, isReduced in
            // Start the next loop from rest instead of jumping back to where the old one was.
            if !isReduced {
                driftStart = Date()
            }
        }
    }

    private var drift: some View {
        TimelineView(.animation(minimumInterval: Self.driftFrameInterval, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let pose = KenBurns.pose(
                    at: context.date.timeIntervalSince(driftStart),
                    in: proxy.size,
                    reduceMotion: reduceMotion
                )
                layers
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(pose.scale)
                    .offset(pose.offset)
            }
        }
        .clipped()
        .backgroundExtensionEffect()
        .animation(.easeInOut(duration: Motion.sectionCrossfade / .seconds(1)), value: shown?.scene)
    }

    private var layers: some View {
        ZStack {
            if let shown {
                BackdropLayer(scene: shown.scene, images: shown.images, focus: focus)
                    .id(shown.scene)
                    .transition(.opacity)
            }
        }
    }

    /// Loads the scene's photo off the main thread, then swaps it in; the swap is the crossfade.
    private func show(_ scene: BackdropScene) async {
        let loader = self.loader
        let images = await Task.detached(priority: .userInitiated) {
            loader.images(for: scene)
        }.value
        guard !Task.isCancelled else {
            return
        }
        shown = Shown(scene: scene, images: images)
    }

    private struct Shown {
        let scene: BackdropScene
        let images: BackdropImages?
    }
}

/// One scene's picture: the photo pair pulled into focus, or the fallback gradient when there is no photo.
struct BackdropLayer: View {
    let scene: BackdropScene
    let images: BackdropImages?
    let focus: Double

    static func clampedFocus(_ focus: Double) -> Double {
        min(max(focus, 0), 1)
    }

    var body: some View {
        if let images {
            // The blurred photo stays fully opaque underneath, so the canvas never shows through mid-fade.
            ZStack {
                picture(images.blurred)
                picture(images.sharp)
                    .opacity(Self.clampedFocus(focus))
            }
        } else {
            LinearGradient(
                colors: scene.fallbackColors.map { Palette.color($0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// Fills the available space, cropping the photo instead of letterboxing it.
    private func picture(_ image: CGImage) -> some View {
        Color.clear
            .overlay {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }
}
```

- [ ] **Step 13: Run the tests to verify they pass, then the whole unit scheme**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BackdropTests`
Expected: `✔ Test run with 23 tests in 3 suites passed`, then `** TEST SUCCEEDED **`. The build shows no Swift warnings for the backdrop files.

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`
Expected: `** TEST SUCCEEDED **`, with Tasks 1–5's tests still green.

- [ ] **Step 14: Commit**

```bash
git add RoomForMac/DesignSystem/Backdrop/BackdropScene.swift RoomForMac/DesignSystem/Backdrop/KenBurns.swift \
    RoomForMac/DesignSystem/Backdrop/BackdropImageLoader.swift RoomForMac/DesignSystem/Backdrop/BackdropView.swift \
    RoomForMac/Resources/Backgrounds/README.md RoomForMacTests/BackdropTests.swift project.yml
git commit -F - <<'EOF'
feat(design): backdrop scenes, Ken Burns drift and pre-blurred photo loader

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 7: App shell — preferences, AppModel, sidebar, RootView, placeholders

**Files:**
- Create: `RoomForMac/App/AppPreferences.swift`, `RoomForMac/App/AppModel.swift`, `RoomForMac/App/SidebarSection.swift`, `RoomForMac/App/RootView.swift`, `RoomForMac/App/AppDependencies.swift`, `RoomForMac/Features/SmartClean/SmartCleanPlaceholderView.swift`, `RoomForMac/Features/Uninstaller/UninstallerPlaceholderView.swift`, `RoomForMac/Features/Status/StatusPlaceholderView.swift`, `RoomForMacTests/AppPreferencesTests.swift`, `RoomForMacTests/AppModelTests.swift`
- Create (added by this section): `RoomForMacTests/Support/TemporaryDefaults.swift`, a throwaway UserDefaults suite that Tasks 8 and 11–15 reuse (no later task writes its own); `RoomForMacTests/RootViewTests.swift`, for the screen precedence, the identifiers and the placeholders.
- Modify: `RoomForMac/App/RoomForMacApp.swift`, `RoomForMac/App/AccessibilityID.swift`
- Modify (added; the String Catalog grows every task): `RoomForMac/Resources/Localizable.xcstrings`

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
- Added by this task (internal to this task; later tasks may use them, and nothing above changes):
  ```swift
  struct AppPreferences: @unchecked Sendable {        // UserDefaults is documented thread-safe
      enum Key { static let onboardingCompleted, onboardingStep, analyticsEnabled, notificationsWanted, lastKnownStatePrefix }
      // every property setter is `nonmutating`, so `let preferences` can be written and all copies share one store
  }
  extension AppDependencies {
      static func forMode(_ mode: RuntimeMode) -> AppDependencies   // DEBUG: .uiTest(s) → forScenario(s); otherwise live()
      static let scenarioSuiteName = "RoomForMac.UITest"          // DEBUG only
  }
  enum RootScreen: Equatable, Sendable {
      case checking, engineProblem(EngineProblem), onboarding, main
      static func resolve(engine: EnginePhase, isOnboarded: Bool) -> RootScreen
  }
  struct SectionPlaceholderView: View { let section: SidebarSection }   // shared by the three placeholder views
  extension AccessibilityID {
      static let engineProblemDownload = "engineProblem.download"   // Task 3's addition, kept
      static let onboardingPlaceholder = "onboarding.placeholder"   // the stand-in until Task 12
  }
  // RoomForMacTests/Support/TemporaryDefaults.swift
  final class TemporaryDefaults {                     // store it in a suite property; deinit removes the suite
      let suiteName: String; let defaults: UserDefaults
      init() throws
      var preferences: AppPreferences { get }
  }
  ```
- Notes for later tasks:
  - Unit tests build `AppDependencies` in exactly one place, `AppModelTests.dependencies(_:)`, with the memberwise initializer. When Task 12 adds `permissionCheckers`, `needsMoveStep` and `loginItem`, it updates that helper, or gives the new stored properties default values so the call keeps compiling.
  - Task 12 replaces `OnboardingPlaceholderView` in `RootView.swift`. If it also deletes `AccessibilityID.onboardingPlaceholder`, it drops that one line from `RootViewTests.accessibilityIdentifiers`.
  - For Task 15's XCUITests, as checked in-process through AppKit accessibility: `sidebar` is an outline, each row's identifier sits on the row's static text (`app.staticTexts["sidebar.status"]`), `engine.checking` is a busy indicator, and each `placeholder.<raw>` is a containing element (`.accessibilityElement(children: .contain)`, like Task 3's card, which reports as a group). `app.descendants(matching: .any)[id]` finds all of them.

**Requirements:**
- `AppPreferences`:
  - The keys and defaults are those in the interface. A missing `analytics.enabled` reads as `true`. A stored value goes through `UserDefaults.bool(forKey:)`, so `defaults write com.roomformac.app analytics.enabled 0` turns analytics off.
  - Setting `onboardingStep` or a last-known state to `nil` removes the key.
  - The setters are `nonmutating`, and all reads and writes go straight to `UserDefaults`. So `AppModel` can write through its `let dependencies`, and every copy sees the same values.
- `AppModel`:
  - `engine` starts `.checking`, `selection` `.smartClean` and `pendingFirstScan` false. `isOnboarded` is read from `preferences.onboardingCompleted` in `init`.
  - `start()` marks itself started before it awaits `engineCheck`. A second call, including one made while the check runs, returns at once. Success gives `.ready(installation)` and failure `.broken(problem)`.
  - `completeOnboarding(startFirstScan:)` sets `onboardingCompleted = true`, clears `onboardingStep`, and sets `isOnboarded`, `selection = .smartClean` and `pendingFirstScan = startFirstScan`.
  - Plan 3 must not start `StatusService` or a scan while `isOnboarded` is false (Ruling 10). The doc comment says so.
- `RootView` precedence (`RootScreen.resolve`):
  - `.checking` → a centred `ProgressView` with the label "Checking RoomForMac…" (identifier `checkingEngine`), whatever the onboarding state.
  - `.broken` → `EngineProblemView`, whatever the onboarding state.
  - Ready, but not onboarded → `OnboardingView` (Task 12). Until Task 12 lands, a placeholder: "Welcome to RoomForMac" on a `GlassCard` over `BackdropView(scene: .onboarding)`, with identifier `onboarding.placeholder`. Task 12 replaces it.
  - Otherwise, a `NavigationSplitView` with:
    - a sidebar `List(SidebarSection.allCases, selection: $model.selection)` using `Label(title, systemImage:)`, with `navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)`. Each row carries `.tag(section)`, because `SidebarSection.id` is a `String` while the selection is a `SidebarSection`. The sidebar gets no `.glassEffect()`: macOS 26 already draws it as glass;
    - a detail showing the placeholder view for the selection;
    - `BackdropView(scene: selection.backdrop)` behind everything (`.background { … .ignoresSafeArea() }`);
    - `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`.
  - The root content has a minimum size of 800 × 540 pt, and the window's own background is `Palette.canvas` (`.containerBackground(Palette.canvas, for: .window)`).
- Placeholders: a `ContentUnavailableView` inside a `GlassCard` (at most 420 pt wide), carrying the section title, its symbol, and "Coming in the next update.", in `Palette.text` and `Palette.textSecondary`. The card is an `.accessibilityElement(children: .contain)` with identifier `placeholder(section)`. The three placeholder views share `SectionPlaceholderView`.
- `RoomForMacApp`:
  - Builds `AppModel` from `AppDependencies.forMode(RuntimeMode.current)`: `.forScenario(s)` in `.uiTest(s)`, which only DEBUG builds produce, and `.live()` otherwise.
  - Main window: `Window("RoomForMac", id: "main") { RootView(model:).task { await model.start() } }` with `.windowStyle(.hiddenTitleBar)`, `.windowToolbarStyle(.unified)`, `.defaultSize(width: 1100, height: 720)` and `.windowBackgroundDragBehavior(.enabled)`.
  - The `Settings` scene keeps Task 1's placeholder until Task 14.
  - `.unitTestHost` is unchanged from Task 1: `RoomForMacLauncher` runs `UnitTestHostApp`, and `RoomForMacApp` is never built.
- `AppDependencies.live` wires `engineCheck` to `EngineHealthCheck().run()`, and `openURL` to `NSWorkspace.shared.open`.
- `AppDependencies.forScenario` (DEBUG only; Task 15 adds the permission fakes):
  - Preferences live in the suite `RoomForMac.UITest`, removed with `removePersistentDomain(forName:)` on every call. `UserDefaults.standard` is never touched.
  - `onboardingCompleted` is true only for `.onboarded`.
  - `.onboarding` and `.onboarded` locate the bundled engine without the helper self-test: `.success(EngineInstallation.bundled())`, or `.installationInvalid` with its message. `.engineBroken` fails with `.versionMismatch(expected: .expected, found:)`, where `found` is `.expected` with `moleTag` "V0.0.0".
  - `openURL` does nothing, so a UI test never opens a browser or System Settings.
- Tests:
  - `AppPreferences`: the defaults, round-trips through a second `AppPreferences` on the same store, the exact keys, `nil` removing keys, last-known states kept per permission, and a string `"0"` from the command line. Each test has its own `TemporaryDefaults` suite, removed afterwards.
  - `AppModel.start` → `.ready` for success and `.broken` for failure.
  - `start` twice runs the check once, counted through a closure. The same holds for two concurrent calls while the check is held open.
  - `completeOnboarding(startFirstScan: true)` persists, clears the step, and sets `isOnboarded`, `selection` and `pendingFirstScan`. With `false`, `pendingFirstScan` stays false.
  - `isOnboarded` comes from preferences.
  - `SidebarSection` order, ids, titles (the `LocalizedStringResource` key and its resolved string), symbols and backdrops.
  - `AppDependencies.forMode(.uiTest(_:))` and `forScenario` (serialized, because they share one suite): the scenario's onboarding flag, a clean suite on every call, `UserDefaults.standard` left alone, and the `engine-broken` mismatch.
  - `RootScreen.resolve` for every engine phase in both onboarding states, every identifier string, and each placeholder rendering through `ImageRenderer` at 600 × 400 in light and dark.

- [ ] **Step 1: Write the test support and the failing preferences tests**

`RoomForMacTests/Support/TemporaryDefaults.swift`:
```swift
import Foundation
import Testing
@testable import RoomForMac

/// A UserDefaults suite of its own, so tests never read or write the app's real
/// preferences. The suite is removed when the last reference goes away: store it
/// in a suite property so it outlives every use inside a test.
final class TemporaryDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "RoomForMacTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    /// Preferences over this suite. Every call reads and writes the same storage.
    var preferences: AppPreferences {
        AppPreferences(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
```

Swift may release a local object right after its last use, so a `TemporaryDefaults` held only in a local variable could remove its suite in the middle of a test. Tests keep it in a stored property of the suite instead, which lives until the test ends. Task 3's `TemporaryDirectory` follows the same rule, and so does every later temporary store: a suite property, or `withExtendedLifetime` around the whole test where a suite property does not fit.

`RoomForMacTests/AppPreferencesTests.swift`:
```swift
import Foundation
import Testing
@testable import RoomForMac

@Suite("App preferences")
struct AppPreferencesTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func defaultsOnAFreshInstall() {
        let preferences = temporary.preferences
        #expect(preferences.onboardingCompleted == false)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == true)
        #expect(preferences.notificationsWanted == false)
        #expect(preferences.lastKnownState(for: "fullDiskAccess") == nil)
    }

    @Test func valuesRoundTripThroughUserDefaults() {
        let writer = temporary.preferences
        writer.onboardingCompleted = true
        writer.onboardingStep = "fullDiskAccess"
        writer.analyticsEnabled = false
        writer.notificationsWanted = true

        let reader = AppPreferences(defaults: temporary.defaults)
        #expect(reader.onboardingCompleted == true)
        #expect(reader.onboardingStep == "fullDiskAccess")
        #expect(reader.analyticsEnabled == false)
        #expect(reader.notificationsWanted == true)
    }

    @Test func keysAreStable() {
        let preferences = temporary.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = "automation"
        preferences.analyticsEnabled = false
        preferences.notificationsWanted = true
        preferences.setLastKnownState("denied", for: "automationFinder")

        let defaults = temporary.defaults
        #expect(defaults.object(forKey: "onboarding.completed") as? Bool == true)
        #expect(defaults.string(forKey: "onboarding.step") == "automation")
        #expect(defaults.object(forKey: "analytics.enabled") as? Bool == false)
        #expect(defaults.object(forKey: "notifications.wanted") as? Bool == true)
        #expect(defaults.string(forKey: "permissions.lastKnown.automationFinder") == "denied")
    }

    @Test func clearingTheStepRemovesTheKey() {
        let preferences = temporary.preferences
        preferences.onboardingStep = "extras"
        preferences.onboardingStep = nil
        #expect(preferences.onboardingStep == nil)
        #expect(temporary.defaults.object(forKey: "onboarding.step") == nil)
    }

    @Test func lastKnownStatesAreKeptPerPermission() {
        let preferences = temporary.preferences
        preferences.setLastKnownState("granted", for: "automationFinder")
        preferences.setLastKnownState("unknown:not running", for: "automationSystemEvents")
        #expect(preferences.lastKnownState(for: "automationFinder") == "granted")
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "unknown:not running")

        preferences.setLastKnownState(nil, for: "automationFinder")
        #expect(preferences.lastKnownState(for: "automationFinder") == nil)
        #expect(temporary.defaults.object(forKey: "permissions.lastKnown.automationFinder") == nil)
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "unknown:not running")
    }

    @Test func analyticsFollowsAValueWrittenFromTheCommandLine() {
        // `defaults write com.roomformac.app analytics.enabled 0` stores a string, not a Bool.
        temporary.defaults.set("0", forKey: "analytics.enabled")
        #expect(temporary.preferences.analyticsEnabled == false)
        temporary.defaults.removeObject(forKey: "analytics.enabled")
        #expect(temporary.preferences.analyticsEnabled == true)
    }

    @Test func copiesShareOneStore() {
        let first = temporary.preferences
        let second = first
        first.onboardingCompleted = true
        #expect(second.onboardingCompleted == true)
    }
}
```

- [ ] **Step 2: Run the preferences tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppPreferencesTests`
Expected: `** TEST FAILED **` (exit 65). The app target builds, and the test target stops at `RoomForMacTests/Support/TemporaryDefaults.swift:18:22: error: cannot find type 'AppPreferences' in scope`.

- [ ] **Step 3: Write `AppPreferences`**

`RoomForMac/App/AppPreferences.swift`:
```swift
import Foundation

/// Typed access to the app's UserDefaults.
///
/// Every property reads and writes the store directly, so all copies of an
/// `AppPreferences` over the same `UserDefaults` see the same values, and the
/// setters work through a `let`. `UserDefaults` is documented as thread-safe,
/// hence `@unchecked Sendable`.
struct AppPreferences: @unchecked Sendable {
    /// The UserDefaults keys. They are stored on users' Macs: never rename one.
    enum Key {
        static let onboardingCompleted = "onboarding.completed"
        static let onboardingStep = "onboarding.step"
        static let analyticsEnabled = "analytics.enabled"
        static let notificationsWanted = "notifications.wanted"
        static let lastKnownStatePrefix = "permissions.lastKnown."
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// True once the user finished or dismissed the last onboarding screen.
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    /// The raw `OnboardingStep` to resume at after a relaunch; nil when none is saved.
    var onboardingStep: String? {
        get { defaults.string(forKey: Key.onboardingStep) }
        nonmutating set { store(newValue, forKey: Key.onboardingStep) }
    }

    /// Anonymous usage data, on unless the user turned it off.
    var analyticsEnabled: Bool {
        get { bool(forKey: Key.analyticsEnabled, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.analyticsEnabled) }
    }

    /// Whether the user asked to be notified when a cleanup finishes.
    var notificationsWanted: Bool {
        get { bool(forKey: Key.notificationsWanted, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsWanted) }
    }

    /// The last state stored for a permission (a `PermissionState.storageValue`),
    /// keyed by its raw `PermissionID`.
    func lastKnownState(for permission: String) -> String? {
        defaults.string(forKey: Key.lastKnownStatePrefix + permission)
    }

    /// Stores the state for a permission; nil removes it.
    func setLastKnownState(_ state: String?, for permission: String) {
        store(state, forKey: Key.lastKnownStatePrefix + permission)
    }

    /// Missing keys give `fallback`. Present values go through `bool(forKey:)`, which
    /// also reads the strings `defaults write` stores, such as "0" or "NO".
    private func bool(forKey key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func store(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
```

- `nonmutating set` is what lets `AppModel` write through its `let dependencies`, and `OnboardingFlow` (Task 11) write through a stored `let preferences`.
- `UserDefaults` is not `Sendable` in the macOS 27 SDK (checked with `swiftc`), so the conformance is `@unchecked` and rests on Apple's thread-safety guarantee. Every current consumer is `@MainActor` anyway.
- No `register(defaults:)`: that registration domain is process-wide and would leak into every test's suite.

- [ ] **Step 4: Run the preferences tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppPreferencesTests`
Expected: `✔ Test run with 7 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing model, sidebar and dependency tests**

`RoomForMacTests/AppModelTests.swift`:
```swift
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

/// Counts engine checks across isolation domains.
private actor CheckCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
@Suite("App model")
struct AppModelTests {
    private let temporary: TemporaryDefaults
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        temporary = try TemporaryDefaults()
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: [
            "mole_tag": "V1.56.0",
            "mole_commit": String(repeating: "a", count: 40),
            "patches_sha256": "none",
            "patch_count": "5",
        ])
        installation = try EngineInstallation(root: root)
    }

    private func dependencies(
        _ engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem>
    ) -> AppDependencies {
        AppDependencies(preferences: temporary.preferences, engineCheck: engineCheck, openURL: { _ in })
    }

    @Test func startsCheckingWithSmartCleanSelected() {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        #expect(model.engine == .checking)
        #expect(model.selection == .smartClean)
        #expect(model.isOnboarded == false)
        #expect(model.pendingFirstScan == false)
    }

    @Test func aHealthyEngineMakesTheAppReady() async {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        await model.start()
        #expect(model.engine == .ready(installation))
    }

    @Test func aBrokenEngineBlocksTheApp() async {
        let problem = EngineProblem.selfTestFailed(tool: "status-go", detail: "Signal 9")
        let model = AppModel(dependencies: dependencies { .failure(problem) })
        await model.start()
        #expect(model.engine == .broken(problem))
    }

    @Test func startRunsTheCheckOnce() async {
        let counter = CheckCounter()
        let installation = installation
        let model = AppModel(dependencies: dependencies {
            await counter.record()
            return .success(installation)
        })
        await model.start()
        await model.start()
        #expect(await counter.count == 1)
        #expect(model.engine == .ready(installation))
    }

    @Test func aSecondStartWhileTheCheckRunsDoesNotRunItAgain() async {
        let counter = CheckCounter()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let problem = EngineProblem.installationInvalid("missing bin/clean.sh")
        let model = AppModel(dependencies: dependencies {
            await counter.record()
            for await _ in gate {
                break
            }
            return .failure(problem)
        })
        async let first: Void = model.start()
        async let second: Void = model.start()
        release.yield()
        release.finish()
        _ = await (first, second)
        #expect(await counter.count == 1)
        #expect(model.engine == .broken(problem))
    }

    @Test func onboardingStateComesFromPreferences() {
        temporary.preferences.onboardingCompleted = true
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        #expect(model.isOnboarded == true)
    }

    @Test func completingOnboardingPersistsAndQueuesTheFirstScan() {
        temporary.preferences.onboardingStep = "ready"
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        model.selection = .status

        model.completeOnboarding(startFirstScan: true)

        #expect(model.isOnboarded == true)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan == true)
        let stored = AppPreferences(defaults: temporary.defaults)
        #expect(stored.onboardingCompleted == true)
        #expect(stored.onboardingStep == nil)
    }

    @Test func notNowCompletesOnboardingWithoutAScan() {
        let installation = installation
        let model = AppModel(dependencies: dependencies { .success(installation) })
        model.selection = .uninstaller

        model.completeOnboarding(startFirstScan: false)

        #expect(model.isOnboarded == true)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan == false)
        #expect(temporary.preferences.onboardingCompleted == true)
    }
}

@Suite("Sidebar sections")
struct SidebarSectionTests {
    @Test func orderAndIdentity() {
        #expect(SidebarSection.allCases == [.smartClean, .uninstaller, .status])
        #expect(SidebarSection.allCases.map(\.id) == ["smartClean", "uninstaller", "status"])
    }

    @Test func titles() {
        #expect(SidebarSection.allCases.map(\.title.key) == ["Smart Clean", "Uninstaller", "Status"])
        #expect(SidebarSection.allCases.map { String(localized: $0.title) } == ["Smart Clean", "Uninstaller", "Status"])
    }

    @Test func symbols() {
        #expect(SidebarSection.smartClean.systemImage == "sparkles")
        #expect(SidebarSection.uninstaller.systemImage == "trash")
        #expect(SidebarSection.status.systemImage == "gauge.with.dots.needle.67percent")
    }

    @Test func backdrops() {
        #expect(SidebarSection.smartClean.backdrop == .smartClean)
        #expect(SidebarSection.uninstaller.backdrop == .uninstaller)
        #expect(SidebarSection.status.backdrop == .status)
    }
}

/// These tests share the scenario suite `RoomForMac.UITest`, so they run one at a time
/// and remove it when they finish.
@MainActor
@Suite("App dependencies", .serialized)
struct AppDependenciesTests {
    private func removeScenarioSuite() {
        UserDefaults(suiteName: AppDependencies.scenarioSuiteName)?
            .removePersistentDomain(forName: AppDependencies.scenarioSuiteName)
    }

    @Test func aUITestModeGetsItsScenario() {
        defer { removeScenarioSuite() }
        #expect(AppDependencies.forMode(.uiTest(.onboarded)).preferences.onboardingCompleted == true)
        #expect(AppDependencies.forMode(.uiTest(.onboarding)).preferences.onboardingCompleted == false)
    }

    @Test func eachScenarioStartsFromEmptyPreferences() {
        defer { removeScenarioSuite() }
        let first = AppDependencies.forScenario(.onboarding)
        first.preferences.onboardingStep = "automation"
        first.preferences.analyticsEnabled = false

        let second = AppDependencies.forScenario(.onboarding)
        #expect(second.preferences.onboardingStep == nil)
        #expect(second.preferences.analyticsEnabled == true)
        #expect(second.preferences.onboardingCompleted == false)
    }

    @Test func theScenarioNeverUsesTheStandardDefaults() {
        defer { removeScenarioSuite() }
        let standardBefore = UserDefaults.standard.object(forKey: "onboarding.completed") as? Bool
        _ = AppDependencies.forScenario(.onboarded)
        #expect(UserDefaults.standard.object(forKey: "onboarding.completed") as? Bool == standardBefore)
        let scenario = UserDefaults(suiteName: AppDependencies.scenarioSuiteName)
        #expect(scenario?.object(forKey: "onboarding.completed") as? Bool == true)
    }

    @Test func theBrokenEngineScenarioReportsAVersionMismatch() async {
        defer { removeScenarioSuite() }
        let result = await AppDependencies.forScenario(.engineBroken).engineCheck()
        guard case .failure(.versionMismatch(let expected, let found)) = result else {
            Issue.record("expected a version mismatch, got \(result)")
            return
        }
        #expect(expected == .expected)
        #expect(found.moleTag == "V0.0.0")
        #expect(found.moleCommit == EngineFingerprint.expected.moleCommit)
    }
}
```

- `EngineLayout` and `TemporaryDirectory` come from Task 3's test support. `EnginePhase.ready` needs a real `EngineInstallation`, and the only way to build one is from a valid layout on disk.
- The concurrent test holds the check open on an `AsyncStream`. The yield is buffered, so it releases the check whichever call starts it.

- [ ] **Step 6: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppModelTests -only-testing:RoomForMacTests/SidebarSectionTests -only-testing:RoomForMacTests/AppDependenciesTests`
Expected: `** TEST FAILED **`. The test target stops at `AppModelTests.swift:36:10: error: cannot find type 'AppDependencies' in scope`, along with `cannot find 'AppModel' in scope`.

- [ ] **Step 7: Write `SidebarSection`, `AppModel` and `AppDependencies`**

`RoomForMac/App/SidebarSection.swift`:
```swift
import Foundation

/// The features in the main window's sidebar, in display order (Ruling 9).
/// Terrain arrives with Plan 4 and has no entry yet.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case smartClean
    case uninstaller
    case status

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .smartClean: "Smart Clean"
        case .uninstaller: "Uninstaller"
        case .status: "Status"
        }
    }

    /// The SF Symbol next to the title.
    var systemImage: String {
        switch self {
        case .smartClean: "sparkles"
        case .uninstaller: "trash"
        case .status: "gauge.with.dots.needle.67percent"
        }
    }

    /// The landscape behind the section (spec §11.3).
    var backdrop: BackdropScene {
        switch self {
        case .smartClean: .smartClean
        case .uninstaller: .uninstaller
        case .status: .status
        }
    }
}
```

`RoomForMac/App/AppModel.swift`:
```swift
import MoleEngine
import Observation

/// Where the launch check of the bundled engine stands.
enum EnginePhase: Equatable, Sendable {
    case checking
    case ready(EngineInstallation)
    case broken(EngineProblem)
}

/// The app-wide state behind the main window.
///
/// Plan 3 must not start `StatusService` or a scan while `isOnboarded` is false
/// (Ruling 10): the engine's Apple events would then prompt before onboarding
/// explains them.
@MainActor
@Observable
final class AppModel {
    let dependencies: AppDependencies

    private(set) var engine: EnginePhase = .checking
    var selection: SidebarSection = .smartClean
    private(set) var isOnboarded: Bool

    /// Set when onboarding ends with "Start first scan". Smart Clean (Plan 3)
    /// starts the scan and clears it.
    var pendingFirstScan = false

    @ObservationIgnored private var hasStarted = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        isOnboarded = dependencies.preferences.onboardingCompleted
    }

    /// Runs the engine check once. Later calls, including one made while the
    /// check is still running, return at once.
    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        switch await dependencies.engineCheck() {
        case .success(let installation):
            engine = .ready(installation)
        case .failure(let problem):
            engine = .broken(problem)
        }
    }

    /// Saves that onboarding is done and shows Smart Clean.
    func completeOnboarding(startFirstScan: Bool) {
        let preferences = dependencies.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
        isOnboarded = true
        selection = .smartClean
        pendingFirstScan = startFirstScan
    }
}
```

`RoomForMac/App/AppDependencies.swift`:
```swift
import AppKit
import MoleEngine

/// The composition root: everything the app model needs from the system.
/// `live` wires the real services. Unit tests build their own with the memberwise
/// initializer, and UI tests get a scripted scenario (DEBUG builds only).
@MainActor
struct AppDependencies {
    var preferences: AppPreferences
    var engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
    var openURL: @MainActor (URL) -> Void

    static func live(defaults: UserDefaults = .standard) -> AppDependencies {
        AppDependencies(
            preferences: AppPreferences(defaults: defaults),
            engineCheck: { await EngineHealthCheck().run() },
            openURL: { url in _ = NSWorkspace.shared.open(url) }
        )
    }

    /// The dependencies for how this process was started. `.unitTestHost` never
    /// gets here (see `RoomForMacLauncher`), and `.uiTest` only exists in DEBUG
    /// builds (see `RuntimeMode.detect`).
    static func forMode(_ mode: RuntimeMode) -> AppDependencies {
        #if DEBUG
        if case .uiTest(let scenario) = mode {
            return forScenario(scenario)
        }
        #endif
        return live()
    }

    #if DEBUG
    /// The UserDefaults suite UI-test scenarios use instead of the app's own domain.
    static let scenarioSuiteName = "RoomForMac.UITest"

    /// A scripted launch for UI tests. Preferences start empty in their own suite,
    /// so every run starts clean and `UserDefaults.standard` is never touched.
    /// Links are not opened. Task 15 adds scripted permission checkers.
    static func forScenario(_ scenario: UITestScenario) -> AppDependencies {
        guard let defaults = UserDefaults(suiteName: scenarioSuiteName) else {
            preconditionFailure("UserDefaults refused the suite \(scenarioSuiteName)")
        }
        defaults.removePersistentDomain(forName: scenarioSuiteName)
        let preferences = AppPreferences(defaults: defaults)
        preferences.onboardingCompleted = scenario == .onboarded

        let engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
        switch scenario {
        case .onboarding, .onboarded:
            engineCheck = { bundledEngineWithoutSelfTest() }
        case .engineBroken:
            var found = EngineFingerprint.expected
            found.moleTag = "V0.0.0"
            let problem = EngineProblem.versionMismatch(expected: .expected, found: found)
            engineCheck = { .failure(problem) }
        }
        return AppDependencies(preferences: preferences, engineCheck: engineCheck, openURL: { _ in })
    }

    /// Locates the bundled engine without running its helpers, so UI tests do not
    /// depend on how fast the Go binaries start.
    private nonisolated static func bundledEngineWithoutSelfTest() -> Result<EngineInstallation, EngineProblem> {
        do {
            return .success(try EngineInstallation.bundled())
        } catch EngineError.installationInvalid(let message) {
            return .failure(.installationInvalid(message))
        } catch {
            return .failure(.installationInvalid(String(describing: error)))
        }
    }
    #endif
}
```

- `engineCheck` is a `@Sendable` closure, so it runs off the main actor even though `live()` is `@MainActor`. `EngineHealthCheck.run()` spawns the helpers without blocking the UI.
- `forMode` holds the only `#if DEBUG` branch the app entry point needs. A Release build compiles without `forScenario` (Step 14 checks this).
- `bundledEngineWithoutSelfTest` is `nonisolated`, so the `@Sendable` closure can call it.

- [ ] **Step 8: Run them to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppModelTests -only-testing:RoomForMacTests/SidebarSectionTests -only-testing:RoomForMacTests/AppDependenciesTests`
Expected: `✔ Test run with 16 tests in 3 suites passed` (8 in "App model", 4 in "Sidebar sections", 4 in "App dependencies") and `** TEST SUCCEEDED **`.

- [ ] **Step 9: Write the failing root view tests**

`RoomForMacTests/RootViewTests.swift`:
```swift
import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Root view")
struct RootViewTests {
    private let directory: TemporaryDirectory
    private let installation: EngineInstallation

    init() throws {
        directory = try TemporaryDirectory()
        let root = try EngineLayout.make(in: directory.url, version: [
            "mole_tag": "V1.56.0",
            "mole_commit": String(repeating: "b", count: 40),
        ])
        installation = try EngineInstallation(root: root)
    }

    @Test(arguments: [false, true])
    func theEngineCheckComesFirst(isOnboarded: Bool) {
        #expect(RootScreen.resolve(engine: .checking, isOnboarded: isOnboarded) == .checking)
        let problem = EngineProblem.installationInvalid("missing bin/clean.sh")
        #expect(RootScreen.resolve(engine: .broken(problem), isOnboarded: isOnboarded) == .engineProblem(problem))
    }

    @Test func aReadyEngineShowsOnboardingUntilItIsDone() {
        #expect(RootScreen.resolve(engine: .ready(installation), isOnboarded: false) == .onboarding)
        #expect(RootScreen.resolve(engine: .ready(installation), isOnboarded: true) == .main)
    }

    @Test func accessibilityIdentifiers() {
        #expect(AccessibilityID.sidebar == "sidebar")
        #expect(SidebarSection.allCases.map(AccessibilityID.sidebarRow)
            == ["sidebar.smartClean", "sidebar.uninstaller", "sidebar.status"])
        #expect(SidebarSection.allCases.map(AccessibilityID.placeholder)
            == ["placeholder.smartClean", "placeholder.uninstaller", "placeholder.status"])
        #expect(AccessibilityID.checkingEngine == "engine.checking")
        #expect(AccessibilityID.onboardingPlaceholder == "onboarding.placeholder")
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemDetails == "engineProblem.details")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
        #expect(AccessibilityID.engineProblemDownload == "engineProblem.download")
    }

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func placeholdersRender(colorScheme: ColorScheme) throws {
        let views: [AnyView] = [
            AnyView(SmartCleanPlaceholderView()),
            AnyView(UninstallerPlaceholderView()),
            AnyView(StatusPlaceholderView()),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view
                .frame(width: 600, height: 400)
                .environment(\.colorScheme, colorScheme))
            let image = try #require(renderer.cgImage)
            #expect(image.width == 600)
            #expect(image.height == 400)
        }
    }
}
```

- [ ] **Step 10: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/RootViewTests`
Expected: `** TEST FAILED **`. The test target stops at `RootViewTests.swift:23:17: error: cannot find 'RootScreen' in scope`, and at `type 'AccessibilityID' has no member 'sidebar'` (also `sidebarRow`, `placeholder`, `checkingEngine`).

- [ ] **Step 11: Write the identifiers, `RootView` and the placeholders**

`RoomForMac/App/AccessibilityID.swift` (whole file; the four `engineProblem*` constants are Task 3's and stay unchanged):
```swift
/// Every accessibility identifier the app sets, so views and UI tests share one spelling.
enum AccessibilityID {
    // Main window
    static let sidebar = "sidebar"
    static let checkingEngine = "engine.checking"
    /// The text that stands in for onboarding until the onboarding screens exist.
    static let onboardingPlaceholder = "onboarding.placeholder"

    /// A sidebar row: "sidebar.<rawValue>".
    static func sidebarRow(_ section: SidebarSection) -> String {
        "sidebar.\(section.rawValue)"
    }

    /// A section's placeholder detail: "placeholder.<rawValue>".
    static func placeholder(_ section: SidebarSection) -> String {
        "placeholder.\(section.rawValue)"
    }

    // Engine problem card (Task 3)
    static let engineProblemCard = "engineProblem.card"
    static let engineProblemDetails = "engineProblem.details"
    static let engineProblemCopy = "engineProblem.copy"
    static let engineProblemDownload = "engineProblem.download"

    // Tasks 12–14 append onboarding.* and settings.* identifiers.
}
```

`RoomForMac/App/RootView.swift`:
```swift
import SwiftUI

/// What the main window shows. The engine check comes first: a broken engine
/// blocks everything, onboarding included.
enum RootScreen: Equatable, Sendable {
    case checking
    case engineProblem(EngineProblem)
    case onboarding
    case main

    static func resolve(engine: EnginePhase, isOnboarded: Bool) -> RootScreen {
        switch engine {
        case .checking:
            .checking
        case .broken(let problem):
            .engineProblem(problem)
        case .ready:
            isOnboarded ? .main : .onboarding
        }
    }
}

/// The main window's content.
struct RootView: View {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        Group {
            switch RootScreen.resolve(engine: model.engine, isOnboarded: model.isOnboarded) {
            case .checking:
                CheckingEngineView()
            case .engineProblem(let problem):
                EngineProblemView(problem: problem)
            case .onboarding:
                OnboardingPlaceholderView()
            case .main:
                MainSplitView(model: model)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        // The window's own background is the canvas token, not the system gray.
        .containerBackground(Palette.canvas, for: .window)
    }
}

/// Shown while the launch check runs, usually for a fraction of a second.
private struct CheckingEngineView: View {
    var body: some View {
        ProgressView("Checking RoomForMac…")
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.checkingEngine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stands in for onboarding until Task 12 replaces it with `OnboardingView`.
private struct OnboardingPlaceholderView: View {
    var body: some View {
        GlassCard {
            Text("Welcome to RoomForMac")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .accessibilityIdentifier(AccessibilityID.onboardingPlaceholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BackdropView(scene: .onboarding)
                .ignoresSafeArea()
        }
    }
}

/// The sidebar and the selected section, over the section's backdrop.
/// The sidebar keeps the system's own glass (Global Constraints).
private struct MainSplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityIdentifier(AccessibilityID.sidebarRow(section))
            }
            .accessibilityIdentifier(AccessibilityID.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .background {
            BackdropView(scene: model.selection.backdrop)
                .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .smartClean:
            SmartCleanPlaceholderView()
        case .uninstaller:
            UninstallerPlaceholderView()
        case .status:
            StatusPlaceholderView()
        }
    }
}

/// The detail of a section whose feature has not shipped yet: its title and
/// symbol on a glass card. Plan 3 replaces each use with the real feature.
struct SectionPlaceholderView: View {
    let section: SidebarSection

    var body: some View {
        GlassCard {
            ContentUnavailableView(
                section.title,
                systemImage: section.systemImage,
                description: Text("Coming in the next update.")
            )
            .foregroundStyle(Palette.text, Palette.textSecondary)
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.placeholder(section))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

`RoomForMac/Features/SmartClean/SmartCleanPlaceholderView.swift`:
```swift
import SwiftUI

/// Smart Clean's detail until Plan 3 builds the feature.
struct SmartCleanPlaceholderView: View {
    var body: some View {
        SectionPlaceholderView(section: .smartClean)
    }
}
```

`RoomForMac/Features/Uninstaller/UninstallerPlaceholderView.swift`:
```swift
import SwiftUI

/// The Uninstaller's detail until Plan 3 builds the feature.
struct UninstallerPlaceholderView: View {
    var body: some View {
        SectionPlaceholderView(section: .uninstaller)
    }
}
```

`RoomForMac/Features/Status/StatusPlaceholderView.swift`:
```swift
import SwiftUI

/// Status's detail until Plan 3 builds the feature.
struct StatusPlaceholderView: View {
    var body: some View {
        SectionPlaceholderView(section: .status)
    }
}
```

About these views:
- `RootView` stores the model as a plain `let`: SwiftUI tracks every `@Observable` property the body reads. Only `MainSplitView` needs `@Bindable`, for the selection binding.
- `List(_:selection:)` binds a non-optional `SidebarSection` (the macOS 13 overload), so a click on empty space cannot clear the selection. The explicit `.tag(section)` is required: without it, rows are tagged with their `String` id and never match the selection. Selection was checked both ways in scratch: selecting row 2 of the underlying outline view set `model.selection` to `.status`, and setting `.uninstaller` moved the outline's selected row to 1.
- The `ContentUnavailableView` defaults to secondary grey, which was hard to read on light glass. `.foregroundStyle(Palette.text, Palette.textSecondary)` gives the title the text token and the description the secondary one (checked in an `ImageRenderer` capture in both appearances).
- The sidebar has no `.glassEffect()` (Global Constraints). The backdrop is placed with `.background` on the split view, and an offscreen capture showed it behind the detail column.

- [ ] **Step 12: Run them to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/RootViewTests`
Expected: `✔ Test run with 4 tests in 1 suite passed` and `** TEST SUCCEEDED **`. The two parameterized tests run two cases each.

- [ ] **Step 13: Wire the model into the app**

`RoomForMac/App/RoomForMacApp.swift` (whole file; only `RoomForMacApp` changes, and `RoomForMacLauncher` and `UnitTestHostApp` are Task 1's):
```swift
import SwiftUI

/// The process entry point. While XCTest hosts the unit tests it runs an empty app,
/// so hosted tests never build the real app's model, engine check or permission checks.
@main
enum RoomForMacLauncher {
    enum Entry: Equatable, Sendable {
        case testHost
        case app
    }

    static func entry(for mode: RuntimeMode) -> Entry {
        mode == .unitTestHost ? .testHost : .app
    }

    @MainActor
    static func main() {
        switch entry(for: .current) {
        case .testHost:
            UnitTestHostApp.main()
        case .app:
            RoomForMacApp.main()
        }
    }
}

/// The only scene of the unit-test host process. It constructs nothing else.
struct UnitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}

/// RoomForMac itself: one main window and the Settings window.
struct RoomForMacApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel(dependencies: .forMode(.current)))
    }

    var body: some Scene {
        // A single-instance Window, so opening it again (Plan 3's menu-bar extra)
        // brings back this window instead of adding a second one (Ruling 8).
        Window("RoomForMac", id: "main") {
            RootView(model: model)
                .task {
                    await model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .windowBackgroundDragBehavior(.enabled)

        Settings {
            // Replaced by SettingsView in Task 14.
            Text("Settings")
                .frame(width: 320, height: 160)
        }
    }
}
```

- `App.init` runs on the main actor, so it can build the `@MainActor` model. `@State` keeps that one instance for the life of the app.
- `.task` starts the engine check when the window first appears. Closing and reopening the window runs the task again, and `start()` then returns at once.

- [ ] **Step 14: Run the whole unit scheme and the build checks**

Run:
```bash
mkdir -p build
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit clean > /dev/null \
    && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test \
    > build/task7-unit.log 2>&1; echo "exit $?"
grep -E '^\*\* TEST|Test run with' build/task7-unit.log
grep -E '(warning|error):' build/task7-unit.log | grep -v appintentsmetadataprocessor | grep -v 'Error Domain'
```
Expected:
- `exit 0`, then `✔ Test run with … tests in … suites passed` and `** TEST SUCCEEDED **`.
- The summary includes this task's five suites: "App preferences" (7), "App model" (8), "Sidebar sections" (4), "App dependencies" (4) and "Root view" (4), 27 tests next to those of Tasks 1–6.
- The last `grep` prints nothing: the clean build compiled every file without a warning. The `Error Domain=NSCocoaErrorDomain Code=4097 … com.apple.linkd.autoShortcut` lines are system log noise from the test host, as in Task 1.
- The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time. `build/` is git-ignored.

Run: `grep -n 'glassEffect' RoomForMac/App/*.swift RoomForMac/Features/*/*PlaceholderView.swift`
Expected: no output and exit status 1. The shell adds no glass of its own; the sidebar keeps the system's.

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build 2>&1 | grep -E '^\*\*|(warning|error):' | grep -v appintentsmetadataprocessor`
Expected: `** BUILD SUCCEEDED **` and nothing else. The Release configuration has no `DEBUG`, so this proves `forMode` compiles without `forScenario`.

- [ ] **Step 15: Add the new strings to the String Catalog**

`xcodebuild` does not update `Localizable.xcstrings`; only the Xcode editor does. So sync the catalog from the `.stringsdata` files that the Step 14 Debug build left for the app target:

```bash
OBJ=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null \
    | awk '/Build settings for action .* and target RoomForMac:/ { t = 1 } t && $1 == "OBJECT_FILE_DIR_normal" { print $3; exit }')
xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --skip-marking-strings-stale --stringsdata "$OBJ"/*/*.stringsdata
git diff RoomForMac/Resources/Localizable.xcstrings
```

Expected: `xcstringstool` prints nothing and exits 0. The diff adds exactly these six keys, each as an empty entry (`"…" : {\n\n}`), and removes nothing: `"Checking RoomForMac…"`, `"Coming in the next update."`, `"Smart Clean"`, `"Status"`, `"Uninstaller"`, `"Welcome to RoomForMac"`. The three section titles come from the `LocalizedStringResource` literals in `SidebarSection.title`. `--skip-marking-strings-stale` keeps the sync from marking other tasks' entries stale.

- [ ] **Step 16: Look at the running app, and run the launch smoke test when Automation Mode allows**

Optional manual look (Debug build from Step 14, whose engine Task 2 embedded):
```bash
APP=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/RoomForMac.app
open -n "$APP" --args -RFMUITestScenario onboarded
```
- Expected: one window shows the sidebar (Smart Clean, Uninstaller, Status) over the Smart Clean backdrop gradient, with the Smart Clean placeholder card. Clicking a row swaps the placeholder and crossfades the backdrop.
- `-RFMUITestScenario engine-broken` shows the Reinstall card instead.
- A plain `open "$APP"` on a Mac that never finished onboarding shows "Welcome to RoomForMac".
- Quit with ⌘Q, then run `defaults delete RoomForMac.UITest` to drop the scenario suite.

Run: `automationmodetool`. If it prints a line containing `DOES NOT REQUIRE`, or you can approve the prompt at the Mac:
- Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS test -only-testing:RoomForMacUITests/LaunchSmokeTests`
- Expected: `** TEST SUCCEEDED **`. The `onboarded` scenario now reaches the split view.
- Otherwise record "LaunchSmokeTests not run: Automation Mode needs authentication", as in Task 1.

- [ ] **Step 17: Commit**

```bash
git add RoomForMac/App/AppPreferences.swift RoomForMac/App/AppModel.swift RoomForMac/App/SidebarSection.swift \
    RoomForMac/App/RootView.swift RoomForMac/App/AppDependencies.swift RoomForMac/App/RoomForMacApp.swift \
    RoomForMac/App/AccessibilityID.swift \
    RoomForMac/Features/SmartClean/SmartCleanPlaceholderView.swift \
    RoomForMac/Features/Uninstaller/UninstallerPlaceholderView.swift \
    RoomForMac/Features/Status/StatusPlaceholderView.swift \
    RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/Support/TemporaryDefaults.swift RoomForMacTests/AppPreferencesTests.swift \
    RoomForMacTests/AppModelTests.swift RoomForMacTests/RootViewTests.swift
git status --short
```
Expected:
```
M  RoomForMac/App/AccessibilityID.swift
A  RoomForMac/App/AppDependencies.swift
A  RoomForMac/App/AppModel.swift
A  RoomForMac/App/AppPreferences.swift
M  RoomForMac/App/RoomForMacApp.swift
A  RoomForMac/App/RootView.swift
A  RoomForMac/App/SidebarSection.swift
A  RoomForMac/Features/SmartClean/SmartCleanPlaceholderView.swift
A  RoomForMac/Features/Status/StatusPlaceholderView.swift
A  RoomForMac/Features/Uninstaller/UninstallerPlaceholderView.swift
M  RoomForMac/Resources/Localizable.xcstrings
A  RoomForMacTests/AppModelTests.swift
A  RoomForMacTests/AppPreferencesTests.swift
A  RoomForMacTests/RootViewTests.swift
A  RoomForMacTests/Support/TemporaryDefaults.swift
```
Nothing under `RoomForMac.xcodeproj/`, `RoomForMac/Generated/` or `build/` is staged.

```bash
git commit -F - <<'EOF'
feat(app): app shell with preferences, app model, sidebar and placeholders

AppPreferences wraps UserDefaults with typed keys. AppModel runs the
engine launch check once and remembers onboarding. RootView shows the
check, the blocking engine card, onboarding or the sidebar over the
section's backdrop. Smart Clean, Uninstaller and Status get placeholder
cards until Plan 3. UI-test scenarios get their own preferences suite
and a scripted engine result.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 8: Permission core — IDs, states, checking protocol, center, blocking calls, Settings links

**Files:**
- Create: `RoomForMac/Features/Permissions/PermissionID.swift`, `PermissionState.swift`, `PermissionChecking.swift`, `PermissionCenter.swift`, `BlockingCall.swift`, `SystemSettingsLink.swift`, `RoomForMacTests/PermissionCenterTests.swift`, `RoomForMacTests/BlockingCallTests.swift`
- Create (added; test support that Tasks 11–14 may reuse): `RoomForMacTests/Support/FakeChecker.swift`
- Modify (added; the String Catalog grows every task): `RoomForMac/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppPreferences` (Task 7) for last-known states. The tests also use `TemporaryDefaults` (Task 7, `RoomForMacTests/Support`).
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
- Added by this task (internal to this task; later tasks may use them, but nothing depends on them yet):
  ```swift
  extension PermissionCenter {   // declared in the class body
      func isRequesting(_ id: PermissionID) -> Bool            // a request(id) is waiting for its checker; Tasks 12–14 may disable the action button with it
      static let lastKnownFallback: Set<PermissionID>          // [.automationFinder, .automationSystemEvents]
  }
  extension BlockingCall {
      static func nanoseconds(_ duration: Duration) -> Int     // dispatch deadline: negative → 0, saturates at Int.max
  }
  extension SystemSettingsLink {
      var urlString: String { get }                            // the exact strings below; url == URL(string: urlString)
  }
  // Test support, RoomForMacTests/Support/FakeChecker.swift:
  struct FakeChecker: PermissionChecking {
      init(id: PermissionID, states: [PermissionState], requestStates: [PermissionState] = [],
           checkGate: Gate? = nil, requestGate: Gate? = nil)
      var checkCount: Int { get async }
      var requestCount: Int { get async }
      actor Gate {                                             // holds the first caller of pass() until open()
          init()
          func pass() async
          func open()
          func waitForArrivals(_ count: Int = 1) async
          var arrivals: Int { get }
      }
  }
  ```

**Requirements:**
- `PermissionID`:
  - The raw values are storage keys. They name the `permissions.lastKnown.<raw>` preferences and are what `Codable` writes, so they never change.
  - `title` returns the six English titles above as `LocalizedStringResource` literals, so the build extracts them into the String Catalog.
- `PermissionState`:
  - `isGranted` is true for `.granted` and `.notApplicable` only.
  - `storageValue` writes exactly the strings listed in the interface. `.unknown(reason)` writes `unknown:` followed by the reason verbatim; the reason may be empty or contain colons.
  - `init?(storageValue:)` reads every value `storageValue` writes back to an equal state, and returns nil for anything else. Case and whitespace matter.
  - The `.unknown` reason ("not running", "timed out", "OSStatus -1712") is diagnostic text, not UI copy. `PermissionChip` (Task 12) shows "Unknown".
- `PermissionChecking`:
  - `currentState()` never shows UI or a prompt, and returns within a few seconds. Task 9 bounds the Automation check with `BlockingCall.passiveDeadline`.
  - `request()` may prompt, open System Settings or move the app, and returns the state right after asking.
- `SystemSettingsLink.url` values, exactly:
  - `fullDiskAccess`: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`
  - `automation`: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation`
  - `appManagement`: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles`
  - `loginItems`: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
  - `notifications`: `x-apple.systempreferences:com.apple.Notifications-Settings.extension`

  The anchors come from the Privacy & Security extension's `TCCServiceList.plist` on macOS 27 (research). They are not click-tested on 26 or 27; that stays on the owner's manual checklist.
- `PermissionCenter`:
  - It holds one checker per `PermissionID`. When two checkers share an ID, the first one in `checkers` wins.
  - It checks nothing in `init` and never calls the system itself. Views decide when to check, and the unit-test host never does.
  - `states` holds each checker's latest recorded answer, unchanged. It is empty until the first check.
  - `state(_:)` is what the UI shows:
    - `.notDetermined` without a checker or an answer;
    - for `automationFinder` and `automationSystemEvents` (`lastKnownFallback`), when the latest answer is `.unknown`, the stored last-known state, if one is stored and parses;
    - otherwise the latest answer.
  - Every answer it records is written with `preferences?.setLastKnownState(answer.storageValue, for: id.rawValue)`, **except `.unknown`**. An unknown answer carries no evidence, and storing it would erase the state the fallback needs: System Events is not running on most launches, so its check answers `.unknown("not running")`. The stored state survives a relaunch.
  - `refresh` and `request` do nothing for an ID without a checker.
  - `refreshAll` checks every checker at once, in child tasks. One Automation check that runs into its 3 s deadline does not hold up the others.
  - `request` ignores a second call for the same ID while one is in flight, and does not call the checker again. A double-click must not move the app twice or stack two prompts. `isRequesting(_:)` reports the request in flight.
  - A check whose answer arrives after a request for the same ID has answered is dropped, because the request's answer is newer. Example: a passive check reads "Not yet" just before the user clicks OK in the prompt, and delivers it late.
  - `poll(_:every:)`:
    - returns at once without a checker;
    - otherwise refreshes, returns as soon as the latest answer `isGranted`, and sleeps `interval` through the injected `sleep`;
    - returns when its task is cancelled or `sleep` throws, and never throws;
    - ignores the last-known fallback, so a stored "granted" never ends a poll (Review Focus 2: never a false "granted").
- `BlockingCall.run`:
  - It resumes a checked continuation exactly once. An `OSAllocatedUnfairLock<Bool>` is shared by the work item (`queue.async`) and the deadline timer (`queue.asyncAfter` on the same queue). The first to finish resumes; the other is ignored.
  - The work runs on `queue`, never on the Swift cooperative pool. `queue` must be concurrent, as the default `.global(qos: .userInitiated)` is: a serial queue would hold the timer behind the work.
  - A blocking call cannot be interrupted. After the deadline, the work keeps its GCD thread until it returns, and its result is dropped.
  - The deadline goes to dispatch through `nanoseconds(_:)`: a negative duration gives 0, and one too long for `Int` saturates at `Int.max`, which dispatch treats as "never".
  - `passiveDeadline` is 3 s and `promptDeadline` is 120 s (Global Constraints).
- It uses `AppPreferences` exactly as Task 7 declares it: `lastKnownState(for:)` and `setLastKnownState(_:for:)`, with `id.rawValue` as the `permission` argument.
- Tests (Swift Testing, with `FakeChecker`, which is an actor-backed struct that returns scripted states in order; nothing touches the system):
  - `PermissionID` raw values, titles and `Codable` form;
  - the storage round-trip for every state, including an empty reason and a reason with colons, and nil for unreadable values;
  - `isGranted` for every state;
  - every `SystemSettingsLink.url` equals its exact string;
  - `refresh` stores the answer; `refreshAll` checks every checker once; an ID without a checker is left alone; the first checker for an ID wins;
  - `request` updates the state; a second request in flight is ignored; a check that started before a request answered is dropped;
  - `poll` makes exactly 3 checks for the script `[.denied, .denied, .granted]`, with an injected `sleep` that records two durations of 1 s; it uses the given interval, stops at `.notApplicable`, returns when `sleep` throws, returns when its task is cancelled (both with a sleep that ignores cancellation and with the real `Task.sleep`), returns at once without a checker, and ignores the last-known fallback;
  - answers are stored as last known, `.unknown` is not stored, Automation shows the last known state while unknown, the fallback survives a relaunch, other permissions show `.unknown` as is, and `.unknown` with nothing stored stays unknown;
  - `BlockingCall` returns the value of fast work; returns nil for work that sleeps 1 s against a 100 ms deadline, in under 0.5 s; runs the work on the given queue; lets late work finish and drops its result; resumes exactly once when work and deadline race, with every call answering its own work's value or nil and every work item still running to the end; has the two deadline constants; and converts durations to nanoseconds.
- The String Catalog gains this task's six keys, synced from the build (Step 13).

Everything in this task is a pure function of its inputs, apart from two orderings: which of work and deadline finishes first in `BlockingCall`, and which of a check and a request answers first in `PermissionCenter`. The tests pin both with a lock-guarded race and with `FakeChecker.Gate`.

- [ ] **Step 1: Write the failing `BlockingCall` tests**

`RoomForMacTests/BlockingCallTests.swift`
```swift
import Foundation
import os
import Testing
@testable import RoomForMac

@Suite("Blocking call")
struct BlockingCallTests {
    @Test func returnsTheResultOfFastWork() async {
        let value = await BlockingCall.run(deadline: .seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test func returnsNilWhenTheDeadlinePassesFirst() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await BlockingCall.run(deadline: .milliseconds(100)) { () -> Int in
            Thread.sleep(forTimeInterval: 1)
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - start < .milliseconds(500))
    }

    @Test func workRunsOnTheGivenQueue() async {
        let queue = DispatchQueue(label: "com.roomformac.tests.blocking-call", attributes: .concurrent)
        let label = await BlockingCall.run(deadline: .seconds(2), queue: queue) {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == "com.roomformac.tests.blocking-call")
    }

    @Test func workThatMissesTheDeadlineStillFinishesAndIsDropped() async {
        let finished = OSAllocatedUnfairLock(initialState: false)
        let value = await BlockingCall.run(deadline: .milliseconds(50)) { () -> Int in
            Thread.sleep(forTimeInterval: 0.3)
            finished.withLock { $0 = true }
            return 1
        }
        #expect(value == nil)
        #expect(finished.withLock { $0 } == false)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(finished.withLock { $0 } == true)
    }

    /// Work and deadline finish at about the same moment, many times over. Every call must
    /// answer with its own work's value or with nil, never another call's value, and every
    /// work item must still run to the end, whichever side won. A second resume of the
    /// continuation would trap with "SWIFT TASK CONTINUATION MISUSE".
    @Test func resumesExactlyOnceWhenWorkAndDeadlineRace() async {
        let finishedWork = OSAllocatedUnfairLock(initialState: 0)
        var answers: [Int?] = []
        for index in 0..<200 {
            let answer = await BlockingCall.run(deadline: .microseconds(300)) { () -> Int in
                usleep(300)
                finishedWork.withLock { $0 += 1 }
                return index
            }
            answers.append(answer)
        }
        for (index, answer) in answers.enumerated() {
            #expect(answer == nil || answer == index, "call \(index) answered \(String(describing: answer))")
        }
        // Work that lost the race keeps its GCD thread for about 300 µs more.
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while finishedWork.withLock({ $0 }) < 200, clock.now < limit {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(finishedWork.withLock { $0 } == 200)
    }

    @Test func deadlinesForPassiveChecksAndPrompts() {
        #expect(BlockingCall.passiveDeadline == .seconds(3))
        #expect(BlockingCall.promptDeadline == .seconds(120))
    }

    @Test(arguments: [
        (Duration.milliseconds(100), 100_000_000),
        (.seconds(3), 3_000_000_000),
        (.nanoseconds(1), 1),
        (.zero, 0),
        (.seconds(-1), 0),
        (.milliseconds(-1), 0),
        (.seconds(Int64.max), Int.max),
    ])
    func dispatchDeadlineInNanoseconds(duration: Duration, nanoseconds: Int) {
        #expect(BlockingCall.nanoseconds(duration) == nanoseconds)
    }
}
```

Notes:
- `__dispatch_queue_get_label(nil)` returns the label of the queue the code is running on, so `workRunsOnTheGivenQueue` proves the work does not run on the cooperative pool.
- `resumesExactlyOnceWhenWorkAndDeadlineRace` pins two invariants that can fail: each call answers with its own work's value or nil, never a value left over from another call, and all 200 work items run to the end even when the deadline won, so cancelling or dropping the work item fails it. A second `resume` also traps the whole test process with `SWIFT TASK CONTINUATION MISUSE`. (Verified while planning: with the `isFirst` check removed from Step 3's code, this test crashes the run.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BlockingCallTests`
Expected: `** TEST FAILED **` (exit 65). The test target stops compiling with eight errors of this form:
```
RoomForMacTests/BlockingCallTests.swift:9:27: error: cannot find 'BlockingCall' in scope
RoomForMacTests/BlockingCallTests.swift:16:27: error: cannot find 'BlockingCall' in scope
```
Run `xcodegen generate` every time a step adds a file: the project lists its files at generation time. Without it, `-only-testing` matches no test and xcodebuild reports `** TEST SUCCEEDED **` with 0 tests, so always read the test count in the expected output.

- [ ] **Step 3: Write `BlockingCall`**

`RoomForMac/Features/Permissions/BlockingCall.swift`
```swift
import Dispatch
import os

/// Runs a call that blocks its thread, such as `AEDeterminePermissionToAutomateTarget`, on a GCD
/// queue, never on the Swift cooperative pool, and stops waiting for it at a deadline.
///
/// The permission call can wait for the user's answer or hang for good (Apple forum 666528).
/// Blocking a cooperative thread with it would starve every other task in the app.
enum BlockingCall {
    /// For checks that never show UI (`askUserIfNeeded == false`).
    static let passiveDeadline: Duration = .seconds(3)
    /// For requests that may show a system prompt and wait for the user's answer.
    static let promptDeadline: Duration = .seconds(120)

    /// Runs `work` on `queue` and returns its result, or nil when `deadline` passes first.
    ///
    /// A blocking call cannot be interrupted. After the deadline, `work` keeps its GCD thread
    /// until it returns, and its result is dropped. The deadline timer runs on `queue` as well,
    /// so `queue` must be concurrent, as the default is: a serial queue would hold the timer
    /// behind `work`.
    static func run<T: Sendable>(
        deadline: Duration,
        queue: DispatchQueue = .global(qos: .userInitiated),
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let isFirst = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst {
                    continuation.resume(returning: value)
                }
            }
            queue.async {
                finish(work())
            }
            queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds(deadline))) {
                finish(nil)
            }
        }
    }

    /// `duration` in whole nanoseconds for a dispatch deadline. A negative duration gives 0,
    /// and one too long for `Int` saturates at `Int.max`, which dispatch treats as "never".
    static func nanoseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow {
            return seconds < 0 ? 0 : Int.max
        }
        let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
        if sumOverflow {
            return whole < 0 ? 0 : Int.max
        }
        return max(0, Int(clamping: total))
    }
}
```

Notes:
- `OSAllocatedUnfairLock` and `CheckedContinuation` are both `Sendable`, so `finish` is a `@Sendable` closure that both dispatch blocks can share under Swift 6 checking.
- `run` does not react to task cancellation. A request that prompts keeps waiting for the user's answer even if the view that started it goes away, and `PermissionCenter` records the answer when it comes.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/BlockingCallTests`
Expected: `✔ Test run with 7 tests in 1 suite passed` and `** TEST SUCCEEDED **`. `dispatchDeadlineInNanoseconds` reports 7 test cases. The suite takes about 0.9 s, most of it in `workThatMissesTheDeadlineStillFinishesAndIsDropped`.

- [ ] **Step 5: Write the fake checker**

`RoomForMacTests/Support/FakeChecker.swift`
```swift
import Foundation
@testable import RoomForMac

/// A permission checker that answers from a script and never touches the system.
///
/// - `currentState()` returns `states` in order, then keeps repeating the last one
///   (`.notDetermined` when `states` is empty).
/// - `request()` does the same with `requestStates`, or answers like `currentState()` when
///   `requestStates` is empty. Its answer is also what every later check returns, as after
///   a real grant.
/// - An answer is taken from the script when the call starts. A `Gate` can then hold it back,
///   the way a slow system call delivers an answer that is already out of date.
struct FakeChecker: PermissionChecking {
    let id: PermissionID
    private let script: Script
    private let checkGate: Gate?
    private let requestGate: Gate?

    init(
        id: PermissionID,
        states: [PermissionState],
        requestStates: [PermissionState] = [],
        checkGate: Gate? = nil,
        requestGate: Gate? = nil
    ) {
        self.id = id
        self.script = Script(checks: states, requests: requestStates)
        self.checkGate = checkGate
        self.requestGate = requestGate
    }

    func currentState() async -> PermissionState {
        let answer = await script.nextCheck()
        await checkGate?.pass()
        return answer
    }

    func request() async -> PermissionState {
        let answer = await script.nextRequest()
        await requestGate?.pass()
        return answer
    }

    /// How many times `currentState()` was called.
    var checkCount: Int {
        get async { await script.checkCount }
    }

    /// How many times `request()` was called.
    var requestCount: Int {
        get async { await script.requestCount }
    }

    private actor Script {
        private var checks: [PermissionState]
        private var requests: [PermissionState]
        private(set) var checkCount = 0
        private(set) var requestCount = 0

        init(checks: [PermissionState], requests: [PermissionState]) {
            self.checks = checks
            self.requests = requests
        }

        func nextCheck() -> PermissionState {
            checkCount += 1
            return Self.next(from: &checks)
        }

        func nextRequest() -> PermissionState {
            requestCount += 1
            let answer: PermissionState
            if requests.isEmpty {
                answer = Self.next(from: &checks)
            } else {
                answer = Self.next(from: &requests)
            }
            checks = [answer]
            return answer
        }

        private static func next(from script: inout [PermissionState]) -> PermissionState {
            guard let first = script.first else { return .notDetermined }
            if script.count > 1 {
                script.removeFirst()
            }
            return first
        }
    }

    /// Holds the first caller of `pass()` until `open()`. Later callers pass straight through,
    /// so a test that goes wrong fails on its expectations instead of hanging.
    actor Gate {
        private var isOpen = false
        private var held: CheckedContinuation<Void, Never>?
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        /// How many callers have reached `pass()`.
        private(set) var arrivals = 0

        func pass() async {
            arrivals += 1
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !isOpen, arrivals == 1 else { return }
            await withCheckedContinuation { held = $0 }
        }

        func open() {
            isOpen = true
            held?.resume()
            held = nil
        }

        /// Returns once `count` callers have reached `pass()`.
        func waitForArrivals(_ count: Int = 1) async {
            while arrivals < count {
                await withCheckedContinuation { arrivalWaiters.append($0) }
            }
        }
    }
}
```

Notes:
- `FakeChecker` is internal, so later test files (Tasks 11–14) can script a `PermissionCenter` with it. Its nested `Script` and `Gate` types keep common names out of the test module.
- The gate holds only the first caller. If a guard in `PermissionCenter` breaks, the second call passes straight through and the test fails on its expectations instead of hanging. (Verified while planning: removing the in-flight guard or the stale-check guard from Step 10's code fails the matching test in milliseconds.)

- [ ] **Step 6: Write the failing permission tests**

`RoomForMacTests/PermissionCenterTests.swift`
```swift
import Foundation
import os
import Testing
@testable import RoomForMac

@Suite("Permission ID")
struct PermissionIDTests {
    /// Raw values name the `permissions.lastKnown.<raw>` preference keys; renaming one loses stored states.
    @Test func rawValuesAreStableStorageKeys() {
        #expect(PermissionID.allCases.map(\.rawValue) == [
            "moveToApplications", "fullDiskAccess", "automationFinder",
            "automationSystemEvents", "notifications", "launchAtLogin",
        ])
    }

    @Test(arguments: [
        (PermissionID.moveToApplications, "Applications folder"),
        (.fullDiskAccess, "Full Disk Access"),
        (.automationFinder, "Finder"),
        (.automationSystemEvents, "System Events"),
        (.notifications, "Notifications"),
        (.launchAtLogin, "Open at login"),
    ])
    func title(id: PermissionID, english: String) {
        #expect(String(localized: id.title) == english)
    }

    @Test func codesAsItsRawValue() throws {
        let data = try JSONEncoder().encode([PermissionID.automationSystemEvents])
        #expect(String(decoding: data, as: UTF8.self) == #"["automationSystemEvents"]"#)
        #expect(try JSONDecoder().decode([PermissionID].self, from: data) == [.automationSystemEvents])
    }
}

@Suite("Permission state")
struct PermissionStateTests {
    static let stored: [(PermissionState, String)] = [
        (.granted, "granted"),
        (.denied, "denied"),
        (.notDetermined, "notDetermined"),
        (.requiresApproval, "requiresApproval"),
        (.unknown("not running"), "unknown:not running"),
        (.unknown(""), "unknown:"),
        (.unknown("OSStatus -1:2"), "unknown:OSStatus -1:2"),
        (.notApplicable, "notApplicable"),
    ]

    @Test(arguments: stored)
    func storageRoundTrip(state: PermissionState, storageValue: String) {
        #expect(state.storageValue == storageValue)
        #expect(PermissionState(storageValue: storageValue) == state)
    }

    @Test(arguments: ["", "Granted", "unknown", "allowed", " granted", "granted "])
    func unreadableStorageGivesNil(storageValue: String) {
        #expect(PermissionState(storageValue: storageValue) == nil)
    }

    @Test func onlyGrantedAndNotApplicableCountAsGranted() {
        let all: [PermissionState] = [.granted, .denied, .notDetermined, .requiresApproval, .unknown("x"), .notApplicable]
        #expect(all.filter(\.isGranted) == [.granted, .notApplicable])
    }
}

@Suite("System Settings links")
struct SystemSettingsLinkTests {
    @Test(arguments: [
        (SystemSettingsLink.fullDiskAccess, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
        (.automation, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"),
        (.appManagement, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"),
        (.loginItems, "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
        (.notifications, "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
    ])
    func url(link: SystemSettingsLink, expected: String) {
        #expect(link.url.absoluteString == expected)
        #expect(link.url.scheme == "x-apple.systempreferences")
    }

    @Test func theTableAboveCoversEveryLink() {
        #expect(SystemSettingsLink.allCases.count == 5)
    }
}

/// Records the durations `PermissionCenter.poll` asks to sleep, and returns at once.
private final class SleepRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var durations: [Duration] {
        recorded.withLock { $0 }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [recorded] duration in
            recorded.withLock { $0.append(duration) }
        }
    }
}

@MainActor
@Suite("Permission center")
struct PermissionCenterTests {
    /// Held by the suite so the defaults outlive every use inside a test.
    private let temporary: TemporaryDefaults
    private var preferences: AppPreferences { temporary.preferences }

    init() throws {
        temporary = try TemporaryDefaults()
    }

    // MARK: Checking and requesting

    @Test func everyStateIsNotDeterminedBeforeTheFirstCheck() {
        let center = PermissionCenter(checkers: [FakeChecker(id: .fullDiskAccess, states: [.granted])])
        #expect(center.states.isEmpty)
        for id in PermissionID.allCases {
            #expect(center.state(id) == .notDetermined)
        }
        #expect(center.hasChecker(.fullDiskAccess))
        #expect(!center.hasChecker(.notifications))
    }

    @Test func refreshStoresTheAnswer() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let center = PermissionCenter(checkers: [checker])
        await center.refresh(.fullDiskAccess)
        #expect(center.states == [.fullDiskAccess: .denied])
        #expect(center.state(.fullDiskAccess) == .denied)
        #expect(await checker.checkCount == 1)
    }

    @Test func refreshAllChecksEveryCheckerOnce() async {
        let fullDisk = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let finder = FakeChecker(id: .automationFinder, states: [.granted])
        let login = FakeChecker(id: .launchAtLogin, states: [.requiresApproval])
        let center = PermissionCenter(checkers: [fullDisk, finder, login])
        await center.refreshAll()
        #expect(center.states == [.fullDiskAccess: .denied, .automationFinder: .granted, .launchAtLogin: .requiresApproval])
        #expect(await fullDisk.checkCount == 1)
        #expect(await finder.checkCount == 1)
        #expect(await login.checkCount == 1)
    }

    @Test func anIDWithoutACheckerIsLeftAlone() async {
        let center = PermissionCenter(checkers: [])
        await center.refresh(.notifications)
        await center.request(.notifications)
        await center.refreshAll()
        #expect(center.states.isEmpty)
        #expect(center.state(.notifications) == .notDetermined)
    }

    @Test func theFirstCheckerForAnIDWins() async {
        let first = FakeChecker(id: .notifications, states: [.granted])
        let second = FakeChecker(id: .notifications, states: [.denied])
        let center = PermissionCenter(checkers: [first, second])
        await center.refresh(.notifications)
        #expect(center.state(.notifications) == .granted)
        #expect(await second.checkCount == 0)
    }

    @Test func requestUpdatesTheState() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied], requestStates: [.granted])
        let center = PermissionCenter(checkers: [checker])
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .denied)
        await center.request(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .granted)
        #expect(await checker.requestCount == 1)
        #expect(!center.isRequesting(.fullDiskAccess))
    }

    /// A double-click must not move the app twice or stack two prompts.
    @Test func aSecondRequestWhileOneIsInFlightIsIgnored() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(
            id: .automationSystemEvents, states: [.notDetermined], requestStates: [.granted], requestGate: gate
        )
        let center = PermissionCenter(checkers: [checker])
        let first = Task { await center.request(.automationSystemEvents) }
        await gate.waitForArrivals(1)
        #expect(center.isRequesting(.automationSystemEvents))

        await center.request(.automationSystemEvents)
        #expect(await checker.requestCount == 1)
        #expect(center.state(.automationSystemEvents) == .notDetermined)

        await gate.open()
        await first.value
        #expect(center.state(.automationSystemEvents) == .granted)
        #expect(!center.isRequesting(.automationSystemEvents))
        #expect(await checker.requestCount == 1)
    }

    /// The check read "not yet" before the user answered the prompt; its late answer must not
    /// replace the request's newer one.
    @Test func aCheckThatStartedBeforeARequestAnsweredIsDropped() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(
            id: .automationFinder, states: [.notDetermined], requestStates: [.granted], checkGate: gate
        )
        let center = PermissionCenter(checkers: [checker])
        let check = Task { await center.refresh(.automationFinder) }
        await gate.waitForArrivals(1)

        await center.request(.automationFinder)
        #expect(center.state(.automationFinder) == .granted)

        await gate.open()
        await check.value
        #expect(center.state(.automationFinder) == .granted)
        #expect(await checker.checkCount == 1)
    }

    // MARK: Polling

    @Test func pollChecksEverySecondUntilGranted() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied, .denied, .granted])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess)
        #expect(await checker.checkCount == 3)
        #expect(sleeps.durations == [.seconds(1), .seconds(1)])
        #expect(center.state(.fullDiskAccess) == .granted)
    }

    @Test func pollSleepsForTheGivenInterval() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied, .granted])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess, every: .milliseconds(250))
        #expect(sleeps.durations == [.milliseconds(250)])
    }

    @Test func pollStopsAtNotApplicable() async {
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .moveToApplications, states: [.notApplicable])
        let center = PermissionCenter(checkers: [checker], sleep: sleeps.sleep)
        await center.poll(.moveToApplications)
        #expect(await checker.checkCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func pollReturnsWhenSleepThrows() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let center = PermissionCenter(checkers: [checker], sleep: { _ in throw CancellationError() })
        await center.poll(.fullDiskAccess)
        #expect(await checker.checkCount == 1)
    }

    @Test func pollReturnsWhenItsTaskIsCancelled() async {
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied])
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        // The first sleep cancels the polling task and returns normally, so only the loop's own
        // cancellation check can end the poll. A second sleep means the loop missed it; throwing
        // then ends the poll so the test fails instead of hanging.
        let center = PermissionCenter(checkers: [checker], sleep: { _ in
            let count = sleeps.withLock { count in
                count += 1
                return count
            }
            if count > 1 { throw CancellationError() }
            withUnsafeCurrentTask { $0?.cancel() }
        })
        // Poll in a task of its own: cancelling the test's task would cancel the test.
        let polling = Task { await center.poll(.fullDiskAccess) }
        await polling.value
        #expect(polling.isCancelled)
        #expect(await checker.checkCount == 1)
        #expect(sleeps.withLock { $0 } == 1)
    }

    @Test func cancellingThePollingTaskEndsARealSleep() async {
        let gate = FakeChecker.Gate()
        let checker = FakeChecker(id: .fullDiskAccess, states: [.denied], checkGate: gate)
        let center = PermissionCenter(checkers: [checker])
        let clock = ContinuousClock()
        let start = clock.now
        let polling = Task { await center.poll(.fullDiskAccess, every: .seconds(60)) }
        await gate.waitForArrivals(1)
        await gate.open()
        polling.cancel()
        await polling.value
        #expect(clock.now - start < .seconds(5))
        #expect(await checker.checkCount == 1)
    }

    @Test func pollWithoutACheckerReturnsAtOnce() async {
        let sleeps = SleepRecorder()
        let center = PermissionCenter(checkers: [], sleep: sleeps.sleep)
        await center.poll(.fullDiskAccess)
        #expect(sleeps.durations.isEmpty)
    }

    // MARK: Last known states

    @Test func learnedStatesAreStoredAsLastKnown() async {
        let center = PermissionCenter(checkers: [
            FakeChecker(id: .fullDiskAccess, states: [.denied]),
            FakeChecker(id: .automationFinder, states: [.notDetermined], requestStates: [.granted]),
        ], preferences: preferences)
        await center.refreshAll()
        #expect(preferences.lastKnownState(for: "fullDiskAccess") == "denied")
        #expect(preferences.lastKnownState(for: "automationFinder") == "notDetermined")
        await center.request(.automationFinder)
        #expect(preferences.lastKnownState(for: "automationFinder") == "granted")
    }

    @Test func unknownIsNotStored() async {
        preferences.setLastKnownState("granted", for: "automationSystemEvents")
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")])],
            preferences: preferences
        )
        await center.refresh(.automationSystemEvents)
        #expect(center.states[.automationSystemEvents] == .unknown("not running"))
        #expect(preferences.lastKnownState(for: "automationSystemEvents") == "granted")
    }

    @Test(arguments: [PermissionID.automationFinder, .automationSystemEvents])
    func automationShowsTheLastKnownStateWhileUnknown(id: PermissionID) async {
        preferences.setLastKnownState("denied", for: id.rawValue)
        let center = PermissionCenter(
            checkers: [FakeChecker(id: id, states: [.unknown("not running"), .granted])],
            preferences: preferences
        )
        await center.refresh(id)
        #expect(center.states[id] == .unknown("not running"))
        #expect(center.state(id) == .denied)
        await center.refresh(id)
        #expect(center.state(id) == .granted)
    }

    @Test func theLastKnownStateSurvivesARelaunch() async {
        let before = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.granted])],
            preferences: preferences
        )
        await before.refresh(.automationSystemEvents)

        let after = PermissionCenter(
            checkers: [FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")])],
            preferences: AppPreferences(defaults: temporary.defaults)
        )
        await after.refresh(.automationSystemEvents)
        #expect(after.state(.automationSystemEvents) == .granted)
    }

    @Test func otherPermissionsShowUnknownAsIs() async {
        preferences.setLastKnownState("granted", for: "fullDiskAccess")
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .fullDiskAccess, states: [.unknown("no probe file")])],
            preferences: preferences
        )
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .unknown("no probe file"))
    }

    @Test func unknownWithNothingStoredStaysUnknown() async {
        let center = PermissionCenter(
            checkers: [FakeChecker(id: .automationFinder, states: [.unknown("timed out")])],
            preferences: preferences
        )
        await center.refresh(.automationFinder)
        #expect(center.state(.automationFinder) == .unknown("timed out"))
    }

    @Test func pollIgnoresTheLastKnownFallback() async {
        preferences.setLastKnownState("granted", for: "automationFinder")
        let sleeps = SleepRecorder()
        let checker = FakeChecker(id: .automationFinder, states: [.unknown("not running"), .granted])
        let center = PermissionCenter(checkers: [checker], preferences: preferences, sleep: sleeps.sleep)
        await center.poll(.automationFinder)
        #expect(await checker.checkCount == 2)
        #expect(sleeps.durations == [.seconds(1)])
    }
}
```

Notes:
- `PermissionCenterTests` is `@MainActor` because `PermissionCenter` is. A `Task { … }` started inside a test inherits the main actor, and `await gate.waitForArrivals(1)` hands the main actor to it until the checker has been called.
- `pollReturnsWhenItsTaskIsCancelled` polls inside its own `Task`. Cancelling the test's own task would make Swift Testing report the test as cancelled rather than passed.
- The suite keeps Task 7's `TemporaryDefaults` in a stored property, so each test gets a fresh `UserDefaults` suite that is removed after the test, and nothing touches `UserDefaults.standard`.

- [ ] **Step 7: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/PermissionCenterTests`
Expected: `** TEST FAILED **` (exit 65). The test target stops compiling with errors such as:
```
RoomForMacTests/PermissionCenterTests.swift:17:10: error: cannot find 'PermissionID' in scope
RoomForMacTests/PermissionCenterTests.swift:37:26: error: cannot find type 'PermissionState' in scope
RoomForMacTests/PermissionCenterTests.swift:68:10: error: cannot find 'SystemSettingsLink' in scope
RoomForMacTests/Support/FakeChecker.swift:13:21: error: cannot find type 'PermissionChecking' in scope
```

- [ ] **Step 8: Write the permission model**

`RoomForMac/Features/Permissions/PermissionID.swift`
```swift
import Foundation

/// Every approval that onboarding and Settings track.
///
/// The raw values are storage keys: they name the `permissions.lastKnown.<raw>` preferences
/// and are what `Codable` writes. Never rename a case's raw value.
enum PermissionID: String, Sendable, CaseIterable, Codable {
    case moveToApplications
    case fullDiskAccess
    case automationFinder
    case automationSystemEvents
    case notifications
    case launchAtLogin

    var title: LocalizedStringResource {
        switch self {
        case .moveToApplications: "Applications folder"
        case .fullDiskAccess: "Full Disk Access"
        case .automationFinder: "Finder"
        case .automationSystemEvents: "System Events"
        case .notifications: "Notifications"
        case .launchAtLogin: "Open at login"
        }
    }
}
```

`RoomForMac/Features/Permissions/PermissionState.swift`
```swift
import Foundation

/// What RoomForMac knows about one approval.
enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Registered, but the user still has to approve it in System Settings (login items).
    case requiresApproval
    /// No reliable answer right now. The reason ("not running", "timed out") is diagnostic
    /// text for logs; the UI shows "Unknown", never the reason.
    case unknown(String)
    /// This approval does not apply to this copy of the app (e.g. a DEBUG build skips Move).
    case notApplicable

    /// True when nothing is left for the user to do.
    var isGranted: Bool {
        switch self {
        case .granted, .notApplicable: true
        case .denied, .notDetermined, .requiresApproval, .unknown: false
        }
    }

    /// The value stored as a last-known state. `init(storageValue:)` reads it back.
    var storageValue: String {
        switch self {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .requiresApproval: "requiresApproval"
        case .unknown(let reason): Self.unknownPrefix + reason
        case .notApplicable: "notApplicable"
        }
    }

    /// nil for anything `storageValue` never writes.
    init?(storageValue: String) {
        switch storageValue {
        case "granted": self = .granted
        case "denied": self = .denied
        case "notDetermined": self = .notDetermined
        case "requiresApproval": self = .requiresApproval
        case "notApplicable": self = .notApplicable
        default:
            guard storageValue.hasPrefix(Self.unknownPrefix) else { return nil }
            self = .unknown(String(storageValue.dropFirst(Self.unknownPrefix.count)))
        }
    }

    private static let unknownPrefix = "unknown:"
}
```

`RoomForMac/Features/Permissions/PermissionChecking.swift`
```swift
import Foundation

/// Detects and requests one approval.
///
/// Implementations reach the system only through injected closures, so unit tests drive them
/// with scripted answers and never trigger a real prompt.
protocol PermissionChecking: Sendable {
    var id: PermissionID { get }

    /// Reads the current state. Never shows UI or a prompt.
    func currentState() async -> PermissionState

    /// Asks for the approval: may show a system prompt, open System Settings or move the app.
    /// Returns the state right after asking.
    func request() async -> PermissionState
}
```

- [ ] **Step 9: Write the System Settings links**

`RoomForMac/Features/Permissions/SystemSettingsLink.swift`
```swift
import Foundation

/// Deep links into System Settings, opened with `NSWorkspace.shared.open(_:)`.
///
/// The anchors come from the Privacy & Security extension's `TCCServiceList.plist` on
/// macOS 27. A wrong anchor fails silently and shows the top of the pane.
enum SystemSettingsLink: Sendable, CaseIterable {
    case fullDiskAccess
    case automation
    case appManagement
    case loginItems
    case notifications

    var urlString: String {
        switch self {
        case .fullDiskAccess: Self.privacyAndSecurity + "?Privacy_AllFiles"
        case .automation: Self.privacyAndSecurity + "?Privacy_Automation"
        case .appManagement: Self.privacyAndSecurity + "?Privacy_AppBundles"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
    }

    var url: URL {
        // Every string above is a valid URL; the tests pin each one.
        URL(string: urlString)!
    }

    private static let privacyAndSecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
}
```

- [ ] **Step 10: Write `PermissionCenter`**

`RoomForMac/Features/Permissions/PermissionCenter.swift`
```swift
import Foundation
import Observation

/// The single source of truth for approvals. Onboarding and Settings read `state(_:)` and call
/// `refresh`, `request` and `poll`; the checkers do the system work.
///
/// It checks nothing on its own: views decide when to refresh, and the unit-test host never does.
@MainActor @Observable
final class PermissionCenter {
    /// Each checker's latest answer, as given. Empty until the first check.
    private(set) var states: [PermissionID: PermissionState] = [:]
    private var requestsInFlight: Set<PermissionID> = []

    private let checkers: [PermissionID: any PermissionChecking]
    private let preferences: AppPreferences?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// How many requests have answered, per permission. A check that started before the latest
    /// answer is out of date.
    @ObservationIgnored private var answeredRequests: [PermissionID: Int] = [:]

    /// Automation checks answer `.unknown` whenever Finder or System Events is not running, so for
    /// these `state(_:)` shows the last state learned, possibly in an earlier launch.
    static let lastKnownFallback: Set<PermissionID> = [.automationFinder, .automationSystemEvents]

    init(
        checkers: [any PermissionChecking],
        preferences: AppPreferences? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        var byID: [PermissionID: any PermissionChecking] = [:]
        for checker in checkers where byID[checker.id] == nil {
            byID[checker.id] = checker
        }
        self.checkers = byID
        self.preferences = preferences
        self.sleep = sleep
    }

    /// What the UI shows: `.notDetermined` without a checker or an answer, the last known state
    /// for an unknown Automation answer, and otherwise the latest answer.
    func state(_ id: PermissionID) -> PermissionState {
        guard let latest = states[id] else { return .notDetermined }
        if case .unknown = latest, Self.lastKnownFallback.contains(id),
           let stored = preferences?.lastKnownState(for: id.rawValue),
           let remembered = PermissionState(storageValue: stored) {
            return remembered
        }
        return latest
    }

    func hasChecker(_ id: PermissionID) -> Bool {
        checkers[id] != nil
    }

    /// True while a `request(id)` is waiting for its checker.
    func isRequesting(_ id: PermissionID) -> Bool {
        requestsInFlight.contains(id)
    }

    func refresh(_ id: PermissionID) async {
        guard let checker = checkers[id] else { return }
        let ticket = answeredRequests[id, default: 0]
        let answer = await checker.currentState()
        recordCheck(answer, for: id, ticket: ticket)
    }

    /// Checks every permission at once, so one slow Automation check does not hold up the rest.
    func refreshAll() async {
        let jobs = checkers.map { id, checker in (id, checker, answeredRequests[id, default: 0]) }
        await withTaskGroup(of: (PermissionID, PermissionState, Int).self) { group in
            for (id, checker, ticket) in jobs {
                group.addTask { (id, await checker.currentState(), ticket) }
            }
            for await (id, answer, ticket) in group {
                recordCheck(answer, for: id, ticket: ticket)
            }
        }
    }

    /// Asks once. A second call for the same permission while the first is in flight returns at
    /// once: a double-click must not move the app twice or stack two prompts.
    func request(_ id: PermissionID) async {
        guard let checker = checkers[id], !requestsInFlight.contains(id) else { return }
        requestsInFlight.insert(id)
        defer { requestsInFlight.remove(id) }
        let answer = await checker.request()
        answeredRequests[id, default: 0] += 1
        record(answer, for: id)
    }

    /// Checks every `interval` until the latest answer is granted, or until the calling task is
    /// cancelled. The last-known fallback never ends a poll. Never throws.
    func poll(_ id: PermissionID, every interval: Duration = .seconds(1)) async {
        guard hasChecker(id) else { return }
        while !Task.isCancelled {
            await refresh(id)
            if states[id]?.isGranted == true { return }
            do {
                try await self.sleep(interval)
            } catch {
                return
            }
        }
    }

    private func recordCheck(_ answer: PermissionState, for id: PermissionID, ticket: Int) {
        guard answeredRequests[id, default: 0] == ticket else { return }
        record(answer, for: id)
    }

    /// Keeps the answer, and stores it as the last known state unless it is `.unknown`, which
    /// carries no evidence and would erase the state the fallback needs.
    private func record(_ answer: PermissionState, for id: PermissionID) {
        states[id] = answer
        if case .unknown = answer { return }
        preferences?.setLastKnownState(answer.storageValue, for: id.rawValue)
    }
}
```

Notes:
- `answeredRequests` is the stale-check guard. Each check records how many requests had answered when it started, and its answer counts only if that number has not changed. Nothing in the UI reads it, so it is `@ObservationIgnored`. `states` and `requestsInFlight` stay observed, so views update when they change.
- `refreshAll` records each answer as its child task finishes. The task group's body runs on the main actor (the `#isolation` default of `withTaskGroup`), while `currentState()` runs in the child tasks, off the main actor.
- `poll` reads `states[id]`, not `state(id)`, so the last-known fallback cannot end it.
- `self.sleep` names the stored closure, not Darwin's `sleep(_:)`.

- [ ] **Step 11: Run the permission tests to verify they pass**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test \
    -only-testing:RoomForMacTests/PermissionIDTests -only-testing:RoomForMacTests/PermissionStateTests \
    -only-testing:RoomForMacTests/SystemSettingsLinkTests -only-testing:RoomForMacTests/PermissionCenterTests
```
Expected: `✔ Test run with 30 tests in 4 suites passed` and `** TEST SUCCEEDED **`: "Permission ID" 3 tests, "Permission state" 3, "System Settings links" 2 and "Permission center" 22. The parameterized tests report their cases (`title(id:english:)` 6, `storageRoundTrip` 8, `unreadableStorageGivesNil` 6, `url(link:expected:)` 5, `automationShowsTheLastKnownStateWhileUnknown(id:)` 2).

- [ ] **Step 12: Run the whole unit scheme and the concurrency checks**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-8.log" | tail -n 5
grep -E '(RoomForMac/Features/Permissions/|RoomForMacTests/(PermissionCenterTests|BlockingCallTests|Support/FakeChecker)).*(warning|error):' "$TMPDIR/rfm-task-8.log"
```
Expected: the tail shows `** TEST SUCCEEDED **` (stderr can put a stray `Testing started` after it), and the `grep` prints nothing, so this task's files compile without warnings. The Swift Testing summary includes this task's five suites (37 tests) next to those of Tasks 1–7. The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

Run: `for arch in arm64 x86_64; do xcrun swiftc -typecheck -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$arch-apple-macos26.0" -swift-version 6 -warnings-as-errors RoomForMac/Features/Permissions/{PermissionID,PermissionState,PermissionChecking,PermissionCenter,BlockingCall,SystemSettingsLink}.swift RoomForMac/App/AppPreferences.swift && echo "$arch ok"; done`
Expected: `arm64 ok` and `x86_64 ok` with no diagnostics. The permission core type-checks for both slices of the universal build under Swift 6 complete concurrency checking. (It also type-checks with the `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` upcoming features, in case a later plan turns on approachable concurrency.)

- [ ] **Step 13: Add the new strings to the String Catalog**

`xcodebuild` does not update `Localizable.xcstrings` (only the Xcode editor does), so sync the catalog from the `.stringsdata` files that the Step 12 build left for the app target:

```bash
OBJ=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null \
    | awk '/Build settings for action .* and target RoomForMac:/ { t = 1 } t && $1 == "OBJECT_FILE_DIR_normal" { print $3; exit }')
xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --skip-marking-strings-stale --stringsdata "$OBJ"/*/*.stringsdata
git diff RoomForMac/Resources/Localizable.xcstrings
```

Expected: `xcstringstool` prints nothing and exits 0. The diff adds these six keys, each an empty entry (English is the source language), unless an earlier task already added one: `"Applications folder"`, `"Finder"`, `"Full Disk Access"`, `"Notifications"`, `"Open at login"`, `"System Events"`. Every key from earlier tasks stays; `--skip-marking-strings-stale` keeps the sync from marking them stale.

- [ ] **Step 14: Commit**

```bash
git add RoomForMac/Features/Permissions/PermissionID.swift RoomForMac/Features/Permissions/PermissionState.swift \
    RoomForMac/Features/Permissions/PermissionChecking.swift RoomForMac/Features/Permissions/PermissionCenter.swift \
    RoomForMac/Features/Permissions/BlockingCall.swift RoomForMac/Features/Permissions/SystemSettingsLink.swift \
    RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/Support/FakeChecker.swift RoomForMacTests/PermissionCenterTests.swift \
    RoomForMacTests/BlockingCallTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'EOF'
feat(permissions): permission center, blocking-call deadline and Settings links

PermissionCenter is the single source of truth for approvals. It asks
injected checkers, stores every answer but "unknown" as the last known
state, and shows that state while an Automation check cannot answer. A
check that started before a request answered is dropped, and a second
request while one is in flight is ignored. BlockingCall runs blocking
Apple-event permission calls on GCD with a deadline, never on the
cooperative pool. SystemSettingsLink holds the Privacy & Security,
Login Items and Notifications deep links.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 9: Live permission checkers — Full Disk Access, Automation, Notifications, Login item

**Files:**
- Create: `RoomForMac/Features/Permissions/FullDiskAccessChecker.swift`, `AutomationChecker.swift`, `AppleEventPermission.swift`, `NotificationChecker.swift`, `LoginItemChecker.swift`, `RoomForMacTests/FullDiskAccessCheckerTests.swift`, `RoomForMacTests/AutomationCheckerTests.swift`, `RoomForMacTests/NotificationAndLoginCheckerTests.swift`
- Create (added; test support the three test files share): `RoomForMacTests/Support/Locked.swift`

**Interfaces:**
- Consumes: `PermissionID`, `PermissionState`, `PermissionChecking`, `BlockingCall`, `SystemSettingsLink` (Task 8). The tests also use `TemporaryDirectory` (Task 3, `RoomForMacTests/Support`).
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
- Added by this task, as the Requirements already ask: `AutomationChecker.init` takes two more parameters, appended after `openSettings:` and defaulted, so every call shape above still compiles:
  ```swift
  //  …, passiveDeadline: Duration = BlockingCall.passiveDeadline, promptDeadline: Duration = BlockingCall.promptDeadline)
  ```
- Added by this task (internal to this task; nothing else depends on them):
  ```swift
  // Internal stored properties (tests read them):
  //   FullDiskAccessChecker.probe: FullDiskAccessProbe
  //   AutomationChecker.target: Target, .passiveDeadline: Duration, .promptDeadline: Duration
  extension AutomationChecker {
      static let launchWait: Duration           // .seconds(2): how long a request waits for a target it launched
      static let launchPollInterval: Duration   // .milliseconds(100)
  }
  extension LoginItemChecker { static let alreadyRegisteredCode: Int }      // Int(kSMErrorAlreadyRegistered) == 12
  // Every checker's `id` is fixed: .fullDiskAccess, target.permissionID, .notifications, .launchAtLogin.
  // The complete set of `.unknown` reasons this task produces (diagnostic data, stored by Task 8 as "unknown:<reason>"):
  //   "no probe file", "timed out", "not running", "OSStatus <n>", "status <rawValue>",
  //   "request failed: <NSError code>", "unavailable in this build", "SMAppService error <code>"
  // Test support, RoomForMacTests/Support/Locked.swift (one copy, shared by the three test files):
  final class Locked<Value: Sendable>: Sendable {   // a Mutex-backed value the fakes change from any thread or actor
      init(_ value: Value)
      var value: Value { get }
      func set(_ newValue: Value)
      func mutate(_ change: (inout Value) -> Void)
      func append<Element: Sendable>(_ element: Element) where Value == [Element]
  }
  ```

**Requirements:**
- **Full Disk Access probe** (Ruling 11, research §1.1):
  - The default candidates, in order: `/Library/Application Support/com.apple.TCC/TCC.db` (always present, `root:wheel 0644`, closed only by TCC), `<home>/Library/Safari/Bookmarks.plist`, `/Library/Preferences/com.apple.TimeMachine.plist`, `<home>/Library/Application Support/com.apple.TCC/TCC.db` (absent on macOS 27). Nothing under `~/Library/Containers/`, which can raise the "access data from other apps" prompt.
  - `check()` calls `open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)` on each candidate in order and closes a descriptor it gets at once. It never reads, and never uses `stat` (which succeeds on protected files).
  - The first candidate that opens → `.granted`. Otherwise, any EPERM or EACCES → `.denied`. Otherwise (ENOENT or any other error, or no candidates) → `.indeterminate`, which is never read as granted.
- **`FullDiskAccessChecker`:** `currentState` maps the probe (`.indeterminate` → `.unknown("no probe file")`) and never opens System Settings. `request` opens `SystemSettingsLink.fullDiskAccess.url` through `openSettings`, then returns `currentState()`. It does not poll; Task 8's `PermissionCenter.poll` does.
- **`AppleEventPermission.determine`** builds the target with `NSAppleEventDescriptor(bundleIdentifier:)`, keeps the descriptor alive across the call (`withExtendedLifetime`), and calls `AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, askUserIfNeeded)`. A descriptor without `aeDesc` returns `paramErr` (-50). It blocks, and with `askUserIfNeeded` it can block forever, so every caller goes through `BlockingCall.run`. `state(forStatus:)` uses the SDK constants `noErr`, `errAEEventNotPermitted`, `errAEEventWouldRequireUserConsent` and `procNotFound`; the tests pin the literal numbers.
- **`AutomationChecker`** (spike S2, research §1.2):
  - `currentState` is `determine(bundleIdentifier, false)` through `BlockingCall.run(deadline: passiveDeadline)`. It never launches the target and never prompts. A target that is not running gives `.unknown("not running")`, and Task 8 shows the last known state instead.
  - `request`: when `isRunning(bundleIdentifier)` is false it calls `launchHidden(applicationURL)` once. Only when that returns true does it wait, polling `isRunning` every `launchPollInterval` for at most `launchWait`; a failed launch goes straight on. Then `determine(bundleIdentifier, true)` through `BlockingCall.run(deadline: promptDeadline)`. Only `.denied` opens `SystemSettingsLink.automation.url` (macOS never prompts again once denied); a timed-out request returns `.unknown("timed out")` and opens nothing.
  - `live` supplies `launchHidden` through `NSWorkspace.shared.openApplication(at:configuration:)` with `activates = false`, `hides = true` and `addsToRecentItems = false`. It returns false when the launch throws. After a launch it waits at most `launchWait` for `isFinishedLaunching`, the order the research probe verified before its query answered -1744, and returns true.
- **`NotificationChecker`:**
  - `state(for:)`: `.authorized`, `.provisional` and `.ephemeral` → `.granted`; `.denied` → `.denied`; `.notDetermined` → `.notDetermined`; `@unknown default` → `.unknown("status <rawValue>")`. `.ephemeral` is `API_UNAVAILABLE(macos)`: an expression cannot name it, but a `switch` pattern can (verified with Swift 6.4), so the interface's mapping stands and the test builds it as `UNAuthorizationStatus(rawValue: 4)!`.
  - `request` calls `requestAuthorization`, then returns the status read afterwards, whatever the call returned. If it throws and the status is still `.notDetermined`, the result is `.unknown("request failed: <code>")`, never "Not yet".
  - `live()` asks for `[.alert, .sound, .badge]`. `UNUserNotificationCenter.current()` raises an exception in a process without a bundle, so it is only ever touched inside the two live closures.
- **`LoginItemChecker`:**
  - `request` calls `register`. A thrown error with code 12 (`kSMErrorAlreadyRegistered`) is success, whatever its domain. It then reads the status: `.requiresApproval` calls `openLoginItemsSettings` and returns `.requiresApproval`. Any other register error that leaves the status `.notRegistered` returns `.unknown("SMAppService error <code>")`.
  - `disable` calls `unregister`, ignores its error (`kSMErrorJobNotFound` when it was never registered), and returns the status read afterwards. A failed unregister of an enabled item therefore still reads `.granted`.
  - `live()` uses `SMAppService.mainApp` for status, register and unregister, and `SMAppService.openSystemSettingsLoginItems()`. Ad-hoc dev builds usually report `.notFound` → "unavailable in this build".
- **No system calls in tests.** Unit tests inject every closure. The only real system calls are `open()` on files in a `TemporaryDirectory`. `live()` checkers are built in one test to read their deadlines and are never called. Nothing here prompts, launches an app or opens System Settings under test.
- **Strings:** this task adds no user-facing strings. The `.unknown` reasons are diagnostic data (Task 8 stores them as `unknown:<reason>`; Task 12's `PermissionChip` shows "Unknown" for all of them), so the String Catalog does not change. Step 13 checks that the five source files emit empty string tables.
- Tests (no real AE, notification or SMAppService calls):
  - FDA probe: with temp files, a readable file → `.granted`; a file with mode 000 (EACCES when not root) → `.denied`; a missing path → `.indeterminate`; the order matters (the first readable file wins); the default candidates list starts with the system TCC.db. The mode-000 cases are `.enabled(if: geteuid() != 0)`, because root opens a mode-000 file.
  - `FullDiskAccessChecker.request` calls `openSettings` with `SystemSettingsLink.fullDiskAccess.url`; `currentState` maps all three probe results and never calls `openSettings`.
  - Every `AppleEventPermission.state(forStatus:)` mapping (0, -1743, -1744, -600, and two others).
  - `AutomationChecker`: passive check passes `ask == false`; request passes `ask == true`; not running → `launchHidden` called once with the target's URL; a failed launch does not wait; a denied request → `openSettings(.automation)`; a `determine` that blocks for 5 s against an injected short deadline gives `.unknown("timed out")`, for the passive check and for a request (which then opens nothing); `live` uses the `BlockingCall` deadlines; the targets' bundle IDs, app paths and permission IDs.
  - Notification mapping for every status, and `request` returning granted, denied, and unknown after a thrown error.
  - Login item: mapping for every status; `request` calls `register` then, on `.requiresApproval`, `openLoginItemsSettings`; `register` throwing error code 12 is treated as success; another register error → `.unknown`; `disable` calls `unregister` and reports the state it left.

Every system call sits behind a closure, so the fakes in the tests stand in for macOS completely. Two test details matter: the "hangs" tests block the fake `determine` on a `DispatchSemaphore` that the test signals in a `defer`, so the GCD thread `BlockingCall` gave up on is released when the test ends; and each fake records its calls in `Locked`, the one `Mutex`-backed box in `RoomForMacTests/Support/Locked.swift` that all three test files share. The fakes themselves stay nested in each suite's extension, because a `private` top-level helper would clash with any internal type of the same name in another test file ("invalid redeclaration").

- [ ] **Step 1: Write the test support and the failing Full Disk Access tests**

`RoomForMacTests/Support/Locked.swift` (the fakes of all three test files in this task record their calls in it)
```swift
import Synchronization

/// A value that test fakes change from any thread or actor, behind a `Mutex`.
/// One copy for the checker tests, so no test file carries its own.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        mutex.withLock { $0 }
    }

    func set(_ newValue: Value) {
        mutex.withLock { $0 = newValue }
    }

    func mutate(_ change: (inout Value) -> Void) {
        mutex.withLock { change(&$0) }
    }

    func append<Element: Sendable>(_ element: Element) where Value == [Element] {
        mutex.withLock { $0.append(element) }
    }
}
```

`RoomForMacTests/FullDiskAccessCheckerTests.swift`
```swift
import Darwin
import Foundation
import Testing
@testable import RoomForMac

@Suite("Full Disk Access probe and checker")
struct FullDiskAccessCheckerTests {
    /// Root opens a mode-000 file, so the "denied" cases only hold for a normal user.
    static let runsAsNormalUser = geteuid() != 0

    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// Writes a small file with the given POSIX permissions and returns its path.
    private func file(_ name: String, permissions: Int = 0o644) throws -> String {
        let url = directory.url.appending(path: name)
        try Data("probe".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url.path
    }

    private var missing: String {
        directory.url.appending(path: "missing.db").path
    }

    // MARK: Probe

    @Test func aReadableFileMeansGranted() throws {
        #expect(FullDiskAccessProbe(candidates: [try file("Bookmarks.plist")]).check() == .granted)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func aFileThatCannotBeOpenedMeansDenied() throws {
        #expect(FullDiskAccessProbe(candidates: [try file("TCC.db", permissions: 0o000)]).check() == .denied)
    }

    @Test func aMissingFileIsNoEvidence() {
        #expect(FullDiskAccessProbe(candidates: [missing]).check() == .indeterminate)
        #expect(FullDiskAccessProbe(candidates: []).check() == .indeterminate)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func theFirstReadableFileWins() throws {
        let locked = try file("TCC.db", permissions: 0o000)
        let readable = try file("Bookmarks.plist")
        #expect(FullDiskAccessProbe(candidates: [locked, missing, readable]).check() == .granted)
        #expect(FullDiskAccessProbe(candidates: [readable, locked]).check() == .granted)
        #expect(FullDiskAccessProbe(candidates: [missing, locked]).check() == .denied)
        #expect(FullDiskAccessProbe(candidates: [locked, missing]).check() == .denied)
    }

    @Test func theDefaultCandidatesStartWithTheSystemTCCDatabase() {
        let probe = FullDiskAccessProbe(home: "/Users/test")
        #expect(probe.candidates == [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/test/Library/Safari/Bookmarks.plist",
            "/Library/Preferences/com.apple.TimeMachine.plist",
            "/Users/test/Library/Application Support/com.apple.TCC/TCC.db",
        ])
        // Opening files in other apps' containers can raise the "access data from other apps" prompt.
        #expect(!probe.candidates.contains { $0.contains("/Library/Containers/") })
    }

    // MARK: Checker

    @Test func theCheckerMapsTheProbeWithoutOpeningSettings() async throws {
        let opened = Locked<[URL]>([])
        let open: @MainActor @Sendable (URL) -> Void = { opened.append($0) }

        let granted = FullDiskAccessChecker(probe: .init(candidates: [try file("Bookmarks.plist")]), openSettings: open)
        #expect(granted.id == .fullDiskAccess)
        #expect(await granted.currentState() == .granted)

        let unknown = FullDiskAccessChecker(probe: .init(candidates: [missing]), openSettings: open)
        #expect(await unknown.currentState() == .unknown("no probe file"))

        #expect(opened.value.isEmpty)
    }

    @Test(.enabled(if: FullDiskAccessCheckerTests.runsAsNormalUser, "root can open a mode-000 file"))
    func theCheckerReportsDenied() async throws {
        let checker = FullDiskAccessChecker(
            probe: .init(candidates: [try file("TCC.db", permissions: 0o000)]),
            openSettings: { _ in }
        )
        #expect(await checker.currentState() == .denied)
    }

    @Test func requestOpensTheFullDiskAccessPaneAndReportsTheCurrentState() async throws {
        let opened = Locked<[URL]>([])
        let checker = FullDiskAccessChecker(
            probe: .init(candidates: [missing]),
            openSettings: { opened.append($0) }
        )
        #expect(await checker.request() == .unknown("no probe file"))
        #expect(opened.value == [SystemSettingsLink.fullDiskAccess.url])
    }

    @Test func theDefaultProbeUsesTheRealHome() {
        #expect(FullDiskAccessChecker(openSettings: { _ in }).probe.candidates
            == FullDiskAccessProbe(home: NSHomeDirectory()).candidates)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/FullDiskAccessCheckerTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The first error is `RoomForMacTests/FullDiskAccessCheckerTests.swift:32:17: error: cannot find 'FullDiskAccessProbe' in scope`, followed by `cannot find 'FullDiskAccessChecker' in scope`.

- [ ] **Step 3: Write the probe and the checker**

`RoomForMac/Features/Permissions/FullDiskAccessChecker.swift`
```swift
import Darwin
import Foundation

/// Detects Full Disk Access by opening files that only TCC keeps closed.
///
/// macOS has no API for Full Disk Access and never prompts for it. Without the grant,
/// `open()` on one of these files fails with EPERM (or EACCES); with it, `open()` succeeds.
/// A missing file (ENOENT) is no evidence either way: the user `TCC.db` does not exist
/// on macOS 27, so it comes last.
struct FullDiskAccessProbe: Sendable {
    enum Result: Sendable, Equatable {
        case granted, denied, indeterminate
    }

    var candidates: [String]

    init(home: String = NSHomeDirectory()) {
        candidates = [
            "/Library/Application Support/com.apple.TCC/TCC.db",          // root:wheel 0644, always present
            home + "/Library/Safari/Bookmarks.plist",
            "/Library/Preferences/com.apple.TimeMachine.plist",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",   // absent on macOS 27
        ]
    }

    init(candidates: [String]) {
        self.candidates = candidates
    }

    /// Opens each candidate in order and closes it at once. It never reads a byte.
    /// The first file that opens means granted; otherwise any EPERM or EACCES means denied.
    func check() -> Result {
        var sawDenied = false
        for path in candidates {
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            let failure = errno
            if failure == EPERM || failure == EACCES {
                sawDenied = true
            }
        }
        return sawDenied ? .denied : .indeterminate
    }
}

struct FullDiskAccessChecker: PermissionChecking {
    let id: PermissionID = .fullDiskAccess
    let probe: FullDiskAccessProbe
    private let openSettings: @MainActor @Sendable (URL) -> Void

    init(probe: FullDiskAccessProbe = .init(), openSettings: @escaping @MainActor @Sendable (URL) -> Void) {
        self.probe = probe
        self.openSettings = openSettings
    }

    func currentState() async -> PermissionState {
        switch probe.check() {
        case .granted: .granted
        case .denied: .denied
        case .indeterminate: .unknown("no probe file")
        }
    }

    /// Full Disk Access has no prompt: open its pane in System Settings, then report the state as it is now.
    /// The caller polls while the user flips the switch.
    func request() async -> PermissionState {
        await openSettings(SystemSettingsLink.fullDiskAccess.url)
        return await currentState()
    }
}
```

`errno` is read into a local straight after `open()`, before `close()` or anything else can change it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/FullDiskAccessCheckerTests`
Expected: `✔ Test run with 9 tests in 1 suite passed` and `** TEST SUCCEEDED **`. Run as root, the three mode-000 tests are skipped with "root can open a mode-000 file" and the other 6 pass.

- [ ] **Step 5: Write the failing Automation tests**

`RoomForMacTests/AutomationCheckerTests.swift`
```swift
import Dispatch
import Foundation
import Testing
@testable import RoomForMac

@Suite("Automation permission for Finder and System Events")
struct AutomationCheckerTests {
    // MARK: OSStatus mapping

    @Test(arguments: [
        (Int32(0), PermissionState.granted),
        (Int32(-1743), PermissionState.denied),
        (Int32(-1744), PermissionState.notDetermined),
        (Int32(-600), PermissionState.unknown("not running")),
        (Int32(-1712), PermissionState.unknown("OSStatus -1712")),
        (Int32(-50), PermissionState.unknown("OSStatus -50")),
    ])
    func mapsEveryStatus(status: Int32, expected: PermissionState) {
        #expect(AppleEventPermission.state(forStatus: status) == expected)
    }

    // MARK: Targets

    @Test func targetsNameTheSystemApps() {
        #expect(AutomationChecker.Target.allCases == [.finder, .systemEvents])
        #expect(AutomationChecker.Target.finder.bundleIdentifier == "com.apple.finder")
        #expect(AutomationChecker.Target.systemEvents.bundleIdentifier == "com.apple.systemevents")
        #expect(AutomationChecker.Target.finder.applicationURL.path == "/System/Library/CoreServices/Finder.app")
        #expect(AutomationChecker.Target.systemEvents.applicationURL.path == "/System/Library/CoreServices/System Events.app")
        #expect(AutomationChecker.Target.finder.permissionID == .automationFinder)
        #expect(AutomationChecker.Target.systemEvents.permissionID == .automationSystemEvents)
    }

    @Test func liveCheckersUseTheSharedDeadlines() {
        let checker = AutomationChecker.live(.finder, openSettings: { _ in })
        #expect(checker.id == .automationFinder)
        #expect(checker.passiveDeadline == BlockingCall.passiveDeadline)
        #expect(checker.promptDeadline == BlockingCall.promptDeadline)
    }

    // MARK: Passive check

    @Test func thePassiveCheckNeverAsks() async {
        let fake = FakeAppleEvents(status: -1744)
        let checker = fake.checker(.systemEvents)
        #expect(checker.id == .automationSystemEvents)
        #expect(await checker.currentState() == .notDetermined)
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.systemevents", ask: false)])
        #expect(fake.launched.value.isEmpty)
        #expect(fake.opened.value.isEmpty)
    }

    @Test func aTargetThatIsNotRunningIsUnknownWithoutLaunchingIt() async {
        let fake = FakeAppleEvents(status: -600, running: false)
        #expect(await fake.checker(.systemEvents).currentState() == .unknown("not running"))
        #expect(fake.launched.value.isEmpty)
    }

    @Test func aPassiveCheckThatHangsTimesOut() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }   // lets the blocked GCD thread finish after the test
        let fake = FakeAppleEvents(status: 0, blockUntil: gate)
        let checker = fake.checker(.finder, passiveDeadline: .milliseconds(100))

        let clock = ContinuousClock()
        let start = clock.now
        let state = await checker.currentState()

        #expect(state == .unknown("timed out"))
        #expect(clock.now - start < .seconds(1))
    }

    // MARK: Request

    @Test func aRequestAsksARunningTarget() async {
        let fake = FakeAppleEvents(status: 0)
        #expect(await fake.checker(.finder).request() == .granted)
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.finder", ask: true)])
        #expect(fake.launched.value.isEmpty)
        #expect(fake.opened.value.isEmpty)
    }

    @Test func aRequestLaunchesATargetThatIsNotRunningOnce() async {
        let fake = FakeAppleEvents(status: -1744, running: false)
        #expect(await fake.checker(.systemEvents).request() == .notDetermined)
        #expect(fake.launched.value == [AutomationChecker.Target.systemEvents.applicationURL])
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.systemevents", ask: true)])
    }

    @Test func aFailedLaunchDoesNotWaitForTheTarget() async {
        let fake = FakeAppleEvents(status: -600, running: false, launchSucceeds: false)
        let clock = ContinuousClock()
        let start = clock.now
        let state = await fake.checker(.systemEvents).request()

        #expect(state == .unknown("not running"))
        #expect(fake.launched.value.count == 1)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func aDeniedRequestOpensAutomationSettings() async {
        let fake = FakeAppleEvents(status: -1743)
        #expect(await fake.checker(.finder).request() == .denied)
        #expect(fake.opened.value == [SystemSettingsLink.automation.url])
    }

    @Test func aRequestNobodyAnswersTimesOutWithoutOpeningSettings() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let fake = FakeAppleEvents(status: -1743, blockUntil: gate)
        let checker = fake.checker(.finder, promptDeadline: .milliseconds(100))

        #expect(await checker.request() == .unknown("timed out"))
        #expect(fake.determined.value == [DetermineCall(bundleIdentifier: "com.apple.finder", ask: true)])
        #expect(fake.opened.value.isEmpty)
    }
}

extension AutomationCheckerTests {
    /// One call of the injected `determine` closure.
    fileprivate struct DetermineCall: Sendable, Equatable {
        let bundleIdentifier: String
        let ask: Bool
    }

    /// Scripted Apple-event answers: records every call, and "launching" the target makes it run.
    fileprivate struct FakeAppleEvents: Sendable {
        let status: Int32
        let running: Bool
        let launchSucceeds: Bool
        let blockUntil: DispatchSemaphore?
        let determined = Locked<[DetermineCall]>([])
        let launched = Locked<[URL]>([])
        let opened = Locked<[URL]>([])

        init(status: Int32, running: Bool = true, launchSucceeds: Bool = true, blockUntil: DispatchSemaphore? = nil) {
            self.status = status
            self.running = running
            self.launchSucceeds = launchSucceeds
            self.blockUntil = blockUntil
        }

        func checker(
            _ target: AutomationChecker.Target,
            passiveDeadline: Duration = .seconds(3),
            promptDeadline: Duration = .seconds(3)
        ) -> AutomationChecker {
            AutomationChecker(
                target: target,
                determine: { [status, blockUntil, determined] bundleIdentifier, ask in
                    determined.append(DetermineCall(bundleIdentifier: bundleIdentifier, ask: ask))
                    if let blockUntil {
                        _ = blockUntil.wait(timeout: .now() + 5)
                    }
                    return status
                },
                isRunning: { [running, launchSucceeds, launched] _ in
                    running || (launchSucceeds && !launched.value.isEmpty)
                },
                launchHidden: { [launchSucceeds, launched] url in
                    launched.append(url)
                    return launchSucceeds
                },
                openSettings: { [opened] url in opened.append(url) },
                passiveDeadline: passiveDeadline,
                promptDeadline: promptDeadline
            )
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AutomationCheckerTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The errors include `RoomForMacTests/AutomationCheckerTests.swift:19:17: error: cannot find 'AppleEventPermission' in scope` and `RoomForMacTests/AutomationCheckerTests.swift:144:23: error: cannot find type 'AutomationChecker' in scope`.

- [ ] **Step 7: Write the Apple-event permission call and the Automation checker**

`RoomForMac/Features/Permissions/AppleEventPermission.swift`
```swift
import CoreServices
import Foundation

/// The Automation permission check for one target app, through `AEDeterminePermissionToAutomateTarget`.
enum AppleEventPermission {
    /// Asks macOS whether this app may send Apple events to the app with `bundleIdentifier`.
    ///
    /// This blocks until macOS answers. With `askUserIfNeeded` that means until the user answers
    /// the prompt, and it can block forever. Call it only through `BlockingCall.run`.
    static func determine(bundleIdentifier: String, askUserIfNeeded: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else {
                return Int32(paramErr)
            }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUserIfNeeded)
        }
    }

    static func state(forStatus status: Int32) -> PermissionState {
        switch status {
        case Int32(noErr):
            .granted
        case Int32(errAEEventNotPermitted):             // -1743: only System Settings can change it now
            .denied
        case Int32(errAEEventWouldRequireUserConsent):  // -1744: asking shows the prompt
            .notDetermined
        case Int32(procNotFound):                       // -600: the target app is not running
            .unknown("not running")
        default:
            .unknown("OSStatus \(status)")
        }
    }
}
```

`RoomForMac/Features/Permissions/AutomationChecker.swift`
```swift
import AppKit

/// Automation permission for Finder or System Events (spec §6, Ruling 10).
///
/// Every `determine` call runs through `BlockingCall`, on a GCD queue and never on the
/// cooperative pool, because `AEDeterminePermissionToAutomateTarget` can block forever.
struct AutomationChecker: PermissionChecking {
    enum Target: String, Sendable, CaseIterable {
        case finder, systemEvents

        var bundleIdentifier: String {
            switch self {
            case .finder: "com.apple.finder"
            case .systemEvents: "com.apple.systemevents"
            }
        }

        var applicationURL: URL {
            switch self {
            case .finder: URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)
            case .systemEvents: URL(filePath: "/System/Library/CoreServices/System Events.app", directoryHint: .isDirectory)
            }
        }

        var permissionID: PermissionID {
            switch self {
            case .finder: .automationFinder
            case .systemEvents: .automationSystemEvents
            }
        }
    }

    /// How long a request waits for a target it launched, and how often it looks.
    static let launchWait: Duration = .seconds(2)
    static let launchPollInterval: Duration = .milliseconds(100)

    let target: Target
    let passiveDeadline: Duration
    let promptDeadline: Duration
    private let determine: @Sendable (String, Bool) -> Int32
    private let isRunning: @Sendable (String) -> Bool
    private let launchHidden: @Sendable (URL) async -> Bool
    private let openSettings: @MainActor @Sendable (URL) -> Void

    var id: PermissionID { target.permissionID }

    init(
        target: Target,
        determine: @escaping @Sendable (String, Bool) -> Int32 = AppleEventPermission.determine,
        isRunning: @escaping @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
        launchHidden: @escaping @Sendable (URL) async -> Bool,
        openSettings: @escaping @MainActor @Sendable (URL) -> Void,
        passiveDeadline: Duration = BlockingCall.passiveDeadline,
        promptDeadline: Duration = BlockingCall.promptDeadline
    ) {
        self.target = target
        self.determine = determine
        self.isRunning = isRunning
        self.launchHidden = launchHidden
        self.openSettings = openSettings
        self.passiveDeadline = passiveDeadline
        self.promptDeadline = promptDeadline
    }

    static func live(_ target: Target, openSettings: @escaping @MainActor @Sendable (URL) -> Void) -> AutomationChecker {
        AutomationChecker(target: target, launchHidden: { await openHidden($0) }, openSettings: openSettings)
    }

    /// Never prompts. A target that is not running reads as `.unknown("not running")`;
    /// `PermissionCenter` then shows the last known state.
    func currentState() async -> PermissionState {
        await determineState(askUserIfNeeded: false, deadline: passiveDeadline)
    }

    /// Starts the target hidden when it is not running, because a target that is not running
    /// cannot be asked (-600). Then shows the system prompt. Once denied, macOS never prompts
    /// again, so a denial opens the Automation pane of System Settings.
    func request() async -> PermissionState {
        let bundleIdentifier = target.bundleIdentifier
        if !isRunning(bundleIdentifier), await launchHidden(target.applicationURL) {
            await waitUntilRunning(bundleIdentifier)
        }
        let state = await determineState(askUserIfNeeded: true, deadline: promptDeadline)
        if state == .denied {
            await openSettings(SystemSettingsLink.automation.url)
        }
        return state
    }

    private func determineState(askUserIfNeeded: Bool, deadline: Duration) async -> PermissionState {
        let determine = determine
        let bundleIdentifier = target.bundleIdentifier
        guard let status = await BlockingCall.run(deadline: deadline, { determine(bundleIdentifier, askUserIfNeeded) }) else {
            return .unknown("timed out")
        }
        return AppleEventPermission.state(forStatus: status)
    }

    private func waitUntilRunning(_ bundleIdentifier: String) async {
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: Self.launchWait)
        while !isRunning(bundleIdentifier), clock.now < giveUp {
            do {
                try await Task.sleep(for: Self.launchPollInterval)
            } catch {
                return
            }
        }
    }

    /// Launches an app without activating it, showing it, or adding it to Recent Items,
    /// and waits (at most `launchWait`) until it has finished launching.
    private static func openHidden(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return false
        }
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: launchWait)
        while !application.isFinishedLaunching, clock.now < giveUp {
            do {
                try await Task.sleep(for: launchPollInterval)
            } catch {
                break
            }
        }
        return true
    }
}
```

`determineState` copies `determine` and the bundle ID into locals, so the `@Sendable` work item that `BlockingCall` runs on its GCD queue captures only `Sendable` values, never `self`. `AppleEventPermission.determine` as the default argument is an unapplied static method reference, which Swift 6 accepts as `@Sendable`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AutomationCheckerTests`
Expected: `✔ Test run with 11 tests in 1 suite passed` and `** TEST SUCCEEDED **`; `mapsEveryStatus(status:expected:)` reports 6 test cases. The two timeout tests take about 0.1 s each.

- [ ] **Step 9: Write the failing notification and login item tests**

`RoomForMacTests/NotificationAndLoginCheckerTests.swift`
```swift
import Foundation
import ServiceManagement
import Testing
import UserNotifications
@testable import RoomForMac

@Suite("Notification and login item checkers")
struct NotificationAndLoginCheckerTests {
    // MARK: Notifications

    @Test(arguments: [
        (UNAuthorizationStatus.notDetermined, PermissionState.notDetermined),
        (UNAuthorizationStatus.denied, PermissionState.denied),
        (UNAuthorizationStatus.authorized, PermissionState.granted),
        (UNAuthorizationStatus.provisional, PermissionState.granted),
        (UNAuthorizationStatus(rawValue: 4)!, PermissionState.granted),   // .ephemeral, which macOS code cannot name
        (UNAuthorizationStatus(rawValue: 42)!, PermissionState.unknown("status 42")),
    ])
    func mapsEveryNotificationStatus(status: UNAuthorizationStatus, expected: PermissionState) {
        #expect(NotificationChecker.state(for: status) == expected)
    }

    @Test func aGrantedNotificationRequest() async {
        let fake = FakeNotifications(status: .notDetermined, answer: .success(true), statusAfterRequest: .authorized)
        let checker = fake.checker()
        #expect(checker.id == .notifications)
        #expect(await checker.currentState() == .notDetermined)
        #expect(fake.requests.value == 0)
        #expect(await checker.request() == .granted)
        #expect(fake.requests.value == 1)
    }

    @Test func aDeniedNotificationRequest() async {
        let fake = FakeNotifications(status: .notDetermined, answer: .success(false), statusAfterRequest: .denied)
        #expect(await fake.checker().request() == .denied)
        #expect(fake.requests.value == 1)
    }

    @Test func aNotificationRequestThatFailsIsUnknown() async {
        let failure = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue)
        let fake = FakeNotifications(status: .notDetermined, answer: .failure(failure), statusAfterRequest: .notDetermined)
        #expect(await fake.checker().request() == .unknown("request failed: \(UNError.Code.notificationsNotAllowed.rawValue)"))
    }

    // MARK: Open at login

    @Test(arguments: [
        (SMAppService.Status.enabled, PermissionState.granted),
        (SMAppService.Status.notRegistered, PermissionState.notDetermined),
        (SMAppService.Status.requiresApproval, PermissionState.requiresApproval),
        (SMAppService.Status.notFound, PermissionState.unknown("unavailable in this build")),
        (SMAppService.Status(rawValue: 42)!, PermissionState.unknown("status 42")),
    ])
    func mapsEveryLoginItemStatus(status: SMAppService.Status, expected: PermissionState) {
        #expect(LoginItemChecker.state(for: status) == expected)
    }

    @Test func aRequestRegistersTheApp() async {
        let fake = FakeLoginItem(status: .notRegistered, statusAfterRegister: .enabled)
        let checker = fake.checker()
        #expect(checker.id == .launchAtLogin)
        #expect(await checker.request() == .granted)
        #expect(fake.calls.value == ["register"])
    }

    @Test func aRequestThatNeedsApprovalOpensLoginItemsSettings() async {
        let fake = FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval)
        #expect(await fake.checker().request() == .requiresApproval)
        #expect(fake.calls.value == ["register", "openLoginItemsSettings"])
    }

    @Test func alreadyRegisteredCountsAsSuccess() async {
        let fake = FakeLoginItem(
            status: .enabled,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 12)
        )
        #expect(await fake.checker().request() == .granted)
        #expect(fake.calls.value == ["register"])
    }

    @Test func anotherRegisterErrorIsUnknown() async {
        let fake = FakeLoginItem(
            status: .notRegistered,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 3)
        )
        #expect(await fake.checker().request() == .unknown("SMAppService error 3"))
        #expect(fake.calls.value == ["register"])
    }

    @Test func disableUnregistersTheApp() async {
        let fake = FakeLoginItem(status: .enabled, statusAfterUnregister: .notRegistered)
        #expect(await fake.checker().disable() == .notDetermined)
        #expect(fake.calls.value == ["unregister"])
    }

    @Test func disableReportsTheStateItLeft() async {
        let fake = FakeLoginItem(status: .enabled, unregisterError: NSError(domain: "SMAppServiceErrorDomain", code: 5))
        #expect(await fake.checker().disable() == .granted)
        #expect(fake.calls.value == ["unregister"])
    }
}

extension NotificationAndLoginCheckerTests {
    /// Scripted notification authorization: the status switches once a request is made.
    fileprivate struct FakeNotifications: Sendable {
        let status: Locked<UNAuthorizationStatus>
        let answer: Result<Bool, NSError>
        let statusAfterRequest: UNAuthorizationStatus
        let requests = Locked(0)

        init(status: UNAuthorizationStatus, answer: Result<Bool, NSError>, statusAfterRequest: UNAuthorizationStatus) {
            self.status = Locked(status)
            self.answer = answer
            self.statusAfterRequest = statusAfterRequest
        }

        func checker() -> NotificationChecker {
            NotificationChecker(
                authorizationStatus: { [status] in status.value },
                requestAuthorization: { [status, answer, statusAfterRequest, requests] in
                    requests.mutate { $0 += 1 }
                    status.set(statusAfterRequest)
                    return try answer.get()
                }
            )
        }
    }

    /// A scripted `SMAppService`: records calls in order and changes status as the real one would.
    fileprivate struct FakeLoginItem: Sendable {
        let status: Locked<SMAppService.Status>
        let statusAfterRegister: SMAppService.Status?
        let statusAfterUnregister: SMAppService.Status?
        let registerError: NSError?
        let unregisterError: NSError?
        let calls = Locked<[String]>([])

        init(
            status: SMAppService.Status,
            statusAfterRegister: SMAppService.Status? = nil,
            statusAfterUnregister: SMAppService.Status? = nil,
            registerError: NSError? = nil,
            unregisterError: NSError? = nil
        ) {
            self.status = Locked(status)
            self.statusAfterRegister = statusAfterRegister
            self.statusAfterUnregister = statusAfterUnregister
            self.registerError = registerError
            self.unregisterError = unregisterError
        }

        func checker() -> LoginItemChecker {
            LoginItemChecker(
                status: { [status] in status.value },
                register: { [status, statusAfterRegister, registerError, calls] in
                    calls.append("register")
                    if let registerError { throw registerError }
                    if let statusAfterRegister { status.set(statusAfterRegister) }
                },
                unregister: { [status, statusAfterUnregister, unregisterError, calls] in
                    calls.append("unregister")
                    if let unregisterError { throw unregisterError }
                    if let statusAfterUnregister { status.set(statusAfterUnregister) }
                },
                openLoginItemsSettings: { [calls] in calls.append("openLoginItemsSettings") }
            )
        }
    }
}
```

- [ ] **Step 10: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/NotificationAndLoginCheckerTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The errors include `RoomForMacTests/NotificationAndLoginCheckerTests.swift:20:17: error: cannot find 'NotificationChecker' in scope` and `RoomForMacTests/NotificationAndLoginCheckerTests.swift:152:27: error: cannot find type 'LoginItemChecker' in scope`.

- [ ] **Step 11: Write the notification and login item checkers**

`RoomForMac/Features/Permissions/NotificationChecker.swift`
```swift
import Foundation
import UserNotifications

/// Notification permission. The system calls sit behind closures: `UNUserNotificationCenter.current()`
/// raises an exception in a process without a bundle, and unit tests must never prompt.
struct NotificationChecker: PermissionChecking {
    let id: PermissionID = .notifications
    private let authorizationStatus: @Sendable () async -> UNAuthorizationStatus
    private let requestAuthorization: @Sendable () async throws -> Bool

    init(
        authorizationStatus: @escaping @Sendable () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping @Sendable () async throws -> Bool
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
    }

    /// The real notification center. Never called in unit tests.
    static func live() -> NotificationChecker {
        NotificationChecker(
            authorizationStatus: {
                await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        )
    }

    /// `.ephemeral` cannot be named in an expression on macOS, but a pattern may match it.
    static func state(for status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown("status \(status.rawValue)")
        }
    }

    func currentState() async -> PermissionState {
        Self.state(for: await authorizationStatus())
    }

    /// Shows the system prompt the first time; later calls return at once with the stored answer.
    /// The status read afterwards is the answer, whatever the request returned.
    func request() async -> PermissionState {
        do {
            _ = try await requestAuthorization()
        } catch {
            let state = await currentState()
            return state == .notDetermined ? .unknown("request failed: \((error as NSError).code)") : state
        }
        return await currentState()
    }
}
```

`RoomForMac/Features/Permissions/LoginItemChecker.swift`
```swift
import Foundation
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp`. The system calls sit behind closures so unit tests
/// never register the test host. Unsigned and ad-hoc dev builds usually report `.notFound`.
struct LoginItemChecker: PermissionChecking {
    /// `kSMErrorAlreadyRegistered`: registering an app that is already registered is not a failure.
    static let alreadyRegisteredCode = Int(kSMErrorAlreadyRegistered)

    let id: PermissionID = .launchAtLogin
    private let status: @Sendable () -> SMAppService.Status
    private let register: @Sendable () throws -> Void
    private let unregister: @Sendable () throws -> Void
    private let openLoginItemsSettings: @Sendable () -> Void

    init(
        status: @escaping @Sendable () -> SMAppService.Status,
        register: @escaping @Sendable () throws -> Void,
        unregister: @escaping @Sendable () throws -> Void,
        openLoginItemsSettings: @escaping @Sendable () -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        self.openLoginItemsSettings = openLoginItemsSettings
    }

    /// The running app's own login item. Never called in unit tests.
    static func live() -> LoginItemChecker {
        LoginItemChecker(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() },
            openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    static func state(for status: SMAppService.Status) -> PermissionState {
        switch status {
        case .enabled: .granted
        case .notRegistered: .notDetermined
        case .requiresApproval: .requiresApproval
        case .notFound: .unknown("unavailable in this build")
        @unknown default: .unknown("status \(status.rawValue)")
        }
    }

    func currentState() async -> PermissionState {
        Self.state(for: status())
    }

    /// Registers the app. When macOS wants the user to approve it, opens Login Items in System Settings.
    /// A failed registration that leaves the app unregistered reads as unknown, never as "Not yet".
    func request() async -> PermissionState {
        var failure: Int?
        do {
            try register()
        } catch {
            let code = (error as NSError).code
            if code != Self.alreadyRegisteredCode {
                failure = code
            }
        }
        let state = await currentState()
        if state == .requiresApproval {
            openLoginItemsSettings()
        }
        if let failure, state == .notDetermined {
            return .unknown("SMAppService error \(failure)")
        }
        return state
    }

    /// Unregisters the app and reports the state it left behind.
    func disable() async -> PermissionState {
        do {
            try unregister()
        } catch {
            // kSMErrorJobNotFound when it was never registered. The status read below is the answer either way.
        }
        return await currentState()
    }
}
```

- [ ] **Step 12: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/NotificationAndLoginCheckerTests`
Expected: `✔ Test run with 11 tests in 1 suite passed` and `** TEST SUCCEEDED **`; `mapsEveryNotificationStatus(status:expected:)` reports 6 test cases and `mapsEveryLoginItemStatus(status:expected:)` 5.

- [ ] **Step 13: Run the whole unit scheme and check for warnings and strings**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-9.log" | tail -n 20
grep -E '(Features/Permissions/(FullDiskAccessChecker|AutomationChecker|AppleEventPermission|NotificationChecker|LoginItemChecker)|RoomForMacTests/((FullDiskAccessChecker|AutomationChecker|NotificationAndLoginChecker)Tests|Support/Locked))\.swift.*(warning|error):' "$TMPDIR/rfm-task-9.log"
OBJROOT=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null | awk '$1 == "OBJROOT" { print $3; exit }')
for name in FullDiskAccessChecker AppleEventPermission AutomationChecker NotificationChecker LoginItemChecker; do
    find "$OBJROOT" -path "*/RoomForMac.build/Objects-normal/*/$name.stringsdata" \
        -exec plutil -extract tables json -o - {} \; -exec echo " $name" \;
done | sort -u
```
Expected:
- The log contains `** TEST SUCCEEDED **` (stderr can print `Testing started` after it). The Swift Testing summary counts this task's 31 tests in 3 suites plus those of Tasks 1–8.
- The `grep` prints nothing: no warnings in this task's files.
- The loop prints exactly these five lines, so none of this task's files adds a String Catalog key:
  ```
  {} AppleEventPermission
  {} AutomationChecker
  {} FullDiskAccessChecker
  {} LoginItemChecker
  {} NotificationChecker
  ```

The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

What the unit tests cannot cover, because it needs a signed build and a person at the keyboard, stays on the owner's manual checklist (research §2, checks 3–7): `open()` of the system `TCC.db` succeeding once Full Disk Access is on, the System Events prompt after a hidden launch, the `Privacy_AllFiles` and `Privacy_Automation` deep links, and `SMAppService.mainApp` on a signed copy in `/Applications`.

- [ ] **Step 14: Commit**

```bash
git add RoomForMac/Features/Permissions/FullDiskAccessChecker.swift \
    RoomForMac/Features/Permissions/AppleEventPermission.swift \
    RoomForMac/Features/Permissions/AutomationChecker.swift \
    RoomForMac/Features/Permissions/NotificationChecker.swift \
    RoomForMac/Features/Permissions/LoginItemChecker.swift \
    RoomForMacTests/Support/Locked.swift \
    RoomForMacTests/FullDiskAccessCheckerTests.swift \
    RoomForMacTests/AutomationCheckerTests.swift \
    RoomForMacTests/NotificationAndLoginCheckerTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'EOF'
feat(app): live Full Disk Access, Automation, notification and login checkers

Full Disk Access is read by opening protected files: the system TCC.db
first, EPERM or EACCES as denied, and a missing file as no evidence, so
macOS 27 without a user TCC.db reads as unknown rather than granted.
Automation asks AEDeterminePermissionToAutomateTarget on a GCD queue
behind a deadline, launches a target that is not running hidden before
it prompts, and opens the Automation pane after a denial. Notifications
and open-at-login wrap UNUserNotificationCenter and SMAppService behind
closures, so unit tests never prompt or register the test host.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 10: App location, Move to Applications and relaunch

**Files:**
- Create: `RoomForMac/Features/Permissions/AppLocation.swift`, `AppLocationChecker.swift`, `AppMover.swift`, `Relauncher.swift`, `RoomForMacTests/AppLocationTests.swift`, `RoomForMacTests/AppMoverTests.swift`
- Create (added; fixtures shared by the two test files): `RoomForMacTests/Support/AppMoveFixtures.swift`
- Modify (added; the String Catalog grows every task): `RoomForMac/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PermissionChecking`, `PermissionID.moveToApplications`, `PermissionState` (Task 8).
- Consumes (added): `TemporaryDirectory` (Task 3 test support).
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
- Added by this task (internal to this task; Task 12 is expected to use the two marked "Task 12", and nothing else depends on them):
  ```swift
  extension AppMoveError: LocalizedError {
      var errorDescription: String? { get }            // one full sentence per case; Task 12 shows lastError?.localizedDescription
      static func displayPath(_ url: URL) -> String    // "~/Applications" rather than "/Users/<name>/Applications"
  }
  extension AppMover {
      init(fileManager: @escaping @Sendable () -> FileManager = { .default },
           isRunning: @escaping @Sendable (URL) -> Bool,
           trashItem: @escaping @Sendable (URL) throws -> Void,
           volumeIsReadOnly: @escaping @Sendable (URL) -> Bool?)   // tests inject the read-only answer; the 3-argument init uses isOnReadOnlyVolume
      static func isOnReadOnlyVolume(_ url: URL) -> Bool?           // statfs MNT_RDONLY, else URLResourceValues.volumeIsReadOnly; nil when unreadable
  }
  extension Translocation {
      static func pathLooksTranslocated(_ path: String) -> Bool     // the "/AppTranslocation/" fallback
  }
  extension AppLocationChecker {
      static func source(for location: AppLocation, bundleURL: URL) -> URL   // a translocated app's original, else bundleURL
      static let forceMoveStepArgument: String                                // "-RFMForceMoveStep"
      static func bypassesMoveStep(arguments: [String], isDebugBuild: Bool) -> Bool
      static var bypassesMoveStepInThisBuild: Bool { get }                    // Task 12. #if DEBUG: bypassesMoveStep(ProcessInfo arguments, true); else false
      static func live(bypass: Bool) -> AppLocationChecker                    // Task 12. AppLocation.current(), AppMover.live(), Relauncher.live()
  }
  // Test support, RoomForMacTests/Support/AppMoveFixtures.swift:
  enum AppBundleFixture {
      static func make(named name: String = "RoomForMac.app", in directory: URL, marker: String) throws -> URL
      static func marker(of bundle: URL) throws -> String
      static func nestedFile(of bundle: URL) -> URL
      static func setQuarantine(on url: URL) throws
      static func hasQuarantine(_ url: URL) -> Bool
      static func setPermissions(_ mode: Int, on url: URL) throws
  }
  final class MoveCallLog<Element: Sendable>: Sendable { func append(_ element: Element); var entries: [Element] { get } }
  final class ConfinedFileManager: FileManager, @unchecked Sendable { init(root: URL) }   // refuses every write outside root
  ```

**Interface issue:** the DEBUG-bypass requirement names `AppDependencies.live`, but `AppDependencies.swift` is not in this task's Files, and Task 12 is the task that adds the live checkers to it. Smallest fix: this task ships and tests the decision (`bypassesMoveStep(arguments:isDebugBuild:)`, `bypassesMoveStepInThisBuild`) and the production factory `AppLocationChecker.live(bypass:)`. Task 12's `AppDependencies.live` computes `let bypass = AppLocationChecker.bypassesMoveStepInThisBuild` once, and uses it for both `AppLocationChecker.live(bypass: bypass)` and `needsMoveStep = AppLocation.current() != .installed && !bypass`.

**Requirements:**
- `AppLocation.classify` is pure and never touches the file system:
  - `isTranslocated` → `.translocated(original: originalURL)`. This holds even when the original is already in Applications, because the Move step is what clears the quarantine flag that caused the translocation.
  - Otherwise `.installed` when the standardized bundle path has more components than one of `AppMover.candidateDirectories(home:)` and starts with all of that folder's components. Matching whole components means `/ApplicationsBackup/…` and `~/ApplicationsOld/…` are outside, `/Applications/Utilities/…` is installed, and `/Applications/../Users/…` is judged after `..` is resolved.
  - Otherwise `.outsideApplications`.
- `AppLocation.current(bundle:)` classifies `bundle.bundleURL` with `NSHomeDirectory()`, `Translocation.isTranslocated`, and `Translocation.originalURL` only when translocated.
- `Translocation`:
  - Looks both functions up in `Security.framework` on every call (`dlopen` with `RTLD_NOLOAD` first, then `dlsym`), so there is no stored global state. The C signatures are `Boolean SecTranslocateIsTranslocatedURL(CFURLRef, bool *, CFErrorRef *)` and `CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef, CFErrorRef *)`, the second returning a +1 reference.
  - `isTranslocated` falls back to `pathLooksTranslocated` when the symbol is missing **or the call fails**. Measured on this Mac (macOS 27.0): the call returns false with `ENOENT` for a path that does not exist. For an existing, normal path it succeeds and reports false, and `originalURL` returns the same path.
- `move(appAt:toFirstWritableOf:)` (Review Focus 4), for each directory in order:
  1. A missing directory is created with `withIntermediateDirectories: false`, so `~/Applications` is created but no deeper path is invented. The directory is skipped when creation fails, when the path exists but is not a directory, or when `isWritableFile(atPath:)` is false.
  2. The destination is `directory/<source name>`. If it is the source itself (standardized, with symlinks resolved), this is a translocated app whose original already sits there: `stripQuarantine` (its error propagates) and return it. Nothing is trashed.
  3. If the destination exists (`attributesOfItem`, so a dangling symlink counts) and `isRunning(destination)` → throw `destinationIsRunning` at once, without trying the next folder. If it exists and is not running → `trashItem(destination)`; a failure there → `.failed(localizedDescription)`.
  4. Copy when the source cannot be removed; otherwise move. The source cannot be removed when its volume is read-only, when that answer is unknown, or when its folder is not writable (a standard user's copy in a folder they cannot change). Read-only means `statfs` has `MNT_RDONLY`, or else `URLResourceValues.volumeIsReadOnly`. Measured on this Mac: `volumeIsReadOnly` is **false** on the sealed, read-only system volume while `statfs` reports `MNT_RDONLY`; a mounted UDZO disk image reports both. A copy or move failure → `.failed(localizedDescription)`.
  5. `stripQuarantine(new)` best effort (the app is already in place), then return the new URL.
  6. If every directory is skipped → `notWritable(last directory)`.
- `stripQuarantine(at:)` calls `removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)` on the bundle and on everything its enumerator yields. `ENOATTR` and `ENOTSUP` count as success; any other error throws `.failed` with a localized sentence.
- `AppMover.live()`:
  - `isRunning` compares the standardized, symlink-resolved path with the `bundleURL` of every `NSWorkspace.shared.runningApplications` entry.
  - `trashItem` is `FileManager.default.trashItem(at:resultingItemURL: nil)`.
- `AppMoveError` conforms to `LocalizedError`; every `errorDescription` is one sentence, built with `String(localized:)`:
  - `destinationIsRunning(url)`: "Another copy of RoomForMac is already open in \<folder\>. Quit it, then try again."
  - `notWritable(url)`: "RoomForMac isn't allowed to add apps to \<folder\>."
  - `failed(sentence)`: the sentence itself, usually a system error's `localizedDescription`.

  Folders are shown with `~` for the home folder. Task 12 shows `lastError?.localizedDescription`, then its own "Drag RoomForMac into your Applications folder, then open it from there."
- `Relauncher`:
  - `command` is exactly the tuple in Interfaces.
  - `relaunch(at:)` spawns the command with this process's pid, then calls `terminate`. A throwing `spawn` propagates and `terminate` is not called.
  - `live()` spawns with `Process`, with stdin, stdout and stderr on `FileHandle.nullDevice`, because the shell outlives the app. It terminates with `NSApp.terminate(nil)`. Verified in scratch: a `Process` child survives its parent's `exit()` and runs its follow-up command. The script waits for the pid, then opens a path that contains spaces intact. `sh -n` and `shellcheck -s sh` are clean on the script body.
- `AppLocationChecker`:
  - `id` is `.moveToApplications`. `currentState()` is as in Interfaces and never moves anything.
  - `request()`:
    - `bypass` → `.notApplicable`.
    - `.installed` → `.granted`, and `lastError` is cleared.
    - Otherwise the source is `source(for:bundleURL:)`: a translocated app's original URL, since the translocated path is a read-only mount; otherwise `bundleURL()`.
    - `mover.move(appAt:toFirstWritableOf: AppMover.candidateDirectories(home: home))` runs on a GCD queue, never on the cooperative pool, because copying from a disk image can take seconds. It has no deadline: a move must never be abandoned halfway.
    - A thrown `AppMoveError` is kept in `lastError`, and any other error as `.failed(localizedDescription)`. Either way the result is `.denied`.
    - On success, `lastError` is cleared, then `relauncher.relaunch(at: newURL)` runs. A throwing relaunch → `.denied` with `.failed("RoomForMac is now in <folder>, but it couldn't reopen itself. Quit it, then open it from there.")`.
    - Otherwise `.granted`. Only tests reach that line; in production the relaunch quits the app.
  - `lastError` lives in a private `final class` that holds a `Mutex<AppMoveError?>` (Synchronization, macOS 15+), so every copy of the struct shares it. Task 12 can find the checker in `AppDependencies.permissionCheckers` by casting, and that copy reports the same error.
- DEBUG bypass: `AppDependencies.live` passes `bypass: true` unless the launch arguments contain `-RFMForceMoveStep YES`. In release, `bypass` is false.
  - `bypassesMoveStep(arguments:isDebugBuild:)` is false in release. In DEBUG it is true unless the argument after `-RFMForceMoveStep` is `YES`, `true` or `1`, compared case-insensitively.
  - Task 12 does the wiring (see **Interface issue**).
- Safety of the tests:
  - No test calls `AppMover.live()`, `Relauncher.live()`, `AppLocationChecker.live(bypass:)`, `NSWorkspace`, `Process` or `NSApp`.
  - Every file operation stays inside a `TemporaryDirectory`, which each suite keeps in a stored property so it outlives every use inside a test (Task 3's rule).
  - The checker always tries `/Applications` first, and an admin user can write there. So the checker tests inject `ConfinedFileManager`, which reads every path outside its root as not writable, and throws for any create, move or copy there.
  - The three tests that `chmod` folders are skipped when running as root.
- Tests:
  - `classify` for:
    - `/Applications/RoomForMac.app`, `~/Applications/RoomForMac.app` and `/Applications/Utilities/RoomForMac.app` → installed;
    - `~/Downloads/RoomForMac.app`, `/Volumes/RoomForMac/RoomForMac.app`, a DerivedData path, another user's `Applications`, `~/ApplicationsOld/…` and `/Applications/../Users/test/Downloads/…` → outside;
    - `/ApplicationsBackup/RoomForMac.app` → outside (a prefix match must respect path components);
    - translocated → `.translocated(original:)`, with an original, with nil, and with an original in `/Applications`.
  - `Translocation.isTranslocated` is false for a temp path, and `pathLooksTranslocated` recognises the `AppTranslocation` shape. The hosted test app classifies as `.outsideApplications`.
  - `AppMover` in temp directories, with a fake `isRunning` and a fake `trashItem` that moves the item into a temp "Trash" folder:
    - a plain move through the 3-argument initializer, with the real read-only check;
    - an existing destination that is not running is trashed, then replaced;
    - an existing running destination → `destinationIsRunning`, with nothing trashed and the second folder untouched;
    - the first directory unwritable (`chmod 555`) → falls through to the second;
    - all unwritable (one `chmod 555`, one missing under a `chmod 555` parent) → `notWritable(second)`;
    - a missing `Applications` folder is created;
    - a read-only or unknown volume, and a read-only source folder, copy and keep the source;
    - the quarantine xattr, set with `setxattr` on the source bundle and a nested file, is gone after a move and after a copy, and a copy leaves the source's flag alone;
    - an app already in place is left there, with its quarantine cleared;
    - `candidateDirectories`, `isOnReadOnlyVolume` (the system volume → true, temp → false, missing → nil), `stripQuarantine` on a clean bundle and on a missing path, and the three error sentences.
  - `Relauncher.command` is exactly the tuple above. `relaunch` calls `spawn` with this pid's command, then `terminate`; a failing `spawn` does not terminate.
  - `AppLocationChecker`:
    - states for bypass, installed, outside and translocated;
    - `request` when bypassed or installed does nothing;
    - `request` success moves into `<home>/Applications` (`/Applications` refused by `ConfinedFileManager`) and calls `relaunch` with the new path;
    - a translocated app moves its original;
    - failure keeps `lastError`, which copies share, and returns `.denied`;
    - a failed relaunch returns `.denied` without quitting;
    - a later success clears `lastError`;
    - the bypass decision for every argument form (`YES`, `yes`, `TRUE`, `true`, `1`, `NO`, and the flag with no value) and both build types.
- The String Catalog gains this task's 4 keys (Step 13).

This task has no UI. Task 12 shows the Move step, and Task 14 shows the Permissions card. What the unit tests cannot reach is the owner's manual check (research §2, item 10): download a DMG through Safari, open the app from it, and confirm that translocation is detected, "Move and relaunch" works, and the relaunched copy is no longer translocated.

- [ ] **Step 1: Write the test fixtures**

`RoomForMacTests/Support/AppMoveFixtures.swift`
```swift
import Darwin
import Foundation
import Synchronization

/// A minimal app bundle on disk, for move tests.
enum AppBundleFixture {
    /// Writes `<directory>/<name>/Contents/MacOS/RoomForMac` and `Contents/Resources/marker.txt`
    /// holding `marker`, and returns the bundle URL.
    @discardableResult
    static func make(named name: String = "RoomForMac.app", in directory: URL, marker: String) throws -> URL {
        let bundle = directory.appending(path: name)
        let macOS = bundle.appending(path: "Contents/MacOS")
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: macOS.appending(path: "RoomForMac"))
        try Data(marker.utf8).write(to: resources.appending(path: "marker.txt"))
        return bundle
    }

    static func marker(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// The nested file that quarantine tests check besides the bundle folder itself.
    static func nestedFile(of bundle: URL) -> URL {
        bundle.appending(path: "Contents/Resources/marker.txt")
    }

    static func setQuarantine(on url: URL) throws {
        let value = Array("0083;66f5a0b1;Safari;".utf8)
        guard setxattr(url.path, "com.apple.quarantine", value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func setPermissions(_ mode: Int, on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

/// A thread-safe record of the calls a fake received.
final class MoveCallLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var entries: [Element] {
        storage.withLock { $0 }
    }
}

/// A file manager that refuses to write outside `root`, so a checker test can never touch the real
/// /Applications: that folder reads as not writable, and creating, moving or copying into it throws.
final class ConfinedFileManager: FileManager, @unchecked Sendable {
    private let root: String

    init(root: URL) {
        self.root = root.standardizedFileURL.path
        super.init()
    }

    private func isInside(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == root || standardized.hasPrefix(root + "/")
    }

    private func refuse(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }

    override func isWritableFile(atPath path: String) -> Bool {
        isInside(path) && super.isWritableFile(atPath: path)
    }

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard isInside(url.path) else {
            throw refuse(url)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard isInside(dstURL.path) else {
            throw refuse(dstURL)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard isInside(dstURL.path) else {
            throw refuse(dstURL)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
```

`ConfinedFileManager` compares standardized paths without resolving symlinks. Every path in these tests is built from the same `TemporaryDirectory.url`, so `/var` against `/private/var` never comes up, and a real `/Applications` is always outside the root.

- [ ] **Step 2: Write the failing mover and relauncher tests**

`RoomForMacTests/AppMoverTests.swift`
```swift
import Foundation
import Testing
@testable import RoomForMac

@Suite("App mover and relauncher")
struct AppMoverTests {
    let temp: TemporaryDirectory
    let downloads: URL
    let first: URL
    let second: URL
    let trash: URL

    init() throws {
        temp = try TemporaryDirectory()
        downloads = temp.url.appending(path: "Downloads")
        first = temp.url.appending(path: "Applications")
        second = temp.url.appending(path: "home/Applications")
        trash = temp.url.appending(path: "Trash")
        for directory in [downloads, first, second, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// A mover whose Trash is a folder in the temporary directory. It records every trash and
    /// every running check; `running` holds the paths that count as open apps.
    func mover(
        running: Set<String> = [],
        readOnlySource: Bool? = false,
        trashed: MoveCallLog<URL> = MoveCallLog(),
        asked: MoveCallLog<URL> = MoveCallLog()
    ) -> AppMover {
        let trash = self.trash
        return AppMover(
            isRunning: { url in
                asked.append(url)
                return running.contains(url.path)
            },
            trashItem: { url in
                trashed.append(url)
                try FileManager.default.moveItem(
                    at: url, to: trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                )
            },
            volumeIsReadOnly: { _ in readOnlySource }
        )
    }

    // MARK: - Moving

    @Test func movesIntoTheFirstFolder() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()
        // The public initializer, so the real read-only check runs: the temporary folder is writable.
        let mover = AppMover(
            isRunning: { url in
                asked.append(url)
                return false
            },
            trashItem: { url in trashed.append(url) }
        )

        let moved = try mover.move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == first.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(trashed.entries.isEmpty)
        #expect(asked.entries.isEmpty)
    }

    @Test func replacesAnOlderCopyThatIsNotRunning() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let existing = try AppBundleFixture.make(in: first, marker: "old")
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()

        let moved = try mover(trashed: trashed, asked: asked).move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == existing)
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(asked.entries == [existing])
        #expect(trashed.entries == [existing])
        let inTrash = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        #expect(inTrash.count == 1)
        #expect(try AppBundleFixture.marker(of: #require(inTrash.first)) == "old")
    }

    @Test func refusesToReplaceARunningCopy() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        let existing = try AppBundleFixture.make(in: first, marker: "old")
        let trashed = MoveCallLog<URL>()

        #expect(throws: AppMoveError.destinationIsRunning(existing)) {
            try mover(running: [existing.path], trashed: trashed).move(appAt: source, toFirstWritableOf: [first, second])
        }
        #expect(try AppBundleFixture.marker(of: existing) == "old")
        #expect(try AppBundleFixture.marker(of: source) == "new")
        #expect(trashed.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.appending(path: "RoomForMac.app").path))
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func skipsAFolderItCannotWriteTo() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setPermissions(0o555, on: first)
        defer { try? AppBundleFixture.setPermissions(0o755, on: first) }

        let moved = try mover().move(appAt: source, toFirstWritableOf: [first, second])

        #expect(moved == second.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
        #expect(!FileManager.default.fileExists(atPath: first.appending(path: "RoomForMac.app").path))
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func reportsTheLastFolderWhenNoneCanTakeTheApp() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        // The first folder is read-only; the second is missing and its parent is read-only, so it cannot be created.
        let home = second.deletingLastPathComponent()
        try FileManager.default.removeItem(at: second)
        try AppBundleFixture.setPermissions(0o555, on: first)
        try AppBundleFixture.setPermissions(0o555, on: home)
        defer {
            try? AppBundleFixture.setPermissions(0o755, on: first)
            try? AppBundleFixture.setPermissions(0o755, on: home)
        }

        #expect(throws: AppMoveError.notWritable(second)) {
            try mover().move(appAt: source, toFirstWritableOf: [first, second])
        }
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test func createsAMissingApplicationsFolder() throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try FileManager.default.removeItem(at: second)

        let moved = try mover().move(appAt: source, toFirstWritableOf: [second])

        #expect(moved == second.appending(path: "RoomForMac.app"))
        #expect(try AppBundleFixture.marker(of: moved) == "new")
    }

    @Test(arguments: [true, nil] as [Bool?])
    func copiesFromAReadOnlyOrUnknownVolume(readOnly: Bool?) throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")

        let copied = try mover(readOnlySource: readOnly).move(appAt: source, toFirstWritableOf: [first])

        #expect(try AppBundleFixture.marker(of: copied) == "new")
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test(.enabled(if: getuid() != 0, "root can write to any folder"))
    func copiesWhenTheSourceFolderIsReadOnly() throws {
        // A standard user running a copy that sits in a folder they cannot change.
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setPermissions(0o555, on: downloads)
        defer { try? AppBundleFixture.setPermissions(0o755, on: downloads) }

        let copied = try mover(readOnlySource: false).move(appAt: source, toFirstWritableOf: [first])

        #expect(try AppBundleFixture.marker(of: copied) == "new")
        #expect(try AppBundleFixture.marker(of: source) == "new")
    }

    @Test(arguments: [false, true])
    func stripsQuarantineFromTheResult(fromReadOnlyVolume: Bool) throws {
        let source = try AppBundleFixture.make(in: downloads, marker: "new")
        try AppBundleFixture.setQuarantine(on: source)
        try AppBundleFixture.setQuarantine(on: AppBundleFixture.nestedFile(of: source))

        let moved = try mover(readOnlySource: fromReadOnlyVolume).move(appAt: source, toFirstWritableOf: [first])

        #expect(!AppBundleFixture.hasQuarantine(moved))
        #expect(!AppBundleFixture.hasQuarantine(AppBundleFixture.nestedFile(of: moved)))
        if fromReadOnlyVolume {
            // The copy's source is never modified.
            #expect(AppBundleFixture.hasQuarantine(source))
        }
    }

    @Test func leavesAnAppThatIsAlreadyInPlaceAndClearsItsQuarantine() throws {
        // A translocated app whose original is already in the folder.
        let inPlace = try AppBundleFixture.make(in: first, marker: "same")
        try AppBundleFixture.setQuarantine(on: inPlace)
        let trashed = MoveCallLog<URL>()
        let asked = MoveCallLog<URL>()

        let result = try mover(trashed: trashed, asked: asked).move(appAt: inPlace, toFirstWritableOf: [first, second])

        #expect(result == inPlace)
        #expect(try AppBundleFixture.marker(of: inPlace) == "same")
        #expect(!AppBundleFixture.hasQuarantine(inPlace))
        #expect(trashed.entries.isEmpty)
        #expect(asked.entries.isEmpty)
    }

    // MARK: - Helpers

    @Test func candidatesAreSystemThenUserApplications() {
        #expect(AppMover.candidateDirectories(home: "/Users/test").map(\.path) == ["/Applications", "/Users/test/Applications"])
    }

    @Test func detectsReadOnlyVolumes() {
        // The sealed system volume is mounted read-only, although URLResourceValues says otherwise.
        #expect(AppMover.isOnReadOnlyVolume(URL(fileURLWithPath: "/System/Library/CoreServices")) == true)
        #expect(AppMover.isOnReadOnlyVolume(temp.url) == false)
        #expect(AppMover.isOnReadOnlyVolume(temp.url.appending(path: "missing")) == nil)
    }

    @Test func strippingQuarantineFailsOnlyForRealErrors() throws {
        let clean = try AppBundleFixture.make(in: downloads, marker: "clean")
        try AppMover.stripQuarantine(at: clean)
        #expect(throws: AppMoveError.self) {
            try AppMover.stripQuarantine(at: downloads.appending(path: "Missing.app"))
        }
    }

    @Test func errorsReadAsSentences() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #expect(
            AppMoveError.destinationIsRunning(URL(fileURLWithPath: "/Applications/RoomForMac.app")).errorDescription
                == "Another copy of RoomForMac is already open in /Applications. Quit it, then try again."
        )
        #expect(
            AppMoveError.notWritable(home.appending(path: "Applications")).errorDescription
                == "RoomForMac isn't allowed to add apps to ~/Applications."
        )
        #expect(AppMoveError.failed("The disk is full.").errorDescription == "The disk is full.")
    }

    // MARK: - Relaunch

    @Test func relaunchCommandWaitsForThisProcessThenOpensTheApp() {
        let command = Relauncher.command(waitingFor: 4242, thenOpen: URL(fileURLWithPath: "/Applications/RoomForMac.app"))
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments == [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
            "sh",
            "4242",
            "/Applications/RoomForMac.app",
        ])
    }

    @Test @MainActor func relaunchSpawnsThenQuits() throws {
        let events = MoveCallLog<String>()
        let spawned = MoveCallLog<[String]>()
        let relauncher = Relauncher(
            spawn: { executable, arguments in
                events.append("spawn \(executable)")
                spawned.append(arguments)
            },
            terminate: { events.append("terminate") }
        )
        let app = URL(fileURLWithPath: "/Applications/RoomForMac.app")

        try relauncher.relaunch(at: app)

        #expect(events.entries == ["spawn /bin/sh", "terminate"])
        let expected = Relauncher.command(waitingFor: ProcessInfo.processInfo.processIdentifier, thenOpen: app)
        #expect(spawned.entries == [expected.arguments])
    }

    @Test @MainActor func aFailedSpawnDoesNotQuit() {
        let events = MoveCallLog<String>()
        let relauncher = Relauncher(
            spawn: { _, _ in
                events.append("spawn")
                throw CocoaError(.executableNotLoadable)
            },
            terminate: { events.append("terminate") }
        )

        #expect(throws: CocoaError.self) {
            try relauncher.relaunch(at: URL(fileURLWithPath: "/Applications/RoomForMac.app"))
        }
        #expect(events.entries == ["spawn"])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppMoverTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The first error is `RoomForMacTests/AppMoverTests.swift:31:10: error: cannot find type 'AppMover' in scope`. The compiler may stop there, before it reports `:33:16: error: cannot find 'AppMover' in scope`.

- [ ] **Step 4: Write the mover**

`RoomForMac/Features/Permissions/AppMover.swift`
```swift
import AppKit
import Darwin
import Foundation

enum AppMoveError: Error, Sendable, Equatable {
    /// An older copy at the destination is open, so it is never replaced.
    case destinationIsRunning(URL)
    /// No candidate folder could take the app; carries the last one tried.
    case notWritable(URL)
    /// A complete, user-readable sentence, usually a system error's `localizedDescription`.
    case failed(String)
}

extension AppMoveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .destinationIsRunning(let destination):
            let folder = Self.displayPath(destination.deletingLastPathComponent())
            return String(localized: "Another copy of RoomForMac is already open in \(folder). Quit it, then try again.")
        case .notWritable(let directory):
            let folder = Self.displayPath(directory)
            return String(localized: "RoomForMac isn't allowed to add apps to \(folder).")
        case .failed(let sentence):
            return sentence
        }
    }

    /// `~/Applications` rather than `/Users/<name>/Applications`.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Moves (or, from a read-only volume, copies) the app into an Applications folder.
/// Every system call that changes something outside the file manager is injected.
struct AppMover: Sendable {
    private let fileManager: @Sendable () -> FileManager
    private let isRunning: @Sendable (URL) -> Bool
    private let trashItem: @Sendable (URL) throws -> Void
    private let volumeIsReadOnly: @Sendable (URL) -> Bool?

    init(
        fileManager: @escaping @Sendable () -> FileManager = { .default },
        isRunning: @escaping @Sendable (URL) -> Bool,
        trashItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.init(
            fileManager: fileManager,
            isRunning: isRunning,
            trashItem: trashItem,
            volumeIsReadOnly: { AppMover.isOnReadOnlyVolume($0) }
        )
    }

    /// Tests inject the read-only answer: no read-only volume exists that they could write a bundle to.
    init(
        fileManager: @escaping @Sendable () -> FileManager = { .default },
        isRunning: @escaping @Sendable (URL) -> Bool,
        trashItem: @escaping @Sendable (URL) throws -> Void,
        volumeIsReadOnly: @escaping @Sendable (URL) -> Bool?
    ) {
        self.fileManager = fileManager
        self.isRunning = isRunning
        self.trashItem = trashItem
        self.volumeIsReadOnly = volumeIsReadOnly
    }

    static func live() -> AppMover {
        AppMover(
            isRunning: { bundleURL in
                NSWorkspace.shared.runningApplications.contains { app in
                    app.bundleURL.map { samePath($0, bundleURL) } ?? false
                }
            },
            trashItem: { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        )
    }

    static func candidateDirectories(home: String) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: home, isDirectory: true).appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Tries each folder in order and returns the new bundle URL.
    /// - A folder that is missing is created (one level, like `~/Applications`); one that cannot be
    ///   created or written is skipped.
    /// - An existing copy at the destination is refused when it is open, and trashed otherwise.
    /// - The source is moved, or copied when it cannot be removed.
    /// - Quarantine is stripped from the result, best effort: the app is already in place by then.
    func move(appAt source: URL, toFirstWritableOf directories: [URL]) throws -> URL {
        let files = fileManager()
        for directory in directories {
            guard Self.prepare(directory, fileManager: files) else {
                continue
            }
            let destination = directory.appending(path: source.lastPathComponent)
            if Self.samePath(destination, source) {
                // A translocated app whose original already sits in this folder:
                // clearing quarantine is all that is left to do.
                try Self.stripQuarantine(at: destination)
                return destination
            }
            if (try? files.attributesOfItem(atPath: destination.path)) != nil {
                if isRunning(destination) {
                    throw AppMoveError.destinationIsRunning(destination)
                }
                do {
                    try trashItem(destination)
                } catch {
                    throw AppMoveError.failed(error.localizedDescription)
                }
            }
            // Copy when the original cannot be removed: a disk image, a translocation mount, a folder
            // this user cannot write. An unknown answer counts as read-only, so nothing is lost.
            let keepSource = (volumeIsReadOnly(source) ?? true)
                || !files.isWritableFile(atPath: source.deletingLastPathComponent().path)
            do {
                if keepSource {
                    try files.copyItem(at: source, to: destination)
                } else {
                    try files.moveItem(at: source, to: destination)
                }
            } catch {
                throw AppMoveError.failed(error.localizedDescription)
            }
            try? Self.stripQuarantine(at: destination)
            return destination
        }
        throw AppMoveError.notWritable(directories.last ?? URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    /// Removes `com.apple.quarantine` from the bundle and everything inside it, without following symlinks.
    static func stripQuarantine(at url: URL) throws {
        try removeQuarantine(atPath: url.path)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return
        }
        for case let item as URL in items {
            try removeQuarantine(atPath: item.path)
        }
    }

    /// `statfs` also catches the sealed system volume and translocation mounts, which
    /// `URLResourceValues.volumeIsReadOnly` reports as writable. nil when the path cannot be read.
    static func isOnReadOnlyVolume(_ url: URL) -> Bool? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else {
            return nil
        }
        if info.f_flags & UInt32(MNT_RDONLY) != 0 {
            return true
        }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    private static func prepare(_ directory: URL, fileManager files: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return false
            }
        } else {
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                return false
            }
        }
        return files.isWritableFile(atPath: directory.path)
    }

    private static func removeQuarantine(atPath path: String) throws {
        guard removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 else {
            return
        }
        let code = errno
        guard code != ENOATTR, code != ENOTSUP else {
            return
        }
        let shownPath = (path as NSString).abbreviatingWithTildeInPath
        throw AppMoveError.failed(String(localized: "RoomForMac couldn't clear the quarantine flag on \(shownPath)."))
    }
}
```

`move` is synchronous and blocking; `AppLocationChecker` calls it from a GCD queue (Step 10). There are two initializers so the skeleton's three-argument signature stays exact for its callers. The four-argument one exists only so tests can decide whether the source counts as read-only: no read-only volume exists that a test could write a bundle to.

- [ ] **Step 5: Write the relauncher**

`RoomForMac/Features/Permissions/Relauncher.swift`
```swift
import AppKit
import Foundation

/// Quits this copy and opens `appURL` once this process has exited (the LetsMove pattern).
/// Two copies never run at once, and `open` launches the new copy through LaunchServices,
/// so it is its own responsible process for TCC.
struct Relauncher: Sendable {
    private let spawn: @Sendable (String, [String]) throws -> Void
    private let terminate: @MainActor @Sendable () -> Void

    static func command(waitingFor pid: Int32, thenOpen appURL: URL) -> (executable: String, arguments: [String]) {
        (
            "/bin/sh",
            [
                "-c",
                "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
                "sh",
                "\(pid)",
                appURL.path,
            ]
        )
    }

    init(
        spawn: @escaping @Sendable (String, [String]) throws -> Void,
        terminate: @escaping @MainActor @Sendable () -> Void
    ) {
        self.spawn = spawn
        self.terminate = terminate
    }

    static func live() -> Relauncher {
        Relauncher(
            spawn: { executable, arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                // The shell outlives this app; it must not write to a terminal or pipe that closes with it.
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            },
            terminate: {
                NSApp.terminate(nil)
            }
        )
    }

    /// Spawns the waiting shell, then quits. Does not quit when the spawn fails.
    @MainActor func relaunch(at appURL: URL) throws {
        let command = Self.command(waitingFor: ProcessInfo.processInfo.processIdentifier, thenOpen: appURL)
        try spawn(command.executable, command.arguments)
        terminate()
    }
}
```

`/usr/bin/open` goes through LaunchServices, so the new copy is its own responsible process. `NSWorkspace.openApplication` would instead just activate this still-running copy (research §1.5).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppMoverTests`
Expected: `✔ Test run with 17 tests in 1 suite passed` and `** TEST SUCCEEDED **`. Run as root, the three `chmod` tests are skipped.

- [ ] **Step 7: Write the failing location and checker tests**

`RoomForMacTests/AppLocationTests.swift`
```swift
import Foundation
import Synchronization
import Testing
@testable import RoomForMac

@Suite("App location and the Move step")
struct AppLocationTests {
    /// Held by the suite so the folder outlives every use inside a test (Task 3's rule).
    let temp: TemporaryDirectory

    init() throws {
        temp = try TemporaryDirectory()
    }

    // MARK: - Classification

    @Test(arguments: [
        ("/Applications/RoomForMac.app", AppLocation.installed),
        ("/Users/test/Applications/RoomForMac.app", .installed),
        ("/Applications/Utilities/RoomForMac.app", .installed),
        ("/Users/test/Downloads/RoomForMac.app", .outsideApplications),
        ("/Volumes/RoomForMac/RoomForMac.app", .outsideApplications),
        ("/ApplicationsBackup/RoomForMac.app", .outsideApplications),
        ("/Users/test/ApplicationsOld/RoomForMac.app", .outsideApplications),
        ("/Users/other/Applications/RoomForMac.app", .outsideApplications),
        ("/Applications/../Users/test/Downloads/RoomForMac.app", .outsideApplications),
        ("/Users/test/Library/Developer/Xcode/DerivedData/RoomForMac/Build/Products/Debug/RoomForMac.app", .outsideApplications),
    ])
    func classifiesByWholePathComponents(path: String, expected: AppLocation) {
        let location = AppLocation.classify(
            bundleURL: URL(fileURLWithPath: path), home: "/Users/test", isTranslocated: false, originalURL: nil
        )
        #expect(location == expected)
    }

    @Test func translocationWinsAndKeepsTheOriginal() {
        let running = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        let downloaded = URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app")
        let installed = URL(fileURLWithPath: "/Applications/RoomForMac.app")

        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: downloaded)
                == .translocated(original: downloaded)
        )
        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: nil)
                == .translocated(original: nil)
        )
        // Still translocated with the original in Applications: the Move step clears its quarantine.
        #expect(
            AppLocation.classify(bundleURL: running, home: "/Users/test", isTranslocated: true, originalURL: installed)
                == .translocated(original: installed)
        )
    }

    @Test func aTemporaryFolderIsNotTranslocated() {
        #expect(!Translocation.isTranslocated(temp.url))
    }

    @Test func theFallbackRecognisesTranslocatedPaths() {
        #expect(Translocation.pathLooksTranslocated("/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app"))
        #expect(!Translocation.pathLooksTranslocated("/Applications/RoomForMac.app"))
    }

    @Test func theTestHostRunsFromOutsideApplications() {
        // Tests run the app from DerivedData, which is never an Applications folder.
        #expect(AppLocation.current() == .outsideApplications)
    }

    @Test func aTranslocatedAppMovesItsOriginal() {
        let original = URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app")
        let running = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        #expect(AppLocationChecker.source(for: .translocated(original: original), bundleURL: running) == original)
        #expect(AppLocationChecker.source(for: .translocated(original: nil), bundleURL: running) == running)
        #expect(AppLocationChecker.source(for: .outsideApplications, bundleURL: running) == running)
    }

    // MARK: - Checker states

    /// A checker whose mover and relauncher record an issue if they are ever used.
    func stateOnlyChecker(_ location: AppLocation, bypass: Bool) -> AppLocationChecker {
        AppLocationChecker(
            location: { location },
            bypass: bypass,
            mover: AppMover(
                isRunning: { _ in
                    Issue.record("a state check must not look for running apps")
                    return false
                },
                trashItem: { _ in Issue.record("a state check must not trash anything") }
            ),
            relauncher: Relauncher(
                spawn: { _, _ in Issue.record("a state check must not relaunch") },
                terminate: { Issue.record("a state check must not quit") }
            ),
            home: "/Users/test",
            bundleURL: { URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app") }
        )
    }

    @Test func stateFollowsTheLocation() async {
        #expect(stateOnlyChecker(.installed, bypass: false).id == .moveToApplications)
        #expect(await stateOnlyChecker(.outsideApplications, bypass: true).currentState() == .notApplicable)
        #expect(await stateOnlyChecker(.installed, bypass: false).currentState() == .granted)
        #expect(await stateOnlyChecker(.outsideApplications, bypass: false).currentState() == .notDetermined)
        #expect(await stateOnlyChecker(.translocated(original: nil), bypass: false).currentState() == .notDetermined)
    }

    @Test func requestDoesNothingWhenBypassedOrInstalled() async {
        let bypassed = stateOnlyChecker(.outsideApplications, bypass: true)
        #expect(await bypassed.request() == .notApplicable)
        let installed = stateOnlyChecker(.installed, bypass: false)
        #expect(await installed.request() == .granted)
        #expect(installed.lastError == nil)
    }

    @Test func debugBuildsSkipTheMoveStepUnlessForced() {
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac"], isDebugBuild: true))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "YES"], isDebugBuild: true))
        for value in ["yes", "true", "1", "TRUE"] {
            #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", value], isDebugBuild: true))
        }
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "NO"], isDebugBuild: true))
        #expect(AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep"], isDebugBuild: true))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac"], isDebugBuild: false))
        #expect(!AppLocationChecker.bypassesMoveStep(arguments: ["RoomForMac", "-RFMForceMoveStep", "NO"], isDebugBuild: false))
    }

    // MARK: - Checker requests (never touch the real /Applications)

    /// A move set up inside `root`, the suite's temporary folder, which outlives the test.
    struct MoveScene {
        let home: URL
        let source: URL
        let files: ConfinedFileManager
        let events = MoveCallLog<String>()
        let spawned = MoveCallLog<[String]>()

        init(in root: URL) throws {
            home = root.appending(path: "home")
            let downloads = root.appending(path: "Downloads")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            source = try AppBundleFixture.make(in: downloads, marker: "new")
            files = ConfinedFileManager(root: root)
        }

        var destination: URL {
            home.appending(path: "Applications/RoomForMac.app")
        }

        func checker(
            location: AppLocation = .outsideApplications,
            running: @escaping @Sendable () -> Bool = { false },
            spawnFails: Bool = false,
            bundleURL: URL? = nil
        ) -> AppLocationChecker {
            let files = self.files
            let events = self.events
            let spawned = self.spawned
            let bundle = bundleURL ?? source
            return AppLocationChecker(
                location: { location },
                bypass: false,
                mover: AppMover(
                    fileManager: { files },
                    isRunning: { _ in running() },
                    trashItem: { url in
                        events.append("trash \(url.lastPathComponent)")
                        try FileManager.default.removeItem(at: url)
                    }
                ),
                relauncher: Relauncher(
                    spawn: { _, arguments in
                        events.append("spawn")
                        spawned.append(arguments)
                        if spawnFails {
                            throw CocoaError(.executableNotLoadable)
                        }
                    },
                    terminate: { events.append("terminate") }
                ),
                home: home.path,
                bundleURL: { bundle }
            )
        }
    }

    @Test func requestMovesTheAppAndRelaunchesTheMovedCopy() async throws {
        let scene = try MoveScene(in: temp.url)
        let checker = scene.checker()

        #expect(await checker.request() == .granted)

        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: scene.source.path))
        #expect(scene.events.entries == ["spawn", "terminate"])
        #expect(scene.spawned.entries.first?.last == scene.destination.path)
        #expect(checker.lastError == nil)
    }

    @Test func requestMovesTheOriginalOfATranslocatedApp() async throws {
        let scene = try MoveScene(in: temp.url)
        let mount = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/RoomForMac.app")
        let checker = scene.checker(location: .translocated(original: scene.source), bundleURL: mount)

        #expect(await checker.request() == .granted)

        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(scene.spawned.entries.first?.last == scene.destination.path)
    }

    @Test func requestKeepsARunningCopyAndReportsIt() async throws {
        let scene = try MoveScene(in: temp.url)
        let existing = try AppBundleFixture.make(in: scene.home.appending(path: "Applications"), marker: "old")
        let checker = scene.checker(running: { true })
        let copy = checker

        #expect(await checker.request() == .denied)

        guard case .destinationIsRunning(let url)? = checker.lastError else {
            Issue.record("expected destinationIsRunning, got \(String(describing: checker.lastError))")
            return
        }
        #expect(url.path == existing.path)
        #expect(copy.lastError == checker.lastError, "copies of a checker share its last error")
        #expect(try AppBundleFixture.marker(of: existing) == "old")
        #expect(try AppBundleFixture.marker(of: scene.source) == "new")
        #expect(scene.events.entries.isEmpty)
    }

    @Test func aFailedRelaunchIsReportedAndDoesNotQuit() async throws {
        let scene = try MoveScene(in: temp.url)
        let checker = scene.checker(spawnFails: true)

        #expect(await checker.request() == .denied)

        #expect(scene.events.entries == ["spawn"])
        guard case .failed(let sentence)? = checker.lastError else {
            Issue.record("expected failed, got \(String(describing: checker.lastError))")
            return
        }
        #expect(sentence.contains("couldn't reopen itself"))
    }

    @Test func aLaterSuccessClearsTheLastError() async throws {
        let scene = try MoveScene(in: temp.url)
        try AppBundleFixture.make(in: scene.home.appending(path: "Applications"), marker: "old")
        let otherCopyIsOpen = RunningSwitch(true)
        let checker = scene.checker(running: { otherCopyIsOpen.value })

        #expect(await checker.request() == .denied)
        #expect(checker.lastError != nil)

        otherCopyIsOpen.value = false   // the user quit the other copy
        #expect(await checker.request() == .granted)
        #expect(checker.lastError == nil)
        #expect(try AppBundleFixture.marker(of: scene.destination) == "new")
        #expect(scene.events.entries == ["trash RoomForMac.app", "spawn", "terminate"])
    }
}

/// Whether the other copy counts as open; flipped between two requests.
private final class RunningSwitch: Sendable {
    private let state: Mutex<Bool>

    init(_ value: Bool) {
        state = Mutex(value)
    }

    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
```

- [ ] **Step 8: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppLocationTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The errors include `RoomForMacTests/AppLocationTests.swift:18:42: error: cannot find 'AppLocation' in scope` and `cannot find type 'AppLocationChecker' in scope`.

- [ ] **Step 9: Write the location and translocation check**

`RoomForMac/Features/Permissions/AppLocation.swift`
```swift
import Darwin
import Foundation

/// Where the running copy of RoomForMac lives, for the Move to Applications step.
enum AppLocation: Sendable, Equatable {
    /// Under /Applications/ or ~/Applications/, at any depth.
    case installed
    /// Anywhere else: Downloads, DerivedData, a mounted disk image.
    case outsideApplications
    /// Gatekeeper App Translocation runs a quarantined app from a random read-only path.
    /// `original` is where the app really is, when macOS can tell.
    case translocated(original: URL?)

    /// Pure: it never touches the file system, so tests can pass any path.
    /// Translocation wins even when the original is in Applications, because the Move step
    /// is what clears the quarantine flag that caused it.
    static func classify(bundleURL: URL, home: String, isTranslocated: Bool, originalURL: URL?) -> AppLocation {
        if isTranslocated {
            return .translocated(original: originalURL)
        }
        let components = bundleURL.standardizedFileURL.pathComponents
        for root in AppMover.candidateDirectories(home: home) {
            let prefix = root.standardizedFileURL.pathComponents
            if components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix {
                return .installed
            }
        }
        return .outsideApplications
    }

    static func current(bundle: Bundle = .main) -> AppLocation {
        let url = bundle.bundleURL
        let translocated = Translocation.isTranslocated(url)
        return classify(
            bundleURL: url,
            home: NSHomeDirectory(),
            isTranslocated: translocated,
            originalURL: translocated ? Translocation.originalURL(for: url) : nil
        )
    }
}

/// Gatekeeper App Translocation, through two Security.framework functions that have no public header.
enum Translocation {
    // Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef *error)
    private typealias IsTranslocatedFunction = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> DarwinBoolean
    // CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef translocatedPath, CFErrorRef *error)
    private typealias OriginalPathFunction = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    private static let securityPath = "/System/Library/Frameworks/Security.framework/Security"

    /// Asks Security.framework. When the function is missing or fails (a path that does not
    /// exist, for one), falls back to the path shape macOS uses for translocated apps.
    static func isTranslocated(_ url: URL) -> Bool {
        if let symbol = symbol(named: "SecTranslocateIsTranslocatedURL") {
            let function = unsafeBitCast(symbol, to: IsTranslocatedFunction.self)
            var translocated = false
            if function(url as CFURL, &translocated, nil).boolValue {
                return translocated
            }
        }
        return pathLooksTranslocated(url.path)
    }

    static func originalURL(for url: URL) -> URL? {
        guard let symbol = symbol(named: "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: OriginalPathFunction.self)
        guard let original = function(url as CFURL, nil) else {
            return nil
        }
        return original.takeRetainedValue() as URL
    }

    static func pathLooksTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    private static func symbol(named name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(securityPath, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(securityPath, RTLD_LAZY) else {
            return nil
        }
        return dlsym(handle, name)
    }
}
```

- [ ] **Step 10: Write the checker**

`RoomForMac/Features/Permissions/AppLocationChecker.swift`
```swift
import Foundation
import Synchronization

/// The Move to Applications "permission": granted when the app runs from an Applications folder.
struct AppLocationChecker: PermissionChecking {
    let id: PermissionID = .moveToApplications

    private let location: @Sendable () -> AppLocation
    private let bypass: Bool
    private let mover: AppMover
    private let relauncher: Relauncher
    private let home: String
    private let bundleURL: @Sendable () -> URL
    private let lastErrorBox = LastMoveErrorBox()

    init(
        location: @escaping @Sendable () -> AppLocation,
        bypass: Bool,
        mover: AppMover,
        relauncher: Relauncher,
        home: String = NSHomeDirectory(),
        bundleURL: @escaping @Sendable () -> URL = { Bundle.main.bundleURL }
    ) {
        self.location = location
        self.bypass = bypass
        self.mover = mover
        self.relauncher = relauncher
        self.home = home
        self.bundleURL = bundleURL
    }

    /// Why the last `request()` failed; nil after a success. Shared by every copy of this checker.
    var lastError: AppMoveError? {
        lastErrorBox.value
    }

    func currentState() async -> PermissionState {
        if bypass {
            return .notApplicable
        }
        return location() == .installed ? .granted : .notDetermined
    }

    /// Moves the app, then relaunches the moved copy. In production the relaunch quits this
    /// process, so this only returns on failure; tests inject a relauncher that returns.
    func request() async -> PermissionState {
        if bypass {
            return .notApplicable
        }
        let current = location()
        if current == .installed {
            lastErrorBox.set(nil)
            return .granted
        }
        let source = Self.source(for: current, bundleURL: bundleURL())
        let directories = AppMover.candidateDirectories(home: home)
        let mover = self.mover
        let destination: URL
        do {
            destination = try await Self.offCooperativePool {
                try mover.move(appAt: source, toFirstWritableOf: directories)
            }
        } catch let error as AppMoveError {
            lastErrorBox.set(error)
            return .denied
        } catch {
            lastErrorBox.set(.failed(error.localizedDescription))
            return .denied
        }
        lastErrorBox.set(nil)
        do {
            try await relauncher.relaunch(at: destination)
        } catch {
            let folder = AppMoveError.displayPath(destination.deletingLastPathComponent())
            lastErrorBox.set(.failed(String(
                localized: "RoomForMac is now in \(folder), but it couldn't reopen itself. Quit it, then open it from there."
            )))
            return .denied
        }
        return .granted
    }

    /// A translocated app is moved from where the user put it, not from its read-only mount.
    static func source(for location: AppLocation, bundleURL: URL) -> URL {
        if case .translocated(let original?) = location {
            return original
        }
        return bundleURL
    }

    /// Copying a bundle off a disk image can take seconds, so it runs on a GCD thread,
    /// never on the Swift cooperative pool.
    private static func offCooperativePool<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

extension AppLocationChecker {
    static let forceMoveStepArgument = "-RFMForceMoveStep"

    /// DEBUG builds run from DerivedData, so they skip the Move step unless launched with
    /// `-RFMForceMoveStep YES`. Release builds never skip it.
    static func bypassesMoveStep(arguments: [String], isDebugBuild: Bool) -> Bool {
        guard isDebugBuild else {
            return false
        }
        guard let flag = arguments.firstIndex(of: forceMoveStepArgument), flag + 1 < arguments.count else {
            return true
        }
        return !["yes", "true", "1"].contains(arguments[flag + 1].lowercased())
    }

    /// `bypassesMoveStep` for this process and build configuration.
    static var bypassesMoveStepInThisBuild: Bool {
        #if DEBUG
        return bypassesMoveStep(arguments: ProcessInfo.processInfo.arguments, isDebugBuild: true)
        #else
        return false
        #endif
    }

    /// The production checker: the real location, mover and relauncher.
    static func live(bypass: Bool) -> AppLocationChecker {
        AppLocationChecker(
            location: { AppLocation.current() },
            bypass: bypass,
            mover: .live(),
            relauncher: .live()
        )
    }
}

/// Lets a `Sendable` struct report its last error: every copy shares this box.
private final class LastMoveErrorBox: Sendable {
    private let storage = Mutex<AppMoveError?>(nil)

    var value: AppMoveError? {
        storage.withLock { $0 }
    }

    func set(_ error: AppMoveError?) {
        storage.withLock { $0 = error }
    }
}
```

- [ ] **Step 11: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/AppLocationTests`
Expected: `✔ Test run with 14 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 12: Run the whole unit scheme**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-10.log" | tail -n 20
grep -E '(Permissions/(AppLocation|AppLocationChecker|AppMover|Relauncher)\.swift|RoomForMacTests/(AppLocationTests|AppMoverTests|Support/AppMoveFixtures)\.swift).*(warning|error):' "$TMPDIR/rfm-task-10.log"
```
Expected: the log ends with `** TEST SUCCEEDED **`, and the `grep` prints nothing, so this task's files have no warnings. The Swift Testing summary counts this task's 31 tests plus those of Tasks 1–9. The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 13: Sync the String Catalog**

Run:
```bash
OBJROOT=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null | awk '$1 == "OBJROOT" { print $3; exit }')
find "$OBJROOT" -path '*/RoomForMac.build/Objects-normal/*' -name '*.stringsdata' \
    -exec xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --stringsdata {} +
git diff --stat RoomForMac/Resources/Localizable.xcstrings
```
Expected: `xcstringstool` prints nothing and exits 0. The diff adds these 4 keys, and every key that earlier tasks added stays:
`Another copy of RoomForMac is already open in %@. Quit it, then try again.`, `RoomForMac couldn't clear the quarantine flag on %@.`, `RoomForMac is now in %@, but it couldn't reopen itself. Quit it, then open it from there.`, `RoomForMac isn't allowed to add apps to %@.`

- [ ] **Step 14: Commit**

```bash
git add RoomForMac/Features/Permissions/AppLocation.swift RoomForMac/Features/Permissions/AppLocationChecker.swift \
    RoomForMac/Features/Permissions/AppMover.swift RoomForMac/Features/Permissions/Relauncher.swift \
    RoomForMac/Resources/Localizable.xcstrings RoomForMacTests/Support/AppMoveFixtures.swift \
    RoomForMacTests/AppLocationTests.swift RoomForMacTests/AppMoverTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'EOF'
feat(app): app location, Move to Applications and relaunch

AppLocation classifies the running copy by whole path components, and
Translocation asks Security.framework whether Gatekeeper translocated
it. AppMover moves the app into /Applications or ~/Applications, never
replaces an open copy, copies when the original cannot be removed and
strips quarantine. Relauncher waits for this process to exit before
opening the new copy, and AppLocationChecker exposes it all as the
moveToApplications permission, with its last error kept for the UI.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 11: Onboarding flow model — steps, choices, persistence, summary

**Files:**
- Create: `RoomForMac/Features/Onboarding/OnboardingStep.swift`, `OnboardingChoices.swift`, `OnboardingFlow.swift`, `RoomForMacTests/OnboardingFlowTests.swift`

**Interfaces:**
- Consumes: `AppPreferences` (Task 7), `PermissionCenter`, `PermissionID`, `PermissionState` (Task 8). The tests also use `TemporaryDefaults` (Task 7, `RoomForMacTests/Support`).
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
- (internal to this task) A helper that no other task calls:
  ```swift
  extension OnboardingFlow {
      nonisolated static func resumeStep(stored raw: String?, in steps: [OnboardingStep]) -> OnboardingStep
  }
  ```
  `OnboardingFlow` also keeps three private stored properties, all `@ObservationIgnored`: `preferences`, `permissions` and a `hasStartedFinishing` flag. `PermissionSummaryItem` is declared in `OnboardingFlow.swift`, next to `summary()`.

**Requirements:**
- `steps` is `OnboardingStep.allCases` in declaration order, without `.moveToApplications` when `needsMoveStep` is false. The raw values are what `preferences.onboardingStep` stores, so a test pins them: renaming a case would send anyone who is half-way through back to Welcome.
- Every change of `step` writes `preferences.onboardingStep = step.rawValue`. Calls that change nothing write nothing: `back()` at Welcome, `next()` at Ready, and `skip()` on Welcome or Ready. The initializer writes nothing either.
- A new `OnboardingFlow` built on the same preferences resumes at the stored step (Review Focus 3). This covers:
  - the relaunch after "Move and relaunch";
  - the relaunch after granting Full Disk Access;
  - a quit at any step, for example at step 5 (`automation`).
- A stored `moveToApplications` with `needsMoveStep == false` resumes at the next step in `steps`, which is `fullDiskAccess`. That is exactly the relaunch of the moved copy: it is installed now, so it no longer has the Move step. A missing value, or one that is not a raw value, starts at `.welcome`.
- `choices` starts as `OnboardingChoices(analytics: preferences.analyticsEnabled)`. `notifications` and `launchAtLogin` start off.
- `summary()` lists, in this order:
  1. `moveToApplications`, only when `steps` contains it;
  2. `fullDiskAccess`, `automationFinder` and `automationSystemEvents`, always;
  3. `notifications`, only when `choices.notifications` is on;
  4. `launchAtLogin`, only when `choices.launchAtLogin` is on.

  Each item's `title` is `PermissionID.title`, and `granted` is `PermissionCenter.state(_:).isGranted`. `.notApplicable` therefore counts as granted, and `.unknown` does not.
- `finish(apply:)`:
  1. snapshots `choices`, then awaits `apply(snapshot)` exactly once;
  2. only after `apply` returns, writes `analyticsEnabled`, `notificationsWanted` (from `choices.notifications`), `onboardingCompleted = true` and `onboardingStep = nil`, in that order.

  If the app quits while `apply` waits on the notification prompt, the next launch resumes at Ready and applies again. `finish` is the only writer of `notificationsWanted` in this plan; Plan 3 can read it before posting a notification. Only the first call does anything. A second call, during or after the first, returns at once without calling `apply`, so a double click on **Start first scan** cannot apply twice.
- This task adds no user-facing strings, since every title comes from `PermissionID.title` (Task 8). `Localizable.xcstrings` does not change.
- Tests (`OnboardingFlowTests`, Swift Testing, `@MainActor`):
  - each test uses its own `UserDefaults` suite, Task 7's `TemporaryDefaults`, kept in a stored property and removed when the test ends;
  - they use a fixed-state `PermissionChecking` fake, and never call a real checker;
  - the fake is nested in the suite, so its name cannot clash with the helpers of Tasks 7 and 8.

  The tests cover:
  - the raw values;
  - which steps are skippable;
  - the order with and without the move step;
  - the `next`/`back` bounds and what they persist;
  - Back from Full Disk Access returning to Move;
  - `skip` as a no-op on Welcome and on Ready, and advancing elsewhere;
  - resuming after a relaunch;
  - resuming at every stored step;
  - resuming from a stale `moveToApplications`, and keeping it while the move is still needed;
  - garbage in preferences → `.welcome`;
  - the choice defaults;
  - `finish` applying once and persisting only after `apply`;
  - a second `finish` being a no-op;
  - three `summary` cases.

- [ ] **Step 1: Write the failing tests**

`RoomForMacTests/OnboardingFlowTests.swift`
```swift
import Foundation
import Testing
@testable import RoomForMac

@MainActor
@Suite("Onboarding flow")
struct OnboardingFlowTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// A fresh view of the same suite, the way a relaunched app would read it.
    private var preferences: AppPreferences { temporary.preferences }

    private func makeFlow(needsMoveStep: Bool = false, permissions: PermissionCenter? = nil) -> OnboardingFlow {
        OnboardingFlow(
            preferences: preferences,
            permissions: permissions ?? PermissionCenter(checkers: []),
            needsMoveStep: needsMoveStep
        )
    }

    /// Writes what an earlier launch left behind, under Task 7's key.
    private func storeStep(_ raw: String) {
        temporary.defaults.set(raw, forKey: "onboarding.step")
    }

    // MARK: Steps

    @Test func rawValuesAreTheStoredNames() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == [
            "welcome", "freeToExplore", "moveToApplications", "fullDiskAccess",
            "automation", "adminAccess", "extras", "ready",
        ])
    }

    @Test func onlyWelcomeAndReadyCannotBeSkipped() {
        #expect(OnboardingStep.allCases.filter { !$0.isSkippable } == [.welcome, .ready])
    }

    @Test func stepsKeepTheMoveStepWhenTheAppIsOutsideApplications() {
        #expect(makeFlow(needsMoveStep: true).steps == [
            .welcome, .freeToExplore, .moveToApplications, .fullDiskAccess,
            .automation, .adminAccess, .extras, .ready,
        ])
    }

    @Test func stepsDropTheMoveStepWhenItIsNotNeeded() {
        #expect(makeFlow(needsMoveStep: false).steps == [
            .welcome, .freeToExplore, .fullDiskAccess,
            .automation, .adminAccess, .extras, .ready,
        ])
    }

    // MARK: Navigation

    @Test func aFreshFlowStartsAtWelcome() {
        let flow = makeFlow()
        #expect(flow.step == .welcome)
        #expect(flow.index == 0)
        #expect(!flow.canGoBack)
    }

    @Test func nextWalksEveryStepPersistingEachAndStopsAtReady() {
        let flow = makeFlow(needsMoveStep: true)
        for expected in flow.steps.dropFirst() {
            flow.next()
            #expect(flow.step == expected)
            #expect(preferences.onboardingStep == expected.rawValue)
        }
        #expect(flow.index == flow.steps.count - 1)
        flow.next()
        #expect(flow.step == .ready)
        #expect(flow.index == 7)
    }

    @Test func backStopsAtWelcomeAndPersistsEveryMove() {
        let flow = makeFlow()
        flow.back()
        #expect(flow.step == .welcome)
        #expect(preferences.onboardingStep == nil)

        flow.next()
        flow.next()
        #expect(flow.step == .fullDiskAccess)
        #expect(flow.canGoBack)

        flow.back()
        #expect(flow.step == .freeToExplore)
        #expect(preferences.onboardingStep == "freeToExplore")

        flow.back()
        #expect(flow.step == .welcome)
        #expect(!flow.canGoBack)
        #expect(preferences.onboardingStep == "welcome")
    }

    @Test func backFromFullDiskAccessRevisitsTheMoveStepWhenItIsNeeded() {
        let flow = makeFlow(needsMoveStep: true)
        flow.next()
        flow.next()
        flow.next()
        #expect(flow.step == .fullDiskAccess)
        flow.back()
        #expect(flow.step == .moveToApplications)
    }

    @Test func skipOnWelcomeIsANoOp() {
        let flow = makeFlow()
        flow.skip()
        #expect(flow.step == .welcome)
        #expect(preferences.onboardingStep == nil)
    }

    @Test func skipOnReadyIsANoOp() {
        storeStep("ready")
        let flow = makeFlow()
        flow.skip()
        #expect(flow.step == .ready)
        #expect(preferences.onboardingStep == "ready")
    }

    @Test func skipAdvancesASkippableStep() {
        let flow = makeFlow()
        flow.next()
        #expect(flow.step == .freeToExplore)
        flow.skip()
        #expect(flow.step == .fullDiskAccess)
        #expect(preferences.onboardingStep == "fullDiskAccess")
    }

    // MARK: Resuming after a relaunch or a quit

    @Test func aNewFlowResumesWhereTheLastOneStopped() {
        let first = makeFlow(needsMoveStep: true)
        first.next()
        first.next()
        first.next()
        #expect(first.step == .fullDiskAccess)

        let relaunched = makeFlow(needsMoveStep: true)
        #expect(relaunched.step == .fullDiskAccess)
        #expect(relaunched.index == 3)
        #expect(relaunched.canGoBack)
    }

    @Test(arguments: OnboardingStep.allCases)
    func resumesAtEveryPersistedStep(_ step: OnboardingStep) {
        storeStep(step.rawValue)
        #expect(makeFlow(needsMoveStep: true).step == step)
    }

    @Test func aStoredMoveStepResumesAtFullDiskAccessOnceTheAppIsInstalled() {
        storeStep("moveToApplications")
        let flow = makeFlow(needsMoveStep: false)
        #expect(flow.step == .fullDiskAccess)
        #expect(flow.index == 2)
    }

    @Test func aStoredMoveStepStaysWhileTheMoveIsStillNeeded() {
        storeStep("moveToApplications")
        #expect(makeFlow(needsMoveStep: true).step == .moveToApplications)
    }

    @Test(arguments: ["", "banana", "Welcome", "fullDiskAccess ", "ready\n"])
    func garbageInPreferencesStartsAtWelcome(_ raw: String) {
        storeStep(raw)
        let flow = makeFlow()
        #expect(flow.step == .welcome)
        #expect(flow.index == 0)
    }

    // MARK: Choices and finishing

    @Test func choicesStartFromTheDefaultsAndTheStoredAnalyticsSetting() {
        #expect(makeFlow().choices == OnboardingChoices(notifications: false, launchAtLogin: false, analytics: true))

        temporary.defaults.set(false, forKey: "analytics.enabled")
        #expect(makeFlow().choices == OnboardingChoices(notifications: false, launchAtLogin: false, analytics: false))
    }

    @Test func finishAppliesTheChoicesOnceThenPersists() async {
        let flow = makeFlow()
        for _ in flow.steps.dropFirst() {
            flow.next()
        }
        #expect(flow.step == .ready)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        flow.choices.analytics = false
        let expected = flow.choices

        let preferences = self.preferences
        var applied: [OnboardingChoices] = []
        var completedWhileApplying: Bool?
        await flow.finish { choices in
            applied.append(choices)
            completedWhileApplying = preferences.onboardingCompleted
        }

        #expect(applied == [expected])
        #expect(completedWhileApplying == false)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == false)
        #expect(preferences.notificationsWanted)
    }

    @Test func finishingTwiceAppliesOnce() async {
        let flow = makeFlow()
        var calls = 0
        await flow.finish { _ in calls += 1 }
        await flow.finish { _ in calls += 1 }
        #expect(calls == 1)
    }

    // MARK: Summary

    @Test func summaryListsTheCorePermissionsWithTheirStates() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .fullDiskAccess, state: .granted),
            FixedPermission(id: .automationFinder, state: .denied),
            FixedPermission(id: .automationSystemEvents, state: .unknown("not running")),
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .granted),
        ])
        await center.refreshAll()

        let summary = makeFlow(permissions: center).summary()

        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents])
        #expect(summary.map(\.granted) == [true, false, false])
        #expect(summary.map(\.title) == summary.map(\.id.title))
    }

    @Test func summaryAddsTheSkippedMoveAndTheChosenExtras() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .moveToApplications, state: .notDetermined),
            FixedPermission(id: .fullDiskAccess, state: .denied),
            FixedPermission(id: .automationFinder, state: .granted),
            FixedPermission(id: .automationSystemEvents, state: .granted),
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .requiresApproval),
        ])
        await center.refreshAll()
        let flow = makeFlow(needsMoveStep: true, permissions: center)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true

        let summary = flow.summary()

        #expect(summary.map(\.id) == [
            .moveToApplications, .fullDiskAccess, .automationFinder,
            .automationSystemEvents, .notifications, .launchAtLogin,
        ])
        #expect(summary.map(\.granted) == [false, false, true, true, true, false])
    }

    @Test func summaryIncludesOnlyTheExtrasThatWereChosen() async {
        let center = PermissionCenter(checkers: [
            FixedPermission(id: .notifications, state: .granted),
            FixedPermission(id: .launchAtLogin, state: .granted),
        ])
        await center.refreshAll()
        let flow = makeFlow(permissions: center)
        flow.choices.launchAtLogin = true

        let summary = flow.summary()

        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents, .launchAtLogin])
        #expect(summary.map(\.granted) == [false, false, false, true])
    }
}

// Nested, so its name cannot clash with helpers in other test files.
extension OnboardingFlowTests {
    /// A checker that always reports the same state and never prompts.
    private struct FixedPermission: PermissionChecking {
        let id: PermissionID
        let state: PermissionState

        func currentState() async -> PermissionState { state }
        func request() async -> PermissionState { state }
    }
}
```

Nothing here writes to `UserDefaults.standard`. Task 7's `TemporaryDefaults` empties its suite with `removePersistentDomain(forName:)` when the test ends. macOS still leaves an empty `RoomForMacTests.<UUID>.plist` in `~/Library/Preferences`, which is harmless; every suite that uses `TemporaryDefaults` leaves the same kind of file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingFlowTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The errors are:
- `RoomForMacTests/OnboardingFlowTests.swift:17:97: error: cannot find type 'OnboardingFlow' in scope`
- `RoomForMacTests/OnboardingFlowTests.swift:149:22: error: cannot find 'OnboardingStep' in scope`
- `RoomForMacTests/OnboardingFlowTests.swift:150:46: error: cannot find type 'OnboardingStep' in scope`

- [ ] **Step 3: Write the steps and the choices**

`RoomForMac/Features/Onboarding/OnboardingStep.swift`
```swift
import Foundation

/// The eight onboarding screens of spec §6, in order. The raw values are
/// persisted as `onboarding.step`, so a relaunch resumes on the same screen;
/// renaming a case strands anyone mid-onboarding back at Welcome.
enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome, freeToExplore, moveToApplications, fullDiskAccess, automation, adminAccess, extras, ready

    /// Welcome and Ready have no Skip button; every other screen does.
    var isSkippable: Bool {
        switch self {
        case .welcome, .ready: false
        case .freeToExplore, .moveToApplications, .fullDiskAccess, .automation, .adminAccess, .extras: true
        }
    }
}
```

`RoomForMac/Features/Onboarding/OnboardingChoices.swift`
```swift
import Foundation

/// What the user picked on the Extras screen. Nothing is applied until
/// `OnboardingFlow.finish(apply:)` runs on the Ready screen.
struct OnboardingChoices: Equatable, Sendable {
    var notifications = false
    var launchAtLogin = false
    var analytics = true
}
```

- [ ] **Step 4: Write the flow**

`RoomForMac/Features/Onboarding/OnboardingFlow.swift`
```swift
import Foundation
import Observation

/// One chip on the Ready screen: granted shows ✓, anything else shows •.
struct PermissionSummaryItem: Identifiable, Equatable, Sendable {
    let id: PermissionID
    let title: LocalizedStringResource
    let granted: Bool
}

/// The onboarding state machine. It owns which screen is showing and what the
/// user chose, and persists the screen on every change, so the relaunch after
/// "Move and relaunch", the relaunch after granting Full Disk Access, or a quit
/// half-way through all resume where the user left off.
@MainActor @Observable
final class OnboardingFlow {
    private(set) var step: OnboardingStep
    let steps: [OnboardingStep]
    var choices: OnboardingChoices

    @ObservationIgnored private var preferences: AppPreferences
    @ObservationIgnored private let permissions: PermissionCenter
    @ObservationIgnored private var hasStartedFinishing = false

    init(preferences: AppPreferences, permissions: PermissionCenter, needsMoveStep: Bool) {
        let steps = OnboardingStep.allCases.filter { needsMoveStep || $0 != .moveToApplications }
        self.steps = steps
        self.step = Self.resumeStep(stored: preferences.onboardingStep, in: steps)
        self.choices = OnboardingChoices(analytics: preferences.analyticsEnabled)
        self.preferences = preferences
        self.permissions = permissions
    }

    /// The position of `step` in `steps`.
    var index: Int {
        steps.firstIndex(of: step) ?? 0
    }

    var canGoBack: Bool {
        index > 0
    }

    func next() {
        let nextIndex = index + 1
        guard step != .ready, steps.indices.contains(nextIndex) else { return }
        show(steps[nextIndex])
    }

    func back() {
        guard canGoBack else { return }
        show(steps[index - 1])
    }

    func skip() {
        guard step.isSkippable else { return }
        next()
    }

    /// The Ready screen's chips: Move to Applications (only while that step is
    /// part of the flow), Full Disk Access, both Automation targets, then
    /// notifications and open-at-login when the user chose them.
    func summary() -> [PermissionSummaryItem] {
        var ids: [PermissionID] = []
        if steps.contains(.moveToApplications) {
            ids.append(.moveToApplications)
        }
        ids += [.fullDiskAccess, .automationFinder, .automationSystemEvents]
        if choices.notifications {
            ids.append(.notifications)
        }
        if choices.launchAtLogin {
            ids.append(.launchAtLogin)
        }
        return ids.map { id in
            PermissionSummaryItem(id: id, title: id.title, granted: permissions.state(id).isGranted)
        }
    }

    /// Applies the choices first, then records completion. If the app quits
    /// while `apply` waits on a system prompt, the next launch resumes at Ready
    /// and asks again. Only the first call does anything, so a double click on
    /// "Start first scan" cannot apply twice.
    func finish(apply: (OnboardingChoices) async -> Void) async {
        guard !hasStartedFinishing else { return }
        hasStartedFinishing = true
        let chosen = choices
        await apply(chosen)
        preferences.analyticsEnabled = chosen.analytics
        preferences.notificationsWanted = chosen.notifications
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
    }

    /// The step to open on: the stored one when it is part of `steps`; for a
    /// stored step the flow no longer has (Move, once the app is installed),
    /// the first later step; for nothing or garbage, Welcome.
    nonisolated static func resumeStep(stored raw: String?, in steps: [OnboardingStep]) -> OnboardingStep {
        guard let raw, let stored = OnboardingStep(rawValue: raw) else { return .welcome }
        if steps.contains(stored) {
            return stored
        }
        let order = OnboardingStep.allCases
        guard let storedPosition = order.firstIndex(of: stored) else { return .welcome }
        return steps.first { (order.firstIndex(of: $0) ?? 0) > storedPosition } ?? .welcome
    }

    private func show(_ newStep: OnboardingStep) {
        step = newStep
        preferences.onboardingStep = newStep.rawValue
    }
}
```

Notes on the code:
- `preferences` is a stored `var`, so the setters work whether Task 7 declares them `mutating` or `nonmutating`. Stored properties never get the "never mutated" warning.
- `step` has no `didSet`. Every assignment goes through `show(_:)`, which also persists it.
- `finish` takes a non-escaping, non-`Sendable` closure and calls it on the main actor. Task 13's `await flow.finish { await OnboardingApply.apply($0, permissions: …, loginItem: …) }` compiles as written, both under Swift 6 and under `NonisolatedNonsendingByDefault`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingFlowTests`
Expected: `✔ Test run with 22 tests in 1 suite passed` and `** TEST SUCCEEDED **`. `resumesAtEveryPersistedStep(_:)` runs 8 cases and `garbageInPreferencesStartsAtWelcome(_:)` runs 5; each counts as one test.

- [ ] **Step 6: Run the whole unit scheme**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-11.log" | tail -n 20
grep -E '(Features/Onboarding/|OnboardingFlowTests\.swift).*(warning|error):' "$TMPDIR/rfm-task-11.log"
git status --short RoomForMac/Resources/Localizable.xcstrings
```
Expected:
- The log ends with `** TEST SUCCEEDED **`. The Swift Testing summary counts this task's 22 tests plus those of Tasks 1–10.
- The `grep` prints nothing, so this task's files have no warnings.
- `git status` prints nothing, because this task adds no strings to the catalog.
- The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 7: Commit**

```bash
git add RoomForMac/Features/Onboarding/OnboardingStep.swift RoomForMac/Features/Onboarding/OnboardingChoices.swift \
    RoomForMac/Features/Onboarding/OnboardingFlow.swift RoomForMacTests/OnboardingFlowTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'MSG'
feat(onboarding): resumable onboarding flow model

OnboardingFlow walks the eight onboarding screens and drops Move to
Applications when the app is already installed. It writes the current
screen to preferences on every change, so a relaunch after moving the
app or granting Full Disk Access, or a quit half-way through, resumes
on the same screen. A stale Move step resumes at Full Disk Access, and
anything unreadable starts at Welcome.

finish(apply:) applies the Extras choices once, and only then records
completion and the analytics and notification choices. summary()
builds the Ready screen's chips from PermissionCenter.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
MSG
```

### Task 12: Onboarding UI, part 1 — scaffold, Welcome, Free to explore, Move, Full Disk Access, PermissionCard

**Files:**
- Create: `RoomForMac/Features/Onboarding/OnboardingView.swift`, `OnboardingScaffold.swift`, `Steps/WelcomeStep.swift`, `Steps/FreeToExploreStep.swift`, `Steps/MoveToApplicationsStep.swift`, `Steps/FullDiskAccessStep.swift`, `RoomForMac/Features/Permissions/PermissionCard.swift`, `RoomForMacTests/OnboardingViewTests.swift`
- Modify: `RoomForMac/App/RootView.swift` (show `OnboardingView`), `RoomForMac/App/AppDependencies.swift` (live permission checkers, `needsMoveStep`, `loginItem`), `RoomForMac/App/AppModel.swift` (`permissions`, `onboardingFlow`), `RoomForMac/App/AccessibilityID.swift`, `RoomForMac/Resources/Localizable.xcstrings` (the new keys, synced in Step 15), and any Task 7 test that names the onboarding placeholder's identifier (Step 12 finds them)

**Interfaces:**
- Consumes:
  - `OnboardingFlow`, `OnboardingStep` (Task 11);
  - `PermissionCenter` (Task 8);
  - the live checkers (Tasks 9–10);
  - `GlassButton`, `GlassCard`, `GlassDots`, `morphingGlass`, `AnimatedWordmark` (Task 5);
  - `BackdropView` (Task 6);
  - `AppModel` (Task 7);
  - the test support `TemporaryDefaults` (Task 7, `RoomForMacTests/Support`).
  - Also, by name: `PermissionID`, `PermissionState`, `PermissionChecking` (Task 8); `FullDiskAccessChecker`, `AutomationChecker.live`, `NotificationChecker.live`, `LoginItemChecker.live` (Task 9); `AppLocation.current`, `AppLocationChecker` (its `init` and `lastError`, and the two members Task 10 adds for this task: `bypassesMoveStepInThisBuild` and `live(bypass:)`), `AppMoveError` and its `LocalizedError` sentences (`localizedDescription`), `AppMover(isRunning:trashItem:)` and `Relauncher(spawn:terminate:)` (tests only), `Relauncher.live` (Task 10); `Palette`, `Typography`, `Motion` (Task 4); Task 5's internal `View.glassSurface(_:in:)` and its test support `RenderCheck.image(of:scheme:size:)` (in `GlassComponentTests.swift`); `AppModel.dependencies` and `AppModel.completeOnboarding` (Task 7).
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
  // AppDependencies (Task 7) gains these stored properties (defaults [], false, nil); live() sets all three,
  // and Task 15's forScenario sets them for the scenarios:
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
- Internal to this task. Task 13 extends the first three when it adds its screens to `OnboardingView`; nothing else depends on them.
  ```swift
  extension OnboardingScaffold {
      func primaryEnabled(_ enabled: Bool) -> Self      // greys out only the primary button; default enabled
  }
  enum OnboardingPrimary: Equatable, Sendable {         // in OnboardingView.swift: what the primary button says and does
      case getStarted, next, moveAndRelaunch, waitForFullDiskAccess, startFirstScan
      static func forStep(_ step: OnboardingStep, fullDiskAccess: PermissionState) -> OnboardingPrimary
      var title: LocalizedStringKey { get }             // "Get started" / "Continue" / "Move and relaunch" / "Continue" / "Start first scan"
      var isEnabled: Bool { get }                       // false only for .waitForFullDiskAccess
  }
  enum OnboardingBackdrop {                             // in OnboardingView.swift
      static let softenedFocus: Double                  // 0.3
      static let revealDuration: Double                 // 1.6 (seconds)
      static let softenDuration: Double                 // 0.8
      static let wordmarkDuration: Double               // 2.0
      static func focus(step: OnboardingStep, welcomeFocus: Double, reduceMotion: Bool) -> Double
  }
  enum OnboardingMotion {                               // in OnboardingView.swift
      static func stepTransition(reduceMotion: Bool) -> AnyTransition
      static func stepAnimation(reduceMotion: Bool) -> Animation
  }
  struct WelcomeStep: View { let wordmarkProgress: Double }
  struct FreeToExploreStep: View { static let freeAllowanceBytes: Int64; static let meterFillDuration: Double }   // 1_000_000_000, 1.2
  struct MoveToApplicationsStep: View {
      let state: PermissionState; let moveError: AppMoveError?
      static let glideDistance: CGFloat                                    // 120
      static func message(for error: AppMoveError?) -> String   // error?.localizedDescription (Task 10's sentence), else "RoomForMac couldn't move itself."
  }
  struct FullDiskAccessStep: View {
      let permissions: PermissionCenter
      static let whyReasons: [LocalizedStringResource]
      static func showsRelaunch(returnedFromSettings: Bool, state: PermissionState) -> Bool
  }
  extension PermissionChip {
      static func label(for state: PermissionState) -> LocalizedStringResource   // required by the tests below
      static func tint(for state: PermissionState) -> Palette.Token              // moss / clay / textSecondary
      static func systemImage(for state: PermissionState) -> String
  }
  extension AppDependencies {
      var appLocationChecker: AppLocationChecker? { get }                        // the one in permissionCheckers
  }
  extension AccessibilityID {
      static let onboardingRevealInFinder = "onboarding.move.revealInFinder"
      static let onboardingRelaunch = "onboarding.fullDiskAccess.relaunch"
      static let onboardingWhy = "onboarding.fullDiskAccess.why"
  }
  ```

**Requirements:**
- **`OnboardingView`** shows the current step inside one `OnboardingScaffold` over `BackdropView(scene: .onboarding, focus:)`.
  - The scaffold stays on screen for the whole flow and only its content changes, so `GlassDots` morphs from step to step. Each step view is content only; `OnboardingView` picks the primary button through `OnboardingPrimary`.
  - The content switches with `.transition(.opacity)` under Reduce Motion (0.3 s ease-in-out), otherwise with a slide from the trailing edge plus a fade (spring, response 0.45, damping 0.85).
  - The content carries `AccessibilityID.onboardingStep(step)` and contains its children.
  - On appear it calls `permissions.refreshAll()` once. Every checker's `currentState()` is passive, so this never prompts.
  - **Backdrop focus (tightened).** The skeleton says both "Focus is 0 while Welcome animates in and 1 afterwards" and "then softens (focus → 0.3)". The single rule is `OnboardingBackdrop.focus`: on Welcome it follows the intro (0 → 1 over 1.6 s, then → 0.3 over 0.8 s, and 0.3 on later visits); every other step is 1; under Reduce Motion it is 1 on every step from the start, with no animation.
  - Until Task 13 lands, Finder & System Events, Admin access, Extras and Ready show an empty content area. Their primary moves on, and on Ready "Start first scan" runs `await flow.finish { _ in }` and then `model.completeOnboarding(startFirstScan: true)`. Task 13 replaces `PendingStepContent` and the `.ready` primary.
- **`OnboardingScaffold`**:
  - The bottom bar holds Back (a secondary `GlassButton`, only when `flow.canGoBack`), the centred `GlassDots(count: flow.steps.count, current: flow.index)`, Skip (a plain text button in `textSecondary`, only when `flow.step.isSkippable`) and the primary `GlassButton`, which has `.keyboardShortcut(.defaultAction)`.
  - Identifiers: `onboardingBack`, `onboardingSkip`, `onboardingPrimary`.
  - The content is centred in a 560 pt column and scrolls when the window is too short.
  - `primaryEnabled(false)` greys out only the primary button.
- **Welcome** (spec §6 screen 1):
  - The backdrop resolves from blur into focus over 1.6 s, then softens (focus → 0.3) over 0.8 s.
  - `AnimatedWordmark` draws over 2.0 s, starting when the softening starts.
  - The CTA is "Get started".
  - Under Reduce Motion, everything is shown in its final state (wordmark drawn, backdrop focus 1).
  - The intro plays once per launch, the first time Welcome is on screen. Leaving Welcome early jumps both values to their final state.
- **Free to explore:** a `GlassCard` with:
  - the heading "Unlimited scans and previews";
  - "1 GB" in `Typography.hero`, formatted with `.byteCount(style: .file)` from 1 000 000 000 bytes;
  - a 1 GB meter: a capsule track in `moss` (at 50% opacity, so the fill stands out), with a `grass` fill animating 0 → 1 over 1.2 s (full at once under Reduce Motion), labelled "1 GB of free cleanup, once", which VoiceOver reads as one element;
  - the line "Upgrade once for unlimited cleanup — every future version included.";
  - the line "No account, no card."
- **Move to Applications** (only when `flow.steps` contains it):
  - The app icon (`NSApplication.shared.applicationIconImage`) glides 120 pt toward an `Image(systemName: "folder")` labelled "Applications", on a loop (`phaseAnimator`). Under Reduce Motion the icon stays put, with an arrow to the folder.
  - The primary button "Move and relaunch" calls `permissions.request(.moveToApplications)`. It is disabled while the request runs. A successful move relaunches and never returns; if the state still comes back granted, the flow moves on.
  - On `.denied`, it shows the `AppLocationChecker.lastError` message, then "Drag RoomForMac into your Applications folder, then open it from there." with a **Reveal in Finder** button (`NSWorkspace.activateFileViewerSelecting`, identifier `onboardingRevealInFinder`).
  - The message is `MoveToApplicationsStep.message(for:)`: Task 10's sentence, `lastError?.localizedDescription`, shown as it is, or "RoomForMac couldn't move itself." when there is no error. This task writes no sentence of its own for a move error and wraps none of Task 10's: they are already complete and localized, with `~` for the home folder, and a `.failed` sentence can describe a move that worked but whose relaunch did not.
  - `AppDependencies.appLocationChecker` supplies the checker. It shares its `lastError` box with the copy inside `PermissionCenter`.
- **Full Disk Access:**
  - A `PermissionCard` for `.fullDiskAccess` with the reason "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete."
  - The action is "Open Settings", which calls `request`.
  - A looping mini-animation of a toggle turning on: a System Settings-style row with a SwiftUI `Toggle` driven by a 1.6 s timer, on and static under Reduce Motion. It is decorative: no hit testing, hidden from VoiceOver.
  - `.task { await permissions.poll(.fullDiskAccess) }`, and a refresh on `NSApplication.didBecomeActiveNotification`.
  - **Once granted (tightened):** the card gives way to a glass checkmark badge (`morphingGlass` circle tinted `action`) with "Full Disk Access is on" and an "Allowed" chip. The badge keeps the card's `permissionCard`/`permissionChip` identifiers, and the change uses a blur-replace transition (a crossfade under Reduce Motion). It is not a `glassEffectID` morph from the card: the card's glass is inside `GlassCard`, and an ID applied from outside would also tag its button's glass, which is unverified behaviour.
  - **The primary button reads "Continue" and stays disabled until the grant (tightened).** The card's "Open Settings" is the step's only call to action, and Skip moves on without access.
  - After returning from Settings with the state still not granted, a "Turned it on? Relaunch RoomForMac" link (identifier `onboardingRelaunch`) calls `Relauncher.live().relaunch(at: Bundle.main.bundleURL)`. If that throws, the step says "RoomForMac couldn't relaunch itself. Quit it and open it again."
  - A "Why?" `DisclosureGroup` (identifier `onboardingWhy`) explains, in plain words, what breaks without it: incomplete scans, a Trash shown as empty, separate prompts for Downloads and other apps' data, and apps that cannot be moved to the Trash.
  - The step polls, so a checker must report the granted state from `currentState()` after a successful `request()`. Otherwise the next poll turns the card back. Task 15's `ScriptedPermissionChecker` must switch to `afterRequest` for both calls.
- **`PermissionCard`:** a `GlassCard` with the title (a header), the reason in `textSecondary`, a `PermissionChip`, and a primary `GlassButton` for the action, hidden when `state.isGranted` (granted or not applicable).
  - Identifiers: the card `permissionCard(id)` (containing its children), the chip `permissionChip(id)`, the button `permissionAction(id)`.
  - Chip colours come from tokens: granted `moss`, denied `clay`, others `textSecondary`. The chip is a capsule tinted at 18% with a 50% edge, a state symbol in the tint colour and the label in `text`, read by VoiceOver as its label alone.
- **`AppDependencies`:**
  - The three new stored properties default to `[]`, `false` and `nil`. The memberwise calls Task 7 already has (`forScenario`, `AppModelTests`) keep compiling, and `live()` sets all three. Task 15 sets them for the scenarios.
  - `live()` builds `AppLocationChecker.live(bypass:)`, `FullDiskAccessChecker`, `AutomationChecker.live(.finder)`, `AutomationChecker.live(.systemEvents)`, `NotificationChecker.live()` and one `LoginItemChecker.live()`. That same login item checker is also `loginItem`. Settings links open through `NSWorkspace.shared.open`.
  - `live()` takes the bypass from Task 10's `AppLocationChecker.bypassesMoveStepInThisBuild` (Ruling 12: DEBUG builds skip the Move step unless launched with `-RFMForceMoveStep YES`, or `true` or `1`, in any case; release builds never skip it). It reads it once and uses the same value for the checker and for `needsMoveStep`. This task declares no argument parsing of its own; Task 10's `AppLocationTests` pin the rule.
  - `needsMoveStep` is `!bypass && AppLocation.current() != .installed`.
- **`AppModel`:** `permissions` is built in `init` from `dependencies.permissionCheckers` and `dependencies.preferences`. `onboardingFlow` is created in `init` when not onboarded, with `needsMoveStep: dependencies.needsMoveStep`, and set to nil by `completeOnboarding`.
- **`RootView`:** the not-onboarded branch shows `OnboardingView(model:flow:)` for `model.onboardingFlow`. Task 7's placeholder and its `onboarding.placeholder` identifier are removed.
- Nothing in this task uses `.buttonStyle(.glass(_:))`, `GlassButtonStyle(_:)`, `@ContentBuilder`, or any API newer than macOS 26.0.
- Tests (`OnboardingViewTests.swift`, 17 tests in 3 suites; no real permission, notification, login-item or file-move call):
  - `PermissionChip` label text for every state, through `static func label(for:) -> LocalizedStringResource`, and its tint tokens.
  - The exact identifier strings.
  - `OnboardingPrimary` for every step and for FDA granted, denied and unknown; titles and enabling.
  - `OnboardingBackdrop.focus` on Welcome, on another step and under Reduce Motion.
  - `FullDiskAccessStep.showsRelaunch`.
  - `MoveToApplicationsStep.message(for:)` returns Task 10's sentence for every `AppMoveError`, unchanged, and "RoomForMac couldn't move itself." for nil.
  - `appLocationChecker` found and absent. `request()` is never called on a real `AppLocationChecker`: it would move the test host app.
  - `AppModel` builds `permissions` from the checkers and stores their states in its preferences. It creates a flow with or without the Move step, resumes at a saved step, creates none when onboarded, and drops it on `completeOnboarding`.
  - Each step view renders through `ImageRenderer` (`RenderCheck`) in light and dark, with a `PermissionCenter` built on scripted fakes: Welcome at progress 0 and 1, Free to explore, Move (idle and failed), and Full Disk Access (off and on). `PermissionCard` renders in every state, and `OnboardingView` renders on Welcome, Full Disk Access and Ready.

- [ ] **Step 1: Write the failing tests**

`RoomForMacTests/OnboardingViewTests.swift`
```swift
import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// A checker that answers with fixed states and never touches the system.
private struct StaticChecker: PermissionChecking {
    let id: PermissionID
    var current: PermissionState
    var afterRequest: PermissionState

    func currentState() async -> PermissionState { current }
    func request() async -> PermissionState { afterRequest }
}

@MainActor
private func dependencies(
    _ preferences: AppPreferences,
    checkers: [any PermissionChecking] = [],
    needsMoveStep: Bool = false
) -> AppDependencies {
    AppDependencies(
        preferences: preferences,
        engineCheck: { .failure(.installationInvalid("not used")) },
        openURL: { _ in },
        permissionCheckers: checkers,
        needsMoveStep: needsMoveStep,
        loginItem: nil
    )
}

private func appLocationChecker() -> AppLocationChecker {
    AppLocationChecker(
        location: { .outsideApplications },
        bypass: false,
        mover: AppMover(isRunning: { _ in false }, trashItem: { _ in }),
        relauncher: Relauncher(spawn: { _, _ in }, terminate: {})
    )
}

@Suite("Onboarding view logic")
@MainActor
struct OnboardingViewLogicTests {
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test(arguments: [
        (PermissionState.granted, "Allowed"),
        (.notDetermined, "Not yet"),
        (.denied, "Denied"),
        (.requiresApproval, "Needs approval"),
        (.unknown("timed out"), "Unknown"),
        (.notApplicable, "Not needed"),
    ])
    func chipNamesEveryState(state: PermissionState, expected: String) {
        #expect(String(localized: PermissionChip.label(for: state)) == expected)
    }

    @Test func chipColoursComeFromTheTokens() {
        #expect(PermissionChip.tint(for: .granted) == .moss)
        #expect(PermissionChip.tint(for: .denied) == .clay)
        for state in [PermissionState.notDetermined, .requiresApproval, .unknown("x"), .notApplicable] {
            #expect(PermissionChip.tint(for: state) == .textSecondary)
        }
    }

    @Test func identifiersAreSpelledOnce() {
        #expect(AccessibilityID.onboardingPrimary == "onboarding.primary")
        #expect(AccessibilityID.onboardingBack == "onboarding.back")
        #expect(AccessibilityID.onboardingSkip == "onboarding.skip")
        #expect(AccessibilityID.onboardingStep(.fullDiskAccess) == "onboarding.step.fullDiskAccess")
        #expect(AccessibilityID.permissionCard(.automationFinder) == "permission.card.automationFinder")
        #expect(AccessibilityID.permissionAction(.fullDiskAccess) == "permission.action.fullDiskAccess")
        #expect(AccessibilityID.permissionChip(.launchAtLogin) == "permission.chip.launchAtLogin")
    }

    @Test func primaryButtonFollowsTheStep() {
        #expect(OnboardingPrimary.forStep(.welcome, fullDiskAccess: .denied) == .getStarted)
        #expect(OnboardingPrimary.forStep(.freeToExplore, fullDiskAccess: .denied) == .next)
        #expect(OnboardingPrimary.forStep(.moveToApplications, fullDiskAccess: .denied) == .moveAndRelaunch)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .denied) == .waitForFullDiskAccess)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .unknown("no probe file")) == .waitForFullDiskAccess)
        #expect(OnboardingPrimary.forStep(.fullDiskAccess, fullDiskAccess: .granted) == .next)
        #expect(OnboardingPrimary.forStep(.automation, fullDiskAccess: .denied) == .next)
        #expect(OnboardingPrimary.forStep(.ready, fullDiskAccess: .denied) == .startFirstScan)
    }

    @Test func primaryTitlesAndEnabling() {
        #expect(OnboardingPrimary.getStarted.title == "Get started")
        #expect(OnboardingPrimary.next.title == "Continue")
        #expect(OnboardingPrimary.moveAndRelaunch.title == "Move and relaunch")
        #expect(OnboardingPrimary.waitForFullDiskAccess.title == "Continue")
        #expect(OnboardingPrimary.startFirstScan.title == "Start first scan")
        #expect(!OnboardingPrimary.waitForFullDiskAccess.isEnabled)
        #expect(OnboardingPrimary.next.isEnabled)
    }

    @Test func backdropFocusPullsOnlyOnWelcome() {
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0, reduceMotion: false) == 0)
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0.3, reduceMotion: false) == 0.3)
        #expect(OnboardingBackdrop.focus(step: .fullDiskAccess, welcomeFocus: 0, reduceMotion: false) == 1)
        #expect(OnboardingBackdrop.focus(step: .welcome, welcomeFocus: 0, reduceMotion: true) == 1)
        #expect(OnboardingBackdrop.softenedFocus == 0.3)
        #expect(OnboardingBackdrop.revealDuration == 1.6)
        #expect(OnboardingBackdrop.wordmarkDuration == 2.0)
    }

    @Test func relaunchLinkNeedsAReturnFromSettingsWithoutAccess() {
        #expect(!FullDiskAccessStep.showsRelaunch(returnedFromSettings: false, state: .denied))
        #expect(FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .denied))
        #expect(FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .unknown("no probe file")))
        #expect(!FullDiskAccessStep.showsRelaunch(returnedFromSettings: true, state: .granted))
    }

    /// The step shows Task 10's sentences as they are. `/Users/test` is not the
    /// test host's home, so that folder keeps its full path instead of `~`.
    @Test func moveErrorsExplainThemselves() {
        let running = URL(fileURLWithPath: "/Applications/RoomForMac.app")
        #expect(MoveToApplicationsStep.message(for: .destinationIsRunning(running))
            == "Another copy of RoomForMac is already open in /Applications. Quit it, then try again.")
        #expect(MoveToApplicationsStep.message(for: .notWritable(URL(fileURLWithPath: "/Users/test/Applications")))
            == "RoomForMac isn't allowed to add apps to /Users/test/Applications.")
        #expect(MoveToApplicationsStep.message(for: .failed("disk full")) == "disk full")
        #expect(MoveToApplicationsStep.message(for: nil) == "RoomForMac couldn't move itself.")
    }

    // Never call `request()` on a real AppLocationChecker here: it would move
    // the test host app into an Applications folder.
    @Test func findsTheMoveChecker() throws {
        let deps = dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .denied, afterRequest: .denied),
            appLocationChecker(),
        ])
        let found = try #require(deps.appLocationChecker)
        #expect(found.id == .moveToApplications)
        #expect(found.lastError == nil)
        #expect(dependencies(temporary.preferences).appLocationChecker == nil)
    }
}

@Suite("App model onboarding")
@MainActor
struct AppModelOnboardingTests {
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    @Test func buildsThePermissionCenterFromTheCheckers() async {
        let model = AppModel(dependencies: dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .granted, afterRequest: .granted),
        ]))
        #expect(model.permissions.hasChecker(.fullDiskAccess))
        #expect(!model.permissions.hasChecker(.automationFinder))

        await model.permissions.refresh(.fullDiskAccess)
        #expect(model.permissions.state(.fullDiskAccess) == .granted)
        #expect(temporary.preferences.lastKnownState(for: "fullDiskAccess") == "granted")
    }

    @Test func aNewUserGetsAFlowThatHonoursTheMoveStep() throws {
        let withMove = AppModel(dependencies: dependencies(temporary.preferences, needsMoveStep: true))
        let flow = try #require(withMove.onboardingFlow)
        #expect(flow.steps.contains(.moveToApplications))
        #expect(flow.step == .welcome)

        let withoutMove = AppModel(dependencies: dependencies(temporary.preferences, needsMoveStep: false))
        #expect(withoutMove.onboardingFlow?.steps.contains(.moveToApplications) == false)
    }

    @Test func theFlowResumesAtTheSavedStep() {
        temporary.preferences.onboardingStep = OnboardingStep.fullDiskAccess.rawValue
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow?.step == .fullDiskAccess)
    }

    @Test func anOnboardedUserGetsNoFlow() {
        temporary.preferences.onboardingCompleted = true
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow == nil)
    }

    @Test func completingOnboardingDropsTheFlow() {
        let model = AppModel(dependencies: dependencies(temporary.preferences))
        #expect(model.onboardingFlow != nil)
        model.completeOnboarding(startFirstScan: false)
        #expect(model.onboardingFlow == nil)
        #expect(model.isOnboarded)
    }
}

@Suite("Onboarding rendering")
@MainActor
struct OnboardingRenderTests {
    private static let size = CGSize(width: 900, height: 640)
    /// Task 7's throwaway suite, held so it outlives every use inside a test.
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func center(fullDiskAccess: PermissionState) async -> PermissionCenter {
        let center = PermissionCenter(checkers: [
            StaticChecker(id: .fullDiskAccess, current: fullDiskAccess, afterRequest: .granted),
            StaticChecker(id: .moveToApplications, current: .notDetermined, afterRequest: .denied),
        ])
        await center.refreshAll()
        return center
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func stepsRender(scheme: ColorScheme) async throws {
        let denied = await center(fullDiskAccess: .denied)
        let granted = await center(fullDiskAccess: .granted)
        let samples: [(String, AnyView)] = [
            ("welcome, start", AnyView(WelcomeStep(wordmarkProgress: 0))),
            ("welcome, drawn", AnyView(WelcomeStep(wordmarkProgress: 1))),
            ("free to explore", AnyView(FreeToExploreStep())),
            ("move", AnyView(MoveToApplicationsStep(state: .notDetermined, moveError: nil))),
            ("move, failed", AnyView(MoveToApplicationsStep(
                state: .denied, moveError: .notWritable(URL(fileURLWithPath: "/Applications"))
            ))),
            ("full disk access, off", AnyView(FullDiskAccessStep(permissions: denied))),
            ("full disk access, on", AnyView(FullDiskAccessStep(permissions: granted))),
        ]
        for (name, view) in samples {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: Self.size), "\(name) did not render")
            #expect(image.width == Int(Self.size.width), "\(name)")
            #expect(image.height == Int(Self.size.height), "\(name)")
        }
    }

    @Test(arguments: [
        PermissionState.granted, .notDetermined, .denied, .requiresApproval, .unknown("timed out"), .notApplicable,
    ])
    func permissionCardRendersEveryState(state: PermissionState) throws {
        let card = PermissionCard(
            id: .automationFinder, state: state, title: "Finder",
            reason: "Shows your disk's exact free space in Status.", actionTitle: "Allow"
        ) {}
        let image = try #require(RenderCheck.image(of: card, scheme: .light, size: CGSize(width: 480, height: 200)))
        #expect(image.width == 480)
    }

    /// The whole screen: backdrop, dots and buttons. `ImageRenderer` draws
    /// nothing for the scaffold's `ScrollView`, so the step content itself is
    /// covered by `stepsRender`.
    @Test(arguments: [OnboardingStep.welcome, .fullDiskAccess, .ready])
    func onboardingViewRendersInsideTheScaffold(step: OnboardingStep) throws {
        temporary.preferences.onboardingStep = step.rawValue
        let model = AppModel(dependencies: dependencies(temporary.preferences, checkers: [
            StaticChecker(id: .fullDiskAccess, current: .denied, afterRequest: .granted),
        ]))
        let flow = try #require(model.onboardingFlow)
        #expect(flow.step == step)
        let image = try #require(RenderCheck.image(
            of: OnboardingView(model: model, flow: flow), scheme: .dark, size: CGSize(width: 1100, height: 720)
        ))
        #expect(image.width == 1100)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingViewLogicTests -only-testing:RoomForMacTests/AppModelOnboardingTests -only-testing:RoomForMacTests/OnboardingRenderTests`
Expected: the test target does not compile, and the run ends `** TEST FAILED **`. The errors include `error: extra arguments at positions #4, #5, #6 in call` (the new `AppDependencies` properties), `error: cannot find 'PermissionChip' in scope`, `error: type 'AccessibilityID' has no member 'onboardingPrimary'` and `error: value of type 'AppModel' has no member 'onboardingFlow'`. The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 3: Add the identifiers**

Append to `RoomForMac/App/AccessibilityID.swift`, after the closing brace of `enum AccessibilityID`:
```swift
// MARK: - Onboarding and permission cards (Task 12)

extension AccessibilityID {
    static let onboardingPrimary = "onboarding.primary"
    static let onboardingBack = "onboarding.back"
    static let onboardingSkip = "onboarding.skip"
    /// "Reveal in Finder" on the Move step, shown after a failed move.
    static let onboardingRevealInFinder = "onboarding.move.revealInFinder"
    /// "Turned it on? Relaunch RoomForMac" on the Full Disk Access step.
    static let onboardingRelaunch = "onboarding.fullDiskAccess.relaunch"
    /// The "Why?" disclosure on the Full Disk Access step.
    static let onboardingWhy = "onboarding.fullDiskAccess.why"

    /// The content of an onboarding step: "onboarding.step.<rawValue>".
    static func onboardingStep(_ step: OnboardingStep) -> String {
        "onboarding.step.\(step.rawValue)"
    }

    /// A permission card: "permission.card.<rawValue>".
    static func permissionCard(_ id: PermissionID) -> String {
        "permission.card.\(id.rawValue)"
    }

    /// The button on a permission card: "permission.action.<rawValue>".
    static func permissionAction(_ id: PermissionID) -> String {
        "permission.action.\(id.rawValue)"
    }

    /// The state chip on a permission card: "permission.chip.<rawValue>".
    static func permissionChip(_ id: PermissionID) -> String {
        "permission.chip.\(id.rawValue)"
    }
}
```

- [ ] **Step 4: Write the permission card and its chip** — `RoomForMac/Features/Permissions/PermissionCard.swift`

```swift
import SwiftUI

/// One approval on a glass card: what it is, why RoomForMac wants it, where it
/// stands, and the button that asks for it. Onboarding and Settings → Permissions
/// use the same card. The button hides once the approval is granted or not needed.
struct PermissionCard: View {
    private let id: PermissionID
    private let state: PermissionState
    private let title: LocalizedStringKey
    private let reason: LocalizedStringKey
    private let actionTitle: LocalizedStringKey
    private let action: @MainActor () -> Void

    init(
        id: PermissionID,
        state: PermissionState,
        title: LocalizedStringKey,
        reason: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.reason = reason
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
                    PermissionChip(state: state)
                        .accessibilityIdentifier(AccessibilityID.permissionChip(id))
                }
                Text(reason)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.isGranted {
                    GlassButton(actionTitle, action: action)
                        .accessibilityIdentifier(AccessibilityID.permissionAction(id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.permissionCard(id))
    }
}

/// A permission's state as a small capsule: "Allowed", "Not yet", "Denied",
/// "Needs approval", "Unknown" or "Not needed". The colour comes from the
/// palette: `moss` when allowed, `clay` when denied, `textSecondary` otherwise.
/// The words always carry the meaning; the colour and symbol only repeat it.
struct PermissionChip: View {
    private let state: PermissionState

    init(state: PermissionState) {
        self.state = state
    }

    static func label(for state: PermissionState) -> LocalizedStringResource {
        switch state {
        case .granted: "Allowed"
        case .notDetermined: "Not yet"
        case .denied: "Denied"
        case .requiresApproval: "Needs approval"
        case .unknown: "Unknown"
        case .notApplicable: "Not needed"
        }
    }

    static func tint(for state: PermissionState) -> Palette.Token {
        switch state {
        case .granted: .moss
        case .denied: .clay
        case .notDetermined, .requiresApproval, .unknown, .notApplicable: .textSecondary
        }
    }

    static func systemImage(for state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        case .requiresApproval: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .notApplicable: "minus.circle"
        }
    }

    var body: some View {
        let tint = Palette.color(Self.tint(for: state))
        HStack(spacing: 4) {
            Image(systemName: Self.systemImage(for: state))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text(Self.label(for: state))
                .foregroundStyle(Palette.text)
        }
        .font(Typography.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.18), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.label(for: state)))
    }
}
```

- [ ] **Step 5: Wire the live checkers into `AppDependencies`**

In `RoomForMac/App/AppDependencies.swift`, delete Task 7's `static func live(defaults:)` and put the block below directly after the stored property `var openURL: @MainActor (URL) -> Void`. The block has:
- the three new stored properties. They must follow Task 7's three, because the memberwise initializer takes stored properties in declaration order and the tests pass the new ones last;
- the new `live(defaults:)`, which takes the DEBUG Move-step bypass and the production Move checker from Task 10 (`AppLocationChecker.bypassesMoveStepInThisBuild`, `AppLocationChecker.live(bypass:)`);
- the checker lookup.

The file keeps `import AppKit` and `import MoleEngine` from Task 7. Leave every other member (`forMode`, `forScenario` and its helpers) unchanged.
```swift
    /// Every approval onboarding and Settings check. The defaults (none, no Move
    /// step, no login item) let tests that do not need permissions leave them out.
    var permissionCheckers: [any PermissionChecking] = []
    /// Whether onboarding shows the Move to Applications step.
    var needsMoveStep = false
    /// The login item checker that is also in `permissionCheckers`. Extras and
    /// Settings need its `disable()`, which `PermissionCenter` does not offer.
    var loginItem: LoginItemChecker? = nil

    static func live(defaults: UserDefaults = .standard) -> AppDependencies {
        let openSettings: @MainActor @Sendable (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
        // Ruling 12, decided by Task 10: a DEBUG build skips the Move step unless it
        // was launched with `-RFMForceMoveStep YES`. Read once, so the checker and
        // `needsMoveStep` always agree.
        let bypass = AppLocationChecker.bypassesMoveStepInThisBuild
        let loginItem = LoginItemChecker.live()
        let checkers: [any PermissionChecking] = [
            AppLocationChecker.live(bypass: bypass),
            FullDiskAccessChecker(openSettings: openSettings),
            AutomationChecker.live(.finder, openSettings: openSettings),
            AutomationChecker.live(.systemEvents, openSettings: openSettings),
            NotificationChecker.live(),
            loginItem,
        ]
        return AppDependencies(
            preferences: AppPreferences(defaults: defaults),
            engineCheck: { await EngineHealthCheck().run() },
            openURL: { url in _ = NSWorkspace.shared.open(url) },
            permissionCheckers: checkers,
            needsMoveStep: !bypass && AppLocation.current() != .installed,
            loginItem: loginItem
        )
    }

    /// The Move to Applications checker, for the reason a move failed. It shares
    /// its `lastError` box with the copy inside `PermissionCenter`.
    var appLocationChecker: AppLocationChecker? {
        permissionCheckers.lazy.compactMap { $0 as? AppLocationChecker }.first
    }
```

`openSettings` is a separate `@MainActor @Sendable` closure because the checkers are `Sendable` and store it, while `openURL` is not `@Sendable`. `live()` is only reached in `.normal` mode; the unit-test host never builds dependencies, so `AppLocationChecker.live(bypass:)`, `NotificationChecker.live()` and `SMAppService` are never touched by tests.

- [ ] **Step 6: Give `AppModel` the permission center and the flow**

In `RoomForMac/App/AppModel.swift`, add these two properties after `var pendingFirstScan`:
```swift
    /// Every approval the app tracks. Onboarding and Settings → Permissions share it.
    let permissions: PermissionCenter

    /// The onboarding in progress, resumed from preferences. Nil once onboarding is complete.
    private(set) var onboardingFlow: OnboardingFlow?
```

Replace `init(dependencies:)` with:
```swift
    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let preferences = dependencies.preferences
        let permissions = PermissionCenter(checkers: dependencies.permissionCheckers, preferences: preferences)
        let isOnboarded = preferences.onboardingCompleted
        self.permissions = permissions
        self.isOnboarded = isOnboarded
        onboardingFlow = isOnboarded
            ? nil
            : OnboardingFlow(preferences: preferences, permissions: permissions, needsMoveStep: dependencies.needsMoveStep)
    }
```

In `completeOnboarding(startFirstScan:)`, add `onboardingFlow = nil` directly after `isOnboarded = true`, so the method reads:
```swift
    /// Saves that onboarding is done and shows Smart Clean.
    func completeOnboarding(startFirstScan: Bool) {
        let preferences = dependencies.preferences
        preferences.onboardingCompleted = true
        preferences.onboardingStep = nil
        isOnboarded = true
        onboardingFlow = nil
        selection = .smartClean
        pendingFirstScan = startFirstScan
    }
```

The locals come first because an `@Observable` class cannot read `self.permissions` before every stored property is set.

- [ ] **Step 7: Write the scaffold** — `RoomForMac/Features/Onboarding/OnboardingScaffold.swift`

```swift
import SwiftUI

/// The frame every onboarding step sits in: the step's content in the middle,
/// and a bottom bar with Back, the progress dots, Skip (on skippable steps) and
/// the primary button.
///
/// `OnboardingView` keeps one scaffold on screen for the whole flow and swaps
/// only the content, so the current dot morphs from step to step instead of
/// being rebuilt.
struct OnboardingScaffold<Content: View>: View {
    private let flow: OnboardingFlow
    private let primaryTitle: LocalizedStringKey
    private let primaryAction: @MainActor () -> Void
    private let content: Content
    private var isPrimaryEnabled = true

    init(
        flow: OnboardingFlow,
        primaryTitle: LocalizedStringKey,
        primaryAction: @escaping @MainActor () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.flow = flow
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.content = content()
    }

    /// Greys out the primary button, as on Full Disk Access before the grant.
    /// Back and Skip stay available.
    func primaryEnabled(_ enabled: Bool) -> Self {
        var copy = self
        copy.isPrimaryEnabled = enabled
        return copy
    }

    var body: some View {
        VStack(spacing: 0) {
            // Centred when the step fits; scrolls when the window is too short,
            // for example with "Why?" open.
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            bottomBar
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
    }

    private var bottomBar: some View {
        ZStack {
            GlassDots(count: flow.steps.count, current: flow.index)
            HStack(spacing: 16) {
                if flow.canGoBack {
                    GlassButton("Back", prominence: .secondary) {
                        flow.back()
                    }
                    .accessibilityIdentifier(AccessibilityID.onboardingBack)
                }
                Spacer(minLength: 0)
                if flow.step.isSkippable {
                    Button("Skip") {
                        flow.skip()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier(AccessibilityID.onboardingSkip)
                }
                GlassButton(primaryTitle, action: primaryAction)
                    .disabled(!isPrimaryEnabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.onboardingPrimary)
            }
        }
        .frame(height: 52)
    }
}
```

- [ ] **Step 8: Write Welcome and Free to explore**

`RoomForMac/Features/Onboarding/Steps/WelcomeStep.swift`
```swift
import SwiftUI

/// Screen 1: the RoomForMac wordmark drawing itself over the onboarding
/// backdrop. `OnboardingView` runs the timing (the backdrop's focus pull, then
/// the 2 s draw) and passes the draw progress in; the primary button reads
/// "Get started".
struct WelcomeStep: View {
    let wordmarkProgress: Double

    var body: some View {
        AnimatedWordmark(progress: wordmarkProgress)
            .frame(maxWidth: 440, maxHeight: 110)
            .padding(.vertical, 24)
    }
}
```

`RoomForMac/Features/Onboarding/Steps/FreeToExploreStep.swift`
```swift
import SwiftUI

/// Screen 2: what is free. Scans and previews are unlimited; cleanup is free up
/// to 1 GB, once. A meter fills to show the allowance.
struct FreeToExploreStep: View {
    /// The free cleanup allowance, shown as "1 GB".
    static let freeAllowanceBytes: Int64 = 1_000_000_000
    /// How long the meter takes to fill, in seconds.
    static let meterFillDuration = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meterFill = 0.0

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Unlimited scans and previews")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.freeAllowanceBytes, format: .byteCount(style: .file))
                        .font(Typography.hero(size: 48))
                        .foregroundStyle(Palette.text)
                    AllowanceMeter(fill: reduceMotion ? 1 : meterFill)
                        .frame(height: 12)
                    Text("1 GB of free cleanup, once")
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("1 GB of free cleanup, once"))

                Text("Upgrade once for unlimited cleanup — every future version included.")
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("No account, no card.")
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !reduceMotion else {
                return
            }
            withAnimation(.easeInOut(duration: Self.meterFillDuration)) {
                meterFill = 1
            }
        }
    }
}

/// A capsule track in `moss` with a `grass` fill from the leading edge.
private struct AllowanceMeter: View {
    let fill: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.moss.opacity(0.5))
                Capsule()
                    .fill(Palette.grass)
                    .frame(width: proxy.size.width * min(max(fill, 0), 1))
            }
        }
    }
}
```

- [ ] **Step 9: Write the Move step** — `RoomForMac/Features/Onboarding/Steps/MoveToApplicationsStep.swift`

```swift
import AppKit
import SwiftUI

/// Screen 3, only when RoomForMac runs from outside an Applications folder: the
/// app icon glides into the Applications folder, and the primary button
/// ("Move and relaunch", in `OnboardingView`) moves the app and opens the moved
/// copy. When the move fails, the step says why and how to do it by hand.
struct MoveToApplicationsStep: View {
    /// How far the icon travels, in points: from its place to the folder's.
    static let glideDistance: CGFloat = 120

    let state: PermissionState
    let moveError: AppMoveError?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Why the move failed, in plain words: Task 10's sentence for the error,
    /// already localized and complete, so it is shown as it is and never wrapped.
    static func message(for error: AppMoveError?) -> String {
        error?.localizedDescription ?? String(localized: "RoomForMac couldn't move itself.")
    }

    var body: some View {
        VStack(spacing: 28) {
            GlideIllustration(animated: !reduceMotion)

            VStack(spacing: 8) {
                Text("Move RoomForMac to Applications")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac works best from your Applications folder. One click moves it there and opens it again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state == .denied {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            // A String, so `Text` shows it verbatim: it is already localized.
                            Text(Self.message(for: moveError))
                                .foregroundStyle(Palette.text)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.clay)
                        }
                        Text("Drag RoomForMac into your Applications folder, then open it from there.")
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        GlassButton("Reveal in Finder", prominence: .secondary) {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .accessibilityIdentifier(AccessibilityID.onboardingRevealInFinder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The app icon gliding into an Applications folder, on a loop. Under Reduce
/// Motion the icon stays put, with an arrow pointing at the folder.
private struct GlideIllustration: View {
    static let iconSize: CGFloat = 72

    let animated: Bool

    /// `start` → glide into the folder and fade → `reset` (jump back while
    /// invisible) → fade in at `start` again.
    private enum Phase: CaseIterable {
        case start, arrived, reset
    }

    var body: some View {
        Group {
            if animated {
                // Icon and folder centres are `glideDistance` apart.
                HStack(alignment: .top, spacing: MoveToApplicationsStep.glideDistance - Self.iconSize) {
                    appIcon
                        .phaseAnimator(Phase.allCases) { icon, phase in
                            icon
                                .offset(x: phase == .arrived ? MoveToApplicationsStep.glideDistance : 0)
                                .scaleEffect(phase == .arrived ? 0.5 : 1)
                                .opacity(phase == .start ? 1 : 0)
                        } animation: { phase in
                            switch phase {
                            case .arrived: .easeInOut(duration: 1.4).delay(0.5)
                            case .reset: .linear(duration: 0.01)
                            case .start: .easeOut(duration: 0.3)
                            }
                        }
                    applicationsFolder
                }
            } else {
                HStack(spacing: 16) {
                    appIcon
                    Image(systemName: "arrow.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                    applicationsFolder
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("RoomForMac moving into the Applications folder"))
    }

    private var appIcon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
    }

    private var applicationsFolder: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 56))
                .foregroundStyle(Palette.action)
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text("Applications")
                .font(Typography.caption)
                .foregroundStyle(Palette.text)
        }
    }
}
```

- [ ] **Step 10: Write the Full Disk Access step** — `RoomForMac/Features/Onboarding/Steps/FullDiskAccessStep.swift`

```swift
import AppKit
import SwiftUI

/// Screen 4: Full Disk Access. The card's "Open Settings" deep-links to Privacy →
/// Full Disk Access, the step re-checks every second and whenever RoomForMac
/// becomes active again, and the card gives way to a checkmark once access is on.
/// If the user comes back from System Settings and access is still off, a link
/// offers to relaunch RoomForMac, since macOS can apply the grant only after one.
struct FullDiskAccessStep: View {
    let permissions: PermissionCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openedSettings = false
    @State private var returnedFromSettings = false
    @State private var relaunchFailed = false
    @State private var switchOn = false

    /// What stops working without Full Disk Access, one line each, for "Why?".
    static let whyReasons: [LocalizedStringResource] = [
        "Scans can't see caches, logs and leftovers in protected folders, so they find less than there is.",
        "Your Trash shows as empty, even when it isn't.",
        "macOS asks separately before RoomForMac looks in Downloads or at other apps' data.",
        "Some apps can't be moved to the Trash when you uninstall them.",
    ]

    /// The relaunch link shows once the user has been to System Settings and
    /// come back while access is still off.
    static func showsRelaunch(returnedFromSettings: Bool, state: PermissionState) -> Bool {
        returnedFromSettings && !state.isGranted
    }

    var body: some View {
        let state = permissions.state(.fullDiskAccess)
        VStack(spacing: 20) {
            SettingsSwitchIllustration(isOn: reduceMotion || state.isGranted || switchOn)

            Group {
                if state.isGranted {
                    FullDiskAccessGrantedBadge()
                } else {
                    PermissionCard(
                        id: .fullDiskAccess,
                        state: state,
                        title: "Full Disk Access",
                        reason: "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.",
                        actionTitle: "Open Settings"
                    ) {
                        openSettings()
                    }
                }
            }
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))

            if Self.showsRelaunch(returnedFromSettings: returnedFromSettings, state: state) {
                Button("Turned it on? Relaunch RoomForMac") {
                    relaunch()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.onboardingRelaunch)
            }
            if relaunchFailed {
                Text("RoomForMac couldn't relaunch itself. Quit it and open it again.")
                    .foregroundStyle(Palette.clay)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Without Full Disk Access:")
                        .foregroundStyle(Palette.text)
                    ForEach(Self.whyReasons.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                                .accessibilityHidden(true)
                            Text(Self.whyReasons[index])
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Why?")
                    .foregroundStyle(Palette.text)
            }
            .accessibilityIdentifier(AccessibilityID.onboardingWhy)
        }
        .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion) ?? .easeInOut(duration: 0.3), value: state.isGranted)
        .task {
            await permissions.poll(.fullDiskAccess)
        }
        .task(id: reduceMotion) {
            await loopSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await permissions.refresh(.fullDiskAccess)
                if openedSettings {
                    returnedFromSettings = true
                }
            }
        }
    }

    private func openSettings() {
        openedSettings = true
        Task {
            await permissions.request(.fullDiskAccess)
        }
    }

    private func relaunch() {
        do {
            try Relauncher.live().relaunch(at: Bundle.main.bundleURL)
        } catch {
            relaunchFailed = true
        }
    }

    /// Flips the illustrated switch every 1.6 s while the step is on screen.
    /// Under Reduce Motion the switch stays on and nothing loops.
    private func loopSwitch() async {
        guard !reduceMotion else {
            return
        }
        while true {
            do {
                try await Task.sleep(for: .seconds(1.6))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                switchOn.toggle()
            }
        }
    }
}

/// A System Settings row with RoomForMac's switch, as the user will see it.
/// Purely illustrative: it ignores clicks and VoiceOver skips it.
private struct SettingsSwitchIllustration: View {
    let isOn: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)
            Text("RoomForMac")
                .foregroundStyle(Palette.text)
            Spacer(minLength: 24)
            Toggle(isOn: .constant(isOn)) {
                Text("Full Disk Access")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Palette.action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
        .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the card turns into once access is on: a glass checkmark and an
/// "Allowed" chip. It keeps the card's identifiers, so UI tests find the same
/// card and chip before and after the grant.
private struct FullDiskAccessGrantedBadge: View {
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 14) {
            GlassEffectContainer {
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Palette.onAction)
                    .frame(width: 88, height: 88)
                    .morphingGlass(id: "fullDiskAccess.granted", in: namespace, shape: .circle, tint: Palette.action, interactive: false)
            }
            .accessibilityHidden(true)
            Text("Full Disk Access is on")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.text)
            PermissionChip(state: .granted)
                .accessibilityIdentifier(AccessibilityID.permissionChip(.fullDiskAccess))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.permissionCard(.fullDiskAccess))
    }
}
```

`AnyTransition(.blurReplace)` wraps the macOS 14 `BlurReplaceTransition`; `.blurReplace` alone does not type-check against `AnyTransition.opacity` in the ternary.

- [ ] **Step 11: Write the onboarding view** — `RoomForMac/Features/Onboarding/OnboardingView.swift`

```swift
import SwiftUI

/// The onboarding inside the main window (spec §6). One `OnboardingScaffold`
/// stays on screen for the whole flow; only the step content changes, over the
/// onboarding backdrop. The permissions come from `model.permissions`.
struct OnboardingView: View {
    private let model: AppModel
    private let flow: OnboardingFlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var welcomeFocus = 0.0
    @State private var wordmarkProgress = 0.0
    @State private var welcomeIntroPlayed = false
    @State private var isMoving = false

    init(model: AppModel, flow: OnboardingFlow) {
        self.model = model
        self.flow = flow
    }

    private var permissions: PermissionCenter {
        model.permissions
    }

    var body: some View {
        let primary = OnboardingPrimary.forStep(flow.step, fullDiskAccess: permissions.state(.fullDiskAccess))
        ZStack {
            BackdropView(
                scene: .onboarding,
                focus: OnboardingBackdrop.focus(step: flow.step, welcomeFocus: welcomeFocus, reduceMotion: reduceMotion)
            )
            .ignoresSafeArea()

            OnboardingScaffold(flow: flow, primaryTitle: primary.title, primaryAction: { perform(primary) }) {
                stepContent
                    .id(flow.step)
                    .transition(OnboardingMotion.stepTransition(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.onboardingStep(flow.step))
            }
            .primaryEnabled(primary.isEnabled && !isMoving)
        }
        .animation(OnboardingMotion.stepAnimation(reduceMotion: reduceMotion), value: flow.step)
        .task {
            await permissions.refreshAll()
        }
        .task(id: flow.step) {
            await playWelcomeIntroIfNeeded()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome:
            WelcomeStep(wordmarkProgress: reduceMotion ? 1 : wordmarkProgress)
        case .freeToExplore:
            FreeToExploreStep()
        case .moveToApplications:
            MoveToApplicationsStep(
                state: permissions.state(.moveToApplications),
                moveError: model.dependencies.appLocationChecker?.lastError
            )
        case .fullDiskAccess:
            FullDiskAccessStep(permissions: permissions)
        case .automation, .adminAccess, .extras, .ready:
            // Task 13 replaces these four with their screens.
            PendingStepContent()
        }
    }

    private func perform(_ primary: OnboardingPrimary) {
        switch primary {
        case .getStarted, .next:
            flow.next()
        case .moveAndRelaunch:
            isMoving = true
            Task {
                // A successful move relaunches the app from its new place and
                // never returns here; the new copy resumes after this step.
                await permissions.request(.moveToApplications)
                isMoving = false
                if permissions.state(.moveToApplications).isGranted {
                    flow.next()
                }
            }
        case .waitForFullDiskAccess:
            break
        case .startFirstScan:
            Task {
                await flow.finish { _ in }
                model.completeOnboarding(startFirstScan: true)
            }
        }
    }

    /// Welcome: the backdrop comes into focus, then softens while the wordmark
    /// draws. Plays once per launch, the first time Welcome is on screen. If the
    /// user moves on early, everything jumps to its final state.
    private func playWelcomeIntroIfNeeded() async {
        guard flow.step == .welcome, !welcomeIntroPlayed else {
            return
        }
        welcomeIntroPlayed = true
        guard !reduceMotion else {
            finishWelcomeIntro()
            return
        }
        withAnimation(.easeOut(duration: OnboardingBackdrop.revealDuration)) {
            welcomeFocus = 1
        }
        do {
            try await Task.sleep(for: .seconds(OnboardingBackdrop.revealDuration))
        } catch {
            finishWelcomeIntro()
            return
        }
        withAnimation(.easeInOut(duration: OnboardingBackdrop.softenDuration)) {
            welcomeFocus = OnboardingBackdrop.softenedFocus
        }
        withAnimation(.linear(duration: OnboardingBackdrop.wordmarkDuration)) {
            wordmarkProgress = 1
        }
    }

    private func finishWelcomeIntro() {
        welcomeFocus = OnboardingBackdrop.softenedFocus
        wordmarkProgress = 1
    }
}

/// What the scaffold's primary button says and does on each step.
enum OnboardingPrimary: Equatable, Sendable {
    /// Welcome: "Get started" → next step.
    case getStarted
    /// "Continue" → next step.
    case next
    /// Move to Applications: "Move and relaunch".
    case moveAndRelaunch
    /// Full Disk Access before the grant: "Continue", disabled. The card's
    /// "Open Settings" is the step's call to action, and Skip moves on without it.
    case waitForFullDiskAccess
    /// Ready: "Start first scan" → finish onboarding and open Smart Clean.
    case startFirstScan

    static func forStep(_ step: OnboardingStep, fullDiskAccess: PermissionState) -> OnboardingPrimary {
        switch step {
        case .welcome: .getStarted
        case .moveToApplications: .moveAndRelaunch
        case .fullDiskAccess: fullDiskAccess.isGranted ? .next : .waitForFullDiskAccess
        case .ready: .startFirstScan
        case .freeToExplore, .automation, .adminAccess, .extras: .next
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .getStarted: "Get started"
        case .next, .waitForFullDiskAccess: "Continue"
        case .moveAndRelaunch: "Move and relaunch"
        case .startFirstScan: "Start first scan"
        }
    }

    var isEnabled: Bool {
        self != .waitForFullDiskAccess
    }
}

/// How sharp the onboarding backdrop is (0 = fully blurred, 1 = sharp).
enum OnboardingBackdrop {
    /// Welcome's backdrop after it has come into focus and softened.
    static let softenedFocus = 0.3
    /// Blur → focus on Welcome, in seconds.
    static let revealDuration = 1.6
    /// Focus → softened on Welcome, in seconds.
    static let softenDuration = 0.8
    /// The wordmark's stroke-by-stroke draw, in seconds.
    static let wordmarkDuration = 2.0

    /// Welcome follows its intro (`welcomeFocus`); every other step is sharp.
    /// Under Reduce Motion the backdrop is sharp from the start and never animates.
    static func focus(step: OnboardingStep, welcomeFocus: Double, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return 1
        }
        return step == .welcome ? welcomeFocus : 1
    }
}

/// How the step content changes.
enum OnboardingMotion {
    /// A slide from the trailing edge with a fade; a plain crossfade under Reduce Motion.
    static func stepTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    static func stepAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.45, dampingFraction: 0.85)
    }
}

/// The content of the steps Task 13 builds (Finder & System Events, Admin
/// access, Extras, Ready). Until then they show only the scaffold.
private struct PendingStepContent: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}
```

`.animation(_:value: flow.step)` sits on the `ZStack`, so a step change also animates the backdrop's focus (0.3 → 1 when leaving Welcome). The intro's own `withAnimation` calls do not change `flow.step`, so that modifier leaves their 1.6 s and 2.0 s curves alone.

- [ ] **Step 12: Show onboarding from `RootView`**

In `RoomForMac/App/RootView.swift`, Task 7 shows a placeholder while the engine is ready and `model.isOnboarded` is false: a view carrying `AccessibilityID.onboardingPlaceholder` (`"onboarding.placeholder"`). Replace that placeholder, together with any private view that only wraps it, with:
```swift
if let flow = model.onboardingFlow {
    OnboardingView(model: model, flow: flow)
}
```
If `RootView` switches over a screen enum, as Task 7's does, this is the whole `.onboarding` case:
```swift
case .onboarding:
    if let flow = model.onboardingFlow {
        OnboardingView(model: model, flow: flow)
    }
```
Then delete `static let onboardingPlaceholder` (and its doc comment) from `AccessibilityID`, and any test expectation that names it.

Run: `grep -rn 'onboardingPlaceholder\|onboarding\.placeholder' RoomForMac RoomForMacTests`
Expected: no output.

- [ ] **Step 13: Run the onboarding tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingViewLogicTests -only-testing:RoomForMacTests/AppModelOnboardingTests -only-testing:RoomForMacTests/OnboardingRenderTests`
Expected: `✔ Test run with 17 tests in 3 suites passed`, then `** TEST SUCCEEDED **`. `chipNamesEveryState` and `permissionCardRendersEveryState` report 6 test cases each, `onboardingViewRendersInsideTheScaffold` 3 and `stepsRender` 2.

`ImageRenderer` draws AppKit-backed controls (the switch in the illustration, the disclosure triangle) as a yellow "unavailable" box, and draws nothing for a `ScrollView`. That is why `stepsRender` renders each step view on its own. Neither affects the app.

- [ ] **Step 14: Run the whole unit scheme**

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-12.log" | tail -n 20
grep -E '(Features/Onboarding/|Features/Permissions/PermissionCard|App/(AppModel|AppDependencies|RootView|AccessibilityID)).*(warning|error):' "$TMPDIR/rfm-task-12.log"
```
Expected: the log ends with `** TEST SUCCEEDED **`, and the `grep` prints nothing. Task 7's `AppModelTests` still build their `AppDependencies` with three arguments; the new properties take their defaults.

- [ ] **Step 15: Sync the String Catalog**

Run:
```bash
OBJROOT=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null | awk '$1 == "OBJROOT" { print $3; exit }')
find "$OBJROOT" -path '*/RoomForMac.build/Objects-normal/*' -name '*.stringsdata' \
    -exec xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --stringsdata {} +
git diff --stat RoomForMac/Resources/Localizable.xcstrings
```
Expected: `xcstringstool` prints nothing and exits 0. The diff adds these 34 keys. `Full Disk Access`, which this step's views also use, is already there from Task 8:
`1 GB of free cleanup, once`, `Allowed`, `Applications`, `Back`, `Continue`, `Denied`, `Drag RoomForMac into your Applications folder, then open it from there.`, `Full Disk Access is on`, `Get started`, `Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.`, `Move RoomForMac to Applications`, `Move and relaunch`, `Needs approval`, `No account, no card.`, `Not needed`, `Not yet`, `Open Settings`, `Reveal in Finder`, `RoomForMac couldn't move itself.`, `RoomForMac couldn't relaunch itself. Quit it and open it again.`, `RoomForMac moving into the Applications folder`, `RoomForMac works best from your Applications folder. One click moves it there and opens it again.`, `Scans can't see caches, logs and leftovers in protected folders, so they find less than there is.`, `Skip`, `Some apps can't be moved to the Trash when you uninstall them.`, `Start first scan`, `Turned it on? Relaunch RoomForMac`, `Unknown`, `Unlimited scans and previews`, `Upgrade once for unlimited cleanup — every future version included.`, `Why?`, `Without Full Disk Access:`, `Your Trash shows as empty, even when it isn't.`, `macOS asks separately before RoomForMac looks in Downloads or at other apps' data.`.

The placeholder's text from Task 7 leaves the catalog, since no source uses it any more and it has no translations. Every other earlier key stays, including Task 10's four move-error sentences, which the Move step shows through `localizedDescription` and does not repeat. `sync` matches a table to its file by name, so always point it at `Localizable.xcstrings` itself, never at a copy with another name. A copy with another name ends up with no keys at all.

- [ ] **Step 16: Look at the flow (visual check, not a gate)**

Run:
```bash
APP="$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/RoomForMac.app"
open -n "$APP" --args -RFMUITestScenario onboarding
```
The `onboarding` scenario uses its own wiped UserDefaults suite and, until Task 15, no permission checkers, so nothing touches the real preferences or permissions. Check:
- Welcome: the backdrop comes into focus, the wordmark draws, and "Get started" works.
- The current dot slides as a capsule from step to step.
- Free to explore: the meter fills.
- Full Disk Access: the switch row flips, "Why?" opens, and "Continue" is greyed out ("Open Settings" does nothing without a checker). Use Skip.
- The four Task 13 steps are empty. On Ready, "Start first scan" lands on the Smart Clean placeholder.

Then run `pkill -x RoomForMac`.

- [ ] **Step 17: Commit**

```bash
git add RoomForMac/Features/Onboarding/OnboardingView.swift RoomForMac/Features/Onboarding/OnboardingScaffold.swift \
    RoomForMac/Features/Onboarding/Steps/WelcomeStep.swift RoomForMac/Features/Onboarding/Steps/FreeToExploreStep.swift \
    RoomForMac/Features/Onboarding/Steps/MoveToApplicationsStep.swift RoomForMac/Features/Onboarding/Steps/FullDiskAccessStep.swift \
    RoomForMac/Features/Permissions/PermissionCard.swift \
    RoomForMac/App/RootView.swift RoomForMac/App/AppDependencies.swift RoomForMac/App/AppModel.swift \
    RoomForMac/App/AccessibilityID.swift RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/OnboardingViewTests.swift
git add -u RoomForMacTests   # a Task 7 test edited in Step 12, if any
git status --short           # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'EOF'
feat(app): onboarding scaffold, first four screens and permission cards

OnboardingView keeps one scaffold (dots, Back, Skip, primary button) on
screen and swaps only the step content: Welcome with the focus pull and
wordmark draw, Free to explore with the 1 GB meter, Move to Applications
with the mover's own failure sentences, and Full Disk Access with
polling, the relaunch link and a "Why?" disclosure. PermissionCard and
PermissionChip show each approval's state in token colours.
AppDependencies wires the live checkers, taking the DEBUG Move-step
bypass from AppLocationChecker, and AppModel owns the PermissionCenter
and the resumable OnboardingFlow.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 13: Onboarding UI, part 2 — Automation, Admin access, Extras, Ready

**Files:**
- Create: `RoomForMac/Features/Onboarding/Steps/AutomationStep.swift`, `Steps/AdminAccessStep.swift`, `Steps/ExtrasStep.swift`, `Steps/ReadyStep.swift`, `RoomForMacTests/OnboardingFinishTests.swift`
- Create (added; test support that Task 14 reuses): `RoomForMacTests/Support/FakeLoginService.swift`
- Modify: `RoomForMac/Features/Onboarding/OnboardingView.swift`, `RoomForMac/App/AccessibilityID.swift`
- Modify (added): `RoomForMac/Features/Onboarding/OnboardingScaffold.swift` (one internal modifier; see the Interface issue), `RoomForMac/Resources/Localizable.xcstrings` (the new keys, synced in Step 16)

**Interfaces:**
- Consumes: Task 12's scaffold, `PermissionCard`, `PermissionChip` and `OnboardingView`; `OnboardingFlow.finish`, `summary` and `choices` (Task 11); `AppModel.completeOnboarding` (Task 7).
  - Also, by name:
    - `PermissionCenter.state`, `hasChecker`, `refresh`, `refreshAll` and `request`; `PermissionID`, `PermissionState`, `PermissionChecking` (Task 8).
    - `LoginItemChecker` (`init(status:register:unregister:openLoginItemsSettings:)`, `currentState`, `request`, `disable`) and `AutomationChecker.Target.applicationURL` (Task 9).
    - `OnboardingChoices`, `PermissionSummaryItem`, `OnboardingStep` (Task 11).
    - `AppModel.permissions`, `onboardingFlow`, `dependencies`, `isOnboarded`, `pendingFirstScan` and `selection`, and the `AppDependencies` memberwise initializer with `permissionCheckers`, `needsMoveStep` and `loginItem` (Tasks 7 and 12).
    - Task 12's internal `OnboardingScaffold.primaryEnabled(_:)` and `OnboardingPrimary`.
    - `GlassButton`, `GlassCard`, `morphingGlass`, and Task 5's internal `View.glassSurface(_:in:)`, `GlassSurfacePolicy` and `GlassHover`; the test support `RenderCheck.image(of:scheme:size:)` (Task 5).
    - The test support `TemporaryDefaults` (Task 7, `RoomForMacTests/Support`).
    - `Palette`, `Typography`, `Motion` (Task 4).
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
- Internal to this task (the tests and `OnboardingView` use them; no other task depends on them):
  ```swift
  extension OnboardingApply {                                  // in OnboardingView.swift, next to Task 12's OnboardingPrimary
      static func isRegistered(_ state: PermissionState) -> Bool    // .granted or .requiresApproval
      @MainActor static func isInstalled(_ permissions: PermissionCenter) -> Bool
      // no .moveToApplications checker, or its state isGranted (.granted, or .notApplicable under DEBUG's bypass)
      @MainActor static func finish(flow: OnboardingFlow, model: AppModel, startFirstScan: Bool) async
      // await flow.finish { await apply($0, permissions: model.permissions, loginItem: model.dependencies.loginItem) },
      // then model.completeOnboarding(startFirstScan:)
  }
  extension OnboardingScaffold { func primaryHidden(_ hidden: Bool) -> Self }   // see the Interface issue
  extension OnboardingView {                                   // Task 12's init(model:flow:) is unchanged
      func automationIcons(_ icon: @escaping @MainActor (URL) -> NSImage) -> Self   // passed on to AutomationStep.targetIcon
  }
  struct AutomationStep: View {                                // memberwise init(permissions:targetIcon:), targetIcon defaulted
      let permissions: PermissionCenter
      var targetIcon: @MainActor (URL) -> NSImage = AutomationStep.workspaceIcon   // tests inject a stand-in
      static func workspaceIcon(_ url: URL) -> NSImage               // NSWorkspace.shared.icon(forFile: url.path)
      enum CardAction: Equatable, Sendable { case allow, openSettings; var title: LocalizedStringKey { get } }   // "Allow" / "Open Settings"
      static let permissionIDs: [PermissionID]                       // [.automationFinder, .automationSystemEvents]
      static func displayState(_ state: PermissionState) -> PermissionState   // .unknown(_) → .notDetermined, others unchanged
      static func action(for state: PermissionState) -> CardAction           // .denied → .openSettings, else .allow
      static func title(for id: PermissionID) -> LocalizedStringKey          // "Finder" / "System Events"
      static func reason(for id: PermissionID) -> LocalizedStringKey         // the Ruling 10 reasons, verbatim
  }
  struct AdminAccessStep: View { init() }
  struct ExtrasStep: View {                                    // memberwise init(flow:)
      @Bindable var flow: OnboardingFlow
      static let collectedData: [LocalizedStringResource]            // "What we collect", seven lines
  }
  struct ReadyStep: View {
      init(flow: OnboardingFlow, permissions: PermissionCenter, isFinishing: Bool,
           startFirstScan: @escaping @MainActor () -> Void, notNow: @escaping @MainActor () -> Void)
      static let startGlassID: String                                // "onboarding.startFirstScan"
      static func rows(_ items: [PermissionSummaryItem], columns: Int = 2) -> [[PermissionSummaryItem]]
      static func notes(choices: OnboardingChoices, notifications: PermissionState, launchAtLogin: PermissionState,
                        isInstalled: Bool) -> [LocalizedStringResource]
  }
  struct ReadySummaryChip: View {                              // memberwise init(item:)
      let item: PermissionSummaryItem
      static func stateLabel(granted: Bool) -> LocalizedStringResource   // "Allowed" / "Not yet"
      static func systemImage(granted: Bool) -> String                   // "checkmark.circle.fill" / "circle.fill"
  }
  extension AccessibilityID {
      static let extrasWhatWeCollect = "onboarding.extras.whatWeCollect"
      static let readyNotNow = "onboarding.ready.notNow"
  }
  ```
  `OnboardingApply.apply` stays `nonisolated`, as declared: it awaits the main-actor `PermissionCenter`, which is `Sendable`, and calls the `Sendable` `LoginItemChecker` off the main actor. `finish` is `@MainActor`, because it reads `AppModel` and calls `OnboardingFlow`. `isInstalled` is `@MainActor` because it reads the center; `apply` awaits it, and `ReadyStep` calls it from `body`.
- Test support added by this task, which Task 14's Settings tests reuse:
  ```swift
  // RoomForMacTests/Support/FakeLoginService.swift
  final class FakeLoginService: Sendable {       // an in-memory SMAppService.mainApp; every call is logged
      enum Call: Equatable, Sendable { case register, unregister, openSettings }
      init(_ status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled)
      var calls: [Call] { get }
      var checker: LoginItemChecker { get }       // a real LoginItemChecker whose system calls land here
  }
  ```

**Interface issue:** Ready cannot show both its own **Start first scan** and the scaffold's primary button. The requirement (and Ruling 5) makes Start first scan `morphingGlass`, which `GlassButton` cannot be, and Task 15 presses `readyStartScan`, not `onboarding.primary`, on Ready. Task 12's scaffold always draws its primary button, and Task 12 already puts "Start first scan" there. Task 12 lists `OnboardingScaffold.primaryEnabled(_:)` as internal and says "Task 13 extends the first three", but `OnboardingScaffold.swift` is not in this task's Files. Smallest fix, taken here: this task also modifies `OnboardingScaffold.swift` to add an internal `func primaryHidden(_ hidden: Bool) -> Self` next to `primaryEnabled(_:)` (Step 12). `OnboardingView` hides the primary on Ready. Nothing else in the scaffold changes. Task 12's `OnboardingPrimary.startFirstScan` stays and still names Ready's action, but it is never drawn now. Its `perform` branch routes to the same finish as Ready's button (Step 13).

**Interface issue:** The skeleton's comment on `OnboardingApply.apply` says "launchAtLogin on → permissions.request(.launchAtLogin)". Research §1.4 says to register a login item only once the app is in /Applications, and the Move step can be skipped. So this task requests the login item only when `OnboardingApply.isInstalled(permissions)` holds after a fresh `permissions.refresh(.moveToApplications)`. That means the Move state is `.granted`, or `.notApplicable` under DEBUG's bypass, or there is no Move checker. The signature does not change. Task 15 is the only other caller, and it scripts Move as `.notApplicable`, so it still sees the login item requested. The skeleton comment should read "launchAtLogin on → permissions.request(.launchAtLogin) once the app is installed".

**Requirements:**
- **Finder & System Events** (spec §6 screen 5): two `PermissionCard`s under a heading, with the reasons from Ruling 10, verbatim:
  - Finder: "Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails."
  - System Events: "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall."

  Each "Allow" calls `permissions.request(id)` at that moment. The card's button is disabled until that request returns, which can take up to Task 9's 120 s prompt deadline.
  - **Chips (tightened):** Allowed / Not yet / Denied. A passive check of System Events answers `.unknown("not running")` whenever it is not running (research §1.2), and `PermissionCenter` then shows the last known state. With none stored yet, the card shows `.notDetermined` ("Not yet") rather than "Unknown", through `AutomationStep.displayState`.
  - **Denied:** the button reads "Open Settings" and calls the same `request`. macOS answers "denied" without prompting again, and Task 9's checker then opens `SystemSettingsLink.automation`.
  - The step refreshes both states when it appears and on `NSApplication.didBecomeActiveNotification`. That covers coming back from the prompt or from System Settings. Both checks run at once, so a hung check of one never delays the other.
  - An illustration shows RoomForMac's icon linked to Finder's and System Events' icons, with a pulsing link symbol that stays still under Reduce Motion. VoiceOver skips it.
  - Finder's and System Events' icons come from `AutomationStep.targetIcon`, a stored closure whose default, `AutomationStep.workspaceIcon`, calls `NSWorkspace.shared.icon(forFile:)`. `OnboardingView` passes its own copy of that closure, which the internal `automationIcons(_:)` replaces. The render tests pass a stand-in to both, so the unit tests never call `NSWorkspace` (Global Constraints).
- **Admin access** (screen 6):
  - The illustration is built from SF Symbols: `lock.shield` in a 112 pt glass circle, through `glassSurface`, so it becomes solid `surface` under Reduce Transparency. The symbol breathes, and stays still under Reduce Motion.
  - There is no password field anywhere, and nothing is requested.
  - Copy, verbatim: "RoomForMac only asks for your password when you pick system-level items, and macOS draws that prompt, never us. Nothing is requested now." Then: "System-level items arrive in a later update." (Admin is Plan 7.)
- **Extras** (screen 7):
  - Three switches bound to `flow.choices`, labels on the leading edge and switches trailing, tinted `action`:
    - "Notify me when a cleanup finishes" (`notifications`, identifier `extrasNotifications`);
    - "Open RoomForMac at login" (`launchAtLogin`, `extrasLaunchAtLogin`);
    - "Share anonymous usage data" (`analytics`, `extrasAnalytics`, on by default from Task 11), with the one-line description "Counts and sizes in ranges. Never file names, paths or app names."
  - A "What we collect" disclosure (`extrasWhatWeCollect`) lists the §8 events in plain words, one bullet each, with no event names: setup finished and which approvals were given; scan finished; cleanup finished or failed; allowance, upgrade screen, checkout and purchase; license activation; the properties sent with every event; the random install ID.
  - The switches only record choices. Nothing is asked of macOS until the user leaves Ready.
- **Ready** (screen 8):
  - **Summary chips** come from `flow.summary()`, two to a row, as glass capsules. A granted item shows ✓ (`checkmark.circle.fill` in `moss`), anything else • (`circle.fill` in `textSecondary`). VoiceOver reads the title, then "Allowed" or "Not yet" as the value. Each chip carries `summaryChip(id)`. The step calls `permissions.refreshAll()` when it appears, so approvals changed in System Settings since their step show correctly.
  - **Notes (tightened):** when a chosen extra is not on yet, a caption says what happens next:
    - "macOS asks whether RoomForMac may send notifications when you continue."
    - "RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings."
    - In place of the second note, when the app is not in an Applications folder (`OnboardingApply.isInstalled` is false): "RoomForMac can open at login once it is in your Applications folder."

    Without them, a chosen extra would show • with no explanation.
  - **Start first scan** is a `.plain` button whose label is `morphingGlass` capsule glass in the `action` tint, with `onAction` text. It sits in its own `GlassEffectContainer` and carries `readyStartScan` and `.keyboardShortcut(.defaultAction)`. Hover scales it through `GlassHover`.
    - When pressed, it morphs, under the same glass ID `ReadyStep.startGlassID`, into a 52 pt progress circle while the choices are applied, which may mean waiting on the notification prompt. Under Reduce Motion the change is a `.materialize` crossfade, through `morphingGlass`.
  - **"Not now"** is a secondary `GlassButton` (`readyNotNow`).
  - Both buttons go through `OnboardingApply.finish(flow:model:startFirstScan:)`, with `true` and `false`. It runs `await flow.finish { await OnboardingApply.apply($0, permissions: model.permissions, loginItem: model.dependencies.loginItem) }` and then `model.completeOnboarding(startFirstScan:)`.
  - `OnboardingView` lets the first press win: it sets `isFinishing`, which disables the scaffold (Back included) and both buttons until `AppModel` hands the window to the main view.
  - The scaffold's primary button is hidden on Ready; Back and the dots stay.
  - The spec's "morphs directly into the Smart Clean scan" needs Plan 3's Scan button. Here the main view replaces onboarding, and `pendingFirstScan` hands over the request.
- **`OnboardingApply.apply`:**
  - Notifications on → `permissions.request(.notifications)`. Off → nothing: an app cannot revoke its own notification permission, and Task 11's `finish` stores `notificationsWanted = false`.
  - Open at login on → `permissions.request(.launchAtLogin)`. Task 9's checker registers the app, and opens Login Items when macOS wants approval.
    - **Only once the app is installed** (research §1.4). The Move step can be skipped. A login item registered from Downloads or from a translocated read-only copy points at a path that is gone after the next relaunch, while the switch looks on. So `apply` first runs `permissions.refresh(.moveToApplications)`, then requests only when `isInstalled(permissions)` holds: there is no Move checker, or its state `isGranted` (`.granted`, or `.notApplicable` under DEBUG's bypass). Otherwise it asks nothing, and Ready's note has already said why.
    - It refreshes the Move state itself. When the app is already installed, the Move step never ran, and Ready's `refreshAll()` may still be running when the button is pressed. Without the refresh, the center would still report `.notDetermined`, and an installed copy would skip its login item.
  - Open at login off → `loginItem.disable()` when the login item's own `currentState()` is `.granted` or, **tightened**, `.requiresApproval`. An app waiting for approval would still open at login once approved, which the user just declined. Then `permissions.refresh(.launchAtLogin)`.
    - The login item is asked directly, not `PermissionCenter`, which may not have checked it yet in this launch.
    - A nil `loginItem` does nothing.
- **`OnboardingView`** shows the four screens in place of Task 12's `PendingStepContent`, which is deleted. The `.startFirstScan` primary routes to the same finish.
- **`OnboardingScaffold.primaryHidden(true)`** leaves out the primary button only.
- Nothing in this task uses `.buttonStyle(.glass(_:))`, `GlassButtonStyle(_:)`, `@ContentBuilder`, or any API newer than macOS 26.0. The newest APIs used are `symbolEffect(.breathe)` (macOS 15), `withDiscardingTaskGroup` (macOS 14) and, in the tests, `Mutex` (macOS 15).
- Every user-facing string is a literal `Text`/`LocalizedStringKey`/`LocalizedStringResource`, with no concatenation. The 28 new keys are listed in Step 16.
- Tests (`OnboardingFinishTests.swift`, 24 tests in 2 suites, Swift Testing, `@MainActor`, no real notification, login item, Apple event or System Settings call):
  - **`OnboardingApply`**, with a counting fake checker and a real `LoginItemChecker` over a fake `SMAppService`:
    - notifications are requested only when chosen;
    - the login item is registered when chosen, and Login Items opens when it needs approval;
    - it is registered only once the app is installed: not while the Move state is `.notDetermined` or `.denied`, and yes for `.granted` or DEBUG's `.notApplicable`, read fresh even when the center never checked it;
    - it is unregistered when not chosen and it is enabled or waiting for approval, even if the center never checked it;
    - it is left alone when not registered, or when there is no `loginItem`;
    - `isRegistered` for every state.
  - **The finish path:**
    - Start first scan applies the choices and persists completion, the analytics and notification choices, and a cleared step;
    - `AppModel.isOnboarded` becomes true, `onboardingFlow` becomes nil, `pendingFirstScan` is set and `selection == .smartClean`;
    - "Not now" completes without a first scan and requests nothing;
    - a relaunched `AppModel` over the same preferences is onboarded, with no flow.
  - **The screens:**
    - the Automation card action and display state for every state, the titles, and the exact reasons;
    - "What we collect" has seven plain-word lines;
    - the Ready chip labels and symbols, rows of two, and the notes, including the one for a copy outside Applications;
    - the identifier strings;
    - each screen renders through `ImageRenderer` in light and dark (Ready also while finishing), with a stand-in `targetIcon` for Automation;
    - `OnboardingView` renders on each of the four steps.
  - `RecordingChecker` is nested in `OnboardingFinishTests`, so its name cannot clash with the helpers of Tasks 8, 11 and 12. `FakeLoginService`, the in-memory `SMAppService`, is test support in `RoomForMacTests/Support/FakeLoginService.swift`, because Task 14's Settings tests drive the login item through it too. Both suites keep Task 7's `TemporaryDefaults` in a stored property.

- [ ] **Step 1: Write the test support and the failing finish tests**

`RoomForMacTests/Support/FakeLoginService.swift` (Task 14's Settings tests use it too)
```swift
import ServiceManagement
import Synchronization
@testable import RoomForMac

/// Stands in for `SMAppService.mainApp`: register turns the status on (or
/// to `statusAfterRegister`), unregister turns it off, and every call is logged.
/// Tests drive a real `LoginItemChecker` through it, so none registers the test host.
final class FakeLoginService: Sendable {
    enum Call: Equatable, Sendable {
        case register, unregister, openSettings
    }

    private let statusAfterRegister: SMAppService.Status
    private let store: Mutex<(status: SMAppService.Status, calls: [Call])>

    init(_ status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled) {
        self.statusAfterRegister = statusAfterRegister
        store = Mutex((status: status, calls: []))
    }

    var calls: [Call] {
        store.withLock { $0.calls }
    }

    /// A real `LoginItemChecker` whose system calls land here.
    var checker: LoginItemChecker {
        LoginItemChecker(
            status: { self.store.withLock { $0.status } },
            register: {
                self.store.withLock { value in
                    value.calls.append(.register)
                    value.status = self.statusAfterRegister
                }
            },
            unregister: {
                self.store.withLock { value in
                    value.calls.append(.unregister)
                    value.status = .notRegistered
                }
            },
            openLoginItemsSettings: {
                self.store.withLock { $0.calls.append(.openSettings) }
            }
        )
    }
}
```

`RoomForMacTests/OnboardingFinishTests.swift`
```swift
import Foundation
import ServiceManagement
import SwiftUI
import Synchronization
import Testing
@testable import RoomForMac

@MainActor
@Suite("Onboarding finish")
struct OnboardingFinishTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    /// A fresh view of the same suite, the way a relaunched app would read it.
    private var preferences: AppPreferences { temporary.preferences }

    private func makeModel(checkers: [any PermissionChecking] = [], loginItem: LoginItemChecker? = nil) -> AppModel {
        AppModel(dependencies: AppDependencies(
            preferences: preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: loginItem
        ))
    }

    // MARK: Notifications

    @Test func notificationsAreRequestedOnlyWhenChosen() async {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let center = PermissionCenter(checkers: [notifications])

        await OnboardingApply.apply(OnboardingChoices(notifications: false), permissions: center, loginItem: nil)
        #expect(notifications.requests == 0)

        await OnboardingApply.apply(OnboardingChoices(notifications: true), permissions: center, loginItem: nil)
        #expect(notifications.requests == 1)
        #expect(center.state(.notifications) == .granted)
    }

    // MARK: Open at login

    @Test func theLoginItemIsRegisteredWhenChosen() async {
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.register])
        #expect(center.state(.launchAtLogin) == .granted)
    }

    @Test func aLoginItemThatNeedsApprovalOpensLoginItemsSettings() async {
        let service = FakeLoginService(.notRegistered, statusAfterRegister: .requiresApproval)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.register, .openSettings])
        #expect(center.state(.launchAtLogin) == .requiresApproval)
    }

    @Test(arguments: [PermissionState.notDetermined, .denied])
    func theLoginItemWaitsUntilTheAppIsInstalled(_ move: PermissionState) async {
        let location = RecordingChecker(id: .moveToApplications, current: move, afterRequest: move)
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [location, loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(service.calls.isEmpty)
        #expect(location.requests == 0)
        #expect(center.state(.launchAtLogin) == .notDetermined)
    }

    @Test(arguments: [PermissionState.granted, .notApplicable])
    func anInstalledAppRegistersItsLoginItem(_ move: PermissionState) async {
        let location = RecordingChecker(id: .moveToApplications, current: move, afterRequest: move)
        let service = FakeLoginService(.notRegistered)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [location, loginItem])
        #expect(center.state(.moveToApplications) == .notDetermined)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: true), permissions: center, loginItem: loginItem)

        #expect(center.state(.moveToApplications) == move)
        #expect(service.calls == [.register])
        #expect(center.state(.launchAtLogin) == .granted)
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func aRegisteredLoginItemIsUnregisteredWhenNotChosen(_ status: SMAppService.Status) async {
        let service = FakeLoginService(status)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])
        await center.refresh(.launchAtLogin)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.unregister])
        #expect(center.state(.launchAtLogin) == .notDetermined)
    }

    @Test func theLoginItemIsAskedDirectlyWhenTheCenterHasNotCheckedIt() async {
        let service = FakeLoginService(.enabled)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])
        #expect(center.state(.launchAtLogin) == .notDetermined)

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls == [.unregister])
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func anUnregisteredLoginItemIsLeftAlone(_ status: SMAppService.Status) async {
        let service = FakeLoginService(status)
        let loginItem = service.checker
        let center = PermissionCenter(checkers: [loginItem])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: loginItem)

        #expect(service.calls.isEmpty)
    }

    @Test func withoutALoginItemNothingIsUnregistered() async {
        let service = FakeLoginService(.enabled)
        let center = PermissionCenter(checkers: [service.checker])

        await OnboardingApply.apply(OnboardingChoices(launchAtLogin: false), permissions: center, loginItem: nil)

        #expect(service.calls.isEmpty)
    }

    @Test func registeredMeansOnOrWaitingForApproval() {
        #expect(OnboardingApply.isRegistered(.granted))
        #expect(OnboardingApply.isRegistered(.requiresApproval))
        for state in [PermissionState.notDetermined, .denied, .unknown("unavailable in this build"), .notApplicable] {
            #expect(!OnboardingApply.isRegistered(state))
        }
    }

    // MARK: The finish path

    @Test func startFirstScanAppliesTheChoicesAndCompletesOnboarding() async throws {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let service = FakeLoginService(.notRegistered)
        let model = makeModel(checkers: [notifications, service.checker], loginItem: service.checker)
        let flow = try #require(model.onboardingFlow)
        for _ in flow.steps.dropFirst() {
            flow.next()
        }
        #expect(flow.step == .ready)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        flow.choices.analytics = false
        model.selection = .status

        await OnboardingApply.finish(flow: flow, model: model, startFirstScan: true)

        #expect(notifications.requests == 1)
        #expect(service.calls == [.register])
        #expect(model.isOnboarded)
        #expect(model.onboardingFlow == nil)
        #expect(model.pendingFirstScan)
        #expect(model.selection == .smartClean)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.onboardingStep == nil)
        #expect(preferences.analyticsEnabled == false)
        #expect(preferences.notificationsWanted)
    }

    @Test func notNowCompletesOnboardingWithoutAFirstScan() async throws {
        let notifications = RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted)
        let model = makeModel(checkers: [notifications])
        let flow = try #require(model.onboardingFlow)

        await OnboardingApply.finish(flow: flow, model: model, startFirstScan: false)

        #expect(notifications.requests == 0)
        #expect(model.isOnboarded)
        #expect(!model.pendingFirstScan)
        #expect(model.selection == .smartClean)
        #expect(preferences.onboardingCompleted)
        #expect(preferences.analyticsEnabled)
        #expect(!preferences.notificationsWanted)
    }

    @Test func aRelaunchAfterFinishingSkipsOnboarding() async throws {
        let first = makeModel()
        await OnboardingApply.finish(flow: try #require(first.onboardingFlow), model: first, startFirstScan: true)

        let relaunched = makeModel()

        #expect(relaunched.isOnboarded)
        #expect(relaunched.onboardingFlow == nil)
        #expect(!relaunched.pendingFirstScan)
    }
}

// Nested, so its name cannot clash with helpers in other test files.
extension OnboardingFinishTests {
    /// A checker with one state that a request replaces. It counts requests and never prompts.
    final class RecordingChecker: PermissionChecking {
        let id: PermissionID
        private let afterRequest: PermissionState
        private let store: Mutex<(state: PermissionState, requests: Int)>

        init(id: PermissionID, current: PermissionState, afterRequest: PermissionState) {
            self.id = id
            self.afterRequest = afterRequest
            store = Mutex((state: current, requests: 0))
        }

        var requests: Int {
            store.withLock { $0.requests }
        }

        func currentState() async -> PermissionState {
            store.withLock { $0.state }
        }

        func request() async -> PermissionState {
            store.withLock { value in
                value.requests += 1
                value.state = afterRequest
                return value.state
            }
        }
    }
}
```

`RecordingChecker` and `FakeLoginService` keep their state in a `Mutex` (the `Synchronization` module), so they stay `Sendable` for the checker protocol and the `@Sendable` closures of `LoginItemChecker`. `FakeLoginService` sits in `RoomForMacTests/Support` because Task 14's Settings tests reuse it. The suite keeps Task 7's `TemporaryDefaults` in a stored property, and nothing here writes to `UserDefaults.standard`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingFinishTests`
Expected: `** TEST FAILED **`, because the test target does not compile. There are 16 errors of one kind, the first being `RoomForMacTests/OnboardingFinishTests.swift:37:15: error: cannot find 'OnboardingApply' in scope`.

- [ ] **Step 3: Write `OnboardingApply`**

The skeleton gives it no file of its own, so it lives in `OnboardingView.swift`, next to Task 12's `OnboardingPrimary`, `OnboardingBackdrop` and `OnboardingMotion`. Append to the end of `RoomForMac/Features/Onboarding/OnboardingView.swift`, after `PendingStepContent`, which Step 13 deletes:
```swift
/// Applies the Extras choices when onboarding ends. The Extras screen only
/// records them; this is the one place that asks macOS, from Ready.
enum OnboardingApply {
    /// Applies Extras choices: requests notifications if chosen; registers or unregisters the login item.
    ///
    /// - Notifications on: `permissions.request(.notifications)`, which shows the
    ///   system prompt the first time. Off: nothing, since an app cannot revoke
    ///   its own notification permission; `notificationsWanted` (written by
    ///   `OnboardingFlow.finish`) keeps Plan 3 from posting.
    /// - Open at login on: once the app is in an Applications folder,
    ///   `permissions.request(.launchAtLogin)`, which registers the app and
    ///   opens Login Items when macOS wants approval. From anywhere else
    ///   (a skipped Move step) nothing is registered: the login item would
    ///   point at a copy in Downloads or a translocated path that is gone after
    ///   a relaunch (research §1.4). Ready's note has said so.
    /// - Open at login off: when the login item itself reports that it is
    ///   registered (on, or waiting for approval), `loginItem.disable()`, then a
    ///   refresh so `PermissionCenter` shows the result. The login item is asked
    ///   directly, because the center may not have checked it yet this launch.
    static func apply(_ choices: OnboardingChoices, permissions: PermissionCenter, loginItem: LoginItemChecker?) async {
        if choices.notifications {
            await permissions.request(.notifications)
        }
        if choices.launchAtLogin {
            // Checked here, not trusted from earlier: an installed copy never
            // showed the Move step, and Ready's refreshAll() may still be running.
            await permissions.refresh(.moveToApplications)
            if await isInstalled(permissions) {
                await permissions.request(.launchAtLogin)
            }
            return
        }
        guard let loginItem else {
            return
        }
        if isRegistered(await loginItem.currentState()) {
            _ = await loginItem.disable()
            await permissions.refresh(.launchAtLogin)
        }
    }

    /// A login item that is on, or registered and waiting for approval in
    /// System Settings. Either would open RoomForMac at login once approved.
    static func isRegistered(_ state: PermissionState) -> Bool {
        state == .granted || state == .requiresApproval
    }

    /// Whether this copy of the app is where a login item may point: in an
    /// Applications folder (`.granted`), or a DEBUG build whose Move checker is
    /// bypassed (`.notApplicable`). Without a Move checker, as in most unit
    /// tests, there is nothing to wait for.
    @MainActor
    static func isInstalled(_ permissions: PermissionCenter) -> Bool {
        !permissions.hasChecker(.moveToApplications) || permissions.state(.moveToApplications).isGranted
    }

    /// What Ready's two buttons do: `flow.finish` applies the choices once and
    /// records completion, then the main window takes over from onboarding.
    @MainActor
    static func finish(flow: OnboardingFlow, model: AppModel, startFirstScan: Bool) async {
        let permissions = model.permissions
        let loginItem = model.dependencies.loginItem
        await flow.finish { choices in
            await apply(choices, permissions: permissions, loginItem: loginItem)
        }
        model.completeOnboarding(startFirstScan: startFirstScan)
    }
}
```

`apply` takes the `choices` snapshot that Task 11's `finish` passes in, so a switch flipped while the notification prompt is up changes nothing. `refresh(.moveToApplications)` does nothing when there is no Move checker, and Task 10's `AppLocationChecker.currentState()` only classifies the bundle's location, so the check is instant. `finish` copies `model.permissions` and `model.dependencies.loginItem` into locals before the closure, which runs on the main actor.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingFinishTests`
Expected: `✔ Test run with 13 tests in 1 suite passed`, then `** TEST SUCCEEDED **`. `theLoginItemWaitsUntilTheAppIsInstalled(_:)`, `anInstalledAppRegistersItsLoginItem(_:)`, `aRegisteredLoginItemIsUnregisteredWhenNotChosen(_:)` and `anUnregisteredLoginItemIsLeftAlone(_:)` report 2 test cases each.

- [ ] **Step 5: Write the failing screen tests**

Append to the end of `RoomForMacTests/OnboardingFinishTests.swift`, after the closing brace of the helper extension, with one blank line between:
```swift
@MainActor
@Suite("Onboarding steps, part 2")
struct OnboardingPartTwoStepTests {
    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    // MARK: Finder & System Events

    @Test(arguments: [PermissionState.notDetermined, .unknown("not running"), .requiresApproval, .granted, .notApplicable])
    func automationCardsAskUntilDenied(_ state: PermissionState) {
        #expect(AutomationStep.action(for: state) == .allow)
    }

    @Test func automationCardsShowAllowedNotYetOrDenied() {
        #expect(AutomationStep.displayState(.unknown("not running")) == .notDetermined)
        #expect(AutomationStep.displayState(.unknown("timed out")) == .notDetermined)
        for state in [PermissionState.granted, .denied, .notDetermined] {
            #expect(AutomationStep.displayState(state) == state)
        }
    }

    @Test func aDeniedAutomationCardOpensSettings() {
        #expect(AutomationStep.action(for: .denied) == .openSettings)
        #expect(AutomationStep.CardAction.allow.title == "Allow")
        #expect(AutomationStep.CardAction.openSettings.title == "Open Settings")
    }

    @Test func automationCardsFollowTheEnginesRealUse() {
        #expect(AutomationStep.permissionIDs == [.automationFinder, .automationSystemEvents])
        #expect(AutomationStep.title(for: .automationFinder) == "Finder")
        #expect(AutomationStep.title(for: .automationSystemEvents) == "System Events")
        #expect(AutomationStep.reason(for: .automationFinder)
            == "Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails.")
        #expect(AutomationStep.reason(for: .automationSystemEvents)
            == "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall.")
    }

    // MARK: Extras

    @Test func whatWeCollectIsInPlainWords() {
        let lines = ExtrasStep.collectedData.map { String(localized: $0) }
        #expect(lines.count == 7)
        #expect(lines.allSatisfy { !$0.isEmpty && !$0.contains("_") })
    }

    // MARK: Ready

    @Test func summaryChipsSayAllowedOrNotYet() {
        #expect(String(localized: ReadySummaryChip.stateLabel(granted: true)) == "Allowed")
        #expect(String(localized: ReadySummaryChip.stateLabel(granted: false)) == "Not yet")
        #expect(ReadySummaryChip.systemImage(granted: true) == "checkmark.circle.fill")
        #expect(ReadySummaryChip.systemImage(granted: false) == "circle.fill")
    }

    @Test func summaryChipsFillRowsOfTwo() {
        let items = PermissionID.allCases.map { PermissionSummaryItem(id: $0, title: $0.title, granted: false) }
        #expect(ReadyStep.rows(items).map { $0.map(\.id) } == [
            [.moveToApplications, .fullDiskAccess],
            [.automationFinder, .automationSystemEvents],
            [.notifications, .launchAtLogin],
        ])
        #expect(ReadyStep.rows(Array(items.prefix(3))).map(\.count) == [2, 1])
        #expect(ReadyStep.rows([]).isEmpty)
    }

    @Test func readyExplainsChosenExtrasThatAreNotOnYet() {
        let both = OnboardingChoices(notifications: true, launchAtLogin: true)
        #expect(ReadyStep.notes(choices: both, notifications: .notDetermined, launchAtLogin: .notDetermined, isInstalled: true).count == 2)
        #expect(ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .granted, isInstalled: true).isEmpty)
        #expect(ReadyStep.notes(choices: OnboardingChoices(), notifications: .denied, launchAtLogin: .notDetermined, isInstalled: false).isEmpty)
        let notificationsOnly = ReadyStep.notes(
            choices: OnboardingChoices(notifications: true),
            notifications: .denied,
            launchAtLogin: .notDetermined,
            isInstalled: true
        )
        #expect(notificationsOnly.map { String(localized: $0) }
            == ["macOS asks whether RoomForMac may send notifications when you continue."])
        let installed = ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .notDetermined, isInstalled: true)
        #expect(installed.map { String(localized: $0) }
            == ["RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings."])
        // The Move step was skipped: the login item waits, and the note says why.
        let notInstalled = ReadyStep.notes(choices: both, notifications: .granted, launchAtLogin: .notDetermined, isInstalled: false)
        #expect(notInstalled.map { String(localized: $0) }
            == ["RoomForMac can open at login once it is in your Applications folder."])
    }

    @Test func identifiersKeepTheirSpelling() {
        #expect(AccessibilityID.extrasNotifications == "onboarding.extras.notifications")
        #expect(AccessibilityID.extrasLaunchAtLogin == "onboarding.extras.launchAtLogin")
        #expect(AccessibilityID.extrasAnalytics == "onboarding.extras.analytics")
        #expect(AccessibilityID.readyStartScan == "onboarding.ready.startScan")
        #expect(AccessibilityID.summaryChip(.fullDiskAccess) == "onboarding.summary.fullDiskAccess")
        #expect(AccessibilityID.summaryChip(.automationSystemEvents) == "onboarding.summary.automationSystemEvents")
    }

    // MARK: Rendering

    @Test(arguments: [ColorScheme.light, .dark])
    func stepsRender(scheme: ColorScheme) throws {
        let (model, flow) = try makeOnboarding()
        let size = CGSize(width: 640, height: 560)
        let steps: [(String, AnyView)] = [
            ("automation", AnyView(AutomationStep(permissions: model.permissions, targetIcon: { _ in NSImage() }))),
            ("admin access", AnyView(AdminAccessStep())),
            ("extras", AnyView(ExtrasStep(flow: flow))),
            ("ready", AnyView(ReadyStep(flow: flow, permissions: model.permissions, isFinishing: false, startFirstScan: {}, notNow: {}))),
            ("ready, finishing", AnyView(ReadyStep(flow: flow, permissions: model.permissions, isFinishing: true, startFirstScan: {}, notNow: {}))),
        ]
        for (name, view) in steps {
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size), "\(name) did not render")
            #expect(image.width == 640, "\(name)")
            #expect(image.height == 560, "\(name)")
        }
    }

    @Test(arguments: [OnboardingStep.automation, .adminAccess, .extras, .ready])
    func onboardingViewShowsTheStep(_ step: OnboardingStep) throws {
        let (model, flow) = try makeOnboarding()
        while flow.step != step {
            flow.next()
        }
        let view = OnboardingView(model: model, flow: flow).automationIcons { _ in NSImage() }
        let image = try #require(RenderCheck.image(of: view, scheme: .light, size: CGSize(width: 1100, height: 720)))
        #expect(image.width == 1100)
    }

    /// An onboarding model over scripted approvals: Full Disk Access and Finder
    /// allowed, System Events denied, both extras chosen and not on yet.
    private func makeOnboarding() throws -> (AppModel, OnboardingFlow) {
        let checkers: [any PermissionChecking] = [
            OnboardingFinishTests.RecordingChecker(id: .fullDiskAccess, current: .granted, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .automationFinder, current: .granted, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .automationSystemEvents, current: .denied, afterRequest: .denied),
            OnboardingFinishTests.RecordingChecker(id: .notifications, current: .notDetermined, afterRequest: .granted),
            OnboardingFinishTests.RecordingChecker(id: .launchAtLogin, current: .notDetermined, afterRequest: .granted),
        ]
        let model = AppModel(dependencies: AppDependencies(
            preferences: temporary.preferences,
            engineCheck: { .failure(.installationInvalid("not used")) },
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: nil
        ))
        let flow = try #require(model.onboardingFlow)
        flow.choices.notifications = true
        flow.choices.launchAtLogin = true
        return (model, flow)
    }
}
```

`ImageRenderer` draws AppKit-backed controls (the switches, the disclosure triangle, the progress spinner) as a yellow "unavailable" box, and nothing inside the scaffold's `ScrollView` (Task 12, Step 13). So the render tests check that each screen builds and lays out, and the four `OnboardingView` renders check only that the wiring renders at all. The Automation renders pass a blank icon source (`targetIcon`, and `automationIcons(_:)` on `OnboardingView`), so no test asks `NSWorkspace` for Finder's or System Events' icon. The app icon that `AutomationStep` still draws comes out with a grey veil in the offscreen image. That is a colour-space quirk of the renderer, and the app is not affected.

- [ ] **Step 6: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingPartTwoStepTests`
Expected: `** TEST FAILED **`, because the test target does not compile. The first error is `RoomForMacTests/OnboardingFinishTests.swift:253:17: error: cannot find 'AutomationStep' in scope`. The others are `cannot find 'AdminAccessStep' in scope`, `cannot find 'ExtrasStep' in scope`, `cannot find 'ReadySummaryChip' in scope`, `cannot find 'ReadyStep' in scope`, `type 'AccessibilityID' has no member 'extrasNotifications'` (and the other four identifiers) and `value of type 'OnboardingView' has no member 'automationIcons'`, with follow-on type-inference errors on the same lines.

- [ ] **Step 7: Add the identifiers**

Append to `RoomForMac/App/AccessibilityID.swift`, after Task 12's `// MARK: - Onboarding and permission cards (Task 12)` extension:
```swift
// MARK: - Onboarding, part 2 (Task 13)

extension AccessibilityID {
    static let extrasNotifications = "onboarding.extras.notifications"
    static let extrasLaunchAtLogin = "onboarding.extras.launchAtLogin"
    static let extrasAnalytics = "onboarding.extras.analytics"
    /// The "What we collect" disclosure under the analytics switch.
    static let extrasWhatWeCollect = "onboarding.extras.whatWeCollect"
    static let readyStartScan = "onboarding.ready.startScan"
    /// "Not now" on Ready: finish onboarding without a first scan.
    static let readyNotNow = "onboarding.ready.notNow"

    /// A permission chip on Ready: "onboarding.summary.<rawValue>".
    static func summaryChip(_ id: PermissionID) -> String {
        "onboarding.summary.\(id.rawValue)"
    }
}
```

- [ ] **Step 8: Write the Finder & System Events screen**

`RoomForMac/Features/Onboarding/Steps/AutomationStep.swift`
```swift
import AppKit
import SwiftUI

/// Screen 5: Finder & System Events. The engine sends Apple events to both
/// (Ruling 10), so each card asks for its approval now, at a moment the user
/// chose, instead of as a surprise prompt in the middle of the first cleanup.
/// "Allow" shows the system prompt; once macOS has recorded a denial it never
/// prompts again, so the card offers "Open Settings" instead.
struct AutomationStep: View {
    /// What a card's button does.
    enum CardAction: Equatable, Sendable {
        /// Ask macOS now. It launches the target hidden first if it is not running.
        case allow
        /// macOS will not ask again; the user must switch it on in System Settings.
        case openSettings

        var title: LocalizedStringKey {
            switch self {
            case .allow: "Allow"
            case .openSettings: "Open Settings"
            }
        }
    }

    /// The two approvals on this screen, in the order they are shown.
    static let permissionIDs: [PermissionID] = [.automationFinder, .automationSystemEvents]

    let permissions: PermissionCenter
    /// Where the illustration gets Finder's and System Events' icons. The unit
    /// tests pass a stand-in, so they never call `NSWorkspace` (Global Constraints).
    var targetIcon: @MainActor (URL) -> NSImage = AutomationStep.workspaceIcon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Requests waiting for the user's answer. Their buttons are disabled.
    @State private var pending: Set<PermissionID> = []

    /// The state a card shows. A passive check cannot answer while the target
    /// is not running (System Events usually is not), and `PermissionCenter`
    /// falls back to the last known state; with none stored yet, the card reads
    /// "Not yet", so the chips are the spec's Allowed / Not yet / Denied.
    static func displayState(_ state: PermissionState) -> PermissionState {
        if case .unknown = state {
            return .notDetermined
        }
        return state
    }

    /// Only a denial changes the button: the request call itself opens
    /// System Settings when macOS answers "denied" (Task 9).
    static func action(for state: PermissionState) -> CardAction {
        state == .denied ? .openSettings : .allow
    }

    static func title(for id: PermissionID) -> LocalizedStringKey {
        id == .automationFinder ? "Finder" : "System Events"
    }

    /// The icon Finder shows for an app: the illustration's default `targetIcon`.
    static func workspaceIcon(_ url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Why the engine needs each app, from what it really sends (research V7).
    static func reason(for id: PermissionID) -> LocalizedStringKey {
        if id == .automationFinder {
            "Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails."
        } else {
            "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall."
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            AutomationIllustration(animated: !reduceMotion, targetIcon: targetIcon)

            VStack(spacing: 8) {
                Text("Finder & System Events")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac's engine asks these two parts of macOS for help. Allow them now, so macOS doesn't stop your first cleanup to ask.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Self.permissionIDs, id: \.self) { id in
                let state = Self.displayState(permissions.state(id))
                let action = Self.action(for: state)
                PermissionCard(
                    id: id,
                    state: state,
                    title: Self.title(for: id),
                    reason: Self.reason(for: id),
                    actionTitle: action.title
                ) {
                    request(id)
                }
                .disabled(pending.contains(id))
            }
        }
        .animation(
            Motion.animation(Motion.hover, reduceMotion: reduceMotion),
            value: Self.permissionIDs.map { permissions.state($0) }
        )
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the prompt or from System Settings: read both states again.
            Task {
                await refresh()
            }
        }
    }

    private func request(_ id: PermissionID) {
        guard !pending.contains(id) else {
            return
        }
        pending.insert(id)
        Task {
            await permissions.request(id)
            pending.remove(id)
        }
    }

    /// Checks both at once, so a slow or hung check of one does not hold up the other.
    private func refresh() async {
        let permissions = permissions
        await withDiscardingTaskGroup { group in
            for id in Self.permissionIDs {
                group.addTask {
                    await permissions.refresh(id)
                }
            }
        }
    }
}

/// RoomForMac's icon linked to Finder's and System Events', with a gentle pulse
/// on the link. Under Reduce Motion the link is still. VoiceOver skips it.
private struct AutomationIllustration: View {
    static let iconSize: CGFloat = 56

    let animated: Bool
    let targetIcon: @MainActor (URL) -> NSImage

    var body: some View {
        HStack(spacing: 14) {
            icon(NSApplication.shared.applicationIconImage)
            Image(systemName: "arrow.left.arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.action)
                .symbolEffect(.pulse, isActive: animated)
            icon(targetIcon(AutomationChecker.Target.finder.applicationURL))
            icon(targetIcon(AutomationChecker.Target.systemEvents.applicationURL))
        }
        .accessibilityHidden(true)
    }

    private func icon(_ image: NSImage?) -> some View {
        Image(nsImage: image ?? NSImage())
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
    }
}
```

`refresh()` copies `permissions` into a local before the task group, so each child task captures only a `Sendable` value. `PermissionCenter` is a `@MainActor` class, and each `refresh(id)` hops back to the main actor to store its answer.

`targetIcon` is a `var` with a default, so the memberwise initializer takes it as an optional argument: `AutomationStep(permissions:)` shows the real icons, and the render test passes `{ _ in NSImage() }`. `OnboardingView` passes its own closure (Step 13), because `ImageRenderer` evaluates the step's `body` even inside the scaffold's `ScrollView`, which it does not draw.

- [ ] **Step 9: Write the Admin access screen**

`RoomForMac/Features/Onboarding/Steps/AdminAccessStep.swift`
```swift
import SwiftUI

/// Screen 6: admin access, explained and never requested. There is no password
/// field anywhere in RoomForMac: when a later update lets the user pick
/// system-level items, macOS itself shows the password prompt for that run.
struct AdminAccessStep: View {
    static let circleSize: CGFloat = 112

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Palette.action)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Admin access")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac only asks for your password when you pick system-level items, and macOS draws that prompt, never us. Nothing is requested now.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("System-level items arrive in a later update.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 10: Write the Extras screen**

`RoomForMac/Features/Onboarding/Steps/ExtrasStep.swift`
```swift
import SwiftUI

/// Screen 7: three optional extras. The toggles only record the choices in
/// `flow.choices`; nothing is asked of macOS until the user leaves Ready, where
/// `OnboardingApply` applies them.
struct ExtrasStep: View {
    /// What anonymous usage data contains, in plain words: the events of spec §8
    /// and the properties sent with every one of them.
    static let collectedData: [LocalizedStringResource] = [
        "That setup finished, and which approvals you gave, as yes or no.",
        "That a scan finished: which tool ran, and how much it found and how long it took, in ranges.",
        "That a cleanup finished or failed: how much it freed and how many items, in ranges, or the kind of error.",
        "When the free 1 GB runs out, whether the upgrade screen or checkout opened, and whether a purchase went through.",
        "Whether a license was activated, and if not, the kind of problem.",
        "With each of these: the app version, the macOS version, the kind of processor and whether RoomForMac is licensed.",
        "A random install ID made on this Mac, so events from one install can be counted together. It is not linked to you.",
    ]

    @Bindable var flow: OnboardingFlow

    @State private var showsCollectedData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extras")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Pick what you like. Nothing changes until you finish setup.")
                    .foregroundStyle(Palette.textSecondary)
            }

            GlassCard(cornerRadius: 24, padding: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    ExtrasToggle(isOn: $flow.choices.notifications, identifier: AccessibilityID.extrasNotifications) {
                        Text("Notify me when a cleanup finishes")
                    }
                    Divider()
                    ExtrasToggle(isOn: $flow.choices.launchAtLogin, identifier: AccessibilityID.extrasLaunchAtLogin) {
                        Text("Open RoomForMac at login")
                    }
                    Divider()
                    ExtrasToggle(isOn: $flow.choices.analytics, identifier: AccessibilityID.extrasAnalytics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share anonymous usage data")
                            Text("Counts and sizes in ranges. Never file names, paths or app names.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DisclosureGroup(isExpanded: $showsCollectedData) {
                        CollectedDataList(items: Self.collectedData)
                            .padding(.top, 6)
                    } label: {
                        Text("What we collect")
                            .foregroundStyle(Palette.text)
                    }
                    .accessibilityIdentifier(AccessibilityID.extrasWhatWeCollect)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with its label on the leading edge and the switch on the trailing
/// edge, as in System Settings. The whole label is the switch's VoiceOver label.
private struct ExtrasToggle<Title: View>: View {
    @Binding private var isOn: Bool
    private let identifier: String
    private let title: Title

    init(isOn: Binding<Bool>, identifier: String, @ViewBuilder title: () -> Title) {
        _isOn = isOn
        self.identifier = identifier
        self.title = title()
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            title
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(Palette.action)
        .accessibilityIdentifier(identifier)
    }
}

/// The "What we collect" lines, one bullet each.
private struct CollectedDataList: View {
    let items: [LocalizedStringResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .accessibilityHidden(true)
                    Text(items[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 11: Write the Ready screen**

`RoomForMac/Features/Onboarding/Steps/ReadyStep.swift`
```swift
import SwiftUI

/// Screen 8: where every approval stands, then the way out of onboarding.
/// **Start first scan** is morphing glass in the `action` tint (Ruling 5): when
/// pressed it shrinks into a progress circle while the Extras choices are
/// applied, which can mean waiting on the notification prompt. "Not now"
/// leaves onboarding without a scan. `OnboardingView` runs both through
/// `OnboardingApply.finish`.
struct ReadyStep: View {
    /// The glass ID the Start button keeps while it morphs into progress.
    static let startGlassID = "onboarding.startFirstScan"
    static let startHeight: CGFloat = 52

    let flow: OnboardingFlow
    let permissions: PermissionCenter
    let isFinishing: Bool
    let startFirstScan: @MainActor () -> Void
    let notNow: @MainActor () -> Void

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHoveringStart = false

    /// The summary chips, two to a row.
    static func rows(_ items: [PermissionSummaryItem], columns: Int = 2) -> [[PermissionSummaryItem]] {
        let width = max(columns, 1)
        return stride(from: 0, to: items.count, by: width).map { start in
            Array(items[start..<min(start + width, items.count)])
        }
    }

    /// What happens next for extras that are chosen but not on yet: they are
    /// only requested when the user leaves this screen. A copy outside the
    /// Applications folder gets no login item (`OnboardingApply.apply`), so
    /// its note says when it can.
    static func notes(
        choices: OnboardingChoices,
        notifications: PermissionState,
        launchAtLogin: PermissionState,
        isInstalled: Bool
    ) -> [LocalizedStringResource] {
        var notes: [LocalizedStringResource] = []
        if choices.notifications && !notifications.isGranted {
            notes.append("macOS asks whether RoomForMac may send notifications when you continue.")
        }
        if choices.launchAtLogin && !launchAtLogin.isGranted {
            if isInstalled {
                notes.append("RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings.")
            } else {
                notes.append("RoomForMac can open at login once it is in your Applications folder.")
            }
        }
        return notes
    }

    var body: some View {
        let items = flow.summary()
        let notes = Self.notes(
            choices: flow.choices,
            notifications: permissions.state(.notifications),
            launchAtLogin: permissions.state(.launchAtLogin),
            isInstalled: OnboardingApply.isInstalled(permissions)
        )
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("RoomForMac is ready")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Here's where your approvals stand. You can change them any time in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 4) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(Self.rows(items).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row) { item in
                                ReadySummaryChip(item: item)
                            }
                        }
                    }
                }
            }

            if !notes.isEmpty {
                VStack(spacing: 4) {
                    ForEach(notes.indices, id: \.self) { index in
                        Text(notes[index])
                            .font(Typography.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 16) {
                GlassButton("Not now", prominence: .secondary) {
                    notNow()
                }
                .disabled(isFinishing)
                .accessibilityIdentifier(AccessibilityID.readyNotNow)

                startButton
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            // Read every state again: an approval may have changed in System
            // Settings since its step, and the extras' chips need a first answer.
            await permissions.refreshAll()
        }
    }

    private var startButton: some View {
        GlassEffectContainer {
            Button(action: startFirstScan) {
                Group {
                    if isFinishing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: Self.startHeight, height: Self.startHeight)
                            .morphingGlass(id: Self.startGlassID, in: namespace, shape: .circle)
                    } else {
                        Label("Start first scan", systemImage: "sparkles")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.onAction)
                            .padding(.horizontal, 28)
                            .frame(height: Self.startHeight)
                            .morphingGlass(id: Self.startGlassID, in: namespace, shape: .capsule)
                    }
                }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isFinishing)
            .scaleEffect(GlassHover.scale(isHovered: isHoveringStart, isEnabled: !isFinishing, reduceMotion: reduceMotion))
            .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHoveringStart)
            .onHover { isHoveringStart = $0 }
            .accessibilityLabel(Text("Start first scan"))
            .accessibilityIdentifier(AccessibilityID.readyStartScan)
        }
    }
}

/// One approval on Ready: ✓ when it is allowed, • when it was skipped or is not
/// on yet. VoiceOver reads the name, then "Allowed" or "Not yet".
struct ReadySummaryChip: View {
    let item: PermissionSummaryItem

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func stateLabel(granted: Bool) -> LocalizedStringResource {
        granted ? "Allowed" : "Not yet"
    }

    static func systemImage(granted: Bool) -> String {
        granted ? "checkmark.circle.fill" : "circle.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Self.systemImage(granted: item.granted))
                .imageScale(item.granted ? .medium : .small)
                .foregroundStyle(item.granted ? Palette.moss : Palette.textSecondary)
            Text(item.title)
                .foregroundStyle(Palette.text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(Self.stateLabel(granted: item.granted)))
        .accessibilityIdentifier(AccessibilityID.summaryChip(item.id))
    }
}
```

`flow.summary()`, `permissions.state(_:)` and `OnboardingApply.isInstalled` are read in `body`, so the chips and notes follow `PermissionCenter` as its states change. Both are `@Observable`. The `refreshAll()` on appear gives the Move state its first answer when the Move step never ran.

- [ ] **Step 12: Let the scaffold hide its primary button**

In `RoomForMac/Features/Onboarding/OnboardingScaffold.swift`, make three edits. The rest of Task 12's file, including its `ScrollView` body and Skip button, stays as it is.

1. Below `private var isPrimaryEnabled = true`, add the stored flag:
   ```swift
       private var isPrimaryHidden = false
   ```
2. Add the modifier after `primaryEnabled(_:)`, just before `var body: some View {`:
   ```swift
       /// Leaves the primary button out, as on Ready, whose own Start first scan
       /// button is morphing glass (Ruling 5). Back and the dots stay.
       func primaryHidden(_ hidden: Bool) -> Self {
           var copy = self
           copy.isPrimaryHidden = hidden
           return copy
       }

   ```
3. In `bottomBar`, replace:
   ```swift
                   GlassButton(primaryTitle, action: primaryAction)
                       .disabled(!isPrimaryEnabled)
                       .keyboardShortcut(.defaultAction)
                       .accessibilityIdentifier(AccessibilityID.onboardingPrimary)
   ```
   with:
   ```swift
                   if !isPrimaryHidden {
                       GlassButton(primaryTitle, action: primaryAction)
                           .disabled(!isPrimaryEnabled)
                           .keyboardShortcut(.defaultAction)
                           .accessibilityIdentifier(AccessibilityID.onboardingPrimary)
                   }
   ```

- [ ] **Step 13: Put the four screens into `OnboardingView`**

In `RoomForMac/Features/Onboarding/OnboardingView.swift`, make six edits:

1. Below `@State private var isMoving = false`, add:
   ```swift
       @State private var isFinishing = false
       /// Where the Automation step gets Finder's and System Events' icons.
       /// `automationIcons(_:)` replaces it, so the unit tests never call `NSWorkspace`.
       private var automationTargetIcon: @MainActor (URL) -> NSImage = AutomationStep.workspaceIcon
   ```
2. After the closing brace of `init(model:flow:)`, add:
   ```swift

       /// Replaces where the Automation step gets Finder's and System Events'
       /// icons. The unit tests pass a stand-in.
       func automationIcons(_ icon: @escaping @MainActor (URL) -> NSImage) -> Self {
           var copy = self
           copy.automationTargetIcon = icon
           return copy
       }
   ```
3. Replace:
   ```swift
               .primaryEnabled(primary.isEnabled && !isMoving)
   ```
   with:
   ```swift
               .primaryEnabled(primary.isEnabled && !isMoving)
               .primaryHidden(flow.step == .ready)
               .disabled(isFinishing)
   ```
4. In `stepContent`, replace:
   ```swift
           case .automation, .adminAccess, .extras, .ready:
               // Task 13 replaces these four with their screens.
               PendingStepContent()
   ```
   with:
   ```swift
           case .automation:
               AutomationStep(permissions: permissions, targetIcon: automationTargetIcon)
           case .adminAccess:
               AdminAccessStep()
           case .extras:
               ExtrasStep(flow: flow)
           case .ready:
               ReadyStep(
                   flow: flow,
                   permissions: permissions,
                   isFinishing: isFinishing,
                   startFirstScan: { finish(startFirstScan: true) },
                   notNow: { finish(startFirstScan: false) }
               )
   ```
5. In `perform(_:)`, replace:
   ```swift
           case .startFirstScan:
               Task {
                   await flow.finish { _ in }
                   model.completeOnboarding(startFirstScan: true)
               }
           }
       }
   ```
   with:
   ```swift
           case .startFirstScan:
               finish(startFirstScan: true)
           }
       }

       /// Ready's two buttons. The first press wins: everything is disabled, and
       /// the Start button morphs into progress, until the choices are applied and
       /// `AppModel` hands the window to the main view.
       private func finish(startFirstScan: Bool) {
           guard !isFinishing else {
               return
           }
           withAnimation(Motion.animation(Motion.hover, reduceMotion: reduceMotion)) {
               isFinishing = true
           }
           Task {
               await OnboardingApply.finish(flow: flow, model: model, startFirstScan: startFirstScan)
           }
       }
   ```
6. Delete Task 12's placeholder, doc comment included:
   ```swift
   /// The content of the steps Task 13 builds (Finder & System Events, Admin
   /// access, Extras, Ready). Until then they show only the scaffold.
   private struct PendingStepContent: View {
       var body: some View {
           Color.clear
               .frame(width: 1, height: 1)
       }
   }
   ```

Run: `grep -n 'PendingStepContent\|Task 13 replaces' RoomForMac/Features/Onboarding/OnboardingView.swift`
Expected: no output.

- [ ] **Step 14: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/OnboardingFinishTests -only-testing:RoomForMacTests/OnboardingPartTwoStepTests`
Expected: `✔ Test run with 24 tests in 2 suites passed`, then `** TEST SUCCEEDED **`. `automationCardsAskUntilDenied(_:)` reports 5 test cases, `onboardingViewShowsTheStep(_:)` 4, `stepsRender(scheme:)` 2, and the four login-item argument tests 2 each. The host may print `Compiler failed to build request` after the render tests (Task 5 describes it). It is not a failure; only `** TEST FAILED **` or a `✘` line is.

- [ ] **Step 15: Run the whole unit scheme and the API guards**

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test 2>&1 | tee "$TMPDIR/rfm-task-13.log" | tail -n 20
grep -E '(Features/Onboarding/|App/AccessibilityID|OnboardingFinishTests\.swift|Support/FakeLoginService\.swift).*(warning|error):' "$TMPDIR/rfm-task-13.log"
grep -nE 'buttonStyle\(\.glass\(|GlassButtonStyle\(|@ContentBuilder|accessibilityPrefersCrossFadeTransitions' \
    RoomForMac/Features/Onboarding/Steps/{AutomationStep,AdminAccessStep,ExtrasStep,ReadyStep}.swift \
    RoomForMac/Features/Onboarding/OnboardingView.swift RoomForMac/Features/Onboarding/OnboardingScaffold.swift
```
Expected:
- The log ends with `** TEST SUCCEEDED **`. The Swift Testing summary counts this task's 24 tests with those of Tasks 1–12, and Task 12's `OnboardingViewTests` still pass: `OnboardingPrimary.forStep(.ready)` is still `.startFirstScan`.
- Both `grep`s print nothing, and the second exits 1. This task's files have no warnings and use no banned or post-26.0 API.
- The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 16: Sync the String Catalog**

Run:
```bash
OBJROOT=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null | awk '$1 == "OBJROOT" { print $3; exit }')
find "$OBJROOT" -path '*/RoomForMac.build/Objects-normal/*' -name '*.stringsdata' \
    -exec xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --stringsdata {} +
git diff --stat RoomForMac/Resources/Localizable.xcstrings
```
Expected: `xcstringstool` prints nothing and exits 0. The diff adds these 28 keys:
`A random install ID made on this Mac, so events from one install can be counted together. It is not linked to you.`, `Admin access`, `Allow`, `Checks which apps are running before a cleanup, and removes the login items of apps you uninstall.`, `Counts and sizes in ranges. Never file names, paths or app names.`, `Extras`, `Finder & System Events`, `Here's where your approvals stand. You can change them any time in Settings.`, `Not now`, `Notify me when a cleanup finishes`, `Open RoomForMac at login`, `Pick what you like. Nothing changes until you finish setup.`, `RoomForMac adds itself to your login items when you continue. If macOS asks, approve it in System Settings.`, `RoomForMac can open at login once it is in your Applications folder.`, `RoomForMac is ready`, `RoomForMac only asks for your password when you pick system-level items, and macOS draws that prompt, never us. Nothing is requested now.`, `RoomForMac's engine asks these two parts of macOS for help. Allow them now, so macOS doesn't stop your first cleanup to ask.`, `Share anonymous usage data`, `Shows your disk's exact free space in Status, and moves apps to the Trash if the usual way fails.`, `System-level items arrive in a later update.`, `That a cleanup finished or failed: how much it freed and how many items, in ranges, or the kind of error.`, `That a scan finished: which tool ran, and how much it found and how long it took, in ranges.`, `That setup finished, and which approvals you gave, as yes or no.`, `What we collect`, `When the free 1 GB runs out, whether the upgrade screen or checkout opened, and whether a purchase went through.`, `Whether a license was activated, and if not, the kind of problem.`, `With each of these: the app version, the macOS version, the kind of processor and whether RoomForMac is licensed.`, `macOS asks whether RoomForMac may send notifications when you continue.`

The screens also use keys that earlier tasks added, and those stay as they are: `Finder`, `System Events` (Task 8); `Open Settings`, `Allowed`, `Not yet`, `Continue`, `Start first scan` (Task 12). The chip titles come from `PermissionID.title` at run time.

- [ ] **Step 17: Look at the flow (visual check, not a gate)**

Run:
```bash
APP="$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/RoomForMac.app"
open -n "$APP" --args -RFMUITestScenario onboarding
```
The `onboarding` scenario uses its own wiped UserDefaults suite. Until Task 15 it has no permission checkers and no `loginItem`, so nothing touches real permissions, notifications or login items. Walk to the new screens with Skip or Continue, and check:
- **Finder & System Events:** two cards with "Not yet" chips, and the link symbol pulses. "Allow" does nothing yet, because there is no checker.
- **Admin access:** the shield breathes in its glass circle; there is no field and no prompt.
- **Extras:** three switches, analytics on. "What we collect" opens seven lines.
- **Ready:**
  - The chips show • (no checkers), and the notes appear once an extra is switched on.
  - There is no bottom-bar primary button. Back goes to Extras.
  - Return presses **Start first scan**, which briefly becomes a progress circle and then shows the Smart Clean placeholder. On a second run, "Not now" does the same.

Then run `pkill -x RoomForMac`.

- [ ] **Step 18: Commit**

```bash
git add RoomForMac/Features/Onboarding/Steps/AutomationStep.swift RoomForMac/Features/Onboarding/Steps/AdminAccessStep.swift \
    RoomForMac/Features/Onboarding/Steps/ExtrasStep.swift RoomForMac/Features/Onboarding/Steps/ReadyStep.swift \
    RoomForMac/Features/Onboarding/OnboardingView.swift RoomForMac/Features/Onboarding/OnboardingScaffold.swift \
    RoomForMac/App/AccessibilityID.swift RoomForMac/Resources/Localizable.xcstrings \
    RoomForMacTests/Support/FakeLoginService.swift RoomForMacTests/OnboardingFinishTests.swift
git status --short   # nothing under RoomForMac/Generated or RoomForMac.xcodeproj is staged
git commit -F - <<'MSG'
feat(onboarding): Finder & System Events, admin, extras and ready screens

The last four onboarding screens. Finder & System Events asks for
each Apple-event approval when the user presses Allow, with the
reasons the engine really has, and offers System Settings once macOS
has recorded a denial. Admin access explains that macOS asks for the
password later and requests nothing. Extras records notifications,
open at login and anonymous usage data, and lists what the usage data
contains.

Ready shows where every approval stands. Start first scan is morphing
glass that turns into progress while OnboardingApply applies the
choices: it requests notifications, and registers the login item once
the app is in an Applications folder, or unregisters one that is still
registered. It then records completion and hands over to the main
window. The scaffold hides its own primary button on Ready.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
MSG
```

### Task 14: Settings — General, Permissions, About; legal documents and credits

**Files:**
- Create: `RoomForMac/Features/Settings/SettingsView.swift`, `GeneralSettingsView.swift`, `PermissionsSettingsView.swift`, `AboutView.swift`, `LegalDocument.swift`, `CREDITS.md`, `RoomForMacTests/SettingsTests.swift`
- Modify: `RoomForMac/App/RoomForMacApp.swift` (Settings scene), `project.yml` (bundle `LICENSE`, `NOTICE` and `CREDITS.md` as resources), `RoomForMac/App/AccessibilityID.swift`
- Modify (added; the String Catalog grows every task): `RoomForMac/Resources/Localizable.xcstrings` (this task's keys, synced from the build, plus the plural of the engine line)

**Interfaces:**
- Consumes: `PermissionCenter`, `PermissionCard` (Tasks 8, 12); `LoginItemChecker`, `NotificationChecker` (Task 9); `AppModel` and its `EnginePhase` (Task 7); `AppPreferences` (Task 7).
- Also consumes, exactly as the earlier tasks declare them:
  - `EngineFingerprint` and its memberwise `init` and `init(_ version: EngineVersion)` (Task 3);
  - `PermissionID`, `PermissionState`, `PermissionChecking`, `SystemSettingsLink`, and `PermissionCenter.states`, `state(_:)`, `hasChecker(_:)`, `refresh(_:)`, `refreshAll()`, `request(_:)` (Task 8);
  - `LoginItemChecker.init(status:register:unregister:openLoginItemsSettings:)` and `disable()` (Task 9);
  - `PermissionChip` (Task 12); `AutomationStep.permissionIDs`, `displayState(_:)`, `title(for:)`, `reason(for:)`, `action(for:)` and `AutomationStep.CardAction.title` (Task 13); `AnimatedWordmark` (Task 5), `Palette`, `Typography` (Task 4);
  - `AppDependencies` with its memberwise initializer in the order `preferences, engineCheck, openURL, permissionCheckers, needsMoveStep, loginItem` (Tasks 7 and 12), and `AppModel.permissions`, `engine`, `dependencies`, `start()`;
  - test support: `RenderCheck` (Task 5), `TemporaryDirectory`, `EngineLayout` (Task 3), `TemporaryDefaults` (Task 7), `FakeChecker` (Task 8), `FakeLoginService` (Task 13, `RoomForMacTests/Support`).
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
- Added by this task (internal to this task; nothing outside it depends on these yet):
  ```swift
  enum SettingsTab: String, CaseIterable, Hashable, Sendable {
      case general, permissions, about
      var title: LocalizedStringResource { get }   // "General", "Permissions", "About"
      var systemImage: String { get }              // "gearshape", "hand.raised", "info.circle"
  }
  extension SettingsView { static let contentSize: CGSize }            // 560 × 540 pt, every tab
  extension LegalDocument {
      static func section(_ heading: String, in markdown: String) -> String?   // body of "## <heading>", trimmed; nil when absent or empty
  }
  extension AboutInfo {
      static let missingValue: String                                  // "—", for a version or build the bundle lacks
      static func shortCommit(_ commit: String) -> String              // first 7 characters
      static func fingerprint(for phase: EnginePhase) -> EngineFingerprint?   // .ready → its VERSION; .checking, .broken → nil
  }
  struct AboutView: View {
      nonisolated static let moleRepository: URL                       // https://github.com/tw93/mole
      init(info: AboutInfo, bundle: Bundle = .main, openURL: @escaping @MainActor (URL) -> Void)
  }
  struct LegalDocumentView: View { init(document: LegalDocument, text: String?) }   // the sheet; nil text → "This document is missing"
  struct GeneralSettingsView: View {
      enum LoginItemPresentation: Equatable, Sendable { case off, on, needsApproval, unavailable; var isOn: Bool { get } }
      enum NotificationAction: Equatable, Sendable { case request, openSettings }
      init(permissions: PermissionCenter, loginItem: LoginItemChecker?, openURL: @escaping @MainActor (URL) -> Void)
      static func loginItemPresentation(for state: PermissionState) -> LoginItemPresentation
      static func setLaunchAtLogin(_ enabled: Bool, permissions: PermissionCenter, loginItem: LoginItemChecker?) async
      static func notificationAction(for state: PermissionState) -> NotificationAction
      static func performNotificationAction(_ action: NotificationAction, permissions: PermissionCenter,
                                            openURL: @MainActor (URL) -> Void) async
  }
  struct PermissionsSettingsView: View {
      enum CardAction: Equatable, Sendable { case request, open(SystemSettingsLink) }
      struct CardContent { let title: LocalizedStringKey; let reason: LocalizedStringKey; let actionTitle: LocalizedStringKey; let action: CardAction }
      init(permissions: PermissionCenter, openURL: @escaping @MainActor (URL) -> Void)
      static func cards(moveState: PermissionState?) -> [PermissionID]
      static func cardState(_ id: PermissionID, permissions: PermissionCenter) -> PermissionState   // Finder, System Events: AutomationStep.displayState; others: state(id)
      static func content(for id: PermissionID, state: PermissionState) -> CardContent
      // Finder, System Events: AutomationStep.title(for:), reason(for:) and action(for:).title (Task 13).
      // .launchAtLogin is never a card (General owns it); its case reuses General's wording.
  }
  extension AccessibilityID {
      static func settingsTab(_ tab: SettingsTab) -> String                  // "settings.tab.<rawValue>"
      static let settingsLaunchAtLogin = "settings.general.launchAtLogin"
      static let settingsApproveLoginItem = "settings.general.approveLoginItem"
      static let settingsNotifications = "settings.general.notifications"
      static let settingsNotificationsAction = "settings.general.notifications.action"
      static let settingsMenuBarNote = "settings.general.menuBarNote"
      static let settingsMoveByHand = "settings.permissions.moveByHand"
      static let settingsRevealInFinder = "settings.permissions.revealInFinder"
      static let settingsVersion = "settings.about.version"; static let settingsEngine = "settings.about.engine"
      static let settingsMoleLink = "settings.about.moleLink"
      static let settingsLegalText = "settings.about.legal.text"; static let settingsLegalDone = "settings.about.legal.done"
      static func settingsLegalDocument(_ document: LegalDocument) -> String // "settings.about.legal.<rawValue>"
  }
  // RoomForMacTests/SettingsTests.swift (test support inside the suite):
  //   SettingsTests.makeBundle(in:info:resources:) -> Bundle        a throwaway bundle with Contents/Info.plist and Resources
  //   SettingsTests.model(defaults:checkers:loginItem:engineCheck:) an onboarded AppModel over fakes (@MainActor)
  //   (the login item is Task 13's FakeLoginService, from RoomForMacTests/Support)
  ```

**Requirements:**
- **General** (`GeneralSettingsView`, a grouped `Form`):
  - "Open RoomForMac at login" is a `Toggle` bound to the login item. On calls `permissions.request(.launchAtLogin)`: the `LoginItemChecker` registers the app and opens Login Items when macOS wants approval. Off calls `loginItem.disable()`, then `permissions.refresh(.launchAtLogin)`.
  - The switch reads on for `.granted` and `.requiresApproval`. `.requiresApproval` adds a row with **Approve in System Settings**, which opens `SystemSettingsLink.loginItems.url`. `.unknown` (ad-hoc and unsigned builds report "not found") adds a one-line explanation. The switch is disabled while a change runs, and when no `.launchAtLogin` checker exists.
  - "Notifications" shows a `PermissionChip` and one button: **Allow** (`permissions.request(.notifications)`) while `.notDetermined`, and **Open Settings** (`SystemSettingsLink.notifications.url`) in every other state, since macOS asks only once.
  - A note that the menu-bar extra arrives with Status: "A menu bar extra with quick gauges arrives with Status in the next update." UI copy names no plan numbers.
  - `.launchAtLogin` and `.notifications` are refreshed on appear and on `NSApplication.didBecomeActiveNotification`, because both can change in System Settings.
  - It does not write `AppPreferences.notificationsWanted`. Task 11 makes `OnboardingFlow.finish` its only writer.
- **Permissions** (`PermissionsSettingsView`):
  - The same `PermissionCard`s as onboarding, with the onboarding wording, for Full Disk Access, Finder, System Events and Notifications, in that order. Finder and System Events take their title, reason and button rule from `AutomationStep` (`title(for:)`, `reason(for:)`, `action(for:)`, Task 13), so onboarding and Settings share one source of copy.
  - `.launchAtLogin` is never a card: General owns open-at-login. `content(for:state:)` still covers it so its `switch` stays exhaustive, but only with General's own wording, so no catalog key and no test exist for a card nobody sees.
  - Finder and System Events show their state through `AutomationStep.displayState`, as onboarding does (Task 13): System Events is usually not running, so its passive check answers `.unknown("not running")`, and with no last-known state stored the card reads "Not yet", not "Unknown". A stored last-known state still wins (Task 8). The other cards show `permissions.state(id)` as it is.
  - Move to Applications comes first, but only once a check has answered and the answer is not granted. `AppLocationChecker` answers `.granted` when installed and `.notApplicable` under the DEBUG bypass, so the card appears only for a copy outside the Applications folders. Before the first check it is hidden, so it never flashes.
  - Move, Full Disk Access, Finder and System Events call `permissions.request`. The Automation button reads **Allow**, or **Open Settings** once denied (`AutomationStep.action(for:)`); a denied Automation request opens Privacy → Automation by itself (Task 9). Notifications: **Allow** requests while `.notDetermined`, otherwise **Open Settings** opens the Notifications pane through `openURL`.
  - After a failed move (`.denied`), the card is followed by "Drag RoomForMac into your Applications folder, then open it from there." and **Reveal in Finder** (`settings.permissions.revealInFinder`).
  - `refreshAll()` on appear and on `didBecomeActive`.
- **About** (`AboutView`, a grouped `Form`):
  - The app name as `AnimatedWordmark(progress: 1)`, then "Version \(appVersion) (\(build))" and `engineLine`, both selectable.
  - "RoomForMac is built on the open-source Mole engine by tw93 (GPL-3.0)." and a link-styled button, labelled `github.com/tw93/mole`, that opens `https://github.com/tw93/mole` through `AppDependencies.openURL`. UI-test scenarios, whose `openURL` does nothing, therefore never open a browser.
  - The list of the four `LegalDocument`s. Each row opens a sheet (`LegalDocumentView`) with the title, **Done** (the default action), and the text in monospaced, selectable type. A document that cannot be read shows "This document is missing" and "Reinstall RoomForMac to restore it."
  - "Photography" shows the body of the `## Photography` section of the bundled `CREDITS.md`, as written. Nothing about photos is hard-coded, so adding a credit to `CREDITS.md` updates About.
- **`AboutInfo`:**
  - `appVersion` and `build` come from `CFBundleShortVersionString` and `CFBundleVersion`, or "—" when the bundle lacks them.
  - `engineLine` is `String(localized: "Engine \(tag) (\(shortCommit), \(count) patches)")`, whose catalog entry varies by plural, so 1 reads "1 patch". It is "Engine unavailable" when `engine` is nil.
  - `SettingsView` passes `AboutInfo.fingerprint(for: model.engine)`: the engine the launch check accepted, and nil while it runs or after it failed.
- **`SettingsView`:** a `TabView` of three `Tab`s (General `gearshape`, Permissions `hand.raised`, About `info.circle`), each 560 × 540 pt, with the identifiers `settings.tab.<raw>`. It reads `model.permissions`, `model.dependencies.loginItem` and `model.dependencies.openURL`, and is the content of the `Settings` scene in `RoomForMacApp`. There is no License or Privacy tab yet; they arrive with the licensing and analytics plans.
- **`LegalDocument`:** `url(in:)` uses `Bundle.url(forResource:withExtension:subdirectory:)`, so `LICENSE`, `NOTICE` and `CREDITS.md` are found at the top of Resources, and `moleLicense` at `engine/LICENSE`, which Task 2's embed phase ships (Ruling 13). `text(in:)` is the UTF-8 content, and nil when the file is missing, unreadable or blank.
- `CREDITS.md`, at the repository root, has these sections:
  - Engine: "Mole by tw93, GPL-3.0, https://github.com/tw93/mole".
  - Photography: "None bundled yet. Every photo will be public domain, CC0 or CC BY, credited here with title, author, source, licence and whether it was modified."
  - Fonts: "SF Pro and SF Pro Rounded, system fonts, not redistributed."
- `project.yml`: add `- path: LICENSE`, `- path: NOTICE` and `- path: CREDITS.md`, each with `buildPhase: resources`, to the app target's sources.
- **Strings:** every literal goes through the String Catalog. The document texts and the photography section are file content and are shown as written, like the licences. The link label `github.com/tw93/mole` is `Text(verbatim:)`. "Mole" appears only in the About credit, the "Engine License (Mole)" title, `NOTICE` and `CREDITS.md` (Global Constraints, Trademark).
- **Tests** (Swift Testing, app-hosted, in one `SettingsTests` suite with five nested suites; every checker is a fake, so nothing prompts, registers a login item or opens a URL):
  - `LegalDocument.url(in: .main)` exists for all four in the hosted app, at `LICENSE`, `NOTICE`, `CREDITS.md` and `engine/LICENSE` under Resources, and each `text` is non-empty with its expected content. `CREDITS.md` has the three sections word for word. A bundle without the files has no documents, each document reads its own file, and a blank file reads as missing. `section` reads one section and stops at the next heading of level 1 or 2.
  - `AboutInfo.engineLine` for a known fingerprint ("Engine V1.56.0 (239c90d, 5 patches)"), for 1 and 0 patches, and for nil. The version and build come from the bundle, with "—" when missing. `fingerprint(for:)` follows the engine phase.
  - General: the login-item presentation for every state; on registers, on with approval opens Login Items, off unregisters; the notification action for every state, and each action.
  - Permissions: the card list for every move state, including before any check; the Automation and Notifications titles and actions; the card wording; an unanswered Automation check with nothing stored reads `.notDetermined`, a stored state wins, and other cards keep their state.
  - Settings tabs render through `ImageRenderer`: each tab's content view (General, Permissions, About with a ready engine) at 560 × 540 in light and dark, and the document sheet for all four documents and a missing one. `SettingsView` itself is not tested: its `TabView` cannot be rendered offscreen, and building it without rendering would check nothing. In scratch, `ImageRenderer` aborted the test host with `SwiftUICore/Logging.swift:232: Fatal error: no current update to enqueue action to` whenever a `TabView` hosted views with `.task` or state. A plain `TabView { Text }` rendered. `ImageRenderer` also draws `Form` and `ScrollView` contents blank. So these tests prove the views build and lay out without crashing, not how they look; Step 18 is the visual check.

- [ ] **Step 1: Write the failing legal-document tests**

`RoomForMacTests/SettingsTests.swift` (the imports cover the whole file; Step 7 appends the rest):
```swift
import Foundation
import MoleEngine
import ServiceManagement
import SwiftUI
import Testing
@testable import RoomForMac

/// Settings: legal documents, About, General, Permissions and the window's tabs.
/// Every checker is a fake; nothing here prompts, registers a login item or opens a URL.
@Suite("Settings")
struct SettingsTests {
    static let fingerprint = EngineFingerprint(
        moleTag: "V1.56.0",
        moleCommit: "239c90d576c7aaaabbbbccccddddeeeeffff0000",
        patchesSHA256: String(repeating: "3f", count: 32),
        patchCount: 5
    )

    /// A bundle folder with `Contents/Info.plist` and the given files under `Contents/Resources`.
    static func makeBundle(
        in directory: TemporaryDirectory,
        info: [String: String] = [:],
        resources: [String: String] = [:]
    ) throws -> Bundle {
        let root = directory.url.appending(path: "Sample-\(UUID().uuidString).bundle")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": "com.roomformac.tests.sample", "CFBundlePackageType": "BNDL"]
        plist.merge(info) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        for (path, text) in resources {
            let url = contents.appending(path: "Resources").appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return try #require(Bundle(url: root))
    }
}

// MARK: - Legal documents

extension SettingsTests {
    @Suite("Legal documents")
    struct LegalDocuments {
        let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
        }

        @Test func orderIdsAndTitles() {
            #expect(LegalDocument.allCases == [.license, .notice, .credits, .moleLicense])
            #expect(LegalDocument.allCases.map(\.id) == ["license", "notice", "credits", "moleLicense"])
            #expect(LegalDocument.allCases.map { String(localized: $0.title) }
                == ["RoomForMac License", "Notice", "Credits", "Engine License (Mole)"])
        }

        @Test(arguments: LegalDocument.allCases)
        func theAppShipsEveryDocument(document: LegalDocument) throws {
            let url = try #require(document.url(in: .main), "\(document) is missing from the app bundle")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let text = try #require(document.text(in: .main))
            #expect(!text.isEmpty)
        }

        @Test func documentsSitWhereTheBuildPutsThem() throws {
            let resources = try #require(Bundle.main.resourceURL).resolvingSymlinksInPath().path
            let paths = LegalDocument.allCases.map { $0.url(in: .main)?.resolvingSymlinksInPath().path }
            #expect(paths == ["LICENSE", "NOTICE", "CREDITS.md", "engine/LICENSE"].map { "\(resources)/\($0)" })
        }

        @Test func documentsHaveTheirContent() throws {
            #expect(try #require(LegalDocument.license.text(in: .main)).contains("GNU GENERAL PUBLIC LICENSE"))
            #expect(try #require(LegalDocument.notice.text(in: .main)).contains("https://github.com/tw93/mole"))
            #expect(try #require(LegalDocument.moleLicense.text(in: .main)).contains("GNU GENERAL PUBLIC LICENSE"))
            let credits = try #require(LegalDocument.credits.text(in: .main))
            #expect(credits.contains("Mole by tw93, GPL-3.0, https://github.com/tw93/mole"))
            #expect(credits.contains("SF Pro and SF Pro Rounded, system fonts, not redistributed."))
        }

        @Test func theCreditsHaveTheThreeSections() throws {
            let credits = try #require(LegalDocument.credits.text(in: .main))
            #expect(LegalDocument.section("Engine", in: credits)?.hasPrefix("- Mole by tw93, GPL-3.0, https://github.com/tw93/mole") == true)
            #expect(LegalDocument.section("Photography", in: credits)
                == "None bundled yet. Every photo will be public domain, CC0 or CC BY, credited here with title, author, source, licence and whether it was modified.")
            #expect(LegalDocument.section("Fonts", in: credits) == "SF Pro and SF Pro Rounded, system fonts, not redistributed.")
        }

        @Test func aBundleWithoutTheFilesHasNoDocuments() throws {
            let bundle = try SettingsTests.makeBundle(in: directory)
            for document in LegalDocument.allCases {
                #expect(document.url(in: bundle) == nil, "\(document)")
                #expect(document.text(in: bundle) == nil, "\(document)")
            }
        }

        @Test func eachDocumentReadsItsOwnFile() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, resources: [
                "LICENSE": "app licence",
                "NOTICE": "notice",
                "CREDITS.md": "credits",
                "engine/LICENSE": "engine licence",
            ])
            #expect(LegalDocument.allCases.map { $0.text(in: bundle) } == ["app licence", "notice", "credits", "engine licence"])
        }

        @Test func aBlankDocumentReadsAsMissing() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, resources: ["NOTICE": " \n\n "])
            #expect(LegalDocument.notice.url(in: bundle) != nil)
            #expect(LegalDocument.notice.text(in: bundle) == nil)
        }

        @Test func sectionReadsOneMarkdownSection() {
            let markdown = """
            # Credits

            Intro

            ## Engine

            - Mole

            ## Photography

            None yet.

            ### Later
            Kept

            ## Fonts

            SF Pro
            """
            #expect(LegalDocument.section("Photography", in: markdown) == "None yet.\n\n### Later\nKept")
            #expect(LegalDocument.section("Fonts", in: markdown) == "SF Pro")
            #expect(LegalDocument.section("Photo", in: markdown) == nil)
            #expect(LegalDocument.section("Credits", in: markdown) == nil)
            #expect(LegalDocument.section("Licences", in: markdown) == nil)
            #expect(LegalDocument.section("Empty", in: "## Empty\n\n## Next\nx") == nil)
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/SettingsTests`
Expected: the test target does not compile, and the run ends `** TEST FAILED **`. The errors include `error: cannot find 'LegalDocument' in scope` and `error: cannot find type 'LegalDocument' in scope`.

- [ ] **Step 3: Write `CREDITS.md`**

`CREDITS.md` (repository root, next to `LICENSE` and `NOTICE`):
```markdown
# Credits

RoomForMac is free software under the GNU General Public License, version 3
(see LICENSE). It is built on the work credited below.

## Engine

- Mole by tw93, GPL-3.0, https://github.com/tw93/mole

RoomForMac bundles a patched copy of Mole as its cleaning engine. Mole's own
licence ships with the engine and is shown in Settings, About, "Engine License
(Mole)". "Mole" is a trademark of the Mole project. RoomForMac is not
affiliated with or endorsed by it.

## Photography

None bundled yet. Every photo will be public domain, CC0 or CC BY, credited here with title, author, source, licence and whether it was modified.

## Fonts

SF Pro and SF Pro Rounded, system fonts, not redistributed.
```

About reads the `## Photography` section from the bundled copy, so a photo credit added here later shows up in Settings → About without a code change. Each Photography line must stay on one line or a plain paragraph: About shows the section as written.

- [ ] **Step 4: Bundle the three documents**

In `project.yml`, append these entries to the end of the `RoomForMac` target's `sources:` list, after the `RoomForMac/Resources/Backgrounds` folder entry that Task 6 added:
```yaml
      # Legal documents for Settings → About. They stay at the repository root,
      # where GitHub and source archives expect them.
      - path: LICENSE
        buildPhase: resources
      - path: NOTICE
        buildPhase: resources
      - path: CREDITS.md
        buildPhase: resources
```

Run: `xcodegen generate && grep -cE '/\* (LICENSE|NOTICE|CREDITS\.md) in Resources \*/ = \{isa = PBXBuildFile' RoomForMac.xcodeproj/project.pbxproj`
Expected: `Created project at …/RoomForMac.xcodeproj`, then `3`. XcodeGen puts the three files in the root group and in Copy Bundle Resources, so the app gets `Contents/Resources/{LICENSE,NOTICE,CREDITS.md}`. The engine's own `Contents/Resources/engine/LICENSE` is separate and comes from Task 2's embed phase.

Run: `grep -nE 'CODE_SIGN|DEVELOPMENT_TEAM' project.yml`
Expected: no output and exit status 1.

- [ ] **Step 5: Write `LegalDocument`**

`RoomForMac/Features/Settings/LegalDocument.swift`
```swift
import Foundation

/// The legal texts Settings → About lists. `LICENSE`, `NOTICE` and `CREDITS.md` are copied from
/// the repository root into Contents/Resources (project.yml). Mole's licence ships inside the
/// engine, at Contents/Resources/engine/LICENSE (Ruling 13).
enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
    case license, notice, credits, moleLicense

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .license: "RoomForMac License"
        case .notice: "Notice"
        case .credits: "Credits"
        case .moleLicense: "Engine License (Mole)"
        }
    }

    /// The file inside `bundle`, or nil when the bundle does not have it.
    func url(in bundle: Bundle) -> URL? {
        switch self {
        case .license: bundle.url(forResource: "LICENSE", withExtension: nil)
        case .notice: bundle.url(forResource: "NOTICE", withExtension: nil)
        case .credits: bundle.url(forResource: "CREDITS", withExtension: "md")
        case .moleLicense: bundle.url(forResource: "LICENSE", withExtension: nil, subdirectory: "engine")
        }
    }

    /// The document's UTF-8 text. Nil when the file is missing, unreadable or blank, so the
    /// viewer can say it is missing instead of showing an empty page.
    func text(in bundle: Bundle) -> String? {
        guard let url = url(in: bundle),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return text
    }

    /// The body of the `## <heading>` section of a Markdown text: the lines up to the next
    /// heading of level 1 or 2, trimmed. Nil when the section is missing or empty.
    /// About reads the photo credits from `CREDITS.md` this way.
    static func section(_ heading: String, in markdown: String) -> String? {
        var body: [Substring] = []
        var inSection = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                if inSection {
                    break
                }
                inSection = line == "## \(heading)"
                continue
            }
            if inSection {
                body.append(line)
            }
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
```

- [ ] **Step 6: Run the legal-document tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/SettingsTests`
Expected: `✔ Suite "Legal documents" passed`, `✔ Test run with 9 tests in 2 suites passed` and `** TEST SUCCEEDED **`; `theAppShipsEveryDocument(document:)` reports 4 test cases.
- If `moleLicense` fails `theAppShipsEveryDocument`, the embedded engine has no `LICENSE`: check that Task 2's `build-engine.sh` copies `vendor/mole/LICENSE` and that the "Embed engine" phase ran.
- The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

- [ ] **Step 7: Append the failing Settings tests**

Append to `RoomForMacTests/SettingsTests.swift`:
```swift
// MARK: - Settings UI

extension SettingsTests {
    /// An app model over fake checkers, already onboarded, whose engine check is never run
    /// unless a test calls `start()`.
    @MainActor
    static func model(
        defaults: TemporaryDefaults,
        checkers: [any PermissionChecking] = [],
        loginItem: LoginItemChecker? = nil,
        engineCheck: @escaping @Sendable () async -> Result<EngineInstallation, EngineProblem> = {
            .failure(.installationInvalid("not checked in this test"))
        }
    ) -> AppModel {
        let preferences = defaults.preferences
        preferences.onboardingCompleted = true
        return AppModel(dependencies: AppDependencies(
            preferences: preferences,
            engineCheck: engineCheck,
            openURL: { _ in },
            permissionCheckers: checkers,
            needsMoveStep: false,
            loginItem: loginItem
        ))
    }
}

// MARK: - About

extension SettingsTests {
    @Suite("About info")
    struct About {
        let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
        }

        @Test func engineLineForAKnownFingerprint() {
            let info = AboutInfo(bundle: .main, engine: SettingsTests.fingerprint)
            #expect(info.engineLine == "Engine V1.56.0 (239c90d, 5 patches)")
        }

        @Test func engineLinePluralizesThePatchCount() {
            var fingerprint = SettingsTests.fingerprint
            fingerprint.patchCount = 1
            #expect(AboutInfo(bundle: .main, engine: fingerprint).engineLine == "Engine V1.56.0 (239c90d, 1 patch)")
            fingerprint.patchCount = 0
            #expect(AboutInfo(bundle: .main, engine: fingerprint).engineLine == "Engine V1.56.0 (239c90d, 0 patches)")
        }

        @Test func engineLineWithoutAnEngine() {
            #expect(AboutInfo(bundle: .main, engine: nil).engineLine == "Engine unavailable")
        }

        @Test func shortCommitKeepsSevenCharacters() {
            #expect(AboutInfo.shortCommit("239c90d576c7aaaabbbb") == "239c90d")
            #expect(AboutInfo.shortCommit("abc") == "abc")
            #expect(AboutInfo.shortCommit("") == "")
        }

        @Test func versionAndBuildComeFromTheBundle() throws {
            let bundle = try SettingsTests.makeBundle(in: directory, info: [
                "CFBundleShortVersionString": "2.3.4",
                "CFBundleVersion": "56",
            ])
            let info = AboutInfo(bundle: bundle, engine: SettingsTests.fingerprint)
            #expect(info == AboutInfo(bundle: bundle, engine: SettingsTests.fingerprint))
            #expect(info.appVersion == "2.3.4")
            #expect(info.build == "56")
            #expect(info.engine == SettingsTests.fingerprint)
        }

        @Test func theAppDeclaresItsVersionAndBuild() {
            let info = AboutInfo(bundle: .main, engine: nil)
            #expect(info.appVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            #expect(info.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            #expect(info.appVersion != AboutInfo.missingValue)
            #expect(info.build != AboutInfo.missingValue)
        }

        @Test func aBundleWithoutVersionsShowsADash() throws {
            let info = AboutInfo(bundle: try SettingsTests.makeBundle(in: directory), engine: nil)
            #expect(info.appVersion == "—")
            #expect(info.build == "—")
        }

        @Test func fingerprintFollowsTheEnginePhase() throws {
            #expect(AboutInfo.fingerprint(for: .checking) == nil)
            #expect(AboutInfo.fingerprint(for: .broken(.installationInvalid("missing bin/clean.sh"))) == nil)
            let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: SettingsTests.fingerprint))
            let installation = try EngineInstallation(root: root)
            #expect(AboutInfo.fingerprint(for: .ready(installation)) == SettingsTests.fingerprint)
        }

        @Test func theMoleLinkIsTheUpstreamRepository() {
            #expect(AboutView.moleRepository.absoluteString == "https://github.com/tw93/mole")
        }
    }
}

// MARK: - General

extension SettingsTests {
    /// General's login switch and notification button. The login item is Task 13's
    /// `FakeLoginService` (RoomForMacTests/Support): a real `LoginItemChecker` over an
    /// in-memory `SMAppService`.
    @MainActor
    @Suite("General settings")
    struct General {
        @Test(arguments: [
            (PermissionState.granted, GeneralSettingsView.LoginItemPresentation.on),
            (.requiresApproval, .needsApproval),
            (.unknown("unavailable in this build"), .unavailable),
            (.notDetermined, .off),
            (.denied, .off),
            (.notApplicable, .off),
        ])
        func loginItemPresentation(state: PermissionState, expected: GeneralSettingsView.LoginItemPresentation) {
            #expect(GeneralSettingsView.loginItemPresentation(for: state) == expected)
        }

        @Test func theSwitchShowsOnWhileRegistered() {
            #expect(GeneralSettingsView.LoginItemPresentation.on.isOn)
            #expect(GeneralSettingsView.LoginItemPresentation.needsApproval.isOn)
            #expect(!GeneralSettingsView.LoginItemPresentation.off.isOn)
            #expect(!GeneralSettingsView.LoginItemPresentation.unavailable.isOn)
        }

        @Test func turningOnRegistersTheApp() async {
            let fake = FakeLoginService(.notRegistered)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.register])
            #expect(permissions.state(.launchAtLogin) == .granted)
        }

        @Test func turningOnThatNeedsApprovalOpensLoginItems() async {
            let fake = FakeLoginService(.notRegistered, statusAfterRegister: .requiresApproval)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await GeneralSettingsView.setLaunchAtLogin(true, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.register, .openSettings])
            #expect(GeneralSettingsView.loginItemPresentation(for: permissions.state(.launchAtLogin)) == .needsApproval)
        }

        @Test func turningOffUnregistersTheApp() async {
            let fake = FakeLoginService(.enabled)
            let loginItem = fake.checker
            let permissions = PermissionCenter(checkers: [loginItem])
            await permissions.refresh(.launchAtLogin)
            #expect(permissions.state(.launchAtLogin) == .granted)
            await GeneralSettingsView.setLaunchAtLogin(false, permissions: permissions, loginItem: loginItem)
            #expect(fake.calls == [.unregister])
            #expect(permissions.state(.launchAtLogin) == .notDetermined)
        }

        @Test func turningOffWithoutALoginItemOnlyRereadsTheState() async {
            let permissions = PermissionCenter(checkers: [FakeChecker(id: .launchAtLogin, states: [.notDetermined])])
            await GeneralSettingsView.setLaunchAtLogin(false, permissions: permissions, loginItem: nil)
            #expect(permissions.state(.launchAtLogin) == .notDetermined)
        }

        @Test(arguments: [
            (PermissionState.notDetermined, GeneralSettingsView.NotificationAction.request),
            (.granted, .openSettings),
            (.denied, .openSettings),
            (.requiresApproval, .openSettings),
            (.unknown("status 9"), .openSettings),
            (.notApplicable, .openSettings),
        ])
        func notificationAction(state: PermissionState, expected: GeneralSettingsView.NotificationAction) {
            #expect(GeneralSettingsView.notificationAction(for: state) == expected)
        }

        @Test func requestingNotificationsAsksTheChecker() async {
            let checker = FakeChecker(id: .notifications, states: [.notDetermined], requestStates: [.granted])
            let permissions = PermissionCenter(checkers: [checker])
            var opened: [URL] = []
            await GeneralSettingsView.performNotificationAction(.request, permissions: permissions) { opened.append($0) }
            #expect(await checker.requestCount == 1)
            #expect(permissions.state(.notifications) == .granted)
            #expect(opened.isEmpty)
        }

        @Test func openingNotificationSettingsUsesTheDeepLink() async {
            let checker = FakeChecker(id: .notifications, states: [.denied])
            let permissions = PermissionCenter(checkers: [checker])
            var opened: [URL] = []
            await GeneralSettingsView.performNotificationAction(.openSettings, permissions: permissions) { opened.append($0) }
            #expect(opened == [SystemSettingsLink.notifications.url])
            #expect(await checker.requestCount == 0)
        }
    }
}

// MARK: - Permissions

extension SettingsTests {
    @MainActor
    @Suite("Permissions settings")
    struct Permissions {
        static let withoutMove: [PermissionID] = [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications]

        /// Held by the suite so the defaults outlive every use inside a test (Task 7's rule).
        let defaults: TemporaryDefaults

        init() throws {
            defaults = try TemporaryDefaults()
        }

        @Test func cardsFollowTheMoveState() {
            #expect(PermissionsSettingsView.cards(moveState: nil) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .granted) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .notApplicable) == Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .notDetermined) == [.moveToApplications] + Self.withoutMove)
            #expect(PermissionsSettingsView.cards(moveState: .denied) == [.moveToApplications] + Self.withoutMove)
        }

        @Test(arguments: [
            (PermissionState.notDetermined, true),
            (.granted, false),
            (.notApplicable, false),
        ])
        func theMoveCardAppearsOnlyOutsideApplications(moveState: PermissionState, shown: Bool) async {
            let permissions = PermissionCenter(checkers: [
                FakeChecker(id: .moveToApplications, states: [moveState]),
                FakeChecker(id: .fullDiskAccess, states: [.denied]),
            ])
            #expect(PermissionsSettingsView.cards(moveState: permissions.states[.moveToApplications]) == Self.withoutMove)
            await permissions.refreshAll()
            let cards = PermissionsSettingsView.cards(moveState: permissions.states[.moveToApplications])
            #expect(cards.contains(.moveToApplications) == shown)
        }

        @Test func cardTitlesAndReasons() {
            let move = PermissionsSettingsView.content(for: .moveToApplications, state: .notDetermined)
            #expect(move.title == "Applications folder")
            #expect(move.actionTitle == "Move and relaunch")
            let fullDiskAccess = PermissionsSettingsView.content(for: .fullDiskAccess, state: .denied)
            #expect(fullDiskAccess.title == "Full Disk Access")
            #expect(fullDiskAccess.reason == "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.")
            #expect(fullDiskAccess.actionTitle == "Open Settings")
            let finder = PermissionsSettingsView.content(for: .automationFinder, state: .notDetermined)
            #expect(finder.title == "Finder")
            #expect(finder.reason == "Moves apps to the Trash if the usual way fails.")
            let systemEvents = PermissionsSettingsView.content(for: .automationSystemEvents, state: .notDetermined)
            #expect(systemEvents.title == "System Events")
            #expect(systemEvents.reason == "Checks which apps are running before a cleanup, and removes the login items of apps you uninstall.")
        }

        @Test(arguments: [PermissionID.automationFinder, .automationSystemEvents])
        func automationAsksUntilDeniedThenOffersSettings(id: PermissionID) {
            let fresh = PermissionsSettingsView.content(for: id, state: .notDetermined)
            #expect(fresh.actionTitle == "Allow")
            #expect(fresh.action == .request)
            let denied = PermissionsSettingsView.content(for: id, state: .denied)
            #expect(denied.actionTitle == "Open Settings")
            // A denied request opens Privacy → Automation itself (Task 9), so the action stays `request`.
            #expect(denied.action == .request)
        }

        @Test func notificationsAskOnceThenOpenSettings() {
            let fresh = PermissionsSettingsView.content(for: .notifications, state: .notDetermined)
            #expect(fresh.actionTitle == "Allow")
            #expect(fresh.action == .request)
            for state in [PermissionState.denied, .granted, .unknown("status 9")] {
                let later = PermissionsSettingsView.content(for: .notifications, state: state)
                #expect(later.actionTitle == "Open Settings")
                #expect(later.action == .open(.notifications))
            }
        }

        @Test func moveAndFullDiskAccessAlwaysRequest() {
            for state in [PermissionState.notDetermined, .denied, .unknown("no probe file")] {
                #expect(PermissionsSettingsView.content(for: .moveToApplications, state: state).action == .request)
                #expect(PermissionsSettingsView.content(for: .fullDiskAccess, state: state).action == .request)
            }
        }

        @Test func anUnansweredAutomationCheckReadsNotYet() async {
            defaults.preferences.setLastKnownState("denied", for: PermissionID.automationFinder.rawValue)
            let permissions = PermissionCenter(checkers: [
                FakeChecker(id: .automationFinder, states: [.unknown("not running")]),
                FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")]),
                FakeChecker(id: .notifications, states: [.unknown("status 9")]),
            ], preferences: defaults.preferences)
            await permissions.refreshAll()
            // System Events: nothing is stored, so the center passes the unknown answer on,
            // and the card reads "Not yet", as onboarding's does (Task 13).
            #expect(permissions.state(.automationSystemEvents) == .unknown("not running"))
            #expect(PermissionsSettingsView.cardState(.automationSystemEvents, permissions: permissions) == .notDetermined)
            // Finder: the last known state still wins.
            #expect(PermissionsSettingsView.cardState(.automationFinder, permissions: permissions) == .denied)
            // Every other card shows the state as it is.
            #expect(PermissionsSettingsView.cardState(.notifications, permissions: permissions) == .unknown("status 9"))
        }
    }
}

// MARK: - Views

extension SettingsTests {
    @MainActor
    @Suite("Settings views")
    struct Views {
        let defaults: TemporaryDefaults
        let directory: TemporaryDirectory

        init() throws {
            defaults = try TemporaryDefaults()
            directory = try TemporaryDirectory()
        }

        func checkers() -> [any PermissionChecking] {
            [
                FakeChecker(id: .moveToApplications, states: [.denied]),
                FakeChecker(id: .fullDiskAccess, states: [.granted]),
                FakeChecker(id: .automationFinder, states: [.denied]),
                FakeChecker(id: .automationSystemEvents, states: [.unknown("not running")]),
                FakeChecker(id: .notifications, states: [.notDetermined]),
            ]
        }

        @Test func tabsTitlesAndSymbols() {
            #expect(SettingsTab.allCases == [.general, .permissions, .about])
            #expect(SettingsTab.allCases.map { String(localized: $0.title) } == ["General", "Permissions", "About"])
            #expect(SettingsTab.allCases.map(\.systemImage) == ["gearshape", "hand.raised", "info.circle"])
        }

        @Test func accessibilityIdentifiers() {
            #expect(SettingsTab.allCases.map(AccessibilityID.settingsTab) == ["settings.tab.general", "settings.tab.permissions", "settings.tab.about"])
            #expect(LegalDocument.allCases.map(AccessibilityID.settingsLegalDocument) == [
                "settings.about.legal.license", "settings.about.legal.notice",
                "settings.about.legal.credits", "settings.about.legal.moleLicense",
            ])
            #expect(AccessibilityID.settingsLaunchAtLogin == "settings.general.launchAtLogin")
            #expect(AccessibilityID.settingsRevealInFinder == "settings.permissions.revealInFinder")
            #expect(AccessibilityID.settingsEngine == "settings.about.engine")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func generalRenders(scheme: ColorScheme) async throws {
            let fake = FakeLoginService(.requiresApproval)
            let loginItem = fake.checker
            let model = SettingsTests.model(defaults: defaults, checkers: checkers() + [loginItem], loginItem: loginItem)
            await model.permissions.refreshAll()
            let view = GeneralSettingsView(permissions: model.permissions, loginItem: loginItem, openURL: { _ in })
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: SettingsView.contentSize))
            #expect(image.width == Int(SettingsView.contentSize.width))
            #expect(image.height == Int(SettingsView.contentSize.height))
            #expect(fake.calls.isEmpty, "rendering must not register or open anything")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func permissionsRenders(scheme: ColorScheme) async throws {
            let model = SettingsTests.model(defaults: defaults, checkers: checkers())
            await model.permissions.refreshAll()
            #expect(PermissionsSettingsView.cards(moveState: model.permissions.states[.moveToApplications]).first == .moveToApplications)
            #expect(PermissionsSettingsView.cardState(.automationSystemEvents, permissions: model.permissions) == .notDetermined)
            let view = PermissionsSettingsView(permissions: model.permissions, openURL: { _ in })
            let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: SettingsView.contentSize))
            #expect(image.width == Int(SettingsView.contentSize.width))
            #expect(image.height == Int(SettingsView.contentSize.height))
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func aboutRendersWithAReadyEngine(scheme: ColorScheme) async throws {
            let root = try EngineLayout.make(in: directory.url, version: EngineLayout.version(for: SettingsTests.fingerprint))
            let installation = try EngineInstallation(root: root)
            let model = SettingsTests.model(defaults: defaults, engineCheck: { .success(installation) })
            await model.start()
            let info = AboutInfo(bundle: .main, engine: AboutInfo.fingerprint(for: model.engine))
            #expect(info.engineLine == "Engine V1.56.0 (239c90d, 5 patches)")
            let image = try #require(RenderCheck.image(
                of: AboutView(info: info, openURL: { _ in }),
                scheme: scheme,
                size: SettingsView.contentSize
            ))
            #expect(image.width == Int(SettingsView.contentSize.width))
        }

        @Test(arguments: LegalDocument.allCases)
        func everyDocumentRendersInItsSheet(document: LegalDocument) throws {
            let view = LegalDocumentView(document: document, text: document.text(in: .main))
            let image = try #require(RenderCheck.image(of: view, scheme: .light, size: CGSize(width: 680, height: 600)))
            #expect(image.width == 680)
            #expect(image.height == 600)
        }

        @Test func aMissingDocumentRendersItsPlaceholder() throws {
            let view = LegalDocumentView(document: .moleLicense, text: nil)
            let image = try #require(RenderCheck.image(of: view, scheme: .dark, size: CGSize(width: 680, height: 600)))
            #expect(image.width == 680)
        }
    }
}
```

- [ ] **Step 8: Run them to verify they fail**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/SettingsTests`
Expected: the test target does not compile, and the run ends `** TEST FAILED **`. The first errors are `error: cannot find 'GeneralSettingsView' in scope` and `error: cannot find type 'GeneralSettingsView' in scope`, with follow-on `cannot infer contextual base in reference to member …` errors. The compiler stops there; `AboutInfo`, `PermissionsSettingsView`, `SettingsView` and the `settings*` identifiers are missing as well.

- [ ] **Step 9: Add the Settings identifiers**

Append to `RoomForMac/App/AccessibilityID.swift`:
```swift
// MARK: - Settings (Task 14)

extension AccessibilityID {
    /// A Settings tab's content: "settings.tab.<rawValue>".
    static func settingsTab(_ tab: SettingsTab) -> String {
        "settings.tab.\(tab.rawValue)"
    }

    // General
    static let settingsLaunchAtLogin = "settings.general.launchAtLogin"
    static let settingsApproveLoginItem = "settings.general.approveLoginItem"
    static let settingsNotifications = "settings.general.notifications"
    static let settingsNotificationsAction = "settings.general.notifications.action"
    static let settingsMenuBarNote = "settings.general.menuBarNote"

    // Permissions (the cards keep their permission.* identifiers)
    static let settingsMoveByHand = "settings.permissions.moveByHand"
    static let settingsRevealInFinder = "settings.permissions.revealInFinder"

    // About
    static let settingsVersion = "settings.about.version"
    static let settingsEngine = "settings.about.engine"
    static let settingsMoleLink = "settings.about.moleLink"
    static let settingsLegalText = "settings.about.legal.text"
    static let settingsLegalDone = "settings.about.legal.done"

    /// A row of the legal documents list: "settings.about.legal.<rawValue>".
    static func settingsLegalDocument(_ document: LegalDocument) -> String {
        "settings.about.legal.\(document.rawValue)"
    }
}
```

The permission cards in the Permissions tab keep their `permission.card.<raw>`, `permission.action.<raw>` and `permission.chip.<raw>` identifiers from `PermissionCard` (Task 12). Only one Settings tab is on screen at a time. Onboarding shows the same cards in the main window, so a UI test that has both windows open scopes its query to one window.

- [ ] **Step 10: Write `AboutInfo`, `AboutView` and the document sheet**

`RoomForMac/Features/Settings/AboutView.swift`
```swift
import SwiftUI

/// What Settings → About says about this build: the app's version and build number, and the
/// engine it checked at launch.
struct AboutInfo: Equatable, Sendable {
    let appVersion: String
    let build: String
    let engine: EngineFingerprint?

    /// Shown for a version or build number the bundle does not declare.
    static let missingValue = "—"

    init(bundle: Bundle, engine: EngineFingerprint?) {
        appVersion = Self.infoString("CFBundleShortVersionString", in: bundle)
        build = Self.infoString("CFBundleVersion", in: bundle)
        self.engine = engine
    }

    /// "Engine V1.56.0 (239c90d, 5 patches)", or "Engine unavailable" before the launch check
    /// has passed. The patch count is a plural in the String Catalog ("1 patch").
    var engineLine: String {
        guard let engine else {
            return String(localized: "Engine unavailable")
        }
        let commit = Self.shortCommit(engine.moleCommit)
        return String(localized: "Engine \(engine.moleTag) (\(commit), \(engine.patchCount) patches)")
    }

    /// The first seven characters of a commit hash, as `git log --oneline` shows it.
    static func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    /// The engine to describe: the one the launch check accepted, and none while the check runs
    /// or after it failed.
    static func fingerprint(for phase: EnginePhase) -> EngineFingerprint? {
        guard case .ready(let installation) = phase else {
            return nil
        }
        return EngineFingerprint(installation.version)
    }

    private static func infoString(_ key: String, in bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return missingValue
        }
        return value
    }
}

/// Settings → About: the wordmark, version, engine, the Mole credit, the legal documents and the
/// photo credits from `CREDITS.md`.
struct AboutView: View {
    nonisolated static let moleRepository = URL(string: "https://github.com/tw93/mole")!

    private let info: AboutInfo
    private let bundle: Bundle
    private let openURL: @MainActor (URL) -> Void
    @State private var shownDocument: LegalDocument?

    init(info: AboutInfo, bundle: Bundle = .main, openURL: @escaping @MainActor (URL) -> Void) {
        self.info = info
        self.bundle = bundle
        self.openURL = openURL
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AnimatedWordmark(progress: 1)
                        .frame(height: 34)
                    Text("Version \(info.appVersion) (\(info.build))")
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier(AccessibilityID.settingsVersion)
                    Text(info.engineLine)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier(AccessibilityID.settingsEngine)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }

            Section {
                Text("RoomForMac is built on the open-source Mole engine by tw93 (GPL-3.0).")
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openURL(Self.moleRepository)
                } label: {
                    Text(verbatim: "github.com/tw93/mole")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.settingsMoleLink)
            } header: {
                Text("Engine")
            }

            Section {
                ForEach(LegalDocument.allCases) { document in
                    Button {
                        shownDocument = document
                    } label: {
                        HStack {
                            Text(document.title)
                                .foregroundStyle(Palette.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Palette.textSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.settingsLegalDocument(document))
                }
            } header: {
                Text("Licenses and notices")
            }

            if let credits = LegalDocument.credits.text(in: bundle),
               let photography = LegalDocument.section("Photography", in: credits) {
                Section {
                    // File content, shown as written (like the licence texts).
                    Text(verbatim: photography)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Photography")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $shownDocument) { document in
            LegalDocumentView(document: document, text: document.text(in: bundle))
        }
    }
}

/// One legal document in a sheet, in monospaced, selectable text.
struct LegalDocumentView: View {
    private let document: LegalDocument
    private let text: String?
    @Environment(\.dismiss) private var dismiss

    init(document: LegalDocument, text: String?) {
        self.document = document
        self.text = text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.settingsLegalDone)
            }
            .padding(16)
            Divider()
            if let text {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .accessibilityIdentifier(AccessibilityID.settingsLegalText)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("This document is missing")
                    } icon: {
                        Image(systemName: "doc.questionmark")
                    }
                } description: {
                    Text("Reinstall RoomForMac to restore it.")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 480, idealHeight: 600)
    }
}
```

- `moleRepository` is `nonisolated`: a `View`'s statics are main-actor isolated, and a nonisolated test reads it. `URL` is `Sendable`, so this is safe.
- `Text("Version \(info.appVersion) (\(info.build))")` is a `LocalizedStringKey` (`Version %@ (%@)`). `Text(info.engineLine)` takes a `String` that `String(localized:)` has already localized, so it is shown as is.

- [ ] **Step 11: Write the General tab**

`RoomForMac/Features/Settings/GeneralSettingsView.swift`
```swift
import AppKit
import SwiftUI

/// Settings → General: open at login, notifications, and a note about the menu-bar extra.
/// Both states are re-read when the tab appears and whenever RoomForMac becomes active again,
/// since either can change in System Settings.
struct GeneralSettingsView: View {
    /// How the "Open RoomForMac at login" row reads for a login-item state.
    enum LoginItemPresentation: Equatable, Sendable {
        case off
        case on
        /// Registered, waiting for the user in System Settings → Login Items.
        case needsApproval
        /// macOS gave no usable answer (ad-hoc builds report "not found").
        case unavailable

        /// The switch shows on while the item is registered, approved or not.
        var isOn: Bool {
            self == .on || self == .needsApproval
        }
    }

    /// What the notifications button does.
    enum NotificationAction: Equatable, Sendable {
        /// Shows the system prompt; macOS asks only once.
        case request
        /// Opens System Settings → Notifications, the only place a decision can change.
        case openSettings
    }

    private let permissions: PermissionCenter
    private let loginItem: LoginItemChecker?
    private let openURL: @MainActor (URL) -> Void
    @State private var isChangingLoginItem = false

    init(permissions: PermissionCenter, loginItem: LoginItemChecker?, openURL: @escaping @MainActor (URL) -> Void) {
        self.permissions = permissions
        self.loginItem = loginItem
        self.openURL = openURL
    }

    static func loginItemPresentation(for state: PermissionState) -> LoginItemPresentation {
        switch state {
        case .granted: .on
        case .requiresApproval: .needsApproval
        case .unknown: .unavailable
        case .denied, .notDetermined, .notApplicable: .off
        }
    }

    /// On registers the app through the center, which opens Login Items when macOS wants approval.
    /// Off unregisters it and reads the state back.
    static func setLaunchAtLogin(_ enabled: Bool, permissions: PermissionCenter, loginItem: LoginItemChecker?) async {
        if enabled {
            await permissions.request(.launchAtLogin)
        } else {
            _ = await loginItem?.disable()
            await permissions.refresh(.launchAtLogin)
        }
    }

    static func notificationAction(for state: PermissionState) -> NotificationAction {
        state == .notDetermined ? .request : .openSettings
    }

    static func performNotificationAction(
        _ action: NotificationAction,
        permissions: PermissionCenter,
        openURL: @MainActor (URL) -> Void
    ) async {
        switch action {
        case .request:
            await permissions.request(.notifications)
        case .openSettings:
            openURL(SystemSettingsLink.notifications.url)
        }
    }

    var body: some View {
        let login = Self.loginItemPresentation(for: permissions.state(.launchAtLogin))
        let notifications = permissions.state(.notifications)
        Form {
            Section {
                Toggle(isOn: Binding(get: { login.isOn }, set: { setLaunchAtLogin($0) })) {
                    Text("Open RoomForMac at login")
                    Text("RoomForMac starts quietly when you log in.")
                }
                .disabled(!permissions.hasChecker(.launchAtLogin) || isChangingLoginItem)
                .accessibilityIdentifier(AccessibilityID.settingsLaunchAtLogin)

                switch login {
                case .needsApproval:
                    LabeledContent {
                        Button("Approve in System Settings") {
                            openURL(SystemSettingsLink.loginItems.url)
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsApproveLoginItem)
                    } label: {
                        Text("macOS wants you to approve this in Login Items.")
                            .foregroundStyle(Palette.textSecondary)
                    }
                case .unavailable:
                    Text("macOS can't add this copy of RoomForMac to your login items. Open RoomForMac from your Applications folder and try again.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .on, .off:
                    EmptyView()
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        PermissionChip(state: notifications)
                        Button {
                            Task {
                                await Self.performNotificationAction(
                                    Self.notificationAction(for: notifications),
                                    permissions: permissions,
                                    openURL: openURL
                                )
                            }
                        } label: {
                            switch Self.notificationAction(for: notifications) {
                            case .request: Text("Allow")
                            case .openSettings: Text("Open Settings")
                            }
                        }
                        .disabled(!permissions.hasChecker(.notifications))
                        .accessibilityIdentifier(AccessibilityID.settingsNotificationsAction)
                    }
                } label: {
                    Text("Notifications")
                    Text("Lets RoomForMac tell you when a cleanup finishes.")
                }
                .accessibilityIdentifier(AccessibilityID.settingsNotifications)
            }

            Section {
                Label {
                    Text("A menu bar extra with quick gauges arrives with Status in the next update.")
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier(AccessibilityID.settingsMenuBarNote)
            }
        }
        .formStyle(.grouped)
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refresh()
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        isChangingLoginItem = true
        Task {
            await Self.setLaunchAtLogin(enabled, permissions: permissions, loginItem: loginItem)
            isChangingLoginItem = false
        }
    }

    private func refresh() async {
        await permissions.refresh(.launchAtLogin)
        await permissions.refresh(.notifications)
    }
}
```

- `setLaunchAtLogin(true)` goes through `PermissionCenter.request`, which ignores a second request while one is in flight (Task 8), so a fast double toggle cannot register twice.
- The live `LoginItemChecker` in `AppDependencies.loginItem` is the same value that `permissionCheckers` holds (Task 12), so `disable()` and the center's `refresh` act on one login item.

- [ ] **Step 12: Write the Permissions tab**

`RoomForMac/Features/Settings/PermissionsSettingsView.swift`
```swift
import AppKit
import SwiftUI

/// Settings → Permissions: the onboarding cards, with live states. Every state is re-read when
/// the tab appears and whenever RoomForMac becomes active again, for example after the user
/// changed something in System Settings.
struct PermissionsSettingsView: View {
    /// What a card's button does.
    enum CardAction: Equatable, Sendable {
        /// `PermissionCenter.request`: prompts, opens System Settings or moves the app, as the
        /// checker does. A denied Automation request opens Privacy → Automation by itself.
        case request
        /// Opens a System Settings pane directly.
        case open(SystemSettingsLink)
    }

    /// The words and the action of one card.
    struct CardContent {
        let title: LocalizedStringKey
        let reason: LocalizedStringKey
        let actionTitle: LocalizedStringKey
        let action: CardAction
    }

    private let permissions: PermissionCenter
    private let openURL: @MainActor (URL) -> Void

    init(permissions: PermissionCenter, openURL: @escaping @MainActor (URL) -> Void) {
        self.permissions = permissions
        self.openURL = openURL
    }

    /// The cards, in onboarding order. Move to Applications comes first, and only once a check
    /// has found RoomForMac outside an Applications folder: its checker answers granted when
    /// installed and "not needed" when the DEBUG bypass is on.
    static func cards(moveState: PermissionState?) -> [PermissionID] {
        var cards: [PermissionID] = [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications]
        if let moveState, !moveState.isGranted {
            cards.insert(.moveToApplications, at: 0)
        }
        return cards
    }

    /// The state a card shows, as onboarding shows it. A passive Automation check cannot answer
    /// while its target is not running (System Events usually is not), and with no last-known
    /// state stored the center passes `.unknown` on. The Finder and System Events cards read that
    /// as "Not yet" through `AutomationStep.displayState` (Task 13); every other card shows the
    /// center's state as it is.
    static func cardState(_ id: PermissionID, permissions: PermissionCenter) -> PermissionState {
        AutomationStep.permissionIDs.contains(id)
            ? AutomationStep.displayState(permissions.state(id))
            : permissions.state(id)
    }

    static func content(for id: PermissionID, state: PermissionState) -> CardContent {
        switch id {
        case .moveToApplications:
            CardContent(
                title: "Applications folder",
                reason: "RoomForMac works best from your Applications folder. One click moves it there and opens it again.",
                actionTitle: "Move and relaunch",
                action: .request
            )
        case .fullDiskAccess:
            CardContent(
                title: "Full Disk Access",
                reason: "Lets RoomForMac see caches, logs and leftovers in every folder, so scans are complete.",
                actionTitle: "Open Settings",
                action: .request
            )
        case .automationFinder, .automationSystemEvents:
            // Onboarding's Automation card, word for word: one source for the title,
            // the reason and the Allow / Open Settings rule (Task 13).
            CardContent(
                title: AutomationStep.title(for: id),
                reason: AutomationStep.reason(for: id),
                actionTitle: AutomationStep.action(for: state).title,
                action: .request
            )
        case .notifications:
            CardContent(
                title: "Notifications",
                reason: "Lets RoomForMac tell you when a cleanup finishes.",
                actionTitle: state == .notDetermined ? "Allow" : "Open Settings",
                action: state == .notDetermined ? .request : .open(.notifications)
            )
        case .launchAtLogin:
            // Never a card: cards(moveState:) leaves it out, because General owns
            // open-at-login with its switch. This case only keeps the switch
            // exhaustive, in General's own words, so it adds no catalog key.
            CardContent(
                title: "Open RoomForMac at login",
                reason: "RoomForMac starts quietly when you log in.",
                actionTitle: "Approve in System Settings",
                action: .open(.loginItems)
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RoomForMac checks these again every time you come back to it.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.cards(moveState: permissions.states[.moveToApplications]), id: \.self) { id in
                    let state = Self.cardState(id, permissions: permissions)
                    let content = Self.content(for: id, state: state)
                    PermissionCard(
                        id: id,
                        state: state,
                        title: content.title,
                        reason: content.reason,
                        actionTitle: content.actionTitle
                    ) {
                        perform(content.action, for: id)
                    }
                    if id == .moveToApplications, state == .denied {
                        moveByHand
                    }
                }
            }
            .padding(24)
        }
        .task {
            await permissions.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await permissions.refreshAll()
            }
        }
    }

    /// Shown after a failed move: the way that always works.
    private var moveByHand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Drag RoomForMac into your Applications folder, then open it from there.")
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .accessibilityIdentifier(AccessibilityID.settingsRevealInFinder)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.settingsMoveByHand)
    }

    private func perform(_ action: CardAction, for id: PermissionID) {
        switch action {
        case .request:
            Task {
                await permissions.request(id)
            }
        case .open(let link):
            openURL(link.url)
        }
    }
}
```

- The card list reads `permissions.states[.moveToApplications]`, the raw latest answer, not `state(_:)`, which reports `.notDetermined` before any check and would flash the Move card on every launch from `/Applications`.
- `cardState(_:permissions:)` gives Finder and System Events the chips onboarding shows (Allowed / Not yet / Denied). Without it, System Events would read "Unknown" in Settings on most launches while onboarding read "Not yet". The `moveByHand` condition reads the same value, which for Move is `state(_:)` unchanged.
- `cards(moveState:)` never lists `.launchAtLogin`: General shows that switch instead of a card. `content(for:state:)` still covers it, so the `switch` stays exhaustive, but only with General's wording (its label, its line and its approve button), so no key and no test exist for a card nobody sees.
- Finder and System Events come from `AutomationStep.title(for:)`, `reason(for:)` and `action(for:).title` (Task 13), so a wording change there reaches both screens. The other reasons are the onboarding ones (Task 12), so the String Catalog shares their keys.

- [ ] **Step 13: Write `SettingsView` and wire the Settings scene**

`RoomForMac/Features/Settings/SettingsView.swift`
```swift
import SwiftUI

/// The tabs of the Settings window, in order. License and Privacy arrive with the plans that
/// add licensing and analytics.
enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general, permissions, about

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// The Settings window (⌘,): General, Permissions and About. It shares the app model's
/// `PermissionCenter` with onboarding, so both always show the same states.
struct SettingsView: View {
    /// Every tab has the same size, so the window does not jump between tabs.
    static let contentSize = CGSize(width: 560, height: 540)

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        TabView {
            Tab {
                GeneralSettingsView(
                    permissions: model.permissions,
                    loginItem: model.dependencies.loginItem,
                    openURL: model.dependencies.openURL
                )
                .accessibilityIdentifier(AccessibilityID.settingsTab(.general))
            } label: {
                label(for: .general)
            }
            Tab {
                PermissionsSettingsView(permissions: model.permissions, openURL: model.dependencies.openURL)
                    .accessibilityIdentifier(AccessibilityID.settingsTab(.permissions))
            } label: {
                label(for: .permissions)
            }
            Tab {
                AboutView(
                    info: AboutInfo(bundle: .main, engine: AboutInfo.fingerprint(for: model.engine)),
                    openURL: model.dependencies.openURL
                )
                .accessibilityIdentifier(AccessibilityID.settingsTab(.about))
            } label: {
                label(for: .about)
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private func label(for tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.systemImage)
        }
    }
}
```

In `RoomForMac/App/RoomForMacApp.swift`, find Task 7's placeholder:
```swift
        Settings {
            // Replaced by SettingsView in Task 14.
            Text("Settings")
                .frame(width: 320, height: 160)
        }
```
and replace it with:
```swift
        // General, Permissions and About. It shares the model's PermissionCenter
        // with onboarding.
        Settings {
            SettingsView(model: model)
        }
```

`RoomForMacApp` builds one `AppModel` in `init`, so the main window and Settings share its `PermissionCenter`: a permission granted in onboarding shows as Allowed in Settings at once, and the reverse. The unit-test host never builds `RoomForMacApp` (Task 1), so no test opens this scene.

- [ ] **Step 14: Run the Settings tests**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/SettingsTests`
Expected: 40 tests pass and one fails, because the String Catalog has no plural for the engine line yet:
```
✘ Test engineLinePluralizesThePatchCount() recorded an issue at SettingsTests.swift:…: Expectation failed: AboutInfo(bundle: .main, engine: fingerprint).engineLine == "Engine V1.56.0 (239c90d, 1 patch)"
✘ Test run with 41 tests in 6 suites failed after … seconds with 1 issue.
** TEST FAILED **
```
No test crashes the host. A `Fatal error: no current update to enqueue action to` means a `TabView` was rendered offscreen (see Requirements, Tests).

- [ ] **Step 15: Add the new strings and the engine-line plural to the String Catalog**

`xcodebuild` does not update `Localizable.xcstrings` (only the Xcode IDE does), so sync the catalog from the `.stringsdata` files that the Step 14 build left for the app target:
```bash
OBJ=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null \
    | awk '/Build settings for action .* and target RoomForMac:/ { t = 1 } t && $1 == "OBJECT_FILE_DIR_normal" { print $3; exit }')
xcrun xcstringstool sync RoomForMac/Resources/Localizable.xcstrings --skip-marking-strings-stale --stringsdata "$OBJ"/*/*.stringsdata
git diff --stat RoomForMac/Resources/Localizable.xcstrings
```
Expected: `xcstringstool` prints nothing and exits 0. The diff adds this task's new keys, and removes nothing:
`A menu bar extra with quick gauges arrives with Status in the next update.`, `About`, `Approve in System Settings`, `Credits`, `Done`, `Engine`, `Engine %@ (%@, %lld patches)`, `Engine License (Mole)`, `Engine unavailable`, `General`, `Lets RoomForMac tell you when a cleanup finishes.`, `Licenses and notices`, `Notice`, `Permissions`, `Photography`, `Reinstall RoomForMac to restore it.`, `RoomForMac License`, `RoomForMac checks these again every time you come back to it.`, `RoomForMac is built on the open-source Mole engine by tw93 (GPL-3.0).`, `RoomForMac starts quietly when you log in.`, `This document is missing`, `Version %@ (%@)`, `macOS can't add this copy of RoomForMac to your login items. Open RoomForMac from your Applications folder and try again.`, `macOS wants you to approve this in Login Items.`

The keys this task shares with Tasks 8, 12 and 13 (`Allow`, `Applications folder`, `Checks which apps are running…`, `Drag RoomForMac into your Applications folder…`, `Finder`, `Full Disk Access`, `Lets RoomForMac see caches…`, `Move and relaunch`, `Moves apps to the Trash if the usual way fails.`, `Notifications`, `Open RoomForMac at login` (Task 13's Extras toggle), `Open Settings`, `Open at login`, `Reveal in Finder`, `RoomForMac works best from your Applications folder…`, `System Events`) are already in the catalog and do not change. If one of them is new in the diff, the earlier task used different wording, and one of the two must change.

The sync writes the multi-argument keys with an `en` value in state `new`. Now make the engine line vary by plural. In `RoomForMac/Resources/Localizable.xcstrings`, find the entry the sync added:
```json
    "Engine %@ (%@, %lld patches)" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Engine %1$@ (%2$@, %3$lld patches)"
          }
        }
      }
    },
```
and replace it with:
```json
    "Engine %@ (%@, %lld patches)" : {
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "Engine %1$@ (%2$@, %3$lld patch)"
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "Engine %1$@ (%2$@, %3$lld patches)"
                }
              }
            }
          }
        }
      }
    },
```

Task 1's placeholder `Text("Settings")` is gone, so its `"Settings"` key is now unused.
Run: `grep -rn '"Settings"' RoomForMac --include='*.swift'`
Expected: no output. Then delete the `"Settings" : { … },` entry (an empty object) from `Localizable.xcstrings`.

Check the file by compiling it the way the build does:
```bash
mkdir -p "$TMPDIR/rfm-xcstrings" && xcrun xcstringstool compile RoomForMac/Resources/Localizable.xcstrings --output-directory "$TMPDIR/rfm-xcstrings"
plutil -p "$TMPDIR/rfm-xcstrings/en.lproj/Localizable.stringsdict"
```
Expected: `compile` prints nothing and exits 0 (a JSON slip gives `error: The data couldn’t be read because it isn’t in the correct format.`). Then `plutil` shows a stringsdict whose `Engine %@ (%@, %lld patches)` entry has `NSStringLocalizedFormatKey` `%3$#@value@`, `NSStringFormatValueTypeKey` `lld`, `one` `Engine %1$@ (%2$@, %3$lld patch)` and `other` `Engine %1$@ (%2$@, %3$lld patches)`. The compiler picks the third argument, the only integer, for the plural rule. Other tasks' plural entries, if any, are listed too.

- [ ] **Step 16: Run the Settings tests to verify they pass**

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/SettingsTests`
Expected: `✔ Test run with 41 tests in 6 suites passed` and `** TEST SUCCEEDED **`. The suites are "Settings", "Legal documents" (9 tests), "About info" (9), "General settings" (9), "Permissions settings" (7) and "Settings views" (7). The parameterized tests report their cases: 4 documents, 6 login-item states, 6 notification states, 3 move states, 2 Automation targets, 2 colour schemes for each tab, and 4 document sheets.

- [ ] **Step 17: Run the whole unit scheme, the API guard and a Release build**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit clean > /dev/null \
    && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test \
    > "$TMPDIR/rfm-task-14.log" 2>&1; echo "exit $?"
grep -E '^\*\* TEST|Test run with' "$TMPDIR/rfm-task-14.log"
grep -E '(Features/Settings/|AccessibilityID\.swift|RoomForMacApp\.swift|SettingsTests\.swift).*(warning|error):' "$TMPDIR/rfm-task-14.log"
```
Expected:
- `exit 0`, `✔ Test run with … tests in … suites passed` and `** TEST SUCCEEDED **`. The summary includes this task's six suites next to those of Tasks 1–13.
- The last `grep` prints nothing: no warnings in this task's files, after a clean build.
- The build runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time.

Run: `grep -nE 'glassEffect|buttonStyle\(\.glass\(|GlassButtonStyle\(|@ContentBuilder' RoomForMac/Features/Settings/*.swift`
Expected: no output and exit status 1. Settings adds no glass of its own: the cards are Task 5's `GlassCard`s, and the window chrome is the system's.

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath build/DerivedData build 2>&1 | grep -E '^\*\*|(warning|error):' | grep -v appintentsmetadataprocessor
APP=build/DerivedData/Build/Products/Release/RoomForMac.app
for f in LICENSE NOTICE CREDITS.md; do cmp "$f" "$APP/Contents/Resources/$f" && echo "$f ok"; done
cmp vendor/mole/LICENSE "$APP/Contents/Resources/engine/LICENSE" && echo "engine/LICENSE ok"
APP="$APP" EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats
```
Expected: `** BUILD SUCCEEDED **` and nothing else from the build; `LICENSE ok`, `NOTICE ok`, `CREDITS.md ok` and `engine/LICENSE ok`; and every `app_bundle.bats` test passes. The three documents are plain files in `Contents/Resources`, so the strict deep signature check and the "no Mach-O under Resources" check still hold.

- [ ] **Step 18: Look at the Settings window**

Optional manual look, on the Debug build from Step 17:
```bash
APP=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/RoomForMac.app
open -n "$APP" --args -RFMUITestScenario onboarded
```
Press ⌘, and check:
- **General:** the "Open RoomForMac at login" switch. An ad-hoc Debug build usually reads "not found", which shows the explanation line. Notifications has a chip and one button; the menu-bar note is last.
- **Permissions:** the Full Disk Access, Finder, System Events and Notifications cards. There is no Move card, because Debug builds bypass it. Until Task 15 the scenario has no permission checkers, so the chips read "Not yet" and the buttons do nothing.
- **About:** the wordmark, "Version 0.1.0 (1)", "Engine V1.56.0 (…, 5 patches)", the Mole credit and link (the scenario's `openURL` opens nothing), the four documents, each opening a monospaced sheet that **Done** or Return closes, and the Photography line from `CREDITS.md`.
- With Reduce Transparency on (System Settings → Accessibility → Display), the cards turn solid.

Quit with ⌘Q, then run `defaults delete RoomForMac.UITest` to drop the scenario suite. A plain `open "$APP"` uses the live checkers; its Permissions tab shows real states, and pressing a button there can show real system prompts.

- [ ] **Step 19: Commit**

```bash
git add CREDITS.md project.yml \
    RoomForMac/Features/Settings/SettingsView.swift RoomForMac/Features/Settings/GeneralSettingsView.swift \
    RoomForMac/Features/Settings/PermissionsSettingsView.swift RoomForMac/Features/Settings/AboutView.swift \
    RoomForMac/Features/Settings/LegalDocument.swift \
    RoomForMac/App/RoomForMacApp.swift RoomForMac/App/AccessibilityID.swift \
    RoomForMac/Resources/Localizable.xcstrings RoomForMacTests/SettingsTests.swift
git status --short
```
Expected:
```
A  CREDITS.md
M  RoomForMac/App/AccessibilityID.swift
M  RoomForMac/App/RoomForMacApp.swift
A  RoomForMac/Features/Settings/AboutView.swift
A  RoomForMac/Features/Settings/GeneralSettingsView.swift
A  RoomForMac/Features/Settings/LegalDocument.swift
A  RoomForMac/Features/Settings/PermissionsSettingsView.swift
A  RoomForMac/Features/Settings/SettingsView.swift
M  RoomForMac/Resources/Localizable.xcstrings
A  RoomForMacTests/SettingsTests.swift
M  project.yml
```
Nothing under `RoomForMac.xcodeproj/`, `RoomForMac/Generated/` or `build/` is staged.

```bash
git commit -F - <<'EOF'
feat(app): settings with general, permissions and about

General turns open-at-login on and off through the login item and
shows the notification state with one button to allow or open System
Settings. Permissions reuses the onboarding cards with live states,
re-read on appear and whenever the app becomes active. About shows the
version, the engine line, the Mole credit, the four legal documents in
monospaced sheets and the photo credits from CREDITS.md, which the app
now bundles with LICENSE and NOTICE.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 15: DEBUG scenarios and UI smoke tests

**Files:**
- Create: `RoomForMac/Features/Permissions/ScriptedPermissionChecker.swift`, `RoomForMacUITests/OnboardingSmokeTests.swift`, `RoomForMacUITests/EngineProblemSmokeTests.swift`, `RoomForMacTests/ScenarioTests.swift`
- Create (added by this section): `RoomForMacUITests/UITestSupport.swift`. It holds the launch helper, the element lookup by exact identifier, and the identifier strings the three smoke tests share.
- Modify: `RoomForMac/App/AppDependencies.swift` (`forScenario`), `RoomForMacUITests/LaunchSmokeTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–14. By name:
  - `RuntimeMode.scenarioArgument` and `UITestScenario` (Task 1);
  - `EngineFingerprint` and `EngineProblem` (Task 3);
  - `AppDependencies`, `AppDependencies.scenarioSuiteName`, `AppPreferences` and `AppPreferences.Key`, `AppModel`, `SidebarSection`, `AccessibilityID`, and the test support `TemporaryDefaults` (Task 7);
  - `PermissionID`, `PermissionState`, `PermissionChecking` and `PermissionCenter` (Task 8);
  - `LoginItemChecker` as a type (Task 9);
  - `OnboardingStep` and `OnboardingFlow` (Task 11);
  - from Task 12: `AppDependencies.permissionCheckers`, `needsMoveStep` and `loginItem`; `AppModel.permissions` and `onboardingFlow`; `PermissionChip.label(for:)`; and `AccessibilityID.onboardingPrimary`, `onboardingStep(_:)`, `permissionAction(_:)` and `permissionChip(_:)`;
  - from Task 13: `OnboardingApply.apply`, `AccessibilityID.readyStartScan` and `summaryChip(_:)`.
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
- Added by this task (internal to this task; nothing outside this task's files uses them):
  ```swift
  #if DEBUG
  extension AppDependencies {   // declared in the struct body
      /// The scenario over a store the caller has emptied. forScenario(_:) passes the scenario
      /// suite; unit tests pass a TemporaryDefaults suite.
      static func forScenario(_ scenario: UITestScenario, defaults: UserDefaults) -> AppDependencies
      /// New scripted checkers for all six PermissionIDs, in live()'s order.
      static func scriptedPermissionCheckers() -> [any PermissionChecking]
  }
  #endif
  // RoomForMacUITests/UITestSupport.swift (the UI-test bundle cannot import the app):
  enum UIID {                  // repeats AccessibilityID's spellings; UITestIdentifierTests pins them
      static let sidebar, engineProblemCard, engineProblemCopy, onboardingPrimary, readyStartScan: String
      static func sidebarRow(_ section: String) -> String        // "sidebar.<raw>"
      static func placeholder(_ section: String) -> String       // "placeholder.<raw>"
      static func onboardingStep(_ step: String) -> String       // "onboarding.step.<raw>"
      static func permissionAction(_ permission: String) -> String  // "permission.action.<raw>"
      static func permissionChip(_ permission: String) -> String    // "permission.chip.<raw>"
      static func summaryChip(_ permission: String) -> String       // "onboarding.summary.<raw>"
  }
  enum UIWait { static let launch: TimeInterval /* 20 */; static let reaction: TimeInterval /* 10 */ }
  extension XCUIApplication {
      static func launched(scenario: String) -> XCUIApplication   // -RFMUITestScenario <raw> -AppleLanguages (en)
      func element(_ identifier: String) -> XCUIElement           // any type, identifier == exactly, firstMatch
  }
  ```
- About the skeleton's wording: "in-memory" suite means that nothing survives from one launch to the next. The suite itself is an ordinary `UserDefaults(suiteName:)` that Task 7 empties with `removePersistentDomain(forName:)` on every launch; `UserDefaults` has no in-memory suite. The signatures are unchanged.
- The memberwise `AppDependencies(...)` call below passes `permissionCheckers`, `needsMoveStep` and `loginItem` in the order Task 12 declares them, after `openURL`.

**Requirements:**
- `ScriptedPermissionChecker` exists only in DEBUG builds and never touches the system.
  - `currentState()` answers `initial` until the first `request()`, then `afterRequest` for every later call, as a real approval sticks once given. `request()` answers `afterRequest`.
  - Copies share one state through an `OSAllocatedUnfairLock<Bool>`, so the copy inside `PermissionCenter` and any other copy agree. Two separately built checkers share nothing.
- `AppDependencies.forScenario(_:)` (DEBUG only):
  - Empties the suite `RoomForMac.UITest` at launch (`removePersistentDomain(forName:)`) so every UI test starts clean, as Task 7 already does. It never touches `UserDefaults.standard`. The building itself moves to `forScenario(_:defaults:)`, so unit tests can use a throwaway suite and never race Task 7's "App dependencies" tests over the shared one.
  - Every scenario, `engine-broken` included, gets the same six scripted checkers, in `live()`'s order. Settings can still open behind the engine card, and it must not reach a live checker either.

    | Permission | Before a request | After a request |
    |---|---|---|
    | `moveToApplications` | `.notApplicable` | `.notApplicable` (like DEBUG `live()`, whose Move checker is bypassed) |
    | `fullDiskAccess` | `.denied` | `.granted` |
    | `automationFinder` | `.notDetermined` | `.granted` |
    | `automationSystemEvents` | `.notDetermined` | `.granted` |
    | `notifications` | `.notDetermined` | `.granted` |
    | `launchAtLogin` | `.notDetermined` | `.granted` |

  - `needsMoveStep` is false, and `loginItem` is nil: the login item is scripted like everything else, so there is no `LoginItemChecker` to `disable()`. `openURL` does nothing.
  - The engine checks and the onboarding flag stay as Task 7 wrote them:
    - `onboarding` and `onboarded` locate the bundled engine without the helper self-test;
    - `engine-broken` fails with `.versionMismatch(expected: .expected, found:)`, where `found` has the tag "V0.0.0";
    - only `onboarded` sets `onboardingCompleted`.
- `OnboardingSmokeTests`:
  - Launches with `["-RFMUITestScenario", "onboarding"]`.
  - For each step (Welcome, Free to explore, Full Disk Access, Finder & System Events, Admin access, Extras), it waits for `onboarding.step.<raw>`. It presses the permission actions where present (`permission.action.fullDiskAccess`; `…automationFinder` and `…automationSystemEvents`). After each one it waits until `permission.chip.<raw>` reads "Allowed". Then it waits until `onboarding.primary` is enabled, and presses it.
  - On Ready: summary chips exist for `fullDiskAccess`, `automationFinder` and `automationSystemEvents`. There is none for `moveToApplications` (no Move step in DEBUG), `notifications` or `launchAtLogin` (Extras left off). It then presses `onboarding.ready.startScan` and asserts that `sidebar` and `placeholder.smartClean` exist.
- `EngineProblemSmokeTests`:
  - `engine-broken` → `engineProblem.card` exists and `engineProblem.copy` is hittable.
  - Neither `onboarding.step.welcome` nor `sidebar` exists behind the card.
  - Copy is not clicked, because that would overwrite the tester's clipboard.
- `LaunchSmokeTests`:
  - Keeps Task 1's window check.
  - With the `onboarded` scenario, `sidebar` exists. Clicking each `sidebar.<raw>` row (Uninstaller, Status, then Smart Clean) shows its `placeholder.<raw>`, and the previous placeholder goes away.
- Every UI test launches through `XCUIApplication.launched(scenario:)`. That passes `-AppleLanguages (en)`, because the tests read the chips' English labels. The UI-test bundle cannot import the app, so `UITestSupport.swift` spells the identifiers out, and the unit suite "UI test identifiers" pins the app's side of each one.
- UI tests need Automation Mode, and `setUpWithError` does not detect it. When it is off, the run fails with "Timed out while enabling automation mode"; the implementer reports that as an environment limit, not a code failure.
- The unit `ScenarioTests.swift` covers all of this without launching the app. For each scenario it checks the scripted checkers and their states before and after a request, and that every launch gets fresh checkers. It also checks:
  - the onboarding flag, both in the preferences and in `AppModel`;
  - the flow's steps without Move;
  - the right `engineCheck` result;
  - a headless version of the onboarding walk, through `OnboardingApply` and `completeOnboarding`;
  - the launch path emptying the shared suite;
  - every identifier and raw value the UI tests spell out, and the "Allowed" label.
- This task adds no user-facing text, so the String Catalog does not change.
- A Release build compiles without any of it: no `forScenario`, no `ScriptedPermissionChecker`, and not even the suite name in the binary.
- Verify:
  - `xcodebuild … -scheme RoomForMacUnit test` is green with no compiler warnings.
  - `xcodebuild … -scheme RoomForMac build-for-testing` compiles the UI tests.
  - `xcodebuild … -scheme RoomForMac test -only-testing:RoomForMacUITests` is attempted, and its result is reported.

- [ ] **Step 1: Write the failing scripted-checker tests**

`RoomForMacTests/ScenarioTests.swift` (this step writes its first suite; Step 5 appends two more):
```swift
import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Scripted permission checker")
struct ScriptedPermissionCheckerTests {
    @Test func answersTheInitialStateUntilRequested() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        #expect(checker.id == .fullDiskAccess)
        #expect(await checker.currentState() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func aRequestAnswersAndTheAnswerSticks() async {
        let checker = ScriptedPermissionChecker(id: .automationFinder, initial: .notDetermined, afterRequest: .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
        #expect(await checker.request() == .granted)
        #expect(await checker.currentState() == .granted)
    }

    @Test func copiesShareOneState() async {
        let checker = ScriptedPermissionChecker(id: .notifications, initial: .notDetermined, afterRequest: .denied)
        let copy = checker
        #expect(await copy.request() == .denied)
        #expect(await checker.currentState() == .denied)
    }

    @Test func checkersDoNotShareState() async {
        let requested = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        let untouched = ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted)
        _ = await requested.request()
        #expect(await untouched.currentState() == .notDetermined)
    }

    /// What the Full Disk Access step does: poll while the user opens Settings. The poll ends
    /// once the scripted request has granted.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aPollEndsOnceTheRequestGrants() async {
        let checker = ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted)
        let center = PermissionCenter(checkers: [checker], sleep: { _ in await Task.yield() })
        await center.refresh(.fullDiskAccess)
        #expect(center.state(.fullDiskAccess) == .denied)

        async let polling: Void = center.poll(.fullDiskAccess)
        await center.request(.fullDiskAccess)
        await polling

        #expect(center.state(.fullDiskAccess) == .granted)
    }
}
```

- `MoleEngine` is imported now for the suites Step 5 appends.
- The poll test injects a `sleep` that only yields. `poll` and `request` then interleave on the main actor exactly as on the Full Disk Access step, without waiting a real second per round. The time limit turns a poll that never ends into a failure instead of a hung run.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ScriptedPermissionCheckerTests`
Expected: `** TEST FAILED **` (exit 65). The app target builds, and the test target stops at `RoomForMacTests/ScenarioTests.swift:9:23: error: cannot find 'ScriptedPermissionChecker' in scope`, with the same error on the other `ScriptedPermissionChecker(` lines.

- [ ] **Step 3: Write `ScriptedPermissionChecker`**

`RoomForMac/Features/Permissions/ScriptedPermissionChecker.swift`:
```swift
#if DEBUG
import os

/// A permission checker for UI-test scenarios, in DEBUG builds only. It never touches the
/// system: it answers `initial` until the first `request()`, then `afterRequest` from then on,
/// the way a real approval sticks once the user gives it.
///
/// Copies share one state, because they share the lock's storage. So the copy inside
/// `PermissionCenter` and any other copy always give the same answer.
struct ScriptedPermissionChecker: PermissionChecking {
    let id: PermissionID
    private let initial: PermissionState
    private let afterRequest: PermissionState
    private let wasRequested = OSAllocatedUnfairLock(initialState: false)

    init(id: PermissionID, initial: PermissionState, afterRequest: PermissionState) {
        self.id = id
        self.initial = initial
        self.afterRequest = afterRequest
    }

    func currentState() async -> PermissionState {
        wasRequested.withLock { $0 } ? afterRequest : initial
    }

    func request() async -> PermissionState {
        wasRequested.withLock { $0 = true }
        return afterRequest
    }
}
#endif
```

- `OSAllocatedUnfairLock<Bool>` is `Sendable`, so the struct conforms to `PermissionChecking` (which is `Sendable`) with no `@unchecked`. Task 8's `BlockingCall` uses the same lock.
- The whole file is `#if DEBUG`, so a Release build has no scripted checker to wire in by mistake.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ScriptedPermissionCheckerTests`
Expected: `✔ Suite "Scripted permission checker" passed`, `✔ Test run with 5 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing scenario and identifier tests**

Append to the end of `RoomForMacTests/ScenarioTests.swift`:
```swift

/// The UI-test scenarios, built over a throwaway suite so these tests never race the
/// "App dependencies" tests over `RoomForMac.UITest`. The one test of the launch path that
/// uses that suite is synchronous and on the main actor, so it cannot interleave with them.
@MainActor
@Suite("UI test scenarios")
struct ScenarioTests {
    /// Every approval a scenario scripts, in `live()`'s order. Written out here rather than
    /// read from the app, so a change to a scenario fails a test.
    private static let script: [(id: PermissionID, initial: PermissionState, afterRequest: PermissionState)] = [
        (.moveToApplications, .notApplicable, .notApplicable),
        (.fullDiskAccess, .denied, .granted),
        (.automationFinder, .notDetermined, .granted),
        (.automationSystemEvents, .notDetermined, .granted),
        (.notifications, .notDetermined, .granted),
        (.launchAtLogin, .notDetermined, .granted),
    ]

    private let temporary: TemporaryDefaults

    init() throws {
        temporary = try TemporaryDefaults()
    }

    private func dependencies(_ scenario: UITestScenario) -> AppDependencies {
        AppDependencies.forScenario(scenario, defaults: temporary.defaults)
    }

    @Test(arguments: UITestScenario.allCases)
    func everyScenarioScriptsEveryApproval(scenario: UITestScenario) {
        let dependencies = dependencies(scenario)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
        #expect(dependencies.loginItem == nil)
    }

    @Test(arguments: UITestScenario.allCases)
    func scriptedApprovalsGrantWhenRequested(scenario: UITestScenario) async {
        let checkers = dependencies(scenario).permissionCheckers
        #expect(checkers.count == Self.script.count)
        for (checker, expected) in zip(checkers, Self.script) {
            #expect(await checker.currentState() == expected.initial, "\(expected.id) before a request")
            #expect(await checker.request() == expected.afterRequest, "\(expected.id) when requested")
            #expect(await checker.currentState() == expected.afterRequest, "\(expected.id) after a request")
        }
    }

    @Test func everyLaunchScriptsFreshApprovals() async throws {
        let first = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await first.request() == .granted)
        let second = try #require(dependencies(.onboarding).permissionCheckers.first { $0.id == .fullDiskAccess })
        #expect(await second.currentState() == .denied)
    }

    @Test(arguments: UITestScenario.allCases)
    func onlyTheOnboardedScenarioSkipsOnboarding(scenario: UITestScenario) {
        let model = AppModel(dependencies: dependencies(scenario))
        let onboarded = scenario == .onboarded
        #expect(temporary.preferences.onboardingCompleted == onboarded)
        #expect(model.isOnboarded == onboarded)
        #expect((model.onboardingFlow == nil) == onboarded)
    }

    @Test func theOnboardingScenarioStartsAtWelcomeWithoutTheMoveStep() throws {
        let flow = try #require(AppModel(dependencies: dependencies(.onboarding)).onboardingFlow)
        #expect(flow.step == .welcome)
        #expect(flow.steps == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras, .ready])
    }

    @Test(arguments: [UITestScenario.onboarding, .onboarded])
    func theWorkingScenariosFindTheBundledEngine(scenario: UITestScenario) async throws {
        let installation = try await dependencies(scenario).engineCheck().get()
        #expect(installation.root.path.hasSuffix("RoomForMac.app/Contents/Resources/engine"))
        #expect(installation == (try EngineInstallation.bundled()))
    }

    @Test func theBrokenEngineScenarioReportsAVersionMismatch() async {
        var found = EngineFingerprint.expected
        found.moleTag = "V0.0.0"
        let result = await dependencies(.engineBroken).engineCheck()
        #expect(result == .failure(.versionMismatch(expected: .expected, found: found)))
    }

    /// The onboarding smoke test's walk, without the UI: every approval granted, the Extras
    /// choices applied, and the app on Smart Clean with the first scan queued.
    @Test func theOnboardingScenarioWalksThroughToSmartClean() async throws {
        let model = AppModel(dependencies: dependencies(.onboarding))
        let flow = try #require(model.onboardingFlow)
        let permissions = model.permissions
        await permissions.refreshAll()
        #expect(permissions.state(.fullDiskAccess) == .denied)
        #expect(permissions.state(.automationFinder) == .notDetermined)

        var visited: [OnboardingStep] = []
        for _ in OnboardingStep.allCases where flow.step != .ready {
            visited.append(flow.step)
            switch flow.step {
            case .fullDiskAccess:
                await permissions.request(.fullDiskAccess)
            case .automation:
                await permissions.request(.automationFinder)
                await permissions.request(.automationSystemEvents)
            case .extras:
                flow.choices.notifications = true
                flow.choices.launchAtLogin = true
            case .welcome, .freeToExplore, .moveToApplications, .adminAccess, .ready:
                break
            }
            flow.next()
        }
        #expect(visited == [.welcome, .freeToExplore, .fullDiskAccess, .automation, .adminAccess, .extras])
        #expect(flow.step == .ready)
        let summary = flow.summary()
        #expect(summary.map(\.id) == [.fullDiskAccess, .automationFinder, .automationSystemEvents, .notifications, .launchAtLogin])
        #expect(summary.prefix(3).allSatisfy { $0.granted })

        let loginItem = model.dependencies.loginItem
        await flow.finish { choices in
            await OnboardingApply.apply(choices, permissions: permissions, loginItem: loginItem)
        }
        model.completeOnboarding(startFirstScan: true)

        #expect(permissions.state(.notifications) == .granted)
        #expect(permissions.state(.launchAtLogin) == .granted)
        #expect(model.isOnboarded)
        #expect(model.onboardingFlow == nil)
        #expect(model.selection == .smartClean)
        #expect(model.pendingFirstScan)
        #expect(temporary.preferences.onboardingCompleted)
        #expect(temporary.preferences.onboardingStep == nil)
    }

    /// The path a UI-test launch takes: the scenario suite is emptied, then scripted.
    @Test func theLaunchPathEmptiesTheScenarioSuiteAndScriptsEveryApproval() throws {
        let suiteName = AppDependencies.scenarioSuiteName
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("automation", forKey: AppPreferences.Key.onboardingStep)

        let dependencies = AppDependencies.forScenario(.onboarding)

        #expect(dependencies.preferences.onboardingStep == nil)
        #expect(dependencies.permissionCheckers.map(\.id) == Self.script.map(\.id))
        #expect(dependencies.permissionCheckers.allSatisfy { $0 is ScriptedPermissionChecker })
        #expect(dependencies.needsMoveStep == false)
    }
}

/// UI tests run in their own process and cannot import the app, so
/// `RoomForMacUITests/UITestSupport.swift` spells these values out. This pins both spellings.
@MainActor
@Suite("UI test identifiers")
struct UITestIdentifierTests {
    @Test func scenarioArguments() {
        #expect(RuntimeMode.scenarioArgument == "-RFMUITestScenario")
        #expect(UITestScenario.allCases.map(\.rawValue) == ["onboarding", "onboarded", "engine-broken"])
    }

    @Test func mainWindowIdentifiers() {
        #expect(AccessibilityID.sidebar == "sidebar")
        #expect(SidebarSection.allCases.map(AccessibilityID.sidebarRow)
            == ["sidebar.smartClean", "sidebar.uninstaller", "sidebar.status"])
        #expect(SidebarSection.allCases.map(AccessibilityID.placeholder)
            == ["placeholder.smartClean", "placeholder.uninstaller", "placeholder.status"])
        #expect(AccessibilityID.engineProblemCard == "engineProblem.card")
        #expect(AccessibilityID.engineProblemCopy == "engineProblem.copy")
    }

    @Test func onboardingIdentifiers() {
        #expect(AccessibilityID.onboardingPrimary == "onboarding.primary")
        #expect(AccessibilityID.readyStartScan == "onboarding.ready.startScan")
        #expect(OnboardingStep.allCases.map(AccessibilityID.onboardingStep) == [
            "onboarding.step.welcome", "onboarding.step.freeToExplore", "onboarding.step.moveToApplications",
            "onboarding.step.fullDiskAccess", "onboarding.step.automation", "onboarding.step.adminAccess",
            "onboarding.step.extras", "onboarding.step.ready",
        ])
        #expect(AccessibilityID.permissionAction(.fullDiskAccess) == "permission.action.fullDiskAccess")
        #expect(AccessibilityID.permissionAction(.automationFinder) == "permission.action.automationFinder")
        #expect(AccessibilityID.permissionAction(.automationSystemEvents) == "permission.action.automationSystemEvents")
        #expect(AccessibilityID.permissionChip(.fullDiskAccess) == "permission.chip.fullDiskAccess")
        #expect(AccessibilityID.permissionChip(.automationFinder) == "permission.chip.automationFinder")
        #expect(AccessibilityID.permissionChip(.automationSystemEvents) == "permission.chip.automationSystemEvents")
        #expect(PermissionID.allCases.map(AccessibilityID.summaryChip) == [
            "onboarding.summary.moveToApplications", "onboarding.summary.fullDiskAccess",
            "onboarding.summary.automationFinder", "onboarding.summary.automationSystemEvents",
            "onboarding.summary.notifications", "onboarding.summary.launchAtLogin",
        ])
    }

    @Test func theGrantedChipReadsAllowed() {
        #expect(String(localized: PermissionChip.label(for: .granted)) == "Allowed")
    }
}
```

Notes:
- The expected script is written out in the test. Reading it back from `scriptedPermissionCheckers()` would let a changed scenario pass.
- `summary.prefix(3).allSatisfy { $0.granted }` uses a closure. A key path there (`allSatisfy(\.granted)`) does not compile inside `#expect`: the macro's expansion calls the `rethrows` `allSatisfy` without `try` (seen with Xcode 27 while planning).
- `theWorkingScenariosFindTheBundledEngine` relies on Task 2's "Embed engine" phase, which puts the engine into the test host, as `EmbeddedEngineTests` does.
- The walk test uses only what Tasks 11–13 promise: `next()`, `choices`, `summary()`, `finish(apply:)`, `OnboardingApply.apply` and `completeOnboarding`. With both Extras on, `OnboardingApply` requests notifications and the login item, and the scripted checkers grant them.
- `UITestIdentifierTests` is `@MainActor` because `PermissionChip` is a `View`, and its static members are main-actor isolated.

- [ ] **Step 6: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ScriptedPermissionCheckerTests -only-testing:RoomForMacTests/ScenarioTests -only-testing:RoomForMacTests/UITestIdentifierTests`
Expected: `** TEST FAILED **` (exit 65). The test target stops at exactly one error, `RoomForMacTests/ScenarioTests.swift:79:67: error: extra argument 'defaults' in call`, because `forScenario(_:defaults:)` does not exist yet.

- [ ] **Step 7: Script every approval in `forScenario`**

In `RoomForMac/App/AppDependencies.swift`, replace the whole `#if DEBUG` … `#endif` block at the end of the struct with this block. It starts at `/// The UserDefaults suite UI-test scenarios use` and ends after `bundledEngineWithoutSelfTest`. `live()` and `forMode(_:)` above it do not change.
```swift
    #if DEBUG
    /// The UserDefaults suite UI-test scenarios use instead of the app's own domain.
    static let scenarioSuiteName = "RoomForMac.UITest"

    /// A scripted launch for UI tests. The scenario suite is emptied first, so every
    /// launch starts clean, and `UserDefaults.standard` is never touched.
    static func forScenario(_ scenario: UITestScenario) -> AppDependencies {
        guard let defaults = UserDefaults(suiteName: scenarioSuiteName) else {
            preconditionFailure("UserDefaults refused the suite \(scenarioSuiteName)")
        }
        defaults.removePersistentDomain(forName: scenarioSuiteName)
        return forScenario(scenario, defaults: defaults)
    }

    /// The scenario over `defaults`, which the caller has emptied: `forScenario(_:)` passes
    /// the scenario suite, and unit tests a throwaway one.
    ///
    /// - `.onboarding` and `.onboarded` find the bundled engine without its helper self-test;
    ///   `.engineBroken` reports a version mismatch.
    /// - Only `.onboarded` starts with onboarding complete.
    /// - Every scenario gets scripted approvals, so neither onboarding nor Settings ever
    ///   reaches TCC, Apple events, notifications or login items. There is no Move step and
    ///   no login item to disable, and links are not opened.
    static func forScenario(_ scenario: UITestScenario, defaults: UserDefaults) -> AppDependencies {
        let preferences = AppPreferences(defaults: defaults)
        preferences.onboardingCompleted = scenario == .onboarded

        let engineCheck: @Sendable () async -> Result<EngineInstallation, EngineProblem>
        switch scenario {
        case .onboarding, .onboarded:
            engineCheck = { bundledEngineWithoutSelfTest() }
        case .engineBroken:
            var found = EngineFingerprint.expected
            found.moleTag = "V0.0.0"
            let problem = EngineProblem.versionMismatch(expected: .expected, found: found)
            engineCheck = { .failure(problem) }
        }
        return AppDependencies(
            preferences: preferences,
            engineCheck: engineCheck,
            openURL: { _ in },
            permissionCheckers: scriptedPermissionCheckers(),
            needsMoveStep: false,
            loginItem: nil
        )
    }

    /// New scripted checkers for every approval, in `live()`'s order. Each request grants at
    /// once, so a UI test can press every "Allow" and see "Allowed". The Move checker answers
    /// `.notApplicable`, as the bypassed `AppLocationChecker` of a DEBUG `live()` does.
    static func scriptedPermissionCheckers() -> [any PermissionChecking] {
        [
            ScriptedPermissionChecker(id: .moveToApplications, initial: .notApplicable, afterRequest: .notApplicable),
            ScriptedPermissionChecker(id: .fullDiskAccess, initial: .denied, afterRequest: .granted),
            ScriptedPermissionChecker(id: .automationFinder, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .automationSystemEvents, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .notifications, initial: .notDetermined, afterRequest: .granted),
            ScriptedPermissionChecker(id: .launchAtLogin, initial: .notDetermined, afterRequest: .granted),
        ]
    }

    /// Locates the bundled engine without running its helpers, so UI tests do not
    /// depend on how fast the Go binaries start.
    private nonisolated static func bundledEngineWithoutSelfTest() -> Result<EngineInstallation, EngineProblem> {
        do {
            return .success(try EngineInstallation.bundled())
        } catch EngineError.installationInvalid(let message) {
            return .failure(.installationInvalid(message))
        } catch {
            return .failure(.installationInvalid(String(describing: error)))
        }
    }
    #endif
```

- `scriptedPermissionCheckers()` builds new checkers on every call. A cached array would carry one launch's grants into the next `AppModel` (`everyLaunchScriptsFreshApprovals` pins this).
- `engine-broken` gets the same checkers. The card blocks the main window, but ⌘, still opens Settings, whose Permissions tab refreshes every checker (Task 14).
- `loginItem` is nil because the login item is one of the scripted checkers. Extras still turn it on through `PermissionCenter.request(.launchAtLogin)`. `OnboardingApply`'s `disable()` branch has nothing to call, and Task 13's unit tests cover that branch.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test -only-testing:RoomForMacTests/ScriptedPermissionCheckerTests -only-testing:RoomForMacTests/ScenarioTests -only-testing:RoomForMacTests/UITestIdentifierTests`
Expected: `✔ Test run with 18 tests in 3 suites passed` and `** TEST SUCCEEDED **`:
- "Scripted permission checker": 5 tests.
- "UI test scenarios": 9 tests. The parameterized ones report their cases: `everyScenarioScriptsEveryApproval(scenario:)` 3, `scriptedApprovalsGrantWhenRequested(scenario:)` 3, `onlyTheOnboardedScenarioSkipsOnboarding(scenario:)` 3, `theWorkingScenariosFindTheBundledEngine(scenario:)` 2.
- "UI test identifiers": 4 tests.

- [ ] **Step 9: Write the UI-test support and the smoke tests**

`RoomForMacUITests/UITestSupport.swift`:
```swift
import XCTest

/// The accessibility identifiers the smoke tests look for. UI tests run in their own process
/// and cannot import the app, so these repeat `AccessibilityID`'s spellings.
/// `UITestIdentifierTests`, in the unit tests, pins the app's side of every one.
enum UIID {
    static let sidebar = "sidebar"
    static let engineProblemCard = "engineProblem.card"
    static let engineProblemCopy = "engineProblem.copy"
    static let onboardingPrimary = "onboarding.primary"
    static let readyStartScan = "onboarding.ready.startScan"

    static func sidebarRow(_ section: String) -> String {
        "sidebar.\(section)"
    }

    static func placeholder(_ section: String) -> String {
        "placeholder.\(section)"
    }

    static func onboardingStep(_ step: String) -> String {
        "onboarding.step.\(step)"
    }

    static func permissionAction(_ permission: String) -> String {
        "permission.action.\(permission)"
    }

    static func permissionChip(_ permission: String) -> String {
        "permission.chip.\(permission)"
    }

    static func summaryChip(_ permission: String) -> String {
        "onboarding.summary.\(permission)"
    }
}

/// How long the smoke tests wait, in seconds. Generous, because CI runners are slow.
enum UIWait {
    /// From launch to the first screen. The app first locates its bundled engine.
    static let launch: TimeInterval = 20
    /// For the app to react to a click.
    static let reaction: TimeInterval = 10
}

extension XCUIApplication {
    /// Launches a fresh RoomForMac in a DEBUG scenario (`-RFMUITestScenario <raw>`), in
    /// English, because the tests read the permission chips' labels.
    static func launched(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RFMUITestScenario", scenario, "-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    /// The first element of any type whose accessibility identifier is exactly `identifier`.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
```

`RoomForMacUITests/OnboardingSmokeTests.swift`:
```swift
import XCTest

/// Walks the whole onboarding in the `onboarding` scenario: empty preferences, the bundled
/// engine, and scripted approvals that grant the moment they are requested, so no system
/// prompt ever appears.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class OnboardingSmokeTests: XCTestCase {
    /// The steps of a DEBUG build, which has no Move to Applications step, each with the
    /// approvals its cards ask for. Ready is checked separately.
    private let walk: [(step: String, approvals: [String])] = [
        ("welcome", []),
        ("freeToExplore", []),
        ("fullDiskAccess", ["fullDiskAccess"]),
        ("automation", ["automationFinder", "automationSystemEvents"]),
        ("adminAccess", []),
        ("extras", []),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingWalksEveryStepToSmartClean() throws {
        let app = XCUIApplication.launched(scenario: "onboarding")

        for (step, approvals) in walk {
            XCTAssertTrue(
                app.element(UIID.onboardingStep(step)).waitForExistence(timeout: UIWait.launch),
                "The \(step) step did not appear"
            )
            for approval in approvals {
                let action = app.element(UIID.permissionAction(approval))
                XCTAssertTrue(action.waitForExistence(timeout: UIWait.reaction), "No button asks for \(approval)")
                action.click()
                XCTAssertTrue(
                    app.element(UIID.permissionChip(approval)).wait(for: \.label, toEqual: "Allowed", timeout: UIWait.reaction),
                    "\(approval) did not turn Allowed"
                )
            }
            let primary = app.element(UIID.onboardingPrimary)
            XCTAssertTrue(
                primary.wait(for: \.isEnabled, toEqual: true, timeout: UIWait.reaction),
                "The primary button stayed disabled on \(step)"
            )
            primary.click()
        }

        XCTAssertTrue(app.element(UIID.onboardingStep("ready")).waitForExistence(timeout: UIWait.reaction))
        for granted in ["fullDiskAccess", "automationFinder", "automationSystemEvents"] {
            XCTAssertTrue(
                app.element(UIID.summaryChip(granted)).waitForExistence(timeout: UIWait.reaction),
                "Ready has no chip for \(granted)"
            )
        }
        // No Move step in a DEBUG build, and Extras were left off.
        for absent in ["moveToApplications", "notifications", "launchAtLogin"] {
            XCTAssertFalse(app.element(UIID.summaryChip(absent)).exists, "Ready shows a chip for \(absent)")
        }

        let startScan = app.element(UIID.readyStartScan)
        XCTAssertTrue(startScan.waitForExistence(timeout: UIWait.reaction))
        startScan.click()

        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.reaction))
        XCTAssertTrue(app.element(UIID.placeholder("smartClean")).waitForExistence(timeout: UIWait.reaction))
    }
}
```

`RoomForMacUITests/EngineProblemSmokeTests.swift`:
```swift
import XCTest

/// The `engine-broken` scenario: the launch check reports a version mismatch, and the
/// blocking Reinstall card replaces everything else.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class EngineProblemSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testABrokenEngineShowsOnlyTheReinstallCard() throws {
        let app = XCUIApplication.launched(scenario: "engine-broken")

        XCTAssertTrue(app.element(UIID.engineProblemCard).waitForExistence(timeout: UIWait.launch))
        let copy = app.element(UIID.engineProblemCopy)
        XCTAssertTrue(copy.waitForExistence(timeout: UIWait.reaction))
        // Not clicked: it would overwrite the clipboard of whoever runs the tests.
        XCTAssertTrue(copy.isHittable)

        // The card blocks the app: no onboarding and no sidebar behind it.
        XCTAssertFalse(app.element(UIID.onboardingStep("welcome")).exists)
        XCTAssertFalse(app.element(UIID.sidebar).exists)
    }
}
```

`RoomForMacUITests/LaunchSmokeTests.swift` (whole file; Task 1's window check stays):
```swift
import XCTest

/// The `onboarded` scenario: onboarding is complete, so the app opens on the sidebar.
///
/// UI tests need Automation Mode. Without it, xcodebuild fails with "Timed out while enabling
/// automation mode", an environment limit rather than a code failure.
final class LaunchSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsAWindow() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: UIWait.launch))
    }

    @MainActor
    func testEverySidebarRowShowsItsPlaceholder() throws {
        let app = XCUIApplication.launched(scenario: "onboarded")
        XCTAssertTrue(app.element(UIID.sidebar).waitForExistence(timeout: UIWait.launch))
        XCTAssertTrue(app.element(UIID.placeholder("smartClean")).waitForExistence(timeout: UIWait.reaction))

        // Smart Clean is selected at launch, so it comes last, after the other two.
        var shown = "smartClean"
        for section in ["uninstaller", "status", "smartClean"] {
            app.element(UIID.sidebarRow(section)).click()
            XCTAssertTrue(
                app.element(UIID.placeholder(section)).waitForExistence(timeout: UIWait.reaction),
                "Clicking \(section) did not show its placeholder"
            )
            XCTAssertTrue(
                app.element(UIID.placeholder(shown)).waitForNonExistence(timeout: UIWait.reaction),
                "The \(shown) placeholder stayed after clicking \(section)"
            )
            shown = section
        }
    }
}
```

About these tests:
- In the SDK 27 `XCUIAutomation` framework, `XCUIApplication` and `XCUIElement` are `@MainActor`. So the test methods are `@MainActor`, and the helpers in the extension inherit that isolation.
- `element(_:)` matches `identifier` exactly. The plain subscript (`app.buttons["…"]`) also matches labels and titles.
- The helper queries any element type, because the identifiers sit on different kinds of element. Task 7 found that `sidebar` is an outline, a sidebar row's identifier sits on the row's static text, and each placeholder is a group. Buttons carry the action and primary identifiers. A chip is one combined element whose label is its text: Task 12 sets `.accessibilityElement(children: .ignore)` and `.accessibilityLabel`.
- `wait(for:toEqual:timeout:)` and `waitForNonExistence(timeout:)` are in Xcode 27's `XCUIAutomation` interface and headers (checked), and Step 10 compiles against them.
- The Full Disk Access step keeps its card and chip identifiers after the grant (Task 12's granted badge). So the same chip is found before and after the click, and its label changes from "Denied" to "Allowed".
- Task 12 disables the primary button on Full Disk Access until access is granted. The test waits for `isEnabled` on every step instead of assuming which steps gate it.

- [ ] **Step 10: Build the app and all tests**

Run:
```bash
xcodegen generate && xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS build-for-testing 2>&1 \
    | grep -E '^\*\* |^(/.*: )?(warning|error): ' | grep -v appintentsmetadataprocessor
```
Expected: `** TEST BUILD SUCCEEDED **` and nothing else. The four `RoomForMacUITests` files compile under Swift 6 with complete concurrency checking, and nothing in the app or the tests warns.

- [ ] **Step 11: Run the whole unit scheme**

Run:
```bash
mkdir -p build
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test > build/task15-unit.log 2>&1; echo "exit $?"
grep -E '^\*\* TEST|Test run with|Suite "(App dependencies|Scripted permission checker|UI test scenarios|UI test identifiers)" ' build/task15-unit.log
grep -E '^(/.*: )?(warning|error): ' build/task15-unit.log
```
Expected:
- `exit 0`.
- The four suites passed: Task 7's "App dependencies" still passes on top of the new `forScenario`.
- `✔ Test run with … tests in … suites passed`: Tasks 1–14's tests plus this task's 18 tests in 3 suites.
- `** TEST SUCCEEDED **`.
- The last `grep` prints nothing.

The scheme runs Task 2's "Prepare engine" phase, so no other engine build may run at the same time. `build/` is git-ignored.

- [ ] **Step 12: Check that Release ships no scenario code**

Run:
```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build 2>&1 \
    | grep -E '^\*\* |^(/.*: )?(warning|error): ' | grep -v appintentsmetadataprocessor
if grep -q 'RoomForMac.UITest' build/DerivedData/Build/Products/Release/RoomForMac.app/Contents/MacOS/RoomForMac; then
    echo "scenario code shipped"
else
    echo "no scenario code in Release"
fi
```
Expected: `** BUILD SUCCEEDED **`, then `no scenario code in Release`.
- The Release configuration has no `DEBUG`, so `forScenario`, `forScenario(_:defaults:)`, `scriptedPermissionCheckers()`, `ScriptedPermissionChecker` and the suite name are all compiled out.
- `RuntimeMode` still recognises the `-RFMUITestScenario` flag in Release, but ignores it (Task 1).

- [ ] **Step 13: Confirm the String Catalog does not change**

Run:
```bash
OBJ=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -showBuildSettings 2>/dev/null \
    | awk '/Build settings for action .* and target RoomForMac:/ { t = 1 } t && $1 == "OBJECT_FILE_DIR_normal" { print $3; exit }')
for file in ScriptedPermissionChecker AppDependencies; do
    printf '%s: ' "$file"
    plutil -extract tables json -o - "$OBJ/arm64/$file.stringsdata"
    echo
done
git status --short RoomForMac/Resources/Localizable.xcstrings
```
Expected: `ScriptedPermissionChecker: {}` and `AppDependencies: {}`, and no status line for the catalog. The build extracts no string from this task's app code. The `preconditionFailure` message is a developer diagnostic, not UI copy. Test code is never extracted into the app's catalog.

- [ ] **Step 14: Run the UI tests, and report the result**

Run: `automationmodetool`
Then attempt:

Run: `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS test -only-testing:RoomForMacUITests`

With Automation Mode available, the run passes. That is the case when `automationmodetool` printed a line containing `DOES NOT REQUIRE`, or when someone at the Mac approves the password or Touch ID prompt. Expected:
- `Executed 4 tests, with 0 failures` and `** TEST SUCCEEDED **`: `LaunchSmokeTests` (2), `OnboardingSmokeTests` (1) and `EngineProblemSmokeTests` (1).
- The onboarding test takes the longest: one launch and seven screens.

Without Automation Mode the run fails. On this Mac `automationmodetool` prints `Automation Mode is disabled.` and `This device requires user authentication to enable Automation Mode.`, and nobody approves the prompt. After about 90 s the run fails with `Failed to initialize for UI testing: … Timed out while enabling automation mode.` (exit 65).
- Report it as "UI smoke tests not run: Automation Mode needs authentication". It is an environment limit, not a code failure.
- Step 10 already proved that they compile. GitHub's runners have Automation Mode enabled, and Task 17 runs these tests there.
- To enable it locally, either run the tests while at the Mac and approve the prompt, or have the owner run `sudo automationmodetool enable-automationmode-without-authentication` once.

Optional manual walk-through, which needs no Automation Mode:
```bash
APP=$(xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/RoomForMac.app
open -n "$APP" --args -RFMUITestScenario onboarding
```
- Expected: onboarding opens at Welcome, with no Move step.
- On Full Disk Access, "Open Settings" turns the chip to "Allowed" at once. No System Settings window opens and no system prompt appears.
- The two Automation "Allow" buttons do the same.
- "Start first scan" lands on Smart Clean.
- Quit with ⌘Q, then run `defaults delete RoomForMac.UITest` to drop the scenario suite.

- [ ] **Step 15: Commit**

```bash
git add RoomForMac/Features/Permissions/ScriptedPermissionChecker.swift RoomForMac/App/AppDependencies.swift \
    RoomForMacTests/ScenarioTests.swift \
    RoomForMacUITests/UITestSupport.swift RoomForMacUITests/OnboardingSmokeTests.swift \
    RoomForMacUITests/EngineProblemSmokeTests.swift RoomForMacUITests/LaunchSmokeTests.swift
git status --short
```
Expected:
```
M  RoomForMac/App/AppDependencies.swift
A  RoomForMac/Features/Permissions/ScriptedPermissionChecker.swift
A  RoomForMacTests/ScenarioTests.swift
A  RoomForMacUITests/EngineProblemSmokeTests.swift
M  RoomForMacUITests/LaunchSmokeTests.swift
A  RoomForMacUITests/OnboardingSmokeTests.swift
A  RoomForMacUITests/UITestSupport.swift
```
Nothing under `RoomForMac.xcodeproj/`, `RoomForMac/Generated/` or `build/` is staged.

```bash
git commit -F - <<'EOF'
test(app): scripted UI-test scenarios and onboarding smoke tests

Every DEBUG scenario now scripts all six approvals with
ScriptedPermissionChecker, which never touches TCC, Apple events,
notifications or login items: approvals grant the moment they are
requested, there is no Move step and no link is opened. UI smoke tests
walk the whole onboarding to Smart Clean, click through the sidebar and
check the blocking engine card. Unit tests cover every scenario, a
headless onboarding walk and the identifiers the UI tests spell out.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

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
- Script details (internal to this task; `docs/signing.md` documents them for the owner):
  - Exit 1 also covers a step that failed: a tool error, a keychain that is missing or not on the search list, or a probe signature that is refused or has an unexpected DR. Exit 2 also covers refusals:
    - an identity named NAME already exists;
    - `--dir` is inside the repository;
    - DIR holds only one of `key.pem` and `cert.pem`;
    - DIR's `cert.pem` has a subject other than `CN=NAME`.
  - `--check` writes `<SHA1> "<NAME>"` to stdout only on success. Its other messages go to stderr, so `scripts/make-signing-identity.sh --check | cut -d' ' -f1` yields the SHA-1 or nothing.
  - Environment: `OPENSSL` (default `/usr/bin/openssl`), `SECURITY` (default `/usr/bin/security`) and `CODESIGN` (default `/usr/bin/codesign`). Apart from those and `PATH`, only `HOME` and `TMPDIR` are read.
  - `--name` accepts letters, digits, spaces, `.`, `_` and `-`. The name goes into `openssl.cnf`, an awk pattern and `Local.xcconfig`, so nothing needs escaping.
  - DIR is mode 700 and holds `key.pem`, `cert.pem`, `openssl.cnf`, `identity.p12`, `identity.p12.password` and `identity.p12.base64`, each mode 600.

**Requirements:**
- Use the S5 research draft, with these properties:
  - `/usr/bin/openssl` pinned (LibreSSL; Homebrew's OpenSSL 3 comes first on `PATH`);
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
- Changes from the draft:
  - The exit codes above; the draft exited 1 for everything.
  - A second creation is refused when the keychain already holds an identity named NAME. The draft reused that identity instead.
  - The DIR check resolves the physical path (relative paths, symlinks, letter case) and runs before anything is created or any tool runs. The draft created DIR first.
  - The restore path checks that `cert.pem` is `CN=NAME` before importing it.
  - `--no-import` neither reads nor changes the keychain, does not probe-sign and does not write `Local.xcconfig`.
- The tests never touch the real keychain and never create a real certificate. Every external tool that makes keys, reads or changes the keychain, or signs is invoked through a variable (`OPENSSL`, `SECURITY`, `CODESIGN`) that the environment can override.
- `signing_identity.bats` puts stub executables on those variables and runs a copy of the script inside a throwaway git repository with a temporary `HOME`. If the `security` stub were ever bypassed, the fake PKCS#12 from the `openssl` stub still could not be imported. Required cases:
  - `--help` exits 0 and prints usage;
  - an unknown flag → 2;
  - `--dir` inside the repo → 2 with a message;
  - `--check` with a stub `security` printing zero identities → 1, one → 0 and prints `<SHA1> "<name>"`, two → 2;
  - a second creation with an existing identity of the same name → refused.

  The file also covers:
  - missing or malformed values;
  - look-alike names;
  - the exact `openssl.cnf` and `req`/`pkcs12` arguments, and the file modes;
  - the exact `security` call sequence (no `add-trusted-cert`);
  - the probe signature;
  - `Local.xcconfig` written, left alone, and not ignored;
  - `--no-import` followed by a restore;
  - a restored certificate with another name;
  - a keychain missing from the search list;
  - a denied probe signature;
  - a probe DR without `certificate leaf`.
- `docs/signing.md`:
  - what the identity is for (stable TCC grants);
  - how to create it (one command; click **Always Allow**);
  - backing up `~/.roomformac/signing`;
  - removing old FDA entries from ad-hoc builds;
  - the verification commands (`codesign -d -r-` and the stability test);
  - the fallbacks if Xcode rejects the identity (re-sign with `codesign` after build);
  - the security note (anyone with the key can sign code that inherits users' grants).
- The implementer runs the script only with `--help` and `--check`. Creating the identity adds an item to the login keychain and shows a password dialog, so it is the owner's step (see the checklist at the end of this task).

- [ ] **Step 1: Write the failing tests** — `scripts/tests/signing_identity.bats`

The stubs log every call to `$STATE`, so the tests can assert exactly what would have run. The `security` stub accepts `find-identity` only as `find-identity -p codesigning`, which pins the parse without `-v`. The `openssl` stub writes fake PEM and PKCS#12 files. A fake certificate's SHA-1 is the SHA-1 of its file, so the script's fingerprint and import checks still compare real values.

```bash
#!/usr/bin/env bats
# Checks scripts/make-signing-identity.sh without a real keychain, certificate
# or signature. Each test runs a copy of the script inside a throwaway git
# repository, with HOME in the test folder and stub executables on the
# OPENSSL, SECURITY and CODESIGN variables. The stubs log their arguments to
# $STATE, so the tests can check exactly what would have run.

setup_file() {
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS/bin"

    cat > "$STUBS/security" << 'STUB'
#!/bin/bash
# security(1) stand-in. Identities are "SHA1|name" lines in $STATE/identities.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/security.log"
case "$1" in
    find-identity)
        # Real `find-identity -v` hides untrusted identities, so only the
        # exact form the script must use is accepted.
        if [[ "$*" != "find-identity -p codesigning" ]]; then
            echo "stub security: unexpected arguments: $*" >&2
            exit 64
        fi
        echo 'Policy: Code Signing'
        echo '  Matching identities'
        count=0
        if [[ -f "$STATE/identities" ]]; then
            while IFS='|' read -r hash name; do
                count=$((count + 1))
                printf '  %d) %s "%s" (CSSMERR_TP_NOT_TRUSTED)\n' "$count" "$hash" "$name"
            done < "$STATE/identities"
        fi
        printf '     %d identities found\n\n' "$count"
        echo '  Valid identities only'
        echo '     0 valid identities found'
        ;;
    list-keychains)
        printf '    "%s"\n' "$STUB_KEYCHAIN" /Library/Keychains/System.keychain
        ;;
    import)
        file="$2"
        password=""
        shift 2
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -P ]]; then
                password="$2"
                shift
            fi
            shift
        done
        if [[ "$(head -n 1 "$file")" != "FAKE P12 password=$password" ]]; then
            echo "security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)" >&2
            exit 1
        fi
        tail -n +2 "$file" > "$STATE/imported-cert.pem"
        hash="$(shasum -a 1 < "$STATE/imported-cert.pem" | cut -c 1-40 | tr 'a-f' 'A-F')"
        name="$(sed -n 's/^FAKE CERT CN=//p' "$STATE/imported-cert.pem")"
        printf '%s|%s\n' "$hash" "$name" >> "$STATE/identities"
        echo '1 identity imported.'
        ;;
    *)
        echo "stub security: unexpected command: $1" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/codesign" << 'STUB'
#!/bin/bash
# codesign(1) stand-in: remembers the identity it signed with and prints the
# DR a certificate signature gets, or $STUB_DR when that is set.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/codesign.log"
for file; do :; done
case "$1" in
    --force)
        if [[ "${STUB_CODESIGN_FAIL:-0}" == 1 ]]; then
            echo "$file: errSecInternalComponent" >&2
            exit 1
        fi
        previous=""
        for argument; do
            if [[ "$previous" == --sign ]]; then
                printf '%s\n' "$argument" > "$STATE/signed-with"
            fi
            previous="$argument"
        done
        echo "$file: replacing existing signature" >&2
        ;;
    --verify)
        [[ -f "$STATE/signed-with" ]]
        ;;
    -d)
        echo "Executable=$file" >&2
        if [[ -n "${STUB_DR:-}" ]]; then
            printf 'designated => %s\n' "$STUB_DR"
        else
            printf 'designated => identifier "com.roomformac.signing-probe" and certificate leaf = H"%s"\n' \
                "$(tr 'A-F' 'a-f' < "$STATE/signed-with")"
        fi
        ;;
    *)
        echo "stub codesign: unexpected arguments: $*" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/openssl" << 'STUB'
#!/bin/bash
# openssl(1) stand-in: logs its arguments and writes fake files. A fake
# certificate's SHA-1 fingerprint is the SHA-1 of the file.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/openssl.log"
value_of() {
    local flag="$1"
    shift
    while [[ $# -gt 1 ]]; do
        if [[ "$1" == "$flag" ]]; then
            printf '%s\n' "$2"
            return 0
        fi
        shift
    done
    echo "stub openssl: missing $flag" >&2
    return 64
}
random_hex() {
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}
case "$1" in
    rand)
        random_hex "$3"
        echo
        ;;
    req)
        config="$(value_of -config "$@")"
        printf 'FAKE KEY %s\n' "$(random_hex 8)" > "$(value_of -keyout "$@")"
        {
            printf 'FAKE CERT CN=%s\n' "$(sed -n 's/^CN = //p' "$config")"
            printf 'serial=%s\n' "$(value_of -set_serial "$@")"
        } > "$(value_of -out "$@")"
        ;;
    x509)
        certificate="$(value_of -in "$@")"
        case " $* " in
            *" -fingerprint "*)
                printf 'SHA1 Fingerprint=%s\n' "$(shasum -a 1 < "$certificate" | cut -c 1-40 |
                    tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')"
                ;;
            *" -subject "*)
                printf 'subject= CN=%s\n' "$(sed -n 's/^FAKE CERT CN=//p' "$certificate")"
                ;;
        esac
        ;;
    pkcs12)
        passout="$(value_of -passout "$@")"
        variable="${passout#env:}"
        {
            printf 'FAKE P12 password=%s\n' "${!variable}"
            cat "$(value_of -in "$@")"
        } > "$(value_of -out "$@")"
        ;;
    *)
        echo "stub openssl: unexpected command: $1" >&2
        exit 64
        ;;
esac
STUB

    # The script prints `gh secret set …` but must never run it.
    cat > "$STUBS/bin/gh" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/gh.log"
exit 1
STUB

    chmod +x "$STUBS/security" "$STUBS/codesign" "$STUBS/openssl" "$STUBS/bin/gh"
    export STUBS
}

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    STATE="$TMP/state"
    HOME="$TMP/home"
    SIGNING_DIR="$TMP/signing"
    STUB_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    mkdir -p "$REPO/scripts" "$REPO/Config" "$STATE" "$HOME/Library/Keychains"
    : > "$STUB_KEYCHAIN"
    cp "$BATS_TEST_DIRNAME/../make-signing-identity.sh" "$REPO/scripts/"
    printf 'Config/Local.xcconfig\n' > "$REPO/.gitignore"
    git -c init.defaultBranch=main init --quiet "$REPO"
    SCRIPT="$REPO/scripts/make-signing-identity.sh"
    PATH="$STUBS/bin:$PATH"
    OPENSSL="$STUBS/openssl"
    SECURITY="$STUBS/security"
    CODESIGN="$STUBS/codesign"
    HASH_A=1A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D
    HASH_B=FFEEDDCCBBAA99887766554433221100FFEEDDCC
    HASH_C=0000000000000000000000000000000000000001
    export HOME STATE STUB_KEYCHAIN PATH OPENSSL SECURITY CODESIGN
}

add_identity() {
    printf '%s|%s\n' "$1" "$2" >> "$STATE/identities"
}

cert_hash() {
    shasum -a 1 < "$SIGNING_DIR/cert.pem" | cut -c 1-40 | tr 'a-f' 'A-F'
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "an unknown flag is a usage error" {
    run "$SCRIPT" --force
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown argument: --force"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "a missing or malformed value is a usage error" {
    run "$SCRIPT" --name
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --name needs a value"* ]] || return 1
    run "$SCRIPT" --dir --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir needs a value"* ]] || return 1
    run "$SCRIPT" --check --name 'Bad "Name"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --name may contain only"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "--dir inside the repository is refused before anything is created" {
    run "$SCRIPT" --dir "$REPO/signing"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must be outside the repository"* ]] || return 1
    ln -s "$REPO/Config" "$TMP/config-link"
    run "$SCRIPT" --dir "$TMP/config-link/signing"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/REPO/signing"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/missing/../repo/signing"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must not contain '..'"* ]] || return 1
    cd "$REPO/Config"
    run "$SCRIPT" --dir ../new/signing
    [ "$status" -eq 2 ]
    [ ! -e "$REPO/signing" ]
    [ ! -e "$REPO/Config/signing" ]
    [ ! -e "$REPO/new" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/openssl.log" ]
}

@test "--check with no identity exits 1" {
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [ "$output" = 'no identity named "RoomForMac Self-Signed"' ]
    [ -z "$("$SCRIPT" --check 2> /dev/null)" ]
}

@test "--check with one identity prints its SHA-1 and name" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    run "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    [ "$("$SCRIPT" --check 2> /dev/null)" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    [ "$(sort -u "$STATE/security.log")" = "find-identity -p codesigning" ]
}

@test "--check with two identities of that name is ambiguous" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_B" "RoomForMac Self-Signed"
    run "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"2 identities named \"RoomForMac Self-Signed\""* ]] || return 1
    [[ "$output" == *"$HASH_A"* && "$output" == *"$HASH_B"* ]]
}

@test "--check ignores look-alike names and repeated listings" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_B" "RoomForMac Self-Signed 2"
    add_identity "$HASH_C" "Old RoomForMac Self-Signed"
    add_identity "$HASH_C" 'Copy of "RoomForMac Self-Signed"'
    run "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    run "$SCRIPT" --check --name "RoomForMac Self-Signed 2"
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_B \"RoomForMac Self-Signed 2\"" ]
}

@test "a second identity with the same name is refused and nothing changes" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the keychain already holds an identity named \"RoomForMac Self-Signed\" ($HASH_A)"* ]] || return 1
    [ ! -e "$SIGNING_DIR" ]
    [ ! -e "$STATE/openssl.log" ]
    [ ! -e "$STATE/codesign.log" ]
    [ ! -e "$REPO/Config/Local.xcconfig" ]
    [ "$(cat "$STATE/security.log")" = "find-identity -p codesigning" ]
}

@test "creates a CN-only, 20-year code-signing certificate in a private folder" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    diff "$SIGNING_DIR/openssl.cnf" - << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = RoomForMac Self-Signed
[ codesign ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    grep -qF -- "req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 7300 -set_serial 0x" "$STATE/openssl.log"
    grep -qF -- "-config $SIGNING_DIR/openssl.cnf -keyout $SIGNING_DIR/key.pem -out $SIGNING_DIR/cert.pem" "$STATE/openssl.log"
    [ "$(sed -n 's/.*-set_serial 0x\([0-9a-f]*\) .*/\1/p' "$STATE/openssl.log" | tr -d '\n' | wc -c | tr -d ' ')" = 32 ]
    [ "$(stat -f %Lp "$SIGNING_DIR")" = 700 ]
    local file
    for file in key.pem cert.pem identity.p12 identity.p12.base64 identity.p12.password; do
        [ "$(stat -f %Lp "$SIGNING_DIR/$file")" = 600 ]
    done
}

@test "exports a PKCS#12 that imports on any macOS, plus its base64 copy" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    grep -qxF -- "pkcs12 -export -name RoomForMac Self-Signed -inkey $SIGNING_DIR/key.pem -in $SIGNING_DIR/cert.pem -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:RFM_P12_PASS -out $SIGNING_DIR/identity.p12" "$STATE/openssl.log"
    grep -qx '[0-9a-f]\{48\}' "$SIGNING_DIR/identity.p12.password"
    [ "$(base64 -D -i "$SIGNING_DIR/identity.p12.base64" | shasum)" = "$(shasum < "$SIGNING_DIR/identity.p12")" ]
}

@test "imports without trust settings and probe-signs with the new identity" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    local hash password
    hash="$(cert_hash)"
    password="$(cat "$SIGNING_DIR/identity.p12.password")"
    diff "$STATE/security.log" - << EOF
find-identity -p codesigning
list-keychains -d user
import $SIGNING_DIR/identity.p12 -k $STUB_KEYCHAIN -f pkcs12 -P $password -x -T /usr/bin/codesign
find-identity -p codesigning
EOF
    [ "$(cat "$STATE/identities")" = "$hash|RoomForMac Self-Signed" ]
    grep -qF -- "--force --timestamp=none --identifier com.roomformac.signing-probe --sign $hash " "$STATE/codesign.log"
    grep -qF -- "--verify --strict " "$STATE/codesign.log"
    [[ "$output" == *"SHA-1:     $hash"* ]] || return 1
    [[ "$output" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<< "$hash")\""* ]]
}

@test "writes Config/Local.xcconfig and prints the CI secret commands without running them" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    diff "$REPO/Config/Local.xcconfig" - << 'EOF'
// Written by scripts/make-signing-identity.sh. Never commit this file.
CODE_SIGN_IDENTITY = RoomForMac Self-Signed
EOF
    [[ "$output" == *"gh secret set RFM_SIGNING_P12_BASE64 < \"$SIGNING_DIR/identity.p12.base64\""* ]] || return 1
    [[ "$output" == *"gh secret set RFM_SIGNING_P12_PASSWORD < \"$SIGNING_DIR/identity.p12.password\""* ]] || return 1
    [[ "$output" != *"not git-ignored"* ]] || return 1
    [ ! -e "$STATE/gh.log" ]
}

@test "an existing Config/Local.xcconfig is left alone" {
    printf 'CODE_SIGN_IDENTITY = -\n' > "$REPO/Config/Local.xcconfig"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$REPO/Config/Local.xcconfig")" = "CODE_SIGN_IDENTITY = -" ]
    [[ "$output" == *"$REPO/Config/Local.xcconfig already exists and was left alone"* ]]
}

@test "warns when Config/Local.xcconfig is not git-ignored" {
    rm "$REPO/.gitignore"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: $REPO/Config/Local.xcconfig is not git-ignored"* ]]
}

@test "--no-import only writes files, and a later run restores that same certificate" {
    run "$SCRIPT" --no-import --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [ -f "$SIGNING_DIR/key.pem" ]
    [ -f "$SIGNING_DIR/identity.p12.base64" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/codesign.log" ]
    [ ! -e "$REPO/Config/Local.xcconfig" ]
    local before
    before="$(cert_hash)"
    rm "$STATE/openssl.log"
    chmod 755 "$SIGNING_DIR"
    chmod 644 "$SIGNING_DIR/key.pem"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing the key and certificate in $SIGNING_DIR"* ]] || return 1
    [ "$(stat -f %Lp "$SIGNING_DIR")" = 700 ]
    [ "$(stat -f %Lp "$SIGNING_DIR/key.pem")" = 600 ]
    [ "$(cert_hash)" = "$before" ]
    [ "$(cat "$STATE/identities")" = "$before|RoomForMac Self-Signed" ]
    run grep -c -e '^req' -e '^pkcs12' "$STATE/openssl.log"
    [ "$output" = 0 ]
}

@test "a restored certificate with another name is refused" {
    run "$SCRIPT" --no-import --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    run "$SCRIPT" --name "RoomForMac Dev" --dir "$SIGNING_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$SIGNING_DIR/cert.pem is CN=RoomForMac Self-Signed, not CN=RoomForMac Dev"* ]] || return 1
    run grep -c '^import' "$STATE/security.log"
    [ "$output" = 0 ]
}

@test "a keychain missing from the search list is refused before anything is created" {
    : > "$TMP/other.keychain-db"
    run "$SCRIPT" --keychain "$TMP/other.keychain-db" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not on the keychain search list"* ]] || return 1
    [ ! -e "$SIGNING_DIR" ]
}

@test "a denied probe signature fails with a hint" {
    run env STUB_CODESIGN_FAIL=1 "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: codesign could not sign with \"RoomForMac Self-Signed\""* ]] || return 1
    [ ! -e "$REPO/Config/Local.xcconfig" ]
}

@test "a probe signature without a certificate leaf requirement fails" {
    run env STUB_DR='cdhash H"0123456789abcdef0123456789abcdef01234567"' "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: unexpected designated requirement: cdhash H"* ]] || return 1
    [ ! -e "$REPO/Config/Local.xcconfig" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats scripts/tests/signing_identity.bats`
Expected: FAIL. The run prints `1..20` and all 20 are `not ok`. Each fails in `setup` with `cp: …/scripts/tests/../make-signing-identity.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/make-signing-identity.sh`**

```bash
#!/bin/bash
# Create, once per Mac, the stable self-signed code-signing identity that
# RoomForMac builds are signed with, so Full Disk Access and Automation grants
# survive rebuilds. docs/signing.md explains why, and what to back up.
#
# An ad-hoc signature's designated requirement (DR) is the build's cdhash, which
# changes on every build. A certificate signature's DR names the certificate:
#   identifier "com.roomformac.RoomForMac" and certificate leaf = H"<SHA-1 of the certificate>"
# That stays the same across rebuilds and releases. The certificate gets no
# trust settings: codesign and Xcode sign with an untrusted self-signed
# identity, and a DR check compares the certificate hash, not trust.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
NAME="RoomForMac Self-Signed"
DIR="$HOME/.roomformac/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=7300 # 20 years: a new certificate means a new DR, and every user re-grants
PROBE_IDENTIFIER="com.roomformac.signing-probe"
CHECK_ONLY=0
IMPORT=1

# Every tool that makes keys, reads or changes the keychain, or signs is called
# through one of these variables, so the bats tests can put stubs there.
# /usr/bin/openssl is LibreSSL; Homebrew's OpenSSL 3 usually comes first on PATH.
OPENSSL="${OPENSSL:-/usr/bin/openssl}"
SECURITY="${SECURITY:-/usr/bin/security}"
CODESIGN="${CODESIGN:-/usr/bin/codesign}"

usage() {
    cat << 'EOF'
Usage: scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]

Creates the self-signed code-signing identity RoomForMac builds are signed with,
imports it into your keychain, checks that codesign can use it, and writes
Config/Local.xcconfig. See docs/signing.md.

  --name NAME      certificate common name (default: "RoomForMac Self-Signed")
  --dir DIR        where key.pem, cert.pem and the CI export live
                   (default: ~/.roomformac/signing; must be outside the repository).
                   If DIR already holds key.pem and cert.pem, they are imported
                   instead of creating a new certificate.
  --keychain PATH  keychain to import into (default: the login keychain)
  --no-import      only create the files in DIR; the keychain is not touched
  --check          read-only: print '<SHA-1> "NAME"' when exactly one identity exists
  --help           show this help

Exit status: 0 done; 1 no identity (--check) or a step failed;
2 bad usage, more than one identity, or a refusal (an identity with NAME
already exists, or DIR holds a different certificate).

The first signature shows a macOS dialog: enter your login password and click
"Always Allow". The terminal never asks for anything.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-signing-identity.sh --help for usage.\n' >&2
    exit 2
}
refuse() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
say() { printf '==> %s\n' "$*"; }

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            need_value "$@"
            NAME="$2"
            shift 2
            ;;
        --dir)
            need_value "$@"
            DIR="$2"
            shift 2
            ;;
        --keychain)
            need_value "$@"
            KEYCHAIN="$2"
            shift 2
            ;;
        --no-import)
            IMPORT=0
            shift
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument: $1" ;;
    esac
done

# NAME ends up in openssl.cnf, an awk pattern and Local.xcconfig.
case "$NAME" in
    *[![:alnum:]\ ._-]*) usage_error "--name may contain only letters, digits, spaces, dots, dashes and underscores" ;;
esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Physical absolute path of $1, which need not exist yet: the deepest existing
# folder is resolved with pwd -P and the rest is appended. A '..' in the part
# that does not exist yet cannot be resolved, so it is refused.
physical_path() {
    local path="$1" rest="" leaf
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ ! -d "$path" ]]; do
        leaf="$(basename "$path")"
        [[ "$leaf" != ".." ]] || usage_error "--dir must not contain '..' in a part that does not exist yet: $1"
        rest="/$leaf$rest"
        path="$(dirname "$path")"
    done
    printf '%s%s\n' "$(cd "$path" && pwd -P)" "$rest"
}

# The key must never be committed, so DIR may not be inside the repository.
# Compared without regard to case: the default APFS volume ignores it.
DIR="$(physical_path "$DIR")"
case "$(lower "$DIR")/" in
    "$(lower "$ROOT")"/*) usage_error "--dir must be outside the repository ($ROOT), because anyone with the key can sign code that inherits RoomForMac's grants" ;;
esac

# SHA-1s (uppercase, unique, one per line) of the code-signing identities named
# exactly NAME in the keychain search list, which codesign and Xcode search.
# No -v: it lists only identities with a trusted certificate, and this one is
# deliberately untrusted. A trusted identity is listed twice, hence sort -u.
identity_hashes() {
    local listing
    listing="$("$SECURITY" find-identity -p codesigning)" || die "security find-identity failed"
    printf '%s\n' "$listing" |
        awk -v want="\"$NAME\"" '
            length($2) == 40 && $2 ~ /^[0-9A-Fa-f]+$/ && index($0, $2 " " want) { print toupper($2) }
        ' | sort -u
}
count_lines() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}
cert_sha1() {
    "$OPENSSL" x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]'
}
cert_subject() {
    "$OPENSSL" x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'
}

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ "$(id -u)" -ne 0 ]] || die "run this as your own user, not as root"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    HASHES="$(identity_hashes)"
    COUNT="$(count_lines "$HASHES")"
    case "$COUNT" in
        0)
            printf 'no identity named "%s"\n' "$NAME" >&2
            exit 1
            ;;
        1)
            printf '%s "%s"\n' "$HASHES" "$NAME"
            exit 0
            ;;
        *)
            printf 'ambiguous: %s identities named "%s":\n%s\n' "$COUNT" "$NAME" "$HASHES" >&2
            exit 2
            ;;
    esac
fi

[[ -x "$OPENSSL" ]] || die "$OPENSSL not found"

if [[ "$IMPORT" -eq 1 ]]; then
    HASHES="$(identity_hashes)"
    COUNT="$(count_lines "$HASHES")"
    if [[ "$COUNT" -eq 1 ]]; then
        refuse "the keychain already holds an identity named \"$NAME\" ($HASHES); nothing was changed. --check prints it, and docs/signing.md explains how to replace it."
    elif [[ "$COUNT" -gt 1 ]]; then
        printf 'error: %s identities named "%s"; codesign cannot choose between them:\n%s\n' \
            "$COUNT" "$NAME" "$HASHES" >&2
        refuse "keep one: delete the others in Keychain Access (login > My Certificates)"
    fi
    [[ -f "$KEYCHAIN" ]] || die "keychain not found: $KEYCHAIN"
    SEARCH_LIST="$("$SECURITY" list-keychains -d user)" || die "security list-keychains failed"
    grep -qF "\"$KEYCHAIN\"" <<< "$SEARCH_LIST" ||
        die "$KEYCHAIN is not on the keychain search list, so codesign and Xcode would not see it"
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ -f "$DIR/key.pem" && -f "$DIR/cert.pem" ]]; then
    SUBJECT="$(cert_subject "$DIR/cert.pem")"
    [[ "$SUBJECT" == "CN=$NAME" ]] ||
        refuse "$DIR/cert.pem is $SUBJECT, not CN=$NAME; pass the matching --name or another --dir"
    say "reusing the key and certificate in $DIR"
else
    [[ ! -e "$DIR/key.pem" && ! -e "$DIR/cert.pem" ]] ||
        refuse "$DIR holds only one of key.pem and cert.pem; move it away first"
    say "creating a self-signed code-signing certificate \"$NAME\" in $DIR"
    # CN only, no O or OU: the DR then pins `certificate leaf`, and Xcode sees no team.
    cat > "$DIR/openssl.cnf" << EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = $NAME
[ codesign ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    "$OPENSSL" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
        -set_serial "0x$("$OPENSSL" rand -hex 16)" \
        -config "$DIR/openssl.cnf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem"
    rm -f "$DIR/identity.p12" "$DIR/identity.p12.base64" "$DIR/identity.p12.password"
fi

if [[ ! -f "$DIR/identity.p12" || ! -f "$DIR/identity.p12.password" ]]; then
    "$OPENSSL" rand -hex 24 > "$DIR/identity.p12.password"
    # PBE-SHA1-3DES and a SHA-1 MAC: `security import` on macOS 14 and older
    # rejects OpenSSL 3's AES/SHA-256 defaults with "MAC verification failed".
    RFM_P12_PASS="$(cat "$DIR/identity.p12.password")" \
        "$OPENSSL" pkcs12 -export -name "$NAME" \
        -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout env:RFM_P12_PASS -out "$DIR/identity.p12"
    rm -f "$DIR/identity.p12.base64"
fi
if [[ ! -f "$DIR/identity.p12.base64" ]]; then
    base64 -i "$DIR/identity.p12" -o "$DIR/identity.p12.base64"
fi
for file in key.pem cert.pem openssl.cnf identity.p12 identity.p12.base64 identity.p12.password; do
    if [[ -e "$DIR/$file" ]]; then
        chmod 600 "$DIR/$file"
    fi
done

HASH="$(cert_sha1 "$DIR/cert.pem")"
DR="(no probe signature: --no-import)"

if [[ "$IMPORT" -eq 1 ]]; then
    say "importing \"$NAME\" into $KEYCHAIN (a dialog appears only if that keychain is locked)"
    # -x: the private key cannot be exported from the keychain again; DIR keeps the copy.
    # -T: codesign may use the key. No trust settings are added.
    "$SECURITY" import "$DIR/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
        -P "$(cat "$DIR/identity.p12.password")" -x -T /usr/bin/codesign

    HASHES="$(identity_hashes)"
    [[ "$(count_lines "$HASHES")" -eq 1 ]] ||
        die "after the import, expected one identity named \"$NAME\", found: ${HASHES:-none}"
    [[ "$HASHES" == "$HASH" ]] || die "the imported identity $HASHES is not $DIR/cert.pem ($HASH)"

    say "probe signature (the first time, a dialog asks for your login password: click Always Allow)"
    TEMP_ROOT="${TMPDIR:-/tmp}"
    PROBE_DIR="$(mktemp -d "${TEMP_ROOT%/}/rfm-signing-probe.XXXXXX")"
    trap 'rm -rf "$PROBE_DIR"' EXIT
    cp /usr/bin/true "$PROBE_DIR/probe"
    if ! SIGN_LOG="$("$CODESIGN" --force --timestamp=none --identifier "$PROBE_IDENTIFIER" \
        --sign "$HASH" "$PROBE_DIR/probe" 2>&1)"; then
        printf '%s\n' "$SIGN_LOG" >&2
        die "codesign could not sign with \"$NAME\" (was the dialog denied, or is the keychain locked?)"
    fi
    "$CODESIGN" --verify --strict "$PROBE_DIR/probe" || die "the probe signature does not verify"
    DR="$("$CODESIGN" -d -r- "$PROBE_DIR/probe" 2> /dev/null | sed -n 's/^designated => //p' || true)"
    case "$(lower "$DR")" in
        *"certificate leaf = h\"$(lower "$HASH")\""*) ;;
        *) die "unexpected designated requirement: ${DR:-none} (expected certificate leaf = H\"$HASH\")" ;;
    esac

    if [[ ! -d "$(dirname "$LOCAL_XCCONFIG")" ]]; then
        say "no Config folder in $ROOT; put CODE_SIGN_IDENTITY = $NAME in Config/Local.xcconfig yourself"
    elif [[ -e "$LOCAL_XCCONFIG" ]]; then
        say "$LOCAL_XCCONFIG already exists and was left alone; it must say CODE_SIGN_IDENTITY = $NAME"
    else
        printf '// Written by scripts/make-signing-identity.sh. Never commit this file.\nCODE_SIGN_IDENTITY = %s\n' \
            "$NAME" > "$LOCAL_XCCONFIG"
        chmod 644 "$LOCAL_XCCONFIG"
        say "wrote $LOCAL_XCCONFIG"
    fi
    if [[ -e "$LOCAL_XCCONFIG" ]] && ! git -C "$ROOT" check-ignore -q "$LOCAL_XCCONFIG" 2> /dev/null; then
        printf 'warning: %s is not git-ignored; never commit it\n' "$LOCAL_XCCONFIG" >&2
    fi
else
    say "files only (--no-import): the keychain was not touched"
fi

cat << EOF

Identity:  $NAME
SHA-1:     $HASH
Probe DR:  $DR
App DR:    identifier "com.roomformac.RoomForMac" and certificate leaf = H"$(lower "$HASH")"

Back up the whole folder $DIR in your password manager.
Losing it means a new certificate, and every user granting Full Disk Access
and Automation again.

CI secrets for release builds (run these yourself when a workflow needs them):
  gh secret set RFM_SIGNING_P12_BASE64 < "$DIR/identity.p12.base64"
  gh secret set RFM_SIGNING_P12_PASSWORD < "$DIR/identity.p12.password"
EOF
```

Then make it executable: `chmod +x scripts/make-signing-identity.sh`

Notes on choices the tests pin:
- `identity_hashes` requires the 40-hex hash to be followed directly by `"NAME"`. That skips `"RoomForMac Self-Signed 2"` and `Copy of "RoomForMac Self-Signed"`. `sort -u` folds a trusted identity, which `find-identity` lists twice (under "Matching" and "Valid").
- `physical_path` never creates anything. It resolves the deepest existing folder with `pwd -P`, then compares in lower case, because bash's `pwd -P` keeps the letter case you typed on a case-insensitive volume.
- The `security import -P` password is visible to `ps` for the moment the import runs. It protects only `identity.p12`, which sits next to its password file anyway.

- [ ] **Step 4: Run the tests to verify they pass, and lint**

Run: `bats scripts/tests/signing_identity.bats`
Expected: PASS, `1..20` and all 20 `ok`, in about 15 s.

Run: `shellcheck scripts/*.sh && shfmt -d -i 4 -ci -sr scripts/*.sh scripts/tests/*.bats`
Expected: no output.

Run: `python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats`
Expected: `bats-assertion-audit-ok files=3` (`build_engine.bats`, `app_bundle.bats` and `signing_identity.bats`).

Run: `scripts/make-signing-identity.sh --help; echo "exit $?"`
Expected: the usage, starting `Usage: scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]`, then `exit 0`.

Run: `scripts/make-signing-identity.sh --check; echo "exit $?"`
Expected: this is read-only. Before the owner has created the identity, it prints `no identity named "RoomForMac Self-Signed"`, then `exit 1`. Afterwards it prints `<SHA1> "RoomForMac Self-Signed"`, then `exit 0`. Either way, `~/.roomformac` is not created.

Run `security find-identity -p codesigning` before and after the `bats` run.
Expected: identical output. The tests never reach the real keychain.

Do not run the script without `--check` or `--help`.

- [ ] **Step 5: Commit**

```bash
git add scripts/make-signing-identity.sh scripts/tests/signing_identity.bats
git commit -F - << 'EOF'
build: add a script that creates the stable signing identity

scripts/make-signing-identity.sh creates the self-signed "RoomForMac
Self-Signed" identity outside the repository and imports it into the
login keychain without trust settings. It then probe-signs a copy of
/usr/bin/true to check the certificate-leaf DR, and writes
Config/Local.xcconfig. Its bats tests run it against stub openssl,
security and codesign, so they never touch a real keychain or create a
certificate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

- [ ] **Step 6: Write `docs/signing.md`**

````markdown
# Signing RoomForMac builds

RoomForMac signs every build, local and release, with one self-signed code-signing identity: **RoomForMac Self-Signed**. This page covers why it exists, how to create and back it up, how to check a signed build, and what to do if Xcode refuses it.

## Why builds need a stable identity

macOS records each privacy grant against the app's bundle ID and its *designated requirement* (DR), a rule the app's signature must satisfy. The grants RoomForMac asks for are Full Disk Access and Automation of Finder and System Events. On every later launch, macOS checks the new build against the DR it recorded.

- **Ad-hoc signature** (`CODE_SIGN_IDENTITY = -`, Xcode's "Sign to Run Locally"): the DR is `cdhash H"…"`, the hash of that one build. The next build has another cdhash, so macOS treats it as a different app. Onboarding asks again, and System Settings keeps an old entry that never matches.
- **Stable identity**: the DR is `identifier "com.roomformac.RoomForMac" and certificate leaf = H"<SHA-1 of the certificate>"`. It stays the same across rebuilds and releases for as long as the certificate does.

The identity is self-signed, because RoomForMac has no Apple Developer account yet. It does not satisfy Gatekeeper, so users still need **Open Anyway** on first launch. It has no trust settings, and needs none:

- `codesign` signs with an untrusted self-signed identity;
- Xcode 27's validity check accepts any self-signed certificate (found by reading Xcode's code, not yet confirmed by a real build; see "If Xcode refuses the identity");
- a DR check compares the certificate's hash, not trust.

Local and release builds share this one identity. A grant made on a development build therefore also covers a release build on the same Mac.

## How the build chooses the identity

- `Config/Signing.xcconfig` is committed. It signs ad-hoc (`CODE_SIGN_IDENTITY = -`) and ends with `#include? "Local.xcconfig"`.
- `Config/Local.xcconfig` is git-ignored. The script below writes it with one setting, `CODE_SIGN_IDENTITY = RoomForMac Self-Signed`.
- Without `Local.xcconfig`, builds are ad-hoc.
- With `Local.xcconfig` but without the identity in the keychain, the build fails with `No certificate matching 'RoomForMac Self-Signed' found`. It never falls back silently. To build ad-hoc once anyway, add `CODE_SIGN_IDENTITY=-` to the `xcodebuild` command.
- The "Embed engine" build phase signs `Contents/Helpers/analyze-go` and `status-go` with the same identity as the app.
- Never set `CODE_SIGN_*` or `DEVELOPMENT_TEAM` in `project.yml`: those settings silently override the xcconfig files.

## Create the identity (once per Mac)

```bash
scripts/make-signing-identity.sh
```

During the run, macOS shows one dialog: *codesign wants to sign using key "RoomForMac Self-Signed" in your keychain*. Enter your login password and click **Always Allow**. If you click **Allow** instead, every build asks again, up to three times for a Debug build; click **Always Allow** the next time it appears. The terminal itself never asks for anything.

The script:

1. Refuses, and changes nothing, if the keychain already holds an identity with that name.
2. Creates `~/.roomformac/signing` (mode 700) with `/usr/bin/openssl`: a 2048-bit RSA key and a certificate valid for 20 years. The certificate's subject is only `CN=RoomForMac Self-Signed`, and its only use is code signing.
3. Exports `identity.p12` with 3DES and a SHA-1 MAC, which every macOS version can import. It also writes a base64 copy and a random password.
4. Imports the identity into the login keychain. The private key cannot be exported from the keychain again (`-x`), and only `codesign` may use it without asking (`-T`). No trust settings are added.
5. Signs a copy of `/usr/bin/true` and checks that its DR is `certificate leaf = H"<SHA-1>"`.
6. Writes `Config/Local.xcconfig` if that file does not exist yet, and warns if git does not ignore it.
7. Prints the identity, its SHA-1 and two `gh secret set` commands. It does not run those commands.

Check the result at any time. This is read-only:

```bash
scripts/make-signing-identity.sh --check
```

It prints `<SHA-1> "RoomForMac Self-Signed"` and exits 0. It exits 1 when there is no such identity, and 2 when there is more than one; `codesign` cannot choose between duplicates, so delete the extras in Keychain Access (login → My Certificates).

| Option | Use |
|---|---|
| `--name NAME` | another certificate name, for example a separate release identity |
| `--dir DIR` | another folder for the files; it must be outside the repository |
| `--keychain PATH` | another keychain, which must be on your keychain search list |
| `--no-import` | create the files only and leave the keychain alone |
| `--check` | print the identity, as above |

Exit status: 0 done; 1 no identity (`--check`) or a step failed; 2 bad usage, more than one identity, or a refusal.

## Back up `~/.roomformac/signing`

| File | What it is |
|---|---|
| `key.pem`, `cert.pem` | the private key and the certificate |
| `identity.p12`, `identity.p12.password` | both, as PKCS#12, and its password |
| `identity.p12.base64` | the PKCS#12 in base64, for the CI secret |
| `openssl.cnf` | the certificate request settings |

Store the whole folder in your password manager, or another encrypted place. It is the only copy: the key in the keychain cannot be exported. If it is lost, a new certificate means a new DR, and every user has to grant Full Disk Access and Automation again.

**On another Mac, or after reinstalling:** copy the folder back to `~/.roomformac/signing`, run `chmod 700 ~/.roomformac/signing`, then run `scripts/make-signing-identity.sh`. It prints `reusing the key and certificate`, imports the same identity, and the SHA-1 and the DR stay the same.

## Remove grants left by ad-hoc builds

Grants recorded for an ad-hoc build name that build's cdhash, and they never match again. After your first signed build, do this once:

1. In System Settings → Privacy & Security → Full Disk Access, select every RoomForMac entry and click **−**.
2. Reset RoomForMac's Automation grants: `tccutil reset AppleEvents com.roomformac.RoomForMac`.
3. Launch the signed build with `open` or from Xcode, and grant access again in onboarding. Never start it by its executable path from Terminal: macOS would then check Terminal's grants, not RoomForMac's.

## Verify a signed build

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Debug \
    -destination platform=macOS -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Debug/RoomForMac.app
dr() { codesign -d -r- "$1" 2> /dev/null | sed -n 's/^designated => //p'; }
cdh() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Signature)'
dr "$APP"
scripts/make-signing-identity.sh --check
codesign --verify --deep --strict -vv "$APP"
APP="$APP" bats scripts/tests/app_bundle.bats
```

Expected:

- `Authority=RoomForMac Self-Signed` and `TeamIdentifier=not set`, with no `Signature=adhoc` line.
- `dr` prints `identifier "com.roomformac.RoomForMac" and certificate leaf = H"<sha1>"`, and `<sha1>` is the `--check` SHA-1 in lower case. If `dr` prints nothing, the build is still ad-hoc: `codesign -d -r-` then shows `# designated => cdhash H"…"`.
- `codesign --verify` prints `valid on disk` and `satisfies its Designated Requirement`.
- Every `app_bundle.bats` test is `ok`. One of them checks that the engine helpers carry the same `Authority` as the app.

### Stability test

The DR must stay the same while the code changes:

```bash
before_dr="$(dr "$APP")" && before_cdh="$(cdh "$APP")"
# Change any visible string, for example a Text in
# RoomForMac/Features/Status/StatusPlaceholderView.swift, and rebuild with the
# xcodebuild command above.
after_dr="$(dr "$APP")" && after_cdh="$(cdh "$APP")"
[ -n "$before_dr" ] && [ "$before_dr" = "$after_dr" ] && [ "$before_cdh" != "$after_cdh" ] && echo "stable: same DR, new code"
git checkout -- RoomForMac/Features/Status/StatusPlaceholderView.swift
```

Then check that the grants survive:

1. `open "$APP"`, grant Full Disk Access in onboarding (relaunch if it asks), and check that Settings → Permissions shows it as granted.
2. Quit, change a visible string again, rebuild and `open "$APP"`. Full Disk Access is still granted without a visit to System Settings, and no new Automation prompt appears.
3. Repeat step 2 with Xcode's **Run** (⌘R).

If a grant does not survive, note the two DR lines, both CDHashes and which step failed.

## If Xcode refuses the identity

Xcode 27 should accept a self-signed identity; this was established by reading Xcode's code, not by a real build. If a build fails at the CodeSign step with *"RoomForMac Self-Signed" is not valid for code signing*, or with *No certificate matching* while `--check` finds the identity, use one of these fallbacks.

**(a) Sign again after the build.** `codesign` signs with untrusted identities. Let Xcode sign ad-hoc, then sign the nested code first and the app last, keeping each identifier:

```bash
ID="$(scripts/make-signing-identity.sh --check | cut -d' ' -f1)"
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Debug \
    -destination platform=macOS -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
APP=build/DerivedData/Build/Products/Debug/RoomForMac.app
resign() { codesign --force --timestamp=none --sign "$ID" --preserve-metadata=identifier,entitlements,flags "$@"; }
resign "$APP/Contents/Helpers/analyze-go" "$APP/Contents/Helpers/status-go"
find "$APP/Contents/MacOS" -name '*.dylib' -exec codesign --force --timestamp=none \
    --sign "$ID" --preserve-metadata=identifier,entitlements,flags {} +
resign "$APP"
codesign --verify --deep --strict -vv "$APP" && dr "$APP"
```

Every Xcode build signs ad-hoc again, so run this after each build; in the Xcode window, also move `Config/Local.xcconfig` aside first. Tell the plan owner if you need this fallback: the lasting fix is a build step that runs these commands.

**(b) Trust the certificate for code signing, for your user only.** This helps only if Xcode filters identities by trust. macOS asks for your password:

```bash
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db ~/.roomformac/signing/cert.pem
```

To undo it: `security remove-trusted-cert ~/.roomformac/signing/cert.pem`.

## CI secrets

Release builds on GitHub Actions will need the identity. The script prints these commands, and you run them only when a release workflow exists:

```bash
gh secret set RFM_SIGNING_P12_BASE64 < ~/.roomformac/signing/identity.p12.base64
gh secret set RFM_SIGNING_P12_PASSWORD < ~/.roomformac/signing/identity.p12.password
```

The workflow imports the PKCS#12 into a temporary keychain and deletes that keychain when the job ends.

## Security

- **Anyone with this key can sign code that inherits RoomForMac's grants.** With `key.pem`, or `identity.p12` and its password, anyone can sign a program with the bundle ID `com.roomformac.RoomForMac`. It satisfies the DR of every grant users gave RoomForMac: Full Disk Access, and Automation of Finder and System Events. Guard the folder like a password.
- Never commit these files, paste them anywhere or attach them to an issue. The script refuses a `--dir` inside the repository.
- In the keychain, the key cannot be exported, and only `codesign` may use it without asking.
- Keep the GitHub secrets in this repository only, and let only the release workflow read them.
- A self-signed certificate cannot be revoked. If the key leaks, the only remedy is a new identity, and every user has to grant access again.
- The certificate is valid for 20 years. To replace it, after a leak or before it expires:
  1. delete the identity in Keychain Access (login → My Certificates → RoomForMac Self-Signed → Delete);
  2. move `~/.roomformac/signing` aside;
  3. run the script again;
  4. update the CI secrets.

  Every user then grants access again.
- A safer setup uses two identities, which the script supports. You would sign local builds with `--name "RoomForMac Dev"`, and keep `--name "RoomForMac Release" --no-import --dir <offline folder>` only offline and in CI. RoomForMac uses one identity instead, because grants made on a development build would otherwise not carry over to release builds on the same Mac.
````

- [ ] **Step 7: Link it from `README.md`**

Find:

```markdown
The host protocol is documented in `docs/engine-protocol.md`.

## License
```

Replace with:

```markdown
The host protocol is documented in `docs/engine-protocol.md`.

## Signing

Until you create the signing identity, builds are signed ad-hoc, and macOS forgets Full Disk Access and Automation grants after every rebuild. Create it once with `scripts/make-signing-identity.sh`, and click **Always Allow** when macOS asks. `docs/signing.md` explains the identity, how to back it up and how to check a signed build.

## License
```

Task 17 rewrites `README.md` whole and moves this text under "Building the app → Signing"; the README keeps a single link to `docs/signing.md`.

- [ ] **Step 8: Check the documents**

Run:

````bash
awk '/^```bash$/ { inside = 1; next } /^```$/ { inside = 0 } inside' docs/signing.md > "${TMPDIR%/}/signing-snippets.sh"
/bin/bash -n "${TMPDIR%/}/signing-snippets.sh" && echo snippets-ok
````

Expected: `snippets-ok`. Every shell block in the page parses under bash 3.2.

Run: `grep -c 'docs/signing.md' README.md && git status --short`
Expected: `1`, then only ` M README.md` and `?? docs/signing.md`. Task 17 keeps it at one link.

- [ ] **Step 9: Commit**

```bash
git add docs/signing.md README.md
git commit -F - << 'EOF'
docs: explain the signing identity and how to check a signed build

docs/signing.md covers why builds need one stable self-signed identity
(TCC grants follow the designated requirement), how to create and back
it up, how to clear grants left by ad-hoc builds, and how to verify the
DR and its stability. It also gives the fallbacks if Xcode refuses the
identity, and the security note: anyone with the key can sign code that
inherits RoomForMac's grants. README links to it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

**Owner's manual checklist** (for the final summary; `docs/signing.md` has the details):
1. Run `scripts/make-signing-identity.sh`. Enter the login password and click **Always Allow** in the dialog.
2. Back up `~/.roomformac/signing` in the password manager.
3. Confirm that `scripts/make-signing-identity.sh --check` prints `<SHA1> "RoomForMac Self-Signed"`.
4. Remove the old RoomForMac Full Disk Access entries, and run `tccutil reset AppleEvents com.roomformac.RoomForMac`.
5. Build, then check that `codesign -d -r-` shows `certificate leaf = H"<sha1>"` and that `APP=… bats scripts/tests/app_bundle.bats` passes.
6. Run the stability test, then the grant-survival steps, from the command line and from Xcode's Run. Report the DR line, both CDHashes and the result. If Xcode refuses the identity, send the exact error text and use fallback (a).

### Task 17: CI app job, README, roadmap and handoff updates

**Files:**
- Modify: `.github/workflows/ci.yml`, `README.md`, `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md`, `docs/superpowers/plans/2026-09-26-mvp-handoff.md`

**Interfaces:**
- Consumes: the schemes (Task 1), `app_bundle.bats` (Task 2) and the UI tests (Task 15).
- Produces: a CI job `app` with `name: RoomForMac app`, `runs-on: xcode-27` and `timeout-minutes: 60`. It does not depend on the `engine` job: engine artifacts are not shared across jobs, so it builds its own engine through `ensure-engine.sh`.
- Also consumes (internal to this task; the CI job and the README name these, and this task changes none of them):
  - `scripts/ensure-engine.sh`, its message `Engine is up to date: <dir>` and its `RFM_NO_ENGINE_BUILD=1` switch (Task 2);
  - `scripts/make-signing-identity.sh` and `docs/signing.md` (Task 16);
  - the DEBUG launch arguments `-RFMUITestScenario onboarding|onboarded|engine-broken` (Task 1) and `-RFMForceMoveStep YES` (Task 10).

**Requirements:**
- Steps of the `app` job, in this order:
  1. checkout with `submodules: recursive`;
  2. `actions/setup-go@v5` (same config as the engine job);
  3. `brew install xcodegen bats-core`;
  4. `xcodegen generate`;
  5. `xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit -destination platform=macOS test`;
  6. a Release build to `build/DerivedData` with `-destination "generic/platform=macOS"`;
  7. `APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats`;
  8. UI tests `xcodebuild … -scheme RoomForMac -only-testing:RoomForMacUITests test`. GitHub's runner images enable Automation Mode.
- Additions to those eight steps:
  - **"Show the toolchain"** prints `sw_vers`, `xcodebuild -version`, `xcodegen --version` and `go version`, so a runner-image change shows in the log.
  - **"Build the patched engine"** runs `scripts/ensure-engine.sh` before step 4. Steps 5, 6 and 8 then run with `RFM_NO_ENGINE_BUILD=1`, so the engine is built once, in its own step, and the "Prepare engine" phase can never rebuild it during a test run. Verified in scratch: `xcodebuild` passes its environment through to run-script phases.
  - **Steps 5, 6 and 8 share `-derivedDataPath build/DerivedData`**, so the local package and the app compile once per configuration.
  - **"Allow Automation Mode for UI tests"** runs before step 8. It prints the state from `automationmodetool`. Only when that state lacks `DOES NOT REQUIRE` does it run `sudo automationmodetool enable-automationmode-without-authentication`. GitHub's images already allow it (research V5), so this step only guards against a future image change.
  - **"Keep the test results of a failed run"** (`if: failure()`) uploads `build/DerivedData/Logs/Test`, which holds the `.xcresult` bundles with the UI-test screenshots, as the artifact `app-test-results`, kept 14 days. The development Mac cannot run the UI tests without Automation Mode, so this artifact is how a CI failure gets diagnosed.
- **Both jobs check out with `fetch-depth: 0`.** This fixes a problem found while writing this task. With the default depth of 1, `actions/checkout` clones `vendor/mole` with `--depth=1` and no tags, so `build-engine.sh` writes `mole_tag=untagged`:
  - Plan 1's check "VERSION records the pinned Mole release and patch set" fails in the engine job.
  - The app built by CI reports an untagged engine.

  This was reproduced in scratch by replaying the checkout action's git commands against a local copy of Mole whose `main` is past `V1.56.0`. With `--depth=1`, `git describe --tags --exact-match` fails. With a full submodule clone, it prints `V1.56.0`.
- The `engine` job gains the `bats scripts/tests/signing_identity.bats` run as part of "Engine build checks". `bats scripts/tests` already covers it, and a comment on the step says so. The "Lint build scripts" and "Audit build-check assertions" steps already cover Plan 2's scripts and bats files through their globs.
- `on.push.branches` gains `main-mrvlfl`, because it is GitHub's default branch.
- `README.md` is rewritten whole. It keeps Plan 1's sections and Task 16's link to `docs/signing.md`, and it gains a "Building the app" section:
  - `brew bundle`;
  - `git submodule update --init`;
  - `xcodegen generate`;
  - `open RoomForMac.xcodeproj`, or `xcodebuild -scheme RoomForMac build` (written with `-project` and `-destination platform=macOS`, like every other command in this plan);
  - the first build builds the engine (about a minute);
  - signing (link to `docs/signing.md`);
  - UI tests need Automation Mode.

  It also covers the test commands, the rule against two engine builds at once, and the two DEBUG launch arguments. Its Requirements now say that building the app needs Xcode 27.0 or later.
- The roadmap:
  - The status line marks Plan 2 done and Plan 3 next.
  - The Plan 2 row names the plan file, as the Plan 1 row does.
- The handoff:
  - Step 1 is marked done, with a pointer to this plan.
  - Step 2 is marked done, and so are the Session 2 and Session 3 prompts.
  - "Where things stand" drops "There is no app yet" and notes that the new CI job has not run either.
- Verify:
  - `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'` parses.
  - The local sequence passes: the engine steps, then `xcodegen generate`, the unit scheme, the Release build and `app_bundle.bats`.
  - Record the UI test result.

All commands run from the repository root.

- [ ] **Step 1: Write the workflow check and watch it fail**

This check pins what the workflow must contain. It is not committed, and Step 3 runs it again.

Run:
```bash
ruby -ryaml - << 'RUBY'
workflow = YAML.load_file(".github/workflows/ci.yml")
errors = []
check = lambda { |ok, message| errors << message unless ok }

on = workflow["on"] || workflow[true] # YAML 1.1 reads the bare key `on` as true
branches = on.dig("push", "branches") || []
check.(branches.sort == %w[main main-mrvlfl], "push must run on main and main-mrvlfl, not #{branches.inspect}")
check.(on.key?("pull_request"), "the pull_request trigger is missing")

jobs = workflow["jobs"] || {}
engine = jobs["engine"] || {}
app = jobs["app"]
check.(engine["runs-on"] == "macos-26", "engine: must stay on macos-26")
check.((engine["steps"] || []).any? { |s| s["run"].to_s.strip == "bats scripts/tests" },
       "engine: must run bats scripts/tests")

{ "engine" => engine, "app" => app || {} }.each do |name, job|
  next if job.empty?
  checkout = (job["steps"] || []).find { |s| s["uses"] == "actions/checkout@v4" } || {}
  check.(checkout.dig("with", "submodules") == "recursive", "#{name}: checkout without submodules: recursive")
  check.(checkout.dig("with", "fetch-depth") == 0, "#{name}: checkout without fetch-depth: 0")
end

if app.nil?
  errors << "jobs.app is missing"
else
  check.(app["name"] == "RoomForMac app", "app: name is #{app["name"].inspect}")
  check.(app["runs-on"] == "xcode-27", "app: runs-on is #{app["runs-on"].inspect}")
  check.(app["timeout-minutes"] == 60, "app: timeout-minutes is #{app["timeout-minutes"].inspect}")
  check.(!app.key?("needs"), "app: must not wait for another job")
  steps = app["steps"] || []
  go = steps.find { |s| s["uses"] == "actions/setup-go@v5" }
  engine_go = (engine["steps"] || []).find { |s| s["uses"] == "actions/setup-go@v5" }
  check.(go && engine_go && go["with"] == engine_go["with"], "app: setup-go differs from the engine job")
  runs = steps.map { |s| s["run"].to_s.strip }
  expected = [
    /\Abrew install xcodegen bats-core\z/,
    /\Ascripts\/ensure-engine\.sh\z/,
    /\Axcodegen generate\z/,
    /-scheme RoomForMacUnit -destination platform=macOS .*\btest\z/,
    /-configuration Release -destination "generic\/platform=macOS" -derivedDataPath build\/DerivedData build\z/,
    /\AAPP=build\/DerivedData\/Build\/Products\/Release\/RoomForMac\.app EXPECT_UNIVERSAL=1 bats scripts\/tests\/app_bundle\.bats\z/,
    /-scheme RoomForMac -destination platform=macOS .*-only-testing:RoomForMacUITests test\z/,
  ]
  previous = -1
  expected.each do |pattern|
    index = runs.index { |run| run.match?(pattern) }
    if index.nil?
      errors << "app: no step runs #{pattern.source}"
    elsif index < previous
      errors << "app: step #{pattern.source} is out of order"
    else
      previous = index
    end
  end
end

if errors.empty?
  puts "ci.yml: ok"
else
  puts errors
  exit 1
end
RUBY
```
Expected: FAIL (exit 1), printing exactly:
```
push must run on main and main-mrvlfl, not ["main"]
engine: checkout without fetch-depth: 0
jobs.app is missing
```
`/usr/bin/ruby` 2.6 ships with macOS and includes YAML. Ruby's YAML parser reads the bare key `on` as `true` (YAML 1.1), hence `workflow[true]`.

- [ ] **Step 2: Write the workflow** — `.github/workflows/ci.yml`

This is the whole file. The `engine` job changes only in its checkout (`fetch-depth: 0`) and a comment on "Engine build checks".

```yaml
name: CI

on:
  push:
    # main-mrvlfl is the repository's default branch on GitHub.
    branches: [main, main-mrvlfl]
  pull_request:

jobs:
  engine:
    name: Engine and MoleEngine
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          # A shallow checkout leaves vendor/mole without its tags, and the
          # engine's VERSION then records mole_tag=untagged.
          fetch-depth: 0

      - uses: actions/setup-go@v5
        with:
          go-version-file: vendor/mole/go.mod
          cache-dependency-path: vendor/mole/go.sum

      - name: Install tools
        run: brew install bats-core shellcheck shfmt coreutils parallel

      - name: Lint build scripts
        run: |
          shellcheck scripts/*.sh
          shfmt -d -i 4 -ci -sr scripts/*.sh

      - name: Audit build-check assertions
        run: python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats

      - name: Build the patched engine
        run: scripts/build-engine.sh

      # build_engine.bats, plus signing_identity.bats (stubbed tools, no
      # keychain). app_bundle.bats skips here without APP; the app job runs it.
      - name: Engine build checks
        run: bats scripts/tests

      - name: Patch tests
        run: >-
          scripts/mole-patches.sh test --tree build/engine-src
          tests/host_integration.bats tests/clean_json_events.bats
          tests/clean_selection.bats tests/uninstall_host_mode.bats

      - name: Analyzer Trash-list tests
        run: cd build/engine-src && go test ./cmd/analyze -run TrashList -count=1

      - name: Mole's full suite on the patched tree
        run: cd build/engine-src && ./scripts/test.sh

      - name: MoleEngine unit and integration tests
        env:
          RFM_ENGINE_DIR: ${{ github.workspace }}/build/engine
        run: swift test --package-path Packages/MoleEngine

  app:
    name: RoomForMac app
    # Xcode 27.0 with the macOS 27 SDK, like the development Mac. The macos-26
    # image has only Xcode 26.6 and SDK 26.5 (Plan 2, Ruling 14).
    runs-on: xcode-27
    timeout-minutes: 60
    # No `needs: engine`: jobs share no files, so this job builds its own engine.
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0

      - uses: actions/setup-go@v5
        with:
          go-version-file: vendor/mole/go.mod
          cache-dependency-path: vendor/mole/go.sum

      - name: Install tools
        run: brew install xcodegen bats-core

      - name: Show the toolchain
        run: |
          sw_vers
          xcodebuild -version
          xcodegen --version
          go version

      - name: Build the patched engine
        run: scripts/ensure-engine.sh

      - name: Generate the Xcode project
        run: xcodegen generate

      # RFM_NO_ENGINE_BUILD=1: the "Prepare engine" phase fails instead of
      # rebuilding, so every build below embeds the engine built above.
      - name: Unit tests
        env:
          RFM_NO_ENGINE_BUILD: "1"
        run: >-
          xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit
          -destination platform=macOS -derivedDataPath build/DerivedData test

      - name: Universal Release build
        env:
          RFM_NO_ENGINE_BUILD: "1"
        run: >-
          xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac
          -configuration Release -destination "generic/platform=macOS"
          -derivedDataPath build/DerivedData build

      - name: Bundle checks
        run: APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats

      # GitHub's macOS images allow Automation Mode without authentication.
      # Allow it here too, should an image ever stop doing so.
      - name: Allow Automation Mode for UI tests
        run: |
          status="$(automationmodetool)"
          echo "$status"
          if ! grep -q 'DOES NOT REQUIRE' <<< "$status"; then
            sudo automationmodetool enable-automationmode-without-authentication
          fi

      - name: UI smoke tests
        env:
          RFM_NO_ENGINE_BUILD: "1"
        run: >-
          xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac
          -destination platform=macOS -derivedDataPath build/DerivedData
          -only-testing:RoomForMacUITests test

      - name: Keep the test results of a failed run
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: app-test-results
          path: build/DerivedData/Logs/Test
          if-no-files-found: ignore
          retention-days: 14
```

Notes:
- `xcode-27` is GitHub's public-preview label for macOS 27.0 with Xcode 27.0 (27A266a) as the default, which matches this Mac (Ruling 14). Neither image ships XcodeGen or bats, hence the `brew install`.
- `run:` steps use GitHub's default macOS shell, `bash -e`. That is bash 3.2, which has the `<<<` here-string used in the Automation Mode step.
- `status-go --json` in `app_bundle.bats` asks Finder for free space with a 5-second timeout (`cmd/status/metrics_disk.go`). A runner that never answers the Apple event cannot stall the job.
- The app job has no `shellcheck`, `shfmt` or bats audit. The engine job already runs them on the same files.

- [ ] **Step 3: Run the check again**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")' && echo parsed`, then the Step 1 command again.
Expected: `parsed`, then `ci.yml: ok` (exit 0).

- [ ] **Step 4: Write `README.md`**

This is the whole file. Plan 1's "Building the engine", "Changing the engine patches" and "License" sections are unchanged. Task 16's link to `docs/signing.md` now sits under "Building the app → Signing".

````markdown
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

- **The first build also builds the engine**, which takes about a minute. Later builds reuse `build/engine` and rebuild it only when `vendor/mole`, `patches/mole/` or `scripts/build-engine.sh` change.
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
````

Run:
```bash
grep -c 'docs/signing.md' README.md
ls docs/signing.md docs/engine-protocol.md scripts/make-signing-identity.sh scripts/ensure-engine.sh scripts/tests/app_bundle.bats
```
Expected: `1`, then the five paths, with no `No such file or directory`. Every file the README names exists.

- [ ] **Step 5: Update the roadmap** — `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md`

Make two exact replacements.

1. Replace the status line:
   ```markdown
   **Status (2026-09-26):** Plan 1 is built on `main`, and its CI run is blocked by Actions billing. The recommended MVP scope, the remaining steps and prompts for the next sessions are in `docs/superpowers/plans/2026-09-26-mvp-handoff.md`.
   ```
   with:
   ```markdown
   **Status:** Plans 1 and 2 are done, and **Plan 3 is next**: Smart Clean, Uninstaller, Status and the menu-bar extra. Plan 1 is on `main`, and Plan 2 is on the branch `plan2/app-shell`. CI still cannot run until Actions billing is fixed or the repository is made public. Plan 2's Rulings record decisions it took for the owner, among them the bundle ID, the single signing identity and the CI runner; confirm them before Plan 6 ships. The recommended MVP scope, the remaining steps and prompts for the next sessions are in `docs/superpowers/plans/2026-09-26-mvp-handoff.md`.
   ```
2. In the plans table, replace the start of the Plan 2 row:
   ```markdown
   | 2 | App shell, design system, onboarding & permissions |
   ```
   with:
   ```markdown
   | 2 | **App shell** — `2026-09-26-plan-2-app-shell.md` |
   ```
   The rest of the row stays as it is.

- [ ] **Step 6: Update the handoff** — `docs/superpowers/plans/2026-09-26-mvp-handoff.md`

Make six exact replacements. Each old text occurs once in the file.

1. In "Where things stand", replace:
   ```markdown
   - **There is no app yet.** There is no `project.yml` and no `RoomForMac/` target. Plans 2–7 are not written.
   ```
   with:
   ```markdown
   - **Plan 2 (app shell) is built** on the branch `plan2/app-shell`. It holds the XcodeGen project with the embedded engine, the design system, onboarding, permissions and Settings. Plans 3–7 are not written.
   ```
2. At the end of the "CI has never run" bullet, replace:
   ```markdown
   private repositories are billed for macOS runner minutes. The workflow file itself is fine.
   ```
   with:
   ```markdown
   private repositories are billed for macOS runner minutes. The workflow file itself is fine. Plan 2 added the `app` job on the `xcode-27` runner and a push trigger for `main-mrvlfl`; they have not run either, for the same reason.
   ```
3. Replace the Step 1 heading and the first line of its brief:
   ```markdown
   ### Step 1 — Write Plan 2: app shell, design system, onboarding and permissions
   Use `superpowers:writing-plans`. Save it as `docs/superpowers/plans/<date>-plan-2-app-shell.md`. It must cover:
   ```
   with the lines below. The rest of the brief stays as it is.
   ```markdown
   ### Step 1 — Write Plan 2: app shell, design system, onboarding and permissions (done)

   **Done:** `docs/superpowers/plans/2026-09-26-plan-2-app-shell.md`. Its Rulings record where it departs from the brief below:
   - `scripts/ensure-engine.sh` rebuilds the engine only when its inputs change, and `scripts/embed-engine.sh` copies it into the app. `build-engine.sh` does not run on every build.
   - The Go tools live in `Contents/Helpers`, linked from `engine/bin`.
   - The app's CI job runs on the `xcode-27` runner.

   The brief it was written from:

   Use `superpowers:writing-plans`. Save it as `docs/superpowers/plans/<date>-plan-2-app-shell.md`. It must cover:
   ```
4. Replace the Step 2 heading and its line:
   ```markdown
   ### Step 2 — Execute Plan 2
   Use `superpowers:subagent-driven-development`, one task per commit, as Plan 1 was built.
   ```
   with:
   ```markdown
   ### Step 2 — Execute Plan 2 (done)
   Use `superpowers:subagent-driven-development`, one task per commit, as Plan 1 was built.

   **Done** on the branch `plan2/app-shell`. What is left needs the owner, and Plan 2's "Done when" lists it: the signing identity, the S2/S5/TCC checks on a signed build, Automation Mode for local UI tests, backdrop photos and CI billing.
   ```
5. Replace `**Session 2: write Plan 2.**` with `**Session 2: write Plan 2.** Done.`
6. Replace `**Session 3: execute Plan 2.**` with `**Session 3: execute Plan 2.** Done.`

- [ ] **Step 7: Check the documents**

Run:
```bash
grep -c 'Plan 3 is next' docs/superpowers/plans/2026-09-25-roomformac-roadmap.md
grep -c '2026-09-26-plan-2-app-shell.md' docs/superpowers/plans/2026-09-25-roomformac-roadmap.md
grep -E '^### Step [12] ' docs/superpowers/plans/2026-09-26-mvp-handoff.md
grep -c 'Done\.$' docs/superpowers/plans/2026-09-26-mvp-handoff.md
grep -c 'There is no app yet' docs/superpowers/plans/2026-09-26-mvp-handoff.md
git diff --shortstat -- docs/superpowers/plans
```
Expected:
```
1
1
### Step 1 — Write Plan 2: app shell, design system, onboarding and permissions (done)
### Step 2 — Execute Plan 2 (done)
2
0
 2 files changed, 18 insertions(+), 8 deletions(-)
```

- [ ] **Step 8: Run the engine half of CI locally**

Run:
```bash
shellcheck scripts/*.sh && shfmt -d -i 4 -ci -sr scripts/*.sh
python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats
scripts/build-engine.sh
bats scripts/tests
RFM_ENGINE_DIR="$PWD/build/engine" swift test --package-path Packages/MoleEngine
```
Expected:
- no output from `shellcheck` or `shfmt`;
- `bats-assertion-audit-ok files=3` (`app_bundle.bats`, `build_engine.bats`, `signing_identity.bats`);
- `Engine ready: …/build/engine (V1.56.0, 5 patches)`;
- from bats, no `not ok`:
  - all 16 tests of `build_engine.bats` are `ok`;
  - all 10 tests of `app_bundle.bats` are `ok … # skip set APP=/path/to/RoomForMac.app to check a built app`;
  - every test of `signing_identity.bats` is `ok`;
- all 61 package tests pass (56 unit, 5 integration). The integration suite takes about 80 s.

This run skips the engine job's patch tests, analyzer tests and Mole's full suite. Plan 2 changes nothing they run: `vendor/mole`, `patches/mole/` and the patched tree are as Plan 1 left them. Plan 1 Task 13 Step 2 runs them, with their three known upstream failures. Let each command finish before starting the next: `build-engine.sh` and `bats` both re-clone `build/engine-src`.

- [ ] **Step 9: Run the app job's build and checks locally**

These are the CI job's commands:
```bash
scripts/ensure-engine.sh
xcodegen generate
RFM_NO_ENGINE_BUILD=1 xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMacUnit \
    -destination platform=macOS -derivedDataPath build/DerivedData test
RFM_NO_ENGINE_BUILD=1 xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac \
    -configuration Release -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 bats scripts/tests/app_bundle.bats
```
Expected, in order:
- `Engine is up to date: …/build/engine`, because Step 8 has just built it;
- `Created project at …/RoomForMac.xcodeproj`;
- `** TEST SUCCEEDED **`, with every Swift Testing suite from Tasks 1–15 passing. The build log shows `Engine is up to date: …/build/engine` from the "Prepare engine" phase, never `Engine is missing or stale`;
- `** BUILD SUCCEEDED **`;
- `1..10`, and all 10 tests `ok`.

Suppose an `xcodebuild` fails with `error: …/build/engine is missing or stale; run scripts/build-engine.sh`. Then `RFM_NO_ENGINE_BUILD=1` did its job: something changed the engine's inputs after Step 8. Run `scripts/ensure-engine.sh` and repeat from the failed command.

- [ ] **Step 10: Attempt the UI smoke tests and record the result**

Run: `automationmodetool`

Run: `RFM_NO_ENGINE_BUILD=1 xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination platform=macOS -derivedDataPath build/DerivedData -only-testing:RoomForMacUITests test`

Expected, one of:
- **Pass.** Automation Mode is available: the state says `DOES NOT REQUIRE`, or someone at the Mac approves the password or Touch ID prompt. Then `LaunchSmokeTests`, `OnboardingSmokeTests` and `EngineProblemSmokeTests` pass, and the run ends with `** TEST SUCCEEDED **`.
- **Environment limit.** After about 90 s, `Timed out while enabling automation mode.`, then `** TEST FAILED **` (exit 65). This Mac is in that state today: `This device requires user authentication to enable Automation Mode.` It is an environment limit, not a code failure, and CI runs these tests.

Report the outcome in the task summary: pass, or not run because of Automation Mode. Do not run `sudo automationmodetool enable-automationmode-without-authentication` on the development Mac yourself. It lowers a security setting, and only the owner decides that (see the README).

- [ ] **Step 11: Commit**

```bash
git add .github/workflows/ci.yml README.md \
    docs/superpowers/plans/2026-09-25-roomformac-roadmap.md \
    docs/superpowers/plans/2026-09-26-mvp-handoff.md
git status --short
```
Expected:
```
M  .github/workflows/ci.yml
M  README.md
M  docs/superpowers/plans/2026-09-25-roomformac-roadmap.md
M  docs/superpowers/plans/2026-09-26-mvp-handoff.md
```
Nothing else is listed. `build/`, `RoomForMac.xcodeproj/`, `RoomForMac/Generated/` and `Config/Local.xcconfig` are git-ignored.

```bash
git commit -F - << 'EOF'
ci: add the RoomForMac app job and document building the app

The new "RoomForMac app" job runs on the xcode-27 image, which matches
the development Mac's Xcode 27.0. It builds its own engine, generates
the project and runs the unit scheme. It then checks a universal Release
build with app_bundle.bats and runs the UI smoke tests. The test results
of a failed run are kept as an artifact.

Both jobs now check out full history. With a shallow checkout,
vendor/mole has no tags, VERSION records mole_tag=untagged, and the
engine build check for V1.56.0 fails. Pushes to main-mrvlfl, GitHub's
default branch, now run CI too.

The README explains how to build, sign and test the app. The roadmap
and the MVP handoff mark Plan 2 done and Plan 3 next.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

- [ ] **Step 12: Push and watch CI (only after the user approves pushing)**

Pushing publishes the branch, so ask first. CI also cannot start until Actions billing is fixed or the repository is public (handoff, "Only you can do these", item 1). Once both are settled:
1. Run `git push -u origin plan2/app-shell`.
2. Open a pull request for the branch. The `pull_request` trigger runs both jobs.
3. Check the run in GitHub Actions.

Expected:
- `Engine and MoleEngine` and `RoomForMac app` are both green.
- In the engine job, "Engine build checks" lists the `signing_identity.bats` tests.
- In the app job, "Show the toolchain" prints `Xcode 27.0`, and "Allow Automation Mode for UI tests" prints a line containing `DOES NOT REQUIRE`.
- If "UI smoke tests" fails, download the `app-test-results` artifact and open its `.xcresult` in Xcode.

This step stays unticked until one run completes with both jobs green.

---

## Done when

- `xcodegen generate && xcodebuild -scheme RoomForMacUnit test` passes on this Mac, with every unit test green and no warnings.
- A Release build is universal, passes `app_bundle.bats`, and launches. On a first launch, onboarding appears, and the `onboarding` UI scenario walks through all steps to the Smart Clean placeholder.
- A broken or mismatched engine shows the blocking Reinstall card.
- Settings shows General, Permissions (live) and About with the engine line and all four legal documents.
- `scripts/make-signing-identity.sh` exists with its bats tests. `docs/signing.md` holds the owner's checklist.
- `ci.yml` has the `app` job. The roadmap and handoff are updated.
- The owner's manual checklist is in the final summary: signing identity, the S2/S5/TCC checks on a signed build, Automation Mode for UI tests, photos, and CI billing.
