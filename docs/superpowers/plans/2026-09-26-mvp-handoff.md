# RoomForMac — MVP Handoff (2026-09-26)

What is left between today's `main` and an MVP, in the order to do it, with a prompt to paste into each next session.

**Read first:** spec `docs/superpowers/specs/2026-09-25-roomformac-design.md`, roadmap `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md`, Plan 1 `docs/superpowers/plans/2026-09-25-plan-1-engine.md` (its Global Constraints and Environment notes apply to every later plan).

## Where things stand

- **Plan 1 (engine) is built on local `main`.** It includes five Mole patches, `scripts/build-engine.sh`, and the `MoleEngine` Swift package. Verified on 2026-09-26: `bats scripts/tests` 6/6, `swift test --package-path Packages/MoleEngine` with `RFM_ENGINE_DIR=$PWD/build/engine` 55/55 (50 unit + 5 integration), and the bats assertion audit is clean.
- **There is no app yet.** There is no `project.yml` and no `RoomForMac/` target. Plans 2–7 are not written.
- **CI has never run.** Every Actions run ended in `startup_failure` with no jobs. The run page's annotation says: "The job was not started because recent account payments have failed or your spending limit needs to be increased." The repository is private, and private repositories are billed for macOS runner minutes. The workflow file itself is fine.
- **Git state:**
  - `main` is 3 commits ahead of `origin/main` and has not been pushed.
  - GitHub's default branch is `main-mrvlfl`, which sits at `057136d` (spec and roadmap only, 14 commits behind `main`).
  - PR #1 (`main` → `main-mrvlfl`) holds all of Plan 1.
  - PR #2 (`fix/engine-kb-overflow` → `main-mrvlfl`) adds two overflow fixes, `f30b1f6` and `ba08729`. Engine sizes that are too large no longer trap the app. A test merge (`git merge-tree`) into `main` is clean. The branch is not merged.

## MVP scope — recommended, confirm before writing Plan 2

| Milestone | Plans | Done when |
|---|---|---|
| **M1: runs on your Mac** | 2, 3 | Built from source, the app on your Mac takes you through onboarding and the Full Disk Access grant. It scans and cleans with Smart Clean, uninstalls an app to the Trash, and shows Status and the menu-bar extra. The engine is bundled, and there is no allowance or paywall. |
| **M2: someone else can download, try and pay** | + 5, 6 | Adds the 1 GB allowance, paywall, Polar licensing, telemetry, and a signed DMG with Sparkle updates. This meets every success criterion in spec §2. |
| After the MVP | 4, 7 | Terrain (bubble explorer) and admin-level cleanup. |

Terrain is one of the four headline tools in spec §1. If it must ship in the MVP, move Plan 4 into M2. It depends only on Plans 1 and 2.

## Only you can do these

1. **Unblock CI.** Fix the account's Actions payment or spending limit, or make the repository public. The spec already plans a public GPL-3.0 repository, and public repositories get standard macOS runners free.
2. **Approve pushing `main`**, then merge PR #1 once CI is green, so that `main-mrvlfl` (the default branch) holds Plan 1. Until then, a session or worktree based on `main-mrvlfl` starts **without the engine**, so start the next sessions on `main`.
3. **Confirm the four "Decisions made while planning"** in the roadmap. Plan 3's Uninstaller and Smart Clean screens build on decisions 1–3.
4. **Backdrop photos (spec §11.3).** Pick five public-domain or CC0 images, or accept flat `canvas` placeholders for M1.
5. **M2 only:** the license price, a Polar account with a license-key benefit (activation limit 3), a Supabase project, a PostHog project, a self-signed code-signing certificate for CI, Sparkle EdDSA keys, and the site domain.

## Work remaining, in order

### Step 0 — Land Plan 1
1. Merge `fix/engine-kb-overflow` into `main`.
2. Run Plan 1 Task 13 Step 2, the full local sequence. Mole's suite has three known upstream failures; see Plan 1 Environment notes.
3. After you approve, push `main`.
4. Once CI is green, tick Task 13 Step 4.

### Step 1 — Write Plan 2: app shell, design system, onboarding and permissions
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

### Step 2 — Execute Plan 2
Use `superpowers:subagent-driven-development`, one task per commit, as Plan 1 was built.

### Step 3 — Write and execute Plan 3: Smart Clean, Uninstaller, Status, menu-bar extra
Base it on spec §5.1, §5.2, §5.4, §5.5 and §10, plus roadmap decisions 1–3. It builds on the `MoleEngine` services as they are:
- `CleanService`
- `UninstallService`
- `StatusService`
- `CleanRunTally` for removed bytes

M1 has no allowance gate. Keep one seam where Plan 5 inserts `AllowanceGate.check(selection)` before a clean. Running apps are quit through `NSRunningApplication` before an uninstall.

### Step 4 — M1 check
On this Mac, build and run the app, then walk the success criterion from spec §2 without the 1 GB part. If you pick M2, Plans 5 and 6 follow, each written with `superpowers:writing-plans` once the one before it lands.

## Environment facts for the next session

- This Mac has macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4 and SDK 27.0. `xcodegen` is at `/opt/homebrew/bin`.
- `bats` runs on `/bin/bash` 3.2. A `[[ ]]` that is not a test's last statement needs `|| return 1`. CI checks this with `vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats`.
- Every `scripts/build-engine.sh` run deletes and re-clones `build/engine-src`, and so does `bats scripts/tests`, which builds in `setup_file`. Never run two of them at once. One build takes about 1 minute.
- The engine integration tests need `RFM_ENGINE_DIR=$PWD/build/engine` and take about 80 s.
- Leftover worktrees:
  - `.claude/worktrees/brave-hermann-b6d5e0`: its plan commit is now on `main` as `1291594`.
  - `.claude/worktrees/intelligent-hertz-25358c`: `fix/engine-kb-overflow`.
  - `~/orca/workspaces/RoomForMac/sablefish`: at `057136d`.

  Remove them once their branches have landed.

## Prompts to paste

**Session 1: land Plan 1.** Do this after you have fixed CI billing, or while you fix it.

> On `main` in RoomForMac, follow Step 0 of `docs/superpowers/plans/2026-09-26-mvp-handoff.md`: merge `fix/engine-kb-overflow`, run Plan 1 Task 13 Step 2 locally, and report the results. Ask me before pushing.

**Session 2: write Plan 2.**

> Read `docs/superpowers/plans/2026-09-26-mvp-handoff.md`, the spec and the roadmap. MVP scope is M1 [or: M2 / M2 with Terrain]. Use superpowers:writing-plans to write Plan 2 exactly as Step 1 of the handoff describes, spikes first. Work on `main`. Stop when the plan is written, so I can review it.

**Session 3: execute Plan 2.**

> Execute `docs/superpowers/plans/<date>-plan-2-app-shell.md` with superpowers:subagent-driven-development on `main`. Stop after each spike and tell me what it found before building on it.

**Session 4: Plan 3.**

> Plan 2 has landed. Read the handoff's Step 3. Write Plan 3 with superpowers:writing-plans, then stop for my review.
