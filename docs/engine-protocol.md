# RoomForMac engine protocol (v1)

RoomForMac drives its bundled, patched Mole engine (`build/engine`, shipped as
`RoomForMac.app/Contents/Resources/engine`) through environment variables and reads
machine-readable results. This is the contract between `patches/mole/` and
`Packages/MoleEngine`.

## Invoking the engine

| Purpose | Executable | Output |
|---|---|---|
| Smart Clean preview | `bin/clean.sh --dry-run` | events file |
| Smart Clean run | `bin/clean.sh` with `MOLE_SELECTION_FILE` | events file |
| App inventory | `bin/uninstall.sh --list` | JSON array on stdout |
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

- One object per line, UTF-8, first key `"v":1`. Hosts skip lines they cannot parse and types they do not know.
- Strings escape `"`, `\`, `\n`, `\r`, `\t`, and other control bytes as `\u00XX`.
- Sizes are integer kilobytes (`size_kb`, `freed_kb`) of at most 9007199254740991 (2^53 − 1,
  the largest count whose bytes fit in a signed 64-bit integer); booleans are JSON booleans.
  A larger size makes its line malformed, so hosts skip it.
- A run is complete only when its `summary` event arrived and the process exited 0.

## Clean events (`bin/clean.sh`, patch 0002)

| `type` | When | Fields |
|---|---|---|
| `section` | a cleanup section starts | `name` |
| `candidate` | a dry run finds an item (live progress; may repeat or overlap) | `section`, `path`, `size_kb`, `size_known` |
| `item` | end of a dry run: the deduplicated preview | `section`, `path`, `size_kb`, `count`, `size_known`, `covered_by` (nearest previewed ancestor whose size already includes this item, or `null`) |
| `result` | real runs: one outcome per path, mirrored from `log_operation` | `command`, `action` (`removed` / `skipped` / `failed`), `path`, `detail`, and on `removed` results `size_kb` when measured (patch 0006) |
| `summary` | end of every run | `command`, `dry_run`, `items`, `size_kb`, `partial`, `exit` |

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
While admin access is off, apps with `needs_sudo` or `brew_cask` cannot be removed (the batch
needs a sudo session); hosts show them as needing a password and never send them.

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

## Analyzer Trash list (`bin/analyze-go --trash-list FILE`, patch 0005)

- FILE lists absolute paths separated by NUL bytes. Each is moved to the Trash with the analyzer's own validation (protected and critical paths are refused), deepest paths first.
- stdout: one `result` event per path (`command:"analyze"`, `action` `removed` / `skipped` (missing) / `failed` with `detail`), then one `summary` (`items` = removed count, `partial` = any failure, `size_kb` 0).
- Exit code 0 when the list was processed; 1 only when FILE cannot be read.
- Hosts route `.app` bundles to the uninstaller instead of this command.

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
  `EngineError.cancelled`. `SIGKILL` follows after the grace period (5 s) if the group is still
  alive. Cancelling the consuming Task instead is a hard abort: lines not yet read are dropped.
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
