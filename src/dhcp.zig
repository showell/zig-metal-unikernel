//! A DHCP client: DISCOVER, OFFER, REQUEST, ACK.
//!
//! This is the first protocol a machine with no operating system needs, and it
//! is a good first one to write: it is short, it is request/response, and
//! there is a server on the other side of QEMU's user-mode networking that
//! answers it without anything being configured.
//!
//! It is also the same exchange Cobblestone's `dhcp-acquire` performs through
//! the Roc machine, which makes the two directly comparable -- one written in
//! zig against a virtio NIC, one in Roc against an emulated NE2000, both
//! ending in a lease. That was the point of doing this one first.
//!
//! **A LOST MESSAGE IS ASKED AGAIN** (RFC 2131 §4.1): each message waits about
//! four seconds for its answer, then is sent again, the wait doubling up to 64
//! seconds, each wait moved by up to a second either way at random so that
//! machines that lost the same frame do not ask again in step. It used to send
//! once and spin twenty million times, so a single lost frame on a real
//! network left the machine with no address forever (found by metal-vmm's
//! `WIRE_EAT`, 2026-09-18). The waits are durations, so the machine's clock
//! must be started first (`pit.calibrate` and `io.startClock`, or
//! `wallclock.start`).
//!
//! What it does NOT do: renew, rebind, decline, or try again after a NAK: a
//! NAK ends the exchange as `Refused` (metal-vmm QUEUE 172: it read as no
//! reply at all, `NoOffer` or `NoAck`). A lease here is taken once and kept
//! until the machine stops; its length is read (`Lease.seconds`) so
//! /admin/host can say when the machine has run past it.

const proto = @import("proto.zig");
const net = @import("net.zig");
const rng = @import("rng.zig");
const io = @import("io.zig");

const port_server: u16 = 67;
const port_client: u16 = 68;

const op_request: u8 = 1;
const op_reply: u8 = 2;
const htype_ethernet: u8 = 1;

/// The four bytes that say the options area is DHCP and not plain BOOTP.
const magic_cookie = [4]u8{ 0x63, 0x82, 0x53, 0x63 };

const opt_subnet_mask: u8 = 1;
const opt_router: u8 = 3;
const opt_dns: u8 = 6;
const opt_requested_ip: u8 = 50;
const opt_lease_time: u8 = 51;
const opt_message_type: u8 = 53;
const opt_server_id: u8 = 54;
const opt_param_list: u8 = 55;
const opt_end: u8 = 255;

const msg_discover: u8 = 1;
const msg_offer: u8 = 2;
const msg_request: u8 = 3;
const msg_ack: u8 = 5;
const msg_nak: u8 = 6;

/// The fixed part of a BOOTP message, before the options.
const bootp_len: usize = 236;

pub const Lease = struct {
    address: [4]u8 = proto.ip_any,
    mask: [4]u8 = proto.ip_any,
    router: [4]u8 = proto.ip_any,
    dns: [4]u8 = proto.ip_any,
    server: [4]u8 = proto.ip_any,
    /// The hardware address the lease came from: on QEMU's user network, the
    /// gateway's, which is where a datagram for the host goes.
    server_mac: [6]u8 = proto.mac_broadcast,
    /// **HOW LONG THE SERVER LENT THE ADDRESS** (option 51), in seconds, or
    /// null when the ACK did not say (metal-vmm QUEUE 193, gap 12). Never
    /// renewed: /admin/host says it, and says when the machine has run past
    /// it.
    seconds: ?u32 = null,
};

pub const Error = error{ NoOffer, NoAck, Refused };

/// Fills the BOOTP fixed fields and the cookie, and answers where options
/// start.
fn writeBootp(p: []u8, xid: u32, mac: [6]u8) usize {
    @memset(p[0..bootp_len], 0);
    p[0] = op_request;
    p[1] = htype_ethernet;
    p[2] = 6; // hardware address length
    p[3] = 0; // hops
    @memcpy(p[4..8], &proto.be32(xid));
    // **THE BROADCAST FLAG MATTERS.** We have no address yet, so a server that
    // replies by unicast would have to ARP for an address we cannot answer to.
    // Asking it to broadcast its reply is what makes the exchange work at all,
    // so every request asks.
    @memcpy(p[10..12], &proto.be16(0x8000));
    @memcpy(p[28..34], &mac); // chaddr
    @memcpy(p[236..240], &magic_cookie);
    return 240;
}

fn option(p: []u8, at: usize, code: u8, value: []const u8) usize {
    p[at] = code;
    p[at + 1] = @intCast(value.len);
    @memcpy(p[at + 2 ..][0..value.len], value);
    return at + 2 + value.len;
}

/// Walks the options area looking for one code. Answers its value, or null.
/// A malformed option list ends the walk rather than running off the end.
fn findOption(payload: []const u8, want: u8) ?[]const u8 {
    if (payload.len < 240) return null;
    var at: usize = 240;
    while (at < payload.len) {
        const code = payload[at];
        if (code == opt_end) return null;
        if (code == 0) { // pad
            at += 1;
            continue;
        }
        if (at + 1 >= payload.len) return null;
        const len = payload[at + 1];
        if (at + 2 + len > payload.len) return null;
        if (code == want) return payload[at + 2 ..][0..len];
        at += 2 + len;
    }
    return null;
}

fn messageType(payload: []const u8) ?u8 {
    const v = findOption(payload, opt_message_type) orelse return null;
    return if (v.len == 1) v[0] else null;
}

fn ipOption(payload: []const u8, code: u8) [4]u8 {
    const v = findOption(payload, code) orelse return proto.ip_any;
    return if (v.len >= 4) v[0..4].* else proto.ip_any;
}

/// A reply to our exchange: the right transaction, addressed to our port, and
/// a BOOTP reply rather than someone else's request.
fn replyFor(payload: []const u8, xid: u32, mac: [6]u8) bool {
    if (payload.len < 240) return false;
    if (payload[0] != op_reply) return false;
    if (proto.readBe32(payload[4..8]) != xid) return false;
    return std_mem_eql(payload[28..34], &mac);
}

/// What one datagram is to an exchange waiting for a `want`: not ours (or
/// not yet), the reply it waits for, or the server's refusal, a NAK.
const Reply = enum { other, wanted, refused };

fn replyKind(payload: []const u8, xid: u32, mac: [6]u8, want: u8) Reply {
    if (!replyFor(payload, xid, mac)) return .other;
    const t = messageType(payload) orelse return .other;
    if (t == msg_nak) return .refused;
    return if (t == want) .wanted else .other;
}

fn std_mem_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// How many times a message is sent before the exchange gives up: waits of
/// about 4, 8, 16, 32, 64 and 64 seconds, a little over three minutes in all.
pub const attempts: u32 = 6;

/// The wait after attempt `n` (0 is the first), in nanoseconds: 4 s doubled
/// per attempt up to 64 s, moved by `jitter_ns`, which is within a second
/// either way.
pub fn waitAfter(n: u32, jitter_ns: i64) u64 {
    const base_s: u64 = @as(u64, 4) << @intCast(@min(n, 4));
    const ns: i64 = @as(i64, @intCast(base_s * 1_000_000_000)) + jitter_ns;
    return @intCast(ns);
}

fn jitter() i64 {
    return @as(i64, rng.int(u32) % 2_000_000_001) - 1_000_000_000;
}

/// Sends one message and waits for a reply of `want` type, sending it again
/// each time a wait runs out, `attempts` times in all. Answers the payload,
/// copied into `reply`, because the frame it arrived in goes back to the
/// device; null when every wait ran out, `Refused` at a NAK.
fn exchange(
    nic: *net.Net,
    frame: []u8,
    frame_len: usize,
    xid: u32,
    want: u8,
    reply: []u8,
    from_mac: *[6]u8,
) error{Refused}!?usize {
    const clock = struct {
        fn now() i96 {
            return io.awakeNs() orelse
                @panic("DHCP before the clock was started: a wait for a lost reply cannot be measured");
        }
    };
    var attempt: u32 = 0;
    while (attempt < attempts) : (attempt += 1) {
        nic.send(frame[0..frame_len]);
        const deadline = clock.now() + waitAfter(attempt, jitter());
        while (clock.now() < deadline) {
            const got = nic.poll() orelse {
                asm volatile ("pause");
                continue;
            };
            defer nic.recycle(got.id);

            const dg = proto.parseUdp(got.frame) orelse continue;
            if (dg.dst_port != port_client or dg.src_port != port_server) continue;
            switch (replyKind(dg.payload, xid, nic.mac, want)) {
                .other => continue,
                .refused => return error.Refused,
                .wanted => {},
            }

            const n = @min(dg.payload.len, reply.len);
            @memcpy(reply[0..n], dg.payload[0..n]);
            from_mac.* = got.frame[6..12].*;
            return n;
        }
    }
    return null;
}

/// The whole exchange. `frame` and `reply` are scratch the caller owns;
/// `frame` must be at least a frame long and `reply` at least 576 bytes.
pub fn acquire(nic: *net.Net, frame: []u8, reply: []u8) Error!Lease {
    // **THE TRANSACTION ID IS DRAWN, NOT WRITTEN DOWN.** It has to be unlike
    // the last one on this wire, and it used to be a constant in the caller.
    const xid = rng.int(u32);

    // DISCOVER
    var at = writeBootp(frame[proto.udp_payload_at..], xid, nic.mac);
    const p = frame[proto.udp_payload_at..];
    at = option(p, at, opt_message_type, &.{msg_discover});
    at = option(p, at, opt_param_list, &.{ opt_subnet_mask, opt_router, opt_dns });
    p[at] = opt_end;
    at += 1;

    var len = proto.writeUdp(frame, nic.mac, proto.mac_broadcast, proto.ip_any, proto.ip_broadcast, port_client, port_server, at);
    var from_mac: [6]u8 = undefined;
    const offer_len = (try exchange(nic, frame, len, xid, msg_offer, reply, &from_mac)) orelse return Error.NoOffer;
    const offer = reply[0..offer_len];

    var lease = Lease{
        .address = offer[16..20].*, // yiaddr
        .mask = ipOption(offer, opt_subnet_mask),
        .router = ipOption(offer, opt_router),
        .dns = ipOption(offer, opt_dns),
        .server = ipOption(offer, opt_server_id),
    };

    // REQUEST: name the address offered and the server that offered it, so a
    // second server on the wire knows its own offer was declined.
    at = writeBootp(p, xid, nic.mac);
    at = option(p, at, opt_message_type, &.{msg_request});
    at = option(p, at, opt_requested_ip, &lease.address);
    at = option(p, at, opt_server_id, &lease.server);
    p[at] = opt_end;
    at += 1;

    len = proto.writeUdp(frame, nic.mac, proto.mac_broadcast, proto.ip_any, proto.ip_broadcast, port_client, port_server, at);
    const ack_len = (try exchange(nic, frame, len, xid, msg_ack, reply, &from_mac)) orelse return Error.NoAck;
    takeAck(&lease, reply[0..ack_len]);
    lease.server_mac = from_mac;

    return lease;
}

/// The ACK is the authority, not the offer: a server may hand over
/// something other than what it offered.
fn takeAck(lease: *Lease, ack: []const u8) void {
    lease.address = ack[16..20].*;
    if (findOption(ack, opt_subnet_mask) != null) lease.mask = ipOption(ack, opt_subnet_mask);
    if (findOption(ack, opt_router) != null) lease.router = ipOption(ack, opt_router);
    if (findOption(ack, opt_dns) != null) lease.dns = ipOption(ack, opt_dns);
    if (findOption(ack, opt_server_id) != null) lease.server = ipOption(ack, opt_server_id);
    if (findOption(ack, opt_lease_time)) |v| {
        if (v.len == 4) lease.seconds = proto.readBe32(v[0..4]);
    }
}

test "acquire reports the lease time the ACK names (metal-vmm QUEUE 193, gap 12)" {
    const mac = [6]u8{ 2, 0, 0, 0, 0, 7 };
    var p: [300]u8 = undefined;
    var at = writeBootp(&p, 0x1234, mac);
    p[0] = op_reply;
    at = option(&p, at, opt_message_type, &.{msg_ack});
    at = option(&p, at, opt_lease_time, &proto.be32(86400));
    p[at] = opt_end;
    var lease: Lease = .{};
    takeAck(&lease, p[0 .. at + 1]);
    if (lease.seconds != 86400) return error.TestUnexpectedResult;
    // An ACK that does not say leaves it unsaid; a malformed one too.
    var q: [300]u8 = undefined;
    at = writeBootp(&q, 0x1234, mac);
    q[0] = op_reply;
    at = option(&q, at, opt_message_type, &.{msg_ack});
    const short = at;
    q[at] = opt_end;
    lease = .{};
    takeAck(&lease, q[0 .. at + 1]);
    if (lease.seconds != null) return error.TestUnexpectedResult;
    at = option(&q, short, opt_lease_time, &.{ 1, 2 });
    q[at] = opt_end;
    takeAck(&lease, q[0 .. at + 1]);
    if (lease.seconds != null) return error.TestUnexpectedResult;
}

test "a NAK is the server's refusal, never a reply that did not come (metal-vmm QUEUE 172)" {
    const mac = [6]u8{ 2, 0, 0, 0, 0, 7 };
    var p: [300]u8 = undefined;
    for ([_]struct { t: u8, want: u8, kind: Reply }{
        .{ .t = msg_nak, .want = msg_offer, .kind = .refused },
        .{ .t = msg_nak, .want = msg_ack, .kind = .refused },
        .{ .t = msg_offer, .want = msg_offer, .kind = .wanted },
        .{ .t = msg_ack, .want = msg_ack, .kind = .wanted },
        .{ .t = msg_offer, .want = msg_ack, .kind = .other },
    }) |c| {
        var at = writeBootp(&p, 0x1234, mac);
        p[0] = op_reply;
        at = option(&p, at, opt_message_type, &.{c.t});
        p[at] = opt_end;
        if (replyKind(p[0 .. at + 1], 0x1234, mac, c.want) != c.kind) return error.TestUnexpectedResult;
        // Another transaction's NAK, or another machine's, is not ours.
        if (replyKind(p[0 .. at + 1], 0x1235, mac, c.want) != .other) return error.TestUnexpectedResult;
    }
}

test "each wait doubles from four seconds and stops at sixty-four" {
    const std = @import("std");
    const want = [_]u64{ 4, 8, 16, 32, 64, 64, 64 };
    for (want, 0..) |seconds, n| {
        try std.testing.expectEqual(seconds * 1_000_000_000, waitAfter(@intCast(n), 0));
    }
    // A second either way, never more.
    try std.testing.expectEqual(@as(u64, 3_000_000_000), waitAfter(0, -1_000_000_000));
    try std.testing.expectEqual(@as(u64, 65_000_000_000), waitAfter(9, 1_000_000_000));
}

// **A FRAME OF ANY BYTES** (QUEUE.md item 80): what a stranger on the wire,
// or a damaged frame, hands the parsers a booting machine runs first. Each
// is refused or parsed with every slice inside the frame; a bounds check
// that fired here would stop the machine, in ReleaseSafe as in Debug.
test "a frame of any bytes is refused or parsed inside itself, by UDP, ARP and DHCP's options" {
    const std = @import("std");
    const arp = @import("arp.zig");
    const mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    var good: [600]u8 = undefined;
    // A real OFFER for transaction 7, as a server would send it.
    const p = good[proto.udp_payload_at..];
    var at = writeBootp(p, 7, mac);
    p[0] = op_reply;
    at = option(p, at, opt_message_type, &.{msg_offer});
    at = option(p, at, opt_subnet_mask, &.{ 255, 255, 255, 0 });
    at = option(p, at, opt_router, &.{ 10, 0, 2, 2 });
    p[at] = opt_end;
    at += 1;
    const len = proto.writeUdp(&good, mac, proto.mac_broadcast, .{ 10, 0, 2, 2 }, proto.ip_broadcast, port_server, port_client, at);
    try std.testing.expect(replyFor(proto.parseUdp(good[0..len]).?.payload, 7, mac));

    var prng = std.Random.DefaultPrng.init(80);
    const r = prng.random();
    var frame: [600]u8 = undefined;
    var parsed: u32 = 0;
    for (0..200_000) |k| {
        var n: usize = len;
        @memcpy(frame[0..len], good[0..len]);
        switch (k % 4) {
            // Noise, of any length.
            0 => {
                n = r.uintAtMost(usize, frame.len);
                r.bytes(frame[0..n]);
            },
            // The OFFER cut short anywhere.
            1 => n = r.uintAtMost(usize, len),
            // A few bytes of it changed: lengths, options, types.
            2 => for (0..r.intRangeAtMost(usize, 1, 6)) |_| {
                frame[r.uintLessThan(usize, len)] = r.int(u8);
            },
            // Changed past the IP header, which is then made to check again,
            // so the damage reaches UDP and DHCP rather than stopping there.
            else => {
                for (0..r.intRangeAtMost(usize, 1, 6)) |_| {
                    frame[r.intRangeLessThan(usize, proto.eth_header_len + 2, len)] = r.int(u8);
                }
                const ip = frame[proto.eth_header_len..][0..proto.ip_header_len];
                if (ip[0] == 0x45) {
                    ip[10] = 0;
                    ip[11] = 0;
                    const sum = proto.checksum(ip);
                    ip[10] = @truncate(sum >> 8);
                    ip[11] = @truncate(sum);
                }
            },
        }
        const f = frame[0..n];
        const lo = @intFromPtr(f.ptr);
        if (proto.parseUdp(f)) |dg| {
            parsed += 1;
            try std.testing.expect(@intFromPtr(dg.payload.ptr) >= lo and @intFromPtr(dg.payload.ptr) + dg.payload.len <= lo + n);
            _ = replyFor(dg.payload, 7, mac);
            _ = messageType(dg.payload);
            _ = ipOption(dg.payload, opt_router);
            if (findOption(dg.payload, opt_subnet_mask)) |v| {
                try std.testing.expect(@intFromPtr(v.ptr) + v.len <= lo + n);
            }
        }
        _ = arp.parseRequest(f);
    }
    // The damage reached past the IP header often enough to mean something.
    try std.testing.expect(parsed > 20_000);
}
