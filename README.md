# zig-metal-unikernel

A small operating-system kernel, written in Zig, that runs one web
application on a cloud machine with nothing else under it. No Linux, no libc,
no system calls: the kernel boots the machine, drives the network card and the
disks, and serves HTTP itself. It has served
[lynrummy.com](https://lynrummy.com) since 2026-10-04, and
[dogpark.lynrummy.com](https://dogpark.lynrummy.com), a second application
on a droplet of its own, since 2026-10-16.

This repo was called **gopher-metal** until 2026-10-13. GitHub redirects the
old links, and dated documents here still use the old name.

## What it is

A **unikernel** is one program compiled together with just enough kernel to
run it, booted directly on a machine (real or virtual), with no general
operating system in between. This one is written in Zig 0.17 and targets
`x86_64-freestanding`, Zig's name for "no operating system".

What it does by itself, with no borrowed code below the application:

- **Boots a real cloud machine.** In production that is a DigitalOcean
  **droplet** (DigitalOcean's name for a virtual machine you rent). A droplet
  starts like an old PC: its BIOS runs the first sector of the disk. This repo
  has its own two-stage boot loader (`droplet/loader.S`) that takes it from
  there to the kernel, and its own disk-image builder (`droplet/image.zig`).
  Under QEMU the kernel is started directly through PVH, the entry point QEMU
  and other virtual-machine monitors use for 64-bit kernels.
- **Drives its own devices.** Virtio network cards and disks (virtio is the
  standard family of virtual devices a hypervisor offers), over both the PCI
  bus a droplet has and the simpler MMIO layout QEMU's small `microvm`
  machine has; DigitalOcean's attachable volumes (virtio-SCSI); the serial
  port; the VGA text screen DigitalOcean's web console shows; the CMOS clock;
  the interrupt controller and timer.
- **Speaks the network itself.** Its own DHCP, ARP, IPv4 and TCP. On top of
  its TCP it runs Zig's standard-library HTTP server, `std.http.Server`,
  unmodified.
- **Keeps files itself.** Its own FAT16 and FAT32 (the filesystem a USB stick
  uses), read and write, with long names and folders. FAT was chosen because
  Linux can read and write the same volume, which makes it easy to judge and
  to back up.

What it is not:

- **No processes and no shell.** One program is compiled into the kernel. You
  cannot log in to it or run anything else on it.
- **One core, no threads.** One loop moves every connection along and serves
  one request at a time, start to finish. There is no preemption.
- **No TLS.** It speaks plain HTTP/1.1. In production a separate Linux machine
  runs Caddy, which handles HTTPS and forwards requests to it over
  DigitalOcean's private network.
- **Not general purpose.** It runs Zig applications written against one
  library, zig-webbox (below), and nothing else.
- **Not for arbitrary hardware.** It has been made to work on one kind of
  machine: a DigitalOcean droplet, and QEMU set up the same way. It does
  not claim to run anywhere else. Virtio is a fairly common standard among
  hypervisors, so other virtual machines are a plausible next step. The
  kernel can be extended gradually as we get access to other kinds of
  hardware. There are no promises beyond that.

**Battle tested, and what that honestly means.** It has served
lynrummy.com since 2026-10-04 for about three regular daily users, who
upload from their phones. That is all the battle there has been. It has
never been under real load or stress. Caddy sits in front of it on a
private network, so production only exercises a well-behaved, happy-path
setup: one polite client and no hostile or lossy traffic. The harder cases
are tested elsewhere. The judges and metal-vmm's faults and sweeps drop,
delay and damage frames, stall and reset clients, fail and cut disks, and
check what the machine did about it.

## How it is used now

### The applications

Both applications are built on **[zig-webbox](https://github.com/showell/zig-webbox)**,
a small Zig library: the application supplies its routes, pages and data
rules, and the library does the HTTP, cookies, live streams and storage. The
library reaches the machine only through one module, `host_io`. On Linux that
module is the standard library's; here it is this kernel's
(`src/host_io_metal.zig`). No line of the application changes between the
two.

- **[angry-gopher](https://github.com/showell/angry-gopher)**, Steve
  Howell's personal site, lynrummy.com: a chat and a handful of small apps
  (Lyn Rummy, a two-player rummy game, among them). **In production on this kernel.**
  It is a combination (webbox's `combo.Mount`, in angry-gopher's
  `zig-server/src/router.zig`): angry-gopher keeps `/`, and
  [cobble-webbox](https://github.com/showell/cobble-webbox)'s Codex Chat
  is mounted at `/codex-chat` (served since v38) and its UO town at `/uo`
  (on `master`, not yet served).
- **[dog-park](https://github.com/showell/dog-park)**, a small herding
  game on zig-webbox. **In production on this kernel since 2026-10-16**, at
  dogpark.lynrummy.com, on its own droplet. dog-park builds its own image,
  with this repo as a dependency, through `addAppKernel` (below; metal-vmm
  QUEUE 215) and `droplet/app_image.py`, and runs its own QEMU gate. This
  repo neither builds nor judges it (8af778b: an application is not this
  repo's test of itself).

**The same source, the same answers.** angry-gopher builds as an ordinary
Linux program and as a kernel from this repo. The checks here send the same
requests to both, built from the same source over the same files, and require
the same answers: status, redirect, cookies, content type, and the body byte
for byte (times stamped by the clock are compared to the window each side
handled the request in). Files a request writes are read back from both sides
and must match. Linux is the reference: if the kernel disagrees with Linux,
the kernel is wrong.

### The repos

The repos, kept separate, checked out side by side:

```
                       zig-webbox  (the library)
                  /         |          \
     angry-gopher        dog-park        observatory
   (lynrummy.com)  (dogpark.lynrummy.com) (watches Dog Park)
         |                  |               |
         |                  (each builds its own image,
         |                   through addAppKernel)
              zig-metal-unikernel  (this repo: the machine)
                    /          \
            metal-vmm            zig-coverage-sdk
      (test hypervisor)          (coverage properties)
```

- **zig-metal-unikernel** (this repo): the kernel, its drivers, TCP, FAT, the
  boot loader, the release tools, and the checks that hold the kernel to the
  Linux builds.
- **[zig-webbox](https://github.com/showell/zig-webbox)**: the library both
  applications are written against.
- **[angry-gopher](https://github.com/showell/angry-gopher)**: the
  application this repo builds and serves, compiled from its checkout as it
  is; nothing is copied in. **[dog-park](https://github.com/showell/dog-park)**:
  an application this repo does not build; it builds itself into a kernel
  through `addAppKernel`, and its image through `droplet/app_image.py`.
- **[cobble-webbox](https://github.com/showell/cobble-webbox)**: Codex
  games compiled to Zig webbox apps. `zig build gopher` compiles its
  `codex_chat` and `uo_town` modules from `../cobble-webbox` (`-Dcobble-root`),
  since angry-gopher's router imports them.
- **[shale](https://github.com/showell/shale)**: the script language
  behind `/admin/script`; every application's kernel compiles it from
  `../shale` (`-Dshale-root`).
- **[roc-webbox](https://github.com/showell/roc-webbox)**: Roc apps on
  webbox; its `zig build metal` makes its TODO list a kernel through
  `addAppKernel`, and dog-park combines that list with the park. Not
  deployed.
- **[observatory](https://github.com/showell/observatory)**: a small
  application that wakes on a period, fetches another server's `/version`
  through its host's fetch, writes a line, and sleeps; built through
  `addAppKernel` like dog-park, and the reason for the sleep
  ([`docs/designs/DESIGN-sleep.md`](docs/designs/DESIGN-sleep.md)). Not
  deployed.
- **[metal-vmm](https://github.com/showell/metal-vmm)**: a deterministic
  hypervisor of our own, on Linux's KVM, used only for testing. It runs the
  real kernel with time, the network and the disks under the test's control,
  so a run can lose a chosen packet or fail a chosen disk write, and the same
  seed gives the same run every time. It also holds the one shared work queue
  for all these repos (`QUEUE.md`).
- **[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk)**:
  **coverage properties**, assertions about a whole run rather than one
  moment. `always(...)` must hold every time it is reached; `sometimes(...)`
  must be true at least once, so a case the tests meant to exercise but never
  did is a failure. The checks here read them. Every build needs it.

### Where lynrummy.com runs

- A droplet booted from a custom image this repo builds, with no Linux on it.
  It listens only on its private network card. Caddy, on an older Linux
  droplet, terminates HTTPS and forwards to it.
- **Two disks.** The boot disk holds the kernel and the site's own files
  (pages, pictures, and a config file), and a new release replaces it. The
  application's data (chat, accounts) lives on a separate DigitalOcean volume,
  FAT32, which a new release does not touch. The kernel refuses writes
  outside the data folders, and refuses to serve at all if the volume it was
  built for (named by its FAT serial number) is missing or another is
  attached, rather than answer as an empty site.
- **Each boot checks both disks** before serving, and reports what it finds.
- **`/admin/host`** (behind the admin login) shows the running server: the
  application's half (its version, commit, memory, refused requests) and the
  kernel's (this repo's commit, uptime, clock, connections, memory, disks,
  disk work, and the newest lines of the kernel's log). Linux shows the same
  page with its own half.

**Dog Park runs the same way**, on a droplet of its own on the same private
network, behind the same Caddy, but with **one disk**: its image holds the
kernel, the site and the data together, so a new release starts its games
over (dog-park's DEPLOY.md). It is the first application in production that
this repo does not build.

## Using it

### What you need

- **Zig 0.17.0**, exactly: the kernels link a patched compiler_rt made
  for 0.17.0 (`compiler_rt_0_17_0/`, whose README says why and when it
  goes), and the build refuses any other Zig.
- **Python 3**, for the judges and the release tools.
- **QEMU** (`qemu-system-x86_64`) and **KVM**, for anything that boots a
  kernel. Without KVM, the droplet-shaped machine runs under software
  emulation (`ACCEL=tcg`), slowly.
- **Disk tools:** mtools, `mkfs.vfat` and `fsck.fat` (dosfstools), `sgdisk`,
  and binutils' `as` and `ld` for the boot loader.
- **The sibling checkouts**, in one folder beside this one: `zig-webbox`,
  `angry-gopher`, `shale`, `cobble-webbox`, `zig-coverage-sdk`, and, for
  the full checks, `metal-vmm`. `build.zig` finds them as `../<name>`
  (`-Dgopher-root`, `-Dwebbox-root`, `-Dshale-root`, `-Dcobble-root` name
  another place). **One rule for
  every script too:** a sibling is `../<name>` beside the checkout running
  it, in this repo and in metal-vmm; an environment variable names another
  place (`GOPHER_ROOT`, `WEBBOX_ROOT`, `SHALE_CHECKOUT`, `COBBLE_ROOT`,
  `METAL_VMM`, `COVERAGE_SDK`, and metal-vmm's `GUESTS`, this repo's
  `probe/`).
- **The pinned zig-coverage-sdk content.** `build.zig` names a hash of the
  SDK's code (`coverage_sdk_pin`: its tracked `build.zig`, `build.zig.zon`,
  `src/` and `tools/`) and refuses any other, printing the hash the checkout
  has; a doc commit there leaves it standing. `-Dcoverage-sdk-unpinned`
  builds anyway.

Without QEMU, KVM or any sibling but the SDK (a laptop, a cloud container)
you can still run `./tier0.sh`, which is most of what catches a bug.

### Building a kernel for an application

    zig build gopher       # angry-gopher as a kernel: probe/gopher.elf
    zig build kernels      # every small test kernel ("probe"), into probe/

An application is a root Zig file that exports `site` (its routes) and
`hosting` (what only it can say about its data), plus an `assets.zon` naming
the files it serves. The kernel around it is the same file for every
application, `probe/gopher.zig`, and `addAppKernel` in `build.zig` puts the
two together. The contract between an application and its host is
[`HOST.md`](HOST.md).

**Another repository builds its own application into a kernel** with
`addAppKernel`, a public function of this package's `build.zig`. It names
this checkout as a dependency (a sibling, as zig-webbox is), builds its
application module itself, with its own options and imports, and hands over
the module, its `assets.zon` and a name; it gets the kernel's compile step
back:

    // build.zig.zon: .zig_metal_unikernel = .{ .path = "../zig-metal-unikernel" },
    const zmu = @import("zig_metal_unikernel");
    const app = b.createModule(.{ .root_source_file = b.path("src/hosted.zig"), .imports = ... });
    const elf = zmu.addAppKernel(b, b.dependency("zig_metal_unikernel", .{}), .{
        .name = "app.elf",
        .module = app,
        .assets = b.path("assets.zon"),
        .optimize = .ReleaseSafe,
    });

The module names no target or optimize mode (it takes the kernel's) and
imports neither `host_io`, `webbox` nor `shale`: `addAppKernel` adds this
machine's (webbox from `../zig-webbox`, shale from `../shale`, or the
dependency's `-Dwebbox-root` and `-Dshale-root`). Each
`.embedded` row of `assets.zon` is compiled in by name from its path,
relative to `assets.zon`, **unless the module already imports that name**:
a file the caller's own build makes (a wasm, say) is imported by the caller
from the step that makes it. The kernel's parts stay the kernel's: its root,
link script, `metal` and `gm_build`; `-Drestart` and `-Dcoverage` are
options of the dependency. `zig build gopher` goes through the same
function.

**Who calls it:** this repo's `zig build gopher` (angry-gopher, with
cobble-webbox's Codex Chat and UO town as its `parts`) and
`zig build sleeper`; dog-park's
`zig build metal` and `zig build metal-dogpark-todo`; roc-webbox's and
observatory's `zig build metal`. Each kernel's build lives in its
**primary application's repo** (Steve's convention for combinations too);
this repo builds only gopher.elf and its test application, the sleeper
(`probe/sleeper/`).

### Hosting a combination

A combination (webbox's `combo.Mount`: a primary application keeps `/`,
the others are served under prefixes) is one root module that imports
other applications as modules of their own. Hand those to `addAppKernel`
as **`parts`** (`App.Part{ .module, .assets }`): each part gets this
machine's `host_io`, `webbox` and `shale` and its own `assets.zon`'s
embedded files, as the top module does. dog-park's `build.zig`
(`metal-dogpark-todo`) is the worked example.

- **One module, one kernel.** `addAppKernel` rewires a module in place
  (red zone, imports, embedded files), so a module may be given to only
  one call, as the top module or as a part: a second call finds it
  importing `host_io` and stops the build. Build a fresh module per
  kernel (dog-park builds a second park module for its combination), and
  never hand over one a Linux executable also uses.
- **Two Roc apps, one runtime.** Roc apps find their runtime hooks in the
  binary's root, which is `probe/gopher.zig`; it forwards the
  application's `roc_hooks` declaration when the root has one
  (roc-webbox's `roc_hooks` module), and declares an empty one otherwise.
- **gopher.elf's parts** are cobble-webbox's two modules, built from
  `-Dcobble-root`'s sources, their pages named by cobble-webbox's
  `assets.zon`.

Useful options: `-Ddev` builds Debug kernels, which rebuild in seconds instead
of tens of seconds (releases are ReleaseSafe, and every run says which it
judged); `-Drestart=false` makes a crash halt the machine instead of
restarting it; `-Dcoverage` makes the kernel print its coverage properties.
`zig build --help` lists every step and option.

### Running it locally

There is no single "boot it and browse" command. A kernel is run by the
script that judges it:

    probe/run.sh                  # boot each test kernel under QEMU (~45 s)
    probe/run.sh clock            # just one
    probe/run.sh gopher           # boot the real server and judge it against Linux
    probe/run.sh gopher uploads   # one part ("gate") of that judge, in seconds
    droplet/boot.sh               # the test kernels, booted the way a droplet boots them

`probe/run.sh gopher` needs angry-gopher's Linux build too; it builds it.
A part name it does not know is an error that lists them all; the list is
`GATES` in `probe/judge_gopher.py` (among them `cases`, `members`,
`codex-chat`, `uploads`). Run directly, the judge takes four paths
(its docstring), given absolute, and `JUDGE_ONLY=<gate,…>` narrows it.
No gate covers the UO town at `/uo` yet.
`droplet/droplet.sh` is QEMU laid out like a droplet (the same chipset and
devices in the same slots, recorded from a real one); its header lists its
settings, among them forwarding a local port to the guest's port 80.
`droplet/rehearse.sh` boots the release kernel on that machine against a copy
of real data and compares it with Linux, page by page.
[`docs/probes.md`](docs/probes.md) says what each test kernel checks.

**Booting another application's kernel to try it:**
`shale repos:zig-metal-unikernel/tools/boot_app.shale elf=<kernel> work=<folder>
port=<N> site=<folders>` (its header): a GPT disk with a FAT16 partition, the
site folders laid on it, and QEMU's microvm as a job that outlives the run,
its serial in `<work>/serial.log`; the disk is kept for the next boot. As a
droplet boots it: lay it on a disk image with
`droplet/app_image.py <kernel.elf> <site-dir> <conf> <out.img>` (its
docstring), then `DISK=<out.img> PUBLIC_FWD=8080 droplet/droplet.sh` and
browse `localhost:8080`. The conf is `zig-metal-unikernel.conf`'s lines
(`probe/config.zig`): an empty file serves on the public card with no
volume; `card = private` wants `PRIVATE_FWD`. dog-park's
`tools/metal_gate.mjs` instead boots its kernel straight under QEMU's
microvm (`-kernel`), as `probe/run.sh` boots the probes.

### The checks, fastest to slowest

A **judge** is a script that runs the kernel and the Linux build side by side
and compares them. A **gate** is a script whose exit code is a verdict (0
passes) and whose last line names what failed. A **simulator** drives one
pure part of the kernel (the TCP table, the FAT, the cache, the store) on
Linux, with no devices, over many random seeds; a seed that fails replays
exactly.

**The checks come in tiers** (`tier0.sh` to `tier3.sh`). Each tier adds
exactly one kind of dependency to the one before, and each says, when it
starts, anything it needs that is missing. Tier 0 also lists what it did not
check and which tier does. `./gates.sh` runs the four tiers in order,
cheapest first, and stops at the first one that fails.

| tier | install | what it proves | about |
|---|---|---|---|
| `./tier0.sh` | zig 0.17, Python 3, and the SDK beside this checkout | the unit tests and short simulator runs; this repo's kernels and host programs type-check; `zig fmt` and the lints; tcp_sim's golden traces. No QEMU, no other repo, no network, no root. Run it on every change | ~2-3 min |
| `./tier1.sh` | + QEMU, dosfstools, gdisk, mtools, curl, binutils, `sudo -n` for loop mounts and the TAP device; KVM for the droplet boots (or `ACCEL=tcg`) | tcp.zig against Linux's own TCP, as server and as client (the native judge, quick, ~25 s, first); each test kernel ("probe") boots and works on virtual hardware; the judges' own tests; the droplet's boot loader and image; the sleeper sleeping on a real timer, woken by its timer and by a request (`droplet/sleeps.py`, KVM) | ~25 s native, ~45 s of probes, then the droplet boots, ~10 s of sleeps |
| `./tier2.sh` | + metal-vmm beside this checkout, and /dev/kvm | metal-vmm runs this checkout's probe kernels the same as QEMU does, and the same twice | minutes |
| `./tier3.sh` | + zig-webbox, shale, cobble-webbox and angry-gopher beside this checkout | the library's tests and the limits it copies; the unit tests' pinned body rule is still the library's; gopher.elf type-checks, builds and is judged against its Linux build on QEMU's microvm and the droplet-shaped machine; the PC-shaped machine's rests and the timeouts on metal-vmm; a sleeping kernel in the machine's own time (metal-vmm `sleeps.sh`: an idle gopher.elf's cost, the sleeper's hour of wakes, the longest rest) | ~20 min |
| `zig build properties` | as tier 0 | the simulators over many seeds, judged by their coverage properties: zig alone, but not in tier 0 for its time (20 min in Debug, 5 with `-Dsweep-optimize=ReleaseSafe`); long.sh runs it at its `SEEDS`, `CROWD_SEEDS` and `FAT_SEEDS` (the top of `long.sh` says how each was chosen) | 5-20 min |
| `zig build tcp-traces` | as tier 0 (it runs it) | tcp_sim's golden traces: the hash of every frame for every world (seeds 1-200 of each peer, and the regressions; a line each in `coverage/tcp-traces.txt`), against that file, so reshaping tcp.zig leaves the wire as it was; `-Dtcp-traces-write` writes them again, and the commit says why (metal-vmm QUEUE 225) | ~25 s, built |
| `./gates.sh quick` | as tier 3 | tiers 0 and 1, then gopher.elf and one chat-judge story | |
| `./gates.sh` | as tier 3 | tiers 0 to 3, for a batch | |
| `./long.sh` | as tier 3 | before every release: the simulators at `long.sh`'s `SEEDS`; the FAT16 judge; the native judge whole, its loss check included; the real kernel on metal-vmm losing a sample of the packets it sends in turn, facing a misbehaving client, and under 100 seeded fault schedules over the network and disks, every run still serving the right page | longest |

**Starting cold:** `./tier0.sh` on every change; `./gates.sh quick`
where QEMU, KVM and the siblings are. A developer can defer every test
against angry-gopher (tier 3) and still have reasonable confidence in a
change that tier 0 passes.

**Skipping a slow step:** `SKIP="tcp-traces probes" ./gates.sh` (any tier,
`gates.sh` or `long.sh`; the words are in `tools/skip_lib.sh`). It is built
against the false pass: a word that names no step stops the run before it
starts, each skipped step prints `SKIPPED <name>: NOT RUN`, the last line
says `NOT A PASS: every step that ran passed; NOT RUN: …`, the exit code
is 3, never 0, and no verdict is kept. A half of `long.sh`, or a knob below
its full size, ends the same way. `JUDGE_QUICK` or `JUDGE_ONLY` left set
stops a gate before it starts: they narrow a judge silently. To run one probe or one chat-judge gate, `probe/run.sh` takes words
too.

Each script's header says what it runs and why. `./release-check.sh <dir>`
runs the two in order, the long tier only after the gates pass, detached,
with their logs and a summary in `<dir>`. The coverage properties and
the floors a long run must reach are in [`COVERAGE.md`](COVERAGE.md).

**A verdict is for exact code.** A full `./gates.sh` and a whole `./long.sh`
each record their verdict against what they judged: this repo's commit, the
SDK's, and a hash of every application and library file the kernel compiles
(`tools/verdicts.py` calls that hash the **content id**). The quick tier and a
partial `long.sh` record nothing.

### Deploying

**[`DEPLOY.md`](DEPLOY.md) is how we operate both sites**: the machines,
where the secrets live, a release step by step (the checks, the image, the
owner's steps, the tag), the way back, Shale scripts and a new site's key,
prod's Caddy, Dog Park, and running your own copies.

[`CUTOVER.md`](CUTOVER.md) is the dated record of the move from Linux on
2026-10-04, and the tools it used.
`droplet/new_volume.py` builds a new, empty data volume.

## Where it stands

**What serves is always a tag, never a branch, and this README does not
name it**, since a number written here goes stale with the next release.
To find it:

- the newest release: `git tag -l 'v*' --sort=-v:refname | head -1`, and
  its note, `git show <tag> --no-patch` (the date, the image's checksum,
  the commits it was built from, what is new);
- what lynrummy.com actually runs: `curl -s https://lynrummy.com/version`
  names angry-gopher's commit; `/admin/host` (the admin's key, DEPLOY.md)
  names this repo's; `git tag --points-at <commit>` turns either into a tag;
- the way back is the tag before it. `master` may be ahead of the serving
  tag: `git log <tag>..master` is what has not shipped.

- **served**: in the serving tag, on lynrummy.com.
- **master**: on `master`, newer than the serving tag, not served yet.
- **test only**: exists for the checks, never deployed.
- **unmeasured**: built, but the number a reader would want has not been taken.

| | state | |
|---|---|---|
| booting a droplet | served | own BIOS boot loader, from a GPT disk; also tested on the droplet-shaped QEMU, on dirty memory |
| booting under QEMU and metal-vmm | test only | PVH entry, QEMU's `microvm` and `pc` machines, metal-vmm |
| the screen | served | everything the log says also goes to VGA text, which DigitalOcean's console shows |
| interrupts, and resting when idle | served | on the PCI machine a droplet is, the card wakes it (MSI-X), else a 1 ms timer. On the MMIO test machines it polls instead |
| virtio network, disk and SCSI volume drivers | served | over PCI on the droplet; over MMIO in tests |
| DHCP, ARP, TCP | served | up to 256 connections; the peer's window and segment size respected, lost segments resent (the oldest first, RFC 6298 5.4), silent peers given up on; segments that arrive ahead of a gap are held (up to four pieces a connection). Each place it departs from the RFCs says why, in `DEPARTS (reason):` lines |
| sleeping until the application's wake | master | a machine with nothing in motion halts until its application's `between` asks for a turn, or at most `longest_rest_ms` (10 s by default); a busy one keeps the 1 ms slice. Judged by `droplet/sleeps.py` (tier 1, a real timer) and metal-vmm's `sleeps.sh` (tier 3) on the sleeper (`probe/sleeper/`). [HOST.md](HOST.md), "Between handlers"; [DESIGN-sleep.md](docs/designs/DESIGN-sleep.md) |
| an application's fetch | master | one GET at a time through webbox's `host_fetch`, on the machine's own network only, in a connection slot kept for it; called by no served application yet ([HOST.md](HOST.md), "the host's fetch") |
| a TCP client: connect, ARP requests, one HTTP fetch | test only | `probe/fetch.elf` is the client kernel, judged against Linux (`native/judge_native.py`) and against this kernel's server on metal-vmm's pair mode (metal-vmm `pair.sh`, tier 3) |
| HTTP | served | `std.http.Server`, unmodified |
| FAT16 and FAT32, read and write | served | long names, folders, append, replace, delete; checked by `fsck` and by Linux reading what it wrote. Production's volume is FAT32 |
| clocks and entropy | served | the CMOS real-time clock; the TSC's rate measured against the PIT; random bytes from virtio-rng where the machine has one, and RDRAND |
| angry-gopher's whole site | served | every route, judged equal to the Linux build, including chat's live streams and uploads |
| a combination's applications as `parts` | master | built by dog-park's `metal-dogpark-todo` (Dog Park with roc-webbox's TODO list); deployed nowhere |
| another repository's application as a kernel | served | Dog Park, on dogpark.lynrummy.com since 2026-10-16, built through `addAppKernel` and `droplet/app_image.py` (dog-park's DEPLOY.md says which image serves); one disk, no volume. This repo neither builds nor judges any application but angry-gopher (an application is not this repo's test of itself); Dog Park's own QEMU gate and droplet rehearsal check its image |
| file contents kept in memory | served | after their first read, write-through (`page_cache_mib`, 64 MiB by default) |
| large disk requests | served | a run of contiguous clusters is one request of up to 1 MiB (the least of the disk's, the controller's and our own limit) |
| the FAT written a sector at a time | served | disk requests for a 1.8 MB, 10 MB and 100 MB upload: 59, 26 and 115, from 93, 218 and 2,017 before it (measured once, when it shipped) |
| the FAT's two copies weighed at mount | served | if they differ, the cleaner copy wins and the other is rewritten from it |
| a mount whose FAT copies cannot be weighed | served | refuses writes until a weighing succeeds (a 503 with Retry-After) |
| an overwrite read back before the old copy is freed | served | |
| a disk check at every boot | served | both disks; a damaged disk is reported and still served |
| a disk check in idle time | served | after 200 ms with nothing arriving, the kernel checks the volume a slice at a time ([HOST.md](HOST.md), "Idle time"). Its cost on production's full volume: unmeasured here |
| exact accounting of what a failed write leaves | served | leaked clusters, orphaned name entries and long chains, counted on `/admin/host` |
| restarting after a crash | served | on by default, a droplet's reset having been measured to restart it; the last boot's log is kept across the restart, and a disk that stops answering restarts it too ([RESTART.md](RESTART.md)) |
| the log, on `/admin/host` and `/admin/log` | served | a 1.25 MiB ring, secrets removed as they are written; every request line with its time, status and duration; `/admin/host` shows the newest lines, `/admin/log` all of it as plain text for scripts; recent uploads and request counts ([docs/admin-for-agents.md](docs/admin-for-agents.md)) |
| `/admin/backup` | served | the whole data set as one tar, checked by `droplet/check_backup.py`; taken by hand with `droplet/backup.sh`; no routine schedule ([DEPLOY.md](DEPLOY.md), "Backups") |
| speed against Linux | unmeasured | last measured 2026-10-01 on v4, before the caches ([docs/port.md](docs/port.md)) |

## Where things are

| where | what |
|---|---|
| `src/` | the kernel: boot, drivers, network, FAT, the `Io` the application calls (`io.zig`; where a path's bytes are, `io_volumes.zig`), the simulators (`*_sim.zig`) and `properties.zig` |
| `src/host_io_metal.zig` | the one file that hands the application this kernel's `Io` |
| `probe/gopher.zig` | the kernel around an application: one loop (`kmain`) and one connection served (`serveOne`); beside it, `probe/config.zig` (the volume's config file), `probe/volumes.zig` (the disks found, mounted and checked), `probe/host_facts.zig` (`/admin/host`'s kernel half) and `probe/stream_turn.zig` (the live streams' turn between requests) |
| `probe/*.zig` | small test kernels, one subsystem each |
| `probe/sleeper/` | the sleeper, a tiny application that only wakes: the test of a sleeping kernel |
| `probe/run.sh`, `probe/judge_*.py` | booting them under QEMU, and the judges |
| `native/` | tcp.zig as a Linux program, judged against Linux's own TCP (`judge_native.py`) |
| `droplet/` | the boot loader, the image builder, the droplet-shaped QEMU, and the release, backup and cutover tools |
| `tools/` | `verdicts.py` (which code a gate judged, and the release rule), `skip_lib.sh` and `tier_lib.sh` (the tiers' shared parts), the lints, the mutation runners (`mutate_*.py`), `fat16_read.py` (a FAT reader that is not ours) |
| `coverage/` | the coverage floors `long.sh` holds runs to, and tcp_sim's golden traces |
| `docs/rfc/` | the RFCs tcp.zig quotes, verbatim ([its README](docs/rfc/README.md)) |
| `tier0.sh` … `tier3.sh`, `gates.sh`, `long.sh`, `release-check.sh` | the checks, each header saying what it runs |

## Documents

**Contracts:**
- [`HOST.md`](HOST.md): what Linux and this kernel both promise an
  application (one handler at a time, durability, limits, idle time).
- [`STORE.md`](STORE.md): the application's data, its operations and what
  each promises across a crash.

**Design**, in `docs/`:
- [`docs/port.md`](docs/port.md): how the application runs here unchanged,
  `std.http.Server`, one loop, the stack and the memory.
- [`docs/disk.md`](docs/disk.md): why our own FAT, and how it is judged.
- [`docs/tcp.md`](docs/tcp.md): the network loop, live streams, and what
  the TCP does not do.
- [`docs/probes.md`](docs/probes.md): the test kernels, and QEMU's traps.
- [`docs/admin-for-agents.md`](docs/admin-for-agents.md): reading
  `/admin/host` and `/admin/log`.
- [`docs/rfc/`](docs/rfc/README.md): the RFCs tcp.zig follows.
- [`docs/designs/`](docs/designs/README.md) and
  [`docs/reviews/`](docs/reviews/README.md): notes and adversarial reviews
  of particular changes.
- [`FAT32.md`](FAT32.md), [`RESTART.md`](RESTART.md),
  [`TCP_TESTING.md`](TCP_TESTING.md), [`COVERAGE.md`](COVERAGE.md),
  [`MUTATION.md`](MUTATION.md) (which deliberately planted bugs the tests
  catch), [`HEAD-PARSER-BUG.md`](HEAD-PARSER-BUG.md) (zig's head parser and
  a bare-LF head end), [`GROWTH-game-store.md`](GROWTH-game-store.md) (the
  game store's disk growth).

**Operations:** [`DEPLOY.md`](DEPLOY.md) (releases, backups, the way
back), [`CUTOVER.md`](CUTOVER.md) (the dated record of the move from
Linux), [`MIGRATION.md`](MIGRATION.md),
[`droplet/RESTART-TEST.md`](droplet/RESTART-TEST.md) (the console test that
turned the restart on),
[`SECRET-LEAK.md`](SECRET-LEAK.md),
[`ADMIN-PASSWORD-LOST.md`](ADMIN-PASSWORD-LOST.md).

## Working on it

The work is done by Claude, on Steve's development machine and in Claude Code
cloud sessions, with Steve. [`CLAUDE.md`](CLAUDE.md) says who does what.

- **`master`** has everything. **`vN`** tags are releases; the newest
  serves. **`claude/*`** branches are cloud sessions' work, merged by the
  development machine; nobody else pushes `master` or a tag.
- **Live work** is in metal-vmm's
  [`QUEUE.md`](https://github.com/showell/metal-vmm/blob/master/QUEUE.md).
  Code comments and commits cite its items as "metal-vmm QUEUE N". A bare
  "QUEUE.md item N" means this repo's old queue, now retired
  (`git show 3cd662c:QUEUE.md`), whose numbers overlap.
