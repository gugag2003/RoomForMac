# RoomForMac — MVP Handoff (2026-09-26)

What is left between today's `main` and an MVP, in the order to do it, with a prompt to paste into each next session.

**Read first:** spec `docs/superpowers/specs/2026-09-25-roomformac-design.md`, roadmap `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md`, Plan 1 `docs/superpowers/plans/2026-09-25-plan-1-engine.md` (its Global Constraints and Environment notes apply to every later plan).

## Where things stand

- **Plan 1 (engine) is on `main`.** It includes five Mole patches, `scripts/build-engine.sh`, and the `MoleEngine` Swift package. Verified on 2026-09-26: `bats scripts/tests` 6/6, `swift test --package-path Packages/MoleEngine` with `RFM_ENGINE_DIR=$PWD/build/engine` 55/55 (50 unit + 5 integration), and the bats assertion audit is clean.
- **Plan 2 (app shell) is on `main`.** It holds the XcodeGen project with the embedded engine, the design system, onboarding, permissions and Settings.
- **Plan 3 is built** on the branch `plan3/features` (`docs/superpowers/plans/2026-09-27-plan-3-features.md`): Smart Clean, the Uninstaller, Status, the menu-bar extra and notifications. It amends patch 0004, adds patch 0006 and the `status-bin` stubs, and adds the removal seams Plan 5 plugs into. Its UI smoke tests are built but not run, because they need Automation Mode. The spec errata it found are listed in the roadmap. Plans 4–7 are not built.
- **CI has never run.** Every Actions run ended in `startup_failure` with no jobs. The run page's annotation says: "The job was not started because recent account payments have failed or your spending limit needs to be increased." The repository is private, and private repositories are billed for macOS runner minutes. The workflow file itself is fine. Plan 2 added the `app` job on the `xcode-27` runner and a push trigger for `main-mrvlfl`; they have not run either, for the same reason. Plan 3 added `tests/clean_removed_sizes.bats` to the engine job's patch tests and changed nothing else.
- **Git state:**
  - `main`, `origin/main` and GitHub's default branch `main-mrvlfl` hold Plans 1 and 2, and `fix/engine-kb-overflow` is merged.
  - Plan 3 is on the branch `plan3/features`, taken from that `main`.

## MVP scope — M2, chosen on 2026-09-26

| Milestone | Plans | Done when |
|---|---|---|
| **M1: runs on your Mac** | 2, 3 | Built from source, the app on your Mac takes you through onboarding and the Full Disk Access grant. It scans and cleans with Smart Clean, uninstalls an app to the Trash, and shows Status and the menu-bar extra. The engine is bundled, and there is no allowance or paywall. |
| **M2: someone else can download, try and pay** | + 5, 6 | Adds the 1 GB allowance, paywall, Polar licensing, telemetry, and a signed DMG with Sparkle updates. This meets every success criterion in spec §2. |
| After the MVP | 4, 7 | Terrain (bubble explorer) and admin-level cleanup. |

Terrain is one of the four headline tools in spec §1. If it must ship in the MVP, move Plan 4 into M2. It depends only on Plans 1 and 2.

## Only you can do these

1. **Unblock CI.** Fix the account's Actions payment or spending limit, or make the repository public. The spec already plans a public GPL-3.0 repository, and public repositories get standard macOS runners free.
2. **Choose the merchant of record** (blocks Plan 5). Polar cannot pay out to Brazil, so sell through Polar with a US or EU entity, through Paddle, or through another provider. Plan 5 keeps the provider behind one backend adapter.
3. **Confirm the roadmap's four "Decisions made while planning", Plan 3's Rulings and the spec errata** the roadmap lists. Plan 3 took these decisions for you, among others:
   - amending patch 0004 and adding patch 0006;
   - the `status-bin` stubs, which keep Status away from Finder and Bluetooth;
   - the menu-bar extra on by default, and Status paused while only the extra shows;
   - unknown-size items selected by default;
   - standard users seeing every `/Applications` app as needing a password until Plan 7;
   - notifications only for finished scans, cleanups and uninstalls.
4. **Backdrop photos (spec §11.3).** Pick five public-domain or CC0 images, or accept flat `canvas` placeholders for M1.
5. **M2 only:** the license price, a Polar account with a license-key benefit (activation limit 3), a Supabase project, a PostHog project, a self-signed code-signing certificate for CI, Sparkle EdDSA keys, and the site domain.
6. **Run Plan 3's manual checks** below, on a signed build. They need your Mac, a real App Store app, a login, a second account or Automation Mode, so no agent can run them.

## Manual checks for Plan 3

Each check needs something an agent cannot use: a signed build, a real App Store app, a login, a second account or Automation Mode. Note what you see for each. The checks marked U settle questions the Plan 3 research could not.

**Setup, once.** macOS ties privacy grants to the app's signature, so use a Release build signed with the stable identity (`docs/signing.md`), installed in `/Applications`:

```bash
scripts/make-signing-identity.sh --check # prints the SHA-1; if it exits 1, run it without --check
xcodegen generate
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build
```

Quit RoomForMac if it runs, and move any older `/Applications/RoomForMac.app` to the Trash. If this Mac already gave RoomForMac Automation access, reset it with `tccutil reset AppleEvents com.roomformac.RoomForMac`, so check 1 starts clean. Then:

```bash
ditto build/DerivedData/Build/Products/Release/RoomForMac.app /Applications/RoomForMac.app
open /Applications/RoomForMac.app
```

In onboarding (or in Settings → Permissions, if onboarding is already done on this Mac), allow Full Disk Access and System Events, but **leave Finder not allowed** for now. Turn on **Notify me when a scan or cleanup finishes** in Extras (on an onboarded Mac, in Settings → General). The menu-bar extra is on by default. End onboarding with **Not now** rather than **Start first scan**, so no scan runs yet.

1. **U6: Status never uses Finder or Bluetooth.** Keep Settings closed and start no scan. In Terminal, record the privacy log:
   ```bash
   log stream --info --style compact --predicate 'subsystem == "com.apple.TCC"' > ~/Desktop/rfm-tcc.log
   ```
   Open RoomForMac → Status and leave it on screen for 70 seconds (the engine does a full collect every 30 s), then open the menu-bar panel. Stop the log with ⌃C.
   - Pass: no dialog asks to let RoomForMac control Finder or use Bluetooth. In System Settings → Privacy & Security, **Bluetooth** does not list RoomForMac, and **Automation** → RoomForMac has no Finder switch.
   - If either appears, keep `rfm-tcc.log`, and check that `ls -l /Applications/RoomForMac.app/Contents/Resources/engine/status-bin` lists `osascript` and `system_profiler` as executable.
   - Then allow Finder in RoomForMac → Settings → Permissions. Checks 2 and 3 may need it.
2. **U3: quitting an app shows no Automation prompt.** TextEdit cannot be used: it lives in `/System/Applications`, which the Uninstaller never lists. Make a throwaway applet before you open the Uninstaller, or relaunch RoomForMac afterwards so the list includes it:
   ```bash
   mkdir -p ~/Applications
   osacompile -s -o ~/Applications/"RFM Quit Test.app" -e 'on idle' -e 'return 30' -e 'end idle'
   /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.rfm-quit-test' \
       ~/Applications/"RFM Quit Test.app"/Contents/Info.plist
   codesign --force --sign - ~/Applications/"RFM Quit Test.app"
   open ~/Applications/"RFM Quit Test.app"
   ```
   Quit any other AppleScript applet first: every applet's executable is named `applet`, and RoomForMac holds back an app whose executable name another running process shares. In RoomForMac → Uninstaller, search for "RFM Quit Test", select it and click **Move to Trash**.
   - Pass: the drawer shows it quitting the app, the applet quits, the summary says it moved to the Trash, and no dialog asks to let RoomForMac control "RFM Quit Test". System Settings → Privacy & Security → Automation → RoomForMac lists no "RFM Quit Test".
   - If a dialog appears, note its words: the quit step then needs an onboarding card (Plan 3 Ruling 14).
3. **U4: a root-owned App Store app moves to the Trash.** Install a small free app from the App Store that you do not need, and check that `ls -ld /Applications/<App>.app` shows `root` and `wheel`. Relaunch RoomForMac so its list includes the app, then remove it with **Move to Trash**.
   - Pass: the app is in the Trash, and the summary lists it as moved. Note whether macOS showed anything: an App Management request, or a notice that RoomForMac was prevented from modifying apps.
   - If it failed and the summary offers **Open App Management**, allow RoomForMac there and try again. Note what happened: onboarding then needs an App Management card (Plan 3 Ruling 14).
   - Afterwards, drag the app back from the Trash or reinstall it from the App Store.
4. **U5: a login launch opens no window.** In RoomForMac → Settings → General, turn on **Open RoomForMac at login** and **Show RoomForMac in the menu bar**. Choose Apple menu → Log Out, untick "Reopen windows when logging back in", and log back in.
   - Pass: the RoomForMac item appears in the menu bar, and no RoomForMac window opens.
   - If the window opens, macOS did not mark the launch as a login launch (`keyAELaunchedAsLogInItem`). That is harmless (Plan 3 Ruling 18); note it.
5. **U7: a purchase link reaches the app in every state.** Plan 3 keeps the link for Plan 5, so the sign that it arrived is the main window coming to the front, once. Run `open 'roomformac://purchased?checkout_id=test_123'` in each state:
   - menu-bar only, right after the login in check 4;
   - running with its window closed (close it with ⌘W);
   - not running (quit it from the menu-bar panel first).

   Pass: each time, RoomForMac comes to the front with one main window, and no second window or error appears. In the first two states the window was closed, so its appearing shows the link arrived. When the app is not running, any launch opens the window, so that state only shows that the link starts the app cleanly; Plan 5 repeats this check with its purchase screen, which shows the link itself.
6. **The menu-bar panel and the extra**, on macOS 27 and, if you can, on macOS 26 (a virtual machine is enough):
   - Open the panel: the gauges fill within about half a second, `pgrep -x status-go` prints exactly one process ID, and `ps -o stat= -p "$(pgrep -x status-go)"` prints a state that does not start with `T`.
   - Close the panel, with the window closed too. About 30 s later the same `ps` command prints a state that starts with `T` (stopped).
   - In Settings → General, turn **Show RoomForMac in the menu bar** off: the item disappears at once. Turn it on: the item comes back. ⌘-drag the item out of the menu bar: the switch turns off.
   - A Dock click, with the main window closed and the menu-bar extra shown, reopens the window.
   - Start an uninstall and let it reach its Force Quit question, close the window, then quit RoomForMac from the menu-bar panel: it brings the Uninstaller forward again with the question still visible.
   - Opening and closing the menu-bar panel turns Status live and back to paused: this is the panel's own visibility signal, separate from the window's Status section being on screen.
7. **Energy.** Close the window and the panel, so only the menu-bar extra shows, wait 30 s, then run:
   ```bash
   for _ in $(seq 12); do
       pid="$(pgrep -x status-go)"
       if [ -n "$pid" ]; then echo "$(date +%T) $(ps -o stat=,pcpu= -p "$pid")"; else echo "$(date +%T) no status-go"; fi
       sleep 30
   done
   ```
   - Pass: each line shows a state starting with `T` and `0.0` CPU until about 5 minutes after the pause began, and `no status-go` after that, because the paused process quits. Opening the panel then shows readings within about half a second.
8. **The first app list on a new account, and a standard user.** In System Settings → Users & Groups, add a **Standard** account, log in to it and open `/Applications/RoomForMac.app`. Granting Full Disk Access there asks for an administrator's name and password.
   - Time the first Uninstaller list, from opening the Uninstaller to seeing rows, and note any row that reads "Size unknown". The plan expects about 15 seconds, with a size for every app.
   - Every app in `/Applications` shows "Needs your password" and cannot be selected. Apps in that account's own `~/Applications` can be removed. Smart Clean scans and cleans that account's files, and Status and the menu-bar extra work.
   - Delete the account afterwards if you do not need it.
9. **A real notification.** With **Notify me when a scan or cleanup finishes** on (Settings → General), start a Smart Clean scan and switch to another app before it ends.
   - Pass: a "Scan finished" notification gives the size that can be cleaned, and clicking it opens RoomForMac on Smart Clean. With RoomForMac in front when a scan ends, nothing is posted. A cleanup and an uninstall that end while another app is in front each post one too. No notification names a file or an app.
10. **The UI smoke tests.** They need Automation Mode; see "UI tests need Automation Mode" in the README. Run:
    ```bash
    xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/RoomForMac-plan3" \
        -only-testing:RoomForMacUITests test
    ```
    Pass: `** TEST SUCCEEDED **`, covering Plan 2's launch, onboarding and engine-problem tests and Plan 3's `SmartCleanSmokeTests`, `UninstallerSmokeTests` and `StatusSmokeTests`.

## Work remaining, in order

### Step 0 — Land Plan 1 (done, except the CI run)

**Done:** `fix/engine-kb-overflow` is merged, Plan 1 Task 13 Step 2 passed, and `main` is pushed. Task 13 Step 4 waits for a green CI run.

1. Merge `fix/engine-kb-overflow` into `main`.
2. Run Plan 1 Task 13 Step 2, the full local sequence. Mole's suite has three known upstream failures; see Plan 1 Environment notes.
3. After you approve, push `main`.
4. Once CI is green, tick Task 13 Step 4.

### Step 1 — Write Plan 2: app shell, design system, onboarding and permissions (done)

**Done:** `docs/superpowers/plans/2026-09-26-plan-2-app-shell.md`. Its Rulings record where it departs from the brief below:
- `scripts/ensure-engine.sh` rebuilds the engine only when its inputs change, and `scripts/embed-engine.sh` copies it into the app. `build-engine.sh` does not run on every build.
- The Go tools live in `Contents/Helpers`, linked from `engine/bin`.
- The app's CI job runs on the `xcode-27` runner.

The brief it was written from:

Use `superpowers:writing-plans`. Save it as `docs/superpowers/plans/<date>-plan-2-app-shell.md`. It must cover:
- **The spikes come first**, because later tasks use their answers:
  - **S1:** which Liquid Glass APIs the installed SDK actually has (`glassEffect`, `GlassEffectContainer`, `glassEffectID`, `.interactive()`). This Mac has SDK 27.0, while the spec was written against 26.
  - **S2:** whether Full Disk Access and Automation grants cover Mole's child `bash` and `osascript` processes.
  - **S5, signing half:** whether a stable self-signed identity keeps TCC grants across rebuilds. This matters for M1 too. Xcode's "Sign to Run Locally" changes the signature on every build, which resets Full Disk Access after each rebuild.
- An XcodeGen `project.yml` for a universal build, macOS 26 or later, Swift 6. Add `xcodegen` to `Brewfile`; it is installed here but not listed there.
- A build phase that runs `scripts/build-engine.sh` with `ENGINE_OUT` set to `Contents/Resources/engine`, and the launch integrity check from spec §10: files present, `VERSION` matches, binaries executable, otherwise a blocking "Reinstall RoomForMac" card.
- The design system from spec §11:
  - color tokens
  - one `GlassButton` and one `GlassCard`
  - backdrops with blur, wash, drift and crossfade
  - Reduce Transparency and Reduce Motion variants
- The sidebar shell with the Smart Clean, Uninstaller and Status sections, using empty placeholder views that Plan 3 fills.
- The eight onboarding screens and the approvals table from spec §6. Cover them with a permission state machine tested against mocked checkers, plus an XCUITest smoke run.
- Settings → Permissions, plus minimal General and About screens. About carries the Mole credit and the engine version.
- CI: extend `ci.yml` with the app build and the UI smoke test.

### Step 2 — Execute Plan 2 (done)
Use `superpowers:subagent-driven-development`, one task per commit, as Plan 1 was built.

**Done** on the branch `plan2/app-shell`. What is left needs the owner, and Plan 2's "Done when" lists it: the signing identity, the S2/S5/TCC checks on a signed build, Automation Mode for local UI tests, backdrop photos and CI billing.

### Step 3 — Write and execute Plan 3: Smart Clean, Uninstaller, Status, menu-bar extra (done)

**Done:** `docs/superpowers/plans/2026-09-27-plan-3-features.md`, on the branch `plan3/features`. What is left needs the owner: "Manual checks for Plan 3" above. Its Rulings record where it departs from the brief below:
- The engine changed twice: patch 0004 is amended (a size for each leftover, and exit 0 when every requested app is blocked), and patch 0006 reports the size of each removed item. `status-go` runs with the `status-bin` stubs, so Status never talks to Finder or Bluetooth.
- The Plan 5 seam is `RemovalGate.check(RemovalRequest)`, called before the confirmation sheet and before any app is quit. `RemovalRecorder` receives each removal as it is confirmed, and `RunReporter` carries path-free scan and cleanup reports for telemetry.
- Status is paused, not polled every 10 s, while only the menu-bar extra shows.
- Notifications cover finished scans, cleanups and uninstalls.

The brief it was written from:

Base it on spec §5.1, §5.2, §5.4, §5.5 and §10, plus roadmap decisions 1–3. It builds on the `MoleEngine` services as they are:
- `CleanService`
- `UninstallService`
- `StatusService`
- `CleanRunTally` for removed bytes

M1 has no allowance gate. Keep one seam where Plan 5 inserts `AllowanceGate.check(selection)` before a clean. Running apps are quit through `NSRunningApplication` before an uninstall.

### Step 4 — M1 check
On this Mac, build and run a signed copy, then walk the success criterion from spec §2 without the 1 GB part, together with "Manual checks for Plan 3" above. M2 continues with Plan 6, then Plan 5 once the merchant of record is chosen, each written with `superpowers:writing-plans` once the one before it lands.

### Step 5 — Write and execute Plan 6: distribution (next)
Base it on spec §12, `docs/signing.md` and Plan 2's Rulings 1 and 4 (the bundle ID and the single signing identity). It builds on Plan 3's `AppDelegate` and `DestructiveRunQueue`, so start it once Plan 3 merges, on a branch taken from the merged `main`. It does not need Plan 5.

### Step 6 — Write and execute Plan 5: monetization and analytics
Start it once the merchant of record is chosen ("Only you can do these", item 2). It plugs into Plan 3's seams: `RemovalGate` and `RemovalRecorder` for the allowance and its ledger, keyed by run and sequence; `RunReporter` for telemetry; and `AppModel.takeDeepLink()` for the purchase link. The spec errata in the roadmap list the names that changed.

## Environment facts for the next session

- This Mac has macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4 and SDK 27.0. `xcodegen` is at `/opt/homebrew/bin`.
- `bats` runs on `/bin/bash` 3.2. A `[[ ]]` that is not a test's last statement needs `|| return 1`. CI checks this with `vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats`.
- Every `scripts/build-engine.sh` run deletes and re-clones `build/engine-src`, and so does `bats scripts/tests`, which builds in `setup_file`. Never run two of them at once. One build takes about 1 minute.
- The engine integration tests need `RFM_ENGINE_DIR=$PWD/build/engine`. Since Plan 3 they take several minutes: they run the clean, uninstall and status cases on a fake home.
- Leftover worktrees:
  - `.claude/worktrees/brave-hermann-b6d5e0`: its plan commit is now on `main` as `1291594`.
  - `.claude/worktrees/intelligent-hertz-25358c`: `fix/engine-kb-overflow`.
  - `~/orca/workspaces/RoomForMac/sablefish`: at `057136d`.

  Remove them once their branches have landed.

## Prompts to paste

**Session 1: land Plan 1.** Done, except the CI run.

> On `main` in RoomForMac, follow Step 0 of `docs/superpowers/plans/2026-09-26-mvp-handoff.md`: merge `fix/engine-kb-overflow`, run Plan 1 Task 13 Step 2 locally, and report the results. Ask me before pushing.

**Session 2: write Plan 2.** Done.

> Read `docs/superpowers/plans/2026-09-26-mvp-handoff.md`, the spec and the roadmap. MVP scope is M1 [or: M2 / M2 with Terrain]. Use superpowers:writing-plans to write Plan 2 exactly as Step 1 of the handoff describes, spikes first. Work on `main`. Stop when the plan is written, so I can review it.

**Session 3: execute Plan 2.** Done.

> Execute `docs/superpowers/plans/<date>-plan-2-app-shell.md` with superpowers:subagent-driven-development on `main`. Stop after each spike and tell me what it found before building on it.

**Session 4: Plan 3.** Done.

> Plan 2 has landed. Read the handoff's Step 3. Write Plan 3 with superpowers:writing-plans, then stop for my review.

**Session 5: Plan 6.**

> Plan 3 has landed. Read the handoff's Step 5, the roadmap and its spec errata. Write Plan 6 with superpowers:writing-plans, then stop for my review.
