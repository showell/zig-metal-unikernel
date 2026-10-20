//! **A DIGITALOCEAN VOLUME: A SCSI DISK BEHIND A VIRTIO CONTROLLER.** A
//! droplet's own disk is virtio-blk (slot 06), and every new image replaces
//! it whole. A volume is a separate disk that survives that, and it arrives
//! on the virtio-SCSI controller in slot 05 — which a droplet has whether or
//! not any volume is attached. So chat's files go on a volume, and this is how
//! the machine reaches one.
//!
//! virtio-scsi carries SCSI commands. A request is a header naming the disk
//! (target and LUN) with a command block (the CDB), then the data, then a
//! response the device writes: its own outcome, the disk's SCSI status, and
//! sense data saying why when the status is CHECK CONDITION. Six commands are
//! all a disk needs here: INQUIRY (is there a disk at this address?), READ
//! CAPACITY (how big?), MODE SENSE (does it cache writes?), MODE SELECT
//! (stop caching them), READ(10), WRITE(10), and SYNCHRONIZE CACHE (make
//! what it cached durable).
//!
//! **IT IS A `virtio_blk.Block` LIKE ANY OTHER.** The FAT16 volume and the GPT
//! reader call `read`, `readMany`, `write` and `writeMany`; on a Block brought
//! up here those become SCSI commands, and nothing above notices.
//!
//! virtio 1.2 §5.6 (the device), SCSI Primary Commands (SPC-4) for INQUIRY and
//! the sense data, SCSI Block Commands (SBC-3) for the rest. The numbers below
//! are theirs.

const std = @import("std");
const props = @import("coverage");
const virtio = @import("virtio.zig");
const virtio_blk = @import("virtio_blk.zig");
const tsc = @import("tsc.zig");
const mode = @import("scsi_mode.zig");

/// The virtio device type of a SCSI controller.
pub const device_id: u32 = 8;

const control_queue: u16 = 0;
const event_queue: u16 = 1;
const request_queue: u16 = 2;

/// The sizes the device uses unless told otherwise (§5.6.4), and the only ones
/// this driver speaks: the request header's CDB, and the sense data in a
/// response.
const cdb_size = 32;
const sense_size = 96;

/// A disk's address on the controller.
pub const Address = struct {
    target: u8,
    lun: u16,

    /// The 8-byte LUN field (§5.6.6.1): 1, the target, then the LUN in the
    /// flat addressing SAM-5 calls single-level, as Linux writes it.
    fn field(self: Address) [8]u8 {
        return .{ 1, self.target, 0x40 | @as(u8, @truncate(self.lun >> 8)), @truncate(self.lun), 0, 0, 0, 0 };
    }
};

/// What the device reads first. **ITS LENGTH ON THE WIRE IS EXACTLY
/// `request_len`**: the device takes that many bytes as the header and any
/// readable bytes after them as data, so the struct's own padding must not go
/// in the descriptor.
pub const Request = extern struct {
    lun: [8]u8,
    tag: u64,
    task_attr: u8,
    prio: u8,
    crn: u8,
    cdb: [cdb_size]u8,
};
const request_len = 19 + cdb_size;

/// What the device writes first, before any data it returns. Its length on the
/// wire is exactly `response_len`, for the same reason.
pub const Response = extern struct {
    sense_len: u32,
    residual: u32,
    status_qualifier: u16,
    status: u8,
    response: u8,
    sense: [sense_size]u8,
};
const response_len = 12 + sense_size;

comptime {
    if (@offsetOf(Request, "cdb") != 19) @compileError("virtio-scsi request header layout");
    if (@sizeOf(Response) != response_len) @compileError("virtio-scsi response layout");
}

/// The device's own outcome (§5.6.6.1): OK means the command reached the disk,
/// and `status` says how it went there.
const response_ok: u8 = 0;
const response_bad_target: u8 = 3;
/// SCSI status: GOOD, or CHECK CONDITION with sense data.
const status_good: u8 = 0;
const status_check_condition: u8 = 2;
/// The sense key a disk reports once after it is attached or reset: a fact to
/// be told, not a failure. The command is simply sent again.
const sense_unit_attention: u8 = 6;

/// The memory a SCSI disk needs on top of `virtio_blk.BlockMemory`'s ring: the
/// controller's two other queues, the header and response, and a sector of
/// scratch for what INQUIRY and READ CAPACITY return.
pub const Memory = struct {
    control_ring: virtio_blk.Block.Q.RingType align(16) = undefined,
    event_ring: virtio_blk.Block.Q.RingType align(16) = undefined,
    request: Request align(16) = undefined,
    response: Response align(16) = undefined,
    scratch: [512]u8 align(16) = undefined,
    /// **THE EVENT QUEUE'S BUFFERS** (virtio 1.2 §5.6.6.3; metal-vmm QUEUE
    /// 198.4): with none waiting, the device drops every event (a transport
    /// reset, a disk removed, a parameter change) and says nothing. Each is
    /// offered at bring-up, read and offered again as the device uses it.
    events: [event_buffers][16]u8 align(16) = undefined,
    event_q: ?virtio_blk.Block.Q = null,
};

/// The event queue's buffers: events come one at a time, and one dropped
/// is counted (`EVENTS_MISSED`) rather than lost silently.
const event_buffers = 4;
comptime {
    std.debug.assert(event_buffers <= virtio_blk.Block.Q.RingType.len);
}

/// Offers every event buffer, once the device is running.
fn offerEvents(mem: *Memory) void {
    const q = if (mem.event_q) |*q| q else return;
    for (0..event_buffers) |k| {
        mem.events[k] = @splat(0);
        q.ring.desc[k] = .{ .addr = @intFromPtr(&mem.events[k]), .len = 16, .flags = virtio.desc_flag_write, .next = 0 };
        q.offer(@intCast(k));
    }
    q.notify();
}

/// **WHAT THE DEVICE SAID SINCE** (198.4): every used event buffer read,
/// counted (disk_failures' `noteEvent`) and offered again. A reset or a
/// parameter change asks for the write cache again, as a unit attention
/// does. Polled at every command: the queue is not vectored.
pub fn pollEvents(b: *virtio_blk.Block) void {
    const mem = b.scsi orelse return;
    // The queue in place: `take` moves its `last_used`.
    const q = if (mem.event_q) |*q| q else return;
    var any = false;
    while (q.take()) |e| {
        if (e.id >= event_buffers) {
            props.reachable(@src(), "scsi: the event queue answers a buffer never offered", null);
            b.failures.event_other +%= 1;
            continue;
        }
        const k: u16 = @intCast(e.id);
        props.reachable(@src(), "scsi: the device says something on the event queue", null);
        if (b.failures.noteEvent(mem.events[k])) b.cache_recheck = true;
        mem.events[k] = @splat(0);
        q.offer(k);
        any = true;
    }
    if (any) q.notifyIfWanted();
}

/// How a command ended. `residual` is how many of the bytes asked for were
/// not moved (virtio 1.2 §5.6.6): a command can end GOOD having moved fewer,
/// an underrun, which is not the whole transfer it was asked for.
const Outcome = struct { response: u8, status: u8, sense_key: u8, asc: u8 = 0, ascq: u8 = 0, residual: u32 = 0 };

// The additional sense codes of a UNIT ATTENTION that can mean the mode
// pages are not what this driver set (a power on or reset, 29h with any
// qualifier, or mode parameters changed, 2Ah/01h) are told apart, with the
// others, in disk_failures.zig's `noteAttention`.

const Direction = enum { none, from_disk, to_disk };

/// One command, start to finish, polled to completion.
fn command(b: *virtio_blk.Block, at: Address, cdb: []const u8, dir: Direction, addr: u64, len: u32) Outcome {
    // A disk that stopped answering is sent nothing more (193.2): reads and
    // writes are refused before they get here, a flush or a recheck here.
    if (b.refuseEnded()) return .{ .response = 0xFF, .status = 0xFF, .sense_key = 0, .asc = 0, .ascq = 0, .residual = 0 };
    const mem = b.scsi.?;
    pollEvents(b);
    mem.request = .{ .lun = at.field(), .tag = 0, .task_attr = 0, .prio = 0, .crn = 0, .cdb = @splat(0) };
    @memcpy(mem.request.cdb[0..cdb.len], cdb);
    mem.response.response = 0xFF; // so a device that writes nothing is not read as OK
    mem.response.status = 0xFF;

    // Every buffer the device reads, then every buffer it writes.
    const d = &b.q.ring.desc;
    const req: virtio.Desc = .{ .addr = @intFromPtr(&mem.request), .len = request_len, .flags = virtio.desc_flag_next, .next = 1 };
    const resp_flags = virtio.desc_flag_write;
    switch (dir) {
        .none => {
            d[0] = req;
            d[1] = .{ .addr = @intFromPtr(&mem.response), .len = response_len, .flags = resp_flags, .next = 0 };
        },
        .from_disk => {
            d[0] = req;
            d[1] = .{ .addr = @intFromPtr(&mem.response), .len = response_len, .flags = resp_flags | virtio.desc_flag_next, .next = 2 };
            d[2] = .{ .addr = addr, .len = len, .flags = virtio.desc_flag_write, .next = 0 };
        },
        .to_disk => {
            d[0] = req;
            d[1] = .{ .addr = addr, .len = len, .flags = virtio.desc_flag_next, .next = 2 };
            d[2] = .{ .addr = @intFromPtr(&mem.response), .len = response_len, .flags = resp_flags, .next = 0 };
        },
    }

    const began = tsc.read();
    b.q.offer(0);
    b.q.notify();
    const ended = b.q.waitFor(virtio.wait_budget_ticks);
    virtio.ack(b.device);
    b.busy_ticks +%= tsc.read() -% began;
    b.requests +%= 1;
    // No answer: a response no command reads as good (193.2).
    if (!b.answered(ended)) return .{ .response = 0xFF, .status = 0xFF, .sense_key = 0, .asc = 0, .ascq = 0, .residual = 0 };

    // Fixed or descriptor format (mode.senseOf, 197.3).
    const got = mode.senseOf(mem.response.sense[0..@min(mem.response.sense_len, mem.response.sense.len)]);
    const sense_key = got.key;
    const asc = got.asc;
    const ascq = got.ascq;
    b.failures.noteScsi(mem.response.response, mem.response.status, sense_key, asc, ascq);
    return .{ .response = mem.response.response, .status = mem.response.status, .sense_key = sense_key, .asc = asc, .ascq = ascq, .residual = mem.response.residual };
}

/// A command, sent again while the disk answers UNIT ATTENTION (it does once
/// after being attached, and may again after a reset). Three tries are plenty:
/// a disk that keeps saying it is a failure.
fn commandSettled(b: *virtio_blk.Block, at: Address, cdb: []const u8, dir: Direction, addr: u64, len: u32) Outcome {
    var tries: u8 = 0;
    while (true) : (tries += 1) {
        const o = command(b, at, cdb, dir, addr, len);
        const attention = o.response == response_ok and o.status == status_check_condition and
            o.sense_key == sense_unit_attention;
        // **A RESET PUTS THE MODE PAGES BACK** (metal-vmm QUEUE 119): a
        // MODE SELECT with SP clear saves nothing, so after a power on or a
        // reset the write cache this driver turned off is on again. Marked
        // here, and the caller looks again once its own command is done.
        // Every unit attention is counted by what it says (193, gap 7).
        if (attention and b.failures.noteAttention(o.asc, o.ascq)) b.cache_recheck = true;
        switch (mode.retry(tries, attention)) {
            .again => {},
            .done => return o,
            .gave_up => {
                b.failures.attentions_unsettled +%= 1;
                return o;
            },
        }
    }
}

fn good(o: Outcome) bool {
    return o.response == response_ok and o.status == status_good;
}

/// GOOD, and every byte asked for moved.
fn whole(o: Outcome) bool {
    return good(o) and o.residual == 0;
}

/// READ(10) or WRITE(10): `len` bytes at `addr`, from or to the sectors from
/// `lba`. Answers a virtio-blk status byte, which is what every caller of a
/// Block already understands.
pub fn transfer(b: *virtio_blk.Block, at: Address, from_disk: bool, lba: u64, addr: u64, len: u32) u8 {
    if (lba + len / 512 > 0xFFFF_FFFF or len / 512 > 0xFFFF) return virtio_blk.blk_s_unsupp;
    const l: u32 = @intCast(lba);
    const n: u16 = @intCast(len / 512);
    const cdb = [10]u8{
        if (from_disk) 0x28 else 0x2A, 0,
        @truncate(l >> 24),            @truncate(l >> 16),
        @truncate(l >> 8),             @truncate(l),
        0,                             @truncate(n >> 8),
        @truncate(n),                  0,
    };
    const o = commandSettled(b, at, &cdb, if (from_disk) .from_disk else .to_disk, addr, len);
    if (b.cache_recheck) recheckCache(b, at);
    // **A SHORT TRANSFER IS A FAILED ONE.** A read that moved fewer bytes
    // than asked leaves the rest of the buffer as it was; a write that did
    // has not put them on the disk. Neither is answered as done.
    if (good(o) and o.residual != 0) {
        b.failures.short_transfers +%= 1;
        props.reachable(@src(), "scsi: a read or write ends GOOD having moved fewer bytes than asked, and fails", .{ .residual = o.residual, .len = len });
        return virtio_blk.blk_s_ioerr;
    }
    return if (good(o)) virtio_blk.blk_s_ok else virtio_blk.blk_s_ioerr;
}

/// **SYNCHRONIZE CACHE(10)** over the whole disk (SBC-3 §5.22: a zero LBA
/// and a zero count mean every block): everything the disk has answered as
/// written is durable when this answers GOOD. A disk that does not know the
/// command (ILLEGAL REQUEST) has no cache to synchronize, and says so once:
/// it is marked write-through and never asked again.
pub fn synchronize(b: *virtio_blk.Block, at: Address) u8 {
    const cdb = [10]u8{ 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const o = commandSettled(b, at, &cdb, .none, 0, 0);
    if (b.cache_recheck) recheckCache(b, at);
    switch (mode.synced(good(o), o.response == response_ok and o.status == status_check_condition, o.sense_key)) {
        .ok => return virtio_blk.blk_s_ok,
        .write_through => {
            b.write_cache = false;
            b.synchronize_unknown = true;
            return virtio_blk.blk_s_ok;
        },
        .failed => return virtio_blk.blk_s_ioerr,
    }
}

/// **DOES THE DISK CACHE WRITES?** MODE SENSE(10) for the caching mode page
/// (SBC-3 §6.5.5, page 08h), current values, no block descriptors: its WCE
/// bit says writes are answered from a cache. Null when the disk does not
/// answer or the page is not there, which `Block.flush` treats as a cache.
/// `got` is how much of the answer the disk sent, for `turnCacheOff`.
fn writeCache(b: *virtio_blk.Block, at: Address, scratch: u64, page: []const u8, got: *usize) ?bool {
    got.* = 0;
    const want: u16 = 8 + 20; // the mode parameter header, then the page
    const cdb = [10]u8{ 0x5A, 0x08, 0x08, 0, 0, 0, 0, @truncate(want >> 8), @truncate(want), 0 };
    const o = commandSettled(b, at, &cdb, .from_disk, scratch, want);
    if (!good(o)) {
        props.reachable(@src(), "scsi: a disk that does not answer MODE SENSE is taken to cache", null);
        return null;
    }
    // Only what the disk sent is its answer: the bytes past it in `page` are
    // whatever was there before.
    got.* = want -| o.residual;
    // The page read: scsi_mode.wceOf, pure and tested (198.2).
    const wce = mode.wceOf(page, got.*);
    if (wce == null) props.reachable(@src(), "scsi: a MODE SENSE answer without the caching page is taken to cache", null);
    return wce;
}

/// **THE WRITE CACHE TURNED OFF** (metal-vmm QUEUE 112, Steve's choice
/// 2026-10-09): with a cache, a power cut keeps the writes it had taken in an
/// order of its own, and FAT's ordering (data, then the FAT, then the
/// directory entry) is lost with it: a file can be left Damaged, or a
/// cluster in two files. Writing through keeps the order the driver wrote
/// in. MODE SELECT(10), PF set and SP clear, sends back the caching page
/// MODE SENSE just answered in `page`, with WCE cleared, the header's mode
/// data length and device-specific byte zeroed, and no block descriptors
/// (SPC-4 §6.13, as Linux's sd does). The caller reads the page again to
/// know: a disk may take the command and keep caching. Only a page as
/// SBC-3 has it, whole within the `got` bytes the disk sent, is sent back
/// (`scsi_mode.selectList`, metal-vmm QUEUE 130).
fn turnCacheOff(b: *virtio_blk.Block, at: Address, scratch: u64, page: []u8, got: usize) bool {
    const len = mode.selectList(page, got) orelse {
        props.reachable(@src(), "scsi: a caching page not as SBC-3 has it is not sent back", null);
        return false;
    };
    const cdb = [10]u8{ 0x55, 0x10, 0, 0, 0, 0, 0, @truncate(len >> 8), @truncate(len), 0 };
    const o = commandSettled(b, at, &cdb, .to_disk, scratch, len);
    if (!good(o)) {
        props.reachable(@src(), "scsi: a disk that refuses to turn its write cache off", null);
        return false;
    }
    return true;
}

/// **THE WRITE CACHE, LOOKED AT AGAIN AFTER A RESET** (metal-vmm QUEUE
/// 119): sensed; if on, turned off and read back as at bring-up; and what
/// it took in meanwhile (the command that met the reset, sent again into
/// the cache) synchronized. A disk that will not turn it off is left as it
/// says: `write_cache` true, so every answer waits on a SYNCHRONIZE
/// (io.durable), and /admin/host derives what it says from it
/// (`scsi_mode.report`).
fn recheckCache(b: *virtio_blk.Block, at: Address) void {
    b.cache_recheck = false;
    b.cache_rechecks +%= 1;
    const mem = b.scsi.?;
    const scratch = @intFromPtr(&mem.scratch);
    var got: usize = 0;
    // What the disk says at each step is asked here; what it leaves is
    // scsi_mode.afterReset's, pure and tested (198.2).
    const on = writeCache(b, at, scratch, &mem.scratch, &got);
    var taken = false;
    var after: ?bool = on;
    if (on == true) {
        props.reachable(@src(), "scsi: a reset turned the write cache back on, and it is turned off again", null);
        taken = turnCacheOff(b, at, scratch, &mem.scratch, got);
        after = writeCache(b, at, scratch, &mem.scratch, &got);
    }
    var r = mode.afterReset(on, taken, after);
    if (r.synchronize) {
        // What the cache took before it was turned off again.
        const sync = [10]u8{ 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        if (!good(commandSettled(b, at, &sync, .none, 0, 0))) {
            props.reachable(@src(), "scsi: after a reset, the cache turned off again, its held writes fail to synchronize", null);
            r = mode.after_failed_sync;
        }
    }
    b.write_cache = r.write_cache;
    if (r.unflushed) b.unflushed = true;
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

pub const Error = virtio.Error || error{
    /// The controller has no disk on it: no volume is attached.
    NoDisk,
    /// The device's CDB or sense sizes are not the defaults this driver uses.
    UnexpectedSizes,
    /// The disk would not say how big it is, or its sectors are not 512 bytes.
    NoCapacity,
};

/// The controller brought up, and the first disk on it found: a `Block` whose
/// reads and writes are SCSI commands to that disk. `NoDisk` is the ordinary
/// answer on a droplet with no volume attached, since the controller is there
/// either way.
pub fn bring(device: virtio.Device, mem: *virtio_blk.BlockMemory) Error!virtio_blk.Block {
    const st = try virtio.negotiate(device, 0);
    if (virtio.configRead32(device, 24) != cdb_size or virtio.configRead32(device, 20) != sense_size) {
        props.reachable(@src(), "scsi: a controller whose CDB or sense size is not the default", null);
        return Error.UnexpectedSizes;
    }
    // The control queue is set up because the device has it; nothing is
    // ever sent on it. The event queue gets buffers once the device runs
    // (`offerEvents`, 198.4).
    _ = try virtio_blk.Block.Q.setup(device, control_queue, &mem.scsi.control_ring);
    mem.scsi.event_q = try virtio_blk.Block.Q.setup(device, event_queue, &mem.scsi.event_ring);
    const q = try virtio_blk.Block.Q.setup(device, request_queue, &mem.ring);
    try virtio.driverOk(device, st);
    offerEvents(&mem.scsi);

    var b = virtio_blk.Block{
        .device = device,
        .q = q,
        .header = &mem.header,
        .status = &mem.status,
        .capacity = 0,
        .scsi = &mem.scsi,
        // virtio 1.2 §5.6.4: max_sectors le32 at 8, the most a command may
        // carry; obeyed where it is less than ours (metal-vmm QUEUE 178). A
        // controller that says 0 has said nothing.
        .most_sectors = virtio_blk.Block.mostSectors(switch (virtio.configRead32(device, 8)) {
            0 => null,
            else => |n| @as(u64, n) * 512,
        }),
    };

    // virtio 1.2 §5.6.4: max_channel le16 at 28, max_target le16 at 30, max_lun le32 at 32.
    const max_target: u16 = @min(virtio.configRead16(device, 30), 63);
    const max_lun: u32 = @min(virtio.configRead32(device, 32), 7);
    const scratch = @intFromPtr(&mem.scsi.scratch);
    var target: u16 = 0;
    while (target <= max_target) : (target += 1) {
        var lun: u16 = 0;
        while (lun <= max_lun) : (lun += 1) {
            const at = Address{ .target = @intCast(target), .lun = lun };
            const inquiry = [6]u8{ 0x12, 0, 0, 0, 36, 0 };
            const o = commandSettled(&b, at, &inquiry, .from_disk, scratch, 36);
            if (o.response == response_bad_target) break; // nobody at this target
            if (!good(o) or o.residual >= 36) continue;
            // Peripheral qualifier 0 (connected) and device type 0 (a disk).
            if (mem.scsi.scratch[0] != 0x00) continue;

            const capacity = [10]u8{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
            if (!whole(commandSettled(&b, at, &capacity, .from_disk, scratch, 8))) {
                props.reachable(@src(), "scsi: a disk that will not say how big it is", null);
                return Error.NoCapacity;
            }
            const last = be32(mem.scsi.scratch[0..4]);
            if (be32(mem.scsi.scratch[4..8]) != 512 or last == 0xFFFF_FFFF) {
                props.reachable(@src(), "scsi: a disk whose sectors are not 512 bytes, or too many to count", null);
                return Error.NoCapacity;
            }
            b.capacity = @as(u64, last) + 1;
            b.address = at;
            // **THE DISK'S OWN MOST** (metal-vmm QUEUE 180.1): Block Limits'
            // MAXIMUM TRANSFER LENGTH, obeyed where it is less than the
            // controller's and ours. A disk with no such page (CHECK
            // CONDITION), or one that says 0, is not limited by it.
            const limits = [6]u8{ 0x12, 1, 0xB0, 0, 64, 0 };
            const lo = commandSettled(&b, at, &limits, .from_disk, scratch, 64);
            b.disk_most_sectors = if (good(lo)) mode.blockLimitsMost(&mem.scsi.scratch, 64 -| lo.residual) else null;
            if (b.disk_most_sectors) |most| {
                props.reachable(@src(), "scsi: a disk says the most one command carries", .{ .sectors = most });
                b.most_sectors = @min(b.most_sectors, most);
            }
            var got: usize = 0;
            b.write_cache = writeCache(&b, at, scratch, &mem.scsi.scratch, &got);
            if (b.write_cache == true) {
                b.cache_on_at_bringup = true;
                // Whether it took is read back: what the disk says now is
                // the one fact (`write_cache`).
                _ = turnCacheOff(&b, at, scratch, &mem.scsi.scratch, got);
                b.write_cache = writeCache(&b, at, scratch, &mem.scsi.scratch, &got);
            }
            // The power-on attention of bring-up is answered just above.
            b.cache_recheck = false;
            return b;
        }
    }
    props.reachable(@src(), "scsi: a controller with no disk on it", null);
    return Error.NoDisk;
}
