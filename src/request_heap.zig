//! **THE HEAP ONE REQUEST GETS**, and gives back whole when it is answered —
//! the machine's equivalent of the arena `server.zig` hands each request on
//! Linux and frees in one go.
//!
//! It is an arena over the machine's pages, with two things added:
//!
//!   - **A size it keeps.** After every request it shrinks back to `keep`
//!     bytes, so the usual request never asks the page heap for anything, and
//!     an unusual one — a ten megabyte image on its way to disk — does not
//!     leave ten megabytes reserved for the rest of the boot.
//!   - **What the request asked for**, exactly, in bytes. The machine prints
//!     it after every request, and the judge requires the same request to use
//!     the same amount every time: a figure that drifts is a handler keeping
//!     something it should not, and a figure that does not drift is the
//!     strongest statement this machine can make about its memory.
//!
//! **WHY GROWABLE.** A fixed heap makes the largest request the machine can
//! answer a number chosen at build time, and the answer past it is not the
//! answer Linux gives: an upload bigger than the heap failed while it was
//! being read, which is "400, could not read the body" instead of "413, the
//! limit is 10 MB" — and, for a big enough one, the connection closing while
//! the client was still sending.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub const RequestHeap = struct {
    arena: std.heap.ArenaAllocator,
    /// What it shrinks back to after each request.
    keep: usize,
    /// What this request has asked for so far.
    used: usize = 0,
    /// The most any one request has asked for.
    most: usize = 0,

    pub fn init(backing: std.mem.Allocator, keep: usize) RequestHeap {
        return .{ .arena = std.heap.ArenaAllocator.init(backing), .keep = keep };
    }

    pub fn deinit(self: *RequestHeap) void {
        self.arena.deinit();
    }

    /// Takes the memory it keeps up front, so the first request does not pay
    /// for it. False if the machine has not that much to give.
    pub fn preheat(self: *RequestHeap) bool {
        const first = self.arena.allocator().alloc(u8, self.keep) catch {
            props.reachable(@src(), "request heap: the machine has not the memory it keeps", .{ .keep = self.keep });
            return false;
        };
        self.arena.allocator().free(first);
        _ = self.arena.reset(.retain_capacity);
        return true;
    }

    pub fn allocator(self: *RequestHeap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The request is answered: everything it took goes back, down to `keep`.
    pub fn reset(self: *RequestHeap) void {
        self.most = @max(self.most, self.used);
        self.used = 0;
        _ = self.arena.reset(.{ .retain_with_limit = self.keep });
        props.reachable(@src(), "request heap: a request is answered and its memory goes back", null);
    }

    /// How much it holds from the pages, including what it keeps.
    pub fn capacity(self: *RequestHeap) usize {
        return self.arena.queryCapacity();
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RequestHeap = @ptrCast(@alignCast(ctx));
        const inner = self.arena.allocator();
        const p = inner.vtable.alloc(inner.ptr, len, alignment, ret_addr) orelse {
            props.reachable(@src(), "request heap: the pages run out under a request", .{ .len = len });
            return null;
        };
        self.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RequestHeap = @ptrCast(@alignCast(ctx));
        const inner = self.arena.allocator();
        if (!inner.vtable.resize(inner.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.used += new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RequestHeap = @ptrCast(@alignCast(ctx));
        const inner = self.arena.allocator();
        const p = inner.vtable.remap(inner.ptr, memory, alignment, new_len, ret_addr) orelse {
            props.reachable(@src(), "request heap: a block cannot grow in place, and the caller must move it", .{ .len = new_len });
            return null;
        };
        if (new_len > memory.len) self.used += new_len - memory.len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RequestHeap = @ptrCast(@alignCast(ctx));
        const inner = self.arena.allocator();
        inner.vtable.free(inner.ptr, memory, alignment, ret_addr);
    }
};

const testing = std.testing;

test "what a request asked for is what it says, and a reset starts again at nothing" {
    var heap = RequestHeap.init(testing.allocator, 1024);
    defer heap.deinit();
    const a = heap.allocator();
    _ = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 250);
    try testing.expectEqual(@as(usize, 350), heap.used);
    heap.reset();
    try testing.expectEqual(@as(usize, 0), heap.used);
    try testing.expectEqual(@as(usize, 350), heap.most);
}

test "the same request twice asks for the same amount" {
    var heap = RequestHeap.init(testing.allocator, 4096);
    defer heap.deinit();
    var seen: [3]usize = undefined;
    for (&seen) |*s| {
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(heap.allocator(), repeated("a request's worth of work", 40));
        _ = try heap.allocator().dupe(u8, list.items);
        s.* = heap.used;
        heap.reset();
    }
    try testing.expectEqual(seen[0], seen[1]);
    try testing.expectEqual(seen[1], seen[2]);
}

test "it grows past what it keeps, and gives the growth back" {
    var heap = RequestHeap.init(testing.allocator, 4096);
    defer heap.deinit();
    try testing.expect(heap.preheat());
    const before = heap.capacity();
    try testing.expect(before >= 4096);

    const big = try heap.allocator().alloc(u8, 2 * 1024 * 1024);
    @memset(big, 7);
    try testing.expect(heap.capacity() >= 2 * 1024 * 1024);
    heap.reset();
    try testing.expect(heap.capacity() <= before);
    try testing.expect(heap.capacity() >= 4096); // and it kept what it keeps

    // Still usable afterwards, without going back to the pages.
    const small = try heap.allocator().alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), small.len);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), heap.most);
}

test "a heap whose backing allocator has nothing does not preheat" {
    var nothing = std.heap.FixedBufferAllocator.init(&.{});
    var heap = RequestHeap.init(nothing.allocator(), 4096);
    defer heap.deinit();
    try testing.expect(!heap.preheat());
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
