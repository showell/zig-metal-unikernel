//! **THE LADDER: ONE OPERATION, MANY TIMES, AT A FLAT COST.**
//!
//! The chat server's own answer time grows over a long run — about 7 ms at the
//! start of a soak and 115 ms near the end — while the number of device
//! requests per route stays flat. Something underneath gets slower as it is
//! used. This kernel looks for it one layer at a time: each rung repeats a
//! single operation and prints what each tenth of the run cost per operation.
//! A well-behaved rung prints ten numbers that do not climb. The first rung
//! that climbs is where the growth lives, and everything below it is an axiom.
//!
//! The rungs, bottom up:
//!
//!   cpu            SHA-256 of 4 KB: the processor, and the clock measuring it
//!   alloc          three allocations and three frees through std's allocator
//!                  on this machine's pages
//!   read_same      one disk sector read, the same one each time
//!   write_same     one disk sector written, the same one each time
//!   write_spread   one disk sector written, a new one each time — the image
//!                  file on the host grows under it
//!   append         512 bytes appended to one file, the way the application
//!                  appends
//!   replace        a small file rewritten whole, the way the message count is
//!   udp_echo       a datagram to an echo server on the host, and back: the NIC
//!                  and the emulator's network, with no TCP in the way
//!   tcp_conn       a connection from the host, a tiny request, a tiny answer,
//!                  and the close — through this machine's TCP table, the way
//!                  the server holds connections
//!
//! **THE VERDICT IS NOT THIS KERNEL'S.** It prints numbers; `probe/run.sh
//! ladder` decides whether they are flat. The machine's command line says how
//! long each rung runs (`scale=N` multiplies every rung's count), so the same
//! kernel answers quickly first and at length once it has earned it, and
//! where the host's echo server listens (`echo_port=N`). The host's side of the
//! network rungs is `probe/judge_ladder.py`.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const disk_fat = metal.disk_fat;
const pages = metal.pages;
const pvh = metal.pvh;
const Io = metal.io;
const net = metal.net;
const proto = metal.proto;
const tcp = metal.tcp;
const arp = metal.arp;
const rng = metal.rng;
const dhcp = metal.dhcp;

comptime {
    _ = metal.boot;
}

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = pages.allocator;
    };
};

pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
    .allow_stack_tracing = false,
};

/// The allocator the server's long-lived heap uses, configured the same way.
var gpa: std.heap.DebugAllocator(.{
    .backing_allocator_zeroes = false,
    .stack_trace_frames = 0,
    .thread_safe = false,
    .safety = false,
    .page_size = pages.page_size,
}) = .{};

var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var scratch: [disk_fat.sector_size]u8 align(4096) = undefined;
var sector: [disk_fat.sector_size]u8 align(4096) = undefined;
var block: [4096]u8 = undefined;
var chunk: [512]u8 = undefined;
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;
var conn_rx: [4][4096]u8 = undefined;
var conn_tx: [4][4096]u8 = undefined;
var conns: [4]tcp.Conn = undefined;

/// The first sector past the FAT volume: run.sh makes the volume 32 MB and the
/// disk 64 MB, so everything from here on is the ladder's to write.
const raw_first: u64 = 65536;

/// Each rung is timed in this many equal parts.
const tenths = 10;

/// A number from the command line (`name=N`), or `default`.
fn fromCommandLine(comptime name: []const u8, default: usize) usize {
    var words = std.mem.tokenizeScalar(u8, metal.boot.commandLine(), ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, name ++ "=")) {
            return std.fmt.parseInt(usize, word[name.len + 1 ..], 10) catch
                serial.fail("the command line's " ++ name ++ "= is not a number");
        }
    }
    return default;
}

/// Runs `op` `count` times and prints the cost per operation of each tenth of
/// the run, in nanoseconds, with the disk requests each tenth made.
fn rung(name: []const u8, count: usize, blk: *virtio_blk.Block, context: anytype, comptime op: fn (@TypeOf(context), usize) void) void {
    const per = @max(count / tenths, 1);
    var spent: [tenths]i96 = @splat(0);
    var requests: [tenths]u64 = @splat(0);
    for (0..tenths) |t| {
        const requests_before = blk.requests;
        const began = now();
        for (0..per) |k| op(context, t * per + k);
        spent[t] = now() - began;
        requests[t] = blk.requests - requests_before;
    }
    report(name, per, spent, requests);
}

fn report(name: []const u8, per: usize, spent: [tenths]i96, requests: [tenths]u64) void {
    serial.put("rung ");
    serial.put(name);
    serial.put(": ");
    serial.putDec(per * tenths);
    serial.put(" ops; ns per op by tenth:");
    for (spent) |ns| {
        serial.put(" ");
        serial.putDec(@intCast(@divTrunc(ns, @as(i96, @intCast(per)))));
    }
    serial.put("; disk requests by tenth:");
    for (requests) |r| {
        serial.put(" ");
        serial.putDec(r);
    }
    serial.put("\n");
}

/// The network rungs' view of the wire: our address and the host's.
const Link = struct {
    nic: *net.Net,
    ip: [4]u8,
    host_ip: [4]u8,
    host_mac: [6]u8,
    echo_port: u16,
};

const echo_from: u16 = 40000;

/// Takes whatever has arrived: answers ARP, and hands back the first frame
/// `want` accepts, copied into `into`. The rest is dropped.
fn receive(link: *Link, into: []u8, want: *const fn ([]const u8) bool) ?usize {
    const got = link.nic.poll() orelse return null;
    defer link.nic.recycle(got.id);
    if (arp.parseRequest(got.frame)) |req| {
        if (std.mem.eql(u8, &req.target_ip, &link.ip)) {
            var out: [64]u8 = undefined;
            const n = arp.writeReply(&out, link.nic.mac, link.ip, req);
            link.nic.send(out[0..n]);
        }
        return null;
    }
    if (!want(got.frame)) return null;
    @memcpy(into[0..got.frame.len], got.frame);
    return got.frame.len;
}

fn isEcho(f: []const u8) bool {
    const dg = proto.parseUdp(f) orelse return false;
    return dg.dst_port == echo_from;
}

fn udpEcho(link: *Link, k: usize) void {
    const payload = frame[proto.udp_payload_at..][0..64];
    @memset(payload, 'u');
    std.mem.writeInt(u64, payload[0..8], k, .little);
    const len = proto.writeUdp(&frame, link.nic.mac, link.host_mac, link.ip, link.host_ip, echo_from, link.echo_port, payload.len);
    link.nic.send(frame[0..len]);
    var back: [net.buffer_size]u8 = undefined;
    const sent_at = now();
    while (now() - sent_at < std.time.ns_per_s) {
        const n = receive(link, &back, isEcho) orelse {
            asm volatile ("pause");
            continue;
        };
        const dg = proto.parseUdp(back[0..n]).?;
        if (dg.payload.len >= 8 and std.mem.readInt(u64, dg.payload[0..8], .little) == k) return;
    }
    serial.fail("udp_echo: no answer within a second");
}

fn isn() u32 {
    return rng.int(u32);
}

/// **THE TCP RUNG** cannot be `rung`: the host decides when each connection
/// comes. This one serves `count` connections — a request of any size ending
/// in a blank line, an answer, our FIN, their FIN — and times each from its
/// SYN to its close, bucketed by arrival.
fn tcpConnections(link: *Link, count: usize, blk: *virtio_blk.Block) void {
    for (&conns, &conn_rx, &conn_tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
    var table = tcp.Table.init(link.ip, link.nic.mac, 80, &conns, &tcp_out, isn);
    var wire = metal.stream.Wire{ .nic = link.nic };
    const per = @max(count / tenths, 1);
    const total = per * tenths;
    var spent: [tenths]i96 = @splat(0);
    // The two legs of each connection: its SYN to its whole request, and the
    // request to the close — what arrives, and what we answer and the peer
    // acknowledges.
    var to_request: [tenths]i96 = @splat(0);
    var to_close: [tenths]i96 = @splat(0);
    var started: [conns.len]i96 = @splat(0);
    var asked: [conns.len]i96 = @splat(0);
    // Frames each way, by tenth: a cost that grows with a constant count is a
    // cost per frame that grows.
    var frames_in: [tenths]u64 = @splat(0);
    var frames_out: [tenths]u64 = @splat(0);
    var sent_before: u64 = 0;
    var done: usize = 0;
    const answer = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok";
    serial.put("  tcp_conn: listening\n");
    var quiet_since = now();
    while (done < total) {
        const got = link.nic.poll() orelse {
            table.transmit(&wire, now());
            if (now() - quiet_since > 30 * std.time.ns_per_s) serial.fail("tcp_conn: the host stopped connecting");
            asm volatile ("pause");
            continue;
        };
        quiet_since = now();
        defer link.nic.recycle(got.id);
        frames_in[@min(done / per, tenths - 1)] += 1;
        if (arp.parseRequest(got.frame)) |req| {
            if (std.mem.eql(u8, &req.target_ip, &link.ip)) {
                var out: [64]u8 = undefined;
                const n = arp.writeReply(&out, link.nic.mac, link.ip, req);
                link.nic.send(out[0..n]);
            }
            continue;
        }
        const r = table.handle(&wire, got.frame, now());
        switch (r.event) {
            .data, .peer_done => {
                const c = &table.conns[r.index];
                if (c.state != .established) {} else if (std.mem.indexOf(u8, c.pending(), "\r\n\r\n") != null) {
                    started[r.index] = c.opened_at;
                    asked[r.index] = now();
                    c.consume(c.pending().len);
                    _ = table.queue(r.index, answer);
                    table.finish(r.index);
                }
            },
            .closed => {
                if (started[r.index] != 0) {
                    const t = @min(done / per, tenths - 1);
                    const closed_at = now();
                    spent[t] += closed_at - started[r.index];
                    to_request[t] += asked[r.index] - started[r.index];
                    to_close[t] += closed_at - asked[r.index];
                    started[r.index] = 0;
                    done += 1;
                }
            },
            else => {},
        }
        table.transmit(&wire, now());
        frames_out[@min(done / per, tenths - 1)] += link.nic.sent - sent_before;
        sent_before = link.nic.sent;
    }
    const none: [tenths]u64 = @splat(blk.requests - blk.requests);
    report("tcp_conn", per, spent, none);
    report("tcp_to_request", per, to_request, none);
    report("tcp_to_close", per, to_close, none);
    serial.put("note tcp_conn frames in by tenth:");
    for (frames_in) |f| {
        serial.put(" ");
        serial.putDec(f);
    }
    serial.put("; out by tenth:");
    for (frames_out) |f| {
        serial.put(" ");
        serial.putDec(f);
    }
    serial.put("\n");
}

fn now() i96 {
    return Io.awakeNs() orelse serial.fail("the clock was not started");
}

// ── the operations ──────────────────────────────────────────────────────────

fn cpu(_: void, _: usize) void {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&block, &out, .{});
    std.mem.doNotOptimizeAway(out);
}

fn alloc(a: std.mem.Allocator, _: usize) void {
    const small = a.alloc(u8, 64) catch serial.fail("alloc: no memory");
    const middle = a.alloc(u8, 1000) catch serial.fail("alloc: no memory");
    const large = a.alloc(u8, 5000) catch serial.fail("alloc: no memory");
    small[0] = 1;
    middle[0] = 2;
    large[0] = 3;
    a.free(middle);
    a.free(small);
    a.free(large);
}

fn readSame(blk: *virtio_blk.Block, _: usize) void {
    if (blk.read(raw_first, @intFromPtr(&sector)) != virtio_blk.blk_s_ok) serial.fail("read_same: the read failed");
}

fn writeSame(blk: *virtio_blk.Block, _: usize) void {
    if (blk.write(raw_first, @intFromPtr(&sector)) != virtio_blk.blk_s_ok) serial.fail("write_same: the write failed");
}

fn writeSpread(blk: *virtio_blk.Block, k: usize) void {
    const lba = raw_first + 1 + k;
    if (lba >= blk.capacity) serial.fail("write_spread: the rung ran off the end of the disk");
    if (blk.write(lba, @intFromPtr(&sector)) != virtio_blk.blk_s_ok) serial.fail("write_spread: the write failed");
}

/// The application's append, verbatim (see probe/append.zig).
fn append(io: Io, _: usize) void {
    var file = Io.Dir.cwd().createFile(io, "append.bin", .{ .truncate = false }) catch
        serial.fail("append: the file would not open");
    defer file.close(io);
    const st = file.stat(io) catch serial.fail("append: no stat");
    file.writePositionalAll(io, &chunk, st.size) catch serial.fail("append: the write failed");
}

fn replace(io: Io, k: usize) void {
    var text: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&text, "{d} {d}\n", .{ k, k * 512 }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = "count.txt", .data = data }) catch
        serial.fail("replace: the write failed");
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel ladder\n");

    const scale = fromCommandLine("scale", 1);
    const echo_port = fromCommandLine("echo_port", 0);
    serial.put("  scale ");
    serial.putDec(scale);
    serial.put("\n");

    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    Io.startClock(hz);

    const entries = metal.boot.memoryMap() catch serial.fail("the loader described no memory");
    const carved = pages.bring(pvh.largestFree(entries, metal.boot.image()));
    if (carved.pages_total == 0) serial.fail("no usable region of RAM");

    const base = virtio.find(virtio.device_id_block) orelse serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    var vol = disk_fat.Volume.mount(&blk, &scratch, 0) catch serial.fail("the disk does not start with a FAT16 volume");
    const fat = pages.allocator.alloc(u8, vol.fatBytes()) catch serial.fail("no memory to hold the FAT");
    _ = vol.cacheFat(fat) catch serial.fail("the FAT could not be held in memory");
    Io.mount(vol);
    const io = Io.io();

    for (&block, 0..) |*b, k| b.* = @truncate(k *% 7);
    @memset(&chunk, 'a');
    @memset(&sector, 0x5A);

    rung("cpu", 500 * scale, &blk, {}, cpu);
    rung("alloc", 20_000 * scale, &blk, gpa.allocator(), alloc);
    rung("read_same", 2000 * scale, &blk, &blk, readSame);
    rung("write_same", 2000 * scale, &blk, &blk, writeSame);
    rung("write_spread", @min(2000 * scale, 60_000), &blk, &blk, writeSpread);
    rung("append", 1000 * scale, &blk, io, append);
    rung("replace", 1000 * scale, &blk, io, replace);

    if (echo_port == 0) serial.fail("no echo_port= on the command line: the network rungs need the host");
    rng.attach(&rng_mem);
    const nic_base = virtio.find(virtio.device_id_net) orelse serial.fail("no virtio-net device on the PCI bus or in any mmio slot");
    var nic = net.Net.init(nic_base, &nic_mem) catch serial.fail("the NIC would not come up");
    const lease = dhcp.acquire(&nic, &frame, &dhcp_reply) catch serial.fail("no DHCP lease");
    var link = Link{
        .nic = &nic,
        .ip = lease.address,
        .host_ip = lease.server,
        .host_mac = lease.server_mac,
        .echo_port = @intCast(echo_port),
    };
    rung("udp_echo", 2000 * scale, &blk, &link, udpEcho);
    tcpConnections(&link, 200 * scale, &blk);

    if (gpa.deinit() == .leak) serial.fail("the allocator rung leaked");
    serial.pass();
}

pub const panic = metal.serial.panic;
