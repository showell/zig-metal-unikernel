//! `disk_fat.zig` on a disk in memory (`virtio_blk.Block.inMemory`): mount, write,
//! read back, append, remove, fill the disk, and damage it on purpose, all
//! on the host.
//!
//! **THE VOLUMES ARE MADE FROM THE SPEC**, by `test_disk.zig`, not by
//! `disk_fat.zig` (Microsoft's FAT specification: the BPB, two FATs, a fixed
//! root). And the checks read the disk's bytes directly where they can: the
//! free clusters are counted in the FAT as it sits on the disk, and the two
//! FAT copies are compared byte for byte. So a test does not ask `disk_fat.zig` to vouch for
//! itself.
//!
//! An independent reader of the images, written from the spec in Python, is
//! QUEUE.md item 4; the images these tests make are what it reads.

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const options = @import("disk_fat_test_options");
const virtio_blk = @import("virtio_blk.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;
/// The tests that apply to both kinds run over both: the same operations,
/// the same expectations, on FAT16 and on FAT32.
pub const formats = [_]Shape{ small, test_disk.small32 };
/// Each format with the FAT on the disk and held in memory.
pub const configs = blk: {
    var out: [formats.len * 2]struct { shape: Shape, cached: bool } = undefined;
    for (formats, 0..) |f, i| {
        out[2 * i] = .{ .shape = f, .cached = false };
        out[2 * i + 1] = .{ .shape = f, .cached = true };
    }
    break :blk out;
};

/// `test_disk.Disk`, kept as an image when the tests are asked to keep them
/// (-Dfat16-images).
pub const Disk = struct {
    pub fn make(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        const d = try test_disk.Disk.make(label, shape, cached);
        d.images_dir = options.images_dir;
        return d;
    }
};

pub fn pattern(buf: []u8, seed: u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

// Every test runs with the FAT on the disk and with it held in memory: the
// two paths through `fatGet` and `fatSet` must agree.
pub const both = [_]bool{ false, true };

test "a volume formatted from the spec mounts, and its root is empty" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("fresh", shape, cached);
        defer d.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.free() > 4085);
    }
}

test "a file is read back exactly, at every size around a sector and a cluster" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("sizes", shape, cached);
        defer d.deinit();
        const sizes = [_]usize{ 0, 1, 511, 512, 513, 1023, 1024, 1025, 4096, 70_000 };
        var data: [70_000]u8 = undefined;
        for (sizes, 0..) |size, k| {
            var name: [16]u8 = undefined;
            const path = try std.fmt.bufPrint(&name, "f{d}.bin", .{k});
            try d.vol.writeFile(path, pattern(data[0..size], @intCast(k)));
            try d.expectFile(path, data[0..size]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a path makes its directories, and names of every length up to max_name read back by name" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("names", shape, cached);
        defer d.deinit();
        var name: [disk_fat.max_name]u8 = undefined;
        var path: [128]u8 = undefined;
        for (1..disk_fat.max_name + 1) |len| {
            for (name[0..len], 0..) |*c, i| c.* = "abcdefghijklmnopqrstuvwxyz0123456789-"[i % 37];
            const p = try std.fmt.bufPrint(&path, "data/chat/{s}", .{name[0..len]});
            try d.vol.writeFile(p, name[0..len]);
            try d.expectFile(p, name[0..len]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a name longer than max_name is refused, not truncated" {
    const d = try Disk.make("toolong", small, true);
    defer d.deinit();
    const long = &@as([disk_fat.max_name + 1]u8, @splat('a'));
    try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile(long, "x"));
}

test "a replaced file gives back what it held" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("replaced", shape, cached);
        defer d.deinit();
        var data: [20_000]u8 = undefined;
        try d.vol.writeFile("data/x", pattern(&data, 1));
        const after_big = d.free();
        try d.vol.writeFile("data/x", "small");
        // 20,000 bytes took 40 clusters; "small" takes one.
        try testing.expectEqual(after_big + 39, d.free());
        try d.expectFile("data/x", "small");
        try testing.expect(d.fatsAgree());
    }
}

test "appends cross cluster boundaries and read back whole" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("appends", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/log", "");
        var whole: [3000]u8 = undefined;
        _ = pattern(&whole, 7);
        var at: usize = 0;
        // Pieces of awkward sizes, so that writes start and end everywhere in
        // a cluster.
        const pieces = [_]usize{ 1, 510, 2, 513, 300, 700, 974 };
        for (pieces) |n| {
            try d.vol.writeInto("data/log", @intCast(at), whole[at..][0..n]);
            at += n;
            try d.expectFile("data/log", whole[0..at]);
        }
        try testing.expectEqual(whole.len, at);
        // An overwrite in the middle, and a write past the end refused.
        try d.vol.writeInto("data/log", 100, "OVERWRITTEN");
        @memcpy(whole[100..][0..11], "OVERWRITTEN");
        try d.expectFile("data/log", &whole);
        try testing.expectError(disk_fat.Error.BadChain, d.vol.writeInto("data/log", whole.len + 1, "hole"));
        try testing.expect(d.fatsAgree());
    }
}

test "removing a tree gives back every cluster, directories included" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("removetree", shape, cached);
        defer d.deinit();
        const empty = d.free();
        var data: [4000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..40) |k| {
            const p = try std.fmt.bufPrint(&path, "data/chat/{d}_{d}/sessions/topic-{d}.md", .{ k % 5, k % 3, k });
            try d.vol.writeFile(p, pattern(data[0 .. 100 * k], @intCast(k)));
        }
        try testing.expect(d.free() < empty);
        try d.vol.removeTree("data");
        try testing.expectEqual(empty, d.free());
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.fatsAgree());
    }
}

test "a directory grows past its first cluster, and every name in it is found" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("growth", shape, cached);
        defer d.deinit();
        // Each name takes three entries; a 512-byte cluster holds sixteen.
        // **A HUNDRED, NOT 200** (metal-vmm QUEUE 198.12): every name here
        // shares its first six characters, so the k-th tries k aliases
        // (SESSIO~1, ~2, ...) and each try lists the directory: the cost is
        // the cube of the count, 4 s of Debug at 200. A hundred names are 300
        // entries, nineteen clusters, and reach the ~100 alias.
        var path: [64]u8 = undefined;
        for (0..100) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, p);
        }
        for (0..100) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.expectFile(p, p);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a full disk refuses the write, and the refused write leaves nothing behind" {
    for (both) |cached| {
        // The smallest FAT16 there is: 4,085 clusters of 512 bytes.
        const d = try Disk.make("full", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        const big = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(big);
        _ = pattern(big, 3);
        try d.vol.writeFile("one", big); // 2,048 clusters
        const before = d.free();
        try testing.expect(before < 2048);
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("two", big));
        try testing.expectEqual(before, d.free());
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("two"));
        // What fits still fits, and the first file is untouched.
        try d.vol.writeFile("three", big[0..1000]);
        try d.expectFile("one", big);
        try testing.expect(d.fatsAgree());
    }
}

test "a reserve is kept for small writes: a large one that would leave less free is refused, a small one is not (metal-vmm QUEUE 132)" {
    for (configs) |cfg| {
        const d = try Disk.make("reserve", cfg.shape, cfg.cached);
        defer d.deinit();
        const reserve = d.vol.reserve_clusters;
        // 64 MiB, or a sixteenth of a volume too small for that.
        const per_cluster = d.vol.sectors_per_cluster * 512;
        try testing.expectEqual(@min((64 << 20) / per_cluster, (d.vol.max_cluster - 1) / 16), reserve);
        try testing.expect(reserve > 3);
        // A write one byte past small (`small_bytes`), whatever its count
        // of clusters.
        const large_clusters = (disk_fat.Volume.small_bytes + 1 + per_cluster - 1) / per_cluster;
        // Filled to leave the reserve and one large write more (its folder
        // made first: it takes a cluster).
        _ = try d.vol.makePath("data");
        const fill = (d.free() - reserve - large_clusters) * per_cluster;
        const big = try testing.allocator.alloc(u8, @max(fill, disk_fat.Volume.small_bytes + 1));
        defer testing.allocator.free(big);
        _ = pattern(big, 5);
        try d.vol.writeFile("data/bulk", big[0..fill]);
        try testing.expectEqual(reserve + large_clusters, @as(u32, @intCast(d.free())));
        // A large write that leaves exactly the reserve: taken.
        const four = big[0 .. disk_fat.Volume.small_bytes + 1];
        try d.vol.writeFile("data/first", four);
        try testing.expectEqual(reserve, @as(u32, @intCast(d.free())));
        // Another would leave less: refused, nothing taken.
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("data/four", four));
        try testing.expectEqual(reserve, @as(u32, @intCast(d.free())));
        // Now a small record still goes, into the reserve.
        try d.vol.writeFile("data/small", big[0..disk_fat.Volume.small_bytes]);
        try d.vol.writeFile("data/smaller", "x");
        try d.expectFile("data/smaller", "x");
        // A large one does not, and a remove always does.
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("data/four", four));
        try d.vol.remove("data/bulk");
        try d.vol.writeFile("data/four", four);
        try testing.expect(d.fatsAgree());
    }
}

test "the reserve is judged in bytes, an append by its file's size, and an overwrite by what it frees (metal-vmm QUEUE 138(e))" {
    const small_bytes = disk_fat.Volume.small_bytes;
    for (configs) |cfg| {
        const d = try Disk.make("reservebytes", cfg.shape, cfg.cached);
        defer d.deinit();
        const reserve = d.vol.reserve_clusters;
        const per_cluster = d.vol.sectors_per_cluster * 512;
        const small_clusters = (small_bytes + per_cluster - 1) / per_cluster;
        // Room in the reserve for a small write, and then the clusters for an
        // overwrite of twice that, on both shapes.
        try testing.expect(reserve > 3 * small_clusters + 1);
        _ = try d.vol.makePath("data");
        const buf = try testing.allocator.alloc(u8, @max(2 * small_bytes, (d.free() - reserve) * per_cluster));
        defer testing.allocator.free(buf);
        _ = pattern(buf, 9);
        const mid = buf[0 .. 2 * small_bytes];
        try d.vol.writeFile("data/mid", mid);
        // Filled to leave the reserve and one cluster more.
        try d.vol.writeFile("data/bulk", buf[0 .. (d.free() - reserve - 1) * per_cluster]);
        try testing.expectEqual(reserve + 1, @as(u32, @intCast(d.free())));
        // One byte past small: refused, nothing taken.
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("data/large", buf[0 .. small_bytes + 1]));
        try testing.expectEqual(reserve + 1, @as(u32, @intCast(d.free())));
        // Small, in bytes, whatever its count of clusters: into the reserve.
        try d.vol.writeFile("data/record", buf[0..small_bytes]);
        try d.expectFile("data/record", buf[0..small_bytes]);
        const after_record = d.free();
        // **AN APPEND IS JUDGED BY THE FILE IT MAKES**: a file grown past
        // small by appends of a cluster each spends the reserve no more than
        // one write of it would. Refused, and nothing taken.
        try testing.expectError(disk_fat.Error.Full, d.vol.writeInto("data/record", small_bytes, buf[0..per_cluster]));
        try testing.expectEqual(after_record, d.free());
        try d.expectFile("data/record", buf[0..small_bytes]);
        // A small file's append that stays small still goes.
        try d.vol.writeFile("data/note", "x");
        try d.vol.writeInto("data/note", 1, "y");
        try d.expectFile("data/note", "xy");
        // **AN OVERWRITE IS JUDGED BY WHAT IT LEAVES**: one that frees as
        // much as it takes goes, though the new chain is taken first.
        const before = d.free();
        std.mem.reverse(u8, mid);
        try d.vol.writeFile("data/mid", mid);
        try d.expectFile("data/mid", mid);
        try testing.expectEqual(before, d.free());
        try testing.expect(d.fatsAgree());
    }
}

test "a full disk refuses a write over a file, and the old file stays whole" {
    for (both) |cached| {
        // Room for the old file's chain and not for a second one beside it:
        // the overwrite needs both at once (essay kernel-facts #1).
        const d = try Disk.make("full-overwrite", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        const big = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(big);
        _ = pattern(big, 3);
        try d.vol.writeFile("one", big); // 2,048 clusters
        const before = d.free();
        _ = pattern(big, 4);
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("one", big));
        try testing.expectEqual(before, d.free());
        _ = pattern(big, 3);
        try d.expectFile("one", big);
        // A smaller one fits beside it, and takes the old one's place.
        try d.vol.writeFile("one", big[0..1000]);
        try d.expectFile("one", big[0..1000]);
        try testing.expect(d.fatsAgree());
    }
}

test "a chain that runs into a free cluster is a broken chain, not a short file" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-chain", shape, cached);
        defer d.deinit();
        var data: [2000]u8 = undefined;
        try d.vol.writeFile("broken", pattern(&data, 9));
        const e = try d.vol.open("broken");
        // Its second cluster is marked free in both copies of the FAT.
        const l = Layout.of(d.bytes);
        for (0..2) |copy| {
            l.set(d.bytes, copy, e.first_cluster, 0);
        }
        try d.mount(cached); // so a held FAT sees the damage too
        var out: [2000]u8 = undefined;
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(e, &out));
    }
}

test "a disk that stops answering is an error, not a hang or a wrong answer" {
    const d = try Disk.make("io-failure", small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "before");
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(disk_fat.Error.ReadFailed, d.vol.open("data/x"));
    try testing.expect(std.meta.isError(d.vol.writeFile("data/y", "after")));
}

/// Sets `cluster`'s entry in both copies of the FAT on the disk, then mounts
/// again so that a held FAT sees it too.
pub fn damageFat(d: *test_disk.Disk, cached: bool, cluster: disk_fat.Cluster, value: disk_fat.Cluster) !void {
    const l = Layout.of(d.bytes);
    for (0..2) |copy| {
        l.set(d.bytes, copy, cluster, value);
    }
    try d.mount(cached);
}

/// The clusters of a chain, in order, read from the first FAT on the disk.
pub fn chainOf(d: *const test_disk.Disk, first: disk_fat.Cluster, out: []disk_fat.Cluster) []disk_fat.Cluster {
    const l = Layout.of(d.bytes);
    var n: usize = 0;
    var c = first;
    while (c >= 2 and !l.ends(c) and n < out.len) {
        out[n] = c;
        n += 1;
        c = l.get(d.bytes, 0, c);
    }
    return out[0..n];
}

// **A LOOP IN THE FAT MUST END A WALK WITH AN ERROR.** Before the walks were
// bounded, each of these hung: the test did not fail, it never finished.

test "a file whose chain loops back is a broken chain to append to, not a hang" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-loop-file", shape, cached);
        defer d.deinit();
        var data: [1536]u8 = undefined; // three clusters, full, so an append needs a fourth
        try d.vol.writeFile("data/log", pattern(&data, 4));
        const e = try d.vol.open("data/log");
        var chain: [8]disk_fat.Cluster = undefined;
        const c = chainOf(d, e.first_cluster, &chain);
        try testing.expectEqual(@as(usize, 3), c.len);
        try damageFat(d, cached, c[2], c[0]);
        // A read stops at the file's size, so it never reaches the loop.
        try d.expectFile("data/log", &data);
        // An append looks for the chain's end, which a loop does not have.
        try testing.expectError(disk_fat.Error.BadChain, d.vol.writeInto("data/log", data.len, "more"));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.layout(try d.vol.open("data/log")));
    }
}

test "a directory whose chain loops back is a broken chain to list, search or grow, not a hang" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-loop-dir", shape, cached);
        defer d.deinit();
        // Every cluster of it full, so no end-of-directory entry stops a walk:
        // "." and "..", and three entries a name, are 32, two clusters.
        var path: [64]u8 = undefined;
        for (0..10) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, "x");
        }
        const dir = try d.vol.open("data/sessions");
        var chain: [64]disk_fat.Cluster = undefined;
        const c = chainOf(d, dir.first_cluster, &chain);
        try testing.expectEqual(@as(usize, 2), c.len);
        try damageFat(d, cached, c[c.len - 1], c[0]);

        var buf: [4096]u8 = undefined;
        try testing.expectError(disk_fat.Error.BadChain, d.names(dir.first_cluster, &buf));
        try testing.expect(std.meta.isError(d.vol.open("data/sessions/nothing-by-this-name")));
        try testing.expect(std.meta.isError(d.vol.writeFile("data/sessions/one-more-session.md", "x")));
    }
}

test "a link past the last cluster, or to the bad-cluster mark, is a broken chain" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-past-end", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("f", pattern(&data, 5));
        const e = try d.vol.open("f");
        const past: disk_fat.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        const l = Layout.of(d.bytes);
        // Past the volume, in the reserved range, and the bad mark.
        for ([_]disk_fat.Cluster{ past, l.end() - 15, l.bad() }) |link| {
            try damageFat(d, cached, e.first_cluster, link);
            var out: [1500]u8 = undefined;
            try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(e, &out));
            try testing.expectError(disk_fat.Error.BadChain, d.vol.writeInto("f", 1000, "x"));
            try testing.expectError(disk_fat.Error.BadChain, d.vol.layout(e));
        }
    }
}

test "an entry whose first cluster is past the volume is a broken chain, and removing it frees nothing" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-first-cluster", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "some bytes");
        try d.vol.writeFile("data/x", "a directory's worth");
        const e = try d.vol.open("f");
        const dir = try d.vol.open("data");
        const past: disk_fat.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        // The first cluster is two bytes at offset 26 of the entry.
        setEntry(d, e, .first_cluster, past);
        setEntry(d, dir, .first_cluster, past + 1000);
        try d.mount(cached);
        const free = d.free();

        var out: [64]u8 = undefined;
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(try d.vol.open("f"), &out));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.layout(try d.vol.open("f")));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.writeInto("f", 2, "x"));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.open("data/x"));
        var buf: [64]u8 = undefined;
        try testing.expectError(disk_fat.Error.BadChain, d.names(past + 1000, &buf));
        try d.vol.remove("f");
        try testing.expectEqual(free, d.free());
        try testing.expect(d.fatsAgree());
    }
}

test "a FAT too short for the clusters it describes is refused at mount" {
    const bytes = try testing.allocator.alloc(u8, small.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    test_disk.format(bytes, small);
    std.mem.writeInt(u16, bytes[22..24], 2, .little); // room for 510 clusters of ~8,000
    var blk = @import("virtio_blk.zig").Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    try testing.expectError(disk_fat.Error.BadBootSector, disk_fat.Volume.mount(&blk, &scratch, 0));
}

// ---- the boot-time check (QUEUE item 5) ------------------------------------
//
// Every disk a test above left healthy is checked when it is torn down, and
// must check clean (test_disk.Disk.deinit). These break a disk on purpose, one
// way each, and expect exactly what the check should say. `Disk.check` also
// requires that the check changed nothing on the disk.

/// Writes a file's entry fields on the disk directly: its size, or its first
/// cluster.
pub fn setEntry(d: *test_disk.Disk, e: disk_fat.Entry, comptime field: enum { size, first_cluster }, value: u32) void {
    const at = e.lba * test_disk.sector + e.slot;
    switch (field) {
        .size => std.mem.writeInt(u32, d.bytes[at + 28 ..][0..4], value, .little),
        .first_cluster => {
            std.mem.writeInt(u16, d.bytes[at + 26 ..][0..2], @truncate(value), .little);
            std.mem.writeInt(u16, d.bytes[at + 20 ..][0..2], @truncate(value >> 16), .little);
        },
    }
}

test "the check counts what a healthy volume holds" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("check-healthy", shape, cached);
        defer d.deinit();
        const empty = d.free();
        var data: [3000]u8 = undefined;
        try d.vol.writeFile("data/chat/a.md", pattern(&data, 1)); // 6 clusters
        try d.vol.writeFile("data/chat/b.md", ""); // none
        try d.vol.writeFile("auth/7/password", "hash"); // 1
        try d.vol.writeFile("data/gone", "x");
        try d.vol.remove("data/gone");
        const r = try d.check();
        try r.expect(&.{});
        try testing.expectEqual(@as(u32, 3), r.health.files);
        try testing.expectEqual(@as(u32, 4), r.health.directories); // data, data/chat, auth, auth/7
        // FAT32's root is a chain in the data region, held like any
        // directory's: one cluster here, already in use when `empty` was
        // counted.
        const root: u32 = if (shape.kind == .fat32) 1 else 0;
        try testing.expectEqual(@as(u32, @intCast(empty - d.free())) + root, r.health.used);
        try testing.expectEqual(@as(u32, 0), r.health.leaked);
    }
}

test "the check finds clusters in use that nothing holds" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-leaked", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/x", "kept");
        const last: disk_fat.Cluster = @intCast(Layout.of(d.bytes).clusters + 1);
        // One cluster alone, and a run of three linked ones, as a write that
        // stopped before its entry was written leaves them.
        const l = Layout.of(d.bytes);
        try damageFat(d, cached, last - 10, l.end());
        try damageFat(d, cached, last - 5, last - 4);
        try damageFat(d, cached, last - 4, last - 3);
        try damageFat(d, cached, last - 3, l.end());
        // A cluster marked bad is in use by nothing, and is not a leak.
        try damageFat(d, cached, last - 1, l.bad());
        // And the volume's very last cluster, where the FAT's scan ends.
        try damageFat(d, cached, last, l.end());
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .leaked, .cluster = last - 10, .count = 1 },
            .{ .problem = .leaked, .cluster = last - 5, .count = 3 },
            .{ .problem = .leaked, .cluster = last, .count = 1 },
        });
        try testing.expectEqual(@as(u32, 5), r.health.leaked);
    }
}

test "the check finds a chain that runs into a free cluster, past the volume, or into a bad one" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-broken", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined; // three clusters
        try d.vol.writeFile("data/f", pattern(&data, 2));
        const e = try d.vol.open("data/f");
        const past: disk_fat.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        for ([_]disk_fat.Cluster{ 0, past, Layout.of(d.bytes).bad() }) |link| {
            try damageFat(d, cached, e.first_cluster, link);
            const r = try d.check();
            // The rest of the chain is then held by nothing.
            try r.expect(&.{
                .{ .problem = .broken, .path = "/data/f", .cluster = e.first_cluster },
                .{ .problem = .leaked, .cluster = e.first_cluster + 1, .count = 2 },
            });
        }
    }
}

test "the check finds a first cluster past the volume, and a directory with no chain" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-first", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        try d.vol.writeFile("auth/7/password", "x");
        const f = try d.vol.open("data/f");
        const dir = try d.vol.open("auth/7");
        const past: disk_fat.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        setEntry(d, f, .first_cluster, past);
        setEntry(d, dir, .first_cluster, 0);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .broken, .path = "/data/f", .cluster = past },
            .{ .problem = .broken, .path = "/auth/7", .cluster = 0 },
            .{ .problem = .leaked, .cluster = f.first_cluster, .count = 1 },
            .{ .problem = .leaked, .cluster = dir.first_cluster, .count = 2 }, // auth/7 and its password
        });
    }
}

test "the check finds two files sharing clusters, and a file that loops" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-crossed", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("a", pattern(&data, 3));
        try d.vol.writeFile("b", pattern(&data, 4));
        try d.vol.writeFile("c", pattern(&data, 5));
        var chain: [8]disk_fat.Cluster = undefined;
        const a = chainOf(d, (try d.vol.open("a")).first_cluster, &chain)[0..3].*;
        const b = chainOf(d, (try d.vol.open("b")).first_cluster, &chain)[0..3].*;
        const c = chainOf(d, (try d.vol.open("c")).first_cluster, &chain)[0..3].*;
        try damageFat(d, cached, a[2], b[1]); // a runs on into b's tail
        try damageFat(d, cached, c[2], c[0]); // c comes back to its start
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .long, .path = "/a", .cluster = a[0], .count = 5 },
            .{ .problem = .crossed, .path = "/b", .cluster = b[1] },
            .{ .problem = .crossed, .path = "/c", .cluster = c[0] },
        });
    }
}

test "the check finds a directory that loops, and one that points at its own parent" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-dirs", shape, cached);
        defer d.deinit();
        // Two full clusters, as in the loop test above.
        var path: [64]u8 = undefined;
        for (0..10) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, "x");
        }
        try d.vol.writeFile("data/up/x", "x");
        const data_dir = try d.vol.open("data");
        const sessions = try d.vol.open("data/sessions");
        const up = try d.vol.open("data/up");
        var chain: [8]disk_fat.Cluster = undefined;
        const s = chainOf(d, sessions.first_cluster, &chain)[0..2].*;
        try damageFat(d, cached, s[1], s[0]);
        setEntry(d, up, .first_cluster, data_dir.first_cluster);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            // The loop is found, and the sessions are all still checked.
            .{ .problem = .crossed, .path = "/data/sessions", .cluster = s[0] },
            // A directory that is its own parent is reported, not walked
            // for ever, and what it used to hold is held by nothing.
            .{ .problem = .crossed, .path = "/data/up", .cluster = data_dir.first_cluster },
            .{ .problem = .leaked, .cluster = up.first_cluster, .count = 2 },
        });
        try testing.expectEqual(@as(u32, 10), r.health.files);
    }
}

test "the check finds a file whose size and chain disagree" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-size", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("short", &@as([1000]u8, @splat('x'))); // two clusters
        try d.vol.writeFile("long", &@as([1000]u8, @splat('x')));
        try d.vol.writeFile("empty", &@as([1000]u8, @splat('x')));
        const short = try d.vol.open("short");
        const long = try d.vol.open("long");
        const empty = try d.vol.open("empty");
        setEntry(d, short, .size, 5000);
        setEntry(d, long, .size, 10);
        setEntry(d, empty, .size, 0);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .short, .path = "/short", .cluster = short.first_cluster, .count = 2 },
            .{ .problem = .long, .path = "/long", .cluster = long.first_cluster, .count = 2 },
            .{ .problem = .long, .path = "/empty", .cluster = empty.first_cluster, .count = 2 },
        });
    }
}

test "a path with an empty part is refused by every operation that takes a path, never read as the path it might mean (the normalization hunt)" {
    for (configs) |cfg| {
        const d = try Disk.make("empty-parts", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/keep", "kept");
        const free = (try d.vol.space()).free;
        for ([_][]const u8{ "data//keep", "/data/keep", "data/keep/", "data/" }) |bad| {
            try testing.expectError(disk_fat.Error.NotFound, d.vol.open(bad));
            try testing.expectError(disk_fat.Error.BadName, d.vol.remove(bad));
            // Never "already gone", so done (metal-vmm QUEUE 172).
            try testing.expectError(disk_fat.Error.BadName, d.vol.removeTree(bad));
            try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile(bad, "x"));
            try testing.expectError(disk_fat.Error.BadName, d.vol.rename(bad, "data/other"));
            try testing.expectError(disk_fat.Error.BadName, d.vol.rename("data/keep", bad));
        }
        for ([_][]const u8{ "data//sub", "/data/sub", "data/sub/" }) |bad| {
            try testing.expectError(disk_fat.Error.BadName, d.vol.makePath(bad));
        }
        try testing.expectEqual(free, (try d.vol.space()).free);
        try d.expectFile("data/keep", "kept");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/sub"));
    }
}

test "the check a slice at a time finds what the whole check finds, and starts again when the volume changes (idle time)" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-run", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("a", pattern(&data, 3));
        try d.vol.writeFile("b", pattern(&data, 4));
        try d.vol.writeFile("short", &@as([1000]u8, @splat('x')));
        var chain: [8]disk_fat.Cluster = undefined;
        const a = chainOf(d, (try d.vol.open("a")).first_cluster, &chain)[0..3].*;
        const b = chainOf(d, (try d.vol.open("b")).first_cluster, &chain)[0..3].*;
        try damageFat(d, cached, a[2], b[1]); // crossed, and a long
        setEntry(d, try d.vol.open("short"), .size, 5000); // short
        try d.mount(cached);
        const whole = try d.check();
        var damage: u32 = 0;
        for (whole.found[0..whole.len]) |f| {
            if (f.problem.damage()) damage += 1;
        }
        try testing.expect(damage >= 2);

        const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(seen);
        var run: disk_fat.Volume.CheckRun = .{};
        try run.begin(&d.vol, seen);
        var steps: u32 = 0;
        while (true) {
            steps += 1;
            switch (try run.step(.{ .sectors = 1, .runs = 1 })) {
                .more => continue,
                .done => break,
                .changed => return error.TestUnexpectedResult,
            }
        }
        // The walk, then a step a run of the FAT: more than one slice.
        try testing.expect(steps >= 2 + (d.vol.sectors_per_fat - 1) / 64);
        try testing.expectEqual(whole.health, run.health());
        try testing.expectEqual(damage, run.tally.damage);
        try testing.expect(run.tally.first != null);

        // A write between two steps: the run says so and stops.
        try run.begin(&d.vol, seen);
        try testing.expectEqual(disk_fat.Volume.CheckRun.Step.more, try run.step(.{ .sectors = 1, .runs = 1 }));
        try d.vol.writeFile("new", "y");
        try testing.expectEqual(disk_fat.Volume.CheckRun.Step.changed, try run.step(.{ .sectors = 1, .runs = 1 }));
        try testing.expectEqual(disk_fat.Volume.CheckRun.Step.done, try run.step(.{ .sectors = 1, .runs = 1 }));
    }
}

/// A tree for the walk's slices: folders that span sectors (long names), a
/// folder found mid-sector after a long-name run, damage at depth, and a
/// tree deeper than the check walks.
fn sliceTree(d: *test_disk.Disk) !void {
    const a = try d.vol.makePath("a");
    var name: [40]u8 = undefined;
    for (0..24) |i| {
        const n = try std.fmt.bufPrint(&name, "a file with a long name, number {d}", .{i});
        try d.vol.writeFileIn(a, n, "x");
        if (i == 9) {
            const b = try d.vol.makeDirIn(a, "b folder with a long name");
            try d.vol.writeFileIn(b, "short", &@as([1000]u8, @splat('x')));
            try d.vol.writeFileIn(b, "long", &@as([1000]u8, @splat('y')));
            const c = try d.vol.makeDirIn(b, "c");
            try d.vol.writeFileIn(c, "f", "z");
        }
    }
    try d.vol.writeFile("top", "t");
    const fifteen = try d.vol.makePath(repeated("d/", 14) ++ "d");
    const sixteen = try d.vol.makeDirIn(fifteen, "d");
    try d.vol.writeFileIn(sixteen, "f", "x");
    setEntry(d, try d.vol.open("a/b folder with a long name/short"), .size, 5000); // short
    setEntry(d, try d.vol.open("a/b folder with a long name/long"), .size, 1); // long
}

test "the walk a few sectors at a time finds exactly what the whole check finds, paths and all (idle time)" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-slice-walk", shape, cached);
        defer d.deinit();
        try sliceTree(d);
        try d.mount(cached);
        const whole = try d.check();
        try testing.expect(whole.len >= 3); // short, long, too deep
        const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(seen);
        for ([_]u32{ 1, 2, 3, 5, 64 }) |sectors| {
            var r = test_disk.Report{};
            r.health = try d.vol.checkInSlicesForTest(seen, &r, test_disk.Report.each, sectors);
            try testing.expectEqual(whole.health, r.health);
            try testing.expectEqual(whole.len, r.len);
            for (whole.found[0..whole.len], r.found[0..r.len]) |w, g| {
                try testing.expectEqual(w.problem, g.problem);
                try testing.expectEqualStrings(w.text(), g.text());
                try testing.expectEqual(w.cluster, g.cluster);
                try testing.expectEqual(w.count, g.count);
            }
        }
    }
}

test "a step of the check's walk reads at most its slice's directory sectors (idle time: production's walk was 548 ms in one step)" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-slice-walk-step", shape, cached);
        defer d.deinit();
        try sliceTree(d);
        try d.mount(cached);
        const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(seen);
        var run: disk_fat.Volume.CheckRun = .{};
        try run.begin(&d.vol, seen);
        const slice: disk_fat.Volume.CheckRun.Slice = .{ .sectors = 3, .runs = 1 };
        var walk_steps: u64 = 0;
        while (true) {
            const before = run.checker.walk_sectors;
            const got = try run.step(slice);
            const read = run.checker.walk_sectors - before;
            try testing.expect(read <= slice.sectors);
            if (read > 0) walk_steps += 1;
            switch (got) {
                .more => continue,
                .done => break,
                .changed => return error.TestUnexpectedResult,
            }
        }
        // The tree's folders hold more sectors than one slice: the walk
        // took several steps, and read every sector the whole check reads.
        try testing.expect(run.checker.walk_sectors > 3 * slice.sectors);
        try testing.expectEqual((run.checker.walk_sectors + slice.sectors - 1) / slice.sectors, walk_steps);
        try testing.expectEqual((try d.check()).health, run.health());
    }
}

test "a check a slice at a time that fails is refused until it begins again (its place moved past the failure)" {
    const d = try Disk.make("damaged-slice-walk-fails", test_disk.small32, true);
    defer d.deinit();
    try sliceTree(d);
    try d.mount(true);
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var run: disk_fat.Volume.CheckRun = .{};
    const slice: disk_fat.Volume.CheckRun.Slice = .{ .sectors = 1, .runs = 1 };
    try run.begin(&d.vol, seen);
    try testing.expectEqual(disk_fat.Volume.CheckRun.Step.more, try run.step(slice));
    d.blk.fail_after = d.blk.requests; // the disk stops answering
    try testing.expectError(disk_fat.Error.ReadFailed, run.step(slice));
    d.blk.fail_after = null; // and answers again: the run still refuses
    try testing.expectError(disk_fat.Error.ReadFailed, run.step(slice));
    try run.begin(&d.vol, seen);
    while (try run.step(slice) == .more) {}
    try testing.expectEqual((try d.check()).health, run.health());
}

test "the check finds FAT copies that differ" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-fats", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "x");
        // The second copy only, and not mounted again: a held FAT would bring
        // the copies into line, which is cacheFat's business, not the check's.
        const l = Layout.of(d.bytes);
        l.set(d.bytes, 1, 300, l.end());
        l.set(d.bytes, 1, 1000, l.end());
        const r = try d.check();
        try r.expect(&.{.{ .problem = .fats_differ, .cluster = 300, .count = 2 }});
    }
}

test "the check reads the FAT in runs: a leak across a run's edge and a difference past the first run are found where they are" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-runs", test_disk.small32, cached);
        defer d.deinit();
        const l = Layout.of(d.bytes);
        const per: usize = test_disk.sector / 4;
        // The check reads 64 sectors a request: the FAT must span several.
        try testing.expect(d.vol.sectors_per_fat > 64);
        // Two clusters nothing holds, in both copies, either side of the edge
        // between the FAT's 64th and 65th sectors: one leaked run of two.
        const edge = 64 * per;
        for (0..2) |copy| {
            l.set(d.bytes, copy, edge - 1, l.end());
            l.set(d.bytes, copy, edge, l.end());
        }
        try d.mount(cached); // a held FAT holds them too
        // The second copy apart from the first in the 66th sector only.
        l.set(d.bytes, 1, edge + per + 5, l.end());
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .leaked, .cluster = @intCast(edge - 1), .count = 2 },
            .{ .problem = .fats_differ, .cluster = @intCast(edge + per + 5), .count = 1 },
        });
    }
}

test "the check finds a . or .. that points elsewhere" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-dots", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/chat/x", "x");
        const chat = try d.vol.open("data/chat");
        const at = @as(usize, chat.first_cluster - 2 + Layout.of(d.bytes).data_sector) * test_disk.sector;
        // "." is the first entry of a directory, ".." the second.
        std.mem.writeInt(u16, d.bytes[at + 26 ..][0..2], 77, .little);
        std.mem.writeInt(u16, d.bytes[at + 32 + 26 ..][0..2], 78, .little);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .bad_dot, .path = "/data/chat/.", .cluster = 77 },
            .{ .problem = .bad_dot, .path = "/data/chat/..", .cluster = 78 },
        });
    }
}

test "the check says where it stopped going deeper, and does not call what is below leaked" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        // A healthy volume (tools/fat16_read.py checks it clean), deeper than
        // the check walks. makePath stops where the check does, so the last
        // level is made by hand, as another program with no such limit would.
        const d = try Disk.make("limit-check-deep", shape, cached);
        defer d.deinit();
        const fifteen = try d.vol.makePath(repeated("d/", 14) ++ "d");
        const sixteen = try d.vol.makeDirIn(fifteen, "d");
        try d.vol.writeFileIn(sixteen, "f", "x");
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .too_deep, .path = repeated("/d", 16), .cluster = (try d.vol.open(repeated("d/", 15) ++ "d")).first_cluster },
        });
        try testing.expectEqual(@as(u32, 0), r.health.leaked);
    }
}

test "the check refuses a bitmap too short, and a disk that stops answering is an error" {
    const d = try Disk.make("io-failure-check", small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "x");
    var short: [8]u8 = undefined;
    const Ignore = struct {
        fn each(_: void, _: disk_fat.Finding) void {}
    };
    try testing.expectError(disk_fat.Error.TooBig, d.vol.check(&short, {}, Ignore.each));
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(disk_fat.Error.ReadFailed, d.check());
}

// **VOLUMES ANOTHER PROGRAM MADE.** Every volume above was formatted by
// test_disk.zig and written by disk_fat.zig itself; the volumes this machine
// meets in service were made by mkfs.vfat and written by Linux. So
// tools/check_fat16_images.sh has tools/fat16_read.py make some with
// mkfs.vfat and mtools (`make-foreign`), healthy and damaged each way its own
// self-test damages them, and passes the directory as -Dfat16-foreign. The
// verdict here must be the oracle's: healthy-* clean, damaged-* not. What was
// judged is written to judged.txt there, and the script requires every image
// in it: an option left unset makes this test do nothing, and the script is
// what says so.
test "a volume mkfs.vfat and mtools made: the check's verdict is the oracle's" {
    if (options.foreign_dir.len == 0) return;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, options.foreign_dir, .{ .iterate = true });
    defer dir.close(io);
    var judged: std.ArrayList(u8) = .empty;
    defer judged.deinit(testing.allocator);

    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (!std.mem.endsWith(u8, file.name, ".img")) continue;
        const bytes = try dir.readFileAlloc(io, file.name, testing.allocator, .limited(64 << 20));
        defer testing.allocator.free(bytes);
        var blk = virtio_blk.Block.inMemory(bytes);
        var scratch: [test_disk.sector]u8 align(16) = undefined;
        const healthy = std.mem.startsWith(u8, file.name, "healthy-");
        // A volume this machine refuses at mount (FAT32 mirroring off, a
        // version it does not know, a root out of range) is one it has found
        // wanting: the oracle must call it damaged too.
        var vol = disk_fat.Volume.mount(&blk, &scratch, 0) catch |e| {
            try judged.print(testing.allocator, "{s}: refused; {s}\n", .{ file.name, @errorName(e) });
            if (healthy) {
                std.debug.print("{s}", .{judged.items});
                return error.TestUnexpectedResult;
            }
            continue;
        };
        const seen = try testing.allocator.alloc(u8, vol.checkBytes());
        defer testing.allocator.free(seen);
        var r = test_disk.Report{};
        r.health = try vol.check(seen, &r, test_disk.Report.each);

        try judged.print(testing.allocator, "{s}: {s}", .{ file.name, if (r.health.clean()) "clean" else "damaged" });
        for (r.found[0..r.len]) |f| try judged.print(testing.allocator, "; {s} at '{s}' cluster {d}", .{ @tagName(f.problem), f.text(), f.cluster });
        try judged.append(testing.allocator, '\n');
        if (healthy != r.health.clean()) {
            std.debug.print("{s}", .{judged.items});
            return error.TestUnexpectedResult;
        }
        if (healthy) try testing.expect(r.health.files > 0);
    }
    try dir.writeFile(io, .{ .sub_path = "judged.txt", .data = judged.items });
}

// The rest of the FAT tests, in files of their own (metal-vmm QUEUE 173),
// run in this binary.
test {
    _ = @import("disk_fat_test_dirs.zig");
    _ = @import("disk_fat_test_fat32.zig");
    _ = @import("disk_fat_test_paths.zig");
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}
