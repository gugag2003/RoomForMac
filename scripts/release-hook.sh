#!/bin/bash
# Runs one optional per-release hook, scripts/release-hooks/<name>, or skips it.
# release.yml calls this for the one hook there is, token-fixture, which
# scripts/release-hooks/README.md specifies. No hook file exists until the
# licensing work (Plan 5) adds one, so until then the call is a no-op.
#
#   scripts/release-hook.sh [--required] <name> [args...]
#
#     the hook exists and is an executable file   run it in the caller's working
#                                                 directory with args...; its exit
#                                                 status is this script's
#     the hook does not exist                     print "skipped: no release hook
#                                                 <name>" to stderr and exit 0, or
#                                                 exit 1 with --required
#     the hook exists but is not executable       exit 1, with or without --required
#     no name, or a name that is not a hook name  exit 2 (usage)
#
# --required counts only as the first argument; after the name, everything is
# handed to the hook unchanged. Hook names are lower-case words joined by
# hyphens, so a name cannot leave scripts/release-hooks/.
#
# The script prints the hook's name, never its arguments or the environment: a
# hook may run with secrets in its environment (RFM_FIXTURE_TOKEN_KEY).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$ROOT/scripts/release-hooks"

usage() {
    cat << 'USAGE'
Usage: scripts/release-hook.sh [--required] <name> [args...]
       scripts/release-hook.sh --help
USAGE
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    usage >&2
    exit 2
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

required=0
if [[ "${1:-}" == "--required" ]]; then
    required=1
    shift
fi
if [[ $# -eq 0 ]]; then
    usage_error "a hook name is required"
fi
name="$1"
shift
# Spelled out, not as ranges: [a-z] can match accented letters in a UTF-8 locale.
letters="abcdefghijklmnopqrstuvwxyz"
case "$name" in
    '' | [!"$letters"]* | *[!"${letters}0123456789-"]*)
        usage_error "not a release hook name: $name"
        ;;
esac

hook="$HOOKS/$name"
if [[ ! -e "$hook" && ! -L "$hook" ]]; then
    if [[ "$required" -eq 1 ]]; then
        printf 'error: release hook %s is required but scripts/release-hooks/%s does not exist\n' "$name" "$name" >&2
        exit 1
    fi
    printf 'skipped: no release hook %s\n' "$name" >&2
    exit 0
fi
if [[ ! -f "$hook" || ! -x "$hook" ]]; then
    printf 'error: release hook %s exists but scripts/release-hooks/%s is not an executable file\n' "$name" "$name" >&2
    exit 1
fi

printf 'running release hook %s\n' "$name" >&2
exec "$hook" "$@"
