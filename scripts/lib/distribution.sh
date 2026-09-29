#!/bin/bash
# Reads Config/Distribution.xcconfig, the one file that holds RoomForMac's
# distribution identifiers (repository, feed and site URLs, disk image name,
# update public key). Xcode reads the same file through Config/App.xcconfig;
# this is the only other parser of it, so scripts, bats tests and workflows call
# distribution_value instead of grepping.
#
#   distribution_value ROOT KEY   prints KEY's value from
#                                 ROOT/Config/Distribution.xcconfig
#
# Xcode reads "//" as a comment, so the file writes a URL as ":/$()/", where
# $() expands to nothing. The parser removes every "$()" the same way and
# expands nothing else: it never evaluates, sources or substitutes what it
# reads. It skips blank lines, lines that start with "//" or "#", and a trailing
# comment that starts at the first whitespace followed by "//". It trims spaces
# and tabs around the name and the value, and splits at the first "=", so a
# value may contain more of them (a base64 key ends with one). It reads only
# that file: never Config/Local.xcconfig, which overrides settings for Xcode
# alone, and never a command-line setting.
#
# A failing call prints "error: ..." to stderr and returns 1. Through $(...),
# run or ||, that is exit status 1. It does not call exit, so a caller that
# invokes it directly keeps running.
#
# Sourcing it defines functions only; it sets no shell options.

# _distribution_trim TEXT: prints TEXT without leading or trailing whitespace.
_distribution_trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

distribution_value() {
    local root="${1-}" key="${2-}"
    if [[ -z "$root" || -z "$key" ]]; then
        echo "error: usage: distribution_value ROOT KEY" >&2
        return 1
    fi
    local file="$root/Config/Distribution.xcconfig"
    if [[ ! -f "$file" ]]; then
        echo "error: $file does not exist" >&2
        return 1
    fi

    # shellcheck disable=SC2016 # "$()" is the literal text the file uses
    local empty_expansion='$()' line name value result="" found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(_distribution_trim "$line")"
        case "$line" in
            '' | '//'* | '#'*) continue ;;
        esac
        line="${line%%[[:space:]]//*}"
        [[ "$line" == *=* ]] || continue
        name="$(_distribution_trim "${line%%=*}")"
        [[ "$name" == "$key" ]] || continue
        value="$(_distribution_trim "${line#*=}")"
        result="${value//"$empty_expansion"/}"
        found=$((found + 1))
    done < "$file"

    if [[ "$found" -eq 0 ]]; then
        echo "error: $key is not defined in $file" >&2
        return 1
    fi
    if [[ "$found" -gt 1 ]]; then
        echo "error: $key is defined more than once in $file" >&2
        return 1
    fi
    printf '%s\n' "$result"
}
