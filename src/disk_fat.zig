//! FAT16 and FAT32 (Microsoft's FAT specification, fatgen103): mount a
//! volume, read and write whole files, append, rename, remove, list and make
//! directories with VFAT long names, and check the volume as fsck would.
//! Not supported: FAT12, and renaming a directory.
//!
//! **NOTHING HERE ALLOCATES.** The caller supplies every buffer, because a
//! buffer the device reads or writes must be identity-mapped physical memory.
//!
//! **WHAT A `Volume` HOLDS IN MEMORY.** The disk is the source of every fact
//! here; nothing promised lives only in memory, and the next mount rebuilds
//! all of it. Each copy has a role, and a rule for when it disagrees:
//!
//! - the geometry (`fat_start` .. `data_start`, `kind`, `root_cluster`,
//!   `serial`): a cache of the boot sector, read once at `mount`. Nothing on
//!   this machine writes the boot sector, so it cannot go stale.
//! - `fat`, the held FAT: a mirror of the FAT, read whole at mount from the
//!   copy `cacheFatChecked` trusts. A change is made in it and written as the
//!   whole sector to every copy (`fatSet`), so where the copies disagree with
//!   it, the next change to that sector writes them over.
//! - `free_clusters`: derived from the FAT. Counted at mount, then moved
//!   entry by entry (`keepCount`); `derive()` recomputes it.
//! - `alloc_hint`: a hint. Wrong costs a longer search or a different free
//!   cluster, never a used one (`allocChain`).
//! - `fsinfo`: a cache of "FSInfo's hints say unknown on the disk".
//!   `as_mounted` at every mount, so each mount writes FSInfo once.
//! - `dirs`: a cache of sectors, exact or absent: a write that succeeds
//!   updates what it holds, a write that fails drops it.
//! - `scratch`, `dir_burst`, a `Lister`'s sector: buffers in motion, meaning
//!   nothing past the operation that filled them.
//!
//! FSInfo's free count and next-free hint are for other systems; this
//! machine never reads them for its own use.
//!
//! **ONE `Volume`, SEVEN FILES** (metal-vmm QUEUE 173, the 1,000-line rule):
//! its fields, the mount and the sector primitives are here; the FAT and its
//! copies are in disk_fat_fat.zig, cluster chains and their ledger in
//! disk_fat_chain.zig, directories and names in disk_fat_dir.zig, files
//! written and read in disk_fat_file.zig, renames and removes in
//! disk_fat_remove.zig, and the check in disk_fat_check.zig. Each member
//! there is named in `Volume` (`pub const fatSet = disk_fat_fat.fatSet;`),
//! so a call reads `vol.fatSet(...)` wherever it is made.

const std = @import("std");
const builtin = @import("builtin");
const virtio_blk = @import("virtio_blk.zig");
const props = @import("coverage");
const plant = @import("plant.zig");

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const dirent = @import("disk_fat_dirent.zig");
const disk_fat_fat = @import("disk_fat_fat.zig");
const disk_fat_chain = @import("disk_fat_chain.zig");
const disk_fat_dir = @import("disk_fat_dir.zig");
const disk_fat_file = @import("disk_fat_file.zig");
const disk_fat_remove = @import("disk_fat_remove.zig");
const disk_fat_check = @import("disk_fat_check.zig");
const dirent_size = dirent.dirent_size;
const attr_volume_label = dirent.attr_volume_label;
const attr_directory = dirent.attr_directory;
const attr_long_name = dirent.attr_long_name;
pub const Cluster = dirent.Cluster;
const le16 = dirent.le16;
const le32 = dirent.le32;
pub const max_name = dirent.max_name;
pub const Dos = dirent.Dos;
pub const Entry = dirent.Entry;
const shortChecksum = dirent.shortChecksum;
const long_offsets = dirent.long_offsets;
const LongName = dirent.LongName;
const putCluster = dirent.putCluster;
const putLe16 = dirent.putLe16;
const putDos = dirent.putDos;
const decode = dirent.decode;
const encode = dirent.encode;
const longParts = dirent.longParts;
const needsLongName = dirent.needsLongName;
const eqlBytes = dirent.eqlBytes;
const upper = dirent.upper;
const eqlFold = dirent.eqlFold;

pub const sector_size: u32 = 512;
pub const Error = error{
    NotFat16,
    BadBootSector,
    ReadFailed,
    WriteFailed,
    NotFound,
    TooBig,
    BadChain,
    BadName,
    Full,
    DirectoryFull,
    /// FAT32 with mirroring off (BPB_ExtFlags bit 7): one FAT is live and the
    /// rest stale, and this machine writes every copy.
    NotMirrored,
    /// A FAT32 version this machine does not know (BPB_FSVer is not 0).
    FatVersion,
    /// A FAT32 root cluster outside the data region.
    BadRoot,
    /// A volume that runs past sector 2^32: sector numbers here are 32 bits.
    VolumeTooLarge,
    /// More clusters than FAT32's 28-bit cluster numbers can name.
    TooManyClusters,
    /// A file asked to replace a directory, which Linux refuses too (EISDIR).
    IsDirectory,
    /// A new name that is another entry's 8.3 alias: a second entry would
    /// share it, which fsck calls a duplicate.
    NameTaken,
    /// A disk whose most in one request is less than a cluster (metal-vmm
    /// QUEUE 178): a cluster is never split across requests, so such a disk
    /// is refused at mount.
    RequestSmallerThanCluster,
    /// The FAT's copies are apart and could not be weighed (metal-vmm QUEUE
    /// 188.2): every write is refused, and nothing is written, until a
    /// weighing succeeds (`reweigh`).
    WritesRefused,
};

/// **WHICH FAT A VOLUME IS**, decided as the specification decides it: by
/// its count of clusters, never by what the boot sector calls itself.
/// Fewer than 4,085 is FAT12 (refused); fewer than 65,525 is FAT16; more is
/// FAT32.
pub const Kind = enum { fat16, fat32 };

/// The first end-of-chain mark: 0xFFF8 and up ends a FAT16 chain.
const chain_end: Cluster = 0xFFF8;
/// The bad-cluster mark. Such a cluster is in use by nothing, and is not a
/// leak.
const bad_cluster: Cluster = 0xFFF7;
/// FAT32's entries are 28 bits; the top four are reserved, and its marks
/// are 28-bit too.
pub const fat32_mask: Cluster = 0x0FFF_FFFF;

/// `Volume.freeEntries` for entries of type `T` (little-endian on the
/// disk), the bits `mask` holds: 16 entries a vector where the host is
/// little-endian too (every target this runs on), then one at a time.
fn freeOf(comptime T: type, comptime mask: T, sectors: []const u8, lo: u32, hi: u32, first: *?u32) u32 {
    const lanes = 16;
    const V = @Vector(lanes, T);
    const w = @sizeOf(T);
    var free: u32 = 0;
    var i = lo;
    if (comptime @import("builtin").cpu.arch.endian() == .little) {
        while (i + lanes <= hi) : (i += lanes) {
            const v: V = @bitCast(sectors[i * w ..][0 .. lanes * w].*);
            const zero: u16 = @bitCast((v & @as(V, @splat(mask))) == @as(V, @splat(0)));
            if (zero == 0) continue;
            free += @popCount(zero);
            if (first.* == null) first.* = i + @ctz(zero);
        }
    }
    while (i < hi) : (i += 1) {
        if (std.mem.readInt(T, sectors[i * w ..][0..w], .little) & mask != 0) continue;
        free += 1;
        if (first.* == null) first.* = i;
    }
    return free;
}
const fat32_chain_end: Cluster = 0x0FFF_FFF8;
const fat32_bad_cluster: Cluster = 0x0FFF_FFF7;

/// What `Volume.check` found wrong with a volume.
pub const Problem = enum {
    /// A chain runs into a free cluster, past the last cluster, or into the
    /// bad-cluster mark (or a directory has no chain at all). `cluster` is
    /// the last one it holds.
    broken,
    /// A chain reaches a cluster another chain holds already, or one earlier
    /// in itself: a cross-link, or a loop. `cluster` is that cluster; the
    /// path is the second chain to reach it.
    crossed,
    /// A file's chain holds fewer clusters than its size needs (`count`).
    short,
    /// A file's chain holds more clusters than its size needs (`count`): the
    /// tail is in use and nothing can reach it.
    long,
    /// `count` clusters from `cluster` are marked in use and nothing holds
    /// them: what a write that stopped part-way leaves behind.
    leaked,
    /// The FAT's copies differ, in `count` sectors; `cluster` is the first
    /// entry that does.
    fats_differ,
    /// "." is not its own directory, or ".." not its parent, or the root
    /// holds either.
    bad_dot,
    /// FAT32's FSInfo says a free count (`count`) that is set and wrong, or
    /// a next-free hint outside the data region (`cluster`): what fsck.fat
    /// reports. Unknown (0xFFFFFFFF) is always right.
    fsinfo,
    /// A directory deeper than the check walks. That is a limit of the
    /// check, not damage: nothing under it was checked, and since what it
    /// holds would look leaked, leaks were not looked for at all.
    too_deep,

    /// **DAMAGE, OR WHAT A STOP LEAVES.** A machine stopped part-way may
    /// leave clusters leaked, a chain long (an append's), the FAT's copies
    /// apart (the next mount mends them), or FSInfo's count stale; and
    /// `too_deep` is the check's limit. The rest no stop of this driver
    /// leaves.
    pub fn damage(p: Problem) bool {
        return switch (p) {
            .broken, .crossed, .short, .bad_dot => true,
            .leaked, .long, .fats_differ, .fsinfo, .too_deep => false,
        };
    }
};

pub const Finding = struct {
    problem: Problem,
    /// Where it was found, from the root ("/data/chat/plan.md"); empty for
    /// the volume as a whole. It points into the checker: a caller that
    /// keeps it copies it.
    path: []const u8,
    cluster: Cluster = 0,
    count: u32 = 0,
};

/// What `Volume.check` walked, and how many findings it made.
pub const Health = struct {
    files: u32 = 0,
    directories: u32 = 0,
    /// Clusters held by the files and directories walked.
    used: u32 = 0,
    leaked: u32 = 0,
    /// **LONG-NAME PARTS NO SHORT ENTRY CLOSES** (metal-vmm 148(b,c)): a
    /// part not in a run that its short entry closes whole, as fsck.fat
    /// finds and deletes them. Not a problem (a stop and a failed cleanup
    /// both leave them, and nothing reads them): a count, for a caller to
    /// hold `Volume.orphaned_parts` to.
    orphaned_parts: u32 = 0,
    /// **AND THE RUNS THEY ARE IN** (metal-vmm 152): fsck.fat says one
    /// "Orphaned long file name part" line a run, the whole name, so a judge
    /// holds its lines to runs, not parts.
    orphaned_runs: u32 = 0,
    /// **LONG-NAME PARTS IN A RUN THAT DOES NOT START AS ONE**: no part
    /// flagged last (0x40) before them. fsck.fat calls each a fragment
    /// "outside a LFN sequence" and leaves it; this driver never leaves one
    /// (it clears a name from its end, 152).
    lfn_fragments: u32 = 0,
    problems: u32 = 0,

    pub fn clean(self: Health) bool {
        return self.problems == 0;
    }
};

/// **SECTORS, HELD** (`Volume.dirs`): direct-mapped, one sector a slot, a
/// slot's key the sector's LBA plus one (0: empty). A sector put where
/// another is held replaces it.
pub const DirCache = struct {
    keys: []u32,
    data: []u8,
    hits: u64 = 0,
    misses: u64 = 0,

    fn slot(c: *const DirCache, lba: u32) usize {
        return @as(usize, (lba *% 2654435761) >> 7) % c.keys.len;
    }

    fn at(c: *DirCache, i: usize) *[sector_size]u8 {
        return c.data[i * sector_size ..][0..sector_size];
    }

    /// The sector at `lba`, if held.
    pub fn get(c: *DirCache, lba: u32) ?*[sector_size]u8 {
        const i = c.slot(lba);
        if (c.keys[i] == lba +% 1) {
            c.hits += 1;
            return c.at(i);
        }
        c.misses += 1;
        return null;
    }

    pub fn put(c: *DirCache, lba: u32, bytes: *const [sector_size]u8) void {
        const i = c.slot(lba);
        c.keys[i] = lba +% 1;
        @memcpy(c.at(i), bytes);
    }

    /// Copies `n` sectors from `lba` into `out` if every one is held.
    pub fn copyOut(c: *DirCache, lba: u32, n: u32, out: []u8) bool {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] != lba + k +% 1) {
                c.misses += 1;
                return false;
            }
        }
        k = 0;
        while (k < n) : (k += 1) @memcpy(out[k * sector_size ..][0..sector_size], c.at(c.slot(lba + k)));
        c.hits += 1;
        return true;
    }

    /// `n` sectors from `lba` were written from `from`: each one held takes
    /// what was written.
    fn wrote(c: *DirCache, lba: u32, n: u32, from: [*]const u8) void {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] == lba + k +% 1) @memcpy(c.at(i), from[k * sector_size ..][0..sector_size]);
        }
    }

    /// A write to `n` sectors from `lba` failed: what they hold is unknown.
    pub fn drop(c: *DirCache, lba: u32, n: u32) void {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] == lba + k +% 1) c.keys[i] = 0;
        }
    }
};

/// **WHAT A VOLUME'S FAT SAYS, WORKED OUT AFRESH** (`Volume.derive`): its
/// free clusters, and the first of them. `free_clusters` must equal the
/// first; `alloc_hint`, a hint, must never be above the second.
pub const Derived = struct {
    free: u32,
    /// None when the volume is full.
    first_free: ?Cluster,
};

/// **A PATH BUILT WRONG**: a doubled, leading or trailing slash, an empty
/// part. The empty path itself is the root, and has none.
pub fn hasEmptyPart(path: []const u8) bool {
    if (path.len == 0) return false;
    return path[0] == '/' or path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null;
}

/// Whether a volume takes writes (`Volume.writes`).
pub const Writes = enum { taken, refused };

pub const Volume = struct {
    blk: *virtio_blk.Block,
    /// **EVERY SECTOR WRITE TRIED**, landed or not: a check made a slice at a
    /// time (`CheckRun`) starts again when this moves under it.
    changes: u64 = 0,

    /// **WHERE THE DATES COME FROM**: the host's wall clock (io.zig sets it
    /// once the RTC is read). Null, or answering null, writes entries with
    /// no date rather than a plausible wrong one.
    clock: ?*const fn () ?i64 = null,
    /// One sector of identity-mapped scratch. **IN MOTION, NOT A COPY**: one
    /// step's sector at a time, never read for what an earlier one left.
    scratch: *[sector_size]u8,

    /// Where this volume starts on the disk. **Every other sector number is
    /// relative to the volume**; this is the only place the disk's own
    /// numbering appears.
    start_lba: u32,

    sectors_per_cluster: u32,
    fat_start: u32,
    sectors_per_fat: u32,
    num_fats: u32,
    root_start: u32,
    root_sectors: u32,
    root_entries: u32,
    data_start: u32,
    kind: Kind = .fat16,
    /// FAT32's root is a chain, from here (BPB_RootClus). Cluster 0 still
    /// means "the root" throughout this file's API, as a `..` entry spells
    /// it on both kinds; `dirStart` turns it into this.
    root_cluster: Cluster = 0,
    /// FAT32's FSInfo sector (BPB_FSInfo) and backup boot sector
    /// (BPB_BkBootSec, its FSInfo copy the sector after it).
    fsinfo_sector: u32 = 0,
    backup_boot: u32 = 0,
    /// **A CACHE OF A FACT ON THE DISK**: whether this mount has marked
    /// FSInfo's hints unknown (`forgetFsInfo`). `said_unknown` only once the
    /// writes have landed; never re-read, since nothing else on this machine
    /// writes FSInfo.
    fsinfo: enum { as_mounted, said_unknown } = .as_mounted,
    /// The highest cluster number the data region holds.
    max_cluster: Cluster,
    /// **HOW MANY CLUSTERS ARE FREE: DERIVED, AND MOVED.** Derived from the
    /// FAT at mount, then moved by `keepCount` as each entry goes from free
    /// to used or back, the failure paths included, so `space` is a field
    /// read. A count gone wrong stays wrong until the next mount;
    /// `countFreeAgain` recounts, for tests and simulators.
    ///
    /// **ONE COPY OF A VOLUME WRITES.** Copies of a `Volume` share the held
    /// FAT (a slice) but not this count, so two that both wrote would each
    /// count only their own writes. Only io.zig's copy writes.
    free_clusters: u32 = 0,
    /// **WHERE THE NEXT ALLOCATION STARTS LOOKING** (FAT32.md §8): a hint,
    /// 2 at every mount. Every cluster below it is in use: it moves up only
    /// past clusters an allocation took or found taken, and down to any
    /// cluster `freeChain` gives back. So allocation chooses the cluster a
    /// search from 2 would, without rescanning FAT32's millions of entries.
    /// Allocation reads the FAT at every candidate, so a hint past a free
    /// cluster costs only the choice: a cluster further on, or a wrap.
    alloc_hint: Cluster = 2,
    /// **CLEANUPS THAT FAILED**: clusters given back on an error, a chain or
    /// long-name parts cleared after a commit, or a failed write's entry that
    /// could not be read exactly. Each leaves a leak the boot's check
    /// reports; counted here and said by a property, never the operation's
    /// error.
    cleanups_failed: u64 = 0,
    /// **CLUSTERS LEFT A COUNTED LEAK**, where the cleanup knows how many:
    /// a failed write's chain left taken (`leftLeaked`), what a give-back
    /// did not free (`notGivenBack`), what a chain freed after a commit
    /// left (`chainLeft`, walked to count it). Exact: a leftover that may be
    /// live is `unsure_clusters`. A judge holds what fsck.fat reclaims to
    /// it: more found than counted is a leak nobody counted.
    leaked_clusters: u64 = 0,
    /// **LONG-NAME PARTS LEFT ORPHANED**: a part whose clearing after a
    /// commit failed (`partLeft`). Parts a failed new entry wrote before its
    /// short entry are counted too (`writeEntry`), and one whose own write
    /// failed among them, since it may have landed.
    orphaned_parts: u64 = 0,
    /// **THE RUNS THOSE PARTS ARE IN** (metal-vmm 152): what fsck.fat
    /// counts, a line a run. `unsure_runs` beside `unsure_parts`.
    orphaned_runs: u64 = 0,
    unsure_runs: u64 = 0,
    /// **LEFTOVERS THAT MAY BE LIVE** (metal-vmm 148(a)): clusters and
    /// long-name parts a failed write may have left, where no exact read
    /// could say (`Landing.unknown`): an entry that may point at them, or
    /// may not. Apart from the two counts above, which are exact, so what a
    /// check or fsck.fat finds is at least those and at most those plus
    /// these.
    unsure_clusters: u64 = 0,
    unsure_parts: u64 = 0,
    /// **LEAKS OF A SIZE NOT KNOWN**: a chain left after a commit that could
    /// not be walked to count it. While any is, what is found has no upper
    /// bound in the counts.
    unsized_leaks: u64 = 0,
    /// **CLUSTERS IN A CHAIN PAST WHAT ITS SIZE NEEDS** (148(c)): an
    /// append whose link landed and whose size did not (the check's `long`,
    /// which fsck.fat truncates). `unsure_long` where the size's landing is
    /// unknown. The next append fills them first, and they are not counted
    /// down then: the count is of what failed operations left.
    long_clusters: u64 = 0,
    unsure_long: u64 = 0,
    /// **THE LEDGER** (`ledger_on`): clusters the operation in
    /// progress took and has not yet ended. Every cluster `allocChain`
    /// takes ends in exactly one of four ways, each of which says how many
    /// it ends: **committed** by the entry's write (`Commit`), **linked**
    /// into a chain already committed (`linked`), **given back**
    /// (`giveBack`), or **a counted leak** (`leftLeaked`). Each public
    /// operation that changes the volume ends on `balanced`, an `always`
    /// that nothing it took is left open.
    ledger_open: u32 = 0,
    /// **A RESERVE FOR SMALL WRITES**: clusters a file larger than
    /// `small_bytes` may not take, set at mount to the lesser of
    /// `reserve_bytes` and a sixteenth of the volume. A bulk write is
    /// refused `Full` first, while small files and a directory's growth
    /// still go, and a remove always does.
    ///
    /// **JUDGED BY THE FILE, IN BYTES**: an append is judged by the file it
    /// makes, not the bytes it adds, so a log grown a cluster at a time
    /// spends the reserve no more than one write of it would. An overwrite
    /// is judged by what it leaves free once its old chain is gone, so one
    /// that frees as much as it takes always goes.
    reserve_clusters: u32 = 0,
    /// Writes of a FAT copy that failed and were left apart (`copyApart`).
    fat_copies_failed: u64 = 0,
    /// **WRITES REFUSED, THE COPIES UNWEIGHED** (metal-vmm QUEUE 188.2): a
    /// mount whose weighing of apart copies failed part way holds the first
    /// copy, and a write made from it would allocate a lost file's clusters
    /// and write over the second copy, the good one. Refused by such a
    /// mount, taken again after a weighing that succeeds; while refused,
    /// `writeSector` and `writeSectors`, which every write goes through,
    /// refuse.
    writes: Writes = .taken,
    /// **FAILED SECTOR READS AND WRITES** (metal-vmm QUEUE 193.3): requests
    /// the disk did not answer OK, as this volume met them (a read tried
    /// again and failed is one). The Block says why (`blk.failures`).
    /// How the FAT's copies stood at mount (`cacheFatChecked`), kept for
    /// /admin/host (metal-vmm QUEUE 193, gap 10); null before.
    mounted: ?Mirrors = null,
    /// Writes turned away because writes are refused (`refuseWrite`):
    /// each one a save that did not happen (metal-vmm QUEUE 193, gap 9).
    writes_turned_away: u64 = 0,
    read_failures: u64 = 0,
    write_failures: u64 = 0,
    /// Weighings tried again (`reweigh`), and those that failed.
    reweighs: u64 = 0,
    reweighs_failed: u64 = 0,
    /// The volume serial number (BS_VolID), or null on a boot sector without
    /// one. `blkid` shows it as the UUID, high half first.
    serial: ?u32 = null,

    /// **THE FAT, HELD IN MEMORY** once the host gives it room: a mirror of
    /// the FAT, read at mount from the copy `cacheFatChecked` trusts and
    /// never read from the disk again, so a lookup is a memory read. A
    /// change is made here and written as the whole sector to every copy
    /// (`fatSet`). Without it every lookup is a device read, and allocation
    /// from 2 costs a read per cluster in use; null is still a working
    /// volume, and the probes of that path leave it null.
    fat: ?[]u8 = null,

    /// **WHERE `find` READS A DIRECTORY, MANY SECTORS A REQUEST**, once the
    /// host gives it identity-mapped room (whole sectors). Only `find` uses
    /// it, and nothing writes while a lookup reads, so a burst cannot go
    /// stale under it.
    dir_burst: ?[]u8 = null,

    /// **SECTORS HELD IN MEMORY** (`cacheDirs`), once the host gives it room,
    /// so a lookup made before reads memory. A cache, **EXACT OR ABSENT**:
    /// a listing puts the sectors it reads, `readSector` looks here first,
    /// every write that succeeds updates each sector it held, and a write
    /// that fails drops them, since what the disk holds is then unknown.
    /// Never written back. Exact needs every write to go through
    /// `writeSector`/`writeSectors`, and every one does. `readSectors`
    /// neither looks nor puts, which is safe because what is held is exact.
    dirs: ?DirCache = null,

    /// Holds sectors in `keys.len` slots of `data` (`dirs`); `data` is
    /// `keys.len` sectors.
    pub fn cacheDirs(self: *Volume, keys: []u32, data: []u8) void {
        std.debug.assert(data.len == keys.len * sector_size and keys.len > 0);
        @memset(keys, 0);
        self.dirs = .{ .keys = keys, .data = data };
    }

    /// How much memory `cacheFat` needs: one copy of the FAT.
    pub fn fatBytes(self: *const Volume) usize {
        return @as(usize, self.sectors_per_fat) * sector_size;
    }
    // The FAT: its copies weighed at mount, its entries read and written: in disk_fat_fat.zig.
    pub const Mirrors = disk_fat_fat.Mirrors;
    pub const max_weighed_sectors = disk_fat_fat.max_weighed_sectors;
    pub const cacheFat = disk_fat_fat.cacheFat;
    pub const cacheFatChecked = disk_fat_fat.cacheFatChecked;
    pub const reweigh = disk_fat_fat.reweigh;
    pub const mirrorFirst = disk_fat_fat.mirrorFirst;
    pub const ignoreFinding = disk_fat_fat.ignoreFinding;
    pub const repairRefused = disk_fat_fat.repairRefused;
    pub const unweighed = disk_fat_fat.unweighed;
    pub const fatGet = disk_fat_fat.fatGet;
    pub const putEntry = disk_fat_fat.putEntry;
    pub const fatRefused = disk_fat_fat.fatRefused;
    pub const fatSet = disk_fat_fat.fatSet;
    pub const writeCopies = disk_fat_fat.writeCopies;
    pub const copyApart = disk_fat_fat.copyApart;
    pub const forgetFsInfo = disk_fat_fat.forgetFsInfo;
    pub const keepCount = disk_fat_fat.keepCount;

    /// Reads the boot sector (the BPB) and works out where everything is.
    ///
    /// **A BOOT SECTOR IS NOT TRUSTED.** Every field is checked before it
    /// computes an offset: a sector of zeros or of another filesystem would
    /// otherwise send reads anywhere.
    pub fn mount(blk: *virtio_blk.Block, scratch: *[sector_size]u8, start_lba: u32) Error!Volume {
        if (blk.read(start_lba, @intFromPtr(scratch)) != virtio_blk.blk_s_ok) {
            props.reachable(@src(), "fat: a mount cannot read the boot sector", null);
            return Error.ReadFailed;
        }
        const b = scratch.*;

        if (b[510] != 0x55 or b[511] != 0xAA) {
            props.reachable(@src(), "fat: a mount refuses a sector without the boot signature", null);
            return Error.BadBootSector;
        }

        const bytes_per_sector = le16(b[11..13]);
        const sectors_per_cluster: u32 = b[13];
        const reserved: u32 = le16(b[14..16]);
        const num_fats: u32 = b[16];
        const root_entries: u32 = le16(b[17..19]);
        const fat16_sectors: u32 = le16(b[22..24]);
        const sectors_per_fat: u32 = if (fat16_sectors != 0) fat16_sectors else le32(b[36..40]);
        var total: u32 = le16(b[19..21]);
        if (total == 0) total = le32(b[32..36]);

        if (bytes_per_sector != sector_size) {
            props.reachable(@src(), "fat: a mount refuses sectors that are not 512 bytes", null);
            return Error.NotFat16;
        }
        if (sectors_per_cluster == 0 or sectors_per_cluster > 128) {
            props.reachable(@src(), "fat: a mount refuses a cluster size no volume has", null);
            return Error.BadBootSector;
        }
        // **A CLUSTER IS ONE REQUEST AT LEAST** (178): the writes and reads
        // go a run of clusters to a request, never part of one.
        if (blk.most_sectors < sectors_per_cluster) {
            props.reachable(@src(), "fat: a mount refuses a disk whose requests are smaller than a cluster", null);
            return Error.RequestSmallerThanCluster;
        }
        if (reserved == 0 or num_fats == 0 or num_fats > 2) {
            props.reachable(@src(), "fat: a mount refuses no reserved sectors, or a count of FATs it does not keep", null);
            return Error.BadBootSector;
        }
        if (sectors_per_fat == 0) {
            props.reachable(@src(), "fat: a mount refuses a FAT of no sectors", null);
            return Error.BadBootSector;
        }
        // Sector numbers here are 32 bits, the volume's own and the disk's.
        if (@as(u64, start_lba) + total > 0xFFFF_FFFF) {
            props.reachable(@src(), "fat: a mount refuses a volume past 32-bit sectors", null);
            return Error.VolumeTooLarge;
        }

        const fats = std.math.mul(u32, num_fats, sectors_per_fat) catch {
            props.reachable(@src(), "fat: a mount refuses FATs whose total size overflows", null);
            return Error.BadBootSector;
        };
        const root_start = std.math.add(u32, reserved, fats) catch {
            props.reachable(@src(), "fat: a mount refuses reserved sectors and FATs whose sum overflows", null);
            return Error.BadBootSector;
        };
        const root_sectors = (root_entries * dirent_size + sector_size - 1) / sector_size;
        const data_start = std.math.add(u32, root_start, root_sectors) catch {
            props.reachable(@src(), "fat: a mount refuses a root directory whose sectors overflow", null);
            return Error.BadBootSector;
        };
        if (total == 0 or data_start >= total) {
            props.reachable(@src(), "fat: a mount refuses a volume with no data region", null);
            return Error.BadBootSector;
        }

        const clusters = (total - data_start) / sectors_per_cluster;
        if (clusters < 4085) {
            props.reachable(@src(), "fat: a mount refuses a volume too small for FAT16", null);
            return Error.NotFat16;
        }
        const kind: Kind = if (clusters < 65525) .fat16 else .fat32;
        // **FAT32'S CLUSTER NUMBERS ARE 28 BITS**, and from 0x0FFFFFF7 up they
        // are marks: a volume with more clusters than numbers below the marks
        // would have chains that end where they should go on.
        if (kind == .fat32 and clusters > 0x0FFF_FFF5) {
            props.reachable(@src(), "fat: a mount refuses a FAT32 volume with more clusters than its numbers", null);
            return Error.TooManyClusters;
        }
        var root_cluster: Cluster = 0;
        switch (kind) {
            .fat16 => if (root_entries == 0) {
                props.reachable(@src(), "fat: a mount refuses a FAT16 root of no entries", null);
                return Error.BadBootSector;
            },
            .fat32 => {
                // BPB_RootEntCnt and BPB_FATSz16 are 0; BPB_ExtFlags,
                // BPB_FSVer and BPB_RootClus are checked like every other.
                if (root_entries != 0 or fat16_sectors != 0) {
                    props.reachable(@src(), "fat: a mount refuses FAT32 with FAT16's fields set", null);
                    return Error.BadBootSector;
                }
                if (le16(b[40..42]) & 0x80 != 0) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 volume that is not mirrored", null);
                    return Error.NotMirrored;
                }
                if (le16(b[42..44]) != 0) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 version it does not know", null);
                    return Error.FatVersion;
                }
                root_cluster = le32(b[44..48]);
                if (root_cluster < 2 or root_cluster > clusters + 1) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 root outside the data", null);
                    return Error.BadRoot;
                }
            },
        }
        // A FAT too short for the clusters it describes would have `fatGet`
        // read past its end, into the next copy or the root.
        const entry_bytes: u32 = if (kind == .fat32) 4 else 2;
        if (@as(u64, sectors_per_fat) * (sector_size / entry_bytes) < @as(u64, clusters) + 2) {
            props.reachable(@src(), "fat: a mount refuses a FAT too short for its clusters", null);
            return Error.BadBootSector;
        }
        // **A FAT ITS ENTRY NUMBERS REACH** (metal-vmm QUEUE 182): the check
        // and the weighing number entries `sector * per + i` in u32, safe
        // before only through the kernel's 32 MiB FAT budget. Bounded here.
        if (@as(u64, sectors_per_fat) * (sector_size / entry_bytes) > 1 << 32) {
            props.reachable(@src(), "fat: a mount refuses a FAT longer than 32-bit entry numbers reach", null);
            return Error.BadBootSector;
        }

        var vol: Volume = .{
            .blk = blk,
            .scratch = scratch,
            .start_lba = start_lba,
            .sectors_per_cluster = sectors_per_cluster,
            .fat_start = reserved,
            .sectors_per_fat = sectors_per_fat,
            .num_fats = num_fats,
            .max_cluster = @intCast(clusters + 1),
            .root_start = root_start,
            .root_sectors = root_sectors,
            .root_entries = root_entries,
            .data_start = data_start,
            .kind = kind,
            .root_cluster = root_cluster,
            .fsinfo_sector = if (kind == .fat32) le16(b[48..50]) else 0,
            .backup_boot = if (kind == .fat32) le16(b[50..52]) else 0,
            // BS_BootSig 0x29 says BS_VolID is there: at 38 on FAT16, at 66
            // on FAT32.
            .serial = switch (kind) {
                .fat16 => if (b[38] == 0x29) le32(b[39..43]) else null,
                .fat32 => if (b[66] == 0x29) le32(b[67..71]) else null,
            },
        };
        // Derived from the first copy on the disk (no FAT is held yet); the
        // hint starts at 2, below every free cluster.
        vol.free_clusters = (try vol.derive()).free;
        vol.reserve_clusters = @min(reserve_bytes / (vol.sectors_per_cluster * sector_size), (vol.max_cluster - 1) / 16);
        return vol;
    }

    /// **WHAT THE FAT SAYS, AFRESH**: its free clusters, and the first of
    /// them. From the held FAT when there is one, else from the first copy
    /// on the disk, a run of sectors at a time.
    pub fn derive(self: *Volume) Error!Derived {
        return self.deriveFrom(if (self.fat != null) .held else .disk);
    }

    pub fn deriveFrom(self: *Volume, source: enum { held, disk }) Error!Derived {
        var free: u32 = 0;
        var first: ?Cluster = null;
        const per = self.entriesPerSector();
        var run: [run_sectors * sector_size]u8 align(16) = undefined;
        var s: u32 = 0;
        while (s < self.sectors_per_fat) {
            const n = @min(run_sectors, self.sectors_per_fat - s);
            const sectors: []const u8 = switch (source) {
                .held => self.fat.?[s * sector_size ..][0 .. n * sector_size],
                .disk => read: {
                    try self.readSectors(self.fat_start + s, n, &run);
                    break :read run[0 .. n * sector_size];
                },
            };
            // The run's entries that are clusters: from cluster 2, to the
            // last cluster.
            const base = s * per;
            const lo = if (base < 2) 2 - base else 0;
            const hi = @min(n * per, self.max_cluster + 1 -| base);
            if (lo < hi) {
                var at: ?u32 = null;
                free += self.freeEntries(sectors, lo, hi, &at);
                if (first == null) if (at) |i| {
                    first = base + i;
                };
            }
            if (base + n * per > self.max_cluster) break;
            s += n;
        }
        return .{ .free = free, .first_free = first };
    }

    /// **THE FREE ENTRIES OF A RUN OF FAT SECTORS**, `lo` to `hi` (not
    /// counting `hi`), and the first of them into `first`: as `entryIn`
    /// reads each and counts the zeros, but a vector of entries at a time
    /// (metal-vmm QUEUE 203(b), P198.12). A call per entry was most of a
    /// FAT32 mount's time in a Debug build, the tests' (a 35 MB disk's
    /// FAT is 270,000 entries). Its own test holds it to `entryIn`'s count.
    pub fn freeEntries(self: *const Volume, sectors: []const u8, lo: u32, hi: u32, first: *?u32) u32 {
        return switch (self.kind) {
            .fat16 => freeOf(u16, 0xFFFF, sectors, lo, hi, first),
            .fat32 => freeOf(u32, fat32_mask, sectors, lo, hi, first),
        };
    }

    /// How many sectors a FAT is read in at a time where it is read whole:
    /// a buffer of this many on the stack.
    pub const run_sectors = 64;

    pub fn entryBytes(self: *const Volume) u32 {
        return if (self.kind == .fat32) 4 else 2;
    }

    /// **MERGE TOWARD ALLOCATED** (metal-vmm QUEUE 198.5): in FAT sector
    /// `at`, held, every cluster entry free here and taken in `other` takes
    /// `other`'s, and the kept free count is moved for it. The two reserved
    /// entries, and entries past the last cluster, are the held copy's.
    pub fn mergeTowardAllocated(self: *Volume, held: *[sector_size]u8, other: *const [sector_size]u8, at: u32) void {
        const per = self.entriesPerSector();
        const width = sector_size / per;
        var e: u32 = 0;
        while (e < per) : (e += 1) {
            const c = at * per + e;
            if (c < 2 or c > self.max_cluster) continue;
            if (self.entryIn(held, e) != 0 or self.entryIn(other, e) == 0) continue;
            @memcpy(held[e * width ..][0..width], other[e * width ..][0..width]);
            props.always(@src(), self.free_clusters > 0, "fat: a cluster merged taken was counted free", null);
            self.free_clusters -|= 1;
        }
    }

    pub fn entriesPerSector(self: *const Volume) u32 {
        return sector_size / self.entryBytes();
    }

    /// The `i`th entry in a FAT sector; on FAT32 the low 28 bits (the top
    /// four are reserved).
    pub fn entryIn(self: *const Volume, sector: []const u8, i: u32) Cluster {
        return switch (self.kind) {
            .fat16 => le16(sector[i * 2 ..][0..2]),
            .fat32 => le32(sector[i * 4 ..][0..4]) & fat32_mask,
        };
    }

    /// The first end-of-chain value, on this kind.
    pub fn chainEndValue(self: *const Volume) Cluster {
        return if (self.kind == .fat32) fat32_chain_end else chain_end;
    }

    /// What a chain's last entry is written as (EOC).
    pub fn endMark(self: *const Volume) Cluster {
        return if (self.kind == .fat32) 0x0FFF_FFFF else 0xFFFF;
    }

    pub fn isEnd(self: *const Volume, v: Cluster) bool {
        return v >= (if (self.kind == .fat32) fat32_chain_end else chain_end);
    }

    pub fn badMark(self: *const Volume) Cluster {
        return if (self.kind == .fat32) fat32_bad_cluster else bad_cluster;
    }

    /// The cluster a directory starts at: on FAT32, cluster 0 (the root) is
    /// `root_cluster`.
    pub fn dirStart(self: *const Volume, dir_cluster: Cluster) Cluster {
        return if (dir_cluster == 0 and self.kind == .fat32) self.root_cluster else dir_cluster;
    }

    /// An entry decoded, with FAT32's DIR_FstClusHI (bytes 20..22). On FAT16
    /// those bytes are not a cluster, and are ignored.
    pub fn entryFrom(self: *const Volume, e: []const u8) Entry {
        var entry = decode(e);
        if (self.kind == .fat32) {
            entry.first_cluster |= @as(Cluster, le16(e[20..22])) << 16;
            if (entry.first_cluster > 0xFFFF) props.reachable(@src(), "fat: a FAT32 entry's first cluster is past 65535", null);
        }
        return entry;
    }

    pub fn readSector(self: *Volume, lba: u32, into: *[sector_size]u8) Error!void {
        if (self.dirs) |*c| if (c.get(lba)) |held| {
            @memcpy(into, held);
            return;
        };
        if (self.blk.read(self.start_lba + lba, @intFromPtr(into)) != virtio_blk.blk_s_ok) {
            self.read_failures +%= 1;
            props.reachable(@src(), "fat: a sector read fails", null);
            return Error.ReadFailed;
        }
    }

    /// `count` whole sectors straight into `into` (identity-mapped), in as
    /// few requests as the driver allows. Bypasses `dirs`.
    pub fn readSectors(self: *Volume, lba: u32, count: u32, into: [*]u8) Error!void {
        var done: u32 = 0;
        while (done < count) {
            const n = @min(count - done, self.blk.most_sectors);
            const status = self.blk.readMany(self.start_lba + lba + done, @intFromPtr(into + done * sector_size), n);
            if (status != virtio_blk.blk_s_ok) {
                self.read_failures +%= 1;
                props.reachable(@src(), "fat: a run of sectors fails to read", null);
                return Error.ReadFailed;
            }
            done += n;
        }
    }

    /// The sector a cluster starts at; the data region's first cluster is 2.
    pub fn clusterSector(self: *Volume, cluster: Cluster) u32 {
        return self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster;
    }

    /// The next cluster in a chain, or null at its end.
    ///
    /// **A LINK OUTSIDE THE DATA REGION IS A BROKEN CHAIN** (BadChain): 0
    /// (free), 1, the bad-cluster mark, or past the last cluster, where the
    /// FAT has no entry and `clusterSector` points past the volume.
    pub fn nextCluster(self: *Volume, cluster: Cluster) Error!?Cluster {
        const v = try self.fatGet(cluster);
        if (v >= self.chainEndValue()) return null;
        if (!self.inData(v)) {
            props.reachable(@src(), "fat: a chain leads outside the data area", null);
            return Error.BadChain;
        }
        return v;
    }

    pub fn inData(self: *const Volume, cluster: Cluster) bool {
        return cluster >= 2 and cluster <= self.max_cluster;
    }
    // Directories: walked, listed, found, grown, entries unlinked, and short aliases: in disk_fat_dir.zig.
    pub const Loop = disk_fat_dir.Loop;
    pub const Walk = disk_fat_dir.Walk;
    pub const Lister = disk_fat_dir.Lister;
    pub const lister = disk_fat_dir.lister;
    pub const list = disk_fat_dir.list;
    pub const find = disk_fat_dir.find;
    pub const open = disk_fat_dir.open;
    pub const Slot = disk_fat_dir.Slot;
    pub const Run = disk_fat_dir.Run;
    pub const findRun = disk_fat_dir.findRun;
    pub const grow = disk_fat_dir.grow;
    pub const max_dir_entries = disk_fat_dir.max_dir_entries;
    pub const max_long_parts = disk_fat_dir.max_long_parts;
    pub const removeEntry = disk_fat_dir.removeEntry;
    pub const Unlinked = disk_fat_dir.Unlinked;
    pub const partLeft = disk_fat_dir.partLeft;
    pub const partStands = disk_fat_dir.partStands;
    pub const partsLeft = disk_fat_dir.partsLeft;
    pub const unlinkEntry = disk_fat_dir.unlinkEntry;
    pub const unlinkUnsure = disk_fat_dir.unlinkUnsure;
    pub const aliasFor = disk_fat_dir.aliasFor;
    pub const aliasTaken = disk_fat_dir.aliasTaken;

    pub fn writeSector(self: *Volume, lba: u32, from: *[sector_size]u8) Error!void {
        if (self.writes == .refused) {
            self.writes_turned_away +%= 1;
            return refuseWrite();
        }
        self.changes +%= 1;
        if (self.blk.write(self.start_lba + lba, @intFromPtr(from)) != virtio_blk.blk_s_ok) {
            self.write_failures +%= 1;
            if (self.dirs) |*c| c.drop(lba, 1);
            props.reachable(@src(), "fat: a sector write fails", null);
            // PLANT (src/plant.zig): a write the disk refused is taken as
            // written, so the caller answers "saved" over a hole.
            if (comptime plant.on == .disk_write_swallowed) {
                props.reachable(@src(), "PLANT: disk-write-swallowed fires", null);
                if (self.dirs) |*c| c.wrote(lba, 1, from);
                return;
            }
            return Error.WriteFailed;
        }
        if (self.dirs) |*c| c.wrote(lba, 1, from);
    }

    /// `count` whole sectors straight from `from`, as **ONE REQUEST**:
    /// `writeRuns`, the only bulk writer, caps a run at one request, so
    /// asking for more is an error, not a loop no test could reach.
    pub fn writeSectors(self: *Volume, lba: u32, count: u32, from: [*]const u8) Error!void {
        if (count > self.blk.most_sectors) {
            props.@"unreachable"(@src(), "fat: a write of more sectors than one request", null);
            return Error.TooBig;
        }
        if (self.writes == .refused) {
            self.writes_turned_away +%= 1;
            return refuseWrite();
        }
        self.changes +%= 1;
        if (self.blk.writeMany(self.start_lba + lba, @intFromPtr(from), count) != virtio_blk.blk_s_ok) {
            self.write_failures +%= 1;
            if (self.dirs) |*c| c.drop(lba, count);
            props.reachable(@src(), "fat: a run of sectors fails to write", null);
            return Error.WriteFailed;
        }
        if (self.dirs) |*c| c.wrote(lba, count, from);
    }
    // Cluster chains: taken, given back, written, and the ledger that counts them: in disk_fat_chain.zig.
    pub const space = disk_fat_chain.space;
    pub const countFreeAgain = disk_fat_chain.countFreeAgain;
    pub const allocChain = disk_fat_chain.allocChain;
    pub const allocChainHeld = disk_fat_chain.allocChainHeld;
    pub const keepTaken = disk_fat_chain.keepTaken;
    pub const keepFreed = disk_fat_chain.keepFreed;
    pub const heldRefused = disk_fat_chain.heldRefused;
    pub const reserve_bytes = disk_fat_chain.reserve_bytes;
    pub const small_bytes = disk_fat_chain.small_bytes;
    pub const Spend = disk_fat_chain.Spend;
    pub const leftLeaked = disk_fat_chain.leftLeaked;
    pub const leftUnsure = disk_fat_chain.leftUnsure;
    pub const giveBack = disk_fat_chain.giveBack;
    pub const notGivenBack = disk_fat_chain.notGivenBack;
    pub const ledger_on = disk_fat_chain.ledger_on;
    pub const took = disk_fat_chain.took;
    pub const ended = disk_fat_chain.ended;
    pub const linked = disk_fat_chain.linked;
    pub const balanced = disk_fat_chain.balanced;
    pub const freeAfterCommit = disk_fat_chain.freeAfterCommit;
    pub const freeAfterCommitHeld = disk_fat_chain.freeAfterCommitHeld;
    pub const chainLeft = disk_fat_chain.chainLeft;
    pub const writeChain = disk_fat_chain.writeChain;

    // Files: an entry's commit, files and directories written, appended, and read: in disk_fat_file.zig.
    pub const stamp = disk_fat_file.stamp;
    pub const Landing = disk_fat_file.Landing;
    pub const Commit = disk_fat_file.Commit;
    pub const commitRefused = disk_fat_file.commitRefused;
    pub const entryRefused = disk_fat_file.entryRefused;
    pub const heldBy = disk_fat_file.heldBy;
    pub const Held = disk_fat_file.Held;
    pub const tombstoned = disk_fat_file.tombstoned;
    pub const writeEntry = disk_fat_file.writeEntry;
    pub const writeFileIn = disk_fat_file.writeFileIn;
    pub const overwrite = disk_fat_file.overwrite;
    pub const makeDirIn = disk_fat_file.makeDirIn;
    pub const makePath = disk_fat_file.makePath;
    pub const writeFile = disk_fat_file.writeFile;
    pub const writeInto = disk_fat_file.writeInto;
    pub const chainEnd = disk_fat_file.chainEnd;
    pub const writeAt = disk_fat_file.writeAt;
    pub const Tail = disk_fat_file.Tail;
    pub const writeRuns = disk_fat_file.writeRuns;
    pub const setEntry = disk_fat_file.setEntry;
    pub const Parent = disk_fat_file.Parent;
    pub const parentOf = disk_fat_file.parentOf;
    pub const readFile = disk_fat_file.readFile;
    pub const Layout = disk_fat_file.Layout;
    pub const layout = disk_fat_file.layout;
    pub const readAt = disk_fat_file.readAt;

    // Renames and removes, a file's or a whole tree's: in disk_fat_remove.zig.
    pub const undoUnlink = disk_fat_remove.undoUnlink;
    pub const rename = disk_fat_remove.rename;
    pub const remove = disk_fat_remove.remove;
    pub const walkFound = disk_fat_remove.walkFound;
    pub const removeTree = disk_fat_remove.removeTree;
    pub const removeDirectoryIn = disk_fat_remove.removeDirectoryIn;
    pub const removeTreeAt = disk_fat_remove.removeTreeAt;

    /// Bounds the recursion of `removeTree` and `check`, which run on a
    /// kernel stack with no guard page. The application's deepest tree is
    /// five levels.
    pub const max_tree_depth: u32 = 16;

    /// The deepest directory `makePath` makes, counted from the root: the
    /// deepest `check` walks. `removeTree` counts from the directory it
    /// removes, so it takes any tree this allows.
    pub const max_path_depth: u32 = max_tree_depth - 1;
    // The check, as fsck would: in disk_fat_check.zig.
    pub const checkBytes = disk_fat_check.checkBytes;
    pub const check = disk_fat_check.check;
    pub const checkInSlicesForTest = disk_fat_check.checkInSlicesForTest;
    pub const checkIn = disk_fat_check.checkIn;
    pub const CheckRun = disk_fat_check.CheckRun;
    pub const Checker = disk_fat_check.Checker;
};

/// The one site every refused write passes (188.2).
fn refuseWrite() Error {
    props.reachable(@src(), "fat: a write is refused, the FAT's copies unweighed", null);
    return Error.WritesRefused;
}

test "the free entries of a run of FAT sectors, a vector at a time, are entryIn's zeros one at a time: both kinds, every bound, the FAT32 top bits ignored (203(b))" {
    var prng: std.Random.DefaultPrng = .init(198);
    const r = prng.random();
    var bytes: [2 * sector_size]u8 = undefined;
    var checked: usize = 0;
    for ([_]Kind{ .fat16, .fat32 }) |kind| {
        // Only the kind is read here.
        var vol: Volume = undefined;
        vol.kind = kind;
        const per = 2 * vol.entriesPerSector();
        for (0..200) |_| {
            // Mostly taken, some free, and on FAT32 free entries with the
            // reserved top four bits set (still free).
            r.bytes(&bytes);
            const w = vol.entryBytes();
            for (0..per) |i| if (r.uintLessThan(u8, 4) == 0) {
                const top: u8 = if (kind == .fat32 and r.boolean()) 0xF0 else 0;
                @memset(bytes[i * w ..][0..w], 0);
                bytes[i * w + w - 1] = top;
            };
            const lo = r.uintAtMost(u32, per);
            const hi = r.intRangeAtMost(u32, lo, per);
            var first: ?u32 = null;
            const free = vol.freeEntries(&bytes, lo, hi, &first);
            var want: u32 = 0;
            var want_first: ?u32 = null;
            var i = lo;
            while (i < hi) : (i += 1) if (vol.entryIn(&bytes, i) == 0) {
                want += 1;
                if (want_first == null) want_first = i;
            };
            try std.testing.expectEqual(want, free);
            try std.testing.expectEqual(want_first, first);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 400), checked);
}
