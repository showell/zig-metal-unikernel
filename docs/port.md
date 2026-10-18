# The port: one file swapped, std's HTTP, one loop

How angry-gopher's server runs on a machine with no operating system, and
why the seam is where it is. The README is the orientation; this page is the
design behind its "What it is".

## `std.http.Server`, unmodified

`zig-server` builds its HTTP server like this, and so does `probe/stdhttp.zig`:

```zig
var server = std.http.Server.init(s.reader(), s.writer());
const req = try server.receiveHead();
try req.respond(body, .{});
```

A reader and a writer, and nothing else. So a TCP connection that can present
those two interfaces gets zig's entire HTTP/1.1 implementation for free — not
ported, not vendored, not adapted, the same code from the same standard
library, on a machine with no operating system:

```
zig-metal-unikernel std.http probe
  address: 10.0.2.15
  listening on port 80, with zig's own HTTP
  connected
  method: GET  target: /probe
  responded
```

`src/stream.zig` is what makes that true, and its core is small, because
each interface needs exactly one function: a reader needs `stream`, a
writer needs `drain`, and everything else in both vtables has a default.

**A read there runs the event loop.** With one core and no preemption there is
nobody else to move the connection forward, so a read with no bytes yet polls
the NIC, answers ARP, feeds TCP and tries again. That is what "blocking" means
when there are no threads to block. Where the card can interrupt (on the PCI
bus: a droplet, the droplet-shaped QEMU, and metal-vmm's `TRANSPORT=pci`
machine), a try that found nothing halts until a frame or the 1 ms timer
(`src/interrupts.zig`); on virtio-mmio (QEMU's microvm, metal-vmm's default
machine) it spins.

## The real server

`build.zig` compiles angry-gopher's `zig-server/src/*.zig` from its checkout
(`-Dgopher-root`, `../angry-gopher` by default) and the webbox library's
`src/*.zig` from zig-webbox's (`-Dwebbox-root`, `../zig-webbox`), and
Shale's from shale's (`-Dshale-root`, `../shale`), unchanged and uncopied (Phase B step 2b, 2026-10-13). Every file that does I/O opens with
`const Io = @import("host_io").Io;`, and this build hands them
`src/host_io_metal.zig` as `host_io`. A file that aliases std's `Io` instead
is refused by the build's check. What the application serves besides its code
is its `zig-server/assets.zon` (Phase B step 3): `.embedded`, the front-end
artifacts the build compiles in by name, read by this build as by its own; and
`.site`, the directories its routes read at request time (pages/, gallery/),
laid whole onto the site disk by `droplet/chat.py` and the judge.
A gate names angry-gopher by the content id of what it serves, and keeps no
verdict if that changed during the run (`tools/verdicts.py`).

`probe/gopher.zig` is a HOST in the sense webbox's `site.zig` defines, taking
the application as the `app` module (`app.site`, `app.hosting`) and the
library as `webbox` — the contract any host meets before calling the route
table:

    mem_meter.init(base)        base: std's general-purpose allocator, on this
                                machine's pages
    roots.point(base, …)        data/ and auth/: on the DigitalOcean volume
                                when one is attached, else the boot disk
    a Bus over base
    an arena per request

— with the site on a GPT disk whose first partition is FAT16 or FAT32, and
clocks from its own hardware. Then it calls `app.site.route`: the application's
real dispatch, every page — a table of up to 256 connections (one kept for
the machine's own fetch), one request
served at a time, each request with its own heap that is reset afterwards.
`zig-metal-unikernel.conf` on the boot disk says how many requests to serve
(`requests = N`); without it, forever. A request that fails is logged and
survived, as it is on Linux.

**It is judged against Linux.** `probe/judge_gopher.py` sends each request to
this kernel and to the ordinary Linux build of the same source over the same
files, each case starting from the same state on both sides. Status, Location,
Set-Cookie, Content-Type and body must match; files a request writes are read
back through mtools (or Linux's vfat driver, with `JUDGE_MOUNT=1`) and must
match too; and a Unix time is only forgiven if it falls inside the window in
which that side handled the request.

```
ok    15 single requests to one boot, each answered as Linux answered
ok    the member story: 40 requests to ONE boot — login, chat, topics, reactions, admin, logout — each answered as Linux answered, all 27 files agree; …
ok    the Lyn Rummy story: 17 requests to ONE boot — a name, a game and its moves, a puzzle and its moves, both reloaded, the roster — each answered as Linux answered, all 26 files agree
answered as Linux answered: cases members uids caps lynrummy streams-linux streams-metal budget churn bulk uploads slow lagging concurrent timeouts damaged (152 s)
```

(the quick tier under TCG, 2026-10-02; the judge has gained gates since, and
`probe/run.sh gopher <a name it does not know>` lists them all.)

**The single requests:** the index read off the volume, the résumé and its
27 KB PDF, both admin screens refusing a stranger, the name page, the player
store, a staged game session rendered in Eastern time, new game and puzzle
sessions stamped with the wall clock, a move appended to an action log, a new
player's counter and row.

**The stories** are one visitor's afternoon each, told to one kernel and one
Linux server — a member's chat, a player's cookies, the game store's caps, a
Lyn Rummy game and its puzzles — the member's with garbage on the wire in
the middle that must not stop it; afterwards the whole data tree is
compared. **Stamina** is 300 requests to one boot: every answer must equal
the first answer to the same request, the base heap must not grow, and each
request must use the same amount of its own heap every round.

## The seam we first got wrong

`std.Io` looks like an interface. It is not one.

In zig 0.16 it has **117 function pointers and no defaults**. Its handles are
literally `std.posix.fd_t`. And `std.Io.Dir.cwd()` reaches for
`std.posix.AT.FDCWD`, which does not exist on a freestanding target — so it
does not merely fail to work there, **it fails to compile**, whatever vtable
you supply. `std.Io` is a portable spelling of the POSIX syscalls, not an
abstraction over storage. The one implementation zig ships, `Io.Threaded`, is
18,902 lines.

The real seam is one line higher, and the application hands it over. Its
filesystem calls are spelled `Io.Dir.cwd().something(io, ...)` (54 of them
at angry-gopher `7e3fbc5e`), and every file that uses them opens with the
same line:

```zig
const Io = @import("host_io").Io;   // std's on Linux; src/io.zig here
```

The build points `host_io` at `src/host_io_metal.zig`, and **not one call
site changes, and no line is edited**. That is the port: one file swapped by
the build, and a `Dir` answering the operations the application actually
asks for.

```
zig-metal-unikernel std.Io probe
  readFileAlloc("HELLO.TXT") -> 12 bytes: Hello, disk!
  statFile -> 12 bytes, kind file
  clock advanced 1008639 ns over a spin
  iterate -> HELLO.TXT
  mutex: locked and unlocked twice, no contention possible
```

**Note what this does not change.** `std.http.Server` still runs unmodified,
because `std.Io.Reader` and `std.Io.Writer` are genuine interfaces — one
required method each, defaults for the rest, no POSIX anywhere in their types.
Two designs in one standard library, and only one of them is a seam.

## No threads, and no wish for any

A large share of those 117 entries are the concurrency family: async,
concurrent, await, cancel, four more for groups, three futex operations,
batching, and cancellation plumbing through everything else. None of it
applies. One core, no preemption, one request served at a time — so "run
this concurrently" becomes "run this now", which loses no overlap a single
core ever had. The application is already built for it: its accept loop is
single-threaded by its own comment, and it already serves inline when its
task pool is exhausted.

**The application's mutexes are free — and they say so out loud.** The
temptation is to delete the calls; that is worse than keeping them. Each lock
marks a critical section somebody identified, and chat's live streams bring
concurrency back — not as threads, but as several connections interleaved in
one event loop — which is exactly when those sections matter. Deleting the
calls throws away the map and keeps the territory.

So the lock is free but not silent: it records that it is held, and a second
lock without an unlock is real re-entrancy that would deadlock on a threaded
host. It cannot happen here — so if it does, the assumption this design rests
on is wrong, and the machine says so rather than carrying on.

**And the compiler is told, because it does not assume it.** A freestanding
target is *not* single-threaded by default, so std kept the threaded
lowerings — real atomic instructions, thread-local storage — for a machine
with one core, no preemption and no scheduler. Every kernel here builds with
`single_threaded = true`, and `probe/gopher.zig` refuses to compile if that
ever stops being so: the stubs above are only honest under it. Nothing named
`std.Thread` appears in `src/`, in the ported application, or in the linked
ELF. The task pool that serves requests on Linux lives in `server.zig`, which
is a host — and this machine has its own.

## The stack is 16 MB, and its depth is measured

The same route table on Linux runs on a thread from `std.Thread`'s pool, which
gets `SpawnConfig.default_stack_size` — 16 MB. The kernel first ran on 64 KB,
and `/chat/recent` went deeper than that: the machine triple-faulted, which is
a reset with nothing in the log, because a fault handler needs a stack too and
there was none left.

So `src/stack.zig` declares the region at exactly std's own number, in `.bss`
so the 16 MB is a program header rather than 16 MB of zeros in the kernel
image. **The boot stub paints the whole thing with 0xA5A5A5A5A5A5A5A5 before
it points `%rsp` at it** — `rep stosq` over memory nothing is running on yet.
Afterwards the lowest word that is no longer painted is the high-water mark:
everything below it has never been written by any call this boot. That is the
real depth of the real route table on real requests, not an estimate. The
serial log says it the first time each new depth is reached, so a request
that goes deeper than every request before it is one line and a request that
does not is silent.

The bottom 64 KB is a guard, and writing it stops the machine. Past the end
of the stack is `.bss` — the heaps, the virtqueues, the volume's sector
buffer — so a frame that runs off the end would corrupt whatever it lands on
and the machine would carry on lying. One blind spot, stated: a stack word
that legitimately holds the paint value reads as untouched, so the mark can
only come out shallower than the truth, never deeper.

## The memory seam: the kernel owns RAM, std does the rest

A fixed array in `.bss` handed to a `FixedBufferAllocator` is a bump
allocator: `free` reclaims only the block it handed out last, so under any
other order the memory is gone for the life of the boot. A server that cannot
reuse what it frees has a clock on it, however little it leaks. That is how
every heap here began; the long-lived ones are now std's allocator on the
machine's pages, below.

**The seam is the one zig already documents.** `std.heap.page_allocator` is
defined as `root.os.heap.page_allocator` when the root file declares one:

```zig
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = metal.pages.allocator;
    };
};
```

That is the whole arrangement. From there, `std.heap.DebugAllocator` — std's
own general-purpose allocator, with its size-class buckets and its reuse —
runs unchanged on this machine's RAM. It is exactly what Linux does: there
`page_allocator` is `mmap` and the allocator above it is std's either way.
What a kernel has to supply is what Linux supplies, and no more.

So `src/pages.zig` is a page allocator and nothing else: a bitmap, one bit per
4 KB page, living in the front of the region it describes, so the size of the
heap is the size of the machine rather than a constant. A page's length is not
recorded anywhere — `std.mem.Allocator` hands `free` the same slice it was
given. Freeing a page twice, or a pointer that never came from here, panics:
the alternative is two owners of the same memory, and whichever writes second
wins.

**The machine knows how much RAM it has.** The PVH loader hands over a memory
map in `%ebx`; `src/pvh.zig` reads it — checking the magic, the version and
every region — and the linker marks `_kernel_start`/`_kernel_end` so the
kernel's own image is cut out of what gets handed around. QEMU is the judge,
because it knows what it was told:

```
     memory | -m 512: found 536472576 bytes, 389 KB of it the firmware's
     memory | -m 256: found 268037120 bytes, 389 KB of it the firmware's
     memory | -m 128: found 133819392 bytes, 389 KB of it the firmware's
```

**The question that decides deployability is whether the peak stops rising.**
Live bytes can sit flat forever while a bump allocator's consumption climbs,
so the machine reports both after every request, and `probe/memory.zig` puts
sixty rounds of a server's shape — allocate three hundred, free three hundred
at random — through std's allocator on these pages:

```
  every one of the 126703 pages taken and given back, twice
  churn: 18000 allocations, peak 1064960 bytes after 10 rounds, 1101824 after 60
  the heap is empty again, and std's allocator finds no leak
```

The same arrangement is checked on the host, where a heap-allocated buffer
stands in for the machine's RAM, against std's own four allocator conformance
suites — `testAllocator`, `testAllocatorAligned`,
`testAllocatorLargeAlignment` and `testAllocatorAlignedShrink`. Those found
two bugs in the first version: a search that gave up before it had covered
the bitmap and reported a nearly empty heap as full, and an over-page
alignment checked against page indices rather than addresses, which failed
every 64 KB-aligned request on a region that did not happen to start on that
boundary.

## Speed against Linux, as last measured

How fast, measured before the cutover (the same pages from both sites,
alternating, 40 rounds; first byte, median / 90th percentile; 2026-10-01, v4:
interrupts and the idle halt):

| | lynrummy.com | metal, through Caddy | Linux alone, on prod | metal alone, from prod |
|---|---|---|---|---|
| home page | 2.95 / 3.55 ms | 4.14 / 7.53 ms | 0.55 / 0.63 ms | 1.27 / 2.37 ms |
| a gallery picture | 2.72 / 3.31 ms | 4.12 / 5.27 ms | 0.28 / 0.38 ms | 1.23 / 1.66 ms |
| /delivery | 2.56 / 2.96 ms | 2.77 / 3.40 ms | 0.20 / 0.30 ms | 0.31 / 0.50 ms |
| /game (a redirect) | 2.52 / 3.20 ms | 2.75 / 3.43 ms | 0.23 / 0.29 ms | 0.30 / 0.50 ms |

Pages that need no file were within about 0.1 ms of Linux, at the median and
in the slow tenth. Pages read from files were about 1 ms slower. That run
predates the page cache (`src/page_cache.zig`) and the site cache
(`io.zig`'s `SiteCache`), which keep files in memory after their first read;
it has not been repeated since, so whether the gap remains is not measured.
One run, on one evening: DigitalOcean's neighbours vary.

## The files

The README's "Where things are" is the map of the repo; each file's header
says what it holds.

## What lives elsewhere

The Roc side of this work stays in
[`roc-apps/floor`](https://github.com/showell/roc-apps): the platform whose
doors Roc programs call, the FAT16 that runs on it, and the fault modes. That
floor and this repo are two implementations of the same device set, which is
why the drivers here are written against the same doors.

The plan this all started from is
[angry-gopher without Linux](https://github.com/showell/essay-repl-server/blob/master/notes/angry-gopher-without-linux.md), and the move
to a DigitalOcean droplet is
[gopher chat on a droplet](https://github.com/showell/essay-repl-server/blob/master/notes/gopher-chat-on-a-droplet.md).
