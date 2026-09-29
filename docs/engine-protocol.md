# RoomForMac engine protocol (v1)

RoomForMac drives its bundled, patched Mole engine (`build/engine`, shipped as
`RoomForMac.app/Contents/Resources/engine`, with its two Go tools in `Contents/Helpers`
behind `engine/bin` symlinks) through environment variables and reads machine-readable results.
This is the contract between `patches/mole/` and `Packages/MoleEngine`.

## Patches and host-side rules

The engine is Mole `V1.56.0` with six patches, which `scripts/build-engine.sh` applies in
order. `VERSION` records the Mole tag and commit, a hash of the patch files and their count
(`patch_count=6`), and the app checks them at launch.

| Patch (`patches/mole/`) | Adds | Section |
|---|---|---|
| `0001-Add-host-integration-helpers-for-GUI-front-ends.patch` | `lib/core/host.sh`, `MOLE_GUI_HOST`, `MOLE_NO_AUTH` | Host variables |
| `0002-Stream-machine-readable-clean-events-for-GUI-hosts.patch` | clean events in `MOLE_JSON_EVENTS_FILE` | Clean events |
| `0003-Honour-exact-path-host-selections-in-clean.patch` | `MOLE_SELECTION_FILE` | Selections |
| `0004-Add-a-host-driven-uninstall-mode.patch` | the host-driven uninstall, amended in Plan 3 with `leftover_items` and an exit 0 when every requested app is blocked | Uninstall |
| `0005-Add-analyze-trash-list-for-GUI-front-ends.patch` | `analyze-go --trash-list` | Analyzer Trash list |
| `0006-Report-removed-sizes-in-clean-result-events.patch` | `size_kb` on `removed` clean results | Clean results |

Three parts need no patch: the `status-bin/` stubs that `scripts/build-engine.sh` writes
(Status helpers), the upstream variable `MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS` (Uninstall),
and the host's stop, suspend, diagnostics and log (the last section).

## Invoking the engine

| Purpose | Executable | Output |
|---|---|---|
| Smart Clean preview | `bin/clean.sh --dry-run` | events file |
| Smart Clean fresh sizes | `bin/clean.sh --dry-run` with `MOLE_SELECTION_FILE` | events file |
| Smart Clean run | `bin/clean.sh` with `MOLE_SELECTION_FILE` | events file |
| App inventory | `bin/uninstall.sh --list` with `MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS=100000` | JSON array on stdout |
| Uninstall preview / run | `bin/uninstall.sh [--dry-run]` with `MOLE_UNINSTALL_APP_PATHS_FILE` | events file |
| Disk level | `bin/analyze-go --json [PATH]` | one JSON document on stdout |
| Move to Trash | `bin/analyze-go --trash-list FILE` | events on stdout |
| Live status | `bin/status-go --watch --interval 2s` | one JSON snapshot per line on stdout |

Every command runs with `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG=en_US.UTF-8`, `NO_COLOR=1`,
`TERM=dumb`, stdin `/dev/null`, its own process group, and `PATH` = test prefixes, then
`host-bin/` (while admin access is off), then Homebrew and system directories. `bin/status-go`
alone runs with `status-bin/` in front of that `PATH` (see Status helpers).

## Host variables

| Variable | Effect |
|---|---|
| `MOLE_GUI_HOST=roomformac` | A GUI drives the run; `force_kill_app` skips its AppleScript Quit (the host quits apps itself). |
| `MOLE_NO_AUTH=1` | Every sudo entry point refuses without prompting (`mole_auth_disabled`). Always paired with `host-bin/sudo`. |
| `MOLE_JSON_EVENTS_FILE=PATH` | Append events (below) to PATH, one JSON object per line. |
| `MOLE_SELECTION_FILE=PATH` | NUL-separated absolute paths. Deletion sinks refuse any other path; tool-driven cleanups are skipped. |

The host creates every file it passes with mode `0600` inside a fresh `0700` directory.

### Host helpers (patch 0001)

Patch 0001 adds `lib/core/host.sh` (sourced by `lib/core/common.sh`) and the two switches
above. It only provides the building blocks: engine commands start writing events with
patch 0002, and deletion sinks start enforcing the selection with patch 0003. With none of
the host variables set, the engine behaves exactly like Mole `V1.56.0`.

| Helper | Behaviour |
|---|---|
| `mole_json_escape STR`, `mole_json_str STR` | JSON string body, or the quoted literal. Escapes `\`, `"`, `\n`, `\r`, `\t` and every other byte `0x01`–`0x1f` as `\u00xx`, in any locale; all other bytes (UTF-8 included) pass through unchanged. |
| `mole_json_num N` | `N` as a JSON integer without leading zeros; anything but a plain non-negative integer becomes `0`. |
| `mole_json_bool B` | `true` for the string `true`, otherwise `false`. |
| `mole_json_emit LINE` | Appends `LINE` and a newline to `MOLE_JSON_EVENTS_FILE`; does nothing when the variable is unset. A failed write never fails the run. |
| `mole_selection_allows PATH` | Always succeeds without `MOLE_SELECTION_FILE`. With it, succeeds only when `PATH`, ignoring trailing slashes, equals one listed path; parents and children of a listed path are refused. |
| `mole_auth_disabled` | True with `MOLE_NO_AUTH=1` (or Mole's own test switches). `request_sudo_access`, `request_sudo_access_with_password`, `has_sudo_session`, `adopt_sudo_session`, `ensure_sudo_session` and `ensure_sudo_session_with_password` then fail without running `sudo`. |
| `force_kill_app` | With `MOLE_GUI_HOST` set to any non-empty value, skips the AppleScript Quit; the SIGTERM and SIGKILL ladder that follows is unchanged (its `sudo -n` retry fails at `host-bin/sudo`). |

Selection file format: each absolute path followed by a NUL byte. Paths may contain any
other byte (spaces, quotes, backslashes, newlines, UTF-8). Empty entries and a final path
without its NUL are ignored. The engine reads the file once, on its first lookup, so the
host writes it completely before starting the engine. A missing, unreadable, non-regular
or symlinked selection file allows nothing.

## JSON conventions

- One object per line, UTF-8, first key `"v":1`. Hosts skip lines they cannot parse, types they do not know and other `v` values, and ignore keys they do not know. Patch 0006 and the amended 0004 only add keys, so `v` stays 1.
- Strings escape `"`, `\`, `\n`, `\r`, `\t`, and other control bytes as `\u00XX`.
- Sizes are integer kilobytes (`size_kb`, `freed_kb`) of at most 9007199254740991 (2^53 − 1,
  the largest count whose bytes fit in a signed 64-bit integer); booleans are JSON booleans.
  A larger size makes its line malformed, so hosts skip it.
- A clean run, or a Trash-list run, is complete only when its `summary` event arrived and the
  process exited 0; `RunCompletion` (last section) classifies every other ending. Uninstall runs
  write no `summary`: hosts judge them by the exit status and one outcome per requested app
  (Uninstall host notes). `uninstall --list` prints one JSON array and `status-go` one snapshot
  per line; neither writes events.

## Clean events (`bin/clean.sh`, patch 0002)

| `type` | When | Fields |
|---|---|---|
| `section` | a cleanup section starts | `name` |
| `candidate` | a dry run finds an item (live progress; may repeat or overlap) | `section`, `path`, `size_kb`, `size_known` |
| `item` | end of a dry run: the deduplicated preview | `section`, `path`, `size_kb`, `count`, `size_known`, `covered_by` (nearest previewed ancestor whose size already includes this item, or `null`) |
| `result` | real runs: one outcome per path, mirrored from `log_operation` | `command`, `action` (`removed` / `skipped` / `failed`), `path`, `detail`, and on `removed` results `size_kb` when measured (patch 0006) |
| `summary` | end of a run that finished its cleanup pass (see below) | `command`, `dry_run`, `items`, `size_kb`, `partial`, `exit` |

Hosts total a preview from `item` events whose `covered_by` is `null`, and charge only
`result` events with `action: removed` whose `path` is one of the paths they selected.

Details:

- `result` events are written whenever `MOLE_JSON_EVENTS_FILE` is set, even with
  `MO_NO_OPLOG=1`, and never while `MOLE_DRY_RUN=1` (which `--dry-run` sets).
  `log_operation` actions other than `REMOVED`, `SKIPPED` and `FAILED` (such as `REBUILT`)
  are not reported. Two removal paths bypass `log_operation` and report directly:
  - Batched admin removals in `safe_sudo_find_delete` (`detail: "batch"`). They only run in
    the System section, which needs admin access, so they never run under `MOLE_NO_AUTH=1`
    and write no `result` events there.
  - Time Machine `tmutil delete` outcomes (`detail` is the human-readable size on
    success, `"tmutil delete"` otherwise). The Time Machine section is not gated by admin
    access: a real run without `--external` calls `tmutil delete` without `sudo` for each
    old incomplete backup it finds on a locally mounted backup volume or backup disk image
    while Time Machine is idle. `tmutil delete` needs root and Full Disk Access, so when
    the engine runs as a normal user (as RoomForMac always runs it, with
    `MOLE_NO_AUTH=1`), the attempt can only report `action: "failed"` with
    `detail: "tmutil delete"`, never `removed`. The same `failed` result is written when
    the delete times out or the section runs out of time before trying it.
- `summary`: `items` and `size_kb` are the run totals (for a dry run, the sums of `count`
  and `size_kb` over `item` rows whose `covered_by` is `null`); `partial` is `true` when a
  dry-run total leaves out items of unknown size; `exit` is `0`, or the status of the
  cleanup step that stopped the run early (`124` timeout, `128` and above a signal, any
  other value a required step that failed). Only a run that reaches the end of the
  cleanup pass writes a `summary`. A run whose engine process is killed, or stopped by
  `SIGINT` or `SIGTERM`, writes none, and so does one that ends before or outside that
  pass: invalid arguments, `--help`, `--whitelist`, a dry run that cannot create its
  preview file, or Mole's test mode (`MOLE_TEST_MODE=1`), for example.

### Clean results (patch 0006)

- **`size_kb` on `removed` results.** A `removed` result carries `size_kb`: the KiB the
  engine measured for that path just before deleting it, measured the same way as the
  path's preview `size_kb`. `0` is a real size (an empty file or folder). The key is
  absent when the removal could not measure the path (its size probe failed or ran out
  of time). `skipped` and `failed` results never carry it, and dry runs still write no
  `result` events. Hosts charge `size_kb` when it is present and the preview size when
  it is absent.
- The size is measured whenever `MOLE_JSON_EVENTS_FILE` is set, even with `MO_NO_OPLOG=1`.
  With the operations log on, the log line and the event share one measurement, and a
  size the calling section already measured is reused without measuring again.
- Most clean items reach the removal with a size their section measured just before
  (`safe_clean` sizes its batch first). When that measurement fails the section passes
  `0`, so the result reads `size_kb: 0`. A preview whose own measurement failed the same
  way shows the row as `size_kb: 0` with `size_known: true`.
- Removals that do not go through `safe_remove` or `safe_sudo_remove` carry no `size_kb`:
  symlinks (`detail: "symlink"`), simulators (`"simulator"`), empty app containers
  (`"stub-container"`), the System section's batched and memory-report removals, and
  Time Machine.
- **`detail` on `removed` results is text for people.** It is the measured size in
  decimal units (Mole's `bytes_to_human`: 1 KB = 1000 bytes, as in `"922KB"` or
  `"3.1MB"`), empty for a zero-size item, or a word such as `"symlink"`. Never parse it;
  use `size_kb`. With the events file set it is filled in even with `MO_NO_OPLOG=1`.
- **`skipped` results also arrive for paths the host did not select.** Sections report
  protected paths they meet before the selection check (`detail: "protected"`; for
  example the engine's own `~/Library/Logs/mole`). Hosts ignore results for paths they
  did not select.

### Host notes for Smart Clean

Verified against the patched `V1.56.0` engine; `MoleEngine`'s `CleanService`,
`CleanSections`, `CleanSelection` and `CleanRunTally` follow them.

- `item.count` is always `1`. It is not a file count.
- Paths may lie outside `HOME`. The per-user clang module cache, for example, is reported
  as `/var/folders/<xx>/<id>/C/clang/ModuleCache`, in `/var/…` form rather than
  `/private/var/…`. Selections match exact strings, so hosts pass every path back byte for
  byte.
- `covered_by` may name a row in another section. `User essentials` sweeps
  `~/Library/Caches/*` whole, so a `Browsers` or `Developer tools` row inside one of those
  folders is covered by a `User essentials` row, and a section's own total can look small.
- Sections arrive in a fixed order: `System` (only with a sudo session, which
  `MOLE_NO_AUTH=1` never grants), `User essentials`, `App caches`, `Browsers`,
  `Cloud & Office`, `Developer tools`, `Apps & utilities`, `Virtualization`,
  `Application Support`, `App leftovers`, `Apple Silicon updates` (Apple silicon only),
  `Device backups & firmware`, `Time Machine`, `Large files`, `Project artifacts`. Every
  section's `section` event arrives even when it finds nothing. The names are English and
  never localized; hosts must still accept a name they do not know.
- Two sections only report: `Large files` and `Project artifacts` write to stdout, which
  the host discards, and never produce `candidate` or `item` rows. They still take time.
- `Time Machine` rows can only end `failed` for a normal user (see Clean events above);
  RoomForMac never offers them.
- A real run's `summary.items` and `summary.size_kb` are Mole's display totals. They do not
  add up from the `result` events, so hosts count removals and bytes from `result` events
  only.
- A selected dry run (`--dry-run` with `MOLE_SELECTION_FILE`) still walks every section,
  so it costs about as much as a whole preview. Its rows carry fresh sizes and
  `covered_by: null`, because a host never selects a row together with its covering
  ancestor.
- Protected paths are a host-side filter, not an engine rule. RoomForMac's own data
  (`ProtectedPaths`) is dropped by `CleanService`: `candidate` and `item` rows equal to,
  inside or containing a protected path (ignoring trailing slashes and letter case) never
  reach the app, and are counted as `"protected"` in the run's diagnostics. Such a path is
  never written to a selection file.

## Selections (`MOLE_SELECTION_FILE`, patch 0003)

- The file lists absolute paths separated by NUL bytes, exactly as the preview's `item.path` reported them. Trailing slashes are ignored; parents and children of a listed path are **not** selected.
- Real runs remove only listed paths. Dry runs preview only listed paths, which gives fresh sizes for a selection just before cleaning.
- Cleanups driven by an external tool never run under a selection: Homebrew cleanup/autoremove, npm/pnpm/pip/uv/corepack/conda/mise caches and Nix garbage collection (`clean_tool_cache`), `bun pm cache rm`, `go clean`, and stopping leaked automation browsers. Unavailable simulators are deleted one by one with `simctl delete <udid>`; each selected device reports a `result` for its previewed path `~/Library/Developer/CoreSimulator/Devices/<udid>` (`detail: "simulator"` when removed, `"simctl delete (status N)"` when it failed).
- A selection file that is missing, a symlink, or unreadable allows nothing.
- Selections match paths, not file identities. A selected path that no longer exists when the run reaches it is skipped and gets no `result`; whatever the cleanup finds at a selected path at run time (a folder an app recreated, for example) is cleaned like the original.
- Hosts select a covered item (`covered_by` set) only when its covering ancestor is not selected, so no bytes are counted twice.

## Uninstall (`bin/uninstall.sh`, patch 0004)

| Variable | Effect |
|---|---|
| `MOLE_UNINSTALL_APP_PATHS_FILE=PATH` | NUL-separated `.app` paths. Each must exactly match an app from the normal eligibility scan; others produce `app_blocked` / `not_eligible`. |
| `MOLE_UNINSTALL_PREVIEW_ONLY=1` | Stop after scanning the selected apps (always pair with `--dry-run`). |
| `MOLE_ASSUME_YES=1` | Treat the plan as confirmed; never read a key. |
| `MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS=100000` | Upstream variable, no patch; RoomForMac sets it on `uninstall --list`. Every app missing from Mole's metadata cache is then measured with a bounded `du` (2 s per app). Upstream does that only when 20 or fewer apps are missing, so a first list on a Mac with more apps reports `size_kb: 0` for them until Mole's background refresh fills the cache. |

| `type` | Fields |
|---|---|
| `app` | `path`, `name`, `bundle_id`, `size_kb` (app + leftovers), `needs_sudo`, `brew_cask`, `sensitive_data`, `running`, `leftovers` (paths removed with the app), `review_only` (system paths shown but never removed), `leftover_items` (each leftover's size; see below) |
| `app_blocked` | `path`, `name`, `reason` (`not_eligible` / `official_uninstaller` / `manual_removal`), `vendor` |
| `app_result` | `path`, `name`, `status` (`removed` / `failed`), `freed_kb`, `reason` |

`uninstall --list` (stdout is a pipe → JSON array) adds `size_kb` and `last_used_epoch` to each app.
While admin access is off, apps with `needs_sudo` or `brew_cask` cannot be removed: the batch
needs a sudo session, so a single such app in the paths file makes the whole run exit 1 before
anything is removed (its `app` events arrive, and no `app_result` does). Hosts show these apps
as needing a password and never send them. In Trash mode `needs_sudo` means the app's parent
folder is not writable: for a standard user that is every app in `/Applications`, while a
root-owned app in `/Applications` needs no password for an administrator.

Details:

- With `MOLE_UNINSTALL_APP_PATHS_FILE` set, name arguments, the `[y/N]` prompt and the
  interactive selector are never used; `MOLE_ASSUME_YES=1` answers the one remaining
  confirmation, the batch's `Enter` / `ESC` key.
- `app` events come from the scan, so previews and real runs both write one for each selected
  app that passed it, before anything is removed. A `not_eligible` event carries the requested
  path (trailing slashes removed) with an empty `name` and `vendor`.
- `leftover_items` has one object per entry of `leftovers`, in the same order:
  `{"path", "size_kb", "size_known", "covered_by"}`. `path` is the `leftovers` entry exactly.
  - Each leftover is measured once, on the basis of the engine's own total: `du -skP` for a
    folder, allocated blocks for a file. The app's `size_kb` is the bundle plus every item
    with `covered_by: null` and `size_known: true`, so the bundle's own size is `size_kb`
    minus their sum.
  - A leftover equal to or inside another listed leftover is not measured again: `size_kb` is
    `0`, `covered_by` names its nearest listed ancestor (for a path listed twice, its first
    listing), and `size_known` repeats the flag of the leftover whose size holds its bytes.
  - `size_known: false` (with `size_kb: 0`) means measuring failed or timed out, for that
    leftover only. After two timeouts in one app, its remaining leftovers are not measured
    and report `false`. A path containing byte `0x1f` is never measured, reports `false`, and
    never covers another leftover.
  - A leftover that no longer exists reports `size_kb: 0`, `size_known: true`.
  - Without `MOLE_JSON_EVENTS_FILE` the engine totals leftovers exactly as Mole `V1.56.0`
    does, where one size timeout counts all of an app's leftovers as 0.
- `app_result` events are written only for real runs, never with `--dry-run`. For a removed
  app, `freed_kb` is the `size_kb` of that run's own `app` event minus the leftovers still in
  place after the removal (measured again with `du`, never below 0). The app is still
  reported `removed`, and no event names the leftovers left behind: a host that needs them
  checks which `leftovers` still exist. Container folders macOS keeps (a
  `Library/Containers/*` folder that still holds `.com.apple.containermanagerd.metadata.plist`)
  are neither subtracted nor reported by the engine. A failed app reports `0`. `reason` is
  empty on success.
- Exit status `0`: the run finished (per-app failures are reported by `app_result`), or every
  requested app was blocked, whether not eligible or blocked during the scan
  (`official_uninstaller`, `manual_removal`). Then the `app_blocked` events are the whole
  answer, for previews and real runs alike, and nothing was removed. A non-zero status before
  removals start also removes nothing: a missing path list, a scan that could not finish (even
  when other apps were already blocked), a scan timeout or signal, or a batch that needs the
  sudo session `MOLE_NO_AUTH=1` refuses. A timeout or signal during removals leaves
  `app_result` events only for apps already handled. Without `MOLE_UNINSTALL_APP_PATHS_FILE`,
  a batch whose apps were all blocked still exits 1, as in Mole `V1.56.0`.
- In `uninstall --list`, `size_kb` is the scanned bundle size and `last_used_epoch` the last use
  in seconds since 1970 (the bundle's modification time when macOS has no last-use date, `0`
  when neither is known). These two fields are the only change without a host variable; they
  are added keys, and the existing ones are unchanged. A `size_kb` above the limit in the JSON
  conventions makes the whole array malformed.

### Uninstall host notes (MoleEngine)

- `uninstall --list` prints apps by last use, oldest first (`last_used_epoch` ascending). Hosts
  sort for themselves.
- An app without an entry in the engine's metadata cache (`~/.cache/mole`, which the engine
  refreshes in the background) is a cold row. The engine measures cold rows with `du` only when there
  are at most `MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS` of them (default 20); otherwise each
  one reads `size_kb: 0` and `size: "--"` until the background refresh has run, so a first list
  after install has no sizes. The variable is an overridable default, not a patch.
  `UninstallService.listApps(measureColdSizes: true)`, the default, sets it to `100000`: every
  app is measured, each `du` still capped at 2 s, which adds a few seconds on a cold cache only.
- `UninstallService` sends each requested path once, without trailing slashes, in request
  order (`normalizedAppPaths`); the engine would scan a duplicate twice.
- A preview that exits 1 with only `app_blocked` events that cover every requested path is an
  answer (every app was blocked in the scan), not a failure; an engine without the amended 0004
  exits 1 there. Any other non-zero exit, any requested path reported neither as `app` nor as
  `app_blocked`, and a cancelled caller are errors: a preview is never partial. The error names no
  path.
- A real run writes no `summary`. `UninstallRunTally` gives each requested app one outcome: the
  first `app_result` wins, an app without one was not handled, and an `app_result` for a path
  nobody requested is kept apart for the diagnostics and never charged.
- Removed apps and leftovers go to the Trash: `uninstall` defaults `MOLE_DELETE_MODE` to
  `trash`, and Trash mode fails closed instead of deleting permanently. The engine moves items
  itself: a direct move for `/Applications/*.app` and for the folders directly inside
  `~/Library/Containers`, `Group Containers` and `Application Scripts`; one batched rename for
  most other leftovers; and `/usr/bin/trash` for the rest, one item at a time. It asks Finder
  (an Apple event) only when those fail, and retries an app bundle through Finder when macOS
  privacy controls refuse its direct move. Directly moved items have no Finder "Put Back" record.
- To quit an app that is still running, the engine's `force_kill_app` skips its AppleScript
  Quit under `MOLE_GUI_HOST` and sends `pkill -x <executable name>`, then `pkill -9 -x`. That
  also ends any other process whose executable has the same name, so RoomForMac quits apps
  itself before a run and never sends an app whose executable name another running process
  shares.

## Analyzer Trash list (`bin/analyze-go --trash-list FILE`, patch 0005)

- FILE lists absolute paths separated by NUL bytes. Each is moved to the Trash with the analyzer's own validation (protected and critical paths are refused), deepest paths first.
- stdout: one `result` event per path (`command:"analyze"`, `action` `removed` / `skipped` (missing) / `failed` with `detail`), then one `summary` (`items` = removed count, `partial` = any failure, `size_kb` 0).
- Exit code 0 when the list was processed; 1 only when FILE cannot be read.
- Hosts route `.app` bundles to the uninstaller instead of this command.

## Live status (`bin/status-go --watch`, no patch)

`bin/status-go --watch --interval <n>s` (whole seconds, at least 1) writes one JSON snapshot per
line on stdout until the host ends it; it exits by itself only when stdout closes. It runs with
`status-bin/` first on `PATH` (see Status helpers). A host keeps one process and pauses it with
`SIGSTOP` and `SIGCONT` to its process group instead of restarting it when demand changes: a
new process starts cold again (no rates, no enrichment, an empty `network_history`). A host stop
is `SIGTERM` followed by `SIGCONT`, so a paused process ends at once.

RoomForMac's cadence (Plan 3 Ruling 16, as revised on 2026-09-27): the process is live while the
Status section is on screen or the menu-bar panel is open, and paused otherwise, including while
only the menu-bar extra is shown with its panel closed, because the extra's label shows no live
numbers. A faster cadence applies at once; a pause waits 30 s. After 5 minutes paused the
process is stopped, and the next demand starts a new one, so at most one runs at a time.
`StatusMonitor` also supports a 10 s background cadence (resume, take one snapshot, suspend),
which `StatusCadence.resolve` does not use in M2. RoomForMac reads free space itself
(`volumeAvailableCapacityForImportantUsage`): when the Status section appears or the panel opens,
every 60 s (with a few seconds' tolerance) while either of them shows it, and after every run; it
never runs a timer for the menu-bar icon alone (Ruling 16 as revised in the final review).

**Timing** (measured on macOS 27 with `--interval 2s`):
- The first line arrives about 0.13 s after the start. It is a *fast* collect and is not
  enriched: every `hardware` string is `""`, `gpu` and `batteries` are `null`,
  `cpu.p_core_count` and `e_core_count` are 0, `memory.pressure` and `cached` are empty,
  `disks[]` hold raw `statfs` values, `disk_io` is 0, the network rate covers about 0.1 s, and
  `top_processes` and the `process_*` keys are absent. Its `health_score` comes from that partial
  data (74 against 43 for the full snapshot 70 ms later).
- The first *full* collect starts right after the first line; its line arrives about 2 s after
  the start. From then on `hardware.os_version` is not empty, which is how a host tells an
  enriched snapshot (`SystemSnapshot.isEnriched`).
- Then one line per interval, plus 0.1–0.5 s of collection. A full collect runs every 30 s of
  wall-clock time. The fast collects in between copy the last full collect's hardware, P/E core
  counts, memory pressure and cache, corrected disks, GPU, batteries and thermal readings. Only a
  full collect in which every step succeeded refreshes that copy; until one has, every tick is a
  full collect.
- After `SIGCONT`, the next line arrives within about 0.5 s, and its rates cover the paused time.
  RoomForMac therefore keeps the rates of the first line after a pause longer than 2.5 s out of
  its history, as it does for a new process's first line.
- A collect step that fails writes `status: collect failed: …` to stderr; the snapshot is still
  written.

**Dates.** `collected_at` (when the collection started) and `process_collected_at` are RFC 3339
with 0 to 9 fraction digits and a zone offset or `Z`, for example
`2026-09-27T02:08:28.26406-03:00`. MoleEngine parses them with
`Date.ISO8601FormatStyle(includingFractionalSeconds: true)`, then `.iso8601`. A line whose date
parses with neither is skipped, like any line that does not decode.

**Fields a host reads.** Units are the Go source's: bytes, percent, MiB/s (the engine's "MB/s"
divides by 1024 × 1024), °C, rpm and W. Any key may be missing or `null`, so MoleEngine decodes
each one as optional. After `.convertFromSnakeCase` the names are `diskIo` and `logicalCpu`, not
`diskIO` and `logicalCPU`: a differently cased optional property decodes as nil without an error.

| Key | Notes |
|---|---|
| `collected_at`, `host`, `platform` (`darwin 27.0`), `uptime_seconds`, `procs` | |
| `hardware{model,cpu_model,total_ram,disk_size,os_version,refresh_rate}` | strings; `""` until the first full collect |
| `health_score`, `health_score_msg` | 0–100 and English `"<Band>[: Issue, Issue]"`. A host shows them only once a snapshot is enriched, and maps the message to its own copy |
| `cpu{usage,per_core[],per_core_estimated,load1,load5,load15,core_count,logical_cpu,p_core_count,e_core_count}` | fast collects use raw deltas; full collects apply the parked-core floor |
| `gpu[]{name,usage,core_count,note}` | full collects only. `usage` is −1 without root, so the app reads GPU use itself |
| `memory{used,total,available,used_percent,swap_used,swap_total,cached,pressure}` | `pressure` is always `""` on macOS 27, so the app reads the pressure level itself |
| `disks[]{mount,device,used,total,used_percent,fstype,external,smart_status,purgeable}` | at most 3, internal first. `purgeable` is present only when Finder answered, so never with `status-bin`. A host uses the disk mounted at `/`, else the first (`SystemSnapshot.rootDisk`) |
| `disk_io{read_rate,write_rate}` | MiB/s since the previous line; 0 on the first |
| `network[]{name,rx_rate_mbs,tx_rate_mbs,ip}`, `network_history{rx_history[],tx_history[]}` | the top 3 interfaces; up to 120 summed samples, which restart with the process |
| `batteries[]{percent,status,time_left,health,cycle_count,capacity}` | `null` on the first line and on Macs without a battery |
| `thermal{cpu_temp,gpu_temp,battery_temp,fan_speed,fan_count,system_power,adapter_power,battery_power}` | 0 means unknown (`cpu_temp` and the fans read 0 on an M2 MacBook Air) |
| `trash_size`, `trash_approx` | walks `$HOME/.Trash` for up to 2 s; 0 without Full Disk Access |
| `top_processes[]{pid,ppid,name,command,cpu,memory,memory_bytes}`, `process_collected_at`, `process_stale` | the top 5; absent on the first line |

A host ignores `uptime`, `proxy`, `sensors` (always `null`), `bluetooth` (the engine's
`"No Bluetooth info"` placeholder with `status-bin`), `zombie_*`, `process_watch` and
`process_alerts`.

## Status helpers (`status-bin/`, no patch)

`scripts/build-engine.sh` writes two bash scripts into `status-bin/`. Hosts put that directory
first on `PATH` for `bin/status-go` only, in front of the `PATH` above. Every other command runs
without it, so Smart Clean, the uninstaller and the analyzer always reach the real tools.

| Stub | Behaviour | Effect on `status-go` |
|---|---|---|
| `status-bin/osascript` | Exits 1 without output, whatever its arguments. | Full collects ask Finder for the startup disk's free space (`tell application "Finder" …`; the result, a failure included, is cached for 2 minutes). With the stub that tier fails at once: `status-go` never sends Finder an Apple event and never launches Finder. It falls back to `diskutil`, and `disks[].purgeable` is absent. |
| `status-bin/system_profiler` | Exits 1 without output when any argument is `SPBluetoothDataType`; otherwise `exec /usr/sbin/system_profiler "$@"`. | Full collects list Bluetooth devices, which may make macOS ask for Bluetooth access. With the stub, `bluetooth` holds the engine's `"No Bluetooth info"` placeholder. The power, hardware and display queries are unchanged. |

Both stubs are required, executable files of an engine: `EngineInstallation(root:)` rejects a
directory without them (`missing status-bin/osascript`, `not executable: …`), and the app then
shows its "Reinstall RoomForMac" card. They are scripts, so the app keeps them in
`Contents/Resources/engine/status-bin`; `Contents/Helpers` holds only the two Go tools.

## Stopping a run, how it ended, and diagnostics (host side)

These rules belong to `Packages/MoleEngine`; the engine needs no patch for them.

- **Host stop.** `EngineRunControl.stop()` sends `SIGTERM`, then `SIGCONT`, to the engine's
  process group, so a suspended group ends at once. The host keeps reading until the process
  exits, delivers every line written before the exit, and then ends the stream with
  `EngineError.cancelled`. `SIGKILL` follows after the grace period (5 s), to the group, if the
  engine's leader process has not exited by then; once the leader is reaped the group is not
  signalled again, because its id may be reused, so a group member that outlived the leader and
  ignores `SIGTERM` is not killed. Cancelling the consuming Task instead is a hard abort: lines
  not yet read are dropped, and the group gets the same `SIGTERM`, `SIGCONT` and, after the grace
  period, `SIGKILL` under the same condition. A stop is final: a command whose control was
  already stopped spawns nothing and ends with `cancelled`.
- **Helpers in their own group.** The engine's `run_with_timeout` runs a helper under GNU
  `timeout` or its perl fallback (`lib/core/timeout.sh`), and both put the helper in a new process
  group. The host's group signals (`SIGSTOP`, `SIGCONT`, `SIGKILL`) never reach such a helper; it
  ends when its wrapper forwards the `SIGTERM` the wrapper receives. A helper whose wrapper was
  killed, or that ignores `SIGTERM`, can outlive the run as an orphan.
- **Host suspend.** `EngineRunControl.suspend()` sends `SIGSTOP` to the process group, and
  `resume()` sends `SIGCONT`. A suspend requested before the process starts applies as soon as
  it starts, and `resume()` clears it. After a stop, or once the process has exited, neither
  sends anything. Only Status suspends its process (see Live status).
- **A stream stopped by the host has no `summary`.** Mole's `TERM` trap exits 143 without writing
  one (see Clean events). The exception is a stop that raced the end of the run: a `summary`
  with `exit` 0 that arrived before the stop means the run finished.
- **How a run ended** is decided in one place, `RunCompletion.classify(summary:error:stopRequested:)`.
  The first matching rule wins:

  | # | Condition | Outcome |
  |---|---|---|
  | 1 | a `summary` with `exit` 0, and no error (or only the `cancelled` that a stop after it produced) | `completed` |
  | 2 | the host requested a stop | `cancelled`, with the summary if one arrived |
  | 3 | a `summary` with a non-zero `exit` | `stoppedEarly` |
  | 4 | an `EngineError` (a Swift `CancellationError` counts as `cancelled`) | `failed` |
  | 5 | any other error | `failed` with `launchFailed` |
  | 6 | no error and no summary | `incomplete` |

  Services throw only `EngineError`. Anything that fails before the engine starts (the run
  folder, a path list) becomes `launchFailed`.
- **The engine outlives a crashed host.** Each command leads its own process group, and nothing
  ties it to the app's life. If RoomForMac crashes or is force-quit, the engine is reparented to
  `launchd` and runs to the end. Its results are never read, and its run folder
  (`$TMPDIR/roomformac-engine-<UUID>/`) is left behind. The same holds for a run the host
  neither stops nor awaits before a normal quit.
- **Run folder.** Besides `events.ndjson`, `stderr.log` and the path lists, it holds `stdout.log`
  (0600). An events-file run's stdout, the engine's readable transcript, is appended there instead
  of going to `/dev/null`.
- **Diagnostics.** Every run produces one `RunDiagnostics` just before its stream ends, however it
  ends: success, error, stop, Task cancellation or a launch failure.
  - `command`: the executable's last path component and the arguments.
  - `startedAt` and `endedAt`.
  - `exit`: `exit 0`, `exit <n>`, `signal <n>`, `cancelled`, `timed out` or `not started`.
  - `eventCounts`: events by `type`. `unparsed` counts lines the host skipped, and `protected`
    counts preview rows the host dropped (Smart Clean).
  - `stdoutTail` and `stderrTail`: the last 64 KiB of each, starting at a UTF-8 character
    boundary. For a stdout-mode command, the stdout tail is the last lines received.
  - `unexpectedRemovals`: filled by the feature from its tally.

  The tails are read before the run folder is removed.
- **Log.** The app appends each record to `~/Library/Logs/RoomForMac/engine.log` with
  `EngineLogStore`: the folder is 0700, the files 0600, and a symlinked file is never written
  through. Before an entry would push the file past 1 MiB, the file rotates, keeping
  `engine.1.log` (the newest) to `engine.4.log`. Each entry is a header line and the tails, with
  every tail line indented by two spaces, so only headers start with `===`:

  ```
  === 2026-09-27T02:05:54Z clean.sh --dry-run · exit 0 · 7.2 s · item=24 section=14 summary=1
  --- stdout (tail)
    Scanning caches
  --- stderr (tail)
  ```

  A non-empty `unexpectedRemovals` adds an `--- unexpected removals` block. **Show details** and
  **Copy diagnostics** read this log. It holds paths, so it never leaves the Mac.
- `MO_NO_OPLOG` stays unset, so the engine keeps writing its own operations log in
  `~/Library/Logs/mole`, which RoomForMac leaves alone. (With patch 0006 the `removed` sizes
  would arrive either way.)
