//! **A FULL SERIAL PORT IS WAITED FOR, BRIEFLY, AND THEN SKIPPED UNTIL IT
//! DRAINS** (QUEUE.md item 41). The pure half of `serial.putPort`,
//! host-tested with a port that is full when a test says so.
//!
//! A droplet's serial port goes to DigitalOcean, and a test's goes to a QEMU
//! that may be slow to drain it; a port nobody drains must not hang the
//! machine. So a byte waits `patience` reads of the line status at most.
//!
//! It used to give the port up for the rest of the boot after one such wait,
//! without a word: a reader of the port saw the log stop mid-boot while the
//! machine carried on (README, "one boot printed its first line and then
//! nothing", 1 of 27). Now a port given up on is tried again, once, at the
//! start of each later write: one status read, no waiting. When it takes
//! bytes again, the first thing it is sent is how many were dropped, so the
//! gap is visible where it happened.

const std = @import("std");

pub const Gate = struct {
    /// The port timed out, and has not taken a byte since.
    dead: bool = false,
    /// Bytes not sent while it was dead, since the last note.
    dropped: u64 = 0,
    /// Times the port was given up on, ever.
    stalls: u64 = 0,

    /// Sends `bytes` through `port`, which has `ready() bool` (the
    /// transmitter can take a byte) and `write(u8)`.
    pub fn send(g: *Gate, bytes: []const u8, port: anytype, patience: u32) void {
        if (g.dead) {
            if (!port.ready()) {
                g.dropped += bytes.len;
                return;
            }
            g.dead = false;
            var buf: [96]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "\n[serial: the port was full; {d} bytes of the log were dropped here]\n", .{g.dropped}) catch unreachable;
            g.dropped = 0;
            if (!g.raw(note, port, patience)) {
                g.dropped += bytes.len;
                return;
            }
        }
        _ = g.raw(bytes, port, patience);
    }

    /// Sends `bytes`, each after at most `patience` waits. Answers false, and
    /// marks the port dead with what was not sent counted, on a timeout.
    ///
    /// A port that declares a `burst` (a FIFO that `ready` says is empty)
    /// is given that many bytes after each ready, in one `writeBurst`.
    fn raw(g: *Gate, bytes: []const u8, port: anytype, patience: u32) bool {
        const Port = @TypeOf(port);
        const P = switch (@typeInfo(Port)) {
            .pointer => |p| p.child,
            else => Port,
        };
        const burst: usize = if (@hasDecl(P, "burst")) P.burst else 1;
        var i: usize = 0;
        while (i < bytes.len) {
            var waited: u32 = 0;
            while (!port.ready()) {
                waited += 1;
                if (waited == patience) {
                    g.dead = true;
                    g.stalls += 1;
                    g.dropped += bytes.len - i;
                    return false;
                }
            }
            const n = @min(burst, bytes.len - i);
            if (burst > 1) port.writeBurst(bytes[i..][0..n]) else port.write(bytes[i]);
            i += n;
        }
        return true;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A port that is full for `full_reads` status reads, then takes bytes.
const Fake = struct {
    full_reads: u32,
    sent: std.ArrayList(u8) = .empty,

    fn ready(f: *Fake) bool {
        if (f.full_reads == 0) return true;
        f.full_reads -= 1;
        return false;
    }
    fn write(f: *Fake, b: u8) void {
        f.sent.append(testing.allocator, b) catch unreachable;
    }
};

test "a port that drains is sent everything" {
    var f = Fake{ .full_reads = 5 };
    defer f.sent.deinit(testing.allocator);
    var g = Gate{};
    g.send("hello\n", &f, 100);
    try testing.expectEqualStrings("hello\n", f.sent.items);
    try testing.expect(!g.dead);
}

test "a port that stays full is given up on, then tried again, and the gap is said when it drains" {
    var f = Fake{ .full_reads = 1_000_000 };
    defer f.sent.deinit(testing.allocator);
    var g = Gate{};
    g.send("zig-metal-unikernel: the first line\n", &f, 100);
    try testing.expect(g.dead);
    try testing.expectEqual(@as(u64, 1), g.stalls);
    // While it stays full, each write costs one status read and is counted.
    const reads_before = f.full_reads;
    g.send("  ram: 1 bytes\n", &f, 100);
    try testing.expectEqual(reads_before - 1, f.full_reads);
    try testing.expectEqual(@as(u64, 36 + 15), g.dropped);
    // It drains: the note comes first, then what is being written now.
    f.full_reads = 0;
    g.send("  listening on port 80\n", &f, 100);
    try testing.expect(!g.dead);
    try testing.expectEqualStrings("\n[serial: the port was full; 51 bytes of the log were dropped here]\n  listening on port 80\n", f.sent.items);
    try testing.expectEqual(@as(u64, 0), g.dropped);
}

test "a port that fills again in the middle of the note stays dead, and counts what it dropped" {
    var f = Fake{ .full_reads = 1_000_000 };
    defer f.sent.deinit(testing.allocator);
    var g = Gate{};
    g.send("abc", &f, 10);
    f.full_reads = 0;
    // Ready for the probe, then full again after the note's first byte.
    const Flaky = struct {
        inner: *Fake,
        reads: u32 = 0,
        fn ready(p: *@This()) bool {
            p.reads += 1;
            return p.reads <= 2;
        }
        fn write(p: *@This(), b: u8) void {
            p.inner.write(b);
        }
    };
    var flaky = Flaky{ .inner = &f };
    g.send("xyz", &flaky, 10);
    try testing.expect(g.dead);
    try testing.expectEqualStrings("\n", f.sent.items);
    try testing.expect(g.dropped >= 3);
}

/// A 16550's FIFO: `burst` bytes after each ready, and full again for
/// `full_after` readies once that many bursts have gone.
const FifoFake = struct {
    pub const burst = 16;
    readies: u32 = 0,
    full_after: u32 = std.math.maxInt(u32),
    bursts: u32 = 0,
    sent: std.ArrayList(u8) = .empty,

    fn ready(f: *FifoFake) bool {
        f.readies += 1;
        return f.bursts < f.full_after;
    }
    fn write(_: *FifoFake, _: u8) void {
        unreachable; // a port with a burst is sent bursts
    }
    fn writeBurst(f: *FifoFake, bytes: []const u8) void {
        std.debug.assert(bytes.len <= burst);
        f.bursts += 1;
        f.sent.appendSlice(testing.allocator, bytes) catch unreachable;
    }
};

test "a port with a FIFO is sent a burst after each ready, in order, the last one short" {
    var f = FifoFake{};
    defer f.sent.deinit(testing.allocator);
    var g = Gate{};
    var text: [40]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    g.send(&text, &f, 100);
    try testing.expectEqualSlices(u8, &text, f.sent.items);
    try testing.expectEqual(@as(u32, 3), f.bursts); // 16, 16, 8
    try testing.expectEqual(@as(u32, 3), f.readies);
}

test "a FIFO port that stays full part-way counts exactly the bytes it dropped" {
    var f = FifoFake{ .full_after = 2 };
    defer f.sent.deinit(testing.allocator);
    var g = Gate{};
    const text: [40]u8 = @splat('x');
    g.send(&text, &f, 50);
    try testing.expectEqual(@as(usize, 32), f.sent.items.len);
    try testing.expect(g.dead);
    try testing.expectEqual(@as(u64, 8), g.dropped);
}
