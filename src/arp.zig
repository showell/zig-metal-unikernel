//! ARP (RFC 826): answering "who has this address?", and, since a kernel
//! that opens connections of its own (metal-vmm QUEUE 225, chunk 7) must
//! know a peer's hardware address before its first SYN, asking it, with a
//! cache of one.
//!
//! **A MACHINE THAT DOES NOT ANSWER ARP CANNOT BE REACHED.** Before anything
//! sends us a packet it asks the wire who owns our address, and silence means
//! the packet is never built. This is twenty-eight bytes of reply and it is the
//! difference between having an address and being at it.
//!
//! **A SERVER NEEDS NO CACHE.** Everything it sends goes to whoever sent to
//! it first, so it already knows their hardware address.
//!
//! **A CLIENT NEEDS ONE ENTRY.** It talks to one peer at a time: it asks
//! (`writeRequest`), and the answer (`parse`) goes into `Cache`, which keeps
//! it as RFC 826's packet reception does: an entry for the sender is brought
//! up to date by any packet from it, and a packet that asks for us replaces
//! the entry with its sender. Pure: when to ask again is the caller's.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const proto = @import("proto.zig");

const packet_len: usize = 28;
const htype_ethernet: u16 = 1;
const oper_request: u16 = 1;
const oper_reply: u16 = 2;

pub const Request = struct {
    /// Who is asking, so the reply can go straight back to them.
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    /// The address they want the owner of.
    target_ip: [4]u8,
};

/// An ARP request out of an ethernet frame, or null for anything else —
/// another ethertype, a reply, a hardware or protocol pair we do not speak.
pub fn parseRequest(frame: []const u8) ?Request {
    const p = parse(frame) orelse return null;
    if (p.op != .request) {
        props.reachable(@src(), "arp: an operation other than a request", null);
        return null;
    }
    return .{ .sender_mac = p.sender_mac, .sender_ip = p.sender_ip, .target_ip = p.target_ip };
}

pub const Op = enum { request, reply };

/// **AN ARP PACKET**, request or reply: who sent it, and the address it is
/// about.
pub const Packet = struct {
    op: Op,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
};

/// An ARP packet out of an ethernet frame, or null for anything else —
/// another ethertype, an operation that is neither request nor reply, a
/// hardware or protocol pair we do not speak.
pub fn parse(frame: []const u8) ?Packet {
    if (frame.len < proto.eth_header_len + packet_len) {
        props.reachable(@src(), "arp: a frame too short for an ARP packet", null);
        return null;
    }
    if (proto.readBe16(frame[12..14]) != proto.ethertype_arp) {
        props.reachable(@src(), "arp: a frame of another ethertype is not ARP", null);
        return null;
    }

    const a = frame[proto.eth_header_len..];
    if (proto.readBe16(a[0..2]) != htype_ethernet) {
        props.reachable(@src(), "arp: a hardware type other than Ethernet", null);
        return null;
    }
    if (proto.readBe16(a[2..4]) != proto.ethertype_ipv4) {
        props.reachable(@src(), "arp: a protocol type other than IPv4", null);
        return null;
    }
    if (a[4] != 6 or a[5] != 4) {
        props.reachable(@src(), "arp: address lengths other than 6 and 4", null);
        return null;
    }
    const op: Op = switch (proto.readBe16(a[6..8])) {
        oper_request => .request,
        oper_reply => .reply,
        else => {
            props.reachable(@src(), "arp: an operation other than a request or a reply", null);
            return null;
        },
    };

    return .{
        .op = op,
        .sender_mac = a[8..14].*,
        .sender_ip = a[14..18].*,
        .target_mac = a[18..24].*,
        .target_ip = a[24..28].*,
    };
}

/// Writes the reply to `req` into `out`, claiming `ip` for `mac`. Answers the
/// frame length.
pub fn writeReply(out: []u8, mac: [6]u8, ip: [4]u8, req: Request) usize {
    proto.writeEth(out, req.sender_mac, mac, proto.ethertype_arp);

    const a = out[proto.eth_header_len..][0..packet_len];
    @memcpy(a[0..2], &proto.be16(htype_ethernet));
    @memcpy(a[2..4], &proto.be16(proto.ethertype_ipv4));
    a[4] = 6;
    a[5] = 4;
    @memcpy(a[6..8], &proto.be16(oper_reply));
    @memcpy(a[8..14], &mac); // we are the sender of the reply
    @memcpy(a[14..18], &ip);
    @memcpy(a[18..24], &req.sender_mac); // and they are its target
    @memcpy(a[24..28], &req.sender_ip);

    return proto.eth_header_len + packet_len;
}

/// **WHO HAS `target_ip`?** The request into `out`, from `mac` at `ip`,
/// broadcast, with the target's hardware address zero (RFC 826: unknown,
/// it is what is asked). Answers the frame length.
pub fn writeRequest(out: []u8, mac: [6]u8, ip: [4]u8, target_ip: [4]u8) usize {
    proto.writeEth(out, proto.mac_broadcast, mac, proto.ethertype_arp);

    const a = out[proto.eth_header_len..][0..packet_len];
    @memcpy(a[0..2], &proto.be16(htype_ethernet));
    @memcpy(a[2..4], &proto.be16(proto.ethertype_ipv4));
    a[4] = 6;
    a[5] = 4;
    @memcpy(a[6..8], &proto.be16(oper_request));
    @memcpy(a[8..14], &mac);
    @memcpy(a[14..18], &ip);
    @memset(a[18..24], 0);
    @memcpy(a[24..28], &target_ip);

    return proto.eth_header_len + packet_len;
}

/// **ONE PEER'S HARDWARE ADDRESS** (RFC 826's translation table, one entry
/// long), for a machine that talks to one peer at a time.
pub const Cache = struct {
    ip: [4]u8 = proto.ip_any,
    mac: [6]u8 = @splat(0),
    known: bool = false,

    /// The hardware address of `ip`, if this is the entry for it.
    pub fn lookup(self: *const Cache, ip: [4]u8) ?[6]u8 {
        if (!self.known or !std.mem.eql(u8, &self.ip, &ip)) return null;
        return self.mac;
    }

    /// **WHAT AN ARP PACKET TEACHES** (RFC 826, "Packet Reception"), for a
    /// machine at `our_ip`. A packet from the entry's own address brings the
    /// entry's hardware address up to date, whatever it is about. Otherwise
    /// one that is about us (a reply to our request, or a request for us)
    /// puts its sender in the entry, in place of whoever was there. Anything
    /// else teaches nothing: a cache of one keeps the peer it has.
    pub fn observe(self: *Cache, p: Packet, our_ip: [4]u8) void {
        if (self.known and std.mem.eql(u8, &self.ip, &p.sender_ip)) {
            if (!std.mem.eql(u8, &self.mac, &p.sender_mac))
                props.reachable(@src(), "arp: the cached peer's hardware address changes", null);
            self.mac = p.sender_mac;
            return;
        }
        if (!std.mem.eql(u8, &p.target_ip, &our_ip)) return;
        if (self.known) props.reachable(@src(), "arp: the one entry is replaced by another peer", null);
        self.* = .{ .ip = p.sender_ip, .mac = p.sender_mac, .known = true };
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const my_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x57 };
const my_ip = [4]u8{ 10, 0, 2, 16 };
const site_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const site_ip = [4]u8{ 10, 0, 2, 15 };

test "a request asks the whole wire for the target's address, from us" {
    var frame: [64]u8 = undefined;
    const n = writeRequest(&frame, my_mac, my_ip, site_ip);
    try std.testing.expectEqual(proto.eth_header_len + packet_len, n);
    try std.testing.expectEqualSlices(u8, &proto.mac_broadcast, frame[0..6]);
    try std.testing.expectEqualSlices(u8, &my_mac, frame[6..12]);
    const p = parse(frame[0..n]).?;
    try std.testing.expectEqual(Op.request, p.op);
    try std.testing.expectEqualSlices(u8, &my_mac, &p.sender_mac);
    try std.testing.expectEqualSlices(u8, &my_ip, &p.sender_ip);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &p.target_mac);
    try std.testing.expectEqualSlices(u8, &site_ip, &p.target_ip);
    // The server's half reads it as the request it always answered.
    const req = parseRequest(frame[0..n]).?;
    try std.testing.expectEqualSlices(u8, &site_ip, &req.target_ip);
}

test "the reply to our request fills the cache; a reply is not a request" {
    var ask: [64]u8 = undefined;
    const n = writeRequest(&ask, my_mac, my_ip, site_ip);
    var answer: [64]u8 = undefined;
    const m = writeReply(&answer, site_mac, site_ip, parseRequest(ask[0..n]).?);
    try std.testing.expectEqual(@as(?Request, null), parseRequest(answer[0..m]));
    const p = parse(answer[0..m]).?;
    try std.testing.expectEqual(Op.reply, p.op);
    var cache: Cache = .{};
    try std.testing.expectEqual(@as(?[6]u8, null), cache.lookup(site_ip));
    cache.observe(p, my_ip);
    try std.testing.expectEqual(@as(?[6]u8, site_mac), cache.lookup(site_ip));
    try std.testing.expectEqual(@as(?[6]u8, null), cache.lookup(.{ 10, 0, 2, 2 }));
}

test "a stale entry is replaced: the peer's new hardware address, or another peer asking for us" {
    var cache: Cache = .{};
    const moved = [6]u8{ 0x52, 0x54, 0, 0xAA, 0xBB, 0xCC };
    cache.observe(.{ .op = .reply, .sender_mac = site_mac, .sender_ip = site_ip, .target_mac = my_mac, .target_ip = my_ip }, my_ip);
    // The site, now at another card, asking someone else: still the entry's
    // own address, so the entry follows it.
    cache.observe(.{ .op = .request, .sender_mac = moved, .sender_ip = site_ip, .target_mac = @splat(0), .target_ip = .{ 10, 0, 2, 2 } }, my_ip);
    try std.testing.expectEqual(@as(?[6]u8, moved), cache.lookup(site_ip));
    // A stranger's packet about someone else teaches nothing.
    const stranger_ip = [4]u8{ 10, 0, 2, 20 };
    const stranger_mac = [6]u8{ 0x52, 0x54, 0, 0, 0, 0x20 };
    cache.observe(.{ .op = .request, .sender_mac = stranger_mac, .sender_ip = stranger_ip, .target_mac = @splat(0), .target_ip = .{ 10, 0, 2, 2 } }, my_ip);
    try std.testing.expectEqual(@as(?[6]u8, moved), cache.lookup(site_ip));
    try std.testing.expectEqual(@as(?[6]u8, null), cache.lookup(stranger_ip));
    // The stranger asking for us replaces the one entry.
    cache.observe(.{ .op = .request, .sender_mac = stranger_mac, .sender_ip = stranger_ip, .target_mac = @splat(0), .target_ip = my_ip }, my_ip);
    try std.testing.expectEqual(@as(?[6]u8, stranger_mac), cache.lookup(stranger_ip));
    try std.testing.expectEqual(@as(?[6]u8, null), cache.lookup(site_ip));
}

test "an ARP packet with an operation other than request or reply is no packet" {
    var frame: [64]u8 = undefined;
    const n = writeRequest(&frame, my_mac, my_ip, site_ip);
    @memcpy(frame[proto.eth_header_len + 6 ..][0..2], &proto.be16(3)); // RARP's
    try std.testing.expectEqual(@as(?Packet, null), parse(frame[0..n]));
    try std.testing.expectEqual(@as(?Request, null), parseRequest(frame[0..n]));
}
