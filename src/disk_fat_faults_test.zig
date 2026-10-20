//! `disk_fat.zig` when the machine stops, and when the disk fails or lies
//! (QUEUE.md items 79 and 80): every operation the application uses, stopped
//! after each write, and with each request failing or lying once. Apart from
//! `disk_fat_test.zig` so the two run side by side: each is a test of hundreds
//! of runs.

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const options = @import("disk_fat_test_options");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const formats = [_]Shape{ test_disk.small, test_disk.small32 };
/// Every format with its FAT held in memory and without, under
/// `-Dfault-sweep-full` (long.sh). In tier 0 (metal-vmm QUEUE 203(d), the
/// box's 2 cores), FAT32 only as the kernel mounts it, its FAT held: its
/// 35 MB disk made the uncached run the dearest of all, and FAT16 still
/// runs both, so each path is swept on every change.
const Config = struct { shape: Shape, cached: bool };
const configs = blk: {
    var out: [formats.len * 2]Config = undefined;
    var n: usize = 0;
    for (formats) |f| for ([_]bool{ false, true }) |cached| {
        if (!options.fault_sweep_full and f.kind == .fat32 and !cached) continue;
        out[n] = .{ .shape = f, .cached = cached };
        n += 1;
    };
    const len = n;
    var trimmed: [len]Config = undefined;
    @memcpy(&trimmed, out[0..len]);
    break :blk trimmed;
};

/// `test_disk.Disk`, kept as an image when the tests are asked to keep them
/// (-Dfat16-images), for tools/check_fat16_images.sh to judge.
const Disk = struct {
    fn make(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        const d = try test_disk.Disk.make(label, shape, cached);
        d.images_dir = options.images_dir;
        return d;
    }

    /// Not kept: a disk the tests failed or lied to on purpose, run after
    /// run, whose last state may hold the damage that allows (a leak), and
    /// is no one outcome to name. The stop test keeps its images itself,
    /// each named by what the check found.
    fn makeUnkept(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        return test_disk.Disk.make(label, shape, cached);
    }
};

// ---- the machine stopped at every write (QUEUE item 79) ---------------------
//
// Each operation the application uses, stopped after its 1st, 2nd, ... Nth
// write to the disk, for every N until it finishes, on FAT16 and FAT32,
// with the FAT on the disk and held in memory. A stop is the disk refusing
// every request from then on (`fail_after_writes`), which is what a machine
// that stopped leaves: nothing more was written. (A stop between two reads
// leaves what the write before them left.) Then the image is mounted again
// as the next boot would, and must hold one of the outcomes the operation's
// doc names, with nothing worse than leaked clusters and FAT copies apart
// (`allowed`), and must still take a new file.

/// What a path may hold after a stop.
const State = union(enum) { absent, dir, file: []const u8 };

/// On FAT32, FSInfo set as mkfs.fat leaves it: a free count that is right,
/// and a next-free hint, in FSInfo and its backup. test_disk leaves both
/// unknown, which no stale count can be wrong against.
fn setFsInfo(d: *test_disk.Disk) void {
    if (Layout.of(d.bytes).kind != .fat32) return;
    for ([_]usize{ 1, 7 }) |s| {
        const at = s * test_disk.sector;
        std.mem.writeInt(u32, d.bytes[at + 488 ..][0..4], @intCast(d.free()), .little);
        std.mem.writeInt(u32, d.bytes[at + 492 ..][0..4], 2, .little);
    }
}
const Want = struct {
    path: []const u8,
    /// What a stop may leave; the last is what the finished operation left.
    any: []const State,
};
const Stopped = struct {
    name: []const u8,
    setup: *const fn (v: *disk_fat.Volume) anyerror!void,
    run: *const fn (v: *disk_fat.Volume) disk_fat.Error!void,
    want: []const Want,
    /// No two of these paths are both present (a rename's two names).
    one_of: []const []const u8 = &.{},
    /// An append, of `tail`: a stop may leave the file on a chain longer
    /// than its size (writeInto's doc), and the same append made again must
    /// use those clusters, leaving the chain exact.
    appends: ?struct { path: []const u8, tail: []const u8 } = null,
};

const both_cached = [_]bool{ false, true };

/// What a stop may leave besides the outcome itself: clusters nothing holds
/// (fsck reclaims them), and FAT copies apart (every FAT change writes the
/// first copy, then the second). An append may also leave a chain longer
/// than its file (`long`), until the next append.
const allowed = [_]disk_fat.Problem{ .leaked, .fats_differ };
const allowed_append = [_]disk_fat.Problem{ .leaked, .fats_differ, .long };

fn patterned(comptime n: usize, comptime seed: u8) [n]u8 {
    @setEvalBranchQuota(n * 8 + 1000);
    var b: [n]u8 = undefined;
    for (&b, 0..) |*c, i| c.* = @truncate(i *% 31 +% seed);
    return b;
}
const old_rec = patterned(3000, 3);
const new_rec = patterned(1300, 9);
const tail_small = patterned(100, 5);
const tail_big = patterned(2100, 6);
const old_plus_small = old_rec ++ tail_small;
const old_plus_big = old_rec ++ tail_big;
const after_bytes = patterned(2000, 11);

const stopped_ops = [_]Stopped{
    .{
        .name = "write a new file",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                _ = try v.makePath("data/chat");
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeFile("data/chat/a-new-conversation.md", &old_rec);
            }
        }.f,
        .want = &.{.{ .path = "data/chat/a-new-conversation.md", .any = &.{ .absent, .{ .file = &old_rec } } }},
    },
    .{
        .name = "write a new file, making its directories",
        .setup = struct {
            fn f(_: *disk_fat.Volume) !void {}
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeFile("data/games/7/state", &new_rec);
            }
        }.f,
        .want = &.{
            .{ .path = "data", .any = &.{ .absent, .dir } },
            .{ .path = "data/games", .any = &.{ .absent, .dir } },
            .{ .path = "data/games/7", .any = &.{ .absent, .dir } },
            .{ .path = "data/games/7/state", .any = &.{ .absent, .{ .file = &new_rec } } },
        },
    },
    .{
        // **A WRITE OVER A FILE IS OLD OR NEW, NEVER GONE** (essay
        // kernel-facts #1): the new chain is written first, and one sector
        // write points the entry at it.
        .name = "replace a file",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/rec", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeFile("data/rec", &new_rec);
            }
        }.f,
        .want = &.{.{ .path = "data/rec", .any = &.{ .{ .file = &old_rec }, .{ .file = &new_rec } } }},
    },
    .{
        .name = "append inside the last cluster",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/log", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeInto("data/log", old_rec.len, &tail_small);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_small },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = &old_rec }, .{ .file = &old_plus_small } } }},
    },
    .{
        .name = "append past the last cluster",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/log", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeInto("data/log", old_rec.len, &tail_big);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_big },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = &old_rec }, .{ .file = &old_plus_big } } }},
    },
    .{
        .name = "append to an empty file",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/log", "");
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeInto("data/log", 0, &tail_big);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_big },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = "" }, .{ .file = &tail_big } } }},
    },
    .{
        .name = "make a directory",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                _ = try v.makePath("data");
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                _ = try v.makePath("data/sessions");
            }
        }.f,
        .want = &.{.{ .path = "data/sessions", .any = &.{ .absent, .dir } }},
    },
    .{
        .name = "remove a file",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/a-rather-long-name-for-a-file.md", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.remove("data/a-rather-long-name-for-a-file.md");
            }
        }.f,
        .want = &.{.{ .path = "data/a-rather-long-name-for-a-file.md", .any = &.{ .{ .file = &old_rec }, .absent } }},
    },
    .{
        // Its chain freed after the commit a FAT sector at a time (B42's
        // frees): 300 clusters, past one FAT sector on FAT16 and FAT32.
        .name = "remove a file spanning FAT sectors",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/LONG", &leak_long);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.remove("data/LONG");
            }
        }.f,
        .want = &.{.{ .path = "data/LONG", .any = &.{ .{ .file = &leak_long }, .absent } }},
    },
    .{
        .name = "replace a file spanning FAT sectors",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/LONG", &leak_long);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.writeFile("data/LONG", &new_rec);
            }
        }.f,
        .want = &.{.{ .path = "data/LONG", .any = &.{ .{ .file = &leak_long }, .{ .file = &new_rec } } }},
    },
    .{
        // A person deleting their account: their tree goes one entry at a
        // time, so a stop leaves part of it.
        .name = "remove a tree",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/users/7/profile", &new_rec);
                try v.writeFile("data/users/7/games/1/state", &old_rec);
                try v.writeFile("data/users/7/games/2/state", &tail_big);
                try v.writeFile("data/users/8/profile", "someone else");
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.removeTree("data/users/7");
            }
        }.f,
        .want = &.{
            .{ .path = "data/users/7/profile", .any = &.{ .{ .file = &new_rec }, .absent } },
            .{ .path = "data/users/7/games/1/state", .any = &.{ .{ .file = &old_rec }, .absent } },
            .{ .path = "data/users/7/games/2/state", .any = &.{ .{ .file = &tail_big }, .absent } },
            .{ .path = "data/users/7/games", .any = &.{ .dir, .absent } },
            .{ .path = "data/users/7", .any = &.{ .dir, .absent } },
            .{ .path = "data/users/8/profile", .any = &.{.{ .file = "someone else" }} },
        },
    },
    .{
        // The Store's replace: the new bytes under a temporary name, then a
        // rename over the old.
        .name = "rename over a file",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/rec", &old_rec);
                try v.writeFile("data/rec.tmp", &new_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.rename("data/rec.tmp", "data/rec");
            }
        }.f,
        .want = &.{
            .{ .path = "data/rec", .any = &.{ .{ .file = &old_rec }, .{ .file = &new_rec } } },
            .{ .path = "data/rec.tmp", .any = &.{ .{ .file = &new_rec }, .absent } },
        },
        .one_of = &.{ "data/rec.tmp", "data/rec" },
    },
    .{
        // To a name nobody has: a stop between its two steps loses a file
        // nobody had yet (rename's doc).
        .name = "rename to a new name",
        .setup = struct {
            fn f(v: *disk_fat.Volume) !void {
                try v.writeFile("data/rec.tmp", &new_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *disk_fat.Volume) disk_fat.Error!void {
                return v.rename("data/rec.tmp", "data/A-New-Record.md");
            }
        }.f,
        .want = &.{
            .{ .path = "data/rec.tmp", .any = &.{ .{ .file = &new_rec }, .absent } },
            .{ .path = "data/a-new-record.md", .any = &.{ .absent, .{ .file = &new_rec } } },
        },
        .one_of = &.{ "data/rec.tmp", "data/a-new-record.md" },
    },
};

/// The largest file a State holds: `leak_long`, 300 clusters of 512 bytes.
const state_bytes = 160 * 1024;

/// What `path` holds on `d`, as a State; a file's bytes go in `buf`.
fn stateOf(d: *test_disk.Disk, path: []const u8, buf: []u8) !State {
    const e = d.vol.open(path) catch |err| switch (err) {
        disk_fat.Error.NotFound => return .absent,
        else => return err,
    };
    if (e.isDirectory()) return .dir;
    if (e.size > buf.len) return error.TestUnexpectedResult;
    const n = try d.vol.readFile(e, buf);
    return .{ .file = buf[0..n] };
}

fn sameState(a: State, b: State) bool {
    return switch (a) {
        .absent => b == .absent,
        .dir => b == .dir,
        .file => |x| b == .file and std.mem.eql(u8, x, b.file),
    };
}

fn describe(s: State) []const u8 {
    return switch (s) {
        .absent => "absent",
        .dir => "a directory",
        .file => "a file",
    };
}

/// **FOUND WITHIN WHAT WAS COUNTED, EXACTLY WHERE NOTHING IS UNSURE**
/// (metal-vmm 148(b)): what the
/// volume counted its failed operation left on the disk, held to what a
/// check finds at once, on the same mount, before anything else is written.
/// The exact counts (`leaked_clusters`, `orphaned_parts`) are a floor, and
/// with what may be live (`unsure_clusters`, `unsure_parts`) a ceiling;
/// with nothing unsure the two are one number. A leftover found and not
/// counted is one nobody knew of; one counted and not found is slack, where
/// an uncounted one could hide.
fn countedIsFound(d: *test_disk.Disk, op: []const u8, kind: []const u8, when: []const u8, n: u64) !void {
    // **EVERY COPY PAST THE FIRST IS THE HELD FAT, OR COUNTED APART**: the
    // check allows FATs that differ (a stop's), so a copy a batch's write
    // never reached is looked for here.
    if (d.vol.fat) |held| {
        var copy: u32 = 1;
        while (copy < d.vol.num_fats) : (copy += 1) {
            const on_disk = d.bytes[(d.vol.fat_start + copy * d.vol.sectors_per_fat) * test_disk.sector ..][0..held.len];
            if (!test_disk.sameBytes(on_disk, held) and d.vol.fat_copies_failed == 0) {
                std.debug.print("{s} ({s}), {s} {d}: FAT copy {d} is not the held FAT, and nothing counted\n", .{ op, kind, when, n, copy });
                return error.TestUnexpectedResult;
            }
        }
    }
    const r = try d.check();
    const v = &d.vol;
    const clusters_ok = r.health.leaked >= v.leaked_clusters and
        (v.unsized_leaks > 0 or r.health.leaked <= v.leaked_clusters + v.unsure_clusters);
    const parts_ok = r.health.orphaned_parts >= v.orphaned_parts and
        r.health.orphaned_parts <= v.orphaned_parts + v.unsure_parts and
        r.health.orphaned_runs >= v.orphaned_runs and
        r.health.orphaned_runs <= v.orphaned_runs + v.unsure_runs;
    // A `long` finding's count is the chain's length: past the size, it is
    // that less what the size needs.
    var long: u64 = 0;
    const cluster_bytes: u64 = @as(u64, v.sectors_per_cluster) * 512;
    for (r.found[0..r.len]) |f| {
        if (f.problem != .long) continue;
        const entry = try v.open(f.text()[1..]);
        long += f.count - (entry.size + cluster_bytes - 1) / cluster_bytes;
    }
    const long_ok = long >= v.long_clusters and long <= v.long_clusters + v.unsure_long;
    // A fragment fsck.fat would leave: never, whatever failed (152).
    const no_fragments = r.health.lfn_fragments == 0;
    if (clusters_ok and parts_ok and long_ok and no_fragments) return;
    std.debug.print("{s} ({s}), {s} {d}: counted {d} clusters leaked (+{d} unsure, {d} unsized), {d} long-name parts orphaned (+{d} unsure) in {d} runs (+{d} unsure) and {d} clusters long (+{d} unsure); the check found {d}, {d} in {d} runs (and {d} parts in fragments) and {d}\n", .{ op, kind, when, n, v.leaked_clusters, v.unsure_clusters, v.unsized_leaks, v.orphaned_parts, v.unsure_parts, v.orphaned_runs, v.unsure_runs, v.long_clusters, v.unsure_long, r.health.leaked, r.health.orphaned_parts, r.health.orphaned_runs, r.health.lfn_fragments, long });
    return error.TestUnexpectedResult;
}

/// The report holds only what `allowed` names.
fn onlyAllowed(r: *const test_disk.Report, these: []const disk_fat.Problem, op: []const u8, kind: []const u8, when: []const u8, n: u64) !void {
    for (r.found[0..r.len]) |f| {
        if (std.mem.indexOfScalar(disk_fat.Problem, these, f.problem) == null) {
            std.debug.print("{s} ({s}), {s} {d}: {s} at {s}\n", .{ op, kind, when, n, @tagName(f.problem), f.text() });
            return error.TestUnexpectedResult;
        }
    }
}

/// **THE REQUESTS A SWEEP STOPS AT** (metal-vmm QUEUE 198.11): the stop
/// after `n` of `total`. Every one under `-Dfault-sweep=full` (long.sh), and
/// where there are few; otherwise, in tier 0, the first `edge` and the last
/// `edge` (an operation's setup and its commit and cleanups) and `middle`
/// spaced evenly between, the same ones every run, so a failure replays.
/// Every stop was ~2 minutes of tier 0 in Debug; the property is the same,
/// over a sample, and long.sh sweeps it whole. 198.12 (tier 0 on 2 cores):
/// 4 and 6, from 6 and 12; four stops at the end still reach the commit,
/// the FAT copy after it and the cleanups of every operation here.
fn nextStop(n: u64, total: u64) u64 {
    const edge = 4;
    const middle = 6;
    if (options.fault_sweep_full or total <= 2 * edge + middle) return n + 1;
    if (n + 1 < edge or n + 1 >= total - edge) return n + 1;
    const stride = (total - 2 * edge + middle - 1) / middle;
    return @min(n + stride, total - edge);
}

test "a sampled sweep stops at every request of a short one, and at a long one's both ends (198.11)" {
    if (options.fault_sweep_full) return error.SkipZigTest;
    var n: u64 = 0;
    var seen: usize = 0;
    while (n < 14) : (n = nextStop(n, 14)) seen += 1;
    try testing.expectEqual(@as(usize, 14), seen);
    var stops: [64]u64 = undefined;
    seen = 0;
    n = 0;
    while (n < 1000) : (n = nextStop(n, 1000)) {
        stops[seen] = n;
        seen += 1;
    }
    try testing.expect(seen <= 4 + 4 + 6 + 1);
    for (0..4) |k| try testing.expectEqual(@as(u64, k), stops[k]);
    for (0..4) |k| try testing.expectEqual(@as(u64, 996 + k), stops[seen - 4 + k]);
}

test "every operation stopped after every write leaves an outcome its doc names, and at worst leaked clusters" {
    var buf: [state_bytes]u8 = undefined;
    for (stopped_ops, 0..) |op, op_index| {
        for (configs) |cfg| {
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            // For the oracle (tools/check_fat16_images.sh): on FAT16 with the
            // FAT on the disk, the image the stop left, the first of each
            // outcome, named by what the check found; an outcome is what each
            // path held and which problems the check found. Every stop's
            // image would be hundreds of 4 MiB files.
            const keeps = cfg.shape.kind == .fat16 and !cfg.cached;
            var outcomes: [32]u64 = undefined;
            var outcomes_len: usize = 0;
            var stop: u64 = 0;
            var finished = false;
            var seen_partial = false;
            // One disk, set up once and put back before each stop, and
            // mounted afresh as a boot would: a disk of its own for every
            // stop was most of this test's time, in page faults.
            var label_buf: [48]u8 = undefined;
            const d = try Disk.make("limit-stopped", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            // The writes the operation makes with no fault: what the stops
            // are sampled over in tier 0 (`nextStop`).
            const writes_whole = blk: {
                try d.mount(cfg.cached);
                const w0 = d.blk.writes;
                op.run(&d.vol) catch {};
                const w = d.blk.writes - w0;
                @memcpy(d.bytes, before);
                break :blk w;
            };
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (!finished) : (stop = nextStop(stop, writes_whole + 1)) {
                try d.restore(&mounted);
                d.label = "limit-stopped";

                d.blk.fail_after_writes = d.blk.writes + stop;
                // Done, it says: and finished, when no cleanup after its
                // commit failed. One that did is done with a leak (metal-vmm
                // QUEUE 131, #3), and the stops go on past it.
                const said_done = if (op.run(&d.vol)) |_| true else |_| false;
                // Nor one whose FAT copy past the first failed: done, with
                // the copies apart until the next mount (#7).
                if (said_done and d.vol.cleanups_failed == 0 and d.vol.fat_copies_failed == 0) finished = true;
                d.blk.fail_after_writes = null;
                if (!finished and d.changedSince(&mounted)) seen_partial = true;

                // The next boot: mounted again as before. The kernel holds
                // the FAT, and copies a stop left apart are brought into line
                // with the first at that mount (cacheFat); that used to
                // refuse the volume, and the machine never booted again.
                try d.mount(cfg.cached);
                var outcome: u64 = 0;
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any, 0..) |st, i| {
                        if (sameState(st, got)) outcome = outcome * 8 + i;
                    }
                    const ok = if (said_done)
                        sameState(w.any[w.any.len - 1], got)
                    else for (w.any) |s| {
                        if (sameState(s, got)) break true;
                    } else false;
                    if (!ok) {
                        std.debug.print("{s} ({s}, FAT {s}), stopped after {d} writes: {s} is {s}, and not one of the outcomes named\n", .{ op.name, kind, if (cfg.cached) "held" else "on disk", stop, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                }
                if (op.one_of.len == 2) {
                    // The new bytes under both names would be two entries on
                    // one chain.
                    var other: [8192]u8 = undefined;
                    const a = try stateOf(d, op.one_of[0], &buf);
                    const b = try stateOf(d, op.one_of[1], &other);
                    if (sameState(a, .{ .file = &new_rec }) and sameState(b, .{ .file = &new_rec })) {
                        std.debug.print("{s} ({s}), stopped after {d} writes: the new bytes under both names\n", .{ op.name, kind, stop });
                        return error.TestUnexpectedResult;
                    }
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "stopped after write", stop);
                // A stop leaves no long-name fragment fsck.fat would leave
                // (152): a name is cleared from its end.
                if (r.health.lfn_fragments != 0) {
                    std.debug.print("{s} ({s}), stopped after {d} writes: {d} long-name parts in fragments\n", .{ op.name, kind, stop, r.health.lfn_fragments });
                    return error.TestUnexpectedResult;
                }
                if (finished) try testing.expect(r.health.clean());

                // The image as the next boot finds it, for the oracle.
                for (r.found[0..r.len]) |f| outcome |= @as(u64, 1) << @intCast(@as(u32, 56) + @backingInt(f.problem));
                if (keeps and d.images_dir.len > 0 and std.mem.indexOfScalar(u64, outcomes[0..outcomes_len], outcome) == null) {
                    outcomes[outcomes_len] = outcome;
                    outcomes_len += 1;
                    const damaged = if (r.health.clean()) "" else "damaged-";
                    d.label = try std.fmt.bufPrint(&label_buf, "{s}stopped-{d:0>2}-{d:0>3}", .{ damaged, op_index, stop });
                    try d.keep();
                    d.label = "limit-stopped";
                }

                // And the volume goes on: a new file is written and read back;
                // an appended file takes the next append, whatever the stop
                // left it as; and nothing is worse than leaked.
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
                if (op.appends) |a| {
                    const was = try d.read(a.path);
                    defer testing.allocator.free(was);
                    try d.vol.writeInto(a.path, @intCast(was.len), a.tail);
                    const want = try std.mem.concat(testing.allocator, u8, &.{ was, a.tail });
                    defer testing.allocator.free(want);
                    try d.expectFile(a.path, want);
                }
                const r2 = try d.check();
                try onlyAllowed(&r2, &allowed, op.name, kind, "stopped after write", stop);
            }
            // The loop did stop it part-way, with something on the disk.
            if (!seen_partial) {
                std.debug.print("{s} ({s}): no stop left a partial write\n", .{ op.name, kind });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ---- the device lies (QUEUE item 80) -----------------------------------------
//
// The same operations, with one request that goes wrong and a machine that
// carries on: it fails (an error the device reports), or it answers OK and
// does not do what it says (a write that lands nothing, a write torn in half,
// a read of other bytes than the disk's).

/// The kept free count, and the FAT if it is held, are the disk's.
fn heldIsDisk(d: *test_disk.Disk, op: []const u8, kind: []const u8, n: u64) !void {
    if (d.vol.free_clusters != d.free()) {
        std.debug.print("{s} ({s}): request {d} failed; the kept free count is {d}, the disk has {d}\n", .{ op, kind, n, d.vol.free_clusters, d.free() });
        return error.TestUnexpectedResult;
    }
    if (d.vol.fat) |held| {
        const l = Layout.of(d.bytes);
        if (!test_disk.sameBytes(held, d.bytes[l.fat_start..][0..held.len])) {
            std.debug.print("{s} ({s}): request {d} failed, and the FAT held in memory is not the disk's\n", .{ op, kind, n });
            return error.TestUnexpectedResult;
        }
    }
}

/// How many requests `op` makes on a fresh disk, from its setup on.
fn requestsOf(op: Stopped, cfg: anytype) !u64 {
    const d = try Disk.makeUnkept("limit-count", cfg.shape, cfg.cached);
    defer d.deinit();
    try op.setup(&d.vol);
    setFsInfo(d);
    try d.mount(cfg.cached);
    const before = d.blk.requests;
    try op.run(&d.vol);
    return d.blk.requests - before;
}

test "a request that fails before a write's commit gives back every cluster it took (metal-vmm QUEUE 131, kernel-facts #6)" {
    // A failure part-way through taking clusters (a FAT read or write, the
    // zeros of a directory's new cluster, the file's own bytes) gave back
    // nothing but on a full volume: every other error leaked what it had
    // taken, and the error said nothing of it. Before the commit nothing
    // points at those clusters, so nothing excuses keeping them. On FAT16,
    // where a new file's last request is its entry's write, the commit:
    // every request before it fails once, in turn.
    const big: [3 * 512 + 100]u8 = @splat('b'); // several clusters on the small shape
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16) continue;
        for ([_]bool{ false, true }) |grows| {
            const d = try Disk.makeUnkept("limit-give-back", cfg.shape, cfg.cached);
            defer d.deinit();
            _ = try d.vol.makePath("data/full");
            if (grows) {
                // Its first cluster full, but for `.` and `..`: the write
                // grows it.
                const slots = d.vol.sectors_per_cluster * (512 / 32) - 2;
                var i: u32 = 0;
                var name: [32]u8 = undefined;
                while (i < slots) : (i += 1) {
                    try d.vol.writeFile(try std.fmt.bufPrint(&name, "data/full/F{d}", .{i}), "x");
                }
            }
            const before = try d.snapshot();
            defer d.drop(before);
            try d.mount(cfg.cached);
            const r0 = d.blk.requests;
            try d.vol.writeFile("data/full/BIG.DAT", &big);
            const total = d.blk.requests - r0;
            var n: u64 = 0;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (n + 1 < total) : (n += 1) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                const result = d.vol.writeFile("data/full/BIG.DAT", &big);
                d.blk.fault = null;
                // Done only when the failure was a FAT copy past the first,
                // which is no failure of the write (#7).
                if ((d.vol.fat_copies_failed != 0) == std.meta.isError(result)) {
                    std.debug.print("a new file{s} (FAT {s}): request {d} of {d} failed; the write {s}, and {d} FAT copy writes failed\n", .{ if (grows) ", growing its directory" else "", if (cfg.cached) "held" else "on disk", n, total, if (std.meta.isError(result)) "failed" else "said done", d.vol.fat_copies_failed });
                    return error.TestUnexpectedResult;
                }
                try d.mount(cfg.cached);
                const r = try d.check();
                if (r.health.leaked != 0) {
                    std.debug.print("a new file{s} (FAT {s}): request {d} of {d} failed, before the commit, and {d} clusters are leaked\n", .{ if (grows) ", growing its directory" else "", if (cfg.cached) "held" else "on disk", n, total, r.health.leaked });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "a request that fails is an error, and the machine carries on with nothing worse than a stop leaves" {
    var buf: [state_bytes]u8 = undefined;
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            // FAT32 with its FAT held, as the kernel holds it; the path with
            // the FAT on the disk is the same code on both, and runs on
            // FAT16. FAT32's disk is 35 MB, and this is a test of every request.
            if (cfg.shape.kind == .fat32 and !cfg.cached) continue;
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-fails", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            // Put back only when something was written since: most failed
            // requests come before any write, and the disk is 35 MB on FAT32.
            var n: u64 = 0;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (n < total) : (n = nextStop(n, total)) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                const result = op.run(&d.vol);
                d.blk.fault = null;
                const said_done = if (result) |_| true else |_| false;
                try countedIsFound(d, op.name, kind, "failed request", n);

                // What the machine holds in memory is still the disk's, at
                // once (a later change to the same FAT sector would write
                // the held one over the disk's and hide it), and after it
                // goes on, on the same mount.
                try heldIsDisk(d, op.name, kind, n);
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
                try heldIsDisk(d, op.name, kind, n);

                // And the next boot finds an outcome the operation names.
                try d.mount(cfg.cached);
                var done = true;
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any) |st| {
                        if (sameState(st, got)) break;
                    } else {
                        std.debug.print("{s} ({s}): request {d} failed; {s} is {s}, not an outcome named\n", .{ op.name, kind, n, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                    if (!sameState(w.any[w.any.len - 1], got)) done = false;
                }
                // **DONE IS SAID OF WHAT IS DONE, AND ONLY OF IT** (metal-vmm
                // QUEUE 131, kernel-facts #3): a request that failed landed
                // nothing, so an operation that answers done must have left
                // its finished outcome (the last one named), and one that
                // left it must answer done. A cleanup after the commit (a
                // chain freed, a long name's parts) that fails is a leak the
                // check reports, not the operation's failure.
                if (said_done != done) {
                    std.debug.print("{s} ({s}, FAT {s}): request {d} of {d} failed; the operation {s}, and its outcome is {s}\n", .{ op.name, kind, if (cfg.cached) "held" else "on disk", n, total, if (said_done) "said it was done" else "said it failed", if (done) "the finished one" else "not the finished one" });
                    return error.TestUnexpectedResult;
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "failed request", n);
            }
        }
    }
}

test "a write that lands and answers failure is an error, and leaves nothing worse than a stop: no rollback once a commit was tried (metal-vmm QUEUE 131)" {
    // A caller cannot tell a refused write that landed from one that did not.
    // Whatever it undoes after trying its commit (the entry that points at
    // what it made) must be safe either way: a cluster freed under an entry
    // that landed is one the next file takes, two files in one cluster.
    var buf: [state_bytes]u8 = undefined;
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            if (cfg.shape.kind == .fat32 and !cfg.cached) continue;
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-lands-fails", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            var n: u64 = 0;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (n < total) : (n = nextStop(n, total)) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails };
                // Its answer is either: a read the fault met is served as
                // it is, since only writes lie.
                op.run(&d.vol) catch {};
                d.blk.fault = null;
                // What the machine holds is the disk's, whatever the write
                // answered: a FAT sector the disk took and called failed is
                // read again, not assumed old (QUEUE 131, #7).
                try heldIsDisk(d, op.name, kind, n);
                try countedIsFound(d, op.name, kind, "write that landed and failed", n);
                try d.mount(cfg.cached);
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any) |st| {
                        if (sameState(st, got)) break;
                    } else {
                        std.debug.print("{s} ({s}): request {d} landed and failed; {s} is {s}, not an outcome named\n", .{ op.name, kind, n, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "write that landed and failed", n);
                // And it still takes a new file.
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
            }
        }
    }
}

test "a write that lands and answers failure, and the read after it fails too, leaves nothing worse than a stop, on the same mount and the next (metal-vmm QUEUE 134)" {
    // The read-back that tells what a failed FAT write left can fail as
    // well, its buffer filled with whatever a device left in it. The held
    // FAT must not take that in, nor a cluster be freed on a read-back that
    // said nothing: the machine goes on writing on this mount, and what it
    // writes next into the same FAT sector reaches every copy.
    var buf: [state_bytes]u8 = undefined;
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            if (cfg.shape.kind == .fat32) continue; // the same code; FAT32's disk is 35 MB
            const kind = "FAT16";
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-lands-fails-twice", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            var n: u64 = 0;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (n < total) : (n = nextStop(n, total)) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails, .then_fail = 1, .seed = @truncate(n) };
                op.run(&d.vol) catch {};
                d.blk.fault = null;
                try countedIsFound(d, op.name, kind, "write that landed and failed, and the next request failed", n);
                // The machine goes on, on the same mount: a new file, near
                // where the operation took its clusters.
                d.vol.writeFile("data/after", &after_bytes) catch {};
                try d.mount(cfg.cached);
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any) |st| {
                        if (sameState(st, got)) break;
                    } else {
                        std.debug.print("{s} ({s}): request {d} landed and failed, and the next failed; {s} is {s}, not an outcome named\n", .{ op.name, kind, n, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "write that landed and failed, and the next request failed", n);
            }
        }
    }
}

test "a write that lands and answers failure (or fails) to a held FAT sector, its read-back and the write again failing too: a batch freed is counted may be live (B42's frees)" {
    // A batch's refused write whose read-back fails is unknown, and the
    // first copy is written again once; where that fails too, the disk
    // holds the batch freed or not, and the count must say so.
    for (stopped_ops) |op| {
        if (std.mem.indexOf(u8, op.name, "spanning FAT sectors") == null) continue;
        // FAT16 and FAT32, each with its FAT held.
        for ([_]@FieldType(@import("virtio_blk.zig").Block.Fault, "kind"){ .fails, .lands_and_fails }) |fault| for (formats) |shape| {
            // Each format with its FAT held, the one that holds it.
            const cfg: Config = .{ .shape = shape, .cached = true };
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-held-twice", cfg.shape, true);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            var unsure: u64 = 0;
            var n: u64 = 0;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(true);
            defer d.dropMounted(&mounted);
            while (n < total) : (n = nextStop(n, total)) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = fault, .then_fail = 2, .seed = @truncate(n) };
                op.run(&d.vol) catch {};
                d.blk.fault = null;
                if (d.vol.unsure_clusters > 1) unsure += 1;
                try countedIsFound(d, op.name, @tagName(fault), "a held FAT sector's write failed, then its read-back and its write again", n);
                // **AND AS THE DISK HAS IT**: the check above walks the held
                // FAT; fsck.fat, and the next boot, read the disk's first
                // copy, which the write again did not reach.
                const exact = d.vol.leaked_clusters;
                const most = exact + d.vol.unsure_clusters;
                const unsized = d.vol.unsized_leaks;
                try d.mount(false);
                const r = try d.check();
                if (r.health.leaked < exact or (unsized == 0 and r.health.leaked > most)) {
                    std.debug.print("{s} ({t}, then 2 failed): request {d}; the disk's first FAT copy leaks {d} clusters, counted {d} to {d}\n", .{ op.name, fault, n, r.health.leaked, exact, most });
                    return error.TestUnexpectedResult;
                }
            }
            // Not vacuous: a batch's write again failed, and was counted.
            try testing.expect(unsure > 0);
        };
    }
}

test "a write that lands and answers failure, its read-back failing too, while a directory grows: no cluster freed that the disk links (metal-vmm QUEUE 134(b))" {
    // grow's link (the directory's last cluster pointing at the fresh one)
    // may land and answer failure, and the read that would say so fail too.
    // Taken for "not linked", the fresh cluster was given back while the
    // disk links it: the next allocation takes it, in two chains at once.
    const big: [3 * 512 + 100]u8 = @splat('b');
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16) continue;
        const d = try Disk.makeUnkept("limit-grow-twice", cfg.shape, cfg.cached);
        defer d.deinit();
        _ = try d.vol.makePath("data/full");
        const slots = d.vol.sectors_per_cluster * (512 / 32) - 2;
        var i: u32 = 0;
        var name: [32]u8 = undefined;
        while (i < slots) : (i += 1) try d.vol.writeFile(try std.fmt.bufPrint(&name, "data/full/F{d}", .{i}), "x");
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(cfg.cached);
        const r0 = d.blk.requests;
        try d.vol.writeFile("data/full/BIG.DAT", &big);
        const total = d.blk.requests - r0;
        var n: u64 = 0;
        @memcpy(d.bytes, before);
        var mounted = try d.mountSaved(cfg.cached);
        defer d.dropMounted(&mounted);
        while (n < total) : (n = nextStop(n, total)) {
            try d.restore(&mounted);
            d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails, .then_fail = 1, .seed = @truncate(n) };
            d.vol.writeFile("data/full/BIG.DAT", &big) catch {};
            d.blk.fault = null;
            try countedIsFound(d, "a new file, growing its directory", "FAT16", "write that landed and failed, and the next request failed", n);
            // On, on the same mount: what it takes next must be free.
            d.vol.writeFile("data/after", &after_bytes) catch {};
            try d.mount(cfg.cached);
            const r = try d.check();
            try onlyAllowed(&r, &allowed, "a new file, growing its directory", "FAT16", "write that landed and failed, and the next request failed", n);
        }
    }
}

test "a write that lands and answers failure, as an allocation links its chain, frees nothing twice (metal-vmm QUEUE 134(c))" {
    // The link (the cluster before pointing at the next) lands and answers
    // failure: the next cluster was given back on its own, and then the
    // errdefer freed the chain the disk now links it into, freeing it again.
    // The disk ended right; "every cluster freed was in use" broke falsely.
    const coverage = @import("coverage");
    const big: [6 * 512 + 100]u8 = @splat('b');
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16) continue;
        const d = try Disk.makeUnkept("limit-link-lands", cfg.shape, cfg.cached);
        defer d.deinit();
        _ = try d.vol.makePath("data");
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(cfg.cached);
        const r0 = d.blk.requests;
        try d.vol.writeFile("data/BIG.DAT", &big);
        const total = d.blk.requests - r0;
        var n: u64 = 0;
        @memcpy(d.bytes, before);
        var mounted = try d.mountSaved(cfg.cached);
        defer d.dropMounted(&mounted);
        while (n < total) : (n = nextStop(n, total)) {
            try d.restore(&mounted);
            coverage.reset();
            d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails };
            d.vol.writeFile("data/BIG.DAT", &big) catch {};
            d.blk.fault = null;
            try countedIsFound(d, "a new file", "FAT16", "write that landed and failed", n);
            var broke = false;
            var it = coverage.catalog();
            while (it.next()) |site| {
                if (site.broken()) {
                    std.debug.print("  broken: {s}\n", .{std.mem.span(site.message)});
                    broke = true;
                }
            }
            if (broke) {
                std.debug.print("a new file (FAT {s}): request {d} of {d} landed and failed, and a property broke\n", .{ if (cfg.cached) "held" else "on disk", n, total });
                return error.TestUnexpectedResult;
            }
            try d.mount(cfg.cached);
            const r = try d.check();
            try onlyAllowed(&r, &allowed, "a new file", "FAT16", "write that landed and failed", n);
        }
    }
}

test "a write that lands and answers failure, its read-back rotten: the kept free count is moved for every entry the read-back changes (metal-vmm QUEUE 134(h))" {
    // The held sector is replaced whole by the read-back of a failed write.
    // Where that differs from what was held in more than the one entry
    // written (rot on the read-back; a weighing that trusted the second copy
    // and whose repair was refused), the count moved for the one entry
    // only, and was wrong after.
    const big: [3 * 512 + 100]u8 = @splat('b');
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16 or !cfg.cached) continue;
        const d = try Disk.makeUnkept("limit-read-back-rots", cfg.shape, cfg.cached);
        defer d.deinit();
        _ = try d.vol.makePath("data");
        const before = try d.snapshot();
        defer d.drop(before);
        try d.mount(cfg.cached);
        const r0 = d.blk.requests;
        try d.vol.writeFile("data/BIG.DAT", &big);
        const total = d.blk.requests - r0;
        var n: u64 = 0;
        @memcpy(d.bytes, before);
        var mounted = try d.mountSaved(cfg.cached);
        defer d.dropMounted(&mounted);
        while (n < total) : (n = nextStop(n, total)) {
            try d.restore(&mounted);
            d.blk.fault_lba = null;
            d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails, .then_garbage = 1, .seed = @truncate(n) };
            d.vol.writeFile("data/BIG.DAT", &big) catch {};
            d.blk.fault = null;
            try countedIsFound(d, "a new file", "FAT16", "write that landed and failed, its read-back rotten", n);
            var held_free: u32 = 0;
            var c: u32 = 2;
            while (c <= d.vol.max_cluster) : (c += 1) {
                if (std.mem.readInt(u16, d.vol.fat.?[c * 2 ..][0..2], .little) == 0) held_free += 1;
            }
            if (held_free != d.vol.free_clusters) {
                std.debug.print("request {d} of {d} landed and failed, its read-back rotten: the kept free count is {d}, the held FAT's {d}\n", .{ n, total, d.vol.free_clusters, held_free });
                return error.TestUnexpectedResult;
            }
            // **AND THE ROT IS NOT TAKEN IN** (QUEUE 138(a)): the held FAT
            // is the authority for every entry but the one in doubt. The
            // machine goes on, on this mount, and the next boot finds
            // nothing worse than a stop leaves.
            d.vol.writeFile("data/after", &after_bytes) catch {};
            try d.mount(cfg.cached);
            const r = try d.check();
            try onlyAllowed(&r, &allowed, "a new file", "FAT16", "write that landed and failed, its read-back rotten", n);
        }
    }
}

test "a write that lands and answers failure, with the FAT on the disk and its read-backs rotten: nothing is given back on a read-back that is not exact (metal-vmm QUEUE 138(b))" {
    // A cluster was given back when a read-back said anything but what was
    // hoped; a rotted nonzero one sent freeChain into another file's chain.
    const coverage = @import("coverage");
    const big: [6 * 512 + 100]u8 = @splat('b');
    const d = try Disk.makeUnkept("limit-rot-on-disk", test_disk.small, false);
    defer d.deinit();
    try d.vol.writeFile("data/KEEP.DAT", &big); // another file's chain, nearby
    const before = try d.snapshot();
    defer d.drop(before);
    try d.mount(false);
    const r0 = d.blk.requests;
    try d.vol.writeFile("data/BIG.DAT", &big);
    const total = d.blk.requests - r0;
    var n: u64 = 0;
    @memcpy(d.bytes, before);
    var mounted = try d.mountSaved(false);
    defer d.dropMounted(&mounted);
    while (n < total) : (n = nextStop(n, total)) {
        try d.restore(&mounted);
        coverage.reset();
        d.blk.fault_lba = null;
        d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails, .then_garbage = 2, .seed = @truncate(n *% 7 +% 1) };
        d.vol.writeFile("data/BIG.DAT", &big) catch {};
        d.blk.fault = null;
        try countedIsFound(d, "a new file beside another", "FAT16", "write that landed and failed, its read-backs rotten", n);
        var it = coverage.catalog();
        while (it.next()) |site| if (site.broken()) {
            std.debug.print("request {d} of {d}: broken: {s}\n", .{ n, total, std.mem.span(site.message) });
            return error.TestUnexpectedResult;
        };
        try d.mount(false);
        try d.expectFile("data/KEEP.DAT", &big);
        const r = try d.check();
        try onlyAllowed(&r, &allowed, "a new file beside another", "FAT16", "write that landed and failed, its read-backs rotten", n);
    }
}

test "a disk that lies (a write that lands nothing or half, a read of other bytes) never stops the machine, and the next boot mounts and checks it" {
    const virtio_blk = @import("virtio_blk.zig");
    // What `Volume.check` found across every run, by problem: the boot's
    // disk check is where a lie that damaged the volume is seen.
    var found: [@typeInfo(disk_fat.Problem).@"enum".field_names.len]u32 = @splat(0);
    var runs: u32 = 0;
    for ([_]@FieldType(virtio_blk.Block.Fault, "kind"){ .lands_nothing, .torn, .garbage }) |lie| {
        for (stopped_ops) |op| {
            for (configs) |cfg| {
                if (!cfg.cached) continue; // the FAT held, as the kernel holds it
                // On FAT32, only the read of other bytes, where its wider
                // entries and cluster fields are what is parsed: a write that
                // lies is the same code on both, and FAT32's disk is 35 MB.
                if (cfg.shape.kind == .fat32 and lie != .garbage) continue;
                const total = try requestsOf(op, cfg);
                const d = try Disk.makeUnkept("limit-lies", cfg.shape, cfg.cached);
                defer d.deinit();
                try op.setup(&d.vol);
                setFsInfo(d);
                const before = try d.snapshot();
                defer d.drop(before);
                var n: u64 = 0;
                @memcpy(d.bytes, before);
                var mounted = try d.mountSaved(cfg.cached);
                defer d.dropMounted(&mounted);
                while (n < total) : (n = nextStop(n, total)) {
                    try d.restore(&mounted);
                    d.blk.fault = .{ .at = d.blk.requests + n, .kind = lie, .seed = @truncate(n) };
                    // It returns, whatever it answers: no panic, no loop
                    // that does not end.
                    op.run(&d.vol) catch {};
                    d.blk.fault = null;
                    d.mount(cfg.cached) catch |e| {
                        std.debug.print("{s}, {s}, request {d}: the next boot does not mount: {s}\n", .{ op.name, @tagName(lie), n, @errorName(e) });
                        return error.TestUnexpectedResult;
                    };
                    // Every finding counted: a read of other bytes can leave
                    // more than test_disk.Report keeps.
                    const Count = struct {
                        by: *@TypeOf(found),
                        fn each(c: *@This(), f: disk_fat.Finding) void {
                            c.by[@backingInt(f.problem)] += 1;
                        }
                    };
                    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
                    defer testing.allocator.free(seen);
                    var count = Count{ .by = &found };
                    const writes = d.blk.writes;
                    _ = d.vol.check(seen, &count, Count.each) catch |e| {
                        std.debug.print("{s}, {s}, request {d}: the next boot's check does not run: {s}\n", .{ op.name, @tagName(lie), n, @errorName(e) });
                        return error.TestUnexpectedResult;
                    };
                    try testing.expectEqual(writes, d.blk.writes);
                    runs += 1;
                }
            }
        }
    }
    // Not vacuous: a run for every request of every operation. Fewer since
    // a chain's FAT entries are written a sector at a time, taken (metal-vmm
    // B42: 804 runs, from over 1,000) and freed (596).
    // Sampled in tier 0 (`nextStop`): 535 runs.
    try testing.expect(runs > if (options.fault_sweep_full) 550 else 500);
}

/// One operation whose failure is judged for lost clusters: what it starts
/// from (`setup`) and what it does (`run`).
const LeakOp = struct {
    name: []const u8,
    setup: *const fn (v: *disk_fat.Volume) anyerror!void,
    run: *const fn (v: *disk_fat.Volume) anyerror!void,
};

const leak_first: [600]u8 = @splat('a');
const leak_long: [300 * 512]u8 = @splat(0x4C);
const leak_more: [3 * 512 + 100]u8 = @splat('m');

const leak_ops = [_]LeakOp{
    .{ .name = "a new file", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeFile("data/NEW.DAT", &leak_more);
        }
    }.f },
    .{ .name = "a new directory", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data/sub");
        }
    }.f },
    .{ .name = "an overwrite", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LOG", &leak_first);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeFile("data/LOG", &leak_more);
        }
    }.f },
    .{ .name = "an append", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LOG", &leak_first);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeInto("data/LOG", leak_first.len, &leak_more);
        }
    }.f },
    .{ .name = "an empty file's first write", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/EMPTY", "");
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeInto("data/EMPTY", 0, &leak_more);
        }
    }.f },
    .{ .name = "a rename to a new name", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LOG", &leak_more);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.rename("data/LOG", "data/a longer name.txt");
        }
    }.f },
    .{ .name = "a rename over another file", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LOG", &leak_more);
            try v.writeFile("data/OLD", &leak_first);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.rename("data/LOG", "data/OLD");
        }
    }.f },
    // A chain past one FAT sector (FAT16's 256 entries; 512-byte
    // clusters here): two batches and the link between them (metal-vmm
    // B42), each failing in turn.
    .{ .name = "a file spanning two FAT sectors", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeFile("data/LONG", &leak_long);
        }
    }.f },
    // Its chain freed (after the commit), a FAT sector at a time: two
    // batches, each failing in turn.
    .{ .name = "a remove of a file spanning two FAT sectors", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LONG", &leak_long);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.remove("data/LONG");
        }
    }.f },
    .{ .name = "an overwrite of a file spanning two FAT sectors", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/LONG", &leak_long);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.writeFile("data/LONG", &leak_more);
        }
    }.f },
    .{ .name = "a remove", .setup = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            _ = try v.makePath("data");
            try v.writeFile("data/a longer name.txt", &leak_more);
        }
    }.f, .run = struct {
        fn f(v: *disk_fat.Volume) anyerror!void {
            try v.remove("data/a longer name.txt");
        }
    }.f },
};

test "a request that fails or lies leaves no cluster lost uncounted, its commit included, nor the kept free count wrong uncounted" {
    // Before the commit, what an operation took is given back; a refused
    // commit is read back, and given back if it did not land; after it, a
    // failed cleanup is counted (`cleanups_failed`). So a check after any
    // one failed request finds no leaked cluster that was not counted.
    //
    // **AND THE KEPT FREE COUNT AGREES WITH THE FAT, OR IS COUNTED WRONG**:
    // where a failed write's read-back fails too (`then_fail`), what the
    // write left is not known, and every reader of it must take one
    // verdict; a caller that read the disk again could free nothing while
    // the count said taken.
    const Kind = @FieldType(@import("virtio_blk.zig").Block.Fault, "kind");
    const faults = [_]struct { kind: Kind, then_fail: u8 }{
        .{ .kind = .fails, .then_fail = 0 },
        .{ .kind = .lands_and_fails, .then_fail = 0 },
        .{ .kind = .fails, .then_fail = 1 },
        .{ .kind = .lands_and_fails, .then_fail = 1 },
    };
    for (leak_ops) |op| {
        for (faults) |fault| {
            const kind = fault.kind;
            for (configs) |cfg| {
                if (cfg.shape.kind != .fat16) continue;
                const d = try Disk.makeUnkept("limit-no-lost", cfg.shape, cfg.cached);
                defer d.deinit();
                try op.setup(&d.vol);
                const before = try d.snapshot();
                defer d.drop(before);
                try d.mount(cfg.cached);
                const r0 = d.blk.requests;
                try op.run(&d.vol);
                const total = d.blk.requests - r0;
                var n: u64 = 0;
                @memcpy(d.bytes, before);
                var mounted = try d.mountSaved(cfg.cached);
                defer d.dropMounted(&mounted);
                while (n < total) : (n = nextStop(n, total)) {
                    try d.restore(&mounted);
                    d.blk.fault = .{ .at = d.blk.requests + n, .kind = kind, .then_fail = fault.then_fail };
                    op.run(&d.vol) catch {};
                    d.blk.fault = null;
                    const counted = d.vol.cleanups_failed;
                    // **AND A HELD FAT'S FIRST COPY ON THE DISK IS THE HELD
                    // FAT, OR COUNTED APART**: an unchecked mount mirrors it
                    // over the others, so one left behind comes back.
                    if (d.vol.fat) |held| {
                        const copy0 = d.bytes[d.vol.fat_start * test_disk.sector ..][0..held.len];
                        if (!std.mem.eql(u8, copy0, held) and d.vol.fat_copies_failed == 0) {
                            std.debug.print("{s} ({t}, then {d} failed): request {d} of {d}; the first FAT copy on the disk is not the held FAT, and nothing counted\n", .{ op.name, kind, fault.then_fail, n, total });
                            return error.TestUnexpectedResult;
                        }
                    }
                    const fat_free = (try d.vol.derive()).free;
                    if (fat_free != d.vol.free_clusters and counted == 0) {
                        std.debug.print("{s} (FAT {s}, {t}, then {d} failed): request {d} of {d}; the kept free count is {d}, the FAT's {d}, and nothing counted\n", .{ op.name, if (cfg.cached) "held" else "on disk", kind, fault.then_fail, n, total, d.vol.free_clusters, fat_free });
                        return error.TestUnexpectedResult;
                    }
                    try d.mount(cfg.cached);
                    const r = try d.check();
                    if (r.health.leaked > 0 and counted == 0) {
                        std.debug.print("{s} (FAT {s}, {t}, then {d} failed): request {d} of {d}; {d} clusters lost and none counted\n", .{ op.name, if (cfg.cached) "held" else "on disk", kind, fault.then_fail, n, total, r.health.leaked });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }
}

test "a disk that lies to a rename's second read of the directory, its new entry then refused: nothing is written outside the directory (145's review)" {
    // The Lister finds `from` and the unlink's walk, reading the directory
    // again, may not: a read that lies the second time. Then nothing was
    // unlinked, and an undo of the new entry's refusal must not write where
    // an unfilled `Unlinked` points: sector 0, the boot sector.
    for (configs) |cfg| {
        const d = try Disk.makeUnkept("rename-miss", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.mount(cfg.cached);
        _ = try d.vol.makePath("data");
        try d.vol.writeFile("data/A-Long-Record.md", "kept");
        const before = try d.snapshot();
        defer d.drop(before);
        var n: u64 = 0;
        while (n < 24) : (n += 1) {
            var m: u64 = 1;
            @memcpy(d.bytes, before);
            var mounted = try d.mountSaved(cfg.cached);
            defer d.dropMounted(&mounted);
            while (m < 24) : (m += 1) {
                try d.restore(&mounted);
                const base = d.blk.requests;
                d.blk.fault = .{ .at = base + n, .kind = .garbage, .seed = 0 };
                d.blk.second = .{ .at = base + n + m, .kind = .fails };
                d.vol.rename("data/A-Long-Record.md", "data/Another-Name.md") catch {};
                d.blk.fault = null;
                d.blk.second = null;
                testing.expectEqualSlices(u8, before[0..512], d.bytes[0..512]) catch |e| {
                    std.debug.print("{s}{s}, garbage at request {d}, a write refused {d} after: the boot sector was written\n", .{ @tagName(cfg.shape.kind), if (cfg.cached) " cached" else "", n, m });
                    return e;
                };
            }
        }
    }
}

test "a write that lands and answers failure as a cleanup gives back what a failed request took: what it left is counted exactly (metal-vmm 148(b))" {
    // A request fails, and the cleanup after it (a give-back, a part's
    // clearing, a chain freed) meets a write the disk took and called failed.
    // The cleanup's own verdict decides what it left, not its answer.
    const before_arms = [_]u64{
        passesOf("fat: clusters taken before a failure could not be given back, and are left a leak"),
        passesOf("fat: a long-name part could not be cleared after a commit, and is left orphaned"),
        passesOf("fat: a chain freed after the commit could not be freed whole, and the rest is left a leak"),
    };
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            if (cfg.shape.kind == .fat32) continue; // the same code; FAT32's disk is 35 MB
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-cleanup-lands", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try d.snapshot();
            defer d.drop(before);
            var n: u64 = 0;
            while (n < total) : (n = nextStop(n, total)) {
                var m: u64 = n + 1;
                @memcpy(d.bytes, before);
                var mounted = try d.mountSaved(cfg.cached);
                defer d.dropMounted(&mounted);
                while (m < n + 8) : (m += 1) {
                    try d.restore(&mounted);
                    const at = d.blk.requests;
                    d.blk.fault = .{ .at = at + n, .kind = .fails };
                    d.blk.second = .{ .at = at + m, .kind = .lands_and_fails };
                    op.run(&d.vol) catch {};
                    d.blk.fault = null;
                    d.blk.second = null;
                    try countedIsFound(d, op.name, if (cfg.cached) "FAT16, held" else "FAT16", "write that landed and failed, a cleanup's after a failed request", n * 8 + (m - n));
                }
            }
        }
    }
    // The premise: the second fault met each cleanup it names, by the
    // cleanup arm's own site (the box's review of 148): a give-back left
    // short, a part left orphaned, a chain freed after its commit left.
    for ([_][]const u8{
        "fat: clusters taken before a failure could not be given back, and are left a leak",
        "fat: a long-name part could not be cleared after a commit, and is left orphaned",
        "fat: a chain freed after the commit could not be freed whole, and the rest is left a leak",
    }, before_arms) |arm, was| {
        if (passesOf(arm) > was) continue;
        std.debug.print("the cleanup arm \"{s}\" was never reached\n", .{arm});
        return error.TestUnexpectedResult;
    }
}

/// How often the sites with `message` were reached, in all.
fn passesOf(message: []const u8) u64 {
    const coverage = @import("coverage");
    var n: u64 = 0;
    var it = coverage.catalog();
    while (it.next()) |site| {
        if (std.mem.eql(u8, std.mem.span(site.message), message)) n += site.passes;
    }
    return n;
}

test "a write that lands and answers failure, leaving long-name parts orphaned, and the next write over them: the count follows what is on the disk (metal-vmm 148(b))" {
    // A new file's long name whose short entry does not land leaves its
    // parts orphaned and counted; the next entry written into that run
    // tombstones them first, and they are counted no more.
    for (both_cached) |cached| {
        const d = try Disk.makeUnkept("orphans-reused", test_disk.small, cached);
        defer d.deinit();
        var body: [700]u8 = undefined;
        @memset(&body, 'o');
        const before = try d.snapshot();
        defer d.drop(before);
        var left: u32 = 0;
        var reused: u32 = 0;
        const kind = if (cached) "FAT16, held" else "FAT16";
        var n: u64 = 0;
        @memcpy(d.bytes, before);
        var mounted = try d.mountSaved(cached);
        defer d.dropMounted(&mounted);
        while (n < 24) : (n += 1) {
            try d.restore(&mounted);
            d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
            d.vol.writeFile("data/A Long Name For A First File.txt", &body) catch {};
            d.blk.fault = null;
            const orphans = d.vol.orphaned_parts;
            if (orphans > 0) left += 1;
            try countedIsFound(d, "a new file", kind, "failed request", n);
            // The next file takes the same run, its orphans tombstoned first.
            d.vol.writeFile("data/A Long Name For The Next File.txt", &body) catch {};
            if (orphans > 0 and d.vol.orphaned_parts == 0) reused += 1;
            try countedIsFound(d, "the next new file", kind, "after a failed request", n);
        }
        // The premises: some failure left parts orphaned, and the next write
        // took their run.
        try testing.expect(left > 0);
        try testing.expect(reused > 0);
    }
}

test "a write that lands and answers failure as a counted orphan run is tombstoned: the count follows what is on the disk (metal-vmm 154(b)'s review)" {
    // An orphan run counted, as a failed new file leaves one; then the next
    // file, which tombstones it first, its every request in turn landing
    // and answering failure, its read-back exact or failing too (unknown).
    var refused_landed: u32 = 0;
    for (both_cached) |cached| {
        for ([_]u8{ 0, 1 }) |then_fail| {
            const d = try Disk.makeUnkept("orphans-tombstone-lies", test_disk.small, cached);
            defer d.deinit();
            var body: [700]u8 = undefined;
            @memset(&body, 'o');
            const kind = if (cached) "FAT16, held" else "FAT16";
            const pristine = try d.snapshot();
            defer d.drop(pristine);
            // The first failure that leaves orphans.
            var n: u64 = 0;
            @memcpy(d.bytes, pristine);
            var mounted = try d.mountSaved(cached);
            defer d.dropMounted(&mounted);
            while (n < 24) : (n += 1) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                d.vol.writeFile("data/A Long Name For A First File.txt", &body) catch {};
                d.blk.fault = null;
                if (d.vol.orphaned_parts > 0) break;
            } else return error.NoOrphans;
            // **THE PREMISE, EXACT** (the box's review): each request in turn
            // both lands and answers failure, and fails landing nothing. The
            // first leaves fewer parts counted than the second only where the
            // request was a tombstone the read-back found landed: "B" writes
            // no long-name parts of its own.
            var m: u64 = 0;
            while (m < 40) : (m += 1) {
                var after: [2]u64 = undefined;
                for ([_]@FieldType(@import("virtio_blk.zig").Block.Fault, "kind"){ .lands_and_fails, .fails }, 0..) |fault, w| {
                    try d.restore(&mounted);
                    d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                    d.vol.writeFile("data/A Long Name For A First File.txt", &body) catch {};
                    d.blk.fault = .{ .at = d.blk.requests + m, .kind = fault, .then_fail = then_fail, .seed = @truncate(m) };
                    d.vol.writeFile("data/B", "bee") catch {};
                    d.blk.fault = null;
                    after[w] = d.vol.orphaned_parts;
                    try countedIsFound(d, "a short name over a counted orphan run", kind, @tagName(fault), m);
                }
                if (after[0] < after[1]) refused_landed += 1;
            }
            // A failed FAT write leaves its copies apart: the disk goes back
            // as it began, for the check its teardown runs.
            @memcpy(d.bytes, pristine);
            try d.mount(cached);
        }
    }
    // Across the disks and read-backs: some refused tombstone was found
    // landed and taken off its count (on this disk, with the FAT held and
    // the read-back failing too, none is; the other three find some).
    try testing.expect(refused_landed > 0);
}

test "a disk that lies to any one request of an upload-sized write on FAT32 never damages the volume the next boot mounts, a new file or an overwrite (metal-vmm QUEUE 181, 188.1)" {
    const virtio_blk = @import("virtio_blk.zig");
    // Six MB: 12,288 clusters, 96 FAT sectors a copy, past what is weighed
    // sector by sector.
    const bytes = try testing.allocator.alloc(u8, 6 << 20);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 13 +% 1);
    const old = try testing.allocator.alloc(u8, 6 << 20);
    defer testing.allocator.free(old);
    for (old, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    var runs: u32 = 0;
    for ([_]bool{ false, true }) |over| {
        var total: u64 = 0;
        {
            const d = try Disk.make("upload-lies-count", test_disk.small32, true);
            defer d.deinit();
            if (over) try d.vol.writeFile("up.bin", old);
            const before = d.blk.requests;
            try d.vol.writeFile("up.bin", bytes);
            total = d.blk.requests - before;
        }
        // One disk, made once and put back before each run (198.12).
        const d = try Disk.makeUnkept("limit-upload-lies", test_disk.small32, true);
        defer d.deinit();
        if (over) try d.vol.writeFile("up.bin", old);
        var mounted = try d.mountSaved(true);
        defer d.dropMounted(&mounted);
        for ([_]@FieldType(virtio_blk.Block.Fault, "kind"){ .lands_nothing, .torn, .torn_tail }) |lie| {
            var n: u64 = 0;
            while (n < total) : (n = nextStop(n, total)) {
                try d.restore(&mounted);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = lie };
                d.vol.writeFile("up.bin", bytes) catch {};
                d.blk.fault = null;
                try d.mount(true);
                const r = try d.check();
                for (r.found[0..r.len]) |f| if (f.problem.damage()) {
                    std.debug.print("{s}, {s} at request {d} of {d}: {s} at '{s}'\n", .{ if (over) "an overwrite" else "a new file", @tagName(lie), n, total, @tagName(f.problem), f.text() });
                    return error.TestUnexpectedResult;
                };
                runs += 1;
            }
        }
    }
    try testing.expect(runs > 20);
}
