# Plan 1 — Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the patched Mole engine that RoomForMac bundles, plus the `MoleEngine` Swift package that runs it safely and turns its output into typed events.

**Architecture:** Mole `V1.56.0` is a git submodule. Five small, upstreamable patches (stored as `git format-patch` files) add a machine-readable event stream, exact-path selections, a no-admin mode, a non-interactive uninstall mode, and a Trash-list mode for the analyzer. `scripts/build-engine.sh` applies them to a fresh clone, builds universal Go binaries and assembles `build/engine/`. The `MoleEngine` package launches engine commands in their own process group, streams NDJSON events from a file or stdout, and exposes Clean / Uninstall / Analyzer / Status services.

**Tech Stack:** Bash 3.2 (macOS `/bin/bash`) + bats-core for the patches; Go 1.26 for the analyzer patch; Swift 6.2+ (Xcode 26/27), Swift Testing, Foundation + Darwin `posix_spawn`; GitHub Actions `macos-26`.

**Spec:** `docs/superpowers/specs/2026-09-25-roomformac-design.md` · **Roadmap:** `docs/superpowers/plans/2026-09-25-roomformac-roadmap.md` (read its "Decisions made while planning")

## Global Constraints

- Mole is pinned to tag `V1.56.0` (commit `239c90d…`). Never run a system-installed `mo`.
- Engine patches: bash 3.2 compatible (no associative arrays, `mapfile`, `declare -g`, `${x,,}`), safe under `set -euo pipefail`, formatted with `shfmt -i 4 -ci -sr`, clean under `shellcheck`, each patch standalone with its own bats tests, and **inert unless a host variable is set**.
- Host interface (the only way RoomForMac drives the engine): environment `MOLE_GUI_HOST=roomformac`, `MOLE_NO_AUTH=1`, `MOLE_JSON_EVENTS_FILE`, `MOLE_SELECTION_FILE`, `MOLE_UNINSTALL_APP_PATHS_FILE`, `MOLE_UNINSTALL_PREVIEW_ONLY=1`, `MOLE_ASSUME_YES=1`; analyzer flag `--trash-list FILE`.
- Event schema: one JSON object per line, `"v":1`. Sizes are KB (`size_kb`) on the wire and bytes (`sizeBytes`) in Swift.
- Deletion safety: with `MOLE_SELECTION_FILE` set, nothing outside the listed exact paths may be removed and tool-driven cleanups never run. Delete modes follow Mole: Smart Clean permanent, Uninstaller and Terrain to the Trash.
- No administrator access in v1: `MOLE_NO_AUTH=1` plus `host-bin/sudo` (always exits 1) first on `PATH`.
- Swift: `swift-tools-version: 6.2`, `.macOS(.v26)`, Swift 6 language mode, no third-party dependencies.
- User-facing RoomForMac text never says "Mole"; attribution lives in `NOTICE`, `README` and About.
- Tests never touch the real Trash, real caches or the developer's home: fake `HOME`, `MOLE_TEST_TRASH_DIR`, stubbed `brew`/`xcrun`/`lsof`/`ps`/`osascript`/`launchctl`/`mdfind`/`killall`, and an `rm` guard that refuses paths outside the fake root.
- License GPL-3.0; the engine is credited in `NOTICE`.

## Review Focus

1. **A selected item vanishes or changes between preview and cleaning** (deleted by the user, recreated by an app, swapped for a symlink) → no `removed` event, not charged, and never a deletion of whatever replaced it. Pinned by Task 5 ("disappears before the run") and Task 10 ("items without a removal event are not removed").
2. **Unusual bytes in paths** (spaces, quotes, backslashes, accents, newlines) through selection files and events → Task 3 escaping/selection tests, Task 8 decoder test, Task 12 integration folder `com.example.gamma café`.
3. **Cancelling mid-run** must stop the whole process tree and keep accounting honest → Task 9 timeout/cancel tests kill a grandchild; Task 10 tally counts only confirmed removals.
4. **Truncated or malformed engine output** (killed mid-write, invalid JSON, unknown types, a future `v:2`) → Task 8 decoder and line-buffer tests; Task 9 final unterminated line.
5. **Very large selections** (thousands of paths) → Task 3 5,000-entry lookup timing test; Task 10 10,000-path selection file test.

---

## File Structure

```
RoomForMac/
├─ Brewfile                          toolchain for this plan
├─ .gitignore  LICENSE  NOTICE  README.md
├─ vendor/mole/                      submodule @ V1.56.0
├─ patches/mole/                     0001…0005 *.patch (git format-patch output)
├─ scripts/
│  ├─ mole-patches.sh                start | export | test | lint
│  ├─ build-engine.sh                → build/engine (+ patched source in build/engine-src)
│  └─ tests/build_engine.bats
├─ docs/engine-protocol.md           host variables + event schema v1
├─ Packages/MoleEngine/
│  ├─ Package.swift
│  ├─ Sources/MoleEngine/
│  │  ├─ Models/     CleanItem, CleanCandidate, ItemResult, RunSummary, AppPreview (+BlockedApp, AppResult), InstalledApp, DiskLevel, SystemSnapshot
│  │  ├─ Protocol/   EngineEvent, EngineEventDecoder, EngineJSON, EngineError
│  │  ├─ Runner/     NDJSONLineBuffer, Spawner, ProcessExit, ProcessControl, FileDescriptorReader, EngineCommand, EngineRunning, MoleRunner, Duration+TimeInterval
│  │  ├─ Engine/     EngineInstallation, EngineVersion, EngineEnvironment, RunFiles
│  │  ├─ Clean/      CleanSelection, CleanRunTally
│  │  └─ Services/   EventRun, CleanService, UninstallService, AnalyzerService (+DiskLevelCache), StatusService
│  └─ Tests/MoleEngineTests/
│     ├─ Support/    TestInstallation, FakeRunner, StubScript, FakeHome
│     ├─ *Tests.swift
│     └─ Integration/EngineIntegrationTests.swift
└─ .github/workflows/ci.yml
```

Patched Mole files (edited in `build/mole-work`, exported to `patches/mole/`):

| Patch | Files |
|---|---|
| 0001 host helpers | `lib/core/host.sh` (new), `lib/core/common.sh`, `lib/core/sudo.sh`, `lib/core/app_protection.sh`, `tests/host_integration.bats` (new) |
| 0002 clean events | `lib/core/host.sh`, `lib/core/log.sh`, `lib/core/file_ops.sh`, `bin/clean.sh`, `lib/clean/system.sh`, `tests/clean_json_events.bats` (new) |
| 0003 clean selection | `lib/core/file_ops.sh`, `bin/clean.sh`, `lib/clean/apps.sh`, `lib/clean/dev.sh`, `lib/clean/brew.sh`, `lib/clean/system.sh`, `tests/clean_selection.bats` (new) |
| 0004 uninstall host mode | `lib/core/host.sh`, `bin/uninstall.sh`, `lib/uninstall/batch.sh`, `tests/uninstall_host_mode.bats` (new) |
| 0005 analyzer Trash list | `cmd/analyze/trashlist.go` (new), `cmd/analyze/trashlist_test.go` (new), `cmd/analyze/main.go` |

**How to edit Mole in Tasks 3–7:** all edits happen inside `build/mole-work` (created once by `scripts/mole-patches.sh start` in Task 3). Each "Find / Replace with" pair is an exact, unique snippet from Mole `V1.56.0`. After each patch task: commit inside `build/mole-work`, run `scripts/mole-patches.sh export`, rebuild the engine, and commit `patches/mole/` in the RoomForMac repo.

---

### Task 1: Repository foundation

**Files:**
- Create: `Brewfile`, `.gitignore`, `NOTICE`, `README.md`, `LICENSE` (copied from Mole)
- Create (submodule): `vendor/mole` pinned to `V1.56.0`, `.gitmodules`

**Interfaces:**
- Consumes: nothing.
- Produces: `vendor/mole` checked out at `V1.56.0`; toolchain `go` (≥ 1.26), `bats`, `shellcheck`, `shfmt`, `gtimeout`, `parallel`.

- [ ] **Step 1: Write the Brewfile**

```ruby
# Toolchain for building and testing the RoomForMac engine.
brew "go"
brew "bats-core"
brew "shellcheck"
brew "shfmt"
brew "coreutils" # gtimeout, used by Mole's run_with_timeout
brew "parallel"  # lets Mole's scripts/test.sh run bats files in parallel
```

- [ ] **Step 2: Install the toolchain and check versions**

Run: `brew bundle --file Brewfile && go version && bats --version && shellcheck --version | head -2`
Expected: `go version go1.26` or newer, `Bats 1.x`, a shellcheck version line.

- [ ] **Step 3: Add Mole as a submodule pinned to V1.56.0**

```bash
git submodule add https://github.com/tw93/mole.git vendor/mole
git -C vendor/mole fetch --quiet --tags
git -C vendor/mole checkout --quiet V1.56.0
git add .gitmodules vendor/mole
```

- [ ] **Step 4: Verify the pin**

Run: `git -C vendor/mole describe --tags --exact-match && git -C vendor/mole rev-parse --short HEAD`
Expected:
```
V1.56.0
239c90d
```

- [ ] **Step 5: Write `.gitignore`**

```gitignore
.DS_Store
/build/
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcuserstate
```

- [ ] **Step 6: Copy the license and write `NOTICE`**

Run: `cp vendor/mole/LICENSE LICENSE`

`NOTICE`:
```
RoomForMac
Copyright (C) 2026 RoomForMac contributors

RoomForMac is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License, version 3 (see LICENSE).

Cleaning engine
---------------
RoomForMac bundles and drives Mole (https://github.com/tw93/mole), an
open-source command-line toolkit licensed under GPL-3.0, copyright the Mole
contributors. RoomForMac applies the patches in patches/mole/ to the Mole
release pinned in vendor/mole.

"Mole" and the Mole logo are trademarks of the Mole project. RoomForMac is an
independent project and is not affiliated with or endorsed by Mole.
```

- [ ] **Step 7: Write `README.md`**

````markdown
# RoomForMac

A calm, native macOS cleaner — Smart Clean, Uninstaller, the Terrain disk explorer and live Status — built on the open-source [Mole](https://github.com/tw93/mole) engine.

> Status: in development. Design: `docs/superpowers/specs/2026-09-25-roomformac-design.md`.

## Requirements

- macOS 26 or later, Xcode 26 or later
- Homebrew tools: `brew bundle --file Brewfile`

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

- [ ] **Step 8: Verify and commit**

Run: `cmp LICENSE vendor/mole/LICENSE && git status --short`
Expected: no output from `cmp`; status lists `.gitignore`, `.gitmodules`, `Brewfile`, `LICENSE`, `NOTICE`, `README.md`, `vendor/mole`.

```bash
git add .gitignore Brewfile LICENSE NOTICE README.md .gitmodules vendor/mole
git commit -m "chore: pin Mole V1.56.0 as the engine submodule"
```

---

### Task 2: Engine build pipeline

**Files:**
- Create: `scripts/mole-patches.sh`, `scripts/build-engine.sh`, `scripts/tests/build_engine.bats`, `patches/mole/.gitkeep`

**Interfaces:**
- Consumes: `vendor/mole` (Task 1).
- Produces: `scripts/build-engine.sh` → `$ENGINE_OUT` (default `build/engine`) containing `VERSION`, `mole`, `bin/*.sh`, `bin/analyze-go`, `bin/status-go` (universal), `lib/**`, `host-bin/sudo`; the patched source tree at `build/engine-src` (kept for tests). `VERSION` keys: `mole_tag`, `mole_commit`, `patches_sha256`, `patch_count`. `scripts/mole-patches.sh start | export | test [--tree DIR] FILES… | lint FILES…`.

- [ ] **Step 1: Write the failing build checks** — `scripts/tests/build_engine.bats`

```bash
#!/usr/bin/env bats
# Engine build checks. Builds once per file into a temporary output directory.

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
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `bats scripts/tests/build_engine.bats`
Expected: FAIL — `setup_file` cannot find `scripts/build-engine.sh`.

- [ ] **Step 3: Write `scripts/build-engine.sh`**

```bash
#!/bin/bash
# Build the patched Mole engine that RoomForMac bundles.
#
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, VERSION
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

cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$patches_sha
patch_count=${#patches[@]}
VERSION

printf 'Engine ready: %s (%s, %d patches)\n' "$OUT" "$tag" "${#patches[@]}"
```

Note: `"${patches[@]}"` is only expanded when the array is non-empty — bash 3.2 treats an empty array as unbound under `set -u`.

- [ ] **Step 4: Write `scripts/mole-patches.sh`**

```bash
#!/bin/bash
# Maintain RoomForMac's patch queue on top of the pinned Mole release.
#
#   start                  Create build/mole-work: pinned Mole with patches/mole/*.patch
#                          applied as commits on branch "roomformac". Edit and commit there.
#   export                 Rewrite patches/mole/*.patch from those commits.
#   test [--tree DIR] F…   Run bats files inside a patched tree (default build/mole-work).
#   lint FILE…             shellcheck + shfmt check (paths relative to build/mole-work).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/mole"
WORK="$ROOT/build/mole-work"
PATCH_DIR="$ROOT/patches/mole"
GIT_ID=(-c user.name="RoomForMac Patches" -c user.email="patches@roomformac.invalid")

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

pinned_commit() {
    git -C "$VENDOR" rev-parse HEAD
}

cmd_start() {
    [[ ! -e "$WORK" ]] || die "$WORK already exists; keep working there or delete it first"
    mkdir -p "$ROOT/build"
    git clone --quiet --no-local "$(git -C "$VENDOR" rev-parse --absolute-git-dir)" "$WORK"
    git -C "$WORK" checkout --quiet -b roomformac "$(pinned_commit)"
    local -a patches=()
    local patch
    for patch in "$PATCH_DIR"/*.patch; do
        if [[ -f "$patch" ]]; then
            patches+=("$patch")
        fi
    done
    if [[ ${#patches[@]} -gt 0 ]]; then
        git -C "$WORK" "${GIT_ID[@]}" am --quiet --3way "${patches[@]}"
    fi
    printf 'Ready: %s (branch roomformac, %d patches applied)\n' "$WORK" "${#patches[@]}"
}

cmd_export() {
    [[ -d "$WORK/.git" ]] || die "run 'scripts/mole-patches.sh start' first"
    [[ -z "$(git -C "$WORK" status --porcelain)" ]] || die "$WORK has uncommitted changes"
    mkdir -p "$PATCH_DIR"
    find "$PATCH_DIR" -name '*.patch' -delete
    git -C "$WORK" format-patch --quiet --zero-commit --no-signature \
        -o "$PATCH_DIR" "$(pinned_commit)..roomformac"
    ls -1 "$PATCH_DIR"
}

cmd_test() {
    local tree="$WORK"
    if [[ "${1:-}" == "--tree" ]]; then
        [[ $# -ge 2 ]] || die "--tree needs a directory"
        tree="$2"
        shift 2
    fi
    [[ -d "$tree/tests" ]] || die "no patched Mole tree at $tree"
    [[ $# -gt 0 ]] || die "usage: scripts/mole-patches.sh test [--tree DIR] tests/<file>.bats..."
    (cd "$tree" && MOLE_TEST_NO_AUTH=1 bats "$@")
}

cmd_lint() {
    [[ $# -gt 0 ]] || die "usage: scripts/mole-patches.sh lint <file.sh>..."
    (cd "$WORK" && shellcheck -x "$@" && shfmt -d -i 4 -ci -sr "$@")
}

case "${1:-}" in
    start) shift && cmd_start "$@" ;;
    export) shift && cmd_export "$@" ;;
    test) shift && cmd_test "$@" ;;
    lint) shift && cmd_lint "$@" ;;
    *) die "usage: scripts/mole-patches.sh start|export|test|lint" ;;
esac
```

- [ ] **Step 5: Make the scripts executable and keep the patch directory**

```bash
chmod +x scripts/build-engine.sh scripts/mole-patches.sh
mkdir -p patches/mole && touch patches/mole/.gitkeep
```

- [ ] **Step 6: Run the checks to verify they pass**

Run: `bats scripts/tests/build_engine.bats`
Expected: PASS, 5 tests (the first run downloads Go modules and takes a few minutes).

- [ ] **Step 7: Lint and commit**

Run: `shellcheck scripts/build-engine.sh scripts/mole-patches.sh && shfmt -d -i 4 -ci -sr scripts/build-engine.sh scripts/mole-patches.sh`
Expected: no output.

```bash
git add scripts patches/mole/.gitkeep
git commit -m "build: add patched engine build and patch-queue scripts"
```

---
### Task 3: Engine patch 0001 — host helpers (events, selection, no-auth, GUI host)

**Files:**
- Create (Mole, in `build/mole-work`): `lib/core/host.sh`, `tests/host_integration.bats`
- Modify (Mole): `lib/core/common.sh`, `lib/core/sudo.sh`, `lib/core/app_protection.sh` (`force_kill_app`)
- Create (RoomForMac): `docs/engine-protocol.md`, `patches/mole/0001-*.patch`
- Modify (RoomForMac): `scripts/tests/build_engine.bats`

**Interfaces:**
- Consumes: `scripts/mole-patches.sh`, `scripts/build-engine.sh` (Task 2).
- Produces (bash): in `lib/core/host.sh` — `mole_json_escape STR`, `mole_json_str STR`, `mole_json_num N`, `mole_json_bool B`, `mole_json_events_enabled`, `mole_json_emit JSON_LINE`, `mole_selection_active`, `mole_selection_allows PATH`; in `lib/core/sudo.sh` — `mole_auth_disabled`. Honoured variables: `MOLE_JSON_EVENTS_FILE`, `MOLE_SELECTION_FILE`, `MOLE_NO_AUTH`, `MOLE_GUI_HOST`.

- [ ] **Step 1: Create the patch work tree**

Run: `scripts/mole-patches.sh start`
Expected: `Ready: …/build/mole-work (branch roomformac, 0 patches applied)`

- [ ] **Step 2: Write the failing tests** — `build/mole-work/tests/host_integration.bats`

```bash
#!/usr/bin/env bats
# Host integration helpers: JSON events, exact-path selections, no-auth mode,
# and GUI-host app quitting.

load helpers/common

setup_file() {
    mole_test_setup_home host-integration
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    unset MOLE_JSON_EVENTS_FILE MOLE_SELECTION_FILE
}

load_host() {
    # shellcheck source=lib/core/host.sh
    source "$PROJECT_ROOT/lib/core/host.sh"
}

write_selection() {
    local file="$1"
    shift
    printf '%s\0' "$@" > "$file"
}

@test "mole_json_escape escapes quotes, backslashes and control bytes" {
    load_host
    run mole_json_escape $'a"b\\c\nd\te\001f\037g'
    [ "$status" -eq 0 ]
    [ "$output" = 'a\"b\\c\nd\te\u0001f\u001fg' ]
}

@test "mole_json_escape leaves UTF-8 text unchanged" {
    load_host
    run mole_json_escape 'Café Ünïcode 日本'
    [ "$output" = 'Café Ünïcode 日本' ]
}

@test "mole_json_num and mole_json_bool always produce valid JSON" {
    load_host
    [ "$(mole_json_num 2048)" = "2048" ]
    [ "$(mole_json_num 007)" = "7" ]
    [ "$(mole_json_num '')" = "0" ]
    [ "$(mole_json_num 'n/a')" = "0" ]
    [ "$(mole_json_bool true)" = "true" ]
    [ "$(mole_json_bool yes)" = "false" ]
}

@test "mole_json_emit appends one line per event only when a file is set" {
    load_host
    local events="$BATS_TEST_TMPDIR/events.ndjson"
    mole_json_emit '{"v":1,"n":0}'
    [ ! -e "$events" ]
    MOLE_JSON_EVENTS_FILE="$events"
    mole_json_emit '{"v":1,"n":1}'
    mole_json_emit '{"v":1,"n":2}'
    run cat "$events"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = '{"v":1,"n":1}' ]
    [ "${lines[1]}" = '{"v":1,"n":2}' ]
}

@test "without a selection file every path is allowed" {
    load_host
    mole_selection_allows "/anything/at/all"
}

@test "a selection allows exact paths and ignores trailing slashes" {
    load_host
    MOLE_SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    write_selection "$MOLE_SELECTION_FILE" "$HOME/Library/Caches/com.example.a" "$HOME/Library/Caches/com.example.b/"
    mole_selection_allows "$HOME/Library/Caches/com.example.a"
    mole_selection_allows "$HOME/Library/Caches/com.example.a/"
    mole_selection_allows "$HOME/Library/Caches/com.example.b"
    run mole_selection_allows "$HOME/Library/Caches/com.example.c"
    [ "$status" -eq 1 ]
}

@test "a selection never allows the parent or a child of a selected path" {
    load_host
    MOLE_SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    write_selection "$MOLE_SELECTION_FILE" "$HOME/Library/Caches/com.example.a"
    run mole_selection_allows "$HOME/Library/Caches"
    [ "$status" -eq 1 ]
    run mole_selection_allows "$HOME/Library/Caches/com.example.a/child"
    [ "$status" -eq 1 ]
}

@test "a selection matches paths with spaces, quotes and newlines" {
    load_host
    MOLE_SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    local odd=$'/tmp/rfm dir/"quoted"/new\nline'
    write_selection "$MOLE_SELECTION_FILE" "$odd"
    mole_selection_allows "$odd"
    run mole_selection_allows "/tmp/rfm dir"
    [ "$status" -eq 1 ]
}

@test "a missing selection file allows nothing" {
    load_host
    MOLE_SELECTION_FILE="$BATS_TEST_TMPDIR/does-not-exist"
    run mole_selection_allows "$HOME/anything"
    [ "$status" -eq 1 ]
}

@test "selection lookups stay fast for 5000 selected paths" {
    load_host
    MOLE_SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    : > "$MOLE_SELECTION_FILE"
    local i
    for ((i = 0; i < 5000; i++)); do
        printf '%s\0' "$HOME/Library/Caches/com.example.vendor$i/data" >> "$MOLE_SELECTION_FILE"
    done
    local started=$SECONDS
    for ((i = 0; i < 1000; i++)); do
        mole_selection_allows "$HOME/Library/Caches/com.example.other$i/data" || true
    done
    mole_selection_allows "$HOME/Library/Caches/com.example.vendor4999/data"
    [ $((SECONDS - started)) -lt 15 ]
}

@test "MOLE_NO_AUTH refuses every sudo entry point without running sudo" {
    mole_test_fake_command sudo 'printf "%s\n" "$*" >> "$HOME/sudo-calls"; exit 0'
    run env HOME="$HOME" PATH="$PATH" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_NO_AUTH=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
if request_sudo_access "test"; then echo "request: granted"; else echo "request: refused"; fi
if has_sudo_session; then echo "session: yes"; else echo "session: no"; fi
if adopt_sudo_session; then echo "adopt: yes"; else echo "adopt: no"; fi
if ensure_sudo_session "test"; then echo "ensure: yes"; else echo "ensure: no"; fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"request: refused"* ]]
    [[ "$output" == *"session: no"* ]]
    [[ "$output" == *"adopt: no"* ]]
    [[ "$output" == *"ensure: no"* ]]
    [ ! -e "$HOME/sudo-calls" ]
}

@test "MOLE_GUI_HOST skips the AppleScript quit in force_kill_app" {
    local exe="rfmfixture$$"
    local app="$HOME/Applications/RFMFixture.app"
    mkdir -p "$app/Contents/MacOS"
    cp /bin/sleep "$app/Contents/MacOS/$exe"
    cat > "$app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$exe</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.rfmfixture</string>
</dict>
</plist>
PLIST
    # Detach the fixture so launchd reaps it after the kill (no zombie left
    # behind for force_kill_app's pgrep to keep seeing).
    ("$app/Contents/MacOS/$exe" 300 > /dev/null 2>&1 &)
    sleep 0.3
    pgrep -x "$exe" > /dev/null
    mole_test_fake_command osascript 'printf "%s\n" "$*" >> "$HOME/osascript-calls"; exit 0'
    run env HOME="$HOME" PATH="$PATH" PROJECT_ROOT="$PROJECT_ROOT" APP="$app" \
        MOLE_GUI_HOST=roomformac MOLE_NO_AUTH=1 MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
force_kill_app "RFMFixture" "$APP"
EOF
    pkill -x "$exe" 2> /dev/null || true
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/osascript-calls" ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `scripts/mole-patches.sh test tests/host_integration.bats`
Expected: FAIL — `lib/core/host.sh: No such file or directory`, and the no-auth / GUI-host tests fail because `sudo` and `osascript` get called.

- [ ] **Step 4: Create `build/mole-work/lib/core/host.sh`**

```bash
#!/bin/bash
# Mole - Host Integration
# Machine-readable events and exact-path selections for graphical front ends.
#
# Everything here is inert unless a host sets one of:
#   MOLE_JSON_EVENTS_FILE  Append newline-delimited JSON events (schema v1).
#   MOLE_SELECTION_FILE    NUL-separated exact paths. Deletion sinks refuse any
#                          other path; cleanups that run a tool instead of
#                          deleting previewed paths are skipped.
# Related switches live next to the code they change:
#   MOLE_NO_AUTH=1         lib/core/sudo.sh never requests or adopts sudo.
#   MOLE_GUI_HOST=<name>   lib/core/app_protection.sh skips AppleScript quits.

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_HOST_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_HOST_LOADED=1

# ============================================================================
# JSON Encoding
# ============================================================================

# Escape a value for a JSON string literal (without the surrounding quotes).
# Paths may contain quotes, backslashes and control bytes, newlines included.
mole_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    case "$s" in
        *[$'\001'-$'\037']*)
            local out="" ch code i
            for ((i = 0; i < ${#s}; i++)); do
                ch="${s:i:1}"
                case "$ch" in
                    [$'\001'-$'\037'])
                        printf -v code '%d' "'$ch"
                        out+=$(printf '\\u%04x' "$code")
                        ;;
                    *) out+="$ch" ;;
                esac
            done
            s="$out"
            ;;
    esac
    printf '%s' "$s"
}

mole_json_str() {
    printf '"%s"' "$(mole_json_escape "${1-}")"
}

mole_json_num() {
    if [[ "${1-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((10#$1))"
    else
        printf '0'
    fi
}

mole_json_bool() {
    if [[ "${1-}" == "true" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# ============================================================================
# Event Stream
# ============================================================================

mole_json_events_enabled() {
    [[ -n "${MOLE_JSON_EVENTS_FILE:-}" ]]
}

# Append one JSON object as a single line. A write failure never stops a
# cleanup; the host treats a run without a summary event as incomplete.
mole_json_emit() {
    mole_json_events_enabled || return 0
    printf '%s\n' "${1-}" >> "$MOLE_JSON_EVENTS_FILE" 2> /dev/null || true
}

# ============================================================================
# Exact-Path Selection
# ============================================================================

# Loaded lazily from MOLE_SELECTION_FILE. A joined string keeps each lookup a
# single pattern match; entries that contain the separator byte fall back to
# an exact list scan, the same approach the dry-run ledger uses.
_MOLE_SELECTION_LOADED_FROM=""
_MOLE_SELECTION_LOAD_OK=false
_MOLE_SELECTION_JOINED=""
_MOLE_SELECTION_JOINED_USABLE=true
_MOLE_SELECTION_PATHS=()

mole_selection_active() {
    [[ -n "${MOLE_SELECTION_FILE:-}" ]]
}

_mole_selection_load() {
    local file="${MOLE_SELECTION_FILE:-}"
    _MOLE_SELECTION_LOADED_FROM="$file"
    _MOLE_SELECTION_LOAD_OK=false
    _MOLE_SELECTION_PATHS=()
    _MOLE_SELECTION_JOINED=""
    _MOLE_SELECTION_JOINED_USABLE=true
    if [[ -z "$file" || ! -f "$file" || -L "$file" || ! -r "$file" ]]; then
        return 1
    fi
    local sep=$'\x1f' entry
    while IFS= read -r -d '' entry; do
        while [[ ${#entry} -gt 1 && "$entry" == */ ]]; do
            entry="${entry%/}"
        done
        [[ -n "$entry" ]] || continue
        _MOLE_SELECTION_PATHS+=("$entry")
        if [[ "$entry" == *"$sep"* ]]; then
            _MOLE_SELECTION_JOINED_USABLE=false
        fi
        _MOLE_SELECTION_JOINED+="$sep$entry$sep"
    done < "$file"
    _MOLE_SELECTION_LOAD_OK=true
    return 0
}

# Succeeds when no selection is active, or when PATH (ignoring trailing
# slashes) is exactly one of the selected paths. Ancestors and descendants of
# a selected path are not selected. An unreadable selection allows nothing.
mole_selection_allows() {
    if ! mole_selection_active; then
        return 0
    fi
    if [[ "$_MOLE_SELECTION_LOADED_FROM" != "$MOLE_SELECTION_FILE" ]]; then
        _mole_selection_load || true
    fi
    if [[ "$_MOLE_SELECTION_LOAD_OK" != "true" ]]; then
        return 1
    fi
    local candidate="${1:-}"
    while [[ ${#candidate} -gt 1 && "$candidate" == */ ]]; do
        candidate="${candidate%/}"
    done
    if [[ -z "$candidate" ]]; then
        return 1
    fi
    local sep=$'\x1f'
    if [[ "$_MOLE_SELECTION_JOINED_USABLE" == "true" && "$candidate" != *"$sep"* ]]; then
        if [[ "$_MOLE_SELECTION_JOINED" == *"$sep$candidate$sep"* ]]; then
            return 0
        fi
        return 1
    fi
    local entry
    for entry in "${_MOLE_SELECTION_PATHS[@]+"${_MOLE_SELECTION_PATHS[@]}"}"; do
        if [[ "$entry" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}
```

- [ ] **Step 5: Load it from `lib/core/common.sh`**

Find:
```bash
# Load core modules
source "$_MOLE_CORE_DIR/base.sh"
prepare_mole_tmpdir > /dev/null
```
Replace with:
```bash
# Load core modules
source "$_MOLE_CORE_DIR/base.sh"
source "$_MOLE_CORE_DIR/host.sh"
prepare_mole_tmpdir > /dev/null
```

- [ ] **Step 6: Add `mole_auth_disabled` to `lib/core/sudo.sh` and use it at all six auth checks**

Find:
```bash
set -euo pipefail

# ============================================================================
# Touch ID and Clamshell Detection
```
Replace with:
```bash
set -euo pipefail

# Administrator access is off for scripted test runs and for hosts that set
# MOLE_NO_AUTH=1 (a GUI front end that has not been granted admin access).
# Every sudo entry point below checks this first, so no prompt can appear.
mole_auth_disabled() {
    [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" || "${MOLE_NO_AUTH:-0}" == "1" ]]
}

# ============================================================================
# Touch ID and Clamshell Detection
```

Then, inside `build/mole-work`, replace the six identical checks:
```bash
sed -i '' 's/if \[\[ "\${MOLE_TEST_MODE:-0}" == "1" || "\${MOLE_TEST_NO_AUTH:-0}" == "1" \]\]; then/if mole_auth_disabled; then/' lib/core/sudo.sh
grep -c 'if mole_auth_disabled; then' lib/core/sudo.sh
grep -c 'MOLE_TEST_NO_AUTH:-0}" == "1" \]\]; then' lib/core/sudo.sh
```
Expected: `6`, then `0`.

- [ ] **Step 7: Skip the AppleScript quit under a GUI host** — `lib/core/app_protection.sh`, in `force_kill_app`

Find:
```bash
    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]] &&
        command -v osascript > /dev/null 2>&1; then
```
Replace with:
```bash
    # A GUI host (MOLE_GUI_HOST) quits apps through its own API before it runs
    # the uninstall; an AppleScript Quit here would only add a per-app
    # Automation permission prompt on the host's behalf.
    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" && -z "${MOLE_GUI_HOST:-}" ]] &&
        command -v osascript > /dev/null 2>&1; then
```

- [ ] **Step 8: Run the new tests and the neighbouring suites**

Run: `scripts/mole-patches.sh test tests/host_integration.bats tests/manage_sudo.bats tests/core_common.bats tests/core_safe_functions.bats tests/uninstall.bats`
Expected: all PASS.

- [ ] **Step 9: Lint**

Run: `scripts/mole-patches.sh lint lib/core/host.sh lib/core/common.sh lib/core/sudo.sh lib/core/app_protection.sh`
Expected: no output.

- [ ] **Step 10: Commit inside the work tree and export the patch**

```bash
git -C build/mole-work add -A
git -C build/mole-work commit -m "Add host integration helpers for GUI front ends

Adds lib/core/host.sh (JSON events, exact-path selections) and two
switches for GUI hosts: MOLE_NO_AUTH disables every sudo entry point and
MOLE_GUI_HOST skips the AppleScript quit in force_kill_app. All inert
unless the variables are set."
scripts/mole-patches.sh export
```
Expected: `0001-Add-host-integration-helpers-for-GUI-front-ends.patch`

- [ ] **Step 11: Check that the engine ships the helpers** — append to `scripts/tests/build_engine.bats`

```bash
@test "patched engine ships the host integration helpers" {
    [ -f "$ENGINE_OUT/lib/core/host.sh" ]
    grep -q '^mole_selection_allows()' "$ENGINE_OUT/lib/core/host.sh"
    grep -q '^mole_auth_disabled()' "$ENGINE_OUT/lib/core/sudo.sh"
}
```

Run: `bats scripts/tests/build_engine.bats`
Expected: PASS, 6 tests, and `VERSION` shows `patch_count=1`.

- [ ] **Step 12: Start the protocol document** — `docs/engine-protocol.md`

```markdown
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

## JSON conventions

- One object per line, UTF-8, first key `"v":1`. Hosts skip lines they cannot parse and types they do not know.
- Strings escape `"`, `\`, `\n`, `\r`, `\t`, and other control bytes as `\u00XX`.
- Sizes are integer kilobytes (`size_kb`); booleans are JSON booleans.
- A run is complete only when its `summary` event arrived and the process exited 0.
```

- [ ] **Step 13: Commit**

```bash
git add patches/mole scripts/tests/build_engine.bats docs/engine-protocol.md
git commit -m "feat(engine): patch 0001 host helpers, no-auth and GUI-host switches"
```

---
### Task 4: Engine patch 0002 — clean events

**Files:**
- Modify (Mole): `lib/core/host.sh` (event functions), `lib/core/log.sh` (`log_operation`), `lib/core/file_ops.sh` (dependency block, sudo batch loop), `bin/clean.sh` (`start_section`, `append_dry_run_cleanup_target`, `render_clean_preview_from_ledger`, `perform_cleanup`), `lib/clean/system.sh` (Time Machine outcomes)
- Create (Mole): `tests/clean_json_events.bats`
- Modify (RoomForMac): `docs/engine-protocol.md`; create `patches/mole/0002-*.patch`

**Interfaces:**
- Consumes: `mole_json_emit`, `mole_json_str`, `mole_json_num`, `mole_json_bool`, `mole_json_events_enabled` (Task 3).
- Produces (bash, `lib/core/host.sh`): `mole_json_event_section NAME`; `mole_json_event_candidate PATH SIZE_KB SIZE_KNOWN SECTION`; `mole_json_event_item SECTION PATH SIZE_KB COUNT SIZE_KNOWN COVERED_BY`; `mole_json_event_result COMMAND ACTION PATH DETAIL`; `mole_json_event_summary COMMAND DRY_RUN ITEMS SIZE_KB PARTIAL EXIT`. Wire events `section`, `candidate`, `item`, `result`, `summary` (exact shapes in the tests below).

- [ ] **Step 1: Write the failing tests** — `build/mole-work/tests/clean_json_events.bats`

```bash
#!/usr/bin/env bats
# Machine-readable clean events: sections, candidates, deduplicated preview
# items, per-path results and the run summary.

load helpers/common

setup_file() {
    mole_test_setup_home clean-json-events
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/.config" "$HOME/.cache" "$HOME/.tmp"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole" "$HOME/.tmp"
    EVENTS="$BATS_TEST_TMPDIR/events.ndjson"
    : > "$EVENTS"
}

# Same seams as clean_core.bats: no real Homebrew, Xcode, process table or
# open-file probe may influence what the pipeline sees.
set_mock_host_toolchains() {
    MOCK_TOOLCHAIN_BIN="$HOME/toolchain-bin"
    mkdir -p "$MOCK_TOOLCHAIN_BIN"
    cat > "$MOCK_TOOLCHAIN_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/xcrun" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/lsof" << 'MOCK'
#!/bin/bash
case " $* " in
    *" -p 1 "*) printf 'p1\nu0\n'; exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/ps" << 'MOCK'
#!/bin/bash
printf '  PID  PPID COMM ARGS\n'
MOCK
    chmod +x "$MOCK_TOOLCHAIN_BIN"/*
}

@test "item events carry section, path, size, count and coverage" {
    run env EVENTS="$EVENTS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/host.sh"
MOLE_JSON_EVENTS_FILE="$EVENTS"
mole_json_event_item "User essentials" '/Users/x/Library/Caches/A "quoted"' 2048 3 true ""
mole_json_event_item "Dev tools" "/Users/x/Library/Caches/A/v6" 10 1 false "/Users/x/Library/Caches/A"
EOF
    [ "$status" -eq 0 ]
    run cat "$EVENTS"
    [ "${lines[0]}" = '{"v":1,"type":"item","section":"User essentials","path":"/Users/x/Library/Caches/A \"quoted\"","size_kb":2048,"count":3,"size_known":true,"covered_by":null}' ]
    [ "${lines[1]}" = '{"v":1,"type":"item","section":"Dev tools","path":"/Users/x/Library/Caches/A/v6","size_kb":10,"count":1,"size_known":false,"covered_by":"/Users/x/Library/Caches/A"}' ]
}

@test "section, candidate and summary events have a fixed shape" {
    run env EVENTS="$EVENTS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/host.sh"
MOLE_JSON_EVENTS_FILE="$EVENTS"
mole_json_event_section "User essentials"
mole_json_event_candidate "/Users/x/Library/Caches/A" 12 true "User essentials"
mole_json_event_summary "clean" true 3 4096 false 0
EOF
    [ "$status" -eq 0 ]
    run cat "$EVENTS"
    [ "${lines[0]}" = '{"v":1,"type":"section","name":"User essentials"}' ]
    [ "${lines[1]}" = '{"v":1,"type":"candidate","section":"User essentials","path":"/Users/x/Library/Caches/A","size_kb":12,"size_known":true}' ]
    [ "${lines[2]}" = '{"v":1,"type":"summary","command":"clean","dry_run":true,"items":3,"size_kb":4096,"partial":false,"exit":0}' ]
}

@test "log_operation mirrors outcomes as result events outside dry runs" {
    run env HOME="$HOME" EVENTS="$EVENTS" PROJECT_ROOT="$PROJECT_ROOT" MO_NO_OPLOG=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_JSON_EVENTS_FILE="$EVENTS"
log_operation "clean" "REMOVED" "/tmp/rfm/a" "1MB"
log_operation "clean" "FAILED" "/tmp/rfm/b" "permission denied"
log_operation "clean" "REBUILT" "/tmp/rfm/c" ""
MOLE_DRY_RUN=1 log_operation "clean" "SKIPPED" "/tmp/rfm/d" "dry-run stub-container"
EOF
    [ "$status" -eq 0 ]
    run cat "$EVENTS"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = '{"v":1,"type":"result","command":"clean","action":"removed","path":"/tmp/rfm/a","detail":"1MB"}' ]
    [ "${lines[1]}" = '{"v":1,"type":"result","command":"clean","action":"failed","path":"/tmp/rfm/b","detail":"permission denied"}' ]
}

@test "clean --dry-run streams sections, items and a summary for a fake home" {
    command -v jq > /dev/null || skip "jq is required"
    mkdir -p "$HOME/Library/Caches/com.example.alpha"
    dd if=/dev/zero of="$HOME/Library/Caches/com.example.alpha/blob.bin" bs=1024 count=2048 2> /dev/null
    set_mock_host_toolchains

    run env HOME="$HOME" TMPDIR="$HOME/.tmp" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_NO_AUTH=1 \
        MOLE_GUI_HOST=roomformac MOLE_LSREGISTER_PATH="" MOLE_JSON_EVENTS_FILE="$EVENTS" \
        PATH="$MOCK_TOOLCHAIN_BIN:$PATH" "$PROJECT_ROOT/bin/clean.sh" --dry-run
    [ "$status" -eq 0 ]

    # Every line is valid JSON with schema version 1.
    run jq -c 'select(.v != 1)' "$EVENTS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run jq -r 'select(.type == "section") | .name' "$EVENTS"
    [ -n "$output" ]
    run jq -r 'select(.type == "candidate") | .path' "$EVENTS"
    [ -n "$output" ]

    local alpha="$HOME/Library/Caches/com.example.alpha"
    run jq -s --arg p "$alpha" '[.[] | select(.type == "item" and (.path == $p or (.path | startswith($p + "/")))) | .size_kb] | add // 0' "$EVENTS"
    [ "$output" -ge 2048 ]

    run jq -r 'select(.type == "summary") | [.command, .dry_run, (.size_kb >= 2048)] | @tsv' "$EVENTS"
    [ "$output" = $'clean\ttrue\ttrue' ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/mole-patches.sh test tests/clean_json_events.bats`
Expected: FAIL — `mole_json_event_item: command not found`, no result lines, no events from the pipeline.

- [ ] **Step 3: Add the clean event functions** — append to `lib/core/host.sh`

```bash

# ============================================================================
# Clean Events
# ============================================================================

mole_json_event_section() {
    mole_json_events_enabled || return 0
    mole_json_emit "{\"v\":1,\"type\":\"section\",\"name\":$(mole_json_str "${1-}")}"
}

# Live dry-run progress. May repeat or overlap; the final item events are
# the authoritative preview. Args: path, size_kb, size_known, section
mole_json_event_candidate() {
    mole_json_events_enabled || return 0
    mole_json_emit "{\"v\":1,\"type\":\"candidate\",\"section\":$(mole_json_str "${4-}"),\"path\":$(mole_json_str "${1-}"),\"size_kb\":$(mole_json_num "${2-}"),\"size_known\":$(mole_json_bool "${3-}")}"
}

# One deduplicated preview row. covered_by names the nearest previewed
# ancestor whose size already includes this row, or is empty.
# Args: section, path, size_kb, count, size_known, covered_by
mole_json_event_item() {
    mole_json_events_enabled || return 0
    local covered_by="null"
    if [[ -n "${6-}" ]]; then
        covered_by=$(mole_json_str "$6")
    fi
    mole_json_emit "{\"v\":1,\"type\":\"item\",\"section\":$(mole_json_str "${1-}"),\"path\":$(mole_json_str "${2-}"),\"size_kb\":$(mole_json_num "${3-}"),\"count\":$(mole_json_num "${4-}"),\"size_known\":$(mole_json_bool "${5-}"),\"covered_by\":$covered_by}"
}

# Mirror of log_operation: one outcome for one path. Dry runs only preview,
# so they never report outcomes.
# Args: command, action (REMOVED/SKIPPED/FAILED), path, detail
mole_json_event_result() {
    mole_json_events_enabled || return 0
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    local action=""
    case "${2-}" in
        REMOVED) action="removed" ;;
        SKIPPED) action="skipped" ;;
        FAILED) action="failed" ;;
        *) return 0 ;;
    esac
    mole_json_emit "{\"v\":1,\"type\":\"result\",\"command\":$(mole_json_str "${1-}"),\"action\":\"$action\",\"path\":$(mole_json_str "${3-}"),\"detail\":$(mole_json_str "${4-}")}"
}

# Args: command, dry_run (true/false), items, size_kb, partial (true/false), exit
mole_json_event_summary() {
    mole_json_events_enabled || return 0
    mole_json_emit "{\"v\":1,\"type\":\"summary\",\"command\":$(mole_json_str "${1-}"),\"dry_run\":$(mole_json_bool "${2-}"),\"items\":$(mole_json_num "${3-}"),\"size_kb\":$(mole_json_num "${4-}"),\"partial\":$(mole_json_bool "${5-}"),\"exit\":$(mole_json_num "${6-}")}"
}
```

- [ ] **Step 4: Mirror `log_operation` into the event stream** — `lib/core/log.sh`

Find:
```bash
# Ensure base.sh is loaded for colors and icons
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    _MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
```
Replace with:
```bash
# Ensure base.sh is loaded for colors and icons
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    _MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi

# log_operation mirrors outcomes into the host event stream.
if [[ -z "${MOLE_HOST_LOADED:-}" ]]; then
    # shellcheck source=lib/core/host.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host.sh"
fi
```

Find:
```bash
log_operation() {
    # Allow disabling via environment variable
    oplog_enabled || return 0
```
Replace with:
```bash
log_operation() {
    # A host needs per-item outcomes even when the operations log is off.
    mole_json_event_result "${1:-unknown}" "${2:-UNKNOWN}" "${3:-}" "${4:-}"

    # Allow disabling via environment variable
    oplog_enabled || return 0
```

- [ ] **Step 5: Report batched admin removals** — `lib/core/file_ops.sh`

Find:
```bash
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_CORE_DIR/timeouts.sh"
fi
```
Replace with:
```bash
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_CORE_DIR/timeouts.sh"
fi
if [[ -z "${MOLE_HOST_LOADED:-}" ]]; then
    # shellcheck source=lib/core/host.sh
    source "$_MOLE_CORE_DIR/host.sh"
fi
```

Find (in `safe_sudo_find_delete`):
```bash
            while IFS= read -r -d '' batch_file; do
                batch_ack_count=$((batch_ack_count + 1))
                if [[ -n "$batch_ts" ]]; then
                    removed_lines+=("[$batch_ts] [${MOLE_CURRENT_COMMAND:-clean}] REMOVED $batch_file (batch)")
                fi
            done < "$batch_result_file"
```
Replace with:
```bash
            while IFS= read -r -d '' batch_file; do
                batch_ack_count=$((batch_ack_count + 1))
                if [[ -n "$batch_ts" ]]; then
                    removed_lines+=("[$batch_ts] [${MOLE_CURRENT_COMMAND:-clean}] REMOVED $batch_file (batch)")
                fi
                # Batch removals bypass log_operation; report each one directly.
                mole_json_event_result "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$batch_file" "batch"
            done < "$batch_result_file"
```

- [ ] **Step 6: Emit sections, candidates, items and the summary** — `bin/clean.sh`

Find:
```bash
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
```
Replace with:
```bash
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    mole_json_event_section "$1"
```

Find (in `append_dry_run_cleanup_target`):
```bash
    [[ "$size_known" == "true" || "$size_known" == "false" ]] || size_known=false

    if [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" && ! -L "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
```
Replace with:
```bash
    [[ "$size_known" == "true" || "$size_known" == "false" ]] || size_known=false

    # Live progress for hosts. The ledger stays authoritative: it is
    # deduplicated and annotated with coverage before the final item events.
    mole_json_event_candidate "$path" "$size_kb" "$size_known" "${CURRENT_SECTION:-Uncategorized}"

    if [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" && ! -L "$CLEAN_PREVIEW_LEDGER_FILE" ]]; then
```

Find (in `render_clean_preview_from_ledger`):
```bash
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
            local item_note=""
```
Replace with:
```bash
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
            mole_json_event_item "$section" "$path" "$size_kb" "$count" "$size_known" "$covered_by"
            local item_note=""
```

Find (end of `perform_cleanup`):
```bash
    # Log session end with summary
    log_operation_session_end "clean" "$files_cleaned" "$total_size_cleaned"
```
Replace with:
```bash
    mole_json_event_summary "clean" "$DRY_RUN" "$files_cleaned" "$total_size_cleaned" \
        "${DRY_RUN_TOTAL_PARTIAL:-false}" "$cleanup_cancel_rc"

    # Log session end with summary
    log_operation_session_end "clean" "$files_cleaned" "$total_size_cleaned"
```

- [ ] **Step 7: Log Time Machine outcomes so they reach the stream** — `lib/clean/system.sh`, `clean_time_machine_failed_backups`

Immediately after each of these two success lines, add a `log_operation … REMOVED` line at the same indentation:
```bash
                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name${NC} · ${line_color}$size_human${NC}"
                    log_operation "clean" "REMOVED" "$inprogress_file" "$size_human"
```
```bash
                        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC} · ${line_color}$size_human${NC}"
                        log_operation "clean" "REMOVED" "$inprogress_file" "$size_human"
```
Immediately after each of these two failure lines, add a `log_operation … FAILED` line:
```bash
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name · try manually with sudo"
                    log_operation "clean" "FAILED" "$inprogress_file" "tmutil delete"
```
```bash
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                        log_operation "clean" "FAILED" "$inprogress_file" "tmutil delete"
```
Verify: `grep -c 'log_operation "clean" "\(REMOVED\|FAILED\)" "$inprogress_file"' lib/clean/system.sh` → `4`. (These paths need admin access, so they stay dormant until Plan 7.)

- [ ] **Step 8: Run the new tests and neighbouring suites**

Run: `scripts/mole-patches.sh test tests/clean_json_events.bats tests/host_integration.bats tests/clean_core.bats tests/clean_system_maintenance.bats tests/file_ops_mole_delete.bats tests/history.bats`
Expected: all PASS.

- [ ] **Step 9: Lint**

Run: `scripts/mole-patches.sh lint lib/core/host.sh lib/core/log.sh lib/core/file_ops.sh bin/clean.sh lib/clean/system.sh`
Expected: no output.

- [ ] **Step 10: Commit inside the work tree, export, rebuild**

```bash
git -C build/mole-work add -A
git -C build/mole-work commit -m "Stream machine-readable clean events for GUI hosts

With MOLE_JSON_EVENTS_FILE set, clean appends one JSON object per line:
section and candidate progress, the deduplicated preview items (with the
covering ancestor), per-path results mirrored from log_operation, and a
run summary."
scripts/mole-patches.sh export
bats scripts/tests/build_engine.bats
```
Expected: two patch files listed; build checks PASS with `patch_count=2`.

- [ ] **Step 11: Document the clean events** — append to `docs/engine-protocol.md`

```markdown

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
```

- [ ] **Step 12: Commit**

```bash
git add patches/mole docs/engine-protocol.md
git commit -m "feat(engine): patch 0002 machine-readable clean events"
```

---
### Task 5: Engine patch 0003 — exact-path selections for clean

**Files:**
- Modify (Mole): `lib/core/file_ops.sh` (`safe_remove`, `safe_remove_symlink`, `safe_sudo_remove`, `safe_sudo_find_delete`), `bin/clean.sh` (`append_dry_run_cleanup_target`, `record_dry_run_cleanup_target`), `lib/clean/apps.sh` (`_remove_verified_container_stub`), `lib/clean/dev.sh` (`clean_tool_cache`, bun cache, `clean_go_cache_root`, automation browsers, unavailable simulators), `lib/clean/brew.sh` (`clean_homebrew`), `lib/clean/system.sh` (Time Machine)
- Create (Mole): `tests/clean_selection.bats`
- Modify (RoomForMac): `docs/engine-protocol.md`; create `patches/mole/0003-*.patch`

**Interfaces:**
- Consumes: `mole_selection_active`, `mole_selection_allows` (Task 3); `result` events via `log_operation` (Task 4).
- Produces: `bin/clean.sh` honours `MOLE_SELECTION_FILE` in real runs (removes only listed paths) and dry runs (previews only listed paths, i.e. fresh sizes for a selection). New helper `_clean_selected_unavailable_simulators UDID…` in `lib/clean/dev.sh`.

**Why every sink:** Mole's clean modules call `safe_remove`, `safe_sudo_remove`, `safe_find_delete` (→ `safe_remove`) and friends directly in dozens of places, and several modules wrap them in process-state guards (running browsers, dev tools, Claude/Codex apps) that must keep working. So the selection is enforced at the deletion sinks, inside the normal clean run, the same way Mole already enforces the user whitelist at `safe_remove` (#710). Cleanups that run a tool instead of deleting a previewed path cannot be scoped and are skipped.

- [ ] **Step 1: Write the failing tests** — `build/mole-work/tests/clean_selection.bats`

```bash
#!/usr/bin/env bats
# Exact-path selections: clean deletion sinks, the dry-run recorder and
# tool-driven cleanups all honour MOLE_SELECTION_FILE.

load helpers/common

setup_file() {
    mole_test_setup_home clean-selection
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/.config" "$HOME/.cache" "$HOME/.tmp"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole" "$HOME/.tmp"
    EVENTS="$BATS_TEST_TMPDIR/events.ndjson"
    SELECTION_FILE=""
    : > "$EVENTS"
}

# Same seams as clean_core.bats: no real Homebrew, Xcode, process table or
# open-file probe may influence what the pipeline sees.
set_mock_host_toolchains() {
    MOCK_TOOLCHAIN_BIN="$HOME/toolchain-bin"
    mkdir -p "$MOCK_TOOLCHAIN_BIN"
    cat > "$MOCK_TOOLCHAIN_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/xcrun" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/lsof" << 'MOCK'
#!/bin/bash
case " $* " in
    *" -p 1 "*) printf 'p1\nu0\n'; exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    cat > "$MOCK_TOOLCHAIN_BIN/ps" << 'MOCK'
#!/bin/bash
printf '  PID  PPID COMM ARGS\n'
MOCK
    chmod +x "$MOCK_TOOLCHAIN_BIN"/*
}

# Test-only guard: any rm aimed outside the fake HOME is refused and logged.
install_rm_guard() {
    RM_GUARD_BIN="$BATS_TEST_TMPDIR/rm-guard-bin"
    RM_GUARD_LOG="$BATS_TEST_TMPDIR/rm-refused.log"
    mkdir -p "$RM_GUARD_BIN"
    : > "$RM_GUARD_LOG"
    cat > "$RM_GUARD_BIN/rm" << GUARD
#!/bin/bash
for arg in "\$@"; do
    case "\$arg" in
        -*) ;;
        "$HOME"/*) ;;
        *)
            printf '%s\n' "\$arg" >> "$RM_GUARD_LOG"
            exit 1
            ;;
    esac
done
exec /bin/rm "\$@"
GUARD
    chmod +x "$RM_GUARD_BIN/rm"
}

run_clean_json() {
    local -a vars=(
        HOME="$HOME" TMPDIR="$HOME/.tmp" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_NO_AUTH=1
        MOLE_GUI_HOST=roomformac MOLE_LSREGISTER_PATH="" MOLE_JSON_EVENTS_FILE="$EVENTS"
        PATH="$RM_GUARD_BIN:$MOCK_TOOLCHAIN_BIN:$PATH"
    )
    if [[ -n "$SELECTION_FILE" ]]; then
        vars+=(MOLE_SELECTION_FILE="$SELECTION_FILE")
    fi
    run env "${vars[@]}" "$PROJECT_ROOT/bin/clean.sh" "$@"
}

make_cache() {
    mkdir -p "$HOME/Library/Caches/$1"
    dd if=/dev/zero of="$HOME/Library/Caches/$1/blob.bin" bs=1024 count="$2" 2> /dev/null
}

@test "safe_remove refuses paths outside the selection and removes selected ones" {
    mkdir -p "$HOME/sel/keep" "$HOME/sel/drop"
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/sel/drop" > "$SELECTION_FILE"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_NO_OPLOG=1 \
        MOLE_SELECTION_FILE="$SELECTION_FILE" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
if safe_remove "$HOME/sel/keep" true; then echo "keep: removed"; else echo "keep: refused"; fi
if safe_remove "$HOME/sel/drop" true; then echo "drop: removed"; else echo "drop: refused"; fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep: refused"* ]]
    [[ "$output" == *"drop: removed"* ]]
    [ -d "$HOME/sel/keep" ]
    [ ! -e "$HOME/sel/drop" ]
}

@test "the dry-run recorder lists only selected paths" {
    mkdir -p "$HOME/sel/a" "$HOME/sel/b"
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/sel/a" > "$SELECTION_FILE"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MO_NO_OPLOG=1 \
        MOLE_SELECTION_FILE="$SELECTION_FILE" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
EXPORT_LIST_FILE="$HOME/preview.txt"
if record_dry_run_cleanup_target "$HOME/sel/b" 4 1 true; then echo "b: listed"; else echo "b: skipped"; fi
if append_dry_run_cleanup_target "$HOME/sel/b" 4 1 true; then echo "b direct: listed"; else echo "b direct: skipped"; fi
if record_dry_run_cleanup_target "$HOME/sel/a" 4 1 true; then echo "a: listed"; else echo "a: skipped"; fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"b: skipped"* ]]
    [[ "$output" == *"b direct: skipped"* ]]
    [[ "$output" == *"a: listed"* ]]
}

@test "tool-driven cache cleanups never run under a selection" {
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/unrelated" > "$SELECTION_FILE"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MO_NO_OPLOG=1 \
        SELECTION="$SELECTION_FILE" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
mark_tool_ran() { : > "$HOME/tool-ran-$1"; }
clean_tool_cache "Example cache" "$HOME/example-cache" mark_tool_ran without-selection
MOLE_SELECTION_FILE="$SELECTION" clean_tool_cache "Example cache" "$HOME/example-cache" mark_tool_ran with-selection
EOF
    [ "$status" -eq 0 ]
    [ -e "$HOME/tool-ran-without-selection" ]
    [ ! -e "$HOME/tool-ran-with-selection" ]
}

@test "the stub-container remover refuses containers outside the selection" {
    local container="$HOME/Library/Containers/com.example.stub"
    mkdir -p "$container"
    : > "$container/.com.apple.containermanagerd.metadata.plist"
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/Library/Containers/com.example.other" > "$SELECTION_FILE"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MO_NO_OPLOG=1 \
        MOLE_SELECTION_FILE="$SELECTION_FILE" CONTAINER="$container" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
if _remove_verified_container_stub "$CONTAINER" "$CONTAINER/.com.apple.containermanagerd.metadata.plist"; then
    echo removed
else
    echo refused
fi
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "refused" ]
    [ -f "$container/.com.apple.containermanagerd.metadata.plist" ]
}

@test "Homebrew cleanup is skipped under a selection" {
    mole_test_fake_command brew 'printf "%s\n" "$*" >> "$HOME/brew-calls"; exit 0'
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/unrelated" > "$SELECTION_FILE"
    run env HOME="$HOME" PATH="$PATH" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MO_NO_OPLOG=1 \
        MOLE_SELECTION_FILE="$SELECTION_FILE" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
clean_homebrew
EOF
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/brew-calls" ]
}

@test "a selected dry run previews only the selected paths" {
    command -v jq > /dev/null || skip "jq is required"
    make_cache com.example.alpha 64
    make_cache com.example.beta 64
    set_mock_host_toolchains
    install_rm_guard
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/Library/Caches/com.example.alpha" > "$SELECTION_FILE"

    run_clean_json --dry-run
    [ "$status" -eq 0 ]
    run jq -r 'select(.type == "item") | .path' "$EVENTS"
    [ "$output" = "$HOME/Library/Caches/com.example.alpha" ]
}

@test "a selected run removes exactly the selected preview items" {
    command -v jq > /dev/null || skip "jq is required"
    local caches="$HOME/Library/Caches"
    make_cache com.example.alpha 256
    make_cache com.example.beta 256
    make_cache com.example.gamma 256
    set_mock_host_toolchains
    install_rm_guard

    run_clean_json --dry-run
    [ "$status" -eq 0 ]
    local preview="$BATS_TEST_TMPDIR/preview.txt"
    jq -r 'select(.type == "item") | .path' "$EVENTS" > "$preview"
    grep -qxF "$caches/com.example.alpha" "$preview"
    grep -qxF "$caches/com.example.beta" "$preview"
    grep -qxF "$caches/com.example.gamma" "$preview"

    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$caches/com.example.alpha" "$caches/com.example.gamma" > "$SELECTION_FILE"
    : > "$EVENTS"
    run_clean_json
    [ "$status" -eq 0 ]

    [ ! -e "$caches/com.example.alpha" ]
    [ ! -e "$caches/com.example.gamma" ]
    [ -f "$caches/com.example.beta/blob.bin" ]

    # Nothing else from the preview disappeared (Mole's own scratch aside).
    local path
    while IFS= read -r path; do
        case "$path" in
            "$caches/com.example.alpha" | "$caches/com.example.gamma") continue ;;
            "$HOME/.tmp"/* | "$HOME/.cache/mole"* | "$HOME/Library/Logs/mole"*) continue ;;
        esac
        [ -e "$path" ] || {
            echo "unexpectedly removed: $path"
            return 1
        }
    done < "$preview"

    run jq -r 'select(.type == "result" and .action == "removed") | .path' "$EVENTS"
    [[ "$output" == *"$caches/com.example.alpha"* ]]
    [[ "$output" == *"$caches/com.example.gamma"* ]]
    [[ "$output" != *"$caches/com.example.beta"* ]]
    [ ! -s "$RM_GUARD_LOG" ]
}

@test "a selected item that vanishes before the run is never reported as removed" {
    command -v jq > /dev/null || skip "jq is required"
    make_cache com.example.alpha 64
    set_mock_host_toolchains
    install_rm_guard
    SELECTION_FILE="$BATS_TEST_TMPDIR/selection"
    printf '%s\0' "$HOME/Library/Caches/com.example.alpha" > "$SELECTION_FILE"
    rm -rf "$HOME/Library/Caches/com.example.alpha"

    run_clean_json
    [ "$status" -eq 0 ]
    run jq -r 'select(.type == "result" and .action == "removed") | .path' "$EVENTS"
    [ -z "$output" ]
    [ ! -s "$RM_GUARD_LOG" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/mole-patches.sh test tests/clean_selection.bats`
Expected: FAIL — unselected paths get removed or listed, the tool marker and `brew-calls` appear, and the selected run removes `com.example.beta` too. (The "vanishes" test may already pass; it pins existing behaviour.)

**Do not run a selected real clean against your real home at any point.** Every real run in this plan uses a fake `HOME` plus the `rm` guard.

- [ ] **Step 3: Gate the four core deletion sinks** — `lib/core/file_ops.sh`

In `safe_remove`, find:
```bash
    local exact_probe_target_id=""

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi
```
Replace with:
```bash
    local exact_probe_target_id=""

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    # A host selection names the exact previewed paths the user approved.
    # Refuse everything else before any probe or removal, and quietly: the
    # host only reports outcomes for paths it selected.
    if ! mole_selection_allows "$path"; then
        return 1
    fi
```

In `safe_remove_symlink`, find:
```bash
    local expected_target_id="${5:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if [[ ! -L "$path" ]]; then
```
Replace with:
```bash
    local expected_target_id="${5:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if ! mole_selection_allows "$path"; then
        return 1
    fi

    if [[ ! -L "$path" ]]; then
```

In `safe_sudo_remove`, find:
```bash
    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if ! validate_path_for_deletion "$path"; then
```
Replace with:
```bash
    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if ! mole_selection_allows "$path"; then
        return 1
    fi

    if ! validate_path_for_deletion "$path"; then
```

In `safe_sudo_find_delete`, find:
```bash
    while IFS= read -r -d '' match; do
        if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
```
Replace with:
```bash
    while IFS= read -r -d '' match; do
        if ! mole_selection_allows "$match"; then
            continue
        fi
        if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
```
(`safe_find_delete` needs no gate: it removes every match through `safe_remove`.)

- [ ] **Step 4: Gate the dry-run recorder** — `bin/clean.sh`

Find:
```bash
append_dry_run_cleanup_target() {
    local path="$1"
    local size_kb="${2:-0}"
    local item_count="${3:-1}"
    local size_known="${4:-true}"
```
Replace with:
```bash
append_dry_run_cleanup_target() {
    local path="$1"
    local size_kb="${2:-0}"
    local item_count="${3:-1}"
    local size_known="${4:-true}"
    if ! mole_selection_allows "$path"; then
        return 1
    fi
```

Find:
```bash
record_dry_run_cleanup_target() {
    local path="$1"
    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi
```
Replace with:
```bash
record_dry_run_cleanup_target() {
    local path="$1"
    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi
    # With a host selection, a dry run re-measures only the selected paths.
    if ! mole_selection_allows "$path"; then
        return 1
    fi
```

- [ ] **Step 5: Gate the stub-container remover** — `lib/clean/apps.sh`

Find:
```bash
_remove_verified_container_stub() {
    local container_dir="$1"
    local metadata_plist="$2"

    [[ -d "$container_dir" ]] || return 1
```
Replace with:
```bash
_remove_verified_container_stub() {
    local container_dir="$1"
    local metadata_plist="$2"

    mole_selection_allows "$container_dir" || return 1
    [[ -d "$container_dir" ]] || return 1
```

- [ ] **Step 6: Skip tool-driven cleanups under a selection** — `lib/clean/dev.sh` and `lib/clean/brew.sh`

`lib/clean/dev.sh`, find:
```bash
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2
```
Replace with:
```bash
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2

    # The tool decides what it deletes, so no previewed path can scope it.
    # A host selection therefore never runs tool-driven cache cleanups.
    if mole_selection_active; then
        return 0
    fi
```

Find:
```bash
        elif [[ "$bun_dry_run" != "true" ]]; then
            if [[ -t 1 ]]; then
                start_section_spinner "Cleaning bun cache..."
            fi
```
Replace with:
```bash
        elif [[ "$bun_dry_run" != "true" ]] && mole_selection_active; then
            # `bun pm cache rm` has no per-path preview; never run it under a
            # host selection.
            bun_cache_cleaned=true
        elif [[ "$bun_dry_run" != "true" ]]; then
            if [[ -t 1 ]]; then
                start_section_spinner "Cleaning bun cache..."
            fi
```

Find:
```bash
clean_go_cache_root() {
    local cache_root="$1"
    local cache_kind="$2"
    local clean_flag="$3"
    local display_name="$4"
    [[ -e "$cache_root" || -L "$cache_root" ]] || return 0
```
Replace with:
```bash
clean_go_cache_root() {
    local cache_root="$1"
    local cache_kind="$2"
    local clean_flag="$3"
    local display_name="$4"
    [[ -e "$cache_root" || -L "$cache_root" ]] || return 0
    # `go clean` is tool-driven and never previewed as a path.
    if [[ "$DRY_RUN" != "true" ]] && mole_selection_active; then
        return 0
    fi
```

Find (in `clean_dev_automation_browsers`):
```bash
    if [[ ${#leaked_processes[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
```
Replace with:
```bash
    # Stopping processes is not a previewed path; a host selection skips it.
    if [[ ${#leaked_processes[@]} -gt 0 ]] && ! mole_selection_active; then
        if [[ "$DRY_RUN" == "true" ]]; then
```

`lib/clean/brew.sh`, find:
```bash
clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0
```
Replace with:
```bash
clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0
    # brew cleanup and autoremove choose their own targets; a host selection
    # can only scope previewed paths, so it skips Homebrew entirely.
    if mole_selection_active; then
        return 0
    fi
```

- [ ] **Step 7: Delete selected unavailable simulators one by one** — `lib/clean/dev.sh`

Insert this helper immediately above the line `clean_dev_mobile() {`:
```bash
# Host selections list unavailable simulator devices one folder at a time.
# `simctl delete unavailable` would also remove devices the user did not
# select, so delete exactly the selected ones through simctl, one by one.
_clean_selected_unavailable_simulators() {
    local udid device_path delete_rc
    for udid in "$@"; do
        device_path="$HOME/Library/Developer/CoreSimulator/Devices/$udid"
        mole_selection_allows "$device_path" || continue
        delete_rc=0
        _run_simctl "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" delete "$udid" > /dev/null 2>&1 || delete_rc=$?
        if [[ $delete_rc -eq 0 ]]; then
            log_operation "clean" "REMOVED" "$device_path" "simulator"
            note_activity
        elif [[ $delete_rc -ge 128 ]]; then
            return "$delete_rc"
        else
            log_operation "clean" "FAILED" "$device_path" "simctl delete (status $delete_rc)"
        fi
    done
    return 0
}
```

Find (in `clean_dev_mobile`):
```bash
                else
                    # Skip if no unavailable simulators
                    if ((unavailable_before == 0)); then
```
Replace with:
```bash
                elif mole_selection_active; then
                    _clean_selected_unavailable_simulators "${unavailable_udids[@]+"${unavailable_udids[@]}"}"
                else
                    # Skip if no unavailable simulators
                    if ((unavailable_before == 0)); then
```

- [ ] **Step 8: Gate Time Machine deletions per file** — `lib/clean/system.sh`

Find (first block, 16-space indent):
```bash
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} Incomplete backup: $backup_name · skipped (tmutil unavailable)"
```
Replace with:
```bash
                if ! mole_selection_allows "$inprogress_file"; then
                    continue
                fi
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} Incomplete backup: $backup_name · skipped (tmutil unavailable)"
```

Find (second block, 20-space indent):
```bash
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
```
Replace with:
```bash
                    if ! mole_selection_allows "$inprogress_file"; then
                        continue
                    fi
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
```
Verify: `grep -c 'mole_selection_allows "$inprogress_file"' lib/clean/system.sh` → `2`.

- [ ] **Step 9: Audit that no deletion path was missed**

Run inside `build/mole-work`:
```bash
grep -nE 'mole_selection_(allows|active)' lib/core/file_ops.sh bin/clean.sh lib/clean/*.sh | wc -l
grep -nE '(^|[^_a-z])(rm -[a-zA-Z]*[rf]|/bin/rm |rmdir|find .* -delete|-exec rm|tmutil delete|simctl .*delete|brew (cleanup|autoremove)|kill -(TERM|9))' lib/clean/*.sh bin/clean.sh | grep -vE 'SAFE: exact|temp_file|tmp_file|scan_file|_tmp"|_stage"|pending_file|processed_file|matches_file|output_file|du_tmp|mktemp|dry-run|echo -e|debug_log|#'
```
Expected: the first count is `16`. Every line printed by the second command is one of: `_remove_verified_container_stub` (gated, Step 5), `clean_homebrew` (gated), `bun pm cache rm` (gated), the two `tmutil delete` lines (gated), `simctl … delete` (gated), or `clean_dev_automation_browsers` kills (gated). Anything else is a new deletion path — gate it with `mole_selection_allows` (path-based) or `mole_selection_active` (tool-driven) before continuing.

- [ ] **Step 10: Run the tests and neighbouring suites**

Run: `scripts/mole-patches.sh test tests/clean_selection.bats tests/clean_json_events.bats tests/host_integration.bats tests/clean_core.bats tests/clean_dev_caches.bats tests/clean_apps.bats tests/clean_user_core.bats tests/core_safe_functions.bats tests/file_ops_safe_remove_symlink.bats`
Expected: all PASS.

- [ ] **Step 11: Lint**

Run: `scripts/mole-patches.sh lint lib/core/file_ops.sh bin/clean.sh lib/clean/apps.sh lib/clean/dev.sh lib/clean/brew.sh lib/clean/system.sh`
Expected: no output.

- [ ] **Step 12: Commit inside the work tree, export, rebuild**

```bash
git -C build/mole-work add -A
git -C build/mole-work commit -m "Honour exact-path host selections in clean

With MOLE_SELECTION_FILE set, every clean deletion sink removes only the
listed paths, dry runs preview only them, cleanups driven by an external
tool (Homebrew, package-manager caches, go clean, leaked automation
browsers) are skipped, and unavailable simulators are deleted one by one
through simctl."
scripts/mole-patches.sh export
bats scripts/tests/build_engine.bats
```
Expected: three patch files; build checks PASS with `patch_count=3`.

- [ ] **Step 13: Document selections** — append to `docs/engine-protocol.md`

```markdown

## Selections (`MOLE_SELECTION_FILE`, patch 0003)

- The file lists absolute paths separated by NUL bytes, exactly as the preview's `item.path` reported them. Trailing slashes are ignored; parents and children of a listed path are **not** selected.
- Real runs remove only listed paths. Dry runs preview only listed paths, which gives fresh sizes for a selection just before cleaning.
- Cleanups driven by an external tool never run under a selection: Homebrew cleanup/autoremove, npm/pip/uv/corepack/conda caches (`clean_tool_cache`), `bun pm cache rm`, `go clean`, and stopping leaked automation browsers. Unavailable simulators are deleted one by one with `simctl delete <udid>`.
- A selection file that is missing, a symlink, or unreadable allows nothing.
- Hosts select a covered item (`covered_by` set) only when its covering ancestor is not selected, so no bytes are counted twice.
```

- [ ] **Step 14: Commit**

```bash
git add patches/mole docs/engine-protocol.md
git commit -m "feat(engine): patch 0003 exact-path selections for clean"
```

---
### Task 6: Engine patch 0004 — host-driven uninstall

**Files:**
- Modify (Mole): `lib/core/host.sh` (uninstall events), `bin/uninstall.sh` (`uninstall_host_paths_mode`, `main`, `uninstall_list_apps`), `lib/uninstall/batch.sh` (`_batch_scan_app_details`, `_batch_preview_and_confirm`, `batch_uninstall_applications`, `_batch_execute_removals`)
- Create (Mole): `tests/uninstall_host_mode.bats`
- Modify (RoomForMac): `docs/engine-protocol.md`; create `patches/mole/0004-*.patch`

**Interfaces:**
- Consumes: `mole_json_*` helpers (Tasks 3–4), `MOLE_NO_AUTH`, `MOLE_GUI_HOST` (Task 3).
- Produces: `bin/uninstall.sh` honours `MOLE_UNINSTALL_APP_PATHS_FILE` (NUL-separated exact `.app` paths), `MOLE_UNINSTALL_PREVIEW_ONLY=1` (stop after the scan) and `MOLE_ASSUME_YES=1` (no key prompt). Events `app`, `app_blocked`, `app_result`. `uninstall --list` JSON gains `size_kb` and `last_used_epoch`. Bash helpers: `mole_json_array_from_lines LINES`, `mole_json_event_app …10 args`, `mole_json_event_app_blocked PATH NAME REASON VENDOR`, `mole_json_event_app_result PATH NAME STATUS FREED_KB REASON`, `uninstall_host_paths_mode`.

**Why exact paths and preview-only:** `mo uninstall NAME` matches by name *and substring* (asking for "Code" can match Xcode) and prompts `[y/N]`; and two teardown helpers (`unload_launch_plist`, `_uninstall_unload_launch_plists`) do not check for dry runs themselves, so a host preview must stop before the removal phase instead of relying on `--dry-run` alone.

- [ ] **Step 1: Write the failing tests** — `build/mole-work/tests/uninstall_host_mode.bats`

```bash
#!/usr/bin/env bats
# Host-driven uninstall: exact bundle paths, no prompts, preview-only runs,
# app events and per-app results.

load helpers/common

setup_file() {
    mole_test_setup_home uninstall-host-mode
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME/Applications" "$HOME/Library/Caches" "$HOME/.config/mole"
    EVENTS="$BATS_TEST_TMPDIR/events.ndjson"
    PATHS_FILE="$BATS_TEST_TMPDIR/app-paths"
    : > "$EVENTS"
}

sourceable_uninstall_sh() {
    local out="$1"
    awk -v script_dir="$PROJECT_ROOT/bin" '
        /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" script_dir "\""; next }
        /main "\$@"/ { print "# main skipped by test"; next }
        { print }
    ' "$PROJECT_ROOT/bin/uninstall.sh" > "$out"
}

create_fixture_app() {
    local app_path="$1" bundle_id="$2" name="$3"
    mkdir -p "$app_path/Contents/MacOS"
    : > "$app_path/Contents/MacOS/$name"
    chmod +x "$app_path/Contents/MacOS/$name"
    cat > "$app_path/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleExecutable</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST
}

create_fixture_with_leftovers() {
    FIXTURE_APP="$HOME/Applications/RFMFixture.app"
    create_fixture_app "$FIXTURE_APP" "com.example.rfmfixture" "RFMFixture"
    mkdir -p "$HOME/Library/Application Support/RFMFixture" "$HOME/Library/Caches/com.example.rfmfixture"
    printf 'state' > "$HOME/Library/Application Support/RFMFixture/state.json"
    printf 'cache' > "$HOME/Library/Caches/com.example.rfmfixture/c.bin"
    printf '%s\0' "$FIXTURE_APP" > "$PATHS_FILE"
}

install_uninstall_fakes() {
    mole_test_fake_command osascript 'exit 1'
    mole_test_fake_command launchctl 'exit 0'
    mole_test_fake_command mdfind 'exit 0'
    mole_test_fake_command killall 'exit 0'
    mole_test_fake_command sudo 'exit 1'
}

# Run the real uninstall main() against $HOME/Applications only.
run_host_uninstall() {
    local src="$BATS_TEST_TMPDIR/uninstall_source.sh"
    sourceable_uninstall_sh "$src"
    run env HOME="$HOME" PATH="$PATH" SRC_PATH="$src" MOLE_TEST_NO_AUTH=1 MOLE_NO_AUTH=1 \
        MOLE_GUI_HOST=roomformac MOLE_LSREGISTER_PATH="" MOLE_JSON_EVENTS_FILE="$EVENTS" \
        MOLE_UNINSTALL_APP_PATHS_FILE="$PATHS_FILE" MOLE_ASSUME_YES=1 "$@" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$SRC_PATH"
uninstall_print_app_search_dirs() { printf '%s\n' "$HOME/Applications"; }
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
main ${MAIN_ARGS:-}
EOF
}

@test "host path mode selects only exact bundle paths and reports the rest" {
    command -v jq > /dev/null || skip "jq is required"
    printf '%s\0' "$HOME/Applications/Code.app/" "$HOME/Applications/Missing.app" > "$PATHS_FILE"
    local src="$BATS_TEST_TMPDIR/uninstall_source.sh"
    sourceable_uninstall_sh "$src"
    run env HOME="$HOME" SRC_PATH="$src" MOLE_TEST_NO_AUTH=1 MOLE_JSON_EVENTS_FILE="$EVENTS" \
        MOLE_UNINSTALL_APP_PATHS_FILE="$PATHS_FILE" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$SRC_PATH"
scan_applications() { mktemp "$HOME/apps.XXXXXX"; }
load_applications() {
    apps_data=(
        "0|$HOME/Applications/Code.app|Code|com.example.code|1MB|Never|1024"
        "0|$HOME/Applications/Xcode Code Helper.app|Xcode Code Helper|com.example.helper|1MB|Never|1024"
    )
}
batch_uninstall_applications() {
    local app
    for app in "${selected_apps[@]}"; do
        printf 'SELECTED %s\n' "$app"
    done
}
uninstall_host_paths_mode
EOF
    [ "$status" -eq 0 ]
    [ "$(grep -c '^SELECTED ' <<< "$output")" -eq 1 ]
    [[ "$output" == *"SELECTED 0|$HOME/Applications/Code.app|Code|"* ]]
    run jq -r 'select(.type == "app_blocked") | [.reason, .path] | @tsv' "$EVENTS"
    [ "$output" = "$(printf 'not_eligible\t%s' "$HOME/Applications/Missing.app")" ]
}

@test "MOLE_ASSUME_YES confirms the plan without reading a key" {
    local src="$BATS_TEST_TMPDIR/uninstall_source.sh"
    sourceable_uninstall_sh "$src"
    run env HOME="$HOME" SRC_PATH="$src" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_YES=1 \
        /bin/bash --noprofile --norc -c '
set -euo pipefail
source "$SRC_PATH"
app_details=("Fixture|$HOME/Applications/Fixture.app|com.example.fixture|64|||false|false|false")
brew_cask_apps=()
running_apps=()
sudo_apps=()
total_estimated_size=64
# "q" would cancel an interactive confirmation.
if printf q | _batch_preview_and_confirm; then echo "confirmed"; else echo "declined"; fi
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"confirmed"* ]]
}

@test "a host preview reports the app with its leftovers and removes nothing" {
    command -v jq > /dev/null || skip "jq is required"
    create_fixture_with_leftovers
    install_uninstall_fakes
    run_host_uninstall MOLE_UNINSTALL_PREVIEW_ONLY=1 MAIN_ARGS=--dry-run
    [ "$status" -eq 0 ]
    [ -d "$FIXTURE_APP" ]
    [ -f "$HOME/Library/Application Support/RFMFixture/state.json" ]
    run jq -r 'select(.type == "app") | .path' "$EVENTS"
    [ "$output" = "$FIXTURE_APP" ]
    run jq -r 'select(.type == "app") | .leftovers[]' "$EVENTS"
    [[ "$output" == *"$HOME/Library/Application Support/RFMFixture"* ]]
    [[ "$output" == *"$HOME/Library/Caches/com.example.rfmfixture"* ]]
    run jq -r 'select(.type == "app_result") | .status' "$EVENTS"
    [ -z "$output" ]
}

@test "a host uninstall moves the app and its leftovers to the Trash and reports it" {
    command -v jq > /dev/null || skip "jq is required"
    create_fixture_with_leftovers
    install_uninstall_fakes
    local trash="$BATS_TEST_TMPDIR/trash"
    run_host_uninstall MOLE_TEST_TRASH_DIR="$trash"
    [ "$status" -eq 0 ]
    [ ! -e "$FIXTURE_APP" ]
    [ ! -e "$HOME/Library/Application Support/RFMFixture" ]
    run ls "$trash"
    [[ "$output" == *"RFMFixture.app"* ]]
    run jq -r 'select(.type == "app_result") | [.status, .path] | @tsv' "$EVENTS"
    [ "$output" = "$(printf 'removed\t%s' "$FIXTURE_APP")" ]
}

@test "uninstall --list JSON includes size_kb and last_used_epoch" {
    local src="$BATS_TEST_TMPDIR/uninstall_source.sh"
    sourceable_uninstall_sh "$src"
    local apps_cache="$BATS_TEST_TMPDIR/apps"
    printf '%s\n' "1700000000|$HOME/Applications/Regular.app|Regular|com.example.regular|420MB|Today|430080" > "$apps_cache"
    run env HOME="$HOME" SRC_PATH="$src" APPS_CACHE_FILE="$apps_cache" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$SRC_PATH"
scan_applications() { cp "$APPS_CACHE_FILE" "$HOME/apps.copy" && printf '%s\n' "$HOME/apps.copy"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
log_operation_session_start() { :; }
uninstall_list_apps
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"size": "420MB", "size_kb": 430080, "last_used_epoch": 1700000000}'* ]]
}
```

Note on `run_host_uninstall`: its extra arguments are `NAME=value` pairs placed inside the `env` command, so they become environment variables for that single run (for example `MOLE_UNINSTALL_PREVIEW_ONLY=1 MAIN_ARGS=--dry-run`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/mole-patches.sh test tests/uninstall_host_mode.bats`
Expected: FAIL — `uninstall_host_paths_mode: command not found`, the `q` key declines, no `app` events, and the list JSON lacks `size_kb`.

- [ ] **Step 3: Add the uninstall events** — append to `lib/core/host.sh`

```bash

# ============================================================================
# Uninstall Events
# ============================================================================

# JSON array of the non-empty lines of a newline-separated list.
mole_json_array_from_lines() {
    local lines="${1-}" out="[" first=true line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            out+=","
        fi
        out+=$(mole_json_str "$line")
    done <<< "$lines"
    printf '%s]' "$out"
}

# Args: path, name, bundle_id, size_kb, needs_sudo, brew_cask,
#       sensitive_data, running, leftovers (lines), review_only (lines)
mole_json_event_app() {
    mole_json_events_enabled || return 0
    local leftovers review_only
    leftovers=$(mole_json_array_from_lines "${9-}")
    review_only=$(mole_json_array_from_lines "${10-}")
    mole_json_emit "{\"v\":1,\"type\":\"app\",\"path\":$(mole_json_str "${1-}"),\"name\":$(mole_json_str "${2-}"),\"bundle_id\":$(mole_json_str "${3-}"),\"size_kb\":$(mole_json_num "${4-}"),\"needs_sudo\":$(mole_json_bool "${5-}"),\"brew_cask\":$(mole_json_bool "${6-}"),\"sensitive_data\":$(mole_json_bool "${7-}"),\"running\":$(mole_json_bool "${8-}"),\"leftovers\":$leftovers,\"review_only\":$review_only}"
}

# Args: path, name, reason (not_eligible|official_uninstaller|manual_removal), vendor
mole_json_event_app_blocked() {
    mole_json_events_enabled || return 0
    mole_json_emit "{\"v\":1,\"type\":\"app_blocked\",\"path\":$(mole_json_str "${1-}"),\"name\":$(mole_json_str "${2-}"),\"reason\":$(mole_json_str "${3-}"),\"vendor\":$(mole_json_str "${4-}")}"
}

# Args: path, name, status (removed|failed), freed_kb, reason
mole_json_event_app_result() {
    mole_json_events_enabled || return 0
    mole_json_emit "{\"v\":1,\"type\":\"app_result\",\"path\":$(mole_json_str "${1-}"),\"name\":$(mole_json_str "${2-}"),\"status\":$(mole_json_str "${3-}"),\"freed_kb\":$(mole_json_num "${4-}"),\"reason\":$(mole_json_str "${5-}")}"
}
```

- [ ] **Step 4: Select apps by exact path** — `bin/uninstall.sh`

Insert immediately above the line `main() {`:
```bash
# Select apps by exact bundle path for a GUI host (MOLE_UNINSTALL_APP_PATHS_FILE,
# NUL-separated). Paths go through the same eligibility scan as the
# interactive list, so protected and system apps can never be selected.
# Requested paths that are not eligible are reported as app_blocked events.
uninstall_host_paths_mode() {
    local paths_file="$MOLE_UNINSTALL_APP_PATHS_FILE"
    if [[ ! -f "$paths_file" || -L "$paths_file" ]]; then
        log_error "Application path list is missing: $paths_file"
        return 1
    fi

    local apps_file=""
    if ! apps_file=$(scan_applications); then
        uninstall_abort "could not complete the application scan"
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        uninstall_abort "application scan produced no list"
        return 1
    fi
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file"
        uninstall_abort "no applications available for uninstallation"
        return 1
    fi
    rm -f "$apps_file"

    selected_apps=()
    local requested app_data app_path matched
    while IFS= read -r -d '' requested; do
        while [[ ${#requested} -gt 1 && "$requested" == */ ]]; do
            requested="${requested%/}"
        done
        [[ -n "$requested" ]] || continue
        matched=false
        for app_data in "${apps_data[@]}"; do
            IFS='|' read -r _ app_path _ _ _ _ _ <<< "$app_data"
            if [[ "$app_path" == "$requested" ]]; then
                selected_apps+=("$app_data")
                matched=true
                break
            fi
        done
        if [[ "$matched" != "true" ]]; then
            mole_json_event_app_blocked "$requested" "" "not_eligible" ""
        fi
    done < "$paths_file"

    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        # Nothing eligible: the app_blocked events already say why.
        return 0
    fi
    batch_uninstall_applications
}

```

In `main`, find:
```bash
    if [[ $list_mode -eq 1 ]]; then
        uninstall_list_apps
        return $?
    fi
```
Replace with:
```bash
    if [[ $list_mode -eq 1 ]]; then
        uninstall_list_apps
        return $?
    fi

    # Host-driven uninstall: exact bundle paths, no name matching and no
    # interactive selector.
    if [[ -n "${MOLE_UNINSTALL_APP_PATHS_FILE:-}" ]]; then
        uninstall_host_paths_mode
        return $?
    fi
```

- [ ] **Step 5: Add sizes and last use to the list JSON** — `bin/uninstall.sh`, `uninstall_list_apps`

Find:
```bash
        local first=1
        local app_data
        for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
            IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
```
Replace with:
```bash
        local first=1
        local app_data
        local last_used_epoch="" size_kb=""
        for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
            IFS='|' read -r last_used_epoch app_path app_name bundle_id size _ size_kb <<< "$app_data"
            [[ "$last_used_epoch" =~ ^[0-9]+$ ]] || last_used_epoch=0
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
```

Find:
```bash
            printf '  {"name": "%s", "bundle_id": "%s", "source": "%s", "uninstall_name": "%s", "path": "%s", "size": "%s"}' \
                "$(uninstall_list_json_escape "$app_name")" \
                "$(uninstall_list_json_escape "$bundle_id")" \
                "$source_label" \
                "$(uninstall_list_json_escape "$uninstall_name")" \
                "$(uninstall_list_json_escape "$app_path")" \
                "$(uninstall_list_json_escape "$size_display")"
```
Replace with:
```bash
            printf '  {"name": "%s", "bundle_id": "%s", "source": "%s", "uninstall_name": "%s", "path": "%s", "size": "%s", "size_kb": %s, "last_used_epoch": %s}' \
                "$(uninstall_list_json_escape "$app_name")" \
                "$(uninstall_list_json_escape "$bundle_id")" \
                "$source_label" \
                "$(uninstall_list_json_escape "$uninstall_name")" \
                "$(uninstall_list_json_escape "$app_path")" \
                "$(uninstall_list_json_escape "$size_display")" \
                "$((10#$size_kb))" \
                "$((10#$last_used_epoch))"
```

- [ ] **Step 6: Emit app and blocked events during the scan** — `lib/uninstall/batch.sh`, `_batch_scan_app_details`

Find:
```bash
        if pgrep -qx "${exec_name:-$app_name}" 2> /dev/null; then
            running_apps+=("$app_name")
        fi
```
Replace with:
```bash
        local app_running=false
        if pgrep -qx "${exec_name:-$app_name}" 2> /dev/null; then
            running_apps+=("$app_name")
            app_running=true
        fi
```

Find:
```bash
            blocked_apps+=("$app_name|$official_vendor")
            continue
```
Replace with:
```bash
            blocked_apps+=("$app_name|$official_vendor")
            mole_json_event_app_blocked "$app_path" "$app_name" "official_uninstaller" "$official_vendor"
            continue
```

Report every "cannot be removed safely" app (four sites), inside `build/mole-work`:
```bash
perl -pi -e 's/^([ \t]*)manual_removal_apps\+=\("\$app_name"\)$/$1manual_removal_apps+=("\$app_name")\n$1mole_json_event_app_blocked "\$app_path" "\$app_name" "manual_removal" ""/' lib/uninstall/batch.sh
grep -c 'mole_json_event_app_blocked "$app_path" "$app_name" "manual_removal"' lib/uninstall/batch.sh
```
Expected: `4`, and each new line sits directly under its `manual_removal_apps+=` line with the same indentation.

Find:
```bash
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system|$encoded_review_system|$encoded_login_item_helpers|$sibling_guard|$app_identity|$original_bundle_id|$encoded_live_sibling_fingerprint|$app_info_identity")
    done
```
Replace with:
```bash
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system|$encoded_review_system|$encoded_login_item_helpers|$sibling_guard|$app_identity|$original_bundle_id|$encoded_live_sibling_fingerprint|$app_info_identity")
        mole_json_event_app "$app_path" "$app_name" "$original_bundle_id" "$total_kb" \
            "$needs_sudo" "$is_brew_cask" "$has_sensitive_data" "$app_running" \
            "$related_files" "$review_only_system_files"
    done
```

- [ ] **Step 7: Stop after the scan for previews, and skip the key prompt when the host confirmed**

In `batch_uninstall_applications`, find:
```bash
    if [[ ${#app_details[@]} -eq 0 ]]; then
        _abort_uninstall_batch
        return 1
    fi
```
Replace with:
```bash
    if [[ ${#app_details[@]} -eq 0 ]]; then
        _abort_uninstall_batch
        return 1
    fi

    # A host preview stops here: the app records and their events are
    # complete, and nothing below may run without a real confirmation.
    if [[ "${MOLE_UNINSTALL_PREVIEW_ONLY:-0}" == "1" ]]; then
        _abort_uninstall_batch
        return 0
    fi
```

In `_batch_preview_and_confirm`, find:
```bash
    drain_pending_input # Clean up any pending input before confirmation
    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
```
Replace with:
```bash
    local key=""
    if [[ "${MOLE_ASSUME_YES:-0}" == "1" ]]; then
        # A GUI host already showed this exact plan and got confirmation.
        key="y"
    else
        drain_pending_input # Clean up any pending input before confirmation
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants
    fi
```

- [ ] **Step 8: Report each app's outcome** — `lib/uninstall/batch.sh`, `_batch_execute_removals`

Find:
```bash
            success_items+=("$app_path")
            success_dock_targets+=("$app_path|$bundle_id")
```
Replace with:
```bash
            success_items+=("$app_path")
            success_dock_targets+=("$app_path|$bundle_id")
            if ! is_uninstall_dry_run; then
                mole_json_event_app_result "$app_path" "$app_name" "removed" "$total_kb" ""
            fi
```

Find:
```bash
            failed_count=$((failed_count + 1))
            failed_items+=("$app_name:$reason:${suggestion:-}")
```
Replace with:
```bash
            failed_count=$((failed_count + 1))
            failed_items+=("$app_name:$reason:${suggestion:-}")
            if ! is_uninstall_dry_run; then
                mole_json_event_app_result "$app_path" "$app_name" "failed" "0" "$reason"
            fi
```

- [ ] **Step 9: Run the tests and neighbouring suites**

Run: `scripts/mole-patches.sh test tests/uninstall_host_mode.bats tests/uninstall.bats tests/uninstall_safety.bats tests/uninstall_steam_launcher.bats tests/uninstall_scan_bash32.bats tests/uninstall_remove_file_list.bats tests/host_integration.bats`
Expected: all PASS.

- [ ] **Step 10: Lint**

Run: `scripts/mole-patches.sh lint lib/core/host.sh bin/uninstall.sh lib/uninstall/batch.sh`
Expected: no output.

- [ ] **Step 11: Commit inside the work tree, export, rebuild**

```bash
git -C build/mole-work add -A
git -C build/mole-work commit -m "Add a host-driven uninstall mode

MOLE_UNINSTALL_APP_PATHS_FILE selects apps by exact bundle path through
the normal eligibility scan (no substring matching), MOLE_ASSUME_YES
skips the key prompt, and MOLE_UNINSTALL_PREVIEW_ONLY stops after the
scan. Events report each app with its leftovers, blocked apps, and
per-app results. uninstall --list JSON gains size_kb and last_used_epoch."
scripts/mole-patches.sh export
bats scripts/tests/build_engine.bats
```
Expected: four patch files; build checks PASS with `patch_count=4`.

- [ ] **Step 12: Document the uninstall mode** — append to `docs/engine-protocol.md`

```markdown

## Uninstall (`bin/uninstall.sh`, patch 0004)

| Variable | Effect |
|---|---|
| `MOLE_UNINSTALL_APP_PATHS_FILE=PATH` | NUL-separated `.app` paths. Each must exactly match an app from the normal eligibility scan; others produce `app_blocked` / `not_eligible`. |
| `MOLE_UNINSTALL_PREVIEW_ONLY=1` | Stop after scanning the selected apps (always pair with `--dry-run`). |
| `MOLE_ASSUME_YES=1` | Treat the plan as confirmed; never read a key. |

| `type` | Fields |
|---|---|
| `app` | `path`, `name`, `bundle_id`, `size_kb` (app + leftovers), `needs_sudo`, `brew_cask`, `sensitive_data`, `running`, `leftovers` (paths removed with the app), `review_only` (system paths shown but never removed) |
| `app_blocked` | `path`, `name`, `reason` (`not_eligible` / `official_uninstaller` / `manual_removal`), `vendor` |
| `app_result` | `path`, `name`, `status` (`removed` / `failed`), `freed_kb`, `reason` |

`uninstall --list` (stdout is a pipe → JSON array) adds `size_kb` and `last_used_epoch` to each app.
While admin access is off, apps with `needs_sudo` or `brew_cask` cannot be removed (the batch
needs a sudo session); hosts show them as needing a password and never send them.
```

- [ ] **Step 13: Commit**

```bash
git add patches/mole docs/engine-protocol.md
git commit -m "feat(engine): patch 0004 host-driven uninstall mode"
```

---
### Task 7: Engine patch 0005 — analyzer `--trash-list`

**Files:**
- Create (Mole): `cmd/analyze/trashlist.go`, `cmd/analyze/trashlist_test.go`
- Modify (Mole): `cmd/analyze/main.go` (flag, usage, dispatch)
- Modify (RoomForMac): `docs/engine-protocol.md`; create `patches/mole/0005-*.patch`

**Interfaces:**
- Consumes: `trashPathWithProgress` / `moveToTrash` / `validateTrashTarget` from `cmd/analyze/delete.go` (Mole's own Trash route and protected-path rules).
- Produces: `analyze-go --trash-list FILE` — reads NUL-separated paths, moves each to the Trash deepest-first, prints `result` events (`action` `removed` / `skipped` (missing) / `failed`) and one `summary` (`command:"analyze"`, `items` = removed count, `partial` = any failure) on stdout; exit 0 unless FILE cannot be read. Go: `runTrashList(listPath string, out io.Writer) int`, `readTrashList(r io.Reader) ([]string, error)`, test seam `var trashListMover func(string) error`.

- [ ] **Step 1: Write the failing tests** — `build/mole-work/cmd/analyze/trashlist_test.go`

```go
//go:build darwin

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func decodeTrashEvents(t *testing.T, out []byte) []map[string]any {
	t.Helper()
	var events []map[string]any
	for _, line := range bytes.Split(bytes.TrimSpace(out), []byte("\n")) {
		var event map[string]any
		if err := json.Unmarshal(line, &event); err != nil {
			t.Fatalf("invalid JSON line %q: %v", line, err)
		}
		events = append(events, event)
	}
	return events
}

func TestReadTrashListSplitsOnNULAndTrimsSlashes(t *testing.T) {
	got, err := readTrashList(strings.NewReader("/a/b/\x00\x00/c d\x00/\x00"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "/a/b|/c d|/"; strings.Join(got, "|") != want {
		t.Fatalf("got %q, want %q", strings.Join(got, "|"), want)
	}
}

func TestRunTrashListReportsEachPathDeepestFirst(t *testing.T) {
	dir := t.TempDir()
	parent := filepath.Join(dir, "parent")
	child := filepath.Join(parent, "child")
	keep := filepath.Join(dir, "keep")
	for _, p := range []string{child, keep} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	missing := filepath.Join(dir, "missing")

	var moved []string
	original := trashListMover
	trashListMover = func(path string) error {
		if _, err := os.Lstat(path); err != nil {
			return err
		}
		moved = append(moved, path)
		return os.RemoveAll(path)
	}
	t.Cleanup(func() { trashListMover = original })

	list := filepath.Join(dir, "list")
	if err := os.WriteFile(list, []byte(parent+"\x00"+child+"\x00"+missing+"\x00"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if code := runTrashList(list, &out); code != 0 {
		t.Fatalf("exit code %d", code)
	}
	if got := strings.Join(moved, "|"); got != child+"|"+parent {
		t.Fatalf("moved %q, want the child before its parent", got)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("an unlisted path was touched: %v", err)
	}

	events := decodeTrashEvents(t, out.Bytes())
	if len(events) != 4 {
		t.Fatalf("got %d events, want 4:\n%s", len(events), out.String())
	}
	want := map[string]string{child: "removed", parent: "removed", missing: "skipped"}
	for _, event := range events[:3] {
		path, _ := event["path"].(string)
		if event["v"] != float64(1) || event["type"] != "result" || event["command"] != "analyze" || event["action"] != want[path] {
			t.Fatalf("unexpected result event %v", event)
		}
	}
	summary := events[3]
	if summary["type"] != "summary" || summary["items"] != float64(2) || summary["partial"] != false || summary["exit"] != float64(0) {
		t.Fatalf("unexpected summary %v", summary)
	}
}

func TestRunTrashListRefusesProtectedPathsWithoutMovingThem(t *testing.T) {
	list := filepath.Join(t.TempDir(), "list")
	if err := os.WriteFile(list, []byte("/System\x00"), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if code := runTrashList(list, &out); code != 0 {
		t.Fatalf("exit code %d", code)
	}
	events := decodeTrashEvents(t, out.Bytes())
	detail, _ := events[0]["detail"].(string)
	if events[0]["action"] != "failed" || !strings.Contains(detail, "protected") {
		t.Fatalf("expected a protected-path failure, got %v", events[0])
	}
	if events[1]["partial"] != true {
		t.Fatalf("the summary should be partial: %v", events[1])
	}
	if _, err := os.Stat("/System"); err != nil {
		t.Fatal("/System must still exist")
	}
}

func TestRunTrashListFailsWhenTheListIsMissing(t *testing.T) {
	var out bytes.Buffer
	if code := runTrashList(filepath.Join(t.TempDir(), "absent"), &out); code != 1 {
		t.Fatalf("exit code %d, want 1", code)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd build/mole-work && go test ./cmd/analyze -run 'TrashList' -count=1)`
Expected: FAIL — `undefined: readTrashList`, `undefined: trashListMover`, `undefined: runTrashList`.

- [ ] **Step 3: Implement** — `build/mole-work/cmd/analyze/trashlist.go`

```go
//go:build darwin

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// trashResultEvent and trashSummaryEvent are the NDJSON lines --trash-list
// prints, in the host event schema (v1) the bash commands also use.
type trashResultEvent struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	Command string `json:"command"`
	Action  string `json:"action"`
	Path    string `json:"path"`
	Detail  string `json:"detail"`
}

type trashSummaryEvent struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	Command string `json:"command"`
	DryRun  bool   `json:"dry_run"`
	Items   int    `json:"items"`
	SizeKB  int64  `json:"size_kb"`
	Partial bool   `json:"partial"`
	Exit    int    `json:"exit"`
}

// trashListMover moves one listed path to the Trash with the analyzer's own
// validation and Trash route. Tests replace it so they never touch the real
// Trash.
var trashListMover = func(path string) error {
	_, err := trashPathWithProgress(path, nil)
	return err
}

// readTrashList parses NUL-separated paths, dropping empty entries and
// trailing slashes. "/" itself is kept so validation can reject it.
func readTrashList(r io.Reader) ([]string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, raw := range bytes.Split(data, []byte{0}) {
		path := string(raw)
		for len(path) > 1 && strings.HasSuffix(path, "/") {
			path = strings.TrimSuffix(path, "/")
		}
		if path != "" {
			paths = append(paths, path)
		}
	}
	return paths, nil
}

// runTrashList moves every listed path to the Trash, deepest first so a
// listed child is reported before its listed parent takes it along, and
// prints one result per path plus a summary. Per-item failures are reported
// in the events; the exit code is 1 only when the list cannot be read.
func runTrashList(listPath string, out io.Writer) int {
	file, err := os.Open(listPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot open trash list: %v\n", err)
		return 1
	}
	paths, err := readTrashList(file)
	_ = file.Close()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot read trash list: %v\n", err)
		return 1
	}

	sort.SliceStable(paths, func(i, j int) bool {
		return strings.Count(paths[i], string(filepath.Separator)) > strings.Count(paths[j], string(filepath.Separator))
	})

	encoder := json.NewEncoder(out)
	encoder.SetEscapeHTML(false)
	removed, failed := 0, 0
	for _, path := range paths {
		event := trashResultEvent{V: 1, Type: "result", Command: "analyze", Path: path}
		switch err := trashListMover(path); {
		case err == nil:
			event.Action = "removed"
			removed++
		case errors.Is(err, fs.ErrNotExist):
			event.Action = "skipped"
			event.Detail = "missing"
		default:
			event.Action = "failed"
			event.Detail = err.Error()
			failed++
		}
		_ = encoder.Encode(event)
	}
	_ = encoder.Encode(trashSummaryEvent{
		V: 1, Type: "summary", Command: "analyze",
		Items: removed, Partial: failed > 0,
	})
	return 0
}
```

- [ ] **Step 4: Wire the flag** — `build/mole-work/cmd/analyze/main.go`

Find:
```go
var (
	jsonMode = flag.Bool("json", false, "output analysis as JSON instead of TUI")
)
```
Replace with:
```go
var (
	jsonMode  = flag.Bool("json", false, "output analysis as JSON instead of TUI")
	trashList = flag.String("trash-list", "", "move the NUL-separated paths in FILE to the Trash and print NDJSON results")
)
```

Find:
```go
  --json          Output the analysis as JSON instead of the interactive TUI
```
Replace with:
```go
  --json          Output the analysis as JSON instead of the interactive TUI
  --trash-list FILE
                  Move the NUL-separated paths in FILE to the Trash and print
                  one JSON result per path (for GUI front ends)
```

Find:
```go
	if code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr); !keepGoing {
		os.Exit(code)
	}
```
Replace with:
```go
	if code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr); !keepGoing {
		os.Exit(code)
	}

	if *trashList != "" {
		os.Exit(runTrashList(*trashList, os.Stdout))
	}
```

- [ ] **Step 5: Run the Go tests and vet**

Run: `(cd build/mole-work && gofmt -l ./cmd/analyze && go vet ./cmd/analyze && go test ./cmd/analyze -count=1)`
Expected: `gofmt -l` prints nothing; vet clean; all analyze tests PASS. (Mole's existing delete tests may move temp files to your Trash; that is upstream behaviour. The new tests never do.)

- [ ] **Step 6: Commit inside the work tree, export, rebuild**

```bash
git -C build/mole-work add -A
git -C build/mole-work commit -m "Add analyze --trash-list for GUI front ends

Moves the NUL-separated paths in FILE to the Trash through the analyzer's
own validation and Trash route, deepest first, and prints one JSON result
per path plus a summary in the host event schema."
scripts/mole-patches.sh export
bats scripts/tests/build_engine.bats
```
Expected: five patch files; build checks PASS with `patch_count=5`.

- [ ] **Step 7: Run Mole's full test suite on the patched tree**

Run: `(cd build/mole-work && ./scripts/test.sh)`
Expected: PASS. Any failure in an existing Mole test means a patch changed upstream behaviour: fix the patch (not the upstream test), re-export, and rerun.

- [ ] **Step 8: Document the Trash list** — append to `docs/engine-protocol.md`

```markdown

## Analyzer Trash list (`bin/analyze-go --trash-list FILE`, patch 0005)

- FILE lists absolute paths separated by NUL bytes. Each is moved to the Trash with the analyzer's own validation (protected and critical paths are refused), deepest paths first.
- stdout: one `result` event per path (`command:"analyze"`, `action` `removed` / `skipped` (missing) / `failed` with `detail`), then one `summary` (`items` = removed count, `partial` = any failure, `size_kb` 0).
- Exit code 0 when the list was processed; 1 only when FILE cannot be read.
- Hosts route `.app` bundles to the uninstaller instead of this command.
```

- [ ] **Step 9: Commit**

```bash
git add patches/mole docs/engine-protocol.md
git commit -m "feat(engine): patch 0005 analyzer Trash list"
```

---
### Task 8: `MoleEngine` package — models and event decoding

**Files:**
- Create: `Packages/MoleEngine/Package.swift`
- Create: `Packages/MoleEngine/Sources/MoleEngine/Models/CleanItem.swift` (`CleanItem`, `CleanCandidate`), `ItemResult.swift` (`ItemResult`, `RunSummary`), `AppPreview.swift` (`AppPreview`, `BlockedApp`, `AppResult`), `InstalledApp.swift`, `DiskLevel.swift` (`DiskLevel`, `DiskEntry`, `LargeFile`), `SystemSnapshot.swift`
- Create: `Packages/MoleEngine/Sources/MoleEngine/Protocol/EngineEvent.swift`, `EngineEventDecoder.swift`, `EngineJSON.swift`, `EngineError.swift`
- Create: `Packages/MoleEngine/Sources/MoleEngine/Runner/NDJSONLineBuffer.swift`
- Test: `Packages/MoleEngine/Tests/MoleEngineTests/EngineEventDecoderTests.swift`, `NDJSONLineBufferTests.swift`, `ReportDecodingTests.swift`

**Interfaces:**
- Consumes: the wire schema in `docs/engine-protocol.md` (Tasks 3–7).
- Produces: `public enum EngineEvent { case section(String), candidate(CleanCandidate), item(CleanItem), result(ItemResult), summary(RunSummary), app(AppPreview), appBlocked(BlockedApp), appResult(AppResult) }`; `EngineEventDecoder.decode(_ line: String) -> EngineEvent?`; models with `sizeBytes: Int64`; `InstalledApp.decodeList(from: Data) throws -> [InstalledApp]` (internal); `DiskLevel`/`DiskEntry`/`LargeFile`, `SystemSnapshot` (Decodable with `EngineJSON.decoder()`, snake_case → camelCase, so properties are named `bundleId`, `sizeKb`, `isDir`, `rxRateMbs`…); `EngineJSON.decoder() -> JSONDecoder` (internal); `public enum EngineError: Error, Equatable { installationInvalid(String), launchFailed(executable:reason:), nonZeroExit(code:stderrTail:), terminatedBySignal(_:stderrTail:), timedOut, cancelled, malformedOutput(String) }`; `NDJSONLineBuffer { mutating append(_ chunk: Data) -> [String]; mutating finish() -> [String] }`.

- [ ] **Step 1: Create the package manifest** — `Packages/MoleEngine/Package.swift`

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MoleEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MoleEngine", targets: ["MoleEngine"]),
    ],
    targets: [
        .target(name: "MoleEngine"),
        .testTarget(name: "MoleEngineTests", dependencies: ["MoleEngine"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`Packages/MoleEngine/Tests/MoleEngineTests/EngineEventDecoderTests.swift`
```swift
import Testing
@testable import MoleEngine

@Suite("Engine event decoding")
struct EngineEventDecoderTests {
    @Test func decodesSection() {
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"section","name":"User essentials"}"#) == .section("User essentials"))
    }

    @Test func decodesCandidate() {
        let line = #"{"v":1,"type":"candidate","section":"User essentials","path":"/Users/me/Library/Caches/A","size_kb":12,"size_known":true}"#
        let expected = CleanCandidate(section: "User essentials", path: "/Users/me/Library/Caches/A", sizeBytes: 12 * 1024, sizeKnown: true)
        #expect(EngineEventDecoder.decode(line) == .candidate(expected))
    }

    @Test func decodesItemWithEscapedPathAndCoverage() {
        let line = #"{"v":1,"type":"item","section":"Dev tools","path":"/Users/me/Caches/A \"q\"\\b\nc","size_kb":2048,"count":3,"size_known":true,"covered_by":"/Users/me/Caches"}"#
        let expected = CleanItem(
            section: "Dev tools", path: "/Users/me/Caches/A \"q\"\\b\nc",
            sizeBytes: 2048 * 1024, sizeKnown: true, count: 3, coveredBy: "/Users/me/Caches"
        )
        #expect(EngineEventDecoder.decode(line) == .item(expected))
    }

    @Test func decodesUncoveredItemAndUnicodePath() {
        let line = #"{"v":1,"type":"item","section":"User essentials","path":"/Users/me/Library/Caches/com.example.gamma café","size_kb":512,"count":1,"size_known":false,"covered_by":null}"#
        guard case .item(let item) = EngineEventDecoder.decode(line) else {
            Issue.record("expected an item")
            return
        }
        #expect(item.path == "/Users/me/Library/Caches/com.example.gamma café")
        #expect(item.coveredBy == nil)
        #expect(item.sizeKnown == false)
    }

    @Test func decodesResultAndSummary() {
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"result","command":"clean","action":"removed","path":"/a","detail":"1MB"}"#)
            == .result(ItemResult(command: "clean", action: .removed, path: "/a", detail: "1MB")))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"summary","command":"clean","dry_run":true,"items":3,"size_kb":4096,"partial":false,"exit":0}"#)
            == .summary(RunSummary(command: "clean", dryRun: true, items: 3, sizeBytes: 4096 * 1024, partial: false, exitCode: 0)))
    }

    @Test func decodesUninstallEvents() {
        let app = #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":100,"needs_sudo":false,"brew_cask":true,"sensitive_data":false,"running":true,"leftovers":["/Users/me/Library/Caches/com.example.foo"],"review_only":[]}"#
        #expect(EngineEventDecoder.decode(app) == .app(AppPreview(
            path: "/Applications/Foo.app", name: "Foo", bundleId: "com.example.foo", sizeBytes: 100 * 1024,
            needsAdmin: false, homebrewCask: true, hasSensitiveData: false, isRunning: true,
            leftovers: ["/Users/me/Library/Caches/com.example.foo"], reviewOnly: []
        )))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"app_blocked","path":"/Applications/Bar.app","name":"Bar","reason":"official_uninstaller","vendor":"Adobe"}"#)
            == .appBlocked(BlockedApp(path: "/Applications/Bar.app", name: "Bar", reason: .officialUninstaller, vendor: "Adobe")))
        #expect(EngineEventDecoder.decode(#"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"failed","freed_kb":0,"reason":"in use"}"#)
            == .appResult(AppResult(path: "/Applications/Foo.app", name: "Foo", status: .failed, freedBytes: 0, reason: "in use")))
    }

    @Test(arguments: [
        "",
        "   ",
        "not json",
        #"{"v":1,"type":"item""#,
        #"{"v":2,"type":"section","name":"Future"}"#,
        #"{"v":1,"type":"telemetry","name":"x"}"#,
        #"{"v":1,"type":"result","command":"clean","action":"vaporized","path":"/a"}"#,
        #"{"v":1,"type":"item","section":"S"}"#,
    ])
    func skipsLinesItCannotUse(_ line: String) {
        #expect(EngineEventDecoder.decode(line) == nil)
    }
}
```

`Packages/MoleEngine/Tests/MoleEngineTests/NDJSONLineBufferTests.swift`
```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("NDJSON line buffer")
struct NDJSONLineBufferTests {
    @Test func joinsLinesSplitAcrossChunks() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(buffer.append(Data(":2}\n".utf8)) == ["{\"b\":2}"])
        #expect(buffer.finish() == [])
    }

    @Test func returnsAnUnterminatedFinalLine() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("one\ntwo".utf8)) == ["one"])
        #expect(buffer.finish() == ["two"])
        #expect(buffer.finish() == [])
    }

    @Test func dropsEmptyLines() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Data("\n\na\n\n".utf8)) == ["a"])
    }

    @Test func keepsMultibyteCharactersSplitAcrossChunks() {
        var buffer = NDJSONLineBuffer()
        let bytes = Array("café\n".utf8)
        #expect(buffer.append(Data(bytes[0..<4])) == [])
        #expect(buffer.append(Data(bytes[4...])) == ["café"])
    }
}
```

`Packages/MoleEngine/Tests/MoleEngineTests/ReportDecodingTests.swift`
```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("Report decoding")
struct ReportDecodingTests {
    @Test func decodesTheAppInventoryAfterLeadingNoise() throws {
        let output = """
        Scanning applications...
        [
          {"name": "Regular", "bundle_id": "com.example.regular", "source": "Homebrew", "uninstall_name": "regular", "path": "/Applications/Regular.app", "size": "420MB", "size_kb": 430080, "last_used_epoch": 1700000000},
          {"name": "Old", "bundle_id": "com.example.old", "source": "App", "uninstall_name": "Old", "path": "/Applications/Old.app", "size": "1MB"}
        ]
        """
        let apps = try InstalledApp.decodeList(from: Data(output.utf8))
        #expect(apps.count == 2)
        #expect(apps[0].sizeBytes == 430080 * 1024)
        #expect(apps[0].isHomebrewCask)
        #expect(apps[0].lastUsed == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(apps[1].sizeBytes == 0)
        #expect(apps[1].lastUsed == nil)
    }

    @Test func rejectsOutputWithoutAnArray() {
        #expect(throws: EngineError.malformedOutput("uninstall --list printed no JSON array")) {
            try InstalledApp.decodeList(from: Data("nothing here".utf8))
        }
    }

    @Test func decodesADiskLevel() throws {
        let json = """
        {
          "path": "/Users/me/Documents",
          "overview": false,
          "entries": [
            {"name": "Photos", "path": "/Users/me/Documents/Photos", "size": 1048576, "is_dir": true, "cleanable": true, "last_access": "2026-09-25T05:21:52Z"},
            {"name": "a.zip", "path": "/Users/me/Documents/a.zip", "size": 2048, "is_dir": false}
          ],
          "large_files": [{"name": "a.zip", "path": "/Users/me/Documents/a.zip", "size": 2048}],
          "total_size": 1050624,
          "total_files": 12
        }
        """
        let level = try EngineJSON.decoder().decode(DiskLevel.self, from: Data(json.utf8))
        #expect(level.entries.count == 2)
        #expect(level.entries[0].isDir)
        #expect(level.entries[0].cleanable == true)
        #expect(level.entries[0].lastAccessDate == Date(timeIntervalSince1970: 1_790_313_712))
        #expect(level.entries[1].lastAccessDate == nil)
        #expect(level.largeFiles?.first?.size == 2048)
        #expect(level.totalSize == 1_050_624)
    }

    @Test func decodesASnapshotWithNullSensors() throws {
        let json = #"{"collected_at":"2026-09-25T13:21:52.123456789+08:00","host":"mac","health_score":92,"health_score_msg":"Good","cpu":{"usage":12.5,"per_core":[10,15],"core_count":10,"p_core_count":6,"e_core_count":4},"gpu":null,"memory":{"used":8,"total":16,"used_percent":50,"pressure":"normal"},"disks":[{"mount":"/","used":1,"total":2,"used_percent":50,"external":false}],"network":[{"name":"en0","rx_rate_mbs":1.5,"tx_rate_mbs":0.5}],"batteries":null,"thermal":{"cpu_temp":45.5,"fan_speed":0},"trash_size":1024}"#
        let snapshot = try EngineJSON.decoder().decode(SystemSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.cpu?.coreCount == 10)
        #expect(snapshot.cpu?.pCoreCount == 6)
        #expect(snapshot.gpu == nil)
        #expect(snapshot.memory?.pressure == "normal")
        #expect(snapshot.network?.first?.rxRateMbs == 1.5)
        #expect(snapshot.trashSize == 1024)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Packages/MoleEngine`
Expected: FAIL to compile — `cannot find 'EngineEventDecoder' in scope`, `cannot find type 'CleanItem'`, and so on.

- [ ] **Step 4: Write the models**

`Sources/MoleEngine/Models/CleanItem.swift`
```swift
import Foundation

/// Something Smart Clean would remove, as previewed by `clean --dry-run`.
public struct CleanItem: Sendable, Hashable, Codable {
    /// Engine section that found the item, for example "User essentials".
    public var section: String
    /// Absolute path exactly as the engine reported it.
    public var path: String
    public var sizeBytes: Int64
    /// False when the engine could not measure the item in time.
    public var sizeKnown: Bool
    /// Number of files the engine counted for this item.
    public var count: Int
    /// Nearest previewed ancestor whose size already includes this item.
    public var coveredBy: String?

    public init(
        section: String,
        path: String,
        sizeBytes: Int64,
        sizeKnown: Bool,
        count: Int = 1,
        coveredBy: String? = nil
    ) {
        self.section = section
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeKnown = sizeKnown
        self.count = count
        self.coveredBy = coveredBy
    }
}

/// Live progress while a preview runs. May repeat or overlap; the final
/// `CleanItem`s are authoritative.
public struct CleanCandidate: Sendable, Hashable, Codable {
    public var section: String
    public var path: String
    public var sizeBytes: Int64
    public var sizeKnown: Bool

    public init(section: String, path: String, sizeBytes: Int64, sizeKnown: Bool) {
        self.section = section
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeKnown = sizeKnown
    }
}
```

`Sources/MoleEngine/Models/ItemResult.swift`
```swift
import Foundation

/// The outcome the engine reported for one path during a real run.
public struct ItemResult: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Codable {
        case removed, skipped, failed
    }

    /// Engine command that produced the result: "clean" or "analyze".
    public var command: String
    public var action: Action
    public var path: String
    /// Engine wording such as "whitelist" or "permission denied"; may be empty.
    public var detail: String

    public init(command: String, action: Action, path: String, detail: String = "") {
        self.command = command
        self.action = action
        self.path = path
        self.detail = detail
    }
}

/// The last event of a run.
public struct RunSummary: Sendable, Hashable, Codable {
    public var command: String
    public var dryRun: Bool
    public var items: Int
    public var sizeBytes: Int64
    /// True when some sizes were unknown (preview) or some items failed (Trash).
    public var partial: Bool
    public var exitCode: Int

    public init(command: String, dryRun: Bool, items: Int, sizeBytes: Int64, partial: Bool, exitCode: Int) {
        self.command = command
        self.dryRun = dryRun
        self.items = items
        self.sizeBytes = sizeBytes
        self.partial = partial
        self.exitCode = exitCode
    }
}
```

`Sources/MoleEngine/Models/AppPreview.swift`
```swift
import Foundation

/// An app the uninstaller would remove, with everything removed alongside it.
public struct AppPreview: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var bundleId: String
    /// App bundle plus leftovers.
    public var sizeBytes: Int64
    /// Removal needs administrator access (unavailable until admin support ships).
    public var needsAdmin: Bool
    /// Installed by Homebrew; removal runs through `brew` and needs admin access.
    public var homebrewCask: Bool
    public var hasSensitiveData: Bool
    public var isRunning: Bool
    /// Paths removed together with the app.
    public var leftovers: [String]
    /// System paths shown for review but never removed.
    public var reviewOnly: [String]

    public init(
        path: String,
        name: String,
        bundleId: String,
        sizeBytes: Int64,
        needsAdmin: Bool,
        homebrewCask: Bool,
        hasSensitiveData: Bool,
        isRunning: Bool,
        leftovers: [String],
        reviewOnly: [String]
    ) {
        self.path = path
        self.name = name
        self.bundleId = bundleId
        self.sizeBytes = sizeBytes
        self.needsAdmin = needsAdmin
        self.homebrewCask = homebrewCask
        self.hasSensitiveData = hasSensitiveData
        self.isRunning = isRunning
        self.leftovers = leftovers
        self.reviewOnly = reviewOnly
    }
}

/// A requested app the uninstaller will not remove.
public struct BlockedApp: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Codable {
        /// Not in the uninstaller's inventory: protected, system, or missing.
        case notEligible = "not_eligible"
        /// The vendor ships its own uninstaller.
        case officialUninstaller = "official_uninstaller"
        /// Cannot be removed safely from where it is installed.
        case manualRemoval = "manual_removal"
    }

    public var path: String
    public var name: String
    public var reason: Reason
    public var vendor: String

    public init(path: String, name: String, reason: Reason, vendor: String = "") {
        self.path = path
        self.name = name
        self.reason = reason
        self.vendor = vendor
    }
}

/// The outcome of uninstalling one app.
public struct AppResult: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case removed, failed
    }

    public var path: String
    public var name: String
    public var status: Status
    public var freedBytes: Int64
    public var reason: String

    public init(path: String, name: String, status: Status, freedBytes: Int64, reason: String = "") {
        self.path = path
        self.name = name
        self.status = status
        self.freedBytes = freedBytes
        self.reason = reason
    }
}
```

`Sources/MoleEngine/Models/InstalledApp.swift`
```swift
import Foundation

/// One app from the uninstaller's inventory (`uninstall --list`).
/// Property names follow the engine's snake_case keys.
public struct InstalledApp: Sendable, Hashable, Decodable {
    public var name: String
    public var bundleId: String
    /// "App" or "Homebrew".
    public var source: String
    public var uninstallName: String
    public var path: String
    /// Engine-formatted size, for example "420MB" or "N/A (Steam-managed)".
    public var size: String
    public var sizeKb: Int64?
    public var lastUsedEpoch: Int64?

    public var sizeBytes: Int64 { max(sizeKb ?? 0, 0) * 1024 }

    public var lastUsed: Date? {
        guard let lastUsedEpoch, lastUsedEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(lastUsedEpoch))
    }

    public var isHomebrewCask: Bool { source == "Homebrew" }

    /// Decodes the JSON array `uninstall --list` prints, ignoring anything
    /// printed before it.
    static func decodeList(from data: Data) throws -> [InstalledApp] {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")) else {
            throw EngineError.malformedOutput("uninstall --list printed no JSON array")
        }
        return try EngineJSON.decoder().decode([InstalledApp].self, from: Data(data[start...]))
    }
}
```

`Sources/MoleEngine/Models/DiskLevel.swift`
```swift
import Foundation

/// One level of the disk explorer (`analyze --json [path]`).
/// Property names follow the engine's snake_case keys.
public struct DiskLevel: Sendable, Hashable, Decodable {
    public var path: String
    /// True for the machine-wide overview (no path given).
    public var overview: Bool
    public var entries: [DiskEntry]
    public var largeFiles: [LargeFile]?
    public var totalSize: Int64
    public var totalFiles: Int64?
}

public struct DiskEntry: Sendable, Hashable, Decodable {
    public var name: String
    public var path: String
    public var size: Int64
    public var isDir: Bool
    /// Overview only: a curated insight row rather than a plain folder.
    public var insight: Bool?
    /// A folder Smart Clean knows how to clean.
    public var cleanable: Bool?
    /// RFC 3339 timestamp in UTC.
    public var lastAccess: String?

    public var lastAccessDate: Date? {
        guard let lastAccess else { return nil }
        return try? Date(lastAccess, strategy: .iso8601)
    }
}

public struct LargeFile: Sendable, Hashable, Decodable {
    public var name: String
    public var path: String
    public var size: Int64
}
```

`Sources/MoleEngine/Models/SystemSnapshot.swift`
```swift
import Foundation

/// One live system reading (`status --watch`). Every field is optional so a
/// missing or null sensor never fails the whole snapshot.
public struct SystemSnapshot: Sendable, Hashable, Decodable {
    public var host: String?
    public var uptimeSeconds: UInt64?
    public var healthScore: Int?
    public var healthScoreMsg: String?
    public var hardware: Hardware?
    public var cpu: CPU?
    public var gpu: [GPU]?
    public var memory: Memory?
    public var disks: [Disk]?
    public var network: [Network]?
    public var batteries: [Battery]?
    public var thermal: Thermal?
    public var trashSize: UInt64?

    public struct Hardware: Sendable, Hashable, Decodable {
        public var model: String?
        public var cpuModel: String?
        public var totalRam: String?
        public var diskSize: String?
        public var osVersion: String?
    }

    public struct CPU: Sendable, Hashable, Decodable {
        public var usage: Double?
        public var perCore: [Double]?
        public var load1: Double?
        public var coreCount: Int?
        public var pCoreCount: Int?
        public var eCoreCount: Int?
    }

    public struct GPU: Sendable, Hashable, Decodable {
        public var name: String?
        public var usage: Double?
    }

    public struct Memory: Sendable, Hashable, Decodable {
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var swapUsed: UInt64?
        public var pressure: String?
    }

    public struct Disk: Sendable, Hashable, Decodable {
        public var mount: String?
        public var used: UInt64?
        public var total: UInt64?
        public var usedPercent: Double?
        public var external: Bool?
    }

    public struct Network: Sendable, Hashable, Decodable {
        public var name: String?
        public var rxRateMbs: Double?
        public var txRateMbs: Double?
    }

    public struct Battery: Sendable, Hashable, Decodable {
        public var percent: Double?
        public var status: String?
        public var timeLeft: String?
        public var health: String?
        public var cycleCount: Int?
        public var capacity: Int?
    }

    public struct Thermal: Sendable, Hashable, Decodable {
        public var cpuTemp: Double?
        public var gpuTemp: Double?
        public var fanSpeed: Int?
        public var systemPower: Double?
    }
}
```

- [ ] **Step 5: Write the protocol layer**

`Sources/MoleEngine/Protocol/EngineJSON.swift`
```swift
import Foundation

enum EngineJSON {
    /// The engine writes snake_case keys; models use the converted camelCase names.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
```

`Sources/MoleEngine/Protocol/EngineError.swift`
```swift
import Foundation

public enum EngineError: Error, Sendable, Equatable {
    case installationInvalid(String)
    case launchFailed(executable: String, reason: String)
    case nonZeroExit(code: Int32, stderrTail: String)
    case terminatedBySignal(Int32, stderrTail: String)
    case timedOut
    case cancelled
    case malformedOutput(String)
}
```

`Sources/MoleEngine/Protocol/EngineEvent.swift`
```swift
import Foundation

/// One line of the engine's event stream (schema v1, see docs/engine-protocol.md).
public enum EngineEvent: Sendable, Hashable {
    case section(String)
    case candidate(CleanCandidate)
    case item(CleanItem)
    case result(ItemResult)
    case summary(RunSummary)
    case app(AppPreview)
    case appBlocked(BlockedApp)
    case appResult(AppResult)
}
```

`Sources/MoleEngine/Protocol/EngineEventDecoder.swift`
```swift
import Foundation

public enum EngineEventDecoder {
    public static let supportedVersion = 1

    /// Decodes one event line. Returns nil for blank or malformed lines,
    /// unknown event types, and other schema versions, so a host can keep
    /// reading past anything it does not understand.
    public static func decode(_ line: String) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = try? EngineJSON.decoder().decode(RawEvent.self, from: Data(trimmed.utf8)),
              raw.v == supportedVersion
        else { return nil }
        return raw.event
    }
}

/// Every field any v1 event may carry, in the engine's snake_case names.
private struct RawEvent: Decodable {
    var v: Int
    var type: String
    var name: String?
    var section: String?
    var path: String?
    var sizeKb: Int64?
    var sizeKnown: Bool?
    var count: Int?
    var coveredBy: String?
    var command: String?
    var action: String?
    var detail: String?
    var dryRun: Bool?
    var items: Int?
    var partial: Bool?
    var exit: Int?
    var bundleId: String?
    var needsSudo: Bool?
    var brewCask: Bool?
    var sensitiveData: Bool?
    var running: Bool?
    var leftovers: [String]?
    var reviewOnly: [String]?
    var reason: String?
    var vendor: String?
    var status: String?
    var freedKb: Int64?

    var event: EngineEvent? {
        switch type {
        case "section":
            guard let name else { return nil }
            return .section(name)
        case "candidate":
            guard let path else { return nil }
            return .candidate(CleanCandidate(
                section: section ?? "", path: path,
                sizeBytes: bytes(sizeKb), sizeKnown: sizeKnown ?? false
            ))
        case "item":
            guard let path else { return nil }
            return .item(CleanItem(
                section: section ?? "", path: path,
                sizeBytes: bytes(sizeKb), sizeKnown: sizeKnown ?? false,
                count: max(count ?? 1, 1), coveredBy: coveredBy
            ))
        case "result":
            guard let path, let action = action.flatMap(ItemResult.Action.init(rawValue:)) else { return nil }
            return .result(ItemResult(command: command ?? "", action: action, path: path, detail: detail ?? ""))
        case "summary":
            return .summary(RunSummary(
                command: command ?? "", dryRun: dryRun ?? false, items: items ?? 0,
                sizeBytes: bytes(sizeKb), partial: partial ?? false, exitCode: exit ?? 0
            ))
        case "app":
            guard let path else { return nil }
            return .app(AppPreview(
                path: path, name: name ?? "", bundleId: bundleId ?? "",
                sizeBytes: bytes(sizeKb), needsAdmin: needsSudo ?? false,
                homebrewCask: brewCask ?? false, hasSensitiveData: sensitiveData ?? false,
                isRunning: running ?? false, leftovers: leftovers ?? [], reviewOnly: reviewOnly ?? []
            ))
        case "app_blocked":
            guard let path, let reason = reason.flatMap(BlockedApp.Reason.init(rawValue:)) else { return nil }
            return .appBlocked(BlockedApp(path: path, name: name ?? "", reason: reason, vendor: vendor ?? ""))
        case "app_result":
            guard let path, let status = status.flatMap(AppResult.Status.init(rawValue:)) else { return nil }
            return .appResult(AppResult(
                path: path, name: name ?? "", status: status,
                freedBytes: bytes(freedKb), reason: reason ?? ""
            ))
        default:
            return nil
        }
    }

    private func bytes(_ kilobytes: Int64?) -> Int64 {
        max(kilobytes ?? 0, 0) * 1024
    }
}
```

- [ ] **Step 6: Write the line buffer** — `Sources/MoleEngine/Runner/NDJSONLineBuffer.swift`

```swift
import Foundation

/// Splits a byte stream into lines. Bytes after the last newline wait for
/// the next chunk; `finish()` returns them as a final line.
public struct NDJSONLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        var index = lineStart
        while index < pending.endIndex {
            if pending[index] == 0x0A {
                if index > lineStart {
                    lines.append(String(decoding: pending[lineStart..<index], as: UTF8.self))
                }
                lineStart = pending.index(after: index)
            }
            index = pending.index(after: index)
        }
        pending = Data(pending[lineStart..<pending.endIndex])
        return lines
    }

    public mutating func finish() -> [String] {
        defer { pending = Data() }
        guard !pending.isEmpty else { return [] }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path Packages/MoleEngine`
Expected: PASS — 15 tests in 3 suites, no warnings under Swift 6 strict concurrency.

- [ ] **Step 8: Commit**

```bash
git add Packages/MoleEngine
git commit -m "feat(engine-kit): MoleEngine models and v1 event decoding"
```

---

### Task 9: Process runner

**Files:**
- Create: `Packages/MoleEngine/Sources/MoleEngine/Runner/Duration+TimeInterval.swift`, `ProcessExit.swift`, `Spawner.swift`, `ProcessControl.swift`, `FileDescriptorReader.swift`, `EngineCommand.swift`, `EngineRunning.swift`, `MoleRunner.swift`
- Test: `Packages/MoleEngine/Tests/MoleEngineTests/Support/StubScript.swift`, `Packages/MoleEngine/Tests/MoleEngineTests/MoleRunnerTests.swift`

**Interfaces:**
- Consumes: `NDJSONLineBuffer`, `EngineError` (Task 8).
- Produces: `public struct EngineCommand { executable: URL; arguments: [String]; environment: [String: String]; output: Output (.stdout | .eventsFile(URL)); stderrLog: URL?; timeout: Duration? }`; `public protocol EngineRunning: Sendable { func lines(for: EngineCommand) -> AsyncThrowingStream<String, any Error> }` plus `collect(_:) async throws -> Data`; `public struct MoleRunner: EngineRunning` (`init(gracePeriod: Duration = .seconds(5), pollInterval: Duration = .milliseconds(50))`); `public enum ProcessExit`. Internal: `Spawner`, `ProcessControl`, `FileDescriptorReader`, `EngineError.failure(exit:stopReason:stderrLog:)`. Test helpers: `StubScript(_ body:)`, `StubScript.command(output:timeout:environment:)`, `collectLines(_:)`, `processIsAlive(_:)`, `eventually(timeout:_:)`.

**Why `posix_spawn` instead of `Process`:** Foundation's `Process` cannot put the child in its own process group, and Mole starts many subprocesses; cancelling must stop all of them. `POSIX_SPAWN_CLOEXEC_DEFAULT` also keeps the app's own file descriptors out of the engine.

- [ ] **Step 1: Write the test helpers** — `Tests/MoleEngineTests/Support/StubScript.swift`

```swift
import Darwin
import Foundation
@testable import MoleEngine

/// A throwaway bash script in its own temporary directory.
struct StubScript {
    let url: URL
    var directory: URL { url.deletingLastPathComponent() }

    init(_ body: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rfm-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "stub.sh")
        try ("#!/bin/bash\nset -euo pipefail\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func command(
        output: EngineCommand.Output = .stdout,
        timeout: Duration? = nil,
        environment extra: [String: String] = [:]
    ) -> EngineCommand {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        environment.merge(extra) { _, new in new }
        return EngineCommand(
            executable: url,
            environment: environment,
            output: output,
            stderrLog: directory.appending(path: "stderr.log"),
            timeout: timeout
        )
    }
}

func collectLines(_ stream: AsyncThrowingStream<String, any Error>) async throws -> [String] {
    var lines: [String] = []
    for try await line in stream {
        lines.append(line)
    }
    return lines
}

/// True while `pid` exists and is not a zombie.
func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Polls until `condition` holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
```

- [ ] **Step 2: Write the failing tests** — `Tests/MoleEngineTests/MoleRunnerTests.swift`

```swift
import Darwin
import Foundation
import Testing
@testable import MoleEngine

@Suite("MoleRunner")
struct MoleRunnerTests {
    let runner = MoleRunner(gracePeriod: .seconds(1), pollInterval: .milliseconds(20))

    @Test func streamsStdoutLinesInOrder() async throws {
        let script = try StubScript("""
        echo one
        echo two
        printf 'three'
        """)
        #expect(try await collectLines(runner.lines(for: script.command())) == ["one", "two", "three"])
    }

    @Test func followsTheEventsFileWhileTheProcessRuns() async throws {
        let script = try StubScript("""
        echo 'ignored stdout'
        printf 'first\\n' >> "$EVENTS"
        sleep 0.3
        printf 'second\\n' >> "$EVENTS"
        printf 'partial' >> "$EVENTS"
        """)
        let events = script.directory.appending(path: "events.ndjson")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let command = script.command(output: .eventsFile(events), environment: ["EVENTS": events.path])
        #expect(try await collectLines(runner.lines(for: command)) == ["first", "second", "partial"])
    }

    @Test func reportsANonZeroExitWithTheStderrTail() async throws {
        let script = try StubScript("""
        echo out
        echo "boom: disk not found" >&2
        exit 3
        """)
        var received: [String] = []
        do {
            for try await line in runner.lines(for: script.command()) {
                received.append(line)
            }
            Issue.record("expected the stream to throw")
        } catch let error as EngineError {
            guard case .nonZeroExit(let code, let tail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(code == 3)
            #expect(tail.contains("boom: disk not found"))
        }
        #expect(received == ["out"])
    }

    @Test func timeoutStopsTheWholeProcessGroup() async throws {
        let script = try StubScript("""
        sleep 30 &
        echo $! > "$PIDFILE"
        echo ready
        wait
        """)
        let pidFile = script.directory.appending(path: "child.pid")
        let command = script.command(timeout: .seconds(2), environment: ["PIDFILE": pidFile.path])
        var received: [String] = []
        do {
            for try await line in runner.lines(for: command) {
                received.append(line)
            }
            Issue.record("expected the command to time out")
        } catch {
            #expect(error as? EngineError == .timedOut)
        }
        #expect(received == ["ready"])
        let childPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { !processIsAlive(childPID) })
    }


    @Test func endingIterationEarlyStopsTheProcess() async throws {
        let script = try StubScript("""
        echo $$ > "$PIDFILE"
        echo ready
        sleep 30
        """)
        let pidFile = script.directory.appending(path: "leader.pid")
        for try await line in runner.lines(for: script.command(environment: ["PIDFILE": pidFile.path])) {
            if line == "ready" { break }
        }
        let leaderPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { !processIsAlive(leaderPID) })
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let command = EngineCommand(
            executable: URL(fileURLWithPath: "/nonexistent/rfm-engine"),
            environment: ["PATH": "/usr/bin:/bin"],
            output: .stdout
        )
        do {
            _ = try await collectLines(runner.lines(for: command))
            Issue.record("expected a launch failure")
        } catch let error as EngineError {
            guard case .launchFailed(let executable, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(executable == "/nonexistent/rfm-engine")
        }
    }

    @Test func collectJoinsLinesWithNewlines() async throws {
        let script = try StubScript("printf 'a\\nb\\n'")
        let data = try await runner.collect(script.command())
        #expect(String(decoding: data, as: UTF8.self) == "a\nb\n")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Packages/MoleEngine --filter MoleRunner`
Expected: FAIL to compile — `cannot find 'MoleRunner' in scope`, `cannot find type 'EngineCommand'`.

- [ ] **Step 4: Write the small runner types**

`Sources/MoleEngine/Runner/Duration+TimeInterval.swift`
```swift
import Foundation

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
```

`Sources/MoleEngine/Runner/ProcessExit.swift`
```swift
import Foundation

/// How an engine process ended, decoded from a `waitpid` status.
public enum ProcessExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        if signal == 0 {
            self = .exited((status >> 8) & 0xff)
        } else {
            self = .signaled(signal)
        }
    }
}
```

`Sources/MoleEngine/Runner/EngineCommand.swift`
```swift
import Foundation

/// One engine invocation.
public struct EngineCommand: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        /// Lines come from the process's stdout.
        case stdout
        /// Lines come from an events file the process appends to; stdout is discarded.
        case eventsFile(URL)
    }

    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var output: Output
    /// Where stderr goes; its tail is attached to failures. nil discards it.
    public var stderrLog: URL?
    public var timeout: Duration?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        output: Output,
        stderrLog: URL? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.stderrLog = stderrLog
        self.timeout = timeout
    }
}
```

`Sources/MoleEngine/Runner/EngineRunning.swift`
```swift
import Foundation

/// Runs engine commands. `MoleRunner` is the real implementation; tests use fakes.
public protocol EngineRunning: Sendable {
    /// Streams output lines. The stream finishes when the process exits 0 and
    /// throws `EngineError` otherwise. Ending iteration early stops the process.
    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error>
}

extension EngineRunning {
    /// All output lines joined with newlines.
    public func collect(_ command: EngineCommand) async throws -> Data {
        var data = Data()
        for try await line in lines(for: command) {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }
}
```

- [ ] **Step 5: Write the process layer**

`Sources/MoleEngine/Runner/Spawner.swift`
```swift
import Darwin
import Foundation

enum StdoutMode: Sendable, Equatable {
    case discard
    case pipe
}

struct SpawnedProcess: Sendable {
    let pid: pid_t
    /// Read end of the stdout pipe when launched with `.pipe`.
    let stdoutReadFD: Int32?
}

enum SpawnError: Error, Equatable {
    case failed(Int32)
}

/// Launches engine commands with `posix_spawn` so each one leads its own
/// process group (cancellation reaches every child), starts with default
/// signal handling, reads stdin from /dev/null, and inherits no descriptors
/// from the app beyond the ones set up here.
enum Spawner {
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdout: StdoutMode,
        stderrPath: String?
    ) throws -> SpawnedProcess {
        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)

        var pipeFDs: [Int32] = [-1, -1]
        switch stdout {
        case .discard:
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        case .pipe:
            guard pipe(&pipeFDs) == 0 else { throw SpawnError.failed(errno) }
            posix_spawn_file_actions_adddup2(&fileActions, pipeFDs[1], 1)
        }
        if let stderrPath {
            posix_spawn_file_actions_addopen(&fileActions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)
        }

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(envp) { envPointer in
                posix_spawn(&pid, executable, &fileActions, &attributes, argvPointer, envPointer)
            }
        }
        if stdout == .pipe {
            close(pipeFDs[1])
        }
        guard result == 0 else {
            if stdout == .pipe {
                close(pipeFDs[0])
            }
            throw SpawnError.failed(result)
        }
        return SpawnedProcess(pid: pid, stdoutReadFD: stdout == .pipe ? pipeFDs[0] : nil)
    }

    /// Blocks until the process exits and returns its raw wait status.
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
```

`Sources/MoleEngine/Runner/ProcessControl.swift`
```swift
import Darwin
import Foundation

/// Stops a running engine process group at most once: SIGTERM first, then
/// SIGKILL after a grace period unless the process has already been reaped.
final class ProcessControl: @unchecked Sendable {
    enum StopReason: Sendable {
        case cancelled
        case timedOut
    }

    let pid: pid_t
    private let gracePeriod: Duration
    private let lock = NSLock()
    private var reason: StopReason?
    private var exited = false

    init(pid: pid_t, gracePeriod: Duration) {
        self.pid = pid
        self.gracePeriod = gracePeriod
    }

    var stopReason: StopReason? {
        lock.withLock { reason }
    }

    func stop(_ newReason: StopReason) {
        let shouldSignal: Bool = lock.withLock {
            guard reason == nil, !exited else { return false }
            reason = newReason
            return true
        }
        guard shouldSignal else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod.timeInterval) { [self] in
            // A reaped leader's process-group id may be reused; never signal it.
            lock.withLock {
                if !exited {
                    kill(-pid, SIGKILL)
                }
            }
        }
    }

    func scheduleTimeout(after duration: Duration) {
        DispatchQueue.global().asyncAfter(deadline: .now() + duration.timeInterval) { [self] in
            stop(.timedOut)
        }
    }

    func markExited() {
        lock.withLock { exited = true }
    }
}
```

`Sources/MoleEngine/Runner/FileDescriptorReader.swift`
```swift
import Darwin
import Foundation

enum FileDescriptorReader {
    /// Reads until end of file, handing every chunk to `onChunk`.
    static func readToEnd(_ fd: Int32, onChunk: (Data) -> Void) {
        var storage = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = storage.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                onChunk(Data(storage[0..<count]))
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }

    /// Follows a file the process appends to until the process exits, then
    /// reads what is left. Returns how the process ended.
    static func tail(
        _ url: URL,
        whileRunning pid: pid_t,
        pollInterval: Duration,
        onChunk: (Data) -> Void
    ) -> ProcessExit {
        let fd = open(url.path, O_RDONLY)
        defer {
            if fd >= 0 { close(fd) }
        }
        var storage = [UInt8](repeating: 0, count: 65_536)
        while true {
            drain(fd, into: &storage, onChunk: onChunk)
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                drain(fd, into: &storage, onChunk: onChunk)
                return ProcessExit(waitStatus: status)
            }
            if result == -1 && errno != EINTR {
                drain(fd, into: &storage, onChunk: onChunk)
                return .exited(-1)
            }
            Thread.sleep(forTimeInterval: pollInterval.timeInterval)
        }
    }

    private static func drain(_ fd: Int32, into storage: inout [UInt8], onChunk: (Data) -> Void) {
        guard fd >= 0 else { return }
        while true {
            let count = storage.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            onChunk(Data(storage[0..<count]))
        }
    }
}
```

- [ ] **Step 6: Write the runner** — `Sources/MoleEngine/Runner/MoleRunner.swift`

```swift
import Darwin
import Foundation

/// Runs engine commands in their own process group and streams their output.
public struct MoleRunner: EngineRunning {
    /// How long a stopped process gets between SIGTERM and SIGKILL.
    public var gracePeriod: Duration
    /// How often an events file is checked for new lines.
    public var pollInterval: Duration

    public init(gracePeriod: Duration = .seconds(5), pollInterval: Duration = .milliseconds(50)) {
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
    }

    public func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        let gracePeriod = self.gracePeriod
        let pollInterval = self.pollInterval
        return AsyncThrowingStream { continuation in
            let spawned: SpawnedProcess
            do {
                spawned = try Spawner.spawn(
                    executable: command.executable.path,
                    arguments: command.arguments,
                    environment: command.environment,
                    stdout: command.output == .stdout ? .pipe : .discard,
                    stderrPath: command.stderrLog?.path
                )
            } catch {
                continuation.finish(throwing: EngineError.launchFailed(
                    executable: command.executable.path,
                    reason: String(describing: error)
                ))
                return
            }

            let control = ProcessControl(pid: spawned.pid, gracePeriod: gracePeriod)
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    control.stop(.cancelled)
                }
            }
            if let timeout = command.timeout {
                control.scheduleTimeout(after: timeout)
            }

            let reader = Thread {
                var buffer = NDJSONLineBuffer()
                let exit: ProcessExit
                switch command.output {
                case .stdout:
                    if let fd = spawned.stdoutReadFD {
                        FileDescriptorReader.readToEnd(fd) { chunk in
                            for line in buffer.append(chunk) { continuation.yield(line) }
                        }
                        close(fd)
                    }
                    exit = ProcessExit(waitStatus: Spawner.waitForExit(spawned.pid))
                case .eventsFile(let url):
                    exit = FileDescriptorReader.tail(url, whileRunning: spawned.pid, pollInterval: pollInterval) { chunk in
                        for line in buffer.append(chunk) { continuation.yield(line) }
                    }
                }
                control.markExited()
                for line in buffer.finish() { continuation.yield(line) }
                if let error = EngineError.failure(exit: exit, stopReason: control.stopReason, stderrLog: command.stderrLog) {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            reader.name = "MoleRunner.reader"
            reader.start()
        }
    }
}

extension EngineError {
    static func failure(exit: ProcessExit, stopReason: ProcessControl.StopReason?, stderrLog: URL?) -> EngineError? {
        switch stopReason {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case nil: break
        }
        switch exit {
        case .exited(0):
            return nil
        case .exited(let code):
            return .nonZeroExit(code: code, stderrTail: stderrTail(stderrLog))
        case .signaled(let signal):
            return .terminatedBySignal(signal, stderrTail: stderrTail(stderrLog))
        }
    }

    static func stderrTail(_ url: URL?, limit: Int = 4096) -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data.suffix(limit), as: UTF8.self)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass, in parallel and serially**

Run: `swift test --package-path Packages/MoleEngine --filter MoleRunner && swift test --package-path Packages/MoleEngine --filter MoleRunner --no-parallel`
Expected: PASS both times, 7 tests. The first run after a build can be slow to start processes; the timeout test waits for `ready` and uses a 2-second limit so a cold start does not make it flaky.

- [ ] **Step 8: Run the whole package**

Run: `swift test --package-path Packages/MoleEngine`
Expected: PASS, 22 tests.

- [ ] **Step 9: Commit**

```bash
git add Packages/MoleEngine
git commit -m "feat(engine-kit): process-group runner with streaming, timeouts and cancellation"
```

---

### Task 10: Engine location, environment, run files, selection and tally

**Files:**
- Create: `Packages/MoleEngine/Sources/MoleEngine/Engine/EngineVersion.swift`, `EngineInstallation.swift`, `EngineEnvironment.swift`, `RunFiles.swift`
- Create: `Packages/MoleEngine/Sources/MoleEngine/Clean/CleanSelection.swift`, `CleanRunTally.swift`
- Test: `Packages/MoleEngine/Tests/MoleEngineTests/Support/TestInstallation.swift`, `EngineInstallationTests.swift`, `RunFilesTests.swift`, `CleanSelectionTests.swift`

**Interfaces:**
- Consumes: `EngineError`, `CleanItem`, `ItemResult`, `RunSummary`, `EngineEvent` (Task 8).
- Produces: `public struct EngineInstallation { init(root: URL) throws; static func bundled(in: Bundle = .main) throws -> Self; root; version: EngineVersion; cleanScript; uninstallScript; analyzeBinary; statusBinary; hostBinDirectory }` (internal `requiredFiles`); `public struct EngineVersion { moleTag; moleCommit; patchesSHA256; patchCount }`; `public struct EngineEnvironment { init(home:user:temporaryDirectory:pathPrefix:allowsAdministrator:extra:); static func current() -> Self; static let systemPath: [String]; func variables(for: EngineInstallation) -> [String: String] }`; internal `struct RunFiles { static func make(in: URL) throws -> RunFiles; directory; events; stderrLog; func writeNULSeparated(_ paths: [String], named: String) throws -> URL; func remove() }`; `public enum CleanSelection { static func enginePaths(for: [CleanItem]) -> [String] }` (internal `normalize(_:)`); `public struct CleanRunTally { init(selection: [CleanItem]); mutating record(_ event: EngineEvent); summary; unexpectedRemovals; removedItems; notRemovedItems; removedBytes; outcome(for:) }`. Test helpers: `TestInstallation.makeLayout(version:)`, `TestInstallation.make()`, `EngineEnvironment.fixture`.

**Allowance rule these types encode (spec §7.2):** bytes are charged only for selected items with a `removed` result, using the size from the preview the user approved; covered children are never listed next to a selected ancestor, so nothing is counted twice; missing, skipped and failed items cost nothing.

- [ ] **Step 1: Write the test helper** — `Tests/MoleEngineTests/Support/TestInstallation.swift`

```swift
import Foundation
@testable import MoleEngine

enum TestInstallation {
    static let version = """
    mole_tag=V1.56.0
    mole_commit=239c90d000000000000000000000000000000000
    patches_sha256=abc123
    patch_count=5
    """

    /// A fake engine directory with every required file present and executable.
    static func makeLayout(version: String = TestInstallation.version) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "rfm-engine-\(UUID().uuidString)")
        for relative in EngineInstallation.requiredFiles {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/bash\nexit 0\n".utf8),
                attributes: [.posixPermissions: 0o755]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try version.write(to: root.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        return root
    }

    static func make() throws -> EngineInstallation {
        try EngineInstallation(root: makeLayout())
    }
}

extension EngineEnvironment {
    static let fixture = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: NSTemporaryDirectory())
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/MoleEngineTests/EngineInstallationTests.swift`
```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("Engine installation and environment")
struct EngineInstallationTests {
    @Test func acceptsACompleteLayout() throws {
        let root = try TestInstallation.makeLayout()
        let installation = try EngineInstallation(root: root)
        #expect(installation.version.moleTag == "V1.56.0")
        #expect(installation.version.patchCount == 5)
        #expect(installation.cleanScript == root.appending(path: "bin/clean.sh"))
        #expect(installation.hostBinDirectory == root.appending(path: "host-bin"))
    }

    @Test func rejectsAMissingScript() throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.removeItem(at: root.appending(path: "bin/uninstall.sh"))
        #expect(throws: EngineError.installationInvalid("missing bin/uninstall.sh")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func rejectsANonExecutableBinary() throws {
        let root = try TestInstallation.makeLayout()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appending(path: "bin/status-go").path)
        #expect(throws: EngineError.installationInvalid("not executable: bin/status-go")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func rejectsAVersionWithoutTheMoleRelease() throws {
        let root = try TestInstallation.makeLayout(version: "patch_count=5\n")
        #expect(throws: EngineError.installationInvalid("VERSION is missing mole_tag or mole_commit")) {
            try EngineInstallation(root: root)
        }
    }

    @Test func blocksAdministratorAccessByDefault() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t", pathPrefix: ["/stubs"])
        let variables = environment.variables(for: installation)
        #expect(variables["PATH"] == (["/stubs", installation.hostBinDirectory.path] + EngineEnvironment.systemPath).joined(separator: ":"))
        #expect(variables["MOLE_NO_AUTH"] == "1")
        #expect(variables["MOLE_GUI_HOST"] == "roomformac")
        #expect(variables["HOME"] == "/Users/test")
        #expect(variables["LOGNAME"] == "test")
        #expect(variables["NO_COLOR"] == "1")
        #expect(variables["TERM"] == "dumb")
    }

    @Test func allowingAdministratorDropsTheSudoShim() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t", allowsAdministrator: true)
        let variables = environment.variables(for: installation)
        #expect(variables["MOLE_NO_AUTH"] == nil)
        #expect(!(variables["PATH"] ?? "").contains("host-bin"))
    }

    @Test func extraVariablesWin() throws {
        let installation = try TestInstallation.make()
        let environment = EngineEnvironment(
            home: "/Users/test", user: "test", temporaryDirectory: "/tmp/t",
            extra: ["TERM": "xterm", "MOLE_LSREGISTER_PATH": ""]
        )
        let variables = environment.variables(for: installation)
        #expect(variables["TERM"] == "xterm")
        #expect(variables["MOLE_LSREGISTER_PATH"] == "")
    }
}
```

`Tests/MoleEngineTests/RunFilesTests.swift`
```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("Run files")
struct RunFilesTests {
    @Test func createsAPrivateDirectoryWithAnEmptyEventsFile() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let directory = try FileManager.default.attributesOfItem(atPath: files.directory.path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let events = try FileManager.default.attributesOfItem(atPath: files.events.path)
        #expect((events[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((events[.size] as? NSNumber)?.intValue == 0)
    }

    @Test func writesNULSeparatedPathsThatKeepNewlines() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let url = try files.writeNULSeparated(["/a b/c", "/new\nline"], named: "selection")
        #expect(try Data(contentsOf: url) == Data("/a b/c\u{0}/new\nline\u{0}".utf8))
    }

    @Test func handlesTenThousandPaths() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        defer { files.remove() }
        let paths = (0..<10_000).map { "/Users/test/Library/Caches/com.example.vendor\($0)/data" }
        let parts = try Data(contentsOf: files.writeNULSeparated(paths, named: "selection")).split(separator: 0)
        #expect(parts.count == 10_000)
        #expect(String(decoding: parts[9_999], as: UTF8.self) == paths[9_999])
    }

    @Test func removeDeletesEverything() throws {
        let files = try RunFiles.make(in: FileManager.default.temporaryDirectory)
        _ = try files.writeNULSeparated(["/a"], named: "apps")
        files.remove()
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }
}
```

`Tests/MoleEngineTests/CleanSelectionTests.swift`
```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("Clean selection and tally")
struct CleanSelectionTests {
    let parent = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/Yarn", sizeBytes: 100, sizeKnown: true)
    let child = CleanItem(
        section: "Dev tools", path: "/Users/test/Library/Caches/Yarn/v6", sizeBytes: 60, sizeKnown: true,
        coveredBy: "/Users/test/Library/Caches/Yarn"
    )
    let other = CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/com.example.a/", sizeBytes: 10, sizeKnown: true)

    @Test func dropsCoveredItemsWhenTheirAncestorIsSelected() {
        #expect(CleanSelection.enginePaths(for: [parent, child, other])
            == ["/Users/test/Library/Caches/Yarn", "/Users/test/Library/Caches/com.example.a"])
    }

    @Test func keepsACoveredItemSelectedWithoutItsAncestor() {
        #expect(CleanSelection.enginePaths(for: [child]) == ["/Users/test/Library/Caches/Yarn/v6"])
    }

    @Test func removesDuplicates() {
        #expect(CleanSelection.enginePaths(for: [other, other]) == ["/Users/test/Library/Caches/com.example.a"])
    }

    @Test func talliesOnlyConfirmedRemovalsOfSelectedPaths() {
        var tally = CleanRunTally(selection: [parent, child, other])
        tally.record(.result(ItemResult(command: "clean", action: .skipped, path: "/Users/test/Library/Caches/Yarn", detail: "live user cache")))
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/Library/Caches/Yarn/")))
        tally.record(.result(ItemResult(command: "clean", action: .failed, path: "/Users/test/Library/Caches/Yarn", detail: "later noise")))
        tally.record(.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/Elsewhere")))
        tally.record(.summary(RunSummary(command: "clean", dryRun: false, items: 1, sizeBytes: 100, partial: false, exitCode: 0)))

        #expect(tally.removedItems == [parent])
        #expect(tally.notRemovedItems == [other])
        #expect(tally.removedBytes == 100)
        #expect(tally.unexpectedRemovals == ["/Users/test/Elsewhere"])
        #expect(tally.summary?.exitCode == 0)
        #expect(tally.outcome(for: other) == nil)
    }

    @Test func itemsWithoutARemovalEventAreNotRemoved() {
        var tally = CleanRunTally(selection: [other])
        tally.record(.result(ItemResult(command: "clean", action: .skipped, path: other.path, detail: "whitelist")))
        #expect(tally.removedItems.isEmpty)
        #expect(tally.notRemovedItems == [other])
        #expect(tally.removedBytes == 0)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Packages/MoleEngine`
Expected: FAIL to compile — `cannot find 'EngineInstallation' in scope`, `cannot find 'RunFiles' in scope`, `cannot find 'CleanSelection' in scope`.

- [ ] **Step 4: Write the engine types**

`Sources/MoleEngine/Engine/EngineVersion.swift`
```swift
import Foundation

/// The engine build's VERSION file, written by scripts/build-engine.sh.
public struct EngineVersion: Sendable, Equatable {
    public var moleTag: String
    public var moleCommit: String
    public var patchesSHA256: String
    public var patchCount: Int

    init(parsing text: String) throws {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let tag = values["mole_tag"], !tag.isEmpty,
              let commit = values["mole_commit"], !commit.isEmpty
        else {
            throw EngineError.installationInvalid("VERSION is missing mole_tag or mole_commit")
        }
        moleTag = tag
        moleCommit = commit
        patchesSHA256 = values["patches_sha256"] ?? "none"
        patchCount = Int(values["patch_count"] ?? "") ?? 0
    }
}
```

`Sources/MoleEngine/Engine/EngineInstallation.swift`
```swift
import Foundation

/// A validated engine directory: the patched Mole scripts, libraries and
/// binaries produced by scripts/build-engine.sh.
public struct EngineInstallation: Sendable, Equatable {
    public let root: URL
    public let version: EngineVersion

    static let requiredFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go",
        "lib/core/common.sh", "lib/core/host.sh", "host-bin/sudo",
    ]
    static let executableFiles = [
        "bin/clean.sh", "bin/uninstall.sh", "bin/analyze-go", "bin/status-go", "host-bin/sudo",
    ]

    public init(root: URL) throws {
        let fileManager = FileManager.default
        for relative in Self.requiredFiles where !fileManager.fileExists(atPath: root.appending(path: relative).path) {
            throw EngineError.installationInvalid("missing \(relative)")
        }
        for relative in Self.executableFiles where !fileManager.isExecutableFile(atPath: root.appending(path: relative).path) {
            throw EngineError.installationInvalid("not executable: \(relative)")
        }
        let versionText: String
        do {
            versionText = try String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8)
        } catch {
            throw EngineError.installationInvalid("missing VERSION")
        }
        self.version = try EngineVersion(parsing: versionText)
        self.root = root
    }

    /// The engine shipped inside the app bundle (Contents/Resources/engine).
    public static func bundled(in bundle: Bundle = .main) throws -> EngineInstallation {
        guard let resources = bundle.resourceURL else {
            throw EngineError.installationInvalid("the app bundle has no resources directory")
        }
        return try EngineInstallation(root: resources.appending(path: "engine"))
    }

    public var cleanScript: URL { root.appending(path: "bin/clean.sh") }
    public var uninstallScript: URL { root.appending(path: "bin/uninstall.sh") }
    public var analyzeBinary: URL { root.appending(path: "bin/analyze-go") }
    public var statusBinary: URL { root.appending(path: "bin/status-go") }
    public var hostBinDirectory: URL { root.appending(path: "host-bin") }
}
```

`Sources/MoleEngine/Engine/EngineEnvironment.swift`
```swift
import Foundation

/// The environment every engine command runs with.
public struct EngineEnvironment: Sendable, Equatable {
    public var home: String
    public var user: String
    public var temporaryDirectory: String
    /// Directories searched before everything else (tests put stubs here).
    public var pathPrefix: [String]
    /// Always false in v1: the engine runs with MOLE_NO_AUTH and the failing
    /// sudo shim first on PATH. See docs/engine-protocol.md.
    public var allowsAdministrator: Bool
    /// Extra variables, applied last.
    public var extra: [String: String]

    public static let systemPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public init(
        home: String,
        user: String,
        temporaryDirectory: String,
        pathPrefix: [String] = [],
        allowsAdministrator: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.home = home
        self.user = user
        self.temporaryDirectory = temporaryDirectory
        self.pathPrefix = pathPrefix
        self.allowsAdministrator = allowsAdministrator
        self.extra = extra
    }

    /// The signed-in user's environment.
    public static func current() -> EngineEnvironment {
        EngineEnvironment(home: NSHomeDirectory(), user: NSUserName(), temporaryDirectory: NSTemporaryDirectory())
    }

    public func variables(for installation: EngineInstallation) -> [String: String] {
        var path = pathPrefix
        if !allowsAdministrator {
            path.append(installation.hostBinDirectory.path)
        }
        path += Self.systemPath
        var variables = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "TMPDIR": temporaryDirectory,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "MOLE_GUI_HOST": "roomformac",
        ]
        if !allowsAdministrator {
            variables["MOLE_NO_AUTH"] = "1"
        }
        variables.merge(extra) { _, new in new }
        return variables
    }
}
```

`Sources/MoleEngine/Engine/RunFiles.swift`
```swift
import Foundation

/// A private scratch directory for one engine run: the events file, the
/// stderr log, and any path lists handed to the engine. Removed afterwards.
struct RunFiles: Sendable {
    let directory: URL

    var events: URL { directory.appending(path: "events.ndjson") }
    var stderrLog: URL { directory.appending(path: "stderr.log") }

    static func make(in parent: URL) throws -> RunFiles {
        let directory = parent.appending(path: "roomformac-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let files = RunFiles(directory: directory)
        guard FileManager.default.createFile(atPath: files.events.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: files.events.path])
        }
        return files
    }

    /// Writes paths separated by NUL bytes, so paths may contain newlines.
    func writeNULSeparated(_ paths: [String], named name: String) throws -> URL {
        var data = Data()
        for path in paths {
            data.append(Data(path.utf8))
            data.append(0)
        }
        let url = directory.appending(path: name)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
```

- [ ] **Step 5: Write the selection and tally**

`Sources/MoleEngine/Clean/CleanSelection.swift`
```swift
import Foundation

public enum CleanSelection {
    /// The paths to hand the engine for the selected preview items. An item
    /// covered by a selected ancestor is dropped: removing the ancestor
    /// removes it, and listing both would count its bytes twice.
    public static func enginePaths(for selected: [CleanItem]) -> [String] {
        let selectedPaths = Set(selected.map { normalize($0.path) })
        var seen = Set<String>()
        var paths: [String] = []
        for item in selected {
            if let ancestor = item.coveredBy, selectedPaths.contains(normalize(ancestor)) {
                continue
            }
            let path = normalize(item.path)
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    /// Drops trailing slashes, keeping "/" itself (the engine does the same).
    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
```

`Sources/MoleEngine/Clean/CleanRunTally.swift`
```swift
import Foundation

/// Folds a selected clean run's events into per-item outcomes. Only a
/// `removed` result for a selected path counts as removed; anything else,
/// including no event at all, leaves the item not removed.
public struct CleanRunTally: Sendable, Equatable {
    public private(set) var summary: RunSummary?
    /// `removed` results for paths that were not selected. Always empty unless
    /// an engine gate is missing; hosts log these as a safety alarm.
    public private(set) var unexpectedRemovals: [String] = []
    private let itemsByPath: [String: CleanItem]
    private var outcomes: [String: ItemResult] = [:]

    public init(selection: [CleanItem]) {
        let enginePaths = Set(CleanSelection.enginePaths(for: selection))
        var items: [String: CleanItem] = [:]
        for item in selection {
            let path = CleanSelection.normalize(item.path)
            if enginePaths.contains(path) {
                items[path] = item
            }
        }
        itemsByPath = items
    }

    public mutating func record(_ event: EngineEvent) {
        switch event {
        case .result(let result):
            let path = CleanSelection.normalize(result.path)
            guard itemsByPath[path] != nil else {
                if result.action == .removed {
                    unexpectedRemovals.append(result.path)
                }
                return
            }
            if outcomes[path]?.action == .removed {
                return
            }
            outcomes[path] = result
        case .summary(let value):
            summary = value
        default:
            break
        }
    }

    /// Selected items the engine confirmed removed, sorted by path.
    public var removedItems: [CleanItem] {
        sortedItems.filter { outcome(for: $0)?.action == .removed }
    }

    /// Selected items that were skipped, failed, vanished, or never reached.
    public var notRemovedItems: [CleanItem] {
        sortedItems.filter { outcome(for: $0)?.action != .removed }
    }

    /// Previewed size of the confirmed removals.
    public var removedBytes: Int64 {
        removedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public func outcome(for item: CleanItem) -> ItemResult? {
        outcomes[CleanSelection.normalize(item.path)]
    }

    private var sortedItems: [CleanItem] {
        itemsByPath.values.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Packages/MoleEngine`
Expected: PASS, 38 tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/MoleEngine
git commit -m "feat(engine-kit): engine installation, environment, selections and run tally"
```

---

### Task 11: Services — Clean, Uninstall, Analyzer, Status

**Files:**
- Create: `Packages/MoleEngine/Sources/MoleEngine/Services/EventRun.swift`, `CleanService.swift`, `UninstallService.swift`, `AnalyzerService.swift`, `StatusService.swift`
- Test: `Packages/MoleEngine/Tests/MoleEngineTests/Support/FakeRunner.swift`, `Packages/MoleEngine/Tests/MoleEngineTests/ServicesTests.swift`

**Interfaces:**
- Consumes: `EngineRunning`, `MoleRunner`, `EngineCommand` (Task 9); `EngineInstallation`, `EngineEnvironment`, `RunFiles`, `CleanSelection` (Task 10); models and `EngineEventDecoder` (Task 8).
- Produces (all `init(installation:environment: = .current(), runner: = MoleRunner(), scratchDirectory: = temporaryDirectory)`):
  - `CleanService.scan() -> AsyncThrowingStream<EngineEvent, any Error>`; `CleanService.clean(_ selection: [CleanItem]) -> AsyncThrowingStream<EngineEvent, any Error>`
  - `UninstallService.listApps() async throws -> [InstalledApp]`; `preview(appPaths: [String]) async throws -> UninstallPreview` (`apps`, `blocked`); `uninstall(appPaths: [String]) -> AsyncThrowingStream<EngineEvent, any Error>`
  - `AnalyzerService.scan(path: String?) async throws -> DiskLevel` (nil = overview; cached by folder mtime, overview for 60 s via `public actor DiskLevelCache`); `invalidate(path:) async`; `trash(_ paths: [String]) -> AsyncThrowingStream<EngineEvent, any Error>`
  - `StatusService.snapshots(interval: Duration = .seconds(2)) -> AsyncThrowingStream<SystemSnapshot, any Error>`
  - Internal: `struct Invocation { arguments; variables }`, `struct EventRun { events(executable:timeout:source:configure:); stdoutData(executable:timeout:configure:); stream(executable:timeout:source:configure:transform:) }`. Test helpers: `FakeRunner(respond:)` with `calls: [Call]` (`command`, `eventsFileExisted`, `files`), `nulSeparatedPaths(_:)`, `collectAll(_:)`.

- [ ] **Step 1: Write the fake runner** — `Tests/MoleEngineTests/Support/FakeRunner.swift`

```swift
import Foundation
@testable import MoleEngine

/// Records every command and answers with canned lines. Files a service wrote
/// for the run are captured at call time, before the service removes them.
final class FakeRunner: EngineRunning, @unchecked Sendable {
    struct Call: Sendable {
        let command: EngineCommand
        let eventsFileExisted: Bool
        let files: [String: Data]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (EngineCommand) throws -> [String]

    init(respond: @escaping @Sendable (EngineCommand) throws -> [String]) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func lines(for command: EngineCommand) -> AsyncThrowingStream<String, any Error> {
        var files: [String: Data] = [:]
        for key in ["MOLE_SELECTION_FILE", "MOLE_UNINSTALL_APP_PATHS_FILE"] {
            if let path = command.environment[key], let data = FileManager.default.contents(atPath: path) {
                files[key] = data
            }
        }
        if let flag = command.arguments.firstIndex(of: "--trash-list"),
           command.arguments.indices.contains(flag + 1),
           let data = FileManager.default.contents(atPath: command.arguments[flag + 1]) {
            files["--trash-list"] = data
        }
        let eventsFileExisted = command.environment["MOLE_JSON_EVENTS_FILE"]
            .map { FileManager.default.fileExists(atPath: $0) } ?? false
        lock.withLock {
            recorded.append(Call(command: command, eventsFileExisted: eventsFileExisted, files: files))
        }
        let respond = self.respond
        return AsyncThrowingStream { continuation in
            do {
                for line in try respond(command) {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits NUL-separated data back into paths.
func nulSeparatedPaths(_ data: Data?) -> [String] {
    guard let data else { return [] }
    return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}

func collectAll<Element>(_ stream: AsyncThrowingStream<Element, any Error>) async throws -> [Element] {
    var elements: [Element] = []
    for try await element in stream {
        elements.append(element)
    }
    return elements
}
```

- [ ] **Step 2: Write the failing tests** — `Tests/MoleEngineTests/ServicesTests.swift`

```swift
import Foundation
import Testing
@testable import MoleEngine

@Suite("Services")
struct ServicesTests {
    let installation: EngineInstallation

    init() throws {
        installation = try TestInstallation.make()
    }

    // MARK: Clean

    @Test func cleanScanRunsADryRunAndDecodesEvents() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"section","name":"User essentials"}"#,
            "noise from a subprocess",
            #"{"v":1,"type":"item","section":"User essentials","path":"/Users/test/Library/Caches/A","size_kb":4,"count":1,"size_known":true,"covered_by":null}"#,
        ] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.scan())
        #expect(events == [
            .section("User essentials"),
            .item(CleanItem(section: "User essentials", path: "/Users/test/Library/Caches/A", sizeBytes: 4096, sizeKnown: true)),
        ])
        let call = try #require(runner.calls.first)
        #expect(call.command.executable == installation.cleanScript)
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.eventsFileExisted)
        guard case .eventsFile(let url) = call.command.output else {
            Issue.record("clean must read events from a file")
            return
        }
        #expect(url.path == call.command.environment["MOLE_JSON_EVENTS_FILE"])
        #expect(call.command.environment["MOLE_SELECTION_FILE"] == nil)
        #expect(call.command.environment["MOLE_NO_AUTH"] == "1")
    }

    @Test func cleanSendsTheEnginePathsAsASelection() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"result","command":"clean","action":"removed","path":"/Users/test/a","detail":""}"#,
        ] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        let parent = CleanItem(section: "S", path: "/Users/test/a", sizeBytes: 10, sizeKnown: true)
        let child = CleanItem(section: "S", path: "/Users/test/a/b", sizeBytes: 5, sizeKnown: true, coveredBy: "/Users/test/a")
        let events = try await collectAll(service.clean([parent, child]))
        #expect(events == [.result(ItemResult(command: "clean", action: .removed, path: "/Users/test/a"))])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.isEmpty)
        #expect(nulSeparatedPaths(call.files["MOLE_SELECTION_FILE"]) == ["/Users/test/a"])
    }

    @Test func cleaningNothingRunsNothing() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        #expect(try await collectAll(service.clean([])).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func runFilesAreRemovedAfterTheRun() async throws {
        let runner = FakeRunner { _ in [] }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        _ = try await collectAll(service.scan())
        let eventsPath = try #require(runner.calls.first?.command.environment["MOLE_JSON_EVENTS_FILE"])
        let runDirectory = URL(fileURLWithPath: eventsPath).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
    }

    @Test func runnerErrorsReachTheCaller() async throws {
        let runner = FakeRunner { _ in throw EngineError.nonZeroExit(code: 2, stderrTail: "boom") }
        let service = CleanService(installation: installation, environment: .fixture, runner: runner)
        await #expect(throws: EngineError.nonZeroExit(code: 2, stderrTail: "boom")) {
            _ = try await collectAll(service.scan())
        }
    }

    // MARK: Uninstall

    @Test func listAppsDecodesTheInventory() async throws {
        let runner = FakeRunner { _ in [
            "Scanning applications...",
            "[",
            #"  {"name": "Foo", "bundle_id": "com.example.foo", "source": "App", "uninstall_name": "Foo", "path": "/Applications/Foo.app", "size": "1MB", "size_kb": 1024, "last_used_epoch": 0}"#,
            "]",
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let apps = try await service.listApps()
        #expect(apps.map(\.path) == ["/Applications/Foo.app"])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--list"])
        #expect(call.command.output == .stdout)
    }

    @Test func previewSendsExactPathsAndStopsAfterTheScan() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"app","path":"/Applications/Foo.app","name":"Foo","bundle_id":"com.example.foo","size_kb":10,"needs_sudo":false,"brew_cask":false,"sensitive_data":false,"running":false,"leftovers":[],"review_only":[]}"#,
            #"{"v":1,"type":"app_blocked","path":"/Applications/Safari.app","name":"","reason":"not_eligible","vendor":""}"#,
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let preview = try await service.preview(appPaths: ["/Applications/Foo.app", "/Applications/Safari.app"])
        #expect(preview.apps.map(\.path) == ["/Applications/Foo.app"])
        #expect(preview.blocked.map(\.reason) == [.notEligible])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--dry-run"])
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == "1")
        #expect(call.command.environment["MOLE_ASSUME_YES"] == "1")
        #expect(nulSeparatedPaths(call.files["MOLE_UNINSTALL_APP_PATHS_FILE"]) == ["/Applications/Foo.app", "/Applications/Safari.app"])
    }

    @Test func uninstallConfirmsWithoutPreviewMode() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"app_result","path":"/Applications/Foo.app","name":"Foo","status":"removed","freed_kb":10,"reason":""}"#,
        ] }
        let service = UninstallService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.uninstall(appPaths: ["/Applications/Foo.app"]))
        #expect(events == [.appResult(AppResult(path: "/Applications/Foo.app", name: "Foo", status: .removed, freedBytes: 10 * 1024))])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.isEmpty)
        #expect(call.command.environment["MOLE_UNINSTALL_PREVIEW_ONLY"] == nil)
        #expect(call.command.environment["MOLE_ASSUME_YES"] == "1")
    }

    // MARK: Analyzer

    @Test func analyzerCachesAFolderUntilItChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rfm-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"path":"\#(folder.path)","overview":false,"entries":[{"name":"a","path":"\#(folder.path)/a","size":10,"is_dir":false}],"total_size":10}"#
        let runner = FakeRunner { _ in [json] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)

        let first = try await service.scan(path: folder.path)
        #expect(first.entries.map(\.name) == ["a"])
        _ = try await service.scan(path: folder.path)
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.command.arguments == ["--json", folder.path])

        try await Task.sleep(for: .milliseconds(20))
        FileManager.default.createFile(atPath: folder.appending(path: "new").path, contents: nil)
        _ = try await service.scan(path: folder.path)
        #expect(runner.calls.count == 2)
    }

    @Test func analyzerOverviewPassesNoPath() async throws {
        let runner = FakeRunner { _ in [#"{"path":"/","overview":true,"entries":[],"total_size":0}"#] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)
        let level = try await service.scan(path: nil)
        #expect(level.overview)
        #expect(runner.calls.first?.command.arguments == ["--json"])
    }

    @Test func trashSendsTheListAndDecodesResults() async throws {
        let runner = FakeRunner { _ in [
            #"{"v":1,"type":"result","command":"analyze","action":"removed","path":"/Users/test/big.zip","detail":""}"#,
            #"{"v":1,"type":"summary","command":"analyze","dry_run":false,"items":1,"size_kb":0,"partial":false,"exit":0}"#,
        ] }
        let service = AnalyzerService(installation: installation, environment: .fixture, runner: runner)
        let events = try await collectAll(service.trash(["/Users/test/big.zip"]))
        #expect(events.first == .result(ItemResult(command: "analyze", action: .removed, path: "/Users/test/big.zip")))
        #expect(events.count == 2)
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments.first == "--trash-list")
        #expect(call.command.output == .stdout)
        #expect(nulSeparatedPaths(call.files["--trash-list"]) == ["/Users/test/big.zip"])
    }

    // MARK: Status

    @Test func statusStreamsDecodedSnapshots() async throws {
        let runner = FakeRunner { _ in [
            #"{"host":"a","cpu":{"core_count":8}}"#,
            "garbage",
            #"{"host":"b","cpu":{"core_count":8}}"#,
        ] }
        let service = StatusService(installation: installation, environment: .fixture, runner: runner)
        let snapshots = try await collectAll(service.snapshots(interval: .seconds(2)))
        #expect(snapshots.map(\.host) == ["a", "b"])
        let call = try #require(runner.calls.first)
        #expect(call.command.arguments == ["--watch", "--interval", "2s"])
        #expect(call.command.timeout == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Packages/MoleEngine`
Expected: FAIL to compile — `cannot find 'CleanService' in scope` and the other services.

- [ ] **Step 4: Write the shared run plumbing** — `Sources/MoleEngine/Services/EventRun.swift`

```swift
import Foundation

/// What a service passes to one engine command. Decided after the run's
/// scratch files exist, so selection and list files can be referenced.
struct Invocation: Sendable {
    var arguments: [String] = []
    var variables: [String: String] = [:]
}

/// Shared plumbing for the services: creates the run's scratch files, builds
/// the environment, runs the command, and removes the files afterwards.
struct EventRun: Sendable {
    enum Source: Sendable {
        /// The command appends events to MOLE_JSON_EVENTS_FILE.
        case eventsFile
        /// The command prints its output on stdout.
        case stdout
    }

    let installation: EngineInstallation
    let environment: EngineEnvironment
    let runner: any EngineRunning
    let scratchDirectory: URL

    func events(
        executable: URL,
        timeout: Duration?,
        source: Source,
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) -> AsyncThrowingStream<EngineEvent, any Error> {
        stream(executable: executable, timeout: timeout, source: source, configure: configure) {
            EngineEventDecoder.decode($0)
        }
    }

    /// Everything the command printed on stdout.
    func stdoutData(
        executable: URL,
        timeout: Duration?,
        configure: @escaping @Sendable (RunFiles) throws -> Invocation
    ) async throws -> Data {
        var data = Data()
        let lines = stream(executable: executable, timeout: timeout, source: .stdout, configure: configure) { $0 }
        for try await line in lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    func stream<Element: Sendable>(
        executable: URL,
        timeout: Duration?,
        source: Source,
        configure: @escaping @Sendable (RunFiles) throws -> Invocation,
        transform: @escaping @Sendable (String) -> Element?
    ) -> AsyncThrowingStream<Element, any Error> {
        let installation = self.installation
        let environment = self.environment
        let runner = self.runner
        let scratchDirectory = self.scratchDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                let files: RunFiles
                do {
                    files = try RunFiles.make(in: scratchDirectory)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer { files.remove() }
                do {
                    let invocation = try configure(files)
                    var variables = environment.variables(for: installation)
                    if source == .eventsFile {
                        variables["MOLE_JSON_EVENTS_FILE"] = files.events.path
                    }
                    variables.merge(invocation.variables) { _, new in new }
                    let command = EngineCommand(
                        executable: executable,
                        arguments: invocation.arguments,
                        environment: variables,
                        output: source == .eventsFile ? .eventsFile(files.events) : .stdout,
                        stderrLog: files.stderrLog,
                        timeout: timeout
                    )
                    for try await line in runner.lines(for: command) {
                        if let element = transform(line) {
                            continuation.yield(element)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 5: Write the services**

`Sources/MoleEngine/Services/CleanService.swift`
```swift
import Foundation

/// Smart Clean on top of the engine: preview everything, then remove exactly
/// the previewed items the user selected.
public struct CleanService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Previews everything Smart Clean would remove (`clean --dry-run`).
    /// Emits `section` and `candidate` progress, then the final `item`s and a `summary`.
    public func scan() -> AsyncThrowingStream<EngineEvent, any Error> {
        run.events(executable: run.installation.cleanScript, timeout: .seconds(1800), source: .eventsFile) { _ in
            Invocation(arguments: ["--dry-run"])
        }
    }

    /// Removes exactly the selected preview items. Fold the `result` events
    /// with `CleanRunTally` to learn what was actually removed.
    public func clean(_ selection: [CleanItem]) -> AsyncThrowingStream<EngineEvent, any Error> {
        let paths = CleanSelection.enginePaths(for: selection)
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.cleanScript, timeout: .seconds(3600), source: .eventsFile) { files in
            Invocation(variables: ["MOLE_SELECTION_FILE": try files.writeNULSeparated(paths, named: "selection").path])
        }
    }
}
```

`Sources/MoleEngine/Services/UninstallService.swift`
```swift
import Foundation

/// What uninstalling some apps would remove, and which apps cannot be removed.
public struct UninstallPreview: Sendable, Equatable {
    public var apps: [AppPreview]
    public var blocked: [BlockedApp]

    public init(apps: [AppPreview] = [], blocked: [BlockedApp] = []) {
        self.apps = apps
        self.blocked = blocked
    }
}

/// The Uninstaller on top of the engine. Apps are always addressed by exact
/// bundle path; removal moves everything to the Trash.
public struct UninstallService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Every app the uninstaller may remove.
    public func listApps() async throws -> [InstalledApp] {
        let data = try await run.stdoutData(executable: run.installation.uninstallScript, timeout: .seconds(600)) { _ in
            Invocation(arguments: ["--list"])
        }
        return try InstalledApp.decodeList(from: data)
    }

    /// What uninstalling these apps would remove. Changes nothing.
    public func preview(appPaths: [String]) async throws -> UninstallPreview {
        var preview = UninstallPreview()
        guard !appPaths.isEmpty else { return preview }
        let events = run.events(executable: run.installation.uninstallScript, timeout: .seconds(600), source: .eventsFile) { files in
            Invocation(arguments: ["--dry-run"], variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(appPaths, named: "apps").path,
                "MOLE_UNINSTALL_PREVIEW_ONLY": "1",
                "MOLE_ASSUME_YES": "1",
            ])
        }
        for try await event in events {
            switch event {
            case .app(let app):
                preview.apps.append(app)
            case .appBlocked(let blocked):
                preview.blocked.append(blocked)
            default:
                break
            }
        }
        return preview
    }

    /// Uninstalls the apps the user confirmed in a preview. Quit them first:
    /// with a GUI host the engine never asks apps to quit itself.
    public func uninstall(appPaths: [String]) -> AsyncThrowingStream<EngineEvent, any Error> {
        guard !appPaths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.uninstallScript, timeout: .seconds(1800), source: .eventsFile) { files in
            Invocation(variables: [
                "MOLE_UNINSTALL_APP_PATHS_FILE": try files.writeNULSeparated(appPaths, named: "apps").path,
                "MOLE_ASSUME_YES": "1",
            ])
        }
    }
}
```

`Sources/MoleEngine/Services/AnalyzerService.swift`
```swift
import Foundation

/// Keeps scanned disk levels: folders until their modification date changes,
/// the machine-wide overview for a short time.
public actor DiskLevelCache {
    static let overviewKey = "\u{0}overview"

    private struct Entry {
        let level: DiskLevel
        let modified: Date?
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    public let overviewLifetime: TimeInterval

    public init(overviewLifetime: TimeInterval = 60) {
        self.overviewLifetime = overviewLifetime
    }

    func level(for key: String, modified: Date?, now: Date) -> DiskLevel? {
        guard let entry = entries[key] else { return nil }
        if key == Self.overviewKey {
            return now.timeIntervalSince(entry.storedAt) < overviewLifetime ? entry.level : nil
        }
        return entry.modified == modified ? entry.level : nil
    }

    func store(_ level: DiskLevel, for key: String, modified: Date?, now: Date) {
        entries[key] = Entry(level: level, modified: modified, storedAt: now)
    }

    func remove(_ key: String) {
        entries[key] = nil
    }
}

/// The disk explorer on top of the engine.
public struct AnalyzerService: Sendable {
    let run: EventRun
    let cache: DiskLevelCache

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        cache: DiskLevelCache = DiskLevelCache()
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
        self.cache = cache
    }

    /// One level of the explorer; nil scans the machine-wide overview.
    public func scan(path: String?) async throws -> DiskLevel {
        let key = path ?? DiskLevelCache.overviewKey
        let modified = path.flatMap(Self.modificationDate(of:))
        if let cached = await cache.level(for: key, modified: modified, now: Date()) {
            return cached
        }
        let arguments = path.map { ["--json", $0] } ?? ["--json"]
        let data = try await run.stdoutData(executable: run.installation.analyzeBinary, timeout: .seconds(900)) { _ in
            Invocation(arguments: arguments)
        }
        let level = try EngineJSON.decoder().decode(DiskLevel.self, from: data)
        await cache.store(level, for: key, modified: modified, now: Date())
        return level
    }

    /// Forgets a cached folder, for example after moving items out of it.
    public func invalidate(path: String) async {
        await cache.remove(path)
    }

    /// Moves the paths to the Trash through the engine's own safety rules.
    /// Emits one `result` per path and a `summary`.
    public func trash(_ paths: [String]) -> AsyncThrowingStream<EngineEvent, any Error> {
        guard !paths.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }
        return run.events(executable: run.installation.analyzeBinary, timeout: .seconds(900), source: .stdout) { files in
            Invocation(arguments: ["--trash-list", try files.writeNULSeparated(paths, named: "trash").path])
        }
    }

    static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
```

`Sources/MoleEngine/Services/StatusService.swift`
```swift
import Foundation

/// Live system readings from one long-running collector.
public struct StatusService: Sendable {
    let run: EventRun

    public init(
        installation: EngineInstallation,
        environment: EngineEnvironment = .current(),
        runner: any EngineRunning = MoleRunner(),
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        run = EventRun(installation: installation, environment: environment, runner: runner, scratchDirectory: scratchDirectory)
    }

    /// Snapshots every `interval` (whole seconds, at least 1). The collector
    /// keeps running until iteration ends.
    public func snapshots(interval: Duration = .seconds(2)) -> AsyncThrowingStream<SystemSnapshot, any Error> {
        let seconds = max(1, interval.components.seconds)
        return run.stream(executable: run.installation.statusBinary, timeout: nil, source: .stdout) { _ in
            Invocation(arguments: ["--watch", "--interval", "\(seconds)s"])
        } transform: { line in
            try? EngineJSON.decoder().decode(SystemSnapshot.self, from: Data(line.utf8))
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift build --package-path Packages/MoleEngine --build-tests 2>&1 | grep -E "error|warning:" ; swift test --package-path Packages/MoleEngine`
Expected: no errors or warnings; PASS, 50 tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/MoleEngine
git commit -m "feat(engine-kit): clean, uninstall, analyzer and status services"
```

---

### Task 12: Integration tests against the real engine

**Files:**
- Test: `Packages/MoleEngine/Tests/MoleEngineTests/Support/FakeHome.swift`, `Packages/MoleEngine/Tests/MoleEngineTests/Integration/EngineIntegrationTests.swift`

**Interfaces:**
- Consumes: every service (Task 11), `CleanRunTally`/`CleanSelection` (Task 10), the built engine from Tasks 2–7 via `RFM_ENGINE_DIR`.
- Produces: the end-to-end proof of the safety contract — a selected clean removes exactly the selected previewed items and nothing outside the fake home; an uninstall previews without changes, then moves the app and its leftovers to a private Trash. Test helpers: `FakeHome.make()`, `environment()`, `makeFile(_:kilobytes:)`, `makeApp(named:bundleId:)`, `rmRefusalLines()`, `remove()`; `IntegrationEngine.root`, `IntegrationEngine.installation()`.

These tests run only when `RFM_ENGINE_DIR` points at a built engine; otherwise the suite reports "skipped". They are the parser coverage against real engine output (roadmap decision 4). The uninstall test scans your real `/Applications` read-only, which takes a minute or two on a cold metadata cache.

- [ ] **Step 1: Write the fake home** — `Tests/MoleEngineTests/Support/FakeHome.swift`

```swift
import Foundation
@testable import MoleEngine

/// A throwaway home for running the real engine: fake HOME and TMPDIR,
/// deterministic tool stubs, a private Trash, and an rm guard that refuses
/// (and logs) any removal outside the fake root.
struct FakeHome {
    let root: URL

    var home: URL { root.appending(path: "home") }
    var temporary: URL { root.appending(path: "tmp") }
    var stubs: URL { root.appending(path: "stubs") }
    var trash: URL { root.appending(path: "trash") }
    var rmRefusals: URL { root.appending(path: "rm-refusals.log") }

    static func make() throws -> FakeHome {
        // Resolve /var → /private/var so our paths match the ones the engine reports.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let fake = FakeHome(root: base.appending(path: "rfm-home-\(UUID().uuidString)"))
        for directory in [
            fake.home, fake.temporary, fake.stubs, fake.trash,
            fake.home.appending(path: "Library/Caches"),
            fake.home.appending(path: "Applications"),
            fake.home.appending(path: ".config/mole"),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fake.writeStub("brew", """
        case "${1:-}" in
            --cache) echo "$HOME/Library/Caches/Homebrew" ;;
            --prefix) echo "$HOME/homebrew" ;;
        esac
        exit 0
        """)
        try fake.writeStub("xcrun", "exit 1")
        try fake.writeStub("lsof", """
        case " $* " in
            *" -p 1 "*) printf 'p1\\nu0\\n'; exit 0 ;;
            *) exit 1 ;;
        esac
        """)
        try fake.writeStub("ps", "printf '  PID  PPID COMM ARGS\\n'")
        try fake.writeStub("osascript", "exit 1")
        try fake.writeStub("launchctl", "exit 0")
        try fake.writeStub("mdfind", "exit 0")
        try fake.writeStub("killall", "exit 0")
        try fake.writeStub("rm", """
        for arg in "$@"; do
            case "$arg" in
                -*) ;;
                "\(fake.root.path)"/*) ;;
                *) printf '%s\\n' "$arg" >> "\(fake.rmRefusals.path)"; exit 1 ;;
            esac
        done
        exec /bin/rm "$@"
        """)
        return fake
    }

    func environment() -> EngineEnvironment {
        EngineEnvironment(
            home: home.path,
            user: NSUserName(),
            temporaryDirectory: temporary.path,
            pathPrefix: [stubs.path],
            extra: ["MOLE_LSREGISTER_PATH": "", "MOLE_TEST_TRASH_DIR": trash.path]
        )
    }

    @discardableResult
    func makeFile(_ relative: String, kilobytes: Int) throws -> URL {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(count: kilobytes * 1024)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func makeApp(named name: String, bundleId: String) throws -> URL {
        let app = home.appending(path: "Applications/\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: macOS.appending(path: name).path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let info: [String: String] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    func rmRefusalLines() -> [String] {
        let text = (try? String(contentsOf: rmRefusals, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStub(_ name: String, _ body: String) throws {
        let url = stubs.appending(path: name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 2: Write the integration tests** — `Tests/MoleEngineTests/Integration/EngineIntegrationTests.swift`

```swift
import Foundation
import Testing
@testable import MoleEngine

enum IntegrationEngine {
    /// A built engine (scripts/build-engine.sh). The suite is skipped without it.
    static var root: URL? {
        ProcessInfo.processInfo.environment["RFM_ENGINE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func installation() throws -> EngineInstallation {
        guard let root else {
            throw EngineError.installationInvalid("RFM_ENGINE_DIR is not set")
        }
        return try EngineInstallation(root: root)
    }
}

@Suite(
    "Engine integration",
    .enabled(if: IntegrationEngine.root != nil, "set RFM_ENGINE_DIR to a built engine"),
    .serialized
)
struct EngineIntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func statusStreamsLiveSnapshots() async throws {
        let service = StatusService(installation: try IntegrationEngine.installation())
        var first: SystemSnapshot?
        for try await snapshot in service.snapshots(interval: .seconds(1)) {
            first = snapshot
            break
        }
        let snapshot = try #require(first)
        #expect((snapshot.cpu?.coreCount ?? 0) > 0)
        #expect((snapshot.memory?.total ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func analyzerMeasuresAFolder() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        try fake.makeFile("Documents/big.bin", kilobytes: 4096)
        try fake.makeFile("Documents/small.bin", kilobytes: 16)
        let service = AnalyzerService(installation: try IntegrationEngine.installation(), environment: fake.environment())
        let level = try await service.scan(path: fake.home.appending(path: "Documents").path)
        let big = try #require(level.entries.first { $0.name == "big.bin" })
        #expect(big.size >= 4096 * 1024)
        #expect(level.entries.contains { $0.name == "small.bin" })
    }

    @Test(.timeLimit(.minutes(2)))
    func analyzerTrashRefusesProtectedPaths() async throws {
        let service = AnalyzerService(installation: try IntegrationEngine.installation())
        var results: [ItemResult] = []
        for try await event in service.trash(["/System/Library"]) {
            if case .result(let result) = event {
                results.append(result)
            }
        }
        #expect(results.map(\.action) == [.failed])
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
    }

    @Test(.timeLimit(.minutes(10)))
    func cleanRemovesExactlyTheSelectedItems() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let caches = fake.home.appending(path: "Library/Caches")
        try fake.makeFile("Library/Caches/com.example.alpha/blob.bin", kilobytes: 2048)
        try fake.makeFile("Library/Caches/com.example.beta/blob.bin", kilobytes: 1024)
        try fake.makeFile("Library/Caches/com.example.gamma café/blob.bin", kilobytes: 512)
        let service = CleanService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        var items: [CleanItem] = []
        for try await event in service.scan() {
            if case .item(let item) = event {
                items.append(item)
            }
        }
        let alpha = caches.appending(path: "com.example.alpha").path
        let beta = caches.appending(path: "com.example.beta").path
        let gamma = caches.appending(path: "com.example.gamma café").path
        func isUnder(_ item: CleanItem, _ root: String) -> Bool {
            item.path == root || item.path.hasPrefix(root + "/")
        }
        #expect(items.contains { isUnder($0, beta) })
        let selected = items.filter { isUnder($0, alpha) || isUnder($0, gamma) }
        #expect(selected.contains { isUnder($0, alpha) })
        #expect(selected.contains { isUnder($0, gamma) })

        var tally = CleanRunTally(selection: selected)
        for try await event in service.clean(selected) {
            tally.record(event)
        }
        #expect(tally.unexpectedRemovals.isEmpty)
        #expect(Set(tally.removedItems.map(\.path)) == Set(CleanSelection.enginePaths(for: selected)))
        #expect(!FileManager.default.fileExists(atPath: alpha + "/blob.bin"))
        #expect(!FileManager.default.fileExists(atPath: gamma + "/blob.bin"))
        #expect(FileManager.default.fileExists(atPath: beta + "/blob.bin"))
        #expect(fake.rmRefusalLines().isEmpty)
    }

    @Test(.timeLimit(.minutes(15)))
    func uninstallPreviewsThenMovesTheAppToTheTrash() async throws {
        let fake = try FakeHome.make()
        defer { fake.remove() }
        let app = try fake.makeApp(named: "RFMFixture", bundleId: "com.example.rfmfixture")
        let support = try fake.makeFile("Library/Application Support/RFMFixture/state.json", kilobytes: 4)
        let service = UninstallService(installation: try IntegrationEngine.installation(), environment: fake.environment())

        let apps = try await service.listApps()
        #expect(apps.contains { $0.path == app.path })

        let preview = try await service.preview(appPaths: [app.path])
        let planned = try #require(preview.apps.first { $0.path == app.path })
        #expect(planned.leftovers.contains(support.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: app.path))

        var results: [AppResult] = []
        for try await event in service.uninstall(appPaths: [app.path]) {
            if case .appResult(let result) = event {
                results.append(result)
            }
        }
        #expect(results.map(\.status) == [.removed])
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!FileManager.default.fileExists(atPath: support.path))
        #expect(fake.rmRefusalLines().isEmpty)
    }
}
```

- [ ] **Step 3: Confirm the suite skips without an engine**

Run: `swift test --package-path Packages/MoleEngine`
Expected: PASS — 50 tests pass and `Suite "Engine integration" skipped: "set RFM_ENGINE_DIR to a built engine"`.

- [ ] **Step 4: Run it against the patched engine**

Run: `scripts/build-engine.sh && RFM_ENGINE_DIR="$PWD/build/engine" swift test --package-path Packages/MoleEngine --filter "Engine integration"`
Expected: PASS, 5 tests, no `rm` refusals.

If a test fails, read it as a finding, not as noise:
- `cleanRemovesExactlyTheSelectedItems` failing on `unexpectedRemovals` or on `rmRefusalLines()` means a deletion path escaped the selection gates — return to Task 5 Step 9 and gate it.
- `items.contains { isUnder($0, beta) }` failing means Mole previews `~/Library/Caches` children at a different granularity than expected; print `items.map(\.path)` and adjust only the fixture layout, never the safety assertions.
- The uninstall test failing at `listApps` usually means a stub is missing for a tool the scan now calls; add it to `FakeHome.make()`.

- [ ] **Step 5: Commit**

```bash
git add Packages/MoleEngine
git commit -m "test(engine-kit): end-to-end engine integration suite"
```

---

### Task 13: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: everything above.
- Produces: one CI job on `macos-26` that audits the build checks for bare `[[ ]]` assertions, builds the patched engine, runs the build checks, the patch tests, the analyzer Go tests, Mole's full suite on the patched tree, and the Swift package including the integration suite.

- [ ] **Step 1: Write the workflow** — `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
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
```

- [ ] **Step 2: Run the same sequence locally**

Run:
```bash
shellcheck scripts/*.sh && shfmt -d -i 4 -ci -sr scripts/*.sh \
  && python3 vendor/mole/scripts/audit_bats_assertions.py scripts/tests/*.bats \
  && scripts/build-engine.sh && bats scripts/tests \
  && scripts/mole-patches.sh test --tree build/engine-src tests/host_integration.bats tests/clean_json_events.bats tests/clean_selection.bats tests/uninstall_host_mode.bats \
  && (cd build/engine-src && go test ./cmd/analyze -run TrashList -count=1 && ./scripts/test.sh) \
  && RFM_ENGINE_DIR="$PWD/build/engine" swift test --package-path Packages/MoleEngine
```
Expected: every step passes.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build the patched engine and run every engine and package test"
```

- [ ] **Step 4: Push and watch CI — only after the user approves pushing**

Pushing publishes the repository contents. Ask first; once approved: `git push -u origin main`, then check the run in GitHub Actions. Expected: the `Engine and MoleEngine` job is green.

---

## Done when

- `patches/mole/` holds five patches that apply cleanly to `V1.56.0`, each with its own tests, and Mole's full suite passes on the patched tree.
- `scripts/build-engine.sh` produces `build/engine` with universal binaries, `host-bin/sudo` and a `VERSION` recording `patch_count=5`.
- `swift test --package-path Packages/MoleEngine` passes 50 unit tests, and with `RFM_ENGINE_DIR` set, the 5 integration tests too.
- `docs/engine-protocol.md` documents every host variable and event the package relies on.
- The next plan (App shell, design system, onboarding) can start: it bundles `build/engine` into the app and calls the services above.
