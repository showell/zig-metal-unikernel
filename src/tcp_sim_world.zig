//! tcp_sim's world: the scenario a seed chooses (the sizes, how the network
//! mistreats frames, how each side reads and stalls, a rough peer, a crowd),
//! the addresses and limits every party shares, and the network that carries
//! the frames. A leaf: the client, the host and the table's driver in
//! tcp_sim.zig use it, and it uses none of them.

const std = @import("std");
const tcp = @import("tcp.zig");

pub const ns_per_ms: i96 = 1_000_000;
pub const ns_per_s: i96 = 1_000_000_000;

/// One turn of the loop: what the kernel's 1 ms rest makes its slowest turn.
pub const tick_ns: i96 = ns_per_ms;
/// Every run ends here. Past every bound the table and the host keep: a
/// vanished client is noticed within `idle_ns`, given up on within about
/// 35 s, and waited for at most `fin_wait_ns`.
pub const horizon_ns: i96 = 150 * ns_per_s;
/// A client that does not vanish has its whole answer by then.
pub const completion_bound_ns: i96 = 60 * ns_per_s;
/// The host's patience, as `stream.default_idle_ns`.
pub const idle_ns: i96 = 10 * ns_per_s;

pub const server_ip = [4]u8{ 10, 0, 2, 15 };
pub const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
pub const client_ip = [4]u8{ 10, 0, 2, 2 };
pub const client_mac = [6]u8{ 0x52, 0x55, 0x0a, 0, 2, 2 };
pub const client_port: u16 = 40000;

/// The table's buffers, small, so that windows shut and queues fill.
pub const rx_bytes = 4096;
pub const tx_bytes = 8192;
/// The client's receive buffer: what it advertises when it has read
/// everything.
pub const client_buffer: usize = 4096;
/// The most a scenario may give the client (`Scenario.client_buffer`): its
/// buffers are this big, and it uses `buffer` of them.
pub const client_buffer_max: usize = 16 * 1024;
/// The segment size the client says, and sends.
pub const client_mss: u32 = 1000;
/// A crowd's most slots and clients (`Crowd`). A plain seed's table has 2
/// slots and one client.
const crowd_slots = 8;
const crowd_clients = 6;
/// **A CROWD THE SIZE OF THE KERNEL'S TABLE** (`Crowd.chooseFull`, metal-vmm
/// QUEUE item 72): gopher.zig's 256 slots, and a quarter more clients.
/// The arrays are sized for it; a small crowd uses the first few.
pub const max_slots = 256;
pub const max_clients = max_slots + max_slots / 4;

pub fn requestByte(k: usize) u8 {
    return @truncate(k *% 7 +% 1);
}

pub fn answerByte(k: usize) u8 {
    return @truncate(k *% 13 +% 5);
}

/// Sequence numbers, modulo 2^32.
pub fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}
pub fn seqLe(a: u32, b: u32) bool {
    return a == b or seqLt(a, b);
}

pub fn randNs(rng: std.Random, max_ns: i96) i96 {
    if (max_ns <= 0) return 0;
    return @intCast(rng.uintLessThan(u64, @intCast(max_ns)));
}

// ── what a seed chooses ─────────────────────────────────────────────────────

pub const Scenario = struct {
    request_len: usize,
    answer_len: usize,
    /// The chance that a frame is lost, either way, before `lossy_until`.
    loss: f64,
    lossy_until: i96,
    duplicate: f64,
    corrupt: f64,
    /// One way, and a random extra on top of it, which is what reorders.
    delay_ns: i96,
    jitter_ns: i96,
    /// How long the client sits on an acknowledgement.
    delayed_ack_ns: i96,
    /// The client sends its FIN right after its request.
    half_close: bool,
    /// The host's reads and the client's reads stall for up to this long.
    host_stall_ns: i96,
    client_stall_ns: i96,
    /// The client stops existing, without a word, at this time.
    vanish_at: ?i96,
    /// The host tells the table it made room, as `streamFn` does; otherwise
    /// the table has to notice by itself.
    host_announces: bool,
    /// **DETERMINISTIC LOSS, FOR THE SWEEP** (QUEUE.md item 96): drop the
    /// frame at this 0-based index among all frames the table sends the client,
    /// once. Null for the random scenarios, which lose by `loss`.
    drop_nth_to_client: ?u64 = null,
    /// **EVERY NTH FRAME TO THE CLIENT LOST** (metal-vmm QUEUE 225, chunk
    /// 0a): the 13th, the 26th, and so on of the frames the table sends the
    /// client, as the native judge's `GM_LOSE_SENT=13` drops them.
    drop_every_to_client: ?u64 = null,
    /// Where in its count of `drop_every_to_client` the first frame falls,
    /// so a sweep can try every alignment of the loss against the window.
    drop_every_phase: u64 = 0,
    /// The client's receive buffer, so its window (at most
    /// `client_buffer_max`).
    client_buffer: usize = client_buffer,

    /// A fixed scenario for the item-96 sweep: a few-KB answer the host closes
    /// after, clean except for one dropped frame to the client, with ACKs
    /// delayed and frames reordered (jitter). This is the shape the lost-frame
    /// `IncompleteRead` was seen in, made deterministic.
    pub fn fixed(answer_len: usize, drop_nth: ?u64, announces: bool) Scenario {
        return .{
            .request_len = 200,
            .answer_len = answer_len,
            .loss = 0,
            .lossy_until = 0,
            .duplicate = 0,
            .corrupt = 0,
            .delay_ns = 500_000,
            .jitter_ns = 3 * ns_per_ms, // reorders frames of the same moment
            .delayed_ack_ns = 40 * ns_per_ms,
            .half_close = false,
            .host_stall_ns = 0,
            .client_stall_ns = 0,
            .vanish_at = null,
            .host_announces = announces,
            .drop_nth_to_client = drop_nth,
        };
    }

    pub fn choose(rng: std.Random) Scenario {
        const lossiness = rng.uintLessThan(u8, 3);
        return .{
            .request_len = rng.intRangeAtMost(usize, 1, 20_000),
            .answer_len = rng.intRangeAtMost(usize, 0, 60_000),
            .loss = ([_]f64{ 0, 0.03, 0.1 })[lossiness],
            .lossy_until = 3 * ns_per_s,
            .duplicate = if (rng.boolean()) 0.02 else 0,
            .corrupt = if (rng.boolean()) 0.01 else 0,
            .delay_ns = @intCast(rng.intRangeAtMost(u64, 100_000, 5_000_000)),
            .jitter_ns = if (rng.boolean()) 3 * ns_per_ms else 0,
            .delayed_ack_ns = if (rng.boolean()) 40 * ns_per_ms else 200 * ns_per_ms,
            .half_close = rng.boolean(),
            // Long enough for the client's persist timer to back off, short
            // enough that the host's own patience is not what ends it.
            .host_stall_ns = randNs(rng, 8 * ns_per_s),
            // Short of the table's zero-window give-up (about 16 s), which
            // is what lets go of a client that stops reading for good.
            .client_stall_ns = randNs(rng, 5 * ns_per_s),
            .vanish_at = if (rng.uintLessThan(u8, 4) == 0) randNs(rng, 20 * ns_per_s) else null,
            .host_announces = rng.boolean(),
        };
    }
};

/// **A ROUGHER PEER** (COVERAGE.md): what a plain seed's client never
/// does, and so what the table's code for it was never run against under
/// loss and reordering. Chosen by a second generator from the seed, so a
/// plain seed runs exactly as it always has and its regressions still
/// reproduce; `runRoughSeed` runs the same seed with these added.
pub const Rough = struct {
    /// The client resets the connection at this time, if it is still open:
    /// at SND.NXT, or `reset_off` past it (inside the table's window, so it
    /// must be challenged, not obeyed). From then on it is a closed port,
    /// and answers whatever reaches it with a reset (RFC 9293 §3.10.7.1).
    reset_at: ?i96 = null,
    reset_off: u32 = 0,
    /// The client vanishes once it has this much of the answer: often after
    /// the host has queued it all and gone, so the table alone is left to
    /// give up on it.
    vanish_after: ?usize = null,
    /// SYNs from addresses that never finish the handshake, `flood_gap`
    /// apart from `flood_at`: more half-open connections than the table has
    /// slots, so a new SYN has to take one's place.
    flood: u8 = 0,
    flood_at: i96 = 0,
    flood_gap: i96 = 0,

    pub fn choose(rng: std.Random, sc: *const Scenario) Rough {
        var r: Rough = .{};
        if (rng.uintLessThan(u8, 3) == 0) {
            r.reset_at = randNs(rng, 2 * ns_per_s);
            r.reset_off = if (rng.boolean()) 0 else rng.intRangeAtMost(u32, 1, 2000);
        }
        if (rng.uintLessThan(u8, 3) == 0) r.vanish_after = rng.uintLessThan(usize, sc.answer_len + 1);
        if (rng.uintLessThan(u8, 3) == 0) {
            r.flood = rng.intRangeAtMost(u8, 1, 8);
            r.flood_at = randNs(rng, 500 * ns_per_ms);
            r.flood_gap = @intCast(rng.intRangeAtMost(u64, 10 * ns_per_ms, 400 * ns_per_ms));
        }
        return r;
    }
};

/// **SEVERAL CLIENTS, AND A TABLE SIZED BY THE SEED** (QUEUE.md item 33).
/// gopher.zig holds 256 slots and serves one request at a time among them,
/// keeps chat's streams open, and answers a keep-alive client's first
/// request and closes. A crowd is that, small: 2 to 6 clients opening a gap
/// apart, each with its own request and answer, one of them perhaps asking
/// twice on one connection, one perhaps holding a stream; a table of 1 to 8
/// slots, so a SYN can find no room and wait. Chosen by a third generator
/// from the seed, over the plain scenario's network, so a plain seed is the
/// run it always was; `runCrowdSeed` runs it.
pub const Crowd = struct {
    slots: usize,
    clients: usize,
    gap_ns: i96,
    request_len: [max_clients]usize = @splat(0),
    answer_len: [max_clients]usize = @splat(0),
    asks: [max_clients]u8 = @splat(1),
    /// The client whose answer is a stream: a head, then `stream_chunks`
    /// chunks of `stream_chunk` bytes `stream_gap_ns` apart, its connection
    /// held open and claimed meanwhile, then closed.
    stream: ?usize = null,
    stream_chunks: usize = 0,
    stream_chunk: usize = 0,
    stream_gap_ns: i96 = 0,

    pub fn choose(rng: std.Random) Crowd {
        const clients = rng.intRangeAtMost(usize, 2, crowd_clients);
        var c: Crowd = .{
            .slots = rng.intRangeAtMost(usize, 1, crowd_slots),
            .clients = clients,
            .gap_ns = randNs(rng, 300 * ns_per_ms),
        };
        for (0..clients) |i| {
            // A request is a head: it fits the table's receive buffer, as a
            // request gopher.zig serves is whole before its turn comes.
            c.request_len[i] = rng.intRangeAtMost(usize, 1, 1500);
            c.answer_len[i] = rng.intRangeAtMost(usize, 0, 20_000);
            if (rng.uintLessThan(u8, 3) == 0) c.asks[i] = 2;
        }
        if (rng.boolean()) {
            const k = rng.uintLessThan(usize, clients);
            c.stream = k;
            c.asks[k] = 1;
            c.stream_chunks = rng.intRangeAtMost(usize, 1, 20);
            c.stream_chunk = rng.intRangeAtMost(usize, 1, 1500);
            c.stream_gap_ns = @intCast(rng.intRangeAtMost(u64, 10 * ns_per_ms, 250 * ns_per_ms));
        }
        return c;
    }

    /// **A FULL TABLE** (QUEUE item 72): 64 to 256 slots and up to a quarter
    /// more clients than that, opening 0 to 100 us apart so they overlap, with short
    /// requests and answers so a seed stays affordable, one perhaps holding
    /// a stream: the table as full as prod's, where `oldestHalfOpen`'s scan
    /// and revival meet every slot taken.
    pub fn chooseFull(rng: std.Random) Crowd {
        const slots = rng.intRangeAtMost(usize, 64, max_slots);
        const clients = slots + rng.intRangeAtMost(usize, 1, slots / 4);
        var c: Crowd = .{
            .slots = slots,
            .clients = clients,
            .gap_ns = randNs(rng, 100 * std.time.ns_per_us),
        };
        for (0..clients) |i| {
            c.request_len[i] = rng.intRangeAtMost(usize, 1, 400);
            c.answer_len[i] = rng.intRangeAtMost(usize, 0, 3000);
            if (rng.uintLessThan(u8, 8) == 0) c.asks[i] = 2;
        }
        if (rng.boolean()) {
            const k = rng.uintLessThan(usize, clients);
            c.stream = k;
            c.asks[k] = 1;
            c.stream_chunks = rng.intRangeAtMost(usize, 1, 10);
            c.stream_chunk = rng.intRangeAtMost(usize, 1, 1000);
            c.stream_gap_ns = @intCast(rng.intRangeAtMost(u64, 10 * ns_per_ms, 250 * ns_per_ms));
        }
        return c;
    }

    pub fn streamLen(self: *const Crowd, i: usize) usize {
        return if (self.stream == i) self.stream_chunks * self.stream_chunk else 0;
    }
};

// ── the network ─────────────────────────────────────────────────────────────

const Packet = struct {
    at: i96,
    to_table: bool,
    len: usize,
    bytes: [1600]u8,
};

pub const Network = struct {
    queue: [256]Packet = undefined,
    count: usize = 0,
    sent: u64 = 0,
    lost: u64 = 0,
    duplicated: u64 = 0,
    corrupted: u64 = 0,
    /// Frames dropped because too many were in flight: a router's queue.
    overflowed: u64 = 0,
    /// Frames the table has sent the client, for `drop_nth_to_client`.
    to_client: u64 = 0,
    /// Every frame handed to the network, in order, hashed: two runs that
    /// sent the same frames have the same trace.
    trace: std.hash.Wyhash = .init(0),

    pub fn send(self: *Network, rng: std.Random, sc: *const Scenario, now: i96, to_table: bool, frame: []const u8) void {
        self.sent += 1;
        // As an i128: an i96's bytes include padding nothing writes.
        const at: i128 = now;
        self.trace.update(std.mem.asBytes(&at));
        self.trace.update(frame);
        // The deterministic drop (item 96): one chosen frame to the client,
        // whatever the clock. Counted as lost, like any other.
        if (!to_table) {
            const nth = self.to_client;
            self.to_client += 1;
            if (sc.drop_nth_to_client == nth) {
                self.lost += 1;
                return;
            }
            if (sc.drop_every_to_client) |every| if ((nth + 1 + sc.drop_every_phase) % every == 0) {
                self.lost += 1;
                return;
            };
        }
        if (now < sc.lossy_until and rng.float(f64) < sc.loss) {
            self.lost += 1;
            return;
        }
        const copies: usize = if (rng.float(f64) < sc.duplicate) 2 else 1;
        if (copies == 2) self.duplicated += 1;
        for (0..copies) |_| {
            if (self.count == self.queue.len) {
                self.overflowed += 1;
                return;
            }
            const p = &self.queue[self.count];
            self.count += 1;
            p.at = now + sc.delay_ns + randNs(rng, sc.jitter_ns + 1);
            p.to_table = to_table;
            p.len = frame.len;
            @memcpy(p.bytes[0..frame.len], frame);
            // One byte of the TCP segment changed: its checksum always
            // notices a single byte.
            if (frame.len > tcp.segment_at and rng.float(f64) < sc.corrupt) {
                self.corrupted += 1;
                p.bytes[tcp.segment_at + rng.uintLessThan(usize, frame.len - tcp.segment_at)] ^= 0x5A;
            }
        }
    }

    /// The earliest frame due by `now`, taken out of the queue into `out`.
    pub fn take(self: *Network, now: i96, out: *[1600]u8) ?struct { to_table: bool, frame: []const u8 } {
        var best: ?usize = null;
        for (self.queue[0..self.count], 0..) |*p, k| {
            if (p.at > now) continue;
            if (best == null or p.at < self.queue[best.?].at) best = k;
        }
        const k = best orelse return null;
        const p = &self.queue[k];
        const len = p.len;
        const to_table = p.to_table;
        @memcpy(out[0..len], p.bytes[0..len]);
        self.queue[k] = self.queue[self.count - 1];
        self.count -= 1;
        return .{ .to_table = to_table, .frame = out[0..len] };
    }
};
