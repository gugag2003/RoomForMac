#!/usr/bin/env bash
# Loaded by build_engine.bats and app_bundle.bats (`load status_stub_spy`).
#
# The status stubs fall back to the real tools: system_profiler runs
# /usr/sbin/system_profiler for every data type but Bluetooth. A test that ran
# the real stub would, if the stub ever regressed, run the very query the stub
# exists to avoid (U6: it may raise a Bluetooth privacy prompt), or send Finder
# an Apple event through osascript. Tests never raise a real system prompt, so
# they run a scratch copy of the stub instead, whose real-tool paths point at
# spies. The spies are also first on PATH; each one logs its arguments and
# exits 0.

# spy_stub <stub>: copies <stub> to $BATS_TEST_TMPDIR/spied/, with
# /usr/sbin/system_profiler and /usr/bin/osascript replaced by the spies.
# Sets SPIED (the copy), SPY_PATH (a PATH with the spies first) and SPY_LOG
# (one line per spy call: the tool's name, then its arguments).
spy_stub() {
    local stub="$1"
    local dir="$BATS_TEST_TMPDIR/spied"
    local tool
    mkdir -p "$dir/spies"
    SPY_LOG="$BATS_TEST_TMPDIR/spy.log"
    : > "$SPY_LOG"
    for tool in system_profiler osascript; do
        cat > "$dir/spies/$tool" << SPY
#!/bin/bash
echo "$tool \$*" >> "$SPY_LOG"
exit 0
SPY
        chmod +x "$dir/spies/$tool"
    done
    SPIED="$dir/$(basename "$stub")"
    sed -e "s#/usr/sbin/system_profiler#$dir/spies/system_profiler#g" \
        -e "s#/usr/bin/osascript#$dir/spies/osascript#g" "$stub" > "$SPIED"
    chmod +x "$SPIED"
    # The copy must not reach a real tool by its full path.
    if grep -q -e /usr/sbin/system_profiler -e /usr/bin/osascript "$SPIED"; then
        echo "spy_stub: $SPIED still names a real tool" >&2
        return 1
    fi
    SPY_PATH="$dir/spies:$PATH"
    export SPIED SPY_PATH SPY_LOG
}
