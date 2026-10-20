//! **WHAT EACH STORE CALL COSTS THE DISK** (zig build store-cost; metal-vmm
//! QUEUE 151). Production's /admin/host: a chat send 222 ms, 218 of them 38
//! disk requests at ~5.8 ms each; `/chat/recent` 76. This drives angry-gopher's
//! own `store.zig` (the port's copy, as store-judge does) over this repo's
//! io.zig, onto a data volume set up as the droplet sets its own (FAT held,
//! 16,384 directory sectors held, a page cache), and counts every disk request
//! each call makes, by kind and by place: the boot sector and FSInfo, the FAT,
//! a directory's sectors, a file's data; and the flushes.
//!
//! Two tables: each store primitive alone, on a warm volume; then each of the
//! four operations QUEUE 151 names, as their store calls were traced from
//! angry-gopher's handlers (2026-10-10), cold (just mounted) and warm.
//!
//! **A BENCH, NOT A GATE**: it prints, and fails only if the stack does.
//! FAT32 here has 512-byte clusters (`test_disk.small32`), production's 32
//! KiB: a directory longer than a cluster takes more requests here, a file's
//! data the same for the small files these operations write.
const std = @import("std");
const world = @import("judge_world");
const store = @import("ag_store_metal");
const testing = std.testing;
const io_mod = world.io;
const test_disk = world.test_disk;
const disk_fat = world.disk_fat;

const mio: io_mod = .{};

/// One kind of request, by direction and place.
const Place = enum { boot, fat, dir, data };
const Tally = struct {
    reads: [4]u32 = .{ 0, 0, 0, 0 },
    writes: [4]u32 = .{ 0, 0, 0, 0 },
    flushes: u64 = 0,

    fn total(t: Tally) u32 {
        var n: u32 = 0;
        for (t.reads) |r| n += r;
        for (t.writes) |w| n += w;
        return n;
    }
};

/// What a disk was asked, kept until the call ends and then sorted into
/// places: a sector is a directory's if the directory cache holds it after
/// the call (it holds every directory sector read or written).
const Seen = struct {
    write: bool,
    lba: u64,
    sectors: u32,
};

const Bench = struct {
    site: *test_disk.Disk,
    data: *test_disk.Disk,
    dir_keys: []u32,
    dir_data: []u8,
    pc: world.page_cache.PageCache,
    seen: std.ArrayList(Seen) = .empty,
    arena: std.heap.ArenaAllocator,

    fn observe(context: *anyopaque, write: bool, lba: u64, sectors: u32) void {
        const b: *Bench = @ptrCast(@alignCast(context));
        b.seen.append(testing.allocator, .{ .write = write, .lba = lba, .sectors = sectors }) catch {};
    }

    fn make() !*Bench {
        const b = try testing.allocator.create(Bench);
        b.* = .{
            .site = try test_disk.Disk.make("store-cost-site", test_disk.small, false),
            .data = try test_disk.Disk.make("store-cost-data", test_disk.small32, true),
            .dir_keys = try testing.allocator.alloc(u32, 16384),
            .dir_data = try testing.allocator.alloc(u8, 16384 * disk_fat.sector_size),
            .pc = world.page_cache.PageCache.init(testing.allocator, 64 << 20, 512 << 10),
            .arena = .init(testing.allocator),
        };
        try b.mount();
        return b;
    }

    /// Mounted as the droplet mounts its data volume: FAT held (the disk
    /// was made cached), directories held in production's 16,384 slots.
    fn mount(b: *Bench) !void {
        if (io_mod.dataVolume()) |v| b.data.vol = v.*;
        try b.data.mount(true);
        b.data.vol.cacheDirs(b.dir_keys, b.dir_data);
        io_mod.mount(b.site.vol);
        io_mod.keepData(&.{ "data", "auth" }, b.data.vol);
        io_mod.keepPages(&b.pc);
        store.setBases("data", "auth");
        b.data.blk.observe = .{ .context = b, .each = observe };
    }

    fn deinit(b: *Bench) void {
        io_mod.keepPages(null);
        if (io_mod.siteVolume()) |v| b.site.vol = v.*;
        if (io_mod.dataVolume()) |v| b.data.vol = v.*;
        b.data.blk.observe = null;
        b.site.deinit();
        b.data.deinit();
        b.pc.clear();
        testing.allocator.free(b.dir_keys);
        testing.allocator.free(b.dir_data);
        b.seen.deinit(testing.allocator);
        b.arena.deinit();
        testing.allocator.destroy(b);
    }

    fn vol(_: *Bench) *disk_fat.Volume {
        return io_mod.dataVolume().?;
    }

    fn placeOf(b: *Bench, device_lba: u64) Place {
        var lba = device_lba;
        const v = b.vol();
        // The volume's own sector numbers, from its partition's start.
        if (lba < v.start_lba) return .boot;
        lba -= v.start_lba;
        if (lba < v.fat_start) return .boot;
        if (lba < v.fat_start + @as(u64, v.num_fats) * v.sectors_per_fat) return .fat;
        if (v.dirs) |c| {
            // As DirCache.slot finds it.
            const l: u32 = @intCast(lba);
            const i = @as(usize, (l *% 2654435761) >> 7) % c.keys.len;
            if (c.keys[i] == l +% 1) return .dir;
        }
        return .data;
    }

    /// The disk requests `f` makes, by kind and place.
    fn cost(b: *Bench, f: anytype) !Tally {
        b.seen.clearRetainingCapacity();
        const flushes = b.data.blk.flushes;
        try f.run(b);
        io_mod.durable(); // the response's flush, as every answer ends
        var t: Tally = .{ .flushes = b.data.blk.flushes - flushes };
        for (b.seen.items) |s| {
            const p = @backingInt(b.placeOf(s.lba));
            if (s.write) t.writes[p] += 1 else t.reads[p] += 1;
        }
        _ = b.arena.reset(.retain_capacity);
        return t;
    }

    fn a(b: *Bench) std.mem.Allocator {
        return b.arena.allocator();
    }
};

fn row(name: []const u8, t: Tally) void {
    std.debug.print("  {s:<44} {d:>4} | reads boot {d} fat {d} dir {d} data {d} | writes boot {d} fat {d} dir {d} data {d} | flushes {d}\n", .{
        name,        t.total(),   t.reads[0],  t.reads[1],  t.reads[2], t.reads[3],
        t.writes[0], t.writes[1], t.writes[2], t.writes[3], t.flushes,
    });
}

const lim: io_mod.Limit = .limited(1 << 20);
const secret = "auth/_session_secret";

/// The volume a chat send, a login, Recent and a game move find: two
/// members with a DM of 20 messages, eight more accounts, three channels.
fn seed(b: *Bench) !void {
    const x = b.a();
    try store.write(mio, x, secret, "s3cret", .{});
    var id: u32 = 1;
    while (id <= 10) : (id += 1) {
        try store.write(mio, x, try std.fmt.allocPrint(x, "auth/{d}/password", .{id}), "hash", .{});
        try store.replace(mio, x, try std.fmt.allocPrint(x, "auth/{d}/name", .{id}), try std.fmt.allocPrint(x, "Person {d}", .{id}), .{});
        try store.write(mio, x, try std.fmt.allocPrint(x, "data/users/{d}/last-seen", .{id}), "1789732801", .{});
        try store.replace(mio, x, try std.fmt.allocPrint(x, "data/players/{d}/name", .{id}), try std.fmt.allocPrint(x, "Person {d}", .{id}), .{});
        try store.write(mio, x, try std.fmt.allocPrint(x, "data/players/{d}/last-seen", .{id}), "1789732801", .{});
    }
    var m: u32 = 0;
    while (m < 20) : (m += 1) _ = try store.append(mio, x, "data/chat/1_2/sessions/1.md", "**Person 1** said: a message of some ordinary length, as people write them\n\n");
    try store.replace(mio, x, "data/chat/1_2/sessions/1.count", "20 1520\n1444 1", .{});
    try store.write(mio, x, "data/chat/1_2/sessions/1.lastauthor", "1", .{});
    try store.write(mio, x, "data/chat/users/1/last-sessions/1_2", "1", .{});
    try store.write(mio, x, "data/chat/users/1/last-conv", "1_2", .{});
    for ([_][]const u8{ "general", "uploads", "ds" }) |ch| {
        try store.replace(mio, x, try std.fmt.allocPrint(x, "data/chat/channels/{s}.channel", .{ch}), "1\n2\n", .{});
        _ = try store.append(mio, x, try std.fmt.allocPrint(x, "data/chat/channels/{s}/sessions/1.md", .{ch}), "**Person 2** said: hello\n\n");
        try store.replace(mio, x, try std.fmt.allocPrint(x, "data/chat/channels/{s}/sessions/1.count", .{ch}), "1 26\n0 2", .{});
    }
    _ = try store.append(mio, x, "data/lynrummy/1/lynrummy-elm/sessions/1/actions.dsl", "start\n");
    io_mod.durable();
}

// ---- the primitives, one at a time ------------------------------------

const Prim = struct {
    name: []const u8,
    run: *const fn (b: *Bench) anyerror!void,
};

const prims = [_]Prim{
    .{ .name = "read a file (kept by the page cache)", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.read(mio, b.a(), "auth/1/name", lim);
        }
    }.f },
    .{ .name = "readOrNull a missing file", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.readOrNull(mio, b.a(), "auth/1/nothing-here", lim);
        }
    }.f },
    .{ .name = "has a file", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.has(mio, b.a(), "auth/1/password");
        }
    }.f },
    .{ .name = "stat a file", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.stat(mio, b.a(), "data/chat/1_2/sessions/1.md");
        }
    }.f },
    .{ .name = "list a folder (auth/, 11 entries)", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.list(mio, b.a(), "auth");
        }
    }.f },
    .{ .name = "write over a small file", .run = struct {
        fn f(b: *Bench) !void {
            try store.write(mio, b.a(), "data/users/1/last-seen", "1789732899", .{});
        }
    }.f },
    .{ .name = "write a new small file", .run = struct {
        var n: u32 = 0;
        fn f(b: *Bench) !void {
            n += 1;
            try store.write(mio, b.a(), try std.fmt.allocPrint(b.a(), "data/users/1/new-{d}", .{n}), "x", .{});
        }
    }.f },
    .{ .name = "append to a transcript (inside its cluster)", .run = struct {
        fn f(b: *Bench) !void {
            _ = try store.append(mio, b.a(), "data/chat/1_2/sessions/1.md", "**Person 1** said: one more\n\n");
        }
    }.f },
    .{ .name = "replace a small file", .run = struct {
        fn f(b: *Bench) !void {
            try store.replace(mio, b.a(), "data/chat/1_2/sessions/1.count", "21 1550\n1520 1", .{});
        }
    }.f },
    .{ .name = "makeDir a folder that is there", .run = struct {
        fn f(b: *Bench) !void {
            try store.makeDir(mio, b.a(), "data/chat/users/1/last-sessions");
        }
    }.f },
};

// ---- the four operations, as traced ------------------------------------

/// A DM send (chat.zig, chat_store.zig, chat_state.zig, users.zig).
fn send(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.has(mio, x, "auth/1/password");
    _ = try store.has(mio, x, "auth/1/password");
    _ = try store.statOrNull(mio, x, "auth/2");
    _ = try store.readOrNull(mio, x, "auth/2/name", lim);
    _ = try store.readOrNull(mio, x, "auth/1/name", lim);
    _ = try store.stat(mio, x, "data/chat/1_2/sessions/1.md");
    _ = try store.read(mio, x, "data/chat/1_2/sessions/1.count", lim);
    _ = try store.append(mio, x, "data/chat/1_2/sessions/1.md", "**Person 1** said: a message of some ordinary length\n\n");
    try store.replace(mio, x, "data/chat/1_2/sessions/1.count", "21 1574\n1520 1", .{});
    try store.write(mio, x, "data/chat/1_2/sessions/1.lastauthor", "1", .{});
    _ = try store.readOrNull(mio, x, "auth/1/name", lim);
    _ = try store.readOrNull(mio, x, "auth/2/name", lim);
    try store.write(mio, x, "data/users/1/last-seen", "1789732900", .{});
    try store.makeDir(mio, x, "data/chat/users/1/last-sessions");
    try store.write(mio, x, "data/chat/users/1/last-sessions/1_2", "1", .{});
    try store.write(mio, x, "data/chat/users/1/last-conv", "1_2", .{});
}

/// Where the last message begins, from a `.count`'s second line, as
/// chat_store.zig's `lastMessage` reads it.
fn lastOffset(count: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, count, '\n');
    _ = lines.next();
    var it = std.mem.tokenizeScalar(u8, lines.next() orelse return 0, ' ');
    return std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch 0;
}

/// GET /chat/recent for member 1 (recent.zig, chat_store.zig, users.zig).
fn recent(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.has(mio, x, "auth/1/password");
    _ = try store.has(mio, x, "auth/1/password");
    _ = try store.read(mio, x, "auth/1/name", lim);
    for (try store.list(mio, x, "auth")) |e| {
        if (e.kind != .directory) continue;
        const p = try std.fmt.allocPrint(x, "auth/{s}", .{e.name});
        if (try store.has(mio, x, try std.fmt.allocPrint(x, "{s}/password", .{p}))) _ = try store.read(mio, x, try std.fmt.allocPrint(x, "{s}/name", .{p}), lim);
    }
    // Every other member's DM folder, there or not.
    var other: u32 = 2;
    while (other <= 10) : (other += 1) {
        const dir = try std.fmt.allocPrint(x, "data/chat/1_{d}/sessions", .{other});
        const items = store.list(mio, x, dir) catch continue;
        for (items) |s| {
            if (!std.mem.endsWith(u8, s.name, ".md")) continue;
            const stem = s.name[0 .. s.name.len - 3];
            const count = try store.read(mio, x, try std.fmt.allocPrint(x, "{s}/{s}.count", .{ dir, stem }), lim);
            var tail: [64 << 10]u8 = undefined;
            _ = try store.readAt(mio, x, try std.fmt.allocPrint(x, "{s}/{s}.md", .{ dir, stem }), lastOffset(count), &tail);
            _ = try store.read(mio, x, "auth/2/name", lim);
        }
    }
    for (try store.list(mio, x, "data/chat/channels")) |e| {
        if (!std.mem.endsWith(u8, e.name, ".channel")) continue;
        _ = try store.read(mio, x, try std.fmt.allocPrint(x, "data/chat/channels/{s}", .{e.name}), lim);
        const ch = e.name[0 .. e.name.len - ".channel".len];
        const dir = try std.fmt.allocPrint(x, "data/chat/channels/{s}/sessions", .{ch});
        for (try store.list(mio, x, dir)) |s| {
            if (!std.mem.endsWith(u8, s.name, ".md")) continue;
            const stem = s.name[0 .. s.name.len - 3];
            const count = try store.read(mio, x, try std.fmt.allocPrint(x, "{s}/{s}.count", .{ dir, stem }), lim);
            var tail: [64 << 10]u8 = undefined;
            _ = try store.readAt(mio, x, try std.fmt.allocPrint(x, "{s}/{s}.md", .{ dir, stem }), lastOffset(count), &tail);
            _ = try store.read(mio, x, "auth/2/name", lim);
        }
    }
    _ = store.list(mio, x, "data/chat/users/1/docs") catch {};
}

/// POST /login/full for member 5 (login.zig, users.zig, uid_cookie.zig,
/// player.zig): the member is found by name twice, as login.zig does.
fn login(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    for (0..2) |_| {
        for (try store.list(mio, x, "auth")) |e| {
            if (e.kind != .directory) continue;
            const p = try std.fmt.allocPrint(x, "auth/{s}", .{e.name});
            if (!try store.has(mio, x, try std.fmt.allocPrint(x, "{s}/password", .{p}))) continue;
            const name = try store.read(mio, x, try std.fmt.allocPrint(x, "{s}/name", .{p}), lim);
            if (std.mem.eql(u8, name, "Person 5")) break;
        }
    }
    _ = try store.readOrNull(mio, x, "auth/5/password", lim);
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.readOrNull(mio, x, secret, lim);
    try store.write(mio, x, "data/players/5/signed", "", .{});
    try store.write(mio, x, "data/users/5/last-seen", "1789732901", .{});
    _ = try store.read(mio, x, "auth/5/name", lim);
    try store.replace(mio, x, "data/players/5/name", "Person 5", .{});
}

/// POST /game/sessions/1/actions for player 1 (game.zig, storage.zig,
/// player.zig), its limits already measured.
fn move(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.readOrNull(mio, x, "data/players/1/name", lim);
    _ = try store.statOrNull(mio, x, "data/lynrummy/1/lynrummy-elm/sessions/1");
    _ = try store.append(mio, x, "data/lynrummy/1/lynrummy-elm/sessions/1/actions.dsl", "move a b\n");
    try store.write(mio, x, "data/players/1/last-seen", "1789732902", .{});
}

/// **THE SEND AFTER 153** (angry-gopher 825c4da, d95dec2): no `.lastauthor`
/// (the `.count` carries the author), the count by `write` not `replace`, no
/// last-seen (153(2)), and the last session and conversation written only
/// when they change (here they do not: two reads, from memory warm).
fn sendCut(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.has(mio, x, "auth/1/password");
    _ = try store.statOrNull(mio, x, "auth/2");
    _ = try store.readOrNull(mio, x, "auth/2/name", lim);
    _ = try store.readOrNull(mio, x, "auth/1/name", lim);
    _ = try store.stat(mio, x, "data/chat/1_2/sessions/1.md");
    _ = try store.read(mio, x, "data/chat/1_2/sessions/1.count", lim);
    _ = try store.append(mio, x, "data/chat/1_2/sessions/1.md", "**Person 1** said: a message of some ordinary length\n\n");
    try store.write(mio, x, "data/chat/1_2/sessions/1.count", "21 1574\n1520 1\n", .{});
    _ = try store.read(mio, x, "data/chat/users/1/last-sessions/1_2", lim);
    _ = try store.read(mio, x, "data/chat/users/1/last-conv", lim);
}

/// **THE LOGIN AFTER 153**: no last-seen, and the player's name read and
/// left, unchanged (153(3), angry-gopher 0f9c858).
fn loginCut(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    for (0..2) |_| {
        for (try store.list(mio, x, "auth")) |e| {
            if (e.kind != .directory) continue;
            const p = try std.fmt.allocPrint(x, "auth/{s}", .{e.name});
            if (!try store.has(mio, x, try std.fmt.allocPrint(x, "{s}/password", .{p}))) continue;
            const name = try store.read(mio, x, try std.fmt.allocPrint(x, "{s}/name", .{p}), lim);
            if (std.mem.eql(u8, name, "Person 5")) break;
        }
    }
    _ = try store.readOrNull(mio, x, "auth/5/password", lim);
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.readOrNull(mio, x, secret, lim);
    try store.write(mio, x, "data/players/5/signed", "", .{});
    _ = try store.read(mio, x, "auth/5/name", lim);
    _ = try store.readOrNull(mio, x, "data/players/5/name", lim);
}

/// **THE MOVE AFTER 153**: no last-seen.
fn moveCut(b: *Bench) !void {
    const x = b.a();
    _ = try store.readOrNull(mio, x, secret, lim);
    _ = try store.readOrNull(mio, x, "data/players/1/name", lim);
    _ = try store.statOrNull(mio, x, "data/lynrummy/1/lynrummy-elm/sessions/1");
    _ = try store.append(mio, x, "data/lynrummy/1/lynrummy-elm/sessions/1/actions.dsl", "move a b\n");
}

/// **SEARCH'S BOOT BUILD** (metal-vmm 155(b)), as angry-gopher's
/// `search_index.buildAll` reads: every conversation listed, every
/// transcript read whole (`chat_store.rawSession`).
fn indexBuild(b: *Bench) !void {
    const x = b.a();
    var dirs: std.ArrayList([]const u8) = .empty;
    for (try store.list(mio, x, "data/chat")) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, "users")) continue;
        if (std.mem.eql(u8, e.name, "channels")) {
            for (try store.list(mio, x, "data/chat/channels")) |ch| {
                if (ch.kind == .directory) try dirs.append(x, try std.fmt.allocPrint(x, "data/chat/channels/{s}", .{ch.name}));
            }
            continue;
        }
        try dirs.append(x, try std.fmt.allocPrint(x, "data/chat/{s}", .{e.name}));
    }
    for (dirs.items) |dir| {
        const sessions = try std.fmt.allocPrint(x, "{s}/sessions", .{dir});
        for (store.list(mio, x, sessions) catch continue) |s| {
            if (s.kind == .directory or !std.mem.endsWith(u8, s.name, ".md")) continue;
            _ = try store.readOrNull(mio, x, try std.fmt.allocPrint(x, "{s}/{s}", .{ sessions, s.name }), .unlimited);
        }
    }
}

const Op = struct { name: []const u8, run: *const fn (b: *Bench) anyerror!void };
const ops = [_]Op{
    .{ .name = "a chat send (a DM)", .run = send },
    .{ .name = "GET /chat/recent", .run = recent },
    .{ .name = "a login", .run = login },
    .{ .name = "a game move", .run = move },
    .{ .name = "a send, after 153", .run = sendCut },
    .{ .name = "a login, after 153", .run = loginCut },
    .{ .name = "a game move, after 153", .run = moveCut },
};

fn Runner(comptime f: *const fn (b: *Bench) anyerror!void) type {
    return struct {
        fn run(_: @This(), b: *Bench) !void {
            return f(b);
        }
    };
}

test "what each store call and each common request costs the disk (metal-vmm 151)" {
    const b = try Bench.make();
    defer b.deinit();
    try seed(b);

    std.debug.print("\nstore-cost: disk requests on the data volume (FAT held, 16,384 directory sectors held, page cache on)\n", .{});
    std.debug.print("each store primitive, warm:\n", .{});
    inline for (prims) |p| {
        _ = try b.cost(Runner(p.run){}); // warm what it touches
        row(p.name, try b.cost(Runner(p.run){}));
    }

    std.debug.print("each request, as traced from angry-gopher's handlers:\n", .{});
    inline for (ops) |o| {
        try b.mount(); // cold: just mounted, nothing held
        const cold = try b.cost(Runner(o.run){});
        const warm = try b.cost(Runner(o.run){});
        row(o.name ++ ", cold", cold);
        row(o.name ++ ", warm", warm);
    }

    // **AFTER 155** (153(7), measured as QUEUE 153 asks): the boot's index
    // build reads every transcript whole, which the page cache keeps; then
    // the first Recent.
    try b.mount();
    row("search's boot build, every transcript", try b.cost(Runner(indexBuild){}));
    row("GET /chat/recent, first after it", try b.cost(Runner(recent){}));
    // Warm: 2 without the build (its tails, never read whole), 0 with.
    row("GET /chat/recent, warm after it", try b.cost(Runner(recent){}));
}
