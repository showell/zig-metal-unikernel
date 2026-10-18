//! disk_fat_dir: directories. Walked and listed (`Lister`), a name found
//! (`find`, `open`), room found or grown for an entry's run (`findRun`,
//! `grow`), an entry unlinked with its long-name parts, and a long name's short
//! alias chosen (split from disk_fat.zig by metal-vmm QUEUE 173).

const std = @import("std");
const builtin = @import("builtin");
const props = @import("coverage");
const dirent = @import("disk_fat_dirent.zig");
const dirent_size = dirent.dirent_size;
const attr_volume_label = dirent.attr_volume_label;
const attr_long_name = dirent.attr_long_name;
const Cluster = dirent.Cluster;
const max_name = dirent.max_name;
const Entry = dirent.Entry;
const LongName = dirent.LongName;
const encode = dirent.encode;
const needsLongName = dirent.needsLongName;
const eqlBytes = dirent.eqlBytes;
const upper = dirent.upper;
const eqlFold = dirent.eqlFold;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const walkFound = Volume.walkFound;
const hasEmptyPart = disk_fat.hasEmptyPart;
const Landing = Volume.Landing;
const sector_size = disk_fat.sector_size;
const Error = disk_fat.Error;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// **A CHAIN THAT LOOPS WOULD HANG EVERY WALK ALONG IT.** A walk hands
/// each cluster it reaches to `pass`, which answers BadChain once the
/// chain has repeated one: Brent's cycle finding, remembering one cluster
/// and a later one each time the steps since reach the next power of
/// two. A loop is found within about two laps, so a looped directory
/// hands out each name a few times at most before its listing fails.
pub const Loop = struct {
    /// Zero is never in a chain.
    seen: Cluster = 0,
    power: u32 = 1,
    steps: u32 = 0,

    pub fn pass(self: *Loop, cluster: Cluster) Error!void {
        if (cluster == self.seen) {
            props.reachable(@src(), "fat: a chain that loops is refused", null);
            return Error.BadChain;
        }
        self.steps += 1;
        if (self.steps == self.power) {
            self.seen = cluster;
            self.power *= 2;
            self.steps = 0;
        }
    }
};

/// Where a directory's next sector is: FAT16's root is a fixed run before
/// the data region, every other directory a chain. `Lister`, `findRun`
/// and `unlinkEntry` walk either through this.
pub const Walk = struct {
    vol: *Volume,
    lba: u32,
    where: union(enum) {
        fixed_root: struct { left: u32 },
        /// Any other directory, FAT32's root among them.
        chain: struct {
            cluster: Cluster,
            in_cluster: u32 = 0,
            loop: Loop,
        },
    },

    fn start(vol: *Volume, dir_cluster: Cluster) Error!Walk {
        const first = vol.dirStart(dir_cluster);
        if (first == 0) return .{ .vol = vol, .lba = vol.root_start, .where = .{ .fixed_root = .{ .left = vol.root_sectors } } };
        if (!vol.inData(first)) {
            props.reachable(@src(), "fat: a directory's first cluster is outside the data", null);
            return Error.BadChain;
        }
        return .{
            .vol = vol,
            .lba = vol.clusterSector(first),
            // As `pass(first)` leaves it.
            .where = .{ .chain = .{ .cluster = first, .loop = .{ .seen = first, .power = 2 } } },
        };
    }

    /// Moves to the next sector. Answers false at the end of the directory.
    fn next(self: *Walk) Error!bool {
        switch (self.where) {
            .fixed_root => |*root| {
                root.left -= 1;
                if (root.left == 0) return false;
                self.lba += 1;
                return true;
            },
            .chain => |*chain| {
                chain.in_cluster += 1;
                if (chain.in_cluster < self.vol.sectors_per_cluster) {
                    self.lba += 1;
                    return true;
                }
                chain.cluster = (try self.vol.nextCluster(chain.cluster)) orelse return false;
                try chain.loop.pass(chain.cluster);
                self.lba = self.vol.clusterSector(chain.cluster);
                chain.in_cluster = 0;
                return true;
            },
        }
    }

    /// The sectors from this one to the end of its stretch of disk: the
    /// rest of the cluster, or the rest of FAT16's fixed root.
    fn sectorsLeftInRun(self: *const Walk) u32 {
        return switch (self.where) {
            .fixed_root => |root| root.left,
            .chain => |chain| self.vol.sectors_per_cluster - chain.in_cluster,
        };
    }
};

/// **A DIRECTORY, ONE ENTRY AT A TIME**: what io.zig's directory iterator
/// hands the application. No ceiling on the directory's length; its
/// memory is one sector and one long name.
///
/// Its sector is its own, not `scratch`, so whatever the volume does
/// between two `next` calls cannot change what it is reading. Sectors
/// are read as they are reached: an entry written meanwhile, past the
/// cursor, is seen.
pub const Lister = struct {
    walk: Walk,
    sector: [sector_size]u8 = undefined,
    at: usize = 0,
    /// The walk's sector: `to_read`, or `read` with `at` the next entry
    /// in it; `ended` once the directory's end is reached.
    sector_is: enum { to_read, read, ended } = .to_read,
    // A long name arrives before its entry: collected here, handed over
    // with the short entry that closes it.
    long: LongName = .{},
    /// Set by `find` alone (the volume's `dir_burst`): sectors are read
    /// up to a stretch at a time, and `burst_n` of them from `burst_lba`
    /// are held.
    burst: ?[]u8 = null,
    burst_lba: u32 = 0,
    burst_n: u32 = 0,

    /// Reads the walk's sector, unless the burst already holds it; `dirs`
    /// answers what it holds, and keeps what is read.
    fn load(self: *Lister) Error!void {
        const vol = self.walk.vol;
        const lba = self.walk.lba;
        const b = self.burst orelse {
            try vol.readSector(lba, &self.sector);
            if (vol.dirs) |*c| c.put(lba, &self.sector);
            return;
        };
        if (lba >= self.burst_lba and lba < self.burst_lba + self.burst_n) return;
        const n = @min(@as(u32, @intCast(b.len / sector_size)), self.walk.sectorsLeftInRun());
        self.burst_lba = lba;
        self.burst_n = n;
        if (vol.dirs) |*c| if (c.copyOut(lba, n, b)) return;
        self.burst_n = 0;
        try vol.readSectors(lba, n, b.ptr);
        self.burst_n = n;
        if (vol.dirs) |*c| {
            var k: u32 = 0;
            while (k < n) : (k += 1) c.put(lba + k, b[k * sector_size ..][0..sector_size]);
        }
    }

    /// The walk's sector, as `load` left it.
    fn current(self: *Lister) *const [sector_size]u8 {
        const b = self.burst orelse return &self.sector;
        return b[(self.walk.lba - self.burst_lba) * sector_size ..][0..sector_size];
    }

    /// The next real entry, or null at the directory's end.
    pub fn next(self: *Lister) Error!?Entry {
        while (self.sector_is != .ended) {
            if (self.sector_is == .to_read) {
                try self.load();
                self.sector_is = .read;
                self.at = 0;
            }
            const sector = self.current();
            while (self.at + dirent_size <= sector_size) {
                const at = self.at;
                self.at += dirent_size;
                const e = sector[at..][0..dirent_size];
                if (e[0] == 0x00) { // nothing further in this directory
                    self.sector_is = .ended;
                    return null;
                }
                if (e[0] == 0xE5) {
                    self.long.letGo();
                    continue;
                }
                if (e[11] == attr_long_name) {
                    self.long.take(e);
                    continue;
                }
                if (e[11] & attr_volume_label != 0) {
                    self.long.letGo();
                    continue;
                }
                var entry = self.walk.vol.entryFrom(e);
                entry.lba = self.walk.lba;
                entry.slot = @intCast(at);
                _ = self.long.close(&entry);
                return entry;
            }
            if (!(try self.walk.next())) {
                self.sector_is = .ended;
                return null;
            }
            self.sector_is = .to_read;
        }
        return null;
    }
};

/// A cursor over a directory's entries; cluster 0 is the root.
pub fn lister(self: *Volume, dir_cluster: Cluster) Error!Lister {
    return .{ .walk = try Walk.start(self, dir_cluster) };
}

/// Walks the entries of a directory, calling `each` for every real one:
/// a `Lister` run to its end.
pub fn list(
    self: *Volume,
    dir_cluster: Cluster,
    context: anytype,
    comptime each: fn (@TypeOf(context), Entry) void,
) Error!void {
    var l = try self.lister(dir_cluster);
    while (try l.next()) |entry| each(context, entry);
}

/// The entry named `name` in a directory, or null; case-insensitive, as
/// FAT names are. It stops at the name, reading in bursts (`dir_burst`).
pub fn find(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!?Entry {
    var l = try self.lister(dir_cluster);
    l.burst = self.dir_burst;
    while (try l.next()) |e| if (eqlFold(e.text(), name)) return e;
    return null;
}

/// Walks a slash-separated path from the root. "EFI/BOOT/BOOTX64.EFI".
/// **EVERY PART IS NAMED**: an empty one (a doubled, leading or trailing
/// slash) names nothing, never the path it might have meant.
pub fn open(self: *Volume, path: []const u8) Error!Entry {
    var cluster: Cluster = 0;
    var at: usize = 0;
    var result: ?Entry = null;
    if (hasEmptyPart(path)) {
        props.reachable(@src(), "fat: a path with an empty part names nothing", null);
        return Error.NotFound;
    }
    while (at < path.len) {
        var end = at;
        while (end < path.len and path[end] != '/') end += 1;
        if (end > at) {
            // **NOT THROUGH A FILE**: its bytes would be read as entries.
            if (result) |r| if (!r.isDirectory()) {
                props.reachable(@src(), "fat: a path through a file names nothing", null);
                return Error.NotFound;
            };
            const e = (try self.find(cluster, path[at..end])) orelse return Error.NotFound;
            result = e;
            cluster = e.first_cluster;
        }
        at = end + 1;
    }
    return result orelse Error.NotFound;
}

/// Where one directory entry sits: a sector the walk reached, and an
/// offset in it.
pub const Slot = struct { lba: u32, at: u32 };

/// **A RUN IS THE SLOTS THEMSELVES, NOT A START AND A LENGTH**: a
/// directory's next cluster is rarely the one after its last, so the
/// sector after a cluster edge is usually another file's data.
///
/// **AND THE ORPHANS JUST BEFORE IT.** Live long-name parts followed by
/// a free slot are an orphan, what a write or remove that failed or
/// stopped part-way leaves. A new entry written after them whose alias
/// happens to share their 8-bit checksum (1 in 256) would be listed
/// under the orphan's name, so writeEntry tombstones them first.
pub const Run = struct {
    slots: [max_long_parts + 1]Slot = undefined,
    len: u32 = 0,
    orphans: [max_long_parts]Slot = undefined,
    orphans_len: u32 = 0,
};

/// `needed` consecutive free entries in a directory, growing it if there
/// is no room. **A LONG NAME NEEDS A RUN, NOT A SLOT**: its parts sit
/// immediately before the short entry, so scattered free entries are not
/// enough.
pub fn findRun(self: *Volume, dir_cluster: Cluster, needed: u32) Error!Run {
    if (needed == 0 or needed > max_long_parts + 1) {
        // `writeFileIn` and `rename` bound names at `max_name` (9 slots);
        // `makeDirIn` does not, and a name past 260 lands here.
        props.@"unreachable"(@src(), "fat: a name needing more long-name parts than FAT allows", null);
        return Error.BadName;
    }
    var walk = try Walk.start(self, dir_cluster);
    var run = Run{};
    // The live long-name parts since the last other entry, at most as
    // many as a name has.
    var parts: [max_long_parts]Slot = undefined;
    var parts_len: u32 = 0;

    while (true) {
        try self.readSector(walk.lba, self.scratch);
        var at: u32 = 0;
        while (at + dirent_size <= sector_size) : (at += dirent_size) {
            const first = self.scratch[at];
            if (first == 0x00 or first == 0xE5) {
                if (run.len == 0) {
                    @memcpy(run.orphans[0..parts_len], parts[0..parts_len]);
                    run.orphans_len = parts_len;
                }
                parts_len = 0;
                run.slots[run.len] = .{ .lba = walk.lba, .at = at };
                run.len += 1;
                if (run.len == needed) {
                    props.sometimes(@src(), run.slots[0].lba != run.slots[run.len - 1].lba, "fat: a name's run of entries straddles a sector", .{ .needed = needed });
                    return run;
                }
            } else {
                run.len = 0;
                if (self.scratch[at + 11] == attr_long_name) {
                    if (parts_len == parts.len) {
                        std.mem.copyForwards(Slot, parts[0 .. parts.len - 1], parts[1..]);
                        parts_len -= 1;
                    }
                    parts[parts_len] = .{ .lba = walk.lba, .at = at };
                    parts_len += 1;
                } else parts_len = 0;
            }
        }
        // A run may straddle sectors and clusters; each slot records its
        // own sector.
        if (!(try walk.next())) break;
    }

    // **FAT16'S ROOT CANNOT GROW**: a fixed run of BPB_RootEntCnt entries.
    if (dir_cluster == 0 and self.kind == .fat16) {
        props.reachable(@src(), "fat: a FAT16 root directory is full", .{ .needed = needed });
        return Error.DirectoryFull;
    }
    try self.grow(dir_cluster);
    return self.findRun(dir_cluster, needed);
}

/// Adds one zeroed cluster to the end of a directory's chain.
pub fn grow(self: *Volume, dir_cluster: Cluster) Error!void {
    const end = try self.chainEnd(self.dirStart(dir_cluster));
    // **FAT'S LIMIT ON A DIRECTORY: 65,536 ENTRIES** (`max_dir_entries`).
    // Past it fsck.fat calls the directory broken, so it is refused as
    // full, as a full root is.
    const per_cluster = self.sectors_per_cluster * (sector_size / dirent_size);
    if ((end.clusters + 1) * per_cluster > max_dir_entries) {
        props.reachable(@src(), "fat: a directory reaches FAT's most entries", null);
        return Error.DirectoryFull;
    }
    props.reachable(@src(), "fat: a directory grows by a cluster", .{ .clusters = end.clusters });
    props.alwaysLessThanOrEqualTo(@src(), (end.clusters + 1) * per_cluster, max_dir_entries, "fat: a directory grown stays within FAT's most entries", null);
    const last = end.last;

    const fresh = try self.allocChain(1, .{ .bytes = 0 });
    // By the link that makes it the directory's: given back on any
    // failure before it or where it did not land; linked where it
    // landed, answered or not; a counted leak where that is unknown.
    var link: Landing = .before;
    defer switch (link) {
        .before => self.giveBack(fresh, 1),
        .landed => self.linked(1),
        .unknown => self.leftUnsure(1),
    };
    var s: u32 = 0;
    @memset(self.scratch, 0);
    while (s < self.sectors_per_cluster) : (s += 1) {
        try self.writeSector(self.clusterSector(fresh) + s, self.scratch);
    }
    try self.fatSet(last, fresh, &link);
}

/// The most entries a directory may hold: the specification's 2 MiB of
/// 32-byte entries.
pub const max_dir_entries: u32 = 65536;

/// The most parts a VFAT long name can have: 255 characters, 13 per part.
pub const max_long_parts = 20;

/// Removes an entry and its long-name run, and frees its chain.
///
/// **THE ORDER IS THE WHOLE FUNCTION.**
///
///   1. Tombstone the short entry while `scratch` holds its sector: the
///      commit. (freeChain reads FAT sectors through `scratch`, so after
///      it the "directory sector" would be a FAT sector.)
///   2. Tombstone each long-name part, at the sector the walk found it in
///      (a directory's clusters need not be adjacent).
///   3. Only then free the chain.
///
/// Freeing last is the crash-safe order: a stop between the steps leaks
/// clusters, where the other order leaves an entry pointing at clusters
/// already given away. A name the walk does not find is NotFound: its
/// callers looked it up first (`walkFound`).
pub fn removeEntry(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!void {
    var gone: Landing = .before;
    try self.unlinkEntry(dir_cluster, name, .free_chain, &gone, null);
    return walkFound(gone);
}

/// An entry `unlinkEntry` tombstoned and kept the means to undo:
/// where the short entry is, the byte its tombstone replaced, and its
/// long name's parts, not yet cleared.
pub const Unlinked = struct {
    /// Whether the walk found the entry and tombstoned it: until it
    /// has, `lba` and `at` point at nothing (sector 0 is the boot
    /// sector), and there is nothing to undo.
    state: enum { not_found, tombstoned } = .not_found,
    lba: u32 = 0,
    at: u32 = 0,
    first: u8 = 0,
    parts: [max_long_parts]Slot = undefined,
    part_count: usize = 0,

    /// The tombstone undone: the entry, long name and all, is back,
    /// where it stands says so. **A REFUSED UNDO IS READ BACK** as every
    /// commit is (145's review): landed, the entry is live, its long
    /// name must stay and its chain is its own; unknown, a counted leak
    /// (`commitRefused`, `clusters`) that leaves the parts alone, as the
    /// entry may be live.
    pub fn undo(u: *const Unlinked, vol: *Volume, clusters: u32) Landing {
        std.debug.assert(u.state == .tombstoned);
        vol.readSector(u.lba, vol.scratch) catch return .before;
        const e = vol.scratch[u.at..][0..dirent_size];
        const was = e.*;
        e[0] = u.first;
        const written = e.*;
        vol.writeSector(u.lba, vol.scratch) catch return vol.commitRefused(u.lba, u.at, &was, &written, clusters);
        return .landed;
    }

    /// The entry is gone for good: its long name's parts go too.
    pub fn forget(u: *const Unlinked, vol: *Volume) void {
        vol.partsLeft(u.parts[0..u.part_count]);
    }
};

/// **A LONG-NAME PART CLEARED AFTER A COMMIT**, where the walk found
/// it: null when it is, else where the refused clear stands (148(b)): a
/// read that failed wrote nothing (`before`); a refused write is read
/// back. A failure is a counted cleanup, and the part is counted where it
/// stands (`orphaned_parts`, or `unsure_parts` where neither).
pub fn partLeft(self: *Volume, lba: u32, at: u32) ?Landing {
    self.readSector(lba, self.scratch) catch return self.partStands(.before);
    const was = self.scratch[at..][0..dirent_size].*;
    self.scratch[at] = 0xE5;
    const written = self.scratch[at..][0..dirent_size].*;
    self.writeSector(lba, self.scratch) catch return self.partStands(self.entryRefused(lba, at, &was, &written));
    return null;
}

/// A part whose clearing failed, counted by where the clear stands,
/// which it answers.
pub fn partStands(self: *Volume, clear: Landing) Landing {
    self.cleanups_failed +%= 1;
    switch (clear) {
        .landed => props.reachable(@src(), "fat: a long-name part's refused clearing landed", null),
        .before => {
            self.orphaned_parts +|= 1;
            props.reachable(@src(), "fat: a long-name part could not be cleared after a commit, and is left orphaned", .{ .count = self.orphaned_parts });
        },
        .unknown => self.unsure_parts +|= 1,
    }
    return clear;
}

/// **A NAME'S PARTS CLEARED FROM ITS END, STOPPING AT THE FIRST THAT
/// FAILS** (metal-vmm 152): `positions` in the order they sit, the part
/// flagged last (0x40) first. Cleared from the short entry's side back,
/// what a failure leaves is always the name's first parts, a run that
/// starts as a run does: fsck.fat deletes it, one "Orphaned long file
/// name part" line, where parts left after a cleared start would be a
/// fragment it reports and leaves. Its parts are `orphaned_parts`, and
/// it is one run (`orphaned_runs`), or one that may be (`unsure_runs`)
/// where it is the one part whose clear is unknown.
pub fn partsLeft(self: *Volume, positions: anytype) void {
    var i = positions.len;
    while (i > 0) {
        i -= 1;
        const failed = self.partLeft(positions[i].lba, positions[i].at) orelse continue;
        // Refused and read back cleared: cleared, so go on.
        if (failed == .landed) continue;
        // The parts before it, never tried: left as they are.
        self.orphaned_parts +|= i;
        if (i > 0 or failed == .before) self.orphaned_runs +|= 1 else self.unsure_runs +|= 1;
        return;
    }
}

/// removeEntry's work. With `.keep_chain` the chain stays allocated, for
/// `rename` to hand to another entry.
///
/// **A REFUSED TOMBSTONE IS READ BACK** (`commitRefused`), and `gone`
/// says where it stands. Landed, the cleanup runs as after one that
/// answered, and the error is still the caller's; unknown, the chain
/// is left, a counted leak.
///
/// **`held` KEEPS THE LONG NAME** (`rename`, metal-vmm 145): its parts
/// are left as they are and their places handed back, with the short
/// entry's place and first byte, so a rename whose new entry does not
/// land, or whose refused tombstone landed, can undo the tombstone and
/// leave `from` whole (`undoUnlink`).
pub fn unlinkEntry(self: *Volume, dir_cluster: Cluster, name: []const u8, then: enum { free_chain, keep_chain }, gone: *Landing, held: ?*Unlinked) Error!void {
    const Pos = struct { lba: u32, at: u32 };
    var walk = try Walk.start(self, dir_cluster);
    // Where the open run's parts sit, to mark each deleted with its
    // entry. A whole run counts down from at most `max_name`'s parts
    // (LongName.take), well inside `parts`; one that overflows it is no
    // whole run, so its name is never put.
    var parts: [max_long_parts]Pos = undefined;
    var part_count: usize = 0;
    var long: LongName = .{};

    while (true) {
        try self.readSector(walk.lba, self.scratch);
        var at: u32 = 0;
        while (at + dirent_size <= sector_size) : (at += dirent_size) {
            const e = self.scratch[at..][0..dirent_size];
            if (e[0] == 0x00) return; // nothing further in this directory
            if (e[0] == 0xE5 or (e[11] != attr_long_name and e[11] & attr_volume_label != 0)) {
                long.letGo();
                part_count = 0;
                continue;
            }
            if (e[11] == attr_long_name) {
                // The part flagged 0x40 (LAST_LONG_ENTRY) opens a run.
                if (e[0] & 0x40 != 0) part_count = 0;
                if (part_count < parts.len) {
                    parts[part_count] = .{ .lba = walk.lba, .at = at };
                    part_count += 1;
                }
                long.take(e);
                continue;
            }

            var entry = self.entryFrom(e);
            const has_long = long.close(&entry);

            if (eqlFold(entry.text(), name)) {
                const chain = entry.first_cluster;
                const short_lba = walk.lba;
                const run = parts[0..part_count];

                // 1. the short entry, while its sector is in scratch: the
                // commit. What follows is cleanup, whose failure leaves
                // orphaned parts or a leaked chain, not the error.
                const was = e.*;
                if (held) |h| {
                    h.* = .{ .state = .tombstoned, .lba = short_lba, .at = at, .first = e[0], .part_count = if (has_long) run.len else 0 };
                    for (run, 0..) |pos, k| h.parts[k] = .{ .lba = pos.lba, .at = pos.at };
                }
                self.scratch[at] = 0xE5;
                const written = e.*;
                var refused: ?Error = null;
                self.writeSector(short_lba, self.scratch) catch |err| {
                    gone.* = self.commitRefused(short_lba, at, &was, &written, 0);
                    // Unknown: the entry may be gone, its chain and
                    // parts left with nothing to reach them, or not
                    // (148(b)). A rename's own undo counts its own.
                    if (gone.* == .unknown and held == null) self.unlinkUnsure(chain, if (has_long) @intCast(run.len) else 0);
                    if (gone.* != .landed) return err;
                    refused = err;
                };
                gone.* = .landed;

                // 2. the long-name parts, each where the walk found it
                // (unless held: the caller clears them once it is sure)
                if (has_long and held == null) {
                    self.partsLeft(run);
                }

                // 3. and only now, the data
                if (then == .free_chain and chain >= 2) self.freeAfterCommit(chain);
                if (refused) |err| return err;
                return;
            }
            part_count = 0;
        }
        if (!(try walk.next())) return;
    }
}

/// What a tombstone whose landing is unknown may have left: the entry's
/// chain, counted by walking it, and its long name's parts, each a
/// leftover that may be live (`unsure_clusters`, `unsure_parts`).
pub fn unlinkUnsure(self: *Volume, chain: Cluster, parts: u32) void {
    self.unsure_parts +|= parts;
    if (parts > 0) self.unsure_runs +|= 1;
    if (!self.inData(chain)) return;
    const end = self.chainEnd(chain) catch {
        self.unsized_leaks +|= 1;
        return;
    };
    self.unsure_clusters +|= end.clusters;
}

/// An 8.3 alias for a name. A name that reads back as itself in 8.3 is
/// its own alias, and refused (`NameTaken`) if another entry's alias is
/// already that; any other gets SESSIO~1, SESSIO~2, and so on until one
/// is free.
pub fn aliasFor(self: *Volume, dir_cluster: Cluster, name: []const u8) Error![11]u8 {
    // **A NEW NAME IS ASCII.** A long name holds a byte as one UTF-16
    // unit, and `LongName.take` reads a unit past ASCII as '?', so such a
    // name would be found under no name it was given. Every name made
    // here comes through this before anything changes.
    for (name) |c| if (c >= 0x80) {
        props.reachable(@src(), "fat: a name past ASCII is refused", null);
        return Error.BadName;
    };
    if (!needsLongName(name)) {
        if (encode(name)) |short| {
            if (try self.aliasTaken(dir_cluster, short)) {
                props.reachable(@src(), "fat: a new name that is another entry's alias is refused", null);
                return Error.NameTaken;
            }
            return short;
        } else |_| {}
    }

    // **ONE LISTING** (metal-vmm QUEUE 203(b), P198.12): every `~N` this
    // name's aliases already hold, marked in one pass; then the first free.
    // Probing `~1, ~2, …` with a listing each was cubic in a directory of
    // names sharing their first six characters.
    const Taken = struct {
        name: []const u8,
        n: std.StaticBitSet(1000) = .initEmpty(),
        fn each(t: *@This(), e: Entry) void {
            // Each `~` in the 8-character part may start the tail: the
            // name's own characters can hold one too.
            for (e.short[0..8], 0..) |c, at| {
                if (c != '~') continue;
                var v: u32 = 0;
                var k = at + 1;
                while (k < 8 and e.short[k] >= '0' and e.short[k] <= '9') : (k += 1) v = v * 10 + (e.short[k] - '0');
                if (k == at + 1 or v == 0 or v >= 1000) continue;
                if (eqlBytes(&aliasCandidate(t.name, v), &e.short)) t.n.set(v);
            }
        }
    };
    var taken = Taken{ .name = name };
    try self.list(dir_cluster, &taken, Taken.each);
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        if (!taken.n.isSet(n)) return aliasCandidate(name, n);
    }
    props.reachable(@src(), "fat: no 8.3 alias is left for a name", null);
    return Error.BadName;
}

/// The `~n` alias of `name` (1 ≤ n < 1000): its first characters, without
/// dots and spaces, as many as fit before the tail (`~9` keeps six, `~10`
/// five), upper-cased; the extension from its last dot.
pub fn aliasCandidate(name: []const u8, n: u32) [11]u8 {
    var short = [_]u8{' '} ** 11;

    var tail: [4]u8 = undefined;
    var tail_len: usize = 1;
    tail[0] = '~';
    var digits: [3]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
    }
    while (d > 0) {
        d -= 1;
        tail[tail_len] = digits[d];
        tail_len += 1;
    }

    // The base: what fits before the tail, without dots and spaces.
    const keep = 8 - tail_len;
    var w: usize = 0;
    for (name) |c| {
        if (w >= keep) break;
        if (c == '.' or c == ' ') continue;
        short[w] = upper(c);
        w += 1;
    }
    for (tail[0..tail_len], 0..) |c, i| short[w + i] = c;

    // The extension, from the last dot.
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }
    if (dot < name.len) {
        var x: usize = 0;
        for (name[dot + 1 ..]) |c| {
            if (x >= 3) break;
            short[8 + x] = upper(c);
            x += 1;
        }
    }
    return short;
}

/// Whether a directory already holds this exact 8.3 field.
pub fn aliasTaken(self: *Volume, dir_cluster: Cluster, short: [11]u8) Error!bool {
    const Search = struct {
        want: [11]u8,
        found: bool = false,
        fn each(sv: *@This(), e: Entry) void {
            if (eqlBytes(&e.short, &sv.want)) sv.found = true;
        }
    };
    var search = Search{ .want = short };
    try self.list(dir_cluster, &search, Search.each);
    return search.found;
}
