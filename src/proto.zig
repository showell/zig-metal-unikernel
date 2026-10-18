//! Ethernet, IPv4 and UDP: enough to put a datagram on the wire and to
//! recognise one coming back.
//!
//! Everything here is big-endian on the wire and little-endian in the machine,
//! so every multi-byte field goes through `be16`/`be32`. That is the single
//! most common way this kind of code is wrong, so there are no raw stores of a
//! multi-byte field anywhere in this file.
//!
//! This is deliberately not a network stack. There is no routing table, no
//! fragmentation, no ARP cache and no retransmission -- it is the smallest
//! thing that can carry DHCP, which is the first thing a machine needs. TCP
//! attaches here when it arrives.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub const mac_broadcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const ip_any = [4]u8{ 0, 0, 0, 0 };
pub const ip_broadcast = [4]u8{ 255, 255, 255, 255 };

pub const ethertype_ipv4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;

pub const proto_udp: u8 = 17;
pub const proto_tcp: u8 = 6;

pub fn be16(v: u16) [2]u8 {
    return .{ @truncate(v >> 8), @truncate(v) };
}

pub fn be32(v: u32) [4]u8 {
    return .{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

pub fn readBe16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

pub fn readBe32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// The ones-complement sum every IP-family header uses. An odd-length buffer
/// is padded with a zero byte, which is what the RFC says and what a naive
/// loop gets wrong.
pub fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

pub const eth_header_len: usize = 14;
pub const ip_header_len: usize = 20;
pub const udp_header_len: usize = 8;
pub const udp_payload_at: usize = eth_header_len + ip_header_len + udp_header_len;

/// The pseudo-header checksum TCP (and optionally UDP) is defined over: the
/// addresses and protocol from the IP header, the segment length, and then the
/// segment itself. **TCP's checksum is not optional**, unlike UDP's over IPv4,
/// and a wrong one is dropped silently by the other end -- which looks exactly
/// like the segment never arriving.
pub fn pseudoChecksum(src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, segment: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    sum += protocol;
    sum += @as(u32, @intCast(segment.len));

    var i: usize = 0;
    while (i + 1 < segment.len) : (i += 2) {
        sum += (@as(u32, segment[i]) << 8) | segment[i + 1];
    }
    if (i < segment.len) sum += @as(u32, segment[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

/// Writes an ethernet header at the front of `out`.
pub fn writeEth(out: []u8, dst: [6]u8, src: [6]u8, ethertype: u16) void {
    @memcpy(out[0..6], &dst);
    @memcpy(out[6..12], &src);
    @memcpy(out[12..14], &be16(ethertype));
}

/// One end of an IPv4 frame: its ethernet address and its IP address.
pub const Host = struct { mac: [6]u8, ip: [4]u8 };

/// A UDP datagram's ports, the sender's and the receiver's.
pub const Ports = struct { src: u16, dst: u16 };

/// An ethernet header and an IPv4 header into `out`, for a payload of
/// `payload_len` already in place at `eth_header_len + ip_header_len`.
/// Answers the total frame length.
///
/// The IPv4 header checksum is not optional and is computed here; what the
/// payload's own checksum should be is the caller's business.
pub fn writeIpv4(out: []u8, from: Host, to: Host, protocol: u8, payload_len: usize) usize {
    writeEth(out, to.mac, from.mac, ethertype_ipv4);

    const ip = out[eth_header_len..][0..ip_header_len];
    const total = ip_header_len + payload_len;
    ip[0] = 0x45; // IPv4, a 20-byte header
    ip[1] = 0; // no differentiated services
    @memcpy(ip[2..4], &be16(@intCast(total)));
    @memcpy(ip[4..6], &be16(0)); // identification
    @memcpy(ip[6..8], &be16(0x4000)); // don't fragment
    ip[8] = 64; // time to live
    ip[9] = protocol;
    @memcpy(ip[10..12], &be16(0)); // the checksum, over a zeroed checksum
    @memcpy(ip[12..16], &from.ip);
    @memcpy(ip[16..20], &to.ip);
    @memcpy(ip[10..12], &be16(checksum(ip)));

    return eth_header_len + total;
}

/// A whole UDP-over-IPv4 datagram into `out`, payload already in place at
/// `udp_payload_at`. Answers the total frame length.
///
/// The UDP checksum is left at zero, which IPv4 permits and every stack
/// accepts.
pub fn writeUdp(out: []u8, from: Host, to: Host, ports: Ports, payload_len: usize) usize {
    const frame_len = writeIpv4(out, from, to, proto_udp, udp_header_len + payload_len);

    const udp = out[eth_header_len + ip_header_len ..][0..udp_header_len];
    @memcpy(udp[0..2], &be16(ports.src));
    @memcpy(udp[2..4], &be16(ports.dst));
    @memcpy(udp[4..6], &be16(@intCast(udp_header_len + payload_len)));
    @memcpy(udp[6..8], &be16(0)); // no checksum, which IPv4 allows

    return frame_len;
}

/// What a received frame turned out to be, when it is a UDP datagram we could
/// make sense of.
pub const Datagram = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
};

/// An IPv4 packet we could make sense of.
pub const Packet = struct {
    src_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload: []const u8,
};

/// Picks an IPv4 packet out of an ethernet frame, or answers null for anything
/// else -- a different ethertype, a fragment, options in the header, a
/// truncated frame. **Every one of those is a silent null**, because on a real
/// wire most frames are not for us and a driver that complains about each one
/// is unusable.
pub fn parseIpv4(frame: []const u8) ?Packet {
    return switch (readIpv4(frame)) {
        .packet => |p| p,
        .not => null,
    };
}

/// **WHY A FRAME IS NOT AN IPv4 PACKET FOR US** (metal-vmm QUEUE 193, gap
/// 8): what `parseIpv4` answers null for, by kind, so it can be counted.
pub const NotIpv4 = enum { other_ethertype, fragment, bad_checksum, malformed };

pub fn readIpv4(frame: []const u8) union(enum) { packet: Packet, not: NotIpv4 } {
    if (frame.len < eth_header_len + ip_header_len) {
        props.reachable(@src(), "proto: a frame too short for an IPv4 header", null);
        return .{ .not = .malformed };
    }
    if (readBe16(frame[12..14]) != ethertype_ipv4) {
        props.reachable(@src(), "proto: a frame of another ethertype is not IPv4", null);
        return .{ .not = .other_ethertype };
    }

    const ip = frame[eth_header_len..];
    if (ip[0] >> 4 != 4) {
        props.reachable(@src(), "proto: a header of another IP version", null);
        return .{ .not = .malformed };
    }
    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    if (ihl != ip_header_len) { // no options here
        props.reachable(@src(), "proto: a header with options, or shorter than 20 bytes", null);
        return .{ .not = .malformed };
    }
    // A fragment is not a packet: the more-fragments bit, or a nonzero offset.
    if (readBe16(ip[6..8]) & 0x1FFF != 0 or ip[6] & 0x20 != 0) {
        props.reachable(@src(), "proto: a fragment is not a packet", null);
        return .{ .not = .fragment };
    }

    const total = readBe16(ip[2..4]);
    if (total < ihl) {
        props.reachable(@src(), "proto: a total length shorter than the header", null);
        return .{ .not = .malformed };
    }
    // A header damaged on the way describes nothing.
    if (checksum(ip[0..ihl]) != 0) {
        props.reachable(@src(), "proto: a header whose checksum is wrong", null);
        return .{ .not = .bad_checksum };
    }
    if (eth_header_len + total > frame.len) {
        props.reachable(@src(), "proto: a total length past the frame", null);
        return .{ .not = .malformed };
    }
    props.alwaysLessThanOrEqualTo(@src(), eth_header_len + total, frame.len, "proto: a packet's payload lies within its frame", null);

    return .{ .packet = .{
        .src_mac = frame[6..12].*,
        .src_ip = ip[12..16].*,
        .dst_ip = ip[16..20].*,
        .protocol = ip[9],
        .payload = ip[ihl..total],
    } };
}

/// **FRAMES PASSED OVER, BY WHY** (metal-vmm QUEUE 193, gap 8): kept by the
/// TCP table, which sees every frame that is not ARP, and shown on
/// /admin/host. Most are not for us and are no fault; a count that grows
/// is the place to look for damage, MTU trouble, misrouting or a scan.
pub const Passed = struct {
    other_ethertype: u64 = 0,
    fragments: u64 = 0,
    bad_ip_checksum: u64 = 0,
    malformed_ip: u64 = 0,
    /// IPv4, but UDP, ICMP or another protocol.
    not_tcp: u64 = 0,
    /// TCP, but to another address or port.
    not_for_us: u64 = 0,
    /// ARP asking for another address.
    arp_for_others: u64 = 0,

    pub fn note(self: *Passed, why: NotIpv4) void {
        switch (why) {
            .other_ethertype => self.other_ethertype +%= 1,
            .fragment => self.fragments +%= 1,
            .bad_checksum => self.bad_ip_checksum +%= 1,
            .malformed => self.malformed_ip +%= 1,
        }
    }

    pub fn write(p: *const Passed, w: anytype) !void {
        try w.print("{d} of another ethertype, {d} fragments, {d} with a damaged IP header, {d} malformed, {d} not TCP, {d} for another address or port, {d} ARP for another address", .{
            p.other_ethertype, p.fragments, p.bad_ip_checksum, p.malformed_ip, p.not_tcp, p.not_for_us, p.arp_for_others,
        });
    }
};

/// Picks a UDP datagram out of an ethernet frame, or answers null for anything
/// else -- a different ethertype, a fragment, options in the IP header, a
/// truncated frame. **Every one of those is a silent null**, because on a real
/// wire most frames are not for us and a driver that complains about each one
/// is unusable.
pub fn parseUdp(frame: []const u8) ?Datagram {
    const pkt = parseIpv4(frame) orelse return null;
    if (pkt.protocol != proto_udp) {
        props.reachable(@src(), "proto: a packet of another protocol is not UDP", null);
        return null;
    }
    if (pkt.payload.len < udp_header_len) {
        props.reachable(@src(), "proto: a packet too short for a UDP header", null);
        return null;
    }

    const udp = pkt.payload;
    const udp_len = readBe16(udp[4..6]);
    if (udp_len < udp_header_len or udp_len > udp.len) {
        props.reachable(@src(), "proto: a UDP length shorter than its header, or past the packet", null);
        return null;
    }

    return .{
        .src_ip = pkt.src_ip,
        .dst_ip = pkt.dst_ip,
        .src_port = readBe16(udp[0..2]),
        .dst_port = readBe16(udp[2..4]),
        .payload = udp[udp_header_len..udp_len],
    };
}
