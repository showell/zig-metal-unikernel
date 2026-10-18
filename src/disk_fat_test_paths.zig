//! `disk_fat.zig`'s paths the other tests leave untried (coverage,
//! 2026-10-09), and its boundaries side by side (the off-by-one hunt) (split
//! from disk_fat_test.zig by metal-vmm QUEUE 173).

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const virtio_blk = @import("virtio_blk.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;
const disk_fat_test = @import("disk_fat_test.zig");
const options = @import("disk_fat_test_options");
const chainOf = disk_fat_test.chainOf;
const damageFat = disk_fat_test.damageFat;
const setEntry = disk_fat_test.setEntry;
const pattern = disk_fat_test.pattern;
const both = disk_fat_test.both;
const configs = disk_fat_test.configs;
const formats = disk_fat_test.formats;
const Disk = disk_fat_test.Disk;

// ---- the paths the tests above leave untried (coverage, 2026-10-09) ----------

const dirent = @import("disk_fat_dirent.zig");
const disk_fat_dir = @import("disk_fat_dir.zig");

const IgnoreFindings = struct {
    fn each(_: void, _: disk_fat.Finding) void {}
};

/// The byte offset of the root directory's first sector, from the BPB.
fn rootAt(d: *const test_disk.Disk) usize {
    const l = Layout.of(d.bytes);
    return switch (l.kind) {
        .fat16 => l.fat_start + 2 * l.fat_bytes,
        .fat32 => (l.data_sector + (l.root_cluster - 2) * d.bytes[13]) * test_disk.sector,
    };
}

/// A long-name part of `chars` (at most thirteen), numbered `seq`, opening a
/// name (`last`, the 0x40 flag) or continuing one, tied to checksum `sum`.
fn longPart(e: *[32]u8, seq: u8, last: bool, sum: u8, chars: []const u8) void {
    @memset(e, 0xFF);
    e[0] = seq | @as(u8, if (last) 0x40 else 0);
    e[11] = 0x0F;
    e[12] = 0;
    e[13] = sum;
    e[26] = 0;
    e[27] = 0;
    for (dirent.long_offsets, 0..) |off, i| {
        const c: u16 = if (i < chars.len) chars[i] else if (i == chars.len) 0 else 0xFFFF;
        e[off] = @truncate(c);
        e[off + 1] = @truncate(c >> 8);
    }
}

/// Makes `path` a directory holding `count` empty files, one 8.3 entry each,
/// named by `nameOf`, after "." and "..": laid onto the disk as
/// `fullDirectory` lays them, the rest of its last cluster free.
fn layEntries(d: *test_disk.Disk, cached: bool, path: []const u8, count: usize, comptime nameOf: fn (usize, *[11]u8) void) !void {
    const first = try d.vol.makePath(path);
    const l = Layout.of(d.bytes);
    try testing.expectEqual(@as(u8, 1), d.bytes[13]);
    const per = test_disk.sector / 32;
    const clusters = (count + 2 + per - 1) / per;
    var last: usize = first;
    var candidate: usize = 2;
    for (1..clusters) |_| {
        while (l.get(d.bytes, 0, candidate) != 0) candidate += 1;
        for (0..2) |copy| {
            l.set(d.bytes, copy, last, @intCast(candidate));
            l.set(d.bytes, copy, candidate, l.end());
        }
        last = candidate;
    }
    var c: usize = first;
    var k: usize = 0;
    for (0..clusters) |i| {
        const sector = d.bytes[(l.data_sector + c - 2) * test_disk.sector ..][0..test_disk.sector];
        for (0..per) |slot| {
            if (i == 0 and slot < 2) continue; // "." and ".."
            const e = sector[slot * 32 ..][0..32];
            @memset(e, 0);
            if (k < count) {
                nameOf(k, e[0..11]);
                e[11] = 0x20;
                k += 1;
            }
        }
        c = l.get(d.bytes, 0, c);
    }
    try d.mount(cached);
}

test "a FAT whose copies differ in more sectors than are weighed is held as the first, and the others are written from it, or left apart if the disk refuses" {
    const d = try Disk.make("fats-apart-past-weighing", test_disk.small32, false);
    defer d.deinit();
    try d.vol.writeFile("data/f", "x");
    const buf = try testing.allocator.alloc(u8, d.vol.fatBytes());
    defer testing.allocator.free(buf);
    const room = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(room);
    // The requests before the copies are mended: the first read, and the
    // second compared with it. Copies that agree take the same reads.
    try d.mount(false);
    const r0 = d.blk.requests;
    try testing.expectEqual(@as(u32, 0), try d.vol.cacheFat(buf));
    const before = d.blk.requests - r0;

    // The second copy apart from the first in one entry of each of its first
    // sectors, more of them than are weighed: clusters nothing holds.
    const l = Layout.of(d.bytes);
    const per = test_disk.sector / 4;
    const apart = disk_fat.Volume.max_weighed_sectors + 6;
    try testing.expect(d.vol.sectors_per_fat > apart);
    for (0..apart) |s| l.set(d.bytes, 1, s * per + 100, l.end());

    // The first mending write fails: the run of the second copy that holds
    // sector 0 is read, then sector 0 is written. The FAT is held, the
    // mount goes on, and the copies are left as far apart as they were.
    // Unchecked (no room to weigh): with room, copies this far apart are
    // weighed whole (metal-vmm QUEUE 181), below.
    try d.mount(false);
    d.blk.fault = .{ .at = d.blk.requests + before + 1, .kind = .fails };
    const m = try d.vol.cacheFatChecked(buf, null);
    d.blk.fault = null;
    try testing.expectEqual(.refused, m.repair);
    try testing.expectEqual(.past_weighing, m.found);
    try testing.expectEqual(@as(u32, 0), m.repaired);
    try testing.expectEqual(l.end(), l.get(d.bytes, 1, 100));
    try testing.expect(!d.fatsAgree());

    // The next mount, with room, weighs the copies whole: the first checks
    // clean and the second leaks, so every differing sector is written from
    // the first.
    try d.mount(false);
    const w = try d.vol.cacheFatChecked(buf, room);
    try testing.expectEqual(.weighed, w.found);
    try testing.expectEqual(@as(u32, 0), w.trusted);
    try testing.expect(w.health[1].leaked > w.health[0].leaked);
    try testing.expectEqual(@as(u32, apart), w.repaired);
    try d.mount(true);
    try testing.expectEqual(@as(u32, 0), d.repaired);
    try testing.expect(d.fatsAgree());
    try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 1, 100));
    try d.expectFile("data/f", "x");
    const r = try d.check();
    try r.expect(&.{});
}

test "copies apart whose second weighing cannot run: the first copy is held as it reads, and neither is written over" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-second-unreadable", shape, false);
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

        // The requests before the first check, and what one check takes:
        // the second takes as many, the volume's directories and copies
        // being the same.
        try d.mount(false);
        const r0 = d.blk.requests;
        const unweighed = try d.vol.cacheFatChecked(buf, null);
        const before_check = d.blk.requests - r0 - unweighed.repaired;
        const c0 = d.blk.requests;
        _ = try d.vol.check(room, {}, IgnoreFindings.each);
        const one_check = d.blk.requests - c0;
        @memcpy(d.bytes, damaged);

        // The first check runs; the second's first read fails.
        try d.mount(false);
        d.blk.fault = .{ .at = d.blk.requests + before_check + one_check, .kind = .fails };
        const m = try d.vol.cacheFatChecked(buf, room);
        d.blk.fault = null;
        try testing.expectEqual(.unweighed, m.found);
        try testing.expectEqual(@as(u32, 0), m.repaired);
        // The held FAT is the first copy as the disk has it, the second's
        // sectors weighed in it put back; neither copy is written.
        try testing.expectEqualSlices(u8, d.bytes[l.fat_start..][0..d.vol.fatBytes()], d.vol.fat.?);
        try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 0, last));
        try testing.expectEqual(was, l.get(d.bytes, 1, last));
    }
}

test "what the FAT says afresh, from a held FAT or the disk, is what its first copy on the disk says" {
    for (configs) |cfg| {
        const d = try Disk.make("derive", cfg.shape, cfg.cached);
        defer d.deinit();
        var data: [3000]u8 = undefined;
        try d.vol.writeFile("data/a", pattern(&data, 1));
        try d.vol.writeFile("data/b", pattern(&data, 2));
        try d.vol.remove("data/a");
        try testing.expectEqual(cfg.cached, d.vol.fat != null);
        const got = try d.vol.derive();
        try testing.expectEqual(@as(u32, @intCast(d.free())), got.free);
        const l = Layout.of(d.bytes);
        var lowest: usize = 2;
        while (l.get(d.bytes, 0, lowest) != 0) lowest += 1;
        try testing.expectEqual(@as(?disk_fat.Cluster, @intCast(lowest)), got.first_free);
    }
}

test "a boot sector whose FAT sizes overflow 32 bits, or that cannot be read, is refused at mount" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small32.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio_blk.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    // FAT32's sectors per FAT (BPB_FATSz32, at 36), as two FATs and the 32
    // reserved sectors before them make it overflow.
    const cases = [_]struct { what: []const u8, per_fat: u32, root_entries: u16 = 0 }{
        .{ .what = "a FAT of no sectors", .per_fat = 0 },
        .{ .what = "two FATs of more than 2^32 sectors", .per_fat = 0x8000_0000 },
        .{ .what = "two FATs and the reserved sectors past 2^32", .per_fat = 0x7FFF_FFFF },
        // BPB_RootEntCnt at its most is 4,096 sectors more, past 2^32.
        .{ .what = "the root directory's sectors past 2^32", .per_fat = 0x7FFF_F800, .root_entries = 0xFFFF },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small32);
        std.mem.writeInt(u32, bytes[36..40], c.per_fat, .little);
        std.mem.writeInt(u16, bytes[17..19], c.root_entries, .little);
        testing.expectError(disk_fat.Error.BadBootSector, disk_fat.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    test_disk.format(bytes, test_disk.small32);
    blk.fail_after = blk.requests;
    try testing.expectError(disk_fat.Error.ReadFailed, disk_fat.Volume.mount(&blk, &scratch, 0));
}

test "an entry is dated by the volume's clock, and a clock with no answer writes no date rather than a wrong one" {
    const Clocks = struct {
        fn known() ?i64 {
            return 1789641533; // 2026-09-17T10:38:53Z, an odd second
        }
        fn unknown() ?i64 {
            return null;
        }
    };
    for (configs) |cfg| {
        const d = try Disk.make("clock", cfg.shape, cfg.cached);
        defer d.deinit();
        d.vol.clock = &Clocks.known;
        try d.vol.writeFile("data/dated", "x");
        try testing.expectEqual(@as(i64, 1789641532), (try d.vol.open("data/dated")).mtime_unix);
        d.vol.clock = &Clocks.unknown;
        try d.vol.writeFile("data/undated", "x");
        try testing.expectEqual(@as(i64, 0), (try d.vol.open("data/undated")).mtime_unix);
        // A rewrite moves the modification time, to none.
        try d.vol.writeFile("data/dated", "y");
        try testing.expectEqual(@as(i64, 0), (try d.vol.open("data/dated")).mtime_unix);
    }
}

test "a folder made is dated by the volume's clock in its own entry and in its `.` and `..`, as a file is (metal-vmm QUEUE 218)" {
    const Clocks = struct {
        fn known() ?i64 {
            return 1789641533;
        }
    };
    const when = dirent.Dos.fromUnix(1789641533);
    for (configs) |cfg| {
        const d = try Disk.make("folder-dated", cfg.shape, cfg.cached);
        defer d.deinit();
        d.vol.clock = &Clocks.known;
        const c = try d.vol.makePath("data/inner");
        try testing.expectEqual(@as(i64, 1789641532), (try d.vol.open("data/inner")).mtime_unix);
        const sector = d.bytes[@as(usize, d.vol.clusterSector(c)) * 512 ..][0..512];
        for ([_][]const u8{ ".          ", "..         " }, 0..) |name, k| {
            const e = sector[k * 32 ..][0..32];
            try testing.expectEqualStrings(name, e[0..11]);
            var want: [4]u8 = undefined;
            dirent.putDos(&want, when);
            try testing.expectEqualSlices(u8, &want, e[14..18]); // created
            try testing.expectEqualSlices(u8, want[2..4], e[18..20]); // accessed
            try testing.expectEqualSlices(u8, &want, e[22..26]); // written
        }
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "a volume label in the root is passed over: a name after it is written, found and removed, and the check calls it clean" {
    for (configs) |cfg| {
        const d = try Disk.make("label", cfg.shape, cfg.cached);
        defer d.deinit();
        // As mkfs.vfat -n writes one: the label's eleven bytes, attribute 0x08.
        const root = rootAt(d);
        @memcpy(d.bytes[root..][0..11], "GOPHER     ");
        d.bytes[root + 11] = 0x08;
        try d.mount(cfg.cached);
        try d.vol.writeFile("after-the-label.md", "x");
        try d.expectFile("after-the-label.md", "x");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("after-the-label.md", try d.names(0, &buf));
        try d.vol.remove("after-the-label.md");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("after-the-label.md"));
        try testing.expectEqualStrings("GOPHER     ", d.bytes[root..][0..11]);
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "more orphan long-name parts in a row than a name has: the ones before a new entry are tombstoned, and it is listed under its own name" {
    for (both) |cached| {
        // FAT16's root, a fixed run of sectors: 21 live parts in a row, as
        // no name leaves them, then free entries.
        const d = try Disk.make("orphans-past-a-name", small, cached);
        defer d.deinit();
        const root = rootAt(d);
        for (0..21) |k| longPart(d.bytes[root + k * 32 ..][0..32], 1, true, 0x77, "orphan");
        try d.mount(cached);
        try d.vol.writeFile("new-name.md", "fresh");
        try d.expectFile("new-name.md", "fresh");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("new-name.md", try d.names(0, &buf));
        // The twenty just before the new entry are tombstoned; the first,
        // as many parts back as a name can have, is left, behind them.
        for (1..21) |k| try testing.expectEqual(@as(u8, 0xE5), d.bytes[root + k * 32]);
        try testing.expectEqual(@as(u8, 0x41), d.bytes[root]);
    }
}

test "a run of long-name parts out of turn is no name: the file is found by its short name only" {
    for (both) |cached| {
        const d = try Disk.make("long-name-out-of-turn", small, cached);
        defer d.deinit();
        try d.vol.writeFile("ABC", "hello"); // one short entry, the root's first
        const root = rootAt(d);
        var short: [32]u8 = d.bytes[root..][0..32].*;
        // Twenty-one parts before it, each numbered 1: the first opens the
        // name, the rest are out of turn (Linux and fsck.fat refuse them too).
        const sum = dirent.shortChecksum(short[0..11].*);
        for (0..21) |k| longPart(d.bytes[root + k * 32 ..][0..32], 1, k == 0, sum, "a-long-name");
        @memcpy(d.bytes[root + 21 * 32 ..][0..32], &short);
        try d.mount(cached);
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("a-long-name"));
        try d.expectFile("ABC", "hello");
    }
}

test "a FAT16 root that is full refuses a new name and a new directory, and takes nothing" {
    for (both) |cached| {
        // A root of one sector: sixteen entries.
        const d = try Disk.make("root-full", .{ .sectors = 8192, .root_entries = 16 }, cached);
        defer d.deinit();
        var name: [8]u8 = undefined;
        for (0..16) |k| try d.vol.writeFile(try std.fmt.bufPrint(&name, "F{d}", .{k}), "x");
        const before = d.free();
        try testing.expectError(disk_fat.Error.DirectoryFull, d.vol.writeFile("ONE.MOR", "x"));
        try testing.expectError(disk_fat.Error.DirectoryFull, d.vol.writeFile("a-longer-name.md", "x"));
        try testing.expectError(disk_fat.Error.DirectoryFull, d.vol.makePath("DIR"));
        try testing.expectEqual(before, d.free());
        // A name already there is still rewritten in place.
        try d.vol.writeFile("F3", "rewritten");
        try d.expectFile("F3", "rewritten");
    }
}

test "a name whose every 8.3 alias is taken is refused, and takes nothing" {
    const Alias = struct {
        /// ABCDEF~1 to ABCDEF~9, ABCDE~10 to ABCDE~99, ABCD~100 to ABCD~999:
        /// every alias of a name beginning "abcdefgh" with no extension.
        fn of(k: usize, out: *[11]u8) void {
            @memset(out, ' ');
            var tail: [4]u8 = undefined;
            const t = std.fmt.bufPrint(&tail, "~{d}", .{k + 1}) catch unreachable;
            const keep = 8 - t.len;
            @memcpy(out[0..keep], "ABCDEFGH"[0..keep]);
            @memcpy(out[keep..][0..t.len], t);
        }
    };
    for (configs) |cfg| {
        const d = try Disk.make("aliases-taken", cfg.shape, cfg.cached);
        defer d.deinit();
        try layEntries(d, cfg.cached, "data/many", 999, Alias.of);
        _ = try d.vol.open("data/many/ABCD~999");
        const before = d.free();
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile("data/many/abcdefghij", "x"));
        try testing.expectEqual(before, d.free());
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/many/abcdefghij"));
        // A name of another beginning still has its aliases.
        try d.vol.writeFile("data/many/zyxwvutsrq", "x");
        try testing.expectEqualStrings("ZYXWVU~1", (try d.vol.open("data/many/zyxwvutsrq")).alias());
    }
}

test "a new name that is another file's 8.3 alias is refused, and takes nothing" {
    for (configs) |cfg| {
        const d = try Disk.make("alias-as-name", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/FooBarBaz.txt", "first");
        try testing.expectEqualStrings("FOOBAR~1.TXT", (try d.vol.open("data/FooBarBaz.txt")).alias());
        try d.vol.writeFile("data/other", "other");
        const before = d.free();
        // Each would write a second FOOBAR~1.TXT, which fsck calls a
        // duplicate and Linux opens as either file.
        try testing.expectError(disk_fat.Error.NameTaken, d.vol.writeFile("data/FOOBAR~1.TXT", "second"));
        try testing.expectError(disk_fat.Error.NameTaken, d.vol.makePath("data/FOOBAR~1.TXT"));
        try testing.expectError(disk_fat.Error.NameTaken, d.vol.rename("data/other", "data/FOOBAR~1.TXT"));
        try testing.expectEqual(before, d.free());
        try d.expectFile("data/FooBarBaz.txt", "first");
        try d.expectFile("data/other", "other");
        // A file renamed to its own alias is the same file: a no-op.
        try d.vol.rename("data/FooBarBaz.txt", "data/FOOBAR~1.TXT");
        try d.expectFile("data/FooBarBaz.txt", "first");
        // Gone, the alias is free to be a name.
        try d.vol.remove("data/FooBarBaz.txt");
        try d.vol.writeFile("data/FOOBAR~1.TXT", "second");
        try d.expectFile("data/FOOBAR~1.TXT", "second");
    }
}

test "a path through a file, too deep, or with no name, and a directory written into, are refused with their own errors" {
    for (configs) |cfg| {
        const d = try Disk.make("refused-paths", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/f", "a file");
        const before = d.free();
        try testing.expectError(disk_fat.Error.BadName, d.vol.makePath("data/f/sub"));
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile("data/f/sub/x", "x"));
        // A parent that is a file: NotFat16, as parentOf names it.
        try testing.expectError(disk_fat.Error.NotFat16, d.vol.remove("data/f/x"));
        try testing.expectError(disk_fat.Error.NotFat16, d.vol.rename("data/f/x", "data/f/y"));
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeInto("data", 0, "x"));
        for ([_][]const u8{ "", "/", "///" }) |p| {
            try testing.expectError(disk_fat.Error.BadName, d.vol.remove(p));
            try testing.expectError(disk_fat.Error.BadName, d.vol.rename(p, "data/g"));
        }
        try testing.expectEqual(before, d.free());
        try d.expectFile("data/f", "a file");
        // Sixteen levels: the fifteen the check walks are made, the
        // sixteenth refused.
        try testing.expectError(disk_fat.Error.BadName, d.vol.makePath("d/" ** 15 ++ "d"));
        try testing.expect((try d.vol.open("d/" ** 14 ++ "d")).isDirectory());
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("d/" ** 15 ++ "d"));
    }
}

test "a tree deeper than removeTree walks is refused, and nothing in it is removed; the same tree from one level down goes" {
    for (configs) |cfg| {
        const d = try Disk.make("limit-remove-deep", cfg.shape, cfg.cached);
        defer d.deinit();
        // Seventeen levels: makePath makes fifteen, the rest by hand, as
        // another program with no such limit would.
        var dir = try d.vol.makePath("d/" ** 14 ++ "d");
        dir = try d.vol.makeDirIn(dir, "d");
        dir = try d.vol.makeDirIn(dir, "d");
        try d.vol.writeFileIn(dir, "f", "deep");
        const before = d.free();
        try testing.expectError(disk_fat.Error.BadChain, d.vol.removeTree("d"));
        try testing.expectEqual(before, d.free());
        try d.expectFile("d/" ** 17 ++ "f", "deep");
        // Sixteen levels, counted from "d/d": within the walk.
        try d.vol.removeTree("d/d");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("d/d"));
        try testing.expect((try d.vol.open("d")).isDirectory());
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "a read at an offset inside a sector, across sectors and clusters, answers exactly the file's bytes there" {
    const shapes = formats ++ [_]Shape{.{ .sectors = 65536, .sectors_per_cluster = 4, .suffix = "-spc4" }};
    for (shapes) |shape| {
        for (both) |cached| {
            const d = try Disk.make("read-at", shape, cached);
            defer d.deinit();
            var data: [5000]u8 = undefined;
            _ = pattern(&data, 13);
            // Another file between its two halves, so its chain breaks.
            try d.vol.writeFile("data/f", data[0..2500]);
            try d.vol.writeFile("data/between", "x" ** 700);
            try d.vol.writeInto("data/f", 2500, data[2500..]);
            const e = try d.vol.open("data/f");
            var out: [5000]u8 = undefined;
            for ([_]u32{ 1, 100, 511, 513, 700, 1023, 2047, 2600, 4999 }) |off| {
                for ([_]usize{ 1, 5, 600, 1500, 5000 }) |len| {
                    const n = try d.vol.readAt(e, off, out[0..len]);
                    try testing.expectEqual(@min(len, data.len - off), n);
                    try testing.expectEqualSlices(u8, data[off..][0..n], out[0..n]);
                }
            }
        }
    }
}

test "a directory read as a file, and a file larger than the room given it, are refused" {
    for (configs) |cfg| {
        const d = try Disk.make("read-refused", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/f", "0123456789");
        const dir = try d.vol.open("data");
        var out: [16]u8 = undefined;
        try testing.expectError(disk_fat.Error.NotFound, d.vol.readFile(dir, &out));
        try testing.expectError(disk_fat.Error.NotFound, d.vol.readAt(dir, 0, &out));
        const f = try d.vol.open("data/f");
        try testing.expectError(disk_fat.Error.TooBig, d.vol.readFile(f, out[0..9]));
        try testing.expectEqual(@as(usize, 10), try d.vol.readFile(f, &out));
        try testing.expectEqualStrings("0123456789", out[0..10]);
    }
}

test "a file whose chain ends before its size is a broken chain, read from its start or from past its end" {
    for (configs) |cfg| {
        const d = try Disk.make("damaged-chain-ends-early", cfg.shape, cfg.cached);
        defer d.deinit();
        var data: [1500]u8 = undefined; // three clusters
        try d.vol.writeFile("f", pattern(&data, 8));
        const e = try d.vol.open("f");
        const l = Layout.of(d.bytes);
        // Its first cluster is made its last.
        try damageFat(d, cfg.cached, e.first_cluster, l.end());
        var out: [1500]u8 = undefined;
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readAt(e, 1200, &out));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readAt(e, 0, &out));
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(e, &out));
        // What the chain does hold still reads.
        try testing.expectEqual(@as(usize, 512), try d.vol.readAt(e, 0, out[0..512]));
        try testing.expectEqualSlices(u8, data[0..512], out[0..512]);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .short, .path = "/f", .cluster = e.first_cluster, .count = 1 },
            .{ .problem = .leaked, .cluster = e.first_cluster + 1, .count = 2 },
        });
    }
}

test "a directory's growth stopped at any request before its commit is an error, and every cluster it leaves taken is counted" {
    for (formats) |shape| {
        // The FAT on the disk, so a stop fails the read-backs as well.
        const d = try Disk.make("limit-grow-stopped", shape, false);
        defer d.deinit();
        _ = try d.vol.makePath("data/full");
        var name: [32]u8 = undefined;
        for (0..14) |k| try d.vol.writeFile(try std.fmt.bufPrint(&name, "data/full/F{d}", .{k}), "x");
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(false);
        const r0 = d.blk.requests;
        try d.vol.writeFile("data/full/NEXT", "x"); // grows the directory
        const total = d.blk.requests - r0;
        var n: u64 = 0;
        while (n < total) : (n += 1) {
            @memcpy(d.bytes, before);
            try d.mount(false);
            d.blk.fail_after = d.blk.requests + n;
            try testing.expect(std.meta.isError(d.vol.writeFile("data/full/NEXT", "x")));
            const counted = d.vol.cleanups_failed;
            d.blk.fail_after = null;
            try d.mount(false);
            const r = try d.check();
            for (r.found[0..r.len]) |f| {
                if (f.problem != .leaked and f.problem != .fats_differ) {
                    std.debug.print("stopped after {d} requests: {s} at {s}\n", .{ n, @tagName(f.problem), f.text() });
                    return error.TestUnexpectedResult;
                }
            }
            // The last request is the entry's write, the commit: a chain
            // it leaves may be the file's, and is not counted. Before it,
            // what is not given back is counted.
            if (n + 1 < total and r.health.leaked > 0 and counted == 0) {
                std.debug.print("{s}: stopped after {d} of {d} requests: {d} clusters leaked at {d}, none counted\n", .{ @tagName(shape.kind), n, total, r.health.leaked, r.found[0].cluster });
                return error.TestUnexpectedResult;
            }
        }
        @memcpy(d.bytes, before);
        try d.mount(false);
    }
}

test "a directory's name is held to the same length as a file's: one too long is refused, and making a path twice makes one directory" {
    for (configs) |cfg| {
        const d = try Disk.make("dir-name-length", cfg.shape, cfg.cached);
        defer d.deinit();
        const longest = [_]u8{'d'} ** disk_fat.max_name;
        const too_long = [_]u8{'d'} ** (disk_fat.max_name + 1);
        var path: [disk_fat.max_name + 8]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "data/{s}", .{&longest});
        const a = try d.vol.makePath(p);
        try testing.expectEqual(a, try d.vol.makePath(p)); // found, not made again
        const q = try std.fmt.bufPrint(&path, "data/{s}", .{&too_long});
        try testing.expectError(disk_fat.Error.BadName, d.vol.makePath(q));
        const r = try d.check();
        try testing.expect(r.health.clean());
    }
}

// **PAST 4,096 ENTRIES ONLY UNDER `-Dfault-sweep-full` (long.sh)**: the
// old bound was 4,096 rounds, and `removeTree` re-lists each round, so
// 4,100 entries cost seconds (metal-vmm QUEUE 203(d)); the unit run
// removes 600, the same path short of that bound.
test "a tree removes whole whatever its size within the directory limit: past 4,096 entries under long.sh" {
    const entries: u32 = if (options.fault_sweep_full) 4100 else 600;
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16 or !cfg.cached) continue;
        const d = try Disk.make("remove-large", cfg.shape, cfg.cached);
        defer d.deinit();
        _ = try d.vol.makePath("data/big");
        var name: [32]u8 = undefined;
        var i: u32 = 0;
        while (i < entries) : (i += 1) try d.vol.writeFile(try std.fmt.bufPrint(&name, "data/big/F{d}", .{i}), "");
        try d.vol.removeTree("data/big");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/big"));
        const r = try d.check();
        try testing.expect(r.health.clean());
    }
}

test "an append onto a chain longer than its size fills that tail first, and links only what it still needs (metal-vmm B30)" {
    // A stop between an append's link and its size leaves the chain long:
    // clusters in use past the size. The next append counts in the chain,
    // not the size, so it links only what the tail does not already hold.
    for (both) |cached| {
        const d = try Disk.make("append-long", test_disk.small, cached);
        defer d.deinit();
        var first: [600]u8 = undefined;
        try d.vol.writeFile("data/LOG", pattern(&first, 1));
        const before = try d.snapshot();
        defer d.drop(before);
        var more: [1000]u8 = undefined;
        _ = pattern(&more, 2);

        // Fail each request of a 1000-byte append in turn, until one leaves
        // the chain long: the link landed and the size did not.
        var n: u64 = 0;
        const long = while (n < 64) : (n += 1) {
            @memcpy(d.bytes, before);
            try d.mount(cached);
            d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
            const failed = if (d.vol.writeInto("data/LOG", first.len, &more)) false else |_| true;
            d.blk.fault = null;
            if (!failed) continue;
            try d.mount(cached);
            const r = try d.check();
            if (r.len == 1 and r.found[0].problem == .long) break r.found[0].count;
        } else return error.NoRequestLeftTheChainLong;
        // Now an append that needs more than the long chain holds: the
        // premise, asserted, so a change of sizes cannot make this pass
        // without linking anything.
        var tail: [3000]u8 = undefined;
        const cluster_bytes = @as(usize, d.vol.sectors_per_cluster) * test_disk.sector;
        try testing.expect((first.len + tail.len + cluster_bytes - 1) / cluster_bytes > long);
        try d.vol.writeInto("data/LOG", first.len, pattern(&tail, 3));
        try d.mount(cached);
        const r = try d.check();
        try testing.expect(r.health.clean());
        var whole: [first.len + tail.len]u8 = undefined;
        @memcpy(whole[0..first.len], &first);
        @memcpy(whole[first.len..], &tail);
        try d.expectFile("data/LOG", &whole);
    }
}

test "a rename whose write fails, refused whole or landed, keeps the file under exactly one of its names (metal-vmm 145, 147(c,g))" {
    // One write fails, at each request in turn and of each kind. Every
    // refused commit is read back: a new entry that did not land has the
    // tombstone undone, long name and all; a tombstone that landed though
    // refused is undone the same way. So one fault never loses the file,
    // nor leaves it under both names, and the volume checks clean.
    for (both) |cached| {
        const d = try Disk.make("rename-keeps", test_disk.small, cached);
        defer d.deinit();
        var body: [1500]u8 = undefined;
        _ = pattern(&body, 7);
        try d.vol.writeFile("data/a long old name.txt", &body);
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(cached);
        const r0 = d.blk.requests;
        try d.vol.rename("data/a long old name.txt", "data/a new long name.md");
        const total = d.blk.requests - r0;
        for ([_]@TypeOf(@as(@import("virtio_blk.zig").Block.Fault, undefined).kind){ .fails, .lands_and_fails }) |kind| {
            var failures: u32 = 0;
            var kept_old: u32 = 0;
            var n: u64 = 0;
            while (n < total) : (n += 1) {
                @memcpy(d.bytes, before);
                try d.mount(cached);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = kind };
                const failed = if (d.vol.rename("data/a long old name.txt", "data/a new long name.md")) false else |_| true;
                d.blk.fault = null;
                if (!failed) continue;
                failures += 1;
                try d.mount(cached);
                const old = d.read("data/a long old name.txt") catch null;
                defer if (old) |o| testing.allocator.free(o);
                const new = d.read("data/a new long name.md") catch null;
                defer if (new) |o| testing.allocator.free(o);
                const names: u32 = @as(u32, @intFromBool(old != null)) + @intFromBool(new != null);
                if (names != 1) {
                    std.debug.print("rename failing ({t}) at request {d} of {d} ({s}): the file is under {d} names\n", .{ kind, n, total, if (cached) "FAT held" else "FAT on disk", names });
                    return error.TestUnexpectedResult;
                }
                if (old) |o| try testing.expectEqualSlices(u8, &body, o);
                if (new) |o| try testing.expectEqualSlices(u8, &body, o);
                if (old != null) kept_old += 1;
                const r = try d.check();
                try testing.expectEqual(@as(u32, 1), r.health.files);
                try testing.expect(r.health.clean());
            }
            // The premise: faults were injected, renames failed and kept
            // `from`; landed and refused, only the tombstone's undo keeps it.
            try testing.expect(failures > 0);
            try testing.expect(kept_old > 0);
        }
    }
}

test "a rename whose undo is refused too keeps the file under one whole name, or loses it and counts it, never under two (145's review, 147(c))" {
    // The new entry's write fails; then the undo's write fails, whole or
    // after landing. Read back, a landed undo keeps from, long name and all;
    // nothing may leave a file the check sees under neither name.
    for (both) |cached| {
        const d = try Disk.make("rename-undo", test_disk.small, cached);
        defer d.deinit();
        var body: [1500]u8 = undefined;
        _ = pattern(&body, 9);
        try d.vol.writeFile("data/a long old name.txt", &body);
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(cached);
        const r0 = d.blk.requests;
        try d.vol.rename("data/a long old name.txt", "data/a new long name.md");
        const total = d.blk.requests - r0;
        var lost: u32 = 0;
        var kept_whole: u32 = 0;
        var n: u64 = 0;
        const Kind = @TypeOf(@as(@import("virtio_blk.zig").Block.Fault, undefined).kind);
        const cluster_bytes = @as(usize, d.vol.sectors_per_cluster) * test_disk.sector;
        const body_clusters = (body.len + cluster_bytes - 1) / cluster_bytes;
        while (n < total) : (n += 1) for ([_]Kind{ .fails, .lands_and_fails }) |first| {
            for ([_]Kind{ .fails, .lands_and_fails }) |second| {
                var m: u64 = n + 1;
                while (m < n + 8) : (m += 1) {
                    @memcpy(d.bytes, before);
                    try d.mount(cached);
                    const at = d.blk.requests;
                    d.blk.fault = .{ .at = at + n, .kind = first };
                    d.blk.second = .{ .at = at + m, .kind = second };
                    const failed = if (d.vol.rename("data/a long old name.txt", "data/a new long name.md")) false else |_| true;
                    d.blk.fault = null;
                    d.blk.second = null;
                    // A mount starts both again.
                    const counted = d.vol.cleanups_failed;
                    const leaked = d.vol.leaked_clusters;
                    try d.mount(cached);
                    const old = d.read("data/a long old name.txt") catch null;
                    defer if (old) |o| testing.allocator.free(o);
                    const new = d.read("data/a new long name.md") catch null;
                    defer if (new) |o| testing.allocator.free(o);
                    const names: u32 = @as(u32, @intFromBool(old != null)) + @intFromBool(new != null);
                    const r = try d.check();
                    // A file the check counts is one a name reads, or the
                    // undo left it under its alias alone.
                    if (r.health.files != names) {
                        std.debug.print("rename failing ({t}) at {d}, then {t} at {d} ({s}): the check sees {d} files, {d} by name\n", .{ first, n, second, m, if (cached) "held" else "on disk", r.health.files, names });
                        return error.TestUnexpectedResult;
                    }
                    // Never both names; none only where the undo was
                    // refused, and then counted (147(c)).
                    if (names > 1 or (names == 0 and counted == 0)) {
                        std.debug.print("rename failing ({t}) at {d}, then {t} at {d} ({s}): the file is under {d} names, {d} cleanups counted\n", .{ first, n, second, m, if (cached) "held" else "on disk", names, counted });
                        return error.TestUnexpectedResult;
                    }
                    // Lost, its chain is a counted leak, left for fsck.fat,
                    // never freed.
                    if (names == 0) {
                        lost += 1;
                        try testing.expect(leaked >= body_clusters);
                    }
                    if (failed and old != null and counted == 0) kept_whole += 1;
                    // Whichever name reads, it reads the whole file; and with
                    // no leak counted, the volume is clean.
                    if (old) |o| try testing.expectEqualSlices(u8, &body, o);
                    if (new) |o| try testing.expectEqualSlices(u8, &body, o);
                    if (counted == 0) try testing.expect(r.health.clean());
                }
            }
        };
        // The premise: both faults struck, some undos were refused and lost
        // the file, and some failed renames kept `from` whole.
        try testing.expect(lost > 0);
        try testing.expect(kept_whole > 0);
    }
}

test "a chain's FAT entries are written once per FAT sector, not once per entry (metal-vmm B42)" {
    // Production's volume answers a request in ~5.8 ms (network block
    // storage, its write cache off), and a 1 MiB upload cost 143 writes,
    // ~128 of them the FAT: two entries changed a cluster, each writing its
    // sector to both copies. A held FAT now takes a chain a sector at a
    // time: each sector written once per copy, then linked to the last.
    for ([_]test_disk.Shape{ test_disk.small, test_disk.small32 }) |shape| {
        const d = try test_disk.Disk.make("b42", shape, true);
        defer d.deinit();
        try d.mount(true);
        const bytes = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(bytes);
        @memset(bytes, 0x5A);
        const w0 = d.blk.writes;
        try d.vol.writeFile("UPLOAD.BIN", bytes);
        const writes = d.blk.writes - w0;
        const per_cluster = @as(u64, d.vol.sectors_per_cluster) * disk_fat.sector_size;
        const clusters = (bytes.len + per_cluster - 1) / per_cluster;
        const per_sector: u64 = disk_fat.sector_size / @as(u64, if (shape.kind == .fat32) 4 else 2);
        const fat_sectors = (clusters + per_sector - 1) / per_sector + 1;
        // Each FAT sector: written to two copies, and its link to the next
        // to two; the rest is the data and the directory, a few dozen.
        const most = 4 * fat_sectors + 32;
        if (writes > most) {
            std.debug.print("{s}: {d} clusters cost {d} writes, more than {d}\n", .{ @tagName(shape.kind), clusters, writes, most });
            return error.TestUnexpectedResult;
        }
        const back = try testing.allocator.alloc(u8, bytes.len);
        defer testing.allocator.free(back);
        try testing.expectEqual(bytes.len, try d.vol.readFile(try d.vol.open("UPLOAD.BIN"), back));
        try testing.expectEqualSlices(u8, bytes, back);
    }
}

test "a chain is freed a FAT sector at a time, by a remove and by an overwrite (metal-vmm B42's frees)" {
    // A remove or overwrite freed its old chain an entry at a time, each
    // writing its sector to both copies: a 1 MiB file on small's 512-byte
    // clusters is 2,048 entries, ~4,096 writes, in 8 or 9 FAT16 sectors.
    for ([_]test_disk.Shape{ test_disk.small, test_disk.small32 }) |shape| {
        for ([_]enum { remove, overwrite }{ .remove, .overwrite }) |how| {
            const d = try test_disk.Disk.make("b42-frees", shape, true);
            defer d.deinit();
            try d.mount(true);
            const bytes = try testing.allocator.alloc(u8, 1 << 20);
            defer testing.allocator.free(bytes);
            @memset(bytes, 0x5A);
            try d.vol.writeFile("UPLOAD.BIN", bytes);
            const free_before = (try d.vol.space()).free;
            const w0 = d.blk.writes;
            switch (how) {
                .remove => try d.vol.remove("UPLOAD.BIN"),
                .overwrite => try d.vol.writeFile("UPLOAD.BIN", "small now"),
            }
            const writes = d.blk.writes - w0;
            const per_cluster = @as(u64, d.vol.sectors_per_cluster) * disk_fat.sector_size;
            const clusters = (bytes.len + per_cluster - 1) / per_cluster;
            const per_sector: u64 = disk_fat.sector_size / @as(u64, if (shape.kind == .fat32) 4 else 2);
            const fat_sectors = (clusters + per_sector - 1) / per_sector + 1;
            // Each FAT sector the chain is in, freed: written to two copies;
            // the rest is the directory and an overwrite's new cluster.
            const most = 2 * fat_sectors + 16;
            if (writes > most) {
                std.debug.print("{s} {s}: {d} clusters freed with {d} writes, more than {d}\n", .{ @tagName(shape.kind), @tagName(how), clusters, writes, most });
                return error.TestUnexpectedResult;
            }
            // Every cluster came back, and the volume is as fsck would have it.
            const free_after = (try d.vol.space()).free;
            const new_bytes: u64 = if (how == .overwrite) per_cluster else 0;
            try testing.expectEqual(free_before + clusters * per_cluster - new_bytes, free_after);
            try testing.expectEqual(try d.vol.countFreeAgain(), @as(u32, @intCast(free_after / per_cluster)));
            const r = try d.check();
            try r.expect(&.{});
        }
    }
}

test "the check counts orphaned long-name parts as fsck.fat finds them: by run, number and checksum (metal-vmm 148(b))" {
    const d = try Disk.make("orphan-rules", test_disk.small, false);
    defer d.deinit();
    try d.vol.writeFile("data/A Rather Long Name For A Test File.txt", "x");
    const pristine = try d.snapshot();
    defer d.drop(pristine);
    // The run: its last-flagged part first, the short entry after its parts.
    const first = blk: {
        var at: usize = 0;
        while (at + 32 <= d.bytes.len) : (at += 32) {
            // This file's: the one name of three parts or more.
            if (d.bytes[at + 11] == 0x0F and d.bytes[at] & 0x40 != 0 and d.bytes[at] != 0xE5 and d.bytes[at] & 0x1F >= 3) break :blk at;
        }
        return error.NoLongName;
    };
    const parts: u32 = d.bytes[first] & 0x1F;
    try testing.expect(parts >= 3);
    const short = first + parts * 32;
    const Case = struct { name: []const u8, at: usize, value: u8, orphans: u32, runs: u32 = 1, fragments: u32 = 0 };
    const cases = [_]Case{
        .{ .name = "whole", .at = first, .value = pristine[first], .orphans = 0, .runs = 0 },
        // A middle part tombstoned: the run before it, which fsck.fat calls
        // orphaned, and after it a fragment it leaves (metal-vmm 152).
        .{ .name = "a middle part tombstoned", .at = first + 32, .value = 0xE5, .orphans = 1, .runs = 1, .fragments = parts - 2 },
        .{ .name = "its short entry tombstoned", .at = short, .value = 0xE5, .orphans = parts },
        .{ .name = "a part of another checksum", .at = first + 32 + 13, .value = pristine[first + 32 + 13] ^ 1, .orphans = parts },
        .{ .name = "a part numbered out of turn", .at = first + 32, .value = pristine[first + 32] +% 1, .orphans = parts },
        .{ .name = "its last-flagged part tombstoned", .at = first, .value = 0xE5, .orphans = 0, .runs = 0, .fragments = parts - 1 },
        // Every part agrees, and the short entry's name is another's.
        .{ .name = "its short entry of another checksum", .at = short + 6, .value = if (pristine[short + 6] == 'Z') 'Y' else 'Z', .orphans = parts },
    };
    for (cases) |c| {
        @memcpy(d.bytes, pristine);
        d.bytes[c.at] = c.value;
        try d.mount(false);
        const r = try d.check();
        if (r.health.orphaned_parts != c.orphans or r.health.orphaned_runs != c.runs or r.health.lfn_fragments != c.fragments) {
            std.debug.print("{s}: the check counted {d} orphaned parts in {d} runs and {d} in fragments, not {d} in {d} and {d}\n", .{ c.name, r.health.orphaned_parts, r.health.orphaned_runs, r.health.lfn_fragments, c.orphans, c.runs, c.fragments });
            return error.TestUnexpectedResult;
        }
    }
    @memcpy(d.bytes, pristine);
    try d.mount(false);
}

// ---- boundaries, side by side (the off-by-one hunt) -------------------------

test "a link to max_cluster is followed and to max_cluster + 1 is a broken chain; to 2 is followed and to 1 is broken" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-edge-links", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("z", "x"); // cluster 2 on FAT16; FAT32's root is 2
        var data: [1000]u8 = undefined; // two clusters
        try d.vol.writeFile("f", pattern(&data, 3));
        const e = try d.vol.open("f");
        const l = Layout.of(d.bytes);
        const max_cluster: disk_fat.Cluster = @intCast(l.clusters + 1);
        try testing.expectEqual(max_cluster, d.vol.max_cluster);
        for (0..2) |copy| l.set(d.bytes, copy, max_cluster, l.end());
        try testing.expect(e.first_cluster > 2);
        for ([_]disk_fat.Cluster{ max_cluster, max_cluster + 1, 2, 1 }, [_]bool{ true, false, true, false }) |link, followed| {
            try damageFat(d, cached, e.first_cluster, link);
            var out: [1000]u8 = undefined;
            if (followed) {
                try testing.expectEqual(data.len, try d.vol.readFile(e, &out));
                try testing.expectEqualSlices(u8, data[0..512], out[0..512]);
                try testing.expectEqual(@as(u32, 2), (try d.vol.layout(e)).clusters);
            } else {
                try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(e, &out));
                try testing.expectError(disk_fat.Error.BadChain, d.vol.layout(e));
            }
        }
    }
}

test "an entry whose first cluster is max_cluster reads, one at max_cluster + 1 is a broken chain" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-edge-first-cluster", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "some bytes");
        const e = try d.vol.open("f");
        const l = Layout.of(d.bytes);
        const max_cluster: disk_fat.Cluster = @intCast(l.clusters + 1);
        for (0..2) |copy| l.set(d.bytes, copy, max_cluster, l.end());
        var out: [64]u8 = undefined;
        setEntry(d, e, .first_cluster, max_cluster);
        try d.mount(cached);
        try testing.expectEqual(@as(usize, 10), try d.vol.readFile(try d.vol.open("f"), &out));
        setEntry(d, e, .first_cluster, max_cluster + 1);
        try d.mount(cached);
        try testing.expectError(disk_fat.Error.BadChain, d.vol.readFile(try d.vol.open("f"), &out));
    }
}

test "FAT32: a root at max_cluster mounts, at max_cluster + 1 is refused; at 2 mounts, at 1 is refused" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small32.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio_blk.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    test_disk.format(bytes, test_disk.small32);
    const max_cluster: u32 = @intCast(Layout.of(bytes).clusters + 1);
    for ([_]u32{ max_cluster, max_cluster + 1, 2, 1 }, [_]bool{ true, false, true, false }) |root, mounts| {
        test_disk.format(bytes, test_disk.small32);
        std.mem.writeInt(u32, bytes[44..48], root, .little);
        const l = Layout.of(bytes);
        if (root <= max_cluster) for (0..2) |copy| l.set(bytes, copy, root, l.end());
        if (mounts) {
            const v = try disk_fat.Volume.mount(&blk, &scratch, 0);
            try testing.expectEqual(root, v.root_cluster);
        } else try testing.expectError(disk_fat.Error.BadRoot, disk_fat.Volume.mount(&blk, &scratch, 0));
    }
}

test "a chain ending at a FAT sector's last entry, and one ending at the next sector's first, are written, read, freed and checked whole" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const per_sector: u32 = disk_fat.sector_size / @as(u32, if (shape.kind == .fat32) 4 else 2);
        var remove_writes: [2]u64 = undefined;
        for ([_]u32{ per_sector - 1, per_sector }, 0..) |last, side| {
            const d = try Disk.make("edge-fat-sector", shape, cached);
            defer d.deinit();
            // The first free cluster: where a fresh volume's next chain starts.
            try d.vol.writeFile("probe", "x");
            const start = (try d.vol.open("probe")).first_cluster;
            try d.vol.remove("probe");
            const clusters = last - start + 1;
            const bytes = try testing.allocator.alloc(u8, clusters * disk_fat.sector_size);
            defer testing.allocator.free(bytes);
            _ = pattern(bytes, @intCast(side));
            const free_before = d.free();
            try d.vol.writeFile("f", bytes);
            var chain: [300]disk_fat.Cluster = undefined;
            const c = chainOf(d, (try d.vol.open("f")).first_cluster, &chain);
            try testing.expectEqual(@as(usize, clusters), c.len);
            try testing.expectEqual(start, c[0]);
            try testing.expectEqual(last, c[c.len - 1]);
            try testing.expect(Layout.of(d.bytes).ends(Layout.of(d.bytes).get(d.bytes, 0, last)));
            try testing.expect(d.fatsAgree());
            try d.expectFile("f", bytes);
            const w0 = d.blk.writes;
            try d.vol.remove("f");
            remove_writes[side] = d.blk.writes - w0;
            try testing.expectEqual(free_before, d.free());
            try testing.expectEqual(@as(u32, @intCast(free_before)), try d.vol.countFreeAgain());
            try testing.expect(d.fatsAgree());
            const r = try d.check();
            try r.expect(&.{});
        }
        // One more cluster, in the next FAT sector: freed by that sector
        // written to both copies, held FAT or not (one entry, its sector).
        try testing.expectEqual(remove_writes[0] + 2, remove_writes[1]);
    }
}

test "the ~N alias: ~9 keeps six of the name's characters, ~10 keeps five" {
    for (configs) |cfg| {
        const d = try Disk.make("edge-alias-tail", cfg.shape, cfg.cached);
        defer d.deinit();
        var path: [64]u8 = undefined;
        for (1..11) |k| try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/abcdefghij-{d}.txt", .{k}), "x");
        try testing.expectEqualStrings("ABCDEF~1.TXT", (try d.vol.open("data/abcdefghij-1.txt")).alias());
        try testing.expectEqualStrings("ABCDEF~9.TXT", (try d.vol.open("data/abcdefghij-9.txt")).alias());
        try testing.expectEqualStrings("ABCDE~10.TXT", (try d.vol.open("data/abcdefghij-10.txt")).alias());
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "a name of max_name is written and renamed to, one of max_name + 1 is refused by both and takes nothing" {
    for (configs) |cfg| {
        const d = try Disk.make("edge-name-length", cfg.shape, cfg.cached);
        defer d.deinit();
        const longest = [_]u8{'n'} ** disk_fat.max_name;
        const too_long = [_]u8{'n'} ** (disk_fat.max_name + 1);
        var path: [disk_fat.max_name + 8]u8 = undefined;
        try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/{s}", .{&longest}), "longest");
        try d.expectFile(try std.fmt.bufPrint(&path, "data/{s}", .{&longest}), "longest");
        const before = d.free();
        try testing.expectError(disk_fat.Error.BadName, d.vol.writeFile(try std.fmt.bufPrint(&path, "data/{s}", .{&too_long}), "x"));
        try testing.expectEqual(before, d.free());

        try d.vol.writeFile("data/r", "renamed");
        try testing.expectError(disk_fat.Error.BadName, d.vol.rename("data/r", try std.fmt.bufPrint(&path, "data/{s}", .{&too_long})));
        try d.expectFile("data/r", "renamed");
        var other = longest;
        other[0] = 'm';
        try d.vol.rename("data/r", try std.fmt.bufPrint(&path, "data/{s}", .{&other}));
        try d.expectFile(try std.fmt.bufPrint(&path, "data/{s}", .{&other}), "renamed");
        try testing.expectError(disk_fat.Error.NotFound, d.vol.open("data/r"));
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "a failed sector read and a failed write are counted on the volume, and the disk's I/O errors on its Block (metal-vmm QUEUE 193.3)" {
    const d = try test_disk.Disk.make("damaged-counted-failures", small, false);
    defer d.deinit();
    try d.vol.writeFile("a.txt", "hello");
    try testing.expectEqual(@as(u64, 0), d.vol.read_failures);
    try testing.expectEqual(@as(u64, 0), d.vol.write_failures);
    try testing.expect(!d.blk.failures.any());
    // Every request from here fails.
    d.blk.fail_after = d.blk.requests;
    var sector: [disk_fat.sector_size]u8 = undefined;
    try testing.expectError(disk_fat.Error.ReadFailed, d.vol.readSector(d.vol.data_start, &sector));
    try testing.expectError(disk_fat.Error.WriteFailed, d.vol.writeSector(d.vol.data_start, &sector));
    d.blk.fail_after = null;
    try testing.expectEqual(@as(u64, 1), d.vol.read_failures);
    try testing.expectEqual(@as(u64, 1), d.vol.write_failures);
    try testing.expectEqual(@as(u64, 2), d.blk.failures.ioerr);
}

test "a write-through disk's clear is not counted as a SYNCHRONIZE sent; a write turned away is counted (metal-vmm QUEUE 193, gap 9)" {
    const d = try test_disk.Disk.make("flush-counted", small, false);
    defer d.deinit();
    try d.vol.writeFile("a.txt", "hello");
    try testing.expectEqual(virtio_blk.blk_s_ok, d.blk.flush());
    try testing.expect(d.blk.flushes > 0);
    // A disk in memory writes through: nothing was sent to it.
    try testing.expectEqual(@as(u64, 0), d.blk.synchronizes_sent);
    try testing.expect(!d.blk.synchronize_unknown);

    d.vol.writes = .refused;
    var sector: [disk_fat.sector_size]u8 = undefined;
    try testing.expectError(disk_fat.Error.WritesRefused, d.vol.writeSector(d.vol.data_start, &sector));
    try testing.expectError(disk_fat.Error.WritesRefused, d.vol.writeSectors(d.vol.data_start, 1, &sector));
    try testing.expectEqual(@as(u64, 2), d.vol.writes_turned_away);
}

/// `aliasFor` as it was before 203(b): `~1, ~2, …`, a listing for each.
fn aliasByProbing(vol: *disk_fat.Volume, dir: u32, name: []const u8) ![11]u8 {
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const c = disk_fat_dir.aliasCandidate(name, n);
        if (!try vol.aliasTaken(dir, c)) return c;
    }
    return disk_fat.Error.BadName;
}

test "a name's ~N alias, from one listing, is the one probing ~1, ~2, … a listing each gives: directories with holes, other bases, and names that hold a ~ (metal-vmm QUEUE 203(b))" {
    var prng: std.Random.DefaultPrng = .init(203);
    const r = prng.random();
    var compared: usize = 0;
    for (0..12) |round| {
        const cached = round % 2 == 0;
        const d = try Disk.make("alias-one-listing", test_disk.small, cached);
        defer d.deinit();
        const dir = try d.vol.makePath("data/d");
        var path: [64]u8 = undefined;
        // Names sharing the probe's first six characters, some removed
        // again past a point (holes), so the first free alias lands
        // anywhere from ~1 to past ~100 (the base shortens at ~10 and ~100).
        // The first round has none: its first free is ~131, past ~100.
        const most = if (round == 0) 130 else r.intRangeAtMost(usize, 1, 120);
        const holes_from = if (round == 0) most else r.intRangeAtMost(usize, 0, most);
        for (0..most) |k| try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/d/abcdefgh-{d}.txt", .{k}), "x");
        for (holes_from..most) |k| if (r.boolean()) try d.vol.remove(try std.fmt.bufPrint(&path, "data/d/abcdefgh-{d}.txt", .{k}));
        // Other bases, another extension, and names that are themselves
        // aliases or hold a ~ in what an alias keeps of them.
        try d.vol.writeFile("data/d/abcdefgh-x.md", "x");
        try d.vol.writeFile("data/d/zzzzzzzz-1.txt", "x");
        // An alias as a name is refused while its file holds it.
        d.vol.writeFile(try std.fmt.bufPrint(&path, "data/d/ABCDEF~{d}.TXT", .{r.intRangeAtMost(u32, 1, 9)}), "x") catch |e| switch (e) {
            disk_fat.Error.NameTaken => {},
            else => return e,
        };
        try d.vol.writeFile("data/d/ab~1cdefgh.txt", "x");
        for ([_][]const u8{ "abcdefgh-new.txt", "abcdefgh-new.md", "ab~1cdefgh-2.txt", "zzzzzzzz-2.txt", "abc.defghij" }) |name| {
            try testing.expectEqual(try aliasByProbing(&d.vol, dir, name), try d.vol.aliasFor(dir, name));
            compared += 1;
        }
        const c = try d.check();
        try c.expect(&.{});
    }
    try testing.expectEqual(@as(usize, 60), compared);
}

test "a name's alias costs one listing however many of its directory's names share its first six characters (203(b))" {
    const d = try Disk.make("alias-cost", test_disk.small, false);
    defer d.deinit();
    const dir = try d.vol.makePath("data/sessions");
    var path: [64]u8 = undefined;
    for (0..300) |k| try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k}), "x");
    // Its ~301 among 300 alike, and a name alone in its base: the same
    // reads, one listing each.
    const before_alike = d.blk.requests;
    const alike = try d.vol.aliasFor(dir, "session-0300.md");
    const alike_reads = d.blk.requests - before_alike;
    const before_alone = d.blk.requests;
    _ = try d.vol.aliasFor(dir, "unrelated-name.md");
    const alone_reads = d.blk.requests - before_alone;
    try testing.expectEqualStrings("SESS~301MD ", &alike);
    try testing.expectEqual(alone_reads, alike_reads);
}
