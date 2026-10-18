//! **THE APPEND.** Every write `angry-gopher` makes that is not a whole file is
//! this, and it is always spelled the same way:
//!
//!     var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
//!     defer file.close(io);
//!     const st = try file.stat(io);
//!     try file.writePositionalAll(io, bytes, st.size);
//!
//! — a chat message, a game action, an uploaded chunk, a puzzle move. So this
//! probe writes through exactly that, not through `disk_fat` underneath it.
//!
//! **THE CASES ARE THE ONES THAT CAN ACTUALLY BREAK**, and each is a different
//! path through disk_fat.writeInto:
//!
//!   log.txt     600 fixed-width lines, appended one at a time. At 2 KB per
//!               cluster that is fourteen clusters, so the chain is extended
//!               thirteen times rather than once — and the probe ASSERTS that,
//!               because the first version of it wrote 1,692 bytes, fitted in a
//!               single cluster, and passed with the extension deleted.
//!   small.txt   Three appends of 1, 2 and 3 bytes. All inside one sector, so
//!               each write must READ that sector before writing it — a write
//!               that skipped the read would erase back to the boundary and
//!               leave "ccc" where "abbccc" belongs. This is the case a
//!               whole-sector writer passes every other test and fails.
//!   over.txt    An overwrite INSIDE the file: offset 3 of a 10-byte file. The
//!               bytes change, the size does not.
//!   (a hole)    offset past the end must be REFUSED. FAT has no sparse files,
//!               so the gap would be whatever those clusters last held, and
//!               answering with stale bytes is worse than failing.
//!
//! **THE VERDICT IS NOT THIS PROBE'S.** `probe/run.sh` hands the volume to
//! `fsck.vfat` and then mounts it with the Linux kernel's own VFAT driver and
//! regenerates the expected 600 lines in shell. Agreeing with our own reader
//! would prove very little — a size field and a cluster chain that disagree can
//! read back perfectly through the code that wrote them.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const gpt = metal.gpt;
const disk_fat = metal.disk_fat;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var scratch: [disk_fat.sector_size]u8 align(4096) = undefined;
var heap: [1024 * 1024]u8 align(16) = undefined;
var line_buf: [64]u8 = undefined;
var expect: [64 * 1024]u8 = undefined;

/// 600 lines of 45 bytes is 27,000 — thirteen 2 KB clusters. Fixed width so the
/// oracle in run.sh can regenerate it with one `seq`.
const lines = 600;

/// append is the application's own three lines, verbatim.
fn append(io: anytype, path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel append probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    // **THIS PROBE TESTS RUNS SPLIT ACROSS REQUESTS** (a FAT read in pieces,
    // a file longer than one request): its disk's requests are held to 64 KiB,
    // what they were before metal-vmm QUEUE 178 made them 1 MiB, so its small
    // volume still splits them.
    blk.most_sectors = @min(blk.most_sectors, 128); // never more than the device said (180.3)
    var vol = disk_fat.Volume.mount(&blk, &scratch, 0) catch
        serial.fail("this is not the FAT16 volume the probe expects");
    Io.mount(vol);

    // **THE CLOCK, BECAUSE A FILE HAS A DATE.** Every entry this probe writes
    // is stamped with the wall clock, and run.sh asks the Linux VFAT driver
    // what time IT thinks those files were written — an outside reading of our
    // own encoding. Without a clock the entries would carry no date, which is
    // honest but proves nothing.
    const clock = metal.wallclock.start() catch |e| {
        serial.put("  wallclock: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the clocks would not come up");
    };
    serial.put("  wall clock ");
    serial.putDec(@intCast(clock.unix));
    serial.put("\n");

    const io = Io.io();
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const alloc = fba.allocator();

    // ── the partial-sector case, first, because it is the subtle one ────────
    append(io, "small.txt", "a") catch serial.fail("the first append to a new file failed");
    append(io, "small.txt", "bb") catch serial.fail("the second append failed");
    append(io, "small.txt", "ccc") catch serial.fail("the third append failed");
    const small = Io.Dir.cwd().readFileAlloc(io, "small.txt", alloc, .limited(64)) catch
        serial.fail("small.txt would not read back");
    if (!eql(small, "abbccc")) {
        serial.put("  small.txt reads [");
        serial.put(small);
        serial.put("] and should read [abbccc]\n");
        serial.fail("an append inside a sector erased what was already there");
    }
    serial.put("  small.txt: three appends inside one sector -> abbccc\n");

    // ── an overwrite inside the file: bytes change, size does not ───────────
    append(io, "over.txt", "0123456789") catch serial.fail("over.txt would not be written");
    {
        var file = Io.Dir.cwd().createFile(io, "over.txt", .{ .truncate = false }) catch
            serial.fail("over.txt would not open");
        file.writePositionalAll(io, "XYZ", 3) catch serial.fail("the overwrite failed");
    }
    const over = Io.Dir.cwd().readFileAlloc(io, "over.txt", alloc, .limited(64)) catch
        serial.fail("over.txt would not read back");
    if (!eql(over, "012XYZ6789")) {
        serial.put("  over.txt reads [");
        serial.put(over);
        serial.put("] and should read [012XYZ6789]\n");
        serial.fail("an overwrite inside the file wrote the wrong bytes");
    }
    serial.put("  over.txt: overwrite at 3 -> 012XYZ6789, size still 10\n");

    // ── a hole must be refused ─────────────────────────────────────────────
    {
        var file = Io.Dir.cwd().createFile(io, "over.txt", .{ .truncate = false }) catch
            serial.fail("over.txt would not open");
        if (file.writePositionalAll(io, "!", 999)) |_| {
            serial.fail("a write past the end was ACCEPTED: that leaves a hole of stale bytes");
        } else |_| {}
    }
    serial.put("  over.txt: a write past the end is refused\n");

    // ── an overwrite from a sector boundary to part-way through a later one ──
    // The file goes on past the write, so the bytes after it in its last
    // sector belong to the file and must survive. An overwrite that starts
    // mid-sector never reaches that sector, which is why over.txt above could
    // not tell a writer that zeroed them from one that kept them.
    appendPattern(io, "mid.txt", 0x55, 0, 2000);
    {
        var file = Io.Dir.cwd().createFile(io, "mid.txt", .{ .truncate = false }) catch
            serial.fail("mid.txt would not open");
        var patch: [700]u8 = undefined;
        @memset(&patch, 'M');
        file.writePositionalAll(io, &patch, 512) catch serial.fail("the mid-file overwrite failed");
    }
    const mid = Io.Dir.cwd().readFileAlloc(io, "mid.txt", alloc, .limited(4096)) catch
        serial.fail("mid.txt would not read back");
    if (mid.len != 2000) serial.fail("the mid-file overwrite changed the file's length");
    for (mid, 0..) |b, i| {
        const want: u8 = if (i >= 512 and i < 1212) 'M' else patternByte(0x55, i);
        if (b != want) {
            serial.put("  mid.txt byte ");
            serial.putDec(i);
            serial.put(" is wrong\n");
            serial.fail("an overwrite inside a file lost the bytes after it in its last sector");
        }
    }
    serial.put("  mid.txt: bytes 512-1211 overwritten, everything around them kept\n");

    // ── the chain-extending case: 600 lines, appended one at a time ─────────
    var want: usize = 0;
    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const line = std.fmt.bufPrint(&line_buf, "line {d:0>4} aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", .{i}) catch
            serial.fail("could not format a line");
        append(io, "log.txt", line) catch {
            serial.put("  failed at line ");
            serial.putDec(i);
            serial.put("\n");
            serial.fail("an append failed part way through the log");
        };
        @memcpy(expect[want..][0..line.len], line);
        want += line.len;
    }

    const log = Io.Dir.cwd().readFileAlloc(io, "log.txt", alloc, .limited(expect.len)) catch
        serial.fail("log.txt would not read back");
    if (log.len != want) {
        serial.put("  log.txt is ");
        serial.putDec(log.len);
        serial.put(" bytes and should be ");
        serial.putDec(want);
        serial.put("\n");
        serial.fail("the appended log is the wrong length");
    }
    if (!eql(log, expect[0..want])) serial.fail("the appended log has the wrong bytes");

    // **THE PROBE CHECKS ITS OWN COVERAGE.** Spanning several clusters is the
    // whole point of this case, and it is a property of the line count AND the
    // volume's geometry — neither of which this file controls. Deleting the
    // chain extension from disk_fat.writeInto must fail here; when the log fitted
    // in one cluster it did not.
    const cluster_bytes: usize = vol.sectors_per_cluster * disk_fat.sector_size;
    const spanned = (want + cluster_bytes - 1) / cluster_bytes;
    if (spanned < 3) {
        serial.put("  the log spans only ");
        serial.putDec(spanned);
        serial.put(" cluster(s)\n");
        serial.fail("this probe is no longer testing chain extension: make the log longer");
    }
    serial.put("  log.txt: ");
    serial.putDec(lines);
    serial.put(" appends -> ");
    serial.putDec(want);
    serial.put(" bytes, over ");
    serial.putDec(spanned);
    serial.put(" clusters\n");

    // ── and the directories the application makes before every write ───────
    Io.Dir.cwd().createDirPath(io, "data/lynrummy/p1/lynrummy-elm/sessions/1") catch
        serial.fail("createDirPath failed");
    append(io, "data/lynrummy/p1/lynrummy-elm/sessions/1/actions.dsl", "1) draw\n") catch
        serial.fail("the first write into a fresh tree failed");
    append(io, "data/lynrummy/p1/lynrummy-elm/sessions/1/actions.dsl", "2) meld\n") catch
        serial.fail("the second write into a fresh tree failed");
    serial.put("  createDirPath: five levels, then two appends into it\n");

    readWindows(io);
    readSweep(io, &vol);
    readThroughCachedFat(&vol);
    createDefaults(io, alloc);

    serial.pass();
}

/// A byte that is a function of its position in a file and of which file it
/// is: so no two files, and no two places in one file, look alike — a read
/// from the wrong cluster cannot pass by accident.
fn patternByte(seed: u8, pos: usize) u8 {
    return @as(u8, @truncate((pos *% 2654435761) >> 13)) ^ seed;
}

fn appendPattern(io: anytype, path: []const u8, seed: u8, from: usize, len: usize) void {
    var chunk: [16 * 1024]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const n = @min(chunk.len, len - done);
        for (chunk[0..n], 0..) |*b, i| b.* = patternByte(seed, from + done + i);
        append(io, path, chunk[0..n]) catch serial.fail("an append for the read sweep failed");
        done += n;
    }
}

var sweep_buf: [128 * 1024]u8 = undefined;
/// 1 MiB: FAT16's FAT here is 130 KB, and FAT32's (FAT=32 in probe/run.sh,
/// 81,000 clusters of 4 bytes) about 320 KB.
var fat_cache: [1024 * 1024]u8 align(4096) = undefined;

/// **THE FAT IN MEMORY, ON A FAT TOO BIG FOR ONE REQUEST.** On this volume's
/// 512-byte clusters the FAT is 130 KB, so reading it in takes more than one
/// device request — the only path that splits a read, since a file read never
/// asks for more than one request's worth at a time. cacheFat compares what it
/// read against the second FAT sector by sector, so a split that put its pieces
/// in the wrong place fails there. Then the sweep files are read again through
/// the cached FAT, which must answer exactly as the one on disk did.
fn readThroughCachedFat(vol: *disk_fat.Volume) void {
    const fat_sectors = vol.fatBytes() / disk_fat.sector_size;
    if (fat_sectors <= vol.blk.most_sectors) {
        serial.put("  the FAT is only ");
        serial.putDec(fat_sectors);
        serial.put(" sectors\n");
        serial.fail("this volume no longer tests a FAT read split across requests: use smaller clusters");
    }
    const repaired = vol.cacheFat(&fat_cache) catch |e| {
        serial.put("  fat cache: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("a FAT larger than one request could not be read into memory");
    };
    if (repaired != 0) serial.fail("the FAT read in pieces is not the second FAT: a split read put a piece in the wrong place");
    Io.mount(vol.*);

    const entry = vol.open("big.txt") catch serial.fail("big.txt is gone");
    const n = vol.readAt(entry, 0, sweep_buf[0 .. 100 * 1024]) catch
        serial.fail("big.txt would not read through the cached FAT");
    if (n != 100 * 1024) serial.fail("big.txt read short through the cached FAT");
    for (sweep_buf[0..n], 0..) |b, i| {
        if (b != patternByte(0x33, i)) serial.fail("big.txt read wrong through the cached FAT");
    }
    const frag = vol.open("frag.txt") catch serial.fail("frag.txt is gone");
    const m = vol.readAt(frag, 0, sweep_buf[0..60000]) catch
        serial.fail("frag.txt would not read through the cached FAT");
    for (sweep_buf[0..m], 0..) |b, i| {
        if (b != patternByte(0x11, i)) serial.fail("frag.txt read wrong through the cached FAT");
    }
    serial.put("  a ");
    serial.putDec(fat_sectors);
    serial.put("-sector FAT held in memory, and both sweep files read back through it\n");
}

/// **EVERY WAY A READ CAN START AND END.** disk_fat.readAt reads a file as runs of
/// consecutive clusters: whole sectors straight into the caller's buffer, one
/// request per run, and only a sector the read starts or ends inside through the
/// scratch sector. So its paths are: a partial first sector, whole sectors, a
/// partial last sector, a break in the chain, and a run longer than one request
/// may carry. Two files are built to have all of those, and the probe checks
/// that they do before trusting what it reads from them:
///
///   frag.txt  60 KB, grown in turns with wedge.txt, so their clusters
///             interleave and frag.txt's chain breaks over and over.
///   big.txt   100 KB, grown alone, so it is one long run — longer than the
///             64 KB a single request may carry.
///
/// Fifteen offsets against eleven lengths, on each: sector edges, cluster
/// edges, the middle, the last bytes, and lengths past the end.
fn readSweep(io: anytype, vol: *disk_fat.Volume) void {
    var round: usize = 0;
    while (round < 40) : (round += 1) {
        appendPattern(io, "frag.txt", 0x11, round * 1500, 1500);
        appendPattern(io, "wedge.txt", 0x77, round * 1500, 1500);
    }
    appendPattern(io, "big.txt", 0x33, 0, 100 * 1024);

    const Case = struct { path: []const u8, seed: u8, size: usize, min_runs: u32, min_longest: u32 };
    const max_run = vol.blk.most_sectors / vol.sectors_per_cluster;
    const cases = [_]Case{
        .{ .path = "frag.txt", .seed = 0x11, .size = 60000, .min_runs = 8, .min_longest = 1 },
        .{ .path = "big.txt", .seed = 0x33, .size = 100 * 1024, .min_runs = 1, .min_longest = max_run + 1 },
    };

    var reads: usize = 0;
    for (cases) |c| {
        const entry = vol.open(c.path) catch serial.fail("a sweep file is missing");
        const shape = vol.layout(entry) catch serial.fail("a sweep file's chain is broken");
        serial.put("  ");
        serial.put(c.path);
        serial.put(": ");
        serial.putDec(shape.clusters);
        serial.put(" clusters in ");
        serial.putDec(shape.runs);
        serial.put(" run(s), the longest ");
        serial.putDec(shape.longest);
        serial.put("\n");
        if (shape.runs < c.min_runs)
            serial.fail("the fragmented file is not fragmented enough to test a break in a run");
        if (shape.longest < c.min_longest)
            serial.fail("the long file has no run longer than one request can carry");

        const size = c.size;
        const offsets = [_]usize{ 0, 1, 511, 512, 513, 2047, 2048, 2049, 4095, 4096, 4097, size / 2, size - 2049, size - 513, size - 1 };
        const lengths = [_]usize{ 1, 2, 511, 512, 513, 2047, 2048, 2049, 4096, 70000, size };
        var file = Io.Dir.cwd().openFile(io, c.path, .{}) catch serial.fail("a sweep file would not open");
        for (offsets) |off| {
            for (lengths) |len| {
                const n = file.readPositionalAll(io, sweep_buf[0..len], off) catch
                    serial.fail("a positional read in the sweep failed");
                const expected = @min(len, size - off);
                if (n != expected) {
                    serial.put("  ");
                    serial.put(c.path);
                    serial.put(" at ");
                    serial.putDec(off);
                    serial.put(" for ");
                    serial.putDec(len);
                    serial.put(": ");
                    serial.putDec(n);
                    serial.put(" bytes, want ");
                    serial.putDec(expected);
                    serial.put("\n");
                    serial.fail("a read in the sweep returned the wrong length");
                }
                for (sweep_buf[0..n], 0..) |b, i| {
                    if (b != patternByte(c.seed, off + i)) {
                        serial.put("  ");
                        serial.put(c.path);
                        serial.put(" at ");
                        serial.putDec(off);
                        serial.put(" for ");
                        serial.putDec(len);
                        serial.put(": wrong byte at +");
                        serial.putDec(i);
                        serial.put("\n");
                        serial.fail("a read in the sweep returned the wrong bytes");
                    }
                }
                reads += 1;
            }
        }
    }
    serial.put("  read sweep: ");
    serial.putDec(reads);
    serial.put(" reads across sector edges, cluster edges, chain breaks and the request cap\n");
}

/// **POSITIONAL READS, AGAINST THE BYTES WE KNOW WERE WRITTEN.** The application
/// answers an HTTP Range request with `readPositionalAll`, so a browser seeking
/// in an image lands in the middle of a chain. Each window below is compared
/// with `expect` — the buffer built from the format string, not from a read —
/// and each is chosen for the path it takes through disk_fat.readAt.
fn readWindows(io: anytype) void {
    const Window = struct { offset: u64, len: usize, why: []const u8 };
    const cluster: u64 = 2048;
    const windows = [_]Window{
        .{ .offset = 0, .len = 10, .why = "the first bytes" },
        .{ .offset = 505, .len = 20, .why = "across a sector boundary" },
        .{ .offset = cluster - 7, .len = 30, .why = "across a cluster boundary" },
        .{ .offset = cluster * 6 + 1, .len = 3000, .why = "deep, spanning two clusters" },
        .{ .offset = 512 * 3, .len = 512, .why = "exactly one sector" },
        .{ .offset = cluster * 2, .len = cluster, .why = "exactly one cluster" },
    };

    var file = Io.Dir.cwd().openFile(io, "log.txt", .{}) catch
        serial.fail("log.txt would not open for reading");
    defer file.close(io);
    const size = (file.stat(io) catch serial.fail("log.txt would not stat")).size;

    var buf: [4096]u8 = undefined;
    for (windows) |w| {
        const n = file.readPositionalAll(io, buf[0..w.len], w.offset) catch
            serial.fail("a positional read failed");
        if (n != w.len or !eql(buf[0..n], expect[w.offset..][0..w.len])) {
            serial.put("  read at ");
            serial.putDec(w.offset);
            serial.put(" (");
            serial.put(w.why);
            serial.put(") got ");
            serial.putDec(n);
            serial.put(" bytes\n");
            serial.fail("a positional read returned the wrong bytes");
        }
    }

    // The tail: asking past the end reads what is there, and says how much.
    const tail = file.readPositionalAll(io, buf[0..100], size - 10) catch
        serial.fail("the tail read failed");
    if (tail != 10 or !eql(buf[0..10], expect[size - 10 ..][0..10]))
        serial.fail("a read across the end did not stop at the end");

    // At the end, and past it, there is nothing — and that is not an error.
    const at_end = file.readPositionalAll(io, buf[0..10], size) catch
        serial.fail("a read at the end failed instead of answering zero");
    const past = file.readPositionalAll(io, buf[0..10], size + 5000) catch
        serial.fail("a read past the end failed instead of answering zero");
    if (at_end != 0 or past != 0) serial.fail("a read at or past the end returned bytes");

    // Reassembled in odd-sized pieces, the whole file is the whole file.
    var at: u64 = 0;
    while (at < size) {
        const n = file.readPositionalAll(io, buf[0..777], at) catch
            serial.fail("a chunked read failed");
        if (n == 0) serial.fail("a chunked read stopped before the end");
        if (!eql(buf[0..n], expect[at..][0..n])) serial.fail("a chunk had the wrong bytes");
        at += n;
    }

    // A handle opened BEFORE an append must see the new size: the application
    // opens, then something appends, then it reads.
    append(io, "log.txt", "one more\n") catch serial.fail("the late append failed");
    const late = file.readPositionalAll(io, buf[0..32], size) catch
        serial.fail("reading the late append failed");
    if (!eql(buf[0..late], "one more\n"))
        serial.fail("a handle opened before an append did not see it");

    serial.put("  readPositionalAll: 6 windows, the tail, past the end, 777-byte chunks, a late append\n");
}

/// createFile's defaults are std's: without `.truncate = false` it EMPTIES the
/// file. This machine once defaulted the other way, which no caller happened to
/// hit; this pins it.
fn createDefaults(io: anytype, alloc: std.mem.Allocator) void {
    append(io, "trunc.txt", "keep me") catch serial.fail("trunc.txt would not be written");
    {
        var f = Io.Dir.cwd().createFile(io, "trunc.txt", .{ .truncate = false }) catch
            serial.fail("createFile(.truncate = false) failed");
        f.close(io);
    }
    const kept = Io.Dir.cwd().readFileAlloc(io, "trunc.txt", alloc, .limited(64)) catch
        serial.fail("trunc.txt would not read");
    if (!eql(kept, "keep me")) serial.fail("createFile(.truncate = false) did not keep the file");

    {
        var f = Io.Dir.cwd().createFile(io, "trunc.txt", .{}) catch
            serial.fail("createFile(.{}) failed");
        f.close(io);
    }
    const emptied = Io.Dir.cwd().readFileAlloc(io, "trunc.txt", alloc, .limited(64)) catch
        serial.fail("trunc.txt would not read after truncation");
    if (emptied.len != 0) serial.fail("createFile(.{}) kept the file; std's default is to truncate");

    serial.put("  createFile: .truncate = false keeps, the default empties\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const panic = metal.serial.panic;
