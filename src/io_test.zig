//! `io.zig`'s two disks, on the host: two FAT16 disks in memory
//! (`test_disk.zig`), the site's and the data volume, and the routing between
//! them that `keepData` sets up — which disk a path goes to, which writes are
//! refused, and that a refusal is logged.
//!
//! Each test sets io's routing itself (`mount`, then `keepData`), because it
//! is module state that outlives a test. What is not tested here:
//! `Dir.fromRoot`'s panic, which would take the test runner down with it.

const std = @import("std");
const io_mod = @import("io.zig");
const serial = @import("serial.zig");
const test_disk = @import("test_disk.zig");
const disk_fat = @import("disk_fat.zig");

const testing = std.testing;
const Disk = test_disk.Disk;
const io = io_mod.io();
const cwd = io_mod.Dir.cwd();
const data_dirs = [_][]const u8{ "data", "auth" };

/// A site disk and a data volume, with io routing between them. With
/// `with_volume` false, the data directories are on the site's disk.
const Two = struct {
    site: *Disk,
    volume: *Disk,

    fn make(with_volume: bool) !Two {
        const site = try Disk.make("io-site", test_disk.small, false);
        errdefer site.deinit();
        const volume = try Disk.make("io-volume", test_disk.small, false);
        io_mod.mount(site.vol);
        io_mod.keepData(&data_dirs, if (with_volume) volume.vol else null);
        serial.clearCaptured();
        return .{ .site = site, .volume = volume };
    }

    /// After a test writes to a disk directly, through its own copy of the
    /// volume: io's copies take it, so that one copy, io's, is again the one
    /// that writes and keeps the free count (see `deinit`).
    fn resync(t: Two, with_volume: bool) void {
        io_mod.mount(t.site.vol);
        io_mod.keepData(&data_dirs, if (with_volume) t.volume.vol else null);
    }

    /// io holds its own copies of the volumes (io.mount and io.keepData take
    /// them by value), and those are the ones the writes moved: the kept free
    /// count among them. They come back before the disks are checked.
    fn deinit(t: Two) void {
        if (io_mod.siteVolume()) |v| t.site.vol = v.*;
        if (io_mod.dataVolume()) |v| t.volume.vol = v.*;
        t.site.deinit();
        t.volume.deinit();
    }
};

fn expectAbsent(d: *Disk, path: []const u8) !void {
    try testing.expectError(disk_fat.Error.NotFound, d.vol.open(path));
}

fn logged(what: []const u8) bool {
    return std.mem.indexOf(u8, serial.captured(), what) != null;
}

// **NOTHING LEAVES AHEAD OF THE WRITES BEFORE IT** (`io.durable`): a write
// leaves its disk unflushed, the next response's `durable` flushes it once,
// and a response with no write before it, or after only reads, sends none.
test "a write is flushed before the next response, once, and a read asks no flush" {
    const t = try Two.make(true);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try cwd.createDirPath(io, "data/chat");
    try cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "saved" });
    try testing.expect(t.volume.blk.unflushed);
    try testing.expect(!t.site.blk.unflushed);

    io_mod.durable();
    try testing.expect(!t.volume.blk.unflushed);
    try testing.expectEqual(@as(u64, 1), t.volume.blk.flushes);
    try testing.expectEqual(@as(u64, 0), t.site.blk.flushes);

    io_mod.durable();
    try testing.expectEqualStrings("saved", try cwd.readFileAlloc(io, "data/chat/plan.md", arena.allocator(), .unlimited));
    io_mod.durable();
    try testing.expectEqual(@as(u64, 1), t.volume.blk.flushes);
}

test "a write under data/ or auth/ lands on the volume, and nothing of it on the site's disk" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.createDirPath(io, "data/chat");
    try cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "on the volume" });
    try cwd.writeFile(io, .{ .sub_path = "auth/7/password", .data = "hash" });
    try t.volume.expectFile("data/chat/plan.md", "on the volume");
    try t.volume.expectFile("auth/7/password", "hash");
    try expectAbsent(t.site, "data");
    try expectAbsent(t.site, "auth");

    const got = try cwd.readFileAlloc(io, "data/chat/plan.md", testing.allocator, .limited(100));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("on the volume", got);
    try testing.expectEqualStrings("", serial.captured());
}

test "a write outside the data directories is refused and logged, and changes neither disk" {
    const t = try Two.make(true);
    defer t.deinit();
    const site_free = t.site.free();
    const volume_free = t.volume.free();
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "index.html", .data = "x" }));
    try testing.expect(logged("refused: a write outside the data directories: index.html"));
    // Each way of changing the disk, not only writeFile.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.createDirPath(io, "static/new"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.createFile(io, "notes.txt", .{ .truncate = false }));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteFile(io, "index.html"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "static"));
    // A name that only begins like a data directory is not one.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "database/x", .data = "x" }));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "dat/x", .data = "x" }));
    try testing.expectEqual(site_free, t.site.free());
    try testing.expectEqual(volume_free, t.volume.free());
}

test "a path with . or .. is refused for writes and not found for reads, on either side" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/keep", .data = "kept" });
    const volume_free = t.volume.free();
    const bad = [_][]const u8{ "data/../x", "./data/x", "data/./x", "data/chat/../../x", "..", "data/.." };
    for (bad) |p| {
        serial.clearCaptured();
        try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = p, .data = "x" }));
        try testing.expect(logged("refused: a write to a path with ., .. or an empty part: "));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.readFileAlloc(io, p, testing.allocator, .limited(100)));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.statFile(io, p, .{}));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.openDir(io, p, .{}));
    }
    // **THE ONE THAT WOULD HURT:** `data/..` resolves, on the volume, to its
    // root, and removing that tree would empty the volume.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "data/.."));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "data/chat/../.."));
    try testing.expectEqual(volume_free, t.volume.free());
    try t.volume.expectFile("data/keep", "kept");
    try expectAbsent(t.volume, "x");
    try expectAbsent(t.site, "x");
}

test "a path with an empty part is refused for writes and not found for reads, on either side" {
    // **A PATH IS ITS PARTS, EACH NAMED** (Steve, 2026-10-10: no papering
    // over): a doubled, leading or trailing slash is a path built wrong. It
    // was walked as the path it might have meant (`data//keep` as
    // `data/keep`); now it names nothing, and a write to it is refused.
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/keep", .data = "kept" });
    const volume_free = t.volume.free();
    const bad = [_][]const u8{ "data//keep", "/data/keep", "data/keep/", "data/chat//x", "//", "data/" };
    for (bad) |p| {
        serial.clearCaptured();
        try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = p, .data = "x" }));
        try testing.expect(logged("refused: a write to a path with ., .. or an empty part: "));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.readFileAlloc(io, p, testing.allocator, .limited(100)));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.statFile(io, p, .{}));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.openDir(io, p, .{}));
    }
    // Removing `data/` would be removing the data directory.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "data/"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "/data"));
    try testing.expectEqual(volume_free, t.volume.free());
    try t.volume.expectFile("data/keep", "kept");
}

test "the first directory is matched without case, as FAT matches it" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "Data/x", .data = "upper" });
    try cwd.writeFile(io, .{ .sub_path = "AUTH/y", .data = "all upper" });
    try t.volume.expectFile("data/x", "upper");
    try t.volume.expectFile("auth/y", "all upper");
    try expectAbsent(t.site, "data");
    try expectAbsent(t.site, "auth");
    try testing.expectEqualStrings("", serial.captured());
}

test "with a volume attached, data/ is read from it, never from the site's disk" {
    const t = try Two.make(true);
    defer t.deinit();
    // The boot disk carries a stale data/ of its own (an image built before
    // the volume, say) and the site's files.
    try t.site.vol.writeFile("data/x", "stale, on the boot disk");
    try t.site.vol.writeFile("data/only-here", "stale");
    try t.site.vol.writeFile("index.html", "<p>site</p>");
    try t.volume.vol.writeFile("data/x", "current, on the volume");
    t.resync(true);

    const x = try cwd.readFileAlloc(io, "data/x", testing.allocator, .limited(100));
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("current, on the volume", x);
    try testing.expectError(io_mod.Error.FileNotFound, cwd.readFileAlloc(io, "data/only-here", testing.allocator, .limited(100)));
    const page = try cwd.readFileAlloc(io, "index.html", testing.allocator, .limited(100));
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("<p>site</p>", page);
    // And the site's file is not on the volume to be read instead.
    try expectAbsent(t.volume, "index.html");
}

test "with no volume, data/ is on the site's disk, and writes outside it are still refused" {
    const t = try Two.make(false);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/x", .data = "one disk" });
    try t.site.expectFile("data/x", "one disk");
    try expectAbsent(t.volume, "data");
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "index.html", .data = "x" }));
    try testing.expect(logged("refused: a write outside the data directories"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "data/../index.html", .data = "x" }));
    try expectAbsent(t.site, "index.html");
}

test "an append through a File goes to the disk its path names" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.createDirPath(io, "data/chat/1_2/sessions");
    const path = "data/chat/1_2/sessions/plan.md";
    // The application's append, spelled as it spells it.
    for ([_][]const u8{ "one\n", "two\n", "three\n" }) |line| {
        var file = try cwd.createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        const st = try file.stat(io);
        try file.writePositionalAll(io, line, st.size);
    }
    try t.volume.expectFile(path, "one\ntwo\nthree\n");
    try expectAbsent(t.site, "data");

    var file = try cwd.openFile(io, path, .{});
    var buf: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try file.readPositionalAll(io, &buf, 4));
    try testing.expectEqualStrings("two\nt", &buf);
}

test "an offset past what FAT holds reads nothing and writes nothing, rather than a panic" {
    // io.zig hands disk_fat a u32 offset. Each cast is guarded (QUEUE.md item
    // 69): a read at or past the file's end is its end, and a write past
    // 4 GiB is a full disk. These are the edges of both.
    const t = try Two.make(true);
    defer t.deinit();
    const path = "data/x";
    try cwd.writeFile(io, .{ .sub_path = path, .data = "abc" });
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try file.readPositionalAll(io, &buf, 2));
    for ([_]u64{ 3, 0xFFFF_FFFF, 0x1_0000_0000, std.math.maxInt(u64) }) |at|
        try testing.expectEqual(@as(usize, 0), try file.readPositionalAll(io, &buf, at));
    for ([_]u64{ 0x1_0000_0000, std.math.maxInt(u64) }) |at|
        try testing.expectError(io_mod.Error.NoSpaceLeft, file.writePositionalAll(io, "x", at));
    // Just under the bound it is disk_fat's own answer: past the end is a hole,
    // which FAT cannot leave, and is refused as a failed write.
    try testing.expectError(io_mod.Error.WriteFailed, file.writePositionalAll(io, "x", 0xFFFF_FFFF));
    try t.volume.expectFile(path, "abc");
}

test "a directory that cannot be read is an error, never an empty listing (metal-vmm QUEUE 104)" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/players/p1/name", .data = "Ada" });
    var dir = try cwd.openDir(io, "data/players", .{ .iterate = true });
    defer dir.close(io);
    // The next request the disk is asked, whichever that is, fails.
    t.volume.blk.fault = .{ .at = t.volume.blk.requests, .kind = .fails };
    var it = dir.iterate();
    try testing.expectError(io_mod.Error.ReadFailed, it.next(io));
    // A directory whose entry names a cluster outside the data, as a damaged
    // entry does: disk_fat refuses to walk it, and that is no empty folder.
    const damaged = io_mod.Dir{ .cluster = 0x0FFF_FFF0, .place = .data };
    var it2 = damaged.iterate();
    try testing.expect(std.meta.isError(it2.next(io)));
}

test "a directory opened under data/ lists the volume's entries, and deleting a tree there frees the volume" {
    const t = try Two.make(true);
    defer t.deinit();
    const empty = t.volume.free();
    try t.site.vol.writeFile("data/players/stale", "x");
    t.resync(true);
    try cwd.writeFile(io, .{ .sub_path = "data/players/p1/name", .data = "Ada" });
    try cwd.writeFile(io, .{ .sub_path = "data/players/p2/name", .data = "Lin" });

    var dir = try cwd.openDir(io, "data/players", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    // A name is good until the next `next` (it is the iterator's, as std's
    // is), so each is copied out, as store.list does.
    var seen: [2][8]u8 = undefined;
    var lens: [2]usize = undefined;
    var n: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(n < 2);
        try testing.expectEqual(io_mod.Kind.directory, e.kind);
        @memcpy(seen[n][0..e.name.len], e.name);
        lens[n] = e.name.len;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("p1", seen[0][0..lens[0]]);
    try testing.expectEqualStrings("p2", seen[1][0..lens[1]]);

    try cwd.deleteTree(io, "data/players");
    try testing.expectError(io_mod.Error.FileNotFound, cwd.statFile(io, "data/players/p1/name", .{}));
    // Only `data` itself is left on the volume: one cluster.
    try testing.expectEqual(empty - 1, t.volume.free());
    // The boot disk's stale copy was not the one removed.
    try t.site.expectFile("data/players/stale", "x");
}

test "rename replaces a file on the volume, as std.Io spells it, and refuses what disk_fat.rename does" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/topic.count", .data = "4\n" });
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/~0a1b2c3d.tmp", .data = "5\n" });
    try cwd.rename("data/chat/1_2/sessions/~0a1b2c3d.tmp", cwd, "data/chat/1_2/sessions/topic.count", io);
    try t.volume.expectFile("data/chat/1_2/sessions/topic.count", "5\n");
    try expectAbsent(t.volume, "data/chat/1_2/sessions/~0a1b2c3d.tmp");

    try testing.expectError(io_mod.Error.FileNotFound, cwd.rename("data/chat/nothing", cwd, "data/chat/x", io));
    // Across directories: disk_fat.rename moves within one only.
    try testing.expectError(io_mod.Error.NameTooLong, cwd.rename("data/chat/1_2/sessions/topic.count", cwd, "data/topic.count", io));
    // Off the volume, or onto the site: refused as every write there is.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.rename("data/chat/1_2/sessions/topic.count", cwd, "index.html", io));
    try t.volume.expectFile("data/chat/1_2/sessions/topic.count", "5\n");
}

test "an exclusive write makes a file that is absent, and refuses one that is there, leaving it as it was" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "auth/~0a1b2c3d.new", .data = "first", .flags = .{ .exclusive = true } });
    try t.volume.expectFile("auth/~0a1b2c3d.new", "first");
    try testing.expectError(io_mod.Error.PathAlreadyExists, cwd.writeFile(io, .{ .sub_path = "auth/~0a1b2c3d.new", .data = "second", .flags = .{ .exclusive = true } }));
    try t.volume.expectFile("auth/~0a1b2c3d.new", "first");
}

test "renamePreserve moves a file to a name that is absent, and refuses one that is there, both left as they were" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "auth/~0a1b2c3d.new", .data = "made" });
    try cwd.renamePreserve("auth/~0a1b2c3d.new", cwd, "auth/_session_secret", io);
    try t.volume.expectFile("auth/_session_secret", "made");
    try expectAbsent(t.volume, "auth/~0a1b2c3d.new");

    try cwd.writeFile(io, .{ .sub_path = "auth/~0e0f1011.new", .data = "a second site's" });
    try testing.expectError(io_mod.Error.PathAlreadyExists, cwd.renamePreserve("auth/~0e0f1011.new", cwd, "auth/_session_secret", io));
    try t.volume.expectFile("auth/_session_secret", "made");
    try t.volume.expectFile("auth/~0e0f1011.new", "a second site's");
    try testing.expectError(io_mod.Error.FileNotFound, cwd.renamePreserve("auth/nothing", cwd, "auth/x", io));
}

test "a file written over a directory is IsDir, as on Linux, and the directory stays" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/topic.md", .data = "x" });
    try testing.expectError(io_mod.Error.IsDir, cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/Sessions", .data = "a file" }));
    try t.volume.expectFile("data/chat/1_2/sessions/topic.md", "x");
}

test "an append onto a directory is IsDir, as on Linux, never NameTooLong (metal-vmm QUEUE 172)" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/topic.md", .data = "x" });
    const opened = cwd.createFile(io, "data/chat/1_2/sessions", .{ .truncate = false });
    if (opened) |f| {
        var file = f;
        defer file.close(io);
        try testing.expectError(io_mod.Error.IsDir, file.writePositionalAll(io, "a line", 0));
    } else |e| try testing.expectEqual(io_mod.Error.IsDir, e);
    try t.volume.expectFile("data/chat/1_2/sessions/topic.md", "x");
}

// ── listings, at the sizes the application makes (QUEUE.md item 50) ──────────

/// An upload's name as chat stores it: 32 hex digits and an extension.
fn uploadName(buf: *[40]u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>32}.webp", .{n *% 0x9E3779B97F4A7C15}) catch unreachable;
}

/// What angry-gopher's store.list keeps of a listing, in the request's
/// arena: every name copied, and the entries in a growing list. Done here as
/// store.list does it, since the application is not built into these tests.
fn listLikeStore(alloc: std.mem.Allocator, path: []const u8) ![]io_mod.Entry {
    var d = try cwd.openDir(io, path, .{ .iterate = true });
    defer d.close(io);
    var out: std.ArrayList(io_mod.Entry) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        try out.append(alloc, .{ .name = try alloc.dupe(u8, e.name), .kind = e.kind });
    }
    return out.items;
}

/// An allocator that counts what is asked of it, over an arena as a request's is.
const Counting = struct {
    arena: std.heap.ArenaAllocator,
    asked: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.asked += n;
        return self.arena.allocator().rawAlloc(n, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ok = self.arena.allocator().rawResize(m, a, n, ra);
        if (ok and n > m.len) self.asked += n - m.len;
        return ok;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.arena.allocator().rawFree(m, a, ra);
    }
};

test "prod's largest folder, 70 uploads, listed as store.list does, takes a few KiB of the request's memory" {
    const t = try Two.make(true);
    defer t.deinit();
    var buf: [40]u8 = undefined;
    var path: [80]u8 = undefined;
    for (0..70) |n| {
        const p = try std.fmt.bufPrint(&path, "data/chat/c/1_2/uploads/{s}", .{uploadName(&buf, n)});
        try cwd.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    var counting = Counting{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer counting.arena.deinit();
    const got = try listLikeStore(counting.allocator(), "data/chat/c/1_2/uploads");
    try testing.expectEqual(@as(usize, 70), got.len);
    for (got, 0..) |e, i| {
        try testing.expectEqual(io_mod.Kind.file, e.kind);
        try testing.expectEqual(@as(usize, 37), e.name.len);
        for (got[0..i]) |o| try testing.expect(!std.mem.eql(u8, o.name, e.name));
    }
    // 70 names of 37 bytes is 2,590; the entries and the list's growth are
    // the rest. The request heap keeps 32 MiB (probe/gopher.zig), and grows.
    try testing.expect(counting.asked < 16 * 1024);
    // And the iterator itself, on the stack, is a sector and a name, not a
    // listing: it held 256 names of 96 bytes before.
    try testing.expect(@sizeOf(io_mod.Iterator) < 2 * 1024);
}

fn manyEntries(shape: test_disk.Shape) !void {
    const site = try Disk.make("io-many-site", test_disk.small, false);
    defer site.deinit();
    const volume = try Disk.make("io-many-volume", shape, false);
    defer volume.deinit();
    io_mod.mount(site.vol);
    io_mod.keepData(&data_dirs, volume.vol);
    defer {
        if (io_mod.siteVolume()) |v| site.vol = v.*;
        if (io_mod.dataVolume()) |v| volume.vol = v.*;
    }
    // 600 sessions: past the 256 the iterator stopped the machine at, and
    // past the 500 a player may keep (angry-gopher's game_limits.zig).
    var path: [80]u8 = undefined;
    for (1..601) |n| {
        const p = try std.fmt.bufPrint(&path, "data/lynrummy/p1/puzzle/sessions/{d}", .{n});
        try cwd.createDirPath(io, p);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try listLikeStore(arena.allocator(), "data/lynrummy/p1/puzzle/sessions");
    try testing.expectEqual(@as(usize, 600), got.len);
    var seen: [601]bool = @splat(false);
    for (got) |e| {
        try testing.expectEqual(io_mod.Kind.directory, e.kind);
        const n = try std.fmt.parseInt(usize, e.name, 10);
        try testing.expect(!seen[n]);
        seen[n] = true;
    }
}

test "a folder of 600 sessions lists whole, on FAT16 and FAT32: the iterator stopped the machine at 257" {
    try manyEntries(test_disk.small);
    try manyEntries(test_disk.small32);
}

// ── the site's files, kept after their first read (QUEUE.md item 61) ─────────

test "a site file is read from the disk once, then from memory; a data file every time" {
    const t = try Two.make(true);
    defer t.deinit();
    try t.site.vol.writeFile("pages/home.txt", "the home page");
    t.resync(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cache = io_mod.siteCache();
    const hits = cache.hits;

    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "pages/home.txt", a, .unlimited));
    const after_first = t.site.blk.requests;
    // Again, and in another case, as FAT names match: no disk request at all.
    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "pages/home.txt", a, .unlimited));
    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "PAGES/Home.txt", a, .unlimited));
    try testing.expectEqual(after_first, t.site.blk.requests);
    try testing.expectEqual(hits + 2, cache.hits);
    // The limit still holds for a kept file.
    try testing.expectError(io_mod.Error.StreamTooLong, cwd.readFileAlloc(io, "pages/home.txt", a, .limited(4)));

    // A data file changes, so it is read every time.
    try cwd.writeFile(io, .{ .sub_path = "data/chat/x", .data = "one" });
    try testing.expectEqualStrings("one", try cwd.readFileAlloc(io, "data/chat/x", a, .unlimited));
    try cwd.writeFile(io, .{ .sub_path = "data/chat/x", .data = "two" });
    try testing.expectEqualStrings("two", try cwd.readFileAlloc(io, "data/chat/x", a, .unlimited));
    try testing.expectEqual(hits + 2, cache.hits);
}

test "the data on the boot disk is never kept, nor anything before the data is named" {
    // No volume: the data directories are on the site's own disk.
    const t = try Two.make(false);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try cwd.writeFile(io, .{ .sub_path = "data/n", .data = "1" });
    _ = try cwd.readFileAlloc(io, "data/n", a, .unlimited);
    try cwd.writeFile(io, .{ .sub_path = "data/n", .data = "2" });
    try testing.expectEqualStrings("2", try cwd.readFileAlloc(io, "data/n", a, .unlimited));

    // A machine that has not named its data (a probe) writes anywhere, so
    // keeps nothing.
    io_mod.keepData(&.{}, null);
    try cwd.writeFile(io, .{ .sub_path = "pages/p", .data = "a" });
    _ = try cwd.readFileAlloc(io, "pages/p", a, .unlimited);
    try cwd.writeFile(io, .{ .sub_path = "pages/p", .data = "b" });
    try testing.expectEqualStrings("b", try cwd.readFileAlloc(io, "pages/p", a, .unlimited));
    io_mod.keepData(&data_dirs, null);
}

test "a site file larger than the cache keeps is read from the disk each time, and still whole" {
    const t = try Two.make(true);
    defer t.deinit();
    const big = try testing.allocator.alloc(u8, io_mod.SiteCache.largest + 1);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = @truncate(i);
    try t.site.vol.writeFile("gallery/big.webp", big);
    t.resync(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u8, big, try cwd.readFileAlloc(io, "gallery/big.webp", a, .unlimited));
    const before = t.site.blk.requests;
    try testing.expectEqualSlices(u8, big, try cwd.readFileAlloc(io, "gallery/big.webp", a, .unlimited));
    try testing.expect(t.site.blk.requests > before);
}

// ── the page cache (QUEUE.md item 87) ───────────────────────────────────────

const PageCache = @import("page_cache.zig").PageCache;

/// What `path` holds on the data volume, read past io and its cache: its
/// bytes (in `buf`), or null when there is no file.
fn onDisk(path: []const u8, buf: []u8) !?[]const u8 {
    const v = io_mod.dataVolume().?;
    const e = v.open(path) catch return null;
    if (e.isDirectory()) return null;
    const n = try v.readFile(e, buf);
    return buf[0..n];
}

test "the page cache is the disk: every change interleaved with reads, under evictions and failed writes" {
    const t = try Two.make(true);
    defer t.deinit();
    // Writes fail part-way here, which leaves what a stop leaves (leaked
    // clusters, chains longer than their files): not a healthy volume.
    t.volume.label = "limit-page-cache";
    // Small, so files are pushed out and read back in all the time.
    const pc = try testing.allocator.create(PageCache);
    defer testing.allocator.destroy(pc);
    pc.* = PageCache.init(testing.allocator, 12 * PageCache.page, 5 * PageCache.page);
    io_mod.keepPages(pc);
    defer io_mod.keepPages(null);

    // Paths in a few directories, some spelled two ways, one a directory's
    // name too, so a tree removed takes files a rename moved into it.
    const paths = [_][]const u8{ "data/a", "data/b", "DATA/B", "data/c/x", "data/c/y", "data/C/Y", "data/c/d/z", "data/e" };
    const dirs = [_][]const u8{ "data/c", "data/c/d" };
    var prng = std.Random.DefaultPrng.init(87);
    const r = prng.random();
    var bytes: [30_000]u8 = undefined;
    var disk_buf: [200_000]u8 = undefined;
    var pos_buf: [200_000]u8 = undefined;
    var failed: u32 = 0;

    for (0..3000) |k| {
        const p = paths[r.uintLessThan(usize, paths.len)];
        const q = paths[r.uintLessThan(usize, paths.len)];
        const n = r.uintAtMost(usize, if (r.boolean()) 600 else bytes.len);
        for (bytes[0..n], 0..) |*b, i| b.* = @truncate(i *% 7 +% k);
        // One operation in eight has a disk request fail part-way.
        if (r.uintLessThan(u8, 8) == 0) {
            t.volume.blk.fault = .{ .at = t.volume.blk.requests + r.uintLessThan(u64, 40), .kind = .fails };
        }
        const ok = switch (r.uintLessThan(u8, 9)) {
            0, 1 => cwd.writeFile(io, .{ .sub_path = p, .data = bytes[0..n] }),
            2, 3 => append: {
                const f = cwd.createFile(io, p, .{ .truncate = false }) catch |e| break :append e;
                const st = f.stat(io) catch |e| break :append e;
                break :append f.writePositionalAll(io, bytes[0..@min(n, 3000)], st.size);
            },
            4 => over: {
                const f = cwd.createFile(io, p, .{ .truncate = false }) catch |e| break :over e;
                const st = f.stat(io) catch |e| break :over e;
                break :over f.writePositionalAll(io, bytes[0..@min(n, 50)], r.uintAtMost(u64, st.size));
            },
            // Across directories too: refused, and the cache must say so.
            5 => cwd.rename(p, cwd, q, io),
            6 => cwd.deleteFile(io, p),
            7 => cwd.deleteTree(io, dirs[r.uintLessThan(usize, dirs.len)]),
            else => cwd.createDirPath(io, dirs[r.uintLessThan(usize, dirs.len)]),
        };
        if (t.volume.blk.fault != null) {
            if (ok) |_| {} else |_| failed += 1;
            t.volume.blk.fault = null;
        }

        // Every path, through io (the cache first) and past it: the same.
        for (paths) |path| {
            const want = try onDisk(path, &disk_buf);
            const got = cwd.readFileAlloc(io, path, testing.allocator, .unlimited) catch |e| switch (e) {
                error.FileNotFound, error.IsDir => null,
                else => return e,
            };
            defer if (got) |g| testing.allocator.free(g);
            if ((want == null) != (got == null) or (want != null and !std.mem.eql(u8, want.?, got.?))) {
                std.debug.print("after operation {d}: {s} is {d} bytes on the disk, and io says {d}\n", .{ k, path, if (want) |w| w.len else 0, if (got) |g| g.len else 0 });
                return error.TestUnexpectedResult;
            }
            // A positional read from a random offset, as a Range request.
            if (want) |w| {
                const f = try cwd.openFile(io, path, .{});
                const off = r.uintAtMost(usize, w.len);
                const m = try f.readPositionalAll(io, pos_buf[0..r.uintAtMost(usize, 4000)], off);
                try testing.expectEqualSlices(u8, w[off..][0..m], pos_buf[0..m]);
            }
        }
    }
    // The cache was used, pushed out, and survived failures.
    try testing.expect(pc.hits > 1000);
    try testing.expect(pc.evicted > 50);
    try testing.expect(failed > 20);
    try testing.expect(pc.held <= pc.budget);
}

test "a picture read whole is kept; a range read keeps nothing; one past largest is never kept (QUEUE.md item 102)" {
    const t = try Two.make(true);
    defer t.deinit();
    const largest = 4 * PageCache.page;
    const pc = try testing.allocator.create(PageCache);
    defer testing.allocator.destroy(pc);
    pc.* = PageCache.init(testing.allocator, 64 * PageCache.page, largest);
    io_mod.keepPages(pc);
    defer io_mod.keepPages(null);

    // A picture the application wrote: a write never brings a file in, so it is
    // not kept yet (write-no-allocate, page_cache.zig).
    var pic: [2 * PageCache.page]u8 = undefined;
    for (&pic, 0..) |*b, i| b.* = @truncate(i *% 7 + 1);
    try cwd.writeFile(io, .{ .sub_path = "data/chat/pic", .data = &pic });
    try testing.expectEqual(@as(usize, 0), pc.count);

    // A plain GET reads it whole (offset 0, a buffer that holds all of it): now
    // it is kept, and the next read is a hit served from memory.
    var buf: [8 * PageCache.page]u8 = undefined;
    {
        const f = try cwd.openFile(io, "data/chat/pic", .{});
        const n = try f.readPositionalAll(io, &buf, 0);
        try testing.expectEqualSlices(u8, &pic, buf[0..n]);
    }
    try testing.expectEqual(@as(usize, 1), pc.count);
    const hits_before = pc.hits;
    {
        const f = try cwd.openFile(io, "data/chat/pic", .{});
        const n = try f.readPositionalAll(io, &buf, 0);
        try testing.expectEqualSlices(u8, &pic, buf[0..n]);
    }
    try testing.expectEqual(hits_before + 1, pc.hits);
    try testing.expectEqual(@as(usize, 1), pc.count);

    // A range read (offset past the start) of an uncached file keeps nothing:
    // a video seek is not a file worth holding whole.
    try cwd.writeFile(io, .{ .sub_path = "data/chat/clip", .data = &pic });
    {
        const f = try cwd.openFile(io, "data/chat/clip", .{});
        _ = try f.readPositionalAll(io, buf[0..PageCache.page], PageCache.page);
    }
    try testing.expect(pc.get("data/chat/clip") == null);
    try testing.expectEqual(@as(usize, 1), pc.count);

    // A picture past `largest`, read whole, is read from the disk every time —
    // never kept, so it cannot push the transcripts out.
    var big: [5 * PageCache.page]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 3 + 2);
    try testing.expect(big.len > largest);
    try cwd.writeFile(io, .{ .sub_path = "data/chat/huge", .data = &big });
    {
        const f = try cwd.openFile(io, "data/chat/huge", .{});
        const n = try f.readPositionalAll(io, &buf, 0);
        try testing.expectEqualSlices(u8, &big, buf[0..n]);
    }
    try testing.expect(pc.get("data/chat/huge") == null);
    try testing.expectEqual(@as(usize, 1), pc.count);
}

// ── the admin's lost password (QUEUE.md item 89) ────────────────────────────

const admin_reset = @import("admin_reset.zig");
const old_hash = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza";
const new_hash = "$2b$10$oxKybo3Oosmt0E6lXGVrnubZfb/VLlOFpGiHrMZAy0/KV3k.BbfMS";

fn adminVolume() !Two {
    const t = try Two.make(true);
    try cwd.writeFile(io, .{ .sub_path = "auth/1/name", .data = "Steve" });
    try cwd.writeFile(io, .{ .sub_path = "auth/1/password", .data = old_hash });
    return t;
}

fn expectRead(path: []const u8, want: []const u8) !void {
    const got = try cwd.readFileAlloc(io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a reset for the admin by name applies once: the new hash in, the old one kept aside, and a second boot changes nothing" {
    const t = try adminVolume();
    defer t.deinit();
    const r = admin_reset.parse("Steve " ++ new_hash).?;
    try testing.expectEqual(admin_reset.Outcome.applied, admin_reset.apply(testing.allocator, r));
    try expectRead("auth/1/password", new_hash);
    try expectRead("auth/1/password.before-reset", old_hash);
    try expectRead("auth/1/password-reset", new_hash);
    try t.volume.expectFile("auth/1/password", new_hash); // on the volume, not just in io's cache

    // The next boot, the line still in the image: nothing changes.
    try testing.expectEqual(admin_reset.Outcome.already, admin_reset.apply(testing.allocator, r));
    // And a password changed since is not put back.
    try cwd.writeFile(io, .{ .sub_path = "auth/1/password", .data = old_hash });
    try testing.expectEqual(admin_reset.Outcome.already, admin_reset.apply(testing.allocator, r));
    try expectRead("auth/1/password", old_hash);
}

test "a reset is refused for another name, and where uid 1 is no member; nothing is written" {
    {
        const t = try adminVolume();
        defer t.deinit();
        try testing.expectEqual(admin_reset.Outcome.other_name, admin_reset.apply(testing.allocator, admin_reset.parse("Mallory " ++ new_hash).?));
        try testing.expectEqual(admin_reset.Outcome.other_name, admin_reset.apply(testing.allocator, admin_reset.parse("steve " ++ new_hash).?));
        try expectRead("auth/1/password", old_hash);
        try testing.expectError(error.FileNotFound, cwd.statFile(io, "auth/1/password-reset", .{}));
    }
    {
        const t = try Two.make(true);
        defer t.deinit();
        try cwd.writeFile(io, .{ .sub_path = "auth/1/name", .data = "Steve" }); // a name, no password
        try testing.expectEqual(admin_reset.Outcome.no_admin, admin_reset.apply(testing.allocator, admin_reset.parse("Steve " ++ new_hash).?));
        try testing.expectError(error.FileNotFound, cwd.statFile(io, "auth/1/password", .{}));
    }
}

test "a reset that fails part-way is finished by the next boot, and the hash kept aside is still the one from before" {
    var stop: u64 = 0;
    var done = false;
    while (!done) : (stop += 1) {
        const t = try adminVolume();
        defer t.deinit();
        // A failure is what a stop leaves here: io holds nothing the disk does
        // not, and the next boot reads the disk.
        t.volume.label = "limit-admin-reset";
        const r = admin_reset.parse("Steve " ++ new_hash).?;
        t.volume.blk.fail_after_writes = t.volume.blk.writes + stop;
        const first = admin_reset.apply(testing.allocator, r);
        t.volume.blk.fail_after_writes = null;
        done = first == .applied;
        if (!done) try testing.expectEqual(admin_reset.Outcome.failed, first);
        // The next boot: the volume mounted afresh from the disk.
        try t.volume.mount(false);
        t.resync(true);
        const second = admin_reset.apply(testing.allocator, r);
        try testing.expect(second == .applied or second == .already);
        try expectRead("auth/1/password", new_hash);
        try expectRead("auth/1/password.before-reset", old_hash);
    }
    try testing.expect(stop > 3);
}

test "a disk that fails a read is not a file that is absent: createFile errors and leaves the file whole" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/log.md", .data = "every message so far" });
    t.volume.blk.fault = .{ .at = t.volume.blk.requests, .kind = .fails };
    try testing.expectError(error.ReadFailed, cwd.createFile(io, "data/chat/log.md", .{ .truncate = false }));
    t.volume.blk.fault = null;
    try t.volume.expectFile("data/chat/log.md", "every message so far");
    // statFile and readFileAlloc say the same: failed, not absent.
    t.volume.blk.fault = .{ .at = t.volume.blk.requests, .kind = .fails };
    try testing.expectError(error.ReadFailed, cwd.statFile(io, "data/chat/log.md", .{}));
    t.volume.blk.fault = null;
}

test "a read tried again (boot's read_tries) answers past one refusal, and is counted; tried once it fails" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/log.md", .data = "every message so far" });
    t.volume.blk.read_tries = 3;
    t.volume.blk.fault = .{ .at = t.volume.blk.requests, .kind = .fails };
    _ = try cwd.statFile(io, "data/chat/log.md", .{});
    try testing.expectEqual(@as(u64, 1), t.volume.blk.reads_retried);
    t.volume.blk.read_tries = 1;
    t.volume.blk.fault = .{ .at = t.volume.blk.requests, .kind = .fails };
    try testing.expectError(error.ReadFailed, cwd.statFile(io, "data/chat/log.md", .{}));
    t.volume.blk.fault = null;
}

test "readFileAlloc whose read fails gives back what it took: the caller is told ReadFailed and holds nothing to free (metal-vmm QUEUE 172)" {
    const t = try Two.make(true);
    defer t.deinit();
    const big = repeated("a file of more than one sector, ", 40);
    try cwd.writeFile(io, .{ .sub_path = "data/chat/big.md", .data = big });
    var n: u64 = 0;
    while (n < 12) : (n += 1) {
        t.volume.blk.fault = .{ .at = t.volume.blk.requests + n, .kind = .fails };
        // testing.allocator: a buffer kept past the failure is a leak it names.
        if (cwd.readFileAlloc(io, "data/chat/big.md", testing.allocator, .limited(4096))) |got| {
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(big, got);
        } else |e| try testing.expectEqual(error.ReadFailed, e);
        t.volume.blk.fault = null;
    }
}

test "a read that fails while a missing path is probed is ReadFailed, never 'not there' (metal-vmm QUEUE 172)" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/a.md", .data = "here" });
    var n: u64 = 0;
    while (n < 16) : (n += 1) {
        const at = t.volume.blk.requests + n;
        t.volume.blk.fault = .{ .at = at, .kind = .fails };
        const got = cwd.statFile(io, "data/chat/nothere/x.md", .{});
        const fired = t.volume.blk.requests > at;
        t.volume.blk.fault = null;
        if (got) |_| return error.TestUnexpectedResult else |e| {
            try testing.expectEqual(if (fired) error.ReadFailed else error.FileNotFound, e);
        }
    }
}

test "a volume whose FAT copies are unweighed refuses every write as a read-only filesystem, and reads go on (metal-vmm QUEUE 188.2)" {
    const t = try Two.make(true);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try cwd.createDirPath(io, "data/chat");
    try cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "saved" });
    // io holds its own copy of the volume (see `Two.deinit`): the flag goes on that one.
    const v = io_mod.dataVolume().?;
    v.writes = .refused;
    defer v.writes = .taken;
    const writes = t.volume.blk.writes;
    try testing.expectError(error.ReadOnlyFileSystem, cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "again" }));
    try testing.expectError(error.ReadOnlyFileSystem, cwd.createDirPath(io, "data/chat/new"));
    try testing.expectError(error.ReadOnlyFileSystem, cwd.deleteFile(io, "data/chat/plan.md"));
    try testing.expectEqual(writes, t.volume.blk.writes);
    try testing.expectEqualStrings("saved", try cwd.readFileAlloc(io, "data/chat/plan.md", arena.allocator(), .unlimited));
    // Weighed: writable again.
    v.writes = .taken;
    try cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "again" });
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
