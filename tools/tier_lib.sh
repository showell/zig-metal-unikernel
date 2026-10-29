# **WHAT EVERY TIER SCRIPT SHARES** (tier0.sh .. tier3.sh, metal-vmm QUEUE
# 197): sourced, never run. The repo's root as the working directory, the
# list of steps that failed, a lap timer, the sibling checkouts, and the
# verdict line.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

failed=()
source "$HERE/tools/skip_lib.sh"
# Each step's time, printed as "time: <step> <seconds> s", so where a run's
# minutes go is read off the output rather than guessed.
t=$SECONDS
lap() { echo "time: $1 $((SECONDS - t)) s"; t=$SECONDS; }

# **THE SIBLINGS ARE BESIDE THIS CHECKOUT** unless named (GOPHER_ROOT,
# WEBBOX_ROOT, SHALE_CHECKOUT, CHAT_MARKDOWN_ROOT, CHAT_CLIENT_ROOT,
# METAL_VMM): ../<name>, as build.zig's own
# defaults and every script's (README, "What you need"): on the box that is
# ~/showell_repos/<name>, and in check-cc.sh's
# worktrees is the worktree's sibling. Only tiers 2 and 3 read them.
sibling() { (cd "$HERE/../$1" 2>/dev/null && pwd) || echo "$HERE/../$1"; }
GOPHER_ROOT="${GOPHER_ROOT:-$(sibling angry-gopher)}"
WEBBOX_ROOT="${WEBBOX_ROOT:-$(sibling zig-webbox)}"
# Not SHALE_ROOT: that is the `shale` CLI's own, its data root, which every
# shale run under a tier would then take (tier 3's doc check found no repos).
SHALE_CHECKOUT="${SHALE_CHECKOUT:-$(sibling shale)}"
CHAT_MARKDOWN_ROOT="${CHAT_MARKDOWN_ROOT:-$(sibling chat-markdown)}"
CHAT_CLIENT_ROOT="${CHAT_CLIENT_ROOT:-$(sibling chat-client)}"
VMM="${METAL_VMM:-$(sibling metal-vmm)}"
export GOPHER_ROOT WEBBOX_ROOT SHALE_CHECKOUT CHAT_MARKDOWN_ROOT CHAT_CLIENT_ROOT
ZIG_SIBLINGS=(-Dgopher-root="$GOPHER_ROOT" -Dwebbox-root="$WEBBOX_ROOT" -Dshale-root="$SHALE_CHECKOUT" -Dchat-markdown-root="$CHAT_MARKDOWN_ROOT" -Dchat-client-root="$CHAT_CLIENT_ROOT")
# Kept results, as gates.sh always kept them.
VERDICTS="${GATES_VERDICTS:-$HOME/build/zig-metal-unikernel/gates}"
mkdir -p "$VERDICTS"

# Every command a tier needs, or the tier stops before its first step and
# says which are missing: a tier that cannot run is not a tier that passed.
need() {
    local missing=()
    for c in "$@"; do command -v "$c" > /dev/null 2>&1 || missing+=("$c"); done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "$TIER: NOT RUN: missing ${missing[*]}"
        exit 2
    fi
}

# The tier's last line: PASS, or FAIL naming each step. Its exit code is
# the verdict.
verdict() {
    if [ ${#failed[@]} = 0 ]; then passed "$TIER"; fi
    echo "$TIER: FAIL (${failed[*]})${not_run[*]:+, and NOT RUN: ${not_run[*]}}"
    exit 1
}
