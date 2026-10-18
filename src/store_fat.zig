//! **THE STORE OVER FAT** (metal-vmm QUEUE item 77): the six operations
//! (`store.zig`) on a mounted `disk_fat.Volume`. The Store's name rules are
//! checked first, so FAT never sees a name the other stores would refuse;
//! FAT's own refusals are mapped to the Store's errors (`map`).
//!
//! **`replace` IS WRITE, FLUSH, RENAME.** The new bytes go to a file of the
//! Store's own name beside the old (`store.temp_prefix`), the disk is
//! flushed, and that file is renamed over the old one: `disk_fat.rename` points
//! the old name's entry at the new chain in one sector write, so a power cut
//! at any point leaves the old file whole or the new one whole. The flush is
//! what makes that true on a disk with a write cache: without it the rename
//! could reach the media before the data it names. A cut that leaves the
//! temporary file behind leaves only a hidden name and its clusters, which
//! the next `replace` of that file writes over.
//!
//! `write` is `disk_fat.writeFile`, which removes the old file before writing
//! the new: a cut between can leave neither, as `store.zig` says it may.
//! `append` is `disk_fat.writeInto` at the file's end, which links and writes
//! before it changes the entry's size: a cut leaves the old file or the new.

const std = @import("std");
const store = @import("store.zig");
const disk_fat = @import("disk_fat.zig");
const Error = store.Error;

pub const FatStore = struct {
    vol: *disk_fat.Volume,

    pub fn store_(f: *FatStore) store.Store {
        return .{ .ptr = f, .vtable = &vtable };
    }

    const vtable = store.Store.VTable{
        .read = readV,
        .write = writeV,
        .append = appendV,
        .list = listV,
        .remove = removeV,
        .replace = replaceV,
    };

    /// What a call that met FAT's error was doing: writing, or looking (a
    /// read, a remove, a listing).
    const Doing = enum { writing, looking };

    /// FAT's answer, as the Store's. A path whose parent is a file is FAT's
    /// `NotFat16`: a write meets it making a directory (`BadName`), a read or
    /// remove looking for one (`NotFound`).
    fn map(e: disk_fat.Error, doing: Doing) Error {
        return switch (e) {
            error.NotFound => Error.NotFound,
            error.IsDirectory => Error.IsDirectory,
            error.BadName, error.NameTaken => Error.BadName,
            error.NotFat16 => switch (doing) {
                .writing => Error.BadName,
                .looking => Error.NotFound,
            },
            error.TooBig => Error.TooBig,
            error.Full, error.DirectoryFull => Error.NoSpace,
            // A volume refusing writes (metal-vmm QUEUE 188.2) is the disk not
            // taking them for now, not damage.
            error.ReadFailed, error.WriteFailed, error.WritesRefused => Error.Io,
            else => Error.Damaged,
        };
    }

    const path_bytes = store.max_parts * (store.max_part + store.temp_prefix.len + 1);

    /// `parts` joined by `/`, with `prefix` on the last, in `buf`.
    fn join(parts: []const []const u8, prefix: []const u8, buf: *[path_bytes]u8) []const u8 {
        var n: usize = 0;
        for (parts, 0..) |p, i| {
            if (i > 0) {
                buf[n] = '/';
                n += 1;
            }
            if (i == parts.len - 1) {
                @memcpy(buf[n..][0..prefix.len], prefix);
                n += prefix.len;
            }
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
        }
        return buf[0..n];
    }

    /// The entry at `path`, or null if there is none. A part that is a file
    /// on the way names nothing.
    fn entryAt(f: *FatStore, path: []const u8) Error!?disk_fat.Entry {
        return f.vol.open(path) catch |e| switch (e) {
            error.NotFound, error.NotFat16 => null,
            else => map(e, .looking),
        };
    }

    pub fn read(f: *FatStore, path: []const u8, out: []u8) Error!usize {
        var pb: [store.max_parts][]const u8 = undefined;
        var jb: [path_bytes]u8 = undefined;
        const p = join(try store.checkPath(path, &pb, false), "", &jb);
        const e = (try f.entryAt(p)) orelse return Error.NotFound;
        if (e.isDirectory()) return Error.IsDirectory;
        return f.vol.readFile(e, out) catch |err| map(err, .looking);
    }

    pub fn write(f: *FatStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        var jb: [path_bytes]u8 = undefined;
        const p = join(try store.checkPath(path, &pb, false), "", &jb);
        f.vol.writeFile(p, bytes) catch |err| return map(err, .writing);
    }

    pub fn append(f: *FatStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        var jb: [path_bytes]u8 = undefined;
        const p = join(try store.checkPath(path, &pb, false), "", &jb);
        const e = (try f.entryAt(p)) orelse return f.vol.writeFile(p, bytes) catch |err| map(err, .writing);
        if (e.isDirectory()) return Error.IsDirectory;
        f.vol.writeInto(p, e.size, bytes) catch |err| return map(err, .writing);
    }

    pub fn remove(f: *FatStore, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        var jb: [path_bytes]u8 = undefined;
        const p = join(try store.checkPath(path, &pb, false), "", &jb);
        const e = (try f.entryAt(p)) orelse return Error.NotFound;
        // disk_fat.remove refuses a directory (B22); a directory goes by removeTree.
        // Store removes files only.
        if (e.isDirectory()) return Error.IsDirectory;
        f.vol.remove(p) catch |err| return map(err, .looking);
    }

    pub fn replace(f: *FatStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        var jb: [path_bytes]u8 = undefined;
        var tb: [path_bytes]u8 = undefined;
        const p = join(parts, "", &jb);
        if (try f.entryAt(p)) |e| if (e.isDirectory()) return Error.IsDirectory;
        const temp = join(parts, store.temp_prefix, &tb);
        f.vol.writeFile(temp, bytes) catch |err| return map(err, .writing);
        // The new bytes on the media before the name that points at them.
        if (f.vol.blk.flush() != @import("virtio_blk.zig").blk_s_ok) return Error.Io;
        f.vol.rename(temp, p) catch |err| {
            f.vol.remove(temp) catch {};
            return map(err, .writing);
        };
    }

    pub fn list(f: *FatStore, path: []const u8, each: store.Each) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, true);
        var cluster: disk_fat.Cluster = 0;
        if (parts.len > 0) {
            var jb: [path_bytes]u8 = undefined;
            const e = (try f.entryAt(join(parts, "", &jb))) orelse return Error.NotFound;
            if (!e.isDirectory()) return Error.NotFound;
            cluster = e.first_cluster;
        }
        var l = f.vol.lister(cluster) catch |err| return map(err, .looking);
        while (l.next() catch |err| return map(err, .looking)) |e| {
            const name = e.text();
            if (store.hidden(name)) continue;
            each.call(each.context, .{ .name = name, .kind = if (e.isDirectory()) .directory else .file, .size = e.size });
        }
    }

    fn self(p: *anyopaque) *FatStore {
        return @ptrCast(@alignCast(p));
    }
    fn readV(p: *anyopaque, path: []const u8, out: []u8) Error!usize {
        return self(p).read(path, out);
    }
    fn writeV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).write(path, bytes);
    }
    fn appendV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).append(path, bytes);
    }
    fn listV(p: *anyopaque, path: []const u8, each: store.Each) Error!void {
        return self(p).list(path, each);
    }
    fn removeV(p: *anyopaque, path: []const u8) Error!void {
        return self(p).remove(path);
    }
    fn replaceV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).replace(path, bytes);
    }
};
