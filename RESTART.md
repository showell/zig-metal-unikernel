# Restarting on failure while serving

**On by default, and served** (`9a337ca`, in every release from v17 on:
`git tag --contains 9a337ca`). A droplet's reset was measured to restart it
([droplet/RESTART-TEST.md](droplet/RESTART-TEST.md), the test that decided
it), and gopher.elf restarts on a failure while serving unless built with
`-Drestart=false`. A disk that stops answering restarts it too (see "Two
kinds of failure").

**What is built:**
- `src/restart.zig` (the record and the back-off, host-tested);
- `src/kept_log.zig` (two slots past the kernel, host-tested);
- `src/reset.zig` (the three methods);
- `src/restarting.zig`, the glue: `serial.on_fatal`, set by `serving()`,
  routes `serial.fail` and the panic handler to the restart.

**`probe/backoff.elf`** (`probe/run.sh backoff`) runs it end to end, on
QEMU's `pc`, on the droplet-shaped boot through SeaBIOS and our loader on
dirty RAM, and on `microvm`: four restarts in a row, each next boot finding
the record counting them and the boot before's kept log ending with its
reason; then the back-off, and serving again.

The design below is what was built, with two refinements:
- **There is no 10-minute clause.** A boot after a restart always follows
  it within seconds, so the back-off depends only on the count of restarts
  in a row.
- **The record lives at CMOS `0x70`–`0x77`.** That is past the last byte
  SeaBIOS (`0x5F`) or QEMU's `pc_cmos_init` (`0x5D`) uses.

The rest of this page is the design as written before it was built (old
QUEUE.md item 7). The measurements come from `probe/restart.elf` (below),
run on QEMU 8.2 under TCG in the cloud container.

## The fatal paths

`serial.fail`, the kernel's `panic` (every `@panic`, and every safety check
in ReleaseSafe: an index out of bounds, an overflow, an unwrapped null), and
`interrupts.gm_exception` (a page fault, a #GP, a double fault). A path that
halts ends in `serial.exitQemu`: a write to the exit door at port `0xF4`,
then `hlt` for ever. Under QEMU the door ends the run, which is what the
judges want; on a droplet the door is not there, and the machine sits
halted until someone reboots it.

## Two kinds of failure

*(metal-vmm QUEUE 198.3.)* **A disk that stops answering
while serving restarts the machine** too (`restart.disk_ended`, one
constant, `.serve_refusing` to overrule it): it answers nothing again until
the device is reset, and a boot is what resets it. Its record says "a disk
that stopped answering", and the kept log holds what the disk said last. A
disk dead at boot fails the mount, which halts, as every refusal at boot
does, so it cannot loop.

**A refusal at boot keeps halting.** Before `listening on port 80`, a fatal
error is a fact about the machine or its configuration, and a restart would
meet it again:

- the wrong volume, or no disk;
- a config line it cannot read;
- no DHCP lease;
- not enough memory for its connections;
- a FAT that cannot be held.

Every `serial.fail` that `probe/gopher.zig` reaches before `serving` is one. Restarting on any
of them would turn one clear message into a loop of them, and the console
shows the screen, which would scroll the reason away. Halting with the
reason on the screen is the right answer, and it stays.

**A failure while serving restarts.** Once the main loop runs, a fatal error
is almost always about one request or one moment:

- a `@panic` in the application;
- a safety check;
- the stack guard (`gopher.zig`'s `reportStack`);
- `io.zig`'s directory-walk limits;
- a CPU exception.

The machine was serving a moment ago, and will very likely serve again.

**The line between them is one flag:** `serving`, set where the main loop
starts. `serial.fail`, the panic handler and `gm_exception` all end in one
`fatal(why)`:

- before `serving`, it halts as it does now;
- after, it restarts.

The NMI handler stays as it is: logged and ignored.

### A restart loop, and the budget

A failure that a request can reach can be reached again, by the same client
or a crawler. So can one that comes from stored data, such as a file whose
contents panic a parser on every visit to some page. Two answers are wrong:

- **halting after N restarts** hands anyone who can crash the machine N
  times a way to take it down for good;
- **restarting at once for ever** fills the log with boots and hides the
  reason.

**Restart every time, but back off.**
- **The record:** the restart count and the time of the last restart, in
  CMOS (below).
- **The back-off:** if the last restart was under 10 minutes ago, wait
  before serving: 0 s for the first three, then 1, 5, and 15 minutes,
  capped at 15.
- **During the wait,** the machine is up and logging, and its screen says
  why it restarted and when it will serve again.
- **The reset:** a restart more than an hour after the last one starts the
  count again.

A refusal at boot is still a halt, with or without the budget.

### What it does not cover

**A hang is not a failure** to any of the paths above. A loop that never
returns to the main loop stops the machine just as surely as a panic does,
with nothing on the screen.

The 1 ms timer that `interrupts.zig` already takes can be a watchdog:
- **the counter:** the main loop counts its turns;
- **the check:** the timer interrupt notices when the counter has not moved
  for, say, 30 seconds;
- **the action:** it calls `fatal("the main loop has not turned in 30 s")`.

This is the same restart, from a different place. It is worth doing after
the restart itself, and it needs care: the handler interrupts arbitrary
code, so it must use only `putPort` and the restart path.

## How to reset an x86 machine with no OS

**Three ways, measured** (`probe/restart.zig`, which tries each in turn):

| method | how | QEMU `pc` (i440FX/PIIX3, the droplet's machine), SeaBIOS + `droplet/loader.S`, dirty RAM | QEMU `microvm` (`probe/run.sh`'s), PVH |
|---|---|---|---|
| reset control register | `0x02` then `0x06` to port `0xCF9` | **restarts** | nothing happens |
| keyboard controller | wait for the input buffer, then `0xFE` to port `0x64` | **restarts** | nothing happens |
| triple fault | load an empty IDT (`lidt` with limit 0), then `int3` | **restarts** | **restarts** |

- **`0xCF9` is PIIX3's Reset Control Register.** It is a device QEMU
  emulates in the same way under KVM. `lspci.txt` shows a droplet has
  PIIX3, which is what `droplet.sh` builds.
- **The keyboard controller** is QEMU's i8042, present on `pc` and absent
  on `microvm`.
- **A triple fault under KVM** is a `KVM_EXIT_SHUTDOWN`, which QEMU turns
  into the same reset request. It works wherever there is a processor.
- **ACPI's reset register** is not worth parsing the FADT for: on QEMU's
  `pc` machine it names `0xCF9` and the value `0x06`, so it is the first
  method again.

**The recommendation is all three, in that order, as Linux does.**
- **The order:** try `0xCF9`, then the keyboard controller, each followed
  by a pause long enough for the reset to land. Fall through to the triple
  fault, which cannot fail to happen.
- **Why not the triple fault alone:** the two device resets go through the
  chipset, which also resets the devices. The triple fault resets the
  processor, and QEMU resets the machine for it; real hardware may not.

**Measured on a real droplet** (2026-10-03, Steve at DigitalOcean's
recovery console, droplet/RESTART-TEST.md): `restart.elf` reached
`boot 4`, "restarted by a triple fault", `PASS`. **All three ways restart
the droplet; none powers it off.** CMOS and RAM past the kernel survived
each, as under QEMU. Under KVM on the box, the same probe through a
`droplet.sh` without `-no-reboot` also reaches `boot 4` and `PASS`.

So the restart is safe to turn on for a droplet: a failure while serving
resets the machine, and it comes back.

## How the judge tells a restart from a halt

QEMU's `-no-reboot` turns any reset into QEMU ending, **with exit status
0**:

| what the kernel did | QEMU's exit status, with `-no-reboot` and the door |
|---|---|
| passed (door, 0) | 1 |
| failed (door, 1) | 3 |
| restarted (any method) | **0** |
| halted with no door (`NO_DOOR=1`) | none: the judge's timeout ends it |

So `probe/run.sh` and `droplet/boot.sh`, which already pass `-no-reboot`,
can see a restart today, measured above.

**The gates the wiring should add:**
1. **A failure while serving restarts.** Use a kernel, or a config knob
   for the judge only, that fails on a chosen request. With `-no-reboot`:
   exit status 0, and the last line `RESTART: <why>`.
2. **It comes back, and says why.** The same run without `-no-reboot`:
   - the log shows a second boot;
   - its first lines say `restarted after: <why> (restart 1)`, read from
     the record below;
   - the machine serves the next request.
3. **A refusal at boot still halts.** A bad config: exit status 3 with the
   door, and only one boot banner without it.
4. **The back-off:** a kernel that fails on every request.
   - The fourth restart must wait, and say so.
   - Under TCG a minute is a minute, so this gate wants a test-only scale
     on the delays.

## What survives a restart

**Measured on both machines, after every method:**

| where | survives? | why |
|---|---|---|
| the kernel's `.text`, `.data` | rewritten | the loader reads the kernel from disk on every boot (`loader.S`; QEMU's PVH option ROM reloads it from fw_cfg) |
| the kernel's `.bss` | zeroed | both loaders zero it (`loader.S`'s `zero_the_rest`; QEMU's): the probe's `.bss` marker read zero on every boot |
| RAM past the kernel, outside the BIOS's | **kept** | nothing writes it: the probe's record at 64 MiB came back intact, from 0xA5-filled RAM |
| CMOS | **kept** | the RTC's NVRAM is a device QEMU does not reset |

A power cycle is different. A droplet powered off and on from DigitalOcean's
side starts a new QEMU, so it keeps neither RAM nor CMOS. That is a fresh
boot, and should read as one.

**So the restart record goes in CMOS, and the log in RAM past the kernel.**

- **In CMOS,** a few bytes:
  - a magic byte;
  - the restart count;
  - the last restart's time, in minutes since an epoch, from the RTC;
  - a reason code (panic, exception, the stack guard, the watchdog);
  - a checksum.

  Bytes `0x40` to `0x7F` past what SeaBIOS reads; the probe uses `0x7D`.
  The box Claude should check the bytes chosen against SeaBIOS's
  `<seabios>/src/hw/rtc.h` and QEMU's `pc_cmos_init` before using them.
- **The log ring (item 6) moves its bytes out of `.bss`** to a fixed region
  past `_kernel_end`, kept out of the page allocator.
  - **Today** `serial.ring`'s header is in `.data` and its bytes in `.bss`,
    so both are gone after a restart.
  - **The region** holds the bytes and a header: a magic, `head`, `total`,
    a boot number and a checksum over the header.
  - **At boot,** if the header checks, that ring is the last boot's log.
    The machine keeps it, read-only, for the status page to serve as "the
    boot before this one, which ended with: <why>". It then writes this
    boot's log into a second region. Two regions, alternating by boot
    number, so the previous log is never overwritten by the next.
  - **The header is checked, not trusted,** as the probe's record is.
    Dirty RAM, or a region the BIOS used, reads as "no previous log".
  - **The bytes need no check:** the header says how many there are, and
    the redaction happened when they were written.
- **`fatal(why)` writes `why` into the ring before it resets,** like any
  line, so the previous boot's log ends with it. The CMOS reason code is
  for when the RAM did not survive.

## The restart path itself

The path runs after something has already gone wrong, so it must depend on
as little as possible:

- **interrupts off** (`cli`) first;
- **no allocation**;
- **a known stack:** the double fault already switches to an IST stack, and
  a panic from a blown stack would need the same;
- **the ring and CMOS writes are plain stores and port writes,** which
  cannot fail;
- **then the three methods,** each with its pause.

`gm_exception` and the panic handler can both reach it. A fault inside the
restart path triple-faults, which restarts anyway.

## Summary

1. Keep halting on refusals at boot; restart on failures while serving.
   The line between them is a `serving` flag.
2. Restart through `0xCF9`, then the keyboard controller, then a triple
   fault. All three restart the droplet's QEMU machine; on `microvm` only
   the last does.
3. Back off from repeated restarts instead of halting. The restart record
   lives in CMOS, which survives every method.
4. The log ring moves to RAM past the kernel, which survives every method
   too, so the next boot can serve the previous boot's log, ending with
   the reason.
5. The box Claude measures, under KVM and on a real droplet, that a guest's
   reset is a restart and not a power-off. Nothing is wired until that
   holds.
