//! **THE STORE, JUDGED: THE MODEL AGAINST FAT** (metal-vmm QUEUE item 77).
//!
//! - **Agreement.** A script of every operation, and then a few hundred
//!   chosen by a seed, each run on the model and on a FAT store; each answer
//!   (an error, or what was read) must match, and after each the two trees,
//!   every name, kind, size and byte, must be the same.
//! - **What a power cut leaves.** A file is written, then `replace`d with a
//!   power cut at every request it makes, and again with the request torn
//!   (half of a multi-sector write landing) as the power goes. After each,
//!   the volume is mounted again, as the next boot would: the file must be
//!   wholly old or wholly new, and new if `replace` answered. `write` may
//!   leave old, new or nothing; `append` old or new. Both are cut the same
//!   way, so what `store.zig` promises of each is checked, not believed.

const std = @import("std");
const store = @import("store.zig");
const Model = @import("store_model.zig").Model;
const FatStore = @import("store_fat.zig").FatStore;
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Error = store.Error;

/// A tree, as text: one line per name, sorted, with each file's bytes.
pub fn snapshot(s: store.Store, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try walk(s, gpa, "", &out);
    return out.toOwnedSlice(gpa);
}

const Named = struct { name: []u8, kind: store.Kind, size: u64 };

fn walk(s: store.Store, gpa: std.mem.Allocator, dir: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    const Collect = struct {
        gpa: std.mem.Allocator,
        items: std.ArrayListUnmanaged(Named) = .empty,
        fn each(c: *anyopaque, item: store.Item) void {
            const self: *@This() = @ptrCast(@alignCast(c));
            const name = self.gpa.dupe(u8, item.name) catch @panic("out of memory");
            self.items.append(self.gpa, .{ .name = name, .kind = item.kind, .size = item.size }) catch @panic("out of memory");
        }
        fn less(_: void, a: Named, b: Named) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };
    var c = Collect{ .gpa = gpa };
    defer {
        for (c.items.items) |i| gpa.free(i.name);
        c.items.deinit(gpa);
    }
    try s.list(dir, .{ .context = &c, .call = Collect.each });
    std.mem.sort(Named, c.items.items, {}, Collect.less);
    for (c.items.items) |i| {
        var pb: [512]u8 = undefined;
        const path = if (dir.len == 0) i.name else try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, i.name });
        try out.print(gpa, "{s} {s} {d}", .{ path, @tagName(i.kind), i.size });
        switch (i.kind) {
            .file => {
                const buf = try gpa.alloc(u8, i.size);
                defer gpa.free(buf);
                const n = try s.read(path, buf);
                try out.print(gpa, " {x}\n", .{std.hash.Wyhash.hash(0, buf[0..n])});
            },
            .directory => {
                try out.append(gpa, '\n');
                try walk(s, gpa, path, out);
            },
        }
    }
}

/// Two stores, and every operation run on both.
const Pair = struct {
    model: Model,
    disk: *test_disk.Disk,
    fat: FatStore,
    step: usize = 0,

    fn init(label: []const u8) !*Pair {
        const p = try testing.allocator.create(Pair);
        p.* = .{ .model = Model.init(testing.allocator), .disk = try test_disk.Disk.make(label, test_disk.small, false), .fat = undefined };
        p.fat = .{ .vol = &p.disk.vol };
        return p;
    }

    fn deinit(p: *Pair) void {
        p.model.deinit();
        p.disk.deinit();
        testing.allocator.destroy(p);
    }

    const Op = union(enum) {
        read: []const u8,
        write: struct { []const u8, []const u8 },
        append: struct { []const u8, []const u8 },
        remove: []const u8,
        replace: struct { []const u8, []const u8 },
        list: []const u8,
    };

    fn one(s: store.Store, op: Op, out: []u8) Error![]const u8 {
        switch (op) {
            .read => |path| return out[0..try s.read(path, out)],
            .write => |a| try s.write(a[0], a[1]),
            .append => |a| try s.append(a[0], a[1]),
            .remove => |path| try s.remove(path),
            .replace => |a| try s.replace(a[0], a[1]),
            .list => |path| {
                const Count = struct {
                    fn each(_: *anyopaque, _: store.Item) void {}
                };
                var dummy: u8 = 0;
                try s.list(path, .{ .context = &dummy, .call = Count.each });
            },
        }
        return "";
    }

    /// `op` on both: the same answer, and the same trees after.
    fn run(p: *Pair, op: Op) !void {
        p.step += 1;
        var ob: [4096]u8 = undefined;
        var fb: [4096]u8 = undefined;
        const want = one(p.model.store_(), op, &ob);
        const got = one(p.fat.store_(), op, &fb);
        if (want) |w| {
            const g = got catch |e| {
                std.debug.print("step {d}, {any}: the model answered, FAT {s}\n", .{ p.step, op, @errorName(e) });
                return error.Disagree;
            };
            if (!std.mem.eql(u8, w, g)) {
                std.debug.print("step {d}, {any}: the model read {d} bytes, FAT {d}\n", .{ p.step, op, w.len, g.len });
                return error.Disagree;
            }
        } else |we| {
            if (got) |_| {
                std.debug.print("step {d}, {any}: the model answered {s}, FAT did it\n", .{ p.step, op, @errorName(we) });
                return error.Disagree;
            } else |ge| if (ge != we) {
                std.debug.print("step {d}, {any}: the model answered {s}, FAT {s}\n", .{ p.step, op, @errorName(we), @errorName(ge) });
                return error.Disagree;
            }
        }
        try p.same();
    }

    fn same(p: *Pair) !void {
        const a = try snapshot(p.model.store_(), testing.allocator);
        defer testing.allocator.free(a);
        const b = try snapshot(p.fat.store_(), testing.allocator);
        defer testing.allocator.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("step {d}: the trees differ\nthe model:\n{s}FAT:\n{s}", .{ p.step, a, b });
            return error.Disagree;
        }
    }
};

test "the model and the FAT store agree on every operation, and every error" {
    const p = try Pair.init("store-agree");
    defer p.deinit();
    const script = [_]Pair.Op{
        .{ .list = "" },
        .{ .write = .{ "Data/Chat/topic.md", "hello" } },
        .{ .read = "data/chat/TOPIC.MD" },
        .{ .append = .{ "data/chat/topic.md", " world" } },
        .{ .append = .{ "data/chat/new.jsonl", "{}\n" } },
        .{ .append = .{ "data/chat/new.jsonl", "" } },
        .{ .replace = .{ "data/chat/topic.md", "replaced" } },
        .{ .replace = .{ "auth/7/session", "s" } },
        .{ .write = .{ "data/chat/empty", "" } },
        .{ .read = "data/chat/empty" },
        .{ .list = "data/chat" },
        .{ .list = "DATA" },
        .{ .read = "data/chat" },
        .{ .read = "data/none" },
        .{ .read = "data/chat/topic.md/under" },
        .{ .write = .{ "data/chat/topic.md/under", "x" } },
        .{ .append = .{ "data/chat/topic.md/under", "x" } },
        .{ .replace = .{ "data/chat/topic.md/under", "x" } },
        .{ .write = .{ "data/chat", "x" } },
        .{ .append = .{ "data", "x" } },
        .{ .replace = .{ "data/chat", "x" } },
        .{ .remove = "data/chat" },
        .{ .remove = "data/nothing" },
        .{ .remove = "data/chat/topic.md/under" },
        .{ .list = "data/chat/topic.md" },
        .{ .list = "data/nothing" },
        .{ .write = .{ "", "x" } },
        .{ .write = .{ "data/a:b", "x" } },
        .{ .write = .{ "data/.~mine", "x" } },
        .{ .read = "data/../data/chat/topic.md" },
        .{ .remove = "DATA/CHAT/TOPIC.MD" },
        .{ .list = "data/chat" },
        .{ .write = .{ "data/chat/Topic.md", "again, in another case" } },
    };
    for (script) |op| try p.run(op);
    var big: [5000]u8 = @splat('b');
    try p.run(.{ .write = .{ "data/big", &big } });
    try p.run(.{ .read = "data/big" }); // larger than the 4096 read into: TooBig on both
}

test "the model and the FAT store agree under a seed: a few hundred operations" {
    const paths = [_][]const u8{ "a", "data/x", "data/X", "data/chat/t.md", "data/chat/u", "auth/1/s", "data/chat", "data", "data/x/y" };
    for (1..6) |seed| {
        const p = try Pair.init("store-seeded");
        defer p.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var bytes: [3000]u8 = undefined;
        for (0..300) |_| {
            const path = paths[r.uintLessThan(usize, paths.len)];
            const n = if (r.boolean()) r.uintLessThan(usize, 100) else r.uintLessThan(usize, bytes.len);
            r.bytes(bytes[0..n]);
            const op: Pair.Op = switch (r.uintLessThan(u8, 6)) {
                0 => .{ .read = path },
                1 => .{ .write = .{ path, bytes[0..n] } },
                2 => .{ .append = .{ path, bytes[0..n] } },
                3 => .{ .remove = path },
                4 => .{ .replace = .{ path, bytes[0..n] } },
                else => .{ .list = path },
            };
            p.run(op) catch |e| {
                std.debug.print("seed {d}\n", .{seed});
                return e;
            };
        }
    }
}

const Promise = enum { old_or_new, old_new_or_neither };

/// `which` on a file holding `old`, with the power cut at the `j`th request
/// it makes (and that request torn, if `torn`), for every `j` until it
/// finishes uncut. After each, the next boot's mount must find what
/// `promise` allows, and the new file if the operation answered.
fn cutEverywhere(comptime which: enum { replace, write, append }, promise: Promise, torn: bool) !usize {
    const old = "the old file, " ** 120;
    const added = "and what was added to it. " ** 80;
    const new = if (which == .append) old ++ added else "the whole new file, " ** 150;
    var cuts: usize = 0;
    var j: u64 = 0;
    while (true) : (j += 1) {
        const d = try test_disk.Disk.make("damaged-store-cut", test_disk.small, false);
        defer d.deinit();
        var f = FatStore{ .vol = &d.vol };
        const s = f.store_();
        try s.write("data/chat/f.md", old);
        const base = d.blk.requests;
        d.blk.fail_after = base + j;
        if (torn) d.blk.fault = .{ .at = base + j -| 1, .kind = .torn };
        const answered = switch (which) {
            .replace => s.replace("data/chat/f.md", new),
            .write => s.write("data/chat/f.md", new),
            .append => s.append("data/chat/f.md", added),
        };
        const finished = d.blk.requests < base + j;
        d.blk.fail_after = null;
        d.blk.fault = null;
        try d.mount(false); // the next boot
        f = .{ .vol = &d.vol };
        var buf: [8192]u8 = undefined;
        const got: ?[]const u8 = if (f.store_().read("data/chat/f.md", &buf)) |n| buf[0..n] else |e| switch (e) {
            Error.NotFound => null,
            else => {
                std.debug.print("{s}, cut at request {d}{s}: the file reads as {s}\n", .{ @tagName(which), j, if (torn) ", torn" else "", @errorName(e) });
                return error.BrokenPromise;
            },
        };
        const is_old = got != null and std.mem.eql(u8, got.?, old);
        const is_new = got != null and std.mem.eql(u8, got.?, new);
        const allowed = is_old or is_new or (promise == .old_new_or_neither and got == null);
        const ok = if (answered) |_| true else |_| false;
        if (!allowed or (ok and !is_new)) {
            std.debug.print("{s}, cut at request {d}{s}: answered {any}, and the file is {s}\n", .{
                @tagName(which), j,                                                                                                if (torn) ", torn" else "",
                answered,        if (got == null) "gone" else if (is_old) "old" else if (is_new) "new" else "neither old nor new",
            });
            return error.BrokenPromise;
        }
        if (finished) break;
        cuts += 1;
    }
    return cuts;
}

test "replace: after a power cut at any request, the file is wholly old or wholly new" {
    const cuts = try cutEverywhere(.replace, .old_or_new, false);
    try testing.expect(cuts > 5);
}

test "replace: and the same with the last request torn as the power goes" {
    _ = try cutEverywhere(.replace, .old_or_new, true);
}

test "append: after a power cut at any request, the file is old or new" {
    _ = try cutEverywhere(.append, .old_or_new, false);
    _ = try cutEverywhere(.append, .old_or_new, true);
}

test "write: after a power cut, old, new, or nothing, as store.zig says" {
    _ = try cutEverywhere(.write, .old_new_or_neither, false);
    _ = try cutEverywhere(.write, .old_new_or_neither, true);
}

/// Whether a write waiting in the cache lands before the power goes, in
/// `replace`'s test below: only those to the root directory's sectors.
const RootOnly = struct {
    cache: *const test_disk.Cache,
    first: u64,
    end: u64,
    fn keep(s: RootOnly, i: usize) bool {
        const lba = s.cache.waiting.items[i].lba;
        return lba >= s.first and lba < s.end;
    }
};

test "replace: its flush puts the new bytes on the media before the name that points at them (metal-vmm QUEUE 112, S5)" {
    // A disk with a write cache, cut just after `replace` answers, whose
    // cache had written back only the root directory's sectors: a legal
    // order for a cache, and the worst one for a rename. With the flush,
    // the new file's clusters and its chain were durable before the rename
    // began, and `f.md` is wholly new. Without it they were still waiting,
    // and the entry the rename wrote points at a chain that never landed.
    const d = try test_disk.Disk.make("damaged-store-replace-cache", test_disk.small, false);
    defer d.deinit();
    const c = try test_disk.Cache.attach(d);
    defer c.detach(d);
    var f = FatStore{ .vol = &d.vol };
    const old = "the old file, " ** 120;
    const new = "the whole new file, " ** 150;
    try f.store_().write("f.md", old);
    try testing.expectEqual(@import("virtio_blk.zig").blk_s_ok, d.blk.flush());
    try f.store_().replace("f.md", new);
    try testing.expect(c.pending() > 0);
    const l = test_disk.Layout.of(d.bytes);
    const root = l.fat_start / test_disk.sector + 2 * l.fat_bytes / test_disk.sector;
    c.cut(d, RootOnly{ .cache = c, .first = root, .end = l.data_sector }, RootOnly.keep);
    try d.mount(false);
    f = .{ .vol = &d.vol };
    var buf: [8192]u8 = undefined;
    const n = try f.store_().read("f.md", &buf);
    try testing.expectEqualStrings(new, buf[0..n]);
}

test "replace: a rename that fails takes its hidden copy back, and every cluster it held (metal-vmm QUEUE 112, S6)" {
    // A root with room for the hidden copy's entries and none for a new
    // name: the copy is written, the rename refused, and the copy must go,
    // its clusters freed and its entries with it. Found by filling the
    // root, then freeing one entry at a time until a replace gets that far.
    var reached = false;
    var freed: usize = 1;
    while (freed <= 4) : (freed += 1) {
        const d = try test_disk.Disk.make("store-replace-full-root", test_disk.small, false);
        defer d.deinit();
        var f = FatStore{ .vol = &d.vol };
        const s = f.store_();
        var name: [8]u8 = undefined;
        var made: usize = 0;
        while (true) : (made += 1) {
            s.write(try std.fmt.bufPrint(&name, "F{d:0>4}", .{made}), "") catch |e| {
                try testing.expectEqual(Error.NoSpace, e);
                break;
            };
        }
        for (0..freed) |k| try s.remove(try std.fmt.bufPrint(&name, "F{d:0>4}", .{made - 1 - k}));
        const free = d.free();
        const writes = d.blk.writes;
        const answered = s.replace("new.md", "the new file's bytes, " ** 100);
        if (answered) |_| break else |e| try testing.expectEqual(Error.NoSpace, e);
        // The copy was written (it took clusters), so the refusal came from
        // the rename.
        if (d.blk.writes - writes > 2) reached = true;
        try testing.expectEqual(free, d.free());
        try d.expectKept();
        try testing.expectError(error.NotFound, d.vol.open(".~new.md"));
    }
    try testing.expect(reached);
}

test "a write under a file is a bad name, on FAT as in the model; a read or a remove there finds nothing (MUTATION.md S11, equivalent)" {
    const d = try test_disk.Disk.make("store-under-a-file", test_disk.small, false);
    defer d.deinit();
    var f = FatStore{ .vol = &d.vol };
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var buf: [16]u8 = undefined;
    for ([_]store.Store{ m.store_(), f.store_() }) |s| {
        try s.write("data/a", "a file");
        // FAT meets `a` where a write would make a directory, and answers
        // `BadName` itself (`makeDirIn`): so `map`'s `NotFat16` for a write
        // is never reached, and MUTATION.md's S11 is equivalent in effect.
        // This pins the answer either way.
        try testing.expectError(Error.BadName, s.write("data/a/b", "x"));
        try testing.expectError(Error.BadName, s.append("data/a/b", "x"));
        try testing.expectError(Error.BadName, s.replace("data/a/b", "x"));
        try testing.expectError(Error.NotFound, s.read("data/a/b", &buf));
        try testing.expectError(Error.NotFound, s.remove("data/a/b"));
        const n = try s.read("data/a", &buf);
        try testing.expectEqualStrings("a file", buf[0..n]);
    }
}

test "the deepest, longest path a Store takes works on FAT as in the model; one part more, or one byte more, is a bad name on both" {
    const d = try test_disk.Disk.make("store-edge-path", test_disk.small, false);
    defer d.deinit();
    var f = FatStore{ .vol = &d.vol };
    var m = Model.init(testing.allocator);
    defer m.deinit();
    const part = "p" ** store.max_part;
    // max_parts parts of max_part bytes: replace's hidden name on the last
    // is temp_prefix longer, within disk_fat's max_name.
    const deepest = (part ++ "/") ** (store.max_parts - 1) ++ part;
    const too_deep = deepest ++ "/x";
    const too_long = (part ++ "/") ** (store.max_parts - 1) ++ part ++ "p";
    var buf: [32]u8 = undefined;
    for ([_]store.Store{ m.store_(), f.store_() }) |s| {
        try s.write(deepest, "written");
        try s.replace(deepest, "replaced");
        try s.append(deepest, "+");
        const n = try s.read(deepest, &buf);
        try testing.expectEqualStrings("replaced+", buf[0..n]);
        try testing.expectError(Error.BadName, s.write(too_deep, "x"));
        try testing.expectError(Error.BadName, s.replace(too_long, "x"));
        try testing.expectError(Error.BadName, s.read(too_long, &buf));
        try s.remove(deepest);
        try testing.expectError(Error.NotFound, s.read(deepest, &buf));
    }
}

test "a volume refusing writes is the Store's Io on every write, never Damaged, and reads go on (metal-vmm QUEUE 188.2)" {
    const d = try test_disk.Disk.make("store-refused", test_disk.small, false);
    defer d.deinit();
    var f = FatStore{ .vol = &d.vol };
    const s = f.store_();
    try s.write("data/a", "a file");
    d.vol.writes = .refused;
    try testing.expectError(Error.Io, s.write("data/b", "x"));
    try testing.expectError(Error.Io, s.append("data/a", "x"));
    try testing.expectError(Error.Io, s.replace("data/a", "x"));
    try testing.expectError(Error.Io, s.remove("data/a"));
    var buf: [16]u8 = undefined;
    const n = try s.read("data/a", &buf);
    try testing.expectEqualStrings("a file", buf[0..n]);
    d.vol.writes = .taken;
    try s.replace("data/a", "taken");
}
