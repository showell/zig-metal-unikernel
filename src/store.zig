//! **THE STORE: THE NARROW DATA DOOR** (metal-vmm QUEUE items 77 and 79).
//!
//! What a web server in a box gives its applications for their data: named
//! files, whole, and six operations on them, nothing else:
//!
//! | operation | does | after a power cut at any point |
//! |---|---|---|
//! | `read` | a file, whole, into the caller's buffer | (reads change nothing) |
//! | `write` | a file, whole, made or written over | old, new, or **neither** |
//! | `append` | bytes on a file's end, making it if absent | old or new |
//! | `list` | a directory's names, each a file or a directory | (reads change nothing) |
//! | `remove` | a file | there, or gone |
//! | `replace` | a file, whole, made or written over | **wholly old or wholly new** |
//!
//! `write` is the cheap one; `replace` is the one to use when losing the old
//! file in a power cut would matter. That is the whole difference.
//!
//! **AN ERROR IS NOT AN UNDO.** A changing operation that answers a disk's
//! failure (`ReadFailed`, `WriteFailed`) may still have taken effect: a
//! disk can take a write it refuses. What it leaves is one of the outcomes
//! the table names for a power cut, so a `remove` that failed may have
//! removed (a retry answers `NotFound`), and a `replace` that failed may be
//! wholly new, never neither. A caller that must know reads back.
//!
//! **NAMES** (`checkPath`). A path is parts between `/`; empty parts are
//! ignored, so `data//x` and `data/x/` are `data/x`. A part is 1 to
//! `max_part` bytes, not `.` or `..`, holds no control byte and none of
//! `"*/:<>?\|`, does not end in `.` or a space, and does not begin with
//! `temp_prefix`, which is the Store's own. Case does not matter: `A` and
//! `a` name one file, and a file keeps the case it was first written with.
//! At most `max_parts` parts. These are FAT's rules, kept by every
//! implementation, so a laptop refuses what the droplet would.
//!
//! **DIRECTORIES** are made by `write`, `append` and `replace` for the
//! parents they need, and are never removed by the Store. A part that is a
//! file where a directory is needed refuses the write (`BadName`); a path
//! through a file names nothing (`NotFound`).
//!
//! **ERRORS** (`Error`), and which of the floor's refusals answer each
//! (zig-metal-unikernel COVERAGE.md, "Errors under the Store"):
//!
//! - `NotFound`: no such file or directory (disk_fat `NotFound`, and a path
//!   whose parent is a file, `NotFat16`, where a read or remove meets it).
//! - `IsDirectory`: a file operation on a directory (disk_fat `IsDirectory`).
//! - `BadName`: a path the rules above refuse, or one through a file where a
//!   directory must be made (disk_fat `BadName`, and `NotFat16` on a write),
//!   or a new name that is another file's 8.3 alias (disk_fat `NameTaken`).
//! - `TooBig`: a file larger than the buffer it is read into (disk_fat `TooBig`).
//! - `NoSpace`: the volume or a directory is full (disk_fat `Full`,
//!   `DirectoryFull`). The model never answers it: it has no size.
//! - `Damaged`: the volume is not what it should be (disk_fat `BadChain`, and
//!   any of `mount`'s refusals met later).
//! - `Io`: the disk refused a request (disk_fat `ReadFailed`, `WriteFailed`, a
//!   failed flush).
//!
//! The implementations: `store_model.zig` (the oracle, in memory),
//! `store_fat.zig` (over `disk_fat.zig`), and the strict Linux store (item 79).

const std = @import("std");

pub const Error = error{ NotFound, IsDirectory, BadName, TooBig, NoSpace, Damaged, Io };

/// The longest part of a path. FAT's longest name is `disk_fat.max_name` (96);
/// this leaves room for `temp_prefix` on it.
pub const max_part = 80;
/// The most parts in a path. FAT's deepest directory is 15 down.
pub const max_parts = 8;
/// The Store's own names, for `replace`'s new file before it is renamed over
/// the old. A path may not use it, and `list` never shows it.
pub const temp_prefix = ".~";

pub const Kind = enum { file, directory };

/// One name in a directory. `name` lives only until `each` returns.
pub const Item = struct { name: []const u8, kind: Kind, size: u64 };

/// What `list` calls once for each name.
pub const Each = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, item: Item) void,
};

/// **ANY STORE**, one of the three, behind one door.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, []const u8, []u8) Error!usize,
        write: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        append: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        list: *const fn (*anyopaque, []const u8, Each) Error!void,
        remove: *const fn (*anyopaque, []const u8) Error!void,
        replace: *const fn (*anyopaque, []const u8, []const u8) Error!void,
    };

    /// `path`'s bytes into `out`; how many.
    pub fn read(s: Store, path: []const u8, out: []u8) Error!usize {
        return s.vtable.read(s.ptr, path, out);
    }
    pub fn write(s: Store, path: []const u8, bytes: []const u8) Error!void {
        return s.vtable.write(s.ptr, path, bytes);
    }
    pub fn append(s: Store, path: []const u8, bytes: []const u8) Error!void {
        return s.vtable.append(s.ptr, path, bytes);
    }
    /// The directory `path` (`""` is the root), one `each` per name.
    pub fn list(s: Store, path: []const u8, each: Each) Error!void {
        return s.vtable.list(s.ptr, path, each);
    }
    pub fn remove(s: Store, path: []const u8) Error!void {
        return s.vtable.remove(s.ptr, path);
    }
    pub fn replace(s: Store, path: []const u8, bytes: []const u8) Error!void {
        return s.vtable.replace(s.ptr, path, bytes);
    }

    /// **THE STORE A `*T` IS**: its vtable made from `T`'s own `read`,
    /// `write`, `append`, `list`, `remove` and `replace`, each called on the
    /// `T` behind the pointer. Each store wrote these six casts by hand, the
    /// same each time (shale's cookbook/zig/clones.shale found the three).
    pub fn of(comptime T: type, ptr: *T) Store {
        return .{ .ptr = ptr, .vtable = vtableOf(T) };
    }

    fn vtableOf(comptime T: type) *const VTable {
        const S = struct {
            fn self(p: *anyopaque) *T {
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
            fn listV(p: *anyopaque, path: []const u8, each: Each) Error!void {
                return self(p).list(path, each);
            }
            fn removeV(p: *anyopaque, path: []const u8) Error!void {
                return self(p).remove(path);
            }
            fn replaceV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
                return self(p).replace(path, bytes);
            }
            const vtable = VTable{ .read = readV, .write = writeV, .append = appendV, .list = listV, .remove = removeV, .replace = replaceV };
        };
        return &S.vtable;
    }
};

/// A path's parts, checked against the rules (the file's comment), into
/// `out`. `allow_root`: the empty path, which only `list` takes. **Every part
/// is named**: an empty one (a doubled, leading or trailing slash) is a path
/// built wrong, refused by `checkPart`, never read as what it might mean.
pub fn checkPath(path: []const u8, out: *[max_parts][]const u8, allow_root: bool) Error![]const []const u8 {
    if (path.len == 0) return if (allow_root) out[0..0] else Error.BadName;
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (n == max_parts) return Error.BadName;
        try checkPart(part);
        out[n] = part;
        n += 1;
    }
    if (n == 0 and !allow_root) return Error.BadName;
    return out[0..n];
}

pub fn checkPart(part: []const u8) Error!void {
    if (part.len == 0 or part.len > max_part) return Error.BadName;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return Error.BadName;
    if (std.mem.startsWith(u8, part, temp_prefix)) return Error.BadName;
    for (part) |c| {
        // Control characters, and past ASCII: FAT holds a name's bytes as
        // UTF-16 units and refuses any past ASCII (metal-vmm QUEUE 104), so
        // every store refuses them too.
        if (c < 0x20 or c >= 0x7F) return Error.BadName;
        if (std.mem.indexOfScalar(u8, "\"*/:<>?\\|", c) != null) return Error.BadName;
    }
    const last = part[part.len - 1];
    if (last == '.' or last == ' ') return Error.BadName;
}

/// Whether a name `list` meets is the Store's own, or a directory's `.`
/// and `..`: never shown.
pub fn hidden(name: []const u8) bool {
    return std.mem.startsWith(u8, name, temp_prefix) or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// `a` and `b` name one file.
pub fn sameName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const testing = std.testing;

test "paths: an empty part refused, FAT's rules kept, the Store's prefix refused" {
    var buf: [max_parts][]const u8 = undefined;
    const p = try checkPath("data/chat/x.md", &buf, false);
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expectEqualStrings("x.md", p[2]);
    // **A PATH IS ITS PARTS, EACH NAMED** (Steve, 2026-10-10: no papering
    // over): a doubled, leading or trailing slash is a path built wrong, and
    // is refused, never read as the path it might have meant.
    for ([_][]const u8{ "data//chat/x.md", "/data", "data/", "data/chat//", "//" }) |bad| {
        try testing.expectError(Error.BadName, checkPath(bad, &buf, false));
        try testing.expectError(Error.BadName, checkPath(bad, &buf, true));
    }
    for ([_][]const u8{ "", "/", "a/./b", "a/../b", "a:b", "what?", "trailing.", "trailing ", ".~mine", "a\x01b", "a\x7fb", "caf\xc3\xa9", "a/b/c/d/e/f/g/h/i" }) |bad| {
        try testing.expectError(Error.BadName, checkPath(bad, &buf, false));
    }
    try testing.expectEqual(@as(usize, 0), (try checkPath("", &buf, true)).len);
    try testing.expectError(Error.BadName, checkPart(&@as([max_part + 1]u8, @splat('x'))));
    try checkPart(&@as([max_part]u8, @splat('x')));
}

test "paths: max_parts parts are a path, max_parts + 1 are not; a part of max_part is a name, max_part + 1 is not" {
    var buf: [max_parts][]const u8 = undefined;
    const deepest = repeated("a/", max_parts - 1) ++ "a";
    try testing.expectEqual(@as(usize, max_parts), (try checkPath(deepest, &buf, false)).len);
    try testing.expectError(Error.BadName, checkPath(deepest ++ "/a", &buf, false));
    try testing.expectError(Error.BadName, checkPath(deepest ++ "/a", &buf, true));
    const longest = &@as([max_part]u8, @splat('x'));
    try testing.expectEqual(@as(usize, 2), (try checkPath("data/" ++ longest, &buf, false)).len);
    try testing.expectError(Error.BadName, checkPath("data/" ++ longest ++ "x", &buf, false));
    // A part of one byte is a name; of none, a path built wrong.
    try checkPart("x");
    try testing.expectError(Error.BadName, checkPart(""));
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}
