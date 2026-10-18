//! **THE WRITES THAT TAKE THINGS AWAY.** Replacing a file, deleting one,
//! deleting a tree — and the directory shapes that made two of them unsafe.
//!
//! Both bugs this probe exists for passed every probe before it:
//!
//!   - removeEntry freed the cluster chain BEFORE tombstoning the entry, and
//!     freeChain reuses the machine's one scratch sector for FAT reads. The
//!     "directory sector" it then wrote back was a FAT sector. Any replace of a
//!     file with data destroyed its directory — and the application replaces a
//!     file every time an id counter moves.
//!   - writeEntry and the old tombstoneRun stepped `lba += 1` to reach a long
//!     name's next part. Past a cluster edge in a subdirectory that is usually
//!     another file's data, because a directory grows into whatever cluster is
//!     free next.
//!
//! So the cases are built to hit exactly those shapes:
//!
//!   counter.txt   rewritten 200 times, growing — the id-counter pattern.
//!   sessions/     120 long-named files (four directory entries each), each
//!                 written with ~3 KB of data so data clusters are allocated
//!                 BETWEEN the directory's own growth. The directory ends up
//!                 fragmented, and long-name runs straddle its cluster edges.
//!                 Then every 7th is replaced with a different size, every
//!                 3rd is deleted, and twenty new files are created into the
//!                 tombstones those deletes left.
//!   tree/         four levels with data at each, removed by deleteTree.
//!
//! **THE VERDICT IS NOT THIS PROBE'S.** probe/run.sh computes the expected final
//! state independently, hands the volume to fsck.vfat (which must find nothing,
//! and reclaim nothing), reads every file back through the Linux VFAT driver,
//! and checks from the raw image that the directory really is fragmented and a
//! run really does straddle an edge — so that this probe fails if it ever stops
//! testing what it says it tests.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const disk_fat = metal.disk_fat;
const Io = metal.io;

/// Built twice: once as it always was, and once with the FAT held in memory.
/// Both are judged by the same gate in run.sh, and their final volumes must be
/// byte-identical — a cache that changed anything on disk is a bug.
const cache_fat = @import("probe_options").cache_fat;
var fat_cache: [512 * 1024]u8 align(4096) = undefined;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var scratch: [disk_fat.sector_size]u8 align(4096) = undefined;
var heap: [256 * 1024]u8 align(16) = undefined;
var body_buf: [8192]u8 = undefined;
var name_buf: [96]u8 = undefined;

pub const files = 120;
pub const new_files = 20;

/// The content of session file `i`, in `variant` 0 (as first written) or 1
/// (after a replace). run.sh builds the same bytes in Python.
fn body(i: usize, variant: usize) []const u8 {
    const len: usize = if (variant == 0) 3000 + (i * 37) % 500 else 100 + (i * 53) % 4000;
    var tag_buf: [16]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "v{d}:{d:0>3}:", .{ variant, i }) catch unreachable;
    var at: usize = 0;
    while (at < len) : (at += 1) body_buf[at] = tag[at % tag.len];
    return body_buf[0..len];
}

fn sessionName(i: usize) []const u8 {
    return std.fmt.bufPrint(&name_buf, "sessions/{d:0>3}-session-file-name.dsl", .{i}) catch unreachable;
}

fn newName(j: usize) []const u8 {
    return std.fmt.bufPrint(&name_buf, "sessions/{d:0>2}-new-file-after-deletes.dsl", .{j}) catch unreachable;
}

fn newBody(j: usize) []const u8 {
    return std.fmt.bufPrint(&body_buf, "new file {d}, written into a tombstone\n", .{j}) catch unreachable;
}

fn isDeleted(i: usize) bool {
    return i % 3 == 0;
}

fn isReplaced(i: usize) bool {
    return i % 7 == 0 and !isDeleted(i);
}

fn write(io: anytype, path: []const u8, data: []const u8) void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        serial.put("  writeFile ");
        serial.put(path);
        serial.put(": ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("a write failed");
    };
}

fn expectFile(io: anytype, fba: *std.heap.FixedBufferAllocator, path: []const u8, want: []const u8) void {
    defer fba.reset();
    const got = Io.Dir.cwd().readFileAlloc(io, path, fba.allocator(), .limited(16384)) catch |e| {
        serial.put("  read ");
        serial.put(path);
        serial.put(": ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("a file that should be there would not read");
    };
    if (!std.mem.eql(u8, got, want)) {
        serial.put("  ");
        serial.put(path);
        serial.put(" has the wrong bytes\n");
        serial.fail("a file read back different from what was written");
    }
}

fn expectGone(io: anytype, path: []const u8) void {
    if (Io.Dir.cwd().statFile(io, path, .{})) |_| {
        serial.put("  ");
        serial.put(path);
        serial.put(" is still there\n");
        serial.fail("a deleted path still exists");
    } else |_| {}
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel replace probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    var vol = disk_fat.Volume.mount(&blk, &scratch, 0) catch
        serial.fail("this is not the FAT16 volume the probe expects");
    if (cache_fat) {
        _ = vol.cacheFat(&fat_cache) catch |e| {
            serial.put("  fat cache: ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail("the FAT could not be held in memory");
        };
        serial.put("  the FAT is held in memory\n");
    }
    Io.mount(vol);
    const io = Io.io();
    var fba = std.heap.FixedBufferAllocator.init(&heap);

    // ── the id-counter pattern ────────────────────────────────────────────────
    var n: usize = 1;
    var num: [16]u8 = undefined;
    while (n <= 200) : (n += 1) {
        // Growing text, so the chain is freed and re-allocated at changing sizes.
        const text = std.fmt.bufPrint(&num, "{d}\n", .{n}) catch unreachable;
        write(io, "counter.txt", text);
    }
    expectFile(io, &fba, "counter.txt", "200\n");
    serial.put("  counter.txt: replaced 200 times -> 200\n");

    // ── a fragmented directory of long names ─────────────────────────────────
    Io.Dir.cwd().createDirPath(io, "sessions") catch serial.fail("createDirPath(sessions) failed");
    var i: usize = 0;
    while (i < files) : (i += 1) write(io, sessionName(i), body(i, 0));
    i = 0;
    while (i < files) : (i += 1) expectFile(io, &fba, sessionName(i), body(i, 0));
    serial.put("  sessions/: 120 long-named files with data\n");

    i = 0;
    while (i < files) : (i += 1) {
        if (isReplaced(i)) write(io, sessionName(i), body(i, 1));
    }
    i = 0;
    while (i < files) : (i += 1) {
        if (!isDeleted(i)) continue;
        Io.Dir.cwd().deleteFile(io, sessionName(i)) catch |e| {
            serial.put("  deleteFile: ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail("a delete failed");
        };
    }
    var j: usize = 0;
    while (j < new_files) : (j += 1) write(io, newName(j), newBody(j));

    // Our own reading of the final state. run.sh does it again from outside.
    i = 0;
    while (i < files) : (i += 1) {
        if (isDeleted(i)) {
            expectGone(io, sessionName(i));
        } else {
            const v: usize = if (isReplaced(i)) 1 else 0;
            // body() and sessionName() share no buffer, so both can be live.
            const want = body(i, v);
            expectFile(io, &fba, sessionName(i), want);
        }
    }
    j = 0;
    while (j < new_files) : (j += 1) {
        var nb: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&nb, "new file {d}, written into a tombstone\n", .{j}) catch unreachable;
        expectFile(io, &fba, newName(j), want);
    }
    serial.put("  sessions/: 14 replaced, 40 deleted, 20 new into the tombstones\n");

    // ── a whole tree, with data at every level ───────────────────────────────
    Io.Dir.cwd().createDirPath(io, "tree/a/b/c") catch serial.fail("createDirPath(tree/a/b/c) failed");
    write(io, "tree/top-level-file.txt", body(1, 0));
    write(io, "tree/a/one.txt", body(2, 1));
    write(io, "tree/a/b/two-with-a-long-name.txt", body(3, 0));
    write(io, "tree/a/b/c/three.txt", body(4, 1));
    write(io, "tree/a/b/c/four-with-another-long-name.txt", body(5, 0));
    Io.Dir.cwd().deleteTree(io, "tree") catch serial.fail("deleteTree failed");
    expectGone(io, "tree");
    expectGone(io, "tree/a/b/c/three.txt");
    // Deleting what is not there is what the caller wanted.
    Io.Dir.cwd().deleteTree(io, "tree") catch serial.fail("deleteTree of a missing path failed");
    serial.put("  tree/: four levels with data, deleted whole\n");

    serial.pass();
}

pub const panic = metal.serial.panic;
