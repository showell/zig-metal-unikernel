//! **NOTHING LEAVES AHEAD OF THE WRITES BEFORE IT, UNDER A SEED** (metal-vmm
//! QUEUE.md item 59). `durable.zig` is the decision `virtio_blk.Block.flush`
//! makes; this drives it as `io.durable` does, over every interleaving a
//! seed draws, against what each disk truly does.
//!
//! Each run is one seed. It chooses two disks: each a SCSI disk or a
//! virtio-blk one, and for a SCSI disk what it truly is (a write cache, said
//! or not said; no cache, said, or not said until SYNCHRONIZE CACHE answers
//! ILLEGAL REQUEST; or a cache that says it writes through). Then events:
//!
//! - **a write** to a disk;
//! - **a response** (`Stream.sendAll`) or **a stream turn**
//!   (`serviceStreams`): `io.durable` over both disks, then output that
//!   says everything written so far;
//! - **bytes kept in a spill** (`sendAll`, the queue full): `io.durable`,
//!   and the bytes wait; **a spill pushed** (`Spill.push`): they join the
//!   queue later with no flush, as its comment defends;
//!   and each SYNCHRONIZE CACHE answered good, failed, or ILLEGAL REQUEST.
//!
//! **THE ORACLES**, from what the disks truly kept, not from the decision:
//!
//! - output that says a write was saved goes out only once that write is
//!   truly durable, but where a flush for its disk failed just before (the
//!   case `io.durable` defends: logged, counted, and the response goes out)
//!   or the disk lied about its cache (believed, as `step` says);
//! - a spill's bytes, pushed after later writes, said only what was durable
//!   when they were kept;
//! - no SYNCHRONIZE CACHE is sent with nothing written since the last good
//!   one, nor to a disk that cannot be asked;
//! - after a failed one, the next output sends one again.

const std = @import("std");
const ev = @import("sim_events.zig");
const durable = @import("durable.zig");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// What a disk truly does with a write it answered.
const Truth = enum { through, cache, lies, unknown_through };

const World = struct {
    disks: [2]durable.Disk = .{ .{}, .{} },
    truth: [2]Truth = undefined,
    written: [2]u64 = .{ 0, 0 },
    /// Writes the device has truly kept.
    kept: [2]u64 = .{ 0, 0 },
    /// The last `io.durable` left this disk unflushed after a failure.
    failed: [2]bool = .{ false, false },
    syncs: u64 = 0,
};

/// Bytes kept in a spill: what they say, and which disks' exception held.
const Kept = struct { says: [2]u64, excused: [2]bool };

const Failure = error{SimulationFailed};

fn fail(seed: u64, comptime fmt: []const u8, args: anytype) Failure {
    std.debug.print("durable_sim seed {d}: " ++ fmt ++ "\n", .{seed} ++ args);
    return error.SimulationFailed;
}

/// `io.durable`: every disk's `Block.flush`, as `step` and `settle` decide,
/// with the device's answers drawn.
fn ioDurable(w: *World, r: std.Random, seed: u64) Failure!void {
    for (&w.disks, 0..) |*d, k| {
        const s = durable.step(d.*);
        w.failed[k] = false;
        if (s == .none) continue;
        if (s == .synchronize) {
            if (!d.asks) return fail(seed, "a synchronize asked of a disk that cannot be asked", .{});
            if (w.written[k] == w.kept[k] and w.truth[k] != .lies and w.truth[k] != .unknown_through and w.truth[k] != .through)
                return fail(seed, "a synchronize with nothing unkept on disk {d}", .{k});
            w.syncs += 1;
            // A disk with no cache that never said so answers ILLEGAL
            // REQUEST, which `scsi.synchronize` takes for write-through.
            if (w.truth[k] == .unknown_through) {
                d.write_cache = false;
                _ = durable.settle(d, s, true);
                props.reachable(@src(), "durable_sim: a disk that never said learns it writes through", null);
                continue;
            }
            const ok = r.uintLessThan(u8, 8) != 0;
            if (ok and w.truth[k] == .cache) w.kept[k] = w.written[k];
            if (durable.settle(d, s, ok)) {
                w.failed[k] = true;
                props.reachable(@src(), "durable_sim: a synchronize fails, and the output goes out", null);
            } else props.reachable(@src(), "durable_sim: a synchronize keeps the writes before an output", null);
        } else {
            _ = durable.settle(d, s, true);
            props.reachable(@src(), "durable_sim: a disk that writes through is cleared without a command", null);
        }
    }
}

/// Output saying `says`: each write it says is durable, or excused.
fn check(w: *const World, says: [2]u64, excused: [2]bool, seed: u64) Failure!void {
    for (0..2) |k| {
        if (w.kept[k] >= says[k]) continue;
        if (excused[k]) continue;
        if (w.truth[k] == .lies) {
            props.reachable(@src(), "durable_sim: a disk that lies about its cache is believed, and loses", null);
            continue;
        }
        return fail(seed, "output says {d} writes to disk {d}, which kept {d}", .{ says[k], k, w.kept[k] });
    }
}

pub fn runSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var w = World{};
    for (0..2) |k| {
        const scsi = r.boolean();
        w.disks[k].asks = scsi;
        if (!scsi) {
            w.truth[k] = .through;
            continue;
        }
        w.truth[k] = switch (r.uintLessThan(u8, 6)) {
            0, 1 => .cache,
            2 => .through,
            3 => .lies,
            4 => .unknown_through,
            else => .cache,
        };
        w.disks[k].write_cache = switch (w.truth[k]) {
            .cache => if (r.boolean()) true else null,
            .through, .lies => false,
            .unknown_through => null,
        };
    }
    var spill: [8]Kept = undefined;
    var spilled: usize = 0;
    for (0..r.intRangeAtMost(usize, 1, 200)) |_| {
        ev.count += 1;
        switch (r.uintLessThan(u8, 6)) {
            0, 1 => {
                const k = r.uintLessThan(usize, 2);
                w.written[k] += 1;
                w.disks[k].unflushed = true;
                if (w.truth[k] != .cache and w.truth[k] != .lies) w.kept[k] = w.written[k];
            },
            2, 3 => {
                // A response, or a stream turn: the same call before output.
                const was_failed = w.failed;
                try ioDurable(&w, r, seed);
                for (0..2) |k| if (was_failed[k] and w.disks[k].asks and w.truth[k] == .cache and durable.step(w.disks[k]) == .none and !w.failed[k])
                    props.reachable(@src(), "durable_sim: a failed synchronize is sent again before the next output", null);
                try check(&w, w.written, w.failed, seed);
            },
            4 => if (spilled < spill.len) {
                try ioDurable(&w, r, seed);
                try check(&w, w.written, w.failed, seed);
                spill[spilled] = .{ .says = w.written, .excused = w.failed };
                spilled += 1;
            },
            else => if (spilled > 0) {
                // `Spill.push`: no flush. What the bytes say was durable
                // when they were kept, and the device keeps what it kept.
                const b = spill[0];
                std.mem.copyForwards(Kept, spill[0 .. spilled - 1], spill[1..spilled]);
                spilled -= 1;
                if (w.written[0] > b.says[0] or w.written[1] > b.says[1])
                    props.reachable(@src(), "durable_sim: a spill is pushed after later writes, with no flush", null);
                try check(&w, b.says, b.excused, seed);
            },
        }
        // After a failure the disk is still unflushed, so the next output
        // asks again: never left behind.
        for (0..2) |k| if (w.failed[k] and durable.step(w.disks[k]) != .synchronize)
            return fail(seed, "disk {d}'s failed synchronize is not tried again", .{k});
    }
}

test "durable.zig under a seed, a handful of seeds" {
    for (1..41) |seed| try runSeed(seed);
}
