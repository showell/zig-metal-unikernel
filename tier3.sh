#!/bin/bash
# **TIER 3: TIER 2, AND ZIG-WEBBOX AND THE APPLICATIONS** (metal-vmm QUEUE
# 197). Everything that compiles or judges code outside this repo: the
# library's own tests and the limits it copies; the unit tests' pinned body
# rule against the library's; gopher.elf (angry-gopher's chat) type-checked,
# built and judged against its Linux build on two machines; the site
# volume, and metal-vmm on gopher.elf (the PC-shaped machine's rests, the
# timeouts). Needs angry-gopher and zig-webbox beside this checkout (or
# GOPHER_ROOT, WEBBOX_ROOT), and tier 2's metal-vmm and KVM. Dog Park is not
# judged here (Steve, 2026-10-13): an application is not this repo's test of
# itself.
#
#   ./tier3.sh          the whole tier
#   ./tier3.sh quick    gopher.elf built and one chat-judge story (members,
#                       FAT32, microvm): gates.sh quick's last part
#
# **gopher.elf IS REBUILT HERE.** `probe/run.sh gopher` judges whatever
# gopher.elf is on disk, so a tier that skipped this judged yesterday's kernel.
#
# **THE CHAT JUDGE RUNS FAT32 HERE, FAT16 IN long.sh** (QUEUE.md item 88):
# prod's data is a FAT32 volume.
#
# **SKIP="word …"** leaves slow steps out (tools/skip_lib.sh): webbox-test, vmm-pc, pair, sleeps, vmm-timeouts, gopher-judges.
# A run with a skip ends NOT A PASS, exit 3, and keeps no verdict.
TIER="tier 3"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig python3 qemu-system-x86_64 mkfs.vfat sgdisk mcopy curl
mode="${1:-full}"
case "$mode" in
    full | quick) ;;
    *) echo "usage: ./tier3.sh [quick]"; exit 2 ;;
esac
# A quick run says it was quick, on its last line too.
[ "$mode" = quick ] && TIER="tier 3 quick (gopher.elf and one story, not tier 3)"

# **WHICH CODE THIS RUN JUDGES** (tools/verdicts.py): every checkout, printed,
# and one the build cannot take refused. gates.sh computes it first, so the
# verdict it records is for this pair.
if [ -z "${VERDICT_PAIR:-}" ]; then
    VERDICT_PAIR="$(python3 tools/verdicts.py ids)" || { echo "$TIER: NOT RUN: tools/verdicts.py ids refused these checkouts"; exit 2; }
    export VERDICT_PAIR
    python3 tools/verdicts.py pair
fi

# **THE DOCS' CITED PATHS AND NAMES**, this repo's (zig-webbox's
# tools/doc_check.shale, a few seconds): before the minutes.
(cd "${WEBBOX_ROOT:-$HERE/../zig-webbox}" && zig build doc-check -- only=zig-metal-unikernel) > "$VERDICTS/tier3-docs.txt" 2>&1 \
    || { failed+=(docs); grep -E "gone |ambiguous |names gone |findings" "$VERDICTS/tier3-docs.txt" | head -9; }
lap "the docs' cited paths and names"

zig build gopher "${ZIG_SIBLINGS[@]}" 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(gopher-build)
lap "gopher.elf"

if [ "$mode" = quick ]; then
    # A single story (the member story: login, chat, topics, admin, logout)
    # on one machine, FAT32, so a single commit is answered in minutes.
    (cd "$GOPHER_ROOT/zig-server" && zig build) > "$VERDICTS/linux-build.txt" 2>&1
    JUDGE_ONLY=members PROBE_WORK="$HOME/build/zig-metal-unikernel/probe-quick" \
        probe/run.sh gopher > "$VERDICTS/gopher-quick.run" 2>&1
    code=$?
    sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p' "$VERDICTS/gopher-quick.run"
    { [ "$code" = 0 ] && grep -q "^PASS gopher" "$VERDICTS/gopher-quick.run"; } || failed+=(gopher-quick)
    lap "one chat-judge story (members, FAT32)"
    verdict
fi

# ── the library, and what this repo takes from it ────────────────────────────
# The limits the store copies from disk_fat.zig and io.zig (tools/check_limits.py).
python3 tools/check_limits.py "$WEBBOX_ROOT/src" || failed+=(limits)
# The unit tests' copy of the body rule, the same as the library's.
zig build pinned "${ZIG_SIBLINGS[@]}" 2>&1 | grep pinned
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(pinned)
# gopher.elf type-checked as `check` does this repo's kernels (Debug, every
# path analysed), not only built.
zig build check-apps "${ZIG_SIBLINGS[@]}" 2>&1 | grep -E "error|NOT type-checked"
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(check-apps)
# The library's own tests, on its Linux host.
if ! skip webbox-test; then
    (cd "$WEBBOX_ROOT" && zig build test 2>&1 | tail -5; exit "${PIPESTATUS[0]}") || failed+=(webbox-test)
fi
lap "limits, pinned, check-apps, zig-webbox's tests"

# **THE SITE VOLUME, FROM THIS CHECKOUT** (tools/site_volume.py): what
# metal-vmm's timeouts.sh and pc_vs_microvm.sh judge.
SITE_VOLUME="$HOME/build/zig-metal-unikernel/site/pristine.img"
python3 tools/site_volume.py "$SITE_VOLUME" "$GOPHER_ROOT" || failed+=(site-volume)
lap "the site volume"

# ── metal-vmm on gopher.elf ──────────────────────────────────────────────────
# `pc_vs_microvm.sh all` is the PC-shaped machine (TRANSPORT=pci): every
# route with the server halting between frames and woken by MSI-X and the
# APIC timer, the path a droplet runs. **TIMEOUTS, IN THE MACHINE'S TIME**:
# what a setting governs, proved by moving it.
export GUESTS="$HERE/probe"
(cd "$VMM" && zig build 2>&1 | tail -5; exit "${PIPESTATUS[0]}") || failed+=(vmm-build)
if ! skip vmm-pc; then
    (cd "$VMM" && SITE="$SITE_VOLUME" ./pc_vs_microvm.sh all 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-pc)
fi
# **TWO KERNELS TALKING** (metal-vmm QUEUE 225 chunk 13, pair.sh): gopher.elf
# serves probe/fetch.elf on metal-vmm's PAIR mode, deterministic; about 50
# runs in about 22 s (unhurt twice, the SYN eaten, silent, no ARP, idle, and
# each side's first 12 and last 8 frames lost in turn), every page checked
# against the single-guest run's.
if ! skip pair; then
    zig build fetch > "$VERDICTS/fetch-build.txt" 2>&1 || failed+=(pair)
    (cd "$VMM" && GUESTS="$HERE/probe" SITE="$SITE_VOLUME" ./pair.sh > "$VERDICTS/pair.txt" 2>&1) || failed+=(pair)
    grep -E "FAIL|NOT RUN|^time|^PAIR" "$VERDICTS/pair.txt"
    lap "pair: two kernels talking"
fi
# **A KERNEL THAT SLEEPS** (docs/designs/DESIGN-sleep.md, sleeps.sh): an
# idle gopher.elf's cost, the sleeper's hour of 60 s wakes, the longest rest
# at 6 ms and 10 s alike, and a request waking a sleep; about 2 s.
if ! skip sleeps; then
    zig build sleeper > "$VERDICTS/sleeper-build.txt" 2>&1 || failed+=(sleeps)
    (cd "$VMM" && GUESTS="$HERE/probe" SITE="$SITE_VOLUME" ./sleeps.sh > "$VERDICTS/sleeps.txt" 2>&1) || failed+=(sleeps)
    grep -E "FAIL|NOT RUN|^time|^SLEEPS" "$VERDICTS/sleeps.txt"
    lap "sleeps: a kernel that sleeps"
fi
if ! skip vmm-timeouts; then
    (cd "$VMM" && SITE="$SITE_VOLUME" ./timeouts.sh 2>&1 | tail -3; exit "${PIPESTATUS[0]}") || failed+=(vmm-timeouts)
fi
lap "metal-vmm rests and timeouts"

# ── the two FAT32 chat judges ────────────────────────────────────────────────
# **GATES_PARALLEL=1 RUNS THE TWO SIDE BY SIDE** (QUEUE.md item 72), the
# default: each in its own scratch (PROBE_WORK), on ports each judge asks
# the host for. `GATES_PARALLEL=0` runs them one after the other.
judge() {  # judge MACHINE: one chat judge, output to $VERDICTS/gopher-MACHINE.run
    local machine=$1 droplet=0
    [ "$machine" = droplet ] && droplet=1
    env JUDGE_DROPLET=$droplet PROBE_WORK="$HOME/build/zig-metal-unikernel/probe-$machine" probe/run.sh gopher \
        > "$VERDICTS/gopher-$machine.run" 2>&1
    echo $? > "$VERDICTS/gopher-$machine.code"
}
report() {  # report TAG: the verdict line and, on a failure, every line after it
    local tag=$1 v code
    v=$(cat "$VERDICTS/gopher-$tag.run")
    code=$(cat "$VERDICTS/gopher-$tag.code")
    echo "$v" | sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p'
    { [ "$code" = 0 ] && echo "$v" | grep -q "^PASS gopher"; } || failed+=("gopher-$tag")
    cp "$HOME/build/zig-metal-unikernel/probe-$tag/gopher.verdict" "$VERDICTS/gopher-$tag.verdict" 2>/dev/null
}
if ! skip gopher-judges; then
    (cd "$GOPHER_ROOT/zig-server" && zig build) > "$VERDICTS/linux-build.txt" 2>&1
    if [ "${GATES_PARALLEL:-1}" = 1 ]; then
        judge microvm & judge droplet & wait
        for machine in microvm droplet; do report $machine; done
        lap "gopher judges, microvm and droplet side by side (FAT32)"
    else
        for machine in microvm droplet; do
            judge $machine
            report $machine
            lap "gopher judge, $machine (FAT32)"
        done
    fi
    echo "FAT16 chat judge: in long.sh, before every release"

    # **A CHECK SKIPPED IS NO PASS**: a chat judge that could not run a check
    # says SKIPPED, and the tier fails, naming each.
    skipped=$(cat "$VERDICTS"/gopher-*.run 2>/dev/null | grep "SKIPPED" || true)
    if [ -n "$skipped" ]; then echo "$skipped"; failed+=(skipped); fi
fi
verdict
