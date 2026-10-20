//! **SEQUENCE NUMBERS, MODULO 2^N** (RFC 9293 §3.4; metal-vmm B37). TCP's
//! numbers wrap, so "comes after" is a question about the distance between
//! two of them, not their order as integers: `b` is after `a` when going
//! forward from `a` reaches `b` in under half the circle. tcp.zig asked it
//! five ways by hand; these are the one way.
//!
//! Generic over the unsigned integer, so the tests below can walk every
//! pair of a `u8` and prove for all of them what TCP's `u32` relies on.

/// Sequence arithmetic over the unsigned integer `T`.
pub fn Seq(comptime T: type) type {
    const bits = @typeInfo(T).int.bits;
    if (@typeInfo(T).int.signedness != .unsigned) @compileError("sequence numbers are unsigned");
    return struct {
        /// Half the circle: no distance this far or more means "after".
        pub const half: T = 1 << (bits - 1);

        /// How far forward from `from` to reach `to`, round the circle.
        pub fn offset(from: T, to: T) T {
            return to -% from;
        }

        /// **`a` COMES AFTER `b`**: going forward from `b` reaches `a`, and
        /// in under half the circle. Never for `a == b`.
        pub fn after(a: T, b: T) bool {
            const d = offset(b, a);
            return d != 0 and d < half;
        }

        /// `a` is `b` or after it.
        pub fn atOrAfter(a: T, b: T) bool {
            return offset(b, a) < half;
        }

        /// **`x` IS ONE OF THE `len` NUMBERS FROM `base` ON**: base, base+1,
        /// ..., base+len-1, round the circle. Nothing is within a length of 0.
        pub fn within(x: T, base: T, len: T) bool {
            return offset(base, x) < len;
        }
    };
}

// ---- tests: every pair of a u8 ------------------------------------------

const std = @import("std");
const testing = std.testing;
const S8 = Seq(u8);

test "after is irreflexive, and of two different numbers exactly one is after the other, but for the pair half apart" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const x: u8 = @intCast(a);
            const y: u8 = @intCast(b);
            if (x == y) {
                try testing.expect(!S8.after(x, y));
                try testing.expect(S8.atOrAfter(x, y));
            } else if (y -% x == S8.half) {
                // Half the circle apart, neither is after the other: the one
                // pair the order cannot decide.
                try testing.expect(!S8.after(x, y) and !S8.after(y, x));
            } else {
                try testing.expect(S8.after(x, y) != S8.after(y, x));
            }
            try testing.expectEqual(S8.after(x, y) or x == y, S8.atOrAfter(x, y));
        }
    }
}

test "after does not care where on the circle the pair sits: shifting both by any k keeps the answer" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const x: u8 = @intCast(a);
            const y: u8 = @intCast(b);
            const want = S8.after(x, y);
            var k: u16 = 0;
            while (k < 256) : (k += 1) {
                const shift: u8 = @intCast(k);
                try testing.expectEqual(want, S8.after(x +% shift, y +% shift));
            }
        }
    }
}

test "after is a walk forward of under half the circle" {
    // The definition, checked against counting steps.
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        const base: u8 = @intCast(b);
        var reached: [256]bool = @splat(false);
        var at: u8 = base;
        var steps: u16 = 1;
        while (steps < S8.half) : (steps += 1) {
            at +%= 1;
            reached[at] = true;
        }
        for (reached, 0..) |r, x| try testing.expectEqual(r, S8.after(@intCast(x), base));
    }
}

test "within agrees with a walk of len steps from base" {
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        const base: u8 = @intCast(b);
        var len: u16 = 0;
        while (len < 256) : (len += 1) {
            var walked: [256]bool = @splat(false);
            var at: u8 = base;
            var n: u16 = 0;
            while (n < len) : (n += 1) {
                walked[at] = true;
                at +%= 1;
            }
            for (walked, 0..) |w, x| try testing.expectEqual(w, S8.within(@intCast(x), base, @intCast(len)));
        }
    }
}

test "offset is the distance forward, and undoes an addition" {
    var a: u16 = 0;
    while (a < 256) : (a += 1) {
        var d: u16 = 0;
        while (d < 256) : (d += 1) {
            const x: u8 = @intCast(a);
            const by: u8 = @intCast(d);
            try testing.expectEqual(by, S8.offset(x, x +% by));
        }
    }
}

test "the u32 instance TCP uses, at its edges" {
    const S = Seq(u32);
    try testing.expect(S.after(0, 0xFFFF_FFFF)); // across the wrap
    try testing.expect(!S.after(0xFFFF_FFFF, 0));
    try testing.expect(S.after(0x7FFF_FFFF, 0));
    try testing.expect(!S.after(0x8000_0000, 0)); // half the circle: neither
    try testing.expect(!S.after(0, 0x8000_0000));
    try testing.expect(!S.atOrAfter(0x8000_0000, 0)); // nor at or after, either way
    try testing.expect(!S.atOrAfter(0, 0x8000_0000));
    try testing.expect(S.within(2, 0xFFFF_FFFE, 5)); // across the wrap
    try testing.expect(!S.within(3, 0xFFFF_FFFE, 5));
}
