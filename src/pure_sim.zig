//! **THE OTHER PURE MODULES, UNDER A SEED** (metal-vmm QUEUE.md item 35):
//! `log_ring.zig`, `kept_log.zig`, `restart.zig` and `request_heap.zig`. Each
//! imports only `std` (kept_log also log_ring), so each is driven here by a
//! seed against a model of what it promises, where a randomized drive shows
//! something its unit tests do not.
//!
//! - **The ring** (`ringSeed`): a ring of 8 to 300 bytes, written in pieces
//!   of any size, lines of any length, with secrets in them split anywhere.
//!   Oracles: the ring holds the newest bytes of everything written (after
//!   the filter), a read starts at the first whole line once anything is
//!   lost and gives the newest bytes that fit; and no planted secret is ever
//!   in what the filter lets through. It found one defect (`ring_regressions`).
//! - **The kept log** (`keptSeed`): boots one after another over one
//!   region, each logging, most sealing, some not (a crash), with the power
//!   cut between some (the region cold again) and headers damaged between
//!   others. Oracles: each boot finds as the boot before it exactly the last
//!   sealed one still intact, with its log as it was read when sealed, and
//!   writes into the other slot; a damaged header is never trusted.
//! - **The restart record** (`restartSeed`): hundreds of restarts in a row
//!   through CMOS, the clock going forward a little or a lot, backwards, or
//!   unknown, and the CMOS damaged or lost between some. Oracles: the count
//!   and the back-off are the ones RESTART.md describes, written here from
//!   its words; a record reads back as written; and any one damaged byte
//!   reads as no record at all.
//! - **The request heap** (`heapSeed`): requests of allocations, growths and
//!   frees over a backing that may run out. Oracles: `used` is what the
//!   request was given, every live allocation keeps its bytes until the
//!   reset, and a reset gives back what grew past what it keeps. And the
//!   same request asks the same amount again, which is the one place a seed
//!   found something here: it does not, after a reset (`heap_red`).

const std = @import("std");
const ev = @import("sim_events.zig");
const log_ring = @import("log_ring.zig");
const kept_log = @import("kept_log.zig");
const restart = @import("restart.zig");
const request_heap = @import("request_heap.zig");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const testing = std.testing;

fn fail(seed: u64, what: []const u8, step: usize) error{SimulationFailed} {
    std.debug.print("pure_sim {s} seed {d} failed at step {d}\n", .{ what, seed, step });
    return error.SimulationFailed;
}

// ── the ring ────────────────────────────────────────────────────────────────

/// A secret's letters: none of them ends a value, so the filter must take
/// the whole of it.
const secret_letters = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

fn secretOf(r: std.Random, out: []u8) []u8 {
    // At least 12 letters, so a secret cannot occur by chance in the rest.
    const n = r.intRangeAtMost(usize, 12, out.len);
    for (out[0..n]) |*c| c.* = secret_letters[r.uintLessThan(usize, secret_letters.len)];
    return out[0..n];
}

/// One line of log, with a secret in it as the redactor promises to find
/// one, or none; the secrets planted go in `secrets`.
fn logLine(r: std.Random, out: *std.ArrayList(u8), secrets: *std.ArrayList([]u8), gpa: std.mem.Allocator) !void {
    var s: [40]u8 = undefined;
    const plain = [_][]const u8{ "  request 12: GET /chat ", "serving ", "net: a frame ", "ok ", "200 13668 bytes " };
    try out.appendSlice(gpa, plain[r.uintLessThan(usize, plain.len)]);
    switch (r.uintLessThan(u8, 8)) {
        0, 1 => {
            // A query: `?key=value&...`, any case of the key.
            const keys = log_ring.Redactor.value_keys;
            const key = keys[r.uintLessThan(usize, keys.len)];
            try out.appendSlice(gpa, if (r.boolean()) "/login?" else "/x?a=1&");
            for (key) |c| try out.append(gpa, if (r.boolean()) std.ascii.toUpper(c) else c);
            try out.append(gpa, if (r.boolean()) '=' else ':');
            const secret = secretOf(r, &s);
            try out.appendSlice(gpa, secret);
            try secrets.append(gpa, try gpa.dupe(u8, secret));
            if (r.boolean()) try out.appendSlice(gpa, "&next=/chat");
        },
        2 => {
            // JSON: `"password": "two words"`, quoted with spaces in it.
            try out.appendSlice(gpa, "{\"password\": \"");
            const a = secretOf(r, &s);
            try out.appendSlice(gpa, a);
            try secrets.append(gpa, try gpa.dupe(u8, a));
            try out.append(gpa, ' ');
            const b = secretOf(r, &s);
            try out.appendSlice(gpa, b);
            try secrets.append(gpa, try gpa.dupe(u8, b));
            try out.appendSlice(gpa, "\"}");
        },
        3 => {
            // A header whose whole value is secret.
            try out.appendSlice(gpa, if (r.boolean()) "Cookie: session=" else "authorization: Bearer ");
            const secret = secretOf(r, &s);
            try out.appendSlice(gpa, secret);
            try secrets.append(gpa, try gpa.dupe(u8, secret));
            try out.appendSlice(gpa, "; theme=dark");
        },
        4 => {
            // An upload's id.
            try out.appendSlice(gpa, "/data/uploads/");
            const secret = secretOf(r, &s);
            try out.appendSlice(gpa, secret);
            try secrets.append(gpa, try gpa.dupe(u8, secret));
            try out.appendSlice(gpa, ".png");
        },
        else => {
            // A long line, sometimes longer than any ring.
            const n = r.uintLessThan(usize, if (r.uintLessThan(u8, 4) == 0) 700 else 60);
            for (0..n) |_| try out.append(gpa, "abcdefghij 0123456789"[r.uintLessThan(usize, 21)]);
        },
    }
    try out.append(gpa, '\n');
}

/// What a read of everything held should give, from the ring's promise:
/// once anything is lost, from the first whole line (unless none starts in
/// what is held, or the only newline is the last byte), then the newest
/// `out_len` bytes of that.
fn expectedRead(held: []const u8, lost: bool, out_len: usize) []const u8 {
    var from: usize = 0;
    if (lost) {
        if (std.mem.indexOfScalar(u8, held, '\n')) |i| {
            if (i + 1 < held.len) from = i + 1;
        }
    }
    const rest = held[from..];
    return rest[rest.len - @min(rest.len, out_len) ..];
}

const RingSink = struct {
    bytes: *std.ArrayList(u8),
    fn put(self: *RingSink, b: u8) void {
        self.bytes.append(testing.allocator, b) catch @panic("out of memory");
    }
};

pub fn ringSeed(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const gpa = testing.allocator;
    const cap = r.intRangeAtMost(usize, 8, 300);
    const buf = try gpa.alloc(u8, cap);
    defer gpa.free(buf);
    var ring = log_ring.Ring.init(buf);
    // What the filter lets through, all of it: a second filter over the same
    // bytes, unbounded. The ring's oracle is about the ring.
    var through: std.ArrayList(u8) = .empty;
    defer through.deinit(gpa);
    var filter: log_ring.Redactor = .{};
    var sink = RingSink{ .bytes = &through };
    var secrets: std.ArrayList([]u8) = .empty;
    defer {
        for (secrets.items) |s| gpa.free(s);
        secrets.deinit(gpa);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var out = try gpa.alloc(u8, cap + 8);
    defer gpa.free(out);

    const lines = r.intRangeAtMost(usize, 1, 80);
    for (0..lines) |step| {
        ev.count += 1;
        text.clearRetainingCapacity();
        try logLine(r, &text, &secrets, gpa);
        // In pieces split anywhere, as serial.put writes a line.
        var at: usize = 0;
        var pieces: usize = 0;
        while (at < text.items.len) {
            pieces += 1;
            const n = @min(text.items.len - at, r.intRangeAtMost(usize, 1, 40));
            const before = ring.total;
            ring.write(text.items[at..][0..n]);
            for (text.items[at..][0..n]) |b| filter.feed(b, &sink, RingSink.put);
            if (ring.total - before >= cap) props.reachable(@src(), "log_ring: one write is longer than the ring, and its tail is kept", null);
            at += n;
        }
        if (pieces > 1 and secrets.items.len > 0) props.reachable(@src(), "log_ring: a line goes in in pieces", null);

        // The ring holds the newest of what came through.
        if (ring.total != through.items.len) return fail(seed, "ring: it counts a different number of bytes than came through", step);
        const held_want = through.items[through.items.len - ring.len() ..];
        const p = ring.parts();
        if (p[0].len + p[1].len != held_want.len or
            !std.mem.eql(u8, p[0], held_want[0..p[0].len]) or
            !std.mem.eql(u8, p[1], held_want[p[0].len..]))
            return fail(seed, "ring: what it holds is not the newest bytes that came through", step);
        if (ring.lost() > 0) props.reachable(@src(), "log_ring: the ring wraps", null);

        // A read, into all of it or less.
        const out_len = if (r.boolean()) out.len else r.uintLessThan(usize, cap + 1);
        const got = ring.read(out[0..out_len]);
        const want = expectedRead(held_want, ring.lost() > 0, out_len);
        if (!std.mem.eql(u8, got, want)) return fail(seed, "ring: a read is not what it promises", step);
        if (ring.lost() > 0 and got.len > 0 and got.len < held_want.len and out_len >= held_want.len)
            props.reachable(@src(), "log_ring: a read after a loss starts at a whole line", null);
        if (got.len > 0 and out_len < held_want.len) props.reachable(@src(), "log_ring: a short read gets the newest bytes", null);

        // No secret got through the filter.
        for (secrets.items) |s| if (std.mem.indexOf(u8, through.items, s) != null)
            return fail(seed, "redactor: a secret got through", step);
    }
    if (secrets.items.len > 0) props.reachable(@src(), "log_ring: secrets split across writes are taken out", null);
}

/// **FOUND: A RING HOLDING EXACTLY ITS CAPACITY READS AS WHAT WAS IN `out`**
/// (metal-vmm QUEUE.md, Questions). Once exactly `buf.len` bytes have been
/// written, `head` has come round to 0 and `total == buf.len`, so `parts`
/// takes the not-yet-wrapped branch and answers `buf[0..0]`: nothing. `len`
/// still says the ring is full, so `read` returns that many bytes of `out`
/// as the caller left it, never written: a status page serving the ring
/// would serve whatever its buffer last held. `kept_log` reads a sealed
/// ring the same way. Seeds 41, 224 and 292 found it; every other ring
/// failure in 5000 seeds was the same one (a one-character change to
/// `parts`, `<` for `<=`, leaves none). Failing until the box fixes it.
const ring_regressions = [_]u64{ 41, 224, 292 };

test "log_ring: a ring holding exactly its capacity reads back what it holds" {
    var b: [8]u8 = undefined;
    var ring = log_ring.Ring.init(&b);
    ring.write("abcdefg\n");
    var out: [16]u8 = @splat('?');
    try testing.expectEqualStrings("abcdefg\n", ring.read(&out));
    for (ring_regressions) |seed| try ringSeed(seed);
}

// ── the kept log ────────────────────────────────────────────────────────────

pub fn keptSeed(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const gpa = testing.allocator;
    const region = try gpa.alloc(u8, kept_log.region_bytes);
    defer gpa.free(region);
    const cold = [_]u8{ 0x00, 0xA5, 0xFF };
    if (r.boolean()) @memset(region, cold[r.uintLessThan(usize, cold.len)]) else r.bytes(region);

    // What each slot holds, by the model: the boot sealed there, and what
    // its log read as when it was sealed.
    const Sealed = struct { boot: u64, read: []u8 };
    var slots: [2]?Sealed = .{ null, null };
    defer for (slots) |s| if (s) |x| gpa.free(x.read);
    const out = try gpa.alloc(u8, kept_log.slot_bytes);
    defer gpa.free(out);

    const boots = r.intRangeAtMost(usize, 2, 30);
    for (0..boots) |step| {
        ev.count += 1;
        // The boot the model says came before: the newer of the slots.
        var best: ?u1 = null;
        for ([_]u1{ 0, 1 }) |s| if (slots[s]) |x| {
            if (best == null or x.boot > slots[best.?].?.boot) best = s;
        };
        const k = kept_log.open(region);
        if (best) |b| {
            const want = slots[b].?;
            const prev = k.previous orelse return fail(seed, "kept: a sealed boot before this one was not found", step);
            if (prev.boot != want.boot) return fail(seed, "kept: the boot before is not the last sealed", step);
            if (!std.mem.eql(u8, prev.read(out), want.read)) return fail(seed, "kept: the previous log is not what it was", step);
            if (k.slot == b) return fail(seed, "kept: this boot writes over the boot before it", step);
            if (k.boot != want.boot + 1) return fail(seed, "kept: this boot's number is not one past the last", step);
            props.reachable(@src(), "kept_log: a boot finds the sealed boot before it", null);
            if (prev.ring.lost() > 0) props.reachable(@src(), "kept_log: the boot before's log had wrapped", null);
        } else {
            if (k.previous != null) return fail(seed, "kept: a log was found where none was sealed", step);
            if (k.boot != 1) return fail(seed, "kept: a boot with nothing before it is not the first", step);
        }
        // Its slot says nothing until it seals.
        if (slots[k.slot]) |x| gpa.free(x.read);
        slots[k.slot] = null;

        // It logs: a little, or past its slot.
        var ring = log_ring.Ring.init(k.bytes());
        const n = if (r.uintLessThan(u8, 6) == 0) r.intRangeAtMost(usize, kept_log.slot_bytes, kept_log.slot_bytes + 5000) else r.uintLessThan(usize, 3000);
        var line: [80]u8 = undefined;
        var written: usize = 0;
        while (written < n) {
            const len = @min(n - written, r.intRangeAtMost(usize, 1, line.len));
            for (line[0..len]) |*c| c.* = "boot log line, 0123456789"[r.uintLessThan(usize, 25)];
            if (r.uintLessThan(u8, 3) == 0) line[len - 1] = '\n';
            ring.write(line[0..len]);
            written += len;
        }
        if (r.uintLessThan(u8, 5) != 0) {
            k.seal(&ring);
            slots[k.slot] = .{ .boot = k.boot, .read = try gpa.dupe(u8, ring.read(out)) };
        } else if (best != null) props.reachable(@src(), "kept_log: a boot ends unsealed, and the next finds the one before it", null);

        // Between boots: the power cut, a header damaged, or nothing.
        switch (r.uintLessThan(u8, 10)) {
            0 => {
                @memset(region, cold[r.uintLessThan(usize, cold.len)]);
                for (&slots) |*s| if (s.*) |x| {
                    gpa.free(x.read);
                    s.* = null;
                };
                props.reachable(@src(), "kept_log: the power is cut and the region is cold", null);
            },
            1 => {
                // One bit of one slot's header, in the fields it checks.
                const s = r.uintLessThan(usize, 2);
                const at = s * (kept_log.region_bytes / 2) + r.uintLessThan(usize, 40);
                region[at] ^= @as(u8, 1) << r.int(u3);
                if (slots[s]) |x| {
                    gpa.free(x.read);
                    slots[s] = null;
                    props.reachable(@src(), "kept_log: a sealed header is damaged and not trusted", null);
                }
            },
            else => {},
        }
    }
}

// ── the restart record ──────────────────────────────────────────────────────

/// RESTART.md's count, from its words: one past the last, up to 255, unless
/// both times are known and this one is more than an hour after the last,
/// or before it; then 1. No record before: 1.
fn modelCount(prev: ?restart.Record, now: ?u32) u8 {
    const p = prev orelse return 1;
    if (p.at) |then| if (now) |n| {
        if (n < then or n - then > 60) return 1;
    };
    return if (p.count == 255) 255 else p.count + 1;
}

/// Its back-off: none for the first three, then 1, 5 and 15 minutes.
fn modelBackoff(count: u8) u32 {
    if (count <= 3) return 0;
    if (count == 4) return 60;
    if (count == 5) return 300;
    return 900;
}

pub fn restartSeed(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    // One run in four is a long streak inside the hour, to its cap.
    const streak = r.uintLessThan(u8, 4) == 0;
    var cmos: [restart.record_len]u8 = undefined;
    // CMOS as it powers up, or holding a record already.
    switch (r.uintLessThan(u8, 4)) {
        0 => cmos = @splat(0),
        1 => cmos = @splat(0xFF),
        2 => r.bytes(&cmos),
        else => cmos = (restart.Record{ .count = r.intRangeAtMost(u8, 1, 255), .at = r.int(u32) >> 1, .reason = .panic }).encode(),
    }
    var model: ?restart.Record = restart.Record.decode(cmos);
    var now: ?u32 = r.uintLessThan(u32, 3_000_000);
    const restarts = if (streak) r.intRangeAtMost(usize, 260, 400) else r.intRangeAtMost(usize, 1, 400);
    for (0..restarts) |step| {
        ev.count += 1;
        const got = restart.Record.decode(cmos);
        if (!std.meta.eql(got, model)) return fail(seed, "restart: the record read back is not the one written", step);
        // The clock: a little later, the hour exactly, much later, earlier,
        // unknown, or known again.
        switch (if (streak) 0 else r.uintLessThan(u8, 10)) {
            0...4 => now = if (now) |n| n + r.uintLessThan(u32, 60) else r.uintLessThan(u32, 3_000_000),
            5 => now = if (now) |n| n + 60 else null,
            6 => now = if (now) |n| n + r.intRangeAtMost(u32, 61, 100_000) else null,
            7 => now = if (now) |n| n -| r.intRangeAtMost(u32, 1, 500) else null,
            8 => now = null,
            else => {},
        }
        const reason: restart.Reason = if (r.boolean()) .panic else .failure;
        const rec = restart.recordRestart(got, now, reason);
        const want = modelCount(got, now);
        if (rec.count != want) return fail(seed, "restart: the count is not RESTART.md's", step);
        if (rec.at != now) return fail(seed, "restart: the record is not of now", step);
        if (restart.backoffSeconds(rec.count) != modelBackoff(rec.count)) return fail(seed, "restart: the back-off is not RESTART.md's", step);
        if (got) |p| {
            if (want == 1 and p.at != null and now != null and now.? < p.at.?) props.reachable(@src(), "restart: a clock that went backwards starts the count again", null);
            if (want == 1 and p.at != null and now != null and now.? > p.at.? + 60) props.reachable(@src(), "restart: a restart past the hour starts the count again", null);
            if (want > 1 and p.at != null and now != null and now.? == p.at.? + 60) props.reachable(@src(), "restart: a restart at the hour exactly is still in a row", null);
            if (want > 1 and (p.at == null or now == null)) props.reachable(@src(), "restart: with no clock the restarts count as in a row", null);
            if (p.count == 255) props.reachable(@src(), "restart: the count stops at 255", null);
        }
        if (restart.backoffSeconds(rec.count) == 900) props.reachable(@src(), "restart: the back-off reaches 15 minutes", null);
        cmos = rec.encode();
        model = rec;

        // Between restarts: CMOS lost, or one byte of it damaged.
        switch (if (streak) 2 else r.uintLessThan(u8, 12)) {
            0 => {
                cmos = @splat(0);
                model = null;
            },
            1 => {
                const at = r.uintLessThan(usize, cmos.len);
                const was = cmos[at];
                cmos[at] = r.int(u8);
                if (cmos[at] != was) {
                    if (restart.Record.decode(cmos) != null) return fail(seed, "restart: a record with one damaged byte still reads", step);
                    props.reachable(@src(), "restart: one damaged byte reads as no record", .{ .at = at });
                    model = null;
                }
            },
            else => {},
        }
    }
    // Minutes since 2020, against its own definition, at and around its ends.
    for (0..50) |_| {
        const epoch: i64 = 1_577_836_800;
        const t: i64 = switch (r.uintLessThan(u8, 4)) {
            0 => epoch - r.intRangeAtMost(i64, 0, 100),
            1 => epoch + r.intRangeAtMost(i64, 0, 100),
            2 => epoch + @as(i64, 0xFFFF_FFFE) * 60 + r.intRangeAtMost(i64, 0, 200),
            else => epoch + r.intRangeAtMost(i64, 0, 1 << 40),
        };
        const m = restart.minutesSince2020(t);
        const want: ?u32 = if (t < epoch) null else if (@divFloor(t - epoch, 60) >= 0xFFFF_FFFF) null else @intCast(@divFloor(t - epoch, 60));
        if (m != want) return fail(seed, "restart: minutes since 2020 are not", 0);
    }
}

// ── the request heap ────────────────────────────────────────────────────────

/// Seeds where a growth could not be made in place, so the block moved: the
/// same request must still ask the same amount, whatever the request before
/// left in the arena.
const heap_moves = [_]u64{ 69, 153, 285 };

test "request_heap: the same request asks the same amount, preheated, where a growth moves its block" {
    for (heap_moves) |seed| try heapSeed(seed, true);
}

pub fn heapSeed(seed: u64, strict: bool) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const gpa = testing.allocator;
    const limited = r.uintLessThan(u8, 3) == 0;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = if (limited) r.uintLessThan(usize, 40) else std.math.maxInt(usize) });
    const keep = r.uintLessThan(usize, 64 * 1024);
    var heap = request_heap.RequestHeap.init(failing.allocator(), keep);
    defer heap.deinit();
    const preheated = r.boolean() and heap.preheat();
    const warm = heap.capacity();

    const Live = struct { mem: []u8, fill: u8 };
    var live: std.ArrayList(Live) = .empty;
    defer live.deinit(gpa);
    var used_by_request: [2]usize = undefined;
    const requests = r.intRangeAtMost(usize, 1, 12);
    for (0..requests) |step| {
        ev.count += 1;
        // A request, and then the same one again: the same ops from the same
        // dice, so the same amount asked.
        const ops_seed = r.int(u64);
        for (0..2) |again| {
            var ops = std.Random.DefaultPrng.init(ops_seed);
            const o = ops.random();
            var given: usize = 0;
            const a = heap.allocator();
            for (0..o.intRangeAtMost(usize, 1, 40)) |_| {
                switch (o.uintLessThan(u8, 6)) {
                    0...2 => {
                        const len = if (o.uintLessThan(u8, 10) == 0) o.intRangeAtMost(usize, 64 * 1024, 512 * 1024) else o.uintLessThan(usize, 2048);
                        const mem = a.alloc(u8, len) catch {
                            props.reachable(@src(), "request_heap: a request meets the limit of what backs it", null);
                            continue;
                        };
                        given += len;
                        const fill = o.int(u8);
                        @memset(mem, fill);
                        try live.append(gpa, .{ .mem = mem, .fill = fill });
                    },
                    3 => if (live.items.len > 0) {
                        // Grow or shrink one as a list does: in place if the
                        // arena can, moved if not. Either way the request
                        // asked for what it grew by.
                        const i = o.uintLessThan(usize, live.items.len);
                        const l = &live.items[i];
                        const new_len = o.uintLessThan(usize, l.mem.len * 2 + 16);
                        const old = l.mem.len;
                        l.mem = a.realloc(l.mem, new_len) catch {
                            props.reachable(@src(), "request_heap: a growth meets the limit of what backs it", null);
                            continue;
                        };
                        if (new_len > old) {
                            given += new_len - old;
                            @memset(l.mem[old..], l.fill);
                        }
                    },
                    4 => if (live.items.len > 0) {
                        const i = o.uintLessThan(usize, live.items.len);
                        a.free(live.items[i].mem);
                        _ = live.swapRemove(i);
                    },
                    else => {},
                }
                if (heap.used != given) return fail(seed, "heap: used is not what the request was given", step);
            }
            // Nothing given was written over by anything given after it.
            for (live.items) |l| for (l.mem) |b| if (b != l.fill) return fail(seed, "heap: a live allocation lost its bytes", step);
            used_by_request[again] = heap.used;
            const cap_before = heap.capacity();
            heap.reset();
            live.clearRetainingCapacity();
            if (heap.used != 0) return fail(seed, "heap: a reset does not start again at nothing", step);
            if (preheated and heap.capacity() > @max(warm, cap_before)) return fail(seed, "heap: a reset kept more than it had", step);
            if (preheated and cap_before > warm and heap.capacity() <= warm) props.reachable(@src(), "request_heap: a reset gives back what grew past what it keeps", null);
        }
        if (!failing.has_induced_failure and used_by_request[0] != used_by_request[1]) {
            if (preheated) props.reachable(@src(), "request_heap: the same request asks a different amount after a reset (a finding)", .{ .seed = seed });
            if (strict) return fail(seed, "heap: the same request asked for a different amount", step);
        }
    }
}

// ── the seeds ───────────────────────────────────────────────────────────────

/// One seed of each.
pub fn runSeed(seed: u64) !void {
    try ringSeed(seed);
    try keptSeed(seed);
    try restartSeed(seed);
    try heapSeed(seed, false);
}

test "the pure modules under a seed, a handful of seeds" {
    // **ONE IN TIER 0** (metal-vmm QUEUE 198.11, then 198.12 for a box of
    // 2 cores): a seed is about 1.5 s in Debug, nearly all of it the kept
    // log's boots that write past their 1.25 MiB slot, and one runs every
    // module and every path of each; `zig build properties` sweeps 200 and
    // long.sh 10,000.
    for (1..2) |seed| try runSeed(seed);
}
