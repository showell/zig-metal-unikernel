//! The kernel's one stack, and the telemetry that says how much of it is used.
//!
//! **16 MB, because that is what the same code got on Linux.** angry-gopher
//! serves each request on a thread from `std.Thread`'s pool, and
//! `SpawnConfig.default_stack_size` is 16 MB. This machine runs the same route
//! table over the same std library with no threads at all — but the frames are
//! the frames, and the deepest one is as deep here as there. This stack was
//! 64 KB, a 250x shortfall, and `/chat/recent` triple-faulted the machine:
//! the fault handler has no stack either, so the third fault is a reset with
//! nothing in the log.
//!
//! **PAINTED, SO THE DEPTH IS MEASURED RATHER THAN HOPED FOR.** The boot stub
//! fills the whole region with `paint` before it sets `rsp`. Afterwards the
//! lowest word that is no longer `paint` is the high-water mark: everything
//! below it has never been touched by any call this boot. That is a
//! measurement of the real route table on the real requests, not an estimate.
//!
//! **AND THE BOTTOM IS A GUARD.** If the lowest `guard` bytes have been
//! written, a frame came within that much of running off the end — and off the
//! end is `.bss`, where the heaps and the device rings live, so the corruption
//! would be silent and arbitrary. A breached guard stops the machine.
//!
//! One blind spot, stated: a stack word that legitimately holds `paint` reads
//! as untouched, so the mark can only ever come out *shallower* than the truth,
//! never deeper. 0xA5A5… is not a plausible pointer, length or ASCII.

const std = @import("std");

/// `std.Thread.SpawnConfig.default_stack_size`, which is what a request thread
/// gets on the Linux host. Kept as the expression rather than the number so it
/// tracks std rather than a memory of std.
pub const size: usize = std.Thread.SpawnConfig.default_stack_size;

/// Not a pointer, not a length, not ASCII, and not zero: a word that is still
/// this was never written by a frame.
pub const paint: u64 = 0xA5A5_A5A5_A5A5_A5A5;

/// How close to the end is too close. A frame that reaches into this has not
/// corrupted anything yet, which is the whole point of noticing here.
pub const guard: usize = 64 * 1024;

/// **The stack itself.** `.bss`, so the 16 MB is a number in a program header
/// rather than 16 MB of zeros in the kernel image, and nothing in it may be
/// assumed zero — the stub paints it before anything runs on it.
///
/// 4096-aligned so the region starts on a page, which makes the addresses in a
/// fault report easy to place.
pub export var kernel_stack: [size]u8 align(4096) = @splat(0);

pub const Usage = struct {
    /// The high-water mark: bytes between the top and the deepest word any
    /// frame has written this boot.
    used: usize,
    /// How much there is.
    size: usize,
    /// The lowest `guard` bytes have been written. The machine is one deep
    /// call away from writing outside its own stack.
    guard_breached: bool,
};

pub fn usage() Usage {
    const words: [*]const volatile u64 = @ptrCast(&kernel_stack);
    const u = used(words, size / 8);
    return .{ .used = u, .size = size, .guard_breached = size - u < guard };
}

/// Bytes from the top down to the deepest word that is no longer painted.
///
/// A hole — painted words below a written one — counts as used, which is the
/// conservative reading: something reached past it.
pub fn used(words: [*]const volatile u64, len: usize) usize {
    return (len - firstUnpainted(words, len)) * 8;
}

/// **HOW MUCH STACK IS LEFT, RIGHT NOW, WITHOUT SCANNING ANYTHING.** The
/// high-water mark above is read between requests, which is too late to stop a
/// runaway: a recursion that walks past the end corrupts `.bss`, then the page
/// tables, and the machine triple-faults with nothing in the log. This is O(1)
/// -- the current frame's address against the end of the region -- so code that
/// is about to recurse can afford to ask on every level.
pub fn roomLeft() usize {
    const here = @frameAddress();
    const bottom = @intFromPtr(&kernel_stack);
    return if (here <= bottom) 0 else here - bottom;
}

/// True when the next few frames would reach the guard. The caller decides what
/// to do about it, because what to say depends on what it was doing.
pub fn nearTheEnd() bool {
    return roomLeft() <= guard;
}

/// The index of the lowest word that is not `paint`, or `len` if every one of
/// them still is. The volatile read is load-bearing: the initializer above
/// says zero, the stub's `rep stosq` is invisible to the optimizer, and a
/// plain read would be free to answer from the initializer.
pub fn firstUnpainted(words: [*]const volatile u64, len: usize) usize {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (words[i] != paint) return i;
    }
    return len;
}

// ── host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixture(comptime n: usize, written: []const usize) [n]u64 {
    var w: [n]u64 = @splat(paint);
    for (written) |i| w[i] = 0xDEAD_BEEF;
    return w;
}

test "an untouched stack has used zero" {
    var w = fixture(8, &.{});
    try testing.expectEqual(@as(usize, 8), firstUnpainted(&w, w.len));
    try testing.expectEqual(@as(usize, 0), used(&w, w.len));
}

test "one word at the top is one word used" {
    var w = fixture(8, &.{7});
    try testing.expectEqual(@as(usize, 7), firstUnpainted(&w, w.len));
    try testing.expectEqual(@as(usize, 8), used(&w, w.len));
}

test "the mark is the DEEPEST word, not the count of them" {
    var w = fixture(8, &.{ 7, 6, 5 });
    try testing.expectEqual(@as(usize, 24), used(&w, w.len));
}

test "a painted hole below a written word still counts as used" {
    // 3 written, 4 and 5 painted again, 6 and 7 written: something reached
    // past the hole, so the mark is at 3.
    var w = fixture(8, &.{ 3, 6, 7 });
    try testing.expectEqual(@as(usize, 3), firstUnpainted(&w, w.len));
    try testing.expectEqual(@as(usize, 40), used(&w, w.len));
}

test "a fully written stack uses all of it" {
    var w = fixture(4, &.{ 0, 1, 2, 3 });
    try testing.expectEqual(@as(usize, 0), firstUnpainted(&w, w.len));
    try testing.expectEqual(@as(usize, 32), used(&w, w.len));
}

test "an unpainted stack reads as fully used, never as empty" {
    // What the scan sees if the stub never ran: zeros are not paint.
    var w: [8]u64 = @splat(0);
    try testing.expectEqual(@as(usize, 64), used(&w, w.len));
}

test "the guard is the bottom of the region, not a share of it" {
    try testing.expect(guard < size);
    // Reaching the last guard byte is breached; one byte above it is not.
    const breached: Usage = .{ .used = size - guard, .size = size, .guard_breached = size - (size - guard) < guard };
    try testing.expect(!breached.guard_breached);
    const over = size - guard + 1;
    try testing.expect(size - over < guard);
}

test "the size is std's own thread stack size, and it is 16 MB" {
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), size);
}

test "paint is not a value a frame plausibly writes" {
    try testing.expect(paint != 0);
    // Not a canonical userspace or kernel pointer, not a small integer, and no
    // byte of it is printable ASCII.
    for (std.mem.asBytes(&paint)) |b| try testing.expect(b < 0x20 or b > 0x7E);
}
