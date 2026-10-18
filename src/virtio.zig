//! virtio: the two transports, the virtqueue, and the block device.
//!
//! **THIS IS THE DEVICE THE FLOOR'S DISK DOOR WAS ALREADY SHAPED FOR.** A
//! virtio-blk request is a header naming a sector, a data buffer named by
//! ADDRESS, and a status byte -- which is `Disk.read!(lba, addr)` and its
//! outcome, arrived at from the other direction. Nothing here copies a sector;
//! the device writes into the page the caller named.
//!
//! **TWO TRANSPORTS, ONE DRIVER.** On QEMU's `microvm` (and Firecracker) a
//! device is a window of registers at a known address, with a magic value at
//! offset 0 and no bus to enumerate: virtio-mmio. On a PC, and so on a
//! DigitalOcean droplet, the same devices sit on the PCI bus and say, through
//! their capability list, which of their memory windows holds which controls:
//! virtio-pci. Everything above "write the status", "pick a queue" and "ring
//! the doorbell" is the same, so a `Device` is either kind and the rest of
//! this file does not ask which.
//!
//! The spec is virtio 1.2 (§4.1 PCI, §4.2 MMIO). Register offsets and
//! constants below are its numbers, not ours. Only the modern interface is
//! spoken on either transport.

const std = @import("std");
const props = @import("coverage");
const tsc = @import("tsc.zig");
const pci = @import("pci.zig");
const device_wait = @import("device_wait.zig");
/// **HOW LONG A REQUEST MAY GO UNANSWERED**, in TSC ticks (metal-vmm QUEUE
/// 193.2). 30 seconds, as Linux's SCSI layer gives a command. Until the
/// kernel has measured the TSC's rate it is 30 s at 3 GHz (longer on a
/// slower clock, never shorter); the kernel sets it from the rate.
pub var wait_budget_ticks: u64 = 30 * 3_000_000_000;

/// The device's status byte, for `device_wait`.
pub fn deviceStatus(d: Device) u32 {
    return getStatus(d);
}

/// A device, found on whichever transport this machine has.
pub const Device = union(enum) {
    /// The base of its register window.
    mmio: usize,
    pci: Pci,

    pub fn describe(self: Device) []const u8 {
        return switch (self) {
            .mmio => "virtio-mmio",
            .pci => "virtio-pci",
        };
    }

    /// Where it is, for a report: the register window on mmio, the common
    /// configuration's window on pci.
    pub fn address(self: Device) u64 {
        return switch (self) {
            .mmio => |base| base,
            .pci => |p| p.common,
        };
    }
};

/// Where a PCI device's four kinds of control live, from its capabilities.
pub const Pci = struct {
    function: pci.Function,
    common: usize,
    notify: usize,
    notify_multiplier: u32,
    isr: usize,
    device: usize,
    /// MSI-X table entry 0, once `prepareMsix` has turned MSI-X on. From then
    /// the device never uses the ISR for its queues (virtio §4.1.4.5).
    msix_entry: ?usize = null,
};

// ---- the mmio register window --------------------------------------------

const Reg = enum(u32) {
    magic = 0x000, // "virt", 0x74726976
    version = 0x004, // 2 for the modern interface, 1 for legacy
    device_id = 0x008, // 2 is block, 1 is net
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_lo = 0x080,
    queue_desc_hi = 0x084,
    queue_driver_lo = 0x090,
    queue_driver_hi = 0x094,
    queue_device_lo = 0x0a0,
    queue_device_hi = 0x0a4,
    config = 0x100,
};

const magic_value: u32 = 0x74726976;

// ---- the pci common configuration (§4.1.4.3) -----------------------------
//
// **EACH FIELD IS READ AND WRITTEN AT ITS OWN WIDTH.** The spec requires it,
// and the widths are not all 32 bits: the status is a byte, a queue's size a
// 16-bit word.

const common_device_feature_select = 0x00; // u32
const common_device_feature = 0x04; // u32
const common_driver_feature_select = 0x08; // u32
const common_driver_feature = 0x0C; // u32
const common_device_status = 0x14; // u8
const common_queue_select = 0x16; // u16
const common_queue_size = 0x18; // u16: the device's maximum, until we write ours
const common_queue_msix_vector = 0x1A; // u16
const common_queue_enable = 0x1C; // u16
const common_queue_notify_off = 0x1E; // u16
const common_queue_desc = 0x20; // u64
const common_queue_driver = 0x28; // u64
const common_queue_device = 0x30; // u64

/// The capability types a virtio-pci device lists (§4.1.4).
const cap_common: u8 = 1;
const cap_notify: u8 = 2;
const cap_isr: u8 = 3;
const cap_device: u8 = 4;

/// Status bits the driver walks up in order; the device watches them.
const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;
const status_failed: u32 = 128;

/// VIRTIO_F_VERSION_1: the driver speaks the modern interface. Without it a
/// modern device refuses to start.
const feature_version_1: u6 = 32;
pub const device_id_block: u32 = 2;
pub const device_id_net: u32 = 1;

/// The device may read the rings the instant the index moves, so the stores
/// that build a chain have to land before the store that publishes it.
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn read8(at: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(at)).*;
}
fn read16(at: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(at)).*;
}
fn read32(at: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(at)).*;
}
fn write8(at: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(at)).* = v;
}
fn write16(at: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(at)).* = v;
}
fn write32(at: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(at)).* = v;
}
fn write64(at: usize, v: u64) void {
    write32(at, @truncate(v));
    write32(at + 4, @truncate(v >> 32));
}

fn mmioRead(base: usize, reg: Reg) u32 {
    return read32(base + @intFromEnum(reg));
}

fn mmioWrite(base: usize, reg: Reg, value: u32) void {
    write32(base + @intFromEnum(reg), value);
}

// ---- the operations, once per transport ----------------------------------

fn setStatus(d: Device, v: u32) void {
    switch (d) {
        .mmio => |base| mmioWrite(base, .status, v),
        .pci => |p| write8(p.common + common_device_status, @truncate(v)),
    }
}

fn getStatus(d: Device) u32 {
    return switch (d) {
        .mmio => |base| mmioRead(base, .status),
        .pci => |p| read8(p.common + common_device_status),
    };
}

fn deviceFeatures(d: Device, select: u32) u32 {
    switch (d) {
        .mmio => |base| {
            mmioWrite(base, .device_features_sel, select);
            return mmioRead(base, .device_features);
        },
        .pci => |p| {
            write32(p.common + common_device_feature_select, select);
            return read32(p.common + common_device_feature);
        },
    }
}

fn driverFeatures(d: Device, select: u32, value: u32) void {
    switch (d) {
        .mmio => |base| {
            mmioWrite(base, .driver_features_sel, select);
            mmioWrite(base, .driver_features, value);
        },
        .pci => |p| {
            write32(p.common + common_driver_feature_select, select);
            write32(p.common + common_driver_feature, value);
        },
    }
}

/// The device-specific configuration: a block device's capacity, a network
/// card's address.
fn configAddress(d: Device, off: u32) usize {
    return switch (d) {
        .mmio => |base| base + @intFromEnum(Reg.config) + off,
        .pci => |p| p.device + off,
    };
}

pub fn configRead8(d: Device, off: u32) u8 {
    return read8(configAddress(d, off));
}

pub fn configRead16(d: Device, off: u32) u16 {
    return read16(configAddress(d, off));
}

pub fn configRead32(d: Device, off: u32) u32 {
    return read32(configAddress(d, off));
}

pub fn configRead64(d: Device, off: u32) u64 {
    const at = configAddress(d, off);
    return (@as(u64, read32(at + 4)) << 32) | read32(at);
}

/// Every window QEMU's microvm machine puts a virtio-mmio transport in: slots
/// of 512 bytes from 0xFEB00000.
///
/// **THERE ARE 24 OF THEM AND QEMU FILLS THEM FROM THE TOP.** A single
/// `-device virtio-blk-device` lands on bus 23, at 0xFEB02E00, with the first
/// eight slots present-but-empty -- which looks exactly like "no device" if
/// you only scan eight. Measured with `info qtree`, 2026-09-16. 32 is scanned
/// for headroom; an empty transport answers device id 0 and costs one read.
pub const mmio_base: usize = 0xFEB00000;
pub const mmio_stride: usize = 0x200;
pub const mmio_slots: usize = 32;

/// What a slot says it is, for a host that wants to report the scan rather
/// than only its verdict.
pub fn magicAt(base: usize) u32 {
    return mmioRead(base, .magic);
}
pub fn versionAt(base: usize) u32 {
    return mmioRead(base, .version);
}
pub fn deviceIdAt(base: usize) u32 {
    return mmioRead(base, .device_id);
}

/// The first device of this kind, or null.
pub fn find(want: u32) ?Device {
    return findNth(want, 0);
}

/// The `n`th device of this kind (0 is the first), or null. **A MACHINE WITH
/// A PCI BUS IS ASKED THROUGH IT**, and only a machine without one has its
/// mmio slots scanned: the two are never mixed, so a PCI window that happened
/// to sit where an mmio slot would cannot be mistaken for one. A droplet has
/// two network cards (public, then private, in slot order) and two disks (the
/// boot disk, then the config drive), which is what `n` is for.
pub fn findNth(want: u32, n: usize) ?Device {
    var seen: usize = 0;
    if (pci.present()) {
        var scan = pci.Scan{};
        while (scan.next()) |f| {
            if (pciType(f) != want) continue;
            const d = pciDevice(f) orelse continue;
            if (seen == n) return .{ .pci = d };
            seen += 1;
        }
        return null;
    }
    var i: usize = 0;
    while (i < mmio_slots) : (i += 1) {
        const base = mmio_base + i * mmio_stride;
        // A slot whose magic is wrong is empty; one whose version is not 2 is
        // the legacy interface, which this driver does not speak.
        if (mmioRead(base, .magic) != magic_value) continue;
        if (mmioRead(base, .device_id) != want) continue;
        if (mmioRead(base, .version) != 2) continue;
        if (seen == n) return .{ .mmio = base };
        seen += 1;
    }
    return null;
}

/// The virtio device type of a PCI function, or 0 if it is not virtio.
/// **TWO NUMBERINGS** (§4.1.2.1): a modern-only device is 0x1040 plus its
/// type; a transitional one (what a droplet has: 0x1000 for its network cards,
/// 0x1001 for its disks) is 0x1000-0x103F and says its type in the subsystem
/// id instead.
fn pciType(f: pci.Function) u32 {
    if (f.vendor() != 0x1AF4) return 0;
    const id = f.device();
    if (id >= 0x1040 and id <= 0x107F) return id - 0x1040;
    if (id >= 0x1000 and id <= 0x103F) return f.subsystem();
    return 0;
}

/// Reads the capability list into the four windows, and lets the device at
/// memory. Null if any of the four is missing: that is a legacy-only device,
/// which this driver does not speak.
fn pciDevice(f: pci.Function) ?Pci {
    var common: ?usize = null;
    var notify: ?usize = null;
    var isr: ?usize = null;
    var device: ?usize = null;
    var multiplier: u32 = 0;
    var caps = f.capabilities();
    while (caps.nextOne()) |cap| {
        if (cap.id != 0x09) continue; // vendor-specific: virtio's
        const kind = f.read8(cap.at + 3);
        const bar = f.bar(f.read8(cap.at + 4)) orelse continue;
        const at: usize = @intCast(bar + f.read32(cap.at + 8));
        switch (kind) {
            cap_common => common = common orelse at,
            cap_notify => if (notify == null) {
                notify = at;
                multiplier = f.read32(cap.at + 16);
            },
            cap_isr => isr = isr orelse at,
            cap_device => device = device orelse at,
            else => {},
        }
    }
    const found = Pci{
        .function = f,
        .common = common orelse return null,
        .notify = notify orelse return null,
        .notify_multiplier = multiplier,
        .isr = isr orelse return null,
        .device = device orelse return null,
    };
    f.enable();
    return found;
}

// ---- the virtqueue -------------------------------------------------------

pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const desc_flag_next: u16 = 1;
/// The DEVICE writes this buffer; without it the device reads.
pub const desc_flag_write: u16 = 2;

/// In the used ring's flags, set by the device: it is already working
/// through the queue and needs no doorbell (VIRTQ_USED_F_NO_NOTIFY).
pub const used_flag_no_notify: u16 = 1;
/// In the available ring's flags, set by us: we will look for completions
/// ourselves and want no interrupt for them (VIRTQ_AVAIL_F_NO_INTERRUPT).
/// A hint the device may ignore.
pub const avail_flag_no_interrupt: u16 = 1;

/// A virtqueue's three rings, laid out as one block of memory the caller owns.
/// The device is told where each ring is and then reads and writes them
/// directly: no ports, no copying, one doorbell.
///
/// Sized by its job. A block queue needs one chain in flight; a receive queue
/// wants as many buffers as it can hold frames.
pub fn Ring(comptime size: u16) type {
    // **A POWER OF TWO** (metal-vmm 150(b)): the indexes are free-running
    // u16s taken `% size`, which stays the slot across their wrap at 65536
    // only if `size` divides it.
    comptime std.debug.assert(size > 0 and size & (size - 1) == 0);
    return extern struct {
        const Self = @This();
        pub const len: u16 = size;

        desc: [size]Desc align(16),

        avail_flags: u16 align(2),
        avail_idx: u16,
        avail_ring: [size]u16,
        avail_used_event: u16,

        used_flags: u16 align(4),
        used_idx: u16,
        used_ring: [size]UsedElem,
        used_avail_event: u16,
    };
}

pub const UsedElem = extern struct { id: u32, len: u32 };

/// One queue on a device: the ring, which queue index it is, and how far we
/// have read its used ring.
pub fn Queue(comptime size: u16) type {
    return struct {
        const Self = @This();
        pub const RingType = Ring(size);

        device: Device,
        index: u16,
        /// The device took MSI-X entry 0 as this queue's vector, before the
        /// queue was enabled.
        vectored: bool = false,
        ring: *RingType,
        last_used: u16 = 0,
        /// Where this queue's doorbell is: one register for every queue on
        /// mmio, a register of its own on pci.
        doorbell: usize,

        /// Tells the device where this queue's rings are and marks it ready.
        /// Must happen before DRIVER_OK.
        pub fn setup(device: Device, index: u16, ring: *RingType) Error!Self {
            const ring_addr = @intFromPtr(ring);
            const avail_addr = ring_addr + @offsetOf(RingType, "avail_flags");
            const used_addr = ring_addr + @offsetOf(RingType, "used_flags");
            var doorbell: usize = undefined;
            var vectored = false;
            // **THE WHOLE RING ZEROED BEFORE THE DEVICE IS TOLD WHERE IT IS**
            // (150(c), 154(a)): a device may read it once the queue is ready,
            // and the memory is `undefined`: a stale NO_NOTIFY in the used
            // ring's flags, which only the device writes, would stop every
            // doorbell. Linux zeroes a ring as it allocates it. Every caller
            // fills its descriptors after this.
            @memset(std.mem.asBytes(ring), 0);
            fence();
            switch (device) {
                .mmio => |base| {
                    mmioWrite(base, .queue_sel, index);
                    if (mmioRead(base, .queue_num_max) < size) {
                        props.reachable(@src(), "virtio: an mmio queue smaller than this driver needs, or none", null);
                        return Error.QueueTooSmall;
                    }
                    mmioWrite(base, .queue_num, size);
                    mmioWrite(base, .queue_desc_lo, @truncate(ring_addr));
                    mmioWrite(base, .queue_desc_hi, @truncate(ring_addr >> 32));
                    mmioWrite(base, .queue_driver_lo, @truncate(avail_addr));
                    mmioWrite(base, .queue_driver_hi, @truncate(avail_addr >> 32));
                    mmioWrite(base, .queue_device_lo, @truncate(used_addr));
                    mmioWrite(base, .queue_device_hi, @truncate(used_addr >> 32));
                    mmioWrite(base, .queue_ready, 1);
                    doorbell = base + @intFromEnum(Reg.queue_notify);
                },
                .pci => |p| {
                    write16(p.common + common_queue_select, index);
                    // Zero is "no such queue"; otherwise the device's maximum.
                    const max = read16(p.common + common_queue_size);
                    if (max < size) {
                        props.reachable(@src(), "virtio: a pci queue smaller than this driver needs, or none", null);
                        return Error.QueueTooSmall;
                    }
                    write16(p.common + common_queue_size, size);
                    write64(p.common + common_queue_desc, ring_addr);
                    write64(p.common + common_queue_driver, avail_addr);
                    write64(p.common + common_queue_device, used_addr);
                    const off = read16(p.common + common_queue_notify_off);
                    doorbell = p.notify + @as(usize, off) * p.notify_multiplier;
                    // **THE VECTOR BEFORE THE QUEUE IS ENABLED** (virtio
                    // §4.1.5.1.3), as Linux sets it: a device may read it only
                    // then. Entry 0 is still masked; `routeToProcessor` aims
                    // and unmasks it later. A device that would not take it
                    // reads back NO_VECTOR, and the queue goes on polled.
                    if (p.msix_entry != null) {
                        write16(p.common + common_queue_msix_vector, 0);
                        vectored = read16(p.common + common_queue_msix_vector) == 0;
                    }
                    write16(p.common + common_queue_enable, 1);
                },
            }

            return .{ .device = device, .index = index, .vectored = vectored, .ring = ring, .doorbell = doorbell };
        }

        /// Puts the chain starting at descriptor `head` on the available ring.
        /// The caller has already filled the descriptors.
        pub fn offer(self: *Self, head: u16) void {
            self.ring.avail_ring[self.ring.avail_idx % size] = head;
            fence();
            self.ring.avail_idx +%= 1;
            fence();
        }

        /// **A DOORBELL ONLY WHEN THE DEVICE WANTS ONE** (virtio §2.7.7). Each
        /// ring of it is a trip out to the hypervisor; a device already
        /// working through the queue says so in the used ring's flags, read
        /// after `offer` has published the new entries.
        pub fn notifyIfWanted(self: *Self) void {
            fence();
            const flags = @as(*volatile u16, @ptrCast(&self.ring.used_flags)).*;
            if (flags & used_flag_no_notify == 0) self.notify();
        }

        /// Whether the device interrupts when it completes something here.
        pub fn interruptOnCompletion(self: *Self, on: bool) void {
            @as(*volatile u16, @ptrCast(&self.ring.avail_flags)).* = if (on) 0 else avail_flag_no_interrupt;
            fence();
        }

        /// Rings the doorbell for this queue.
        pub fn notify(self: *Self) void {
            switch (self.device) {
                .mmio => write32(self.doorbell, self.index),
                .pci => write16(self.doorbell, self.index),
            }
        }

        /// The next completion, or null if the device has published none.
        ///
        /// **THE INDEX, THEN A FENCE, THEN THE ENTRY** (virtio §2.7.13,
        /// metal-vmm 150(a)): the device writes the entry before it moves the
        /// index, and the entry must be read after the index is. x86 does
        /// not reorder loads, but the compiler may: the index is a volatile
        /// load and the entry a plain one, whose address does not depend on
        /// it. Read in ReleaseSafe (`net.Net.reclaim`, 2026-10-10), LLVM
        /// kept the order, by no rule that holds it.
        pub fn take(self: *Self) ?UsedElem {
            const idx = @as(*volatile u16, @ptrCast(&self.ring.used_idx)).*;
            if (idx == self.last_used) return null;
            fence();
            const e = self.ring.used_ring[self.last_used % size];
            self.last_used +%= 1;
            return e;
        }

        /// How a wait ended: a completion, or `device_wait`'s verdict.
        pub const Ended = union(enum) { done: UsedElem, needs_reset, timed_out };

        /// **SPINS UNTIL A COMPLETION ARRIVES, OR IT NEVER WILL** (193.2): every
        /// `device_wait.look_every` spins it asks the clock and the device's
        /// status whether to go on (a status read is a trip to the hypervisor).
        pub fn waitFor(self: *Self, budget_ticks: u64) Ended {
            const began = tsc.read();
            var spins: u32 = 0;
            while (true) {
                if (self.take()) |e| return .{ .done = e };
                asm volatile ("pause");
                spins +%= 1;
                if (spins % device_wait.look_every != 0) continue;
                switch (device_wait.verdict(began, tsc.read(), budget_ticks, getStatus(self.device))) {
                    .wait => {},
                    .needs_reset => return .needs_reset,
                    .timed_out => return .timed_out,
                }
            }
        }
    };
}

/// Walks the device up to DRIVER_OK, taking VIRTIO_F_VERSION_1 and whatever
/// else the caller names in `want_low` (feature bits below 32). Every step is
/// checked, because a device that has silently refused looks exactly like one
/// that is working until the first transfer hangs.
///
/// Answers the status word so far; the caller adds its queues, then calls
/// `driverOk`.
pub fn negotiate(d: Device, want_low: u32) Error!u32 {
    return (try negotiateWith(d, want_low, 0)).st;
}

/// `negotiate`, also taking the features of `may_low` the device offers;
/// answers the status word and the low features taken.
pub fn negotiateWith(d: Device, want_low: u32, may_low: u32) Error!struct { st: u32, low: u32 } {
    setStatus(d, 0); // reset
    // **A RESET IS NOT DONE UNTIL THE DEVICE SAYS SO** on pci (§4.1.4.3.1):
    // the status reads back 0 once it is. mmio's reset is immediate.
    if (d == .pci) {
        while (getStatus(d) != 0) asm volatile ("pause");
    }
    var st: u32 = status_acknowledge;
    setStatus(d, st);
    st |= status_driver;
    setStatus(d, st);

    const hi = deviceFeatures(d, 1);
    if (hi & (@as(u32, 1) << (feature_version_1 - 32)) == 0) {
        props.reachable(@src(), "virtio: a device without VIRTIO_F_VERSION_1 is refused", null);
        setStatus(d, status_failed);
        return Error.DeviceRefused;
    }
    const lo = deviceFeatures(d, 0);
    if (lo & want_low != want_low) {
        props.reachable(@src(), "virtio: a device without a feature this driver needs is refused", null);
        setStatus(d, status_failed);
        return Error.DeviceRefused;
    }

    const taken = want_low | (lo & may_low);
    driverFeatures(d, 1, @as(u32, 1) << (feature_version_1 - 32));
    driverFeatures(d, 0, taken);

    st |= status_features_ok;
    setStatus(d, st);
    if (getStatus(d) & status_features_ok == 0) {
        props.reachable(@src(), "virtio: a device that will not keep FEATURES_OK is refused", null);
        setStatus(d, status_failed);
        return Error.DeviceRefused;
    }
    return .{ .st = st, .low = taken };
}

pub fn driverOk(d: Device, st: u32) Error!void {
    setStatus(d, st | status_driver_ok);
    if (getStatus(d) & status_failed != 0) {
        props.reachable(@src(), "virtio: a device that fails at DRIVER_OK", null);
        return Error.DeviceRefused;
    }
}

/// The interrupt this device raised, acknowledged. Polling drivers still have
/// to do this or the device stops raising them. On pci, reading the ISR byte
/// is the acknowledgement — unless MSI-X is on, when the ISR says nothing
/// about the queues and the read would only be a trip to the hypervisor per
/// frame.
pub fn ack(d: Device) void {
    switch (d) {
        .mmio => |base| {
            const s = mmioRead(base, .interrupt_status);
            if (s != 0) mmioWrite(base, .interrupt_ack, s);
        },
        .pci => |p| if (p.msix_entry == null) {
            _ = read8(p.isr);
        },
    }
}

/// **MSI-X TURNED ON, WITH NOTHING SENT YET.** On PCI a device raises an
/// interrupt by writing a message to an address — MSI-X — and the table of
/// messages it may write sits in one of its memory windows, named by its
/// MSI-X capability (PCI 3.0 §6.8.2). Entry 0 is masked first, then MSI-X is
/// enabled for the function: from here the device sends nothing (a masked
/// entry only sets its pending bit) until `routeToProcessor` aims and
/// unmasks it. Called after `negotiate`'s reset and before `Queue.setup`, so
/// that each queue's vector is set before the queue is enabled. Answers the
/// device unchanged on mmio, or when it has no MSI-X capability.
pub fn prepareMsix(d: Device) Device {
    var p = switch (d) {
        .pci => |p| p,
        .mmio => return d,
    };
    const f = p.function;
    var caps = f.capabilities();
    const cap = while (caps.nextOne()) |c| {
        if (c.id == 0x11) break c;
    } else return d;
    const table = f.read32(cap.at + 4);
    const window = f.bar(@truncate(table & 7)) orelse return d;
    const entry: usize = @intCast(window + (table & ~@as(u32, 7)));
    write32(entry + 12, 1); // masked
    write32(entry + 0, 0);
    write32(entry + 4, 0);
    write32(entry + 8, 0);

    // Enable (bit 15), and not masked as a whole (bit 14).
    const control = f.read16(cap.at + 2);
    f.write16(cap.at + 2, (control | 0x8000) & ~@as(u16, 0x4000));
    p.msix_entry = entry;
    return .{ .pci = p };
}

/// **A DEVICE THAT INTERRUPTS THE PROCESSOR WHEN IT HAS SOMETHING.** MSI-X
/// entry 0, which `prepareMsix` turned on masked and `Queue.setup` gave the
/// queues, is aimed at `address` with `vector` and unmasked. A message the
/// device wanted to send while it was masked is sent now. False, and nothing
/// changed, on mmio or on a device `prepareMsix` found no MSI-X on.
pub fn routeToProcessor(d: Device, address: u32, vector: u8) bool {
    const entry = switch (d) {
        .pci => |p| p.msix_entry orelse return false,
        .mmio => return false,
    };
    write32(entry + 0, address);
    write32(entry + 4, 0);
    write32(entry + 8, vector);
    write32(entry + 12, 0); // unmasked
    return true;
}

pub const Error = error{ NoDevice, DeviceRefused, QueueTooSmall, TransferFailed };

// ---- the block device ----------------------------------------------------

fn wrapCase(comptime size: u16) !void {
    const Q = Queue(size);
    var ring: Q.RingType = undefined;
    @memset(std.mem.asBytes(&ring), 0);
    // Both indexes start just short of the wrap, as after 65,530 requests.
    const start: u16 = 65530;
    ring.avail_idx = start;
    ring.used_idx = start;
    var q: Q = .{ .device = .{ .mmio = 0 }, .index = 0, .ring = &ring, .last_used = start, .doorbell = 0 };
    // Three rounds of a full ring, across the wrap: every head offered is
    // in the slot its index names, and every completion comes back once, in
    // order, then nothing.
    var next_id: u32 = 0;
    for (0..3) |_| {
        for (0..size) |k| {
            const at = ring.avail_idx;
            q.offer(@intCast(k));
            try std.testing.expectEqual(@as(u16, @intCast(k)), ring.avail_ring[at % size]);
            try std.testing.expectEqual(at +% 1, ring.avail_idx);
        }
        // The device answers each, as it does: the entry, then the index.
        for (0..size) |k| {
            ring.used_ring[ring.used_idx % size] = .{ .id = next_id + @as(u32, @intCast(k)), .len = 1 };
            ring.used_idx +%= 1;
        }
        for (0..size) |k| {
            const e = q.take().?;
            try std.testing.expectEqual(next_id + @as(u32, @intCast(k)), e.id);
        }
        try std.testing.expectEqual(@as(?UsedElem, null), q.take());
        next_id += size;
    }
    try std.testing.expectEqual(start +% 3 *% size, ring.avail_idx);
    try std.testing.expectEqual(ring.used_idx, q.last_used);
}

test "a queue's indexes run across their u16 wrap: every head in its slot, every completion once and in order (metal-vmm QUEUE 197.3)" {
    // Every size this kernel uses: rng's, the Block's and net's.
    try wrapCase(4);
    try wrapCase(8);
    try wrapCase(64);
}
