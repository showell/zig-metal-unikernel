//! disk_fat_fat: the FAT itself. Its copies read and weighed at mount
//! (`cacheFatChecked`), one entry read (`fatGet`) or changed and written to
//! every copy (`fatSet`), and the free count kept with it (metal-vmm QUEUE 173:
//! disk_fat.zig split by the 1,000-line rule; the rules are disk_fat.zig's
//! header).

const std = @import("std");
const builtin = @import("builtin");
const props = @import("coverage");
const dirent = @import("disk_fat_dirent.zig");
const Cluster = dirent.Cluster;
const le32 = dirent.le32;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const sector_size = disk_fat.sector_size;
const Landing = Volume.Landing;
const fat32_mask = disk_fat.fat32_mask;
const Finding = disk_fat.Finding;
const run_sectors = Volume.run_sectors;
const Error = disk_fat.Error;
const Health = disk_fat.Health;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// What `cacheFatChecked` found of the FAT's copies.
pub const Mirrors = struct {
    found: Found = .agree,
    repair: Repair = .none,
    /// Sectors of a copy written to bring it into line with the other.
    repaired: u32 = 0,
    /// The copy the other was brought into line with: 0, the first,
    /// unless the second checked cleaner.
    trusted: u32 = 0,
    /// When `weighed` or `tied`, what the check found with each copy:
    /// problems, then leaked clusters.
    health: [2]Health = .{ .{}, .{} },

    /// How the copies stood, and which is the FAT.
    ///
    /// When `unweighed` or `tied`, **NEITHER IS WRITTEN AT MOUNT**: the
    /// first change to an entry in a differing sector writes the held
    /// sector, the first copy's, whole over the second (`fatSet`).
    pub const Found = enum {
        /// The copies agree.
        agree,
        /// More sectors differ than are weighed: the first is the FAT,
        /// and the others are written from it.
        past_weighing,
        /// They differ, with no room given to weigh them: the first is
        /// the FAT, and the second is written from it.
        unchecked,
        /// They differ, and the check that weighs them failed: the first
        /// is held, and neither is written.
        unweighed,
        /// Each was checked; `trusted` checked cleaner, and the other is
        /// written from it.
        weighed,
        /// Each was checked, and they checked alike: the first is held,
        /// and neither is written, since nothing says which is right.
        tied,
    };

    /// Whether the writes `found` calls for went through.
    pub const Repair = enum {
        /// Nothing to write.
        none,
        written,
        /// The disk refused one: the mount goes on with the FAT held,
        /// and the copies are as far apart as the writes left them.
        refused,
    };
};

/// The most differing sectors weighed copy against copy; past it the
/// first copy is the FAT, and the others are written from it.
pub const max_weighed_sectors = 64;

/// `cacheFatChecked` without a check: the first copy is the FAT.
pub fn cacheFat(self: *Volume, buf: []u8) Error!u32 {
    return (try self.cacheFatChecked(buf, null)).repaired;
}

/// Reads the FAT into `buf` (identity-mapped: the device writes FAT
/// sectors straight out of it), holds it from then on, and brings the
/// copies into line where they differ.
///
/// **COPIES APART ARE BROUGHT INTO LINE, NOT REFUSED.** A machine stopped
/// between a change's writes to the first copy and the second leaves
/// them a sector apart, and refusing such a volume would stop every boot.
///
/// **WHICH COPY IS THE FAT.** Where the copies differ and `seen` is given
/// (room for `check`), the volume is checked with each copy's sectors;
/// the copy with fewer problems, then fewer leaked clusters, is the FAT,
/// and the other is written from it. So a stop keeps whichever copy
/// agrees with the directories, and a first copy that reads wrong is not
/// written over a good second. A tie, or a check that cannot run, holds
/// the first and writes neither. Without `seen`, the first is the FAT.
///
/// **MORE APART THAN ARE KEPT TO WEIGH, THE COPIES ARE WEIGHED WHOLE**
/// (metal-vmm QUEUE 181, `weighWhole`): a FAT run written as one request
/// can leave hundreds of sectors apart after one lie or one cut, and taking
/// the first copy then lost a file the second held whole.
pub fn cacheFatChecked(self: *Volume, buf: []u8, seen: ?[]u8) Error!Mirrors {
    // Allowed to write its own repair: the refusal is the weighing's answer.
    self.writes = .taken;
    const m = try cacheFatCheckedInner(self, buf, seen);
    self.writes = if (m.found == .unweighed) .refused else .taken;
    if (self.writes == .refused) props.reachable(@src(), "fat: a mount whose weighing failed refuses writes", null);
    return m;
}

/// **THE WEIGHING TRIED AGAIN** (metal-vmm QUEUE 188.2), on the held FAT's
/// buffer, as the mount weighs: the first copy read afresh, the copies
/// compared and weighed. Nothing has been written since the mount refused,
/// so the disk is as it was. Writes are allowed again when it succeeds.
pub fn reweigh(self: *Volume, seen: []u8) Error!Mirrors {
    const fat = self.fat orelse return .{};
    self.reweighs +%= 1;
    const m = self.cacheFatChecked(fat, seen) catch |e| {
        self.reweighs_failed +%= 1;
        self.writes = .refused;
        return e;
    };
    if (m.found == .unweighed) self.reweighs_failed +%= 1;
    return m;
}

fn cacheFatCheckedInner(self: *Volume, buf: []u8, seen: ?[]u8) Error!Mirrors {
    if (buf.len < self.fatBytes()) {
        props.reachable(@src(), "fat: a FAT cache buffer too small for the FAT is refused", null);
        return Error.TooBig;
    }
    const fat = buf[0..self.fatBytes()];
    try self.readSectors(self.fat_start, self.sectors_per_fat, fat.ptr);
    // Compared in runs: a FAT32 FAT can be tens of thousands of sectors.
    var run: [run_sectors * sector_size]u8 align(16) = undefined;
    // Every differing sector is counted; the first `max_weighed_sectors`
    // are kept to weigh.
    var differ: [max_weighed_sectors]u32 = undefined;
    var n_differ: usize = 0;
    var copy: u32 = 1;
    while (copy < self.num_fats) : (copy += 1) {
        var s: u32 = 0;
        while (s < self.sectors_per_fat) {
            const n = @min(run_sectors, self.sectors_per_fat - s);
            try self.readSectors(self.fat_start + copy * self.sectors_per_fat + s, n, &run);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                if (std.mem.eql(u8, run[k * sector_size ..][0..sector_size], fat[(s + k) * sector_size ..][0..sector_size])) continue;
                if (n_differ < differ.len) differ[n_differ] = s + k;
                n_differ += 1;
            }
            s += n;
        }
    }
    self.fat = fat;
    if (n_differ == 0) return .{};
    if (n_differ > differ.len) {
        if (seen) |room| return weighWhole(self, fat, room, &run);
        props.reachable(@src(), "fat: more FAT sectors differ than are weighed, and the first copy is the FAT", null);
        const n = self.mirrorFirst(fat, &run) catch {
            repairRefused();
            return .{ .found = .past_weighing, .repair = .refused };
        };
        return .{ .found = .past_weighing, .repair = .written, .repaired = n };
    }
    var m: Mirrors = .{ .found = .unchecked };
    // The second copy's version of each differing sector, kept to weigh.
    var second: [max_weighed_sectors][sector_size]u8 = undefined;
    for (differ[0..n_differ], 0..) |at, i| try self.readSector(self.fat_start + self.sectors_per_fat + at, &second[i]);
    if (seen) |room| {
        // **A WEIGHING THAT CANNOT RUN LEAVES THE CHOICE UNMADE**: a
        // directory that fails to read must not fail the mount. The
        // first copy is held and neither is written, so the second,
        // perhaps the good one, is there for a boot that can weigh.
        const first_health = self.check(room, {}, ignoreFinding) catch {
            unweighed();
            return .{ .found = .unweighed };
        };
        m.health[0] = first_health;
        var first: [max_weighed_sectors][sector_size]u8 = undefined;
        for (differ[0..n_differ], 0..) |at, i| {
            const held = fat[at * sector_size ..][0..sector_size];
            first[i] = held.*;
            held.* = second[i];
        }
        m.health[1] = self.check(room, {}, ignoreFinding) catch {
            for (differ[0..n_differ], 0..) |at, i| fat[at * sector_size ..][0..sector_size].* = first[i];
            unweighed();
            return .{ .found = .unweighed };
        };
        m.found = .weighed;
        const better = m.health[1].problems < m.health[0].problems or
            (m.health[1].problems == m.health[0].problems and m.health[1].leaked < m.health[0].leaked);
        if (better) {
            props.reachable(@src(), "fat: the second FAT copy checks cleaner than the first, and is the FAT", null);
            m.trusted = 1;
            // Mount counted the first copy's free clusters: move the
            // count by every entry the second differs in.
            const per = self.entriesPerSector();
            for (differ[0..n_differ], 0..) |at, i| {
                var e: u32 = 0;
                while (e < per) : (e += 1) {
                    const c = at * per + e;
                    if (c < 2 or c > self.max_cluster) continue;
                    const was = self.entryIn(&first[i], e);
                    const now = self.entryIn(&second[i], e);
                    if (was == 0 and now != 0) {
                        props.always(@src(), self.free_clusters > 0, "fat: the second copy's taken clusters were counted free in the first", null);
                        self.free_clusters -|= 1;
                    }
                    if (was != 0 and now == 0) self.free_clusters += 1;
                }
            }
        } else {
            for (differ[0..n_differ], 0..) |at, i| fat[at * sector_size ..][0..sector_size].* = first[i];
            // **A TIE MERGES TOWARD ALLOCATED** (metal-vmm QUEUE 198.5,
            // P124(f)): neither copy is the FAT, so each differing entry
            // takes its nonzero side, and both copies are written at once.
            // The worst it leaves is a cluster marked taken that nothing
            // holds, which a check reports leaked and fsck reclaims; never
            // a cluster a file holds marked free.
            if (m.health[0].problems == m.health[1].problems and m.health[0].leaked == m.health[1].leaked) {
                props.reachable(@src(), "fat: FAT copies apart check alike, and are merged toward allocated", null);
                m.found = .tied;
                for (differ[0..n_differ], 0..) |at, i| {
                    const held = fat[at * sector_size ..][0..sector_size];
                    self.mergeTowardAllocated(held, &second[i], at);
                    m.repaired += writeMerged(self, at, held, &first[i], &second[i]) catch {
                        repairRefused();
                        m.repair = .refused;
                        return m;
                    };
                }
                m.repair = .written;
                return m;
            }
        }
    }
    // The copy not trusted is written from the held FAT. **A REPAIR THE
    // DISK REFUSES DOES NOT STOP THE MOUNT**: the FAT is held either way,
    // and later changes write each sector they touch to every copy.
    const into = if (m.trusted == 0) self.fat_start + self.sectors_per_fat else self.fat_start;
    for (differ[0..n_differ]) |at| {
        self.writeSector(into + at, fat[at * sector_size ..][0..sector_size]) catch {
            repairRefused();
            m.repair = .refused;
            return m;
        };
        m.repaired += 1;
    }
    m.repair = .written;
    return m;
}

/// **COPIES WEIGHED WHOLE**, where more sectors differ than are kept to
/// weigh one by one: the volume checked with the first copy held, then
/// with the second read over it (the first is still on the disk, so no
/// memory is kept for it). The one with fewer problems, then fewer leaked
/// clusters, is the FAT, and the other is written from it, as in
/// `cacheFatChecked`; a tie holds the first and writes neither. A check,
/// or the read of the second, that fails leaves the first held and
/// neither written (`unweighed`).
///
/// Why it holds for a lie and a cut alike: the copies are written one
/// after the other, so one lie or one cut leaves at most one of them other
/// than the writes meant. A copy that lost part of a committed chain
/// checks broken; one that holds part of an uncommitted chain checks
/// leaked; the other copy checks as the volume should.
fn weighWhole(self: *Volume, fat: []u8, room: []u8, run: *[run_sectors * sector_size]u8) Error!Mirrors {
    props.reachable(@src(), "fat: more FAT sectors differ than are kept to weigh, and the copies are weighed whole", null);
    var m: Mirrors = .{ .found = .weighed };
    m.health[0] = self.check(room, {}, ignoreFinding) catch {
        unweighed();
        return .{ .found = .unweighed };
    };
    const second: ?Health = if (self.readSectors(self.fat_start + self.sectors_per_fat, self.sectors_per_fat, fat.ptr))
        self.check(room, {}, ignoreFinding) catch null
    else |_|
        null;
    m.health[1] = second orelse {
        try self.readSectors(self.fat_start, self.sectors_per_fat, fat.ptr);
        unweighed();
        return .{ .found = .unweighed };
    };
    const better = m.health[1].problems < m.health[0].problems or
        (m.health[1].problems == m.health[0].problems and m.health[1].leaked < m.health[0].leaked);
    if (better) {
        props.reachable(@src(), "fat: the second FAT copy, weighed whole, checks cleaner than the first, and is the FAT", null);
        m.trusted = 1;
        // Mount counted the first copy's free clusters.
        self.free_clusters = (try self.deriveFrom(.held)).free;
    } else {
        try self.readSectors(self.fat_start, self.sectors_per_fat, fat.ptr);
        if (m.health[0].problems == m.health[1].problems and m.health[0].leaked == m.health[1].leaked) {
            // Merged toward allocated, as in `cacheFatChecked` (198.5).
            props.reachable(@src(), "fat: FAT copies apart, weighed whole, check alike, and are merged toward allocated", null);
            m.found = .tied;
            m.repaired = mergeWhole(self, fat, run) catch {
                repairRefused();
                m.repair = .refused;
                return m;
            };
            m.repair = .written;
            return m;
        }
    }
    m.repaired = mirrorHeld(self, fat, run, m.trusted) catch {
        repairRefused();
        m.repair = .refused;
        return m;
    };
    m.repair = .written;
    return m;
}

/// Every other copy written from the first where they differ.
pub fn mirrorFirst(self: *Volume, fat: []u8, run: *[run_sectors * sector_size]u8) Error!u32 {
    return mirrorHeld(self, fat, run, 0);
}

/// The second copy read run by run against the held first; each sector
/// that differs merged toward allocated and written to both.
fn mergeWhole(self: *Volume, fat: []u8, run: *[run_sectors * sector_size]u8) Error!u32 {
    var repaired: u32 = 0;
    var s: u32 = 0;
    while (s < self.sectors_per_fat) {
        const n = @min(run_sectors, self.sectors_per_fat - s);
        try self.readSectors(self.fat_start + self.sectors_per_fat + s, n, run);
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const held = fat[(s + k) * sector_size ..][0..sector_size];
            const second = run[k * sector_size ..][0..sector_size];
            if (std.mem.eql(u8, held, second)) continue;
            const first = held.*;
            self.mergeTowardAllocated(held, second, s + k);
            repaired += try writeMerged(self, s + k, held, &first, second);
        }
        s += n;
    }
    return repaired;
}

/// FAT sector `at`, merged, written to each copy it differs from.
fn writeMerged(self: *Volume, at: u32, merged: *[sector_size]u8, first: *const [sector_size]u8, second: *const [sector_size]u8) Error!u32 {
    var n: u32 = 0;
    if (!std.mem.eql(u8, merged, first)) {
        try self.writeSector(self.fat_start + at, merged);
        n += 1;
    }
    if (!std.mem.eql(u8, merged, second)) {
        try self.writeSector(self.fat_start + self.sectors_per_fat + at, merged);
        n += 1;
    }
    return n;
}

/// Every copy but `trusted` written from the held FAT where they differ.
fn mirrorHeld(self: *Volume, fat: []u8, run: *[run_sectors * sector_size]u8, trusted: u32) Error!u32 {
    var repaired: u32 = 0;
    var copy: u32 = 0;
    while (copy < self.num_fats) : (copy += 1) {
        if (copy == trusted) continue;
        var s: u32 = 0;
        while (s < self.sectors_per_fat) {
            const n = @min(run_sectors, self.sectors_per_fat - s);
            const at = self.fat_start + copy * self.sectors_per_fat + s;
            try self.readSectors(at, n, run);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const first = fat[(s + k) * sector_size ..][0..sector_size];
                if (std.mem.eql(u8, run[k * sector_size ..][0..sector_size], first)) continue;
                try self.writeSector(at + k, first);
                repaired += 1;
            }
            s += n;
        }
    }
    return repaired;
}

pub fn ignoreFinding(_: void, _: Finding) void {}

/// One coverage site for every repair write the disk refused.
pub fn repairRefused() void {
    props.reachable(@src(), "fat: a repair of the FAT's copies is refused by the disk, and the mount goes on", null);
}

/// One coverage site for both checks of a weighing that could not run.
pub fn unweighed() void {
    props.reachable(@src(), "fat: FAT copies apart cannot be weighed (the check failed), and neither is written over", null);
}

/// The FAT entry for a cluster.
pub fn fatGet(self: *Volume, cluster: Cluster) Error!Cluster {
    const width = self.entryBytes();
    const at = @as(u32, cluster) * width;
    if (self.fat) |fat| {
        return self.entryIn(fat[at - at % sector_size ..][0..sector_size], at % sector_size / width);
    }
    try self.readSector(self.fat_start + at / sector_size, self.scratch);
    return self.entryIn(self.scratch, at % sector_size / width);
}

/// Puts `value` into the entry at byte `at` of a FAT sector. **On FAT32
/// the top four bits are kept**: the spec reserves them, and another tool
/// may have set them.
pub fn putEntry(self: *const Volume, sector: []u8, at: u32, value: Cluster) void {
    switch (self.kind) {
        .fat16 => {
            sector[at] = @truncate(value);
            sector[at + 1] = @truncate(value >> 8);
        },
        .fat32 => {
            const kept = le32(sector[at..][0..4]) & ~fat32_mask;
            std.mem.writeInt(u32, sector[at..][0..4], kept | (value & fat32_mask), .little);
        },
    }
}

/// **WHETHER A FAILED WRITE OF THE FIRST COPY LANDED, FOR THE ONE ENTRY
/// IN DOUBT**, read back once into scratch: as `value`, `landed`; as
/// `old`, `before`; anything else (rot, a read-back that failed too),
/// `unknown`. Only that entry is read: the held FAT stays the mirror for
/// every other. **THIS ONE READ IS THE VERDICT** for `fatSet` and its
/// caller both: a caller that read the disk again could hear another.
pub fn fatRefused(self: *Volume, lba: u32, at: u32, old: Cluster, value: Cluster) Landing {
    const width = self.entryBytes();
    self.readSector(lba, self.scratch) catch {
        props.reachable(@src(), "fat: a FAT sector whose write failed cannot be read again", null);
        return .unknown;
    };
    const now = self.entryIn(self.scratch, at % sector_size / width);
    if (now == value) return .landed;
    if (now == old) return .before;
    props.reachable(@src(), "fat: a FAT sector whose write failed reads back as neither old nor new", null);
    return .unknown;
}

/// Sets a cluster's FAT entry **in every copy of the FAT**, the one place
/// a FAT entry changes after mount, and moves `free_clusters` with it.
///
/// **THE FIRST COPY'S WRITE IS THE CHANGE**: its failure is the caller's
/// error, and `fatRefused`'s verdict is the caller's too (`landing`).
/// The held entry and the count go back only on `before`; `unknown` is
/// taken as written, so the count never says free what may be linked.
/// A later copy that fails is counted apart (`copyApart`) for the next
/// mount to mend, not the operation's failure.
pub fn fatSet(self: *Volume, cluster: Cluster, value: Cluster, landing: ?*Landing) Error!void {
    try self.forgetFsInfo();
    const width = self.entryBytes();
    const at = @as(u32, cluster) * width;
    const in_sector = at / sector_size;
    if (self.fat) |fat| {
        // The held sector is written whole to each copy, none read back
        // first; where the mount left the copies apart (a tie, a weighing
        // that could not run, a repair refused), this write mends them.
        const sector = fat[in_sector * sector_size ..][0..sector_size];
        const old = self.entryIn(sector, at % sector_size / width);
        self.putEntry(sector, at % sector_size, value);
        self.writeSector(self.fat_start + in_sector, sector) catch |e| {
            const verdict = self.fatRefused(self.fat_start + in_sector, at, old, value);
            if (landing) |l| l.* = verdict;
            switch (verdict) {
                .before => self.putEntry(sector, at % sector_size, old),
                // Taken as written: the held entry and the count keep
                // the value, and the other copies are written as after
                // a write that answered.
                .landed => {
                    self.keepCount(old, value);
                    self.writeCopies(in_sector, sector);
                },
                // And the first copy is written again, once: left as
                // the disk had it, an unchecked mount (`cacheFat`) would
                // mirror it over the others. A second failure leaves it
                // counted apart.
                .unknown => {
                    self.keepCount(old, value);
                    self.writeSector(self.fat_start + in_sector, sector) catch self.copyApart();
                    self.writeCopies(in_sector, sector);
                },
            }
            return e;
        };
        if (landing) |l| l.* = .landed;
        self.keepCount(old, value);
        self.writeCopies(in_sector, sector);
        return;
    }
    var copy: u32 = 0;
    while (copy < self.num_fats) : (copy += 1) {
        const lba = self.fat_start + copy * self.sectors_per_fat + in_sector;
        if (copy == 0) {
            try self.readSector(lba, self.scratch);
            // Without a held FAT, every read follows the disk's first copy.
            const old = self.entryIn(self.scratch, at % sector_size / width);
            self.putEntry(self.scratch, at % sector_size, value);
            self.writeSector(lba, self.scratch) catch |e| {
                // The count by the verdict, as above. Taken as written,
                // the other copies are left and counted apart, for the
                // next mount to weigh.
                const verdict = self.fatRefused(lba, at, old, value);
                if (landing) |l| l.* = verdict;
                switch (verdict) {
                    .before => {},
                    .landed, .unknown => {
                        self.keepCount(old, value);
                        self.copyApart();
                    },
                }
                return e;
            };
            if (landing) |l| l.* = .landed;
            self.keepCount(old, value);
            continue;
        }
        self.readSector(lba, self.scratch) catch {
            self.copyApart();
            continue;
        };
        self.putEntry(self.scratch, at % sector_size, value);
        self.writeSector(lba, self.scratch) catch self.copyApart();
    }
}

/// The held sector to every copy past the first; one that fails is
/// counted apart (`copyApart`).
pub fn writeCopies(self: *Volume, in_sector: u32, sector: *[sector_size]u8) void {
    var c: u32 = 1;
    while (c < self.num_fats) : (c += 1) {
        self.writeSector(self.fat_start + c * self.sectors_per_fat + in_sector, sector) catch self.copyApart();
    }
}

/// A FAT copy that could not be written (one past the first, or the
/// first written again after a failure): apart until a later write of
/// that sector or the next mount mends it.
pub fn copyApart(self: *Volume) void {
    self.fat_copies_failed +%= 1;
    props.reachable(@src(), "fat: a FAT copy fails to write, and is left apart", .{ .count = self.fat_copies_failed });
}

/// **FSINFO'S FREE COUNT AND NEXT-FREE HINT, MARKED UNKNOWN**
/// (0xFFFFFFFF) before the first change to a FAT32 volume's FAT after
/// mount, in FSInfo and in the backup boot sector's copy (FAT32.md §7).
/// Linux recomputes a hint that says unknown; one set and wrong is what
/// fsck.fat reports. A sector without FSInfo's signatures is skipped.
///
/// `fsinfo` is `said_unknown` only after every write has landed; a failure
/// is the change's error, and the next change tries again.
pub fn forgetFsInfo(self: *Volume) Error!void {
    if (self.kind != .fat32 or self.fsinfo == .said_unknown) return;
    for ([_]u32{ self.fsinfo_sector, self.backup_boot + 1 }) |lba| {
        if (lba == 0 or lba >= self.fat_start) continue; // no such sector in the reserved area
        try self.readSector(lba, self.scratch);
        if (le32(self.scratch[0..4]) != 0x4161_5252 or le32(self.scratch[484..488]) != 0x6141_7272) continue;
        std.mem.writeInt(u32, self.scratch[488..492], 0xFFFF_FFFF, .little);
        std.mem.writeInt(u32, self.scratch[492..496], 0xFFFF_FFFF, .little);
        try self.writeSector(lba, self.scratch);
    }
    props.reachable(@src(), "fat: a FAT32 volume's FSInfo count is let go", null);
    self.fsinfo = .said_unknown;
}

/// Moves `free_clusters` for one FAT entry going from `old` to `new`:
/// **THE DERIVED VALUE, MOVED IN STEP WITH ITS SOURCE**; the next mount
/// re-derives it. Saturating: a count gone wrong must not stop the
/// machine; the host tests compare it with a fresh one.
pub fn keepCount(self: *Volume, old: Cluster, new: Cluster) void {
    if (old == 0 and new != 0) props.always(@src(), self.free_clusters > 0, "fat: the kept free count never runs below zero", null);
    // Records the fewest free clusters any run left.
    if (old == 0 and new != 0) props.alwaysGreaterThan(@src(), self.free_clusters, 0, "fat: a cluster is taken with one free", null);
    if (old == 0 and new != 0) self.free_clusters -|= 1;
    if (old != 0 and new == 0) self.free_clusters += 1;
}
