//! **WHOLE FILES, KEPT IN MEMORY AFTER THEIR FIRST READ** (QUEUE.md item 87):
//! metal's page cache. Two people in one conversation read the same
//! transcript on every send and every refresh, and each read was a directory
//! walk and a run of sector reads; prod's 47 transcripts are 2.3 MB in all.
//!
//! **IT IS BELOW THE APPLICATION**, in `io.zig`, as Linux's page cache is
//! below angry-gopher: the application is unchanged, and Linux needs nothing.
//! io.zig asks it for a data file before the disk, and tells it every change
//! it makes: a whole-file write, an append, a rename, a remove, a tree
//! removed. Every change to the data goes through io.zig (the Store), so
//! nothing reaches the disk around it.
//!
//! **EXACT, OR ABSENT.** What it holds for a path is what the disk holds, or
//! it holds nothing for that path. A change it is told of is applied to the
//! kept copy only when the disk took it; a change that failed drops the path,
//! because after a failed write the disk may hold the old file, the new, or
//! neither (disk_fat's docs), and the next read must ask the disk which.
//!
//! **A CACHE, IN THE LEXICON'S SENSE.** The disk is the source of every file
//! it holds; a kept copy is never written back, and when it cannot be kept
//! exact it is dropped and read again. Its loss costs only reads: every byte
//! of it is reconstructable, which is what lets it be bounded and evicted.
//! A change is applied to the copy from the bytes io.zig wrote, not read
//! back from the disk: exact because the disk answered that it took them.
//!
//! **BOUNDED.** At most `budget` bytes, counted in whole pages as the
//! allocator hands them out, so the count is the memory; at most `slots`
//! files; nothing larger than `largest`, so a big upload is read from the
//! disk as before rather than pushing out every transcript. The file used
//! least recently goes first.
//!
//! **NAMES AS FAT MATCHES THEM.** disk_fat compares names ignoring ASCII case,
//! and a path's empty parts (`data//x`, `data/x/`) name the same file, so the
//! key folds both: two spellings of one file must not be two copies, one of
//! them stale. disk_fat matches each file by one name only (its long name, or
//! its 8.3 name when it has no long one), so there is no third spelling.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub const PageCache = struct {
    /// The longest path kept; longer ones are simply not cached.
    pub const max_key = 256;
    /// How many files at most.
    pub const slots = 4096;
    /// Memory is counted in these, as the kernel's allocator gives it out.
    pub const page = 4096;

    alloc: std.mem.Allocator,
    budget: usize,
    largest: usize,

    /// Bytes of memory held, in whole pages.
    held: usize = 0,
    count: usize = 0,
    clock: u64 = 0,

    keys: [slots][max_key]u8 = undefined,
    key_lens: [slots]u16 = undefined,
    /// Each file's memory, of which the first `lens[i]` bytes are the file.
    bufs: [slots][]u8 = undefined,
    lens: [slots]usize = undefined,
    /// When each was last used, by `clock`: the least goes first.
    used: [slots]u64 = undefined,

    /// For a host's report and the tests.
    hits: u64 = 0,
    misses: u64 = 0,
    evicted: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, budget: usize, largest: usize) PageCache {
        return .{ .alloc = alloc, .budget = budget, .largest = largest };
    }

    /// The key for `path`, in `out`, or null if it is too long to keep or has
    /// an empty part (a doubled, leading or trailing slash: a path built
    /// wrong, which FAT refuses too, never kept under the path it might mean).
    fn keyOf(path: []const u8, out: *[max_key]u8) ?[]const u8 {
        if (path.len > 0 and (path[0] == '/' or path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null)) {
            props.reachable(@src(), "page cache: a path with an empty part is never kept", null);
            return null;
        }
        var n: usize = 0;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (n != 0) {
                if (n >= max_key) return tooLong();
                out[n] = '/';
                n += 1;
            }
            if (n + part.len > max_key) return tooLong();
            for (part, 0..) |c, i| out[n + i] = std.ascii.toLower(c);
            n += part.len;
        }
        return out[0..n];
    }

    fn tooLong() ?[]const u8 {
        props.reachable(@src(), "page cache: a path too long to key is never kept", null);
        return null;
    }

    fn find(self: *const PageCache, key: []const u8) ?usize {
        for (0..self.count) |i| {
            if (self.key_lens[i] == key.len and std.mem.eql(u8, self.keys[i][0..key.len], key)) return i;
        }
        return null;
    }

    fn roundUp(n: usize) usize {
        return std.mem.alignForward(usize, @max(n, 1), page);
    }

    /// The kept bytes of `path`, or null. They are the cache's: a caller
    /// copies them before anything else changes the cache.
    pub fn get(self: *PageCache, path: []const u8) ?[]const u8 {
        var kb: [max_key]u8 = undefined;
        const key = keyOf(path, &kb) orelse return null;
        const i = self.find(key) orelse {
            self.misses += 1;
            return null;
        };
        self.clock += 1;
        self.used[i] = self.clock;
        self.hits += 1;
        return self.bufs[i][0..self.lens[i]];
    }

    /// Drops slot `i`, moving the last into its place.
    fn drop(self: *PageCache, i: usize) void {
        self.alloc.free(self.bufs[i]);
        self.held -= self.bufs[i].len;
        const last = self.count - 1;
        if (i != last) {
            self.keys[i] = self.keys[last];
            self.key_lens[i] = self.key_lens[last];
            self.bufs[i] = self.bufs[last];
            self.lens[i] = self.lens[last];
            self.used[i] = self.used[last];
        }
        self.count = last;
    }

    /// Makes room for `bytes` more, dropping the least recently used files,
    /// but never slot `keep`. False if it cannot.
    fn room(self: *PageCache, bytes: usize, keep: ?usize) bool {
        var keep_at = keep;
        while (self.held + bytes > self.budget) {
            var oldest: ?usize = null;
            for (0..self.count) |i| {
                if (keep_at != null and i == keep_at.?) continue;
                if (oldest == null or self.used[i] < self.used[oldest.?]) oldest = i;
            }
            const o = oldest orelse {
                props.reachable(@src(), "page cache: no room, with nothing left to evict but the file itself", .{ .bytes = bytes });
                return false;
            };
            props.reachable(@src(), "page cache: the least recently used file is evicted for room", null);
            // Dropping moves the last slot into `o`: follow `keep` if it was
            // the last.
            if (keep_at) |k| if (k == self.count - 1) {
                keep_at = o;
            };
            self.drop(o);
            self.evicted += 1;
        }
        return true;
    }

    /// `path` is now `bytes` on the disk, just read whole: kept, room
    /// allowing.
    /// The most bytes any run held, against the budget (zig-coverage-sdk's
    /// comparisons): a property only.
    fn noteHeld(self: *const PageCache) void {
        props.alwaysLessThanOrEqualTo(@src(), self.held, self.budget, "page cache: the bytes held stay within its budget", null);
        props.alwaysLessThanOrEqualTo(@src(), self.count, slots, "page cache: the files kept stay within its slots", null);
    }

    pub fn put(self: *PageCache, path: []const u8, bytes: []const u8) void {
        var kb: [max_key]u8 = undefined;
        const key = keyOf(path, &kb) orelse return;
        if (self.find(key)) |i| self.drop(i);
        if (bytes.len > self.largest) {
            props.reachable(@src(), "page cache: a file larger than the largest is not kept", .{ .bytes = bytes.len });
            return;
        }
        const size = roundUp(bytes.len);
        if (size > self.budget) {
            props.reachable(@src(), "page cache: a file whose pages pass the whole budget is not kept", .{ .bytes = bytes.len });
            return;
        }
        // Within the budget, room is always found: everything else can go.
        if (!self.room(size, null)) {
            props.@"unreachable"(@src(), "page cache: no room for a file within the budget", .{ .bytes = bytes.len });
            return;
        }
        if (self.count == slots) {
            props.reachable(@src(), "page cache: every slot is taken, so the oldest file goes", null);
            if (!self.dropOldest()) return;
        }
        const buf = self.alloc.alloc(u8, size) catch {
            props.reachable(@src(), "page cache: no memory for a copy, so the file is not kept", .{ .bytes = size });
            return;
        };
        @memcpy(buf[0..bytes.len], bytes);
        const i = self.count;
        @memcpy(self.keys[i][0..key.len], key);
        self.key_lens[i] = @intCast(key.len);
        self.bufs[i] = buf;
        self.lens[i] = bytes.len;
        self.clock += 1;
        self.used[i] = self.clock;
        self.held += size;
        self.count += 1;
        self.noteHeld();
    }

    /// `path` was written whole on the disk as `bytes`. **A WRITE NEVER
    /// BRINGS A FILE IN** (write-no-allocate): a kept copy is replaced, and a
    /// file not kept stays out. Only a read is a sign the file will be read
    /// again; a client that only uploads pictures would otherwise push out
    /// every transcript a reader wants (CC's soak, QUEUE.md item 83).
    pub fn replaced(self: *PageCache, path: []const u8, bytes: []const u8) void {
        var kb: [max_key]u8 = undefined;
        const key = keyOf(path, &kb) orelse return;
        if (self.find(key) == null) return;
        self.put(path, bytes);
    }

    fn dropOldest(self: *PageCache) bool {
        if (self.count == 0) return false;
        var oldest: usize = 0;
        for (1..self.count) |i| if (self.used[i] < self.used[oldest]) {
            oldest = i;
        };
        self.drop(oldest);
        self.evicted += 1;
        return true;
    }

    /// `bytes` landed at `offset` of `path` on the disk (an append, at the
    /// end; an overwrite, inside). A kept copy takes them; one that would
    /// grow past `largest`, or that has a hole (`offset` past its end, which
    /// the disk refuses anyway), is dropped.
    pub fn wrote(self: *PageCache, path: []const u8, offset: usize, bytes: []const u8) void {
        var kb: [max_key]u8 = undefined;
        const key = keyOf(path, &kb) orelse return;
        var i = self.find(key) orelse return;
        const len = self.lens[i];
        const end = offset + bytes.len;
        if (offset > len) {
            props.reachable(@src(), "page cache: a write past a kept file's end drops the copy", null);
            return self.drop(i);
        }
        if (end > self.largest) {
            props.reachable(@src(), "page cache: a write that grows a copy past the largest drops it", null);
            return self.drop(i);
        }
        if (end > self.bufs[i].len) {
            // Grows by a quarter more than it needs, so a run of appends
            // does not copy the file each time.
            const size = @min(roundUp(end + end / 4), roundUp(self.largest));
            const more = size - self.bufs[i].len;
            if (!self.room(more, i)) {
                props.reachable(@src(), "page cache: no room to grow a copy, so it is dropped", .{ .more = more });
                return self.drop(self.find(key).?);
            }
            i = self.find(key).?;
            const buf = self.alloc.alloc(u8, size) catch {
                props.reachable(@src(), "page cache: no memory to grow a copy, so it is dropped", .{ .bytes = size });
                return self.drop(i);
            };
            @memcpy(buf[0..len], self.bufs[i][0..len]);
            self.alloc.free(self.bufs[i]);
            self.held += more;
            self.bufs[i] = buf;
            self.noteHeld();
        }
        @memcpy(self.bufs[i][offset..end], bytes);
        self.lens[i] = @max(len, end);
        props.alwaysLessThanOrEqualTo(@src(), self.lens[i], self.largest, "page cache: a kept file is never larger than the largest", null);
    }

    /// Nothing is known of `path` any more: it was removed, or a change to it
    /// failed and the disk must say what it holds.
    pub fn forget(self: *PageCache, path: []const u8) void {
        var kb: [max_key]u8 = undefined;
        const key = keyOf(path, &kb) orelse return;
        if (self.find(key)) |i| self.drop(i);
    }

    /// `from` was renamed to `to` on the disk, over any `to` there was.
    pub fn renamed(self: *PageCache, from: []const u8, to: []const u8) void {
        var fb: [max_key]u8 = undefined;
        var tb: [max_key]u8 = undefined;
        const to_key = keyOf(to, &tb);
        if (to_key) |k| if (self.find(k)) |i| self.drop(i);
        const from_key = keyOf(from, &fb) orelse return;
        const i = self.find(from_key) orelse return;
        const k = to_key orelse {
            props.reachable(@src(), "page cache: a file renamed to a path too long to key is dropped", null);
            return self.drop(i);
        };
        @memcpy(self.keys[i][0..k.len], k);
        self.key_lens[i] = @intCast(k.len);
    }

    /// `path`, and everything under it, is gone (or may be).
    pub fn forgetTree(self: *PageCache, path: []const u8) void {
        var kb: [max_key]u8 = undefined;
        // Too long to key: nothing under it was ever kept either.
        const key = keyOf(path, &kb) orelse return;
        var i: usize = 0;
        while (i < self.count) {
            const k = self.keys[i][0..self.key_lens[i]];
            const under = key.len == 0 or std.mem.eql(u8, k, key) or
                (k.len > key.len and k[key.len] == '/' and std.mem.eql(u8, k[0..key.len], key));
            if (under) self.drop(i) else i += 1;
        }
    }

    pub fn clear(self: *PageCache) void {
        while (self.count > 0) self.drop(self.count - 1);
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn make(budget: usize, largest: usize) !*PageCache {
    const c = try testing.allocator.create(PageCache);
    c.* = PageCache.init(testing.allocator, budget, largest);
    return c;
}

fn done(c: *PageCache) void {
    c.clear();
    testing.allocator.destroy(c);
}

test "a file put is got back, under any spelling FAT takes for it" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    c.put("data/chat/Plan.md", "the plan");
    try testing.expectEqualStrings("the plan", c.get("data/chat/plan.md").?);
    try testing.expectEqualStrings("the plan", c.get("DATA/chat/PLAN.MD").?);
    // A path with an empty part is no spelling FAT takes (disk_fat
    // `hasEmptyPart`): it names nothing here either (the normalization hunt).
    try testing.expect(c.get("DATA//chat/PLAN.MD/") == null);
    try testing.expect(c.get("/data/chat/plan.md") == null);
    try testing.expect(c.get("data/chat/plan.m") == null);
    try testing.expect(c.get("data/plan.md") == null);
    // A second put replaces it, under another spelling too.
    c.put("data/chat/PLAN.md", "changed");
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqualStrings("changed", c.get("data/chat/plan.md").?);
    try testing.expectEqual(@as(usize, PageCache.page), c.held);
}

test "a whole-file write replaces a kept copy and never brings a file in" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    c.replaced("data/uploads/picture", "an upload");
    try testing.expect(c.get("data/uploads/picture") == null);
    try testing.expectEqual(@as(usize, 0), c.count);
    c.put("data/chat/plan.md", "the plan");
    c.replaced("DATA/chat/Plan.md", "changed");
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqualStrings("changed", c.get("data/chat/plan.md").?);
}

test "appends and overwrites land in the kept copy; a hole or a file grown past largest is dropped" {
    const c = try make(1 << 20, 10_000);
    defer done(c);
    c.put("data/log", "one\n");
    c.wrote("data/log", 4, "two\n");
    try testing.expectEqualStrings("one\ntwo\n", c.get("data/log").?);
    c.wrote("data/log", 0, "ONE");
    try testing.expectEqualStrings("ONE\ntwo\n", c.get("data/log").?);
    // Past a page: the copy grows, and keeps what it held.
    var big: [6000]u8 = undefined;
    @memset(&big, 'x');
    c.wrote("data/log", 8, &big);
    const got = c.get("data/log").?;
    try testing.expectEqual(@as(usize, 6008), got.len);
    try testing.expectEqualStrings("ONE\ntwo\n", got[0..8]);
    try testing.expect(c.held >= 6008 and c.held % PageCache.page == 0);
    // A write to a file not kept changes nothing.
    c.wrote("data/other", 0, "x");
    try testing.expect(c.get("data/other") == null);
    // A hole: dropped.
    c.wrote("data/log", 7000, "x");
    try testing.expect(c.get("data/log") == null);
    try testing.expectEqual(@as(usize, 0), c.held);
    // Past largest: dropped.
    c.put("data/log", "a");
    c.wrote("data/log", 1, &big);
    c.wrote("data/log", 6001, &big);
    try testing.expect(c.get("data/log") == null);
    try testing.expectEqual(@as(usize, 0), c.held);
}

test "the budget holds: the least recently used go first, and a file larger than largest is never kept" {
    const c = try make(4 * PageCache.page, 3 * PageCache.page);
    defer done(c);
    c.put("data/a", "a");
    c.put("data/b", "b");
    c.put("data/c", "c");
    c.put("data/d", "d");
    _ = c.get("data/a"); // a is now the most recent
    c.put("data/e", "e"); // b goes
    try testing.expect(c.get("data/b") == null);
    try testing.expect(c.get("data/a") != null);
    try testing.expectEqual(@as(usize, 4 * PageCache.page), c.held);
    // Two pages' worth pushes out the two least recent.
    var two: [PageCache.page + 1]u8 = undefined;
    @memset(&two, 't');
    c.put("data/two", &two);
    try testing.expect(c.held <= c.budget);
    try testing.expectEqualSlices(u8, &two, c.get("data/two").?);
    // Too large to keep: not kept, and nothing pushed out for it.
    const before = c.count;
    var huge: [3 * PageCache.page + 1]u8 = undefined;
    c.put("data/huge", &huge);
    try testing.expect(c.get("data/huge") == null);
    try testing.expectEqual(before, c.count);
    // An append that would need more than the budget, with the others
    // pushed out, drops the file appended to as well rather than overrun.
    c.put("data/grow", "g");
    c.wrote("data/grow", 1, two[0..PageCache.page]);
    try testing.expect(c.held <= c.budget);
}

test "rename moves the copy over any at the new name; a tree removed takes everything under it, and only that" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    c.put("data/rec.tmp", "new");
    c.put("data/rec", "old");
    c.renamed("data/rec.tmp", "data/REC");
    try testing.expectEqualStrings("new", c.get("data/rec").?);
    try testing.expect(c.get("data/rec.tmp") == null);
    try testing.expectEqual(@as(usize, 1), c.count);
    // From a name not kept: whatever was kept at the new name is stale.
    c.renamed("data/x.tmp", "data/rec");
    try testing.expect(c.get("data/rec") == null);

    c.put("data/users/7/profile", "p");
    c.put("data/users/7/games/1/state", "s");
    c.put("data/users/70/profile", "not 7's");
    c.put("data/users/7", "a file named like the tree");
    c.forgetTree("data/users/7");
    try testing.expect(c.get("data/users/7/profile") == null);
    try testing.expect(c.get("data/users/7/games/1/state") == null);
    try testing.expect(c.get("data/users/7") == null);
    try testing.expectEqualStrings("not 7's", c.get("data/users/70/profile").?);
}

test "memory that cannot be had leaves the file uncached, never a wrong copy" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var c = PageCache.init(failing.allocator(), 1 << 20, 64 << 10);
    c.put("data/a", "a"); // the first allocation succeeds
    c.put("data/b", "b"); // the second fails
    try testing.expect(c.get("data/b") == null);
    // Growing a copy that cannot get memory drops it.
    var more: [PageCache.page]u8 = undefined;
    @memset(&more, 'm');
    c.wrote("data/a", 1, &more);
    try testing.expect(c.get("data/a") == null);
    try testing.expectEqual(@as(usize, 0), c.held);
    c.clear();
}

test "a path too long to key is never kept" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    const long = "data/" ++ &@as([PageCache.max_key]u8, @splat('x'));
    c.put(long, "x");
    try testing.expect(c.get(long) == null);
    c.put("data/a", "a");
    c.forgetTree(long);
    try testing.expectEqual(@as(usize, 1), c.count);
}

test "a key of max_key bytes is kept, and one of max_key + 1 is not" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    const fits = "data/" ++ &@as([PageCache.max_key - 5]u8, @splat('x'));
    const over = "data/" ++ &@as([PageCache.max_key - 4]u8, @splat('x'));
    try testing.expectEqual(PageCache.max_key, fits.len);
    c.put(fits, "kept");
    c.put(over, "not");
    try testing.expectEqualStrings("kept", c.get(fits).?);
    try testing.expect(c.get(over) == null);
}

test "a slash at the key's last byte, or just past it, leaves no room for the next part" {
    const c = try make(1 << 20, 64 << 10);
    defer done(c);
    // The slash at max_key - 2: one byte left, and the part takes it.
    const fits = &@as([PageCache.max_key - 2]u8, @splat('x')) ++ "/y";
    // The slash at max_key - 1: the part would be the byte past the end.
    const over = &@as([PageCache.max_key - 1]u8, @splat('x')) ++ "/y";
    // A part filling the key: the slash itself does not fit.
    const whole = &@as([PageCache.max_key]u8, @splat('x'));
    c.put(fits, "kept");
    c.put(over, "not");
    c.put(whole, "kept too");
    c.put(whole ++ "/y", "not either");
    try testing.expectEqualStrings("kept", c.get(fits).?);
    try testing.expect(c.get(over) == null);
    try testing.expectEqualStrings("kept too", c.get(whole).?);
    try testing.expect(c.get(whole ++ "/y") == null);
}

test "a write at a kept file's end is an append; one byte past it is a hole, and drops the copy" {
    const c = try make(1 << 20, 10_000);
    defer done(c);
    c.put("data/a", "abc");
    c.put("data/b", "abc");
    c.wrote("data/a", 3, "d");
    c.wrote("data/b", 4, "d");
    try testing.expectEqualStrings("abcd", c.get("data/a").?);
    try testing.expect(c.get("data/b") == null);
}

test "a copy grown to exactly largest is kept; one byte more drops it" {
    const largest = 10_000;
    const c = try make(1 << 20, largest);
    defer done(c);
    var rest: [largest - 1]u8 = undefined;
    @memset(&rest, 'r');
    c.put("data/a", "a");
    c.put("data/b", "b");
    c.wrote("data/a", 1, &rest);
    c.wrote("data/b", 1, &rest ++ "!");
    try testing.expectEqual(@as(usize, largest), c.get("data/a").?.len);
    try testing.expect(c.get("data/b") == null);
}

test "a file of exactly largest is kept; one byte more is not" {
    const largest = 10_000;
    const c = try make(1 << 20, largest);
    defer done(c);
    var bytes: [largest + 1]u8 = undefined;
    @memset(&bytes, 'f');
    c.put("data/a", bytes[0..largest]);
    c.put("data/b", &bytes);
    try testing.expectEqual(@as(usize, largest), c.get("data/a").?.len);
    try testing.expect(c.get("data/b") == null);
}
