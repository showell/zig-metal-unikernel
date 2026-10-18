//! `disk_fat.zig`'s FAT32 cases on a disk in memory, and its free-cluster
//! cursor (FAT32.md; split from disk_fat_test.zig by metal-vmm QUEUE 173).

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const virtio_blk = @import("virtio_blk.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;
const disk_fat_test = @import("disk_fat_test.zig");
const chainOf = disk_fat_test.chainOf;
const pattern = disk_fat_test.pattern;
const configs = disk_fat_test.configs;
const Disk = disk_fat_test.Disk;
const both = disk_fat_test.both;

// ---- FAT32's own cases (QUEUE item 17, FAT32.md "Judged against Linux") ------

/// A FAT32 volume big enough for files past cluster 65,535: about 44 MiB.
const big32 = Shape{ .sectors = 90_000, .kind = .fat32, .suffix = "-fat32" };

test "FAT32: files that start past cluster 65,535 are found by both halves of their cluster, and read back" {
    for (both) |cached| {
        const d = try Disk.make("fat32-high", big32, cached);
        defer d.deinit();
        try testing.expectEqual(disk_fat.Kind.fat32, d.vol.kind);
        // 33 MiB first: 67,584 clusters, so what follows starts past 65,535.
        const huge = try testing.allocator.alloc(u8, 33 << 20);
        defer testing.allocator.free(huge);
        _ = pattern(huge, 11);
        try d.vol.writeFile("data/huge.bin", huge);
        var data: [3000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..5) |k| {
            const p = try std.fmt.bufPrint(&path, "data/after/file-{d}.md", .{k});
            try d.vol.writeFile(p, pattern(&data, @intCast(k)));
            const e = try d.vol.open(p);
            try testing.expect(e.first_cluster > 0xFFFF);
            // Both halves on the disk, as the spec lays them out.
            const raw = d.bytes[e.lba * test_disk.sector + e.slot ..][0..32];
            const hi = std.mem.readInt(u16, raw[20..22], .little);
            const lo = std.mem.readInt(u16, raw[26..28], .little);
            try testing.expectEqual(e.first_cluster, (@as(u32, hi) << 16) | lo);
        }
        // And after a fresh mount, which reads them back from the disk.
        try d.mount(cached);
        for (0..5) |k| {
            const p = try std.fmt.bufPrint(&path, "data/after/file-{d}.md", .{k});
            try d.expectFile(p, pattern(&data, @intCast(k)));
        }
        try d.expectFile("data/huge.bin", huge);
        // An append past the end of a high file, and a directory made there.
        try d.vol.writeInto("data/after/file-0.md", 3000, "and more");
        _ = try d.vol.makePath("data/after/deeper");
        try d.vol.writeFile("data/after/deeper/x", "x");
        try d.expectFile("data/after/deeper/x", "x");
    }
}

test "FAT32: the root is a chain, and grows past its first cluster as FAT16's cannot" {
    for (both) |cached| {
        const d = try Disk.make("fat32-root", test_disk.small32, cached);
        defer d.deinit();
        var path: [64]u8 = undefined;
        // Three entries a name, sixteen a cluster: 60 names need 12 clusters.
        for (0..60) |k| {
            const p = try std.fmt.bufPrint(&path, "root-file-number-{d:0>3}.txt", .{k});
            try d.vol.writeFile(p, p);
        }
        const l = Layout.of(d.bytes);
        var chain: [64]disk_fat.Cluster = undefined;
        try testing.expect(chainOf(d, l.root_cluster, &chain).len >= 12);
        for (0..60) |k| {
            const p = try std.fmt.bufPrint(&path, "root-file-number-{d:0>3}.txt", .{k});
            try d.expectFile(p, p);
        }
        // A directory in the root has ".." = 0, as the spec spells the root.
        _ = try d.vol.makePath("sub");
        const sub = try d.vol.open("sub");
        const dotdot = d.bytes[(l.data_sector + sub.first_cluster - 2) * test_disk.sector + 32 ..][0..32];
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dotdot[26..28], .little));
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dotdot[20..22], .little));
    }
}

test "FAT32: an entry's reserved top four bits survive a write through it" {
    for (both) |cached| {
        const d = try Disk.make("fat32-reserved", test_disk.small32, cached);
        defer d.deinit();
        var data: [1024]u8 = undefined; // two clusters
        try d.vol.writeFile("f", pattern(&data, 2));
        const e = try d.vol.open("f");
        const l = Layout.of(d.bytes);
        var chain: [8]disk_fat.Cluster = undefined;
        const last = chainOf(d, e.first_cluster, &chain)[1];
        // Another tool set the reserved bits on the last entry, an end mark.
        for (0..2) |copy| l.set(d.bytes, copy, last, 0xA000_0000 | l.end());
        try d.mount(cached);
        // An append links a new cluster from that entry: its value changes,
        // and its top four bits must not.
        try d.vol.writeInto("f", 1024, "more");
        for (0..2) |copy| {
            const raw = std.mem.readInt(u32, d.bytes[l.fat_start + copy * l.fat_bytes + @as(usize, last) * 4 ..][0..4], .little);
            try testing.expectEqual(@as(u32, 0xA000_0000), raw & 0xF000_0000);
            try testing.expect(raw & 0x0FFF_FFFF != l.end());
        }
        var all: [1028]u8 = undefined;
        @memcpy(all[0..1024], &data);
        @memcpy(all[1024..], "more");
        try d.expectFile("f", &all);
    }
}

test "FAT32: FSInfo's free count and hint are marked unknown on the first write, in both copies" {
    for (both) |cached| {
        const d = try Disk.make("fat32-fsinfo", test_disk.small32, cached);
        defer d.deinit();
        // As a tool that kept them would leave them: set, and right.
        for ([_]usize{ 1, 7 }) |s| {
            std.mem.writeInt(u32, d.bytes[s * test_disk.sector + 488 ..][0..4], @intCast(d.free()), .little);
            std.mem.writeInt(u32, d.bytes[s * test_disk.sector + 492 ..][0..4], 3, .little);
        }
        try d.mount(cached);
        // Reading changes nothing.
        _ = d.vol.open("nothing") catch {};
        try testing.expectEqual(@as(u32, @intCast(d.free())), std.mem.readInt(u32, d.bytes[1 * test_disk.sector + 488 ..][0..4], .little));
        try d.vol.writeFile("x", "a write");
        for ([_]usize{ 1, 7 }) |s| {
            try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, d.bytes[s * test_disk.sector + 488 ..][0..4], .little));
            try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, d.bytes[s * test_disk.sector + 492 ..][0..4], .little));
        }
    }
}

test "FAT32: a volume this machine cannot write safely is refused at mount, each with its own error" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small32.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio_blk.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: disk_fat.Error };
    const cases = [_]Case{
        .{ .what = "mirroring off", .offset = 40, .value = 0x80, .size = 2, .want = disk_fat.Error.NotMirrored },
        .{ .what = "version 1", .offset = 42, .value = 1, .size = 2, .want = disk_fat.Error.FatVersion },
        .{ .what = "a root cluster past the volume", .offset = 44, .value = 0x0FFF_0000, .size = 4, .want = disk_fat.Error.BadRoot },
        .{ .what = "a root cluster of 1", .offset = 44, .value = 1, .size = 4, .want = disk_fat.Error.BadRoot },
        .{ .what = "a FAT16 root count on FAT32", .offset = 17, .value = 512, .size = 2, .want = disk_fat.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small32);
        if (c.size == 2) std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little) else std.mem.writeInt(u32, bytes[c.offset..][0..4], c.value, .little);
        testing.expectError(c.want, disk_fat.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // Past sector 2^32: the volume starts at sector 32 of the disk and says
    // it is nearly 2^32 sectors long.
    test_disk.format(bytes, test_disk.small32);
    @memcpy(bytes[32 * test_disk.sector ..][0..test_disk.sector], bytes[0..test_disk.sector]);
    std.mem.writeInt(u32, bytes[32 * test_disk.sector + 32 ..][0..4], 0xFFFF_FFF0, .little);
    try testing.expectError(disk_fat.Error.VolumeTooLarge, disk_fat.Volume.mount(&blk, &scratch, 32));
    // More clusters than FAT32's 28-bit numbers can name: their top numbers
    // are the bad-cluster and end-of-chain marks (QUEUE.md item 69). The
    // FAT is said to be big enough for them, so only the count refuses it.
    test_disk.format(bytes, test_disk.small32);
    std.mem.writeInt(u32, bytes[32..][0..4], 0xFFFF_FFF0, .little); // sectors in all
    std.mem.writeInt(u32, bytes[36..][0..4], 0x0200_0000, .little); // sectors per FAT
    try testing.expectError(disk_fat.Error.TooManyClusters, disk_fat.Volume.mount(&blk, &scratch, 0));
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small32);
    const v = try disk_fat.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(disk_fat.Kind.fat32, v.kind);
    try testing.expectEqual(@as(?u32, 0x3232_3232), v.serial);
}

test "FAT16: a boot sector this machine cannot trust is refused at mount, each with its own error" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio_blk.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    // Where the data begins on the volume test_disk.small makes, from its
    // own fields, so a total just past it, or short of it, can be written.
    test_disk.format(bytes, test_disk.small);
    const reserved = std.mem.readInt(u16, bytes[14..16], .little);
    const per_fat = std.mem.readInt(u16, bytes[22..24], .little);
    const root_sectors = std.mem.readInt(u16, bytes[17..19], .little) * 32 / test_disk.sector;
    const data_start: u32 = reserved + @as(u32, bytes[16]) * per_fat + root_sectors;

    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: disk_fat.Error };
    const cases = [_]Case{
        .{ .what = "no 55 AA", .offset = 510, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "1,024-byte sectors", .offset = 11, .value = 1024, .size = 2, .want = disk_fat.Error.NotFat16 },
        .{ .what = "no sectors a cluster", .offset = 13, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "255 sectors a cluster", .offset = 13, .value = 255, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no reserved sectors", .offset = 14, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no FATs", .offset = 16, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "three FATs", .offset = 16, .value = 3, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "a FAT of no sectors", .offset = 22, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no sectors at all", .offset = 19, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "a volume that ends before its data", .offset = 19, .value = data_start, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "too few clusters for FAT16 (FAT12)", .offset = 19, .value = data_start + 100, .size = 2, .want = disk_fat.Error.NotFat16 },
        .{ .what = "a FAT16 with no root entries", .offset = 17, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small);
        switch (c.size) {
            1 => bytes[c.offset] = @intCast(c.value),
            2 => std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little),
            else => unreachable,
        }
        // The 32-bit total is 0 on this shape, so the 16-bit one is the size.
        testing.expectError(c.want, disk_fat.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small);
    const v = try disk_fat.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(disk_fat.Kind.fat16, v.kind);
}

test "a FAT is held only in a buffer that holds all of it, and a file past 4 GiB is refused before anything is written" {
    const d = try Disk.make("refused-sizes", small, false);
    defer d.deinit();
    const short = try testing.allocator.alloc(u8, d.vol.fatBytes() - 1);
    defer testing.allocator.free(short);
    try testing.expectError(disk_fat.Error.TooBig, d.vol.cacheFat(short));
    // A file of 4 GiB: FAT's size field is 32 bits. The size is checked
    // before a byte of it is read, so the slice need not be backed.
    const huge = @as([*]const u8, @ptrFromInt(0x1000))[0 .. 1 << 32];
    try testing.expectError(disk_fat.Error.TooBig, d.vol.writeFile("data/huge", huge));
    try testing.expectEqual(d.free(), d.vol.free_clusters);
}

// ---- the free-cluster cursor (FAT32.md §8) -----------------------------------

/// Every cluster below the cursor is in use, read from the FAT on the disk:
/// what makes a search from the cursor choose what a search from 2 would.
fn expectCursorSound(d: *test_disk.Disk) !void {
    const l = Layout.of(d.bytes);
    var c: usize = 2;
    while (c < d.vol.alloc_hint) : (c += 1) {
        if (l.get(d.bytes, 0, c) == 0) {
            std.debug.print("cluster {d} is free, below the cursor at {d}\n", .{ c, d.vol.alloc_hint });
            return error.TestUnexpectedResult;
        }
    }
}

test "the cursor: every cluster below it stays in use, through writes, removes, a refused write and a remount" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("cursor", shape, cached);
        defer d.deinit();
        var data: [5000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..30) |k| {
            const p = try std.fmt.bufPrint(&path, "data/f{d}", .{k});
            try d.vol.writeFile(p, pattern(data[0 .. 100 + 150 * k], @intCast(k)));
            try expectCursorSound(d);
        }
        // Holes, low and high: the cursor goes back to the lowest, and the
        // next write fills from there, as a search from 2 would.
        for ([_]usize{ 3, 17, 4, 25 }) |k| {
            const p = try std.fmt.bufPrint(&path, "data/f{d}", .{k});
            const first = (try d.vol.open(p)).first_cluster;
            try d.vol.remove(p);
            try testing.expect(d.vol.alloc_hint <= first);
            try expectCursorSound(d);
        }
        const lowest_free = blk: {
            const l = Layout.of(d.bytes);
            var c: usize = 2;
            while (l.get(d.bytes, 0, c) != 0) c += 1;
            break :blk c;
        };
        try d.vol.writeFile("data/new", "fills the first hole");
        try testing.expectEqual(@as(disk_fat.Cluster, @intCast(lowest_free)), (try d.vol.open("data/new")).first_cluster);
        try expectCursorSound(d);
        try d.vol.removeTree("data");
        try expectCursorSound(d);
        try d.mount(cached);
        try testing.expectEqual(@as(disk_fat.Cluster, 2), d.vol.alloc_hint);
        try d.vol.writeFile("after-a-mount", "x");
        try expectCursorSound(d);
    }
}

test "the cursor: on a FAT32 volume 33 MiB full, a small write reads a few FAT sectors, not 67,000" {
    // The FAT on the disk, so each entry looked at is a read the device
    // counts.
    const d = try Disk.make("cursor-cost", big32, false);
    defer d.deinit();
    const huge = try testing.allocator.alloc(u8, 33 << 20);
    defer testing.allocator.free(huge);
    @memset(huge, 7);
    try d.vol.writeFile("data/huge.bin", huge);
    const before = d.blk.requests;
    try d.vol.writeFile("data/small.md", "a small file after a big one");
    const reads = d.blk.requests - before;
    // A search from 2 would read a FAT sector for each of the 67,584
    // clusters in use. From the cursor it is the directory walk and a handful.
    try testing.expect(reads < 200);
    try d.expectFile("data/small.md", "a small file after a big one");
}

test "a lookup reads a directory in bursts and stops at the name, finding what the sector-at-a-time walk finds" {
    // 4 KB clusters, so a directory's cluster is many sectors; FAT16, so the
    // fixed root is a run of its own as well.
    const shape = Shape{ .sectors = 65536, .sectors_per_cluster = 8, .suffix = "-burst" };
    const d = try Disk.make("dir-burst", shape, true);
    defer d.deinit();
    // The bursts alone: the directory cache (`dirs`) would answer the
    // lookups after the first, and has a test of its own below.
    d.vol.dirs = null;
    const dir = try d.vol.makePath("chat/conversation/sessions");
    // Long names, three slots each: two clusters and part of a third.
    var name: [40]u8 = undefined;
    const files = 60;
    for (0..files) |k| {
        const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
        try d.vol.writeFileIn(dir, n, n);
    }
    var cluster_burst: [8 * disk_fat.sector_size]u8 = undefined;
    const bursts = [_]?[]u8{ null, d.vol.dir_burst, &cluster_burst };
    var cost: [bursts.len]u64 = undefined;
    for (bursts, 0..) |b, i| {
        d.vol.dir_burst = b;
        const before = d.blk.requests;
        for (0..files) |k| {
            const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
            const e = (try d.vol.find(dir, n)).?;
            try testing.expectEqualStrings(n, e.text());
        }
        try testing.expect((try d.vol.find(dir, "not-there")) == null);
        cost[i] = d.blk.requests - before;
    }
    // A cluster at a request is about an eighth of a sector at a request.
    try testing.expect(cost[2] * 4 < cost[0]);
    try testing.expect(cost[1] < cost[0]);
    // The first name is in the first sector: one request, however long the
    // directory.
    d.vol.dir_burst = null;
    const before = d.blk.requests;
    _ = (try d.vol.find(dir, "a-session-with-a-long-name-0000")).?;
    try testing.expectEqual(@as(u64, 1), d.blk.requests - before);
    // The volume keeps the burst it was given, for deinit's check.
    d.vol.dir_burst = &d.dir_burst;
}

test "folders held in memory: a lookup made before reads no sector, and a write keeps what is held the disk's" {
    const shape = Shape{ .sectors = 65536, .sectors_per_cluster = 8, .suffix = "-dirs" };
    const d = try Disk.make("dir-cache", shape, true);
    defer d.deinit();
    var keys: [4096]u32 = undefined;
    var data: [4096 * disk_fat.sector_size]u8 = undefined;
    d.vol.cacheDirs(&keys, &data);
    defer d.vol.cacheDirs(&d.dir_keys, &d.dir_data);
    const dir = try d.vol.makePath("chat/conversation/sessions");
    var name: [40]u8 = undefined;
    for (0..60) |k| {
        const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
        try d.vol.writeFileIn(dir, n, n);
    }
    // The first round reads the folders; the second finds them in memory.
    for (0..2) |round| {
        const before = d.blk.requests;
        for (0..60) |k| {
            const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
            const e = (try d.vol.find(dir, n)).?;
            try testing.expectEqualStrings(n, e.text());
        }
        if (round == 1) try testing.expectEqual(@as(u64, 0), d.blk.requests - before);
    }
    // A file added, one removed, one renamed: what the folder holds now is
    // found from memory as the disk has it.
    try d.vol.writeFileIn(dir, "a new one", "new");
    try d.vol.remove("chat/conversation/sessions/a-session-with-a-long-name-0007");
    try d.vol.rename("chat/conversation/sessions/a-session-with-a-long-name-0009", "chat/conversation/sessions/renamed");
    try testing.expect((try d.vol.find(dir, "a new one")) != null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0007")) == null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0009")) == null);
    try testing.expect((try d.vol.find(dir, "renamed")) != null);
    // And the uncached walk agrees, entry for entry.
    const held = d.vol.dirs;
    d.vol.dirs = null;
    try testing.expect((try d.vol.find(dir, "a new one")) != null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0007")) == null);
    try testing.expect((try d.vol.find(dir, "renamed")) != null);
    d.vol.dirs = held;
}

// `remove` once took a directory's entry as it takes a file's, and left the
// directory's clusters and everything under it allocated, reachable from
// nothing (the cloud session's finding, item 77). It refuses one now, as
// Linux's unlink does (EISDIR; metal-vmm QUEUE B22), and the volume the
// refusal leaves checks clean on the way out (test_disk's deinit).
test "remove refuses a directory, and leaves the volume clean" {
    const d = try test_disk.Disk.make("remove-dir", test_disk.small, false);
    defer d.deinit();
    try d.vol.writeFile("data/dir/inside.txt", "under the directory");
    try testing.expectError(disk_fat.Error.IsDirectory, d.vol.remove("data/dir"));
}

test "a remove, and a tree's, that answers success left nothing behind: a read that lies on the second walk is an error (metal-vmm QUEUE 172)" {
    // Each request a remove makes after its lookup, read back as other bytes
    // (the first a zero: "nothing further in this directory").
    var n: u64 = 0;
    while (n < 40) : (n += 1) {
        inline for (.{ "data/X.DAT", "data/sub" }) |path| {
            // Lied to on purpose: a leak is allowed ("limit-"), a false "done" is not.
            const d = try test_disk.Disk.make("limit-remove-lies", test_disk.small, false);
            defer d.deinit();
            try d.vol.writeFile("data/X.DAT", "a file to remove");
            try d.vol.writeFile("data/sub/inner.txt", "a tree to remove");
            // Past the lookup that finds it (a lie there is absence, which
            // removeTree calls done, and remove refuses): the walk after.
            const before_lookup = d.blk.requests;
            _ = try d.vol.open(path);
            const lookup = d.blk.requests - before_lookup;
            d.blk.fault = .{ .at = d.blk.requests + lookup + n, .kind = .garbage, .seed = 0 };
            const removed = if (comptime std.mem.eql(u8, path, "data/X.DAT")) d.vol.remove(path) else d.vol.removeTree(path);
            d.blk.fault = null;
            if (removed) |_| {
                // Said done: the next boot finds it gone.
                try d.mount(false);
                if (d.vol.open(path)) |_| {
                    std.debug.print("{s}: request {d} read as other bytes, and the remove said done\n", .{ path, n });
                    return error.TestUnexpectedResult;
                } else |e| try testing.expectEqual(disk_fat.Error.NotFound, e);
            } else |_| {}
        }
    }
}

// ---- a run of clusters as one request, as large as the device takes (metal-vmm QUEUE 178) ----

/// Two sectors a cluster, FAT16: the root is before the data, so every
/// write into the data is a file's.
const two_sector_clusters = Shape{ .sectors = 20_000, .sectors_per_cluster = 2 };

/// What a disk is asked in the data region: requests, and the largest.
const DataRequests = struct {
    data_start: u64,
    write: bool,
    count: u32 = 0,
    largest: u32 = 0,
    fn each(context: *anyopaque, write: bool, lba: u64, sectors: u32) void {
        const r: *DataRequests = @ptrCast(@alignCast(context));
        if (write != r.write or lba < r.data_start) return;
        r.count += 1;
        r.largest = @max(r.largest, sectors);
    }
};

fn watchData(d: *test_disk.Disk, r: *DataRequests) void {
    d.blk.observe = .{ .context = r, .each = DataRequests.each };
}

test "a run of contiguous clusters is one request up to the device's most, and one cluster more is two (metal-vmm QUEUE 178)" {
    const d = try Disk.make("runs-most", two_sector_clusters, true);
    defer d.deinit();
    defer d.blk.observe = null;
    const cluster = 2 * disk_fat.sector_size;
    var buf: [5 * cluster]u8 = undefined;
    // A device that takes four clusters a request.
    d.blk.most_sectors = 8;
    for ([_]struct { clusters: usize, requests: u32 }{ .{ .clusters = 4, .requests = 1 }, .{ .clusters = 5, .requests = 2 } }) |c| {
        var r: DataRequests = .{ .data_start = d.vol.data_start, .write = true };
        watchData(d, &r);
        try d.vol.writeFile("run.bin", pattern(buf[0 .. c.clusters * cluster], @intCast(c.clusters)));
        try testing.expectEqual(c.requests, r.count);
        try testing.expectEqual(@as(u32, 8), r.largest);
        try d.expectFile("run.bin", buf[0 .. c.clusters * cluster]);
        try d.vol.remove("run.bin");
    }
}

test "the most a request carries is 1 MiB unless the device says less: a 1 MiB run is one write and one read, a cluster more is two (metal-vmm QUEUE 178)" {
    const d = try Disk.make("runs-mib", two_sector_clusters, true);
    defer d.deinit();
    defer d.blk.observe = null;
    try testing.expectEqual(@as(u32, 2048), d.blk.most_sectors);
    const mib = 1 << 20;
    const bytes = try testing.allocator.alloc(u8, mib + 2 * disk_fat.sector_size);
    defer testing.allocator.free(bytes);
    for ([_]struct { len: usize, requests: u32 }{ .{ .len = mib, .requests = 1 }, .{ .len = bytes.len, .requests = 2 } }) |c| {
        var w: DataRequests = .{ .data_start = d.vol.data_start, .write = true };
        watchData(d, &w);
        try d.vol.writeFile("big.bin", pattern(bytes[0..c.len], 7));
        try testing.expectEqual(c.requests, w.count);
        var r: DataRequests = .{ .data_start = d.vol.data_start, .write = false };
        watchData(d, &r);
        const entry = try d.vol.open("big.bin");
        const back = try testing.allocator.alloc(u8, c.len);
        defer testing.allocator.free(back);
        try testing.expectEqual(c.len, try d.vol.readFile(entry, back));
        try testing.expectEqual(c.requests, r.count);
        try testing.expectEqualSlices(u8, bytes[0..c.len], back);
        try d.vol.remove("big.bin");
    }
}

test "a run that ends at the volume's last cluster is written and read whole (metal-vmm QUEUE 178)" {
    const d = try Disk.make("runs-end", two_sector_clusters, true);
    defer d.deinit();
    const cluster: u64 = 2 * disk_fat.sector_size;
    // A bulk file up to the reserve (which a bulk write may not take), then
    // small files through it: the last of them runs to the volume's end.
    const bulk = (try d.vol.space()).free - @as(u64, d.vol.reserve_clusters) * cluster;
    const bytes = try testing.allocator.alloc(u8, disk_fat.Volume.small_bytes);
    defer testing.allocator.free(bytes);
    const big = try testing.allocator.alloc(u8, @intCast(bulk));
    defer testing.allocator.free(big);
    try d.vol.writeFile("bulk.bin", pattern(big, 1));
    var name_buf: [16]u8 = undefined;
    var k: u8 = 0;
    var last: []const u8 = "";
    var last_len: usize = 0;
    while ((try d.vol.space()).free > 0) : (k += 1) {
        last_len = @intCast(@min((try d.vol.space()).free, bytes.len));
        last = try std.fmt.bufPrint(&name_buf, "small{d}.bin", .{k});
        try d.vol.writeFile(last, pattern(bytes[0..last_len], k));
    }
    try testing.expect(k > 1);
    try d.expectFile(last, pattern(bytes[0..last_len], k - 1));
    try d.expectFile("bulk.bin", big);
}

test "a device whose request is smaller than a cluster is refused at mount, never a cluster split (metal-vmm QUEUE 178)" {
    const d = try Disk.make("runs-small-device", two_sector_clusters, false);
    defer d.deinit();
    d.blk.most_sectors = 1;
    try testing.expectError(disk_fat.Error.RequestSmallerThanCluster, d.mount(false));
    // One cluster a request is enough.
    d.blk.most_sectors = 2;
    try d.mount(false);
}

test "a request's most is ours, 1 MiB, or less where the device says less, never more (metal-vmm QUEUE 178)" {
    try testing.expectEqual(@as(u32, 2048), virtio_blk.Block.mostSectors(null));
    try testing.expectEqual(@as(u32, 2048), virtio_blk.Block.mostSectors(1 << 20));
    try testing.expectEqual(@as(u32, 2048), virtio_blk.Block.mostSectors((1 << 20) + 512));
    try testing.expectEqual(@as(u32, 2047), virtio_blk.Block.mostSectors((1 << 20) - 512));
    try testing.expectEqual(@as(u32, 1), virtio_blk.Block.mostSectors(1023));
    try testing.expectEqual(@as(u32, 0), virtio_blk.Block.mostSectors(511));
}

// ---- the FAT written as runs, each sector once (metal-vmm QUEUE 179) ----

/// Writes into the FAT's copies, by copy: requests, and the sectors they carry.
const FatWrites = struct {
    blk: *virtio_blk.Block,
    fat_start: u64,
    per_fat: u64,
    copies: [2]u32 = .{ 0, 0 },
    sectors: [2]u32 = .{ 0, 0 },
    /// The request number of the first write into the first copy, and of
    /// the second.
    first_at: ?u64 = null,
    second_at: ?u64 = null,
    fn each(context: *anyopaque, write: bool, lba: u64, sectors: u32) void {
        const r: *FatWrites = @ptrCast(@alignCast(context));
        if (!write or lba < r.fat_start or lba >= r.fat_start + 2 * r.per_fat) return;
        const c: usize = @intCast((lba - r.fat_start) / r.per_fat);
        r.copies[c] += 1;
        r.sectors[c] += sectors;
        if (c == 0 and r.first_at != null and r.second_at == null) r.second_at = r.blk.requests - 1;
        if (c == 0 and r.first_at == null) r.first_at = r.blk.requests - 1;
    }
    fn watch(d: *test_disk.Disk) FatWrites {
        return .{ .blk = &d.blk, .fat_start = d.vol.fat_start, .per_fat = d.vol.sectors_per_fat };
    }
    fn on(r: *FatWrites, d: *test_disk.Disk) void {
        d.blk.observe = .{ .context = r, .each = each };
    }
};

/// Clusters a FAT sector holds.
fn perFatSector(d: *test_disk.Disk) u32 {
    return disk_fat.sector_size / d.vol.entryBytes();
}

/// A file of `clusters` two-sector clusters.
fn clusterFile(d: *test_disk.Disk, name: []const u8, clusters: u32, seed: u8) !void {
    const bytes = try testing.allocator.alloc(u8, @as(usize, clusters) * 2 * disk_fat.sector_size);
    defer testing.allocator.free(bytes);
    try d.vol.writeFile(name, pattern(bytes, seed));
    try expectClusterFile(d, name, clusters, seed);
}

fn expectClusterFile(d: *test_disk.Disk, name: []const u8, clusters: u32, seed: u8) !void {
    const bytes = try testing.allocator.alloc(u8, @as(usize, clusters) * 2 * disk_fat.sector_size);
    defer testing.allocator.free(bytes);
    try d.expectFile(name, pattern(bytes, seed));
}

test "a chain's FAT sectors are one request a copy up to the device's most, and one sector more is two (metal-vmm QUEUE 179)" {
    for ([_]struct { sectors: u32, requests: u32 }{ .{ .sectors = 4, .requests = 1 }, .{ .sectors = 5, .requests = 2 } }) |c| {
        const d = try Disk.make("fat-runs-most", two_sector_clusters, true);
        defer d.deinit();
        defer d.blk.observe = null;
        d.blk.most_sectors = 4;
        const start = @max(d.vol.alloc_hint, 2);
        // A chain from the first free cluster to the last of FAT sector `c.sectors - 1`.
        const clusters = c.sectors * perFatSector(d) - start;
        var w = FatWrites.watch(d);
        w.on(d);
        try clusterFile(d, "chain.bin", clusters, 5);
        try testing.expectEqual([2]u32{ c.requests, c.requests }, w.copies);
        // Each sector once.
        try testing.expectEqual([2]u32{ c.sectors, c.sectors }, w.sectors);
    }
}

/// FAT sector 0 taken and given back, sector 1 full: the next chain of
/// more than sector 0 holds skips sector 1.
fn gapDisk(label: []const u8) !*test_disk.Disk {
    const d = try Disk.make(label, two_sector_clusters, true);
    errdefer d.deinit();
    const per = perFatSector(d);
    const start = @max(d.vol.alloc_hint, 2);
    try clusterFile(d, "first.bin", per - start, 1);
    try clusterFile(d, "middle.bin", per, 2);
    try d.vol.remove("first.bin");
    return d;
}

test "changed FAT sectors with a full one between them are two runs, and a refusal of the second, the first landed, leaves a counted leak (metal-vmm QUEUE 179)" {
    var second_at: u64 = undefined;
    var split: u32 = undefined;
    {
        const d = try gapDisk("fat-runs-gap");
        defer d.deinit();
        defer d.blk.observe = null;
        // All of sector 0's, then ten in sector 2.
        split = perFatSector(d) - @max(d.vol.alloc_hint, 2) + 10;
        var w = FatWrites.watch(d);
        w.on(d);
        try clusterFile(d, "split.bin", split, 3);
        try testing.expectEqual([2]u32{ 2, 2 }, w.copies);
        try testing.expectEqual([2]u32{ 2, 2 }, w.sectors);
        try expectClusterFile(d, "middle.bin", perFatSector(d), 2);
        second_at = w.second_at.?;
    }
    // The second run refused, the first landed: landed in part, so the
    // first copy is written again and the chain left a counted leak.
    {
        const d = try gapDisk("damaged-fat-runs-gap-refused");
        defer d.deinit();
        d.blk.fault = .{ .at = second_at, .kind = .fails };
        const bytes = try testing.allocator.alloc(u8, @as(usize, split) * 2 * disk_fat.sector_size);
        defer testing.allocator.free(bytes);
        try testing.expectError(disk_fat.Error.WriteFailed, d.vol.writeFile("split.bin", pattern(bytes, 3)));
        d.blk.fault = null;
        try testing.expectEqual(@as(u64, split), d.vol.leaked_clusters);
        try testing.expect(d.fatsAgree());
        try d.expectKept();
        const r = try d.check();
        // Leaked as two runs of clusters, sector 0's and sector 2's.
        const per = perFatSector(d);
        try r.expect(&.{
            .{ .problem = .leaked, .cluster = 2, .count = split - 10 },
            .{ .problem = .leaked, .cluster = 2 * per, .count = 10 },
        });
        try expectClusterFile(d, "middle.bin", perFatSector(d), 2);
    }
}

test "a chain whose last link lands in the next FAT sector writes both sectors once, as one run (metal-vmm QUEUE 179)" {
    const d = try Disk.make("fat-runs-link", two_sector_clusters, true);
    defer d.deinit();
    defer d.blk.observe = null;
    const per = perFatSector(d);
    const start = @max(d.vol.alloc_hint, 2);
    // Up to five before sector 0's end.
    try clusterFile(d, "before.bin", per - start - 5, 1);
    var w = FatWrites.watch(d);
    w.on(d);
    // Five in sector 0, the last in sector 1.
    try clusterFile(d, "across.bin", 6, 2);
    try testing.expectEqual([2]u32{ 1, 1 }, w.copies);
    try testing.expectEqual([2]u32{ 2, 2 }, w.sectors);
}

/// The request number of the first copy's FAT run in writing `clusters`
/// to a fresh disk: found on one, failed on another made the same.
fn firstCopyRunAt(clusters: u32) !u64 {
    const d = try Disk.make("fat-runs-probe", two_sector_clusters, true);
    defer d.deinit();
    defer d.blk.observe = null;
    var w = FatWrites.watch(d);
    w.on(d);
    try clusterFile(d, "f.bin", clusters, 9);
    return w.first_at.?;
}

test "a FAT run whose first copy's write fails, and whose second's does not (metal-vmm QUEUE 179)" {
    const clusters = 300; // two FAT sectors
    const at = try firstCopyRunAt(clusters);
    // The second copy refused: saved, the copies apart until a mount mends them.
    {
        const d = try Disk.make("damaged-fat-runs-second", two_sector_clusters, true);
        defer d.deinit();
        d.blk.fault = .{ .at = at + 1, .kind = .fails };
        try clusterFile(d, "f.bin", clusters, 9);
        try testing.expectEqual(@as(u64, 1), d.vol.fat_copies_failed);
        try testing.expect(!d.fatsAgree());
        d.blk.fault = null;
        try d.mount(true);
        try testing.expect(d.fatsAgree());
        try expectClusterFile(d, "f.bin", clusters, 9);
    }
    // The first copy refused, nothing landed: nothing taken, nothing left.
    {
        const d = try Disk.make("fat-runs-first", two_sector_clusters, true);
        defer d.deinit();
        const free = d.vol.free_clusters;
        d.blk.fault = .{ .at = at, .kind = .fails };
        const bytes = try testing.allocator.alloc(u8, clusters * 2 * disk_fat.sector_size);
        defer testing.allocator.free(bytes);
        try testing.expectError(disk_fat.Error.WriteFailed, d.vol.writeFile("f.bin", pattern(bytes, 9)));
        d.blk.fault = null;
        try testing.expectEqual(free, d.vol.free_clusters);
        try testing.expect(d.fatsAgree());
        try d.expectKept();
    }
    // The first copy cut short by a stop: its first sector landed, its
    // second not, and nothing after. Read as a cut-short sector is: nothing
    // points at the chain, and nothing is damaged.
    {
        const d = try Disk.make("damaged-fat-runs-torn", two_sector_clusters, true);
        defer d.deinit();
        d.blk.fault = .{ .at = at, .kind = .torn };
        d.blk.fail_after = at + 1;
        const bytes = try testing.allocator.alloc(u8, clusters * 2 * disk_fat.sector_size);
        defer testing.allocator.free(bytes);
        try testing.expect(std.meta.isError(d.vol.writeFile("f.bin", pattern(bytes, 9))));
        d.blk.fault = null;
        d.blk.fail_after = null;
        try d.mount(true);
        const r = try d.check();
        // Lost clusters at most (the mount may trust the copy the cut left
        // untouched, and mend the other), never damage.
        for (r.found[0..r.len]) |f| try testing.expect(!f.problem.damage());
        try d.expectKept();
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("f.bin"));
    }
}

// ---- a lie or a cut inside an upload-sized FAT run (metal-vmm QUEUE 181) ----

/// Twenty MB on `small32`: a chain of 40,960 clusters, 320 FAT sectors, one
/// run a copy: more than the mount weighs sector by sector.
const upload_clusters = 40_960;

fn uploadBytes() ![]u8 {
    const bytes = try testing.allocator.alloc(u8, upload_clusters * disk_fat.sector_size);
    return pattern(bytes, 0x5A);
}

/// The request number of the upload's first-copy FAT run, on a fresh `small32`.
fn uploadRunAt() !u64 {
    const d = try Disk.make("upload-probe", test_disk.small32, true);
    defer d.deinit();
    defer d.blk.observe = null;
    const bytes = try uploadBytes();
    defer testing.allocator.free(bytes);
    var w = FatWrites.watch(d);
    w.on(d);
    try d.vol.writeFile("up.bin", bytes);
    try testing.expect(w.sectors[0] > disk_fat.Volume.max_weighed_sectors);
    return w.first_at.?;
}

test "one lie to the first copy's upload-sized FAT run costs nothing: the mount keeps the copy that checks clean, and the file reads whole (metal-vmm QUEUE 181)" {
    const at = try uploadRunAt();
    const bytes = try uploadBytes();
    defer testing.allocator.free(bytes);
    for ([_]@FieldType(virtio_blk.Block.Fault, "kind"){ .lands_nothing, .torn, .torn_tail }) |lie| {
        const d = try Disk.make("upload-lie", test_disk.small32, true);
        defer d.deinit();
        d.blk.fault = .{ .at = at, .kind = lie };
        try d.vol.writeFile("up.bin", bytes);
        d.blk.fault = null;
        try d.mount(true);
        try testing.expectEqual(@as(u32, 1), d.trusted);
        try d.expectFile("up.bin", bytes);
        try testing.expect(d.fatsAgree());
        const r = try d.check();
        try r.expect(&.{});
        // And the next write is a write like any other.
        try d.vol.writeFile("next.bin", bytes[0 .. 4 << 20]);
        try d.expectFile("next.bin", bytes[0 .. 4 << 20]);
    }
}

test "a cut inside the first copy's upload-sized FAT run leaves nothing: the mount keeps the untouched copy (metal-vmm QUEUE 181)" {
    const at = try uploadRunAt();
    const bytes = try uploadBytes();
    defer testing.allocator.free(bytes);
    const d = try Disk.make("upload-cut", test_disk.small32, true);
    defer d.deinit();
    const free = d.vol.free_clusters;
    d.blk.fault = .{ .at = at, .kind = .torn };
    d.blk.fail_after = at + 1;
    try testing.expect(std.meta.isError(d.vol.writeFile("up.bin", bytes)));
    d.blk.fault = null;
    d.blk.fail_after = null;
    try d.mount(true);
    try testing.expectEqual(@as(u32, 1), d.trusted);
    try testing.expectEqual(free, d.vol.free_clusters);
    try d.expectKept();
    const r = try d.check();
    try r.expect(&.{});
}

test "a FAT run that landed and answered failure is given back as runs, not a cluster at a time (metal-vmm QUEUE 181)" {
    const clusters = 300; // two FAT sectors, one run
    const at = try firstCopyRunAt(clusters);
    const d = try Disk.make("fat-runs-landed", two_sector_clusters, true);
    defer d.deinit();
    defer d.blk.observe = null;
    const free = d.vol.free_clusters;
    d.blk.fault = .{ .at = at, .kind = .lands_and_fails };
    var w = FatWrites.watch(d);
    w.on(d);
    const bytes = try testing.allocator.alloc(u8, clusters * 2 * disk_fat.sector_size);
    defer testing.allocator.free(bytes);
    try testing.expectError(disk_fat.Error.WriteFailed, d.vol.writeFile("f.bin", pattern(bytes, 9)));
    d.blk.fault = null;
    // Taken (the run that landed, then copy 1), then given back (copy 0, copy 1).
    try testing.expectEqual([2]u32{ 2, 2 }, w.copies);
    try testing.expectEqual(free, d.vol.free_clusters);
    try testing.expect(d.fatsAgree());
    try d.expectKept();
}

test "virtio-blk's size_max is per segment: a request carries it times the segments, and 0 is unset (metal-vmm QUEUE 180.2)" {
    const most = virtio_blk.Block.mostSectorsBlk;
    // Unset, or 0: ours.
    try testing.expectEqual(@as(u32, 2048), most(null, null));
    try testing.expectEqual(@as(u32, 2048), most(0, 8));
    // One segment where seg_max is not said, as Linux takes it.
    try testing.expectEqual(@as(u32, 8), most(4096, null));
    // Up to seg_max segments, at most the six a request's chain holds.
    try testing.expectEqual(@as(u32, 24), most(4096, 3));
    try testing.expectEqual(@as(u32, 48), most(4096, 6));
    try testing.expectEqual(@as(u32, 48), most(4096, 126));
    // Never more than ours.
    try testing.expectEqual(@as(u32, 2048), most(1 << 20, 126));
    // A size_max under a cluster served by segments (before 180.2, refused at mount).
    try testing.expect(most(512, 126) >= 2);
}

test "a file whose size is near 4 GiB is checked, not a panic: its clusters are counted in 64 bits (metal-vmm QUEUE 182.3)" {
    for ([_]u32{ std.math.maxInt(u32) - 512 * 4 + 1, std.math.maxInt(u32) }) |size| {
        const d = try Disk.make("damaged-near-4gib", test_disk.small32, true);
        defer d.deinit();
        try d.vol.writeFile("BIG.BIN", "x");
        // The entry's size, raised by hand: a FAT32 file may be that big.
        const at = std.mem.indexOf(u8, d.bytes, "BIG     BIN").?;
        std.mem.writeInt(u32, d.bytes[at + 28 ..][0..4], size, .little);
        try d.mount(true);
        const r = try d.check();
        try r.expect(&.{.{ .problem = .short, .path = "/BIG.BIN", .cluster = (try d.vol.open("BIG.BIN")).first_cluster, .count = 1 }});
    }
}

test "a FAT longer than 32-bit entry numbers reach is refused at mount, in the driver itself (metal-vmm QUEUE 182)" {
    const d = try Disk.make("limit-fat-length", test_disk.small32, false);
    defer d.deinit();
    const b = d.bytes[0..disk_fat.sector_size];
    const saved = b.*;
    defer b.* = saved;
    // A boot sector that says a volume of nearly 2^32 sectors, 128 to a
    // cluster, and a FAT of `spf` sectors: 2^25 of them is 2^32 entries,
    // the last numbered 2^32 - 1; one more and its numbers overflow u32.
    b[13] = 128;
    std.mem.writeInt(u32, b[32..36], 0xFFFF_0000, .little);
    for ([_]struct { spf: u32, ok: bool }{ .{ .spf = 1 << 25, .ok = true }, .{ .spf = (1 << 25) + 1, .ok = false } }) |c| {
        std.mem.writeInt(u32, b[36..40], c.spf, .little);
        var scratch: [disk_fat.sector_size]u8 align(16) = undefined;
        const got = disk_fat.Volume.mount(&d.blk, &scratch, 0);
        // At the edge the bound lets it by, and the mount reads on, past
        // this small disk; one more is refused as a boot sector.
        if (c.ok) try testing.expectError(disk_fat.Error.ReadFailed, got) else try testing.expectError(disk_fat.Error.BadBootSector, got);
    }
}

test "a virtio-blk request that would need more segments than its chain holds is refused, never built past the ring (metal-vmm QUEUE 187.2)" {
    const n = virtio_blk.Block.segmentsFor;
    try testing.expectEqual(@as(u32, 1), n(512, null));
    try testing.expectEqual(@as(u32, 1), n(512, 512));
    try testing.expectEqual(@as(u32, 6), n(512, 86));
    try testing.expectEqual(@as(u32, 7), n(512, 85));
    try testing.expectEqual(@as(u32, 2), n(4096, 4095));
    try testing.expect(n(512, 85) > virtio_blk.Block.most_segments);
}

// ---- an overwrite reads its commit back (metal-vmm QUEUE 188.1) ----

/// Request numbers of writes to one sector.
const SectorWrites = struct {
    blk: *virtio_blk.Block,
    lba: u64,
    at: ?u64 = null,
    fn each(context: *anyopaque, write: bool, lba: u64, _: u32) void {
        const r: *SectorWrites = @ptrCast(@alignCast(context));
        if (write and lba == r.lba and r.at == null) r.at = r.blk.requests - 1;
    }
};

test "an overwrite whose commit lands nothing keeps the old file whole, never broken; read back past the directory cache (metal-vmm QUEUE 188.1)" {
    for (configs) |cfg| {
        const old = try testing.allocator.alloc(u8, 20 * 1024);
        defer testing.allocator.free(old);
        const new = try testing.allocator.alloc(u8, 30 * 1024);
        defer testing.allocator.free(new);
        _ = pattern(old, 1);
        _ = pattern(new, 2);
        // The commit's request, found on a disk made the same.
        var commit_at: u64 = undefined;
        {
            const d = try Disk.make("commit-probe", cfg.shape, cfg.cached);
            defer d.deinit();
            defer d.blk.observe = null;
            try d.vol.writeFile("f.bin", old);
            var w: SectorWrites = .{ .blk = &d.blk, .lba = (try d.vol.open("f.bin")).lba };
            d.blk.observe = .{ .context = &w, .each = SectorWrites.each };
            try d.vol.writeFile("f.bin", new);
            try d.expectFile("f.bin", new);
            commit_at = w.at.?;
        }
        const d = try Disk.make("damaged-commit-lost", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("f.bin", old);
        _ = try d.vol.open("f.bin"); // the probe's one read, so the numbers agree
        d.blk.fault = .{ .at = commit_at, .kind = .lands_nothing };
        try testing.expectError(disk_fat.Error.WriteFailed, d.vol.writeFile("f.bin", new));
        d.blk.fault = null;
        // This boot reads the old file, and so does the next.
        try d.expectFile("f.bin", old);
        try d.mount(cfg.cached);
        try d.expectFile("f.bin", old);
        const r = try d.check();
        try r.expect(&.{});
        try d.expectKept();
    }
}

// ---- an unweighed mount refuses writes (metal-vmm QUEUE 188.2) ----

/// The request number of the first read in [lo, hi), from `from` on.
const CopyReads = struct {
    blk: *virtio_blk.Block,
    lo: u64,
    hi: u64,
    from: u64,
    at: ?u64 = null,
    fn each(context: *anyopaque, write: bool, lba: u64, _: u32) void {
        const r: *CopyReads = @ptrCast(@alignCast(context));
        if (!write and lba >= r.lo and lba < r.hi and r.at == null and r.blk.requests - 1 >= r.from) r.at = r.blk.requests - 1;
    }
};

test "a mount whose weighing of apart copies fails refuses every write, writes nothing, and is writable again once a weighing succeeds (metal-vmm QUEUE 188.2)" {
    // Whole (an upload's run, 320 sectors apart) and one sector apart (178's form).
    for ([_]u32{ upload_clusters, 300 }) |clusters| {
        const bytes = try testing.allocator.alloc(u8, @as(usize, clusters) * disk_fat.sector_size);
        defer testing.allocator.free(bytes);
        _ = pattern(bytes, 0x21);
        // The lie, and the mount's first read of the second copy, found on
        // a disk made the same.
        var lie_at: u64 = undefined;
        var weigh_read_at: u64 = undefined;
        {
            const d = try Disk.make("refuse-probe", test_disk.small32, true);
            defer d.deinit();
            defer d.blk.observe = null;
            var w = FatWrites.watch(d);
            w.on(d);
            try d.vol.writeFile("up.bin", bytes);
            lie_at = w.first_at.?;
        }
        {
            const d = try Disk.make("refuse-probe2", test_disk.small32, true);
            defer d.deinit();
            defer d.blk.observe = null;
            d.blk.fault = .{ .at = lie_at, .kind = .lands_nothing };
            try d.vol.writeFile("up.bin", bytes);
            d.blk.fault = null;
            // The weighing's check: its first read of a directory, in the data.
            var r: CopyReads = .{ .blk = &d.blk, .lo = d.vol.data_start, .hi = std.math.maxInt(u64), .from = d.blk.requests };
            d.blk.observe = .{ .context = &r, .each = CopyReads.each };
            try d.mount(true);
            weigh_read_at = r.at.?;
        }
        const d = try Disk.make("damaged-refuse", test_disk.small32, true);
        defer d.deinit();
        d.blk.fault = .{ .at = lie_at, .kind = .lands_nothing };
        try d.vol.writeFile("up.bin", bytes);
        // The mount's weighing fails part way: unweighed.
        d.blk.fault = .{ .at = weigh_read_at, .kind = .fails };
        try d.mount(true);
        d.blk.fault = null;
        try testing.expect(d.vol.writes == .refused);
        // Every write refused, and nothing written.
        const writes = d.blk.writes;
        try testing.expectError(disk_fat.Error.WritesRefused, d.vol.writeFile("next.bin", bytes[0..4096]));
        try testing.expectError(disk_fat.Error.WritesRefused, d.vol.remove("up.bin"));
        try testing.expectError(disk_fat.Error.WritesRefused, d.vol.rename("up.bin", "moved.bin"));
        try testing.expectError(disk_fat.Error.WritesRefused, d.vol.makePath("dir"));
        try testing.expectError(disk_fat.Error.WritesRefused, d.vol.writeInto("up.bin", 0, "x"));
        try testing.expectEqual(writes, d.blk.writes);
        // Weighed again: the second copy is the FAT, the file whole, and
        // the volume writable.
        const m = try d.vol.reweigh(d.check_room.?);
        try testing.expectEqual(.weighed, m.found);
        try testing.expect(d.vol.writes == .taken);
        try d.expectFile("up.bin", bytes);
        try d.vol.writeFile("next.bin", bytes[0..4096]);
        try d.expectFile("next.bin", bytes[0..4096]);
    }
}
