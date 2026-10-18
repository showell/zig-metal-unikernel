#!/bin/bash
# **TIER 0: ZIG, PYTHON AND THE COVERAGE SDK, NOTHING ELSE** (metal-vmm QUEUE
# 197). The check to run on every change: the unit tests and the simulators,
# this repo's own kernels type-checked, the formatter and the lints. No QEMU, no other repo, no
# network, no root. Needs zig 0.16, python3, and ../zig-coverage-sdk at the
# commit build.zig.zon pins.
#
# **EVERY SIBLING IS POINTED AT NOTHING HERE**, so a step that reaches
# outside this repo fails in this tier instead of passing on a machine that
# happens to have the sibling beside it.
#
# What it does not check is named at the end, with the tier that does.
#
# **SKIP="word …"** leaves slow steps out (tools/skip_lib.sh): test, tcp-traces.
# A run with a skip ends NOT A PASS, exit 3, and keeps no verdict.
TIER="tier 0"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig python3

NOWHERE="$HERE/.no-sibling"
ALONE=(-Dgopher-root="$NOWHERE" -Dwebbox-root="$NOWHERE" -Dshale-root="$NOWHERE")

# The unit tests, the simulators' own tests, this repo's kernels and host
# programs type-checked, `zig fmt --check src`, the machine lint and its
# cases. Each test binary runs under tools/cpu_time.py, which writes its CPU
# time to $CPU_DIR (198.12). The directory is part of the build's command
# line, so it is the same one every run: a new one would compile every test
# binary again.
# **MORE JOBS THAN CORES** (198.11): zig's default (one per core) left the
# four big test binaries waiting on small steps' slots. Each binary is one
# thread.
JOBS=$(( $(nproc 2>/dev/null || echo 4) * 2 ))
CPU_DIR="$HERE/.zig-cache/test-cpu"
# **CHEAPEST FIRST** (seconds): formats and parses, before the minutes.
zig fmt --check probe droplet native > /dev/null || failed+=(fmt)
python3 droplet/check_volume_tree.py --self-test > /dev/null || failed+=(volume-tree)
# Parsed, not run: a syntax error in a judge would otherwise wait for tier 1.
python3 -c 'import ast, sys
for f in sys.argv[1:]: ast.parse(open(f).read(), f)' tools/*.py probe/*.py droplet/*.py native/*.py || failed+=(python-parses)
lap "fmt, the volume-tree self-test, every Python file parses"
if ! skip test; then
    rm -rf "$CPU_DIR"
    zig build test "${ALONE[@]}" -Dtest-cpu-dir="$CPU_DIR" -j"$JOBS" --summary all > "$VERDICTS/tier0-test.txt" 2>&1
    [ $? = 0 ] || failed+=(test)
    grep -E "tests passed|error" "$VERDICTS/tier0-test.txt" | tail -5
    lap "zig build test"
    # **THE BUDGET** (198.11, B31; 198.12: CPU time, not wall time): a test
    # binary whose CPU time passes TIER0_RUN_BUDGET (25 s), or all of them
    # together past TIER0_TOTAL_BUDGET (75 s), fails the tier, so the cost cannot
    # creep back. CPU time is the same on 2 cores and on 8; wall time under -j
    # was the neighbours' as much as the test's.
    python3 tools/test_budget.py "$CPU_DIR" "${TIER0_RUN_BUDGET:-25}" "${TIER0_TOTAL_BUDGET:-75}"
    case $? in 0 | 2) ;; *) failed+=(test-budget) ;; esac
fi

# **THE GOLDEN TRACES** (metal-vmm QUEUE 225, chunk 1): every pinned
# tcp_sim world sends the same frames, or the commit that changes them says
# so and rewrites coverage/tcp-traces.txt. In no tier until 2026-10-16, when
# a change to the wire (QUEUE 227) went in claiming them unchanged, unrun.
# ReleaseSafe, a binary of its own: the build is most of its minute cold.
if ! skip tcp-traces; then
    zig build tcp-traces "${ALONE[@]}" > "$VERDICTS/tier0-traces.txt" 2>&1 || { failed+=(tcp-traces); grep -E "trace changed|pinned|now " "$VERDICTS/tier0-traces.txt" | head -9; }
    lap "zig build tcp-traces"
fi

cat <<'NOTE'
tier 0 does NOT check, and which tier does:
  - the coverage properties over the simulators' seeds (zig build
    properties: zig alone, but 20 min in Debug and 5 in ReleaseSafe, too
    long for every change): long.sh, at 1,000 seeds
  - the probe kernels booted, the judges' own tests, the FAT image tools,
    the droplet's boots (QEMU, dosfstools, gdisk, mtools): tier 1
  - metal-vmm against this repo's kernels: tier 2
  - the docs' cited paths and names (shale's doc check, which reads
    every sibling): tier 3
  - src/pinned/webbox_body.zig against zig-webbox's body.zig (zig build
    pinned); gopher.elf type-checked (zig build check-apps) and built;
    the limits zig-webbox copies (tools/check_limits.py); zig-webbox's own
    tests; the site volume and the chat judges; metal-vmm on
    gopher.elf: tier 3
NOTE
verdict
