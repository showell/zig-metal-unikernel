//! disk_fat_check: the volume checked as fsck would. Every chain walked from
//! every directory, each problem found reported (`Finding`), whole or a slice at
//! a time (`CheckRun`) (split from disk_fat.zig by metal-vmm QUEUE 173).

const std = @import("std");
const builtin = @import("builtin");
const props = @import("coverage");
const dirent = @import("disk_fat_dirent.zig");
const dirent_size = dirent.dirent_size;
const attr_volume_label = dirent.attr_volume_label;
const attr_long_name = dirent.attr_long_name;
const Cluster = dirent.Cluster;
const le32 = dirent.le32;
const max_name = dirent.max_name;
const Entry = dirent.Entry;
const shortChecksum = dirent.shortChecksum;
const LongName = dirent.LongName;
const eqlBytes = dirent.eqlBytes;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const run_sectors = Volume.run_sectors;
const sector_size = disk_fat.sector_size;
const max_tree_depth = Volume.max_tree_depth;
const Health = disk_fat.Health;
const Error = disk_fat.Error;
const Problem = disk_fat.Problem;
const Finding = disk_fat.Finding;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

// ---- the boot-time check -------------------------------------------

/// How many bytes `check` needs to borrow: a bit for every cluster.
pub fn checkBytes(self: *const Volume) usize {
    return @as(usize, self.max_cluster) / 8 + 1;
}

/// **THE BOOT-TIME CHECK: WHAT IS WRONG WITH THIS VOLUME, SAID AND NEVER
/// MENDED.** It walks the tree from the root and follows every chain
/// (through the held FAT when there is one), marking each cluster in
/// `seen` (`checkBytes` long). Then it finds clusters in use that nothing
/// holds, by the held FAT when there is one, and compares the copies on
/// the disk. Each thing wrong goes to `each` as a `Finding`; the answer
/// counts what was walked and the findings.
///
/// **IT WRITES NOTHING.** A repair decides whose data wins, and that
/// belongs to a person running fsck.vfat on a copy, not a machine
/// halfway through booting.
///
/// **THE MARKING ENDS THE WALK.** A chain that reaches a marked cluster
/// has crossed another or looped, and is followed no further, so the walk
/// is at most as long as the volume, and a directory pointing at its own
/// ancestor is reported, not descended into for ever.
///
/// Walked `max_tree_depth` deep; the checker holds a frame (a sector and
/// a long name) for each level, ~13 KB, on the caller's stack.
/// Errors are the disk's (ReadFailed), or `seen` too short (TooBig); a
/// damaged volume is not an error but the answer.
pub fn check(
    self: *Volume,
    seen: []u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), Finding) void,
) Error!Health {
    if (seen.len < self.checkBytes()) {
        props.reachable(@src(), "fat: a check given too little room to mark clusters is refused", null);
        return Error.TooBig;
    }
    return self.checkIn(seen, context, each, std.math.maxInt(u32));
}

/// `check`, its walk `sectors` directory sectors at a time: what a
/// `CheckRun` does, findings and all, for a test to hold to `check`.
pub fn checkInSlicesForTest(
    self: *Volume,
    seen: []u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), Finding) void,
    sectors: u32,
) Error!Health {
    if (seen.len < self.checkBytes()) return Error.TooBig;
    return self.checkIn(seen, context, each, sectors);
}

pub fn checkIn(
    self: *Volume,
    seen: []u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), Finding) void,
    sectors: u32,
) Error!Health {
    const len = self.checkBytes();
    @memset(seen[0..len], 0);
    var c = Checker(@TypeOf(context), each){ .vol = self, .seen = seen[0..len], .context = context };
    try c.walkStart();
    while (!try c.walkSome(sectors)) {}
    try c.fatOnDisk();
    return c.health;
}

/// **THE CHECK, A SLICE AT A TIME** (essay `idle-time-on-metal`): the
/// same walk and the same FAT pass as `check`, cut into steps for the
/// kernel's idle time: the tree `Slice.sectors` directory sectors a step,
/// then the FAT on the disk `Slice.runs` runs a step. It writes nothing.
/// **THE WALK IS SLICED TOO**: walked whole in one step, production's
/// volume (159 folders) took 548 ms of a 200 ms budget.
///
/// **A VOLUME THAT CHANGES UNDER IT STARTS IT AGAIN**: a write between
/// two steps would make the tree walked and the FAT read disagree, and
/// the findings would be the check's, not the volume's. So every step
/// first compares `Volume.changes` with what it was at the start, and
/// answers `changed` if it moved.
///
/// It lives where the caller puts it (the kernel's long-lived memory),
/// and must not move between `begin` and its last step: the checker
/// points at its own tally.
pub const CheckRun = struct {
    tally: Tally = .{},
    checker: Checker(*Tally, Tally.each) = undefined,
    phase: enum { start, walk, fat, done, failed } = .done,
    changes_at_start: u64 = 0,

    /// What a run found, in counts: what `/admin/host` says.
    pub const Tally = struct {
        damage: u32 = 0,
        /// The first damage found, its kind and cluster.
        first: ?struct { problem: Problem, cluster: Cluster } = null,

        fn each(t: *Tally, f: Finding) void {
            if (!f.problem.damage()) return;
            t.damage +|= 1;
            if (t.first == null) t.first = .{ .problem = f.problem, .cluster = f.cluster };
        }
    };

    pub const Step = enum { more, done, changed };

    /// How much one step may read: directory sectors while it walks,
    /// runs of the FAT (`run_sectors`, each copy) after.
    pub const Slice = struct { sectors: u32, runs: u32 };

    /// A run over `vol`, its marks in `seen` (`checkBytes` long), from
    /// the start. Nothing is read until the first step.
    pub fn begin(self: *CheckRun, vol: *Volume, seen: []u8) Error!void {
        if (seen.len < vol.checkBytes()) return Error.TooBig;
        self.tally = .{};
        self.checker = .{ .vol = vol, .seen = seen[0..vol.checkBytes()], .context = &self.tally };
        self.phase = .start;
        self.changes_at_start = vol.changes;
    }

    /// One step: a slice of the tree's walk, or of the FAT on the disk.
    ///
    /// **A RUN THAT FAILED IS BEGUN AGAIN, NEVER RESUMED**: a step that
    /// fails has moved the walk's place past what it failed on, so every
    /// step after it is refused with that failure (`ReadFailed`) until
    /// `begin`. A slice that reads nothing would never finish: a panic,
    /// the caller's mistake.
    pub fn step(self: *CheckRun, slice: Slice) Error!Step {
        if (slice.sectors == 0 or slice.runs == 0) @panic("a check's slice reads nothing: it would never finish");
        if (self.phase == .failed) {
            props.reachable(@src(), "fat: a step of a check that failed is refused until it begins again", null);
            return Error.ReadFailed;
        }
        errdefer self.phase = .failed;
        const c = &self.checker;
        const v = c.vol;
        if (self.phase == .done) return .done;
        if (v.changes != self.changes_at_start) {
            props.reachable(@src(), "fat: a check a slice at a time meets a volume changed under it", null);
            self.phase = .done;
            return .changed;
        }
        switch (self.phase) {
            .start => {
                @memset(c.seen, 0);
                try c.walkStart();
                self.phase = .walk;
                return self.step(slice);
            },
            .walk => {
                if (try c.walkSome(slice.sectors)) self.phase = .fat;
                return .more;
            },
            .fat => {
                if (!try c.fatSome(slice.runs)) return .more;
                self.phase = .done;
                props.reachable(@src(), "fat: a check a slice at a time finishes", .{ .damage = self.tally.damage });
                return .done;
            },
            .done, .failed => unreachable,
        }
    }

    /// What the run walked and found, as `check` answers it.
    pub fn health(self: *const CheckRun) Health {
        return self.checker.health;
    }
};

pub fn Checker(comptime Context: type, comptime each: fn (Context, Finding) void) type {
    return struct {
        vol: *Volume,
        seen: []u8,
        context: Context,
        health: Health = .{},
        /// Whether every directory was walked. Where one was not, a
        /// leak cannot be told from what it holds, and none is reported.
        walked: enum { every_directory, stopped_short } = .every_directory,
        /// The path being walked, for the findings.
        path: [max_tree_depth * (max_name + 1)]u8 = undefined,
        path_len: usize = 0,
        /// The directories being walked, the root first: a frame a level.
        frames: [max_tree_depth]Frame = undefined,
        frames_len: u32 = 0,
        /// Directory sectors the walk has read, all its slices.
        walk_sectors: u64 = 0,
        /// Where the FAT's pass stands (`fatSome`), between slices.
        fat: struct {
            base: u32 = 0,
            differ: u32 = 0,
            differ_at: Cluster = 0,
            run_start: Cluster = 0,
            run: u32 = 0,
            free: u32 = 0,
        } = .{},

        const Self = @This();

        /// **A DIRECTORY, PART WALKED**: where it stands (sector `k`,
        /// entry offset `at` in `sector`, 0 before the sector is read),
        /// and the long-name run it is in.
        const Frame = struct {
            cluster: Cluster,
            parent: Cluster,
            depth: u32,
            sectors: u32,
            k: u32 = 0,
            at_cluster: Cluster,
            at: usize = 0,
            sector: [sector_size]u8 align(16) = undefined,
            long: LongName = .{},
            // The long-name parts since the last entry that was none,
            // their run's checksum, whether every part agrees, the
            // number the next part must have, and whether the run began
            // with a part flagged last (0x40).
            run_parts: u32 = 0,
            run_sum: u8 = 0,
            run_whole: bool = false,
            run_next: u8 = 0,
            run_started: bool = false,
            path_was: usize,
        };

        fn report(self: *Self, problem: Problem, cluster: Cluster, count: u32) void {
            self.health.problems += 1;
            each(self.context, .{ .problem = problem, .path = self.path[0..self.path_len], .cluster = cluster, .count = count });
        }

        /// Marks `cluster` held, and answers whether it already was.
        fn mark(self: *Self, cluster: Cluster) bool {
            const bit = @as(u8, 1) << @intCast(cluster % 8);
            const was = self.seen[cluster / 8] & bit != 0;
            self.seen[cluster / 8] |= bit;
            return was;
        }

        fn held(self: *const Self, cluster: Cluster) bool {
            return self.seen[cluster / 8] & (@as(u8, 1) << @intCast(cluster % 8)) != 0;
        }

        /// Follows the chain from `first`, marking it, and answers how
        /// many clusters it holds before anything went wrong. `size` is a
        /// file's, which its chain must match; null for a directory.
        fn chain(self: *Self, first: Cluster, size: ?u32) Error!u32 {
            const v = self.vol;
            const cluster_bytes = v.sectors_per_cluster * sector_size;
            // Rounded in 64 bits (metal-vmm QUEUE 182.3): a FAT32 file within
            // a cluster of 4 GiB overflowed u32, and every check panicked.
            const need: u32 = if (size) |n| @intCast((@as(u64, n) + cluster_bytes - 1) / cluster_bytes) else 0;
            if (first == 0) {
                if (size == null or need > 0) self.report(if (size == null) .broken else .short, 0, 0);
                return 0;
            }
            if (!v.inData(first)) {
                self.report(.broken, first, 0);
                return 0;
            }
            var n: u32 = 0;
            var cluster = first;
            while (true) {
                if (self.mark(cluster)) {
                    self.report(.crossed, cluster, 0);
                    self.health.used += n;
                    return n;
                }
                n += 1;
                const next = try v.fatGet(cluster);
                if (next >= v.chainEndValue()) break;
                if (!v.inData(next)) {
                    self.report(.broken, cluster, 0);
                    self.health.used += n;
                    return n;
                }
                cluster = next;
            }
            self.health.used += n;
            if (size != null) {
                if (n < need) self.report(.short, first, n);
                if (n > need) self.report(.long, first, n);
            }
            return n;
        }

        fn push(self: *Self, name: []const u8) usize {
            const was = self.path_len;
            if (self.path_len + 1 + name.len <= self.path.len) {
                self.path[self.path_len] = '/';
                @memcpy(self.path[self.path_len + 1 ..][0..name.len], name);
                self.path_len += 1 + name.len;
            }
            return was;
        }

        /// **THE WALK, FROM THE ROOT**: its chain followed and its frame
        /// the first on the stack. `walkSome` does the rest.
        fn walkStart(self: *Self) Error!void {
            const v = self.vol;
            self.frames_len = 0;
            const root_clusters: u32 = if (v.kind == .fat32) try self.chain(v.root_cluster, null) else 0;
            if (v.kind == .fat16 or root_clusters > 0) self.enter(0, 0, root_clusters, 0, self.path_len);
        }

        /// A directory's frame on the stack: everything in the directory
        /// at `cluster` (0: the root), over the first `clusters` clusters
        /// of its chain, which `chain` has followed and found sound.
        /// `path_was` is the path's length to go back to when it is done.
        fn enter(self: *Self, cluster: Cluster, parent: Cluster, clusters: u32, depth: u32, path_was: usize) void {
            const v = self.vol;
            const fixed_root = cluster == 0 and v.kind == .fat16;
            self.frames[self.frames_len] = .{
                .cluster = cluster,
                .parent = parent,
                .depth = depth,
                .sectors = if (fixed_root) v.root_sectors else clusters * v.sectors_per_cluster,
                .at_cluster = v.dirStart(cluster),
                .path_was = path_was,
            };
            self.frames_len += 1;
        }

        /// **THE WALK, AT MOST `sectors` DIRECTORY SECTORS READ** (a
        /// slice of idle time; `check` gives it no limit): a directory is
        /// a frame on `frames`, its place kept between calls, where a
        /// call walked the whole tree at once, as deep as it went. Answers
        /// whether the walk is done.
        fn walkSome(self: *Self, sectors: u32) Error!bool {
            const v = self.vol;
            var read: u32 = 0;
            while (self.frames_len > 0) {
                const f = &self.frames[self.frames_len - 1];
                if (f.at == 0) {
                    if (f.k == f.sectors) {
                        self.orphaned(&f.run_parts, &f.run_started);
                        self.path_len = f.path_was;
                        self.frames_len -= 1;
                        continue;
                    }
                    if (read == sectors) return false;
                    const fixed_root = f.cluster == 0 and v.kind == .fat16;
                    const lba = if (fixed_root) v.root_start + f.k else blk: {
                        if (f.k > 0 and f.k % v.sectors_per_cluster == 0) f.at_cluster = try v.fatGet(f.at_cluster);
                        break :blk v.clusterSector(f.at_cluster) + f.k % v.sectors_per_cluster;
                    };
                    try v.readSector(lba, &f.sector);
                    read += 1;
                    self.walk_sectors +|= 1;
                }
                if (try self.sectorFrom(f)) |child| {
                    self.enter(child.cluster, f.cluster, child.clusters, f.depth + 1, child.path_was);
                }
            }
            return true;
        }

        /// A directory to walk next, found in its parent's sector.
        const Child = struct { cluster: Cluster, clusters: u32, path_was: usize };

        /// The entries of `f`'s sector from where it stands: to its end,
        /// or to a directory to walk first, answered with `f` left just
        /// past it. Where the directory ends, `f` is left at its last
        /// sector's end.
        fn sectorFrom(self: *Self, f: *Frame) Error!?Child {
            while (f.at + dirent_size <= sector_size) {
                const e = f.sector[f.at..][0..dirent_size];
                f.at += dirent_size;
                if (e[0] == 0x00) { // nothing further in this directory
                    f.k = f.sectors;
                    f.at = 0;
                    return null;
                }
                if (e[0] == 0xE5) {
                    self.orphaned(&f.run_parts, &f.run_started);
                    f.long.letGo();
                    continue;
                }
                if (e[11] == attr_long_name) {
                    // A last part opens a run: the one before it was
                    // closed by nothing. A part of another checksum
                    // spoils the run.
                    // Each part after the last-flagged one is numbered
                    // one less, down to 1, as fsck.fat checks.
                    if (e[0] & 0x40 != 0) {
                        self.orphaned(&f.run_parts, &f.run_started);
                        f.run_started = true;
                        f.run_sum = e[13];
                        f.run_whole = true;
                        f.run_next = e[0] & 0x1F;
                    } else if (f.run_parts == 0 or e[13] != f.run_sum or e[0] & 0x1F != f.run_next) f.run_whole = false;
                    f.run_next -%= 1;
                    f.run_parts +|= 1;
                    f.long.take(e);
                    continue;
                }
                if (e[11] & attr_volume_label != 0) {
                    self.orphaned(&f.run_parts, &f.run_started);
                    f.long.letGo();
                    continue;
                }
                var entry = self.vol.entryFrom(e);
                _ = f.long.close(&entry);
                // **AN ORPHAN AS fsck.fat SEES ONE**, by the run and the
                // checksum, not by whether this driver reads the name
                // (one past `max_name` it does not, and the parts are no
                // orphans).
                if (f.run_parts > 0 and f.run_whole and f.run_next == 0 and f.run_sum == shortChecksum(e[0..11].*)) {
                    f.run_parts = 0;
                    f.run_started = false;
                } else self.orphaned(&f.run_parts, &f.run_started);
                // A child's walk first; `f`, past this entry, resumes after
                // it (at a sector's end, the loop's test moves it on).
                if (try self.entryIn(entry, f.cluster, f.parent, f.depth)) |child| return child;
            }
            f.at = 0;
            f.k += 1;
            return null;
        }

        /// The parts of a run nothing closed, counted, and the run let go.
        fn orphaned(self: *Self, run_parts: *u32, started: *bool) void {
            defer started.* = false;
            if (run_parts.* > 0) {
                if (started.*) {
                    self.health.orphaned_parts +|= run_parts.*;
                    self.health.orphaned_runs +|= 1;
                } else self.health.lfn_fragments +|= run_parts.*;
            }
            run_parts.* = 0;
        }

        /// One entry of the directory `dir`: checked, its chain marked;
        /// a directory to walk is answered, its name left on the path.
        fn entryIn(self: *Self, entry: Entry, dir: Cluster, parent: Cluster, depth: u32) Error!?Child {
            const name = entry.text();
            // "." is this directory and ".." its parent, 0 for the root.
            if (eqlBytes(name, ".") or eqlBytes(name, "..")) {
                const want = if (eqlBytes(name, ".")) dir else parent;
                if (dir == 0 or entry.first_cluster != want) {
                    const was = self.push(name);
                    self.report(.bad_dot, entry.first_cluster, 0);
                    self.path_len = was;
                }
                return null;
            }
            const was = self.push(name);
            if (entry.isDirectory()) {
                self.health.directories += 1;
                const n = try self.chain(entry.first_cluster, null);
                if (n > 0 and depth + 1 >= max_tree_depth) {
                    self.walked = .stopped_short;
                    self.report(.too_deep, entry.first_cluster, 0);
                } else if (n > 0) return .{ .cluster = entry.first_cluster, .clusters = n, .path_was = was };
            } else {
                self.health.files += 1;
                _ = try self.chain(entry.first_cluster, entry.size);
            }
            self.path_len = was;
            return null;
        }

        /// Every copy on the disk against the first, every cluster in use
        /// against what the walk held, and FSInfo's count against the
        /// free clusters. Read `run_sectors` at a time.
        fn fatOnDisk(self: *Self) Error!void {
            while (!try self.fatSome(std.math.maxInt(u32))) {}
        }

        /// **THE FAT ON THE DISK, `runs` RUNS AT A TIME** (`run_sectors`
        /// each, every copy read): the copies compared, and the leaks and
        /// the free count found by the FAT the machine uses. Answers
        /// whether it is done; where it stops is kept in `fat`, so the
        /// next call goes on from there (`CheckRun`, a slice per idle
        /// step; `fatOnDisk`, all at once).
        fn fatSome(self: *Self, runs: u32) Error!bool {
            const v = self.vol;
            const f = &self.fat;
            var firsts: [run_sectors * sector_size]u8 align(16) = undefined;
            var others: [run_sectors * sector_size]u8 align(16) = undefined;
            var done_runs: u32 = 0;
            while (f.base < v.sectors_per_fat) {
                if (done_runs == runs) return false;
                done_runs += 1;
                const base = f.base;
                const n = @min(run_sectors, v.sectors_per_fat - base);
                try v.readSectors(v.fat_start + base, n, &firsts);
                var copy: u32 = 1;
                while (copy < v.num_fats) : (copy += 1) {
                    try v.readSectors(v.fat_start + copy * v.sectors_per_fat + base, n, &others);
                    var k: u32 = 0;
                    while (k < n) : (k += 1) {
                        const first = firsts[k * sector_size ..][0..sector_size];
                        const other = others[k * sector_size ..][0..sector_size];
                        if (std.mem.eql(u8, first, other)) continue;
                        if (f.differ == 0) {
                            var i: usize = 0;
                            while (first[i] == other[i]) i += 1;
                            f.differ_at = @intCast((base + k) * v.entriesPerSector() + i / v.entryBytes());
                        }
                        f.differ += 1;
                    }
                }
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    const sec = base + k;
                    // Leaks and the free count by the FAT the machine
                    // uses, the held one when there is one; the copies
                    // were compared as the disk holds them.
                    const entries: *const [sector_size]u8 = if (v.fat) |fat| fat[sec * sector_size ..][0..sector_size] else firsts[k * sector_size ..][0..sector_size];
                    var i: u32 = 0;
                    const per = v.entriesPerSector();
                    while (i < per) : (i += 1) {
                        const c = sec * per + i;
                        if (c < 2) continue;
                        if (c > v.max_cluster) break;
                        const value = v.entryIn(entries, i);
                        if (value == 0) f.free += 1;
                        const leaked = self.walked == .every_directory and value != 0 and value != v.badMark() and !self.held(@intCast(c));
                        if (leaked) {
                            if (f.run == 0) f.run_start = @intCast(c);
                            f.run += 1;
                        } else if (f.run > 0) {
                            self.leak(f.run_start, f.run);
                            f.run = 0;
                        }
                    }
                }
                f.base += n;
            }
            if (f.run > 0) self.leak(f.run_start, f.run);
            f.run = 0;
            if (f.differ > 0) self.report(.fats_differ, f.differ_at, f.differ);
            if (v.kind == .fat32 and v.fsinfo_sector != 0 and v.fsinfo_sector < v.fat_start) {
                var fsinfo: [sector_size]u8 align(16) = undefined;
                try v.readSector(v.fsinfo_sector, &fsinfo);
                if (le32(fsinfo[0..4]) == 0x4161_5252 and le32(fsinfo[484..488]) == 0x6141_7272) {
                    self.path_len = 0;
                    const count = le32(fsinfo[488..492]);
                    const hint = le32(fsinfo[492..496]);
                    if (count != 0xFFFF_FFFF and count != f.free) self.report(.fsinfo, 0, count);
                    if (hint != 0xFFFF_FFFF and !v.inData(hint)) self.report(.fsinfo, hint, 0);
                }
            }
            return true;
        }

        fn leak(self: *Self, start: Cluster, count: u32) void {
            self.health.leaked += count;
            self.path_len = 0;
            self.report(.leaked, start, count);
        }
    };
}
