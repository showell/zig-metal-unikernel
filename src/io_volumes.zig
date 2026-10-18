//! Where a path's bytes are, under io.zig's `Io`: the two mounted volumes
//! (the site's boot disk and the data volume), which one holds a path, their
//! caches (the page cache, the site cache) and durability. io.zig mounts them,
//! handing each this machine's clock, and re-exports what the kernel calls
//! (`Io.durable`, `Io.siteVolume`, ...), so its surface is unchanged.

const disk_fat = @import("disk_fat.zig");
const PageCache = @import("page_cache.zig").PageCache;
const virtio = @import("virtio.zig");
const props = @import("coverage");
const serial = @import("serial.zig");
const std = @import("std");

/// **TWO DISKS, ONE TREE.** The site's own files (its pages, its pictures,
/// this machine's settings) come with each new image, and the application's
/// data must outlive that image. So a path is sent to a volume by its first
/// directory: one named in `data_dirs` goes to `data`, everything else to
/// `site`. The application still sees one tree and spells every path as it
/// does on Linux.
///
/// With no data volume, the data directories are on the site's volume, as
/// they were when the machine had one disk.
///
/// **THESE ARE THE COPIES OF EACH `Volume` THAT WRITE** (disk_fat's
/// `free_clusters`): the host's copy shares the held FAT and the folder
/// cache's memory, and must not write once it has handed a volume here.
pub var site: ?disk_fat.Volume = null;
pub var data: ?disk_fat.Volume = null;
pub var data_dirs: []const []const u8 = &.{};

/// **THE DATA'S FILES, KEPT AFTER THEIR FIRST READ** (`page_cache.zig`,
/// QUEUE.md item 87): from here on a data file is read from `pc` when it is
/// there, and every change io makes to a data file is told to it. Null:
/// none kept (the probes, and a host that gives it no memory).
///
/// **IO.ZIG IS THE ONE DOOR**: every change to a data file goes through
/// io.zig, and each one tells the cache, so it stays exact. A write or rename
/// that fails drops its paths (`forget`). A remove and a tree removed drop
/// them before the disk is asked, so one that fails part-way leaves no copy
/// to disagree with what it left.
pub fn keepPages(pc: ?*PageCache) void {
    if (page_cache) |old| old.clear();
    page_cache = pc;
}

pub var page_cache: ?*PageCache = null;

/// The page cache, for a host's report and the tests.
pub fn pageCache() ?*PageCache {
    return page_cache;
}

/// The page cache, if `path` is a data file it keeps.
pub fn pagesFor(path: []const u8) ?*PageCache {
    const pc = page_cache orelse return null;
    if (data_dirs.len == 0 or placeOf(path) != .data) return null;
    return pc;
}

/// **NOTHING LEAVES THE MACHINE AHEAD OF THE WRITES BEFORE IT.** Every
/// disk with writes it has answered but may not have kept is flushed
/// (`virtio.Block.flush`). `stream.zig` calls this before any response byte
/// joins a connection's send queue, so a 303 that says a message was saved,
/// or a chat frame that shows it to others, goes out only once the message
/// is durable. This is external synchrony (Nightingale et al., "Rethink the
/// Sync", OSDI 2006): durability matters where someone can see it, so it is
/// tied to output, not to the application's own calls. The application
/// never calls `File.sync`, on Linux either, where a write sat in the page
/// cache for up to half a minute; here every write already reaches the
/// device, and this makes it past the device's cache.
///
/// A flush that fails is logged and counted (/admin/host), and the response
/// goes out: the write itself was answered as done, and refusing every
/// response after a disk stops flushing would take the site down for what
/// may be a disk with no cache at all. The flush is tried again before the
/// next response.
pub fn durable() void {
    _ = durableChecked();
}

/// **DURABLE NOW, AND WHETHER IT HELD** (webbox's `store.makeDurable`,
/// metal-vmm QUEUE 200): `durable`, answering false when a flush failed, for
/// the one caller that may not go on until its writes are kept (the script
/// route's sequence number, before the script runs). The host sets it as
/// webbox's `store.durable_now`.
pub fn durableChecked() bool {
    var ok = true;
    for ([_]?disk_fat.Volume{ site, data }, 0..) |maybe, k| {
        const v = maybe orelse continue;
        if (!v.blk.unflushed) continue;
        if (v.blk.flush() != virtio.blk_s_ok) {
            // Reached under metal-vmm with VOLUME_SYNC_FAIL=1 (the volume);
            // no knob fails a flush of the boot disk, which is virtio-blk
            // and writes through.
            props.reachable(@src(), "io: a flush failed, and the response goes out anyway", .{ .disk = k });
            serial.put(if (k == 0) "  a flush of the boot disk failed\n" else "  a flush of the volume failed\n");
            ok = false;
        }
    }
    return ok;
}

/// The two volumes, for a host's status report: the site's, and the data's
/// when it has one of its own.
pub fn siteVolume() ?*disk_fat.Volume {
    return if (site) |*v| v else null;
}
pub fn dataVolume() ?*disk_fat.Volume {
    return if (data) |*v| v else null;
}

pub const Place = enum { site, data };

/// **THE DISK IS CHOSEN THE WAY FAT16 WILL RESOLVE THE PATH**, or the path is
/// refused. disk_fat matches names ignoring case, so the first directory is
/// compared the same way; and it resolves `.` and `..` as real entries, so a
/// path holding either could be routed by its first directory and land
/// somewhere else — `data/../x` at the volume's root, past the refusal in
/// `writing`. **AND EVERY PART IS NAMED** (Steve, 2026-10-10): a doubled,
/// leading or trailing slash is a path built wrong, never read as the path it
/// might have meant. The application never spells a path either way, so such
/// a path is refused (null) rather than interpreted.
pub fn placeOf(path: []const u8) ?Place {
    if (path.len > 0) {
        var each = std.mem.splitScalar(u8, path, '/');
        while (each.next()) |part| {
            if (part.len == 0) {
                props.reachable(@src(), "io: a path with an empty part is refused", null);
                return null;
            }
        }
    }
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
    }
    parts.reset();
    const first = parts.next() orelse return .site;
    for (data_dirs) |dir| {
        if (std.ascii.eqlIgnoreCase(dir, first)) return .data;
    }
    return .site;
}

pub fn volumeAt(place: Place) Error!*disk_fat.Volume {
    if (place == .data) {
        if (data) |*d| return d;
    }
    return &(site orelse return Error.FileNotFound);
}

/// **THE SITE'S OWN FILES, KEPT AFTER THEIR FIRST READ** (QUEUE.md item 61).
/// A page read from a file (the home page's text, the resume, a picture) cost
/// four disk requests every time: under QEMU about 0.4 ms of each answer,
/// where an embedded page costs none. Once `keepData` has named the data
/// directories, nothing outside them is written (`writing` refuses it), so a
/// site file read once is the same file until the next image, and keeping it
/// can never go stale. Data files are never kept.
///
/// Bounded and fixed: `capacity` bytes in all, files of up to `largest`, and
/// `slots` of them, first come; past that a file is read from the disk as
/// before. No allocator, so it is here from the boot, in `.bss`.
///
/// **A CACHE OF A SOURCE THAT CANNOT CHANGE**, so it never disagrees and
/// needs no rule for it: it is filled only once `keepData` has made the site
/// read-only, and emptied when `mount` hands io another volume.
pub const SiteCache = struct {
    pub const capacity = 4 << 20;
    pub const largest = 512 << 10;
    pub const slots = 64;

    bytes: [capacity]u8 = undefined,
    used: usize = 0,
    names: [slots][max_path]u8 = undefined,
    name_lens: [slots]u16 = undefined,
    starts: [slots]usize = undefined,
    sizes: [slots]usize = undefined,
    count: usize = 0,
    /// Reads answered from here, for a host's report and the tests.
    hits: u64 = 0,

    /// The kept bytes for `path`, matched as FAT matches names: ignoring case.
    pub fn find(self: *SiteCache, path: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], path))
                return self.bytes[self.starts[i]..][0..self.sizes[i]];
        }
        return null;
    }

    /// Keeps `bytes` as `path`'s, if they fit.
    pub fn keep(self: *SiteCache, path: []const u8, bytes: []const u8) void {
        if (self.count >= slots or path.len > max_path or bytes.len > largest) return;
        if (self.used + bytes.len > capacity) return;
        @memcpy(self.names[self.count][0..path.len], path);
        self.name_lens[self.count] = @intCast(path.len);
        self.starts[self.count] = self.used;
        self.sizes[self.count] = bytes.len;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        self.count += 1;
    }

    pub fn clear(self: *SiteCache) void {
        self.used = 0;
        self.count = 0;
    }
};

pub var site_cache: SiteCache = .{};

test "the site cache keeps what fits, up to its capacity, and not a byte past it" {
    const c = try std.testing.allocator.create(SiteCache);
    defer std.testing.allocator.destroy(c);
    c.* = .{};
    var file: [SiteCache.largest]u8 = undefined;
    var name: [16]u8 = undefined;
    // Eight of the largest file it keeps are exactly its capacity.
    const fill = SiteCache.capacity / SiteCache.largest;
    for (0..fill) |k| {
        @memset(&file, @truncate(k));
        c.keep(try std.fmt.bufPrint(&name, "gallery/{d}", .{k}), &file);
    }
    try std.testing.expectEqual(@as(usize, SiteCache.capacity), c.used);
    try std.testing.expectEqual(fill, c.count);
    // One byte more is not kept, and what is kept is untouched.
    c.keep("pages/one-more", "x");
    try std.testing.expectEqual(fill, c.count);
    try std.testing.expect(c.find("pages/one-more") == null);
    for (0..fill) |k| {
        const got = c.find(try std.fmt.bufPrint(&name, "gallery/{d}", .{k})).?;
        try std.testing.expectEqual(SiteCache.largest, got.len);
        try std.testing.expectEqual(@as(u8, @truncate(k)), got[got.len - 1]);
    }
}

/// The site cache, for a host's report and the tests.
pub fn siteCache() *SiteCache {
    return &site_cache;
}

/// Whether `path` is a site file that cannot change: one outside the data
/// directories, once there are data directories to be outside of.
pub fn cacheable(path: []const u8) bool {
    return data_dirs.len != 0 and placeOf(path) == .site;
}

/// **ABSENT, OR A DISK THAT WOULD NOT SAY: NOT THE SAME ANSWER.** disk_fat's
/// `open`, its errors as the application's: NotFound is FileNotFound, and a
/// read that failed is ReadFailed. Every failure was FileNotFound, so a disk
/// error read as "no such file": `createFile` then made the file afresh,
/// emptying one that was there, and the admin's reset took the admin for
/// absent (QUEUE.md item 89).
pub fn openEntry(v: *disk_fat.Volume, path: []const u8) Error!disk_fat.Entry {
    return v.open(path) catch |e| switch (e) {
        error.NotFound => if (try throughFile(v, path)) Error.NotDir else Error.FileNotFound,
        else => Error.ReadFailed,
    };
}

/// **A PATH THROUGH A FILE IS `NotDir`, AS std.Io ANSWERS ON LINUX.** disk_fat
/// refuses `a/b` with `a` a file as a name that is not there, and this
/// answered FileNotFound, where Linux says NotDir: so the same store.zig call
/// read as an absent file on metal and as an error on Linux (the store judge,
/// 2026-10-07: `readOrEmpty` gave "" on one host and failed on the other).
/// Asked only after a miss, so a found path costs nothing more.
/// A read that fails while it looks is ReadFailed, never "not through a
/// file", which the caller would answer as absent (metal-vmm QUEUE 172).
pub fn throughFile(v: *disk_fat.Volume, path: []const u8) Error!bool {
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        if (slash == 0) continue;
        const e = v.open(path[0..slash]) catch |err| switch (err) {
            error.NotFound, error.NotFat16 => return false,
            else => return Error.ReadFailed,
        };
        if (!e.isDirectory()) return true;
    }
    return false;
}

/// The volume to read `path` from.
pub fn reading(path: []const u8) Error!*disk_fat.Volume {
    return volumeAt(placeOf(path) orelse return Error.FileNotFound);
}

/// The volume to change `path` on, or a refusal: see `keepData`.
pub fn writing(path: []const u8) Error!*disk_fat.Volume {
    const place = placeOf(path) orelse {
        serial.put("  refused: a write to a path with ., .. or an empty part: ");
        serial.put(path);
        serial.put("\n");
        return Error.WriteFailed;
    };
    if (place == .site and data_dirs.len != 0) {
        serial.put("  refused: a write outside the data directories: ");
        serial.put(path);
        serial.put("\n");
        return Error.WriteFailed;
    }
    const v = try volumeAt(place);
    // **THE ONE REFUSAL** (188.2): before anything of the write is done.
    // disk_fat's own writes refuse too; this answers it as what it is.
    if (v.writes == .refused) return Error.ReadOnlyFileSystem;
    return v;
}

pub const Error = error{
    FileNotFound,
    NotDir,
    IsDir,
    OutOfMemory,
    StreamTooLong,
    ReadFailed,
    WriteFailed,
    NameTooLong,
    NoSpaceLeft,
    PathAlreadyExists,
    /// The volume refuses writes until its FAT's copies are weighed (metal-vmm
    /// QUEUE 188.2): the application answers it as a 503.
    ReadOnlyFileSystem,
};

/// max_path bounds the path a File remembers. The application's deepest is a
/// game session's action log — `{data_root}/{id}/lynrummy-elm/sessions/{n}/
/// actions.dsl` — and a data root is an absolute path on the host it came from,
/// so this is generous rather than tight. There is no allocator here to make it
/// dynamic.
pub const max_path: usize = 256;
