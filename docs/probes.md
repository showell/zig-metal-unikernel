# The probes, and what cost time

A probe is a kernel that is only a driver and a serial port (`probe/*.zig`,
one root file with a `kmain` each). They exist so a driver can be put on
virtual hardware and checked before anything is built on top of it.
`probe/run.sh` boots each under QEMU's `-M microvm` and maps QEMU's exit code
back to the guest's; `probe/run.sh <name>` boots one.

## What the probes check

**`block`** brings the device up, reads sector 0 and checks its boot
signature, then writes the last sector and reads all 512 bytes back. Reading
proves bytes moved; writing and comparing proves they moved **where we said**.

**`net`** brings the NIC up and takes a DHCP lease. QEMU's user-mode
networking answers DHCP at 10.0.2.2 with nothing configured, so the result
needs no second machine — and it is the same exchange Cobblestone's
`dhcp-acquire` performs through the Roc machine and an emulated NE2000. Two
paths, one protocol, one answer to compare.

**`http`** takes a lease, listens on port 80 and answers one request.
**Its verdict is not its own output** — QEMU forwards a host port to the
guest's 80, `run.sh` fetches from it, and what curl got back is what is
checked. The guest's console only says what it thought happened.

```
zig-metal-unikernel http probe
  address: 10.0.2.15
  listening on port 80
  request: GET / HTTP/1.1
  answered and closed
```

The rest: `stdhttp` (zig's own HTTP server, [port.md](port.md)), `stdio` (the
`Io.Dir` surface), `vfat`, `restore`, `append` and `replace`/`replace_cached`
([disk.md](disk.md)), `clock` and `realunset` (the TSC, the RTC, and refusing
a wall-clock read before the clock is set), `rng`, `memory`
([port.md](port.md)), `ladder` ([tcp.md](tcp.md)), `restart` and `backoff`
(the restart on failure, [RESTART.md](../RESTART.md)), and `fetch`, the client
kernel: one GET with tcp.zig's `connect` to `python3 -m http.server` on the
host (10.0.2.2 to the guest), its outcome the exit code (`src/fetch.zig`;
`probe/judge_fetch.py` judges QEMU's code and the body's hash: a 200, 300 KB,
refused, no ARP, and a command line without its deadlines).

**The sleeper** (`probe/sleeper/`, `zig build sleeper`, into
`probe/sleeper.elf`) is not a probe but a tiny application built through
`addAppKernel`: it only wakes, every `period_ms`, and writes a line each
time. It is the test of a sleeping kernel
([DESIGN-sleep.md](designs/DESIGN-sleep.md)): `droplet/sleeps.py` (tier 1)
times it on a real timer under KVM, and metal-vmm's `sleeps.sh` (tier 3) in
the machine's own time. `probe/run.sh` does not boot it.

A run of `probe/run.sh` looks like this (an excerpt):

```
PASS block |   wrote and read back sector 65535: 512 bytes match
PASS stdio |   mutex: locked and unlocked twice, no contention possible
PASS vfat |   auth/damian: . .. api-key _session_secret
     vfat | fsck.vfat finds no error in what we wrote
     vfat | the Linux VFAT driver reads every name and byte we wrote
PASS restore |   auth/damian/_session_secret still reads: sixteen bytes!!!
PASS append |   createFile: .truncate = false keeps, the default empties
     append | fsck.vfat finds no error after 600 appends
     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte
PASS replace |   tree/: four levels with data, deleted whole
     replace | fsck.vfat finds nothing, and reclaims nothing
     replace | sessions/ is 7 clusters with 6 gap(s) and 2 straddling run(s); all 100 files read back byte for byte
PASS clock |   .real: the time it was told, advancing with .awake, re-anchored when told again
     clock | ok   unix 1789600584 is within the host's clock [1789600582, 1789600591]
     clock | ok   tsc_hz 2494162684 vs the host's 2494134000 (0.001%)
     clock | pinned to midnight, across a leap day: civil 2020-3-1 0:0:1, four formats agree
     clock | pinned to noon: civil 2020-3-1 12:0:1, four formats agree
     clock | pinned to 4 PM: civil 2020-3-1 16:0:1, four formats agree
PASS clock | refused as it must: the PIT would not calibrate the TSC
PASS realunset | refused as it must: PANIC: Io.Clock.now(.real) before setRealTime()
PASS rng |   over 4 KB: 16347 of 32768 bits set, commonest byte appears 25 times
PASS net |   server : 10.0.2.2
PASS http | curl got "hello from no Linux"
PASS stdhttp | curl got "hello from std.http.Server, with no Linux under it"
PASS fetch | every case passed
```

**One gate of the judge at a time.** `probe/run.sh gopher <gate>` runs one;
a name it does not know is an error that lists them all (the judge's `GATES`
in `probe/judge_gopher.py`), not a silently complete run. The single requests
go to one boot by default; `probe/run.sh gopher isolated` gives each its own
boot, which proves an answer owes nothing to an earlier one. No tier script
runs `isolated`; `probe/long_run.sh` does.

**Two builds.** `-Ddev` builds the kernels in Debug — a rebuild of the real
server in seconds instead of ReleaseSafe's tens — and `run.sh quick` builds
that way and runs the judge with test-sized waits (a 3-second stream
keepalive), one boot for the single
requests, and without the boots that exist to be long. Shipping kernels are
ReleaseSafe, and every run says which build it judged, read from a marker
each kernel carries.

## Things that cost time

Written down because each one looks like something else.

**QEMU's multiboot loader refuses a 64-bit ELF** outright: *"Cannot load
x86-64 image, give a 32bit one."* PVH is the other door into the same
machine, takes an ELF of either width, and is what every modern microVM boots
anyway.

**`virtio-mmio` defaults to the LEGACY interface.** Every transport reads
version 1 until `-global virtio-mmio.force-legacy=false`, and a driver that
speaks virtio 1.2 correctly refuses to talk to it.

**microvm has 24 transports and fills them from the top.** A single
`-device virtio-blk-device` lands on bus 23 at 0xFEB02E00, with slots 0–7
present but empty — which is indistinguishable from "no device at all" if
you only scan eight of them. `info qtree` answers this in one command;
guessing does not.

**There is no port 0x61.** The textbook TSC calibration gates PIT channel 2
through the PC speaker's port and reads its output there; `microvm` has no
speaker, and the port reads 0xFF. Channel 0's count, latched and read back,
needs neither.

**A request sent while the guest is still starting takes six seconds.**
QEMU's user-mode network accepts the host connection at once and forwards the
SYN; a guest with no NIC driver running yet drops it, and QEMU's own TCP
retries only about six seconds later. `judge_gopher.py` waits for the guest to
print "listening" first.

**`-M microvm` leaves the CMOS clock out under KVM** unless asked
(`rtc=auto` means on under TCG, off under KVM, where microvm expects the guest
to use kvmclock). A port with nothing behind it reads 0xFF, and 0xFF in
register A has the update-in-progress bit set — so a missing chip looks
exactly like one forever mid-update. Every boot asks for `rtc=on,pit=on` by
name, and the kernel calls a 0xFF register A what it is: `NoChip`.

**A spin count is not a duration.** Under KVM a register read is two port
writes that exit to the emulator, so a spin costs thousands of times more than
under TCG, and "two billion spins, just over a second" becomes hours. The RTC
waits are durations of the calibrated timestamp counter; a missed edge reports
how many polls it made and what the seconds register said, and polls are a
quarter of a millisecond apart with nothing touched in between — how a real
chip wants to be treated, at the cost of that much anchor precision.

**Timing runs under KVM.** On microvm a boot asks for KVM only when it is
for timing (`judge_gopher.py`'s `start_kernel(kvm=True)`), because those
numbers are about speed and a deployed machine does not emulate its CPU; a
timing run that cannot get KVM fails rather than quietly measuring TCG under
its name. The correctness judges on microvm stay on TCG; the droplet-shaped
machine uses KVM whenever `/dev/kvm` is usable, as a droplet does.
