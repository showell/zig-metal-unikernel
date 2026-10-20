//! **RESTARTING ON A FAILURE WHILE SERVING** (RESTART.md, QUEUE.md item 16).
//!
//! The pure half, host-tested: the restart record this machine keeps in CMOS
//! across a restart, and the back-off it takes from it. The kernel half, which
//! reads and writes CMOS and resets the machine, is `restarting.zig`.
//!
//! **THE RECORD**, eight bytes of the RTC's NVRAM at `cmos_record`:
//!
//!     [0]    magic, 0xA7
//!     [1]    restarts in a row (see `recordRestart`), 1 to 255
//!     [2..6] when the last one happened: minutes since 2020-01-01 UTC,
//!            little end first, or 0xFFFFFFFF when the clock was unknown
//!     [6]    why: a `Reason`
//!     [7]    a checksum over [0..7]
//!
//! CMOS survives every way this machine restarts itself (RESTART.md,
//! measured), and is lost when the VM is powered off, which is a fresh start
//! and should read as one. 0x70 to 0x77 is past every byte SeaBIOS
//! (`src/hw/rtc.h`, the last is 0x5F) and QEMU's `pc_cmos_init` (the last is
//! 0x5D) use.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub const cmos_record: u8 = 0x70;
pub const record_len = 8;

const magic: u8 = 0xA7;
const unknown_time: u32 = 0xFFFF_FFFF;
/// 2020-01-01T00:00:00Z.
const epoch_2020: i64 = 1_577_836_800;

pub const Reason = enum(u8) {
    /// `serial.fail`: a check this machine makes on itself, a CPU exception
    /// among them (`interrupts.gm_exception` ends there).
    failure = 1,
    /// A Zig panic: a safety check, an `@panic`, the application's own.
    panic = 2,
    /// A disk the machine serves from stopped answering (metal-vmm QUEUE
    /// 198.3): nothing on it can be saved, and a fresh boot negotiates the
    /// device again.
    disk_stopped = 3,
    _,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .failure => "a failure",
            .panic => "a panic",
            .disk_stopped => "a disk that stopped answering",
            _ => "an unknown reason",
        };
    }
};

/// **WHAT A DISK THAT STOPPED ANSWERING DOES TO THE MACHINE** (metal-vmm
/// QUEUE 198.3, P193(c), Steve's choice 2026-10-13): restart it. A disk
/// that has stopped answering (193.2: a request unanswered for its budget,
/// or the device asking for a reset) answers nothing again until the
/// device is reset, and only a boot resets it here; serving on refuses
/// every page and every write. **THE ONE CONSTANT TO OVERRULE**: set it to
/// `.serve_refusing` and the machine serves on as 193.2 left it, the disk
/// marked STOPPED ANSWERING on /admin/host.
///
/// **NO RESTART LOOP** (the guard): a disk dead at boot fails the mount
/// before `restarting.serving()`, and a failure at boot halts (serial's
/// `on_fatal` is null until then); a disk that dies again and again just
/// after boot restarts under the back-off every restart has
/// (`backoffSeconds`: the fourth in an hour waits a minute, then 5, then
/// 15).
pub const DiskEnded = enum { restart, serve_refusing };
pub const disk_ended: DiskEnded = .restart;

/// What a disk that stopped answering does, under `policy`, on a machine
/// with the restart built in or not (a machine without one cannot).
pub fn onDiskEnded(policy: DiskEnded, restart_built: bool) DiskEnded {
    return if (restart_built) policy else .serve_refusing;
}

pub const Record = struct {
    count: u8,
    /// Minutes since 2020, or null when the clock was not known.
    at: ?u32,
    reason: Reason,

    pub fn encode(r: Record) [record_len]u8 {
        var b: [record_len]u8 = undefined;
        b[0] = magic;
        b[1] = r.count;
        std.mem.writeInt(u32, b[2..6], r.at orelse unknown_time, .little);
        b[6] = @backingInt(r.reason);
        b[7] = checksum(b[0..7]);
        return b;
    }

    /// The record in `b`, or null when there is none: a CMOS that powered up
    /// holding zeros or anything else, a checksum that does not hold, or a
    /// count of zero, which no restart writes.
    pub fn decode(b: [record_len]u8) ?Record {
        if (b[0] != magic) {
            props.reachable(@src(), "restart: CMOS holds no record, or another's", null);
            return null;
        }
        if (b[7] != checksum(b[0..7])) {
            props.reachable(@src(), "restart: a record whose checksum does not hold is no record", null);
            return null;
        }
        if (b[1] == 0) {
            props.reachable(@src(), "restart: a record with a count of zero is no record", null);
            return null;
        }
        const at = std.mem.readInt(u32, b[2..6], .little);
        return .{ .count = b[1], .at = if (at == unknown_time) null else at, .reason = @fromBackingInt(@intCast(b[6])) };
    }
};

/// Not a sum alone: a run of equal bytes, 0x00 or 0xFF, must not check.
fn checksum(b: []const u8) u8 {
    var s: u8 = 0x5A;
    for (b) |c| s = std.math.rotl(u8, s, 1) +% c;
    return s;
}

/// The Unix time a record's minutes name.
pub fn unixOfMinutes(m: u32) i64 {
    return epoch_2020 + @as(i64, m) * 60;
}

/// Minutes since 2020 for a Unix time, or null for one before it or past
/// what fits.
pub fn minutesSince2020(unix: ?i64) ?u32 {
    const t = unix orelse {
        props.reachable(@src(), "restart: the clock is unknown, so the time is too", null);
        return null;
    };
    if (t < epoch_2020) {
        props.reachable(@src(), "restart: a clock before 2020 says no time", null);
        return null;
    }
    const m = @divFloor(t - epoch_2020, 60);
    if (m >= unknown_time) {
        props.reachable(@src(), "restart: a clock past what the record holds says no time", null);
        return null;
    }
    return @intCast(m);
}

/// **A RESTART MORE THAN AN HOUR AFTER THE LAST STARTS THE COUNT AGAIN.**
pub const count_resets_after_minutes: u32 = 60;

/// The record a restart writes, given the one before it (null: none) and the
/// time now. In a row means within the hour: a machine that failed once
/// yesterday and once now has failed once. With no clock on either side the
/// restarts are counted as in a row, which only ever waits longer.
pub fn recordRestart(previous: ?Record, now: ?u32, reason: Reason) Record {
    const count: u8 = if (previous) |p| blk: {
        if (p.at) |then| if (now) |n| {
            if (n < then or n - then > count_resets_after_minutes) break :blk 1;
        };
        break :blk p.count +| 1;
    } else 1;
    return .{ .count = count, .at = now, .reason = reason };
}

/// **THE BACK-OFF**: how long to wait before serving again after the
/// `count`th restart in a row. None for the first three, then 1, 5 and 15
/// minutes, and 15 from then on. Never a halt: a machine anyone can crash is
/// not handed to them to stop for good (RESTART.md).
pub fn backoffSeconds(count: u8) u32 {
    return switch (count) {
        0...3 => 0,
        4 => 60,
        5 => 5 * 60,
        else => 15 * 60,
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "a record reads back as it was written" {
    const r = Record{ .count = 3, .at = 3_571_234, .reason = .panic };
    const got = Record.decode(r.encode()).?;
    try testing.expectEqual(r.count, got.count);
    try testing.expectEqual(r.at, got.at);
    try testing.expectEqual(r.reason, got.reason);
    const no_clock = Record.decode((Record{ .count = 1, .at = null, .reason = .failure }).encode()).?;
    try testing.expectEqual(@as(?u32, null), no_clock.at);
}

test "CMOS that holds no record reads as none: zeros, 0xFF, garbage, a bad checksum, a count of zero" {
    try testing.expectEqual(@as(?Record, null), Record.decode(@splat(0)));
    try testing.expectEqual(@as(?Record, null), Record.decode(@splat(0xFF)));
    try testing.expectEqual(@as(?Record, null), Record.decode(@splat(0xA5)));
    var b = (Record{ .count = 2, .at = 5, .reason = .failure }).encode();
    b[3] ^= 1;
    try testing.expectEqual(@as(?Record, null), Record.decode(b));
    var zero = (Record{ .count = 0, .at = 5, .reason = .failure }).encode();
    try testing.expectEqual(@as(?Record, null), Record.decode(zero));
    zero[0] = magic; // still none
    try testing.expectEqual(@as(?Record, null), Record.decode(zero));
    // Not our magic, though the checksum is fixed up for it.
    var other = (Record{ .count = 2, .at = 5, .reason = .failure }).encode();
    other[0] = magic +% 1;
    other[7] = checksum(other[0..7]);
    try testing.expectEqual(@as(?Record, null), Record.decode(other));
    // The checksum's own promise: a run of equal bytes, as blank CMOS reads,
    // does not check, so it would not pass even without the magic.
    for ([_]u8{ 0x00, 0xFF }) |v| {
        const run: [record_len]u8 = @splat(v);
        try testing.expect(checksum(run[0..7]) != v);
    }
    // Every random 8 bytes that happens to begin with the magic: the checksum
    // turns almost all of them away.
    var prng = std.Random.DefaultPrng.init(7);
    var passed: u32 = 0;
    for (0..10_000) |_| {
        var g: [record_len]u8 = undefined;
        prng.random().bytes(&g);
        g[0] = magic;
        if (Record.decode(g) != null) passed += 1;
    }
    try testing.expect(passed < 100); // about 1 in 256
}

test "restarts within the hour count up; one after an hour starts again; no clock counts up" {
    const first = recordRestart(null, 1000, .panic);
    try testing.expectEqual(@as(u8, 1), first.count);
    try testing.expectEqual(@as(?u32, 1000), first.at);
    const second = recordRestart(first, 1001, .failure);
    try testing.expectEqual(@as(u8, 2), second.count);
    try testing.expectEqual(Reason.failure, second.reason);
    const at_the_hour = recordRestart(second, 1001 + 60, .panic);
    try testing.expectEqual(@as(u8, 3), at_the_hour.count);
    const past_it = recordRestart(at_the_hour, 1061 + 61, .panic);
    try testing.expectEqual(@as(u8, 1), past_it.count);
    // A clock that went backwards is not "in a row".
    try testing.expectEqual(@as(u8, 1), recordRestart(second, 999, .panic).count);
    // No clock, now or then: counted as in a row.
    try testing.expectEqual(@as(u8, 3), recordRestart(second, null, .panic).count);
    try testing.expectEqual(@as(u8, 2), recordRestart(.{ .count = 1, .at = null, .reason = .panic }, 5, .panic).count);
    // And it stops counting at 255 rather than wrapping to a fresh start.
    try testing.expectEqual(@as(u8, 255), recordRestart(.{ .count = 255, .at = 7, .reason = .panic }, 8, .panic).count);
}

test "the back-off: none for three, then 1, 5 and 15 minutes, and 15 from then on" {
    const want = [_]u32{ 0, 0, 0, 0, 60, 300, 900, 900, 900 };
    for (want, 0..) |w, n| try testing.expectEqual(w, backoffSeconds(@intCast(n)));
    try testing.expectEqual(@as(u32, 900), backoffSeconds(255));
}

test "minutes since 2020" {
    try testing.expectEqual(@as(?u32, 0), minutesSince2020(epoch_2020));
    try testing.expectEqual(@as(?u32, 0), minutesSince2020(epoch_2020 + 59));
    try testing.expectEqual(@as(?u32, 1), minutesSince2020(epoch_2020 + 60));
    try testing.expectEqual(@as(?u32, null), minutesSince2020(epoch_2020 - 1));
    try testing.expectEqual(@as(?u32, null), minutesSince2020(null));
    // 2026-10-02T12:00:00Z
    try testing.expectEqual(@as(?u32, (1_790_942_400 - epoch_2020) / 60), minutesSince2020(1_790_942_400));
}

test "a disk that stopped answering restarts the machine, says so in its record, and only where a restart is built (metal-vmm QUEUE 198.3)" {
    const r: Record = .{ .count = 1, .at = 5, .reason = .disk_stopped };
    try std.testing.expectEqual(r, Record.decode(r.encode()).?);
    try std.testing.expectEqualStrings("a disk that stopped answering", Reason.disk_stopped.text());
    try std.testing.expectEqual(DiskEnded.restart, disk_ended);
    try std.testing.expectEqual(DiskEnded.restart, onDiskEnded(.restart, true));
    // No restart built in: nothing can restart; the machine serves on,
    // refusing what needs the disk, as 193.2 left it.
    try std.testing.expectEqual(DiskEnded.serve_refusing, onDiskEnded(.restart, false));
    try std.testing.expectEqual(DiskEnded.serve_refusing, onDiskEnded(.serve_refusing, true));
    // A restart for it counts toward the back-off like any other: the
    // fourth in the hour waits.
    var rec: ?Record = null;
    for (0..4) |_| rec = recordRestart(rec, 100, .disk_stopped);
    try std.testing.expect(backoffSeconds(rec.?.count) > 0);
}
