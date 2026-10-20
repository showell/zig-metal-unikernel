//! virtio-net over MMIO: frames out, frames in.
//!
//! Two virtqueues, and the asymmetry between them is the whole of the driver.
//! **The receive queue is filled with empty buffers before the device is told
//! it may run**, because a device with nowhere to put a frame drops it; the
//! transmit queue is filled as there is something to send, and its buffers
//! come back as the device finishes with them. Every buffer, in both directions, carries a 12-byte virtio header in
//! front of the ethernet frame.
//!
//! Nothing here interprets a frame. That is `proto.zig`'s job, and keeping the
//! line there is what lets the same driver carry ARP, DHCP and eventually TCP
//! without learning about any of them.
//!
//! **WHAT WAITS IN THE DRIVER, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md
//! §2). The driver drains nothing by itself; whoever calls `poll` does.
//!
//! - **Frames the device has delivered** (the receive ring's used entries).
//!   Taken by `poll`, which `stream.pump` calls until the ring is empty.
//!   Bounded by: the next `pump` — at most `interrupts.slice_ns` while the
//!   machine is idle, since a frame's arrival or the timer wakes it; but
//!   nothing at all while a request does work that does not pump (the
//!   disk). Then the ring fills, and past `rx_buffers` frames the device
//!   drops what arrives: the wait is bounded, by loss, and TCP sends again.
//! - **A receive buffer handed out by `poll`.** Returned by `recycle`, which
//!   `pump` defers to the end of the frame's turn. Bounded by: that turn.
//! - **Frames being sent** (`send`). `tx_buffers` of them may be with the
//!   device at once; `send` hands a frame over and returns, and takes back
//!   the buffers the device has finished with on its way in. Only when every
//!   buffer is still the device's does it wait, resting between looks.
//!   Bounded by: the device alone — nothing here gives up. A device that
//!   stopped taking frames would stop the machine; on a droplet the device's
//!   own thread needs this processor, which the rest gives back.
//!
//! **WHY MANY, NOT ONE** (QUEUE.md item 90): with one buffer, every frame
//! waited for the device to take it, a trip through the hypervisor's network
//! thread and an interrupt, about 65 us under KVM. A response went out one
//! segment per trip, about 20 MB/s however wide the peer's window, where
//! Linux on the same droplet sends 200-475.

const virtio = @import("virtio.zig");
const interrupts = @import("interrupts.zig");
const tsc = @import("tsc.zig");
const device_wait = @import("device_wait.zig");
const props = @import("coverage");

/// **HOW LONG A SEND MAY WAIT FOR A BUFFER**, in TSC ticks (193.2): one
/// second at 3 GHz until the kernel sets it from the measured rate. A card
/// that takes no frame back in a second is stalled; TCP resends what it
/// drops.
pub var send_budget_ticks: u64 = 3_000_000_000;

/// The header on every buffer in both directions. With VIRTIO_F_VERSION_1 it
/// always carries `num_buffers`, so it is 12 bytes and not the legacy 10.
pub const Header = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 0,
};

comptime {
    if (@sizeOf(Header) != 12) @compileError("virtio-net header must be 12 bytes under VERSION_1");
}

/// VIRTIO_NET_F_MAC: the device tells us our own address in its config space.
/// Without it we would have to invent one, which QEMU's network would then not
/// route to.
const feature_mac: u32 = 1 << 5;

/// An ethernet frame is at most 1514 bytes without the FCS; 2048 leaves room
/// for the header in front and is a round number the device likes.
pub const buffer_size: usize = 2048;
pub const rx_buffers: u16 = 8;
/// Frames that may be with the device at once: a peer's whole 64 KiB window
/// of full segments (45) with room to spare.
pub const tx_buffers: u16 = 64;

pub const Q = virtio.Queue(rx_buffers);
pub const TxQ = virtio.Queue(tx_buffers);

/// The rings and the buffers, which the caller owns and keeps for as long as
/// the device is up. Identity-mapped, because a descriptor carries a PHYSICAL
/// address.
pub const Memory = struct {
    rx_ring: Q.RingType align(16) = undefined,
    tx_ring: TxQ.RingType align(16) = undefined,
    rx_bufs: [rx_buffers][buffer_size]u8 align(16) = undefined,
    tx_bufs: [tx_buffers][buffer_size]u8 align(16) = undefined,
};

pub const Net = struct {
    device: virtio.Device,
    rx: Q,
    tx: TxQ,
    mem: *Memory,
    /// The transmit buffers that are ours to fill: `free[0..free_len]`.
    free: [tx_buffers]u16 = undefined,
    free_len: u16 = 0,
    /// Which transmit buffers are the device's, so a completion naming one
    /// it was not given is passed over rather than handed out twice.
    lent: [tx_buffers]bool = @splat(false),
    /// Our own hardware address, from the device.
    mac: [6]u8,
    /// Frames sent since the device came up.
    sent: u64 = 0,
    /// Frames refused because they would not fit a transmit buffer. A frame
    /// this large is a kernel bug (tcp.zig caps a segment at `our_mss`, so a
    /// built frame is ~1514 bytes against this 2036-byte room), never a peer's
    /// doing — so it is counted and shown on /admin/host, loud, rather than
    /// overrunning the buffer into the next frame's. See `send`.
    oversized: u64 = 0,
    /// **WAITS FOR A SEND BUFFER THAT ENDED** (metal-vmm QUEUE 193.2): the
    /// card took no frame back in `send_budget_ticks`, or asked for a
    /// reset; and the frames dropped since, while it had taken none back.
    send_stalls: u64 = 0,
    reset_asked: u64 = 0,
    dropped_stalled: u64 = 0,
    stalled: bool = false,
    /// **THE CARD'S RING, MISBEHAVING** (metal-vmm QUEUE 193.5): receive
    /// entries naming a buffer we never offered (each one a buffer lost to
    /// the ring for good), receive entries with a length no frame has, and
    /// send completions for a buffer we had not lent. Zero on a sound card.
    rx_strange_ids: u64 = 0,
    rx_bad_lengths: u64 = 0,
    tx_strange_completions: u64 = 0,

    pub fn init(found: virtio.Device, mem: *Memory) virtio.Error!Net {
        const st = try virtio.negotiate(found, feature_mac);
        // After negotiate's reset and before the queues: their vectors must be
        // set before they are enabled.
        const device = virtio.prepareMsix(found);
        var rx = try Q.setup(device, 0, &mem.rx_ring);
        const tx = try TxQ.setup(device, 1, &mem.tx_ring);

        // **EVERY RECEIVE BUFFER IS OFFERED BEFORE DRIVER_OK.** A frame that
        // arrives with no buffer waiting is dropped, and the first frame we
        // care about is the answer to the first frame we send.
        var i: u16 = 0;
        while (i < rx_buffers) : (i += 1) {
            rx.ring.desc[i] = .{
                .addr = @intFromPtr(&mem.rx_bufs[i]),
                .len = buffer_size,
                .flags = virtio.desc_flag_write,
                .next = 0,
            };
            rx.offer(i);
        }

        var mac: [6]u8 = undefined;
        for (&mac, 0..) |*b, k| b.* = virtio.configRead8(device, @intCast(k));

        try virtio.driverOk(device, st);
        rx.notify();
        var net: Net = .{ .device = device, .rx = rx, .tx = tx, .mem = mem, .mac = mac };
        // Finished frames are taken back on the next `send`; an interrupt for
        // each would only wake the machine to do it sooner.
        net.tx.interruptOnCompletion(false);
        while (net.free_len < tx_buffers) : (net.free_len += 1) net.free[net.free_len] = net.free_len;
        return net;
    }

    /// The most a frame may carry: a buffer, less the virtio header in front.
    pub const max_frame: usize = buffer_size - @sizeOf(Header);

    /// Hands one frame to the device and returns; the frame is copied, so the
    /// caller's bytes are free at once. Waits only when every transmit buffer
    /// is still the device's.
    pub fn send(self: *Net, frame: []const u8) void {
        // **A FRAME TOO LONG IS REFUSED, NOT TRUNCATED, NEVER OVERRUN**
        // (REVIEW-item90-step2.md finding 1). The copy below would otherwise
        // run off `tx_bufs[id]` into the next frame's buffer — one connection's
        // bytes in another's. It cannot happen as the tree stands (the MSS cap),
        // so this is defence in depth: net.zig enforces its own buffer, loudly
        // (the count shows on /admin/host; the serving loop writes a console
        // line when it first grows), without taking the site down. Counted
        // before `sent` moves, and before the ring is touched, so a refused
        // frame leaves everything as it was.
        if (frame.len > max_frame) {
            self.oversized +%= 1;
            return;
        }
        self.sent +%= 1;
        self.reclaim();
        // The device's thread takes the frames; on a droplet it needs this
        // processor to do it, so the wait rests rather than spins.
        if (self.free_len == 0) {
            // **A CARD THAT TAKES NO FRAMES ENDS THE WAIT** (metal-vmm QUEUE
            // 193.2): it hung the machine. After `send_budget_ticks` with no
            // buffer back, or the card asking for a reset, the frame is
            // dropped and counted, and TCP sends it again later; while the
            // card has taken none back since, the next frames drop at once
            // rather than each waiting out its own budget.
            if (self.stalled) {
                self.dropped_stalled +%= 1;
                return;
            }
            // Now a completion is worth an interrupt: it ends the wait. One
            // that landed before the flag changed is found by `reclaim`.
            self.tx.interruptOnCompletion(true);
            self.reclaim();
            const began = tsc.read();
            while (self.free_len == 0) {
                switch (device_wait.verdict(began, tsc.read(), send_budget_ticks, virtio.deviceStatus(self.device))) {
                    .wait => {},
                    .timed_out, .needs_reset => |why| {
                        self.tx.interruptOnCompletion(false);
                        self.stalled = true;
                        if (why == .needs_reset) self.reset_asked +%= 1 else self.send_stalls +%= 1;
                        self.dropped_stalled +%= 1;
                        props.reachable(@src(), "net: a card that takes no frames back ends the wait, and the frame is dropped", null);
                        return;
                    },
                }
                interrupts.rest();
                self.reclaim();
            }
            self.tx.interruptOnCompletion(false);
        }
        self.free_len -= 1;
        const id = self.free[self.free_len];
        self.lent[id] = true;
        const buf = &self.mem.tx_bufs[id];
        const hdr: *Header = @ptrCast(@alignCast(buf));
        hdr.* = .{};
        @memcpy(buf[@sizeOf(Header)..][0..frame.len], frame);

        self.tx.ring.desc[id] = .{
            .addr = @intFromPtr(buf),
            .len = @intCast(@sizeOf(Header) + frame.len),
            .flags = 0,
            .next = 0,
        };
        self.tx.offer(id);
        self.tx.notifyIfWanted();
    }

    /// Takes back every transmit buffer the device has finished with.
    fn reclaim(self: *Net) void {
        while (self.tx.take()) |e| {
            virtio.ack(self.device);
            if (!txEntryOurs(e.id, &self.lent)) {
                self.tx_strange_completions +%= 1;
                continue;
            }
            self.lent[e.id] = false;
            self.free[self.free_len] = @intCast(e.id);
            self.free_len += 1;
            // A buffer back: the card is taking frames again.
            self.stalled = false;
        }
    }

    /// From now on both queues interrupt this processor at `vector` when
    /// they have something: a frame arrived, or a frame was taken. False on a
    /// card that cannot (mmio, or no MSI-X), which goes on being polled.
    pub fn interruptOnFrames(self: *Net, address: u32, vector: u8) bool {
        if (!self.rx.vectored or !self.tx.vectored) return false;
        return virtio.routeToProcessor(self.device, address, vector);
    }

    /// The next frame the device has delivered, or null. The slice points into
    /// the receive buffer it arrived in and stays valid until `recycle`.
    ///
    /// **NULL MEANS THE RING IS EMPTY, AND NOTHING ELSE.** A completion that
    /// carries no frame is passed over, not reported as the end: a caller that
    /// drains until null would otherwise stop with frames still waiting behind
    /// it. One naming a buffer we never offered cannot be handed back, and is
    /// dropped; one too short to hold a header returns its buffer at once.
    pub fn poll(self: *Net) ?struct { id: u16, frame: []const u8 } {
        while (self.rx.take()) |e| {
            virtio.ack(self.device);
            switch (rxEntry(e.id, e.len)) {
                .strange_id => {
                    self.rx_strange_ids +%= 1;
                    continue;
                },
                .bad_length => {
                    self.rx_bad_lengths +%= 1;
                    self.recycle(@intCast(e.id));
                    continue;
                },
                .frame => {},
            }
            const id: u16 = @intCast(e.id);
            return .{
                .id = id,
                .frame = self.mem.rx_bufs[id][@sizeOf(Header)..e.len],
            };
        }
        return null;
    }

    /// Hands a receive buffer back to the device. A driver that forgets this
    /// works until it has used every buffer once and then goes quiet, which is
    /// a memorable afternoon.
    pub fn recycle(self: *Net, id: u16) void {
        self.rx.ring.desc[id] = .{
            .addr = @intFromPtr(&self.mem.rx_bufs[id]),
            .len = buffer_size,
            .flags = virtio.desc_flag_write,
            .next = 0,
        };
        self.rx.offer(id);
        self.rx.notifyIfWanted();
    }
};

/// **WHAT A USED-RING ENTRY IS** (metal-vmm QUEUE 193.5), decided apart
/// from the device so it is tested: a frame in one of our buffers; an entry
/// naming no buffer we offered (the buffer the device really used is lost to
/// the ring for good, one fewer each time); or a length no frame has (too
/// short for the header, or past the buffer), whose buffer goes straight back.
pub const RxEntry = enum { frame, strange_id, bad_length };

pub fn rxEntry(id: u32, len: u32) RxEntry {
    if (id >= rx_buffers) return .strange_id;
    if (len <= @sizeOf(Header) or len > buffer_size) return .bad_length;
    return .frame;
}

/// A send completion: one of ours, given back; or one naming a buffer we
/// did not lend, passed over.
pub fn txEntryOurs(id: u32, lent: []const bool) bool {
    return id < tx_buffers and id < lent.len and lent[id];
}

const testing = @import("std").testing;

test "send refuses a frame too long for its buffer: counted, nothing sent, the ring untouched" {
    // A Net whose transmit ring is real (so the test can see it did not move)
    // and whose device is never reached, because a refused frame returns before
    // `reclaim`, `offer` or `notify` — the refusal touches only the counter.
    var mem: Memory = undefined;
    mem.tx_ring.avail_idx = 7; // a known value the refusal must leave alone
    var n: Net = .{
        .device = .{ .mmio = 0 },
        .rx = undefined,
        .tx = .{ .device = .{ .mmio = 0 }, .index = 1, .ring = &mem.tx_ring, .doorbell = 0 },
        .mem = &mem,
        .mac = .{ 0, 0, 0, 0, 0, 0 },
    };
    n.free_len = tx_buffers; // as init leaves it: every buffer ours
    for (0..tx_buffers) |i| n.free[i] = @intCast(i);

    var too_long: [Net.max_frame + 1]u8 = undefined;
    n.send(&too_long);
    try testing.expectEqual(@as(u64, 1), n.oversized);
    try testing.expectEqual(@as(u64, 0), n.sent); // it was not sent
    try testing.expectEqual(tx_buffers, n.free_len); // no buffer taken
    try testing.expectEqual(@as(u16, 7), mem.tx_ring.avail_idx); // the ring did not move
}

test "a used-ring entry: a frame, a buffer we never offered, a length no frame has; a send completion we did not lend (metal-vmm QUEUE 193.5)" {
    try testing.expectEqual(RxEntry.frame, rxEntry(0, @sizeOf(Header) + 60));
    try testing.expectEqual(RxEntry.frame, rxEntry(rx_buffers - 1, buffer_size));
    try testing.expectEqual(RxEntry.strange_id, rxEntry(rx_buffers, 100));
    try testing.expectEqual(RxEntry.strange_id, rxEntry(0xFFFF_FFFF, 100));
    try testing.expectEqual(RxEntry.bad_length, rxEntry(0, @sizeOf(Header)));
    try testing.expectEqual(RxEntry.bad_length, rxEntry(0, buffer_size + 1));
    var lent: [tx_buffers]bool = @splat(false);
    lent[2] = true;
    try testing.expect(txEntryOurs(2, &lent));
    try testing.expect(!txEntryOurs(3, &lent));
    try testing.expect(!txEntryOurs(tx_buffers, &lent));
}
