//! **FAT16 AND FAT32 AGAINST A RANDOM WORKLOAD AND A MODEL OF WHAT THEY HOLD.**
//!
//! Each run is one seed. The seed chooses a volume (FAT16 or FAT32), how big
//! the files run (enough to fill the volume, or not), and a sequence of the
//! operations the application makes: whole-file writes and rewrites, appends,
//! removes, renames, directories made and trees removed, and remounts — the
//! next boot. Names come from a pool shaped like the application's: long
//! names, 8.3 names, names that differ only past their eighth character, deep
//! paths, and enough numbered names to fill a directory.
//!
//! **THE ORACLES**, after every operation:
//!
//! - **The model.** Every file the model holds reads back byte for byte, and
//!   every directory opens as one. An operation that fails for want of room
//!   (`Full`, `DirectoryFull`) may leave what it touched as it was or as it
//!   would have been, nothing else: a write over a file and an append each
//!   keep the old file whole.
//! - **The volume.** `Volume.check` finds nothing: no leaked cluster, no
//!   chain shared, no orphaned long name. The kept free count is the count
//!   of the FAT on the disk, the volume's own recount agrees, and the FAT
//!   copies are the same bytes.
//! - **Both paths, one disk.** The same seed runs with the FAT on the disk
//!   and with it held in memory, and must leave byte-identical volumes, as
//!   `probe/run.sh` requires of the probes.
//!
//! A failing seed is reported with the operation it failed at; it is the
//! repro. disk_fat.zig's coverage properties (COVERAGE.md) say which of its
//! paths the runs reached.

const std = @import("std");
const ev = @import("sim_events.zig");
const disk_fat = @import("disk_fat.zig");
const test_disk = @import("test_disk.zig");
const props = @import("coverage");
const explore = @import("explore");
const testing = std.testing;

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const dirs = [_][]const u8{ "data", "data/chat", "data/chat/A Long Topic Name", "auth", "auth/7" };
const names = [_][]const u8{
    "a",
    "B.TXT",
    "messages.jsonl",
    "a rather long file name that needs several parts.txt",
    "x.y.z",
    "UPPER",
    "last-seen-by-user",
    "last-seen-by-admin",
};
/// Numbered names, for a run that fills a directory.
const numbered = 700;

const Op = enum { write, append, remove, rename, mkdir, remove_tree, remount };

const Scenario = struct {
    shape: test_disk.Shape,
    ops: usize,
    /// The largest file a write makes.
    max_bytes: usize,
    /// **FILLING THE VOLUME**: files sized to it, so a handful of live ones
    /// leave no room, and the allocation cursor goes round.
    filling: bool,
    /// **FILLING A DIRECTORY**: hundreds of operations, mostly on numbered
    /// names in one directory. The root of a FAT16 volume is a fixed 512
    /// entries, the one limit this filesystem has that the application can
    /// meet in normal use.
    crowded: bool,
    crowd_dir: usize,
    /// The model and the volume are checked whole every this many
    /// operations, and after each of the first twenty that found no room.
    check_every: usize,
    /// **THE DISK'S MOST IN ONE REQUEST** (metal-vmm QUEUE 180.4): a
    /// cluster, 8, 128 or ours (2,048), so a run cut by the limit part-way
    /// through a chain is in the sweeps. Drawn from its own generator,
    /// seeded from the run's seed (`mostOf`), never from the run's draws:
    /// so every seed's other draws are what they were, and the pinned
    /// regression seeds still replay the runs that found them (187.2).
    most_sectors: u32 = 0,

    fn choose(rng: std.Random) Scenario {
        // Named choices (zig-coverage-sdk's explore.pick), drawn exactly as
        // `uintLessThan(u8, 4)` was, so every seed's run is the run it was.
        const fat32 = explore.pick(rng, "fat_sim: the volume is FAT32", .{ .yes = 1, .no = 3 }) == .yes;
        const shape = if (fat32) test_disk.small32 else test_disk.small;
        const volume_bytes = @as(usize, shape.sectors) * test_disk.sector;
        const mode = explore.pick(rng, "fat_sim: the run's mode", .{ .plain = 1, .filling = 1, .crowded = 1, .also_plain = 1 });
        const filling = mode == .filling;
        const crowded = mode == .crowded;
        return .{
            .shape = shape,
            .ops = if (crowded) rng.intRangeAtMost(usize, 800, 1200) else rng.intRangeAtMost(usize, 20, 120),
            .max_bytes = if (filling) volume_bytes * 3 / 8 else ([_]usize{ 300, 6000, 70_000, 600_000 })[rng.uintLessThan(usize, 4)],
            .filling = filling,
            .crowded = crowded,
            .crowd_dir = if (crowded and rng.boolean()) dirs.len else rng.uintLessThan(usize, dirs.len + 1),
            .check_every = if (crowded) 50 else 1,
        };
    }
};

const Model = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMap([]u8),
    dirs: std.StringHashMap(void),

    fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa, .files = .init(gpa), .dirs = .init(gpa) };
    }

    fn deinit(m: *Model) void {
        var f = m.files.iterator();
        while (f.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.*);
        }
        m.files.deinit();
        var d = m.dirs.keyIterator();
        while (d.next()) |k| m.gpa.free(k.*);
        m.dirs.deinit();
    }

    fn setFile(m: *Model, path: []const u8, bytes: []const u8) !void {
        const copy = try m.gpa.dupe(u8, bytes);
        if (m.files.getPtr(path)) |v| {
            m.gpa.free(v.*);
            v.* = copy;
        } else try m.files.put(try m.gpa.dupe(u8, path), copy);
    }

    fn dropFile(m: *Model, path: []const u8) void {
        if (m.files.fetchRemove(path)) |kv| {
            m.gpa.free(kv.key);
            m.gpa.free(kv.value);
        }
    }

    fn addDir(m: *Model, path: []const u8) !void {
        if (path.len == 0 or m.dirs.contains(path)) return;
        try m.dirs.put(try m.gpa.dupe(u8, path), {});
    }

    /// Every directory a path needs, in the model.
    fn addParents(m: *Model, path: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            try m.addDir(path[0..slash]);
        }
    }

    /// A tree, gone: the directory and everything under it.
    fn dropTree(m: *Model, dir: []const u8) !void {
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(m.gpa);
        var f = m.files.keyIterator();
        while (f.next()) |k| if (under(k.*, dir)) try doomed.append(m.gpa, k.*);
        for (doomed.items) |k| m.dropFile(k);
        doomed.clearRetainingCapacity();
        var d = m.dirs.keyIterator();
        while (d.next()) |k| if (std.mem.eql(u8, k.*, dir) or under(k.*, dir)) try doomed.append(m.gpa, k.*);
        for (doomed.items) |k| {
            const kv = m.dirs.fetchRemove(k).?;
            m.gpa.free(kv.key);
        }
    }
};

fn under(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

const Sim = struct {
    /// What the run allocates from: `std.testing`'s under a test, the
    /// program's otherwise (metal-vmm QUEUE 106).
    gpa: std.mem.Allocator,
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    cached: bool,
    disk: *test_disk.Disk,
    model: Model,
    step: usize = 0,
    path_buf: [256]u8 = undefined,
    path2_buf: [256]u8 = undefined,
    /// **WHAT THE LAST OPERATION TOUCHED** (metal-vmm QUEUE 224.4, Steve's
    /// (b)): its paths, copied, a directory's standing for everything under
    /// it. `verify` reads those files back at once; every file only on every
    /// `read_all_every`th operation, the last, a step with a probe, and in a
    /// scenario that verifies seldom (`check_every` above 1).
    touched_buf: [2][256]u8 = undefined,
    touched: [2][]const u8 = .{ "", "" },
    touched_n: usize = 0,
    probed_now: bool = false,
    bytes: []u8,
    /// The first oracle that failed, if any.
    broken: ?[]const u8 = null,
    /// How many operations failed for want of room, for the report.
    full: usize = 0,
    /// **WHERE A FILLING RUN STANDS** (metal-vmm B33): large files, until the
    /// volume refuses one (`Full`, the reserve kept for small writes); then
    /// a file of what still fits outside the reserve, and once nothing
    /// does, the small writes the reserve is for, each as large as it takes.
    /// Without the turn a run never spent the reserve: allocation takes the
    /// lowest free cluster, so a FAT32 volume's clusters past 65535 sat in
    /// it, out of every seed's reach.
    filling: enum { large, small } = .large,
    /// The last operation, and what it said, for the report.
    last: Op = .remount,
    last_said: []const u8 = "ok",
    /// **PROBES** (`runProbeSeed`): what the volume must refuse, tried
    /// between the operations from dice of their own, so a seed's
    /// operations are the ones it always had.
    probes: ?std.Random.DefaultPrng = null,
    /// **A RUN UNDER A TAPE** (`runWith`): its draws come from `drawn`, not
    /// from `prng`, and its probes too when `probes_drawn` says so.
    drawn: ?std.Random = null,
    probes_drawn: bool = false,
    /// A probe made the disk fail, which ends the run.
    failed_disk: bool = false,
    /// The last probe, for the report.
    last_probe: []const u8 = "none",

    fn init(seed: u64, cached: bool) !Sim {
        var prng = std.Random.DefaultPrng.init(seed);
        // The scenario first: the run's draws go on from where it left the PRNG.
        const sc = Scenario.choose(prng.random());
        return initFrom(testing.allocator, testing.io, seed, prng, sc, cached);
    }

    /// A run whose every draw comes from `r` (a tape's, under `runWith`).
    fn initWith(gpa: std.mem.Allocator, io: std.Io, seed: u64, r: std.Random, cached: bool) !Sim {
        var s = try initFrom(gpa, io, seed, .init(seed), Scenario.choose(r), cached);
        s.drawn = r;
        return s;
    }

    fn initFrom(gpa: std.mem.Allocator, io: std.Io, seed: u64, prng: std.Random.DefaultPrng, drawn_sc: Scenario, cached: bool) !Sim {
        var sc = drawn_sc;
        sc.most_sectors = mostOf(seed, sc.shape);
        var s: Sim = .{
            .gpa = gpa,
            .seed = seed,
            .prng = prng,
            .rng = undefined,
            .sc = sc,
            .cached = cached,
            .disk = try test_disk.Disk.makeIn(gpa, io, "fat-sim", sc.shape, cached),
            .model = .init(gpa),
            .bytes = try gpa.alloc(u8, sc.max_bytes),
        };
        s.disk.blk.most_sectors = sc.most_sectors;
        return s;
    }

    /// The disk's most for the run of `seed` (`Scenario.most_sectors`).
    fn mostOf(seed: u64, shape: test_disk.Shape) u32 {
        var side = std.Random.DefaultPrng.init(seed ^ 0x6d6f_7374_7365_6374); // "mostsect"
        const choices = [_]u32{ shape.sectors_per_cluster, 8, 128, @import("virtio_blk.zig").Block.most_sectors_ours };
        return choices[side.random().uintLessThan(usize, choices.len)];
    }

    fn deinit(s: *Sim) void {
        s.model.deinit();
        s.gpa.free(s.bytes);
        // test_disk checks a disk left healthy on the way out; a run that
        // failed has already said why, so it is not asked again.
        if (s.broken != null or s.failed_disk) s.disk.blk.fail_after = 0;
        s.disk.deinit();
    }

    fn fault(s: *Sim, what: []const u8) void {
        if (s.broken == null) s.broken = what;
    }

    fn pickDir(s: *Sim) []const u8 {
        if (s.sc.crowded and s.rng.uintLessThan(u8, 4) != 0) return if (s.sc.crowd_dir == dirs.len) "" else dirs[s.sc.crowd_dir];
        const k = s.rng.uintLessThan(usize, dirs.len + 1);
        return if (k == dirs.len) "" else dirs[k];
    }

    fn pickName(s: *Sim, buf: []u8) []const u8 {
        // Half of them long names, two or three entries each: a directory
        // fills in fewer files, and a long name needs a run, not a slot.
        if (s.sc.crowded and s.rng.uintLessThan(u8, 10) != 0) {
            const k = s.rng.uintLessThan(usize, numbered);
            return (if (k % 2 == 0) std.fmt.bufPrint(buf, "n{d}", .{k}) else std.fmt.bufPrint(buf, "message number {d}.jsonl", .{k})) catch unreachable;
        }
        return names[s.rng.uintLessThan(usize, names.len)];
    }

    fn join(dir: []const u8, name: []const u8, buf: []u8) []const u8 {
        if (dir.len == 0) return std.fmt.bufPrint(buf, "{s}", .{name}) catch unreachable;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch unreachable;
    }

    /// Bytes no other write in this run has, so a file that reads back
    /// another's contents is caught.
    fn content(s: *Sim, n: usize) []const u8 {
        for (s.bytes[0..n], 0..) |*b, k| b.* = @truncate(k *% 31 +% s.step *% 7 +% 1);
        return s.bytes[0..n];
    }

    fn size(s: *Sim) usize {
        // Mostly small, now and then up to the scenario's largest; filling,
        // mostly large until one is refused, then up to what the reserve
        // takes.
        if (s.sc.filling and s.rng.uintLessThan(u8, 3) != 0) return switch (s.filling) {
            .large => s.rng.uintAtMost(usize, s.sc.max_bytes),
            .small => small: {
                const vol = &s.disk.vol;
                const cluster: usize = @as(usize, vol.sectors_per_cluster) * test_disk.sector;
                const outside: usize = if (vol.free_clusters > vol.reserve_clusters) (vol.free_clusters - vol.reserve_clusters) * cluster else 0;
                break :small if (outside > disk_fat.Volume.small_bytes)
                    @min(s.sc.max_bytes, outside - cluster) // one to spare: the directory may grow
                else
                    @min(s.sc.max_bytes, disk_fat.Volume.small_bytes);
            },
        };
        if (s.rng.uintLessThan(u8, 5) == 0) return s.rng.uintAtMost(usize, s.sc.max_bytes);
        return s.rng.uintAtMost(usize, @min(s.sc.max_bytes, 600));
    }

    fn roomless(e: anyerror) bool {
        return e == disk_fat.Error.Full or e == disk_fat.Error.DirectoryFull;
    }

    fn run(s: *Sim) !void {
        s.rng = s.drawn orelse s.prng.random();
        while (s.step < s.sc.ops and s.broken == null) : (s.step += 1) {
            ev.count += 1;
            const full = s.full;
            s.touched_n = 0;
            s.probed_now = false;
            try s.turn();
            if (s.probeRandom()) |p| if (s.broken == null and p.uintLessThan(u8, 3) == 0) {
                s.probed_now = true;
                try s.probe(p);
                if (s.failed_disk) break;
            };
            // After an operation that found no room, at once, but only for the
            // first twenty: a full directory refuses nearly everything after,
            // and the leaks this has found showed on the first refusals.
            const refused = s.full != full and s.full <= 20;
            const due = refused or s.step % s.sc.check_every == 0 or s.step + 1 == s.sc.ops;
            if (s.broken == null and due) try s.verify();
        }
        if (s.broken) |what| {
            std.debug.print("fat_sim seed {d} ({s}, {s}) failed at operation {d}, a {s} that said {s}: {s}\n", .{
                s.seed, if (s.cached) "FAT held in memory" else "FAT on the disk", if (s.sc.shape.kind == .fat32) "FAT32" else "FAT16",
                s.step, @tagName(s.last),                                          s.last_said,
                what,
            });
            if (s.probes != null or s.probes_drawn) std.debug.print("  the last probe: {s}\n", .{s.last_probe});
            return error.SimulationFailed;
        }
    }

    fn probeRandom(s: *Sim) ?std.Random {
        if (s.probes_drawn) return s.drawn;
        return if (s.probes) |*p| p.random() else null;
    }

    fn turn(s: *Sim) !void {
        // A named choice outside a crowd (explore.pick, drawn as
        // `uintLessThan(u8, 100)` was); a crowd keeps the raw roll, since
        // crowding a directory is mostly making names in it.
        const op: Op = if (!s.sc.crowded) switch (explore.pick(s.rng, "fat_sim: the operation", .{ .write = 30, .append = 25, .remove = 10, .rename = 10, .mkdir = 8, .remove_tree = 5, .remount = 12 })) {
            inline else => |o| @field(Op, @tagName(o)),
        } else blk: {
            const roll = s.rng.uintLessThan(u8, 100);
            break :blk if (roll < 50) .write else switch (roll) {
                0...29 => .write,
                30...54 => .append,
                55...64 => .remove,
                65...74 => .rename,
                75...82 => .mkdir,
                83...87 => .remove_tree,
                else => .remount,
            };
        };
        const vol = &s.disk.vol;
        s.last = op;
        s.last_said = "ok";
        switch (op) {
            .write => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                s.touch(path);
                const bytes = s.content(s.size());
                const old = s.model.files.get(path);
                if (vol.writeFile(path, bytes)) {
                    try s.model.setFile(path, bytes);
                    try s.model.addParents(path);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: a write finds no room", .{ .seed = s.seed });
                    if (s.sc.filling and s.filling == .large and e == disk_fat.Error.Full and bytes.len > disk_fat.Volume.small_bytes) {
                        props.reachable(@src(), "fat_sim: a filling run turns to small writes, to spend the reserve", .{ .seed = s.seed });
                        s.filling = .small;
                    }
                    try s.settle(path, old, null);
                }
            },
            .append => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                s.touch(path);
                const bytes = s.content(@max(1, s.size()));
                const old = s.model.files.get(path) orelse {
                    if (vol.writeInto(path, 0, bytes)) {
                        return s.fault("an append to a file that is not there succeeded");
                    } else |e| if (e != disk_fat.Error.NotFound) return s.fault(@errorName(e));
                    return;
                };
                if (vol.writeInto(path, @intCast(old.len), bytes)) {
                    const whole = try std.mem.concat(s.gpa, u8, &.{ old, bytes });
                    defer s.gpa.free(whole);
                    try s.model.setFile(path, whole);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: an append finds no room", .{ .seed = s.seed });
                    // An append that could not finish leaves the old file whole.
                }
            },
            .remove => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                s.touch(path);
                if (vol.remove(path)) {
                    if (!s.model.files.contains(path)) return s.fault("a remove of a file that is not there succeeded");
                    s.model.dropFile(path);
                } else |e| {
                    if (e != disk_fat.Error.NotFound or s.model.files.contains(path)) return s.fault(@errorName(e));
                }
            },
            .rename => {
                const dir = s.pickDir();
                var name_a: [40]u8 = undefined;
                var name_b: [40]u8 = undefined;
                const from = join(dir, s.pickName(&name_a), &s.path_buf);
                const to = join(dir, s.pickName(&name_b), &s.path2_buf);
                if (std.mem.eql(u8, from, to)) return;
                s.touch(from);
                s.touch(to);
                const old_from = s.model.files.get(from);
                const old_to = s.model.files.get(to);
                if (vol.rename(from, to)) {
                    const moved = old_from orelse return s.fault("a rename of a file that is not there succeeded");
                    const copy = try s.gpa.dupe(u8, moved);
                    defer s.gpa.free(copy);
                    s.model.dropFile(from);
                    try s.model.setFile(to, copy);
                } else |e| {
                    if (e == disk_fat.Error.NotFound and old_from == null) return;
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: a rename finds no room", .{ .seed = s.seed });
                    // Either nothing happened, or all of it.
                    try s.settle(to, old_to, old_from);
                    try s.settle(from, old_from, null);
                }
            },
            .mkdir => {
                const dir = dirs[s.rng.uintLessThan(usize, dirs.len)];
                s.touch(dir);
                if (vol.makePath(dir)) |_| {
                    try s.model.addParents(dir);
                    try s.model.addDir(dir);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    try s.settleDirs();
                }
            },
            .remove_tree => {
                const dir = dirs[s.rng.uintLessThan(usize, dirs.len)];
                s.touch(dir);
                vol.removeTree(dir) catch |e| return s.fault(@errorName(e));
                try s.model.dropTree(dir);
            },
            .remount => {
                props.reachable(@src(), "fat_sim: the volume is mounted again", null);
                s.disk.mount(s.cached) catch |e| return s.fault(@errorName(e));
            },
        }
    }

    /// **ONE PROBE**: something the volume must refuse, with the error it
    /// must refuse it with, leaving everything as it was (the next `verify`
    /// says so). Last in a run, now and then, the disk stops answering part
    /// way through an operation, which must end in `ReadFailed` or
    /// `WriteFailed` and nothing worse.
    fn probe(s: *Sim, r: std.Random) !void {
        const vol = &s.disk.vol;
        const E = disk_fat.Error;
        const Kind = enum { boot, unreadable, bad_name, onto_dir, overwrite_dir, hole, through_open, through_write, through_remove, rename_across, rename_dir, rename_onto_dir, chain_out, chain_loop, refusing, failing };
        // Named choices (explore.pickAs, .pick, .flag), each drawn exactly as
        // the call it replaced, so a probe seed's run is the run it was.
        const named = explore.pickAs(r, usize, "fat_sim: the probe", .{ .boot = 1, .unreadable = 1, .bad_name = 1, .onto_dir = 1, .overwrite_dir = 1, .hole = 1, .through_open = 1, .through_write = 1, .through_remove = 1, .rename_across = 1, .rename_dir = 1, .rename_onto_dir = 1, .chain_out = 1, .chain_loop = 1, .refusing = 1 });
        var kind: Kind = std.meta.stringToEnum(Kind, @tagName(named)).?;
        if (s.step + 1 == s.sc.ops and explore.pick(r, "fat_sim: the last probe fails the disk", .{ .yes = 1, .no = 1 }) == .yes) kind = .failing;
        var buf: [300]u8 = undefined;
        var buf2: [300]u8 = undefined;
        s.last_probe = @tagName(kind);
        switch (kind) {
            .boot => try s.probeBoot(r),
            .unreadable => {
                var scratch: [disk_fat.sector_size]u8 align(16) = undefined;
                s.disk.blk.fail_after = s.disk.blk.requests;
                const got = disk_fat.Volume.mount(&s.disk.blk, &scratch, 0);
                s.disk.blk.fail_after = null;
                if (got) |_| return s.fault("a mount of a disk that does not answer succeeded") else |e| if (e != E.ReadFailed) return s.fault(@errorName(e));
            },
            .bad_name => {
                // A name past the longest FAT keeps, or none at all.
                // In a directory that is there: making one could find no room.
                const dir = (if (r.boolean()) s.someDir(r) else null) orelse "";
                const name = if (r.boolean()) &@as([disk_fat.max_name + 1]u8, @splat('x')) else "";
                const path = join(dir, name, &buf);
                if (vol.writeFile(path, "never")) return s.fault("a write with no name, or too long a one, succeeded") else |e| if (e != E.BadName) return s.fault(@errorName(e));
            },
            .onto_dir => {
                const dir = s.someDir(r) orelse return;
                if (vol.writeFile(dir, "never")) return s.fault("a write onto a directory succeeded") else |e| if (e != E.IsDirectory) return s.fault(@errorName(e));
            },
            .overwrite_dir => {
                const dir = s.someDir(r) orelse return;
                if (vol.writeInto(dir, 0, "never")) return s.fault("an overwrite of a directory succeeded") else |e| if (e != E.BadName) return s.fault(@errorName(e));
            },
            .hole => {
                const f = s.someFile(r) orelse return;
                const past: u32 = @intCast(f.bytes.len + 1 + r.uintLessThan(usize, 5000));
                if (vol.writeInto(f.path, past, "never")) return s.fault("an overwrite past a file's end succeeded") else |e| if (e != E.BadChain) return s.fault(@errorName(e));
            },
            .through_open => {
                const f = s.someFile(r) orelse return;
                const path = join(f.path, "inside", &buf);
                if (vol.open(path)) |_| return s.fault("a path through a file opened") else |e| if (e != E.NotFound) return s.fault(@errorName(e));
            },
            .through_write => {
                const f = s.someFile(r) orelse return;
                const path = join(f.path, "inside", &buf);
                // The directory it would make is a file's name.
                if (vol.writeFile(path, "never")) return s.fault("a write under a file succeeded") else |e| if (e != E.BadName) return s.fault(@errorName(e));
            },
            .through_remove => {
                const f = s.someFile(r) orelse return;
                const path = join(f.path, "inside", &buf);
                if (vol.remove(path)) |_| return s.fault("a remove under a file succeeded") else |e| if (e != E.NotFat16) return s.fault(@errorName(e));
            },
            .rename_across => {
                const f = s.someFile(r) orelse return;
                const parent = if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |i| f.path[0..i] else "";
                const dir = s.someDir(r) orelse return;
                if (std.mem.eql(u8, dir, parent)) return;
                const to = join(dir, "moved", &buf2);
                if (vol.rename(f.path, to)) return s.fault("a rename across directories succeeded") else |e| if (e != E.BadName) return s.fault(@errorName(e));
            },
            .rename_dir => {
                const dir = s.someDir(r) orelse return;
                const parent = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| dir[0..i] else "";
                const to = join(parent, "renamed dir", &buf);
                if (vol.rename(dir, to)) return s.fault("a rename of a directory succeeded") else |e| if (e != E.BadName) return s.fault(@errorName(e));
            },
            .rename_onto_dir => {
                const dir = s.someDir(r) orelse return;
                const parent = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| dir[0..i] else "";
                const from = join(parent, "a file beside it", &buf);
                if (s.model.files.contains(from) or s.model.dirs.contains(from)) return;
                vol.writeFile(from, "beside") catch |e| {
                    if (roomless(e)) return; // no room to set it up
                    return s.fault(@errorName(e));
                };
                try s.model.setFile(from, "beside");
                if (vol.rename(from, dir)) return s.fault("a rename onto a directory succeeded") else |e| if (e != E.IsDirectory) return s.fault(@errorName(e));
            },
            .chain_out, .chain_loop => try s.probeChain(r, kind == .chain_loop),
            .refusing => try s.probeRefusing(r),
            .failing => {
                // The disk stops answering a few requests into an operation.
                s.disk.blk.fail_after = s.disk.blk.requests + r.uintLessThan(u64, if (explore.flag(r, "fat_sim: the disk fails within 12 requests, not 80")) 12 else 80);
                s.failed_disk = true;
                // **A STOP THAT TEARS ITS LAST REQUEST** (metal-vmm QUEUE
                // 181): some of its sectors land, as a power cut leaves a
                // multi-sector write, where a stop failed whole requests.
                if (explore.flag(r, "fat_sim: the stop tears its last request")) s.disk.blk.fault = .{ .at = s.disk.blk.fail_after.? -| 1, .kind = if (explore.flag(r, "fat_sim: the tear lands its request's second half, not its first")) .torn_tail else .torn };
                // On FAT32, now and then an upload's size: a FAT run past
                // what the mount weighs sector by sector (181).
                const upload = s.sc.shape.kind == .fat32 and explore.flag(r, "fat_sim: the failing write is upload-sized");
                // An upload's FAT runs come within its first few requests:
                // its stop is drawn there, so a torn one lands in them.
                if (upload) {
                    s.disk.blk.fail_after = s.disk.blk.requests + 1 + r.uintLessThan(u64, 8);
                    if (s.disk.blk.fault != null) s.disk.blk.fault.?.at = s.disk.blk.fail_after.? - 1;
                }
                const k = r.uintLessThan(usize, dirs.len + 1);
                const path = join(if (k == dirs.len) "" else dirs[k], names[r.uintLessThan(usize, names.len)], &buf);
                var failed: ?anyerror = null;
                const appended = if (explore.flag(r, "fat_sim: the failing operation is an append")) s.someFile(r) else null;
                if (appended) |f| {
                    // An append, which writes its runs of sectors whole: the
                    // disk stops at one of its writes rather than a request.
                    s.disk.blk.fail_after = null;
                    s.disk.blk.fail_after_writes = s.disk.blk.writes + r.uintLessThan(u64, if (explore.flag(r, "fat_sim: the append fails within 8 writes, not 600")) 8 else 600);
                    vol.writeInto(f.path, @intCast(f.bytes.len), s.content(@max(1, @min(s.sc.max_bytes, r.uintLessThan(usize, 200_000))))) catch |e| {
                        failed = e;
                    };
                } else if (upload or explore.flag(r, "fat_sim: the failing operation is a write, not a read")) {
                    const big: ?[]u8 = if (upload) try s.gpa.alloc(u8, 6 << 20) else null;
                    defer if (big) |b| s.gpa.free(b);
                    if (big) |b| for (b, 0..) |*x, i| {
                        x.* = @truncate(i *% 31 +% 1);
                    };
                    vol.writeFile(path, big orelse s.content(@min(s.sc.max_bytes, r.uintLessThan(usize, 200_000)))) catch |e| {
                        failed = e;
                    };
                } else if (s.disk.read(path)) |got| {
                    s.gpa.free(got);
                } else |e| failed = e;
                if (failed) |e| if (e != E.ReadFailed and e != E.WriteFailed and e != E.NotFound and !roomless(e))
                    return s.fault(@errorName(e));
                props.reachable(@src(), "fat_sim: the disk stops answering part-way through an operation", null);
                s.disk.blk.fail_after = null;
                s.disk.blk.fail_after_writes = null;
                s.disk.blk.fault = null;
                try s.judgeStop(if (appended) |f| f.path else path);
            },
        }
    }

    /// **A BOOT SECTOR THAT LIES**, one field at a time: the mount must
    /// refuse it with its own error, and the volume, restored, is untouched.
    fn probeBoot(s: *Sim, r: std.Random) !void {
        const E = disk_fat.Error;
        const disk = s.disk.bytes;
        const fat32 = s.sc.shape.kind == .fat32;
        var saved: [2 * test_disk.sector]u8 = undefined;
        @memcpy(&saved, disk[0..saved.len]);
        defer @memcpy(disk[0..saved.len], &saved);
        const b = disk[0..test_disk.sector];
        const le16 = struct {
            fn f(at: []u8, v: u16) void {
                std.mem.writeInt(u16, at[0..2], v, .little);
            }
        }.f;
        const le32 = struct {
            fn f(at: []u8, v: u32) void {
                std.mem.writeInt(u32, at[0..4], v, .little);
            }
        }.f;
        var start: u32 = 0;
        const want: anyerror = switch (r.uintLessThan(u8, if (fat32) 15 else 11)) {
            0 => w: {
                b[510 + r.uintLessThan(usize, 2)] ^= 0xFF;
                break :w E.BadBootSector;
            },
            1 => w: {
                le16(b[11..13], if (r.boolean()) 1024 else 4096);
                break :w E.NotFat16;
            },
            2 => w: {
                b[13] = if (r.boolean()) 0 else r.intRangeAtMost(u8, 129, 255);
                break :w E.BadBootSector;
            },
            3 => w: {
                if (r.boolean()) le16(b[14..16], 0) else b[16] = if (r.boolean()) 0 else r.intRangeAtMost(u8, 3, 255);
                break :w E.BadBootSector;
            },
            4 => w: {
                le16(b[22..24], 0);
                le32(b[36..40], 0);
                break :w E.BadBootSector;
            },
            5 => w: {
                // No data region: fewer sectors than the FATs and the root.
                le16(b[19..21], 1);
                break :w E.BadBootSector;
            },
            6 => w: {
                // Too few clusters for FAT16: the data region cut to 100.
                const reserved: u32 = std.mem.readInt(u16, b[14..16], .little);
                const fats: u32 = b[16];
                const spf: u32 = if (std.mem.readInt(u16, b[22..24], .little) != 0) std.mem.readInt(u16, b[22..24], .little) else std.mem.readInt(u32, b[36..40], .little);
                const root: u32 = (@as(u32, std.mem.readInt(u16, b[17..19], .little)) * 32 + 511) / 512;
                const data = reserved + fats * spf + root;
                const total = data + 100 * @as(u32, b[13]);
                if (total > 0xFFFF) {
                    le16(b[19..21], 0);
                    le32(b[32..36], total);
                } else le16(b[19..21], @intCast(total));
                break :w E.NotFat16;
            },
            7 => w: {
                // A FAT of one sector, far too short for the clusters.
                if (fat32) le32(b[36..40], 1) else le16(b[22..24], 1);
                break :w E.BadBootSector;
            },
            8 => w: {
                // A volume past 32-bit sectors, from where it starts: the
                // boot sector copied one sector on, and the mount told to
                // start there.
                le16(b[19..21], 0);
                le32(b[32..36], 0xFFFF_FFFF);
                @memcpy(disk[test_disk.sector..][0..test_disk.sector], b);
                start = 1;
                break :w E.VolumeTooLarge;
            },
            9, 10 => w: {
                if (fat32) {
                    // A FAT32 volume with FAT16's FAT size set: a FAT of
                    // one sector by FAT16's field, the clusters still too
                    // many for FAT16.
                    le16(b[22..24], 1);
                    break :w E.BadBootSector;
                }
                le16(b[17..19], 0);
                break :w E.BadBootSector;
            },
            11 => w: {
                le16(b[40..42], std.mem.readInt(u16, b[40..42], .little) | 0x80);
                break :w E.NotMirrored;
            },
            12 => w: {
                le16(b[42..44], r.intRangeAtMost(u16, 1, 0xFFFF));
                break :w E.FatVersion;
            },
            13 => w: {
                le32(b[44..48], if (r.boolean()) r.uintLessThan(u32, 2) else 0x0FFF_FFF0);
                break :w E.BadRoot;
            },
            else => w: {
                // FAT32 with root entries, as FAT16 has them.
                le16(b[17..19], 512);
                break :w E.BadBootSector;
            },
        };
        var scratch: [disk_fat.sector_size]u8 align(16) = undefined;
        if (disk_fat.Volume.mount(&s.disk.blk, &scratch, start)) |_| {
            return s.fault("a mount of a boot sector that lies succeeded");
        } else |e| if (e != want) {
            std.debug.print("  the boot sector probe wanted {s}\n", .{@errorName(want)});
            return s.fault(@errorName(e));
        }
    }

    /// **A FILE'S CHAIN DAMAGED, AND PUT BACK**: its first link pointed
    /// outside the data, or its second back at its first (a loop). In every
    /// copy of the FAT, and in the one held in memory. A read must not
    /// answer with bytes the file does not hold as if they were its own, and
    /// an append must refuse the loop; then the FAT is restored, and the
    /// next `verify` finds everything as it was.
    fn probeChain(s: *Sim, r: std.Random, loop: bool) !void {
        const E = disk_fat.Error;
        const disk = s.disk.bytes;
        const l = test_disk.Layout.of(disk);
        const cluster_bytes = @as(usize, disk[13]) * test_disk.sector;
        // A file of at least two clusters.
        var it = s.model.files.iterator();
        var k = r.uintLessThan(usize, @max(s.model.files.count(), 1));
        var pick: ?[]const u8 = null;
        var bytes: []const u8 = "";
        while (it.next()) |e| {
            if (e.value_ptr.len > cluster_bytes) {
                pick = e.key_ptr.*;
                bytes = e.value_ptr.*;
                if (k == 0) break;
            }
            k -|= 1;
        }
        const path = pick orelse return;
        const entry = s.disk.vol.open(path) catch |e| return s.fault(@errorName(e));
        const first: usize = entry.first_cluster;
        const second: usize = l.get(disk, 0, first);
        const at: usize = if (loop) second else first;
        const width: usize = if (l.kind == .fat32) 4 else 2;
        var saved: [2]u32 = undefined;
        var cached_saved: u32 = 0;
        const raw = struct {
            fn get(b: []const u8, w: usize) u32 {
                return if (w == 4) std.mem.readInt(u32, b[0..4], .little) else std.mem.readInt(u16, b[0..2], .little);
            }
            fn set(b: []u8, w: usize, v: u32) void {
                if (w == 4) std.mem.writeInt(u32, b[0..4], v, .little) else std.mem.writeInt(u16, b[0..2], @intCast(v), .little);
            }
        };
        const to: u32 = if (loop) @intCast(first) else 1;
        for (0..2) |copy| {
            const off = l.fat_start + copy * l.fat_bytes + at * width;
            saved[copy] = raw.get(disk[off..], width);
            raw.set(disk[off..], width, (saved[copy] & ~@as(u32, if (width == 4) 0x0FFF_FFFF else 0xFFFF)) | to);
        }
        if (s.disk.fat_cache) |c| {
            cached_saved = raw.get(c[at * width ..], width);
            raw.set(c[at * width ..], width, (cached_saved & ~@as(u32, if (width == 4) 0x0FFF_FFFF else 0xFFFF)) | to);
        }
        defer {
            for (0..2) |copy| raw.set(disk[l.fat_start + copy * l.fat_bytes + at * width ..], width, saved[copy]);
            if (s.disk.fat_cache) |c| raw.set(c[at * width ..], width, cached_saved);
        }
        if (s.disk.read(path)) |got| {
            defer s.gpa.free(got);
            if (!loop) return s.fault("a file whose chain leads outside the data read without an error");
            if (!std.mem.eql(u8, got, bytes)) props.reachable(@src(), "fat_sim: a file whose chain loops reads as other bytes, without an error", null);
        } else |e| {
            if (e != E.BadChain) return s.fault(@errorName(e));
            if (loop) props.reachable(@src(), "fat_sim: a file whose chain loops is refused on read", null);
        }
        if (loop) {
            if (s.disk.vol.writeInto(path, @intCast(bytes.len), "never")) return s.fault("an append to a file whose chain loops succeeded") else |e| if (e != E.BadChain) return s.fault(@errorName(e));
        }
    }

    /// **A VOLUME REFUSING WRITES** (metal-vmm QUEUE 188.2), as a mount whose
    /// weighing of apart copies failed leaves it: every kind of write is
    /// `WritesRefused`, before a sector goes to the disk; reads go on; and a
    /// weighing that succeeds takes writes again. `verify` then finds the
    /// volume as the model has it, so nothing of a refused write was kept.
    fn probeRefusing(s: *Sim, r: std.Random) !void {
        const vol = &s.disk.vol;
        const E = disk_fat.Error;
        var buf: [300]u8 = undefined;
        var buf2: [300]u8 = undefined;
        vol.writes = .refused;
        const writes = s.disk.blk.writes;
        const dir = s.someDir(r);
        const fresh = join(dir orelse "", "refused", &buf);
        const Refused = struct {
            fn is(sim: *Sim, got: anytype, what: []const u8) !void {
                if (got) |_| return sim.fault(what) else |e| if (e != E.WritesRefused) return sim.fault(@errorName(e));
            }
        };
        try Refused.is(s, vol.writeFile(fresh, "never"), "a write to a volume refusing writes succeeded");
        try Refused.is(s, vol.makePath(fresh), "a directory made on a volume refusing writes");
        if (s.someFile(r)) |f| {
            try Refused.is(s, vol.writeFile(f.path, "never"), "an overwrite on a volume refusing writes succeeded");
            try Refused.is(s, vol.writeInto(f.path, @intCast(f.bytes.len), "never"), "an append on a volume refusing writes succeeded");
            try Refused.is(s, vol.remove(f.path), "a remove on a volume refusing writes succeeded");
            try Refused.is(s, vol.rename(f.path, join(dir orelse "", "renamed", &buf2)), "a rename on a volume refusing writes succeeded");
            const got = s.disk.read(f.path) catch |e| return s.fault(@errorName(e));
            defer s.gpa.free(got);
            if (!std.mem.eql(u8, got, f.bytes)) return s.fault("a volume refusing writes reads a file as other bytes");
        }
        if (dir) |d| try Refused.is(s, vol.removeTree(d), "a tree removed on a volume refusing writes");
        if (s.disk.blk.writes != writes) return s.fault("a volume refusing writes wrote to the disk");
        props.reachable(@src(), "fat_sim: a volume refusing writes refuses each kind, and writes nothing", null);
        if (s.disk.check_room) |room| {
            const m = vol.reweigh(room) catch |e| return s.fault(@errorName(e));
            if (m.found == .unweighed or vol.writes == .refused) return s.fault("a weighing on a disk that answers left the volume refusing writes");
            props.reachable(@src(), "fat_sim: a volume refusing writes is weighed again, and takes writes", null);
        } else vol.writes = .taken; // a FAT on disk is never weighed, so never refused
    }

    /// A file the model holds, by the probe's dice, or none.
    fn someFile(s: *Sim, r: std.Random) ?struct { path: []const u8, bytes: []const u8 } {
        const n = s.model.files.count();
        if (n == 0) return null;
        var k = r.uintLessThan(usize, n);
        var it = s.model.files.iterator();
        while (it.next()) |e| : (k -|= 1) if (k == 0) return .{ .path = e.key_ptr.*, .bytes = e.value_ptr.* };
        return null;
    }

    /// A directory the model holds, by the probe's dice, or none.
    fn someDir(s: *Sim, r: std.Random) ?[]const u8 {
        const n = s.model.dirs.count();
        if (n == 0) return null;
        var k = r.uintLessThan(usize, n);
        var it = s.model.dirs.keyIterator();
        while (it.next()) |d| : (k -|= 1) if (k == 0) return d.*;
        return null;
    }

    /// After an operation that found no room: `path` holds one of the two
    /// states it may (`before`, or `after` if the operation went through), and
    /// the model follows what the disk says.
    fn settle(s: *Sim, path: []const u8, before: ?[]const u8, after: ?[]const u8) !void {
        const got = s.disk.read(path) catch |e| switch (e) {
            disk_fat.Error.NotFound => {
                // Absent only where there was no file: a write over one is
                // old or new, never gone (essay kernel-facts #1).
                if (before != null) return s.fault("an operation that found no room lost the file it was writing over");
                s.model.dropFile(path);
                return;
            },
            else => return s.fault(@errorName(e)),
        };
        defer s.gpa.free(got);
        const ok = (before != null and std.mem.eql(u8, got, before.?)) or (after != null and std.mem.eql(u8, got, after.?));
        if (!ok) return s.fault("an operation that found no room left a file that is neither its old self nor its new one");
        try s.model.setFile(path, got);
        try s.model.addParents(path);
    }

    /// The model's directories as the disk has them, after a makePath that
    /// found no room part-way.
    fn settleDirs(s: *Sim) !void {
        for (dirs) |d| {
            if (s.disk.vol.open(d)) |e| {
                if (!e.isDirectory()) return s.fault("a directory's path opens as a file");
                try s.model.addDir(d);
            } else |_| {}
        }
    }

    /// **WHAT A STOP LEAVES, JUDGED** (metal-vmm QUEUE 181: a stop was
    /// only checked for its error): the next boot mounts, the check finds
    /// no damage (lost clusters, copies apart and a stale count are what a
    /// stop may leave), and every file the model holds but `stopped` reads
    /// as the model says.
    fn judgeStop(s: *Sim, stopped: []const u8) !void {
        const d = s.disk;
        d.mount(s.cached) catch |e| return s.fault(@errorName(e));
        const r = try d.check();
        for (r.found[0..r.len]) |f| if (f.problem.damage()) {
            std.debug.print("  after the stop: {s} at {s}\n", .{ @tagName(f.problem), f.text() });
            return s.fault("a stop left the volume damaged");
        };
        var it = s.model.files.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, stopped)) continue;
            const got = d.read(e.key_ptr.*) catch return s.fault("after a stop, a file the model holds does not open");
            defer s.gpa.free(got);
            if (!std.mem.eql(u8, got, e.value_ptr.*)) return s.fault("after a stop, a file the model holds reads otherwise");
        }
        props.reachable(@src(), "fat_sim: what a stop leaves is judged", .{ .held = s.cached });
    }

    /// Every file read back on this many operations (and see `touched`).
    const read_all_every = 16;

    fn touch(s: *Sim, path: []const u8) void {
        const n = @min(path.len, s.touched_buf[s.touched_n].len);
        @memcpy(s.touched_buf[s.touched_n][0..n], path[0..n]);
        s.touched[s.touched_n] = s.touched_buf[s.touched_n][0..n];
        s.touched_n += 1;
    }

    /// Whether `path` is one the last operation touched, or under one.
    fn wasTouched(s: *const Sim, path: []const u8) bool {
        return underAny(s.touched[0..s.touched_n], path);
    }

    fn verify(s: *Sim) !void {
        const d = s.disk;
        const r = try d.check();
        if (!r.health.clean()) {
            std.debug.print("  the check found {d} problems, the first {s} at {s}\n", .{ r.health.problems, @tagName(r.found[0].problem), r.found[0].text() });
            return s.fault("the volume does not check clean");
        }
        if (d.vol.free_clusters != d.free()) return s.fault("the kept free count is not the FAT's");
        if ((try d.vol.countFreeAgain()) != d.free()) return s.fault("the volume's recount is not the FAT's");
        if (!d.fatsAgree()) return s.fault("the FAT copies differ");
        const read_all = s.sc.check_every > 1 or s.step % read_all_every == 0 or s.step + 1 == s.sc.ops or s.probed_now;
        var f = s.model.files.iterator();
        while (f.next()) |e| {
            if (!read_all and !s.wasTouched(e.key_ptr.*)) continue;
            const got = d.read(e.key_ptr.*) catch return s.fault("a file the model holds does not open");
            defer s.gpa.free(got);
            if (!std.mem.eql(u8, got, e.value_ptr.*)) return s.fault("a file reads back other bytes than were written");
        }
        var k = s.model.dirs.keyIterator();
        while (k.next()) |dir| {
            const e = d.vol.open(dir.*) catch return s.fault("a directory the model holds does not open");
            if (!e.isDirectory()) return s.fault("a directory the model holds opens as a file");
        }
    }
};

/// Whether `path` is one of `touched`, or a file under one of them.
fn underAny(touched: []const []const u8, path: []const u8) bool {
    for (touched) |t| {
        if (std.mem.eql(u8, path, t)) return true;
        if (path.len > t.len and std.mem.startsWith(u8, path, t) and path[t.len] == '/') return true;
    }
    return false;
}

test "fat_sim: a file is touched when an operation names it, or a directory above it, and only then" {
    const touched = [_][]const u8{ "a/b.txt", "docs" };
    try std.testing.expect(underAny(&touched, "a/b.txt"));
    try std.testing.expect(underAny(&touched, "docs/x/y.md"));
    try std.testing.expect(!underAny(&touched, "a/b.txt2"));
    try std.testing.expect(!underAny(&touched, "docsx/y.md"));
    try std.testing.expect(!underAny(&touched, "a/c.txt"));
    try std.testing.expect(!underAny(&.{}, "a/b.txt"));
}

/// Runs one seed with the FAT on the disk and with it held in memory; an
/// error, with the operation that failed printed, if any oracle fails.
/// The same seed with probes between its operations (`Sim.probe`): what
/// the volume must refuse, from dice of their own. A run whose disk was made
/// to fail is not compared across the two paths: the FAT held in memory asks
/// the disk for less, and so fails at another point.
pub fn runProbeSeed(seed: u64) !void {
    var hashes: [2]u64 = undefined;
    var failed = false;
    for ([_]bool{ false, true }, 0..) |cached, i| {
        var s = try Sim.init(seed, cached);
        s.probes = std.Random.DefaultPrng.init(seed ^ 0x7072_6f62_6573_6661); // "probesfa"
        defer s.deinit();
        try s.run();
        hashes[i] = std.hash.Wyhash.hash(0, s.disk.bytes);
        failed = failed or s.failed_disk;
    }
    if (!failed and hashes[0] != hashes[1]) {
        std.debug.print("fat_sim probe seed {d}: the FAT on the disk and the FAT held in memory left different volumes\n", .{seed});
        return error.SimulationFailed;
    }
}

/// **ONE RUN UNDER A TAPE** (the seed explorer, zig-coverage-sdk's
/// explore.zig): every draw, the probes' too, comes from `tape`, and whether
/// to probe is itself a named choice. As `runSeed`, the story runs twice,
/// with the FAT on the disk and with it held in memory; the second run
/// replays the first's draws (`Tape.twin`) and must draw exactly as many and
/// leave the same volume. Answers the volume's hash, for the replay test.
pub fn runWith(tape: *explore.Tape) !u64 {
    return runWithIn(testing.allocator, testing.io, tape);
}

/// `runWith`, with the allocator and the `Io` a program gives it (the
/// explorer's bench and soak, metal-vmm QUEUE 106): the same run, the same
/// hash.
pub fn runWithIn(gpa: std.mem.Allocator, io: std.Io, tape: *explore.Tape) !u64 {
    const r = tape.random();
    const probed = explore.pick(r, "fat_sim: probes between the operations", .{ .no = 1, .yes = 1 }) == .yes;
    const start = tape.position();
    var hashes: [2]u64 = undefined;
    var failed = false;
    var full: usize = 0;
    {
        var s = try Sim.initWith(gpa, io, tape.seed, r, false);
        s.probes_drawn = probed;
        defer s.deinit();
        try s.run();
        hashes[0] = std.hash.Wyhash.hash(0, s.disk.bytes);
        failed = s.failed_disk;
        full = s.full;
    }
    const end = tape.position();
    var twin = explore.Tape.twin(gpa, tape, start, end, tape.seed ^ 0x7477_696e); // "twin"
    defer twin.deinit();
    {
        var s = try Sim.initWith(gpa, io, tape.seed, twin.random(), true);
        s.probes_drawn = probed;
        defer s.deinit();
        try s.run();
        hashes[1] = std.hash.Wyhash.hash(0, s.disk.bytes);
        failed = failed or s.failed_disk;
    }
    props.sometimes(@src(), full > 0, "fat_sim: some run under a tape finds the volume full", null);
    // A probe that failed the disk ends a run where it struck, and the FAT
    // held in memory meets it later or not at all (`runProbeSeed` excuses
    // the same): only two runs the disk never failed must draw alike.
    if (!failed and (twin.drifted or twin.position() != end - start)) {
        std.debug.print("fat_sim tape {d}: the run with the FAT in memory drew {d} times, the run with it on the disk {d}\n", .{ tape.seed, twin.position(), end - start });
        return error.SimulationFailed;
    }
    if (!failed and hashes[0] != hashes[1]) {
        std.debug.print("fat_sim tape {d}: the FAT on the disk and the FAT held in memory left different volumes\n", .{tape.seed});
        return error.SimulationFailed;
    }
    return hashes[0];
}

pub fn runSeed(seed: u64) !void {
    var hashes: [2]u64 = undefined;
    var full: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |cached, i| {
        var s = try Sim.init(seed, cached);
        defer s.deinit();
        try s.run();
        hashes[i] = std.hash.Wyhash.hash(0, s.disk.bytes);
        full[i] = s.full;
    }
    props.sometimes(@src(), full[0] > 0, "fat_sim: some run finds the volume full", .{ .seed = seed });
    if (hashes[0] != hashes[1]) {
        std.debug.print("fat_sim seed {d}: the FAT on the disk and the FAT held in memory left different volumes\n", .{seed});
        return error.SimulationFailed;
    }
}

/// The seeds `zig build test` runs, plain and with probes. `zig build
/// properties` sweeps 1..20 of both (it was 1..8 here until metal-vmm QUEUE
/// 136: a quick test is a smoke test, and the sweep is the coverage). One
/// since 203(d) (tier 0 on the box's 2 cores).
const seeds = [_]u64{1};

/// **SEEDS THAT ONCE FAILED**, each under what it found. Run by
/// `zig build properties` (src/properties.zig) on every sweep, not by
/// `zig build test`: each is a crowded run of a thousand operations, most of
/// a minute in Debug, and the quick tests stay quick.
pub const regressions = [_]u64{
    // A full FAT16 root: a rename to a new name unlinked `from` before
    // finding room for `to`, and a lost file's chain leaked (disk_fat.zig's
    // rename).
    38,
    // A full FAT16 root: a directory's cluster was taken before room for its
    // entry was found, and leaked on DirectoryFull, by a write making its
    // parents (33) and by a mkdir (45) (disk_fat.zig's makeDirIn).
    33,
    45,
};

// **THE DEEPEST TREE `makePath` MAKES IS ONE `check` AND `removeTree` TAKE**
// (found by a fat_sim probe: makePath once made directories at any depth,
// which `check` called `too_deep` and `removeTree` refused). Fifteen levels
// are made, checked clean and removed; a sixteenth is refused as a name too
// long, and leaves the volume as it was.
test "disk_fat: the deepest tree makePath makes is one check and removeTree take" {
    const d = try test_disk.Disk.make("limit-deep", test_disk.small, false);
    defer d.deinit();
    var path: [64]u8 = undefined;
    @memcpy(path[0..4], "deep");
    var n: usize = 4;
    for (0..14) |_| {
        @memcpy(path[n..][0..2], "/d");
        n += 2;
    }
    _ = try d.vol.makePath(path[0..n]); // fifteen levels
    @memcpy(path[n..][0..2], "/d");
    try testing.expectError(disk_fat.Error.BadName, d.vol.makePath(path[0 .. n + 2]));
    const r = try d.check();
    try testing.expect(r.health.clean());
    try d.vol.removeTree("deep");
    const after = try d.check();
    try testing.expect(after.health.clean());
}

test "the same, with probes of what the volume must refuse, one seed (properties: 1..20)" {
    for (seeds) |seed| try runProbeSeed(seed);
}

test "FAT16 and FAT32 against a random workload, one seed (properties: 1..20), both FAT paths" {
    for (seeds) |seed| try runSeed(seed);
}

/// **A RUN UNDER A TAPE REPLAYS EXACTLY**: the same draws, the same volume,
/// for one seed. `zig build test` runs `replay_seeds`; `zig build properties`
/// runs every seed to 40 at least, as `test` did until it cost 135 s of a
/// Debug run (metal-vmm QUEUE 136).
pub fn replaysExactly(seed: u64) !void {
    var first = explore.Tape.init(testing.allocator, seed);
    defer first.deinit();
    const a = try runWith(&first);
    var again = explore.Tape.branch(testing.allocator, &first, first.position(), seed +% 0x9999, null);
    defer again.deinit();
    const b = try runWith(&again);
    try testing.expectEqual(a, b);
    try testing.expect(!again.drifted);
    try testing.expectEqualSlices(u8, first.bytes.items, again.bytes.items);
    try testing.expectEqual(first.choices.items.len, again.choices.items.len);
}

/// The replays `zig build test` runs (`replaysExactly`).
const replay_seeds = [_]u64{1};

test "a run under a tape replays exactly: the same draws, the same volume" {
    for (replay_seeds) |seed| try replaysExactly(seed);
}
