#!/bin/bash
# **THE LONG TIER** (COVERAGE.md): for bug hunting, and before a deploy. Not
# for every commit; that is gates.sh.
#
#   ./long.sh                 the simulator at 1,000 seeds (500 crowded), then the lossy
#                             sweep of the real kernel
#   SEEDS=10000 ./long.sh     more seeds, for hunting
#   ./long.sh sim | metal     one half
#   SKIP="word …" ./long.sh   leaves steps out (tools/skip_lib.sh): sim,
#                             fault-sweeps, lossy, rough, native-full,
#                             volume-sweep, fat16-judge
#
# Only a whole run at full size passes (exit 0) and keeps a verdict; a half,
# a knob cut, or a skip ends NOT A PASS, exit 3, naming what was cut.
#
# 1. **The simulators** (`zig build properties`, ReleaseSafe): TCP's plain and
#    rough seeds and FAT's, with `coverage/floor-sim.txt` as their floor:
#    every property on it must be reached, and none broken.
#
# 2. **The chat judge on FAT16** (QEMU's microvm), its write path: the
#    gates that write, append and rewrite (uploads, churn, bulk), quick
#    (metal-vmm QUEUE 224.7). Moved here from gates.sh, whose FAT32 judges
#    are what prod runs. It runs LAST, being QEMU, after 3 to 5.
#
# 3. **The real kernel, losing its frames in turn.** gopher.elf, built
#    with -Dcoverage, on metal-vmm's PC-shaped machine (TRANSPORT=pci: it
#    halts between frames and wakes on interrupts, as on a droplet), over a
#    5 ms wire. For each route, the wire eats the guest's 1st frame, then its
#    2nd, and so on through a sample of the frames the route sends (the first
#    4, the last 4, every 5th), one deterministic run each, two at a time.
#    The release kernel runs the unhurt case, and must match the coverage
#    kernel's byte for byte. **Every run must still serve the page an unhurt run serves**: TCP's
#    whole promise is that losing a frame costs time, not the answer. Every
#    run's coverage lines go to one sdk.jsonl, judged by zig-coverage-sdk's
#    report.py against `coverage/floor-metal.txt`.
#
#    **IN PRODUCTION'S SHAPE** (QUEUE B24, 2026-10-08): every boot of 3
#    and 4 has a copy of the site volume attached as a SCSI disk, so chat's
#    data is on a volume, as on the droplet. No gate ran that shape until
#    then, and its first run found metal-vmm crashing on virtio-scsi's third
#    queue and every write's residual wrong.
#
# 4. **The real kernel, with a peer that misbehaves**: one run each for a
#    reset (exact and not), a peer that vanishes, a window it shuts, a
#    damaged segment, a SYN flood that fills the table, and a request
#    segment lost so the next arrives ahead (the table in the script).
#    The flood's real client drips its request (PEER_DRIP_US): the site
#    serves one request and stops, so a client answered at once ends the
#    run before any half-open is older than min_rto_ns, the age at which
#    one gives way to a new SYN (tcp.zig oldestHalfOpen). In production's
#    shape, 1000 SYNs 100 us apart reached it in no run.
#    Their coverage joins the same sdk.jsonl.
#
# 5. **Seeded fault schedules, with a volume** (metal-vmm's sweep.sh,
#    `VOLUME_SITE`): `VOLUME_SEEDS` seeds (100), each a whole schedule drawn
#    over the wire, the peer, the disk and the volume. A seed that fails, as
#    sweep.sh judges it (a page its faults do not excuse, an exit, a disk or
#    volume left unsound, a broken property), fails this tier. It runs the
#    -Dcoverage kernel: sweep.sh refuses one that reports no property, since
#    "no property broken" would hold of it vacuously (2026-10-09), and
#    through metal-vmm's coverage door its pages are the release kernel's.
#
# Needs: metal-vmm and zig-coverage-sdk as sibling checkouts (METAL_VMM,
# COVERAGE_SDK), the judge's site volume (probe/run.sh gopher builds it), and
# mtools (mcopy) for a copy of it that asks for two requests.
# gopher.elf is rebuilt without -Dcoverage at the end, as gates.sh expects.
#
# **ITS EXIT CODE IS THE VERDICT**, and the last line names what failed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
source "$HERE/tools/skip_lib.sh"
VMM="${METAL_VMM:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/metal-vmm}"
SDK="${COVERAGE_SDK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zig-coverage-sdk}"
# **THE SITE VOLUME IS THIS CHECKOUT'S** (tools/site_volume.py), built below
# unless SITE names one: it was a default path whatever chat judge ran last
# had left, which nothing kept fresh.
SITE="${SITE:-}"
GOPHER_ROOT="${GOPHER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/angry-gopher}"
WEBBOX_ROOT="${WEBBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zig-webbox}"
export WEBBOX_ROOT
SHALE_CHECKOUT="${SHALE_CHECKOUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shale}"
export SHALE_CHECKOUT
# **SEEDS BY MEASUREMENT** (metal-vmm QUEUE 224.3): the smallest of 1k, 2k
# and 5k that reaches the whole floor-sim.txt. 1,000 does (2026-10-16,
# -Dtrace-reach: every TCP floor line by seed 89), and crowds on 500 of
# them. A floor line a later change leaves unreached fails the tier and
# names it; raising this, or moving the line, is a commit.
SEEDS="${SEEDS:-1000}"
CROWD_SEEDS="${CROWD_SEEDS:-500}"
# 150 (Steve's call, 224): fat_sim's two floor lines of its own come by seed 113.
FAT_SEEDS="${FAT_SEEDS:-150}"
LATENCY_US="${LATENCY_US:-5000}"
VOLUME_SEEDS="${VOLUME_SEEDS:-100}"
# A page, a large one (many frames), and a form.
ROUTES="${ROUTES:-/ /steve-resume.pdf /login/full}"
OUT="${LONG_OUT:-$HOME/build/zig-metal-unikernel/long}"
want="${1:-all}"
case "$want" in all | sim | metal) ;; *) echo "usage: ./long.sh [sim|metal]"; exit 2 ;; esac

# **WHICH CODE THIS RUN JUDGES** (tools/verdicts.py), as gates.sh does. Only
# a whole run at full size keeps a verdict: a release asks for this tier as
# it is, not a smaller one.
VERDICT_PAIR="$(python3 tools/verdicts.py ids)" || exit 2
export VERDICT_PAIR
python3 tools/verdicts.py pair
keeps_verdict=no
# **EVERY KNOB AT ITS FULL SIZE, OR NO VERDICT** (the box's ergonomics
# review, 2026-10-16): seeds alone let `ROUTES=/ VOLUME_SEEDS=1` record a
# PASS for a run that did less than the tier. And no step skipped.
[ "$want" = all ] && [ "$SEEDS" -ge 1000 ] && [ "$CROWD_SEEDS" -ge 500 ] && [ "$FAT_SEEDS" -ge 150 ] \
    && [ "$VOLUME_SEEDS" -ge 100 ] && [ "$LATENCY_US" = 5000 ] && [ "$ROUTES" = "/ /steve-resume.pdf /login/full" ] \
    && [ -z "$SKIP" ] && keeps_verdict=yes

failed=()
began=$(date +%s)
lap() { echo "time: $1 $(( $(date +%s) - began )) s"; began=$(date +%s); }

if [ "$want" != metal ]; then
if ! skip sim; then  # (SKIP=sim, tools/skip_lib.sh)
    echo "── the simulators: $SEEDS TCP seeds, plain and rough, and $FAT_SEEDS FAT seeds, against coverage/floor-sim.txt"
    # ReleaseSafe: a sweep this long is nearly all running (build.zig).
    # **TWO SHARDS, SIDE BY SIDE** (metal-vmm QUEUE 224.4): the FAT's (the
    # largest) and everything else, a core each, each writing its JSONL;
    # zig-coverage-sdk's report.py judges the floor over both, as the
    # unsharded run judged it over one (properties.zig's `on`).
    sim_args=(-Dseeds="$SEEDS" -Dcrowd-seeds="$CROWD_SEEDS" -Dfat-seeds="$FAT_SEEDS" -Dsweep-optimize=ReleaseSafe)
    shard_a="fat,fat_replays,regressions"
    shard_b="tcp_plain,tcp_rough,tcp_crowd,page,pure,ready,drain,tcp_full,store,floor,durable,store_replays,tcp_pair"
    zig build properties "${sim_args[@]}" -Dsims="$shard_a" -Dsdk-jsonl="$OUT.sim-a.jsonl" > "$OUT.sim-a" 2>&1 &
    pid_a=$!
    zig build properties "${sim_args[@]}" -Dsims="$shard_b" -Dsdk-jsonl="$OUT.sim-b.jsonl" > "$OUT.sim-b" 2>&1 &
    pid_b=$!
    wait $pid_a; code_a=$?
    wait $pid_b; code_b=$?
    cat "$OUT.sim-a" "$OUT.sim-b" > "$OUT.sim"
    grep -E 'runs failed|^ *FAIL' "$OUT.sim" | sed 's/^ *//'
    # A failure the lines above don't name (a build error) says itself.
    for shard in a b; do
        c=$code_a; [ $shard = b ] && c=$code_b
        if [ $c != 0 ] && ! grep -qE 'runs failed|^ *FAIL' "$OUT.sim-$shard"; then
            echo "the simulators' shard $shard did not run to a verdict ($OUT.sim-$shard):"; grep -E 'error' "$OUT.sim-$shard" | head -5
        fi
    done
    { [ $code_a = 0 ] && [ $code_b = 0 ]; } || failed+=(sim)
    python3 "$SDK/tools/report.py" "$OUT.sim-a.jsonl" "$OUT.sim-b.jsonl" --floor coverage/floor-sim.txt > "$OUT.sim-floor" 2>&1
    code=$?
    grep -E '^(FAIL|FLOOR|STALE|SILENT)' "$OUT.sim-floor"
    echo "the simulators' floor (both shards, report.py): $([ $code = 0 ] && echo reached || echo "NOT reached, $OUT.sim-floor")"
    [ $code = 0 ] || failed+=(sim-floor)
    # **THE BUILD APART FROM THE RUN** (metal-vmm QUEUE 224.1): each
    # simulator's seconds as properties.zig printed them, and the build's as
    # the phase's time less the longer shard's run.
    grep '^ *time: sim ' "$OUT.sim" | grep -v ' 0 runs' | sed 's/^ *//'
    run_s=$(sed -n 's/^ *time: sim run \([0-9]*\).*/\1/p' "$OUT.sim" | sort -n | tail -1)
    [ -n "$run_s" ] && echo "time: simulator build $(( $(date +%s) - began - run_s )) s"
    lap "simulator"
fi  # sim

    # **THE FAULT SWEEPS WHOLE** (metal-vmm QUEUE 198.11): tier 0 stops a
    # FAT operation at a sample of its requests; here, at every one.
if ! skip fault-sweeps; then  # (SKIP=fault-sweeps, tools/skip_lib.sh)
    echo "── the FAT's fault and lie sweeps, every request"
    zig build test -Dtest-file=src/disk_fat_faults_test.zig -Dfault-sweep-full > "$OUT.faults" 2>&1
    code=$?
    grep -E "error|failed" "$OUT.faults" | head -5
    [ $code = 0 ] || failed+=(fault-sweeps)
    # And disk_fat_test's own long cases (QUEUE 203(d)): a tree past
    # 4,096 entries removed whole.
    zig build test -Dtest-file=src/disk_fat_test.zig -Dfault-sweep-full > "$OUT.fatlong" 2>&1
    code=$?
    grep -E "error|failed" "$OUT.fatlong" | head -5
    [ $code = 0 ] || failed+=(fat-long)
    lap "fault sweeps"
fi  # fault-sweeps
fi

if [ "$want" != sim ]; then
    echo "── the real kernel on metal-vmm's PC-shaped machine, losing its frames in turn, sampled"
    mkdir -p "$OUT"
    rm -f "$OUT/sdk.jsonl"
    if [ -z "$SITE" ]; then
        SITE="$HOME/build/zig-metal-unikernel/site/pristine.img"
        python3 tools/site_volume.py "$SITE" "$GOPHER_ROOT" || { echo "the site volume does not build"; exit 2; }
    fi
    [ -f "$SITE" ] || { echo "no site volume at $SITE"; exit 2; }
    (cd "$VMM" && zig build) || { echo "metal-vmm does not build"; exit 2; }
    # **ONE KERNEL A CASE** (metal-vmm QUEUE 224.5): every case runs on the
    # -Dcoverage kernel alone, judged on its page and counted for coverage.
    # The release kernel, which ships, runs each route's unhurt case, and
    # must send the same frames and serve the same page byte for byte: that
    # comparison is what lets the coverage kernel stand in for it. **It is
    # not the same run.** Through metal-vmm's coverage door (`a92ca03`) its
    # properties cost no serial exits, but it does more work: the PDF route,
    # unhurt, measured 2026-10-16, 8,058 exits to the release kernel's 7,543
    # (clock 1,316 to 1,007, mmio 891 to 685), 147 disk requests to 95, and
    # 807 ms of guest time to 756, the same 57 frames and the same page. A
    # bug that only the release kernel's timing reaches is outside this tier. (Before the door, a coverage kernel printed its
    # catalog a byte an exit, and v19's first long.sh failed every route on
    # it while the release kernel served each page whole.)
    zig build gopher -Dcoverage -Dgopher-root="$GOPHER_ROOT" -Dwebbox-root="$WEBBOX_ROOT" -Dshale-root="$SHALE_CHECKOUT" > "$OUT/build.log" 2>&1 || { echo "gopher.elf -Dcoverage does not build: $OUT/build.log"; exit 2; }
    cp probe/gopher.elf "$OUT/gopher-coverage.elf"
    zig build gopher -Dgopher-root="$GOPHER_ROOT" -Dwebbox-root="$WEBBOX_ROOT" -Dshale-root="$SHALE_CHECKOUT" > "$OUT/rebuild.log" 2>&1 || { echo "gopher.elf does not build: $OUT/rebuild.log"; exit 2; }
    JUDGED=probe/gopher.elf
    COUNTED="$OUT/gopher-coverage.elf"
    lap "the metal half's builds (the site volume, metal-vmm, two kernels)"

    # run <eat> <path> [kernel]: one boot in the folder $W; sets code, sent,
    # status, and the page in $W/page, and adds its coverage to
    # $W/sdk.jsonl. The judged kernel unless another is named.
    W="$OUT"
    run() {
        cp "$SITE" "$W/run.img"
        cp "$SITE" "$W/run.vol"
        # A page is this run's or none: metal-vmm writes none for an answer
        # it kept only in part, and a page left by the run before would be
        # judged in its place.
        rm -f "$W/page"
        TRANSPORT=pci VOLUME="$W/run.vol" WIRE_LATENCY_US="$LATENCY_US" WIRE_EAT="$1" PEER_BODY="$W/page" \
            timeout 120 "$VMM/zig-out/bin/metal-vmm" "${3:-$JUDGED}" "$W/run.img" "" "$2" \
            > "$W/run.out" 2> "$W/run.err"
        code=$?
        sent=$(sed -n 's/^wire: \([0-9]*\) frames sent.*/\1/p' "$W/run.err")
        status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$W/run.out")
        grep -a '^coverage: ' "$W/run.out" | sed -e 's/^coverage: //' -e 's/\r$//' >> "$W/sdk.jsonl"
    }

    # **SAMPLED** (metal-vmm QUEUE 224.6): the frames lost in turn are the
    # first 4, the last 4 and every 5th between. The handshake and the
    # request are early, the FIN late, and the middle is the same work
    # again; the floor (`floor-metal.txt`) says whether the sample still
    # reaches what every frame did.
    sampled() {
        for n in $(seq 1 "$1"); do
            if [ "$n" -le 4 ] || [ "$n" -gt $(($1 - 4)) ] || [ $((n % 5)) = 0 ]; then echo "$n"; fi
        done
    }

if ! skip lossy; then  # (SKIP=lossy, tools/skip_lib.sh)
    lost_pages=0
    for route in $ROUTES; do
        # Frame 9999 is never sent: the unhurt run, whose page every other
        # must match. The release kernel's first, then the coverage kernel's.
        run 9999 "$route"
        rm -f "$OUT/release.page"
        cp "$OUT/page" "$OUT/release.page" 2>/dev/null
        release_status=$status release_sent=$sent
        run 9999 "$route" "$COUNTED"
        rm -f "$OUT/unhurt.page"
        cp "$OUT/page" "$OUT/unhurt.page" 2>/dev/null
        unhurt_status=$status
        total=${sent:-0}
        if [ "$code" != 0 ] || [ -z "$status" ] || [ "$total" = 0 ] || [ ! -f "$OUT/unhurt.page" ]; then
            echo "  $route: the unhurt run failed (exit $code, status '${status}', page $([ -f "$OUT/unhurt.page" ] && echo written || echo 'not written')); see $OUT/run.out and run.err"
            failed+=("metal $route")
            continue
        fi
        if [ "$release_status" != "$unhurt_status" ] || [ "$release_sent" != "$total" ] || ! cmp -s "$OUT/release.page" "$OUT/unhurt.page"; then
            echo "  $route: the release kernel's unhurt run is not the coverage kernel's (status $release_status and $unhurt_status, frames $release_sent and $total)"
            failed+=("metal $route")
            continue
        fi
        # **TWO AT A TIME** (224.6), a folder each, the sample dealt between them.
        picks=$(sampled "$total")
        for j in 0 1; do
            (
                W="$OUT/job$j"
                mkdir -p "$W"
                rm -f "$W/sdk.jsonl" "$W/bad"
                k=0
                for n in $picks; do
                    k=$((k + 1))
                    [ $((k % 2)) = "$j" ] || continue
                    run "$n" "$route" "$COUNTED"
                    if [ "$code" != 0 ] || [ "$status" != "$unhurt_status" ] || ! cmp -s "$W/page" "$OUT/unhurt.page"; then
                        echo "$n" >> "$W/bad"
                        cp "$W/run.out" "$OUT/lost-$(echo "$route" | tr / _)-$n.out"
                    fi
                done
            ) &
        done
        wait
        cat "$OUT"/job0/sdk.jsonl "$OUT"/job1/sdk.jsonl >> "$OUT/sdk.jsonl" 2>/dev/null
        bad=$(cat "$OUT"/job0/bad "$OUT"/job1/bad 2>/dev/null | sort -n | sed 's/^/ #/' | tr -d '\n')
        lost_pages=$((lost_pages + $(cat "$OUT"/job0/bad "$OUT"/job1/bad 2>/dev/null | wc -l)))
        if [ -z "$bad" ]; then
            echo "  $route: $total frames, $(echo "$picks" | wc -w) of them lost in turn: the same page every time ($unhurt_status)"
        else
            echo "  $route: $total frames; losing these lost the page:$bad (logs in $OUT/lost-*)"
            failed+=("metal $route")
        fi
    done
    lap "lossy sweep"
fi  # lossy

    # **THE PEER MISBEHAVES**, one run per way (metal-vmm's KNOBS.md, "The peer:
    # a worse client"). A client that stays (`page`) must still get the
    # page an unhurt run gets; one that hurts itself (`end`: a reset, a
    # vanish) is owed nothing, and the run may end with the guest idle,
    # waiting on a request that never comes. Either way metal-vmm must end
    # the run itself: no panic, no timeout, no guest that never rests.
    # `two` is the site volume asking for two requests, so the guest stays up
    # after the first and its table gives up on a silent peer. A `page` run
    # is on `one`: an idle end prints no page. The shut window lasts 1.5 s,
    # inside the 2 s a guest that has served its last request gives its
    # connections before it stops; a longer one is cut by that stop, which
    # only a request limit causes (the site has none).
if ! skip rough; then  # (SKIP=rough, tools/skip_lib.sh)
    cp "$SITE" "$OUT/two.img"
    printf 'requests = 2\nidle_timeout_ms = 10000\n' > "$OUT/two.conf"
    mcopy -o -i "$OUT/two.img@@1M" "$OUT/two.conf" ::/zig-metal-unikernel.conf || { echo "mcopy (mtools) could not write the two-request volume"; exit 2; }
    printf 'GET / HTTP/1.1\r\nHost: lynrummy.com\r\nX-Pad: %s\r\nConnection: close\r\n\r\n' "$(head -c 900 /dev/zero | tr '\0' a)" > "$OUT/req1k"
    for route in / /steve-resume.pdf; do
        run 9999 "$route"
        cp "$OUT/page" "$OUT/unhurt$(echo "$route" | tr / _).page"
    done
    rough_bad=""
    while read -r name volume route must knobs; do
        [ -z "$name" ] && continue
        img="$SITE"
        [ "$volume" = two ] && img="$OUT/two.img"
        # The coverage kernel alone (224.5), its page against the release
        # kernel's unhurt one above.
        cp "$img" "$OUT/run.img"
        cp "$SITE" "$OUT/run.vol"
        # shellcheck disable=SC2086 # knobs are words on purpose
        env TRANSPORT=pci VOLUME="$OUT/run.vol" WIRE_LATENCY_US="$LATENCY_US" PATIENCE_S=60 PEER_BODY="$OUT/page" $knobs \
            timeout 300 "$VMM/zig-out/bin/metal-vmm" "$COUNTED" "$OUT/run.img" "" "$route" \
            > "$OUT/run.out" 2> "$OUT/run.err"
        code=$?
        grep -a '^coverage: ' "$OUT/run.out" | sed -e 's/^coverage: //' -e 's/\r$//' >> "$OUT/sdk.jsonl"
        ok=yes
        case "$code" in
            0) ;;
            1) grep -q '^error: GuestIdle$' "$OUT/run.err" || ok=no ;;
            *) ok=no ;;
        esac
        if [ "$must" = page ] && ! cmp -s "$OUT/page" "$OUT/unhurt$(echo "$route" | tr / _).page"; then ok=no; fi
        if [ $ok = yes ]; then
            if [ "$code" = 0 ]; then echo "  rough $name: answered $(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$OUT/run.out" | head -1)"
            else echo "  rough $name: no answer owed; the guest ended idle"; fi
        else
            rough_bad="$rough_bad $name"
            cp "$OUT/run.err" "$OUT/rough-$name.err"
            cp "$OUT/run.out" "$OUT/rough-$name.out"
            echo "  rough $name: FAILED (exit $code; logs in $OUT/rough-$name.*)"
        fi
    done <<EOF
reset          one /steve-resume.pdf end  PEER_RESET_AT=30000
reset-inexact  one /steve-resume.pdf end  PEER_RESET_AT=30000 PEER_RESET_OFF=100
vanish         two /steve-resume.pdf end  PEER_VANISH_AFTER=3000
shut-window    one /steve-resume.pdf page PEER_SHUT_AFTER=5000 PEER_SHUT_FOR_US=1500000
damaged        one /                 page PEER_DAMAGE=3
flood          one /                 page PEER_FLOOD=1000 PEER_FLOOD_GAP_US=1000 PEER_DRIP_US=100000 PEER_MSS=10
ahead          one /                 page PEER_REQUEST=$OUT/req1k PEER_MSS=100 PEER_EAT=6
EOF
    [ -z "$rough_bad" ] || failed+=("metal rough:$rough_bad")
    lap "rough peer"
fi  # rough

if ! skip native-full; then  # (SKIP=native-full, tools/skip_lib.sh)
    # **LINUX AS THE WITNESS, WHOLE** (the box, 2026-10-16): tier 1 runs
    # judge_native quick; here it runs whole, its loss check waiting out
    # real retransmission timers on both sides (5% toward the table, 1 in
    # 13 from it, a seed printed). About 35 s. Needs `sudo -n` (the TAP).
    echo "── tcp.zig against Linux's TCP, natively, whole (loss included)"
    if ! zig build native > "$OUT.native-build" 2>&1; then
        echo "  the native build failed: $OUT.native-build"; failed+=(native-full)
    elif python3 native/judge_native.py > "$OUT.native" 2>&1; then
        echo "  $(tail -1 "$OUT.native")"
    else
        grep "^FAIL" "$OUT.native"; echo "  $(tail -1 "$OUT.native")"; failed+=(native-full)
    fi
    lap "native, whole"
fi  # native-full
if ! skip volume-sweep; then  # (SKIP=volume-sweep, tools/skip_lib.sh)
    echo "── seeded fault schedules with a volume attached: $VOLUME_SEEDS seeds (metal-vmm's sweep.sh)"
    VOLUME_SITE="$SITE" SITE="$SITE" KERNEL="$COUNTED" "$VMM/sweep.sh" 1 "$VOLUME_SEEDS" > "$OUT/volume-sweep" 2>&1
    code=$?
    grep -iE '^[0-9]+ seeds:|FAULT_SEED=[0-9]+: FAIL|nothing can be judged' "$OUT/volume-sweep"
    [ $code = 0 ] || { echo "  the volume sweep failed (exit $code): $OUT/volume-sweep"; failed+=(volume-sweep); }
    lap "volume sweep"
fi  # volume-sweep
    # **THE METAL FLOOR NEEDS ALL THREE** (lossy, rough, volume-sweep): with
    # one skipped, a miss would be the skip's, and a pass would be a lie
    # about the floor, so it is not judged, and says so.
    if [[ " ${not_run[*]} " =~ " lossy " || " ${not_run[*]} " =~ " rough " || " ${not_run[*]} " =~ " volume-sweep " ]]; then
        not_run+=(metal-floor)
        echo "SKIPPED metal-floor: NOT RUN (a run it needs was skipped)"
    else
        python3 "$SDK/tools/report.py" "$OUT/sdk.jsonl" --floor coverage/floor-metal.txt > "$OUT/report" 2>&1
        code=$?
        grep -E '^(FAIL|FLOOR|STALE)|^[0-9]+ runs|under the floor' "$OUT/report"
        [ $code = 0 ] || failed+=(metal-floor)
    fi

    # **THE FAT16 CHAT JUDGE** (moved here from gates.sh, the gates essay's
    # item 6): the whole chat story on QEMU's microvm with the data on FAT16,
    # every run. **LAST, BEING QEMU** (Steve, 2026-10-11: find things
    # quickly), on gopher.elf as a release builds it, which the coverage
    # build above put back (224.5: no build here, it was a cache hit).
if ! skip fat16-judge; then  # (SKIP=fat16-judge, tools/skip_lib.sh)
    echo "── the chat judge on FAT16 (microvm), its write path"
    # **ITS WRITE PATH ONLY** (metal-vmm QUEUE 224.7): the gates that write,
    # append and rewrite (uploads, churn, bulk), quick. FAT16 matters again
    # (Dog Park keeps its data on FAT16 in production); endurance and
    # stamina stay on tier 3's FAT32. The whole judge on FAT16 is
    # `FAT=16 probe/run.sh gopher` (193 s under TCG, 2026-10-16).
    env JUDGE_DROPLET=0 FAT=16 JUDGE_QUICK=1 PROBE_WORK="$HOME/build/zig-metal-unikernel/probe-microvm-fat16" \
        probe/run.sh gopher "uploads churn bulk" > "$OUT.fat16" 2>&1
    code=$?
    sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p' "$OUT.fat16"
    { [ "$code" = 0 ] && grep -q "^PASS gopher" "$OUT.fat16"; } || failed+=(fat16-judge)
    lap "chat judge, FAT16"
fi  # fat16-judge

fi

if [ ${#failed[@]} = 0 ]; then
    if [ $keeps_verdict = yes ]; then python3 tools/verdicts.py record long PASS; passed LONG; fi
    # **A PARTIAL RUN IS NOT A PASS** (the second cold review): one half,
    # or a knob below its full size, ends as a skip does, exit 3, saying
    # what was cut.
    cut=""
    [ "$want" != all ] && cut="$cut only the $want half;"
    [ "$SEEDS" -lt 1000 ] || [ "$CROWD_SEEDS" -lt 500 ] || [ "$FAT_SEEDS" -lt 150 ] && cut="$cut fewer simulator seeds;"
    [ "$VOLUME_SEEDS" -lt 100 ] && cut="$cut VOLUME_SEEDS=$VOLUME_SEEDS;"
    [ "$LATENCY_US" != 5000 ] && cut="$cut LATENCY_US=$LATENCY_US;"
    [ "$ROUTES" != "/ /steve-resume.pdf /login/full" ] && cut="$cut ROUTES='$ROUTES';"
    [ ${#not_run[@]} -gt 0 ] && cut="$cut NOT RUN: ${not_run[*]};"
    echo "no verdict kept"
    echo "LONG: NOT A PASS: every step that ran passed; a partial run:${cut%;}"
    exit 3
else
    [ $keeps_verdict = yes ] && python3 tools/verdicts.py record long FAIL
    echo "LONG: FAIL (${failed[*]})${not_run[*]:+, and NOT RUN: ${not_run[*]}}"
    exit 1
fi
