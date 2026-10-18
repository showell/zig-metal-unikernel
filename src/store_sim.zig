//! **THE THREE STORES, UNDER A SEED** (metal-vmm QUEUE item 79): the model
//! (`store_model.zig`), the FAT store (`store_fat.zig`, on a disk in memory)
//! and the strict Linux store (`store_linux.zig`, in a temporary directory),
//! given the same operations, chosen by a seed from a pool of paths that
//! differ in case, nest under each other, and break the name rules.
//!
//! **THE ORACLES**, after every operation:
//!
//! - **One answer.** All three answer it alike: the same error, or the same
//!   bytes read. So FAT and Linux refuse the same names for the same reason,
//!   and both refuse what the model refuses.
//! - **One tree.** Every name, kind, size and byte the three hold is the
//!   same (`store_test.snapshot`).
//! - **What a cut leaves.** Some operations on the FAT store have the power
//!   cut part-way, at a request the seed picks. The volume is mounted again
//!   as the next boot would, and the file the operation was on must be what
//!   `store.zig` promises: `replace` wholly old or wholly new, `append` old
//!   or new, `write` old, new or gone, `remove` there or gone. Then the
//!   model and the Linux store are made what FAT holds, and the run goes on.
//! - **What a full volume leaves** (metal-vmm item 83). One seed in four,
//!   chosen by a second generator so the others run as they did, has a
//!   volume of about 2 MiB and files of up to 600 KB, so FAT runs out of room
//!   where the model and the Linux store do not. When FAT answers `NoSpace`,
//!   the file must be what the operation's promise allows without the room
//!   to finish: `replace` wholly old, `append` old, `write` old or gone
//!   (FAT removes the old file before it writes the new). Then the model
//!   and the Linux store are made what FAT holds, as after a cut.

const std = @import("std");
const ev = @import("sim_events.zig");
const store = @import("store.zig");
const explore = @import("explore");
const Model = @import("store_model.zig").Model;
const FatStore = @import("store_fat.zig").FatStore;
const LinuxStore = @import("store_linux.zig").LinuxStore;
const ScratchDir = @import("scratch_dir.zig").ScratchDir;
const test_disk = @import("test_disk.zig");
const snapshot = @import("store_test.zig").snapshot;
const props = @import("coverage");
const Error = store.Error;

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const paths = [_][]const u8{
    "a",                  "A",                  "data/x.md",         "DATA/X.MD",
    "data/chat/topic.md", "data/Chat/Topic.md", "data/chat/u.jsonl", "data/chat",
    "data",               "auth/7/session",     "data/x.md/under",   "data//chat/",
    "data/a:b",           "data/what?",         "data/trailing.",    "data/.~hidden",
    "data/../a",          "",                   "a/b/c/d/e/f/g/h/i", "data/" ++ "n" ** 81,
};

/// The pool's other spellings of a name it also has: another case, or
/// empty parts.
fn isVariant(path: []const u8) bool {
    for ([_][]const u8{ "A", "DATA/X.MD", "data/Chat/Topic.md", "data//chat/" }) |v| {
        if (std.mem.eql(u8, path, v)) return true;
    }
    return false;
}

const Failure = error{SimulationFailed};

/// Failures not printed: for a test that expects some, whose output would
/// otherwise read as a failure of its own.
var quiet = false;

fn fail(seed: u64, comptime fmt: []const u8, args: anytype) Failure {
    if (!quiet) std.debug.print("store_sim seed {d}: " ++ fmt ++ "\n", .{seed} ++ args);
    return error.SimulationFailed;
}

const Op = enum { read, write, append, remove, replace, list };

/// One operation's answer, comparable across stores.
const Answer = struct {
    err: ?Error = null,
    bytes: []const u8 = "",

    fn eql(a: Answer, b: Answer) bool {
        if (a.err) |ae| {
            const be = b.err orelse return false;
            return ae == be;
        }
        if (b.err != null) return false;
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

fn noItem(_: *anyopaque, _: store.Item) void {}

fn run(s: store.Store, op: Op, path: []const u8, bytes: []const u8, out: []u8) Answer {
    const r: Error![]const u8 = switch (op) {
        .read => if (s.read(path, out)) |n| out[0..n] else |e| e,
        .write => if (s.write(path, bytes)) |_| "" else |e| e,
        .append => if (s.append(path, bytes)) |_| "" else |e| e,
        .remove => if (s.remove(path)) |_| "" else |e| e,
        .replace => if (s.replace(path, bytes)) |_| "" else |e| e,
        .list => blk: {
            var dummy: u8 = 0;
            break :blk if (s.list(path, .{ .context = &dummy, .call = noItem })) |_| "" else |e| e;
        },
    };
    return if (r) |b| .{ .bytes = b } else |e| .{ .err = e };
}

const World = struct {
    seed: u64,
    gpa: std.mem.Allocator,
    io: std.Io,
    model: Model,
    disk: *test_disk.Disk,
    fat: FatStore,
    tmp: ScratchDir,
    linux: LinuxStore,
    /// The disk's write cache, on a run that has one (`runSeedCached`): what
    /// a cut keeps of the writes since the last flush is the seed's choice.
    cache: ?*test_disk.Cache = null,
    /// Room to read any file the volume can hold (a seed's appends grow
    /// them): before a cut, what it should leave, after it, and a copy.
    big: [4][]u8,

    /// The disk flushed, as before a response.
    fn flush(w: *World, step: usize) !void {
        if (w.disk.blk.flush() != @import("virtio_blk.zig").blk_s_ok) return fail(w.seed, "step {d}: a flush failed with the power on", .{step});
        if (w.cache.?.pending() != 0) return fail(w.seed, "step {d}: a flush left writes waiting", .{step});
    }

    fn reset(w: *World) !void {
        w.model.deinit();
        w.model = Model.init(w.gpa);
        w.tmp.cleanup();
        w.tmp = try ScratchDir.make(w.io, .{ .iterate = true });
        w.linux = .{ .io = w.io, .root = w.tmp.dir };
    }

    /// The model and the Linux store, made what FAT holds: after a cut.
    fn copyFromFat(w: *World) !void {
        try w.reset();
        try copyDir(w, "");
    }

    fn copyDir(w: *World, dir: []const u8) !void {
        const Collect = struct {
            gpa: std.mem.Allocator,
            names: std.ArrayListUnmanaged(struct { name: []u8, kind: store.Kind }) = .empty,
            fn each(c: *anyopaque, item: store.Item) void {
                const self: *@This() = @ptrCast(@alignCast(c));
                const name = self.gpa.dupe(u8, item.name) catch @panic("out of memory");
                self.names.append(self.gpa, .{ .name = name, .kind = item.kind }) catch @panic("out of memory");
            }
        };
        var c = Collect{ .gpa = w.gpa };
        defer {
            for (c.names.items) |n| w.gpa.free(n.name);
            c.names.deinit(w.gpa);
        }
        try w.fat.store_().list(dir, .{ .context = &c, .call = Collect.each });
        for (c.names.items) |n| {
            var pb: [512]u8 = undefined;
            const path = if (dir.len == 0) n.name else try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, n.name });
            switch (n.kind) {
                .file => {
                    const buf = w.big[3];
                    const got = try w.fat.store_().read(path, buf);
                    try w.model.write(path, buf[0..got]);
                    try w.linux.store_().write(path, buf[0..got]);
                },
                .directory => {
                    // A directory is made by a write under it; an empty one
                    // is made by writing a file there and removing it.
                    var probe_buf: [600]u8 = undefined;
                    const probe = try std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ path, "probe" });
                    for ([_]store.Store{ w.model.store_(), w.linux.store_() }) |s| {
                        try s.write(probe, "");
                        try s.remove(probe);
                    }
                    try copyDir(w, path);
                },
            }
        }
    }
};

pub fn runSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed);
    var second = std.Random.DefaultPrng.init(seed ^ 0x6675_6c6c); // "full"
    return runFrom(std.testing.allocator, std.testing.io, seed, prng.random(), second.random(), false) catch |e| switch (e) {
        error.SimulationFailed => error.SimulationFailed,
        else => fail(seed, "{s}", .{@errorName(e)}),
    };
}

/// **ONE RUN UNDER A TAPE** (the seed explorer, zig-coverage-sdk's
/// explore.zig): every draw, the filling tier's too, comes from `tape`, so
/// all of it is recorded and can be steered. **A tape's seed is not a
/// `runSeed` seed**: the filling tier draws from the tape here and from a
/// stream of its own there, so a tape replays only as a tape.
pub fn runWith(tape: *explore.Tape) Failure!void {
    return runWithIn(std.testing.allocator, std.testing.io, tape);
}

/// `runWith`, with the allocator and the `Io` a program gives it (the
/// explorer's bench and soak, metal-vmm QUEUE 106): the same run.
pub fn runWithIn(gpa: std.mem.Allocator, io: std.Io, tape: *explore.Tape) Failure!void {
    const r = tape.random();
    return runFrom(gpa, io, tape.seed, r, r, false) catch |e| switch (e) {
        error.SimulationFailed => error.SimulationFailed,
        else => fail(tape.seed, "{s}", .{@errorName(e)}),
    };
}

/// A run whose draws come from `r`, and the filling tier's from `second`
/// (`runSeed` keeps them apart, as its seeds always have). The decisions
/// are named choices (explore.pick, .pickAs, .flag), each drawn exactly as
/// the call it replaced.
fn runFrom(gpa: std.mem.Allocator, io: std.Io, seed: u64, r: std.Random, second: std.Random, cached: bool) !void {
    const fat32 = explore.pick(r, "store_sim: the volume is FAT32", .{ .yes = 1, .no = 3 }) == .yes;
    const filling = explore.pick(second, "store_sim: the volume is tiny, and fills", .{ .yes = 1, .no = 3 }) == .yes;
    const shape = if (filling) tiny else if (fat32) test_disk.small32 else test_disk.small;
    var w = World{
        .seed = seed,
        .gpa = gpa,
        .io = io,
        .model = Model.init(gpa),
        .disk = try test_disk.Disk.makeIn(gpa, io, "damaged-store-sim", shape, false),
        .fat = undefined,
        .tmp = try ScratchDir.make(io, .{ .iterate = true }),
        .linux = undefined,
        .big = undefined,
    };
    const max_n: usize = if (filling) 1_500_000 else 6000;
    // Room for the volume, and for an append's old bytes and new together.
    for (&w.big) |*b| b.* = try gpa.alloc(u8, @as(usize, shape.sectors) * 512 + max_n);
    defer for (w.big) |b| gpa.free(b);
    w.fat = .{ .vol = &w.disk.vol };
    w.linux = .{ .io = io, .root = w.tmp.dir };
    if (cached) w.cache = try test_disk.Cache.attach(w.disk);
    defer {
        w.model.deinit();
        if (w.cache) |c| c.detach(w.disk);
        w.disk.deinit();
        w.tmp.cleanup();
    }
    const stores = [_]store.Store{ w.model.store_(), w.fat.store_(), w.linux.store_() };
    _ = stores;
    const bytes = try gpa.alloc(u8, max_n);
    defer gpa.free(bytes);
    var outs: [3][8192]u8 = undefined;
    const cut_every = r.intRangeAtMost(u32, 4, 20);
    for (0..r.intRangeAtMost(usize, 30, 120)) |step| {
        ev.count += 1;
        const op: Op = switch (explore.pickAs(r, usize, "store_sim: the operation", .{ .read = 1, .write = 1, .append = 1, .remove = 1, .replace = 1, .list = 1 })) {
            inline else => |o| @field(Op, @tagName(o)),
        };
        const path = paths[r.uintLessThan(usize, paths.len)];
        const n = if (explore.flag(r, "store_sim: the bytes are few")) r.uintLessThan(usize, 64) else if (filling) second.uintLessThan(usize, bytes.len) else r.uintLessThan(usize, bytes.len);
        r.bytes(bytes[0..n]);
        const writes_something = op == .write or op == .append or op == .replace or op == .remove;
        // What `io.durable` does before every response: each step's writes
        // are durable before the next begins. Only a cache can tell.
        if (w.cache != null) try w.flush(step);
        if (writes_something and r.uintLessThan(u32, cut_every) == 0) {
            try cutOne(&w, r, op, path, bytes[0..n], step);
            continue;
        }
        // What FAT holds there before, for the promise if it runs out.
        const before: ?[]const u8 = if (filling and writes_something) (if (w.fat.store_().read(path, w.big[0])) |got| w.big[0][0..got] else |_| null) else null;
        const a = [_]Answer{
            run(w.model.store_(), op, path, bytes[0..n], &outs[0]),
            run(w.fat.store_(), op, path, bytes[0..n], &outs[1]),
            run(w.linux.store_(), op, path, bytes[0..n], &outs[2]),
        };
        if (a[1].err) |fe| if (fe == Error.NoSpace) {
            try noSpace(&w, op, path, before, step);
            continue;
        };
        const alike = a[0].eql(a[1]) and a[0].eql(a[2]);
        props.always(@src(), alike, "store_sim: the three stores answer every operation alike", .{ .step = step, .op = @tagName(op) });
        if (!alike) return fail(seed, "step {d}, {s} \"{s}\": the model {any}, FAT {any}, Linux {any}", .{ step, @tagName(op), path, a[0].err, a[1].err, a[2].err });
        if (a[0].err) |e| switch (e) {
            Error.BadName => props.reachable(@src(), "store_sim: all three refuse a name, for the same reason", .{ .op = @tagName(op) }),
            Error.NotFound => props.reachable(@src(), "store_sim: all three find nothing there", null),
            Error.IsDirectory => props.reachable(@src(), "store_sim: all three refuse a file operation on a directory", null),
            Error.TooBig => props.reachable(@src(), "store_sim: all three refuse a read into too little room", null),
            else => {},
        } else if (op == .read and isVariant(path))
            props.reachable(@src(), "store_sim: a spelling in another case, or with empty parts, finds the same file", null);
        try same(&w, step);
    }
}

fn same(w: *World, step: usize) !void {
    const m = try snapshot(w.model.store_(), w.gpa);
    defer w.gpa.free(m);
    const f = try snapshot(w.fat.store_(), w.gpa);
    defer w.gpa.free(f);
    const l = try snapshot(w.linux.store_(), w.gpa);
    defer w.gpa.free(l);
    const alike = std.mem.eql(u8, m, f) and std.mem.eql(u8, m, l);
    props.always(@src(), alike, "store_sim: the three trees are the same after every operation", .{ .step = step });
    if (!alike) return fail(w.seed, "step {d}: the trees differ\nthe model:\n{s}FAT:\n{s}Linux:\n{s}", .{ step, m, f, l });
}

/// The smallest FAT16 volume `test_disk` makes: about 2 MiB, so a few large
/// files fill it.
const tiny = test_disk.Shape{ .sectors = 4400, .suffix = "-tiny" };

/// FAT answered `NoSpace` to `op` on `path`, which held `before`: the file
/// must be what the promise allows without the room to finish.
fn noSpace(w: *World, op: Op, path: []const u8, before: ?[]const u8, step: usize) !void {
    props.reachable(@src(), "store_sim: a full volume answers NoSpace", .{ .op = @tagName(op) });
    const now: ?[]const u8 = if (w.fat.store_().read(path, w.big[2])) |got| w.big[2][0..got] else |e| switch (e) {
        Error.NotFound => null,
        else => return fail(w.seed, "step {d}, {s} \"{s}\" out of room: the file reads as {s}", .{ step, @tagName(op), path, @errorName(e) }),
    };
    const old = if (now == null or before == null) now == null and before == null else std.mem.eql(u8, now.?, before.?);
    const kept = switch (op) {
        .replace => blk: {
            props.always(@src(), old, "store_sim: after NoSpace, a replaced file is wholly old", .{ .step = step });
            break :blk old;
        },
        .append => blk: {
            props.always(@src(), old, "store_sim: after NoSpace, an appended file is old", .{ .step = step });
            break :blk old;
        },
        .write => blk: {
            props.always(@src(), old or now == null, "store_sim: after NoSpace, a written file is old or gone", .{ .step = step });
            break :blk old or now == null;
        },
        else => false,
    };
    if (!kept) return fail(w.seed, "step {d}, {s} \"{s}\" out of room: the file is not what store.zig allows", .{ step, @tagName(op), path });
    try w.copyFromFat();
    try same(w, step);
}

/// `op` on the FAT store with the power cut at a request the seed picks,
/// then the next boot's mount, and the promise for `op` checked on `path`.
fn cutOne(w: *World, r: std.Random, op: Op, path: []const u8, bytes: []const u8, step: usize) !void {
    const before_buf = w.big[0];
    const before: ?[]const u8 = if (w.fat.store_().read(path, before_buf)) |n| before_buf[0..n] else |e| switch (e) {
        Error.NotFound, Error.BadName, Error.IsDirectory => null,
        else => return fail(w.seed, "step {d}: before the cut, \"{s}\" reads as {s}", .{ step, path, @errorName(e) }),
    };
    // What the operation would leave, from the model, on a copy of what it
    // holds for this path only.
    const after_buf = w.big[1];
    var after: ?[]const u8 = null;
    switch (op) {
        .write, .replace => after = bytes,
        .append => if (before) |b| {
            @memcpy(after_buf[0..b.len], b);
            @memcpy(after_buf[b.len..][0..bytes.len], bytes);
            after = after_buf[0 .. b.len + bytes.len];
        } else {
            after = bytes;
        },
        else => after = null,
    }
    const base = w.disk.blk.requests;
    w.disk.blk.fail_after = base + r.uintLessThan(u64, 60);
    if (explore.pick(r, "store_sim: the cut tears a sector", .{ .yes = 1, .no = 2 }) == .yes) w.disk.blk.fault = .{ .at = w.disk.blk.fail_after.? -| 1, .kind = .torn };
    var scratch: [8192]u8 = undefined;
    const answered = run(w.fat.store_(), op, path, bytes, &scratch);
    const cut = w.disk.blk.requests >= w.disk.blk.fail_after.?;
    w.disk.blk.fail_after = null;
    w.disk.blk.fault = null;
    if (w.cache) |c| {
        if (cut) {
            if (c.pending() > 0) props.reachable(@src(), "store_sim: a cut drops some of the writes a cache held", .{ .op = @tagName(op), .waiting = c.pending() });
            c.cut(w.disk, r, keepOne);
        } else try w.flush(step);
    }
    try w.disk.mount(false);
    w.fat = .{ .vol = &w.disk.vol };
    if (!cut) {
        // The operation finished before the cut: an ordinary step, whose
        // answer the others must give too.
        try w.copyFromFat();
        _ = answered;
        try same(w, step);
        return;
    }
    props.reachable(@src(), "store_sim: a cut lands inside an operation", .{ .op = @tagName(op) });
    const now_buf = w.big[2];
    const now: ?[]const u8 = if (w.fat.store_().read(path, now_buf)) |n| now_buf[0..n] else |e| switch (e) {
        Error.NotFound, Error.BadName, Error.IsDirectory => null,
        else => return fail(w.seed, "step {d}, {s} \"{s}\" cut: the file reads as {s}", .{ step, @tagName(op), path, @errorName(e) }),
    };
    const is = struct {
        fn same(a: ?[]const u8, b: ?[]const u8) bool {
            if (a == null or b == null) return a == null and b == null;
            return std.mem.eql(u8, a.?, b.?);
        }
    };
    const old = is.same(now, before);
    const new = if (op == .remove) now == null else is.same(now, after);
    const kept = switch (op) {
        .replace => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, a replaced file is wholly old or wholly new", .{ .step = step });
            break :blk old or new;
        },
        .append => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, an appended file is old or new", .{ .step = step });
            break :blk old or new;
        },
        .write => blk: {
            props.always(@src(), old or new or now == null, "store_sim: after a cut, a written file is old, new or gone", .{ .step = step });
            break :blk old or new or now == null;
        },
        .remove => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, a removed file is there or gone", .{ .step = step });
            break :blk old or new;
        },
        else => true,
    };
    if (!kept) return fail(w.seed, "step {d}, {s} \"{s}\" cut: the file is neither what store.zig allows", .{ step, @tagName(op), path });
    try w.copyFromFat();
    try same(w, step);
}

/// Whether a waiting write reaches the disk before the power goes: a coin
/// for each, so a cut keeps any subset of them, as a cache that writes back
/// in its own order may.
fn keepOne(r: std.Random, _: usize) bool {
    return explore.flag(r, "store_sim: a cached write lands before the cut");
}

/// **`runSeed` ON A DISK WITH A WRITE CACHE** (metal-vmm QUEUE 112): each
/// step's writes are flushed before the next step, as `io.durable` flushes
/// before a response, and a cut keeps what was flushed and any subset of
/// what was not. The same promises are checked. Its own entry, not a draw
/// in `runSeed`, so every seed `runSeed` runs is the run it was.
pub fn runSeedCached(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed);
    var second = std.Random.DefaultPrng.init(seed ^ 0x6675_6c6c); // "full"
    return runFrom(std.testing.allocator, std.testing.io, seed, prng.random(), second.random(), true) catch |e| switch (e) {
        error.SimulationFailed => error.SimulationFailed,
        else => fail(seed, "{s}", .{@errorName(e)}),
    };
}

test {
    _ = test_disk; // its write cache's own test
}

/// The seeds `zig build test` runs, of `runSeed` and of `replaysExactly`.
/// `zig build properties` sweeps the rest: 1,000 seeds of `runSeed`, and
/// seeds 1 to 20 of `replaysExactly`, which `test` ran until
/// they cost most of a minute of a Debug run (metal-vmm QUEUE 136). One
/// since 203(d) (tier 0 on the box's 2 cores): 1 and 2 were the ordinary
/// runs every seed of the sweep repeats.
const seeds = [_]u64{
    // Kills mutant S4 (MUTATION.md: a full volume's `Full` not mapped to
    // NoSpace); 1 and 2 never fill it.
    5,
};

test "store_sim: one seed, the one that fills the volume (properties: 1..1000)" {
    for (seeds) |seed| try runSeed(seed);
}

/// **A RUN UNDER A TAPE REPLAYS EXACTLY**: the same draws, the same
/// choices, for one seed.
pub fn replaysExactly(seed: u64) !void {
    var first = explore.Tape.init(std.testing.allocator, seed);
    defer first.deinit();
    try runWith(&first);
    var again = explore.Tape.branch(std.testing.allocator, &first, first.position(), seed +% 0x9999, null);
    defer again.deinit();
    try runWith(&again);
    try std.testing.expect(!again.drifted);
    try std.testing.expectEqualSlices(u8, first.bytes.items, again.bytes.items);
    try std.testing.expectEqual(first.choices.items.len, again.choices.items.len);
}

test "a run under a tape replays exactly: the same draws, the same choices" {
    try replaysExactly(1);
}

// **FAT16 HERE NEEDS A DISK THAT WRITES THROUGH** (metal-vmm QUEUE 112):
// its crash safety is the order of its writes, and a write cache keeps no
// order between flushes, so on one a cut breaks the promises `runSeed`
// holds. Boot turns the volume's cache off for that (`scsi.turnCacheOff`,
// Steve's choice over write barriers, 2026-10-09). This holds the reason:
// if disk_fat ever orders its writes with barriers instead, these seeds pass,
// this fails, and the choice is worth making again.
test "store_sim: on a disk with a write cache, a cut breaks disk_fat's promises (why boot turns the cache off)" {
    var broken: u32 = 0;
    quiet = true;
    defer quiet = false;
    // Up to forty seeds, stopping at the first that breaks: one is the
    // finding (metal-vmm QUEUE 136: the rest cost time and said no more).
    // **SEED 13 FIRST** (metal-vmm QUEUE 198.11): the first that breaks,
    // found by running 1 to 40; the twelve before it cost 9 s and said
    // nothing. Should a change make 13 hold, the rest are still tried.
    const first_break = 13;
    for ([_]u64{first_break} ++ seedsBut(first_break)) |seed| {
        runSeedCached(seed) catch {
            broken += 1;
            break;
        };
    }
    try std.testing.expect(broken > 0);
}

/// 1 to 40, but `skip`.
fn seedsBut(comptime skip: u64) [39]u64 {
    var out: [39]u64 = undefined;
    var k: usize = 0;
    for (1..41) |s| if (s != skip) {
        out[k] = s;
        k += 1;
    };
    return out;
}
