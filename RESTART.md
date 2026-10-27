# Restarting on failure while serving

**On by default, and served.** An application's kernel restarts the machine
on a failure while serving, unless built with `-Drestart=false`, which halts
instead. A droplet's reset restarts it (measured on a real droplet, below).

**Where it is:**
- `src/restart.zig`: the record kept in CMOS and the back-off (host-tested);
- `src/kept_log.zig`: the log kept past the kernel, in two slots (host-tested);
- `src/reset.zig`: the three ways of resetting;
- `src/restarting.zig`, the glue: `serving()`, where the main loop starts,
  routes `serial.fail`, the panic handler and `interrupts.gm_exception` to
  the restart.

**`probe/backoff.elf`** (`probe/run.sh backoff`) runs it end to end, on
QEMU's `pc`, on the droplet-shaped boot through SeaBIOS and our loader on
dirty RAM, and on `microvm`: four restarts in a row, each next boot finding
the record counting them and the boot before's kept log ending with its
reason; then the back-off, and serving again.

## Two kinds of failure

**A refusal at boot halts.** Before `serving()`, a fatal error is a fact
about the machine or its configuration (the wrong volume or no disk, a
config line it cannot read, no DHCP lease, not enough memory, a FAT that
cannot be held), and a restart would meet it again. Halting keeps the
reason on the screen instead of scrolling it away in a loop. A path that
halts ends in `serial.exitQemu`: the exit door at port `0xF4`, which ends a
QEMU run, then `hlt` for ever, which on a droplet waits for someone to
reboot it.

**A failure while serving restarts:** a `@panic` in the application, a
ReleaseSafe safety check, the stack guard, `io.zig`'s directory-walk limits,
a CPU exception. The machine was serving a moment ago and will very likely
serve again.

**A disk that stops answering while serving restarts the machine** too
(`restart.disk_ended`; the one constant to set to `.serve_refusing` to
overrule it): it answers nothing again until the device is reset, and a
boot is what resets it. A disk dead at boot fails the mount, which halts,
so it cannot loop.

The NMI handler only logs and carries on.

**A restart loop backs off, and never halts:** a machine anyone can crash
must not be handed to them to stop for good. The restarts in a row (within
an hour of each other) are counted in the record; none waits for the first
three, then 1, 5 and 15 minutes, and 15 from then on (`backoffSeconds`).
During the wait the machine is up, and its screen says why it restarted and
when it will serve again.

**A hang is not covered.** A loop that never returns to the main loop stops
the machine as surely as a panic, with nothing on the screen. There is no
watchdog on the timer.

## How it resets

`reset.now` tries three ways in order, as Linux does, each followed by a
pause long enough for it to land:

| method | how | QEMU `pc` (the droplet's machine) | QEMU `microvm` |
|---|---|---|---|
| reset control register | `0x02` then `0x06` to port `0xCF9` (PIIX3's) | restarts | nothing |
| keyboard controller | `0xFE` to port `0x64` | restarts | nothing |
| triple fault | an empty IDT, then `int3` | restarts | restarts |

The two device resets go through the chipset, which resets the devices
too; the triple fault resets the processor, and cannot fail to happen.
ACPI's reset register on `pc` names `0xCF9` again, so it is not parsed.

**On a real droplet all three restart it and none powers it off;** CMOS and
RAM past the kernel survive each. **Before trusting the restart on another
provider,** measure it the same way: `zig build restart`, then
`droplet/image.sh probe/restart.elf restart.img`, write that to the boot
disk from the provider's recovery console, and boot it. `probe/restart.zig`
tries each method in turn; the last screen reads `PASS` and `boot N`, where
N − 1 methods restarted it, and a line saying `did NOT restart this
machine` for any that did not. A machine that powered off instead forgets
CMOS, and its next boot says `first boot: CMOS stage byte`.

## What survives a restart

| where | survives? | why |
|---|---|---|
| the kernel's `.text`, `.data` | rewritten | the loader reads the kernel again on every boot |
| the kernel's `.bss` | zeroed | both loaders zero it |
| RAM past the kernel, outside the BIOS's | **kept** | nothing writes it |
| CMOS | **kept** | the RTC's NVRAM is not reset |

A power cycle from DigitalOcean's side keeps neither, and reads as a fresh
boot.

**So the record is in CMOS and the log in RAM past the kernel.** The record
is eight bytes at CMOS `0x70`–`0x77`, past every byte SeaBIOS and QEMU's
`pc_cmos_init` use (`src/restart.zig` lays it out). The kept log's region
is the first page past the kernel's image, cut out of the page heap
(`restarting.reserved`). Its header is checked, not trusted: dirty RAM or a
boot that never sealed its slot reads as no log. `/admin/host` serves the
boot before's log, ending with the reason it restarted.

**The restart path depends on as little as possible:** interrupts off
first, no allocation, plain stores and port writes, then the three methods.
A fault inside it triple-faults, which restarts anyway.

## How a judge tells a restart from a halt

QEMU's `-no-reboot` turns any reset into QEMU ending with exit status 0, so
`probe/run.sh` and `droplet/boot.sh`, which pass it, can see a restart:

| what the kernel did | QEMU's exit status, with `-no-reboot` and the door |
|---|---|
| passed (door, 0) | 1 |
| failed (door, 1) | 3 |
| restarted (any method) | **0** |
| halted with no door (`NO_DOOR=1`) | none: the judge's timeout ends it |
