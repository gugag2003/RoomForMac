# RoomForMac — Design Spec

- **Date:** 2026-09-25
- **Status:** Design approved in conversation; this written spec awaits review
- **Repo:** https://github.com/gugag2003/RoomForMac
- **Engine:** [tw93/mole](https://github.com/tw93/mole) (GPL-3.0), vendored and lightly patched

---

## 1. Summary

RoomForMac is a native macOS app (SwiftUI, Liquid Glass) that puts a calm, modern interface on top of Mole's open-source cleaning engine. It ships four tools — **Smart Clean**, **Uninstaller**, **Terrain** (a bubble-based disk explorer), and **Status** — plus a menu-bar extra. Scanning is free and unlimited; cleanup is free up to a one-time 1 GB allowance, after which a **lifetime license** (pay once, every future version included, up to 3 Macs, no account) unlocks unlimited cleanup.

The visual identity is "Alpine Moss": olive/oat/dry-grass colors over heavily blurred Patagonia and Yosemite landscapes, with Liquid Glass controls and gentle motion.

## 2. Goals, non-goals, success criteria

### Goals
1. Expose Mole's clean, uninstall, analyze and status capabilities through a polished native UI without rewriting Mole's cleaning logic.
2. Let anyone understand what fills their disk for free, and experience real cleanup (1 GB) before paying.
3. Sell a lifetime license without accounts, with offline use after activation and a license that survives every future major release.
4. Measure the free-to-paid funnel without collecting filenames, file paths, or app names.
5. Ship publicly as GPL-3.0 open source, without an Apple Developer account at launch.

### Non-goals (v1)
- Optimize, Purge, Installer finder, History, Touch ID-for-sudo (roadmap, §15).
- Mac App Store distribution, StoreKit, Homebrew cask.
- Localization beyond English (all strings go through a String Catalog so pt-BR and others can follow).
- Windows or older-macOS support.

### Success criteria
- A first-time user completes onboarding, grants Full Disk Access, runs a Smart Clean scan and cleans ≤ 1 GB without reading documentation.
- No destructive action happens without a preview the user confirmed. Uninstaller and Terrain removals go to the Trash; Smart Clean deletes regenerable caches/logs permanently (Mole's default, see §10); admin-level items only after explicit system password approval.
- Every analytics event passes an automated check that no property contains a path, filename, or app name.
- A license token issued by v1.0 still verifies in every later build (enforced by tests, §13).

## 3. Constraints

### 3.1 Legal
- **GPL-3.0.** RoomForMac links/bundles GPL code, so the whole app is GPL-3.0. Full source, including licensing and allowance code, is public. Anyone may legally build a copy without the allowance; we accept this and do not obfuscate or add anti-tamper measures. We must not impose additional legal restrictions (no EULA restricting redistribution); the 3-device limit is a technical property of activation, not a legal term.
- **Mole trademark** (`TRADEMARK.md`): no "Mole" name or logo in our branding or marketing; no implied endorsement; do not use the Mole name to market our paid product. Mole is credited in About, `NOTICE`, and `README` as the engine, as GPL attribution requires. Recommended: courtesy note to the Mole author before launch.
- **CleanMyMac:** workflows may be similar; no names, icons, artwork, copy, or color scheme copied.
- **Photography:** only public-domain or CC0 images (CC BY acceptable with attribution), credited in `CREDITS.md`.

### 3.2 Platform
- macOS 26 (Tahoe) or later — required for Liquid Glass APIs. Universal binary (arm64 + x86_64).
- Swift 6, SwiftUI, Swift Charts, Swift Testing. Xcode project generated from `project.yml` via XcodeGen.

### 3.3 No Apple Developer account (until after launch)
| Consequence | Mitigation |
|---|---|
| Gatekeeper blocks first launch; on macOS 15+ right-click → Open no longer bypasses it — users must use **System Settings → Privacy & Security → Open Anyway**. | Animated 3-step guide on the download page and as the DMG window background. In-app onboarding cannot help because the app has not launched yet. |
| Ad-hoc signatures change every build, which resets Full Disk Access and Automation grants (TCC keys on the designated requirement). | Sign every build with **one stable self-signed code-signing certificate** kept in CI secrets, giving a stable designated requirement. Verified in spike S5. |
| No notarization → Homebrew cask not viable. | Direct DMG download only until the account exists. |
| No StoreKit / App Store. | Payments through Polar (Merchant of Record, paid out via Stripe) with our own native paywall. |
| No privileged helper via `SMAppService.daemon`. | Admin actions use the system authorization prompt per run (§4.5, spike S3). |

## 4. Architecture

### 4.1 Repository layout
```
RoomForMac/
├─ project.yml                     XcodeGen definition
├─ RoomForMac/                     App target (SwiftUI)
│  ├─ App/                         App entry, window + MenuBarExtra scenes, AppModel, routing
│  ├─ DesignSystem/                Tokens, GlassButton, backgrounds, motion helpers
│  ├─ Features/
│  │  ├─ Onboarding/  SmartClean/  Uninstaller/  Terrain/  Status/
│  │  ├─ MenuBar/     Paywall/     Settings/     Permissions/
│  └─ Resources/                   Assets.xcassets, Backgrounds/, Localizable.xcstrings
├─ Packages/
│  ├─ MoleEngine/                  UI-free: runner, services, parsers, models
│  ├─ Licensing/                   Token verify, keyring, device ID, allowance ledger
│  └─ Telemetry/                   Typed event schema, PostHog client wrapper
├─ vendor/mole/                    git submodule, pinned to a Mole release tag
├─ patches/mole/                   git-format patches applied at build (upstreamable)
├─ scripts/                        build-engine.sh, sign.sh, make-dmg.sh, release.sh
├─ backend/supabase/               Edge functions + SQL migrations (§9)
├─ site/                           Static download / thanks / privacy / guide pages
├─ .github/workflows/              ci.yml, release.yml
├─ LICENSE  NOTICE  CREDITS.md  README.md
└─ docs/superpowers/{specs,plans}/
```

Module boundaries: the app target depends on the three packages; the packages are independent of each other and of the app. The app composes them.

### 4.2 Bundled engine
- `scripts/build-engine.sh`: checks out `vendor/mole` at the pinned tag, applies `patches/mole/*.patch` (`git am`), builds `cmd/analyze` and `cmd/status` for arm64 and amd64 with `CGO_ENABLED=0`, `lipo`s them into universal binaries, and copies `mole`, `bin/`, `lib/`, and the binaries into `RoomForMac.app/Contents/Resources/engine/`.
- The app records the engine's pinned tag + patch set hash in `engine/VERSION` and verifies it at launch (§10).
- The app never uses a system-installed `mo`.

### 4.3 Mole patches (each a standalone, upstreamable patch)
| # | Patch | Purpose |
|---|---|---|
| P1 | `clean --json` | Dry-run emits NDJSON `item` records (`section`, `path`, `size_bytes`, `needs_admin`, `note`); a real run emits `progress` and per-item `result` records (`path`, `status: removed\|skipped\|failed`, `bytes`, `reason`), then a `summary`. |
| P2 | `clean --only-list <file>` | Cleans only listed paths. Each path must also appear in a fresh internal scan; anything else is ignored and reported as `skipped`. Mole's safety checks still apply to every path. |
| P3 | `uninstall --yes --json --app-path <path>` | Non-interactive uninstall targeting an exact bundle path (no name matching, no `[y/N]` prompt). With `--dry-run` it emits the app plus every leftover it would remove with sizes. Real runs emit per-item `result` records. |
| P4 | `MOLE_GUI_HOST=roomformac` | (a) Skips Mole's own `osascript` app-quit (RoomForMac quits apps itself via `NSRunningApplication`, avoiding one Automation prompt per app). (b) Replaces Mole's custom "Mole" password dialog with the host's privileged-execution path (spike S3). |
| P5 | `analyze --trash-list <file> --json` | Moves listed paths to the Trash using `cmd/analyze/delete.go`'s existing safety rules, emitting per-item results. Keeps Mole as the single safety authority for Terrain deletions. |

Existing JSON surfaces used as-is: `status --json`, `analyze --json <path>`, `uninstall --list` (JSON when piped). Patch CI runs Mole's own test suite on the patched tree.

### 4.4 MoleEngine package
- **`MoleRunner`** — launches engine commands with `Process`; environment: `NO_COLOR=1`, `TERM=dumb`, `HOME`, `MOLE_GUI_HOST=roomformac`, engine-local `PATH`. Streams stdout as NDJSON lines via `AsyncThrowingStream`; captures stderr to a rotating log. Runs each command in its own process group; cancellation sends SIGTERM to the group, then SIGKILL after 5 s. Per-command timeouts. Maps exit codes to typed `EngineError`.
- **Services** (actors, each with a protocol for test doubles):
  - `StatusService` — `status --json` every 2 s while any status UI is visible, 10 s when only the menu bar is open, paused otherwise.
  - `CleanService` — `scan() -> AsyncStream<CleanEvent>` (P1 dry-run), `clean(selection) -> AsyncStream<CleanEvent>` (P1 + P2).
  - `UninstallService` — `listApps()`, `preview(app)` (P3 dry-run), `uninstall(apps)` (P3).
  - `AnalyzerService` — `scan(path)` (one level), `trash(paths)` (P5); in-memory cache keyed by path + directory mtime.
- **Models:** `CleanItem`, `CleanSection`, `InstalledApp`, `AppLeftover`, `DiskEntry`, `DiskLevel`, `SystemSnapshot`, `ItemResult`, all `Sendable` and `Codable`.

### 4.5 Privilege model
- Default runs are user-level: no password.
- Items Mole marks `needs_admin` are unselected by default and visually tagged ("Needs your password").
- If the user selects any, RoomForMac runs the admin subset as a separate engine invocation through the standard macOS authorization prompt (once per run). The exact mechanism (e.g. `do shell script … with administrator privileges` wrapping the engine, or an askpass hook) is chosen in spike S3; the requirement is a system-drawn prompt, never a custom password field.

### 4.6 Data flow (Smart Clean example)
```
Scan button → CleanService.scan() → engine: clean --dry-run --json
   → NDJSON item events → CleanScanModel (grouped by section, live totals)
User selects → AllowanceGate.check(selection) → ok | exceedsRemaining | exhausted
Clean → CleanService.clean(selection) → engine: clean --json --only-list <tmp>
   → per-item result events → AllowanceLedger.record(removed bytes only)
   → Telemetry: cleanup_succeeded (bucketed) → Summary screen
```

## 5. Features

### 5.1 Smart Clean
- Hero state: large glass **Scan** button over the Yosemite Valley backdrop.
- Scanning: the button morphs (`glassEffectID`) into a progress ring; section rows stream in with live size counters.
- Results: sections (Mole's categories) with checkboxes, expandable to items; sizes in Grass; admin items tagged; totals update live.
- Primary action shows **"Clean 4.2 GB"**, or the allowance state (§7.2).
- Cleaning: per-section progress; failures listed inline without blocking others.
- Summary: freed total, items removed, items skipped/failed with plain-language reasons.
- Smart Clean runs with Mole's default `MOLE_DELETE_MODE=permanent`: its items are regenerable caches, logs and leftovers, and space is reclaimed immediately. The confirmation copy says so explicitly ("These files are removed permanently; apps recreate caches as needed").

### 5.2 Uninstaller
- Searchable, sortable (size, name, last used) list/grid with real icons (`NSWorkspace.icon(forFile:)`) and sizes; Homebrew-managed apps labeled.
- Selecting apps opens a glass drawer with the dry-run preview: app bundle + every leftover (preferences, caches, launch agents, containers) with sizes and checkboxes.
- Running apps are quit by RoomForMac first (`NSRunningApplication.terminate()`, then prompt the user before `forceTerminate()`).
- Confirm → **Move to Trash** (Mole's uninstall default `MOLE_DELETE_MODE=trash`) → per-item progress → summary with an "Empty Trash to reclaim the space" hint.
- Backdrop: Fitz Roy.

### 5.3 Terrain (disk explorer with dynamic bubbles)
Terrain is RoomForMac's space explorer. Layout, modeled on the approved reference but in our own visual language:

- **Left glass panel**
  - Disk card: volume name, "381 GB used of 494 GB", segmented usage bar (Action / Moss / Grass).
  - Current-folder card: icon, total size, item count.
  - **Select** menu: Manually · Largest items · Not opened in a year (uses `last_access`).
  - Entry list: checkbox, icon or thumbnail, name, size; the long tail collapses into an **Other items** row that expands.
- **Right canvas**
  - Toolbar: glass back/forward buttons and a clickable breadcrumb (Macintosh HD › Users › you › Documents).
  - **Bubble field**: the top 24 entries by size as circles whose **area is proportional to size**; everything else aggregates into one "Other items" bubble.
  - Packing: front-chain circle packing (the algorithm behind d3's `packSiblings`), scaled to the canvas, followed by a short spring relaxation so bubbles settle rather than snap.
  - Each bubble: Liquid Glass circle tinted by kind — folders Moss, archives/disk images Grass, media Action, other neutral — with icon or Quick Look thumbnail (`QLThumbnailGenerator`), middle-truncated name, and size.
- **Dynamic behavior**
  - Idle: each bubble drifts a few points on its own slow sine path (`TimelineView`).
  - Hover: bubble scales to 1.06, brightens and lifts; neighbors are nudged away with springs; tooltip shows full name, size, last opened.
  - Click folder: the bubble expands to fill the canvas while siblings fade and shrink; children spring in with a 30 ms stagger. Back reverses the motion.
  - Selection: selected bubbles get an Action-colored ring and a check badge; list and bubbles stay in sync both ways.
  - Loading: placeholder "breathing" bubbles while a level scans; the three largest child folders are prefetched after a level renders so drill-in feels instant.
  - `cleanable` entries (from Mole) show a small leaf badge linking to Smart Clean.
- **Bottom bar:** "Selected 46 items · 59.7 GB" and a glass **Review and remove** button → sheet listing the selection, with Quick Look (space bar), Reveal in Finder, and **Move to Trash** (engine P5).
- Terrain removals **do not** use the free allowance (Finder-equivalent action).
- Refuses to trash items Mole's analyze safety rules protect; app bundles are redirected to the Uninstaller.
- Backdrop: Half Dome.

### 5.4 Status
- Cards for CPU, GPU, memory, disk, network, battery with Swift Charts sparklines (last 60 samples) and large rounded numerals.
- Health summary line from Mole's diagnosis data.
- Backdrop: Torres del Paine.

### 5.5 Menu-bar extra
- `MenuBarExtra` (window style): compact CPU / memory / disk gauges, free-space figure, **Quick Scan** (opens the window and starts Smart Clean), **Open RoomForMac**.
- Optional launch at login (§6).

### 5.6 Settings
- General (launch at login, menu-bar extra on/off, notifications), Permissions (same cards as onboarding, live status), License (status, activate key, deactivate this Mac, "Lost your key?"), Privacy (analytics toggle, what we collect), About (version, engine version, Mole credit, licenses, photo credits).

## 6. Onboarding and permissions

Every system approval the app can trigger is covered by an onboarding step, re-checkable in **Settings → Permissions**, and re-offered just-in-time as an inline card before an action that needs it.

| # | Approval | Where it's handled | Detection |
|---|---|---|---|
| 0 | Gatekeeper "Open Anyway" | Download page + DMG background (animated guide) | n/a (pre-launch) |
| 1 | Move to /Applications | Onboarding step (conditional) | Bundle path outside `/Applications` or under `AppTranslocation` |
| 2 | Full Disk Access | Onboarding step | Readability of a TCC-protected file (e.g. user `TCC.db`) |
| 3 | Automation → Finder (Trash moves) | Onboarding step | `AEDeterminePermissionToAutomateTarget` |
| 4 | Automation → System Events (running-app list) | Onboarding step | `AEDeterminePermissionToAutomateTarget` |
| 5 | Administrator password | Explainer only; prompted per run when admin items are chosen | n/a |
| 6 | Notifications (optional) | Extras step | `UNUserNotificationCenter` settings |
| 7 | Launch at login (optional) | Extras step | `SMAppService.mainApp.status` (deep link if `requiresApproval`) |
| 8 | Anonymous analytics (on by default) | Extras step, clear toggle | Local preference |

Per-app Automation prompts during uninstall are eliminated by P4 (RoomForMac quits apps itself).

### Screens (all animated, all with Back / Skip, all with a Reduce Motion variant)
1. **Welcome** — the Patagonia backdrop resolves from blur into focus, then softens behind glass as the RoomForMac wordmark draws in stroke by stroke. CTA: "Get started".
2. **Free to explore** — "Unlimited scans and previews" + a 1 GB meter that fills to show "1 GB of free cleanup, once". Lifetime promise line: "Upgrade once for unlimited cleanup — every future version included." No account, no card.
3. **Move to Applications** *(only if needed)* — animated app icon gliding into an Applications folder; one click moves and relaunches.
4. **Full Disk Access** — looping mini-animation of the System Settings switch turning on; "Open Settings" deep-links to Privacy → Full Disk Access; the app polls every second and morphs the card to a checkmark on grant; offers "Relaunch" if the grant needs it. "Why?" disclosure explains what breaks without it.
5. **Finder & System Events** — two cards; each "Allow" triggers the system prompt at that moment; state chips (Allowed / Not yet / Denied → "Open Settings").
6. **Admin access** — illustration of the native password sheet; copy explains it is only requested when the user picks system-level items. Nothing requested here.
7. **Extras** — toggles for notifications, menu-bar extra at login, anonymous analytics (on; one-line description + "What we collect").
8. **Ready** — permission summary chips (granted ✓ / skipped •), and a **Start first scan** glass button that morphs directly into the Smart Clean scan.

Progress indicator: glass dots in a `GlassEffectContainer` that morph between steps.

## 7. Monetization

### 7.1 Offer
- **Free:** unlimited scans and previews in every tool; **1 GB of cleanup, total, ever** (Smart Clean + Uninstaller); Terrain trash moves are free.
- **Lifetime license:** unlimited cleanup; **every future version and update included**; up to **3 Macs**; purchase by email, no account.
- **Price:** open decision owned by the product owner (§16); stored in one config value used by the paywall and site.

### 7.2 Free allowance rules
- 1 GB = **1,000,000,000 bytes** (decimal, matching Finder).
- **Cumulative and non-renewing.** Never resets per scan, day, or version.
- Only **bytes actually removed** count — taken from per-item `result: removed` events. Skipped and failed items consume nothing. A run that fails entirely consumes nothing.
- **Items are atomic.** No item is ever partially deleted to fit the limit.
- **Pre-run gate:** if the selected total (fresh sizes from the latest dry-run) exceeds the remaining allowance, the Clean button reads "Selection exceeds your free 380 MB" and offers:
  - **Fit to my remaining space** — reselects whole items (largest-first greedy) that fit;
  - **Unlock unlimited** — opens the paywall.
- If an item grows between scan and removal so that usage passes 1 GB, the item still completes and usage is capped at 1 GB (user-favorable; nothing is interrupted mid-run).
- **Storage:** `~/Library/Application Support/RoomForMac/state.json` (`used_bytes` + ledger of `{timestamp, feature, bytes}` — no paths) mirrored in `UserDefaults`; the higher value wins on mismatch. Not tamper-proof by design (§3.1).
- Always visible: sidebar meter "620 MB of 1 GB free cleanup left" (hidden once licensed).

### 7.3 Paywall
- Native SwiftUI sheet over the current backdrop.
- Triggers: selection exceeds remaining allowance; allowance exhausted; sidebar "Upgrade"; Settings → License.
- Content: headline, benefits (unlimited cleanup · every future version and update included · up to 3 Macs · no account), price, **Buy lifetime license**, **I have a key**, **Lost your key?**.
- Buy → backend `checkout` function creates a Polar checkout session carrying the anonymous `install_id` in metadata → opens in the default browser.
- Success → thanks page on the site deep-links `roomformac://purchased?checkout_id=…`; the app calls `claim` to receive and activate its key (no license key in any URL). The key is also emailed by Polar.

### 7.4 Licensing
- **Merchant of Record:** Polar (tax/VAT handled by Polar; payouts via Stripe). License-key benefit configured with an activation limit of 3.
- **Activation:** app → `activate(key, device_hash, device_label)` → backend calls Polar's activate endpoint (Polar enforces the limit) → backend returns a **RoomForMac activation token**, signed with our Ed25519 key.
- **Token:** `RFM1.<base64url(payload)>.<base64url(signature)>`; payload `{v, kid, lic, act, dev, plan: "lifetime", iat}`. No expiry, no version ceiling.
- **Offline:** the app verifies the token locally against a bundled **keyring** of public keys. Activation needs the internet once; nothing afterwards does.
- **Device identity:** `SHA-256(IOPlatformUUID + "roomformac-device-v1")`. Reinstalling on the same Mac reproduces the same hash, so it reuses its activation.
- **Deactivate this Mac** frees a slot (online). **Lost your key?** opens Polar's email-based customer portal.
- **Refund/chargeback handling:** when online, a background `refresh` at most every 30 days; only an explicit `revoked` response removes the license. Network errors, timeouts, or an unreachable backend never affect a licensed user.

### 7.5 Lifetime promise — engineering guarantees
1. Token payloads are versioned; every build parses every token version ever issued.
2. The bundled keyring is append-only; no public key is ever removed from a release.
3. Key rotation: ship the new public key in a release first; switch the server to sign with it only after that release is out.
4. `LegacyTokenTests` holds real tokens from every past release (fixtures committed on each release) and must pass in CI forever.
5. The device-hash salt string is frozen.
6. Tokens do not reference Polar-specific formats, so a change of payment vendor never invalidates existing customers.

## 8. Analytics

- **Tool:** PostHog (EU or US cloud; free tier), via its Apple SDK behind our `Telemetry` package. IP capture off, autocapture off, session replay off, no person profiles beyond the random `install_id`.
- **Consent:** on by default; toggle in onboarding (Extras) and Settings → Privacy; turning it off stops sending immediately and deletes the local queue. Disclosed in the site privacy page.
- **Typed schema** — events and properties are Swift enums; property values are enums, bools, or bucketed numbers. There is no free-form string property, so paths cannot be sent.

| Event | Properties |
|---|---|
| `onboarding_completed` | `fda_granted`, `finder_automation`, `system_events_automation`, `notifications`, `login_item` (bools) |
| `scan_completed` | `feature` (clean/uninstall/terrain), `found_bytes_bucket`, `item_count_bucket`, `duration_bucket` |
| `cleanup_succeeded` | `feature`, `freed_bytes_bucket`, `item_count_bucket`, `licensed`, `allowance_remaining_bucket` |
| `cleanup_failed` | `feature`, `error_kind` |
| `allowance_reached` | `trigger` (exhausted / selection_exceeds) |
| `paywall_viewed` | `trigger` |
| `checkout_started` | — |
| `purchase_completed` | server-side from Polar webhook, keyed to `install_id` from checkout metadata; `amount_bucket`, `currency` |
| `license_activated` | `source` (deeplink / manual_key) |
| `license_activation_failed` | `reason` (limit_reached / invalid / network) |

- Global properties: `app_version`, `os_major`, `arch`, `licensed`.
- Buckets: bytes `<100MB, 100MB–1GB, 1–5GB, 5–20GB, 20GB+`; counts `0, 1–10, 11–100, 101–1000, 1000+`; durations `<10s, 10–60s, 1–5m, 5m+`.
- Funnel in PostHog: `scan_completed → allowance_reached → paywall_viewed → checkout_started → purchase_completed → license_activated`. Revenue totals also visible in Polar's dashboard.

## 9. Backend (Supabase)

- **Edge functions:** `checkout`, `claim`, `activate`, `deactivate`, `refresh`, `polar-webhook`.
- **Tables:**
  - `activations(id, polar_license_key_id, polar_activation_id, device_hash, kid, issued_at, revoked_at)`
  - `purchases(polar_order_id, polar_license_key_id, install_id, amount, currency, created_at, refunded_at)`
  - No email addresses stored (Polar holds customer identity).
- **Secrets:** Ed25519 private key(s) by `kid`, Polar access token + webhook secret, PostHog project key.
- `polar-webhook` verifies signatures, records purchases/refunds, marks activations revoked on refund, and forwards `purchase_completed` to PostHog.
- Rate limits on `activate`, `claim`, and `refresh` per IP/device hash.
- Outage impact: only new purchases/activations; existing licensed users are unaffected (offline tokens).

## 10. Errors and safety

- Preview before every removal; confirmation shows exactly what will be removed and the total.
- Delete modes follow Mole's defaults: Smart Clean permanent (regenerable items, stated in the confirmation), Uninstaller and Terrain to the Trash. Admin items only after the system password prompt.
- For the free allowance, bytes count when an item leaves its original location (deleted or moved to Trash).
- Engine failures surface as plain-language cards ("Some items were in use and were skipped") with **Show details** (log excerpt) and **Copy diagnostics**.
- Launch integrity check: engine files present, `VERSION` matches the build, binaries executable; otherwise a blocking "Reinstall RoomForMac" card.
- Missing permission at action time → inline permission card, not a silent failure.
- Cancel stops the engine's whole process group; partially completed runs still produce an accurate summary and allowance accounting.
- Crash-safe allowance: ledger entries are written as result events arrive, not at the end.

## 11. Design system

### 11.1 Color tokens
| Token | Light | Dark (initial; tuned in design pass) | Use |
|---|---|---|---|
| `canvas` | `#F1F0E5` | `#1C2119` | Window base, backdrop wash |
| `surface` | `#FCFBF2` | `#262D22` | Cards, Reduce Transparency fallback |
| `text` | `#333B2D` | `#F1F0E5` | Primary text |
| `textSecondary` | `text` @ 65% | `text` @ 65% | Secondary text |
| `action` | `#586440` | `#ADB591` | Primary buttons, selection, focus |
| `onAction` | `#FCFBF2` | `#1C2119` | Text/icons on action |
| `moss` | `#ADB591` | `#7E8866` | Progress, charts, folder bubbles, sidebar selection |
| `grass` | `#B3915D` | `#C9A877` | Sizes, highlights, cautions, archive bubbles |
| `clay` | `#A8563F` | `#C97A5F` | Destructive confirmations only (added; palette has no red) |

`action` on `canvas` ≈ 5.6:1 and `onAction` on `action` ≈ 6.4:1 (WCAG AA).

### 11.2 Typography
SF Pro for UI; SF Pro Rounded with `monospacedDigit()` for sizes, counters and gauges; large-number hero style at 44–56 pt.

### 11.3 Backdrops
| Surface | Scene |
|---|---|
| Onboarding | Fitz Roy / Laguna de los Tres at sunrise (Patagonia) |
| Smart Clean | Yosemite Valley (Tunnel View) |
| Uninstaller | Cerro Torre / Fitz Roy massif (Patagonia) |
| Terrain | Half Dome (Yosemite) |
| Status | Torres del Paine (Patagonia) |

- Stored as ~2560 px HEIC; blurred at runtime (radius ≈ 40) so onboarding can animate focus; washed with `canvas` at ~40% for legibility.
- Slow Ken Burns drift (60 s loop, ≤ 8% scale); 0.8 s crossfade between sections.

### 11.4 Liquid Glass and motion
- Sidebar, toolbars, cards and buttons use `.glassEffect()`; primary buttons use `.regular.tint(action).interactive()`; related controls share a `GlassEffectContainer` so they merge and morph (`glassEffectID`).
- Hover: spring (response 0.3, damping 0.7) to scale 1.02, brighter tint, softer/larger shadow. Press: system interactive glass response.
- Signature morphs: Scan button → progress ring → results header; onboarding dots; Terrain drill-in.
- One reusable `GlassButton` and `GlassCard` carry all of this so later design rounds change one place.

### 11.5 Accessibility
- **Reduce Transparency** → solid `surface` cards, no backdrop blur.
- **Reduce Motion** → no drift, no bubble idle motion, crossfades instead of morphs.
- Full VoiceOver labels (bubbles announce name, size, selection state); keyboard navigation for lists and bubbles; Dynamic Type-friendly layouts.

## 12. Distribution and updates

- **Signing:** stable self-signed certificate (private key in GitHub Actions secrets) + hardened runtime off (not required without notarization).
- **DMG:** custom background with the Open Anyway guide; drag-to-Applications.
- **Updates:** Sparkle 2 with EdDSA-signed appcast hosted on GitHub Releases/Pages; in v1 because the lifetime promise includes updates. Verified in spike S5.
- **CI (`ci.yml`):** engine build + patch apply + Mole tests, Swift package tests, app build, legacy-token tests, telemetry schema check.
- **Release (`release.yml`):** tag → build universal app → sign → DMG → Sparkle appcast → GitHub Release; appends that release's token fixture.
- **Site (`site/`):** download page, Open Anyway guide, thanks/deep-link page, privacy page. Hosted on GitHub Pages until a domain is chosen.

## 13. Testing

- **Parsers:** fixtures recorded from real engine output (P1/P3/P5 NDJSON, `status --json`, `analyze --json`, `uninstall --list`).
- **MoleRunner:** stub scripts for streaming, stderr, timeouts, cancellation of process groups, exit-code mapping.
- **Allowance:** cumulative across launches; failures/skips don't count; atomic items; pre-run gate; fit-to-remaining greedy; cap at 1 GB; ledger survives crash mid-run.
- **Licensing:** token verification (good, tampered, wrong device, unknown kid), keyring append-only check, `LegacyTokenTests`, refresh behavior (network error never revokes).
- **Telemetry:** schema test asserting no event property can hold a string outside its enum; runtime guard dropping any value containing `/` or the home directory.
- **Terrain packing:** no overlaps, areas proportional to sizes within tolerance, deterministic layout for identical input, "Other items" aggregation.
- **Onboarding:** permission state machine with mocked checkers; XCUITest smoke run through all steps.
- **Backend:** Deno tests for each edge function with mocked Polar API and webhook signature verification.
- **Engine patches:** Mole's own test suite on the patched tree in CI.

## 14. Spikes (first plan tasks) and risks

| ID | Question | Why it matters |
|---|---|---|
| S1 | Exact Liquid Glass API surface in the installed macOS 26 SDK (`glassEffect`, `GlassEffectContainer`, `glassEffectID`, `.interactive()`) | Design system foundation |
| S2 | Do FDA and Automation grants on RoomForMac cover Mole's child `bash`/`osascript` processes? | Onboarding correctness |
| S3 | Native authorization prompt mechanism for Mole's admin operations | Privilege model, P4 |
| S4 | Polar: license-key activation limits and API, checkout metadata, success URL, webhooks, current fees | Monetization |
| S5 | Stable self-signed cert keeps TCC grants across builds; Sparkle updates an un-notarized app cleanly | Updates + lifetime promise |

**Risks:** Gatekeeper friction lowers conversion until notarization; GPL permits free rebuilds without the allowance; upstream Mole changes can break patches (pinned tag + CI); photo licensing must be verified per image.

## 15. Roadmap (post-v1)
Optimize, Purge (dev artifacts), Installer finder, History (`mo history --json`), Apple Developer ID + notarization + Homebrew cask, privileged helper, localization (pt-BR first), richer design rounds.

## 16. Open decisions
| Decision | Owner | Default until decided |
|---|---|---|
| Lifetime license price | Product owner | Placeholder config value; debug builds show "—"; the release workflow fails if the price is unset |
| Website domain | Product owner | GitHub Pages under the repo |
