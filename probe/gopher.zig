//! **THE REAL SERVER.** Not a probe that imitates it — `angry-gopher`'s own
//! ROUTE TABLE, compiled from its own source, serving real requests on a machine
//! with no operating system, with its data on a FAT16 or FAT32 volume.
//!
//! Nothing is done to the application: its files take their `Io` from
//! `host_io`, which this build hands this machine's (src/host_io_metal.zig).
//! Not one call site moves, and `std.http.Server` is the one the application
//! already constructs.
//!
//! **THIS FILE IS A HOST** (webbox's site.zig contract, the application as
//! the `app` module): `mem_meter.init` over its own heap, one
//! `app.site.start` with what this machine supplies (data/ and auth/ on the
//! DigitalOcean volume if one is attached, the floor read off the data's FAT),
//! and per request `app.site.route`, then what the request kept served from
//! a table of held streams, drained every turn.
//!
//! Its clocks come from its own hardware (wallclock.zig).
//!
//! **IT HOLDS MANY CONNECTIONS AND SERVES ONE REQUEST AT A TIME, IN A LOOP**:
//! a connection whose request has arrived is answered start to finish; the
//! rest wait in the table meanwhile, and the network keeps moving for all of
//! them. Each request gets its own heap, reset afterwards, the
//! way server.zig gives each request an arena it frees wholesale. How many
//! requests to serve is host configuration, read from `zig-metal-unikernel.conf` on
//! the boot disk (`requests = N`); without it, forever.
//!
//! **A FAILED REQUEST IS NOT A FAILED MACHINE.** On Linux, an error from the
//! route table is logged and the connection closed; so it is here. A panic
//! still stops the machine, as a crash stops a Linux process.
//!
//! **IT IS JUDGED AGAINST LINUX.** judge_gopher.py sends the same requests to
//! this kernel and to the same application running as an ordinary Linux process
//! over the same files, and requires the same answers.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const scsi = metal.scsi;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;
const tcp = metal.tcp;
const stream = metal.stream;
const gpt = metal.gpt;
const disk_fat = metal.disk_fat;
const stack = metal.stack;
const pages = metal.pages;
const pvh = metal.pvh;
const Io = metal.io;
const ready = metal.ready;
const RequestHeap = metal.request_heap.RequestHeap;
const interrupts = metal.interrupts;
const gm_build = @import("gm_build");
// **NO PLANT IN A RELEASE** (src/plant.zig): a deliberate bug compiles only
// into a -Dcoverage kernel, which no release image is.
comptime {
    if (metal.plant.on != .none and !gm_build.coverage) @compileError("a plant (-Dplant) needs -Dcoverage: no release image may hold one");
}
/// B15 (metal-vmm QUEUE item 78): a `-Dcoverage` build checks the TCP table
/// after every turn of the network (`stream.checkTable`) and the volumes after
/// every request (`checkVolumes`). A production build has neither.
pub const coverage_checks = gm_build.coverage;

/// **THE APPLICATION, AS A HOST TAKES IT** (Phase B step 1): its root as the
/// `app` module, `site` (start, route, the body rule's questions) and
/// `hosting` (what only it can say about itself), and the library it is
/// built on as `webbox`. Nothing else of either is reached from here.
const app = @import("app");
const webbox = @import("webbox");
const config_file = @import("config.zig");
const volumes = @import("volumes.zig");
const bootDisk = volumes.bootDisk;
const boot_read_tries = volumes.boot_read_tries;
const mountFat = volumes.mountFat;
const dataVolume = volumes.dataVolume;
const dataSpace = volumes.dataSpace;
const diskStopped = volumes.diskStopped;
const checkVolumes = volumes.checkVolumes;
const readConfig = config_file.readConfig;
const config_path = config_file.config_path;
const Config = config_file.Config;

// **WHAT AN APPLICATION EXPORTS TO BE HOSTED HERE**, said where it is missed,
// not as an error deep in this file.
comptime {
    for (.{ "site", "hosting" }) |name| {
        if (!@hasDecl(app, name)) @compileError("the application's root exports `" ++ name ++ "` (Phase B: `site`, its webbox Site; `hosting`, what only it can say)");
    }
    for (.{ "data_name", "whole_read_max", "cache_largest_most", "describeStart" }) |name| {
        if (!@hasDecl(app.hosting, name)) @compileError("the application's `hosting` declares `" ++ name ++ "` (probe/gopher.zig names each use)");
    }
}
const edge = webbox.edge;
const Bus = webbox.bus.Bus;
const Hub = webbox.bus.Hub;
const streams = webbox.bus;

comptime {
    _ = metal.boot;
    // **NO THREADS, AND THE COMPILER AGREES.** A freestanding target is
    // single-threaded, so `std.Thread.spawn` is not a thing that compiles here
    // -- which is why the Linux host's task pool is not part of the port, and
    // why every lock, futex and group in the application costs nothing (see
    // src/io.zig). If this ever stops holding, the concurrency stubs there are
    // lies and this must not build.
    if (!@import("builtin").single_threaded) @compileError("this host serves one connection at a time; std.Io's concurrency here is stubbed for a single thread");
}

/// **THE SEAM.** `std.heap.page_allocator` is defined as
/// `root.os.heap.page_allocator` when the root file declares one — zig's own
/// hook for a target that must supply its own. So this one line puts every
/// allocator in std on this machine's RAM, and std's general-purpose allocator
/// below needs nothing passed to it. It is the same arrangement as on Linux,
/// where `page_allocator` is mmap and the allocator above it is std's either
/// way; what this machine has to supply is exactly what Linux supplies.
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = pages.allocator;
    };
};

/// std.heap asks a freestanding target for its page size rather than assuming
/// one. **No stack traces**: this machine has no unwinder and no debug info, and
/// saying so is what keeps std's allocator from reaching for `std.Io.Threaded`
/// to capture a trace of zero frames.
pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
    .allow_stack_tracing = false,
};

/// **THE SITE'S LONG-LIVED HEAP IS std's GENERAL-PURPOSE ALLOCATOR**, over this
/// machine's pages. It used to be a bump allocator over a fixed array, which
/// reclaims a free only when the block being freed was the last one handed out;
/// everything else it handed out was gone for the life of the boot. That is a
/// clock on the machine, whatever leaks or does not.
///
/// `safety` off, because the safety this config buys is use-after-free
/// detection by NOT reusing a freed slot — which is the opposite of what a
/// server needs. The double-free check that matters is still there, one layer
/// down, where pages.zig panics rather than handing the same memory out twice.
var gpa: std.heap.DebugAllocator(.{
    .backing_allocator_zeroes = false,
    .stack_trace_frames = 0,
    .thread_safe = false,
    .safety = false,
    .page_size = pages.page_size,
}) = .{};

pub var blk_mem: virtio.BlockMemory align(4096) = .{};
pub var volume_mem: virtio.BlockMemory align(4096) = .{};
/// The disks, for the per-request log: how many requests they served and how
/// long they took. The boot disk, then the volume if one is attached.
pub var disks: [2]?*virtio.Block = .{ null, null };
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var sector: [disk_fat.sector_size]u8 align(4096) = undefined;
var volume_sector: [disk_fat.sector_size]u8 align(4096) = undefined;
var dhcp_frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;

/// **HOW MANY CONNECTIONS THE MACHINE HOLDS AT ONCE.** A chat tab holds three
/// or four open for as long as it is open, so this is room for about sixty
/// tabs — more than chat has ever had, on purpose. Each connection has its own
/// receive buffer and send queue, taken from the machine's pages at boot:
/// about 20 MB for all of them.
pub const max_connections = 256;
const rx_bytes = 16 * 1024;
comptime {
    // A head the application allows must fit a connection's receive buffer,
    // or ready.zig would wait for one that cannot arrive.
    std.debug.assert(rx_bytes >= webbox.http.head_bytes);
}
/// A send queue holds what the peer has not yet acknowledged. A response
/// larger than this waits for acknowledgements as it goes; a held stream whose
/// next frames do not fit is a client that is not keeping up.
const tx_bytes = 64 * 1024;
var conn_slots: [max_connections]tcp.Conn = undefined;

fn isn() u32 {
    return rng.int(u32);
}

/// **THE STREAMS THIS MACHINE KEEPS.** A request that kept a stream leaves its
/// connection open and claimed, and the stream lives here, indexed by that
/// connection — so there is always room, and no search. Every turn of the loop
/// drains each one's mailbox and writes what arrived; one that has been quiet
/// for the application's keepalive gets a ping; one whose client has gone is
/// ended. That is the whole of "iterating through the open sessions".
const Held = struct {
    conn: usize,
    kept: streams.Kept,
    last_write: i96,
    /// **THE REST OF A FRAME THE SEND QUEUE HAD NO ROOM FOR**, on the base heap,
    /// and how much of it has been queued. While it is here no further event
    /// is taken: they wait in the stream's mailbox.
    carry: []u8 = &.{},
    carry_at: usize = 0,
    /// Since when the carry has not moved, and where the peer's
    /// acknowledgements stood then: a stream stuck for the idle time is a
    /// client that is not keeping up.
    stuck_since: ?i96 = null,
    stuck_una: u32 = 0,
};
var held: [max_connections]?Held = @splat(null);

/// **RESPONSES STILL ON THEIR WAY**, after their handler finished: what the
/// send queue had no room for (`stream.Spill`), indexed by connection, as
/// `held` is. Every turn of the network queues more of each as its peer's
/// window opens; one that is empty is closed, one that has not moved for the
/// idle time is reset. Meanwhile the connection stays claimed, and the
/// machine serves the next request.
const Draining = struct {
    spill: stream.Spill,
    since: i96,
    una: u32,
};
var draining: [max_connections]?Draining = @splat(null);
var draining_now: usize = 0;

/// **WHAT THE HOST KNOWS OF EVERY CONNECTION'S BODY** (webbox's body.zig,
/// metal-vmm QUEUE 166, 169, 170), and what it does next with each: the
/// pure decisions of src/drain.zig (QUEUE 171), tested at every edge there
/// and driven by drain_sim. This loop keeps only the I/O: the table's bytes
/// consumed, `100 Continue` queued, the uploader asked of the store, the
/// clock read. Drained bodies live in the machine's heap.
const Drains = metal.drain.Drains(webbox.body, max_connections);
var drains: Drains = undefined;

/// The machine's clock `ms` from now, for a stream's body deadline: within
/// i64's nanoseconds for any deadline the rule makes (it holds them below
/// half of u64's milliseconds, and the clock counts from boot).
fn bodyDeadline(ms: u64) i64 {
    const now: i96 = Io.awakeNs() orelse 0;
    const at = now + @as(i96, @min(ms, std.math.maxInt(i64) / std.time.ns_per_ms)) * std.time.ns_per_ms;
    return @intCast(@min(at, std.math.maxInt(i64)));
}

/// The host's own answer to `Expect: 100-continue`, for a body it waits for.
const continue_line = "HTTP/1.1 100 Continue\r\n\r\n";

/// **THE LOG SAYS A BODY'S SIZE AND HOW LONG IT TOOK TO ARRIVE** (169): from
/// its drain's start (an upload's: its slot) to whole, or to `until`.
fn logBody(d: Drains.Drain, until: i96) void {
    serial.put(if (d.upload) "    upload: " else "    body: ");
    serial.putDec(d.len - d.head_len);
    serial.put(if (d.whole) " bytes, arrived in " else " bytes, not whole after ");
    serial.putDec(@intCast(@divTrunc(@max(until - d.began, 0), std.time.ns_per_ms)));
    serial.put(" ms\n");
}

/// Who is uploading, by the site's `uploader` over the head alone (its
/// sign-in, checked before a byte of the body is kept). A failure to tell is
/// no stranger: it is said, and the upload told the host is busy.
const Asker = metal.drain.Who;

var asker_scratch: [64 * 1024]u8 = undefined;

fn uploaderOf(io: Io, head: []const u8) Asker {
    var fba = std.heap.FixedBufferAllocator.init(&asker_scratch);
    var in: std.Io.Reader = .fixed(head);
    var out: std.Io.Writer = .fixed(&.{});
    var server = std.http.Server.init(&in, &out);
    var req = server.receiveHead() catch return .unknown;
    const who = app.site.uploader(&req, io, fba.allocator()) catch |e| {
        serial.put("  uploader: ");
        serial.put(@errorName(e));
        serial.put("\n");
        return .unknown;
    };
    return if (who) |name| .{ .who = webbox.body.keyOf(name) } else .stranger;
}
/// The most bytes one connection may keep (a whole upload of a few MB fits;
/// a larger response waits for room, as before spills).
const spill_cap = 32 * 1024 * 1024;
/// How much of the console's backlog one idle turn writes (serial.drain): at
/// a few tens of microseconds a byte, under a millisecond, which is how long
/// a request that arrives meanwhile waits for it.
const console_budget = 16;

/// **THE CONSOLE WAITS FOR THE RESPONSES** (QUEUE.md item 90). While a
/// connection has bytes the peer has not acknowledged, its acknowledgements
/// are what lets the rest go out, and a console turn taken then holds them:
/// a 4 MB picture spent half its time behind the console's turns. So the
/// console is written only once nothing is on its way, or once its backlog
/// is half full, so it never reaches the point where `put` writes directly.
fn consoleTurn(table: *const tcp.Table) bool {
    if (serial.pending() == 0) return false;
    if (serial.pending() >= serial.backlog / 2) return true;
    for (table.conns) |*c| {
        if (c.queued() > 0) return false;
    }
    return draining_now == 0;
}
var held_now: usize = 0;
var held_most: usize = 0;
var streams_ended: u64 = 0;
/// For /admin/host as well as the closing log: requests served, and the
/// connections open now and at most.
var served: u64 = 0;
var open_now: usize = 0;
var busiest: usize = 0;
/// The serving loop's TCP table, for /admin/host's counts (metal-vmm QUEUE
/// 193.1): set once the table is made.
var serving_table: ?*const tcp.Table = null;
/// The DHCP lease taken at boot, for /admin/host (193, gap 12).
var lease_held: ?dhcp.Lease = null;
/// When this boot's wall clock started, and the TSC's measured rate.
var booted_unix: i64 = 0;
var tsc_hz_seen: u64 = 0;
/// The request head's buffer: webbox's `http.head_bytes` sizes it, as it
/// sizes Linux's, so the two hosts answer 431 at the same byte.
var read_buf: [webbox.http.head_bytes]u8 align(16) = undefined;
var write_buf: [64 * 1024]u8 align(16) = undefined;

/// Each request's heap, reset after the response: the equivalent of the arena
/// server.zig gives each request and frees wholesale. A bump allocator is the
/// right shape for it — nothing in a request outlives the request — and the
/// memory under it is asked for once, from the machine's pages, rather than
/// being a fixed array inside the kernel image.
const request_heap_bytes = 32 * 1024 * 1024;

/// The page cache (`metal.page_cache`), its size from the config. In `.bss`:
/// its table of names is a megabyte, and the files' bytes are taken from the
/// pages as they are kept.
var page_cache: metal.page_cache.PageCache = undefined;
/// **THE APPLICATION'S DATA**: the two directories `app.site.start` points the
/// stores at (`Host.roots`), and the only ones this machine writes. On a droplet they are on the
/// volume, which outlives every new image; everything else is the site's own,
/// on the boot disk, and comes with the image.
const data_dir = "data";
const auth_dir = "auth";
const data_dirs = [_][]const u8{ data_dir, auth_dir };

/// **A COVERAGE LINE, ON THE PORT ONLY** (-Dcoverage): not into the ring,
/// which is the log /admin/host shows, and after whatever the console still
/// owes, so no line lands inside another. tools/coverage_jsonl.sh takes each
/// back out by its prefix.
/// **metal-vmm's COVERAGE DOOR** (its main.zig): a port that answers
/// `coverage_door_answer` there and nowhere else (a PC decodes nothing at
/// 0xE2, and an unanswered read is 0xFF). A line handed to it costs the
/// guest no time, where on the serial port every byte is an exit (KVM
/// emulates `rep outsb` a byte at a time), and a boot's catalog alone was
/// about nine seconds of guest time: enough to change what a run did
/// (metal-vmm QUEUE B28). The line is copied into `door_line` (its length,
/// then its bytes) and the buffer's address written to the door, one exit.
/// The kernel's memory is identity-mapped, so the address is physical.
/// Read once, at boot.
const coverage_door: u16 = 0xE2;
const coverage_door_answer: u8 = 'M';
var coverage_door_found = false;
var door_line: [4 + 4096]u8 align(4) = undefined;

fn coverageLine(line: []const u8) void {
    if (coverage_door_found) {
        // A line longer than the buffer goes in pieces; metal-vmm joins
        // them up to the newline.
        var rest = line;
        while (rest.len > 0) {
            const n = @min(rest.len, door_line.len - 4);
            std.mem.writeInt(u32, door_line[0..4], @intCast(n), .little);
            @memcpy(door_line[4..][0..n], rest[0..n]);
            metal.port.outl(coverage_door, @intCast(@intFromPtr(&door_line)));
            rest = rest[n..];
        }
        return;
    }
    serial.flushPending();
    serial.putPort("coverage: ");
    serial.putPort(line);
}

pub fn kmain() noreturn {
    serial.init();
    interrupts.install();
    serial.put("zig-metal-unikernel: " ++ (if (@hasDecl(app.hosting, "name")) app.hosting.name else "angry-gopher") ++ "'s route table, with no Linux under it\n");
    if (gm_build.coverage) {
        coverage_door_found = metal.port.inb(coverage_door) == coverage_door_answer;
        metal.coverage.sink = coverageLine;
        metal.coverage.declare();
    }

    // ── the machine's memory ────────────────────────────────────────────────
    // What RAM there is, where it is, and which of it this kernel is sitting
    // in. Everything below — the site's heap and each request's — comes out of
    // what is left, so this machine serves as much as it was booted with.
    const entries = metal.boot.memoryMap() catch |e| {
        serial.put("  memory map: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the loader described no memory, so there is nothing to serve from");
    };
    const image = metal.boot.image();
    // With the restart built in, the kept log's region past the image is
    // reserved too, so the page allocator never hands it out.
    const carved = pages.bring(pvh.largestFree(entries, if (gm_build.restart) metal.restarting.reserved() else image));
    if (carved.pages_total == 0) serial.fail("no usable region of RAM to serve from");
    serial.put("  ram: ");
    serial.putDec(pvh.totalRam(entries));
    serial.put(" bytes, kernel image ");
    serial.putDec(image.len);
    serial.put(", heap ");
    serial.putDec(carved.bytes_total);
    serial.put(" in ");
    serial.putDec(carved.pages_total);
    serial.put(" pages\n");

    // ── the disks ───────────────────────────────────────────────────────────
    // The boot disk holds the site and this machine's settings, and no boot
    // disk is a failure. The settings say whether the application's data is
    // on a volume, and which one (`volume = 92DE-8831`); without that line a
    // volume is used if one is attached, and the boot disk otherwise.
    var boot_disk = bootDisk();
    boot_disk.read_tries = boot_read_tries;
    disks[0] = &boot_disk;
    Io.mount(mountFat(&boot_disk, &sector, "the boot disk"));
    const io = Io.io();
    const base = webbox.mem_meter.init(gpa.allocator());
    const conf = readConfig(io, base);
    var volume_disk: virtio.Block = undefined;
    if (dataVolume()) |b| {
        volume_disk = b;
        volume_disk.read_tries = boot_read_tries;
        disks[1] = &volume_disk;
        const vol = mountFat(&volume_disk, &volume_sector, "the volume");
        serial.put("  its serial: ");
        putSerial(vol.serial);
        serial.put("\n");
        if (conf.volume) |want| if (vol.serial != want) {
            serial.put("  " ++ config_path ++ " names volume ");
            putSerial(want);
            serial.put("\n");
            serial.fail("the volume attached is not the one this machine serves");
        };
        Io.keepData(&data_dirs, vol);
        serial.put("  " ++ app.hosting.data_name ++ ": the volume\n");
    } else {
        // **A VOLUME THAT WAS NAMED AND IS MISSING STOPS THE MACHINE.** Serving
        // on would answer with no accounts and no conversations, and keep what
        // was written meanwhile on the boot disk, which the next image erases.
        if (conf.volume) |want| {
            serial.put("  " ++ config_path ++ " names volume ");
            putSerial(want);
            serial.put("\n");
            serial.fail("the volume this machine serves is not attached");
        }
        Io.keepData(&data_dirs, null);
        serial.put("  " ++ app.hosting.data_name ++ ": the boot disk\n");
    }
    // **THE DATA'S FILES, KEPT AFTER THEIR FIRST READ** (QUEUE.md item 87):
    // a transcript two people are reading is read from memory, not walked to
    // and read from the disk on every send. Memory is taken as files are
    // kept, never more than this; what it cannot get, it does not keep.
    //
    // **NEVER MORE THAN A QUARTER OF WHAT IS FREE.** The request heap is an
    // arena over the same pages, and a request larger than what it keeps grows
    // it while serving; memory the cache held would be memory that request
    // could not have. On a machine with little to spare the cache is smaller,
    // and the boot says so.
    if (conf.page_cache_mib != 0) {
        const p = pages.stats();
        const budget = @min(@as(usize, conf.page_cache_mib) << 20, (p.bytes_total - p.bytes_taken) / 4);
        const largest = @as(usize, conf.page_cache_largest_kib) << 10;
        page_cache = metal.page_cache.PageCache.init(pages.allocator, budget, largest);
        Io.keepPages(&page_cache);
        serial.put("  the data's files kept in memory: up to ");
        serial.putDec(budget >> 20);
        if (budget >> 20 < conf.page_cache_mib) {
            serial.put(" MiB (a quarter of the ");
            serial.putDec((p.bytes_total - p.bytes_taken) >> 20);
            serial.put(" MiB free, not the ");
            serial.putDec(conf.page_cache_mib);
            serial.put(" asked)");
        } else serial.put(" MiB");
        serial.put(", files of up to ");
        serial.putDec(largest >> 10);
        serial.put(" KiB\n");
    } else serial.put("  the data's files kept in memory: none (page_cache_mib = 0)\n");

    // **THE ADMIN'S LOST PASSWORD** (QUEUE.md item 89): a reset the boot
    // disk carries, applied before anything is served, and once.
    if (conf.reset) {
        const r = metal.admin_reset.Reset{ .name = conf.reset_name[0..conf.reset_name_len], .hash = &conf.reset_hash };
        serial.put("  admin password reset for ");
        serial.put(r.name);
        serial.put(": ");
        serial.put(switch (metal.admin_reset.apply(base, r)) {
            .applied => "applied; the old hash is auth/1/password.before-reset\n",
            .already => "applied by an earlier boot; nothing changed\n",
            .no_admin => "REFUSED: uid 1 has no password, so there is no admin to give one to; nothing changed\n",
            .other_name => "REFUSED: uid 1 is not named so on this volume; nothing changed\n",
            .failed => "FAILED: the volume would not read or write; the next boot tries again\n",
        });
    }

    const clock = metal.wallclock.start() catch |e| {
        serial.put("  wallclock: ");
        serial.put(@errorName(e));
        // **SAY WHICH CLOCK.** NoTimer and Implausible are the timer's: its
        // rate never settled, and the RTC was never asked. This printed the
        // RTC's empty record for them, "0 polls", which read as an RTC that
        // was never polled (QUEUE.md item 67).
        if (e == error.NoTimer or e == error.Implausible) {
            serial.put(" (the timestamp counter's rate, against the PIT, never settled; the RTC was not asked)\n");
            serial.fail("the clocks would not come up");
        }
        const m = metal.rtc.last_miss;
        serial.put(" (rtc: ");
        serial.putDec(m.polls);
        serial.put(" polls, ");
        serial.putDec(m.updating);
        serial.put(" mid-update, seconds ");
        serial.putDec(m.first_seconds);
        serial.put(" -> ");
        serial.putDec(m.last_seconds);
        serial.put(")\n");
        serial.fail("the clocks would not come up");
    };
    serial.put("  clock: TSC at ");
    serial.putDec(clock.tsc_hz);
    serial.put(" Hz, wall clock ");
    serial.putDec(@intCast(clock.unix));
    serial.put("\n");
    booted_unix = @intCast(clock.unix);
    tsc_hz_seen = clock.tsc_hz;
    // **A DEVICE WAIT ENDS** (metal-vmm QUEUE 193.2): 30 s for a disk
    // request, as Linux's SCSI layer gives one, and 1 s for a send buffer,
    // now that the TSC's rate is known. Before this, the defaults assume
    // 3 GHz (longer on a slower clock).
    metal.virtio.wait_budget_ticks = clock.tsc_hz * 30;
    metal.net.send_budget_ticks = clock.tsc_hz;

    // ── the restart (RESTART.md), only with -Drestart ───────────────────────
    if (gm_build.restart) {
        const restarted = metal.restarting.begin(wallNow);
        restart_record = restarted.record;
        if (restarted.wait_seconds > 0) waitSeconds(restarted.wait_seconds);
    }

    // Whose X-Forwarded-For is believed: the config's trusted_proxy, handed
    // to the host contract below (`app.site.start`).
    const trusted_proxy: ?[]const u8 = if (conf.trusted_proxy) |p| ipText(&trusted_proxy_text, p) else null;
    if (trusted_proxy) |p| {
        serial.put("  X-Forwarded-For is believed from ");
        serial.put(p);
        serial.put(" only\n");
    } else serial.put("  no trusted_proxy: every request is the address it came from\n");

    const limit = conf.requests;
    serial.put("  a connection may make no progress for ");
    serial.putDec(conf.idle_ns / std.time.ns_per_ms);
    serial.put(" ms\n");
    if (limit) |n| {
        serial.put("  serving ");
        serial.putDec(n);
        serial.put(" request(s), as " ++ config_path ++ " says\n");
    } else serial.put("  serving until stopped\n");

    // ── the network ─────────────────────────────────────────────────────────
    rng.attach(&rng_mem);
    const nic_base = virtio.findNth(virtio.device_id_net, @intFromEnum(conf.card)) orelse switch (conf.card) {
        .public => serial.fail("no virtio-net device on the PCI bus or in any mmio slot"),
        .private => serial.fail("`card = private`, and this machine has no second network card"),
    };
    serial.put("  network: the ");
    serial.put(@tagName(conf.card));
    serial.put(" card\n");
    var nic = net.Net.init(nic_base, &nic_mem) catch serial.fail("the NIC would not come up");
    const lease = dhcp.acquire(&nic, &dhcp_frame, &dhcp_reply) catch
        serial.fail("no DHCP lease, so there is no address to listen on");
    lease_held = lease;
    restBetweenFrames(&nic, clock.tsc_hz);
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  listening on port 80\n");
    // Serving, a failed read fails its request and says so; boot's retries
    // end here, and those it needed are told.
    for (disks) |maybe| if (maybe) |d| {
        d.read_tries = 1;
        if (d.reads_retried > 0) {
            serial.put("  reads that failed at boot and answered when tried again: ");
            serial.putDec(d.reads_retried);
            serial.put(if (d == &boot_disk) " (the boot disk)\n" else " (the volume)\n");
        }
    };

    const rx_all = pages.allocator.alloc(u8, max_connections * rx_bytes) catch
        serial.fail("the machine has not enough memory for its connections");
    const tx_all = pages.allocator.alloc(u8, max_connections * tx_bytes) catch
        serial.fail("the machine has not enough memory for its connections");
    for (&conn_slots, 0..) |*c, k| c.* = .{
        .rx = rx_all[k * rx_bytes ..][0..rx_bytes],
        .tx = tx_all[k * tx_bytes ..][0..tx_bytes],
    };
    var table = tcp.Table.init(lease.address, nic.mac, 80, &conn_slots, &tcp_out, isn);
    serving_table = &table;
    // **ONE SLOT IS THE MACHINE'S OWN** (the application's fetch, host_fetch):
    // a flood of SYNs cannot take it. And its ports start where a draw says,
    // as probe/fetch.zig's do, not at the same port every boot.
    table.reserved_for_initiated = 1;
    table.ephemeral_next = @intCast(tcp.ephemeral_first + rng.int(u16) % (0xFFFF - tcp.ephemeral_first));
    fetching = .{ .our_ip = lease.address, .our_mac = nic.mac, .mask = lease.mask };
    stream.on_arp = fetchLearned;
    var wire = stream.Wire{ .nic = &nic, .lose_one_sent_in = conf.lose_one_sent_in };
    if (conf.lose_one_sent_in != 0) {
        serial.put("  losing one TCP frame in ");
        serial.putDec(conf.lose_one_sent_in);
        serial.put(" of those sent, as " ++ config_path ++ " says\n");
    }
    serial.put("  holding up to ");
    serial.putDec(max_connections);
    serial.put(" connections at once, one of them kept for the machine's own fetch\n");

    var request_heap = RequestHeap.init(pages.allocator, request_heap_bytes);
    if (!request_heap.preheat())
        serial.fail("the machine has not enough memory for a request heap");
    // **THE HOST CONTRACT, ONE CALL** (webbox's site.zig, the application's
    // `app.site`): what this machine supplies (where the data is on
    // its volumes, how its free space is read off the data's FAT, the trusted
    // proxy, /admin/host's facts and the serial log), and the setup in its one
    // order before the first request: the session secret's move, every chat
    // session's last-message record (as Linux does, so the two hosts leave
    // the same files behind, which the judge compares), and search's index.
    // Each one-time pass reads on an arena `start` gives back.
    var started = app.site.start(io, .{
        .roots = .{ .data_dir = data_dir, .auth_dir = auth_dir },
        .free_space = .{ .reader = dataSpace },
        .trusted_proxy = trusted_proxy,
        .facts = metalFacts,
        .log = metalLog,
        .logs = metalLogs,
        .say = metalSay,
        .fetch = .{ .start = fetchStart, .result = fetchResult },
    }) catch |e| {
        serial.put("  ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the host contract's setup (app.site.start) failed");
    };
    const hub = &started.hub;
    // **DURABLE ON DEMAND** (metal-vmm QUEUE 200): the script route's
    // sequence number is flushed before its script runs, and a failed
    // flush refuses the run.
    webbox.store.durable_now = Io.durableChecked;
    drains = .{ .gpa = hub.gpa, .limit = app.site.bodyLimit };
    {
        var said: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&said);
        app.hosting.describeStart(started.app, &w) catch
            serial.fail("the application's start report is past its 1 KiB buffer (app.hosting.describeStart)");
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
        while (lines.next()) |line| {
            serial.put("  ");
            serial.put(line);
            serial.put("\n");
        }
    }
    // **IDLE TIME** (src/idle.zig, essay idle-time-on-metal): each volume's
    // check, asked again while the machine serves, a slice per quiet moment.
    for ([_]?*disk_fat.Volume{ Io.siteVolume(), Io.dataVolume() }, 0..) |maybe, k| {
        const vol = maybe orelse continue;
        const seen = pages.allocator.alloc(u8, vol.checkBytes()) catch
            serial.fail("the machine has not enough memory for a volume's idle check");
        volume_checks[k] = .{ .vol = vol, .seen = seen };
        idle_work.add(volume_checks[k].?.init(volume_check_names[k])) catch unreachable;
    }
    const scratch_heap = pages.allocator.alloc(u8, stream_scratch_bytes) catch
        serial.fail("the machine has not enough memory for its streams' scratch");
    turning = .{ .wire = &wire, .table = &table, .hub = hub, .conf = conf, .scratch = .init(scratch_heap) };
    stream.after_arrivals = streamTurn;

    // From here a fatal error is a failure while serving: with the restart
    // built in, it restarts the machine (RESTART.md).
    if (gm_build.restart) metal.restarting.serving();

    // **STEPPED BEFORE THE FIRST REQUEST** (metal-vmm QUEUE 222), as the
    // Linux host does: a site that learns from its first `between` that its
    // host steps background runs knows it before the first request.
    betweenSlice(io);

    // ── the loop: talk to the network, serve whatever is ready ──────────────
    //
    // **MANY CONNECTIONS, ONE REQUEST AT A TIME.** Every turn moves the
    // network — every connection, and every held stream — and then serves at
    // most one thing: the oldest connection whose whole request head has
    // arrived, start to finish, or else the oldest one that has been quiet for
    // `idle_timeout_ms`, which is let go. A client that connects and says
    // nothing waits in the table instead of holding the door.
    //
    // **WHAT WAITS FOR THIS LOOP, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md
    // §2). The loop serves one thing at a time, so every row below is bounded
    // only as long as no single serve waits without a bound of its own.
    //
    // - **A connection whose request has arrived.** Served when it is the
    //   oldest ready. Bounded by: every older ready request's serve, plus the
    //   one in progress. A serve's waits are each bounded by `idle_ns`
    //   without progress (stream.zig); its close queues a FIN and does not
    //   wait — the table finishes it.
    // - **A connection that has gone quiet.** Let go once it has been silent
    //   for `idle_ns`, and only on a turn with nothing ready: a steady run of
    //   ready requests delays it, at the cost of a slot, never of an answer.
    //   Bounded by: `idle_ns`, plus the serves ahead of it.
    // - **A held stream's frames and pings.** Moved by every turn of the
    //   network, the turns inside a serve included (`stream.after_arrivals`).
    //   Bounded by: the next turn — which a serve doing disk work holds back.
    // - **A connection served and closing.** The table's timers.
    // - **The loop itself, with nothing to do.** It rests only when nothing
    //   arrived, nothing was ready and nothing was quiet. Bounded by: the
    //   card's interrupt, or `interrupts.slice_ns`.
    // - **The goodbyes, when the boot ends.** Connections still closing are
    //   given two seconds of turns, then the machine stops.
    var deepest: usize = 0;
    var oversized_seen: u64 = 0; // net.oversized last reported to the console
    // From here the console waits for idle turns (serial.deferred).
    serial.deferred = true;
    while (limit == null or served < limit.?) {
        diskStopped();
        open_now = table.inUse();
        busiest = @max(busiest, open_now);
        const arrived = stream.pump(&wire, &table, lease.address);
        sleeps.turned(arrived != null);
        const now = Io.awakeNs() orelse 0;
        if (arrived != null) idle_work.busy(now);
        if (nextReady(io, &wire, &table, now)) |pick| {
            served += 1;
            serveOne(io, &wire, &table, pick, lease.address, request_heap.allocator(), hub, served, conf.idle_ns, conf.streams);
            const after_turn = Io.awakeNs() orelse now;
            drains.pause(after_turn - now);
            idle_work.busy(after_turn);
        } else if (quiet(&table, now, conf.idle_ns)) |pick| {
            served += 1;
            letGo(&wire, &table, pick, served);
        } else {
            // Nothing to serve: the console's turn, a little at a time so a
            // request that arrives meanwhile waits at most this much.
            if (consoleTurn(&table)) {
                serial.drain(console_budget);
                continue;
            }
            // Then the application's work between requests: a slice a turn
            // while it says there is more, and once the time it asked for has
            // come. A request that arrives meanwhile is served first, on the
            // next turn; and the network turns before any rest, for what the
            // call queued.
            if (Sleep.betweenDue(now, between.wake, fetching.news)) {
                betweenSlice(io);
                continue;
            }
            // Then idle work, a step, once nothing has arrived for a while.
            if (idle_work.turn(now, awakeNow)) continue;
            if (arrived == null) restOrSleep(&table, now, conf.longest_rest_ns);
            continue;
        }
        // What this request used of its heap, BEFORE the reset: the same
        // request must use the same amount every time, and a heap that was not
        // reset would show up as a number that only grows.
        serial.put("    request heap: ");
        serial.putDec(request_heap.used);
        serial.put(" bytes\n");
        request_heap.reset();
        if (coverage_checks) checkVolumes();
        deepest = reportStack(deepest);
        // One slice of the application's work after each served turn: the
        // request may have started it, and a steady run of requests never
        // starves it.
        betweenSlice(io);
        // **LOUD, ONCE PER OCCURRENCE** (REVIEW-item90-step2.md finding 1): a
        // frame too long to send is a kernel bug net.zig refused rather than
        // overrun. The count is on /admin/host; this is the console line.
        if (nic.oversized != oversized_seen) {
            oversized_seen = nic.oversized;
            serial.put("  net: a frame too long to send was refused (a kernel bug); /admin/host counts them\n");
        }
    }

    // The boot is over: the console is written out in full from here.
    serial.immediate();
    // Responses still on their way are given the idle time
    // to finish (their turns run inside `pump`), then the rest are reset.
    const draining_from = Io.awakeNs() orelse 0;
    while (draining_now > 0 and (Io.awakeNs() orelse 0) - draining_from < conf.idle_ns) {
        stream.pumpOrRestOn(&wire, &table, lease.address);
    }
    for (&draining, 0..) |*slot, i| {
        if (slot.*) |*d| {
            table.abandon(&wire, i, .slow_client);
            serial.put("  let go at the end: the client stopped taking the response\n");
            d.spill.deinit();
            table.release(i);
            slot.* = null;
            draining_now -= 1;
        }
    }
    // Every stream still held ends with it, and the goodbyes are given a
    // moment to be acknowledged.
    stream.after_arrivals = null;
    for (&held) |*slot| {
        if (slot.* != null) endStream(slot, &wire, &table, hub, .stopping);
    }
    const stopping_at = Io.awakeNs() orelse 0;
    while (closing(&table) and (Io.awakeNs() orelse 0) - stopping_at < 2 * std.time.ns_per_s) {
        stream.pumpOrRestOn(&wire, &table, lease.address);
    }
    // **A RESPONSE CUT BY THE STOP IS SAID TO BE.** One still unacknowledged
    // now is never finished: its request counted as answered, and its client
    // has part of the answer. Only a request limit stops the machine.
    var cut_conns: usize = 0;
    var cut_bytes: usize = 0;
    for (table.conns) |c| {
        if (c.state != .closing or c.queued() == 0) continue;
        cut_conns += 1;
        cut_bytes += c.queued();
    }
    if (cut_conns > 0) {
        serial.put("  let go at the end: ");
        serial.putDec(cut_conns);
        serial.put(" response(s) cut by the stop, ");
        serial.putDec(cut_bytes);
        serial.put(" bytes never acknowledged\n");
    }
    serial.put("  streams: at most ");
    serial.putDec(held_most);
    serial.put(" held at once, ");
    serial.putDec(streams_ended);
    serial.put(" ended, ");
    // Every stream has been ended, so every subscriber should be gone: one
    // left behind is a stream that was never dropped.
    serial.putDec(hub.entries.items.len);
    serial.put(" still subscribed\n");

    serial.put("  connections: at most ");
    serial.putDec(busiest);
    serial.put(" at once, ");
    serial.putDec(table.refused);
    serial.put(" turned away for want of a slot\n");
    serial.put("  tcp: ");
    serial.putDec(table.retransmits);
    serial.put(" timeouts sent something again, ");
    serial.putDec(table.probes);
    serial.put(" window probes, ");
    serial.putDec(table.given_up);
    serial.put(" peers given up on, ");
    serial.putDec(table.fin_waits_expired);
    serial.put(" never finished, ");
    serial.putDec(table.strays);
    serial.put(" strays reset, ");
    serial.putDec(wire.lost);
    serial.put(" frames lost on purpose, ");
    serial.putDec(table.window_updates);
    serial.put(" reopened windows said again\n");
    const mem = webbox.mem_meter.snapshot();
    const page_stats = pages.stats();
    serial.put("  pages: ");
    serial.putDec(page_stats.bytes_taken);
    serial.put(" bytes held of ");
    serial.putDec(page_stats.bytes_total);
    serial.put(", peak ");
    serial.putDec(page_stats.pages_high_water * pages.page_size);
    serial.put("\n");
    // The judge (metal-vmm sweep.sh, `counted_leak`) reads these: what fsck
    // reclaims on a disk must not pass what the kernel counted there.
    if (Io.siteVolume()) |v| leakLine("the boot disk", v);
    if (Io.dataVolume()) |v| leakLine("the volume", v);
    serial.put("  served ");
    serial.putDec(served);
    serial.put(" request(s); base heap holds ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes in ");
    serial.putDec(mem.live_allocs);
    serial.put(" allocations\n");
    serial.put("  stack high water: ");
    serial.putDec(deepest);
    serial.put(" of ");
    serial.putDec(stack.size);
    serial.put(" bytes\n");
    serial.pass();
}

/// The oldest connection with something to serve, or null. **THE TURN
/// NEVER WAITS ON THE NETWORK** (metal-vmm QUEUE 169): a connection is ready
/// only once everything its handler reads is in memory. A head asking
/// `100-continue` is answered here; a small body too big for the buffer is
/// drained into memory; an upload's asker is checked, given a slot, and its
/// body drained; a body coming past the rule's deadline is served as late.
fn nextReady(io: Io, wire: *stream.Wire, table: *tcp.Table, now: i96) ?usize {
    var best: ?usize = null;
    for (table.conns, 0..) |*c, i| {
        _ = drains.of(i, c.serial);
        if (c.claimed) continue;
        // **THE HOST SERVES WHAT IT ACCEPTED**: a connection this machine
        // opened is its client's (tcp.zig's Role), never a request to answer.
        if (c.role == .initiated) continue;
        if (c.state != .established) {
            // Gone before its turn: what its body held, given back.
            if (!c.open()) drains.release(i);
            continue;
        }
        if (!readyNow(io, wire, table, i, now)) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// The drain's decision for connection `i`, and its I/O done.
fn readyNow(io: Io, wire: *stream.Wire, table: *tcp.Table, i: usize, now: i96) bool {
    const c = &table.conns[i];
    while (true) {
        const next = drains.step(i, .{ .serial = c.serial, .pending = c.pending(), .peer_done = c.peerDone(), .capacity = c.rx.len }, now);
        if (next.consumed > 0) {
            // Drained into memory: the window reopens.
            if (c.consumeReopens(next.consumed)) table.ack(wire, i);
        }
        switch (next.then) {
            .wait => return false,
            .serve => return true,
            .send_continue => {
                // Sixteen bytes in a send queue of 64 KiB, nothing yet in it.
                if (table.queue(i, continue_line) == continue_line.len) drains.continued(i);
                return false;
            },
            // Asked once, of the store; then decided again.
            .ask_who => drains.know(i, uploaderOf(io, c.pending())),
        }
    }
}

/// The oldest connection that has gone quiet for `idle_ns` without sending a
/// whole request, or null.
fn quiet(table: *tcp.Table, now: i96, idle_ns: u64) ?usize {
    var best: ?usize = null;
    for (table.conns, 0..) |*c, i| {
        if (c.claimed or !c.open()) continue;
        // **THE MACHINE'S OWN CONNECTIONS ARE ITS CLIENT'S** (the application's
        // fetch): bounded by their own deadlines (`tcp.Deadlines`), never let
        // go as a silent request would be, behind the client's back.
        if (c.role == .initiated) continue;
        // A body coming after a whole head is the rule's to end, with a 408
        // at its deadline (nextReady), not let go unanswered.
        // A body coming, draining, or waiting for an upload slot is the
        // rule's to end (nextReady), not let go unanswered.
        if (c.state == .established and drains.of(i, c.serial).holds()) continue;
        if (now - c.heard_at < idle_ns) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// **A CLIENT THAT STOPPED TALKING IS NOT A BROKEN NIC.** It is logged as a
/// request that never came, the way it always has been, and closed.
fn letGo(wire: *stream.Wire, table: *tcp.Table, i: usize, number: u64) void {
    logRequest(number, wallMs(), "(no request)", "the client stopped sending, and was let go", 0, null);
    close(wire, table, i);
}

/// Answers the request waiting on connection `i`, and closes it. Every failure
/// short of a panic is logged and survived.
fn serveOne(
    io: Io,
    wire: *stream.Wire,
    table: *tcp.Table,
    i: usize,
    address: [4]u8,
    request_alloc: std.mem.Allocator,
    hub: *Hub,
    number: u64,
    idle_ns: u64,
    max_streams: usize,
) void {
    table.claim(i);
    // A connection that now carries a kept stream stays claimed and open.
    var kept_open = false;
    defer if (!kept_open) table.release(i);
    var s = stream.Stream.init(wire, table, i, address, &read_buf, &write_buf);
    s.idle_ns = idle_ns;
    var spill = stream.Spill{ .gpa = hub.gpa, .cap = spill_cap };
    var spill_kept = false;
    defer if (!spill_kept) spill.deinit();
    s.spill = &spill;

    // **WHAT THIS MACHINE'S OWN CLOCK SAYS EACH REQUEST COST.** How long the
    // connection had been open before its turn came — the client finishing
    // its request, and then the queue — and how long the route table took to
    // answer. Timing from outside measures curl, slirp and the emulator too.
    const opened_at = table.conns[i].opened_at;

    // **A BODY IN MEMORY IS SERVED FROM MEMORY** (metal-vmm QUEUE 169): a
    // drained request's head and body are read from where the loop kept
    // them, never from the network; its memory and slot are given back when
    // it is done.
    const wait = drains.of(i, table.conns[i].serial);
    defer drains.release(i);
    var from_memory: std.Io.Reader = .fixed(wait.memory() orelse "");
    // **THE HEAD HAS ONE DEADLINE TOO** (metal-vmm QUEUE 166's cold review):
    // a head is served unended only when the buffer is too full for more
    // (ready.zig), and the rest of it is read here. Without a bound for the
    // whole of it, a byte every `idle_ns` less a little held the turn for
    // hours before the 431. So is any body read from the buffer (one that
    // fit it, whole already, or a client's that ended short).
    s.body_deadline_at = bodyDeadline(webbox.body.smallMs(webbox.http.head_bytes));
    // **A HEAD THAT FILLED THE BUFFER UNENDED IS A 431 AT ONCE** (169's cold
    // review): the buffer is the head's most (`head_bytes`), so the rest of
    // it, read here, could only overflow, and reading it waited on the
    // network in the turn. A client that closed is served as ever.
    if (wait.drain == null and !table.conns[i].peerDone()) {
        var hp: std.http.HeadParser = .{};
        _ = hp.feed(table.conns[i].pending());
        if (hp.state != .finished) {
            edge.count(.header_too_large);
            s.writer().writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            s.writer().flush() catch {};
            logRequest(number, wallMs(), "(no request)", "a head that filled the buffer unended: 431", 431, null);
            close(wire, table, i);
            return;
        }
    }
    var server = std.http.Server.init(if (wait.drain != null) &from_memory else s.reader(), s.writer());
    var req = server.receiveHead() catch |e| {
        // **A HEAD PAST THE READ BUFFER IS ANSWERED 431, AS LINUX ANSWERS IT**
        // (angry-gopher's server.zig, handleConn): counted for /version, and
        // the same bytes. Metal closed without a word, so a browser with an
        // oversized cookie saw an empty reply (QUEUE.md item 81, found by
        // probe/fuzz_requests.py).
        if (e == error.HttpHeadersOversize) {
            edge.count(.header_too_large);
            s.writer().writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            s.writer().flush() catch {};
        }
        // **A HEAD THAT IS NOT HTTP IS A 400, COUNTED, AS LINUX ANSWERS IT**
        // (metal-vmm QUEUE 172): it was closed with no answer.
        if (e == error.HttpHeadersInvalid) {
            edge.count(.head_malformed);
            s.writer().writeAll("HTTP/1.1 400 Bad Request\r\n" ++
                "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            s.writer().flush() catch {};
        }
        logRequest(number, wallMs(), "(no request)", if (s.timed_out)
            "the client stopped sending, and was let go"
        else
            @errorName(e), if (e == error.HttpHeadersInvalid) 400 else 0, null);
        close(wire, table, i);
        return;
    };
    req.head.keep_alive = false;

    // **THE BODY BY THE ONE RULE** (webbox's body.zig; metal-vmm QUEUE 166,
    // 169): refused from its head, late from waiting (a 408), refused by the
    // loop's verdict, or in memory (or in the buffer) whole already: the turn
    // never waits on the network.
    const body_rule = webbox.body;
    const cap = app.site.bodyLimit(req.head.target);
    const refusal: ?struct { kind: edge.RejectKind, msg: []const u8 } = if (wait.refusal()) |r| switch (r) {
        .too_slow => .{ .kind = .body_too_slow, .msg = "request body too slow\n" },
        .busy => .{ .kind = .uploads_busy, .msg = "Uploads are busy; try again in a minute.\n" },
        .too_large => .{ .kind = .body_too_large, .msg = "request body too large\n" },
        .stalled => .{ .kind = .body_too_slow, .msg = "the upload stalled\n" },
        .replaced => .{ .kind = .upload_replaced, .msg = "a newer upload took this one's place\n" },
    } else switch (body_rule.plan(&req.head, cap)) {
        .refused => |r| switch (r) {
            .too_large => .{ .kind = .body_too_large, .msg = "request body too large\n" },
            .framed_twice => .{ .kind = .body_framed_twice, .msg = "request body framed twice\n" },
            .length_required => .{ .kind = .body_length_required, .msg = "an upload says its length\n" },
            .expectation_failed => .{ .kind = .body_expectation_failed, .msg = "only 100-continue is met\n" },
        },
        .none, .small, .upload => null,
    };
    // The one expectation met, in any case, made std's exact one (metal-vmm
    // QUEUE 180.7: std refuses `100-Continue` with no answer, and a bodiless
    // one reached it).
    if (refusal == null) body_rule.meetExpectation(&req.head);
    // Told to send already, by the host, or never to be: std must not tell it.
    if (wait.continued or wait.verdict == .stranger) req.head.expect = null;
    if (refusal) |r| {
        // Refused, never told to send (std answers an expectation first
        // while it is set).
        req.head.expect = null;
        webbox.edge.reject(&req, r.kind, r.msg) catch {};
        s.writer().flush() catch {};
        const refused_status: u16 = @intFromEnum(webbox.edge.statusFor(r.kind));
        // Its method and path, so /admin/log's `path=` finds it (194.5).
        var refused_buf: [300]u8 = undefined;
        logRequest(number, wallMs(), metal.request_line.what(&refused_buf, @tagName(req.head.method), metal.log_ring.withoutQuery(req.head.target), true), r.msg[0 .. r.msg.len - 1], refused_status, null);
        // A drained body refused (late, past what is kept): what came of it.
        // **AN UPLOAD REFUSED FROM ITS HEAD IS AN UPLOAD** (194.1), with
        // or without a drain: busy, no memory, an asker unknown, an older
        // retry's 409, a stranger.
        if (wait.wasUpload()) {
            noteUpload(number, wait.drain, metal.log_ring.withoutQuery(req.head.target), if (wait.drain) |d| metal.uploads_seen.kindOf(d.body()) orelse "" else "", refused_status, r.msg, null, 0, Io.awakeNs() orelse 0);
        } else if (wait.drain) |d| {
            if (d.len > d.head_len) logBody(d, Io.awakeNs() orelse 0);
        }
        close(wire, table, i);
        return;
    }

    // The target is borrowed from the read buffer, which the handler may
    // consume; copy it for the log now — the PATH only, never the query, which
    // is not the log's to keep (serial.log_ring.withoutQuery; QUEUE.md item 95).
    var what_buf: [300]u8 = undefined;
    const path = metal.log_ring.withoutQuery(req.head.target);
    const what = metal.request_line.what(&what_buf, @tagName(req.head.method), path, false);

    const head_at = Io.awakeNs() orelse 0;
    const disk_before = diskWork();

    var outcome: []const u8 = "ok";
    var bus = Bus.of(hub);
    var peer_text: [15]u8 = undefined;
    bus.peer = ipText(&peer_text, table.conns[i].peer_ip);
    bus.at_unix_ms = wallMs();
    // The stream the handler kept is route's answer (angry-gopher 157(a)):
    // on an error, route has already dropped it.
    // A drained body handed to the handler's read as it is (170.5): only a
    // Content-Length one that came whole to its length. A chunked one is
    // still framed, and a short one (its client gone) must be refused: std
    // reads both from memory, decoding the one and refusing the other.
    // An upload's kind, from its part's own header, before the handler
    // reads the body (189.4).
    const upload_kind: metal.uploads_seen.Text(48) = if (wait.drain) |d| .of(if (d.upload) metal.uploads_seen.kindOf(d.body()) orelse "" else "") else .{};
    switch (wait.handover()) {
        .whole => |body| webbox.http.held_body = body,
        .network, .memory => {},
    }
    defer webbox.http.held_body = null;
    const kept_stream = app.site.route(&req, io, request_alloc, &bus) catch |e| blk: {
        outcome = @errorName(e);
        break :blk null;
    };
    // The body's deadline is the body's: what follows only writes.
    s.body_deadline_at = null;
    // **THE HEAD AND BACKLOG GO FIRST.** Every turn of the network may service
    // the held streams, and this flush takes turns: a stream registered before
    // it would have its live frames queued ahead of its own head.
    const flushed = if (s.writer().flush()) |_| true else |_| false;
    // What the head and backlog left in the spill goes ahead of every live
    // frame, as the carry the stream already drains first: copied here, and
    // a stream whose copy fails is not kept (metal-vmm QUEUE 198.1).
    var carry: ?[]u8 = null;
    if (kept_stream != null and flushed and spill.pending().len > 0) {
        carry = hub.gpa.dupe(u8, spill.pending()) catch null;
    }
    // **WHAT BECOMES OF THE CONNECTION** (src/after_turn.zig: the decision,
    // pure and tested; here, its I/O).
    const after = metal.after_turn.decide(.{
        .kept = kept_stream != null,
        .flushed = flushed,
        .timed_out = s.timed_out,
        .spill_pending = spill.pending().len,
        .carry_copied = carry != null,
        .established = table.conns[i].state == .established,
        .held_now = held_now,
        .max_streams = max_streams,
    });
    if (after.outcome) |o| outcome = o;
    switch (after.stream) {
        .none => {},
        .drop => {
            streams.drop(hub, kept_stream.?);
            if (carry) |c| hub.gpa.free(c);
        },
        .keep, .keep_displacing_oldest => {
            // The handler wrote the stream's head and backlog; the live part
            // is this machine's now.
            // **THE BUDGET IS KEPT BY ENDING THE OLDEST.** A browser whose
            // stream ends reconnects, and a conversation stream resumes from
            // its last event; a new tab that could not open at all would not.
            if (after.stream == .keep_displacing_oldest) {
                if (oldestHeld(table)) |slot| endStream(slot, wire, table, hub, .displaced);
            }
            held[i] = .{ .conn = i, .kept = kept_stream.?, .last_write = Io.awakeNs() orelse 0, .carry = carry orelse &.{} };
            held_now += 1;
            held_most = @max(held_most, held_now);
        },
    }
    const done_at = Io.awakeNs() orelse 0;
    // **THE CONNECTION IS LET GO BEFORE ITS LOG IS WRITTEN**, so the client is
    // done when the response is, not when the console has caught up.
    switch (after.conn) {
        .stream => kept_open = true,
        .abandon => table.abandon(wire, i, .slow_client),
        .drain => {
            draining[i] = .{ .spill = spill, .since = Io.awakeNs() orelse 0, .una = table.conns[i].una };
            draining_now += 1;
            spill_kept = true;
            kept_open = true;
        },
        .close => close(wire, table, i),
    }
    logRequest(number, bus.at_unix_ms, what, outcome, bus.status, if (done_at >= head_at) @intCast(done_at - head_at) else null);
    // **THE LOG SAYS A BODY'S SIZE AND HOW LONG IT TOOK TO ARRIVE** (169), so
    // a slow link is read, not inferred.
    const disk_after = diskWork();
    if (wait.drain) |d| {
        if (d.upload) {
            // `what`, the log's own copy: the target is borrowed from the
            // read buffer, which the handler may have consumed.
            const copied = if (std.mem.indexOfScalar(u8, what, ' ')) |sp| what[sp + 1 ..] else what;
            noteUpload(number, d, copied, upload_kind.slice(), bus.status, outcome, if (done_at >= head_at) @intCast(done_at - head_at) else null, disk_after.requests - disk_before.requests, done_at);
        } else if (wait.verdict == .none) logBody(d, d.whole_at);
    }
    serial.put("    waited ");
    serial.putDec(@intCast(@divTrunc(head_at - opened_at, 1000)));
    serial.put(" us, answered in ");
    serial.putDec(@intCast(@divTrunc(done_at - head_at, 1000)));
    serial.put(" us, ");
    serial.putDec(disk_after.requests - disk_before.requests);
    serial.put(" disk requests taking ");
    serial.putDec(@intCast(@divTrunc(Io.ticksToNs(disk_after.ticks -% disk_before.ticks), 1000)));
    serial.put(" us\n");
}

/// One pass over the responses still on their way: queue more of each, close
/// the ones that are done, reset the ones whose peer stopped taking them.
fn serviceDraining(wire: *stream.Wire, table: *tcp.Table, now: i96, idle_ns: u64) void {
    if (draining_now == 0) return;
    for (&draining, 0..) |*slot, i| {
        const d = if (slot.*) |*d| d else continue;
        const c = &table.conns[i];
        var done = false;
        if (c.state != .established) {
            done = true;
        } else {
            if (d.spill.push(table, i) > 0 or c.una != d.una) {
                d.since = now;
                d.una = c.una;
            }
            if (d.spill.pending().len == 0) {
                close(wire, table, i);
                done = true;
            } else if (now - d.since >= idle_ns) {
                table.abandon(wire, i, .slow_client);
                serial.put("  let go: the client stopped taking the response\n");
                done = true;
            }
        }
        if (done) {
            d.spill.deinit();
            table.release(i);
            slot.* = null;
            draining_now -= 1;
        }
    }
}

/// What a turn of the held streams needs, set once the network is up.
var turning: ?struct { wire: *stream.Wire, table: *tcp.Table, hub: *Hub, conf: Config, scratch: std.heap.FixedBufferAllocator } = null;
/// The streams' own scratch: a turn can come in the middle of a request, whose
/// heap is not the streams' to reset. Big enough for the largest frame chat
/// renders, several times over.
const stream_scratch_bytes = 4 * 1024 * 1024;
var in_turn = false;

/// Called by every turn of the network (`stream.after_arrivals`). A turn does
/// not start another: ending a stream never waits, but it is simpler to know
/// that than to prove it each time.
fn streamTurn() void {
    const t = if (turning) |*t| t else return;
    if (in_turn) return;
    in_turn = true;
    defer in_turn = false;
    const now = Io.awakeNs() orelse 0;
    fetchStep(t.table, t.wire, now);
    serviceStreams(t.wire, t.table, t.hub, t.scratch.allocator(), now, t.conf);
    t.scratch.reset();
    serviceDraining(t.wire, t.table, now, t.conf.idle_ns);
}

/// One pass over the held streams: end the ones whose client has gone, queue
/// what has arrived for the rest, ping the quiet ones. `scratch` holds the
/// rendered frames for this pass only.
///
/// **NOTHING HERE WAITS.** A frame goes into its connection's send queue as far
/// as there is room, and the rest is carried to the next turn. A stream whose
/// carry has not moved for the idle time is ended: its tab is not reading, and
/// its browser will reconnect and resume. So is one whose mailbox overflowed —
/// a stream with a gap in it is worse than one that starts again.
fn serviceStreams(wire: *stream.Wire, table: *tcp.Table, hub: *Hub, scratch: std.mem.Allocator, now: i96, conf: Config) void {
    // A frame shows others what was just saved: the save is durable first,
    // as for any response (`io.durable`). These frames, and the keepalive
    // ping below, are queued here, not through a Stream, so this one call
    // covers all three of this function's queues.
    Io.durable();
    for (&held) |*slot| {
        const h = if (slot.*) |*h| h else continue;
        const c = &table.conns[h.conn];
        if (!c.open() or c.peerDone()) {
            endStream(slot, wire, table, hub, .client_left);
            continue;
        }
        var wrote = false;
        while (true) {
            if (h.carry_at < h.carry.len) {
                const n = table.queue(h.conn, h.carry[h.carry_at..]);
                h.carry_at += n;
                wrote = wrote or n > 0;
                if (h.carry_at < h.carry.len) break;
                hub.gpa.free(h.carry);
                h.carry = &.{};
                h.carry_at = 0;
            }
            const next = streams.nextFrame(h.kept, scratch) catch |e| {
                endStream(slot, wire, table, hub, if (e == error.EventsMissed) .missed_events else .no_room_to_render);
                break;
            };
            const frame = next orelse break;
            const n = table.queue(h.conn, frame);
            wrote = wrote or n > 0;
            if (n == frame.len) continue;
            h.carry = hub.gpa.dupe(u8, frame[n..]) catch {
                endStream(slot, wire, table, hub, .no_room_to_render);
                break;
            };
        }
        const still = if (slot.*) |*left| left else continue;
        if (wrote) still.last_write = now;
        if (still.carry.len == 0) {
            still.stuck_since = null;
            if (!wrote and now - still.last_write >= conf.keepalive_ns and c.queueRoom() >= streams.ping.len) {
                _ = table.queue(still.conn, streams.ping);
                still.last_write = now;
            }
            continue;
        }
        if (still.stuck_since == null or c.una != still.stuck_una or wrote) {
            still.stuck_since = now;
            still.stuck_una = c.una;
        } else if (now - still.stuck_since.? >= conf.idle_ns) {
            endStream(slot, wire, table, hub, .lagging);
        }
    }
}

/// Whether any connection is still saying goodbye.
fn closing(table: *tcp.Table) bool {
    for (table.conns) |c| {
        if (c.state == .closing) return true;
    }
    return false;
}

/// Why a stream ended, as the log says it.
const Ending = enum {
    client_left,
    no_room_to_render,
    /// Its client has not taken what it was sent. Such a stream is reset, not
    /// closed: a goodbye would queue behind everything the client is not
    /// reading.
    lagging,
    /// Its mailbox overflowed. Reset, like a lagging one.
    missed_events,
    displaced,
    stopping,

    fn why(self: Ending) []const u8 {
        return switch (self) {
            .client_left => "its client went away",
            .no_room_to_render => "there was no room to render it",
            .lagging => "its client is not keeping up",
            .missed_events => "it fell too far behind and missed events",
            .displaced => "to make room for a newer one",
            .stopping => "the machine is stopping",
        };
    }
};

fn oldestHeld(table: *tcp.Table) ?*?Held {
    var best: ?*?Held = null;
    for (&held) |*slot| {
        const h = slot.* orelse continue;
        if (best == null or table.conns[h.conn].serial < table.conns[best.?.*.?.conn].serial) best = slot;
    }
    return best;
}

/// Ends a held stream: its subscriber leaves the bus, its slot is free again,
/// and its connection is closed — without waiting. The FIN is queued behind
/// whatever the stream still had on its way, and the table finishes the close
/// on later turns (or gives up on a peer that stops answering); a closing
/// connection is not handed to anyone else meanwhile.
fn endStream(slot: *?Held, wire: *stream.Wire, table: *tcp.Table, hub: *Hub, ending: Ending) void {
    const h = slot.*.?;
    streams.drop(hub, h.kept);
    if (h.carry.len > 0) hub.gpa.free(h.carry);
    switch (ending) {
        .lagging, .missed_events => table.abandon(wire, h.conn, .stream_behind),
        else => table.finish(h.conn),
    }
    table.release(h.conn);
    slot.* = null;
    held_now -= 1;
    streams_ended += 1;
    serial.put("  stream ended: ");
    serial.put(ending.why());
    serial.put("\n");
}

/// How deep the calls have gone, said out loud the first time each new depth is
/// reached: a request that needs more stack than every request before it is
/// worth a line, and one that needs no more is not.
///
/// **A BREACHED GUARD STOPS THE MACHINE.** Past the end of the stack is `.bss`
/// -- the heaps, the virtqueues, the volume's sector buffer -- so a frame that
/// runs off the end corrupts whatever it lands on and the machine carries on
/// lying. This is the one place that can still be said clearly.
fn reportStack(deepest: usize) usize {
    const u = stack.usage();
    if (u.guard_breached) {
        serial.put("    stack: ");
        serial.putDec(u.used);
        serial.put(" of ");
        serial.putDec(u.size);
        serial.put(" bytes used\n");
        serial.fail("the stack guard was written: the next call would corrupt .bss");
    }
    if (u.used <= deepest) return deepest;
    serial.put("    stack high water: ");
    serial.putDec(u.used);
    serial.put(" of ");
    serial.putDec(u.size);
    serial.put(" bytes\n");
    return u.used;
}

/// **SAYS GOODBYE WITHOUT WAITING FOR IT TO BE HEARD.** The FIN is queued
/// behind whatever the response still has on its way, and the table finishes
/// the close on later turns: it re-sends what is not acknowledged, waits
/// `fin_wait_ns` for the peer's own FIN, and resets a peer that stops
/// answering. A closing connection is not handed to anyone else meanwhile.
///
/// **WAITING HERE WOULD STOP THE MACHINE.** It answers one request at a time,
/// so a close that waited for the peer's acknowledgement held every other
/// ready request for as long as the peer said nothing — up to the idle time,
/// once per connection, and a client that has gone quiet is exactly the one
/// that says nothing. A handshake that never completed has no FIN to wait for
/// at all, and is reset.
///
/// The FIN goes on the wire now rather than on the next turn of the network,
/// which comes after the request's log is written.
fn close(wire: *stream.Wire, table: *tcp.Table, i: usize) void {
    table.finish(i);
    if (table.conns[i].state != .closing) return table.abandon(wire, i, .unfinished);
    const now = Io.awakeNs() orelse 0;
    table.transmit(wire, now);
    if (coverage_checks) stream.checkTable(table, now, .after_transmit);
}

/// **A MACHINE WITH NOTHING TO DO HALTS**, once the network card can wake it.
/// Only a card on the PCI bus can: on mmio (QEMU's microvm, metal-vmm) nothing
/// is touched and every wait goes on spinning, as it always has.
fn restBetweenFrames(nic: *net.Net, tsc_hz: u64) void {
    if (nic.device != .pci) return;
    switch (interrupts.startApic()) {
        .refused => |why| {
            serial.put("  never resting: the local APIC refused (");
            serial.put(@tagName(why));
            serial.put(")\n");
        },
        .id => |apic| if (nic.interruptOnFrames(interrupts.msiAddress(apic), interrupts.wake_vector)) {
            interrupts.arm(tsc_hz);
            serial.put("  resting between frames: the card interrupts when one comes\n");
        } else serial.put("  never resting: the card would not take an MSI-X vector\n"),
    }
}

/// Every request the disks have served, and the time they took, so far.
fn diskWork() struct { requests: u64, ticks: u64 } {
    var requests: u64 = 0;
    var ticks: u64 = 0;
    for (disks) |d| if (d) |b| {
        requests += b.requests;
        ticks +%= b.busy_ticks;
    };
    return .{ .requests = requests, .ticks = ticks };
}

/// **THE LAST UPLOADS, AND EVERY ONE COUNTED** (metal-vmm QUEUE 189.4,
/// src/uploads_seen.zig), for /admin/host and the log.
var uploads: metal.uploads_seen.Seen = .{};
/// How many of them /admin/host shows; the log has every one.
const uploads_shown = 10;

/// Now as Unix milliseconds, if the wall clock is set.
fn wallMs() ?i64 {
    if (!Io.realTimeIsSet()) return null;
    return @intCast(@divFloor(Io.Clock.now(.real, Io.io()).nanoseconds, std.time.ns_per_ms));
}

/// An upload's answer, recorded and said under its request's line.
fn noteUpload(number: u64, drained: ?Drains.Drain, path: []const u8, kind: []const u8, status: u16, ended: []const u8, turn_ns: ?u64, disk_requests: u64, now: i96) void {
    // Refused at its head before a drain was begun: no body, no time.
    const d: Drains.Drain = drained orelse .{ .bytes = &.{}, .head_len = 0, .framing = .length, .want = 0, .most = 0, .began = now, .deadline_at = now, .last_progress = now, .whole = true, .whole_at = now, .upload = true, .charged = false };
    const u: metal.uploads_seen.Upload = .{
        .number = number,
        .unix_ms = wallMs(),
        .path = .of(path),
        .kind = .of(kind),
        .bytes = d.len - d.head_len,
        .arrival_ms = @intCast(@divTrunc(@max((if (d.cameWhole()) d.whole_at else now) - d.began, 0), std.time.ns_per_ms)),
        .turn_ms = if (turn_ns) |t| t / std.time.ns_per_ms else null,
        .disk_requests = disk_requests,
        .status = status,
        .came_whole = d.cameWhole(),
        .outcome = metal.uploads_seen.classify(status, d.cameWhole(), ended),
    };
    uploads.record(u);
    var line: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    u.write(&w) catch {}; // cut short past 512 bytes
    serial.put("    upload: ");
    serial.put(w.buffered());
    serial.put("\n");
}

/// A request's line (src/request_line.zig): its UTC time, what it was, how it
/// ended, its status and how long it took; then what memory held after it.
/// `status` 0 and `took_ns` null where no request came.
/// `at_unix_ms`: when the request came (189's minor 7: a 40-second upload
/// was stamped when it ended, and the 5xx list's time, which is when it
/// came, did not match its line).
fn logRequest(number: u64, at_unix_ms: ?i64, what: []const u8, outcome: []const u8, status: u16, took_ns: ?u64) void {
    const mem = webbox.mem_meter.snapshot();
    var line: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    metal.request_line.write(&w, .{
        .number = number,
        .unix_ms = at_unix_ms,
        .what = what,
        .outcome = outcome,
        .status = status,
        .took_ns = took_ns,
    }) catch {}; // a line past 512 bytes is cut short; what fits is said
    serial.put("  ");
    serial.put(w.buffered());
    serial.put(" (base: ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes, ");
    serial.putDec(pages.stats().bytes_taken);
    serial.put(" in pages, peak ");
    serial.putDec(pages.stats().pages_high_water * pages.page_size);
    serial.put(")\n");
}

/// **THE LOG, FOR /admin/host**: the newest `page_log_bytes` of what the
/// serial ring holds, from a whole line. Its secrets were taken out as it
/// was written (log_ring.zig's Redactor), so it is shown as it is. **THE
/// PAGE STAYS SHORT** (metal-vmm QUEUE 189.1): the ring holds 1.25 MiB, and
/// the page shows what it did before, 64 KiB; the whole ring is the text
/// view's.
const page_log_bytes = 64 * 1024;
fn metalLog(io: Io, alloc: std.mem.Allocator) anyerror!?[]const u8 {
    _ = io;
    const buf = try alloc.alloc(u8, @min(serial.ring.len(), page_log_bytes));
    const text = serial.ring.read(buf);
    // Cut short: the newest bytes begin part way through a line.
    if (text.len < serial.ring.len()) if (std.mem.indexOfScalar(u8, text, '\n')) |i| return text[i + 1 ..];
    return text;
}

/// **THE WHOLE LOG, FOR /admin/log** (metal-vmm QUEUE 189.3): the ring, all
/// 1.25 MiB of it, and the boot before this one's where the restart kept it.
fn metalLogs(io: Io, alloc: std.mem.Allocator) anyerror!?webbox.host_facts.Logs {
    _ = io;
    const now = try alloc.alloc(u8, serial.ring.len());
    var logs: webbox.host_facts.Logs = .{
        .this_boot = serial.ring.read(now),
        .capacity = serial.ring.buf.len,
        .lost = serial.ring.lost(),
        .booted_unix = if (booted_unix != 0) booted_unix else null,
        .host_commit = gm_build.commit,
    };
    if (gm_build.restart) if (metal.restarting.keptBefore()) |p| {
        const before = try alloc.alloc(u8, p.ring.len());
        logs.before = .{ .boot = p.boot, .text = p.read(before) };
    };
    return logs;
}

/// **WHAT THIS MACHINE SAYS ABOUT ITSELF**, for /admin/host: what a Linux
/// host reads from /proc, read here from this machine's own counters, clocks
/// and volumes.
/// **IDLE TIME** (src/idle.zig): the work queued for quiet moments, and a
/// check of each volume in it, the boot disk's first.
var idle_work: metal.idle.Idle = .{};

/// **BETWEEN REQUESTS** (metal-vmm QUEUE 216): the application's own work
/// (webbox's `Site.between`, a background Shale run's slice), opaque here:
/// the kernel calls it and keeps its clock, nothing more. One call after
/// each served turn, and calls on idle turns while it says there is more.
/// A request waits at most one slice, so a slice past `between_target_ns`
/// is counted, for /admin/host. 50 ms: a slice is 100,000 steps or one
/// store call (zig-webbox `script_route.slice_steps`), a few ms on this
/// machine; 50 ms is a wait a person at a page would notice, and a quarter
/// of the idle step's 200 ms budget, so an overrun is a slice gone wrong,
/// not a slow one.
const Between = struct {
    /// What the last call said: when the application next needs a turn
    /// (webbox's `site.Wake`). Before the first call, `.more`.
    wake: webbox.site.Wake = .more,
    calls: u64 = 0,
    overruns: u64 = 0,
    longest_ns: u64 = 0,
};
var between: Between = .{};
const between_target_ns: u64 = 50 * std.time.ns_per_ms;

/// One call of the application's `between`, timed.
fn betweenSlice(io: Io) void {
    const from = awakeNow();
    const unix: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    // The fetch's end is news only until between has been called with it.
    fetching.news = false;
    between.wake = app.site.between(io, .{ .awake_ns = from, .unix_s = unix });
    const took: u64 = @intCast(@max(0, awakeNow() - from));
    between.calls += 1;
    between.longest_ns = @max(between.longest_ns, took);
    if (took > between_target_ns) between.overruns += 1;
}
var volume_checks: [2]?metal.idle_check.VolumeCheck = .{ null, null };
const volume_check_names = [2][]const u8{ "the boot disk's check", "the volume's check" };

/// **THE APPLICATION'S FETCH** (webbox's `host_fetch`, DESIGN-sleep.md chunk
/// 5): one GET at a time, by the kernel's own client in the serving table.
/// `start` only records it; each turn of the main loop steps the client after
/// the network's turn (which hands the table its frames, the client its ARP,
/// and transmits). Its end is news: `between` is due at once, whatever the
/// application's wake. On-link only: a target off the lease's network is
/// `no_route` at once.
const Fetching = struct {
    client: ?metal.fetch.Client = null,
    our_ip: [4]u8 = .{ 0, 0, 0, 0 },
    our_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    mask: [4]u8 = .{ 0, 0, 0, 0 },
    /// The target's path, the client's to point at.
    path: [webbox.host_fetch.path_most]u8 = undefined,
    kept: [webbox.host_fetch.body_most]u8 = undefined,
    body_len: usize = 0,
    too_long: bool = false,
    ended: ?webbox.host_fetch.Result = null,
    /// A fetch ended and `between` has not been called since.
    news: bool = false,

    /// The client's sink: the body kept up to `body_most`, and past it, said.
    pub fn body(self: *Fetching, bytes: []const u8) void {
        const room = self.kept.len - self.body_len;
        if (bytes.len > room) self.too_long = true;
        const n = @min(room, bytes.len);
        @memcpy(self.kept[self.body_len..][0..n], bytes[0..n]);
        self.body_len += n;
    }

    fn end(self: *Fetching, outcome: webbox.host_fetch.Outcome, status: u16) void {
        self.client = null;
        self.ended = .{ .outcome = outcome, .status = status, .body = self.kept[0..self.body_len] };
        self.news = true;
    }
};
var fetching: Fetching = .{};

fn fetchStart(target: webbox.host_fetch.Target, d: webbox.host_fetch.Deadlines) webbox.host_fetch.StartError!void {
    // One at a time, and an end is handed over before the next begins.
    if (fetching.client != null or fetching.ended != null) return error.Busy;
    if (target.path.len > fetching.path.len) return error.PathTooLong;
    fetching.body_len = 0;
    fetching.too_long = false;
    // **ON-LINK ONLY**, by the lease's mask. A lease that named no network
    // (no mask) says nothing is on-link: everything is no_route, never a
    // fetch that ARPs for an address off the network until its deadline.
    if (std.mem.allEqual(u8, &fetching.mask, 0)) return fetching.end(.no_route, 0);
    for (target.ip, fetching.our_ip, fetching.mask) |a, b, m| {
        if (a & m != b & m) return fetching.end(.no_route, 0);
    }
    const n = target.path.len;
    @memcpy(fetching.path[0..n], target.path);
    const ms = std.time.ns_per_ms;
    fetching.client = metal.fetch.Client.init(
        .{ .ip = target.ip, .port = target.port, .path = fetching.path[0..n] },
        .{ .connect_ns = @as(u64, d.connect_ms) * ms, .idle_ns = @as(u64, d.idle_ms) * ms, .total_ns = @as(u64, d.total_ms) * ms },
        fetching.our_ip,
        fetching.our_mac,
        awakeNow(),
    ) catch unreachable; // the request fits: a path of at most path_most in 512 bytes
}

fn fetchResult() ?webbox.host_fetch.Result {
    const r = fetching.ended orelse return null;
    fetching.ended = null;
    return r;
}

fn fetchLearned(p: metal.arp.Packet) void {
    if (fetching.client) |*c| c.learned(p);
}

/// One step of the application's fetch, if one runs: on every turn of the
/// network (`streamTurn`), the turns inside a serve included, so a long serve
/// holds up its request and its reading no more than any connection's, and
/// its deadlines never run out on a fetch nobody stepped.
fn fetchStep(table: *tcp.Table, wire: *stream.Wire, now: i96) void {
    const c = if (fetching.client) |*c| c else return;
    // Past what is kept, the rest is not read: the connection is let go,
    // and the next step says how it ended (too_long, below).
    if (fetching.too_long) if (c.slot) |i| if (table.conns[i].state != .closed) table.abandon(wire, i, .unfinished);
    const o = c.step(table, wire, now, &fetching) orelse return;
    const status = c.answer.status;
    fetching.end(if (fetching.too_long) .too_long else hostOutcome(o), status);
}

/// The kernel's client's word, as webbox says it: every one has its twin.
fn hostOutcome(o: metal.fetch.Outcome) webbox.host_fetch.Outcome {
    comptime for (std.enums.values(metal.fetch.Outcome)) |k| {
        if (!@hasField(webbox.host_fetch.Outcome, @tagName(k))) @compileError("webbox's host_fetch has no outcome " ++ @tagName(k));
    };
    return switch (o) {
        inline else => |k| @field(webbox.host_fetch.Outcome, @tagName(k)),
    };
}

/// An application's line (webbox's `host_facts.say`), on the console with
/// the machine's own, so in the kept log and /admin/log too.
fn metalSay(line: []const u8) void {
    serial.put("  ");
    serial.put(line);
    serial.put("\n");
}

fn awakeNow() i96 {
    return Io.awakeNs() orelse 0;
}

/// **THE QUIESCENT MACHINE SLEEPS** (docs/designs/DESIGN-sleep.md, phase 1):
/// nothing in motion, so only the application's wake can be due, and the
/// machine halts until it, at most `longest_ns`. Otherwise a slice, as it
/// always has. Coverage kernels count quiescence a second way, from the
/// arrays rather than the counters, at every sleep.
fn restOrSleep(table: *const tcp.Table, now: i96, longest_ns: u64) void {
    // A machine that cannot halt (the APIC refused, or mmio) pauses, as it
    // always has, and nothing it does is a sleep.
    if (!interrupts.armed()) return interrupts.rest();
    longest_rest_ms_now = longest_ns / std.time.ns_per_ms;
    const facts: metal.sleep.Facts = .{
        .conns_in_use = table.inUse(),
        .held = held_now,
        .draining = draining_now,
        .drains_holding = drainsHolding(),
        .console_pending = serial.pending(),
        .fetching = fetching.client != null,
        .wants_more = between.wake == .more,
    };
    const still = metal.sleep.quiescent(facts);
    switch (Sleep.next(now, still, between.wake, idle_work.gateAt(), interrupts.slice_ns, longest_ns)) {
        .turn => {},
        .until => |u| if (u.by == .slice) interrupts.rest() else {
            // **NOTHING UNFLUSHED SLEEPS**: what `between` wrote has no
            // response behind it, but every turn of the network flushes
            // (`streamTurn`'s `serviceStreams`, `Io.durable`), and the loop
            // turns after every `between` before it rests.
            if (coverage_checks) {
                checkQuiescence();
                metal.coverage.always(@src(), !Io.unflushed(), "sleep: nothing unflushed when the machine sleeps", null);
            }
            const ended = interrupts.restUntil(Io.tscAt(u.at));
            sleeps.slept(u.by, ended);
        },
    }
}

/// The application's wake, decided over webbox's `Wake`.
const Sleep = metal.sleep.Over(webbox.site.Wake);
var sleeps: metal.sleep.Sleeps = .{};
/// The longest rest in force, for /admin/host.
var longest_rest_ms_now: u64 = default_longest_rest_ms;
pub const default_longest_rest_ms = 10_000;

fn drainsHolding() usize {
    var n: usize = 0;
    for (&drains.waits) |*w| {
        if (w.holds()) n += 1;
    }
    return n;
}

/// **QUIESCENCE, COUNTED A SECOND WAY** (a cold review of DESIGN-sleep.md):
/// the held streams and the draining responses from their arrays, where
/// the predicate read their counters. Two computations of one fact.
fn checkQuiescence() void {
    var held_seen: usize = 0;
    for (held) |h| {
        if (h != null) held_seen += 1;
    }
    var draining_seen: usize = 0;
    for (draining) |d| {
        if (d != null) draining_seen += 1;
    }
    metal.coverage.always(@src(), held_seen == 0 and draining_seen == 0, "sleep: a quiescent machine holds no stream and drains no response, by the arrays as by the counters", .{ .held = held_seen, .draining = draining_seen });
}

/// A volume's idle check, as /admin/host says it.
fn checkFact(alloc: std.mem.Allocator, c: *const metal.idle_check.VolumeCheck) ![]const u8 {
    const hs = webbox.host_facts;
    const last = if (c.last) |l| blk: {
        const ago: i64 = @intCast(@divFloor(awakeNow() - l.at, std.time.ns_per_s));
        const damage = if (l.tally.first) |f|
            try std.fmt.allocPrint(alloc, "{d} damaged, the first {s} at cluster {d}", .{ l.tally.damage, @tagName(f.problem), f.cluster })
        else
            "no damage";
        break :blk try std.fmt.allocPrint(alloc, "last finished {s} ago: {d} files, {d} folders, {s}, {d} clusters leaked, {d} problems in all", .{
            try hs.duration(alloc, ago), l.health.files, l.health.directories, damage, l.health.leaked, l.health.problems,
        });
    } else "not finished yet";
    return std.fmt.allocPrint(alloc, "{s}; {d} finished, {d} started again (a write under it), {d} ended by a read that failed; {d} steps, the longest {d} ms", .{
        last, c.finished, c.restarts, c.failed, c.task.steps, c.task.longest_ns / std.time.ns_per_ms,
    });
}

/// The restart record this boot found, if it was a restart (198.3).
var restart_record: ?metal.restart.Record = null;

fn metalFacts(io: Io, alloc: std.mem.Allocator) anyerror![]const webbox.host_facts.Fact {
    const hs = webbox.host_facts;
    var facts: std.ArrayList(hs.Fact) = .empty;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const add = struct {
        fn f(list: *std.ArrayList(hs.Fact), a: std.mem.Allocator, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try list.append(a, .{ .label = label, .value = try std.fmt.allocPrint(a, fmt, args) });
        }
    }.f;
    try add(&facts, alloc, "host", "zig-metal-unikernel, with no operating system", .{});
    try add(&facts, alloc, "zig-metal-unikernel commit", "{s}", .{gm_build.commit});
    try add(&facts, alloc, "booted", "{s}", .{try hs.utc(alloc, booted_unix)});
    try add(&facts, alloc, "up for", "{s}", .{try hs.duration(alloc, now - booted_unix)});
    // **WHY THIS BOOT** (198.3): a restart says what ended the boot before.
    if (gm_build.restart) try add(&facts, alloc, "restarted", "{s}", .{if (restart_record) |r|
        try std.fmt.allocPrint(alloc, "yes, after {s} (restart {d} in a row{s}{s}); the boot before's log is the end of /admin/log", .{
            r.reason.text(),                   r.count,
            if (r.at != null) ", at " else "", if (r.at) |m| try hs.utc(alloc, metal.restart.unixOfMinutes(m)) else "",
        })
    else
        "no: this boot was not a restart"});
    try add(&facts, alloc, "its clock now", "{s} (set from the hardware clock at boot, never corrected)", .{try hs.utc(alloc, now)});
    try add(&facts, alloc, "processor", "TSC at {d} MHz; {s}", .{
        tsc_hz_seen / 1_000_000,
        if (interrupts.armed()) "rests between frames" else "never rests (polls)",
    });
    // **THE LEASE IS NEVER RENEWED** (193, gap 12): its length, and
    // whether the machine has run past it.
    if (lease_held) |l| try add(&facts, alloc, "address", "{d}.{d}.{d}.{d} from DHCP, never renewed; {s}", .{
        l.address[0], l.address[1], l.address[2], l.address[3],
        if (l.seconds) |lent|
            if (now - booted_unix > lent)
                try std.fmt.allocPrint(alloc, "lent for {s}, and the machine has run PAST ITS LEASE", .{try hs.duration(alloc, lent)})
            else
                try std.fmt.allocPrint(alloc, "lent for {s}", .{try hs.duration(alloc, lent)})
        else
            "the server did not say for how long",
    });
    try add(&facts, alloc, "requests served", "{d}", .{served});
    try add(&facts, alloc, "connections", "{d} open now, {d} at most, of {d}", .{ open_now, busiest, max_connections });
    if (serving_table) |t| {
        var counts: std.Io.Writer.Allocating = .init(alloc);
        try tcp.writeCounts(t, &counts.writer);
        try facts.append(alloc, .{ .label = "tcp since boot", .value = counts.written() });
        // **FRAMES PASSED OVER** (193, gap 8), by why.
        var passed: std.Io.Writer.Allocating = .init(alloc);
        try t.passed.write(&passed.writer);
        try facts.append(alloc, .{ .label = "frames passed over", .value = passed.written() });
    }
    try add(&facts, alloc, "streams", "{d} held now, {d} at most, {d} ended", .{ held_now, held_most, streams_ended });
    const p = pages.stats();
    try add(&facts, alloc, "memory (pages)", "{d} MB taken now, {d} MB at most, of {d} MB", .{
        p.bytes_taken >> 20, (p.pages_high_water * pages.page_size) >> 20, p.bytes_total >> 20,
    });
    // **UPLOADS** (189.4): every one counted by its answer, then the newest.
    {
        var counts: std.Io.Writer.Allocating = .init(alloc);
        try uploads.writeCounts(&counts.writer);
        try facts.append(alloc, .{ .label = "uploads", .value = counts.written() });
        var k: usize = 0;
        while (uploads.newest(k)) |u| : (k += 1) {
            if (k == uploads_shown) break;
            var one: std.Io.Writer.Allocating = .init(alloc);
            try u.write(&one.writer);
            try facts.append(alloc, .{ .label = if (k == 0) "an upload, the newest first" else "", .value = one.written() });
        }
    }
    if (Io.siteVolume()) |v| try addVolume(&facts, alloc, "the boot disk (the site)", "the boot disk's write cache", "the boot disk's folders in memory", "the boot disk at boot", v);
    if (Io.dataVolume()) |v| {
        try addVolume(&facts, alloc, "the volume (" ++ app.hosting.data_name ++ ")", "the volume's write cache", "the volume's folders in memory", "the volume at boot", v);
    } else try add(&facts, alloc, "the volume (" ++ app.hosting.data_name ++ ")", "none attached: the data is on the boot disk", .{});
    const kept = Io.siteCache();
    try add(&facts, alloc, "site files in memory", "{d} kept, {d} KB of {d} KB; {d} reads answered from them", .{
        kept.count, kept.used >> 10, @as(usize, Io.SiteCache.capacity) >> 10, kept.hits,
    });
    if (Io.pageCache()) |pc| {
        try add(&facts, alloc, "data files in memory", "{d} kept, {d} MB of {d} MB, files up to {d} KiB; {d} reads answered from them, {d} from the disk; {d} pushed out", .{
            pc.count, pc.held >> 20, pc.budget >> 20, pc.largest >> 10, pc.hits, pc.misses, pc.evicted,
        });
    } else try add(&facts, alloc, "data files in memory", "none (page_cache_mib = 0)", .{});
    try add(&facts, alloc, "idle time", "{d} steps in quiet moments, {d} over the {d} ms budget", .{
        idle_work.steps, idle_work.overruns, idle_work.budget_ns / std.time.ns_per_ms,
    });
    try add(&facts, alloc, "between requests", "{d} calls of the application's work, {d} over the {d} ms target, the longest {d} ms", .{
        between.calls, between.overruns, between_target_ns / std.time.ns_per_ms, between.longest_ns / std.time.ns_per_ms,
    });
    for (&volume_checks, volume_check_names) |*maybe, name| {
        if (maybe.*) |*c| try facts.append(alloc, .{ .label = name, .value = try checkFact(alloc, c) });
    }
    const work = diskWork();
    try add(&facts, alloc, "disk requests", "{d}, busy {d} ms in all", .{ work.requests, @divTrunc(Io.ticksToNs(work.ticks), std.time.ns_per_ms) });
    // **THE MOST ONE REQUEST CARRIES**, each disk's (metal-vmm QUEUE 178): 1
    // MiB unless the device said less, which it is obeyed in.
    try add(&facts, alloc, "disk request most", "boot {d} KiB, volume {d} KiB (the volume's own: {s})", .{
        if (disks[0]) |d| d.most_sectors / 2 else 0,
        if (disks[1]) |d| d.most_sectors / 2 else 0,
        if (disks[1]) |d| if (d.disk_most_sectors) |m| try std.fmt.allocPrint(alloc, "{d} KiB", .{m / 2}) else "not said" else "no volume",
    });
    try add(&facts, alloc, "NMIs", "{d}", .{interrupts.nmis});
    // **WAKES** (193, gap 11): a device that interrupts endlessly shows as
    // wakes by a device far past the frames that came.
    if (interrupts.armed()) try add(&facts, alloc, "rests", "{d}, {d} of them ended by a device, {d} by neither the timer nor the card", .{ interrupts.rests.rests, interrupts.rests.woken_by_device, interrupts.rests.woken_by_other });
    // **SLEEPS** (sleep.zig): the quiescent machine's long rests, and a wake
    // that came without its interrupt.
    if (interrupts.armed()) try add(&facts, alloc, "sleeps", "{d} while quiescent, {d} ended by a device, {d} by the longest rest ({d} ms), {d} by neither the timer nor the card, {d} missed wakes (a frame waiting after the timer ended one)", .{
        sleeps.sleeps, sleeps.by_device, sleeps.by_longest, longest_rest_ms_now, sleeps.by_other, sleeps.missed,
    });
    if (turning) |t| try add(&facts, alloc, "frames refused (too long to send)", "{d}", .{t.wire.nic.oversized});
    // **A RESPONSE CUT OFF BEHIND ITS SPILL** (198.1): the connection went
    // while part of the response still waited to be sent.
    try add(&facts, alloc, "responses cut off (connection gone, rest unsent)", "{d}", .{stream.gone_behind_spill});
    // **A CARD THAT STOPPED TAKING FRAMES** (193.2): sends that waited out
    // their budget, the card asking for a reset, and frames dropped since.
    if (turning) |t| try add(&facts, alloc, "network card stalls", "{d} sends waited out their second, {d} times the card asked for a reset, {d} frames dropped while it took none back{s}", .{
        t.wire.nic.send_stalls, t.wire.nic.reset_asked, t.wire.nic.dropped_stalled, if (t.wire.nic.stalled) "; STALLED NOW" else "",
    });
    // **THE CARD'S RING** (193.5): entries no sound card makes.
    if (turning) |t| try add(&facts, alloc, "network card ring", "{d} received into a buffer never offered, {d} with a length no frame has, {d} send completions for a buffer not lent", .{
        t.wire.nic.rx_strange_ids, t.wire.nic.rx_bad_lengths, t.wire.nic.tx_strange_completions,
    });
    return facts.items;
}

/// What the host status page calls a volume: it said FAT16 of every one,
/// and metal's volume is FAT32.
/// **K AND P ARE CEILINGS** (metal-vmm 148(a)): what the volume counted
/// exactly plus what may be live (`unsure_*`), so the judge's "fsck finds no
/// more than K" holds; how much of each may be live is said after.
fn leakLine(what: []const u8, v: *const disk_fat.Volume) void {
    serial.put("  ");
    serial.put(what);
    serial.put(": ");
    serial.putDec(v.leaked_clusters +| v.unsure_clusters);
    serial.put(" clusters left a counted leak, ");
    serial.putDec(v.orphaned_parts +| v.unsure_parts);
    serial.put(" long-name parts left orphaned in ");
    // R, the names: fsck.fat says a line a run (metal-vmm 152).
    serial.putDec(v.orphaned_runs +| v.unsure_runs);
    serial.put(" runs, ");
    serial.putDec(v.fat_copies_failed);
    serial.put(" FAT copy writes failed; of the clusters and parts, ");
    serial.putDec(v.unsure_clusters);
    serial.put(" and ");
    serial.putDec(v.unsure_parts);
    serial.put(" may be live, and ");
    // W and Y, apart (metal-vmm 154(c)): the floors are R - W and L - Y.
    serial.putDec(v.unsure_runs);
    serial.put(" of the runs; ");
    serial.putDec(v.unsized_leaks);
    serial.put(" leaks of a size not known (K no ceiling while any); ");
    serial.putDec(v.long_clusters +| v.unsure_long);
    serial.put(" clusters past a size, ");
    serial.putDec(v.unsure_long);
    serial.put(" of them may be live (");
    serial.putDec(v.cleanups_failed);
    serial.put(" cleanups failed)\n");
}

fn kindName(v: *const disk_fat.Volume) []const u8 {
    return if (v.kind == .fat32) "FAT32" else "FAT16";
}

fn addVolume(facts: *std.ArrayList(webbox.host_facts.Fact), alloc: std.mem.Allocator, label: []const u8, cache_label: []const u8, dirs_label: []const u8, boot_label: []const u8, v: *disk_fat.Volume) !void {
    var serial_text: [9]u8 = undefined;
    const named = if (v.serial) |n| serialText(&serial_text, n) else "no serial";
    const value = if (v.space()) |sp|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: {d} MB free of {d} MB, {d} MB of it kept for small writes; {d} cleanups after a commit failed (leaks, {d} clusters counted, {d} more may be live; {d} long names left orphaned, {d} more may be), {d} FAT copy writes failed (copies apart); {d} sector reads failed, {d} sector writes failed", .{
            kindName(v),                                                      named,             sp.free >> 20,       sp.total >> 20,
            @as(u64, v.reserve_clusters) * v.sectors_per_cluster * 512 >> 20, v.cleanups_failed, v.leaked_clusters,   v.unsure_clusters,
            v.orphaned_runs,                                                  v.unsure_runs,     v.fat_copies_failed, v.read_failures,
            v.write_failures,
        })
    else |e|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: free space unreadable ({s})", .{ kindName(v), named, @errorName(e) });
    try facts.append(alloc, .{ .label = label, .value = value });
    // **WHAT THE BOOT FOUND** (193, gap 10): once only boot log lines.
    {
        var boot: std.Io.Writer.Allocating = .init(alloc);
        try metal.boot_facts.write(&boot.writer, v.blk.reads_retried, v.mounted);
        try facts.append(alloc, .{ .label = boot_label, .value = boot.written() });
    }
    // **A VOLUME THAT REFUSES WRITES SAYS SO** (metal-vmm QUEUE 188.2).
    if (v.writes == .refused or v.reweighs > 0) try facts.append(alloc, .{
        .label = "writes",
        .value = try std.fmt.allocPrint(alloc, "{s}; the FAT's copies weighed again {d} times, {d} failed; {d} sector writes turned away while refused", .{
            if (v.writes == .refused) "REFUSED: the FAT's copies differ and could not be weighed; reads are served, and the weighing is tried again once a minute" else "taken: a weighing succeeded",
            v.reweighs,
            v.reweighs_failed,
            v.writes_turned_away,
        }),
    });
    // **WHETHER A SAVE IS DURABLE BEFORE IT IS ANSWERED** (io.durable): what
    // the disk says of its write cache, and the flushes sent to it.
    const cache: []const u8 = switch (metal.scsi_mode.report(v.blk.write_cache, v.blk.cache_on_at_bringup)) {
        .would_not_turn_off => "on, and it would not turn off: writes wait in it until flushed, and a power cut can damage the filesystem",
        .turned_off => "turned off at boot: it writes through",
        .caches => "on: writes wait in it until flushed",
        .writes_through => "off: it writes through",
        .unknown => "not said: flushed as if on",
    };
    try facts.append(alloc, .{
        .label = cache_label,
        .value = try std.fmt.allocPrint(alloc, "{s}; {d} flushes, {d} of them SYNCHRONIZE CACHE sent{s}, {d} failed; looked at again after {d} resets; {s}; what its failed requests ended with (193.3): {s}", .{
            cache, v.blk.flushes, v.blk.synchronizes_sent, if (v.blk.synchronize_unknown) " (the disk did not know the command, and is treated as writing through)" else "", v.blk.flush_failures, v.blk.cache_rechecks,
            // **A DISK THAT STOPPED ANSWERING** (193.2).
            switch (v.blk.ended) {
                .serving => "answering",
                .timed_out => try std.fmt.allocPrint(alloc, "STOPPED ANSWERING: a request went 30 s unanswered; {d} requests refused since", .{v.blk.refused_after_end}),
                .needs_reset => try std.fmt.allocPrint(alloc, "STOPPED ANSWERING: it asked for a reset; {d} requests refused since", .{v.blk.refused_after_end}),
            },
            blk: {
                var failed: std.Io.Writer.Allocating = .init(alloc);
                try v.blk.failures.write(&failed.writer);
                break :blk failed.written();
            },
        }),
    });
    if (v.dirs) |d| try facts.append(alloc, .{
        .label = dirs_label,
        .value = try std.fmt.allocPrint(alloc, "{d} sectors held at most; {d} sector reads answered from it, {d} from the disk (every sector read asks it, folders or not)", .{ d.keys.len, d.hits, d.misses }),
    });
}

var trusted_proxy_text: [15]u8 = undefined;

/// `203.0.113.7`, into `buf`.
fn ipText(buf: *[15]u8, ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
}

fn putSerial(serial_number: ?u32) void {
    const n = serial_number orelse return serial.put("none");
    var text: [9]u8 = undefined;
    serial.put(serialText(&text, n));
}

const serialText = metal.config_text.serialText;

/// The wall clock in Unix seconds, or null before it is set: for the restart
/// record, which must not panic asking.
fn wallNow() ?i64 {
    if (!Io.realTimeIsSet()) return null;
    return @intCast(@divFloor(Io.Clock.now(.real, Io.io()).nanoseconds, std.time.ns_per_s));
}

/// The restart's back-off: a busy wait on the TSC, before anything serves.
fn waitSeconds(s: u32) void {
    const until = Io.awakeNs().? + @as(i96, s) * std.time.ns_per_s;
    while (Io.awakeNs().? < until) asm volatile ("pause");
    serial.put("  waited ");
    serial.putDec(s);
    serial.put(" s; serving\n");
}

pub const panic = metal.serial.panic;
