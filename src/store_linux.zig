//! **THE STORE ON A LAPTOP, STRICT** (metal-vmm QUEUE item 79): the six
//! operations (`store.zig`) over `std.Io`'s filesystem, under one directory,
//! keeping FAT's rules so that a laptop refuses what the droplet would.
//!
//! - **Names are checked before the disk is touched** (`store.checkPath`):
//!   the characters FAT forbids, a trailing dot or space, a part too long,
//!   too many parts. Linux would take every one of them.
//! - **Case does not matter, as on FAT.** Each part of a path is found in its
//!   directory ignoring ASCII case (`find`), so `Data/x` opens `data/X`; a
//!   new name is made with the case it is given, and a file written again
//!   keeps the case it has. Linux's own names are case-sensitive; this is the
//!   difference a laptop must not show.
//! - **`replace` is write, sync, rename**, as on FAT: the new bytes under the
//!   Store's hidden name beside the old, synced, then renamed over it.
//!
//! What it does not copy: FAT's limits of space (a laptop has more), and a
//! power cut (`store_sim` cuts the FAT store, which has a disk to cut).

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const Error = store.Error;

pub const LinuxStore = struct {
    io: Io,
    /// Opened with iteration: every lookup lists a directory.
    root: Io.Dir,

    pub fn store_(l: *LinuxStore) store.Store {
        return store.Store.of(LinuxStore, l);
    }

    const path_bytes = store.max_parts * (store.max_part + store.temp_prefix.len + 1);

    /// A path as the disk spells it: each part as it was found, or as given
    /// where it is new.
    const Found = struct {
        buf: [path_bytes]u8 = undefined,
        len: usize = 0,
        /// What the last part is: null if it is not there.
        kind: ?store.Kind = null,

        fn path(f: *const Found) []const u8 {
            return f.buf[0..f.len];
        }

        fn push(f: *Found, part: []const u8) void {
            if (f.len > 0) {
                f.buf[f.len] = '/';
                f.len += 1;
            }
            @memcpy(f.buf[f.len..][0..part.len], part);
            f.len += part.len;
        }
    };

    fn mapOpen(e: anyerror) Error {
        return switch (e) {
            error.FileNotFound, error.NotDir => Error.NotFound,
            error.NameTooLong, error.BadPathName => Error.BadName,
            error.NoSpaceLeft, error.DiskQuota => Error.NoSpace,
            error.IsDir => Error.IsDirectory,
            else => Error.Io,
        };
    }

    /// `name` in the directory `dir` (relative to the root; "" is the root),
    /// ignoring case: the name as the disk spells it, into `out`, and what it
    /// is. Null if there is none.
    fn find(l: *LinuxStore, dir: []const u8, name: []const u8, out: []u8) Error!?struct { name: []const u8, kind: store.Kind } {
        var d = if (dir.len == 0) l.root else l.root.openDir(l.io, dir, .{ .iterate = true }) catch |e| return mapOpen(e);
        defer if (dir.len != 0) d.close(l.io);
        var it = d.iterate();
        while (it.next(l.io) catch |e| return mapOpen(e)) |entry| {
            if (!store.sameName(entry.name, name)) continue;
            @memcpy(out[0..entry.name.len], entry.name);
            return .{ .name = out[0..entry.name.len], .kind = if (entry.kind == .directory) .directory else .file };
        }
        return null;
    }

    /// Every part found as the disk spells it. A part missing, or a file on
    /// the way, ends the walk: `kind` is then null. With `make`, a missing
    /// parent is made and a file on the way is `BadName`, as a write needs.
    fn walk(l: *LinuxStore, parts: []const []const u8, make: bool) Error!Found {
        var f = Found{};
        for (parts, 0..) |part, i| {
            const last = i == parts.len - 1;
            var nb: [store.max_part + store.temp_prefix.len]u8 = undefined;
            const got = try l.find(f.path(), part, &nb);
            if (got) |g| {
                f.push(g.name);
                if (last) {
                    f.kind = g.kind;
                } else if (g.kind != .directory) {
                    if (make) return Error.BadName;
                    f.kind = null;
                    return f;
                }
            } else {
                f.push(part);
                if (last) {
                    f.kind = null;
                } else if (make) {
                    l.root.createDir(l.io, f.path(), .default_dir) catch |e| return mapOpen(e);
                } else {
                    f.kind = null;
                    return f;
                }
            }
        }
        return f;
    }

    pub fn read(l: *LinuxStore, path: []const u8, out: []u8) Error!usize {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const f = try l.walk(parts, false);
        const kind = f.kind orelse return Error.NotFound;
        if (kind == .directory) return Error.IsDirectory;
        const st = l.root.statFile(l.io, f.path(), .{}) catch |e| return mapOpen(e);
        if (st.size > out.len) return Error.TooBig;
        const got = l.root.readFile(l.io, f.path(), out) catch |e| return mapOpen(e);
        return got.len;
    }

    /// The file a write lands on: parents made, a directory refused.
    fn target(l: *LinuxStore, parts: []const []const u8) Error!Found {
        const f = try l.walk(parts, true);
        if (f.kind == .directory) return Error.IsDirectory;
        return f;
    }

    pub fn write(l: *LinuxStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const f = try l.target(try store.checkPath(path, &pb, false));
        l.root.writeFile(l.io, .{ .sub_path = f.path(), .data = bytes }) catch |e| return mapOpen(e);
    }

    pub fn append(l: *LinuxStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const f = try l.target(try store.checkPath(path, &pb, false));
        if (f.kind == null) {
            l.root.writeFile(l.io, .{ .sub_path = f.path(), .data = bytes }) catch |e| return mapOpen(e);
            return;
        }
        var file = l.root.openFile(l.io, f.path(), .{ .mode = .write_only }) catch |e| return mapOpen(e);
        defer file.close(l.io);
        const st = file.stat(l.io) catch |e| return mapOpen(e);
        file.writePositionalAll(l.io, bytes, st.size) catch |e| return mapOpen(e);
    }

    pub fn replace(l: *LinuxStore, path: []const u8, bytes: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const f = try l.target(parts);
        // The hidden name, beside the file, in the directory as it is spelled.
        var temp = Found{};
        const dir_len = std.mem.lastIndexOfScalar(u8, f.path(), '/') orelse 0;
        if (dir_len > 0) temp.push(f.path()[0..dir_len]);
        var tn: [store.max_part + store.temp_prefix.len]u8 = undefined;
        const name = f.path()[if (dir_len > 0) dir_len + 1 else 0..];
        @memcpy(tn[0..store.temp_prefix.len], store.temp_prefix);
        @memcpy(tn[store.temp_prefix.len..][0..name.len], name);
        temp.push(tn[0 .. store.temp_prefix.len + name.len]);
        {
            var file = l.root.createFile(l.io, temp.path(), .{}) catch |e| return mapOpen(e);
            defer file.close(l.io);
            file.writePositionalAll(l.io, bytes, 0) catch |e| return mapOpen(e);
            file.sync(l.io) catch |e| return mapOpen(e);
        }
        Io.Dir.rename(l.root, temp.path(), l.root, f.path(), l.io) catch |e| {
            l.root.deleteFile(l.io, temp.path()) catch {};
            return mapOpen(e);
        };
    }

    pub fn remove(l: *LinuxStore, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const f = try l.walk(try store.checkPath(path, &pb, false), false);
        const kind = f.kind orelse return Error.NotFound;
        if (kind == .directory) return Error.IsDirectory;
        l.root.deleteFile(l.io, f.path()) catch |e| return mapOpen(e);
    }

    pub fn list(l: *LinuxStore, path: []const u8, each: store.Each) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, true);
        var f = Found{};
        if (parts.len > 0) {
            f = try l.walk(parts, false);
            if (f.kind != .directory) return Error.NotFound;
        }
        var d = if (f.len == 0) l.root else l.root.openDir(l.io, f.path(), .{ .iterate = true }) catch |e| return mapOpen(e);
        defer if (f.len != 0) d.close(l.io);
        var it = d.iterate();
        while (it.next(l.io) catch |e| return mapOpen(e)) |entry| {
            if (store.hidden(entry.name)) continue;
            const is_dir = entry.kind == .directory;
            const size: u64 = if (is_dir) 0 else (d.statFile(l.io, entry.name, .{}) catch |e| return mapOpen(e)).size;
            each.call(each.context, .{ .name = entry.name, .kind = if (is_dir) .directory else .file, .size = size });
        }
    }
};
