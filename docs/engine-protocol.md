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
`host-bin/` (while admin access is off), then Homebrew and system directories.

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
- Sizes are integer kilobytes (`size_kb`); booleans are JSON booleans.
- A run is complete only when its `summary` event arrived and the process exited 0.

## Clean events (`bin/clean.sh`, patch 0002)

| `type` | When | Fields |
|---|---|---|
| `section` | a cleanup section starts | `name` |
| `candidate` | a dry run finds an item (live progress; may repeat or overlap) | `section`, `path`, `size_kb`, `size_known` |
| `item` | end of a dry run: the deduplicated preview | `section`, `path`, `size_kb`, `count`, `size_known`, `covered_by` (nearest previewed ancestor whose size already includes this item, or `null`) |
| `result` | real runs: one outcome per path, mirrored from `log_operation` | `command`, `action` (`removed` / `skipped` / `failed`), `path`, `detail` |
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
