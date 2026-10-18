//! **TWO TABLES TALKING** (metal-vmm QUEUE 225, chunk 6; docs/TWO-KERNELS.md):
//! the kernel's TCP as a client (`Table.connect`) against the kernel's TCP
//! as a server, on one virtual clock, through a network that loses,
//! duplicates and delays, with jitter, which may reorder frames (half the
//! jittered seeds) or keep each direction first in, first out, as
//! metal-vmm's pair does. Reordering needed the segments ahead of a hole
//! held (metal-vmm QUEUE 226): before, two kernels missed the metal bounds. tcp_sim.zig holds the table to a client
//! written from the RFCs; this holds it to itself, which is what two
//! kernels on one machine will be.
//!
//! Each run is one seed, which chooses a request (1 B to 20 KB), an answer
//! (up to 300 KB), the path's delay and jitter, whether it duplicates, and
//! one of three kinds of trouble:
//!
//! - **`single`: at most two frames lost, chosen by number**, the SYN or
//!   the SYN-ACK among them a quarter of the time each, under the metal ↔
//!   metal `Deadlines` (TWO-KERNELS.md §5: connect 150 ms, idle 1 s, total
//!   3 s). Each loss is recovered well inside them, so every run completes,
//!   and established within the connect bound.
//! - **`random`: 3 or 10 % of frames lost either way for the first second**,
//!   under the production `Deadlines` (1 s, 5 s, 15 s): §5's "random loss
//!   gets the production values". Every run completes.
//! - **`deadline`: a peer that makes a deadline fire.** No server at all
//!   (`connect`); the path dying once the request is half sent (`idle`); a
//!   server that answers one byte every 500 ms (`total`). The client is let
//!   go at that deadline, to the tick, by that deadline's counter and no
//!   other, and the server's table empties by the horizon all the same.
//!
//! **THE ORACLES**, any of which fails the run with its seed:
//!
//! - **Invariants:** tcp_check.zig's, on both tables, after every step.
//! - **Exactly once, in order:** each side reads the next byte of what the
//!   other sent, and nothing past it.
//! - **Completion** (`single`, `random`): the whole request read, the whole
//!   answer and the server's FIN taken, no deadline fired, nobody given up
//!   on, nobody reset; for `single`, established by `connect_ns`.
//! - **The right deadline, on time** (`deadline`).
//! - **Quiescence:** by the horizon every slot of both tables is closed.

const std = @import("std");
const tcp = @import("tcp.zig");
const invariants = @import("tcp_check.zig");
const props = @import("coverage");
const explore = @import("explore");

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const ns_per_ms: i96 = tcp.ns_per_ms;
const ns_per_s: i96 = tcp.ns_per_s;
const tick_ns: i96 = ns_per_ms;
/// Every run ends here, or earlier once nothing is left to happen. Past
/// every bound: the server host's patience (`server_idle_ns`), then its
/// table's give-up on an unanswered FIN or window (about 35 s at most).
const horizon_ns: i96 = 90 * ns_per_s;
/// The server host lets go of a connection that makes no progress for this
/// long, as gopher.zig's `idle_ns`.
const server_idle_ns: i96 = 10 * ns_per_s;

const server_ip = [4]u8{ 10, 0, 2, 15 };
const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const client_ip = [4]u8{ 10, 0, 2, 16 };
const client_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x57 };
/// The client kernel's own listening port, which nothing here connects to.
const client_listen_port: u16 = 7;

/// The kernel's buffers are larger; these are small so windows shut.
const rx_bytes = 8192;
const tx_bytes = 16384;
const slots = 2;

/// TWO-KERNELS.md §5's two rows.
pub const pair_deadlines: tcp.Deadlines = .{ .connect_ns = 150 * tcp.ns_per_ms, .idle_ns = 1 * tcp.ns_per_s, .total_ns = 3 * tcp.ns_per_s };
pub const production_deadlines: tcp.Deadlines = .{ .connect_ns = 1 * tcp.ns_per_s, .idle_ns = 5 * tcp.ns_per_s, .total_ns = 15 * tcp.ns_per_s };

fn requestByte(k: usize) u8 {
    return @truncate(k *% 7 +% 1);
}
fn answerByte(k: usize) u8 {
    return @truncate(k *% 13 +% 5);
}

fn randNs(rng: std.Random, max_ns: i96) i96 {
    if (max_ns <= 0) return 0;
    return @intCast(rng.uintLessThan(u64, @intCast(max_ns)));
}

// ── what a seed chooses ─────────────────────────────────────────────────────

pub const Trouble = enum { single, random, deadline };
pub const Fires = enum { connect, idle, total };

/// One frame, by direction and its number among that side's frames.
pub const Loss = struct { from_client: bool, nth: u64 };

const Scenario = struct {
    trouble: Trouble,
    request_len: usize,
    answer_len: usize,
    delay_ns: i96,
    jitter_ns: i96,
    /// Whether the jitter may reorder frames, or each direction stays
    /// first in, first out (as metal-vmm's pair does) with the jitter only
    /// spacing frames out.
    reorder: bool = false,
    duplicate: f64,
    deadlines: tcp.Deadlines,
    /// `single`: the frames lost.
    losses: [2]?Loss = .{ null, null },
    /// `random`: the chance of a loss, either way, before `lossy_until`.
    loss: f64 = 0,
    lossy_until: i96 = 0,
    /// `deadline`: which one the peer makes fire.
    fires: ?Fires = null,
    /// **THE SYN'S FIRST WAIT, PLANTED** (`plantSynRto`): the client's
    /// connection is made to wait this long instead, as tcp.zig did before
    /// chunk 5b gave the client its own (the server's floor).
    syn_rto_plant: ?u64 = null,

    fn choose(rng: std.Random) Scenario {
        var sc: Scenario = .{
            .trouble = switch (rng.uintLessThan(u8, 8)) {
                0...3 => .single,
                4...5 => .random,
                else => .deadline,
            },
            .request_len = rng.intRangeAtMost(usize, 1, 20_000),
            .answer_len = rng.intRangeAtMost(usize, 0, 300_000),
            .delay_ns = @intCast(rng.intRangeAtMost(u64, 100_000, 2_000_000)),
            .jitter_ns = if (rng.boolean()) 3 * ns_per_ms else 0,
            .duplicate = if (rng.boolean()) 0.02 else 0,
            .deadlines = pair_deadlines,
        };
        switch (sc.trouble) {
            .single => {
                for (&sc.losses) |*l| {
                    l.* = switch (rng.uintLessThan(u8, 6)) {
                        0 => null,
                        1 => .{ .from_client = true, .nth = 0 }, // the SYN
                        2 => .{ .from_client = false, .nth = 0 }, // the SYN-ACK
                        else => .{ .from_client = rng.boolean(), .nth = rng.uintLessThan(u64, 60) },
                    };
                }
            },
            .random => {
                sc.deadlines = production_deadlines;
                sc.loss = if (rng.boolean()) 0.03 else 0.1;
                sc.lossy_until = 1 * ns_per_s;
                sc.answer_len = rng.intRangeAtMost(usize, 0, 100_000);
            },
            .deadline => {
                sc.fires = switch (rng.uintLessThan(u8, 3)) {
                    0 => .connect,
                    1 => .idle,
                    else => .total,
                };
                // The idle case dies part-way through a request long enough
                // to still be sending; the total case trickles its answer.
                if (sc.fires == .idle) sc.request_len = rng.intRangeAtMost(usize, 4_000, 20_000);
                if (sc.fires == .total) sc.answer_len = 100;
            },
        }
        // Drawn after the rest, so a seed's other choices are as they were.
        sc.reorder = sc.jitter_ns > 0 and rng.boolean();
        return sc;
    }
};

// ── the network ─────────────────────────────────────────────────────────────

/// `order` is the frame's place among all frames sent: of two due at once,
/// the earlier sent is taken first.
const Packet = struct { at: i96, order: u64, to_server: bool, len: usize, bytes: [1600]u8 };

const Network = struct {
    queue: [512]Packet = undefined,
    count: usize = 0,
    sent: [2]u64 = .{ 0, 0 }, // by the client, by the server
    lost: u64 = 0,
    duplicated: u64 = 0,
    overflowed: u64 = 0,
    /// From this time on nothing gets through (`Fires.idle`).
    dead_from: ?i96 = null,
    /// The server is not there (`Fires.connect`): what is sent to it is lost.
    no_server: bool = false,
    trace: std.hash.Wyhash = .init(0),
    /// The latest arrival yet, each way, which a first-in, first-out path
    /// holds the next frame behind.
    last_at: [2]i96 = .{ 0, 0 },

    fn send(self: *Network, rng: std.Random, sc: *const Scenario, now: i96, from_client: bool, frame: []const u8) void {
        const nth = self.sent[@intFromBool(!from_client)];
        self.sent[@intFromBool(!from_client)] += 1;
        const at: i128 = now;
        self.trace.update(std.mem.asBytes(&at));
        self.trace.update(frame);
        const lose = for (sc.losses) |l| {
            if (l) |x| if (x.from_client == from_client and x.nth == nth) break true;
        } else false;
        if (lose or (from_client and self.no_server) or
            (if (self.dead_from) |t| now >= t else false) or
            (now < sc.lossy_until and rng.float(f64) < sc.loss))
        {
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
            const way = @intFromBool(!from_client);
            if (!sc.reorder) p.at = @max(p.at, self.last_at[way]);
            self.last_at[way] = @max(self.last_at[way], p.at);
            p.order = self.sent[0] + self.sent[1];
            p.to_server = from_client;
            p.len = frame.len;
            @memcpy(p.bytes[0..frame.len], frame);
        }
    }

    fn take(self: *Network, now: i96, out: *[1600]u8) ?struct { to_server: bool, frame: []const u8 } {
        var best: ?usize = null;
        for (self.queue[0..self.count], 0..) |*p, k| {
            if (p.at > now) continue;
            if (best == null) {
                best = k;
                continue;
            }
            const b = &self.queue[best.?];
            if (p.at < b.at or (p.at == b.at and p.order < b.order)) best = k;
        }
        const k = best orelse return null;
        const p = &self.queue[k];
        const len = p.len;
        const to_server = p.to_server;
        @memcpy(out[0..len], p.bytes[0..len]);
        self.queue[k] = self.queue[self.count - 1];
        self.count -= 1;
        return .{ .to_server = to_server, .frame = out[0..len] };
    }
};

const Wire = struct {
    sim: *Sim,
    from_client: bool,

    pub fn send(self: *Wire, frame: []const u8) void {
        const sim = self.sim;
        sim.net.send(sim.rng, &sim.sc, sim.now, self.from_client, frame);
    }
};

var client_isn_next: u32 = 0;
fn clientIsn() u32 {
    client_isn_next +%= 64_000;
    return client_isn_next;
}
var server_isn_next: u32 = 0;
fn serverIsn() u32 {
    server_isn_next +%= 96_000;
    return server_isn_next;
}

// ── the two hosts ───────────────────────────────────────────────────────────

/// **THE CLIENT KERNEL'S PROGRAM**: one `connect`, the request queued as
/// room allows, the answer read as it comes, and our FIN once the server's
/// has come and everything before it is read.
const ClientApp = struct {
    slot: ?usize = null,
    queued: usize = 0,
    received: usize = 0,
    finished: bool = false,
    established_at: ?i96 = null,
    /// When the table let go of the connection, and how.
    closed_at: ?i96 = null,
    peer_fin: bool = false,
    /// Resets the client's table had taken when it sent its FIN: any after
    /// are the server's answer to a FIN sent again (see `judge`).
    resets_before_fin: ?u64 = null,

    fn turn(self: *ClientApp, sim: *Sim) void {
        var wire: Wire = .{ .sim = sim, .from_client = true };
        const t = &sim.client;
        if (self.slot == null) {
            const i = t.connect(&wire, .{ .mac = server_mac, .ip = server_ip, .port = 80 }, sim.sc.deadlines, sim.now) orelse
                return sim.fault("the client's table had no slot for its connect");
            if (sim.sc.syn_rto_plant) |wait| {
                t.conns[i].rto_ns = wait;
                t.conns[i].rto_at = sim.now + wait;
            }
            self.slot = i;
            return;
        }
        const i = self.slot.?;
        const c = &t.conns[i];
        if (self.closed_at != null) return;
        if (c.state == .closed) {
            self.closed_at = sim.now;
            return;
        }
        if (c.state == .syn_sent) return;
        if (self.established_at == null) self.established_at = sim.now;

        if (self.queued < sim.sc.request_len) {
            var chunk: [2048]u8 = undefined;
            const want = @min(chunk.len, sim.sc.request_len - self.queued);
            for (chunk[0..want], self.queued..) |*b, k| b.* = requestByte(k);
            self.queued += t.queue(i, chunk[0..want]);
        }
        const pending = c.pending();
        if (pending.len > 0) {
            for (pending, self.received..) |b, k| {
                if (k >= sim.sc.answer_len or b != answerByte(k))
                    return sim.fault("the client read a byte that is not the next byte of the answer");
            }
            self.received += pending.len;
            if (c.consumeReopens(pending.len)) t.ack(&wire, i);
        }
        if (c.peerDone()) self.peer_fin = true;
        if (self.peer_fin and !self.finished and self.queued == sim.sc.request_len and c.state == .established) {
            t.finish(i);
            self.finished = true;
            self.resets_before_fin = t.resets_received;
        }
    }
};

/// **THE SERVER KERNEL'S PROGRAM**, as gopher.zig serves one connection:
/// the request read whole, the answer queued as room allows (one byte every
/// 500 ms when the seed says the server is slow), then our FIN; a
/// connection quiet for `server_idle_ns` let go.
const ServerApp = struct {
    slot: ?usize = null,
    consumed: usize = 0,
    queued: usize = 0,
    done: bool = false,
    last_progress: i96 = 0,
    seen_una: u32 = 0,
    next_trickle: i96 = 0,

    fn turn(self: *ServerApp, sim: *Sim) void {
        var wire: Wire = .{ .sim = sim, .from_client = false };
        const t = &sim.server;
        if (self.done) return;
        if (self.slot == null) {
            for (t.conns, 0..) |held, k| {
                if (held.state == .established) {
                    self.slot = k;
                    self.last_progress = sim.now;
                    t.claim(k);
                    break;
                }
            } else return;
        }
        const i = self.slot.?;
        const c = &t.conns[i];
        if (c.state == .closed) return self.letGo(sim, i);

        if (self.consumed < sim.sc.request_len) {
            const pending = c.pending();
            if (pending.len > 0) {
                for (pending, self.consumed..) |b, k| {
                    if (k >= sim.sc.request_len or b != requestByte(k))
                        return sim.fault("the server read a byte that is not the next byte of the request");
                }
                self.consumed += pending.len;
                self.last_progress = sim.now;
                if (c.consumeReopens(pending.len)) t.ack(&wire, i);
            } else if (c.peerDone()) {
                return self.close(sim, i);
            } else if (sim.now - self.last_progress >= server_idle_ns) {
                t.abandon(&wire, i, .slow_client);
                return self.letGo(sim, i);
            }
            if (self.consumed < sim.sc.request_len) return;
        }

        if (self.queued < sim.sc.answer_len) {
            var chunk: [2048]u8 = undefined;
            var want = @min(chunk.len, sim.sc.answer_len - self.queued);
            if (sim.sc.fires == .total) {
                if (sim.now < self.next_trickle) return;
                self.next_trickle = sim.now + 500 * ns_per_ms;
                want = @min(want, 1);
            }
            for (chunk[0..want], self.queued..) |*b, k| b.* = answerByte(k);
            const n = t.queue(i, chunk[0..want]);
            self.queued += n;
            if (n > 0 or c.una != self.seen_una) {
                self.last_progress = sim.now;
                self.seen_una = c.una;
            } else if (sim.now - self.last_progress >= server_idle_ns) {
                t.abandon(&wire, i, .slow_client);
                return self.letGo(sim, i);
            }
            if (self.queued < sim.sc.answer_len) return;
        }
        self.close(sim, i);
    }

    fn close(self: *ServerApp, sim: *Sim, i: usize) void {
        var wire: Wire = .{ .sim = sim, .from_client = false };
        sim.server.finish(i);
        if (sim.server.conns[i].state != .closing) sim.server.abandon(&wire, i, .unfinished);
        self.letGo(sim, i);
    }

    fn letGo(self: *ServerApp, sim: *Sim, i: usize) void {
        sim.server.release(i);
        self.done = true;
    }
};

// ── the world ───────────────────────────────────────────────────────────────

const Sim = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    now: i96 = 0,
    net: Network = .{},
    client_conns: [slots]tcp.Conn,
    server_conns: [slots]tcp.Conn,
    client_rx: [slots][rx_bytes]u8,
    client_tx: [slots][tx_bytes]u8,
    server_rx: [slots][rx_bytes]u8,
    server_tx: [slots][tx_bytes]u8,
    client_out: [1600]u8,
    server_out: [1600]u8,
    client: tcp.Table,
    server: tcp.Table,
    capp: ClientApp = .{},
    sapp: ServerApp = .{},
    broken: ?[]const u8 = null,
    quiet: bool = false,

    fn init(self: *Sim, seed: u64) void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = Scenario.choose(self.rng);
        self.build();
    }

    fn build(self: *Sim) void {
        self.now = 0;
        self.net = .{};
        self.capp = .{};
        self.sapp = .{};
        self.broken = null;
        for (&self.client_conns, &self.client_rx, &self.client_tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        for (&self.server_conns, &self.server_rx, &self.server_tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        client_isn_next = self.rng.int(u32);
        server_isn_next = self.rng.int(u32);
        self.client = tcp.Table.init(client_ip, client_mac, client_listen_port, &self.client_conns, &self.client_out, clientIsn);
        self.client.reserved_for_initiated = 1;
        self.client.ephemeral_next = self.rng.intRangeAtMost(u16, tcp.ephemeral_first, 0xFFFF);
        self.server = tcp.Table.init(server_ip, server_mac, 80, &self.server_conns, &self.server_out, serverIsn);
        if (self.sc.fires == .connect) self.net.no_server = true;
    }

    fn fault(self: *Sim, what: []const u8) void {
        if (self.broken == null) self.broken = what;
    }

    fn check(self: *Sim, phase: invariants.Phase) void {
        if (self.broken != null) return;
        if (invariants.check(&self.client, self.now, phase)) |v| {
            if (!self.quiet) std.debug.print("seed {d}: the client's table, connection {d}: {s}\n", .{ self.seed, v.conn, v.rule.says() });
            self.fault("an invariant of the client's table broke");
        }
        if (invariants.check(&self.server, self.now, phase)) |v| {
            if (!self.quiet) std.debug.print("seed {d}: the server's table, connection {d}: {s}\n", .{ self.seed, v.conn, v.rule.says() });
            self.fault("an invariant of the server's table broke");
        }
    }

    fn quiescent(self: *const Sim) bool {
        for (self.client.conns) |c| if (c.state != .closed) return false;
        for (self.server.conns) |c| if (c.state != .closed) return false;
        return true;
    }

    fn run(self: *Sim) !void {
        var buf: [1600]u8 = undefined;
        var cw: Wire = .{ .sim = self, .from_client = true };
        var sw: Wire = .{ .sim = self, .from_client = false };
        while (self.now < horizon_ns and self.broken == null) : (self.now += tick_ns) {
            // The idle case: the path dies once the server has read some of
            // the request, while the client still has more to send.
            if (self.sc.fires == .idle and self.net.dead_from == null and self.sapp.consumed > 0)
                self.net.dead_from = self.now;
            while (self.net.take(self.now, &buf)) |p| {
                if (p.to_server) {
                    _ = self.server.handle(&sw, p.frame, self.now);
                } else {
                    _ = self.client.handle(&cw, p.frame, self.now);
                }
                self.check(.after_handle);
            }
            self.capp.turn(self);
            self.sapp.turn(self);
            self.check(.after_handle);
            self.client.transmit(&cw, self.now);
            self.server.transmit(&sw, self.now);
            self.check(.after_transmit);
            self.capp.turn(self); // a connection let go by `transmit` is seen at once
            if (self.capp.slot != null and self.net.count == 0 and self.quiescent() and
                (self.sapp.done or self.sapp.slot == null)) break;
        }
        self.judge();
        const what = self.broken orelse return;
        if (self.quiet) return error.SimulationFailed;
        const sc = self.sc;
        std.debug.print(
            \\tcp_pair_sim seed {d} failed: {s}
            \\  scenario: {s}, request {d} B, answer {d} B, delay {d} us + {d} us jitter, duplicate {d:.2},
            \\            losses {any}, loss {d:.2} until {d} ms, fires {?s}, deadlines {d}/{d}/{d} ms, SYN RTO plant {?d} ms
            \\
        , .{
            self.seed,                                             what,                                    @tagName(sc.trouble),                    sc.request_len,                       sc.answer_len,
            @divTrunc(sc.delay_ns, 1000),                          @divTrunc(sc.jitter_ns, 1000),           sc.duplicate,                            sc.losses,                            sc.loss,
            @divTrunc(sc.lossy_until, ns_per_ms),                  if (sc.fires) |f| @tagName(f) else null, sc.deadlines.connect_ns / tcp.ns_per_ms, sc.deadlines.idle_ns / tcp.ns_per_ms, sc.deadlines.total_ns / tcp.ns_per_ms,
            if (sc.syn_rto_plant) |w| w / tcp.ns_per_ms else null,
        });
        // Two calls: one holds at most 32 arguments.
        std.debug.print(
            \\  at {d} ms: established at {?d} ms, closed at {?d} ms; client sent {d}, received {d}, peer FIN {any};
            \\            server read {d}, queued {d}; network sent {d}+{d}, lost {d}, duplicated {d}, overflowed {d}
            \\  client table: {d} connects, deadlines {d}/{d}/{d}, given up {d}, retransmits {d}, resets {d}
            \\  server table: given up {d}, retransmits {d}, resets {d}
            \\
        , .{
            @divTrunc(self.now, ns_per_ms),                                 if (self.capp.established_at) |t| @divTrunc(t, ns_per_ms) else null,
            if (self.capp.closed_at) |t| @divTrunc(t, ns_per_ms) else null, self.capp.queued,
            self.capp.received,                                             self.capp.peer_fin,
            self.sapp.consumed,                                             self.sapp.queued,
            self.net.sent[0],                                               self.net.sent[1],
            self.net.lost,                                                  self.net.duplicated,
            self.net.overflowed,                                            self.client.connects,
            self.client.connect_deadlines,                                  self.client.idle_deadlines,
            self.client.total_deadlines,                                    self.client.given_up,
            self.client.retransmits,                                        self.client.resets_received,
            self.server.given_up,                                           self.server.retransmits,
            self.server.resets_received,
        });
        return error.SimulationFailed;
    }

    fn judge(self: *Sim) void {
        if (self.broken != null) return;
        if (!self.quiescent()) return self.fault("a table still holds a connection at the horizon");
        const t = &self.client;
        const fired = t.connect_deadlines + t.idle_deadlines + t.total_deadlines;
        const sc = self.sc;
        if (sc.fires) |want| {
            const count = switch (want) {
                .connect => t.connect_deadlines,
                .idle => t.idle_deadlines,
                .total => t.total_deadlines,
            };
            if (count != 1 or fired != 1) return self.fault("the deadline the peer made fire was not the one that let the client go");
            const closed = self.capp.closed_at orelse return self.fault("the client's connection was never let go");
            const due: i96 = switch (want) {
                .connect => @intCast(sc.deadlines.connect_ns),
                .total => @intCast(sc.deadlines.total_ns),
                // From the last thing heard, which the test cannot see once
                // the connection is reset: no earlier than the path's death.
                .idle => (self.net.dead_from orelse return self.fault("the path never died")) + @as(i96, @intCast(sc.deadlines.idle_ns)),
            };
            const late = closed - due;
            // A tick for `transmit` to see it. For idle, the last frame
            // heard is the server's answer to the tick before the death, or
            // one already on its way, landing up to a way's delay and
            // jitter after it.
            const early: i96 = if (want == .idle) tick_ns else 0;
            const slack: i96 = if (want == .idle) sc.delay_ns + sc.jitter_ns + tick_ns else tick_ns;
            if (late < -early or late > slack) return self.fault("the client was let go at the wrong time for its deadline");
            props.reachable(@src(), "tcp_pair_sim: a deadline lets the client go, on time", .{ .which = want });
            return;
        }
        if (fired != 0) return self.fault("a deadline fired on a path that recovers");
        if (t.connect_deadlines == 0 and sc.trouble == .single) {
            const at = self.capp.established_at orelse return self.fault("the client was never established");
            if (at > sc.deadlines.connect_ns) return self.fault("the client was established past the connect bound");
        }
        if (t.given_up != 0 or self.server.given_up != 0) return self.fault("a table gave up on its peer");
        // **ONE RESET IS ALLOWED, AT THE VERY END.** The server closes
        // first and keeps no TIME-WAIT (tcp.zig), so once it has our FIN
        // its slot is free; when its ACK of that FIN is lost, our FIN sent
        // again finds no connection and is answered with a reset. By then
        // each side has everything, so nothing is lost but a clean close.
        const before_fin = self.capp.resets_before_fin orelse t.resets_received;
        if (before_fin != 0 or self.server.resets_received != 0) return self.fault("a connection was reset before the exchange was whole");
        if (t.resets_received != before_fin)
            props.reachable(@src(), "tcp_pair_sim: the client's FIN sent again finds the server's slot free and is reset", .{ .seed = self.seed });
        if (self.sapp.consumed != sc.request_len) return self.fault("the server did not read the whole request");
        if (self.capp.received != sc.answer_len or !self.capp.peer_fin) return self.fault("the client did not get the whole answer and the server's FIN");
        if (sc.losses[0] != null and sc.losses[0].?.nth == 0 and sc.losses[0].?.from_client)
            props.reachable(@src(), "tcp_pair_sim: a lost SYN, and the client established within the connect bound", null);
        props.reachable(@src(), "tcp_pair_sim: two tables exchange a request and an answer whole", .{ .trouble = sc.trouble });
    }
};

/// Runs one seed; an error, with the scenario printed, if any oracle fails.
pub fn runSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.init(seed);
    try sim.run();
}

/// **ONE RUN UNDER A TAPE** (the seed explorer, zig-coverage-sdk's
/// explore.zig, as tcp_sim's `runWithIn`): every draw, the scenario's and
/// the network's, comes from `tape`.
pub fn runWithIn(gpa: std.mem.Allocator, io: std.Io, tape: *explore.Tape) !void {
    _ = io;
    const sim = try gpa.create(Sim);
    defer gpa.destroy(sim);
    sim.seed = tape.seed;
    sim.prng = std.Random.DefaultPrng.init(tape.seed);
    sim.rng = tape.random();
    sim.sc = Scenario.choose(sim.rng);
    sim.build();
    try sim.run();
}

/// What a test forces on a seed's world (`passes`).
pub const Forced = struct {
    /// `single`, under the metal Deadlines, with these losses.
    losses: ?[2]?Loss = null,
    /// The client's SYN waits this long first (`Scenario.syn_rto_plant`).
    syn_rto_ns: ?u64 = null,
    /// The jitter reorders frames (true) or keeps each way first in, first
    /// out (false); null, as the seed chose.
    reorder: ?bool = null,
};

/// Seed `seed`'s world with `forced` on it, and whether every oracle held.
pub fn passes(seed: u64, forced: Forced) !bool {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.seed = seed;
    sim.prng = std.Random.DefaultPrng.init(seed);
    sim.rng = sim.prng.random();
    sim.sc = Scenario.choose(sim.rng);
    if (forced.losses) |l| {
        sim.sc.trouble = .single;
        sim.sc.fires = null;
        sim.sc.deadlines = pair_deadlines;
        sim.sc.loss = 0;
        sim.sc.lossy_until = 0;
        sim.sc.losses = l;
    }
    sim.sc.syn_rto_plant = forced.syn_rto_ns;
    if (forced.reorder) |r| sim.sc.reorder = r;
    sim.build();
    sim.quiet = true;
    return if (sim.run()) true else |_| false;
}

/// How many seeds `zig build test` runs: about 300 (TWO-KERNELS.md §6,
/// chunk 6).
const seed_count = 300;

test "the kernel's client against the kernel's server: 300 seeds of loss, duplicates, jitter and each deadline" {
    var kinds: [3]usize = .{ 0, 0, 0 };
    var fires: [3]usize = .{ 0, 0, 0 };
    for (1..seed_count + 1) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const sc = Scenario.choose(prng.random());
        kinds[@intFromEnum(sc.trouble)] += 1;
        if (sc.fires) |f| fires[@intFromEnum(f)] += 1;
        try runSeed(seed);
    }
    // The sweep holds every kind, and every deadline, several times.
    for (kinds) |n| try std.testing.expect(n >= 30);
    for (fires) |n| try std.testing.expect(n >= 10);
}

test "a lost SYN: established within the connect bound at 25 ms; with the server's 200 ms first wait (the plant), the connect bound fails" {
    const syn_lost: [2]?Loss = .{ .{ .from_client = true, .nth = 0 }, null };
    for (1..21) |seed| {
        try std.testing.expect(try passes(seed, .{ .losses = syn_lost }));
        try std.testing.expect(!try passes(seed, .{ .losses = syn_lost, .syn_rto_ns = tcp.min_rto_ns }));
    }
}

test "a lost SYN-ACK is recovered by the client's next SYN, inside the connect bound" {
    const syn_ack_lost: [2]?Loss = .{ .{ .from_client = false, .nth = 0 }, null };
    for (1..21) |seed| try std.testing.expect(try passes(seed, .{ .losses = syn_ack_lost }));
}

test "reordered, two kernels stay inside the metal bounds: segments ahead of a hole are held (metal-vmm QUEUE 226)" {
    // Before 226, tcp.zig dropped a segment ahead of a hole: two segments of
    // a recovering window that swapped places left one duplicate ACK where
    // three resend, every round ended on the timer, and seed 2 moved 41 KB
    // of 195 KB in 3 s. Held, the hole's resend makes everything behind it
    // whole at once.
    try std.testing.expect(try passes(2, .{ .reorder = false }));
    try std.testing.expect(try passes(2, .{ .reorder = true }));
}
