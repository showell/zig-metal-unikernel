//! **ONE GET, AND HOW IT ENDED** (metal-vmm QUEUE 225, chunks 8 and 9):
//! what the two clients of tcp.zig's `connect` share, `native/fetch.zig` on
//! Linux and `probe/fetch.zig` in the kernel. Pure: the answer is read from
//! bytes handed in, and the outcome is a value, each with its exit code.

const std = @import("std");
const tcp = @import("tcp.zig");
const arp = @import("arp.zig");

/// **HOW A FETCH ENDS**, one exit code each, so a judge reads the outcome
/// from the status alone. 1 is the program's own: it could not start.
pub const Outcome = enum(u8) {
    /// A 200, with as many body bytes as its content-length says (or, with
    /// none, everything up to the server's FIN).
    ok = 0,
    /// The server's machine answered the SYN with a reset: no one listens.
    refused = 2,
    /// Not established by `Deadlines.connect_ns`.
    connect_deadline = 3,
    /// Nothing heard from the server for `Deadlines.idle_ns`.
    idle_deadline = 4,
    /// Not finished by `Deadlines.total_ns`.
    total_deadline = 5,
    /// The retransmission timer ran out (`max_retries`).
    given_up = 6,
    /// The server reset an established connection.
    reset = 7,
    /// Not a 200, or a head past `head_max`, or more body than it said.
    bad_answer = 8,
    /// No ARP reply for the server's address by the connect deadline.
    no_arp = 9,
    /// The server finished before the body its content-length promised.
    short_answer = 10,

    pub fn code(o: Outcome) u8 {
        return @backingInt(o);
    }
};

/// The most head an answer may have.
pub const head_max = 4096;

/// **THE ANSWER, READ AS IT ARRIVES**: the head kept until its blank line,
/// then the status and content-length taken from it; the body counted, not
/// kept (the caller sinks it).
pub const Answer = struct {
    head: [head_max]u8 = undefined,
    head_len: usize = 0,
    state: enum { head, body, bad } = .head,
    status: u16 = 0,
    length: ?u64 = null,
    body_len: u64 = 0,

    /// Takes `bytes`, the next of the answer, and returns the part of them
    /// that is body.
    pub fn feed(self: *Answer, bytes: []const u8) []const u8 {
        switch (self.state) {
            .bad => return &.{},
            .body => {
                self.body_len += bytes.len;
                return bytes;
            },
            .head => {},
        }
        // The blank line may straddle two feeds: look again from three
        // bytes back.
        const from = self.head_len -| 3;
        const room = head_max - self.head_len;
        const take = @min(room, bytes.len);
        @memcpy(self.head[self.head_len..][0..take], bytes[0..take]);
        self.head_len += take;
        const end = std.mem.indexOf(u8, self.head[from..self.head_len], "\r\n\r\n") orelse {
            if (self.head_len == head_max) self.state = .bad;
            return &.{};
        };
        const head_end = from + end + 4;
        if (!self.parseHead(self.head[0..head_end])) {
            self.state = .bad;
            return &.{};
        }
        self.state = .body;
        // What came after the blank line in this feed is body.
        const body = bytes[take - (self.head_len - head_end) ..];
        self.body_len += body.len;
        return body;
    }

    fn parseHead(self: *Answer, head: []const u8) bool {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return false;
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return false;
        var words = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = words.next();
        self.status = std.fmt.parseInt(u16, words.next() orelse return false, 10) catch return false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            self.length = std.fmt.parseInt(u64, value, 10) catch return false;
        }
        return true;
    }

    /// The whole body is here (by its content-length).
    pub fn complete(self: *const Answer) bool {
        return self.state == .body and if (self.length) |n| self.body_len >= n else false;
    }

    /// **HOW IT ENDED, ONCE THE SERVER HAS FINISHED** (its FIN taken).
    pub fn outcome(self: *const Answer) Outcome {
        if (self.state != .body or self.status != 200) return .bad_answer;
        const n = self.length orelse return .ok; // read to the FIN
        if (self.body_len < n) return .short_answer;
        if (self.body_len > n) return .bad_answer;
        return .ok;
    }
};

/// The request: `GET path` to `host`, asking the server to close after.
pub fn writeRequest(out: []u8, host: []const u8, path: []const u8) ![]u8 {
    return std.fmt.bufPrint(out, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
}

/// What a fetch is to: the server's address and port, and the path asked.
pub const Target = struct { ip: [4]u8, port: u16, path: []const u8 };

/// How often an unanswered ARP request is asked again.
pub const arp_every_ns: i96 = 100 * std.time.ns_per_ms;

/// **ONE GET, AS A MACHINE MAKES IT** (chunks 8 and 9): who has the
/// server's address (ARP, every `arp_every_ns` until the connect deadline),
/// the connection (`Table.connect`), the request, the answer read as it
/// comes, our FIN after the server's, and how it ended. Pure: frames come in
/// through `arrived`, go out through the caller's `wire`, and the time is the
/// caller's; the body goes to the caller's `sink` (anything with
/// `body([]const u8)`).
///
/// **IN A TABLE SHARED WITH A SERVER** (the bare-metal host, DESIGN-sleep.md
/// chunk 5) the host's own turn of the network hands the table every frame
/// and calls `transmit`, so the client takes only ARP (`learned`) and its own
/// step (`step`). Its connection is known by its role and its own port, never
/// by its slot alone: a reset and a stranger's SYN in one batch can hand the
/// slot to someone else. How it ended is the slot's record (`Conn.ended`), not
/// the table's counters, which every connection moves.
pub const Client = struct {
    target: Target,
    deadlines: tcp.Deadlines,
    our_ip: [4]u8,
    our_mac: [6]u8,
    request_buf: [512]u8 = undefined,
    request_len: usize = 0,
    queued: usize = 0,
    cache: arp.Cache = .{},
    asked_at: ?i96 = null,
    began: i96,
    slot: ?usize = null,
    /// The connection's own port, once it has one.
    local_port: u16 = 0,
    answer: Answer = .{},
    finished: bool = false,
    outcome: ?Outcome = null,

    pub fn init(target: Target, deadlines: tcp.Deadlines, our_ip: [4]u8, our_mac: [6]u8, now: i96) error{NoSpaceLeft}!Client {
        var c: Client = .{ .target = target, .deadlines = deadlines, .our_ip = our_ip, .our_mac = our_mac, .began = now };
        var host: [16]u8 = undefined;
        const ip = target.ip;
        const name = std.fmt.bufPrint(&host, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
        c.request_len = (try writeRequest(&c.request_buf, name, target.path)).len;
        return c;
    }

    /// **A FRAME ARRIVED.** ARP is ours: it teaches the cache, and a request
    /// for our address is answered. Anything else is the table's.
    pub fn arrived(self: *Client, table: *tcp.Table, wire: anytype, frame: []const u8, now: i96) void {
        if (arp.parse(frame)) |p| {
            self.learned(p);
            if (p.op == .request and std.mem.eql(u8, &p.target_ip, &self.our_ip)) {
                var reply: [64]u8 = undefined;
                const n = arp.writeReply(&reply, self.our_mac, self.our_ip, .{ .sender_mac = p.sender_mac, .sender_ip = p.sender_ip, .target_ip = p.target_ip });
                wire.send(reply[0..n]);
            }
            return;
        }
        _ = table.handle(wire, frame, now);
    }

    /// An ARP packet the host's turn of the network saw: the cache learns.
    pub fn learned(self: *Client, p: arp.Packet) void {
        self.cache.observe(p, self.our_ip);
    }

    /// **ONE TURN**, then the table's `transmit`: the outcome once it is
    /// known, else null. For a table the client has to itself.
    pub fn turn(self: *Client, table: *tcp.Table, wire: anytype, now: i96, sink: anytype) ?Outcome {
        const o = self.step(table, wire, now, sink);
        table.transmit(wire, now);
        return o;
    }

    /// **ONE STEP**, with no `transmit`: in a table shared with a server,
    /// the host's turn of the network transmits.
    pub fn step(self: *Client, table: *tcp.Table, wire: anytype, now: i96, sink: anytype) ?Outcome {
        if (self.outcome) |o| return o;
        const i = self.slot orelse {
            if (self.cache.lookup(self.target.ip)) |mac| {
                self.slot = table.connect(wire, .{ .mac = mac, .ip = self.target.ip, .port = self.target.port }, self.deadlines, now) orelse {
                    self.outcome = .connect_deadline; // no slot: it never connects
                    return self.outcome;
                };
                self.local_port = table.conns[self.slot.?].local_port;
                // **THE SLOT IS HELD UNTIL ITS END IS READ** (a cold review):
                // the first free slot is the next SYN's, so a stranger could
                // take this one once it closed, end too, and write its own end
                // over ours before this step read it.
                table.claim(self.slot.?);
            } else if (now - self.began >= @as(i96, @intCast(self.deadlines.connect_ns))) {
                self.outcome = .no_arp;
                return self.outcome;
            } else if (self.asked_at == null or now - self.asked_at.? >= arp_every_ns) {
                var ask: [64]u8 = undefined;
                wire.send(ask[0..arp.writeRequest(&ask, self.our_mac, self.our_ip, self.target.ip)]);
                self.asked_at = now;
            }
            return null;
        };
        const c = &table.conns[i];
        if (!self.mine(c)) {
            self.outcome = self.ended(c);
            table.release(i);
            return self.outcome;
        }
        const request = self.request_buf[0..self.request_len];
        if (c.state == .established and self.queued < request.len) self.queued += table.queue(i, request[self.queued..]);
        const pending = c.pending();
        if (pending.len > 0) {
            sink.body(self.answer.feed(pending));
            if (c.consumeReopens(pending.len)) table.ack(wire, i);
        }
        if (c.peerDone() and !self.finished and c.state == .established) {
            table.finish(i);
            self.finished = true;
        }
        return null;
    }

    /// The slot still holds this client's connection.
    fn mine(self: *const Client, c: *const tcp.Conn) bool {
        return c.state != .closed and c.role == .initiated and c.local_port == self.local_port;
    }

    /// **HOW THE CONNECTION ENDED**: once the answer was whole (the server's
    /// FIN taken, or its body by its length), the answer's; however the
    /// connection closed after (our FIN never acknowledged and a deadline,
    /// a server's reset after a whole response; metal-vmm pair.sh's eat0-25
    /// once said idle_deadline for a whole page). Else the slot's record of
    /// it, which is ours: the slot was held (`claim`) until now.
    fn ended(self: *const Client, c: *const tcp.Conn) Outcome {
        if (self.finished or self.answer.complete()) return self.answer.outcome();
        const e = c.ended.?;
        std.debug.assert(e.role == .initiated and e.local_port == self.local_port);
        return switch (e.how) {
            // Both close only after our FIN, which follows the server's: the
            // answer was over, above.
            .closed => unreachable,
            .reset_by_peer => .reset,
            .abandoned => |why| switch (why) {
                .refused => .refused,
                .connect_deadline => .connect_deadline,
                .idle_deadline => .idle_deadline,
                .total_deadline => .total_deadline,
                .silent_peer => .given_up,
                .fin_wait => unreachable,
                // The host's own reasons, for a connection it accepted, or one
                // it abandoned for its client (a body past its bound).
                .slow_client, .stream_behind, .unfinished => .reset,
                .gave_way => unreachable, // an accepted half-open's
            },
        };
    }
};

/// **WHAT A COMMAND LINE ASKS** (`fetch <ip> <port> <path> connect_ms=N
/// idle_ms=N total_ms=N`, the leading word optional; probe/fetch.zig's),
/// or why it cannot be read. The deadlines have no defaults.
pub const Ask = struct { target: Target, deadlines: tcp.Deadlines };

pub fn parseAsk(line: []const u8) error{ NoTarget, BadAddress, BadPort, NoDeadline, BadDeadline }!Ask {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    var first = words.next() orelse return error.NoTarget;
    if (std.mem.eql(u8, first, "fetch")) first = words.next() orelse return error.NoTarget;
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, first, '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10) catch return error.BadAddress;
    if (parts.next() != null) return error.BadAddress;
    const port = std.fmt.parseInt(u16, words.next() orelse return error.BadPort, 10) catch return error.BadPort;
    const path = words.next() orelse return error.NoTarget;
    var connect: ?u64 = null;
    var idle: ?u64 = null;
    var total: ?u64 = null;
    while (words.next()) |w| {
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse continue;
        const ms = std.fmt.parseInt(u64, w[eq + 1 ..], 10) catch return error.BadDeadline;
        const ns = ms * std.time.ns_per_ms;
        const name = w[0..eq];
        if (std.mem.eql(u8, name, "connect_ms")) connect = ns;
        if (std.mem.eql(u8, name, "idle_ms")) idle = ns;
        if (std.mem.eql(u8, name, "total_ms")) total = ns;
    }
    return .{
        .target = .{ .ip = ip, .port = port, .path = path },
        .deadlines = .{
            .connect_ns = connect orelse return error.NoDeadline,
            .idle_ns = idle orelse return error.NoDeadline,
            .total_ns = total orelse return error.NoDeadline,
        },
    };
}

/// **WHAT QEMU REPORTS** for a kernel that ended with `o` through
/// isa-debug-exit: `code << 1 | 1`.
pub fn qemuExit(o: Outcome) u8 {
    return o.code() << 1 | 1;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every outcome has its own exit code, and none is the program's own 1" {
    var seen: [256]bool = @splat(false);
    for (std.enums.values(Outcome)) |o| {
        try testing.expect(o.code() != 1);
        try testing.expect(!seen[o.code()]);
        seen[o.code()] = true;
    }
    try testing.expectEqual(@as(u8, 0), Outcome.ok.code());
}

test "an answer fed whole, or a byte at a time, reads the same" {
    const text = "HTTP/1.0 200 OK\r\nServer: x\r\nContent-Length: 5\r\n\r\nhello";
    var whole: Answer = .{};
    try testing.expectEqualStrings("hello", whole.feed(text));
    try testing.expect(whole.complete());
    try testing.expectEqual(Outcome.ok, whole.outcome());
    var bytewise: Answer = .{};
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (text) |b| try body.appendSlice(testing.allocator, bytewise.feed(&.{b}));
    try testing.expectEqualStrings("hello", body.items);
    try testing.expectEqual(@as(u16, 200), bytewise.status);
    try testing.expectEqual(@as(?u64, 5), bytewise.length);
    try testing.expectEqual(Outcome.ok, bytewise.outcome());
}

test "how an answer ends: short, long, not a 200, no length, not HTTP, a head too big" {
    const Row = struct { text: []const u8, want: Outcome };
    const rows = [_]Row{
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nhello", .want = .short_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhello", .want = .bad_answer },
        .{ .text = "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.0 200 OK\r\n\r\nto the end", .want = .ok },
        .{ .text = "SSH-2.0-OpenSSH\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: x\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-len", .want = .bad_answer }, // never a blank line
    };
    for (rows, 0..) |r, k| {
        var a: Answer = .{};
        _ = a.feed(r.text);
        testing.expectEqual(r.want, a.outcome()) catch |e| {
            std.debug.print("row {d}\n", .{k});
            return e;
        };
    }
    var big: Answer = .{};
    var junk: [head_max + 10]u8 = @splat('a');
    _ = big.feed(&junk);
    try testing.expectEqual(Outcome.bad_answer, big.outcome());
}

test "the request asks for the path and for the server to close" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("GET /big HTTP/1.1\r\nHost: 10.77.0.1\r\nConnection: close\r\n\r\n", try writeRequest(&buf, "10.77.0.1", "/big"));
}

// ── the client against the kernel's own server, in one process ────────────

const Loop = struct {
    /// Frames on the way, each to `to_server` or to the client, in order.
    frames: [64][1600]u8 = undefined,
    lens: [64]usize = undefined,
    to_server: [64]bool = undefined,
    n: usize = 0,

    const End = struct {
        loop: *Loop,
        server: bool,
        pub fn send(self: *End, frame: []const u8) void {
            const l = self.loop;
            if (l.n == l.frames.len) return; // full: lost, as a wire would
            @memcpy(l.frames[l.n][0..frame.len], frame);
            l.lens[l.n] = frame.len;
            l.to_server[l.n] = !self.server;
            l.n += 1;
        }
    };
};

const Sink = struct {
    got: [64]u8 = undefined,
    len: usize = 0,
    pub fn body(self: *Sink, bytes: []const u8) void {
        @memcpy(self.got[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

const Server = enum {
    answers,
    short,
    mute,
    deaf,
    absent,
    /// The request answered with a reset.
    resets,
    /// A reset, and in the same batch a stranger's SYN to the client's
    /// machine, which takes the slot the reset freed.
    resets_then_stranger,
    /// A reset, while another of the client's table's connections is given
    /// up on (its `given_up` count moves).
    resets_beside_a_give_up,
    /// The answer whole and its FIN, then deaf to everything the client
    /// sends: our FIN is never acknowledged, and a deadline ends it.
    answers_then_deaf,
    /// The answer whole by its length, then a reset once it is all
    /// acknowledged, never a FIN.
    answers_then_resets,
};

fn testIsn() u32 {
    return 77_000;
}

/// One fetch against the kernel's own table as the server, `how` it
/// behaves, a millisecond a step: the outcome, and what the sink got.
fn against(how: Server, sink: *Sink) !Outcome {
    const server_ip = [4]u8{ 10, 0, 2, 15 };
    const server_mac = [6]u8{ 2, 0, 0, 0, 0, 15 };
    const client_ip = [4]u8{ 10, 0, 2, 16 };
    const client_mac = [6]u8{ 2, 0, 0, 0, 0, 16 };
    var s_rx: [2][2048]u8 = undefined;
    var s_tx: [2][2048]u8 = undefined;
    var c_rx: [2][2048]u8 = undefined;
    var c_tx: [2][2048]u8 = undefined;
    var s_conns: [2]tcp.Conn = .{ .{ .rx = &s_rx[0], .tx = &s_tx[0] }, .{ .rx = &s_rx[1], .tx = &s_tx[1] } };
    var c_conns: [2]tcp.Conn = .{ .{ .rx = &c_rx[0], .tx = &c_tx[0] }, .{ .rx = &c_rx[1], .tx = &c_tx[1] } };
    var s_out: [1600]u8 = undefined;
    var c_out: [1600]u8 = undefined;
    var server = tcp.Table.init(server_ip, server_mac, 80, &s_conns, &s_out, testIsn);
    // A third machine, at the server's address, whose SYN the client's
    // machine accepts (it listens on 7).
    var x_rx: [1][2048]u8 = undefined;
    var x_tx: [1][2048]u8 = undefined;
    var x_conns: [1]tcp.Conn = .{.{ .rx = &x_rx[0], .tx = &x_tx[0] }};
    var x_out: [1600]u8 = undefined;
    var stranger = tcp.Table.init(server_ip, server_mac, 9, &x_conns, &x_out, testIsn);
    var client = tcp.Table.init(client_ip, client_mac, 7, &c_conns, &c_out, testIsn);
    client.reserved_for_initiated = 1;
    var loop: Loop = .{};
    var to_s: Loop.End = .{ .loop = &loop, .server = false };
    var to_c: Loop.End = .{ .loop = &loop, .server = true };
    const deadlines: tcp.Deadlines = .{ .connect_ns = 150 * std.time.ns_per_ms, .idle_ns = 1 * std.time.ns_per_s, .total_ns = 3 * std.time.ns_per_s };
    var f = try Client.init(.{ .ip = server_ip, .port = 80, .path = "/x" }, deadlines, client_ip, client_mac, 0);
    var answered = false;
    var now: i96 = 0;
    while (now < 10 * std.time.ns_per_s) : (now += std.time.ns_per_ms) {
        // Deliver what is on the way, in order.
        var k: usize = 0;
        const due = loop.n;
        var held: [64][1600]u8 = undefined;
        var held_lens: [64]usize = undefined;
        var held_to: [64]bool = undefined;
        for (0..due) |j| {
            held[j] = loop.frames[j];
            held_lens[j] = loop.lens[j];
            held_to[j] = loop.to_server[j];
        }
        loop.n = 0;
        while (k < due) : (k += 1) {
            const frame = held[k][0..held_lens[k]];
            if (held_to[k]) {
                if (how == .absent) continue;
                if (arp.parseRequest(frame)) |req| {
                    var reply: [64]u8 = undefined;
                    to_c.send(reply[0..arp.writeReply(&reply, server_mac, server_ip, req)]);
                    continue;
                }
                if (how == .deaf) continue;
                if (how == .answers_then_deaf and answered) continue;
                _ = server.handle(&to_c, frame, now);
            } else f.arrived(&client, &to_s, frame, now);
        }
        // The server's program: the request whole, then its answer.
        for (server.conns, 0..) |*c, i| {
            if (how == .answers_then_resets and answered and c.state == .established and c.highest() == c.una) {
                server.abandon(&to_c, i, .unfinished);
                continue;
            }
            if (c.state != .established or answered) continue;
            if (std.mem.indexOf(u8, c.pending(), "\r\n\r\n") == null) continue;
            answered = true;
            c.consume(c.pending().len);
            switch (how) {
                .answers, .answers_then_deaf => _ = server.queue(i, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello"),
                .answers_then_resets => {
                    _ = server.queue(i, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello");
                    continue;
                },
                .short => _ = server.queue(i, "HTTP/1.1 200 OK\r\ncontent-length: 9\r\n\r\nhello"),
                .mute => continue,
                .resets, .resets_then_stranger, .resets_beside_a_give_up => {
                    server.abandon(&to_c, i, .unfinished);
                    if (how == .resets_then_stranger) {
                        _ = stranger.connect(&to_c, .{ .mac = client_mac, .ip = client_ip, .port = 7 }, deadlines, now);
                        stranger.transmit(&to_c, now);
                    }
                    if (how == .resets_beside_a_give_up) client.given_up += 1;
                    continue;
                },
                .deaf, .absent => unreachable,
            }
            server.finish(i);
        }
        server.transmit(&to_c, now);
        if (f.turn(&client, &to_s, now, sink)) |o| return o;
    }
    return error.NeverEnded;
}

test "the client against the kernel's own server: a 200, no ARP, the connect and idle deadlines, a short answer" {
    var sink: Sink = .{};
    try testing.expectEqual(Outcome.ok, try against(.answers, &sink));
    try testing.expectEqualStrings("hello", sink.got[0..sink.len]);
    sink = .{};
    try testing.expectEqual(Outcome.no_arp, try against(.absent, &sink));
    try testing.expectEqual(Outcome.connect_deadline, try against(.deaf, &sink));
    try testing.expectEqual(Outcome.idle_deadline, try against(.mute, &sink));
    sink = .{};
    try testing.expectEqual(Outcome.short_answer, try against(.short, &sink));
}

test "a fetch reset by its server is a reset, though a stranger takes its slot in the same batch (DESIGN-sleep.md chunk 5)" {
    var sink: Sink = .{};
    try testing.expectEqual(Outcome.reset, try against(.resets, &sink));
    try testing.expectEqual(Outcome.reset, try against(.resets_then_stranger, &sink));
}

test "a fetch's end is its own connection's, not the table's: another given up meanwhile does not make a reset a give-up (DESIGN-sleep.md chunk 5)" {
    var sink: Sink = .{};
    try testing.expectEqual(Outcome.reset, try against(.resets_beside_a_give_up, &sink));
}

test "a fetch whose answer is whole is ok, however the connection ends after: our FIN unacknowledged, or a reset (DESIGN-sleep.md chunk 5; pair.sh's eat0-25)" {
    var sink: Sink = .{};
    try testing.expectEqual(Outcome.ok, try against(.answers_then_deaf, &sink));
    try testing.expectEqualStrings("hello", sink.got[0..sink.len]);
    sink = .{};
    try testing.expectEqual(Outcome.ok, try against(.answers_then_resets, &sink));
    try testing.expectEqualStrings("hello", sink.got[0..sink.len]);
}

test "a command line: target and deadlines, the leading word optional, no default deadline" {
    const a = try parseAsk("fetch 10.0.2.2 8000 /big connect_ms=150 idle_ms=1000 total_ms=3000");
    try testing.expectEqual([4]u8{ 10, 0, 2, 2 }, a.target.ip);
    try testing.expectEqual(@as(u16, 8000), a.target.port);
    try testing.expectEqualStrings("/big", a.target.path);
    try testing.expectEqual(@as(u64, 150 * std.time.ns_per_ms), a.deadlines.connect_ns);
    _ = try parseAsk("10.0.2.2 80 / total_ms=1 idle_ms=1 connect_ms=1");
    try testing.expectError(error.NoDeadline, parseAsk("fetch 10.0.2.2 80 / connect_ms=1 idle_ms=1"));
    try testing.expectError(error.BadAddress, parseAsk("fetch 10.0.2 80 / connect_ms=1 idle_ms=1 total_ms=1"));
    try testing.expectError(error.BadPort, parseAsk("fetch 10.0.2.2 http / connect_ms=1 idle_ms=1 total_ms=1"));
    try testing.expectError(error.NoTarget, parseAsk(""));
}

test "what QEMU reports for each outcome: a whole 200 is 1, a kernel that could not start is 3, and no outcome shares one" {
    const Row = struct { o: Outcome, qemu: u8 };
    const rows = [_]Row{
        .{ .o = .ok, .qemu = 1 },
        .{ .o = .refused, .qemu = 5 },
        .{ .o = .connect_deadline, .qemu = 7 },
        .{ .o = .idle_deadline, .qemu = 9 },
        .{ .o = .total_deadline, .qemu = 11 },
        .{ .o = .given_up, .qemu = 13 },
        .{ .o = .reset, .qemu = 15 },
        .{ .o = .bad_answer, .qemu = 17 },
        .{ .o = .no_arp, .qemu = 19 },
        .{ .o = .short_answer, .qemu = 21 },
    };
    try testing.expectEqual(std.enums.values(Outcome).len, rows.len);
    for (rows) |r| {
        try testing.expectEqual(r.qemu, qemuExit(r.o));
        try testing.expect(r.qemu != 3); // serial.fail's
    }
}
