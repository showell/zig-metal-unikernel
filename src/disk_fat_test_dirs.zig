//! `disk_fat.zig`'s directories and names on a disk in memory: a directory at
//! FAT's limit, the NT case bits, a rewrite that keeps its name, a file near
//! 4 GiB, a file that never replaces a directory, rename, mutation testing's
//! survivors, and the kept free count (split from disk_fat_test.zig by
//! metal-vmm QUEUE 173; its header says how the volumes are made).

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Layout = test_disk.Layout;
const small = test_disk.small;
const disk_fat_test = @import("disk_fat_test.zig");
const setEntry = disk_fat_test.setEntry;
const pattern = disk_fat_test.pattern;
const chainOf = disk_fat_test.chainOf;
const both = disk_fat_test.both;
const formats = disk_fat_test.formats;
const Disk = disk_fat_test.Disk;
const configs = disk_fat_test.configs;

// ---- a directory at FAT's limit (QUEUE item 9) -----------------------------

/// Makes `path` a directory of `clusters` clusters with every entry in use:
/// "." and "..", then empty files F0000000, F0000001, ..., one 8.3 entry
/// each. Laid straight onto the disk, in both FATs: writing 65,536 names
/// through disk_fat.zig would scan the directory from its start for each one.
fn fullDirectory(d: *test_disk.Disk, cached: bool, path: []const u8, clusters: usize) !void {
    const first = try d.vol.makePath(path);
    const l = Layout.of(d.bytes);
    try testing.expectEqual(@as(u8, 1), d.bytes[13]); // one sector a cluster, below
    const fat = struct {
        fn set(bytes: []u8, at: Layout, c: usize, v: u32) void {
            for (0..2) |copy| at.set(bytes, copy, c, v);
        }
    };
    var last: usize = first;
    var candidate: usize = 2;
    for (1..clusters) |_| {
        while (l.get(d.bytes, 0, candidate) != 0) candidate += 1;
        fat.set(d.bytes, l, last, @intCast(candidate));
        fat.set(d.bytes, l, candidate, l.end());
        last = candidate;
    }
    var name: u32 = 0;
    var c: usize = first;
    for (0..clusters) |k| {
        const sector = d.bytes[(l.data_sector + c - 2) * test_disk.sector ..][0..test_disk.sector];
        for (0..test_disk.sector / 32) |slot| {
            if (k == 0 and slot < 2) continue; // "." and ".."
            const e = sector[slot * 32 ..][0..32];
            @memset(e, 0);
            _ = std.fmt.bufPrint(e[0..8], "F{X:0>7}", .{name}) catch unreachable;
            @memset(e[8..11], ' ');
            e[11] = 0x20; // an archive bit: a plain file
            name += 1;
        }
        c = l.get(d.bytes, 0, c);
    }
    try d.mount(cached);
}

test "a directory grows to FAT's limit of 65,536 entries, and no further" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("dirlimit", shape, cached);
        defer d.deinit();
        const per_cluster = test_disk.sector / 32;
        const limit = disk_fat.Volume.max_dir_entries / per_cluster; // 4,096 clusters
        // One cluster short of the limit, and full: the next name grows it
        // to exactly the limit.
        try fullDirectory(d, cached, "data/big", limit - 1);
        try d.vol.writeFile("data/big/one-more.md", "fits");
        try d.expectFile("data/big/one-more.md", "fits");
        var chain: [4200]disk_fat.Cluster = undefined;
        try testing.expectEqual(limit, chainOf(d, (try d.vol.open("data/big")).first_cluster, &chain).len);
        // "one-more.md" took two of the new cluster's sixteen entries (a long
        // part and the short entry); seven more such names take the other
        // fourteen, and then the directory is full.
        var path: [64]u8 = undefined;
        for (0..7) |k| try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/big/more-{d}.md", .{k}), "x");
        const before = d.free();
        try testing.expectError(disk_fat.Error.DirectoryFull, d.vol.writeFile("data/big/past-the-limit.md", "x"));
        try testing.expectEqual(before, d.free());
        try testing.expectEqual(limit, chainOf(d, (try d.vol.open("data/big")).first_cluster, &chain).len);
        // Every name in it is still found, the first laid down and the last.
        _ = try d.vol.open("data/big/F0000000");
        _ = try d.vol.open("data/big/more-6.md");
        // Other directories still grow.
        try d.vol.writeFile("data/small/x", "x");
    }
}

// ---- the NT case bits (QUEUE item 12) ---------------------------------------

test "a short name with the NT lower-case bits lists in lower case, and is found either way" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("ntcase", shape, cached);
        defer d.deinit();
        // Upper-case 8.3 names: one short entry each, no long name.
        try d.vol.writeFile("data/TOPIC.MD", "both");
        try d.vol.writeFile("data/NOTES.TXT", "base");
        try d.vol.writeFile("data/README.MD", "ext");
        try d.vol.writeFile("data/KEEP.MD", "neither");
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("TOPIC.MD NOTES.TXT README.MD KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        // As Windows or mtools would have written them.
        for ([_]struct { []const u8, u8 }{ .{ "data/TOPIC.MD", 0x18 }, .{ "data/NOTES.TXT", 0x08 }, .{ "data/README.MD", 0x10 } }) |set| {
            const e = try d.vol.open(set[0]);
            d.bytes[e.lba * test_disk.sector + e.slot + 12] = set[1];
        }
        try d.mount(cached);
        try testing.expectEqualStrings("topic.md notes.TXT README.md KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        // Found by any case, as every name is; the alias is still the alias.
        try d.expectFile("data/topic.md", "both");
        try d.expectFile("data/TOPIC.MD", "both");
        const e = try d.vol.open("data/Topic.Md");
        try testing.expectEqualStrings("TOPIC.MD", e.alias());
        try testing.expectEqualStrings("topic.md", e.text());
    }
}

// ---- a rewrite keeps the name (the box's judge, 2026-10-02) ------------------

test "a file rewritten under a name in another case keeps the name and alias it has" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("recase", shape, cached);
        defer d.deinit();
        // A long name, as the Store writes a topic's sidecar; a name that
        // needs no long one; and one that fits 8.3 only in upper case.
        try d.vol.writeFile("data/metal-talk.count", "1");
        try d.vol.writeFile("data/plan.md", "one");
        try d.vol.writeFile("data/KEEP.MD", "a");
        const alias = (try d.vol.open("data/metal-talk.count")).alias();
        var alias_buf: [12]u8 = undefined;
        const kept_alias = alias_buf[0..alias.len];
        @memcpy(kept_alias, alias);

        try d.vol.writeFile("data/Metal-Talk.count", "2");
        try d.vol.writeFile("data/PLAN.md", "two");
        try d.vol.writeFile("data/keep.md", "b");
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        try testing.expectEqualStrings(kept_alias, (try d.vol.open("data/METAL-TALK.COUNT")).alias());
        try d.expectFile("data/metal-talk.count", "2");
        try d.expectFile("data/plan.md", "two");
        try d.expectFile("data/KEEP.MD", "b");

        // A new file still takes the case it is given.
        try d.vol.writeFile("data/New-Topic.md", "x");
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD New-Topic.md", try d.names(data_dir.first_cluster, &buf));
        try d.mount(cached);
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD New-Topic.md", try d.names(data_dir.first_cluster, &buf));
        try testing.expect(d.fatsAgree());
    }
}

// ---- a file near 4 GiB (REVIEW-restart-fat32.md F1) --------------------------

test "an append to a file within a cluster of 4 GiB answers TooBig past it, not a panic" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-near-4g", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/x", "abc");
        const e = try d.vol.open("data/x");
        // Its entry says 4 GiB less 100 bytes; the chain is still one cluster,
        // so the disk is damaged on purpose, but the arithmetic is what is
        // under test: it used to overflow before reading the chain.
        const at = e.lba * test_disk.sector + e.slot + 28;
        std.mem.writeInt(u32, d.bytes[at..][0..4], 0xFFFF_FF9C, .little);
        try d.mount(cached);
        try testing.expectError(disk_fat.Error.TooBig, d.vol.writeInto("data/x", 0xFFFF_FF9C, &@as([101]u8, @splat('x'))));
        // Within the limit it gets past the sizes and meets the short chain.
        try testing.expect(std.meta.isError(d.vol.writeInto("data/x", 0xFFFF_FF9C, "more")));
    }
}

// ---- a file never replaces a directory (QUEUE item 36) -----------------------

test "a file written over a directory's name is refused, and the directory and its contents stay" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("file-over-dir", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/plan/inside.md", "kept");
        const before = d.free();
        // In its own case and in another: FAT matches either.
        try testing.expectError(disk_fat.Error.IsDirectory, d.vol.writeFile("data/plan", "a file"));
        try testing.expectError(disk_fat.Error.IsDirectory, d.vol.writeFile("data/Plan", "a file"));
        try d.expectFile("data/plan/inside.md", "kept");
        try testing.expectEqual(before, d.free());
        try testing.expect((try d.vol.open("data/plan")).isDirectory());
        try d.mount(cached);
        try d.expectFile("data/plan/inside.md", "kept");
    }
}

test "a long name's orphan parts are tombstoned before a new entry is written after them, so it is not listed under their name" {
    for (configs) |cfg| {
        const d = try Disk.make("orphan-long-name", cfg.shape, cfg.cached);
        defer d.deinit();
        // "c" is stored as a long name and the alias C~1, whose checksum is
        // 0xC0; so is the short name B's. Tombstone c's short entry alone, as
        // a remove stopped between its two steps leaves it: the long part
        // is an orphan, followed by a free slot.
        try d.vol.writeFile("data/c", "");
        const c = try d.vol.open("data/c");
        d.bytes[(d.vol.start_lba + c.lba) * test_disk.sector + c.slot] = 0xE5;
        try d.mount(cfg.cached);

        try d.vol.writeFile("data/B", "bee");
        try d.expectFile("data/b", "bee");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/c"));
        const dir = try d.vol.open("data");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("B", try d.names(dir.first_cluster, &buf));
    }
}

/// An earlier boot's orphan run of two long-name parts before a free slot;
/// this boot's counts set to `before`; a short name written into the slot,
/// which tombstones the run; the counts after.
fn tombstoneUncounted(cfg: anytype, before: [4]u64) ![4]u64 {
    const d = try Disk.make("orphan-uncounted", cfg.shape, cfg.cached);
    defer d.deinit();
    try d.vol.writeFile("data/abcdefghijklmnop", "");
    const c = try d.vol.open("data/abcdefghijklmnop");
    d.bytes[(d.vol.start_lba + c.lba) * test_disk.sector + c.slot] = 0xE5;
    try d.mount(cfg.cached);
    d.vol.orphaned_runs, d.vol.orphaned_parts, d.vol.unsure_runs, d.vol.unsure_parts = before;
    try d.vol.writeFile("data/B", "bee");
    try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/abcdefghijklmnop"));
    return .{ d.vol.orphaned_runs, d.vol.orphaned_parts, d.vol.unsure_runs, d.vol.unsure_parts };
}

test "tombstoning an orphan run takes it from a count of this boot only where one covers it (metal-vmm 154(b))" {
    for (configs) |cfg| {
        // [runs, parts, runs that may be, parts that may be]. No count holds
        // a run of two parts: an earlier boot's, left as counted.
        try testing.expectEqual([4]u64{ 1, 1, 0, 0 }, try tombstoneUncounted(cfg, .{ 1, 1, 0, 0 }));
        // The exact counts do.
        try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, try tombstoneUncounted(cfg, .{ 1, 2, 0, 0 }));
        // Both do: the exact one first.
        try testing.expectEqual([4]u64{ 0, 0, 1, 2 }, try tombstoneUncounted(cfg, .{ 1, 2, 1, 2 }));
        // A run and one part exact, one part that may be live: the run
        // `partsLeft` leaves where its last clear is unknown (the review).
        try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, try tombstoneUncounted(cfg, .{ 1, 1, 0, 1 }));
        // Only the one that may be live does.
        try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, try tombstoneUncounted(cfg, .{ 0, 0, 1, 2 }));
        // Mixed before what may be live, as exact before it: wrong, the
        // judge passes leniently; the other way, it fails falsely.
        try testing.expectEqual([4]u64{ 0, 0, 1, 1 }, try tombstoneUncounted(cfg, .{ 1, 1, 1, 2 }));
        // None at all.
        try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, try tombstoneUncounted(cfg, .{ 0, 0, 0, 0 }));
    }
}

test "a path through a file names nothing, whatever the file's bytes spell" {
    for (configs) |cfg| {
        const d = try Disk.make("through-a-file", cfg.shape, cfg.cached);
        defer d.deinit();
        // A file whose first 32 bytes are a directory entry for "X", a file
        // of 5 bytes at cluster 2: what a walk through it would find.
        var bytes: [64]u8 = @splat(0);
        @memcpy(bytes[0..11], "X          ");
        bytes[11] = 0x20;
        bytes[26] = 2;
        bytes[28] = 5;
        try d.vol.writeFile("data/f", &bytes);
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/f/x"));
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/f/x/y"));
        try testing.expect(!(try d.vol.open("data/f")).isDirectory());
    }
}

// ---- rename, for a replace that survives a crash (QUEUE item 24) -------------

test "rename moves a file to a new name, and over a file, keeping that file's name" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("rename", shape, cached);
        defer d.deinit();
        var big: [3000]u8 = undefined;
        try d.vol.writeFile("data/old.count", pattern(&big, 7));
        try d.vol.writeFile("data/tmp1", "new contents");
        const before = d.free();

        // Over a file: `to` holds the new bytes under its own name, and its
        // old clusters (six of them) are free again; `from` is gone.
        try d.vol.rename("data/tmp1", "data/OLD.COUNT");
        try d.expectFile("data/old.count", "new contents");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/tmp1"));
        try testing.expectEqual(before + 6, d.free());
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("old.count", try d.names(data_dir.first_cluster, &buf));

        // To a name nobody has: the case given, no cluster moved.
        try d.vol.writeFile("data/tmp2", "x");
        const mid = d.free();
        try d.vol.rename("data/tmp2", "data/Fresh-Name.md");
        try d.expectFile("data/fresh-name.md", "x");
        try testing.expectEqual(mid, d.free());
        try testing.expectEqualStrings("old.count Fresh-Name.md", try d.names(data_dir.first_cluster, &buf));

        // An empty file renames too.
        try d.vol.writeFile("data/empty", "");
        try d.vol.rename("data/empty", "data/old.count");
        try d.expectFile("data/old.count", "");

        // Refused: across directories, a directory either side, a missing
        // `from`. Renaming a file to its own name in another case does nothing.
        try d.vol.writeFile("data/a", "a");
        try d.vol.writeFile("other/b", "b");
        try testing.expectError(disk_fat.Error.BadName, d.vol.rename("data/a", "other/a"));
        _ = try d.vol.makePath("data/sub");
        try testing.expectError(disk_fat.Error.IsDirectory, d.vol.rename("data/a", "data/sub"));
        try testing.expectError(disk_fat.Error.BadName, d.vol.rename("data/sub", "data/c"));
        try testing.expectError(disk_fat.Error.NotFound, d.vol.rename("data/nothing", "data/a"));
        try d.vol.rename("data/a", "data/A");
        try d.expectFile("data/a", "a");

        try d.mount(cached);
        try d.expectFile("data/old.count", "");
        try d.expectFile("data/fresh-name.md", "x");
        try d.expectKept();
        try testing.expect(d.fatsAgree());
    }
}

test "a rename stopped at any point leaves the old file or the new, whole, and at worst leaked clusters" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        var stop: u64 = 0;
        var finished = false;
        while (!finished) : (stop += 1) {
            // Labelled by what the stop left, once it is known: a disk with
            // leaked clusters is damaged-*, and the oracle must find that; a
            // clean one must check clean. Every stop is kept on FAT16 with
            // the FAT on the disk; elsewhere only the last, to save room.
            var label_buf: [48]u8 = undefined;
            const d = try Disk.make("limit-rename-stop", shape, cached);
            defer d.deinit();
            var big: [3000]u8 = undefined;
            const old = pattern(&big, 3);
            try d.vol.writeFile("data/rec", old);
            try d.vol.writeFile("data/rec.tmp", "the new record");

            d.blk.fail_after = d.blk.requests + stop;
            if (d.vol.rename("data/rec.tmp", "data/rec")) |_| {
                finished = true;
            } else |_| {}
            d.blk.fail_after = null;
            // Mounted again as the boot does, FAT held or not: a held FAT
            // brings copies a stop left apart into line (cacheFat).
            try d.mount(cached);

            const got = try d.read("data/rec");
            defer testing.allocator.free(got);
            const is_old = std.mem.eql(u8, got, old);
            const is_new = std.mem.eql(u8, got, "the new record");
            if (!is_old and !is_new) {
                std.debug.print("stopped after {d} requests: data/rec is neither file ({d} bytes)\n", .{ stop, got.len });
                return error.TestUnexpectedResult;
            }
            if (finished) try testing.expect(is_new);
            // Whatever is left over is leaked clusters, never a cross-link,
            // a short file or a broken chain. And FAT copies that differ:
            // every FAT update writes the first copy, then the second, so a
            // stop between the two leaves them apart, rename or not.
            const r = try d.check();
            for (r.found[0..r.len]) |f| {
                if (f.problem != .leaked and f.problem != .fats_differ) {
                    std.debug.print("stopped after {d} requests: {s} at {s}\n", .{ stop, @tagName(f.problem), f.text() });
                    return error.TestUnexpectedResult;
                }
            }
            if (shape.kind == .fat16 and !cached) {
                const kind = if (r.health.clean()) "" else "damaged-";
                d.label = try std.fmt.bufPrint(&label_buf, "{s}rename-stop-{d:0>2}", .{ kind, stop });
            }
        }
        // It took more than one request, so the loop did stop it part-way.
        try testing.expect(stop > 2);
    }
}

test "a FAT whose copies differ is held as the first, and the others are written from it" {
    for (formats) |shape| {
        const d = try Disk.make("fats-brought-into-line", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        // As a machine stopped between the copies' writes leaves them: the
        // second behind the first, in two sectors.
        const l = Layout.of(d.bytes);
        const per_sector: usize = if (shape.kind == .fat32) test_disk.sector / 4 else test_disk.sector / 2;
        l.set(d.bytes, 1, 3 * per_sector + 7, l.end());
        l.set(d.bytes, 1, 9 * per_sector + 1, l.end());
        try testing.expect(!d.fatsAgree());
        const writes = d.blk.writes;

        try d.mount(true);
        try testing.expectEqual(@as(u32, 2), d.repaired);
        try testing.expectEqual(@as(u32, 0), d.trusted); // the second has clusters nothing holds
        try testing.expectEqual(writes + 2, d.blk.writes); // those two sectors, nothing else
        try testing.expect(d.fatsAgree());
        try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 0, 3 * per_sector + 7));
        try d.expectFile("data/f", "x");
        const r = try d.check();
        try r.expect(&.{});
        // Agreeing copies are left alone.
        try d.mount(true);
        try testing.expectEqual(@as(u32, 0), d.repaired);
        try testing.expectEqual(writes + 2, d.blk.writes);
    }
}

test "a first FAT copy that reads wrong is not written over the second: the copy that checks clean is the FAT (B26)" {
    for (formats) |shape| {
        const d = try Disk.make("first-copy-rotted", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        // The file's cluster, the last one taken: its first copy's entry is
        // made free, as a rotted sector of the first copy would read.
        const l = Layout.of(d.bytes);
        var c: usize = 2;
        var last: usize = 0;
        while (c <= l.end() and c < 1000) : (c += 1) {
            if (l.get(d.bytes, 0, c) != 0) last = c;
        }
        try testing.expect(last >= 3);
        const was = l.get(d.bytes, 1, last);
        l.set(d.bytes, 0, last, 0);
        try testing.expect(!d.fatsAgree());

        try d.mount(true);
        try testing.expectEqual(@as(u32, 1), d.repaired);
        try testing.expectEqual(@as(u32, 1), d.trusted); // the second copy
        try testing.expect(d.fatsAgree());
        try testing.expectEqual(was, l.get(d.bytes, 0, last)); // the first, healed from it
        try d.expectFile("data/f", "x");
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "copies apart and a directory that cannot be read: the volume mounts, and neither copy is written over (metal-vmm QUEUE 103)" {
    // (CC, 2026-10-08.) Weighing the copies
    // (B26) runs a whole check, which reads every directory. Before B26
    // copies apart were brought into line from the first and the volume
    // mounted; now one directory sector that fails to read fails the mount,
    // and on metal the boot stops ("the FAT could not be held in memory").
    // A disk with a bad sector in a folder and a rotted FAT sector is the
    // disk B25 and B26 were for. The check failing should leave the choice
    // unmade: mount with the first copy held, and write neither, so the
    // second copy, perhaps the good one, is there for a boot that can weigh.
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-unreadable", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        const l = Layout.of(d.bytes);
        var c: usize = 2;
        var last: usize = 0;
        while (c <= l.end() and c < 1000) : (c += 1) {
            if (l.get(d.bytes, 0, c) != 0) last = c;
        }
        try testing.expect(last >= 3);
        const was = l.get(d.bytes, 1, last);
        l.set(d.bytes, 0, last, 0);
        const damaged = try d.snapshot();
        defer d.drop(damaged);
        const buf = try testing.allocator.alloc(u8, d.vol.fatBytes());
        defer testing.allocator.free(buf);
        const room = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(room);

        // How many requests come before the check: the copies read and
        // compared, unweighed, less the sectors written to repair them.
        try d.mount(false);
        const r0 = d.blk.requests;
        const unweighed = try d.vol.cacheFatChecked(buf, null);
        const before_check = d.blk.requests - r0 - unweighed.repaired;
        @memcpy(d.bytes, damaged);

        // The same mount, weighing, and the check's first read fails.
        try d.mount(false);
        d.blk.fault = .{ .at = d.blk.requests + before_check, .kind = .fails };
        const m = try d.vol.cacheFatChecked(buf, room);
        try testing.expectEqual(.unweighed, m.found);
        try testing.expectEqual(@as(u32, 0), m.repaired);
        try testing.expectEqual(was, l.get(d.bytes, 1, last)); // the second copy kept
    }
}

test "a name past ASCII is refused, not written to read back as another (metal-vmm QUEUE 104)" {
    // A long name holds each byte as one UTF-16 unit, and a unit past ASCII
    // read back as '?': "café" (UTF-8) was written, and then found under
    // no name it was given, so a second write made a second file.
    for (configs) |cfg| {
        const d = try Disk.make("non-ascii", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/plain", "x");
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile("data/caf\xc3\xa9", "x"));
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile("data/\xe2\x82\xac/f", "x")); // a folder made on the way
        try testing.expectError(disk_fat.Error.BadName, d.vol.rename("data/plain", "data/na\xefve"));
        try d.expectFile("data/plain", "x"); // a refused rename keeps what it would have moved
    }
}

// ---- the survivors of mutation testing (MUTATION.md, metal-vmm QUEUE 107) ----

test "a file ending inside a sector leaves zeros past its end, not what a file before it left (mutant F6)" {
    for (configs) |cfg| {
        const d = try Disk.make("f6-tail", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/old", &@as([1500]u8, @splat('Y')));
        const old = (try d.vol.open("data/old")).first_cluster;
        try d.vol.remove("data/old");
        try d.vol.writeFile("data/new", &@as([10]u8, @splat('x'))); // the freed cluster, first
        const e = try d.vol.open("data/new");
        try testing.expectEqual(old, e.first_cluster);
        const l = Layout.of(d.bytes);
        const at = (l.data_sector + (e.first_cluster - 2) * d.bytes[13]) * test_disk.sector;
        try testing.expectEqualStrings(&@as([10]u8, @splat('x')), d.bytes[at..][0..10]);
        try testing.expect(std.mem.allEqual(u8, d.bytes[at + 10 ..][0 .. test_disk.sector - 10], 0));
    }
}

test "reading at a file's very end reads nothing, even where its chain ends there too (mutant F10)" {
    for (configs) |cfg| {
        const d = try Disk.make("f10-end", cfg.shape, cfg.cached);
        defer d.deinit();
        const cluster_bytes = @as(usize, d.bytes[13]) * test_disk.sector;
        const data = try testing.allocator.alloc(u8, 2 * cluster_bytes);
        defer testing.allocator.free(data);
        try d.vol.writeFile("data/f", pattern(data, 3));
        const e = try d.vol.open("data/f");
        var out: [16]u8 = undefined;
        try testing.expectEqual(@as(usize, 0), try d.vol.readAt(e, e.size, &out));
    }
}

test "the check finds a chain exactly one cluster short of its size (mutant F14)" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-f14-short", shape, cached);
        defer d.deinit();
        const cluster_bytes: u32 = @as(u32, d.bytes[13]) * test_disk.sector;
        const data = try testing.allocator.alloc(u8, 2 * cluster_bytes);
        defer testing.allocator.free(data);
        try d.vol.writeFile("f", pattern(data, 4)); // two clusters
        const e = try d.vol.open("f");
        setEntry(d, e, .size, 2 * cluster_bytes + 1); // three's worth
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{.{ .problem = .short, .path = "/f", .cluster = e.first_cluster, .count = 2 }});
    }
}

test "a name removed leaves its entries for the next name of the same length (mutant F15)" {
    for (configs) |cfg| {
        const d = try Disk.make("f15-reuse", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/keep", "k");
        try d.vol.writeFile("data/gone", "g");
        const gone = try d.vol.open("data/gone");
        try d.vol.writeFile("data/last", "l");
        try d.vol.remove("data/gone");
        try d.vol.writeFile("data/next", "n");
        const next = try d.vol.open("data/next");
        try testing.expectEqual(gone.lba, next.lba);
        try testing.expectEqual(gone.slot, next.slot);
    }
}

test "FAT copies apart that check alike are merged toward allocated, the marked side kept (the night of 2026-10-08, seed 16341; 198.5)" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-tie", shape, false);
        defer d.deinit();
        // A cluster marked bad in the first copy, free in the second: neither
        // is a leak, so the two check alike.
        const l = Layout.of(d.bytes);
        const c: usize = 900;
        l.set(d.bytes, 0, c, l.bad());
        const writes = d.blk.writes;
        try d.mount(true);
        try testing.expect(d.fatsAgree());
        try testing.expectEqual(@as(u32, 1), d.repaired); // the second copy's sector
        try testing.expectEqual(writes + 1, d.blk.writes);
        try testing.expectEqual(l.bad(), l.get(d.bytes, 0, c));
        try testing.expectEqual(l.bad(), l.get(d.bytes, 1, c));
    }
}

test "FAT copies that tie merge toward allocated: each differing entry's nonzero side wins, both copies written at once (metal-vmm QUEUE 198.5, P124(f))" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-tie-merged", shape, false);
        defer d.deinit();
        const l = Layout.of(d.bytes);
        // A tie both ways in one sector: 900 marked only in the second
        // copy, 901 only in the first. Each is neutral to the check, so
        // the copies check alike.
        l.set(d.bytes, 1, 900, l.bad());
        l.set(d.bytes, 0, 901, l.bad());
        const free_before = blk: {
            try d.mount(false);
            break :blk d.vol.free_clusters;
        };
        try d.mount(true);
        // Both marks in both copies, on the disk, at mount.
        for ([_]usize{ 0, 1 }) |copy| {
            try testing.expectEqual(l.bad(), l.get(d.bytes, copy, 900));
            try testing.expectEqual(l.bad(), l.get(d.bytes, copy, 901));
        }
        try testing.expect(d.fatsAgree());
        // The first copy was counted with 901 taken and 900 free: 900 is
        // taken now too.
        try testing.expectEqual(free_before - 1, d.vol.free_clusters);
        // And a write after it keeps both.
        try d.vol.writeFile("after", "x");
        try testing.expectEqual(l.bad(), l.get(d.bytes, 1, 900));
        try testing.expectEqual(l.bad(), l.get(d.bytes, 0, 900));
    }
}

test "a repair of FAT copies apart that the disk refuses: the mount goes on (the night of 2026-10-08, seed 18771)" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-repair-refused", shape, false);
        defer d.deinit();
        try d.vol.writeFile("f", "x");
        // The second copy apart from the first by clusters nothing holds: the
        // first checks cleaner, and the second is to be written from it.
        const l = Layout.of(d.bytes);
        l.set(d.bytes, 1, 300, l.end());
        const damaged = try d.snapshot();
        defer d.drop(damaged);
        const buf = try testing.allocator.alloc(u8, d.vol.fatBytes());
        defer testing.allocator.free(buf);
        const room = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(room);

        // How many requests come before the repair: the copies read and
        // weighed, less the sectors written to repair them.
        try d.mount(false);
        const r0 = d.blk.requests;
        const whole = try d.vol.cacheFatChecked(buf, room);
        try testing.expect(whole.repaired > 0);
        const before_repair = d.blk.requests - r0 - whole.repaired;
        @memcpy(d.bytes, damaged);

        // The same mount, and the repair's first write fails.
        try d.mount(false);
        d.blk.fault = .{ .at = d.blk.requests + before_repair, .kind = .fails };
        const m = try d.vol.cacheFatChecked(buf, room);
        d.blk.fault = null;
        try testing.expectEqual(.weighed, m.found);
        try testing.expectEqual(.refused, m.repair);
        try testing.expectEqual(@as(u32, 0), m.trusted);
        try testing.expectEqual(@as(u32, 0), m.repaired);
    }
}

// ---- the kept free count (QUEUE item 14) -------------------------------------

test "the kept free count follows every operation, the refused and failed ones included" {
    for (both) |cached| {
        const d = try Disk.make("keptfree", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        try d.expectKept();
        var data: [20_000]u8 = undefined;
        _ = pattern(&data, 6);
        try d.vol.writeFile("data/a", &data);
        try d.expectKept();
        try d.vol.writeFile("data/a", data[0..100]); // replaced, smaller
        try d.expectKept();
        try d.vol.writeFile("data/b", "");
        try d.expectKept();
        try d.vol.writeInto("data/b", 0, data[0..3000]); // an append that allocates
        try d.expectKept();
        try d.vol.writeInto("data/b", 100, "overwrite"); // inside: allocates nothing
        try d.expectKept();
        try testing.expectError(disk_fat.Error.BadChain, d.vol.writeInto("data/b", 5000, "hole"));
        try d.expectKept();
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile(&@as([disk_fat.max_name + 1]u8, @splat('x')), "x"));
        try d.expectKept();
        _ = try d.vol.makePath("data/deep/er/still");
        try d.expectKept();
        // Fill the disk: the write that does not fit takes clusters, then
        // gives them all back.
        const big = try testing.allocator.alloc(u8, 3 << 20);
        defer testing.allocator.free(big);
        try testing.expectError(disk_fat.Error.Full, d.vol.writeFile("data/too-big", big));
        try d.expectKept();
        try d.vol.writeFile("data/fits", big[0 .. 1 << 20]);
        try d.expectKept();
        try testing.expectError(disk_fat.Error.Full, d.vol.writeInto("data/fits", 1 << 20, big[0 .. 2 << 20]));
        try d.expectKept();
        try d.vol.remove("data/a");
        try d.expectKept();
        try d.vol.removeTree("data");
        try d.expectKept();
        // A fresh mount counts it again, to the same number.
        const kept = d.vol.free_clusters;
        try d.mount(cached);
        try testing.expectEqual(kept, d.vol.free_clusters);
        const sp = try d.vol.space();
        try testing.expectEqual(@as(u64, kept) * 512, sp.free);
    }
}
