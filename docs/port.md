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
those two interfaces gets zig's entire HTTP/1.1 implementation — not ported,
not vendored, the same code from the same standard library.
`src/stream.zig` is what makes that true, and its core is small: a reader
needs `stream`, a writer needs `drain`, and everything else in both vtables
has a default.

**A read there runs the event loop.** With one core and no preemption there is
nobody else to move the connection forward, so a read with no bytes yet polls
the NIC, answers ARP, feeds TCP and tries again. That is what "blocking" means
when there are no threads to block. Where the card can interrupt (on the PCI
bus: a droplet, the droplet-shaped QEMU, and metal-vmm's `TRANSPORT=pci`
machine), a try that found nothing halts until a frame or the timer
(`interrupts.slice_ns`, `src/interrupts.zig`); on virtio-mmio (QEMU's microvm,
metal-vmm's default machine) it spins.

## The real server

`build.zig` compiles, unchanged and uncopied, angry-gopher's
`zig-server/src/*.zig` from its checkout (`-Dgopher-root`, `../angry-gopher`
by default), the webbox library from zig-webbox's (`-Dwebbox-root`,
`../zig-webbox`), and Shale from shale's (`-Dshale-root`, `../shale`).
Every file that does I/O opens with
`const Io = @import("host_io").Io;`, and this build hands them
`src/host_io_metal.zig` as `host_io`; angry-gopher's
`tools/lint_portable.shale` refuses a file in the route table's reach that
takes std's `Io` instead. What the application serves besides its code is
its `zig-server/assets.zon`: `.embedded`, the front-end artifacts the build
compiles in by name; and `.site`, the directories its routes read at request
time (pages/, gallery/), laid whole onto the site disk by `droplet/chat.py`
and the judge. A gate names the applications by the content id of what they
serve, and keeps no verdict if that changed during the run
(`tools/verdicts.py`).

`probe/gopher.zig` is a HOST in the sense webbox's `site.zig` defines, taking
the application as the `app` module (`app.site`, `app.hosting`) and the
library as `webbox`, and meeting the contract any host meets before calling
`app.site.route`: `mem_meter` over std's allocator on this machine's pages,
the data roots (data/ and auth/: on the DigitalOcean volume when one is
attached, else the boot disk), a Bus, an arena per request. The site is on a
GPT disk whose data partition is FAT16 or FAT32, and the clocks are its own
hardware's. One request is served at a time, each with its own heap that is
reset afterwards, from a table of `max_connections` (one kept for the
machine's own fetch). A request that fails is logged and survived, as it is
on Linux.

**It is judged against Linux.** `probe/judge_gopher.py` sends each request to
this kernel and to the ordinary Linux build of the same source over the same
files, each case starting from the same state on both sides. Status, Location,
Set-Cookie, Content-Type and body must match; files a request writes are read
back through mtools (or Linux's vfat driver, with `JUDGE_MOUNT=1`) and must
match too; and a Unix time is only forgiven if it falls inside the window in
which that side handled the request. The gates are the judge's `GATES`
(`probe/run.sh gopher <a name it does not know>` lists them): single
requests, then **stories**, one visitor's afternoon each told to one kernel
and one Linux server (a member's chat with garbage on the wire in the
middle, a player's cookies, the game store's caps, a Lyn Rummy game and its
puzzles), with the whole data tree compared afterwards; and **stamina**, 300
requests to one boot, every answer equal to the first answer to the same
request, the base heap not growing, each request using the same amount of
its own heap every round.

## The seam is `host_io`, not `std.Io`

`std.Io` looks like an interface and is not one: a vtable of over a hundred
function pointers with no defaults, handles that are `std.posix.fd_t`, and
`Io.Dir.cwd()` reaching for `std.posix.AT.FDCWD`. It is a portable spelling
of the POSIX syscalls, not an abstraction over storage. The real seam is one
line higher, the `host_io` import above: the build points it at
`src/host_io_metal.zig` (this machine's `src/io.zig`), and no call site
changes. `src/io.zig`'s header says why. `std.Io.Reader` and `std.Io.Writer`
are genuine interfaces, one required method each, which is why
`std.http.Server` runs unmodified.

## No threads, and no wish for any

Much of `std.Io`'s vtable is the concurrency family: async, concurrent,
await, cancel, groups, futexes. None of it applies. One core, no
preemption, one request served at a time — so "run this concurrently"
becomes "run this now", which loses no overlap a single core ever had.

**The application's mutexes are free, and loud.** Each lock marks a critical
section somebody identified, and chat's live streams interleave several
connections in one event loop, which is when those sections matter; so the
calls are kept. The lock records that it is held, and a second lock without
an unlock — re-entrancy that would deadlock on a threaded host — stops the
machine, since the assumption this design rests on is then wrong.

**And the compiler is told.** A freestanding target is *not* single-threaded
by default, so std would keep real atomics and thread-local storage. Every
kernel builds with `single_threaded = true`, and `probe/gopher.zig` refuses
to compile if that ever stops being so: the stubs are only honest under it.
Nothing named `std.Thread` appears in `src/` or the ported application's
route table; the task pool that serves requests on Linux is that host's.

## The stack is 16 MB, and its depth is measured

The same route table on Linux runs on a thread from `std.Thread`'s pool, with
`SpawnConfig.default_stack_size`, 16 MB, and a deeper stack than this
machine has triple-faults it: a reset with nothing in the log. So
`src/stack.zig` declares exactly std's number, in `.bss`. The boot stub
paints it before it points `%rsp` at it, so the lowest word no longer painted
is the real high-water mark, and the serial log says it each time a new
depth is reached. The bottom 64 KB is a guard, and writing it stops the
machine, because past it is `.bss` and the corruption would be silent.
`src/stack.zig`'s header has the details and the one blind spot.

## The memory seam: the kernel owns RAM, std does the rest

**The seam is the one zig already documents.** `std.heap.page_allocator` is
`root.os.heap.page_allocator` when the root file declares one:

```zig
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = metal.pages.allocator;
    };
};
```

From there `std.heap.DebugAllocator`, std's general-purpose allocator, runs
unchanged on this machine's RAM, as on Linux it runs over `mmap`. So
`src/pages.zig` is a page allocator and nothing else: a bitmap, one bit per
4 KB page, at the front of the region it describes, so the heap is the size
of the machine. Freeing a page twice, or a pointer that never came from
here, panics. `src/pvh.zig` reads the PVH memory map the loader hands over,
and the linker's `_kernel_start`/`_kernel_end` cut the kernel's own image out
of it; the `memory` probe checks the total against QEMU's `-m`.

**The question that decides deployability is whether the peak stops rising.**
Live bytes can sit flat forever while consumption climbs, so the machine
reports both after every request, and `probe/memory.zig` puts rounds of a
server's shape (allocate three hundred, free three hundred at random) through
std's allocator on these pages. On the host, `src/pages.zig` is held to
std's four allocator conformance suites.

## Speed against Linux

Last measured before the page cache and the site cache existed: pages that
need no file were within about 0.1 ms of Linux, and pages read from files
about 1 ms slower. It has not been measured since.

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
