//! **THE STORE, AS PLAIN AS IT CAN BE MADE: THE ORACLE** (metal-vmm QUEUE
//! item 77). Every file and directory in a hash map, by its path folded to
//! lower case; each keeps the case it was made with. No disk, no power, no
//! size: it never answers `NoSpace`, `Damaged` or `Io`. The other stores are
//! judged by whether they answer what this answers (`store.zig` says what
//! each operation means).

const std = @import("std");
const props = @import("coverage");
const store = @import("store.zig");
const Error = store.Error;

pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Folded path -> the entry. The root is "" and always there.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        /// The last part, as it was first written.
        name: []u8,
        kind: store.Kind,
        bytes: std.ArrayListUnmanaged(u8) = .empty,
    };

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Model) void {
        var it = m.entries.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.name);
            e.value_ptr.bytes.deinit(m.gpa);
        }
        m.entries.deinit(m.gpa);
    }

    pub fn store_(m: *Model) store.Store {
        return store.Store.of(Model, m);
    }

    /// `parts[0..n]`, folded and joined, in `buf`.
    fn key(parts: []const []const u8, buf: []u8) []const u8 {
        var n: usize = 0;
        for (parts, 0..) |p, i| {
            if (i > 0) {
                buf[n] = '/';
                n += 1;
            }
            for (p, 0..) |c, j| buf[n + j] = std.ascii.toLower(c);
            n += p.len;
        }
        return buf[0..n];
    }

    const key_bytes = store.max_parts * (store.max_part + 1);

    fn find(m: *Model, parts: []const []const u8) ?*Entry {
        if (parts.len == 0) return null;
        var buf: [key_bytes]u8 = undefined;
        return m.entries.getPtr(key(parts, &buf));
    }

    /// What a read or remove meets on the way: a part that is a file is
    /// `NotFound`, as is one that is missing.
    fn walkTo(m: *Model, parts: []const []const u8) Error!?*Entry {
        for (1..parts.len) |n| {
            const e = m.find(parts[0..n]) orelse {
                props.reachable(@src(), "store model: a path through a folder that is not there", null);
                return Error.NotFound;
            };
            if (e.kind != .directory) {
                props.reachable(@src(), "store model: a path through a file", null);
                return Error.NotFound;
            }
        }
        return m.find(parts);
    }

    /// The parents of `parts`, made where missing: a part that is a file is
    /// `BadName`.
    fn makeParents(m: *Model, parts: []const []const u8) Error!void {
        for (1..parts.len) |n| {
            if (m.find(parts[0..n])) |e| {
                if (e.kind != .directory) {
                    props.reachable(@src(), "store model: a write or folder under a file is refused", null);
                    return Error.BadName;
                }
                continue;
            }
            props.reachable(@src(), "store model: a missing parent folder is made", null);
            try m.put(parts[0..n], .directory);
        }
    }

    fn put(m: *Model, parts: []const []const u8, kind: store.Kind) Error!void {
        var buf: [key_bytes]u8 = undefined;
        const k = m.gpa.dupe(u8, key(parts, &buf)) catch @panic("the model ran out of memory");
        const name = m.gpa.dupe(u8, parts[parts.len - 1]) catch @panic("the model ran out of memory");
        m.entries.put(m.gpa, k, .{ .name = name, .kind = kind }) catch @panic("the model ran out of memory");
        // **EVERY ENTRY'S PARENT IS A FOLDER**: what makeParents promises,
        // checked where an entry is made (O(depth), not the whole map).
        props.always(@src(), parts.len == 1 or (if (m.find(parts[0 .. parts.len - 1])) |p| p.kind == .directory else false), "store model: a new entry's parent is a folder", null);
    }

    pub fn read(m: *Model, path: []const u8, out: []u8) Error!usize {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const e = (try m.walkTo(parts)) orelse {
            props.reachable(@src(), "store model: a read of a file that is not there", null);
            return Error.NotFound;
        };
        if (e.kind == .directory) {
            props.reachable(@src(), "store model: a read of a folder", null);
            return Error.IsDirectory;
        }
        if (e.bytes.items.len > out.len) {
            props.reachable(@src(), "store model: a read into too small a buffer", .{ .size = e.bytes.items.len, .room = out.len });
            return Error.TooBig;
        }
        @memcpy(out[0..e.bytes.items.len], e.bytes.items);
        return e.bytes.items.len;
    }

    /// A file at `parts`, made (with its parents) if absent, for a write of
    /// any kind. A directory there is `IsDirectory`.
    fn fileFor(m: *Model, path: []const u8) Error!*Entry {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        try m.makeParents(parts);
        if (m.find(parts)) |e| {
            if (e.kind == .directory) {
                props.reachable(@src(), "store model: a write over a folder", null);
                return Error.IsDirectory;
            }
            // The name keeps the case it was first written with.
            if (!std.mem.eql(u8, e.name, parts[parts.len - 1])) props.reachable(@src(), "store model: a write in another case keeps the name first written", null);
            return e;
        }
        try m.put(parts, .file);
        return m.find(parts).?;
    }

    pub fn write(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        const e = try m.fileFor(path);
        e.bytes.clearRetainingCapacity();
        e.bytes.appendSlice(m.gpa, bytes) catch @panic("the model ran out of memory");
        props.always(@src(), e.kind == .file and std.mem.eql(u8, e.bytes.items, bytes), "store model: a write leaves a file holding exactly its bytes", null);
    }

    pub fn append(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        const e = try m.fileFor(path);
        const was = e.bytes.items.len;
        e.bytes.appendSlice(m.gpa, bytes) catch @panic("the model ran out of memory");
        props.always(@src(), e.kind == .file and e.bytes.items.len == was + bytes.len, "store model: an append grows a file by exactly its bytes", null);
    }

    /// The same as `write`: the model has no power to lose.
    pub fn replace(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        return m.write(path, bytes);
    }

    pub fn remove(m: *Model, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const e = (try m.walkTo(parts)) orelse {
            props.reachable(@src(), "store model: a remove of a file that is not there", null);
            return Error.NotFound;
        };
        if (e.kind == .directory) {
            props.reachable(@src(), "store model: a remove of a folder is refused", null);
            return Error.IsDirectory;
        }
        var buf: [key_bytes]u8 = undefined;
        const kv = m.entries.fetchRemove(key(parts, &buf)).?;
        m.gpa.free(kv.key);
        m.gpa.free(kv.value.name);
        var bytes = kv.value.bytes;
        bytes.deinit(m.gpa);
    }

    /// **THE SEAM'S OTHER FOLDER OPERATIONS** (STORE.md: the eleven), for the
    /// store judge; not in the six, so not in the vtable.
    ///
    /// A folder and every one above it. A part that is a file is `BadName`,
    /// as in a write.
    pub fn makeDir(m: *Model, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        try m.makeParents(parts);
        if (m.find(parts)) |e| {
            if (e.kind != .directory) {
                props.reachable(@src(), "store model: a folder where a file is is refused", null);
                return Error.BadName;
            }
            props.reachable(@src(), "store model: a folder made again is no error", null);
            return;
        }
        try m.put(parts, .directory);
    }

    /// `path` and everything under it; a file is removed as itself, and
    /// nothing there is no error.
    pub fn removeTree(m: *Model, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        _ = (m.walkTo(parts) catch {
            props.reachable(@src(), "store model: a tree removed through a file or a missing folder is nothing", null);
            return;
        }) orelse {
            props.reachable(@src(), "store model: a tree removed that is not there is nothing", null);
            return;
        };
        var buf: [key_bytes]u8 = undefined;
        const k = key(parts, &buf);
        var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer doomed.deinit(m.gpa);
        var it = m.entries.iterator();
        while (it.next()) |e| {
            const ek = e.key_ptr.*;
            if (std.mem.eql(u8, ek, k) or (ek.len > k.len and std.mem.startsWith(u8, ek, k) and ek[k.len] == '/'))
                doomed.append(m.gpa, ek) catch @panic("the model ran out of memory");
        }
        props.reachable(@src(), "store model: a tree removed", .{ .entries = doomed.items.len });
        for (doomed.items) |ek| {
            const kv = m.entries.fetchRemove(ek).?;
            m.gpa.free(kv.key);
            m.gpa.free(kv.value.name);
            var bytes = kv.value.bytes;
            bytes.deinit(m.gpa);
        }
        // Nothing under it is left: its own key is gone, and so its
        // children's parent (O(1): the walk above found every one).
        props.always(@src(), m.find(parts) == null, "store model: a tree removed is gone", null);
    }

    /// What is at `path`: its kind and, for a file, its size.
    pub fn stat(m: *Model, path: []const u8) Error!struct { kind: store.Kind, size: u64 } {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const e = (try m.walkTo(parts)) orelse {
            props.reachable(@src(), "store model: a stat of nothing", null);
            return Error.NotFound;
        };
        return .{ .kind = e.kind, .size = e.bytes.items.len };
    }

    pub fn list(m: *Model, path: []const u8, each: store.Each) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, true);
        var prefix_buf: [key_bytes]u8 = undefined;
        const prefix = key(parts, &prefix_buf);
        if (parts.len > 0) {
            const e = (try m.walkTo(parts)) orelse {
                props.reachable(@src(), "store model: a list of a folder that is not there", null);
                return Error.NotFound;
            };
            if (e.kind != .directory) {
                props.reachable(@src(), "store model: a list of a file", null);
                return Error.NotFound;
            }
        }
        var it = m.entries.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const rest = if (prefix.len == 0) k else if (k.len > prefix.len and k[prefix.len] == '/' and std.mem.eql(u8, k[0..prefix.len], prefix)) k[prefix.len + 1 ..] else continue;
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            const e = kv.value_ptr;
            each.call(each.context, .{ .name = e.name, .kind = e.kind, .size = e.bytes.items.len });
        }
    }

    /// **THE MODEL'S OWN SHAPE**, all of it, for the tests: every entry's
    /// key is its path folded, its name the last part of it in some case, its
    /// parent a folder, and a folder holds no bytes. O(entries x depth), so
    /// not on every operation.
    pub fn wellFormed(m: *Model) bool {
        var it = m.entries.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const e = kv.value_ptr;
            const last = if (std.mem.lastIndexOfScalar(u8, k, '/')) |at| k[at + 1 ..] else k;
            if (!std.ascii.eqlIgnoreCase(last, e.name)) return false;
            for (k) |c| if (std.ascii.isUpper(c)) return false;
            if (e.kind == .directory and e.bytes.items.len != 0) return false;
            if (std.mem.lastIndexOfScalar(u8, k, '/')) |at| {
                const parent = m.entries.get(k[0..at]) orelse return false;
                if (parent.kind != .directory) return false;
            }
        }
        return true;
    }
};

const testing = std.testing;

test "the model: every operation, and the errors each answers" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var out: [64]u8 = undefined;
    try m.write("Data/Chat/a.md", "hello");
    try testing.expectEqual(@as(usize, 5), try m.read("data/chat/A.MD", &out));
    try m.append("data/chat/a.md", " world");
    try testing.expectEqualStrings("hello world", out[0..try m.read("data/chat/a.md", &out)]);
    try m.append("data/new", "x");
    try m.replace("data/new", "yz");
    try testing.expectEqualStrings("yz", out[0..try m.read("data/new", &out)]);
    try testing.expectError(Error.IsDirectory, m.read("data/chat", &out));
    try testing.expectError(Error.IsDirectory, m.write("data", "x"));
    try testing.expectError(Error.NotFound, m.read("data/none", &out));
    try testing.expectError(Error.NotFound, m.read("data/new/under", &out));
    try testing.expectError(Error.BadName, m.write("data/new/under", "x"));
    try testing.expectError(Error.TooBig, m.read("data/chat/a.md", out[0..3]));
    try testing.expectError(Error.IsDirectory, m.remove("data/chat"));
    try m.remove("DATA/NEW");
    try testing.expectError(Error.NotFound, m.remove("data/new"));
    const Count = struct {
        n: usize = 0,
        fn each(c: *anyopaque, item: store.Item) void {
            const self_: *@This() = @ptrCast(@alignCast(c));
            _ = item;
            self_.n += 1;
        }
    };
    var root = Count{};
    try m.list("", .{ .context = &root, .call = Count.each });
    try testing.expectEqual(@as(usize, 1), root.n); // Data
    var chat = Count{};
    try m.list("data/chat", .{ .context = &chat, .call = Count.each });
    try testing.expectEqual(@as(usize, 1), chat.n);
    try testing.expectError(Error.NotFound, m.list("data/chat/a.md", .{ .context = &chat, .call = Count.each }));
}

/// Each item `list` gives, as "name:kind:size" lines in the order given.
const Listed = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    n: usize = 0,
    fn each(c: *anyopaque, item: store.Item) void {
        const l: *Listed = @ptrCast(@alignCast(c));
        const line = std.fmt.bufPrint(l.buf[l.len..], "{s}:{t}:{d}\n", .{ item.name, item.kind, item.size }) catch unreachable;
        l.len += line.len;
        l.n += 1;
    }
    fn has(l: *const Listed, line: []const u8) bool {
        return std.mem.indexOf(u8, l.buf[0..l.len], line) != null;
    }
    fn of(m: *Model, path: []const u8) Error!Listed {
        var l = Listed{};
        try m.list(path, .{ .context = &l, .call = each });
        return l;
    }
};

test "the model: a folder made, again, under a file, over a file" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.makeDir("Data/Games/7");
    try testing.expectEqual(store.Kind.directory, (try m.stat("data/games")).kind);
    try m.makeDir("data/GAMES/7"); // again: no error
    try m.write("data/f", "x");
    try testing.expectError(Error.BadName, m.makeDir("data/f")); // a file is there
    try testing.expectError(Error.BadName, m.makeDir("data/f/under")); // a parent is a file
    try testing.expect(m.wellFormed());
}

test "the model: stat says a file's size and a folder's kind, and nothing is NotFound" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.write("data/a", "hello");
    const f = try m.stat("DATA/A");
    try testing.expectEqual(store.Kind.file, f.kind);
    try testing.expectEqual(@as(u64, 5), f.size);
    try testing.expectEqual(store.Kind.directory, (try m.stat("data")).kind);
    try testing.expectError(Error.NotFound, m.stat("data/none"));
    try testing.expectError(Error.NotFound, m.stat("none/at/all"));
    try testing.expectError(Error.NotFound, m.stat("data/a/under"));
}

test "the model: a tree removed takes everything under it and nothing beside it" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.write("data/chat/a.md", "a");
    try m.write("data/chat/deep/b.md", "b");
    // A sibling whose name starts with the tree's: not under it.
    try m.write("data/chatter/c.md", "c");
    try m.write("data/chat.md", "d");
    try m.removeTree("DATA/Chat");
    try testing.expectError(Error.NotFound, m.stat("data/chat"));
    try testing.expectError(Error.NotFound, m.stat("data/chat/deep/b.md"));
    try testing.expectEqual(@as(u64, 1), (try m.stat("data/chatter/c.md")).size);
    try testing.expectEqual(@as(u64, 1), (try m.stat("data/chat.md")).size);
    // A file is removed as itself; nothing there, or a path through a file
    // or a missing folder, is no error.
    try m.removeTree("data/chat.md");
    try testing.expectError(Error.NotFound, m.stat("data/chat.md"));
    try m.removeTree("data/none");
    try m.removeTree("none/at/all");
    try m.write("data/f", "x");
    try m.removeTree("data/f/under");
    try testing.expect(m.wellFormed());
}

test "the model: list gives a folder's own entries, its name as first written, and no deeper" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.write("Data/Chat/A.md", "hello");
    try m.write("data/chat/deep/b.md", "b");
    try m.write("data/chatter/c.md", "c");
    try m.write("data/CHAT/a.MD", "hi"); // another case: the first name stays
    const chat = try Listed.of(&m, "data/chat");
    try testing.expectEqual(@as(usize, 2), chat.n);
    try testing.expect(chat.has("A.md:file:2\n"));
    try testing.expect(chat.has("deep:directory:0\n"));
    const data = try Listed.of(&m, "DATA");
    try testing.expectEqual(@as(usize, 2), data.n);
    try testing.expect(data.has("Chat:directory:0\n"));
    try testing.expect(data.has("chatter:directory:0\n"));
    const root = try Listed.of(&m, "");
    try testing.expectEqual(@as(usize, 1), root.n);
    try testing.expect(root.has("Data:directory:0\n"));
    try testing.expectError(Error.NotFound, Listed.of(&m, "data/none"));
    try testing.expectError(Error.NotFound, Listed.of(&m, "none/at/all"));
    try testing.expectError(Error.NotFound, Listed.of(&m, "data/chat/A.md"));
    try testing.expect(m.wellFormed());
}

test "the model: a path the store refuses is refused before the model looks" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var out: [8]u8 = undefined;
    // What `store.checkPath` refuses, every operation refuses alike.
    for ([_][]const u8{ "", "/", "a//b", "a/", "/a", "../x", ".~tmp", "a/b:c", "a/" ++ &@as([store.max_part + 1]u8, @splat('x')), "a/b/c/d/e/f/g/h/i" }) |bad| {
        try testing.expectError(Error.BadName, m.read(bad, &out));
        try testing.expectError(Error.BadName, m.write(bad, "x"));
        try testing.expectError(Error.BadName, m.append(bad, "x"));
        try testing.expectError(Error.BadName, m.remove(bad));
        try testing.expectError(Error.BadName, m.makeDir(bad));
        try testing.expectError(Error.BadName, m.removeTree(bad));
        try testing.expectError(Error.BadName, m.stat(bad));
    }
    try testing.expectEqual(@as(u32, 0), m.entries.count());
}

test "the model: the six through the Store interface answer as the model does" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    const s = m.store_();
    var out: [16]u8 = undefined;
    try s.write("data/a", "one");
    try s.append("data/a", "+two");
    try testing.expectEqualStrings("one+two", out[0..try s.read("data/a", &out)]);
    try s.replace("data/a", "three");
    try testing.expectEqualStrings("three", out[0..try s.read("data/a", &out)]);
    var l = Listed{};
    try s.list("data", .{ .context = &l, .call = Listed.each });
    try testing.expect(l.has("a:file:5\n"));
    try s.remove("data/a");
    try testing.expectError(Error.NotFound, s.read("data/a", &out));
    try testing.expect(m.wellFormed());
}

test "the model: wellFormed sees a broken map (its own check, checked)" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    try m.write("data/a", "x");
    try testing.expect(m.wellFormed());
    // A folder that holds bytes.
    try m.entries.getPtr("data").?.bytes.append(testing.allocator, 'z');
    try testing.expect(!m.wellFormed());
    m.entries.getPtr("data").?.bytes.clearRetainingCapacity();
    // A file whose parent is a file.
    m.entries.getPtr("data").?.kind = .file;
    try testing.expect(!m.wellFormed());
    m.entries.getPtr("data").?.kind = .directory;
    // A name that is not its key's last part.
    const e = m.entries.getPtr("data/a").?;
    const was = e.name;
    e.name = @constCast("b");
    try testing.expect(!m.wellFormed());
    e.name = was;
    try testing.expect(m.wellFormed());
}
