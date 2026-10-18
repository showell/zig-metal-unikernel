# **SKIPPING A STEP, WITHOUT A FALSE PASS** (Steve, 2026-10-16: the pitfall
# is "agents think they ran a script or checked something that was
# effectively skipped"; the annoyance is "waiting too long when the agent
# makes no effort to skip steps"). Sourced by tier_lib.sh and long.sh.
#
#   SKIP="tcp-traces probes" ./gates.sh
#
# Each script's header lists its own words.
#
# - **The words are the steps' names**, the ones each prints when it fails
#   (`STEPS` below). A word that names no step stops the run before
#   anything runs (exit 2): a typo never "skips" nothing quietly.
# - **Each skipped step says so where it would have run** (`SKIPPED <name>:
#   NOT RUN`), and the last line says so again, never leading with PASS:
#   `NOT A PASS: every step that ran passed; NOT RUN: …`.
# - **A run with a skip exits 3, never 0**, and records no verdict
#   (tools/verdicts.py refuses while SKIP is set). Only a whole run passes.
#
# Only the steps worth skipping are named: the slow ones, and those whose
# skipping leaves the rest meaningful. Builds a later step needs are not.

STEPS="test tcp-traces native probes droplet-boot droplet-hello droplet-sleeps screen vmm-check vmm-same webbox-test shale-test vmm-pc pair sleeps vmm-timeouts gopher-judges sim fault-sweeps lossy rough native-full volume-sweep fat16-judge"

# **NOTHING NARROWS A JUDGE BEHIND THE GATES' BACK** (the second cold
# review, 2026-10-16): JUDGE_QUICK left in a shell silently dropped
# judge_native's loss check and the chat judges' long gates, and a full
# verdict was kept. A gate refuses them; SKIP is the way to narrow, and it
# says so. Inside, a script sets them on the one command that wants them.
for v in JUDGE_QUICK JUDGE_ONLY; do
    if [ -n "${!v:-}" ]; then echo "$v is set ('${!v}'): a gate run judges whole; unset it, or name what to leave out with SKIP"; exit 2; fi
done

# Spaces only: words split by tabs or newlines would pass the check below
# and then match nothing.
SKIP="$(echo ${SKIP:-})"
for word in $SKIP; do
    case " $STEPS " in
        *" $word "*) ;;
        *) echo "SKIP names no step: '$word' (the steps: $STEPS)"; exit 2 ;;
    esac
done
not_run=()

# `if ! skip <name>; then …the step…; fi`: true, and said, when SKIP names
# it. A name missing from STEPS is a script's mistake, and stops the run.
skip() {
    case " $STEPS " in
        *" $1 "*) ;;
        *) echo "skip: '$1' is not in tools/skip_lib.sh's STEPS"; exit 2 ;;
    esac
    case " $SKIP " in
        *" $1 "*) not_run+=("$1"); echo "SKIPPED $1: NOT RUN"; return 0 ;;
    esac
    return 1
}

# The last line, for a run whose steps all passed: PASS only when every
# step ran; otherwise exit 3, naming what did not.
passed() {
    if [ ${#not_run[@]} = 0 ]; then echo "$1: PASS"; exit 0; fi
    echo "$1: NOT A PASS: every step that ran passed; NOT RUN: ${not_run[*]}"
    exit 3
}
