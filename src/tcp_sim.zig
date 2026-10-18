//! **THE TABLE AGAINST A SIMULATED NETWORK AND A PEER WE DID NOT DERIVE FROM
//! IT** (TCP_TESTING.md §3).
//!
//! Each run is one seed. The seed chooses a scenario:
//!
//! - how big the request and the answer are;
//! - how the network loses, duplicates, delays, reorders and corrupts
//!   frames, in both directions;
//! - how slowly each side reads, and for how long it stalls;
//! - whether the client closes its half early;
//! - whether it vanishes part-way.
//!
//! Then three parties run on one virtual clock, a millisecond at a time:
//!
//! - **The table** (`tcp.zig`), exactly as the kernel runs it.
//! - **A host** that does what `probe/gopher.zig` and `stream.zig` do with a
//!   connection. It reads the request at its own pace, stalling now and
//!   then, and announces a reopened window as `streamFn` does (or, by the
//!   seed, does not). It queues the answer as room allows and finishes. It
//!   lets go of a connection that makes no progress for `idle_ns`.
//! - **A client** written from RFC 9293 and RFC 1122, not by turning
//!   `tcp.zig` around: a model that shared the table's misreadings would
//!   agree with its bugs. It has:
//!   - its own retransmission timer, which goes back to SND.UNA on a timeout;
//!   - delayed acknowledgements: every second segment, or after 40 ms or
//!     200 ms by the seed (Linux and slirp);
//!   - a persist timer that probes a shut window and backs off to 60 s;
//!   - receiver-side silly-window avoidance;
//!   - RFC 9293's acceptability test, and its handling of each state.
//!
//! **THE ORACLES**, any of which fails the run with its seed:
//!
//! - **Invariants:** tcp_check.zig's, after every step the table takes.
//! - **Exactly once, in order:** every byte the host reads is the next byte
//!   of the request, and every byte the client takes is the next byte of the
//!   answer.
//! - **Completion:** a client that did not vanish gets the whole answer and
//!   our FIN, the host reads the whole request, nobody gives up or resets,
//!   all of it within `completion_bound_ns` of the start. This is the oracle
//!   that catches liveness bugs ("it recovers, eventually, after a minute"),
//!   which the next one alone would allow.
//! - **Quiescence:** by `horizon_ns` every slot of the table is closed,
//!   whatever the client did. A connection still held then is held by
//!   nothing.
//!
//! **AND A CROWD** (`Crowd`, `runCrowdSeed`): the same seed's network with
//! 2 to 6 clients against a table of 1 to 8 slots, served one request at a
//! time as gopher.zig serves them, one client perhaps asking twice on one
//! connection and one perhaps holding a stream. Its oracle is every client
//! that stayed got its whole answer and our FIN, the stream's to its end,
//! and none was given up on.
//!
//! Frames are lost only before `lossy_until`. After that the path is clean,
//! so a run that does not complete is a bug, not bad luck. A lossy phase can
//! still, very rarely, lose one frame `max_retries` + 1 times running. A seed
//! that fails that way is reported with the table's give-up count, and it is
//! the run to look at first.

const std = @import("std");
const ev = @import("sim_events.zig");
const proto = @import("proto.zig");
const tcp = @import("tcp.zig");
const invariants = @import("tcp_check.zig");
const props = @import("coverage");
const explore = @import("explore");
const world = @import("tcp_sim_world.zig");
const client_port = world.client_port;
const client_buffer_max = world.client_buffer_max;
const client_buffer = world.client_buffer;
const ns_per_ms = world.ns_per_ms;
const ns_per_s = world.ns_per_s;
const seqLt = world.seqLt;
const client_mss = world.client_mss;
const client_mac = world.client_mac;
const server_mac = world.server_mac;
const client_ip = world.client_ip;
const server_ip = world.server_ip;
const requestByte = world.requestByte;
const randNs = world.randNs;
const seqLe = world.seqLe;
const answerByte = world.answerByte;
const idle_ns = world.idle_ns;
const max_clients = world.max_clients;
const Scenario = world.Scenario;
const Network = world.Network;
const max_slots = world.max_slots;
const rx_bytes = world.rx_bytes;
const tx_bytes = world.tx_bytes;
const Crowd = world.Crowd;
const Rough = world.Rough;
const horizon_ns = world.horizon_ns;
const tick_ns = world.tick_ns;
const completion_bound_ns = world.completion_bound_ns;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

// ── the client, from RFC 9293 ───────────────────────────────────────────────

const ClientState = enum { syn_sent, established, fin_wait_1, fin_wait_2, closing, time_wait, close_wait, last_ack, closed };

const Client = struct {
    state: ClientState = .syn_sent,
    /// **WHO IT IS AND WHAT IT ASKS.** A plain seed's one client takes the
    /// scenario's; a crowd's (`Crowd`) each have their own. With `asks` 2 it
    /// sends a second request on the same connection once the first answer
    /// is whole, as a keep-alive client does.
    index: usize = 0,
    port: u16 = client_port,
    request_len: usize = 0,
    answer_len: usize = 0,
    asks: u8 = 1,
    half_close: bool = false,
    /// When it opens, and whether it has.
    open_at: i96 = 0,
    opened: bool = false,
    /// From `vanish_at` on it neither sends nor hears.
    gone: bool = false,
    /// It was reset, or reset the connection itself, before the end.
    aborted: bool = false,
    /// It reset the connection on purpose (`Rough.reset_at`), and is now a
    /// closed port.
    reset_sent: bool = false,

    iss: u32,
    snd_una: u32,
    snd_nxt: u32,
    /// The furthest it has ever sent: an acknowledgement up to here counts,
    /// even after a timeout sent `snd_nxt` back.
    snd_max: u32,
    snd_wnd: u32 = 0,
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    /// Its FIN follows the request: from the start if it closes early, else
    /// once the table's FIN has come.
    fin_wanted: bool = false,
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    /// The table's FIN has arrived.
    peer_fin: bool = false,

    rto_ns: i96 = base_rto_ns,
    rto_at: ?i96 = null,
    retries: u8 = 0,
    persist_ns: i96 = base_rto_ns,
    persist_at: ?i96 = null,
    probes: u64 = 0,
    /// In-order segments taken and not yet acknowledged.
    ack_owed: u8 = 0,
    delack_at: ?i96 = null,
    told_wnd: u32 = 0,

    /// Bytes of the answer taken, and of those not yet read by its
    /// application.
    received: usize = 0,
    unread: usize = 0,
    stall_until: i96 = 0,
    time_wait_until: ?i96 = null,
    done_at: ?i96 = null,

    /// Bytes ahead of a hole, by their offset from RCV.NXT, waiting for it
    /// to fill; and where the table's FIN is, once one has been seen.
    held: [client_buffer_max]u8 = undefined,
    held_mask: [client_buffer_max]bool = @splat(false),
    /// Its receive buffer: the scenario's `client_buffer`.
    buffer: usize = client_buffer,
    fin_at: ?u32 = null,

    const base_rto_ns: i96 = 300 * ns_per_ms;
    const max_rto_ns: i96 = 8 * ns_per_s;
    const max_persist_ns: i96 = 60 * ns_per_s;
    const max_retries: u8 = 12;
    const time_wait_ns: i96 = 2 * ns_per_s;

    fn init(iss: u32) Client {
        return .{ .iss = iss, .snd_una = iss, .snd_nxt = iss, .snd_max = iss };
    }

    /// Whether anything is held past a hole.
    fn holding(self: *const Client) bool {
        return std.mem.indexOfScalar(bool, self.held_mask[0..self.buffer], true) != null;
    }

    fn window(self: *const Client) u32 {
        return @intCast(@min(self.buffer - self.unread, 0xFFFF));
    }

    /// Bytes of the request sent so far, at `snd_nxt`.
    fn requestSent(self: *const Client, sim: *const Sim) usize {
        _ = sim;
        const n: usize = self.snd_nxt -% (self.iss +% 1);
        return @min(n, self.toSend());
    }

    /// Everything it will ever send: each of its requests.
    fn toSend(self: *const Client) usize {
        return self.request_len * self.asks;
    }

    /// What it may send by now: its first request, and the second once the
    /// first answer is whole.
    fn released(self: *const Client) usize {
        if (self.asks > 1 and self.received >= self.answer_len) return self.toSend();
        return self.request_len;
    }

    fn finSeq(self: *const Client, sim: *const Sim) u32 {
        _ = sim;
        return self.iss +% 1 +% @as(u32, @intCast(self.toSend()));
    }

    fn finSent(self: *const Client, sim: *const Sim) bool {
        return self.fin_wanted and seqLt(self.finSeq(sim), self.snd_nxt);
    }

    fn emit(self: *Client, sim: *Sim, flags: u8, seq: u32, data: []const u8) void {
        var buf: [1600]u8 = undefined;
        const options: []const u8 = if (flags & tcp.flag_syn != 0) &[_]u8{ 2, 4, client_mss >> 8, client_mss & 0xFF } else &.{};
        const len = tcp.header_len + options.len;
        const frame_len = proto.writeIpv4(&buf, .{ .mac = client_mac, .ip = client_ip }, .{ .mac = server_mac, .ip = server_ip }, proto.proto_tcp, len + data.len);
        const t = buf[tcp.segment_at..][0 .. len + data.len];
        const wnd = self.window();
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(80));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(if (flags & tcp.flag_ack != 0) self.rcv_nxt else 0));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(@intCast(wnd)));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[tcp.header_len..len], options);
        @memcpy(t[len..], data);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(client_ip, server_ip, proto.proto_tcp, t)));
        if (flags & tcp.flag_ack != 0) {
            // Every acknowledgement it sends pays what it owed.
            self.ack_owed = 0;
            self.delack_at = null;
            self.told_wnd = wnd;
        }
        sim.net.send(sim.rng, &sim.sc, sim.now, true, buf[0..frame_len]);
    }

    fn sendAck(self: *Client, sim: *Sim) void {
        self.emit(sim, tcp.flag_ack, self.snd_nxt, "");
    }

    fn open(self: *Client, sim: *Sim) void {
        self.fin_wanted = self.half_close;
        self.opened = true;
        self.emit(sim, tcp.flag_syn, self.iss, "");
        self.snd_nxt = self.iss +% 1;
        self.snd_max = self.snd_nxt;
        self.rto_at = sim.now + self.rto_ns;
    }

    fn abort(self: *Client, sim: *Sim) void {
        self.emit(sim, tcp.flag_rst, self.snd_nxt, "");
        self.aborted = true;
        self.finish(sim);
    }

    fn finish(self: *Client, sim: *Sim) void {
        self.state = .closed;
        self.rto_at = null;
        self.persist_at = null;
        self.delack_at = null;
        if (self.done_at == null) self.done_at = sim.now;
    }

    /// Sends what the window allows, then the FIN if it is due.
    fn output(self: *Client, sim: *Sim) void {
        if (self.state != .established and self.state != .close_wait and
            self.state != .fin_wait_1 and self.state != .last_ack and self.state != .closing) return;
        const n_req = self.released();
        while (true) {
            if (self.finSent(sim)) return;
            const sent = self.requestSent(sim);
            if (sent < n_req) {
                const flight = self.snd_nxt -% self.snd_una;
                if (flight >= self.snd_wnd) {
                    // A shut window with nothing in flight: only the persist
                    // timer will learn that it has opened (RFC 9293 §3.8.6.1).
                    if (self.snd_wnd == 0 and flight == 0 and self.persist_at == null)
                        self.persist_at = sim.now + self.persist_ns;
                    return;
                }
                const n = @min(n_req - sent, self.snd_wnd - flight, client_mss);
                var data: [client_mss]u8 = undefined;
                for (data[0..n], sent..) |*b, k| b.* = requestByte(k);
                if (sent >= self.request_len)
                    props.reachable(@src(), "tcp_sim: a keep-alive client sends its second request", .{ .client = self.index });
                self.emit(sim, tcp.flag_psh | tcp.flag_ack, self.snd_nxt, data[0..n]);
                self.advance(sim, @intCast(n));
                continue;
            }
            // The FIN follows every request, never one still to be released.
            if (sent < self.toSend()) return;
            if (!self.fin_wanted) return;
            self.emit(sim, tcp.flag_fin | tcp.flag_ack, self.snd_nxt, "");
            self.advance(sim, 1);
            self.state = switch (self.state) {
                .established => .fin_wait_1,
                .close_wait => .last_ack,
                else => self.state, // a FIN sent again
            };
            return;
        }
    }

    fn advance(self: *Client, sim: *Sim, n: u32) void {
        self.snd_nxt +%= n;
        if (seqLt(self.snd_max, self.snd_nxt)) self.snd_max = self.snd_nxt;
        if (self.rto_at == null) self.rto_at = sim.now + self.rto_ns;
    }

    /// One turn: its application reads, its timers run, it sends.
    fn turn(self: *Client, sim: *Sim) void {
        if (self.gone or self.state == .closed) return;
        // The scenario's and the rough peer's misbehaviour is the first
        // client's alone: a crowd's others behave.
        if (self.index == 0) if (sim.sc.vanish_at) |at| if (sim.now >= at) {
            self.gone = true;
            if (self.done_at == null) self.done_at = sim.now;
            return;
        };
        if (self.index == 0) if (sim.rough.vanish_after) |n| if (self.state != .syn_sent and self.received >= n) {
            props.reachable(@src(), "tcp_sim: the client vanishes part-way through the answer", .{ .received = self.received });
            self.gone = true;
            if (self.done_at == null) self.done_at = sim.now;
            return;
        };
        if (self.index == 0) if (sim.rough.reset_at) |at| if (sim.now >= at and self.state != .syn_sent) {
            props.reachable(@src(), "tcp_sim: the client resets the connection", .{ .off = sim.rough.reset_off });
            self.emit(sim, tcp.flag_rst, self.snd_nxt +% sim.rough.reset_off, "");
            self.reset_sent = true;
            self.aborted = true;
            return self.finish(sim);
        };

        // Its application reads what has arrived, at its own pace.
        if (self.unread > 0 and sim.now >= self.stall_until) {
            if (sim.rng.uintLessThan(u32, 2000) == 0) {
                self.stall_until = sim.now + randNs(sim.rng, sim.sc.client_stall_ns);
            } else {
                self.unread -= sim.rng.intRangeAtMost(usize, 1, self.unread);
                // Receiver-side silly-window avoidance: a window update once
                // it has grown by a segment or half the buffer.
                const grown = self.window() -| self.told_wnd;
                if (self.state != .syn_sent and grown >= @min(client_mss, self.buffer / 2)) self.sendAck(sim);
            }
        }

        if (self.time_wait_until) |until| if (sim.now >= until) return self.finish(sim);
        if (self.delack_at) |at| if (sim.now >= at) self.sendAck(sim);

        if (self.rto_at) |at| if (sim.now >= at) {
            self.retries += 1;
            if (self.retries > max_retries) return self.abort(sim);
            self.rto_ns = @min(self.rto_ns * 2, max_rto_ns);
            self.rto_at = sim.now + self.rto_ns;
            if (self.state == .syn_sent) {
                self.emit(sim, tcp.flag_syn, self.iss, "");
            } else {
                // Go back: everything from SND.UNA is sent again. If the
                // window is shut nothing goes, and the persist timer, which
                // does not count toward giving up, takes over.
                self.snd_nxt = self.snd_una;
                self.output(sim);
                if (self.snd_nxt == self.snd_una) self.rto_at = null;
            }
        };

        if (self.persist_at) |at| if (sim.now >= at) {
            // One byte of new data past the shut window (RFC 9293 §3.8.6.1).
            // It is not counted as sent: if the table takes it, its
            // acknowledgement says so.
            const sent = self.requestSent(sim);
            if (self.snd_wnd == 0 and sent < self.released() and self.snd_nxt == self.snd_una) {
                self.probes += 1;
                const probe = [1]u8{requestByte(sent)};
                self.emit(sim, tcp.flag_psh | tcp.flag_ack, self.snd_nxt, &probe);
                if (seqLt(self.snd_max, self.snd_nxt +% 1)) self.snd_max = self.snd_nxt +% 1;
                self.persist_ns = @min(self.persist_ns * 2, max_persist_ns);
                self.persist_at = sim.now + self.persist_ns;
            } else self.persist_at = null;
        };

        self.output(sim);
    }

    /// **A CLOSED PORT** answers a segment with a reset, numbered by its
    /// acknowledgement (RFC 9293 §3.10.7.1): which names exactly the byte
    /// the table expects next, and so is the exact reset that answers its
    /// challenge.
    fn answerClosed(self: *Client, sim: *Sim, frame: []const u8) void {
        const pkt = proto.parseIpv4(frame) orelse return;
        const t = pkt.payload;
        if (pkt.protocol != proto.proto_tcp or t.len < tcp.header_len) return;
        if (proto.readBe16(t[2..4]) != self.port) return;
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) return;
        const flags = t[13];
        if (flags & tcp.flag_rst != 0 or flags & tcp.flag_ack == 0) return;
        self.emit(sim, tcp.flag_rst, proto.readBe32(t[8..12]), "");
    }

    /// A frame from the table.
    fn receive(self: *Client, sim: *Sim, frame: []const u8) void {
        if (self.reset_sent) return self.answerClosed(sim, frame);
        if (self.gone) return;
        // **A CLOSED CLIENT IS A HOST WITH NOTHING ON THAT PORT**, and answers
        // with a reset (RFC 9293 §3.10.7.1). Its TIME-WAIT is short, so the
        // table's backed-off FIN can arrive after it; silence there would
        // leave the table to give up on a client that got everything.
        if (self.state == .closed) return self.answerClosed(sim, frame);
        const pkt = proto.parseIpv4(frame) orelse return;
        const t = pkt.payload;
        if (pkt.protocol != proto.proto_tcp or t.len < tcp.header_len) return;
        if (proto.readBe16(t[2..4]) != self.port) return;
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) return;
        const seq = proto.readBe32(t[4..8]);
        const ack = proto.readBe32(t[8..12]);
        const flags = t[13];
        const wnd: u32 = proto.readBe16(t[14..16]);
        const offset = @as(usize, t[12] >> 4) * 4;
        if (offset < tcp.header_len or offset > t.len) return;
        const data = t[offset..];

        if (self.state == .syn_sent) {
            if (flags & tcp.flag_ack != 0 and ack != self.iss +% 1) return;
            if (flags & tcp.flag_rst != 0) {
                if (flags & tcp.flag_ack != 0) {
                    self.aborted = true;
                    self.finish(sim);
                }
                return;
            }
            if (flags & tcp.flag_syn == 0 or flags & tcp.flag_ack == 0) return;
            self.irs = seq;
            self.rcv_nxt = seq +% 1;
            self.snd_una = ack;
            self.snd_wnd = wnd;
            self.snd_wl1 = seq;
            self.snd_wl2 = ack;
            self.state = .established;
            self.rto_at = null;
            self.retries = 0;
            self.rto_ns = base_rto_ns;
            self.sendAck(sim);
            self.output(sim);
            return;
        }

        // **THE ACCEPTABILITY TEST** (RFC 9293 §3.10.7.4, first).
        var seg_len: u32 = @intCast(data.len);
        if (flags & tcp.flag_syn != 0) seg_len += 1;
        if (flags & tcp.flag_fin != 0) seg_len += 1;
        const rcv_wnd = self.window();
        const acceptable = if (seg_len == 0)
            (if (rcv_wnd == 0) seq == self.rcv_nxt else (seq -% self.rcv_nxt) < rcv_wnd)
        else
            rcv_wnd > 0 and ((seq -% self.rcv_nxt) < rcv_wnd or
                ((seq +% seg_len -% 1) -% self.rcv_nxt) < rcv_wnd);
        if (!acceptable) {
            if (flags & tcp.flag_rst == 0) self.sendAck(sim);
            return;
        }

        // Second, the reset.
        if (flags & tcp.flag_rst != 0) {
            if (seq != self.rcv_nxt) return self.sendAck(sim); // RFC 5961's challenge
            // In the closing states a reset is only an early end (RFC 9293
            // §3.10.7.4); before them it is an abort.
            switch (self.state) {
                .closing, .last_ack, .time_wait => {},
                else => self.aborted = true,
            }
            return self.finish(sim);
        }
        // Fourth, a SYN in the window: a challenge ACK, and nothing else.
        if (flags & tcp.flag_syn != 0) return self.sendAck(sim);
        // Fifth, the acknowledgement.
        if (flags & tcp.flag_ack == 0) return;
        if (seqLt(self.snd_max, ack)) return self.sendAck(sim); // of something never sent
        if (seqLt(self.snd_una, ack)) {
            self.snd_una = ack;
            if (seqLt(self.snd_nxt, self.snd_una)) self.snd_nxt = self.snd_una;
            self.retries = 0;
            self.rto_ns = base_rto_ns;
            self.rto_at = if (self.snd_nxt != self.snd_una) sim.now + self.rto_ns else null;
            if (self.fin_wanted and ack == self.finSeq(sim) +% 1) {
                switch (self.state) {
                    .fin_wait_1 => self.state = .fin_wait_2,
                    .closing => {
                        self.state = .time_wait;
                        self.time_wait_until = sim.now + time_wait_ns;
                    },
                    .last_ack => return self.finish(sim),
                    else => {},
                }
            }
        }
        if (seqLt(self.snd_wl1, seq) or (self.snd_wl1 == seq and seqLe(self.snd_wl2, ack))) {
            self.snd_wnd = wnd;
            self.snd_wl1 = seq;
            self.snd_wl2 = ack;
            if (wnd > 0) {
                self.persist_at = null;
                self.persist_ns = base_rto_ns;
            }
        }

        // Seventh, the text. Segments ahead of a hole are held, as Linux
        // holds them (RFC 9293 makes it a MAY), and a hole is reported, and
        // its filling acknowledged, at once (RFC 5681 §4.2).
        if (flags & tcp.flag_fin != 0) self.fin_at = seq +% @as(u32, @intCast(data.len));
        var at_once = false;
        if (data.len > 0) {
            const takes = self.state == .established or self.state == .fin_wait_1 or self.state == .fin_wait_2;
            if (!takes) {
                // Text after the table's FIN: it should never come.
                sim.fault("the table sent text after its FIN");
                return;
            }
            // Where the segment's bytes go, relative to RCV.NXT: a segment
            // that straddles it has its old part skipped.
            var skip: usize = 0;
            var at: usize = 0;
            if (seqLt(seq, self.rcv_nxt)) {
                skip = self.rcv_nxt -% seq;
            } else at = seq -% self.rcv_nxt;
            const room = self.window();
            const had_hole = self.holding();
            if (at > 0) at_once = true; // out of order: a duplicate ACK now
            for (data[@min(skip, data.len)..], at..) |b, pos| {
                if (pos >= room) break;
                self.held[pos] = b;
                self.held_mask[pos] = true;
            }
            var n: usize = 0;
            while (n < room and self.held_mask[n]) n += 1;
            if (n > 0) {
                for (self.held[0..n], self.received..) |b, k| {
                    if (k >= self.answer_len or b != answerByte(k)) {
                        sim.fault("the client took a byte that is not the next byte of the answer");
                        return;
                    }
                }
                self.received += n;
                self.unread += n;
                self.rcv_nxt +%= @intCast(n);
                std.mem.copyForwards(u8, self.held[0 .. self.buffer - n], self.held[n..self.buffer]);
                std.mem.copyForwards(bool, self.held_mask[0 .. self.buffer - n], self.held_mask[n..self.buffer]);
                @memset(self.held_mask[self.buffer - n .. self.buffer], false);
                if (had_hole or self.holding()) at_once = true; // a hole filled, or one left
            }
            if (data.len > skip and skip + (room -| at) < data.len) at_once = true; // some did not fit
            self.ack_owed += 1;
            if (at_once or self.ack_owed >= 2) {
                self.sendAck(sim);
            } else if (self.delack_at == null) {
                self.delack_at = sim.now + sim.sc.delayed_ack_ns;
            }
        }

        // Eighth, the FIN, once everything before it has been taken.
        if (self.fin_at) |fin_seq| {
            if (!self.peer_fin and fin_seq == self.rcv_nxt) {
                self.rcv_nxt +%= 1;
                self.peer_fin = true;
                switch (self.state) {
                    .established => {
                        self.state = .close_wait;
                        self.fin_wanted = true;
                    },
                    .fin_wait_1 => self.state = .closing,
                    .fin_wait_2 => {
                        self.state = .time_wait;
                        self.time_wait_until = sim.now + time_wait_ns;
                    },
                    else => {},
                }
                self.sendAck(sim);
            } else if (!self.peer_fin and flags & tcp.flag_fin != 0) {
                // A FIN ahead of a hole: say what is missing.
                self.sendAck(sim);
            }
        }
        self.output(sim);
    }
};

// ── the host ────────────────────────────────────────────────────────────────

const Host = struct {
    slot: ?usize = null,
    consumed: usize = 0,
    queued: usize = 0,
    finished: bool = false,
    let_go: bool = false,
    stall_until: i96 = 0,
    last_progress: i96 = 0,
    seen_una: u32 = 0,

    /// One turn, between the network's arrivals and the table's `transmit`.
    fn turn(self: *Host, sim: *Sim) void {
        const table = &sim.table;
        var wire = TableWire{ .sim = sim };
        if (self.slot == null) {
            for (table.conns, 0..) |held, k| {
                if (held.state == .established) {
                    self.slot = k;
                    self.last_progress = sim.now;
                    table.claim(k);
                    break;
                }
            } else return;
        }
        const i = self.slot.?;
        const c = &table.conns[i];
        if (self.finished or self.let_go) return;
        if (c.state == .closed) {
            // Reset under us: the host's part is over.
            self.let_go = true;
            table.release(i);
            return;
        }

        if (self.consumed < sim.sc.request_len) {
            if (sim.now < self.stall_until) return;
            if (sim.rng.uintLessThan(u32, 2000) == 0) {
                self.stall_until = sim.now + randNs(sim.rng, sim.sc.host_stall_ns);
                return;
            }
            const pending = c.pending();
            if (pending.len > 0) {
                const n = sim.rng.intRangeAtMost(usize, 1, @min(pending.len, 3000));
                for (pending[0..n], self.consumed..) |b, k| {
                    if (k >= sim.sc.request_len or b != requestByte(k)) {
                        sim.fault("the host read a byte that is not the next byte of the request");
                        return;
                    }
                }
                // As streamFn, by the same rule (Conn.consumeReopens): a
                // tight window is announced when it reopens.
                const reopened = c.consumeReopens(n);
                self.consumed += n;
                self.last_progress = sim.now;
                if (sim.sc.host_announces and reopened) table.ack(&wire, i);
            } else if (c.peerDone() or !c.open()) {
                // The request will never be whole: answered and closed, as
                // the host does a request that ends early.
                self.close(sim, i);
            } else if (sim.now - self.last_progress >= idle_ns) {
                self.giveUp(sim, i);
            }
            return;
        }

        if (self.queued < sim.sc.answer_len) {
            var chunk: [2048]u8 = undefined;
            const want = @min(chunk.len, sim.sc.answer_len - self.queued);
            for (chunk[0..want], self.queued..) |*b, k| b.* = answerByte(k);
            const n = table.queue(i, chunk[0..want]);
            self.queued += n;
            if (n > 0 or c.una != self.seen_una) {
                self.last_progress = sim.now;
                self.seen_una = c.una;
            } else if (sim.now - self.last_progress >= idle_ns) {
                // As sendAll: a write that gets nowhere for the idle time.
                return self.giveUp(sim, i);
            }
            if (self.queued < sim.sc.answer_len) return;
        }
        self.close(sim, i);
    }

    /// As gopher.zig's `close`: the FIN is queued and nobody waits for it.
    fn close(self: *Host, sim: *Sim, i: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.finish(i);
        if (sim.table.conns[i].state != .closing) sim.table.abandon(&wire, i, .unfinished);
        sim.table.release(i);
        self.finished = true;
    }

    fn giveUp(self: *Host, sim: *Sim, i: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.abandon(&wire, i, .slow_client);
        sim.table.release(i);
        self.let_go = true;
    }
};

// ── the host of a crowd, as gopher.zig ──────────────────────────────────────

/// **MANY CONNECTIONS, ONE REQUEST AT A TIME** (gopher.zig's loop). Each turn
/// it moves its held stream, then serves at most one thing: the oldest
/// connection whose whole request has arrived, start to finish over as many
/// turns as that takes, or else the oldest that has been quiet for `idle_ns`,
/// which it lets go. Each serve reads one request and answers it and closes,
/// as gopher.zig does a keep-alive client's; a stream's serve writes its
/// head and leaves the connection held open, and its chunks go out on every
/// turn after, among the other serves.
const Server = struct {
    /// The slot being served, and whose it is.
    current: ?usize = null,
    who: usize = 0,
    consumed: [max_clients]usize = @splat(0),
    queued: [max_clients]usize = @splat(0),
    finished: [max_clients]bool = @splat(false),
    let_go: [max_clients]bool = @splat(false),
    stall_until: i96 = 0,
    last_progress: i96 = 0,
    seen_una: u32 = 0,
    held: ?Held = null,

    const Held = struct {
        slot: usize,
        who: usize,
        next_at: i96,
        last_progress: i96,
        seen_una: u32,
    };

    /// Whose connection slot `k` holds, if a crowd client's.
    fn owner(sim: *const Sim, k: usize) ?usize {
        const c = &sim.table.conns[k];
        if (!std.mem.eql(u8, &c.peer_ip, &client_ip)) return null;
        if (c.peer_port < client_port or c.peer_port - client_port >= sim.n_clients) return null;
        return c.peer_port - client_port;
    }

    fn idle(self: *const Server) bool {
        return self.current == null and self.held == null;
    }

    fn turn(self: *Server, sim: *Sim) void {
        self.moveStream(sim);
        if (self.current == null) {
            if (self.nextReady(sim)) |k| {
                sim.table.claim(k);
                self.current = k;
                self.who = owner(sim, k).?;
                self.last_progress = sim.now;
                self.seen_una = sim.table.conns[k].una;
            } else if (self.quiet(sim)) |k| {
                // A client that said nothing for the idle time, let go.
                if (owner(sim, k)) |w| self.let_go[w] = true;
                sim.table.claim(k);
                close(sim, k);
                return;
            } else return;
        } else if (self.nextReady(sim) != null) {
            props.reachable(@src(), "tcp_sim: a whole request waits while another is served", .{ .slot = self.current.? });
        }
        if (self.held != null) props.reachable(@src(), "tcp_sim: a held stream moves while another request is served", .{ .slot = self.current.? });
        self.serve(sim);
    }

    /// The oldest connection, not claimed and established, whose request is
    /// whole (or whose client has said all it will).
    fn nextReady(self: *const Server, sim: *const Sim) ?usize {
        _ = self;
        var best: ?usize = null;
        for (sim.table.conns, 0..) |*c, k| {
            if (c.claimed or c.state != .established) continue;
            const w = owner(sim, k) orelse continue;
            if (c.pending().len < sim.clientAtConst(w).request_len and !c.peerDone()) continue;
            if (best == null or c.serial < sim.table.conns[best.?].serial) best = k;
        }
        return best;
    }

    fn quiet(self: *const Server, sim: *const Sim) ?usize {
        _ = self;
        var best: ?usize = null;
        for (sim.table.conns, 0..) |*c, k| {
            if (c.claimed or !c.open()) continue;
            if (sim.now - c.heard_at < idle_ns) continue;
            if (best == null or c.serial < sim.table.conns[best.?].serial) best = k;
        }
        return best;
    }

    /// One turn of the serve in progress: read the request, queue the
    /// answer, close (or hold the stream).
    fn serve(self: *Server, sim: *Sim) void {
        const k = self.current.?;
        const w = self.who;
        const c = &sim.table.conns[k];
        const client = sim.clientAtConst(w);
        if (c.state == .closed) {
            // Reset under us: this serve is over.
            self.let_go[w] = true;
            sim.table.release(k);
            self.current = null;
            return;
        }
        if (self.consumed[w] < client.request_len) {
            if (sim.now < self.stall_until) return;
            if (sim.rng.uintLessThan(u32, 2000) == 0) {
                self.stall_until = sim.now + randNs(sim.rng, sim.sc.host_stall_ns);
                return;
            }
            const pending = c.pending();
            if (pending.len > 0) {
                // One request, and not a byte of the next: a keep-alive
                // client's second is left unread, as gopher.zig leaves it.
                const most = @min(pending.len, client.request_len - self.consumed[w]);
                const n = sim.rng.intRangeAtMost(usize, 1, @min(most, 3000));
                for (pending[0..n], self.consumed[w]..) |b, j| {
                    if (b != requestByte(j)) {
                        sim.fault("the host read a byte that is not the next byte of the request");
                        return;
                    }
                }
                c.consume(n);
                self.consumed[w] += n;
                self.last_progress = sim.now;
            } else if (c.peerDone() or !c.open()) {
                return self.end(sim, k, w);
            } else if (sim.now - self.last_progress >= idle_ns) {
                return self.giveUp(sim, k, w);
            }
            return;
        }
        const head = client.answer_len - sim.crowd.?.streamLen(w);
        if (self.queued[w] < head) {
            if (!self.queueSome(sim, k, w, head)) return self.giveUp(sim, k, w);
            if (self.queued[w] < head) return;
        }
        if (sim.crowd.?.stream == w) {
            // The head is out: the stream is held from here, claimed and
            // open, and this host goes on to the next request.
            self.held = .{ .slot = k, .who = w, .next_at = sim.now, .last_progress = sim.now, .seen_una = c.una };
            self.current = null;
            return;
        }
        self.end(sim, k, w);
    }

    /// Queues what fits of the answer up to `upto`. False when nothing has
    /// moved for the idle time: the client is not taking it.
    fn queueSome(self: *Server, sim: *Sim, k: usize, w: usize, upto: usize) bool {
        const c = &sim.table.conns[k];
        var chunk: [2048]u8 = undefined;
        const want = @min(chunk.len, upto - self.queued[w]);
        for (chunk[0..want], self.queued[w]..) |*b, j| b.* = answerByte(j);
        const n = sim.table.queue(k, chunk[0..want]);
        self.queued[w] += n;
        if (n > 0 or c.una != self.seen_una) {
            self.last_progress = sim.now;
            self.seen_una = c.una;
        } else if (sim.now - self.last_progress >= idle_ns) return false;
        return true;
    }

    /// The held stream's next chunk, when it is due; its close after the
    /// last; and the end of a stream whose client stopped taking it.
    fn moveStream(self: *Server, sim: *Sim) void {
        const h = &(self.held orelse return);
        const c = &sim.table.conns[h.slot];
        const crowd = sim.crowd.?;
        const total = sim.clientAtConst(h.who).answer_len;
        if (c.state == .closed) {
            self.let_go[h.who] = true;
            sim.table.release(h.slot);
            self.held = null;
            return;
        }
        if (c.una != h.seen_una) {
            h.seen_una = c.una;
            h.last_progress = sim.now;
        }
        if (self.queued[h.who] < total and sim.now >= h.next_at) {
            const upto = @min(total, self.queued[h.who] + crowd.stream_chunk);
            var chunk: [2048]u8 = undefined;
            const want = @min(chunk.len, upto - self.queued[h.who]);
            for (chunk[0..want], self.queued[h.who]..) |*b, j| b.* = answerByte(j);
            const n = sim.table.queue(h.slot, chunk[0..want]);
            self.queued[h.who] += n;
            if (n > 0) h.last_progress = sim.now;
            if (n == want) h.next_at = sim.now + crowd.stream_gap_ns;
        }
        if (self.queued[h.who] == total) {
            const w = h.who;
            const slot = h.slot;
            self.held = null;
            return self.endHeld(sim, slot, w);
        }
        if (sim.now - h.last_progress >= idle_ns) {
            // A stream whose client stopped taking it is ended (gopher.zig).
            const w = h.who;
            const slot = h.slot;
            self.held = null;
            var wire = TableWire{ .sim = sim };
            sim.table.abandon(&wire, slot, .stream_behind);
            sim.table.release(slot);
            self.let_go[w] = true;
        }
    }

    fn endHeld(self: *Server, sim: *Sim, k: usize, w: usize) void {
        close(sim, k);
        self.finished[w] = true;
    }

    fn end(self: *Server, sim: *Sim, k: usize, w: usize) void {
        close(sim, k);
        self.finished[w] = true;
        self.current = null;
    }

    fn giveUp(self: *Server, sim: *Sim, k: usize, w: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.abandon(&wire, k, .slow_client);
        sim.table.release(k);
        self.let_go[w] = true;
        self.current = null;
    }

    /// As gopher.zig's `close`: the FIN is queued and nobody waits for it.
    fn close(sim: *Sim, k: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.finish(k);
        if (sim.table.conns[k].state != .closing) sim.table.abandon(&wire, k, .unfinished);
        sim.table.release(k);
    }
};

// ── the run ─────────────────────────────────────────────────────────────────

/// What the table sends goes into the network, toward the client.
const TableWire = struct {
    sim: *Sim,

    pub fn send(self: *TableWire, frame: []const u8) void {
        const sim = self.sim;
        sim.karn(frame);
        sim.net.send(sim.rng, &sim.sc, sim.now, false, frame);
    }
};

/// **THE REVIVAL RING'S SIZE, FOR A MEASUREMENT** (tcp.zig `revival_cap`):
/// null is the kernel's, all `tcp.revival_slots`; zero turns revival off,
/// which is the table before it.
pub var revival_cap: ?u16 = null;

var sim_isn: u32 = 0;
fn simIsn() u32 {
    sim_isn +%= 64_000;
    return sim_isn;
}

const Sim = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    now: i96 = 0,
    net: Network = .{},
    conns: [max_slots]tcp.Conn,
    rx: [max_slots][rx_bytes]u8,
    tx: [max_slots][tx_bytes]u8,
    /// How many of them the table has: 2 for a plain seed.
    slots: usize = 2,
    out: [1600]u8,
    table: tcp.Table,
    host: Host = .{},
    client: Client,
    /// A crowd's (`Crowd`) other clients, and its host.
    others: [max_clients - 1]Client = undefined,
    n_clients: usize = 1,
    crowd: ?Crowd = null,
    server: Server = .{},
    /// The table's give-ups on each client's own connection.
    given_up_on: [max_clients]u64 = @splat(0),
    /// Each client's half-open connection given way to another's SYN (the
    /// table's `oldestHalfOpen`): the class of item 24's red rough seeds.
    given_way_on: [max_clients]u64 = @splat(0),
    rough: Rough = .{},
    /// Set by a test after the sim's init: `slotsOf` counts its calls, and
    /// holds every 16th to `slotOf` for every client.
    slots_checked: ?u64 = null,
    flooded: u8 = 0,
    /// The table's give-ups on the client's own connection: with a flood,
    /// `table.given_up` also counts the flood's half-open ones, which it
    /// is right to give up on.
    client_given_up: u64 = 0,
    /// The first oracle that failed, if any.
    broken: ?[]const u8 = null,
    /// A failure is not printed (`traceOf`, which asks whether one happens).
    quiet: bool = false,

    /// In place: the table holds slices of this struct's own buffers.
    fn init(self: *Sim, seed: u64) void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = Scenario.choose(self.rng);
        self.build();
    }

    /// Like `init`, but with a chosen scenario (the item-96 sweep). The seed
    /// still seeds the RNG, so jitter — which is what reorders frames — is
    /// deterministic per (seed, scenario).
    fn initScenario(self: *Sim, seed: u64, sc: Scenario) void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = sc;
        self.build();
    }

    /// Like `init`, with a rougher peer chosen from the same seed.
    fn initRough(self: *Sim, seed: u64) void {
        self.init(seed);
        var second = std.Random.DefaultPrng.init(seed ^ 0x726f_7567_6870_6565); // "roughpee"
        self.rough = Rough.choose(second.random(), &self.sc);
    }

    fn build(self: *Sim) void {
        self.now = 0;
        self.net = .{};
        self.host = .{};
        self.rough = .{};
        self.flooded = 0;
        self.client_given_up = 0;
        self.broken = null;
        self.slots = 2;
        self.n_clients = 1;
        self.crowd = null;
        self.server = .{};
        self.given_up_on = @splat(0);
        self.given_way_on = @splat(0);
        for (&self.conns, &self.rx, &self.tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        sim_isn = self.rng.int(u32);
        self.table = tcp.Table.init(server_ip, server_mac, 80, self.conns[0..self.slots], &self.out, simIsn);
        if (revival_cap) |cap| self.table.revival_cap = cap;
        self.client = Client.init(self.rng.int(u32));
        std.debug.assert(self.sc.client_buffer <= client_buffer_max);
        self.client.buffer = self.sc.client_buffer;
        self.client.request_len = self.sc.request_len;
        self.client.answer_len = self.sc.answer_len;
        self.client.half_close = self.sc.half_close;
    }

    /// Like `init`, with a crowd chosen from the same seed (`Crowd`): its
    /// table's size, its clients and what each asks.
    fn initCrowd(self: *Sim, seed: u64) void {
        self.init(seed);
        var third = std.Random.DefaultPrng.init(seed ^ 0x6372_6f77_6463_726f); // "crowdcro"
        const r = third.random();
        self.withCrowd(Crowd.choose(r), r);
    }

    /// Like `initCrowd`, with a crowd the size of the kernel's table
    /// (`Crowd.chooseFull`), from a fourth generator.
    fn initFull(self: *Sim, seed: u64) void {
        self.init(seed);
        var fourth = std.Random.DefaultPrng.init(seed ^ 0x6675_6c6c_7461_626c); // "fulltabl"
        const r = fourth.random();
        self.withCrowd(Crowd.chooseFull(r), r);
    }

    fn withCrowd(self: *Sim, crowd: Crowd, r: std.Random) void {
        self.crowd = crowd;
        self.slots = crowd.slots;
        self.n_clients = crowd.clients;
        self.table = tcp.Table.init(server_ip, server_mac, 80, self.conns[0..self.slots], &self.out, simIsn);
        if (revival_cap) |cap| self.table.revival_cap = cap;
        for (0..crowd.clients) |i| {
            const c = self.clientAt(i);
            if (i > 0) c.* = Client.init(r.int(u32));
            c.index = i;
            c.port = client_port + @as(u16, @intCast(i));
            c.request_len = crowd.request_len[i];
            c.answer_len = crowd.answer_len[i] + crowd.streamLen(i);
            c.asks = crowd.asks[i];
            c.half_close = i == 0 and self.sc.half_close and c.asks == 1 and crowd.stream != 0;
            c.open_at = crowd.gap_ns * @as(i96, @intCast(i));
        }
        // What the first client asks is the scenario's, for the report.
        self.sc.request_len = self.client.request_len;
        self.sc.answer_len = self.client.answer_len;
        self.sc.half_close = self.client.half_close;
    }

    pub fn clientAt(self: *Sim, i: usize) *Client {
        return if (i == 0) &self.client else &self.others[i - 1];
    }

    fn clientAtConst(self: *const Sim, i: usize) *const Client {
        return if (i == 0) &self.client else &self.others[i - 1];
    }

    /// **KARN'S RULE, CHECKED FROM OUTSIDE** (metal-vmm QUEUE 93, mutant
    /// T14): a segment the table sends again over bytes it is timing must
    /// find the timer already stopped. Otherwise the acknowledgement that
    /// follows is taken as a sample, and nobody can tell which copy it
    /// answers. The frame is read here as the wire carries it, before the
    /// network can lose or delay it.
    fn karn(self: *Sim, frame: []const u8) void {
        const at = tcp.segment_at;
        if (frame.len < at + tcp.header_len) return;
        const t = frame[at..];
        const ip_len: usize = proto.readBe16(frame[proto.eth_header_len + 2 ..][0..2]);
        const offset = @as(usize, t[12] >> 4) * 4;
        if (ip_len -| proto.ip_header_len <= offset or t[13] & tcp.flag_syn != 0) return; // no data
        const port = proto.readBe16(t[2..4]);
        const seq = proto.readBe32(t[4..8]);
        const to = frame[proto.eth_header_len + 16 ..][0..4];
        for (self.table.conns) |c| {
            if (c.state == .closed or c.peer_port != port or !std.mem.eql(u8, &c.peer_ip, to)) continue;
            if (seq -% c.una >= c.high) return; // sent for the first time
            const timed = c.timed_at != null and seqLt(seq, c.timed_seq);
            props.always(@src(), !timed, "tcp_sim: a segment sent again is never timed (Karn)", .{ .port = port });
            props.reachable(@src(), "tcp_sim: the table sends a segment again", null);
            if (timed) self.fault("a segment sent again while it was timed (Karn)");
            return;
        }
    }

    fn fault(self: *Sim, what: []const u8) void {
        if (self.broken == null) self.broken = what;
    }

    fn checkTable(self: *Sim, phase: invariants.Phase) void {
        if (invariants.check(&self.table, self.now, phase)) |v| {
            std.debug.print("seed {d}: invariant broken {s}, connection {d}, at {d} ms: {s}\n", .{
                self.seed, @tagName(phase), v.conn, @divTrunc(self.now, ns_per_ms), v.rule.says(),
            });
            self.fault("a tcp_check.zig invariant");
        }
    }

    /// The next flood SYN, when it is due: from an address and port of its
    /// own, which the client's port filter ignores the answers to.
    fn flood(self: *Sim) void {
        if (self.flooded >= self.rough.flood) return;
        if (self.now < self.rough.flood_at + self.rough.flood_gap * self.flooded) return;
        const k = self.flooded;
        self.flooded += 1;
        props.reachable(@src(), "tcp_sim: a flood SYN is sent", .{ .k = k });
        var buf: [1600]u8 = undefined;
        const ip = [4]u8{ 10, 0, 3, 10 + k };
        const len = tcp.header_len;
        const frame_len = proto.writeIpv4(&buf, .{ .mac = client_mac, .ip = ip }, .{ .mac = server_mac, .ip = server_ip }, proto.proto_tcp, len);
        const t = buf[tcp.segment_at..][0..len];
        @memcpy(t[0..2], &proto.be16(50_000 + @as(u16, k)));
        @memcpy(t[2..4], &proto.be16(80));
        @memcpy(t[4..8], &proto.be32(self.rng.int(u32)));
        @memcpy(t[8..12], &proto.be32(0));
        t[12] = @intCast((len / 4) << 4);
        t[13] = tcp.flag_syn;
        @memcpy(t[14..16], &proto.be16(0xFFFF));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(ip, server_ip, proto.proto_tcp, t)));
        self.net.send(self.rng, &self.sc, self.now, true, buf[0..frame_len]);
    }

    /// The slot holding client `i`'s connection, if one does.
    fn slotOf(self: *const Sim, i: usize) ?usize {
        const port = self.clientAtConst(i).port;
        for (self.table.conns, 0..) |c, k| {
            if (c.state != .closed and c.peer_port == port and std.mem.eql(u8, &c.peer_ip, &client_ip)) return k;
        }
        return null;
    }

    /// Every client's `slotOf`, into `out[0..n_clients]`, in one pass over
    /// the table: a crowd's client `i` has the port `client_port + i`, so a
    /// slot's port names its client, and the first slot found for it is
    /// `slotOf`'s. Clients times slots, every frame, was nearly all of a
    /// full table's run (metal-vmm QUEUE 203(d)).
    fn slotsOf(self: *const Sim, out: *[max_clients]?usize) void {
        out.* = @splat(null);
        if (self.crowd == null) {
            for (0..self.n_clients) |i| out[i] = self.slotOf(i);
            return;
        }
        for (self.table.conns, 0..) |c, k| {
            if (c.state == .closed or !std.mem.eql(u8, &c.peer_ip, &client_ip)) continue;
            if (c.peer_port < client_port) continue;
            const i: usize = c.peer_port - client_port;
            if (i >= self.n_clients or self.clientAtConst(i).port != c.peer_port) continue;
            if (out[i] == null) out[i] = k;
        }
        if (self.slots_checked) |n| {
            // Every 16th call: each one is the cost this pass removes.
            if (n % 16 == 0) for (0..self.n_clients) |i| std.debug.assert(out[i] == self.slotOf(i));
            @constCast(self).slots_checked = n + 1;
        }
    }

    fn quiescent(self: *const Sim) bool {
        for (self.table.conns) |c| if (c.state != .closed) return false;
        return true;
    }

    fn over(self: *const Sim) bool {
        if (self.flooded < self.rough.flood) return false;
        if (self.crowd != null) {
            for (0..self.n_clients) |i| {
                const c = self.clientAtConst(i);
                if (!c.opened or !(c.gone or c.state == .closed)) return false;
            }
            return self.server.idle() and self.quiescent() and self.net.count == 0;
        }
        const client_done = self.client.gone or self.client.state == .closed;
        return client_done and (self.host.finished or self.host.let_go or self.host.slot == null) and
            self.quiescent() and self.net.count == 0;
    }

    fn run(self: *Sim) !void {
        self.client.open(self);
        var buf: [1600]u8 = undefined;
        while (self.now < horizon_ns and self.broken == null and !self.over()) {
            ev.count += 1;
            self.now += tick_ns;
            self.flood();
            for (1..self.n_clients) |i| {
                const c = self.clientAt(i);
                if (!c.opened and self.now >= c.open_at) c.open(self);
            }
            var wire = TableWire{ .sim = self };
            const refused = self.table.refused;
            while (self.net.take(self.now, &buf)) |p| {
                ev.count += 1;
                if (p.to_table) {
                    const given_way = self.table.half_open_given_way;
                    var half_open: [max_clients]?usize = undefined;
                    self.slotsOf(&half_open);
                    for (half_open[0..self.n_clients]) |*h| if (h.*) |k| {
                        if (self.table.conns[k].state != .syn_received) h.* = null;
                    };
                    _ = self.table.handle(&wire, p.frame, self.now);
                    if (self.table.half_open_given_way != given_way) for (0..self.n_clients) |i| if (half_open[i]) |k| {
                        if (self.table.conns[k].peer_port != self.clientAtConst(i).port) {
                            self.given_way_on[i] += 1;
                            props.reachable(@src(), "tcp_sim: a real client's half-open slot gives way to another's SYN", .{ .client = i });
                        }
                    };
                    self.checkTable(.after_handle);
                } else for (0..self.n_clients) |i| self.clientAt(i).receive(self, p.frame);
            }
            if (self.crowd != null and self.table.refused != refused)
                props.reachable(@src(), "tcp_sim: a crowd's SYN finds every slot taken", .{ .slots = self.slots });
            for (0..self.n_clients) |i| self.clientAt(i).turn(self);
            if (self.crowd != null) self.server.turn(self) else self.host.turn(self);
            self.checkTable(.after_handle);
            // Give-ups happen only in `transmit`: one that closes a client's
            // slot is a give-up on that client.
            const given_up = self.table.given_up;
            var mine: [max_clients]?usize = undefined;
            self.slotsOf(&mine);
            self.table.transmit(&wire, self.now);
            if (self.table.given_up != given_up) for (0..self.n_clients) |i| if (mine[i]) |k| {
                if (self.table.conns[k].state == .closed) {
                    self.given_up_on[i] += 1;
                    if (i == 0) self.client_given_up += 1;
                    props.reachable(@src(), "tcp_sim: the table alone gives up on a client that left", .{ .seed = self.seed });
                }
            };
            self.checkTable(.after_transmit);
        }
        try self.judge();
    }

    /// **EVERY CLIENT THAT STAYED GOT ITS WHOLE ANSWER**: a crowd's, each of
    /// them, the held stream's to its end, and none given up on. The first
    /// client's own is judged as a plain seed's is (`judge`), but for what
    /// the host read, which a crowd's host counts per client.
    fn judgeCrowd(self: *Sim) void {
        var all = true;
        for (0..self.n_clients) |i| {
            if (self.broken != null) return;
            const c = self.clientAtConst(i);
            const left = i == 0 and (self.sc.vanish_at != null or c.gone or c.reset_sent);
            if (left) {
                all = false;
                continue;
            }
            if (c.aborted and self.given_way_on[i] != 0) {
                self.fault("a crowd's client was reset after its half-open slot gave way to another's SYN (item 24's class)");
            } else if (c.aborted) {
                self.fault("a crowd's client that stayed was reset");
            } else if (c.received != c.answer_len or !c.peer_fin) {
                self.fault("a crowd's client that stayed did not get its whole answer and our FIN");
            } else if (self.server.consumed[i] != c.request_len) {
                self.fault("the host did not read a crowd's client's whole request");
            } else if (self.given_up_on[i] != 0 or self.server.let_go[i]) {
                self.fault("the table or the host gave up on a crowd's client that stayed");
            } else if (c.done_at == null or c.done_at.? > completion_bound_ns) {
                self.fault("a crowd's client did not finish within the completion bound");
            }
        }
        if (self.broken == null and all and self.crowd.?.stream != null)
            props.reachable(@src(), "tcp_sim: a held stream's client got the whole stream among others", .{ .clients = self.n_clients });
        if (self.broken == null and all)
            props.reachable(@src(), "tcp_sim: every client of a crowd got its whole answer", .{ .clients = self.n_clients, .slots = self.slots });
    }

    fn judge(self: *Sim) !void {
        if (self.broken == null and !self.quiescent())
            self.fault("the table still holds a connection at the horizon");
        // A client that left on purpose is owed no answer; a reset it was
        // dealt is still a fault, unless it left first.
        const stayed = self.sc.vanish_at == null and !self.client.gone and !self.client.reset_sent;
        if (self.broken == null and stayed and self.crowd == null) {
            const c = &self.client;
            if (c.aborted) {
                self.fault("the connection was reset though the client stayed");
            } else if (c.received != self.sc.answer_len or !c.peer_fin) {
                self.fault("the client did not get the whole answer and our FIN");
            } else if (self.host.consumed != self.sc.request_len) {
                self.fault("the host did not read the whole request");
            } else if (self.client_given_up != 0) {
                self.fault("the table gave up on a client that stayed");
            } else if (c.done_at == null or c.done_at.? > completion_bound_ns) {
                self.fault("the exchange did not finish within the completion bound");
            }
        }
        if (self.crowd != null) self.judgeCrowd();
        if (self.broken == null and stayed and self.rough.flood > 0)
            props.reachable(@src(), "tcp_sim: a client that stayed through a flood got its whole answer", .{ .given_way = self.table.half_open_given_way });
        const what = self.broken orelse return;
        if (self.quiet) return error.SimulationFailed;
        const sc = self.sc;
        std.debug.print(
            \\seed {d} failed: {s}
            \\  scenario: request {d} B, answer {d} B, loss {d:.2} until {d} ms, duplicate {d:.2}, corrupt {d:.2},
            \\            delay {d} us + {d} us jitter, delayed ACK {d} ms, half-close {any}, host stalls {d} ms,
            \\            client stalls {d} ms, vanishes {?d} ms, host announces {any}
            \\
        , .{
            self.seed,                                                 what,
            sc.request_len,                                            sc.answer_len,
            sc.loss,                                                   @divTrunc(sc.lossy_until, ns_per_ms),
            sc.duplicate,                                              sc.corrupt,
            @divTrunc(sc.delay_ns, 1000),                              @divTrunc(sc.jitter_ns, 1000),
            @divTrunc(sc.delayed_ack_ns, ns_per_ms),                   sc.half_close,
            @divTrunc(sc.host_stall_ns, ns_per_ms),                    @divTrunc(sc.client_stall_ns, ns_per_ms),
            if (sc.vanish_at) |at| @divTrunc(at, ns_per_ms) else null, sc.host_announces,
        });
        // Two calls: one holds at most 32 arguments.
        std.debug.print(
            \\  at {d} ms: client {s} (aborted {any}, gone {any}), received {d}, peer FIN {any}, probes {d};
            \\            host read {d}, queued {d}, finished {any}, let go {any};
            \\            table given up {d}, retransmits {d}, probes {d}, window updates {d}, damaged {d};
            \\            network sent {d}, lost {d}, duplicated {d}, corrupted {d}, overflowed {d}
            \\
        , .{
            @divTrunc(self.now, ns_per_ms), @tagName(self.client.state),
            self.client.aborted,            self.client.gone,
            self.client.received,           self.client.peer_fin,
            self.client.probes,             self.host.consumed,
            self.host.queued,               self.host.finished,
            self.host.let_go,               self.table.given_up,
            self.table.retransmits,         self.table.probes,
            self.table.window_updates,      self.table.damaged,
            self.net.sent,                  self.net.lost,
            self.net.duplicated,            self.net.corrupted,
            self.net.overflowed,
        });
        const r = self.rough;
        std.debug.print(
            \\  rough: reset at {?d} ms (+{d}, sent {any}), vanish after {?d} B, flood {d} SYNs from {d} ms every {d} ms; given way {d}, refused {d}
            \\
        , .{
            if (r.reset_at) |at| @divTrunc(at, ns_per_ms) else null, r.reset_off,
            self.client.reset_sent,                                  r.vanish_after,
            r.flood,                                                 @divTrunc(r.flood_at, ns_per_ms),
            @divTrunc(r.flood_gap, ns_per_ms),                       self.table.half_open_given_way,
            self.table.refused,
        });
        return error.SimulationFailed;
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
/// explore.zig): which peer the table meets is a named choice (a plain
/// client, a rougher one, a crowd, a crowd the size of the kernel's table),
/// and every draw after it, the network's and each client's, comes from
/// `tape`. The four `run...Seed`s draw a rough peer or a crowd from
/// generators of their own so that a plain seed's run never changes; here one
/// tape is the whole story.
pub fn runWith(tape: *explore.Tape) !void {
    return runWithIn(std.testing.allocator, std.testing.io, tape);
}

/// `runWith`, with the allocator a program gives it (the explorer's bench
/// and soak, metal-vmm QUEUE 106), and an `Io` as the other simulators take
/// one (this one needs none): the same run.
pub fn runWithIn(gpa: std.mem.Allocator, io: std.Io, tape: *explore.Tape) !void {
    _ = io;
    const r = tape.random();
    const peer = explore.pick(r, "tcp_sim: the peer", .{ .plain = 3, .rough = 2, .crowd = 2, .full = 1 });
    const sim = try gpa.create(Sim);
    defer gpa.destroy(sim);
    sim.seed = tape.seed;
    sim.prng = std.Random.DefaultPrng.init(tape.seed);
    sim.rng = r;
    sim.sc = Scenario.choose(r);
    sim.build();
    switch (peer) {
        .plain => try sim.run(),
        .rough => {
            sim.rough = Rough.choose(r, &sim.sc);
            try sim.run();
        },
        .crowd => {
            sim.withCrowd(Crowd.choose(r), r);
            try runCrowded(sim);
        },
        .full => {
            sim.withCrowd(Crowd.chooseFull(r), r);
            try runCrowded(sim);
            fullTableRefused(sim);
        },
    }
}

test "a run under a tape is a function of its tape: replayed whole, it draws the same" {
    for (0..12) |seed| {
        var first = explore.Tape.init(std.testing.allocator, seed);
        defer first.deinit();
        try runWith(&first);
        var again = explore.Tape.branch(std.testing.allocator, &first, first.position(), seed +% 0x9999, null);
        defer again.deinit();
        try runWith(&again);
        try std.testing.expect(!again.drifted);
        try std.testing.expectEqual(first.position(), again.position());
    }
}

/// The same seed with a rougher peer (`Rough`).
pub fn runRoughSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.initRough(seed);
    try sim.run();
}

/// The same seed's network with a crowd (`Crowd`): several clients, a table
/// sized by the seed, keep-alive and a held stream.
pub fn runCrowdSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.initCrowd(seed);
    try runCrowded(sim);
}

/// The same seed's network with a crowd the size of the kernel's table
/// (`Crowd.chooseFull`, metal-vmm QUEUE item 72).
pub fn runFullSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.initFull(seed);
    try runCrowded(sim);
    fullTableRefused(sim);
}

/// One coverage site for both ways a full table is run (`runFullSeed`,
/// `runWith`): a second site with the same message is a second property, and
/// one that only the soak reaches leaves long.sh's floor short of it.
fn fullTableRefused(sim: *const Sim) void {
    if (sim.table.refused > 0) props.reachable(@src(), "tcp_sim: a crowd the size of the kernel's table fills it, and a SYN finds no room", .{ .slots = sim.crowd.?.slots });
}

fn runCrowded(sim: *Sim) !void {
    sim.run() catch |e| {
        const c = sim.crowd.?;
        std.debug.print("  crowd: {d} clients {d} ms apart, {d} slots; requests {any}, answers {any}, asks {any}; stream {?d}: {d} chunks of {d} B every {d} ms\n", .{
            c.clients,                             @divTrunc(c.gap_ns, ns_per_ms), c.slots,
            c.request_len[0..c.clients],           c.answer_len[0..c.clients],     c.asks[0..c.clients],
            c.stream,                              c.stream_chunks,                c.stream_chunk,
            @divTrunc(c.stream_gap_ns, ns_per_ms),
        });
        for (0..sim.n_clients) |i| {
            const cl = sim.clientAtConst(i);
            std.debug.print("  client {d}: {s} (aborted {any}, gone {any}), received {d} of {d}, peer FIN {any}; host read {d}, queued {d}, finished {any}, let go {any}; given up {d}\n", .{
                i,                    @tagName(cl.state),     cl.aborted,           cl.gone,
                cl.received,          cl.answer_len,          cl.peer_fin,          sim.server.consumed[i],
                sim.server.queued[i], sim.server.finished[i], sim.server.let_go[i], sim.given_up_on[i],
            });
        }
        return e;
    };
}

pub const Mode = enum { plain, rough, crowd, full };

/// One seed's run in `mode` with the revival ring at `cap` (null: the
/// kernel's): whether every oracle held, the frames' trace, and how often
/// a half-open gave way.
pub fn traceOf(seed: u64, mode: Mode, cap: ?u16) !struct { ok: bool, trace: u64, given_way: u64, revived: u64 } {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    const was = revival_cap;
    revival_cap = cap;
    defer revival_cap = was;
    switch (mode) {
        .plain => sim.init(seed),
        .rough => sim.initRough(seed),
        .crowd => sim.initCrowd(seed),
        .full => sim.initFull(seed),
    }
    sim.quiet = true;
    const ok = if (sim.run()) true else |_| false;
    return .{ .ok = ok, .trace = sim.net.trace.final(), .given_way = sim.table.half_open_given_way, .revived = sim.table.revived };
}

/// The seeds `zig build test` runs. A seed that once failed and was fixed
/// stays here, named, as a regression test.
const seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ regressions;

/// Seeds that once failed, kept apart from the eight plain ones so that
/// `zig fmt` keeps one to a line, each under the comment that names it.
const regressions = [_]u64{
    // A half-closed client: the table re-marked a window as owed after the
    // peer's FIN, every turn it sent data (fixed in tcp.zig's emit).
    125,
    // Heavy reordering, when this client took segments in order only: every
    // round ended on the 5 s backed-off timer, and Karn's rule threw away the
    // round's only sample. The client now holds segments past a hole.
    1332,
    // The client's last ACK lost, and the table's backed-off FIN reaching it
    // after its TIME-WAIT: a closed client said nothing, so the table gave
    // up on a client that had the whole answer. It now answers with a reset.
    23953,
};

test "the table against a simulated network and an RFC 9293 client, a handful of seeds" {
    for (seeds) |seed| try runSeed(seed);
}

/// The rough seeds `zig build test` runs (`Rough`): the plain eight again,
/// each with a peer that resets, vanishes part-way or floods. `zig build
/// properties` sweeps hundreds.
const rough_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };

test "the same, with a peer that resets, vanishes part-way, or floods the table with SYNs" {
    for (rough_seeds) |seed| try runRoughSeed(seed);
}

/// The crowd seeds `zig build test` runs (`Crowd`); `zig build properties`
/// sweeps hundreds.
const crowd_seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };

test "several clients, a table sized by the seed, keep-alive and a held stream" {
    for (crowd_seeds) |seed| try runCrowdSeed(seed);
}

/// **ITEM 24'S CLASS, AND REVIVAL** (REVIEW-flood.md option 4, QUEUE.md
/// item 47). Each of these seeds failed one way before revival: a real
/// client's handshake, slowed past `min_rto_ns` by a lost SYN-ACK or ACK
/// while every slot was taken, looked to the table like a flood's stuck
/// half-open; another SYN took its slot (`oldestHalfOpen`), and its next
/// segment drew a reset. The rough ones are every failure of the first
/// 50,000 rough seeds (a flood's SYN took the slot), the crowd ones every
/// failure of the first 10,000 crowd seeds (another client's). With
/// revival, the client's ACK rebuilds its half-open, and each passes; with
/// the ring turned off (`revival_cap` 0) each fails as it did.
const rough_red = [_]u64{ 11277, 11529, 13514, 16190, 20063, 20615, 22509, 25720, 32011, 38526, 41147, 43082, 48515, 48671 };
// **FIVE LEFT THIS LIST WITH metal-vmm QUEUE 133** (1733, 6918, 7374, 7968,
// 9728): without the ring each failed by fast retransmits that old
// acknowledgements set off. With a duplicate held to SND.UNA (RFC 5681 §2)
// each passes either way, so none witnesses the ring any more. Every rough
// seed still fails without it. **6307 LEFT WITH KARN ON THE SYN-ACK**: a
// SYN-ACK sent again is no longer timed, so its first RTO is not the whole
// timeout, and without the ring it passes too.
// **FOUR LEFT WITH RFC 6298 (5.4)** (640, 1961, 2870, 6606; metal-vmm QUEUE
// 225, chunk 0a): a timeout sends one segment again, not the window, so each
// crowd's frames change, and these four pass with the ring off as well as
// on. None witnesses the ring any more. **FOUR MORE WITH FAST RETRANSMIT
// SENDING ONE SEGMENT** (4362, 8003, 8575, 9366; chunk 0b), the same way.
// **TWO MORE WITH THE HELD PIECES** (2305, 9769; metal-vmm QUEUE 226): a
// segment ahead of a hole is held, not dropped, so these crowds pass with
// the ring off as well as on. The five left still fail without it.
const crowd_red = [_]u64{ 1281, 1452, 1872, 7546, 9951 };

test "a crowd the size of the kernel's table: every oracle holds, and the table fills" {
    // **ONE IN TIER 0** (metal-vmm QUEUE 198.12): 1.7 s in Debug each
    // then, 0.35 s since `slotsOf` (203(d));
    // `zig build properties` and long.sh sweep the full table's seeds.
    for (1..2) |seed| try runFullSeed(seed);
}

test "revival: item 24's seeds, rough and crowded, pass; with the ring off, each fails as before" {
    for (rough_red) |seed| {
        try runRoughSeed(seed);
        const off = try traceOf(seed, .rough, 0);
        try std.testing.expect(!off.ok);
        // With it, a revival, or an ACK it matched dropped for want of
        // room rather than reset (seed 20063), and the client carries on.
        const on = try traceOf(seed, .rough, null);
        try std.testing.expect(on.ok and on.given_way > 0);
    }
    for (crowd_red) |seed| {
        try runCrowdSeed(seed);
        const off = try traceOf(seed, .crowd, 0);
        try std.testing.expect(!off.ok);
    }
}

test "revival changes nothing where nothing gave way: the same frames, with the ring or without" {
    // **FIVE SEEDS IN TIER 0** (metal-vmm QUEUE 198.11, 203(d)): forty were
    // 4 s in Debug, and each seed is the same check, three modes run twice.
    for (1..6) |seed| {
        for ([_]Mode{ .plain, .rough, .crowd }) |mode| {
            const on = try traceOf(seed, mode, null);
            const off = try traceOf(seed, mode, 0);
            if (on.given_way == 0) try std.testing.expectEqual(off.trace, on.trace);
        }
    }
}

// **THE LOST-FRAME IncompleteRead, HUNTED** (QUEUE.md item 96). The bug was
// seen once in nine FAT32 runs of the bulk story with one frame in seven lost:
// the client got 2,820 of 4,895 bytes and then end-of-stream. Here, where loss
// and time are ours, a few-KB answer the host closes after is run under every
// placement of a single lost frame to the client in the first 20 it sends,
// with ACKs delayed and frames reordered. The completion oracle in judge
// catches exactly the reported failure — a short answer, or a FIN/close with
// data still owed, or a give-up/reset on a client that stayed. A failing n
// is the repro; a clean sweep says the bug is not a single lost frame in this
// shape, and the box reads a wire capture under KVM (the bulk story carries
// the per-connection close counts it needs).
test "every client's slot in one pass is each client's own lookup's: a crowd and a full table, compared every 16th frame" {
    for ([_]bool{ false, true }) |full| {
        const sim = try std.testing.allocator.create(Sim);
        defer std.testing.allocator.destroy(sim);
        if (full) sim.initFull(1) else sim.initCrowd(3);
        sim.slots_checked = 0;
        try runCrowded(sim);
        try std.testing.expect(sim.slots_checked.? > 160);
    }
}

test "every 13th frame to the client lost, against a window of 13 segments: the table recovers, never phase-locked (RFC 6298 (5.4); metal-vmm QUEUE 225, chunk 0a)" {
    // The native judge's GM_LOSE_SENT=13 against a go-back: each timeout
    // resent the same 13-segment window, so with the loss aligned on its
    // head the same frame was lost every time, until the retries ran out
    // (`given_up`). Sending only the oldest segment after a timeout breaks
    // the lock. Every alignment of the loss against the window is tried.
    for ([_]usize{ 60_000, 13 * client_mss * 3 }) |answer| {
        for (0..13) |phase| {
            const sim = try std.testing.allocator.create(Sim);
            defer std.testing.allocator.destroy(sim);
            var sc = Scenario.fixed(answer, null, true);
            sc.drop_every_to_client = 13;
            sc.drop_every_phase = phase;
            sc.client_buffer = 13 * client_mss;
            sim.initScenario(225_000 + answer, sc);
            sim.run() catch |e| {
                std.debug.print("every 13th frame lost, answer {d} B, phase {d}: the table did not recover (given up {d})\n", .{ answer, phase, sim.table.given_up });
                return e;
            };
            try std.testing.expectEqual(@as(u64, 0), sim.table.given_up);
        }
    }
}

test "item 96: one lost frame to the client, swept over the first 20, always recovers" {
    for ([_]bool{ true, false }) |announces| {
        for ([_]usize{ 3000, 4895, 16000 }) |answer| {
            for (0..20) |n| {
                const sim = try std.testing.allocator.create(Sim);
                defer std.testing.allocator.destroy(sim);
                sim.initScenario(90_000 + n, Scenario.fixed(answer, @intCast(n), announces));
                sim.run() catch |e| {
                    std.debug.print("item 96: dropping frame #{d} to the client (answer {d} B, announces {any}) did not recover\n", .{ n, answer, announces });
                    return e;
                };
            }
        }
    }
}

test "what arrives out of order is counted: ahead of the next byte, and from behind (metal-vmm QUEUE 193.4)" {
    var ahead: u64 = 0;
    var behind: u64 = 0;
    for (1..41) |seed| {
        const sim = try std.testing.allocator.create(Sim);
        defer std.testing.allocator.destroy(sim);
        sim.init(seed);
        try sim.run();
        ahead += sim.table.arrived_ahead;
        behind += sim.table.arrived_behind;
    }
    // The simulated network loses, reorders and duplicates: over forty
    // seeds a segment arrives ahead of a lost one, and a resend from behind.
    try std.testing.expect(ahead > 0);
    try std.testing.expect(behind > 0);
}

// **THE FLOORS KEY ON THESE STRINGS** (metal-vmm QUEUE 225, chunk 1): every
// `tcp: ` property in the coverage catalog, against coverage/tcp-strings.txt,
// so the tcp.zig reshaping (chunks 2-4) cannot rename one by accident and
// leave a floor line naming nothing. A string changed on purpose is changed
// in the file, and in any floor that names it, in the same commit.
test "every tcp: property string is the one the floors know, and none is missing or new" {
    const coverage = @import("coverage");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var have: std.ArrayList([]const u8) = .empty;
    defer have.deinit(gpa);
    var it = coverage.catalog();
    while (it.next()) |site| {
        const m = std.mem.span(site.message);
        if (!std.mem.startsWith(u8, m, "tcp: ")) continue;
        for (have.items) |h| {
            if (std.mem.eql(u8, h, m)) break;
        } else try have.append(gpa, m);
    }
    std.mem.sort([]const u8, have.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "coverage/tcp-strings.txt", gpa, .unlimited);
    defer gpa.free(text);
    var want: std.ArrayList([]const u8) = .empty;
    defer want.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| if (l.len > 0 and l[0] != '#') try want.append(gpa, l);
    var wrong: usize = 0;
    for (want.items) |w| {
        for (have.items) |h| {
            if (std.mem.eql(u8, h, w)) break;
        } else {
            wrong += 1;
            std.debug.print("tcp-strings.txt names no property: {s}\n", .{w});
        }
    }
    for (have.items) |h| {
        for (want.items) |w| {
            if (std.mem.eql(u8, h, w)) break;
        } else {
            wrong += 1;
            std.debug.print("a tcp: property not in tcp-strings.txt: {s}\n", .{h});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
