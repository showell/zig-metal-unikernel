#!/bin/bash
# **THE PROBES, BOOTED THE WAY A DROPLET BOOTS THEM.** Each one is put on a
# disk with the boot loader and checked as a GPT disk (image.sh), and the
# droplet-shaped QEMU starts it from its BIOS. A probe passes when it prints PASS and leaves through the door
# with 0.
#
#   droplet/boot.sh          every probe below
#   droplet/boot.sh clock    just one
#
# **EVERY BOOT STARTS ON DIRTY RAM** (droplet.sh's DIRTY=1): a machine that
# hands over zeroed memory hides a loader that forgot to zero it.
#
# `memory` boots at three sizes, because the memory map is the one thing the
# loader builds from what the BIOS says, and 4 GB is where the map gets a hole
# in it (the PCI window, under 4 GB) and a region above it. `block` and `net`
# find their devices on the PCI bus, as on a droplet; `block` writes the disk's
# last sector, which on this image is the backup GPT header, so it runs after
# sgdisk has looked. `rng` finds no virtio-rng, because a droplet has none,
# and draws from RDRAND alone.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
want="${1:-all}"

failed=0
# probe:memory-in-MB
for one in memory:512 memory:2048 memory:4096 clock:2048 block:2048 net:2048 rng:2048; do
    probe="${one%%:*}"
    memory="${one##*:}"
    [ "$want" = all ] || [ "$want" = "$probe" ] || continue
    img="$WORK/$probe.img"
    if ! "$HERE/image.sh" "$ROOT/probe/$probe.elf" "$img" > "$WORK/image.txt" 2>&1; then
        echo "FAIL $probe  $(cat "$WORK/image.txt")"; failed=1; continue
    fi
    began=$(date +%s%N)
    DIRTY=1 MEMORY="$memory" DISK="$img" timeout 120 "$HERE/droplet.sh" > "$WORK/out.txt" 2>&1
    code=$?
    ms=$(( ($(date +%s%N) - began) / 1000000 ))
    # The door turns the guest's 0 into QEMU's 1.
    if [ "$code" = 1 ] && [ "$(tail -1 "$WORK/out.txt" | tr -d '\r')" = PASS ]; then
        printf 'PASS %-7s %5s MB  %s (%s ms)\n' "$probe" "$memory" \
            "$(grep -a -m1 'total ram\|tsc_hz\|device at\|virtio-rng' "$WORK/out.txt" | sed 's/^ *//')" "$ms"
    else
        echo "FAIL $probe  $memory MB, exit $code:"; sed 's/^/    /' "$WORK/out.txt"; failed=1
    fi
    # **ONE BOOT'S SCRATCH AT A TIME**: DIRTY=1's RAM file is the machine's
    # whole memory, so leaving each to the EXIT trap held 10 GB at once by
    # `net`, and a box with less free failed `net` and `rng` with no output.
    rm -f "$img" "$img.ram" "$img.config"
done
exit $failed
