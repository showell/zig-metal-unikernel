//! The TCP table's tests: a fake peer on the other end of a recording wire.
//! Every test drives the table with the frames a real client would send and
//! reads back the frames the table sent, checking the sequence numbers a real
//! client would check.

const std = @import("std");
const props = @import("coverage");
const proto = @import("proto.zig");
const tcp = @import("tcp.zig");
const invariants = @import("tcp_check.zig");

const Conn = tcp.Conn;
const Table = tcp.Table;
const Result = tcp.Result;
const Event = tcp.Event;
const State = tcp.State;
const header_len = tcp.header_len;
const segment_at = tcp.segment_at;
const flag_fin = tcp.flag_fin;
const flag_syn = tcp.flag_syn;
const flag_rst = tcp.flag_rst;
const flag_psh = tcp.flag_psh;
const flag_ack = tcp.flag_ack;
const mss_option = tcp.mss_option;
const parseMss = tcp.parseMss;
const first_rto_ns = tcp.first_rto_ns;
const min_rto_ns = tcp.min_rto_ns;
const max_retries = tcp.max_retries;
const ns_per_ms = tcp.ns_per_ms;
const ns_per_s = tcp.ns_per_s;

const testing = std.testing;

const server_ip = [4]u8{ 10, 0, 2, 15 };
const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const client_mac = [6]u8{ 0x52, 0x55, 0x0a, 0, 2, 2 };

/// The wire, recording what the table sent.
const Wire = struct {
    frames: [128][1600]u8 = undefined,
    lens: [128]usize = undefined,
    count: usize = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        @memcpy(self.frames[self.count][0..frame.len], frame);
        self.lens[self.count] = frame.len;
        self.count += 1;
    }

    const Seg = struct { src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16, options: []const u8, payload: []const u8 };

    fn last(self: *Wire) Seg {
        return self.at(self.count - 1);
    }

    fn at(self: *Wire, k: usize) Seg {
        const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]).?;
        const t = pkt.payload;
        const offset = @as(usize, t[12] >> 4) * 4;
        return .{
            .src_port = proto.readBe16(t[0..2]),
            .dst_port = proto.readBe16(t[2..4]),
            .seq = proto.readBe32(t[4..8]),
            .ack = proto.readBe32(t[8..12]),
            .flags = t[13],
            .window = proto.readBe16(t[14..16]),
            .options = t[header_len..offset],
            .payload = t[offset..],
        };
    }

    /// The segments sent since `from`, with their payload lengths.
    fn sizesSince(self: *Wire, from: usize, buf: []usize) []usize {
        for (from..self.count, 0..) |k, n| buf[n] = self.at(k).payload.len;
        return buf[0 .. self.count - from];
    }

    /// The window in the last segment, other than a reset, this machine
    /// sent from `from` to `ip`:`port`, or null if it has sent none. All
    /// four name the connection: two of ours may share the peer's half.
    fn lastWindowTo(self: *Wire, ip: [4]u8, port: u16, from: u16) ?u16 {
        var k = self.count;
        while (k > 0) {
            k -= 1;
            const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]) orelse continue;
            if (!std.mem.eql(u8, &pkt.dst_ip, &ip)) continue;
            const s = self.at(k);
            if (s.dst_port != port or s.src_port != from or s.flags & flag_rst != 0) continue;
            return s.window;
        }
        return null;
    }

    /// The checksum a real peer would verify, recomputed.
    fn checksumOk(self: *Wire, k: usize) bool {
        const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]).?;
        return proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, pkt.payload) == 0;
    }
};

/// **EVERY STEP A TEST TAKES IS CHECKED** (TCP_TESTING.md §1). Tests drive
/// the table through these two rather than its own methods, and after each
/// one every slot is held to tcp_check.zig's rules: the bookkeeping agrees
/// with itself, and everything a connection owes has a deadline that will
/// see it done. So every scenario below is also a test of every invariant,
/// at every step it takes.
///
/// A broken invariant is a bug in the table, not an outcome a test can
/// expect, so it stops the run with the rule, the connection and the time;
/// the stack trace names the step.
fn handle(table: *Table, wire: *Wire, frame: []const u8, now: i96) Result {
    const r = table.handle(wire, frame, now);
    verify(table, wire, now, .after_handle);
    return r;
}

fn transmit(table: *Table, wire: *Wire, now: i96) void {
    table.transmit(wire, now);
    verify(table, wire, now, .after_transmit);
}

fn verify(table: *Table, wire: *Wire, now: i96, phase: invariants.Phase) void {
    if (invariants.check(table, now, phase)) |v| {
        std.debug.panic("TCP invariant broken {s}, connection {d}, at {d} ns: {s} ({s})", .{
            @tagName(phase), v.conn, now, v.rule.says(), @tagName(v.rule),
        });
    }
    // What the table believes it told each peer is what the wire carried.
    for (table.conns, 0..) |*c, i| {
        if (c.state == .closed) continue;
        const said = wire.lastWindowTo(c.peer_ip, c.peer_port, c.local_port) orelse continue;
        if (said != c.told_wnd) {
            std.debug.panic("TCP invariant broken {s}, connection {d}, at {d} ns: told_wnd is {d}, but the last segment sent said {d}", .{
                @tagName(phase), i, now, c.told_wnd, said,
            });
        }
    }
}

/// **WHERE SEQUENCE NUMBERS START**, from build.zig: the suite runs once per
/// pair, near zero, half-way and the wrap (TCP_TESTING.md §6). Tests compare
/// sequence numbers only to each other, with `+%` and `-%`, never to a literal.
const start = @import("tcp_test_start");

/// The first initial sequence number each fixture hands out is `start.isn`,
/// and each after it 1000 further on.
var next_isn: u32 = 0;
fn fakeIsn() u32 {
    next_isn +%= 1000;
    return next_isn;
}

/// One client: an address, a port, and the sequence numbers it keeps.
const Peer = struct {
    ip: [4]u8,
    port: u16,
    seq: u32 = start.peer,
    ack: u32 = 0,
    window: u16 = 8192,
    /// The segment size its SYN says, if it says one.
    mss: ?u16 = null,
    /// Our port it sends to: the table's, or one of our own connections'.
    to_port: u16 = 80,

    fn frame(self: *const Peer, buf: []u8, flags: u8, seq: u32, data: []const u8) []const u8 {
        var options: [4]u8 = undefined;
        const olen: usize = if (flags & flag_syn != 0 and self.mss != null) 4 else 0;
        if (olen > 0) options = .{ 2, 4, @intCast(self.mss.? >> 8), @intCast(self.mss.? & 0xFF) };
        const len = header_len + olen;
        const frame_len = proto.writeIpv4(buf, .{ .mac = client_mac, .ip = self.ip }, .{ .mac = server_mac, .ip = server_ip }, proto.proto_tcp, len + data.len);
        const t = buf[segment_at..][0 .. len + data.len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(self.to_port));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(self.ack));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(self.window));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[header_len..len], options[0..olen]);
        @memcpy(t[len..], data);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.ip, server_ip, proto.proto_tcp, t)));
        return buf[0..frame_len];
    }

    /// SYN, then the ACK of the server's SYN-ACK. Returns the slot.
    fn connect(self: *Peer, table: *Table, wire: *Wire, now: i96) !usize {
        var buf: [1600]u8 = undefined;
        _ = handle(table, wire, self.frame(&buf, flag_syn, self.seq, ""), now);
        const synack = wire.last();
        try testing.expectEqual(flag_syn | flag_ack, synack.flags);
        try testing.expectEqual(self.seq +% 1, synack.ack);
        self.seq +%= 1;
        self.ack = synack.seq +% 1;
        const r = handle(table, wire, self.frame(&buf, flag_ack, self.seq, ""), now);
        try testing.expectEqual(Event.opened, r.event);
        return r.index;
    }

    fn write(self: *Peer, table: *Table, wire: *Wire, bytes: []const u8, now: i96) Result {
        var buf: [1600]u8 = undefined;
        const r = handle(table, wire, self.frame(&buf, flag_psh | flag_ack, self.seq, bytes), now);
        const reply = wire.last();
        self.seq = reply.ack; // what the server says it has
        return r;
    }

    fn fin(self: *Peer, table: *Table, wire: *Wire, now: i96) Result {
        var buf: [1600]u8 = undefined;
        return handle(table, wire, self.frame(&buf, flag_fin | flag_ack, self.seq, ""), now);
    }

    /// Acknowledges everything up to `number`, with the peer's window.
    fn ackUpTo(self: *Peer, table: *Table, wire: *Wire, number: u32, now: i96) Result {
        self.ack = number;
        var buf: [1600]u8 = undefined;
        return handle(table, wire, self.frame(&buf, flag_ack, self.seq, ""), now);
    }

    /// Acknowledges every byte the server has sent so far.
    fn ackAll(self: *Peer, table: *Table, wire: *Wire, now: i96) Result {
        const s = wire.last();
        const end = s.seq +% @as(u32, @intCast(s.payload.len)) +% @as(u32, if (s.flags & flag_fin != 0) 1 else 0);
        return self.ackUpTo(table, wire, end, now);
    }
};

const Fixture = struct {
    conns: [4]Conn = undefined,
    rx: [4][64]u8 = undefined,
    tx: [4][2048]u8 = undefined,
    out: [1600]u8 = undefined,
    wire: Wire = .{},
    table: Table = undefined,

    fn init(self: *Fixture) void {
        next_isn = start.isn -% 1000;
        for (&self.conns, &self.rx, &self.tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        self.table = Table.init(server_ip, server_mac, 80, &self.conns, &self.out, fakeIsn);
    }
};

const ms: i96 = ns_per_ms;
/// The first wait before sending again, whatever it is set to.
const rto: i96 = first_rto_ns;

/// A payload whose every byte says where it is.
fn pattern(buf: []u8) []u8 {
    for (buf, 0..) |*b, k| b.* = @truncate(k *% 7 +% k / 256);
    return buf;
}

test "a handshake, a request, and the bytes are there to read" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const r = p.write(&f.table, &f.wire, "GET / HTTP/1.1\r\n\r\n", 2);
    try testing.expectEqual(Event.data, r.event);
    try testing.expectEqual(i, r.index);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", f.table.conns[i].pending());
    try testing.expect(f.wire.checksumOk(f.wire.count - 1));
    try testing.expectEqual(@as(i96, 1), f.table.conns[i].opened_at);
    try testing.expectEqual(@as(i96, 2), f.table.conns[i].heard_at);
}

test "two connections at once each keep their own bytes" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40001 };
    const ia = try a.connect(&f.table, &f.wire, 1);
    const ib = try b.connect(&f.table, &f.wire, 2);
    try testing.expect(ia != ib);
    _ = a.write(&f.table, &f.wire, "from a ", 3);
    _ = b.write(&f.table, &f.wire, "from b", 4);
    _ = a.write(&f.table, &f.wire, "again", 5);
    try testing.expectEqualStrings("from a again", f.table.conns[ia].pending());
    try testing.expectEqualStrings("from b", f.table.conns[ib].pending());
    // Arrival order is kept, for serving the oldest first.
    try testing.expect(f.table.conns[ia].serial < f.table.conns[ib].serial);
}

test "the same port from another address is another connection" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 40000 };
    const ia = try a.connect(&f.table, &f.wire, 1);
    const ib = try b.connect(&f.table, &f.wire, 1);
    try testing.expect(ia != ib);
}

test "a full table drops the SYN and counts it, and a freed slot is used again" {
    var f: Fixture = .{};
    f.init();
    var peers: [5]Peer = undefined;
    for (&peers, 0..) |*p, k| p.* = .{ .ip = .{ 10, 0, 2, 2 }, .port = @intCast(41000 + k) };
    var slots: [4]usize = undefined;
    for (peers[0..4], &slots) |*p, *s| s.* = try p.connect(&f.table, &f.wire, 1);

    var buf: [1600]u8 = undefined;
    const sent = f.wire.count;
    _ = handle(&f.table, &f.wire, peers[4].frame(&buf, flag_syn, peers[4].seq, ""), 2);
    try testing.expectEqual(sent, f.wire.count); // nothing answered
    try testing.expectEqual(@as(u64, 1), f.table.refused);

    f.table.abandon(&f.wire, slots[2], .slow_client);
    const again = try peers[4].connect(&f.table, &f.wire, 3);
    try testing.expectEqual(slots[2], again);
}

test "a slot the host holds is not given to a stranger, even after it closes" {
    var f: Fixture = .{};
    f.init();
    var peers: [5]Peer = undefined;
    for (&peers, 0..) |*p, k| p.* = .{ .ip = .{ 10, 0, 2, 2 }, .port = @intCast(42000 + k) };
    var slots: [4]usize = undefined;
    for (peers[0..4], &slots) |*p, *s| s.* = try p.connect(&f.table, &f.wire, 1);

    f.table.claim(slots[0]);
    // The peer resets the connection the host is part-way through serving.
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, peers[0].frame(&buf, flag_rst, peers[0].seq, ""), 2);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(State.closed, f.table.conns[slots[0]].state);

    // A new SYN finds no free slot: the closed one is still the host's.
    _ = handle(&f.table, &f.wire, peers[4].frame(&buf, flag_syn, peers[4].seq, ""), 3);
    try testing.expectEqual(@as(u64, 1), f.table.refused);

    f.table.release(slots[0]);
    try testing.expectEqual(slots[0], try peers[4].connect(&f.table, &f.wire, 4));
}

test "the window is the room left, and reading gives it back" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);

    _ = p.write(&f.table, &f.wire, "0123456789" ** 4, 2);
    try testing.expectEqual(@as(u16, 24), f.wire.last().window);

    f.table.conns[i].consume(40);
    f.table.ack(&f.wire, i);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);
}

test "a window that reopens is said again until the peer sends" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = p.write(&f.table, &f.wire, "0123456789" ** 6, 1);
    try testing.expectEqual(@as(u16, 4), f.wire.last().window); // shut, as far as the peer can tell

    // The reader takes it all and says so; say that announcement is lost.
    f.table.conns[i].consume(60);
    f.table.ack(&f.wire, i);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);
    var from = f.wire.count;
    transmit(&f.table, &f.wire, 2); // starts the clock, sends nothing
    try testing.expectEqual(from, f.wire.count);
    transmit(&f.table, &f.wire, 2 + rto);
    try testing.expectEqual(from + 1, f.wire.count);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);
    try testing.expectEqual(@as(u64, 1), f.table.window_updates);

    // The peer sends: it saw the window, and nothing more is said.
    _ = p.write(&f.table, &f.wire, "more", 3 + rto);
    from = f.wire.count;
    transmit(&f.table, &f.wire, 60 * ns_per_s);
    try testing.expectEqual(from, f.wire.count);
}

test "a reader that makes room without saying so is announced for it" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = p.write(&f.table, &f.wire, "0123456789" ** 6, 1);
    f.table.conns[i].consume(60);
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 2);
    try testing.expectEqual(from + 1, f.wire.count);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);
}

test "a peer with nothing more to say is told a bounded number of times" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = p.write(&f.table, &f.wire, "0123456789" ** 6, 1);
    f.table.conns[i].consume(60);
    f.table.ack(&f.wire, i);
    var now: i96 = 2;
    while (now < 120 * ns_per_s) : (now += 10 * ms) transmit(&f.table, &f.wire, now);
    try testing.expectEqual(@as(u64, max_retries), f.table.window_updates);
    try testing.expectEqual(State.established, f.table.conns[i].state);
}

test "a segment bigger than the room is taken in part, and the rest arrives after a read" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const body = "abcdefghij" ** 10; // 100 bytes into a 64-byte buffer

    var buf: [1600]u8 = undefined;
    const first = p.seq;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, first, body), 2);
    try testing.expectEqual(first +% 64, f.wire.last().ack); // only what fitted
    try testing.expectEqualStrings(body[0..64], f.table.conns[i].pending());

    // The peer sends the rest again from where the ACK said.
    f.table.conns[i].consume(64);
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, first +% 64, body[64..]), 3);
    try testing.expectEqual(first +% 100, f.wire.last().ack);
    try testing.expectEqualStrings(body[64..], f.table.conns[i].pending());
}

test "consuming part of a request compacts the buffer once the front is half gone" {
    var b: [16]u8 = undefined;
    var c = Conn{ .rx = &b, .tx = &.{} };
    @memcpy(b[0..12], "abcdefghijkl");
    c.end = 12;
    c.consume(3);
    try testing.expectEqual(@as(usize, 3), c.start); // not yet past half
    try testing.expectEqualStrings("defghijkl", c.pending());
    c.consume(6);
    try testing.expectEqual(@as(usize, 0), c.start); // compacted
    try testing.expectEqualStrings("jkl", c.pending());
    try testing.expectEqual(@as(usize, 13), c.room());
    c.consume(3);
    try testing.expectEqual(@as(usize, 16), c.room());
    // More than there is is the caller's bug, said (a property breaks, on
    // purpose here), and held to all of it (the normalization hunt).
    const Seen = struct {
        var n: usize = 0;
        fn count(_: *const props.Site) void {
            n += 1;
        }
    };
    const was = props.on_broken;
    props.on_broken = Seen.count;
    defer props.on_broken = was;
    Seen.n = 0;
    c.consume(5);
    try testing.expectEqual(@as(usize, 1), Seen.n);
    try testing.expectEqual(@as(usize, 0), c.pending().len);
}

test "a segment out of order is dropped and the right one asked for again" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq +% 5, "later"), 2);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len);
}

test "the peer's FIN leaves what it sent to be read, and we can still answer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    _ = p.write(&f.table, &f.wire, "GET / HTTP/1.1\r\n\r\n", 2);
    const r = p.fin(&f.table, &f.wire, 3);
    try testing.expectEqual(Event.peer_done, r.event);
    try testing.expect(f.table.conns[i].peerDone());
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", f.table.conns[i].pending());
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN acknowledged
    try testing.expectEqual(@as(usize, 19), f.table.queue(i, "HTTP/1.1 200 OK\r\n\r\n"));
    transmit(&f.table, &f.wire, 4);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\n", f.wire.last().payload);
}

test "our FIN, then theirs acknowledging it, closes it and frees the slot" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 2);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    p.ack = f.wire.last().seq +% 1;
    const r = p.fin(&f.table, &f.wire, 3);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN answered
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "our FIN acknowledged first: the connection waits for theirs, acknowledges it, and closes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 2);
    try testing.expectEqual(Event.nothing, p.ackAll(&f.table, &f.wire, 3).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    try testing.expectEqual(tcp.Fin.acknowledged, f.table.conns[i].fin.get());
    // Nothing more of ours goes out while it waits.
    const sent = f.wire.count;
    transmit(&f.table, &f.wire, 3 + 10 * rto);
    try testing.expectEqual(sent, f.wire.count);

    const r = p.fin(&f.table, &f.wire, 4);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN acknowledged
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "a peer that never sends its FIN is let go after the wait" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 0);
    _ = p.ackAll(&f.table, &f.wire, 1);
    transmit(&f.table, &f.wire, 1 + tcp.fin_wait_ns - 1);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    transmit(&f.table, &f.wire, 1 + tcp.fin_wait_ns);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.fin_waits_expired);
}

test "their FIN repeated before we close is acknowledged again, and after, reset" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    try testing.expectEqual(Event.peer_done, p.fin(&f.table, &f.wire, 1).event);
    const first_ack = f.wire.last();
    // Our acknowledgement was lost; they say it again.
    const sent = f.wire.count;
    try testing.expectEqual(Event.nothing, p.fin(&f.table, &f.wire, 2).event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(first_ack.ack, f.wire.last().ack);

    f.table.finish(i);
    transmit(&f.table, &f.wire, 3);
    p.seq +%= 1;
    try testing.expectEqual(Event.closed, p.ackAll(&f.table, &f.wire, 4).event);
    // Closed and forgotten: their FIN once more is refused.
    p.seq -%= 1;
    _ = p.fin(&f.table, &f.wire, 5);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
}

test "their FIN before our FIN is acknowledged leaves the connection closing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 2);
    const r = p.fin(&f.table, &f.wire, 3); // acknowledges only the SYN
    try testing.expectEqual(Event.peer_done, r.event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    p.seq +%= 1;
    try testing.expectEqual(Event.closed, p.ackUpTo(&f.table, &f.wire, p.ack +% 1, 4).event);
}

test "a segment for no connection is answered with a reset; a stray reset is not" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .ack = 777 };
    var buf: [1600]u8 = undefined;
    // With an acknowledgement: the reset is numbered by it.
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, p.frame(&buf, flag_ack, 1, "hello"), 1).event);
    try testing.expectEqual(@as(usize, 1), f.wire.count);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(@as(u32, 777), f.wire.last().seq);
    try testing.expectEqual(@as(u16, 40000), f.wire.last().dst_port);
    try testing.expect(f.wire.checksumOk(0));
    // Without one: the reset acknowledges what the segment carried, its FIN too.
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_fin, 50, "abc"), 1);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u32, 54), f.wire.last().ack);
    // A reset is never answered.
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, p.frame(&buf, flag_rst, 1, ""), 1).event);
    try testing.expectEqual(@as(usize, 2), f.wire.count);
    try testing.expectEqual(@as(u64, 2), f.table.strays);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "a repeated SYN is answered again, from the same starting number" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
    const first = f.wire.last();
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 2);
    const second = f.wire.last();
    try testing.expectEqual(first.seq, second.seq);
    try testing.expectEqual(flag_syn | flag_ack, second.flags);
    try testing.expectEqual(@as(usize, 1), f.table.inUse()); // not a second connection
}

test "a segment ahead, before the handshake's ACK, is answered with what we expect and opens nothing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
    const synack = f.wire.last();
    p.seq +%= 1;
    p.ack = synack.seq +% 1;
    // Its first data segment is lost; the second, 10 bytes on, comes first.
    const sent = f.wire.count;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq +% 10, "later"), 2);
    try testing.expectEqual(Event.nothing, r.event);
    try testing.expectEqual(State.syn_received, f.table.conns[0].state);
    try testing.expectEqual(sent + 1, f.wire.count);
    const answer = f.wire.last();
    try testing.expectEqual(flag_ack, answer.flags); // a bare ACK
    try testing.expectEqual(p.seq, answer.ack); // naming the byte it still waits for
    try testing.expectEqual(@as(usize, 0), answer.payload.len);
    // The ACK in order opens it, and the early bytes were not taken.
    const opened = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 3);
    try testing.expectEqual(Event.opened, opened.event);
    try testing.expectEqual(@as(usize, 0), f.table.conns[0].pending().len);
}

test "a SYN-ACK sent again is not timed: the handshake's ACK takes no sample (Karn), whichever way it was sent again" {
    for ([_]bool{ true, false }) |by_timer| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
        var buf: [1600]u8 = undefined;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
        const synack = f.wire.last();
        const sent = f.wire.count;
        if (by_timer) {
            transmit(&f.table, &f.wire, 1 + rto); // the timer sends it again
        } else {
            _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1 + rto); // so does a repeated SYN
        }
        try testing.expectEqual(sent + 1, f.wire.count);
        try testing.expectEqual(flag_syn | flag_ack, f.wire.last().flags);
        // The ACK answers one copy or the other; no telling which.
        p.seq +%= 1;
        p.ack = synack.seq +% 1;
        const r = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 2 + rto);
        try testing.expectEqual(Event.opened, r.event);
        try testing.expectEqual(@as(u64, 0), f.table.conns[r.index].srtt_ns);
        try testing.expectEqual(@as(u64, 0), f.table.samples);
    }
}

test "every initial sequence number comes from the supplied source" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40001 };
    _ = try a.connect(&f.table, &f.wire, 1);
    const first = a.ack -% 1;
    _ = try b.connect(&f.table, &f.wire, 1);
    const second = b.ack -% 1;
    try testing.expectEqual(first +% 1000, second);
}

test "a frame that is not ours changes nothing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    const frame = p.frame(&buf, flag_syn, 1, "");
    // Another port.
    var other: [1600]u8 = undefined;
    @memcpy(other[0..frame.len], frame);
    @memcpy(other[segment_at + 2 .. segment_at + 4], &proto.be16(8080));
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, other[0..frame.len], 1).event);
    // Garbage.
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, "not a frame", 1).event);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

// ── the send side ────────────────────────────────────────────────────────────

test "the SYN-ACK says our segment size, and the peer's sizes what we send" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .mss = 100 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
    try testing.expectEqualSlices(u8, &mss_option, f.wire.last().options);
    try testing.expect(f.wire.checksumOk(f.wire.count - 1));
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 1;
    const i = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 1).index;

    var body: [250]u8 = undefined;
    try testing.expectEqual(@as(usize, 250), f.table.queue(i, pattern(&body)));
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 100, 100, 50 }, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[200..], f.wire.last().payload);
    try testing.expectEqual(p.ack +% 200, f.wire.last().seq);
}

test "a peer that names a segment size under 88 is sent 88 bytes at a time, as Linux would (the normalization hunt)" {
    // An MSS of 0 sized every send to nothing, so each went down the shut
    // window's path, a byte per retransmission timeout; 1 sent a byte a
    // segment. A peer is a stranger, so its size is raised to Linux's least
    // (TCP_MIN_MSS), a decision named in tcp.zig `min_mss`, not refused.
    for ([_]u16{ 0, 1, 87 }) |tiny| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .mss = tiny };
        const i = try p.connect(&f.table, &f.wire, 1);
        var body: [200]u8 = undefined;
        _ = f.table.queue(i, pattern(&body));
        const from = f.wire.count;
        transmit(&f.table, &f.wire, 2);
        var sizes: [8]usize = undefined;
        try testing.expectEqualSlices(usize, &.{ 88, 88, 24 }, f.wire.sizesSince(from, &sizes));
    }
}

test "a peer that names no segment size is sent 536 bytes at a time" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var body: [1200]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 536, 536, 128 }, f.wire.sizesSince(from, &sizes));
}

test "only what the window allows goes out, and an acknowledgement lets more go" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 100 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var body: [250]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));

    var from = f.wire.count;
    transmit(&f.table, &f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{100}, f.wire.sizesSince(from, &sizes));
    from = f.wire.count;
    transmit(&f.table, &f.wire, 3);
    try testing.expectEqual(from, f.wire.count); // the window is full

    // Forty bytes acknowledged: forty more may go.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 40, 4);
    transmit(&f.table, &f.wire, 5);
    try testing.expectEqualSlices(usize, &.{40}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[100..140], f.wire.last().payload);
    try testing.expectEqual(@as(usize, 210), f.table.conns[i].queued());
}

test "an acknowledgement of nothing sent, or an old one, changes nothing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const first = p.ack;
    _ = f.table.queue(i, "hello");
    transmit(&f.table, &f.wire, 2);

    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 6, 3); // one past what was sent
    try testing.expectEqual(@as(usize, 5), f.table.conns[i].queued());
    try testing.expectEqual(@as(u32, 8192), f.table.conns[i].wnd);
    _ = p.ackUpTo(&f.table, &f.wire, first -% 1, 3); // before the start
    try testing.expectEqual(@as(usize, 5), f.table.conns[i].queued());
    try testing.expectEqual(@as(u32, 8192), f.table.conns[i].wnd);

    _ = p.ackUpTo(&f.table, &f.wire, first +% 5, 4);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(?i96, null), f.table.conns[i].rto_at);
}

test "what is not acknowledged in time is sent again, oldest first, and the wait doubles" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [700]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 0); // 536 + 164
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 100, 50 * ms); // the timer restarts from here

    var from = f.wire.count;
    transmit(&f.table, &f.wire, 50 * ms + rto - 1);
    try testing.expectEqual(from, f.wire.count); // not yet
    transmit(&f.table, &f.wire, 50 * ms + rto);
    var sizes: [8]usize = undefined;
    // The oldest segment alone (RFC 6298 (5.4)), not the go-back's 536 + 64.
    try testing.expectEqualSlices(usize, &.{536}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[100..636], f.wire.at(from).payload);
    try testing.expectEqual(p.ack, f.wire.at(from).seq);
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);

    from = f.wire.count;
    transmit(&f.table, &f.wire, 50 * ms + 3 * rto - 1);
    try testing.expectEqual(from, f.wire.count); // the wait is twice as long now
    transmit(&f.table, &f.wire, 50 * ms + 3 * rto);
    try testing.expectEqual(from + 1, f.wire.count);

    // Progress resets the wait.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 600, 100 * ms + 3 * rto);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(u8, 0), f.table.conns[i].retries);
    try testing.expectEqual(first_rto_ns, f.table.conns[i].rto_ns);
}

test "a timeout sends only the oldest segment, and each acknowledgement lets twice as much follow (RFC 6298 (5.4); metal-vmm QUEUE 225, chunk 0a)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [2000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    var sizes: [8]usize = undefined;
    var from = f.wire.count;
    transmit(&f.table, &f.wire, 0);
    try testing.expectEqualSlices(usize, &.{ 536, 536, 536, 392 }, f.wire.sizesSince(from, &sizes));

    // Nothing is acknowledged: the timeout sends the oldest segment alone,
    // where a go-back sent all four.
    from = f.wire.count;
    transmit(&f.table, &f.wire, rto);
    try testing.expectEqualSlices(usize, &.{536}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqual(p.ack, f.wire.at(from).seq);
    // Nor does a later turn send more before an acknowledgement.
    from = f.wire.count;
    transmit(&f.table, &f.wire, rto + 1 * ms);
    try testing.expectEqual(from, f.wire.count);

    // Its acknowledgement lets two follow, theirs the rest.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 536, rto + 10 * ms);
    from = f.wire.count;
    transmit(&f.table, &f.wire, rto + 10 * ms);
    try testing.expectEqualSlices(usize, &.{ 536, 536 }, f.wire.sizesSince(from, &sizes));
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1072, rto + 20 * ms);
    from = f.wire.count;
    transmit(&f.table, &f.wire, rto + 20 * ms);
    try testing.expectEqualSlices(usize, &.{392}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqual(@as(?usize, null), f.table.conns[i].recovery);
}

test "a full but live peer is probed after every timeout, recovering or not, and never given up on (RFC 6298 (5.4); metal-vmm QUEUE 225, chunk 0a)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 1000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [1500]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 0);
    // The peer takes the first segment and is full.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 536, 5 * ms);
    var now: i96 = 5 * ms;
    for (0..3 * max_retries) |_| {
        // Each timeout probes with one byte, which the peer takes, still full.
        const from = f.wire.count;
        now = f.table.conns[i].rto_at.?;
        transmit(&f.table, &f.wire, now);
        try testing.expectEqual(from + 1, f.wire.count);
        try testing.expectEqual(@as(usize, 1), f.wire.last().payload.len);
        _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1, now + 1 * ms);
    }
    try testing.expectEqual(@as(u64, 0), f.table.given_up);
    try testing.expect(f.table.conns[i].state != .closed);
}

test "a peer that never answers is reset after the last timeout" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "anyone there?");
    var now: i96 = 0;
    transmit(&f.table, &f.wire, now);
    var sends: usize = 1;
    while (f.table.conns[i].state != .closed) {
        now += 1 * ms;
        const before = f.wire.count;
        transmit(&f.table, &f.wire, now);
        if (f.wire.count > before and f.table.conns[i].state != .closed) sends += 1;
        try testing.expect(now < 120 * ns_per_s);
    }
    try testing.expectEqual(@as(usize, 1 + max_retries), sends);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
    // Each wait doubles up to the ceiling, and the last one runs out too.
    var total: i96 = 0;
    var wait: i96 = rto;
    for (0..max_retries + 1) |_| {
        total += wait;
        wait = @min(wait * 2, tcp.max_rto_ns);
    }
    try testing.expectEqual(total, now);
}

test "a shut window is probed, and the rest goes when it opens" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 0 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "0123456789");
    var from = f.wire.count;
    transmit(&f.table, &f.wire, 0);
    try testing.expectEqual(from, f.wire.count); // no room
    transmit(&f.table, &f.wire, rto);
    try testing.expectEqualStrings("0", f.wire.last().payload); // the probe
    try testing.expectEqual(@as(u64, 1), f.table.probes);

    // The peer took the byte and has room now.
    p.window = 100;
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1, rto + 10 * ms);
    from = f.wire.count;
    transmit(&f.table, &f.wire, rto + 10 * ms);
    try testing.expectEqualStrings("123456789", f.wire.last().payload);
    try testing.expectEqual(from + 1, f.wire.count);
}

test "a probe the shut window refuses is not taken as sent: when the window opens, the oldest byte goes first (metal-vmm QUEUE 227)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 1000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 0);
    // The peer shuts its window and takes none of what was in flight.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, p.ack, 5 * ms);
    // The timeout probes with the oldest byte, and the shut window refuses
    // it too: the peer's answer acknowledges nothing.
    var now = f.table.conns[i].rto_at.?;
    transmit(&f.table, &f.wire, now);
    try testing.expectEqual(@as(usize, 1), f.wire.last().payload.len);
    try testing.expectEqual(p.ack, f.wire.last().seq);
    _ = p.ackUpTo(&f.table, &f.wire, p.ack, now + 1 * ms);

    // The window opens, still acknowledging nothing: what goes next starts
    // at the oldest byte, the one the probe carried and the peer refused.
    // Taking the probe as sent left a hole there, which only a later,
    // backed-off timeout filled (long.sh's rough shut-window, 2026-10-16).
    p.window = 1000;
    now += 10 * ms;
    _ = p.ackUpTo(&f.table, &f.wire, p.ack, now);
    const from = f.wire.count;
    transmit(&f.table, &f.wire, now);
    try testing.expect(f.wire.count > from);
    try testing.expectEqual(p.ack, f.wire.at(from).seq);

    // And the rest follows, an acknowledgement at a time, with no timer.
    var guard: usize = 0;
    while (f.table.conns[i].queued() > 0) : (guard += 1) {
        try testing.expect(guard < 20);
        now += 10 * ms;
        _ = p.ackAll(&f.table, &f.wire, now);
        transmit(&f.table, &f.wire, now);
    }
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);
}

test "a window that stays shut is given up on" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 0 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "nobody is reading");
    var now: i96 = 0;
    while (f.table.conns[i].state != .closed) : (now += 10 * ms) {
        transmit(&f.table, &f.wire, now);
        // The peer answers every probe, still with no room.
        if (f.wire.count > 0 and f.wire.last().payload.len > 0) _ = p.ackUpTo(&f.table, &f.wire, p.ack, now);
        try testing.expect(now < 60 * ns_per_s);
    }
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
}

test "our FIN waits for the queue, and only its own acknowledgement closes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 100 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [150]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.finish(i);
    try testing.expectEqual(@as(usize, 0), f.table.queue(i, "too late"));
    transmit(&f.table, &f.wire, 1);
    try testing.expectEqual(flag_psh | flag_ack, f.wire.last().flags); // no FIN yet

    // Every byte so far acknowledged is not the FIN acknowledged.
    try testing.expectEqual(Event.nothing, p.ackAll(&f.table, &f.wire, 2).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    transmit(&f.table, &f.wire, 3);
    try testing.expectEqual(@as(usize, 50), f.wire.at(f.wire.count - 2).payload.len);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.ack +% 50, f.wire.last().seq);
    try testing.expectEqual(Event.nothing, p.ackUpTo(&f.table, &f.wire, p.ack +% 50, 4).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    try testing.expectEqual(tcp.Fin.sent, f.table.conns[i].fin.get());
    try testing.expectEqual(Event.nothing, p.ackUpTo(&f.table, &f.wire, p.ack +% 1, 5).event);
    try testing.expectEqual(tcp.Fin.acknowledged, f.table.conns[i].fin.get());
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, 6).event);
}

test "a lost FIN is sent again" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 0);
    const fin = f.wire.last();
    const before = f.wire.count;
    transmit(&f.table, &f.wire, rto);
    // A segment of its own: the last one on the wire being the old FIN proves
    // nothing (tools/mutate_tcp.py's go-back-keeps-fin passed that way).
    try testing.expectEqual(before + 1, f.wire.count);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(fin.seq, f.wire.last().seq);
    _ = p.ackAll(&f.table, &f.wire, rto + 10 * ms);
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, rto + 20 * ms).event);
}

test "a lost SYN-ACK is sent again by the timer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    const first = f.wire.last();
    transmit(&f.table, &f.wire, rto - 1);
    try testing.expectEqual(@as(usize, 1), f.wire.count);
    transmit(&f.table, &f.wire, rto);
    try testing.expectEqual(first.seq, f.wire.last().seq);
    try testing.expectEqual(flag_syn | flag_ack, f.wire.last().flags);
}

test "an ACK with the wrong number does not complete the handshake" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    _ = r;
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 2;
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 0).event);
    try testing.expectEqual(State.syn_received, f.table.conns[0].state);
}

test "a full queue takes only what fits, and acknowledged bytes make room" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [3000]u8 = undefined;
    _ = pattern(&body);
    try testing.expectEqual(@as(usize, 2048), f.table.queue(i, &body));
    try testing.expectEqual(@as(usize, 0), f.table.queue(i, body[2048..]));
    transmit(&f.table, &f.wire, 0);
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1000, 1);
    try testing.expectEqual(@as(usize, 952), f.table.queue(i, body[2048..]));
    try testing.expectEqual(@as(usize, 2000), f.table.conns[i].queued());

    // What goes out next is still the stream in order: all 2048 of the first
    // queueing were on the wire, and the rest follows them.
    _ = p.ackAll(&f.table, &f.wire, 2);
    try testing.expectEqual(@as(usize, 952), f.table.conns[i].queued());
    var sent: usize = 2048;
    while (f.table.conns[i].queued() > 0) {
        const from = f.wire.count;
        transmit(&f.table, &f.wire, 3);
        for (from..f.wire.count) |k| {
            const s = f.wire.at(k);
            try testing.expectEqualSlices(u8, body[sent..][0..s.payload.len], s.payload);
            sent += s.payload.len;
        }
        _ = p.ackAll(&f.table, &f.wire, 3);
        f.wire.count = 0;
    }
    try testing.expectEqual(@as(usize, 3000), sent);
}

test "nothing is queued before the handshake completes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    try testing.expectEqual(@as(usize, 0), f.table.queue(0, "early"));
}

test "abandoning a connection tells the peer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.abandon(&f.wire, i, .slow_client);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
}

test "segment-size options are read past padding and other options" {
    try testing.expectEqual(@as(?u16, 1460), parseMss(&.{ 1, 1, 4, 2, 2, 4, 5, 180 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 0, 2, 4, 5, 180 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 2, 4, 5 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 3, 0 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{}));
}

// ── what the RFC review found ────────────────────────────────────────────────

test "a keepalive probe is acknowledged, and does not count as hearing from the peer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    const sent = f.wire.count;
    // A keepalive: one before the next byte expected, and no data.
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq -% 1, ""), 50);
    try testing.expectEqual(Event.nothing, r.event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(@as(i96, 1), f.table.conns[i].heard_at);
}

test "a reset at the window's right edge is outside it, and is ignored" {
    // RFC 9293: in the window means RCV.NXT <= SEG.SEQ < RCV.NXT + RCV.WND,
    // so the edge itself is outside, and RFC 5961 drops a reset there.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    const edge = c.rcv_nxt +% @as(u32, c.window());
    const before = f.wire.count;
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_rst | flag_ack, edge, ""), 1);
    try testing.expectEqual(before, f.wire.count);
    try testing.expectEqual(State.established, c.state);
    // One byte inside it draws the challenge.
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_rst | flag_ack, edge -% 1, ""), 2);
    try testing.expectEqual(before + 1, f.wire.count);
}

test "a reset counts only at the next byte expected; one inside the window draws an acknowledgement" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    var sent = f.wire.count;
    // Far outside the window: ignored, without a word.
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, p.frame(&buf, flag_rst, p.seq +% 100_000, ""), 2).event);
    try testing.expectEqual(sent, f.wire.count);
    // Inside it but not exact: a challenge.
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, p.frame(&buf, flag_rst, p.seq +% 10, ""), 2).event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    // Exact: the connection is over.
    sent = f.wire.count;
    try testing.expectEqual(Event.closed, handle(&f.table, &f.wire, p.frame(&buf, flag_rst, p.seq, ""), 3).event);
    try testing.expectEqual(sent, f.wire.count);
}

test "a late acknowledgement does not overrule a newer one's window" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 4000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [300]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 1);
    const first = p.ack;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 100, 2); // newer, window 4000
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first, 3); // older, window 0, arriving late
    try testing.expectEqual(@as(u32, 4000), f.table.conns[i].wnd);
}

test "an acknowledgement of bytes sent before a timeout still counts after it" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 2000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [1000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 0);
    const first = p.ack;
    // The window shuts, the timer runs out, and one byte goes as a probe.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first, 1);
    transmit(&f.table, &f.wire, rto);
    try testing.expectEqual(@as(usize, 1), f.wire.last().payload.len);
    // A probe is not counted as sent (QUEUE 227), only as `high`.
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].sent);
    // The peer's acknowledgement of all 1000 bytes is still good.
    p.window = 2000;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 1000, rto + 1);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].sent);
    try testing.expectEqual(first +% 1000, f.table.conns[i].una);
    try testing.expectEqual(@as(?i96, null), f.table.conns[i].rto_at);
}

test "a handshake ACK of something we never sent is refused with a reset" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 99;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 0);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(State.syn_received, f.table.conns[0].state);
}

test "a segment with a wrong checksum is dropped" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var buf: [1600]u8 = undefined;
    const frame = p.frame(&buf, flag_psh | flag_ack, p.seq, "hello");
    buf[frame.len - 1] ^= 0xFF; // damage the payload
    const sent = f.wire.count;
    try testing.expectEqual(Event.nothing, handle(&f.table, &f.wire, frame, 1).event);
    try testing.expectEqual(sent, f.wire.count);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len);
    try testing.expectEqual(@as(u64, 1), f.table.damaged);
}

test "a SYN on an established connection draws an acknowledgement, not a new connection" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    _ = try p.connect(&f.table, &f.wire, 0);
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, 99, ""), 1);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(usize, 1), f.table.inUse());
}

test "data ahead of what is expected still carries its acknowledgement" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "answer");
    transmit(&f.table, &f.wire, 0);
    p.ack +%= 6;
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq +% 5, "later"), 1);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued()); // "answer" acknowledged
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len); // "later" not taken
    try testing.expectEqual(p.seq, f.wire.last().ack);
}

test "their FIN first, then again with ours acknowledged, closes at once" {
    // Seen from QEMU's network: the repeated FIN is numbered before what we
    // now expect, and its acknowledgement of our FIN must still count.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    try testing.expectEqual(Event.peer_done, p.fin(&f.table, &f.wire, 1).event);
    f.table.finish(i);
    transmit(&f.table, &f.wire, 2);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    p.ack = f.wire.last().seq +% 1;
    // The same FIN again, numbered as before, now acknowledging ours.
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, 3).event);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
}

test "what we send after going back is still numbered at the furthest we sent" {
    // **SND.NXT IS NOT THE RETRANSMISSION POINTER.** A timeout rewinds what to
    // send next; it does not un-send anything. A peer whose window shut can
    // only be probed one byte at a time, so the rewound pointer stays near
    // `una` — and a reset numbered there is behind the peer's window, which
    // discards it and leaves the peer waiting forever on a connection we have
    // already thrown away.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [100]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 1);
    try testing.expectEqual(@as(usize, 100), f.wire.last().payload.len);
    const una = f.table.conns[i].una;

    // The peer stops reading: it acknowledges nothing new and shuts its window.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, una, 2);

    var t: i96 = 2;
    var k: usize = 0;
    while (k <= max_retries) : (k += 1) {
        t += 6 * ns_per_s;
        transmit(&f.table, &f.wire, t);
    }
    try testing.expect(f.table.given_up == 1);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    const rst = f.wire.last();
    try testing.expectEqual(flag_rst | flag_ack, rst.flags);
    try testing.expectEqual(una +% 100, rst.seq); // where the peer's window begins
}

test "a segment beyond the window carries nothing, not even its acknowledgement" {
    // Taking the acknowledgement of a segment the peer cannot have sent yet
    // would set SND.WL1 past anything it will ever send, and then the window
    // rule refuses every real update that follows.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "ten bytes!");
    transmit(&f.table, &f.wire, 1);
    const una = f.table.conns[i].una;
    const wl1 = f.table.conns[i].wl1;

    p.ack = una +% 10; // it claims to have the lot
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq +% 100_000, ""), 2);

    try testing.expectEqual(una, f.table.conns[i].una);
    try testing.expectEqual(wl1, f.table.conns[i].wl1);
    try testing.expectEqual(@as(usize, 10), f.table.conns[i].queued());
    try testing.expectEqual(flag_ack, f.wire.last().flags);
}

test "a segment beyond the window carries nothing at any distance past it, half the circle included (metal-vmm B37's review)" {
    // Half the circle past rcv_nxt is neither after it nor before it; it is
    // not behind, so its acknowledgement must be refused like any beyond.
    for ([_]u32{ 100_000, 0x7FFF_FFFF, 0x8000_0000 }) |past| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
        const i = try p.connect(&f.table, &f.wire, 0);
        _ = f.table.queue(i, "ten bytes!");
        transmit(&f.table, &f.wire, 1);
        const una = f.table.conns[i].una;
        const wl1 = f.table.conns[i].wl1;
        p.ack = una +% 10;
        var buf: [1600]u8 = undefined;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq +% past, ""), 2);
        try testing.expectEqual(una, f.table.conns[i].una);
        try testing.expectEqual(wl1, f.table.conns[i].wl1);
    }
}

test "an older segment with a newer acknowledgement moves the window's edge too" {
    // The window rule keeps the old segment from setting the window, but its
    // acknowledgement still moves `una` — and the window is measured from
    // `una`, so the edge has to come back by as much.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = p.write(&f.table, &f.wire, "GET /\r\n\r\n", 1);
    var body: [50]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2);
    const before = f.table.conns[i].wnd;

    p.ack = f.table.conns[i].una +% 50;
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq -% 20, ""), 3);

    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(before - 50, f.table.conns[i].wnd);
}

// ---- sequence edges (RFC 9293 §3.4, §3.10.7.4): each test pins the last
// number on one side and the first on the other, side by side.

/// One connection with "ten bytes!" on the wire, and a bare ACK of all ten
/// sent at `seq_from_next` past the next byte expected. Whether `una` moved
/// says whether the segment's acknowledgement was taken.
fn ackTakenAt(seq_from_next: u32) !bool {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "ten bytes!");
    transmit(&f.table, &f.wire, 1);
    const una = f.table.conns[i].una;
    p.ack = una +% 10;
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq +% seq_from_next, ""), 2);
    return f.table.conns[i].una != una;
}

test "the window's last number is ahead and its acknowledgement is taken; the right edge is beyond and its is not" {
    // In the window: RCV.NXT =< SEG.SEQ < RCV.NXT + RCV.WND.
    const w: u32 = 64; // the fixture's receive buffer, empty
    try testing.expect(try ackTakenAt(w - 1));
    try testing.expect(!try ackTakenAt(w));
}

test "half the circle less one behind is from behind and its acknowledgement counts; half the circle is not behind" {
    const half: u32 = 1 << 31;
    const next: u32 = 0;
    try testing.expect(try ackTakenAt(next -% 1)); // one behind: a keepalive
    try testing.expect(try ackTakenAt(next -% (half - 1)));
    try testing.expect(!try ackTakenAt(next -% half));
}

test "a shut window takes a segment at the next byte expected, and none one past it" {
    // RFC 9293 §3.10.7.4: with RCV.WND 0, only SEG.SEQ = RCV.NXT is acceptable.
    for ([_]struct { past: u32, taken: bool }{ .{ .past = 0, .taken = true }, .{ .past = 1, .taken = false } }) |case| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
        const i = try p.connect(&f.table, &f.wire, 0);
        var fill: [64]u8 = undefined;
        _ = p.write(&f.table, &f.wire, pattern(&fill), 1);
        try testing.expectEqual(@as(u16, 0), f.table.conns[i].window());
        _ = f.table.queue(i, "ten bytes!");
        transmit(&f.table, &f.wire, 2);
        const una = f.table.conns[i].una;
        p.ack = una +% 10;
        var buf: [1600]u8 = undefined;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq +% case.past, ""), 3);
        try testing.expectEqual(case.taken, f.table.conns[i].una != una);
    }
}

test "a window update from the segment that last set it counts; from the one before it, it does not" {
    // SND.WL1 < SEG.SEQ, or SND.WL1 = SEG.SEQ and SND.WL2 =< SEG.ACK.
    for ([_]struct { back: u32, updated: bool }{ .{ .back = 0, .updated = true }, .{ .back = 1, .updated = false } }) |case| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
        const i = try p.connect(&f.table, &f.wire, 0);
        try testing.expectEqual(p.seq, f.table.conns[i].wl1);
        try testing.expectEqual(p.ack, f.table.conns[i].wl2);
        p.window = 1234;
        var buf: [1600]u8 = undefined;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq -% case.back, ""), 1);
        try testing.expectEqual(case.updated, f.table.conns[i].wnd == 1234);
    }
}

test "an acknowledgement of the timed segment's last byte takes the sample; one short of it does not" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "ten bytes!");
    transmit(&f.table, &f.wire, 100 * ms);
    const una = f.table.conns[i].una;
    const samples = f.table.samples;
    _ = p.ackUpTo(&f.table, &f.wire, una +% 9, 150 * ms);
    try testing.expectEqual(samples, f.table.samples);
    _ = p.ackUpTo(&f.table, &f.wire, una +% 10, 160 * ms);
    try testing.expectEqual(samples + 1, f.table.samples);
}

test "a FIN behind data that exactly fills the room is taken; behind one byte more, it waits" {
    for ([_]struct { len: usize, done: bool }{ .{ .len = 64, .done = true }, .{ .len = 65, .done = false } }) |case| {
        var f: Fixture = .{};
        f.init();
        var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
        const i = try p.connect(&f.table, &f.wire, 0);
        var body: [65]u8 = undefined;
        var buf: [1600]u8 = undefined;
        const r = handle(&f.table, &f.wire, p.frame(&buf, flag_fin | flag_ack, p.seq, pattern(body[0..case.len])), 1);
        try testing.expectEqual(case.done, f.table.conns[i].peerDone());
        try testing.expectEqual(@as(usize, 64), f.table.conns[i].pending().len);
        try testing.expectEqual(if (case.done) Event.peer_done else Event.data, r.event);
    }
}

test "giving up on a handshake tells the peer, instead of leaving it on a timer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    const synack = f.wire.last();
    try testing.expectEqual(flag_syn | flag_ack, synack.flags);

    var t: i96 = 0;
    var k: usize = 0;
    while (k <= max_retries) : (k += 1) {
        t += 6 * ns_per_s;
        transmit(&f.table, &f.wire, t);
    }
    const rst = f.wire.last();
    try testing.expect(rst.flags & flag_rst != 0);
    try testing.expectEqual(synack.seq +% 1, rst.seq);
    try testing.expectEqual(State.closed, f.table.conns[0].state);
    try testing.expect(f.table.given_up == 1);
}

test "the handshake is the first measurement, and the estimate is RFC 6298's" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    const synack = f.wire.last();
    p.seq +%= 1;
    p.ack = synack.seq +% 1;
    // Their acknowledgement comes back 100 ms later: that is the round trip.
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 100 * ms);
    const c = &f.table.conns[0];
    try testing.expectEqual(@as(u64, 100 * ns_per_ms), c.srtt_ns);
    try testing.expectEqual(@as(u64, 50 * ns_per_ms), c.rttvar_ns); // half, for the first
    try testing.expectEqual(@as(u64, 300 * ns_per_ms), c.rto_ns); // srtt + 4 * rttvar

    // A second sample, 60 ms: the estimate moves an eighth, the variation a
    // quarter.
    _ = f.table.queue(0, "a response");
    transmit(&f.table, &f.wire, 200 * ms);
    _ = p.ackAll(&f.table, &f.wire, 260 * ms);
    try testing.expectEqual(@as(u64, 95 * ns_per_ms), c.srtt_ns);
    try testing.expectEqual(@as(u64, 47_500_000), c.rttvar_ns);
    try testing.expectEqual(@as(u64, 285 * ns_per_ms), c.rto_ns);
}

test "a fast path waits the floor, not a second" {
    // **THE FLOOR IS THE PEER'S DELAYED ACKNOWLEDGEMENTS, NOT THE PATH.** On a
    // private network the round trip is microseconds; nothing should wait a
    // second for it.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 1;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 200_000); // 0.2 ms
    try testing.expectEqual(@as(u64, 200_000), f.table.conns[0].srtt_ns);
    try testing.expectEqual(min_rto_ns, f.table.conns[0].rto_ns);
}

test "a segment that was sent twice is not timed" {
    // Karn's algorithm: there is no telling which copy the acknowledgement
    // answers, so the sample would be wrong either way.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 1;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 100 * ms);
    const c = &f.table.conns[0];
    const settled = c.srtt_ns;

    _ = f.table.queue(0, "a response");
    transmit(&f.table, &f.wire, 200 * ms);
    // Nothing comes back, so it goes again — and then the acknowledgement
    // arrives a long time after the FIRST copy went out.
    transmit(&f.table, &f.wire, 200 * ms + @as(i96, @intCast(c.rto_ns)));
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);
    _ = p.ackAll(&f.table, &f.wire, 900 * ms);
    try testing.expectEqual(settled, c.srtt_ns);
}

test "three duplicate acknowledgements send it again at once" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const una = f.table.conns[i].una;
    const sent = f.wire.count;

    // The peer received what came after the first segment, and says so three
    // times. It is nowhere near the retransmission timer.
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.fast_retransmits);
    try testing.expect(f.wire.count > sent);
    try testing.expectEqual(una, f.wire.at(sent).seq); // from the oldest byte on
    try testing.expectEqual(@as(u8, 0), f.table.conns[i].dupacks);
}

test "three duplicate acknowledgements resend exactly one segment, the oldest, and its acknowledgement lets twice as much follow (RFC 6298 (5.4), RFC 5681; metal-vmm QUEUE 225, chunk 0b)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const una = f.table.conns[i].una;
    const retries = f.table.conns[i].retries;
    const rto_ns = f.table.conns[i].rto_ns;

    var from = f.wire.count;
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{536}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqual(una, f.wire.at(from).seq);
    // The backoff is untouched: a hole is no evidence of a slower path.
    try testing.expectEqual(retries, f.table.conns[i].retries);
    try testing.expectEqual(rto_ns, f.table.conns[i].rto_ns);

    // The resent segment acknowledged: two more follow.
    _ = p.ackUpTo(&f.table, &f.wire, una +% 536, 4 * ms);
    from = f.wire.count;
    transmit(&f.table, &f.wire, 4 * ms);
    try testing.expectEqualSlices(usize, &.{ 536, 536 }, f.wire.sizesSince(from, &sizes));
}

test "a duplicate acknowledgement names SND.UNA: an older one, or one of data never sent, counts toward no fast retransmit (metal-vmm QUEUE 133, RFC 5681 §2)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const first = f.table.conns[i].una;
    // The first hundred bytes acknowledged: SND.UNA moves past `first`.
    _ = p.ackUpTo(&f.table, &f.wire, first +% 100, 3 * ms);
    const una = f.table.conns[i].una;
    try testing.expectEqual(first +% 100, una);
    const sent = f.wire.count;

    // Three bare acknowledgements of less than SND.UNA: old news, reordered.
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, first +% 50, 4 * ms);
    try testing.expectEqual(@as(u64, 0), f.table.fast_retransmits);
    try testing.expectEqual(@as(u8, 0), f.table.conns[i].dupacks);
    // Nor of more than was ever sent.
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, f.table.conns[i].highest() +% 1000, 5 * ms);
    try testing.expectEqual(@as(u64, 0), f.table.fast_retransmits);
    try testing.expectEqual(@as(u8, 0), f.table.conns[i].dupacks);
    // Nothing was sent again; three that name SND.UNA still are.
    try testing.expectEqual(sent, f.wire.count);
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 6 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.fast_retransmits);
}

test "a peer that keeps repeating its duplicate acknowledgement is answered by one fast retransmit, and its count cannot overflow" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const una = f.table.conns[i].una;
    // Far more than a u8 counts, every one naming SND.UNA, none moving it.
    for (0..600) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.fast_retransmits);
    try testing.expectEqual(una, f.table.conns[i].una);
}

test "a fast retransmit restarts the timer, so the timeout does not follow on its heels" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms); // the timer: 2 ms + rto
    const una = f.table.conns[i].una;
    for (0..3) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);
    // When the first timer would have run out, the restarted one has not.
    transmit(&f.table, &f.wire, 2 * ms + rto);
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);
    transmit(&f.table, &f.wire, 3 * ms + rto);
    try testing.expectEqual(@as(u64, 2), f.table.retransmits);
}

test "duplicates before new data are forgotten: a new run needs three of its own" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const una = f.table.conns[i].una;
    // Two duplicates, then something new acknowledged, then two more: never
    // three in a row, so nothing is sent again early.
    for (0..2) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    _ = p.ackUpTo(&f.table, &f.wire, una +% 100, 3 * ms);
    for (0..2) |_| _ = p.ackUpTo(&f.table, &f.wire, una +% 100, 3 * ms);
    try testing.expectEqual(@as(u64, 0), f.table.fast_retransmits);
    _ = p.ackUpTo(&f.table, &f.wire, una +% 100, 3 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.fast_retransmits);
}

test "a peer that repeats itself forever gets one answer, not one each time" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [3000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    transmit(&f.table, &f.wire, 2 * ms);
    const una = f.table.conns[i].una;
    for (0..30) |_| _ = p.ackUpTo(&f.table, &f.wire, una, 3 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.fast_retransmits);
}

test "a shut window's probes are answered without being mistaken for loss" {
    // The peer has no room, so it acknowledges every probe with the same
    // number: the same shape as a duplicate acknowledgement, and not loss.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 0 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "nobody is reading");
    var now: i96 = 0;
    while (f.table.conns[i].state != .closed) : (now += 10 * ms) {
        transmit(&f.table, &f.wire, now);
        if (f.wire.count > 0 and f.wire.last().payload.len > 0) _ = p.ackUpTo(&f.table, &f.wire, p.ack, now);
    }
    try testing.expectEqual(@as(u64, 0), f.table.fast_retransmits);
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
}

// ── the state × event matrix (TCP_TESTING.md §7) ───────────────────────────
//
// RFC 9293 §3.10.7 says, state by state, what each kind of segment does. Here
// that is a table: one row per kind of segment, one cell per state, each cell
// what must be sent back and what the connection becomes. A null cell is a
// question about the design rather than a test, and is listed under §7 in
// TCP_TESTING.md; it stays null until the question has an answer.

/// Where the connection is when the segment arrives. `listen` is no
/// connection at all: a segment from a peer the table does not know, to the
/// port it listens on. `fin_queued`, `fin_sent` and `fin_acked` are RFC 9293's
/// FIN-WAIT-1 before and after our FIN goes, and FIN-WAIT-2; `peer_done` is
/// CLOSE-WAIT.
const MatrixSetup = enum { listen, syn_received, established, fin_queued, fin_sent, fin_acked, peer_done };

/// What arrives. In the comments, `r` is RCV.NXT, `u` SND.UNA and `h` SND.NXT
/// (`highest()`). Every segment but the SYNs and the `ack_*` rows carries the
/// acknowledgement a well-behaved peer would send now: `h` in a handshake
/// (completing it), `u` otherwise (acknowledging nothing new).
const MatrixKind = enum {
    /// SYN at r-1: the peer's SYN again.
    syn_repeated,
    /// SYN at r.
    syn_in_window,
    /// SYN at r, carrying 5 bytes.
    syn_with_data,
    /// RST at r.
    rst_exact,
    /// RST at r+1.
    rst_in_window,
    /// RST at r+1000, past the 64-byte window.
    rst_outside,
    /// ACK of u-10.
    ack_old,
    /// ACK of u.
    ack_duplicate,
    /// ACK of h.
    ack_new,
    /// ACK of h+10: of something never sent.
    ack_future,
    /// 10 bytes at r.
    data_in_order,
    /// 10 bytes at r+5.
    data_ahead,
    /// 10 bytes at r-20: all of them already taken.
    data_behind,
    /// 10 bytes at r-5: five old, five new.
    data_straddling,
    /// 10 bytes at r+1000.
    data_past_window,
    /// FIN at r — in `peer_done`, the peer's FIN repeated, at r-1.
    fin,
    /// 10 bytes and a FIN at r.
    fin_with_data,
};

const MatrixReply = enum { none, ack, syn_ack, rst };

const MatrixOutcome = struct {
    reply: MatrixReply,
    /// The state after, or null for "as it was": state, our FIN and the
    /// peer's FIN all unchanged.
    state: ?State = null,
    fin: ?tcp.Fin = null,
    peer_done: ?bool = null,
    /// Bytes the segment added to what waits to be read (not checked once
    /// the slot is closed).
    taken: usize = 0,
    event: ?Event = null,
};

const MatrixRow = struct { kind: MatrixKind, cells: [7]?MatrixOutcome };

const cell_none: ?MatrixOutcome = .{ .reply = .none };
const cell_ack: ?MatrixOutcome = .{ .reply = .ack };
const cell_rst: ?MatrixOutcome = .{ .reply = .rst };
/// To a peer the table does not know: refused with a reset, nothing opened.
const cell_refused: ?MatrixOutcome = .{ .reply = .rst, .state = .closed };
/// Ignored without a word, and nothing opened (or the slot closed).
const cell_quiet_closed: ?MatrixOutcome = .{ .reply = .none, .state = .closed };
/// A handshake begun: a SYN-ACK that acknowledges the SYN and nothing else.
const cell_opens: ?MatrixOutcome = .{ .reply = .syn_ack, .state = .syn_received };

const matrix_rows = [_]MatrixRow{
    //                                   listen        syn_received       established fin_queued fin_sent  fin_acked peer_done
    // A SYN-ACK said again, for a peer whose copy was lost (as Linux does;
    // RFC 9293's first check would send a bare ACK, which a client still
    // waiting for our SYN cannot use).
    .{ .kind = .syn_repeated, .cells = .{ cell_opens, .{ .reply = .syn_ack }, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    // RFC 5961 §4: a SYN on a synchronized connection gets a challenge ACK.
    .{ .kind = .syn_in_window, .cells = .{ cell_opens, null, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    .{ .kind = .syn_with_data, .cells = .{ cell_opens, null, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    // RFC 5961 §3: only an exact reset resets; one in the window is
    // challenged; anything else is dropped.
    .{ .kind = .rst_exact, .cells = .{ cell_quiet_closed, cell_quiet_closed, cell_quiet_closed, cell_quiet_closed, cell_quiet_closed, cell_quiet_closed, cell_quiet_closed } },
    .{ .kind = .rst_in_window, .cells = .{ cell_quiet_closed, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    .{ .kind = .rst_outside, .cells = .{ cell_quiet_closed, cell_none, cell_none, cell_none, cell_none, cell_none, cell_none } },
    // In a handshake an ACK of anything but our SYN is refused with a reset
    // numbered by it; on a synchronized connection an old or duplicate one
    // is ignored.
    .{ .kind = .ack_old, .cells = .{ cell_refused, cell_rst, cell_none, cell_none, cell_none, cell_none, cell_none } },
    .{ .kind = .ack_duplicate, .cells = .{ cell_refused, cell_rst, cell_none, cell_none, cell_none, cell_none, cell_none } },
    .{
        .kind = .ack_new,
        .cells = .{
            cell_refused,
            .{ .reply = .none, .state = .established, .event = .opened },
            cell_none, // nothing in flight: the same as a duplicate
            cell_none,
            .{ .reply = .none, .state = .closing, .fin = .acknowledged },
            cell_none,
            cell_none,
        },
    },
    .{ .kind = .ack_future, .cells = .{ cell_refused, cell_rst, null, null, null, null, null } },
    // Text is taken in ESTABLISHED and both FIN-WAITs, and ignored (but
    // acknowledged) once the peer has sent its FIN.
    .{ .kind = .data_in_order, .cells = .{
        cell_refused,
        .{ .reply = .ack, .state = .established, .taken = 10, .event = .opened },
        .{ .reply = .ack, .taken = 10, .event = .data },
        .{ .reply = .ack, .taken = 10 },
        .{ .reply = .ack, .taken = 10 },
        .{ .reply = .ack, .taken = 10 },
        cell_ack,
    } },
    // In-order only: anything else is acknowledged and dropped.
    .{ .kind = .data_ahead, .cells = .{ cell_refused, null, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    .{ .kind = .data_behind, .cells = .{ cell_refused, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    .{ .kind = .data_straddling, .cells = .{ cell_refused, null, null, null, null, null, cell_ack } },
    .{ .kind = .data_past_window, .cells = .{ cell_refused, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack, cell_ack } },
    // The peer's FIN: CLOSE-WAIT from a handshake or ESTABLISHED; CLOSING
    // from FIN-WAIT-1; and from FIN-WAIT-2 closed at once, there being no
    // TIME-WAIT here.
    .{ .kind = .fin, .cells = .{
        cell_refused,
        .{ .reply = .ack, .state = .established, .peer_done = true, .event = .peer_done },
        .{ .reply = .ack, .state = .established, .peer_done = true, .event = .peer_done },
        .{ .reply = .ack, .state = .closing, .fin = .queued, .peer_done = true, .event = .peer_done },
        .{ .reply = .ack, .state = .closing, .fin = .sent, .peer_done = true, .event = .peer_done },
        .{ .reply = .ack, .state = .closed, .event = .closed },
        cell_ack,
    } },
    .{ .kind = .fin_with_data, .cells = .{
        cell_refused,
        .{ .reply = .ack, .state = .established, .peer_done = true, .taken = 10 },
        .{ .reply = .ack, .state = .established, .peer_done = true, .taken = 10, .event = .peer_done },
        .{ .reply = .ack, .state = .closing, .fin = .queued, .peer_done = true, .taken = 10 },
        .{ .reply = .ack, .state = .closing, .fin = .sent, .peer_done = true, .taken = 10 },
        .{ .reply = .ack, .state = .closed, .event = .closed },
        cell_ack,
    } },
};

test "the state × event matrix: every state, every kind of segment" {
    for (matrix_rows) |row| {
        for (std.enums.values(MatrixSetup), row.cells) |setup, cell| {
            const want = cell orelse continue; // a question: TCP_TESTING.md §7
            matrixCell(setup, row.kind, want) catch |err| {
                std.debug.print("the matrix cell for {s} in {s} failed\n", .{ @tagName(row.kind), @tagName(setup) });
                return err;
            };
        }
    }
}

/// Builds a fresh table in `setup`, sends one segment of `kind`, and holds the
/// result to `want`.
fn matrixCell(setup: MatrixSetup, kind: MatrixKind, want: MatrixOutcome) !void {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    // A fresh table gives its first connection the first slot.
    const i: usize = 0;
    switch (setup) {
        .listen => {},
        .syn_received => {
            _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
            p.seq +%= 1;
            p.ack = f.wire.last().seq +% 1;
        },
        .established, .fin_queued, .fin_sent, .fin_acked, .peer_done => {
            try testing.expectEqual(i, try p.connect(&f.table, &f.wire, 1));
            switch (setup) {
                .fin_queued => f.table.finish(i),
                .fin_sent, .fin_acked => {
                    f.table.finish(i);
                    transmit(&f.table, &f.wire, 1);
                    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
                    if (setup == .fin_acked) _ = p.ackAll(&f.table, &f.wire, 1);
                },
                .peer_done => _ = p.fin(&f.table, &f.wire, 1),
                else => {},
            }
        },
    }

    const c = &f.table.conns[i];
    const known = setup != .listen;
    const r: u32 = if (known) c.rcv_nxt else p.seq;
    const u: u32 = if (known) c.una else 0x1234_5678;
    const h: u32 = if (known) c.highest() else u;
    const now_ack: u32 = if (setup == .syn_received) h else u;
    const was_state = c.state;
    const was_fin = c.fin.get();
    const was_peer_done = c.peerDone();
    const had = c.pending().len;
    const from = f.wire.count;

    const got = handle(&f.table, &f.wire, matrixSegment(kind, setup, &p, &buf, r, u, h, now_ack), 2);

    switch (want.reply) {
        .none => try testing.expectEqual(from, f.wire.count),
        .ack, .syn_ack, .rst => {
            try testing.expect(f.wire.count > from);
            const said = f.wire.last();
            switch (want.reply) {
                .ack => try testing.expectEqual(flag_ack, said.flags),
                .syn_ack => try testing.expectEqual(flag_syn | flag_ack, said.flags),
                .rst => try testing.expect(said.flags & flag_rst != 0),
                .none => unreachable,
            }
            if (want.reply == .rst) {
                // Numbered by the acknowledgement it answers.
                try testing.expectEqual(p.ack, said.seq);
            } else if (c.state != .closed) {
                try testing.expectEqual(c.rcv_nxt, said.ack);
                const numbered = if (want.reply == .syn_ack) c.una else c.highest();
                try testing.expectEqual(numbered, said.seq);
            }
        },
    }

    if (want.state) |state| {
        try testing.expectEqual(state, c.state);
        if (want.fin) |fin_now| try testing.expectEqual(fin_now, c.fin.get());
        if (want.peer_done) |done| try testing.expectEqual(done, c.peerDone());
    } else {
        try testing.expectEqual(was_state, c.state);
        try testing.expectEqual(was_fin, c.fin.get());
        try testing.expectEqual(was_peer_done, c.peerDone());
    }
    if (c.state != .closed) try testing.expectEqual(had + want.taken, c.pending().len);
    if (want.event) |event| try testing.expectEqual(event, got.event);
}

/// The segment of `kind`, from `p`, numbered from the connection's `r`, `u`
/// and `h` (see `MatrixKind`), acknowledging `now_ack` unless the kind says
/// otherwise.
fn matrixSegment(kind: MatrixKind, setup: MatrixSetup, p: *Peer, buf: []u8, r: u32, u: u32, h: u32, now_ack: u32) []const u8 {
    const ten = "0123456789";
    const data_flags = flag_psh | flag_ack;
    p.ack = now_ack;
    switch (kind) {
        .ack_old => p.ack = u -% 10,
        .ack_duplicate => p.ack = u,
        .ack_new => p.ack = h,
        .ack_future => p.ack = h +% 10,
        else => {},
    }
    return switch (kind) {
        .syn_repeated => p.frame(buf, flag_syn, r -% 1, ""),
        .syn_in_window => p.frame(buf, flag_syn, r, ""),
        .syn_with_data => p.frame(buf, flag_syn, r, "hello"),
        .rst_exact => p.frame(buf, flag_rst | flag_ack, r, ""),
        .rst_in_window => p.frame(buf, flag_rst | flag_ack, r +% 1, ""),
        .rst_outside => p.frame(buf, flag_rst | flag_ack, r +% 1000, ""),
        .ack_old, .ack_duplicate, .ack_new, .ack_future => p.frame(buf, flag_ack, r, ""),
        .data_in_order => p.frame(buf, data_flags, r, ten),
        .data_ahead => p.frame(buf, data_flags, r +% 5, ten),
        .data_behind => p.frame(buf, data_flags, r -% 20, ten),
        .data_straddling => p.frame(buf, data_flags, r -% 5, ten),
        .data_past_window => p.frame(buf, data_flags, r +% 1000, ten),
        .fin => p.frame(buf, flag_fin | flag_ack, if (setup == .peer_done) r -% 1 else r, ""),
        .fin_with_data => p.frame(buf, flag_fin | data_flags, r, ten),
    };
}

// ── a flood of SYNs (QUEUE.md item 82) ───────────────────────────────────────

test "a SYN flood does not keep a real client out: the oldest half-open connection gives way" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;
    // Spoofed SYNs from addresses that will never answer: the table fills
    // with connections waiting on a SYN-ACK nobody receives.
    var flood: u16 = 0;
    for (0..f.conns.len) |_| {
        const p = Peer{ .ip = .{ 203, 0, 113, 7 }, .port = 50000 + flood };
        flood += 1;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    }
    for (f.table.conns) |c| try testing.expectEqual(State.syn_received, c.state);

    // A real client a moment later finds every slot taken by a half-open too
    // fresh to evict (younger than a round trip): it is refused, as a burst
    // of real connections is, and Linux retries.
    var early = Peer{ .ip = .{ 10, 0, 2, 9 }, .port = 39000 };
    var buf2: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, early.frame(&buf2, flag_syn, early.seq, ""), ms);
    try testing.expectEqual(@as(u64, 1), f.table.refused);

    // Once the flood's half-opens are older than a round trip, a real client
    // gets in: the oldest stuck one gives way.
    var real = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try real.connect(&f.table, &f.wire, min_rto_ns + ms);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    try testing.expectEqual(@as(u64, 1), f.table.half_open_given_way);

    // The flood goes on; a real client between every few spoofed SYNs still
    // gets in, and keeps its slot. Time advances a round trip each step, so
    // the half-opens the flood leaves are always stuck enough to evict.
    var now: i96 = min_rto_ns + 2 * ms;
    var real_ones: u16 = 0;
    var kept: [8]usize = undefined;
    var kept_len: usize = 0;
    for (0..200) |k| {
        f.wire.count = 0; // the recording wire holds 128 frames; a flood sends more
        // A real client first, while the flood's earlier half-opens are stuck
        // (every slot holds one at least a round trip old), then a fresh
        // spoofed SYN. The real one gets in by evicting a stuck half-open; the
        // spoofed one takes a freed or stuck slot, or is refused.
        if (k % 25 == 0) {
            var c = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 41000 + real_ones };
            real_ones += 1;
            const slot = try c.connect(&f.table, &f.wire, now);
            // Established connections are not given way: hold at most two,
            // so the flood always has half-open ones to push out.
            if (kept_len < 2) {
                f.table.claim(slot);
                kept[kept_len] = slot;
                kept_len += 1;
            } else f.table.abandon(&f.wire, slot, .slow_client);
        }
        const p = Peer{ .ip = .{ 203, 0, 113, 7 }, .port = 50000 + flood };
        flood += 1;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), now);
        transmit(&f.table, &f.wire, now);
        now += min_rto_ns + ms;
    }
    for (kept[0..kept_len]) |s| try testing.expectEqual(State.established, f.table.conns[s].state);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    try testing.expect(f.table.half_open_given_way > 100);

    // The flood stops: what it left times out, and the table is whole again.
    for (kept[0..kept_len]) |s| f.table.release(s);
    while (now < 60 * ns_per_s) : (now += 100 * ms) {
        f.wire.count = 0;
        transmit(&f.table, &f.wire, now);
    }
    for (f.table.conns, 0..) |c, s| {
        if (s == i or std.mem.indexOfScalar(usize, kept[0..kept_len], s) != null) continue;
        try testing.expectEqual(State.closed, c.state);
    }
}

/// A real client's SYN, answered, and its ACK lost: it is now `seq` and
/// `ack` as if connected, and the table holds a half-open for it.
fn halfOpened(f: *Fixture, real: *Peer, now: i96) void {
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, real.frame(&buf, flag_syn, real.seq, ""), now);
    const synack = f.wire.last();
    real.seq +%= 1;
    real.ack = synack.seq +% 1;
}

/// SYNs from addresses that never answer, `n` of them at `now`.
fn floodSyns(f: *Fixture, first_port: u16, n: usize, now: i96) void {
    var buf: [1600]u8 = undefined;
    for (0..n) |k| {
        const p = Peer{ .ip = .{ 203, 0, 113, 7 }, .port = first_port + @as(u16, @intCast(k)) };
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), now);
    }
}

test "revival: a real client whose ACK was lost, its half-open given way to a flood, is revived by its next segment" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;
    var real = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    halfOpened(&f, &real, 0);
    floodSyns(&f, 50000, f.conns.len - 1, 0);
    // A round trip on, one more flood SYN finds the table full: the oldest
    // stuck half-open, the client's, gives way (the 14 rough seeds' race).
    floodSyns(&f, 51000, 1, min_rto_ns + ms);
    try testing.expectEqual(@as(u64, 1), f.table.half_open_given_way);
    for (f.table.conns) |c| try testing.expect(c.peer_port != real.port);
    // The client, believing itself connected, sends its request. Its ACK
    // names our ISS + 1: the half-open is rebuilt, in a stuck flood slot,
    // and the request is taken, not reset.
    const request = "GET / HTTP/1.1\r\n\r\n";
    const r = handle(&f.table, &f.wire, real.frame(&buf, flag_psh | flag_ack, real.seq, request), min_rto_ns + 2 * ms);
    try testing.expectEqual(Event.opened, r.event);
    try testing.expectEqual(State.established, f.table.conns[r.index].state);
    try testing.expectEqualStrings(request, f.table.conns[r.index].pending());
    try testing.expectEqual(@as(u64, 1), f.table.revived);
    try testing.expect(f.wire.last().flags & flag_rst == 0);
}

test "revival: with no stuck slot to take, the ACK is dropped, not reset, and a round trip later it gets in" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;
    var real = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    halfOpened(&f, &real, 0);
    floodSyns(&f, 50000, f.conns.len - 1, 0);
    floodSyns(&f, 51000, 1, min_rto_ns + ms); // the client's slot gives way
    // Fresh flood SYNs fill what would free up: every slot is too young to
    // give way when the client's ACK comes.
    const fresh_at = 2 * min_rto_ns + 2 * ms;
    floodSyns(&f, 52000, f.conns.len, fresh_at);
    for (f.table.conns) |c| try testing.expect(fresh_at - c.opened_at < min_rto_ns);
    const sent = f.wire.count;
    _ = handle(&f.table, &f.wire, real.frame(&buf, flag_ack, real.seq, ""), fresh_at + ms);
    try testing.expectEqual(sent, f.wire.count); // not a word: no reset
    try testing.expectEqual(@as(u64, 1), f.table.revival_no_room);
    // A round trip later the fresh ones are stuck; the client's ACK again
    // finds its entry still kept, and gets in.
    const r = handle(&f.table, &f.wire, real.frame(&buf, flag_ack, real.seq, ""), fresh_at + min_rto_ns + 2 * ms);
    try testing.expectEqual(Event.opened, r.event);
    try testing.expectEqual(@as(u64, 1), f.table.revived);
}

test "revival: only the ACK the half-open would have taken; a wrong one, a SYN or a reset never revives" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;
    var real = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    halfOpened(&f, &real, 0);
    floodSyns(&f, 50000, f.conns.len - 1, 0);
    floodSyns(&f, 51000, 1, min_rto_ns + ms);
    const at = min_rto_ns + 2 * ms;
    // An ACK one off ISS + 1: refused with a reset, as any stray is.
    var wrong = real;
    wrong.ack +%= 1;
    _ = handle(&f.table, &f.wire, wrong.frame(&buf, flag_ack, real.seq, ""), at);
    try testing.expect(f.wire.last().flags & flag_rst != 0);
    // From another port of the same address: the same.
    var other = real;
    other.port += 1;
    _ = handle(&f.table, &f.wire, other.frame(&buf, flag_ack, real.seq, ""), at);
    try testing.expect(f.wire.last().flags & flag_rst != 0);
    // A reset with the right numbers: nothing at all.
    _ = handle(&f.table, &f.wire, real.frame(&buf, flag_rst | flag_ack, real.seq, ""), at);
    try testing.expectEqual(@as(u64, 0), f.table.revived);
    // And the right ACK still revives: none of the above used its entry up.
    const r = handle(&f.table, &f.wire, real.frame(&buf, flag_ack, real.seq, ""), at);
    try testing.expectEqual(Event.opened, r.event);
    try testing.expectEqual(@as(u64, 1), f.table.revived);
}

test "a storm of resets and FINs for connections we never had leaves no trace, and a real client is served through it" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;
    // One real, established connection the host is part-way through serving.
    var real = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try real.connect(&f.table, &f.wire, 0);
    f.table.claim(i);

    // A storm of RSTs and FINs from strangers: no connection matches any of
    // them. None takes a slot, none that draws a stray reset is left behind
    // (a RST draws nothing; a FIN/ACK for no connection draws a reset).
    var k: u16 = 0;
    while (k < 500) : (k += 1) {
        f.wire.count = 0; // strays would overrun the recording wire
        const flags: u8 = if (k & 1 == 0) flag_rst else (flag_fin | flag_ack);
        const p = Peer{ .ip = .{ 198, 51, 100, @intCast(k & 0xFF) }, .port = 30000 + k };
        _ = handle(&f.table, &f.wire, p.frame(&buf, flags, p.seq, ""), @as(i96, k) * ms);
    }
    // No slot was taken: the real one, and nothing else, is in use.
    for (f.table.conns, 0..) |c, s| {
        if (s == i) {
            try testing.expectEqual(State.established, c.state);
        } else try testing.expectEqual(State.closed, c.state);
    }

    // The real client is still served: its request arrives and is pending.
    const r = real.write(&f.table, &f.wire, "GET / HTTP/1.1\r\n\r\n", 500 * ms);
    try testing.expectEqual(Event.data, r.event);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", f.table.conns[i].pending());
}

test "the first FIN's ACK arriving after a go-back acknowledges the FIN still owed (machine tcp.Fin: resending --fin_acknowledged--> acknowledged)" {
    // The sweep never reached this cell (metal-vmm QUEUE 140): after a
    // timeout's go-back the FIN is owed again behind the bytes the window
    // lets out, and the peer's ACK of the first one lands meanwhile.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 8192 };
    const i = try p.connect(&f.table, &f.wire, ms);
    var body: [2048]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.finish(i);
    transmit(&f.table, &f.wire, 2 * ms);
    try testing.expectEqual(tcp.Fin.sent, f.table.conns[i].fin.get());

    // The window narrows (no news of a loss), and the timer fires: the
    // go-back resends what the window lets out, and the FIN waits.
    p.window = 1000;
    _ = p.ackUpTo(&f.table, &f.wire, f.table.conns[i].una, 3 * ms);
    transmit(&f.table, &f.wire, 2 * ms + rto);
    try testing.expectEqual(tcp.Fin.resending, f.table.conns[i].fin.get());

    // The first FIN arrived after all, and its ACK covers it.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% @as(u32, body.len) +% 1, 2 * ms + rto + ms);
    try testing.expectEqual(tcp.Fin.acknowledged, f.table.conns[i].fin.get());
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, 2 * ms + rto + 2 * ms).event);
}

test "resets are counted by who and why: the peer's exact and inexact ones, ours for a bad ACK, the host's by reason (metal-vmm QUEUE 193, gap 6)" {
    var f: Fixture = .{};
    f.init();
    var buf: [1600]u8 = undefined;

    // An inexact reset inside the window draws a challenge ACK; an exact one
    // ends the connection.
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    _ = try a.connect(&f.table, &f.wire, 1);
    _ = handle(&f.table, &f.wire, a.frame(&buf, flag_rst, a.seq +% 10, ""), 2);
    try testing.expectEqual(@as(u64, 1), f.table.challenge_acks);
    try testing.expectEqual(@as(u64, 0), f.table.resets_received);
    try testing.expectEqual(Event.closed, handle(&f.table, &f.wire, a.frame(&buf, flag_rst, a.seq, ""), 3).event);
    try testing.expectEqual(@as(u64, 1), f.table.resets_received);

    // A SYN-RECEIVED peer whose ACK names the wrong number is reset.
    var b = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40001 };
    _ = handle(&f.table, &f.wire, b.frame(&buf, flag_syn, b.seq, ""), 4);
    b.seq +%= 1;
    b.ack = f.wire.last().seq +% 7;
    _ = handle(&f.table, &f.wire, b.frame(&buf, flag_ack, b.seq, ""), 5);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.bad_ack_resets);

    // The host's abandons, each by its reason.
    var c = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 40002 };
    f.table.abandon(&f.wire, try c.connect(&f.table, &f.wire, 6), .slow_client);
    var d = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 40003 };
    f.table.abandon(&f.wire, try d.connect(&f.table, &f.wire, 7), .stream_behind);
    var e = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 40004 };
    f.table.abandon(&f.wire, try e.connect(&f.table, &f.wire, 8), .unfinished);
    try testing.expectEqual(@as(u64, 1), f.table.abandoned_slow_client);
    try testing.expectEqual(@as(u64, 1), f.table.abandoned_stream_behind);
    try testing.expectEqual(@as(u64, 1), f.table.abandoned_unfinished);
}

/// A copy of `frame` with its IP header changed by `change` and its
/// checksum made right again (unless `keep_sum`).
fn retouched(out: []u8, frame: []const u8, change: *const fn ([]u8) void, keep_sum: bool) []const u8 {
    @memcpy(out[0..frame.len], frame);
    const ip = out[proto.eth_header_len..][0..20];
    change(ip);
    if (!keep_sum) {
        ip[10] = 0;
        ip[11] = 0;
        @memcpy(ip[10..12], &proto.be16(proto.checksum(ip)));
    }
    return out[0..frame.len];
}

test "frames passed over are counted by why: damaged IP header, fragment, not TCP, not for us, another ethertype (metal-vmm QUEUE 193, gap 8)" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    var out: [1600]u8 = undefined;
    const frame = p.frame(&buf, flag_syn, 1, "");
    const ttl = struct {
        fn change(ip: []u8) void {
            ip[8] -%= 1;
        }
    }.change;
    const fragment = struct {
        fn change(ip: []u8) void {
            ip[6] |= 0x20;
        }
    }.change;
    const udp = struct {
        fn change(ip: []u8) void {
            ip[9] = proto.proto_udp;
        }
    }.change;
    const elsewhere = struct {
        fn change(ip: []u8) void {
            ip[19] +%= 1;
        }
    }.change;
    _ = handle(&f.table, &f.wire, retouched(&out, frame, ttl, true), 1);
    try testing.expectEqual(@as(u64, 1), f.table.passed.bad_ip_checksum);
    _ = handle(&f.table, &f.wire, retouched(&out, frame, fragment, false), 1);
    try testing.expectEqual(@as(u64, 1), f.table.passed.fragments);
    _ = handle(&f.table, &f.wire, retouched(&out, frame, udp, false), 1);
    try testing.expectEqual(@as(u64, 1), f.table.passed.not_tcp);
    _ = handle(&f.table, &f.wire, retouched(&out, frame, elsewhere, false), 1);
    @memcpy(out[0..frame.len], frame);
    @memcpy(out[segment_at + 2 .. segment_at + 4], &proto.be16(8080));
    _ = handle(&f.table, &f.wire, out[0..frame.len], 1);
    try testing.expectEqual(@as(u64, 2), f.table.passed.not_for_us);
    @memcpy(out[0..frame.len], frame);
    out[12] = 0x86;
    out[13] = 0xDD;
    _ = handle(&f.table, &f.wire, out[0..frame.len], 1);
    try testing.expectEqual(@as(u64, 1), f.table.passed.other_ethertype);
    _ = handle(&f.table, &f.wire, "not a frame", 1);
    try testing.expectEqual(@as(u64, 1), f.table.passed.malformed_ip);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

// ── The pure decisions of SEGMENT ARRIVES (metal-vmm QUEUE 225, chunk 2):
// a row each, near zero and across the half-circle, where `<` would do what
// `sq.after` must.

test "acceptability: the next byte, ahead in the window, behind, and beyond it (RFC 9293 §3.10.7.4, first check)" {
    var rx: [1000]u8 = undefined;
    var tx: [16]u8 = undefined;
    const Row = struct { rcv_nxt: u32, seq: u32, want: tcp.Acceptability };
    const rows = [_]Row{
        .{ .rcv_nxt = 5000, .seq = 5000, .want = .next },
        .{ .rcv_nxt = 5000, .seq = 5001, .want = .ahead },
        .{ .rcv_nxt = 5000, .seq = 5999, .want = .ahead }, // the window's last byte
        .{ .rcv_nxt = 5000, .seq = 6000, .want = .beyond }, // its right edge, outside
        .{ .rcv_nxt = 5000, .seq = 4999, .want = .behind },
        .{ .rcv_nxt = 5000, .seq = @as(u32, 5000) -% 0x7FFF_FFFF, .want = .behind },
        .{ .rcv_nxt = 5000, .seq = @as(u32, 5000) +% 0x8000_0000, .want = .beyond }, // half the circle: not behind
        .{ .rcv_nxt = 0xFFFF_FFF0, .seq = 0x10, .want = .ahead }, // across zero
        .{ .rcv_nxt = 0x10, .seq = 0xFFFF_FFF0, .want = .behind }, // back across zero
    };
    for (rows) |r| {
        const c: Conn = .{ .rx = &rx, .tx = &tx, .rcv_nxt = r.rcv_nxt, .state = .established };
        testing.expectEqual(r.want, tcp.acceptability(&c, r.seq)) catch |e| {
            std.debug.print("acceptability: rcv_nxt {x}, seq {x}\n", .{ r.rcv_nxt, r.seq });
            return e;
        };
    }
}

test "resetCheck: exact at RCV.NXT, a challenge elsewhere in the window, ignored outside it (RFC 9293 §3.10.7.4, after RFC 5961)" {
    var rx: [1000]u8 = undefined;
    var tx: [16]u8 = undefined;
    const Row = struct { rcv_nxt: u32, seq: u32, want: tcp.ResetCheck };
    const rows = [_]Row{
        .{ .rcv_nxt = 5000, .seq = 5000, .want = .exact },
        .{ .rcv_nxt = 5000, .seq = 5001, .want = .challenge },
        .{ .rcv_nxt = 5000, .seq = 5999, .want = .challenge },
        .{ .rcv_nxt = 5000, .seq = 6000, .want = .ignore },
        .{ .rcv_nxt = 5000, .seq = 4999, .want = .ignore },
        .{ .rcv_nxt = 0xFFFF_FFFF, .seq = 0, .want = .challenge }, // across zero
    };
    for (rows) |r| {
        const c: Conn = .{ .rx = &rx, .tx = &tx, .rcv_nxt = r.rcv_nxt, .state = .established };
        testing.expectEqual(r.want, tcp.resetCheck(&c, r.seq)) catch |e| {
            std.debug.print("resetCheck: rcv_nxt {x}, seq {x}\n", .{ r.rcv_nxt, r.seq });
            return e;
        };
    }
}

test "ackCheck: the handshake's ACK names ISS + 1; after it, new, duplicate, or never sent (RFC 9293 §3.10.7.4, fifth check)" {
    var rx: [16]u8 = undefined;
    var tx: [16]u8 = undefined;
    const Row = struct { state: State, una: u32, high: usize, number: u32, want: tcp.AckCheck };
    const rows = [_]Row{
        .{ .state = .syn_received, .una = 100, .high = 0, .number = 101, .want = .new },
        .{ .state = .syn_received, .una = 100, .high = 0, .number = 100, .want = .reset_it }, // ISS itself
        .{ .state = .syn_received, .una = 100, .high = 0, .number = 102, .want = .reset_it },
        .{ .state = .established, .una = 100, .high = 50, .number = 100, .want = .duplicate },
        .{ .state = .established, .una = 100, .high = 50, .number = 101, .want = .new },
        .{ .state = .established, .una = 100, .high = 50, .number = 150, .want = .new }, // all of it
        .{ .state = .established, .una = 100, .high = 50, .number = 151, .want = .ignore }, // never sent
        .{ .state = .established, .una = 100, .high = 50, .number = 99, .want = .ignore }, // from before SND.UNA
        .{ .state = .established, .una = 0xFFFF_FFF0, .high = 0x20, .number = 0x08, .want = .new }, // across zero
    };
    for (rows) |r| {
        const c: Conn = .{ .rx = &rx, .tx = &tx, .state = r.state, .una = r.una, .high = r.high };
        testing.expectEqual(r.want, tcp.ackCheck(&c, r.number)) catch |e| {
            std.debug.print("ackCheck: {t}, una {x}, high {d}, number {x}\n", .{ r.state, r.una, r.high, r.number });
            return e;
        };
    }
}

test "two connections to one ip:80 from two of our ports are two connections: a segment goes to the one its port names (metal-vmm QUEUE 225, chunk 4)" {
    var f: Fixture = .{};
    f.init();
    const site = [4]u8{ 10, 0, 2, 2 };
    // Two connections this machine opened to the same site's port 80, as
    // `connect` will (chunk 5a): set up by hand here.
    for ([_]u16{ 50000, 50001 }, 0..) |port, k| {
        const c = &f.table.conns[k];
        c.* = .{ .rx = c.rx, .tx = c.tx, .state = .established, .role = .initiated, .peer_ip = site, .peer_port = 80, .local_port = port, .rcv_nxt = 7000, .una = 9000 };
    }
    // The site answers the second of them.
    var p = Peer{ .ip = site, .port = 80, .seq = 7000, .ack = 9000, .to_port = 50001 };
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq, "HTTP/1.1 200 OK"), 1 * ms);
    try testing.expectEqual(@as(usize, 1), r.index);
    try testing.expectEqual(@as(usize, 0), f.table.conns[0].pending().len);
    try testing.expectEqualStrings("HTTP/1.1 200 OK", f.table.conns[1].pending());
    // Its acknowledgement goes out from the second connection's own port.
    try testing.expectEqual(@as(u16, 80), f.wire.last().dst_port);
    try testing.expectEqual(@as(u16, 50001), f.wire.last().src_port);
    // A port that is neither the table's nor one of its connections' is
    // not for us.
    p.to_port = 50002;
    const before = f.table.passed.not_for_us;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 2 * ms);
    try testing.expectEqual(before + 1, f.table.passed.not_for_us);
}

test "the slot kept for this machine's own connections is never taken by an accepted one (metal-vmm QUEUE 225, chunk 4)" {
    var f: Fixture = .{};
    f.init();
    f.table.reserved_for_initiated = 1;
    // Four slots: three peers connect, the fourth is refused.
    for (0..3) |k| {
        var p = Peer{ .ip = .{ 10, 0, 2, @intCast(10 + k) }, .port = 40000 };
        _ = try p.connect(&f.table, &f.wire, 0);
    }
    var q = Peer{ .ip = .{ 10, 0, 2, 20 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, q.frame(&buf, flag_syn, q.seq, ""), 0);
    try testing.expectEqual(@as(u64, 1), f.table.refused);
}

// ── SYN-SENT: this machine's own connections (metal-vmm QUEUE 225, 5a) ────

const site_ip = [4]u8{ 10, 0, 2, 2 };
const the_site: Table.Remote = .{ .mac = client_mac, .ip = site_ip, .port = 80 };

/// Opens a connection to the site and checks its SYN: from an ephemeral
/// port, to 80, numbered ISS, carrying our segment size. Returns the slot.
fn openToSite(f: *Fixture) !usize {
    return openToSiteWithin(f, far);
}

/// Deadlines no 5a test reaches.
const far: tcp.Deadlines = .{ .connect_ns = 3600 * tcp.ns_per_s, .idle_ns = 3600 * tcp.ns_per_s, .total_ns = 3600 * tcp.ns_per_s };
/// TWO-KERNELS.md §5's metal <-> metal values.
const pair: tcp.Deadlines = .{ .connect_ns = 150 * tcp.ns_per_ms, .idle_ns = 1 * tcp.ns_per_s, .total_ns = 3 * tcp.ns_per_s };

fn openToSiteWithin(f: *Fixture, d: tcp.Deadlines) !usize {
    const i = f.table.connect(&f.wire, the_site, d, 0) orelse return error.NoSlot;
    verify(&f.table, &f.wire, 0, .after_transmit);
    const syn = f.wire.last();
    try testing.expectEqual(flag_syn, syn.flags);
    try testing.expectEqual(@as(u16, tcp.ephemeral_first), syn.src_port);
    try testing.expectEqual(@as(u16, 80), syn.dst_port);
    try testing.expectEqual(f.table.conns[i].una, syn.seq);
    try testing.expectEqual(@as(?u16, tcp.our_mss), parseMss(syn.options));
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
    return i;
}

/// The site, answering from port 80 to the connection's own port.
fn siteFor(f: *const Fixture, i: usize) Peer {
    return .{ .ip = site_ip, .port = 80, .to_port = f.table.conns[i].local_port, .seq = start.peer, .mss = 1000 };
}

test "SYN-SENT: an acceptable SYN-ACK establishes the connection, and our ACK names the site's next byte (RFC 9293 §3.10.7.3, fourth)" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSite(&f);
    const iss = f.table.conns[i].una;
    var p = siteFor(&f, i);
    p.ack = iss +% 1;
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_syn | flag_ack, p.seq, ""), 3 * ms);
    try testing.expectEqual(Event.opened, r.event);
    try testing.expectEqual(i, r.index);
    const c = &f.table.conns[i];
    try testing.expectEqual(State.established, c.state);
    try testing.expectEqual(p.seq +% 1, c.rcv_nxt);
    try testing.expectEqual(iss +% 1, c.una);
    try testing.expectEqual(@as(u16, 1000), c.mss);
    try testing.expectEqual(@as(?i96, null), c.rto_at);
    const ack = f.wire.last();
    try testing.expectEqual(flag_ack, ack.flags);
    try testing.expectEqual(iss +% 1, ack.seq);
    try testing.expectEqual(p.seq +% 1, ack.ack);
    try testing.expectEqual(c.local_port, ack.src_port);
    try testing.expectEqual(@as(u64, 1), f.table.samples); // the handshake is timed
}

test "SYN-SENT: an ACK of ISS itself, or past SND.NXT, is answered with <SEQ=SEG.ACK><CTL=RST> (RFC 9293 §3.10.7.3, first)" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSite(&f);
    const iss = f.table.conns[i].una;
    var buf: [1600]u8 = undefined;
    for ([_]u32{ iss, iss +% 2 }, 1..) |number, n| {
        var p = siteFor(&f, i);
        p.ack = number;
        const from = f.wire.count;
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn | flag_ack, p.seq, ""), 3 * ms);
        try testing.expectEqual(from + 1, f.wire.count);
        const rst = f.wire.last();
        try testing.expectEqual(flag_rst, rst.flags);
        try testing.expectEqual(number, rst.seq);
        try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
        try testing.expectEqual(@as(u64, n), f.table.syn_sent_bad_acks);
    }
    // A reset with an unacceptable ACK is dropped, not answered.
    var p = siteFor(&f, i);
    p.ack = iss;
    const from = f.wire.count;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_rst | flag_ack, 0, ""), 4 * ms);
    try testing.expectEqual(from, f.wire.count);
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
}

test "SYN-SENT: a reset with an acceptable ACK refuses the connection and sends nothing back; one with no ACK is dropped (RFC 9293 §3.10.7.3, second)" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSite(&f);
    const iss = f.table.conns[i].una;
    var buf: [1600]u8 = undefined;
    var p = siteFor(&f, i);
    // No ACK: dropped. Its number is 0, which is RCV.NXT's too before the
    // handshake: a dispatch that took the synchronized states' RST check
    // first would close the connection here.
    var from = f.wire.count;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_rst, 0, ""), 2 * ms);
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
    try testing.expectEqual(from, f.wire.count);
    // RST|ACK, as Linux refuses a port: <SEQ=0><ACK=ISS+1><CTL=RST,ACK>.
    p.ack = iss +% 1;
    from = f.wire.count;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_rst | flag_ack, 0, ""), 3 * ms);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(@as(u64, 1), f.table.connects_refused);
    try testing.expectEqual(from, f.wire.count);
}

test "SYN-SENT: a SYN with no ACK, a simultaneous open, is dropped and counted; a bare acceptable ACK is dropped (RFC 9293 §3.10.7.3, fourth and fifth)" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSite(&f);
    const iss = f.table.conns[i].una;
    var buf: [1600]u8 = undefined;
    var p = siteFor(&f, i);
    const from = f.wire.count;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_syn, p.seq, ""), 2 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.simultaneous_opens_refused);
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
    p.ack = iss +% 1;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 3 * ms);
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
    try testing.expectEqual(from, f.wire.count);
}

test "SYN-SENT: a SYN unanswered is sent again by the timer, untimed, and the connection given up after the last" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSite(&f);
    const iss = f.table.conns[i].una;
    const from = f.wire.count;
    transmit(&f.table, &f.wire, f.table.conns[i].rto_at.?);
    try testing.expectEqual(from + 1, f.wire.count);
    try testing.expectEqual(flag_syn, f.wire.last().flags);
    try testing.expectEqual(iss, f.wire.last().seq);
    try testing.expectEqual(@as(?i96, null), f.table.conns[i].timed_at);
    while (f.table.conns[i].state != .closed) transmit(&f.table, &f.wire, f.table.conns[i].rto_at.?);
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
}

test "synSent: each of the RFC's answers, by its ACK and its bits (RFC 9293 §3.10.7.3)" {
    var rx: [16]u8 = undefined;
    var tx: [16]u8 = undefined;
    const c: Conn = .{ .rx = &rx, .tx = &tx, .state = .syn_sent, .una = 0xFFFF_FFFF }; // ISS; SND.NXT is 0
    const Row = struct { ctl: tcp.Ctl, ack: u32, want: tcp.SynSent };
    const rows = [_]Row{
        .{ .ctl = .{ .syn = true, .ack = true }, .ack = 0, .want = .established }, // ISS + 1, across zero
        .{ .ctl = .{ .syn = true, .ack = true }, .ack = 0xFFFF_FFFF, .want = .reset_it }, // ISS itself
        .{ .ctl = .{ .syn = true, .ack = true }, .ack = 1, .want = .reset_it }, // past SND.NXT
        .{ .ctl = .{ .rst = true, .ack = true }, .ack = 0, .want = .refused },
        .{ .ctl = .{ .rst = true, .ack = true }, .ack = 1, .want = .drop }, // a reset, unacceptable
        .{ .ctl = .{ .rst = true }, .ack = 0, .want = .drop },
        .{ .ctl = .{ .syn = true }, .ack = 0, .want = .simultaneous_open },
        .{ .ctl = .{ .ack = true }, .ack = 0, .want = .drop },
        .{ .ctl = .{}, .ack = 0, .want = .drop },
    };
    for (rows) |r| {
        const seg: tcp.Segment = .{ .src_port = 80, .dst_port = 49152, .seq = 5, .ack = r.ack, .ctl = r.ctl, .window = 100 };
        testing.expectEqual(r.want, tcp.synSent(&c, seg)) catch |e| {
            std.debug.print("synSent: ctl {any}, ack {x}\n", .{ r.ctl, r.ack });
            return e;
        };
    }
}

// ── a connection of our own's deadlines (metal-vmm QUEUE 225, 5b) ─────────

/// The site's SYN-ACK to connection `i`, at `now`.
fn establish(f: *Fixture, i: usize, now: i96) !Peer {
    var p = siteFor(f, i);
    p.ack = f.table.conns[i].una +% 1;
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_syn | flag_ack, p.seq, ""), now);
    try testing.expectEqual(Event.opened, r.event);
    p.seq +%= 1;
    return p;
}

test "SYN-SENT: our SYN is sent again at 25 ms, then 50 ms later, not at the server's 200 ms floor" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSiteWithin(&f, pair);
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 25 * ms - 1);
    try testing.expectEqual(from, f.wire.count);
    transmit(&f.table, &f.wire, 25 * ms);
    try testing.expectEqual(from + 1, f.wire.count);
    try testing.expectEqual(flag_syn, f.wire.last().flags);
    try testing.expectEqual(@as(?i96, 75 * ms), f.table.conns[i].rto_at);
    transmit(&f.table, &f.wire, 75 * ms);
    try testing.expectEqual(from + 2, f.wire.count);
    try testing.expectEqual(@as(?i96, 175 * ms), f.table.conns[i].rto_at);
}

test "SYN-SENT: not established by deadlines.connect_ns, the connection is let go with no reset (RFC 9293 §3.10.5, ABORT in SYN-SENT)" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSiteWithin(&f, pair);
    transmit(&f.table, &f.wire, 25 * ms);
    transmit(&f.table, &f.wire, 75 * ms);
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 150 * ms - 1);
    try testing.expectEqual(State.syn_sent, f.table.conns[i].state);
    transmit(&f.table, &f.wire, 150 * ms);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(from, f.wire.count);
    try testing.expectEqual(@as(u64, 1), f.table.connect_deadlines);
    try testing.expectEqual(@as(u64, 0), f.table.given_up);
    verify(&f.table, &f.wire, 150 * ms, .after_transmit);
}

test "a connection of our own whose peer is silent for deadlines.idle_ns is reset; one heard from is not" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSiteWithin(&f, pair);
    var p = try establish(&f, i, 3 * ms);
    // Heard at 500 ms: the idle clock starts again from there.
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), 500 * ms);
    transmit(&f.table, &f.wire, 1003 * ms);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    transmit(&f.table, &f.wire, 1500 * ms - 1);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    const from = f.wire.count;
    transmit(&f.table, &f.wire, 1500 * ms);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(from + 1, f.wire.count);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.idle_deadlines);
    verify(&f.table, &f.wire, 1500 * ms, .after_transmit);
}

test "a connection of our own open for deadlines.total_ns is reset, however lately heard from" {
    var f: Fixture = .{};
    f.init();
    const i = try openToSiteWithin(&f, pair);
    var p = try establish(&f, i, 3 * ms);
    var buf: [1600]u8 = undefined;
    var now: i96 = 500 * ms;
    while (now < 3 * tcp.ns_per_s) : (now += 500 * ms) {
        _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), now);
        transmit(&f.table, &f.wire, now);
        try testing.expectEqual(State.established, f.table.conns[i].state);
    }
    _ = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, ""), now);
    transmit(&f.table, &f.wire, now);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.total_deadlines);
    try testing.expectEqual(@as(u64, 0), f.table.idle_deadlines);
}

test "pastDeadline: which deadline has passed, connect only while SYN-SENT, total before idle" {
    var rx: [16]u8 = undefined;
    var tx: [16]u8 = undefined;
    var c: Conn = .{ .rx = &rx, .tx = &tx, .state = .syn_sent, .opened_at = 100, .heard_at = 100, .deadlines = .{ .connect_ns = 10, .idle_ns = 50, .total_ns = 80 } };
    const D = ?tcp.Deadline;
    try testing.expectEqual(@as(D, null), tcp.pastDeadline(&c, 109));
    try testing.expectEqual(@as(D, .connect), tcp.pastDeadline(&c, 110));
    try testing.expectEqual(@as(D, .connect), tcp.pastDeadline(&c, 200)); // all three passed
    c.state = .established;
    try testing.expectEqual(@as(D, null), tcp.pastDeadline(&c, 149));
    try testing.expectEqual(@as(D, .idle), tcp.pastDeadline(&c, 150));
    try testing.expectEqual(@as(D, .total), tcp.pastDeadline(&c, 180)); // both passed
    c.heard_at = 170;
    try testing.expectEqual(@as(D, null), tcp.pastDeadline(&c, 179));
    c.deadlines = null; // an accepted connection: the host's to bound
    try testing.expectEqual(@as(D, null), tcp.pastDeadline(&c, 1_000_000));
}

// ── the RFC's words, held to the RFC (metal-vmm QUEUE 225, chunk 3b) ──────

/// Whitespace collapsed to single spaces, so a quote rewrapped by a comment's
/// indent still matches the text it was copied from.
fn squeeze(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |b| {
        if (std.ascii.isWhitespace(b)) {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(gpa, ' ');
        space = false;
        try out.append(gpa, b);
    }
    return out.toOwnedSlice(gpa);
}

/// The text of a quote line (`// > ...`, `/// > ...`, `//! > ...`), or null
/// for a line that is not one.
fn quoted(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    const rest = if (std.mem.startsWith(u8, t, "/// ") or std.mem.startsWith(u8, t, "//! "))
        t[4..]
    else if (std.mem.startsWith(u8, t, "// "))
        t[3..]
    else
        return null;
    if (std.mem.eql(u8, rest, ">")) return "";
    if (std.mem.startsWith(u8, rest, "> ")) return rest[2..];
    return null;
}

/// The quotes in `source` not found word for word in any of `rfcs`
/// (squeezed), and how many quotes there were.
fn checkQuotes(gpa: std.mem.Allocator, source: []const u8, rfcs: []const []const u8, missing: *std.ArrayList([]const u8)) !usize {
    var quotes: usize = 0;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (true) {
        const line = lines.next();
        if (line) |l| if (quoted(l)) |q| {
            try block.appendSlice(gpa, q);
            try block.append(gpa, '\n');
            continue;
        };
        if (block.items.len > 0) {
            quotes += 1;
            const want = try squeeze(gpa, block.items);
            const found = for (rfcs) |r| {
                if (std.mem.indexOf(u8, r, want) != null) break true;
            } else false;
            if (found) gpa.free(want) else try missing.append(gpa, want);
            block.clearRetainingCapacity();
        }
        if (line == null) break;
    }
    return quotes;
}

test "every DEPARTS line names one of tcp.zig's five reasons" {
    // **ONE STORY FOR EVERY DEPARTURE** (Steve, 2026-10-16: "a consistent
    // story in all our DEPARTS lines"): `DEPARTS (reason):`, the reason one
    // of the five tcp.zig's header defines. `reason` itself is the
    // placeholder the headers use to name the form.
    const gpa = testing.allocator;
    const io = testing.io;
    const reasons = [_][]const u8{ "bounded", "fast", "simpler", "stricter", "scale", "reason" };
    const files = [_][]const u8{ "src/tcp.zig", "src/tcp_arrives.zig", "src/tcp_timeouts.zig", "src/tcp_segment.zig" };
    var named: usize = 0;
    var unnamed: usize = 0;
    for (files) |f| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, f, gpa, .unlimited);
        defer gpa.free(source);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, "DEPARTS")) |i| {
            at = i + "DEPARTS".len;
            const rest = source[at..];
            // A heading's "DEPARTS FROM" is prose, not a line of the form.
            if (!std.mem.startsWith(u8, rest, " (") and !std.mem.startsWith(u8, rest, ":")) continue;
            const ok = for (reasons) |r| {
                if (std.mem.startsWith(u8, rest[@min(2, rest.len)..], r) and std.mem.startsWith(u8, rest[@min(2 + r.len, rest.len)..], "):")) break true;
            } else false;
            if (ok) named += 1 else {
                unnamed += 1;
                const end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
                std.debug.print("{s}: a DEPARTS line with no reason of the five: \"DEPARTS{s}\"\n", .{ f, source[at..end] });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), unnamed);
    // Not vacuous: 19 departures (2026-10-16), plus the headers' placeholders.
    try testing.expect(named >= 19);
}

test "every quote of an RFC in the tcp files is the RFC's own words (docs/rfc/)" {
    const gpa = testing.allocator;
    const io = testing.io;
    const names = [_][]const u8{ "rfc9293", "rfc6298", "rfc5681", "rfc6056" };
    var rfcs: [names.len][]u8 = undefined;
    for (names, &rfcs) |n, *r| {
        var path: [64]u8 = undefined;
        const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.bufPrint(&path, "docs/rfc/{s}.txt", .{n}), gpa, .unlimited);
        defer gpa.free(text);
        r.* = try squeeze(gpa, text);
    }
    defer for (rfcs) |r| gpa.free(r);
    const files = [_][]const u8{ "src/tcp.zig", "src/tcp_arrives.zig", "src/tcp_timeouts.zig", "src/tcp_segment.zig", "src/tcp_held.zig" };
    var missing: std.ArrayList([]const u8) = .empty;
    defer {
        for (missing.items) |m| gpa.free(m);
        missing.deinit(gpa);
    }
    var quotes: usize = 0;
    for (files) |f| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, f, gpa, .unlimited);
        defer gpa.free(source);
        const before = missing.items.len;
        quotes += try checkQuotes(gpa, source, &.{ rfcs[0], rfcs[1], rfcs[2], rfcs[3] }, &missing);
        for (missing.items[before..]) |m| std.debug.print("{s}: a quote not in docs/rfc/: \"{s}\"\n", .{ f, m });
    }
    try testing.expectEqual(@as(usize, 0), missing.items.len);
    // Not vacuous: the quotes are there to be checked.
    try testing.expect(quotes >= 10);
}

test "the quote check finds a word changed" {
    const gpa = testing.allocator;
    var missing: std.ArrayList([]const u8) = .empty;
    defer {
        for (missing.items) |m| gpa.free(m);
        missing.deinit(gpa);
    }
    const rfc = "Fifth, if neither of the SYN or RST bits is set, then drop the segment and return.";
    const good = "    // > Fifth, if neither of the SYN or RST bits is set, then drop the\n    // > segment and return.\n";
    const bad = "    // > Fifth, if neither of the SYN or RST bits is set, then keep the\n    // > segment and return.\n";
    try testing.expectEqual(@as(usize, 1), try checkQuotes(gpa, good, &.{rfc}, &missing));
    try testing.expectEqual(@as(usize, 0), missing.items.len);
    try testing.expectEqual(@as(usize, 1), try checkQuotes(gpa, bad, &.{rfc}, &missing));
    try testing.expectEqual(@as(usize, 1), missing.items.len);
}

// ── a window that shuts with bytes in flight, and reopens (QUEUE 227) ─────

test "a window that shuts with bytes in flight and refuses its probes: once it reopens, the rest arrives within a few round trips (metal-vmm QUEUE 227)" {
    // long.sh's rough `shut-window` case, small: the peer takes some,
    // shuts its window with segments still on the way (lost to it, having
    // no room), refuses each one-byte probe, and later opens again with an
    // ACK that acknowledges nothing. 0a cut what follows to one segment past
    // the refused probe byte, which the peer drops as ahead of a hole.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 1600 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const total = 2000; // the fixture's send buffer holds 2048
    var body: [total]u8 = undefined;
    for (&body, 0..) |*b, k| b.* = @truncate(k *% 7 +% 1);
    try testing.expectEqual(@as(usize, total), f.table.queue(i, &body));
    const base = p.ack; // the byte numbered 0
    transmit(&f.table, &f.wire, 0);
    // It takes one segment and shuts; the rest of the 1600 is lost to it.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, base +% 536, 2 * ms);
    var now: i96 = 2 * ms;
    for (0..3) |_| {
        now = f.table.conns[i].rto_at.?;
        transmit(&f.table, &f.wire, now);
        _ = p.ackUpTo(&f.table, &f.wire, base +% 536, now + 1 * ms); // refused
    }
    try testing.expect(f.table.probes >= 3);
    // It opens again: an ACK of nothing new, with room.
    const reopened = now + 50 * ms;
    p.window = 8000;
    _ = p.ackUpTo(&f.table, &f.wire, base +% 536, reopened);
    // A peer that takes each segment at the next byte, and acknowledges it
    // a millisecond later; one ahead of the next byte is dropped and
    // answered with an ACK of what it has.
    var got: u32 = 536;
    var seen = f.wire.count;
    now = reopened;
    while (got < total) : (now += 1 * ms) {
        try testing.expect(now - reopened <= 30 * ms); // a few round trips
        transmit(&f.table, &f.wire, now);
        var answer = false;
        while (seen < f.wire.count) : (seen += 1) {
            const s = f.wire.at(seen);
            if (s.payload.len == 0) continue;
            answer = true;
            if (s.seq == base +% got) got += @intCast(s.payload.len);
        }
        if (answer) _ = p.ackUpTo(&f.table, &f.wire, base +% got, now + 1 * ms);
    }
    try testing.expectEqual(@as(u64, 0), f.table.given_up);
}

// ── segments held ahead of a hole (metal-vmm QUEUE 226) ────────────────────

/// Sends `data` at `off` bytes past the peer's next byte, as is, and
/// answers the table's ACK.
fn sendAt(f: *Fixture, p: *const Peer, off: u32, flags: u8, data: []const u8, now: i96) Wire.Seg {
    var buf: [1600]u8 = undefined;
    _ = handle(&f.table, &f.wire, p.frame(&buf, flags, p.seq +% off, data), now);
    return f.wire.last();
}

test "a segment ahead of a hole is held, and the one that fills the hole delivers both, with one ACK of the new RCV.NXT" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    // "world" arrives first, ahead of "hello ".
    const dup = sendAt(&f, &p, 6, flag_psh | flag_ack, "world", 1 * ms);
    try testing.expectEqual(p.seq, dup.ack); // a duplicate ACK, asking for the hole
    try testing.expectEqual(@as(usize, 0), c.pending().len);
    try testing.expectEqual(@as(u64, 1), f.table.held_segments);
    const from = f.wire.count;
    const ack = sendAt(&f, &p, 0, flag_psh | flag_ack, "hello ", 2 * ms);
    try testing.expectEqual(from + 1, f.wire.count); // one ACK
    try testing.expectEqual(p.seq +% 11, ack.ack);
    try testing.expectEqualStrings("hello world", c.pending());
    try testing.expectEqual(@as(u64, 5), f.table.held_delivered);
    try testing.expect(c.held.empty());
}

test "pieces that overlap what is held, or each other, are delivered once" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    const text = "0123456789abcdefghij";
    _ = sendAt(&f, &p, 10, flag_ack, text[10..15], 1 * ms);
    _ = sendAt(&f, &p, 12, flag_ack, text[12..20], 2 * ms); // overlaps, runs on
    _ = sendAt(&f, &p, 13, flag_ack, text[13..16], 3 * ms); // a repeat
    _ = sendAt(&f, &p, 4, flag_ack, text[4..11], 4 * ms); // reaches into it
    try testing.expectEqual(@as(usize, 0), c.pending().len);
    _ = sendAt(&f, &p, 0, flag_ack, text[0..6], 5 * ms); // overlaps the next
    try testing.expectEqualStrings(text, c.pending());
    try testing.expectEqual(p.seq +% 20, c.rcv_nxt);
}

test "a FIN held ahead is taken only once every byte before it is" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    _ = sendAt(&f, &p, 5, flag_fin | flag_ack, "tail", 1 * ms);
    try testing.expect(!c.peerDone());
    var buf: [1600]u8 = undefined;
    const r = handle(&f.table, &f.wire, p.frame(&buf, flag_ack, p.seq, "head "), 2 * ms);
    try testing.expectEqual(Event.peer_done, r.event);
    try testing.expect(c.peerDone());
    try testing.expectEqualStrings("head tail", c.pending());
    try testing.expectEqual(p.seq +% 10, c.rcv_nxt); // the FIN takes one
    try testing.expectEqual(p.seq +% 10, f.wire.last().ack);
}

test "a fifth piece apart from four held is dropped and counted; one that touches them is still held" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    for ([_]u32{ 2, 6, 10, 14 }) |off| _ = sendAt(&f, &p, off, flag_ack, "x", 1 * ms);
    try testing.expectEqual(@as(u8, 4), c.held.n);
    _ = sendAt(&f, &p, 18, flag_ack, "x", 2 * ms);
    try testing.expectEqual(@as(u64, 1), f.table.held_refused_full);
    _ = sendAt(&f, &p, 3, flag_ack, "yyy", 3 * ms); // 3..6, joining 2 and 6
    try testing.expectEqual(@as(u8, 3), c.held.n);
    try testing.expectEqual(@as(u64, 1), f.table.held_refused_full);
}

test "what is held moves with the buffer when the reader's bytes are let go" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    const c = &f.table.conns[i];
    // 40 bytes read up to `end`, then a piece held 5 past it.
    var forty: [40]u8 = undefined;
    @memset(&forty, 'a');
    _ = p.write(&f.table, &f.wire, &forty, 1 * ms);
    _ = sendAt(&f, &p, 5, flag_ack, "HELD", 2 * ms);
    // Most of it read: the buffer compacts, past half (`consume`).
    c.consume(38);
    _ = sendAt(&f, &p, 0, flag_ack, "fills", 3 * ms);
    try testing.expectEqualStrings("aafillsHELD", c.pending());
    // All of it read: back to the start, with a new piece held.
    _ = sendAt(&f, &p, 13, flag_ack, "LATER", 4 * ms);
    c.consume(c.pending().len);
    _ = sendAt(&f, &p, 9, flag_ack, "then", 5 * ms);
    try testing.expectEqualStrings("thenLATER", c.pending());
}
