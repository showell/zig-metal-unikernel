//! disk_fat_file: files. An entry written as one commit (`writeEntry`), a
//! file written whole or into (`writeFile`, `writeInto`), a directory made, and
//! a file read back (`readFile`, `readAt`) (split from disk_fat.zig by metal-vmm
//! QUEUE 173).

const std = @import("std");
const builtin = @import("builtin");
const props = @import("coverage");
const dirent = @import("disk_fat_dirent.zig");
const dirent_size = dirent.dirent_size;
const attr_directory = dirent.attr_directory;
const attr_long_name = dirent.attr_long_name;
const Cluster = dirent.Cluster;
const max_name = dirent.max_name;
const Dos = dirent.Dos;
const Entry = dirent.Entry;
const shortChecksum = dirent.shortChecksum;
const long_offsets = dirent.long_offsets;
const putCluster = dirent.putCluster;
const putLe16 = dirent.putLe16;
const putDos = dirent.putDos;
const longParts = dirent.longParts;
const needsLongName = dirent.needsLongName;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const max_path_depth = Volume.max_path_depth;
const Loop = Volume.Loop;
const hasEmptyPart = disk_fat.hasEmptyPart;
const sector_size = disk_fat.sector_size;
const Error = disk_fat.Error;
const Run = Volume.Run;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// An entry's times: created, written and accessed, one moment.
fn putStamp(e: *[dirent_size]u8, when: Dos) void {
    putDos(e[14..18], when); // creation time, creation date
    putLe16(e[18..20], when.date); // last access date
    putDos(e[22..26], when); // write time, write date
}

/// The date to stamp on an entry being written now.
pub fn stamp(self: *Volume) Dos {
    const clock = self.clock orelse return .none;
    const now = clock() orelse return .none;
    return Dos.fromUnix(now);
}

/// **WHERE A WRITE STANDS**: a directory entry's (an operation's commit)
/// or a FAT entry's (`fatSet`). `before`: not tried, or refused and read
/// back exactly as it was; what the operation took is pointed at by
/// nothing, and a failure gives it back. `landed`: on the disk as
/// written. `unknown`: refused, and the read-back was neither (rot, or a
/// read that failed too), so what the operation took is left taken, a
/// counted leak (`leftLeaked`).
pub const Landing = enum { before, landed, unknown };

/// **AN OPERATION'S COMMIT**: where it stands against the entry's write
/// (`landing`), and how many clusters that write makes the entry's: the
/// ledger's committed ending where it lands, a counted leak where that
/// is unknown. Before, the caller gives them back.
pub const Commit = struct {
    landing: Landing = .before,
    clusters: u32,
    /// **READ BACK BEFORE IT COUNTS** (metal-vmm QUEUE 188.1): the entry's
    /// sector read from the disk, past the directory cache, after a write
    /// the disk answered; a commit that did not land is undone as a refused
    /// one is. An overwrite asks it, since it frees the old chain after: a
    /// commit that lied freed the chain the entry still pointed at.
    confirm: enum { as_answered, read_back } = .as_answered,
    /// What the read-back found: `.neither` what was written nor what was
    /// there, and the commit stands (the disk answered it) but the old chain
    /// is not freed (it may still be the file's): a counted leak at worst.
    read_back_found: enum { as_written, neither } = .as_written,

    pub fn done(c: *Commit, vol: *Volume, landing: Landing) void {
        c.landing = landing;
        if (landing == .landed) vol.ended(c.clusters);
    }
};

/// **A REFUSED COMMIT IS READ BACK, AND ONLY AN EXACT READ DECIDES.**
/// The disk may have taken a write it refused, and a caller cannot tell
/// from the answer. The entry at `at` in sector `lba` read back as
/// `written` landed; as `was`, it did not, and the operation is undone;
/// as anything else (rot, a read that failed) it is `unknown`, and what
/// the operation took is a counted leak, never given back under an entry
/// that may point at it.
pub fn commitRefused(self: *Volume, lba: u32, at: u32, was: *const [dirent_size]u8, written: *const [dirent_size]u8, clusters: u32) Landing {
    const landing = self.entryRefused(lba, at, was, written);
    switch (landing) {
        .landed => props.reachable(@src(), "fat: a refused commit read back landed", null),
        .before => props.reachable(@src(), "fat: a refused commit read back did not land, and is undone", null),
        // May be live, may be lost (148(a)).
        .unknown => self.leftUnsure(clusters),
    }
    return landing;
}

/// **WHERE A REFUSED DIRECTORY WRITE STANDS**, read back once: the
/// entry at `at` as `written`, landed; as `was`, before; anything else
/// (rot, a read that failed), unknown. Nothing counted: the caller's.
pub fn entryRefused(self: *Volume, lba: u32, at: u32, was: *const [dirent_size]u8, written: *const [dirent_size]u8) Landing {
    self.readSector(lba, self.scratch) catch return .unknown;
    const now = self.scratch[at..][0..dirent_size];
    if (std.mem.eql(u8, now, written)) return .landed;
    if (std.mem.eql(u8, now, was)) return .before;
    return .unknown;
}

/// Which of this boot's counts holds an orphan run of `len` parts about
/// to be tombstoned (154(b)), as the counts can tell with no state:
///
/// - `exact`: a run, and `len` parts, in the exact counts;
/// - `mixed`: a run and `len - 1` parts in the exact counts, and a part
///   that may be live: the run `partsLeft` or a failed `writeEntry`
///   leaves where one part's write is unknown, that part the one
///   nearest the short entry, tombstoned first;
/// - `unsure`: a run, and `len` parts, that may be live;
/// - `none`: no count of this boot holds it (an earlier boot's run, an
///   older kernel's), and the counts are left.
///
/// **EXACT FIRST**: where the run taken is the wrong one, the exact floor
/// drops and the sum stays, so the judge passes leniently; taken from
/// the counts that may be live when it was exact, the floor would stand
/// above what fsck.fat finds, a false failure. The counts are the
/// judge's accounting, never the data.
pub fn heldBy(self: *const Volume, len: u32) Held {
    if (len == 0) return .none;
    if (self.orphaned_runs > 0 and self.orphaned_parts >= len) return .exact;
    if (len >= 2 and self.orphaned_runs > 0 and self.orphaned_parts >= len - 1 and self.unsure_parts >= 1) return .mixed;
    if (self.unsure_runs > 0 and self.unsure_parts >= len) return .unsure;
    props.reachable(@src(), "fat: an orphan run no count of this boot holds is tombstoned", .{ .parts = len });
    return .none;
}

pub const Held = enum { exact, mixed, unsure, none };

/// The orphan part `k` of a run of `len`, tombstoned (`landed`) or
/// maybe (`unknown`), taken from the count `held` says. A part as it
/// lands, so a stop leaves the run's first parts still counted; the run
/// with its first part (`k == 0`), the last tombstoned. One that may
/// have landed moves to the counts that may be live.
pub fn tombstoned(self: *Volume, held: Held, k: u32, len: u32, how: Landing) void {
    const exact_part = switch (held) {
        .exact => true,
        .mixed => k != len - 1,
        .unsure, .none => false,
    };
    const exact_run = held == .exact or held == .mixed;
    if (held != .none) {
        if (exact_part) self.orphaned_parts -= 1 else self.unsure_parts -= 1;
        if (how == .unknown) self.unsure_parts += 1;
        if (k == 0) {
            if (exact_run) self.orphaned_runs -= 1 else self.unsure_runs -= 1;
            if (how == .unknown) self.unsure_runs += 1;
        }
    }
}

/// **LONG-NAME PART `part` OF `parts`** of `name`, its checksum `sum`, into
/// `e`, whole: the sequence number (0x40 on the last part), the 13 UCS-2
/// characters at `long_offsets`, the name's end a 0x0000 and the rest
/// 0xFFFF; the attribute, type, checksum and cluster fields.
fn putLongPart(e: *[dirent_size]u8, name: []const u8, part: u32, parts: u32, sum: u8) void {
    @memset(e, 0);
    e[0] = @intCast(part | (if (part == parts) @as(u32, 0x40) else 0));
    e[11] = attr_long_name;
    e[12] = 0;
    e[13] = sum;
    e[26] = 0;
    e[27] = 0;
    const base = (part - 1) * 13;
    for (long_offsets, 0..) |off, i| {
        const idx = base + i;
        const c: u16 = if (idx < name.len)
            name[idx]
        else if (idx == name.len) 0x0000 else 0xFFFF;
        e[off] = @truncate(c);
        e[off + 1] = @truncate(c >> 8);
    }
}

/// **THE SHORT ENTRY** into `e`, whole: its 8.3 name, its attribute, its
/// time, its first cluster and its size.
fn putShortEntry(e: *[dirent_size]u8, short: [11]u8, attr: u8, when: Dos, first: Cluster, size: u32) void {
    @memset(e, 0);
    @memcpy(e[0..11], &short);
    e[11] = attr;
    putStamp(e, when);
    putCluster(e, first);
    e[28] = @truncate(size);
    e[29] = @truncate(size >> 8);
    e[30] = @truncate(size >> 16);
    e[31] = @truncate(size >> 24);
}

/// Tombstones the run's orphans, then writes the long-name parts and the
/// short entry that closes them.
pub fn writeEntry(
    self: *Volume,
    run: Run,
    name: []const u8,
    short: [11]u8,
    attr: u8,
    first: Cluster,
    size: u32,
    /// Where the operation stands against the short entry's write, the
    /// commit: the caller gives back what it took while it is `before`,
    /// and undoes nothing once the entry landed.
    commit: ?*Commit,
) Error!void {
    const parts = longParts(name);
    const sum = shortChecksum(short);
    if (run.len != parts + 1) { // the run was sized for another name
        props.@"unreachable"(@src(), "fat: a directory run sized for another name", null);
        return Error.BadName;
    }

    // Orphans first (see Run): a stop after leaves the run still free.
    // From the end back, as `partsLeft` clears: a stop or a failure
    // leaves the run's first parts, never a fragment (152).
    //
    // **TAKEN FROM A COUNT ONLY WHERE A COUNT OF THIS BOOT COVERS THE
    // RUN** (154(b)): the counts are this boot's, and the run may be an
    // earlier boot's, or an older kernel's, which no count holds. Nothing
    // says which run a count was for, so a run is taken as `heldBy`
    // finds a count that holds it, else from none.
    const held = self.heldBy(run.orphans_len);
    var k = run.orphans_len;
    while (k > 0) {
        k -= 1;
        const o = run.orphans[k];
        try self.readSector(o.lba, self.scratch);
        const e = self.scratch[o.at..][0..dirent_size];
        const was = e.*;
        e[0] = 0xE5;
        const written = e.*;
        // A refused tombstone is read back, as `partsLeft`'s clears are:
        // one that landed is gone, whatever the answer said.
        self.writeSector(o.lba, self.scratch) catch |err| {
            switch (self.entryRefused(o.lba, o.at, &was, &written)) {
                .landed => self.tombstoned(held, k, run.orphans_len, .landed),
                .before => {},
                .unknown => self.tombstoned(held, k, run.orphans_len, .unknown),
            }
            return err;
        };
        self.tombstoned(held, k, run.orphans_len, .landed);
    }

    // **PARTS ON THE DISK WITH NO SHORT ENTRY TO CLOSE THEM** are left
    // orphaned when this returns an error before the short entry
    // landed: counted (`orphaned_parts`), a part whose own write failed
    // among them where it reads back landed (148(b)); one that reads as
    // neither, and every part where the short entry's own landing is
    // unknown, may be closed or not (`unsure_parts`). fsck.fat
    // auto-deletes them; the next entry written into this run
    // tombstones them first.
    var on_disk: u32 = 0;
    var short_entry: Landing = .before;
    // The parts on the disk are one run, the first ones of the name
    // (152); a part of unknown landing after them is in it, or alone.
    var part_unsure = false;
    errdefer switch (short_entry) {
        .landed => {},
        .before => {
            if (on_disk > 0) {
                self.orphaned_parts +|= on_disk;
                self.orphaned_runs +|= 1;
                props.reachable(@src(), "fat: a new entry's long-name parts are left orphaned, its short entry not written", .{ .parts = on_disk });
            } else if (part_unsure) self.unsure_runs +|= 1;
        },
        .unknown => if (on_disk > 0) {
            self.unsure_parts +|= on_disk;
            self.unsure_runs +|= 1;
        },
    };
    var next: u32 = 0;
    var part: u32 = parts;
    while (part > 0) : (part -= 1) {
        const slot = run.slots[next];
        next += 1;
        try self.readSector(slot.lba, self.scratch);
        const e = self.scratch[slot.at..][0..dirent_size];
        const part_was = e.*;
        putLongPart(e, name, part, parts, sum);
        const part_written = e.*;
        self.writeSector(slot.lba, self.scratch) catch |err| {
            switch (self.entryRefused(slot.lba, slot.at, &part_was, &part_written)) {
                .landed => on_disk += 1,
                .before => {},
                .unknown => {
                    self.unsure_parts +|= 1;
                    part_unsure = true;
                },
            }
            return err;
        };
        on_disk += 1;
    }

    const slot = run.slots[next];
    try self.readSector(slot.lba, self.scratch);
    const e = self.scratch[slot.at..][0..dirent_size];
    const was = e.*;
    putShortEntry(e, short, attr, self.stamp(), first, size);
    const written = e.*;
    self.writeSector(slot.lba, self.scratch) catch |err| {
        if (commit) |c| {
            short_entry = self.commitRefused(slot.lba, slot.at, &was, &written, c.clusters);
            c.done(self, short_entry);
        }
        return err;
    };
    short_entry = .landed;
    if (commit) |c| c.done(self, .landed);
}

/// Writes a whole file into `dir_cluster`, replacing one of the same name.
///
/// **A REWRITE KEEPS THE NAME THE FILE HAS.** Names match without case,
/// so `PLAN.md` replaces `plan.md` and the file stays `plan.md`, alias
/// and all, as Linux's vfat keeps it on a truncating open. Only a new
/// file takes the case it was given.
///
/// **A DIRECTORY OF THAT NAME IS REFUSED** (`IsDirectory`, Linux's
/// EISDIR): replacing its entry would orphan everything in it.
pub fn writeFileIn(self: *Volume, dir_cluster: Cluster, given: []const u8, bytes: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    if (given.len == 0 or given.len > max_name) {
        props.reachable(@src(), "fat: a write's name is empty or too long", null);
        return Error.BadName;
    }
    const old = try self.find(dir_cluster, given);
    if (old) |*e| if (e.isDirectory()) {
        props.reachable(@src(), "fat: a write onto a directory is refused", null);
        return Error.IsDirectory;
    };
    const per_cluster = self.sectors_per_cluster * sector_size;
    if (bytes.len > 0xFFFF_FFFF) {
        props.reachable(@src(), "fat: a file of 4 GiB or more is refused", null);
        return Error.TooBig;
    }
    const clusters: u32 = @intCast((@as(u64, bytes.len) + per_cluster - 1) / per_cluster);
    if (old) |e| return self.overwrite(e, clusters, bytes);

    const name = given;
    const short = try self.aliasFor(dir_cluster, name);
    const needs_long = needsLongName(name);
    const parts: u32 = if (needs_long) longParts(name) else 0;
    const run = try self.findRun(dir_cluster, parts + 1);

    const first = try self.allocChain(clusters, .{ .bytes = bytes.len });
    // A failure before the entry gives the chain back; a failure of the
    // entry's write may have landed, and leaves it.
    var commit: Commit = .{ .clusters = clusters };
    errdefer if (commit.landing == .before) self.giveBack(first, clusters);
    if (bytes.len > 0) try self.writeChain(first, bytes);

    // The entry goes last: a stop before it loses the new file and
    // corrupts nothing.
    try self.writeEntry(run, if (needs_long) name else name[0..0], short, 0x20, first, @intCast(bytes.len), &commit);
}

/// **AN OVERWRITE COMMITS IN ONE SECTOR WRITE.** The new bytes go into a
/// chain of their own, one write of the entry's sector points the file at
/// it, and then the old chain is freed. A stop anywhere leaves the old
/// file or the new, never neither; a volume without room for both
/// refuses the write and keeps the old. The entry keeps its names.
///
/// **NO UNDO ONCE THE ENTRY'S WRITE IS ASKED**: a write the disk failed
/// may still have landed, and freeing the chain it points at would give
/// one cluster to two files. So a failure there leaves the new chain
/// taken (a leak at worst). A failure freeing the old chain after is a
/// counted leak (`freeAfterCommit`), not the write's error.
pub fn overwrite(self: *Volume, old: Entry, clusters: u32, bytes: []const u8) Error!void {
    // Counted from the old size: a chain longer than its size gives back
    // more, never less.
    const per_cluster: u64 = @as(u64, self.sectors_per_cluster) * sector_size;
    const frees = (@as(u64, old.size) + per_cluster - 1) / per_cluster;
    const first = try self.allocChain(clusters, .{ .bytes = bytes.len, .frees = frees });
    if (bytes.len > 0) self.writeChain(first, bytes) catch |err| {
        self.giveBack(first, clusters);
        return err;
    };
    var commit: Commit = .{ .clusters = clusters, .confirm = .read_back };
    self.setEntry(old, first, @intCast(bytes.len), &commit) catch |err| {
        switch (commit.landing) {
            .before => self.giveBack(first, clusters),
            // The entry points at the new chain: the old one is the
            // cleanup, as after a commit that answered.
            .landed => self.freeAfterCommit(old.first_cluster),
            // The new chain is counted by the read-back; the old one is
            // the file's or no one's, as the entry is (148(b)).
            .unknown => self.unlinkUnsure(old.first_cluster, 0),
        }
        return err;
    };
    if (commit.read_back_found == .neither) return self.unlinkUnsure(old.first_cluster, 0);
    self.freeAfterCommit(old.first_cluster);
}

/// Makes a directory in `dir_cluster`, or answers the one already there.
/// Its first cluster holds `.` and `..`, which every directory but the
/// root has. The entry goes last, so a stop before it leaves no directory
/// and a leaked cluster.
///
/// **ROOM FOR THE ENTRY IS FOUND BEFORE THE CLUSTER IS TAKEN**, so a
/// parent with no room (`DirectoryFull`) takes nothing. The run stays
/// free meanwhile: taking and writing the cluster touch no parent sector.
pub fn makeDirIn(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!Cluster {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    // Held to a file's length: one longer is written and never found
    // again, so every makePath would make another.
    if (name.len == 0 or name.len > max_name) {
        props.reachable(@src(), "fat: a directory's name is empty or too long", null);
        return Error.BadName;
    }
    if ((try self.find(dir_cluster, name))) |e| {
        if (e.isDirectory()) return e.first_cluster;
        props.reachable(@src(), "fat: a directory to be made is a file's name", null);
        return Error.BadName;
    }

    const short = try self.aliasFor(dir_cluster, name);
    const needs_long = needsLongName(name);
    const parts: u32 = if (needs_long) longParts(name) else 0;
    const run = try self.findRun(dir_cluster, parts + 1);

    const cluster = try self.allocChain(1, .{ .bytes = 0 });
    // A failure before the commit gives the cluster back. **NO ROLLBACK
    // ONCE THE COMMIT IS TRIED**: the entry's write may land and still
    // fail, and a cluster freed under it would be given to two. So a
    // failure from there leaves it taken, a leak if the entry did not
    // land.
    var commit: Commit = .{ .clusters = 1 };
    errdefer if (commit.landing == .before) self.giveBack(cluster, 1);
    @memset(self.scratch, 0);
    var s: u32 = 0;
    while (s < self.sectors_per_cluster) : (s += 1) {
        try self.writeSector(self.clusterSector(cluster) + s, self.scratch);
    }

    // `..` spells the root as cluster zero. Both are dated as the folder's
    // own entry is (metal-vmm QUEUE 218: they were left with no date).
    @memset(self.scratch, 0);
    const when = self.stamp();
    const dot = self.scratch[0..dirent_size];
    @memcpy(dot[0..11], ".          ");
    dot[11] = attr_directory;
    putStamp(dot, when);
    putCluster(dot, cluster);
    const dotdot = self.scratch[dirent_size..][0..dirent_size];
    @memcpy(dotdot[0..11], "..         ");
    dotdot[11] = attr_directory;
    putStamp(dotdot, when);
    putCluster(dotdot, dir_cluster);
    try self.writeSector(self.clusterSector(cluster), self.scratch);

    try self.writeEntry(run, if (needs_long) name else name[0..0], short, attr_directory, cluster, 0, &commit);
    return cluster;
}

/// Walks a slash-separated path, making each missing directory, and
/// answers the last one's cluster.
///
/// **NO DEEPER THAN THE CHECK WALKS** (`max_path_depth`): deeper would
/// make a volume its own check calls `too_deep`. Refused `BadName`.
pub fn makePath(self: *Volume, path: []const u8) Error!Cluster {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    // "" is the root (a top-level file's folder); otherwise every part is
    // named: `a//b/` made `a/b` (the normalization hunt).
    if (hasEmptyPart(path)) {
        props.reachable(@src(), "fat: a folder path with an empty part is refused", null);
        return Error.BadName;
    }
    var cluster: Cluster = 0;
    var at: usize = 0;
    var depth: u32 = 0;
    while (at < path.len) {
        var end = at;
        while (end < path.len and path[end] != '/') end += 1;
        if (end > at) {
            depth += 1;
            if (depth > max_path_depth) {
                props.reachable(@src(), "fat: a directory deeper than the check walks is refused", null);
                return Error.BadName;
            }
            cluster = try self.makeDirIn(cluster, path[at..end]);
        }
        at = end + 1;
    }
    return cluster;
}

/// A whole file at a path, making the directories above it.
pub fn writeFile(self: *Volume, path: []const u8, bytes: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    var slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') slash = i;
    }
    if (slash) |i| {
        const dir = try self.makePath(path[0..i]);
        return self.writeFileIn(dir, path[i + 1 ..], bytes);
    }
    return self.writeFileIn(0, path, bytes);
}

/// **A POSITIONAL WRITE INTO AN EXISTING FILE**: the append `writeFile`
/// cannot express without rewriting the whole file (N messages costing
/// N-squared bytes). It fills the partial cluster already there and links
/// on only what it still needs.
///
/// `offset` may be the end (an append) or inside the file. It may NOT be
/// past the end: FAT has no sparse files, and a hole would be whatever
/// those clusters last held.
///
/// An append stopped part-way leaves the old file whole, since the data
/// lands past its size and the size moves last; it may also leave leaked
/// clusters, or a chain longer than the size, which the next append
/// fills. A write inside the file overwrites in place, not atomically.
pub fn writeInto(self: *Volume, path: []const u8, offset: u32, bytes: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    if (bytes.len == 0) return;
    const entry = try self.open(path);
    if (entry.isDirectory()) {
        props.reachable(@src(), "fat: an overwrite of a directory is refused", null);
        return Error.BadName;
    }
    if (offset > entry.size) { // would leave a hole
        props.reachable(@src(), "fat: an overwrite past a file's end is refused", null);
        return Error.BadChain;
    }

    const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
    const old_size: u32 = entry.size;
    const reach: u64 = @as(u64, offset) + bytes.len;
    if (reach > 0xFFFF_FFFF) {
        props.reachable(@src(), "fat: a write reaching past 4 GiB is refused", null);
        return Error.TooBig;
    }
    const new_size: u32 = @max(old_size, @as(u32, @intCast(reach)));

    // **IN 64 BITS**: rounding a size near 4 GiB up to whole clusters
    // overflows 32.
    const have: u32 = @intCast((@as(u64, old_size) + cluster_bytes - 1) / cluster_bytes);
    const need: u32 = @intCast((@as(u64, new_size) + cluster_bytes - 1) / cluster_bytes);

    // An empty file has no chain (first_cluster 0): the first append is
    // also the allocation.
    //
    // **A FILE'S CLUSTERS ARE COUNTED IN ITS CHAIN, NOT FROM ITS SIZE.**
    // An append links, then writes the data, then the entry's size, so a
    // stop between leaves a chain longer than the size (the check's
    // `long`). Counted in the chain, the next append fills those first.
    var first = entry.first_cluster;
    // A chain made here is the file's only once `setEntry` is tried (the
    // commit); before, a failure gives it back. After, nothing is undone.
    var chain: enum { the_files, made_here } = .the_files;
    var commit: Commit = .{ .clusters = 0 };
    errdefer if (chain == .made_here and commit.landing == .before) self.giveBack(first, need);
    // **CLUSTERS LINKED PAST THE SIZE** (148(c)): a link that landed and
    // a size that did not leave the chain `long` by them, counted
    // (`long_clusters`), or may (`unsure_long`) where the size's landing
    // is unknown. The next append fills them first.
    // A link whose landing is unknown leaves its clusters leaked or
    // long, which may be live either way: both counts' ceilings.
    var linked_past: u32 = 0;
    var maybe_linked: u32 = 0;
    errdefer if (commit.landing != .landed) {
        if (commit.landing == .before) self.long_clusters +|= linked_past else self.unsure_long +|= linked_past;
        self.unsure_long +|= maybe_linked;
    };
    if (have == 0 and first == 0) {
        first = try self.allocChain(need, .{ .bytes = new_size });
        chain = .made_here;
        commit.clusters = need;
    } else {
        const end = try self.chainEnd(first);
        if (need > end.clusters) {
            props.reachable(@src(), "fat: an append links clusters onto a file", .{ .need = need, .have = end.clusters });
            const more = need - end.clusters;
            const extra = try self.allocChain(more, .{ .bytes = new_size });
            // A link that does not land leaves `extra` taken and linked
            // from nothing: given back; unknown, a counted leak; landed,
            // answered or not, linked into the file's chain. As `grow`'s
            // link.
            var link: Landing = .before;
            defer switch (link) {
                .before => self.giveBack(extra, more),
                .landed => {
                    self.linked(more);
                    linked_past = more;
                },
                .unknown => {
                    self.leftUnsure(more);
                    maybe_linked = more;
                },
            };
            try self.fatSet(end.last, extra, &link);
        }
    }

    try self.writeAt(first, offset, bytes);
    try self.setEntry(entry, first, new_size, &commit);
}

/// A chain's last cluster, and how many clusters it holds.
pub fn chainEnd(self: *Volume, first: Cluster) Error!struct { last: Cluster, clusters: u32 } {
    if (!self.inData(first)) {
        props.reachable(@src(), "fat: a file's first cluster is outside the data, at its chain's end", null);
        return Error.BadChain;
    }
    var cluster = first;
    var clusters: u32 = 1;
    var loop = Loop{};
    try loop.pass(first);
    while (try self.nextCluster(cluster)) |next| {
        try loop.pass(next);
        cluster = next;
        clusters += 1;
    }
    return .{ .last = cluster, .clusters = clusters };
}

/// Writes `bytes` into a chain already long enough, at byte `offset`.
/// **A SECTOR THE WRITE STARTS OR ENDS INSIDE IS READ FIRST**: an append
/// rarely starts on a sector boundary, and the bytes before it are the
/// file's.
pub fn writeAt(self: *Volume, first: Cluster, offset: u32, bytes: []const u8) Error!void {
    return self.writeRuns(first, offset, bytes, .kept);
}

/// What fills the rest of a sector a write ends inside: what was there,
/// or zeros (a new file's, so a deleted file's bytes are not carried).
pub const Tail = enum { kept, zeros };

/// **A FILE IS WRITTEN AS RUNS**, as it is read (`readAt`): whole sectors
/// go straight from `bytes`, one request per run of consecutive clusters
/// (at most the disk's `most_sectors`: 1 MiB unless it says less, metal-vmm
/// QUEUE 178); only a sector the write starts or ends inside goes through
/// `scratch`.
pub fn writeRuns(self: *Volume, first: Cluster, offset: u32, bytes: []const u8, tail: Tail) Error!void {
    if (bytes.len == 0) return;
    const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;

    var cluster = first;
    if (!self.inData(cluster)) {
        // `first` is what `chainEnd` walked or `allocChain` made.
        props.@"unreachable"(@src(), "fat: a write finds a file's first cluster outside the data", null);
        return Error.BadChain;
    }
    var skip = offset / cluster_bytes;
    while (skip > 0) : (skip -= 1) {
        cluster = (try self.nextCluster(cluster)) orelse {
            props.reachable(@src(), "fat: a write finds a file's chain ends before its size, writing, at its start", null);
            return Error.BadChain;
        };
        if (cluster < 2) {
            props.@"unreachable"(@src(), "fat: a write finds a file's chain points at a reserved cluster, writing, at its start", null);
            return Error.BadChain;
        }
    }

    var sector_in_cluster: u32 = (offset % cluster_bytes) / sector_size;
    var skip_in_sector: u32 = (offset % cluster_bytes) % sector_size;
    var at: usize = 0;
    // At least one: the mount refused a disk that takes less than a cluster.
    const max_run = self.blk.most_sectors / self.sectors_per_cluster;
    while (at < bytes.len) {
        var run: u32 = 1;
        var last = cluster;
        var after: ?Cluster = null;
        while (true) {
            const have = run * cluster_bytes - sector_in_cluster * sector_size - skip_in_sector;
            if (at + have >= bytes.len) break;
            const next = (try self.nextCluster(last)) orelse break;
            if (run >= max_run or next != last + 1) {
                after = next;
                break;
            }
            last = next;
            run += 1;
        }

        var lba = self.clusterSector(cluster) + sector_in_cluster;
        var sectors_left = run * self.sectors_per_cluster - sector_in_cluster;

        if (skip_in_sector != 0) {
            // Starting inside a sector: keep what is before the offset.
            try self.readSector(lba, self.scratch);
            const n = @min(bytes.len - at, @as(usize, sector_size - skip_in_sector));
            @memcpy(self.scratch[skip_in_sector..][0..n], bytes[at..][0..n]);
            try self.writeSector(lba, self.scratch);
            at += n;
            lba += 1;
            sectors_left -= 1;
            skip_in_sector = 0;
        }

        const whole: u32 = @intCast(@min(@as(usize, sectors_left), (bytes.len - at) / sector_size));
        if (whole > 0) {
            try self.writeSectors(lba, whole, bytes[at..].ptr);
            at += @as(usize, whole) * sector_size;
            lba += whole;
            sectors_left -= whole;
        }

        if (at < bytes.len and sectors_left > 0) {
            // Ending inside a sector.
            switch (tail) {
                .kept => try self.readSector(lba, self.scratch),
                .zeros => @memset(self.scratch, 0),
            }
            const n = bytes.len - at;
            @memcpy(self.scratch[0..n], bytes[at..][0..n]);
            try self.writeSector(lba, self.scratch);
            at += n;
        }

        if (at >= bytes.len) break;
        cluster = after orelse ((try self.nextCluster(last)) orelse {
            props.reachable(@src(), "fat: a write finds a file's chain ends before its size, writing, past its first run", null);
            return Error.BadChain;
        });
        if (cluster < 2) {
            props.@"unreachable"(@src(), "fat: a write finds a file's chain points at a reserved cluster, writing, past its first run", null);
            return Error.BadChain;
        }
        sector_in_cluster = 0;
    }
}

/// Writes a file's size and first cluster into its entry, in place, at
/// `entry.lba`/`entry.slot`: the commit of an append or an overwrite.
/// A failure of the read before it leaves `commit` `before`; a refused
/// write is read back (`commitRefused`).
pub fn setEntry(self: *Volume, entry: Entry, first_cluster: Cluster, size: u32, commit: *Commit) Error!void {
    if (entry.lba == 0) { // never located; refuse to guess
        props.@"unreachable"(@src(), "fat: an entry never located is written back", null);
        return Error.NotFound;
    }
    try self.readSector(entry.lba, self.scratch);
    const e = self.scratch[entry.slot..][0..dirent_size];
    const was = e.*;
    // **A WRITE MOVES THE MODIFICATION TIME** (and the access date);
    // the creation time stays.
    const when = self.stamp();
    putDos(e[22..26], when);
    putLe16(e[18..20], when.date);
    putCluster(e, first_cluster);
    e[28] = @truncate(size);
    e[29] = @truncate(size >> 8);
    e[30] = @truncate(size >> 16);
    e[31] = @truncate(size >> 24);
    const written = e.*;
    self.writeSector(entry.lba, self.scratch) catch |err| {
        commit.done(self, self.commitRefused(entry.lba, entry.slot, &was, &written, commit.clusters));
        return err;
    };
    // **ONLY EVIDENCE OF A LIE UNDOES IT**: the disk answered the write.
    // A read-back that fails says nothing (the answer stands); one that
    // reads the entry as it was says the write landed nothing, and the
    // commit is undone; one that reads neither leaves the commit standing
    // and the old chain unfreed (`read_back_found`).
    if (commit.confirm == .read_back) if (self.readSectors(entry.lba, 1, self.scratch)) {
        const now = self.scratch[entry.slot..][0..dirent_size];
        if (!std.mem.eql(u8, now, &written)) {
            if (self.dirs) |*c| c.drop(entry.lba, 1);
            if (std.mem.eql(u8, now, &was)) {
                props.reachable(@src(), "fat: a commit the disk answered reads back as it was, and is undone", null);
                commit.done(self, .before);
                return Error.WriteFailed;
            }
            props.reachable(@src(), "fat: a commit the disk answered reads back as neither, and the old chain is kept", null);
            commit.read_back_found = .neither;
        }
    } else |_| {};
    commit.done(self, .landed);
}

/// The cluster of a path's parent directory, plus the final component:
/// "a/b/c" -> (cluster of a/b, "c"). A path with no slash is in the root.
pub const Parent = struct { cluster: Cluster, name: []const u8 };

pub fn parentOf(self: *Volume, path: []const u8) Error!Parent {
    // **EVERY PART IS NAMED** (the normalization hunt): a trailing slash
    // was trimmed away, so `remove("x/")` removed `x`.
    if (hasEmptyPart(path)) {
        props.reachable(@src(), "fat: a path with an empty part is refused", null);
        return Error.BadName;
    }
    const trimmed = path;
    if (trimmed.len == 0) {
        props.reachable(@src(), "fat: a path with no name in it is refused", null);
        return Error.BadName;
    }

    var cut: ?usize = null;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '/') cut = i;
    }
    if (cut == null) return .{ .cluster = 0, .name = trimmed };
    const at = cut.?;
    const dir = try self.open(trimmed[0..at]);
    if (!dir.isDirectory()) {
        props.reachable(@src(), "fat: a path whose parent is a file is refused", null);
        return Error.NotFat16;
    }
    return .{ .cluster = dir.first_cluster, .name = trimmed[at + 1 ..] };
}

/// A whole file into `out`, which must hold it; answers its size. It is
/// `readAt` from zero, so every whole-file read exercises the positional
/// read too.
pub fn readFile(self: *Volume, entry: Entry, out: []u8) Error!usize {
    if (entry.isDirectory()) {
        props.reachable(@src(), "fat: a directory read as a file is refused, reading a file whole", null);
        return Error.NotFound;
    }
    if (entry.size > out.len) {
        props.reachable(@src(), "fat: a file larger than the room to read it into is refused", null);
        return Error.TooBig;
    }
    const n = try self.readAt(entry, 0, out[0..entry.size]);
    if (n != entry.size) { // the chain ended before the size did
        // `readAt` refuses a chain that ends early.
        props.@"unreachable"(@src(), "fat: a file's chain ends before its size, reading a file whole", null);
        return Error.BadChain;
    }
    return n;
}

/// How a file sits on the disk.
pub const Layout = struct {
    clusters: u32,
    /// Stretches of consecutive clusters. One is a contiguous file.
    runs: u32,
    /// The most clusters in any one run.
    longest: u32,
};

/// **FOR A PROBE TO CHECK ITS OWN COVERAGE**: readAt takes another path
/// at every break in a chain, which contiguous files never test.
pub fn layout(self: *Volume, entry: Entry) Error!Layout {
    var out = Layout{ .clusters = 0, .runs = 0, .longest = 0 };
    var cluster = entry.first_cluster;
    if (cluster < 2) return out;
    if (!self.inData(cluster)) {
        props.reachable(@src(), "fat: a file's first cluster is outside the data, when its layout is asked", null);
        return Error.BadChain;
    }
    var previous: Cluster = 0;
    var run: u32 = 0;
    while (true) {
        out.clusters += 1;
        if (previous != 0 and cluster == previous + 1) {
            run += 1;
        } else {
            out.runs += 1;
            run = 1;
        }
        out.longest = @max(out.longest, run);
        previous = cluster;
        cluster = (try self.nextCluster(cluster)) orelse break;
        // `nextCluster` refuses a reserved cluster; a loop goes round
        // until the count passes the volume.
        if (cluster < 2) {
            props.@"unreachable"(@src(), "fat: a file's layout finds a reserved cluster", null);
            return Error.BadChain;
        }
        if (out.clusters > self.max_cluster) {
            props.reachable(@src(), "fat: a file's layout counts more clusters than the volume holds: a loop", null);
            return Error.BadChain;
        }
    }
    return out;
}

/// Up to `out.len` bytes from byte `offset`, stopping at the file's end;
/// answers how many. An offset at or past the end reads nothing. The
/// shape of `std.Io.File.readPositionalAll`, for HTTP Range requests: it
/// walks the chain to `offset`'s cluster, reading nothing before it.
pub fn readAt(self: *Volume, entry: Entry, offset: u32, out: []u8) Error!usize {
    if (entry.isDirectory()) {
        props.reachable(@src(), "fat: a directory read as a file is refused, reading at an offset", null);
        return Error.NotFound;
    }
    if (offset >= entry.size or out.len == 0) return 0;
    const want: usize = @min(out.len, entry.size - offset);

    const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
    var cluster = entry.first_cluster;
    if (!self.inData(cluster)) { // a non-empty file has a chain
        props.reachable(@src(), "fat: a file's first cluster is outside the data", null);
        return Error.BadChain;
    }
    // **A CHAIN THAT LOOPS IS REFUSED**: the read stops at the size, so a
    // loop would answer earlier clusters' bytes again as the file's.
    // `Loop` finds one within about two laps, so a file that ends inside
    // those can still answer a repeated cluster.
    var loop = Loop{};
    try loop.pass(cluster);
    var skip = offset / cluster_bytes;
    while (skip > 0) : (skip -= 1) {
        cluster = (try self.nextCluster(cluster)) orelse {
            props.reachable(@src(), "fat: a file's chain ends before its size, reading at an offset, at its start", null);
            return Error.BadChain;
        };
        if (cluster < 2) {
            // `nextCluster` refuses any link outside the data first.
            props.@"unreachable"(@src(), "fat: a file's chain points at a reserved cluster, reading at an offset, at its start", null);
            return Error.BadChain;
        }
        try loop.pass(cluster);
    }

    // **A FILE IS READ AS RUNS** of consecutive clusters: whole sectors
    // go straight into `out`, one request a run; only a sector the read
    // starts or ends inside goes through `scratch`, since the device
    // delivers whole sectors.
    var sector_in_cluster: u32 = (offset % cluster_bytes) / sector_size;
    var skip_in_sector: u32 = (offset % cluster_bytes) % sector_size;
    var got: usize = 0;
    // At least one: the mount refused a disk that takes less than a cluster.
    const max_run = self.blk.most_sectors / self.sectors_per_cluster;
    while (got < want) {
        var run: u32 = 1;
        var last = cluster;
        var after: ?Cluster = null;
        while (true) {
            const have = run * cluster_bytes - sector_in_cluster * sector_size - skip_in_sector;
            const next = try self.nextCluster(last);
            if (next == null) break;
            if (got + have >= want or run >= max_run or next.? != last + 1) {
                after = next;
                break;
            }
            last = next.?;
            try loop.pass(last);
            run += 1;
        }

        var lba = self.clusterSector(cluster) + sector_in_cluster;
        var sectors_left = run * self.sectors_per_cluster - sector_in_cluster;

        if (skip_in_sector != 0) {
            try self.readSector(lba, self.scratch);
            const n = @min(want - got, @as(usize, sector_size - skip_in_sector));
            @memcpy(out[got..][0..n], self.scratch[skip_in_sector..][0..n]);
            got += n;
            lba += 1;
            sectors_left -= 1;
            skip_in_sector = 0;
        }

        const whole: u32 = @intCast(@min(@as(usize, sectors_left), (want - got) / sector_size));
        if (whole > 0) {
            try self.readSectors(lba, whole, out[got..].ptr);
            got += @as(usize, whole) * sector_size;
            lba += whole;
            sectors_left -= whole;
        }

        if (got < want and sectors_left > 0) {
            try self.readSector(lba, self.scratch);
            const n = @min(want - got, @as(usize, sector_size));
            @memcpy(out[got..][0..n], self.scratch[0..n]);
            got += n;
        }

        if (got >= want) break;
        cluster = after orelse {
            props.reachable(@src(), "fat: a file's chain ends before its size, reading at an offset, past its first run", null);
            return Error.BadChain;
        };
        if (cluster < 2) {
            props.@"unreachable"(@src(), "fat: a file's chain points at a reserved cluster, reading at an offset, past its first run", null);
            return Error.BadChain;
        }
        try loop.pass(cluster);
        sector_in_cluster = 0;
    }
    return got;
}
