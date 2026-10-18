//! The virtio block driver, over virtio.zig's transport and queue: a disk
//! found and brought up (`Block.init`, or SCSI through scsi.zig), its
//! requests and their answers, the write cache and its flush, the faults a
//! test plants, and a disk in memory for the tests.

const tsc = @import("tsc.zig");
const props = @import("coverage");

const scsi = @import("scsi.zig");
const durable = @import("durable.zig");

const disk_failures = @import("disk_failures.zig");
const virtio = @import("virtio.zig");

/// virtio-blk's VIRTIO_BLK_F_SIZE_MAX (§5.2.3): `size_max`, at config 8, is
/// the most bytes in one segment.
const blk_f_size_max: u32 = 1 << 1;
/// VIRTIO_BLK_F_SEG_MAX: `seg_max`, at config 12, is the most segments in
/// one request.
const blk_f_seg_max: u32 = 1 << 2;

const blk_t_in: u32 = 0; // read from the device
const blk_t_out: u32 = 1; // write to the device

/// The three status bytes virtio-blk answers with. **The floor's Disk door
/// invented an outcome; this is where the outcome comes from.**
pub const blk_s_ok: u8 = 0;
pub const blk_s_ioerr: u8 = 1;
pub const blk_s_unsupp: u8 = 2;
/// Ours, not virtio's: the disk stopped answering (a request it never ended,
/// or it asked for a reset), so no request goes to it any more (193.2).
pub const blk_s_ended: u8 = 0xEE;

const BlkReqHeader = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

pub const Block = struct {
    const queue_size = 8;
    pub const Q = virtio.Queue(queue_size);

    device: virtio.Device,
    q: Q,
    header: *BlkReqHeader,
    status: *volatile u8,
    /// The device's size in 512-byte sectors, from its config space.
    capacity: u64,
    /// **THE MOST SECTORS ONE REQUEST ASKS FOR, ON THIS DISK** (metal-vmm
    /// QUEUE 178): `most_sectors_ours`, or less where the device says less
    /// (virtio-blk's `size_max`, virtio-scsi's `max_sectors`), obeyed. A
    /// filesystem asks for no more, and refuses at mount a disk that takes
    /// less than a cluster (`disk_fat`).
    most_sectors: u32 = most_sectors_ours,
    /// What a SCSI disk itself said of its most (INQUIRY's Block Limits
    /// page, metal-vmm QUEUE 180.1), for the host facts; null where it said
    /// nothing, or on virtio-blk.
    disk_most_sectors: ?u32 = null,
    /// **THE MOST BYTES IN ONE SEGMENT** (virtio-blk's `size_max`, metal-vmm
    /// QUEUE 180.2): a request's data is chained in segments of at most
    /// this; null, one segment.
    segment_bytes: ?u32 = null,

    /// **WHAT THE DEVICE COST.** Every request counted, and the timestamp-counter
    /// ticks spent between offering it and seeing it done — so a host can say
    /// how much of a slow HTTP request was the disk, rather than guessing. The
    /// soak could only see the whole machine slowing down; these split it.
    requests: u64 = 0,
    busy_ticks: u64 = 0,
    /// **A DISK THAT STOPPED ANSWERING** (metal-vmm QUEUE 193.2): a request
    /// it never ended in `wait_budget_ticks`, or it set DEVICE_NEEDS_RESET.
    /// The abandoned request's buffers are still the device's, which may
    /// yet write into them, so nothing more goes to it: every later request
    /// is `blk_s_ended`, counted. Only a reset (or a restart) brings it back.
    ended: enum { serving, timed_out, needs_reset } = .serving,
    /// Requests refused because the disk had stopped answering.
    refused_after_end: u64 = 0,
    /// **WHAT ITS FAILED REQUESTS ENDED WITH** (metal-vmm QUEUE 193.3): on
    /// virtio-blk each status but OK; on SCSI each command's response,
    /// CHECK CONDITION by sense key, and short transfers.
    failures: disk_failures.Failures = .{},

    /// **ON A SCSI CONTROLLER, THE DISK THIS BLOCK IS** (`scsi.zig`), and the
    /// memory its commands are built in. Null on virtio-blk.
    address: ?scsi.Address = null,
    scsi: ?*scsi.Memory = null,

    /// **WRITES THE DISK HAS ANSWERED BUT MAY NOT HAVE KEPT.** A disk with a
    /// write cache answers a write once the bytes are in the cache; only a
    /// flush makes them durable. Set by every write, cleared by `flush`.
    /// `io.durable` reads it before any response leaves the machine.
    unflushed: bool = false,
    /// What the disk says of its own cache: true (writes wait in it), false
    /// (it writes through), or null (it did not say). A SCSI disk says in
    /// MODE SENSE's caching page (`scsi.zig`). A virtio-blk disk is
    /// write-through unless VIRTIO_BLK_F_FLUSH is negotiated (virtio 1.2
    /// §5.2.5.1), and this driver never negotiates it, so it is false there.
    write_cache: ?bool = null,
    /// Whether the disk said its write cache was on at bring-up, before
    /// boot turned it off (`scsi.turnCacheOff`). With `write_cache`, all
    /// that is said of the cache is derived from it (`scsi_mode.report`,
    /// metal-vmm QUEUE 131, #11): no second stored fact to drift.
    cache_on_at_bringup: bool = false,
    /// A reset or a change of mode parameters was told (UNIT ATTENTION), so
    /// the write cache may be on again: looked at after the command that
    /// met it (`scsi.recheckCache`). How many times it was.
    cache_recheck: bool = false,
    cache_rechecks: u64 = 0,
    /// **HOW MANY TIMES A READ IS TRIED** before its failure is the caller's
    /// (B25, Steve 2026-10-08). 1 while the machine serves: a request that
    /// meets a failing disk fails, and says so. Boot sets more
    /// (probe/gopher.zig): one refused read of the partition table or the FAT
    /// would otherwise stop the machine, and a disk that refused once, a
    /// transient error, answers the next time. Writes are never tried again
    /// here: what a failed one left behind is the filesystem's to judge.
    read_tries: u8 = 1,
    /// Reads that failed and answered on a later try.
    reads_retried: u64 = 0,
    /// Flush points (every flush with something written before it, on any
    /// disk), and those the disk answered with an error.
    flushes: u64 = 0,
    flush_failures: u64 = 0,
    /// **WHAT REACHED THE DISK** (metal-vmm QUEUE 193, gap 9): flush points
    /// that sent SYNCHRONIZE CACHE; a write-through disk's are cleared with
    /// no command. And whether a SYNCHRONIZE was refused as unknown
    /// (ILLEGAL REQUEST), which turned the disk write-through.
    synchronizes_sent: u64 = 0,
    synchronize_unknown: bool = false,

    /// **A DISK IN MEMORY, FOR HOST TESTS** (`inMemory`): every transfer is a
    /// copy to or from these bytes, and no device is touched. Null on a real
    /// device.
    memory: ?[]u8 = null,
    /// A host test's way to make the disk fail: once this many requests have
    /// been served, every further one answers `blk_s_ioerr`.
    fail_after: ?u64 = null,
    /// The same, counting only writes: once this many have been served,
    /// every further request fails. A machine stopped after its Nth write
    /// (QUEUE.md item 79); the reads between two writes change nothing.
    fail_after_writes: ?u64 = null,
    /// Writes served, on a disk in memory.
    writes: u64 = 0,
    /// **EACH REQUEST, TOLD** (metal-vmm 151): a host bench's way to see
    /// what a disk in memory is asked, by kind and place. Memory disks only.
    observe: ?Observe = null,
    /// A host test's lie, told once, at request number `at` (counted as
    /// `requests` counts) on a disk in memory (QUEUE.md item 80).
    fault: ?Fault = null,
    /// **A SECOND FAULT, OF ITS OWN** (metal-vmm 145's review), for a
    /// recovery that writes in its turn (rename's undo) to be failed too:
    /// `fails` or `lands_and_fails` on the write numbered `at`. Memory disks
    /// only, as `fault` is.
    second: ?Fault = null,
    /// The sector the fault's write went to, for `then_garbage`.
    fault_lba: ?u64 = null,

    /// **A HOST TEST'S WRITE CACHE** (metal-vmm QUEUE 112), on a disk in
    /// memory: told of every write as it lands in `memory`, which is what
    /// the disk shows, and of every flush, which makes what it was told
    /// durable. What a cut keeps of the rest is the test's to choose
    /// (`test_disk.Cache`). Null: the disk writes through, as before.
    cache: ?*const Cache = null,

    pub const Cache = struct {
        context: *anyopaque,
        wrote: *const fn (context: *anyopaque, lba: u64, bytes: []const u8) void,
        flushed: *const fn (context: *anyopaque) void,
    };

    pub const Observe = struct {
        context: *anyopaque,
        each: *const fn (context: *anyopaque, write: bool, lba: u64, sectors: u32) void,
    };

    pub const Fault = struct {
        at: u64,
        kind: enum {
            /// The request answers `blk_s_ioerr`, and the next one is served.
            fails,
            /// A write answers OK and nothing lands.
            lands_nothing,
            /// A write lands whole and answers `blk_s_ioerr`: the disk took
            /// it and said it did not (metal-vmm QUEUE 131), which is what a
            /// caller cannot tell from one that did not land.
            lands_and_fails,
            /// A write of more than one sector answers OK and only its first
            /// half lands: a torn write.
            torn,
            /// The same, its SECOND half landing (metal-vmm QUEUE 187.1): a
            /// cut lands any of a request's sectors, not only a prefix.
            torn_tail,
            /// A read answers OK with other bytes than the disk's: what a
            /// short read leaves in the buffer, or a device that lies.
            garbage,
        },
        /// The bytes `garbage` reads.
        seed: u8 = 0xA5,
        /// **A SECOND FAILURE** (metal-vmm QUEUE 134): this many requests
        /// after `at` fail too, a read among them first filling its buffer
        /// with other bytes, as a device that wrote part of it may. What a
        /// caller does when its read-back of a failed write fails as well.
        then_fail: u8 = 0,
        /// This many reads after `at`, of the sector `at` wrote, answer OK
        /// with other bytes: rot on the read-backs of a failed write
        /// (metal-vmm QUEUE 134(h), 138(b)).
        then_garbage: u8 = 0,
    };

    /// A disk of `bytes.len / 512` sectors held in `bytes`, which the caller
    /// owns. For host tests of what sits on a disk (`disk_fat.zig`, `io.zig`):
    /// on a host every address is the caller's own memory, so a transfer is a
    /// copy. Nothing here may be called on it but the transfers.
    pub fn inMemory(bytes: []u8) Block {
        return .{
            .device = .{ .mmio = 0 },
            .q = undefined,
            .header = undefined,
            .status = undefined,
            .capacity = bytes.len / 512,
            .memory = bytes,
        };
    }

    fn memoryTransfer(self: *Block, disk: []u8, kind: u32, lba: u64, addr: u64, len: u32) u8 {
        if (self.fail_after) |n| if (self.requests >= n) return blk_s_ioerr;
        if (self.fail_after_writes) |n| if (self.writes >= n) return blk_s_ioerr;
        const number = self.requests;
        self.requests +%= 1;
        if (self.observe) |o| o.each(o.context, kind != blk_t_in, lba, len / 512);
        if (kind != blk_t_in) {
            self.writes +%= 1;
            self.unflushed = true;
        }
        const at = lba * 512;
        if (at > disk.len or len > disk.len - at) return blk_s_ioerr;
        const there = disk[@intCast(at)..][0..len];
        const here: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
        if (self.fault) |f| if (number > f.at and number - f.at <= f.then_fail) {
            if (kind == blk_t_in) {
                for (here[0..len], 0..) |*b, i| b.* = @truncate(i *% 131 +% f.seed);
            }
            return blk_s_ioerr;
        };
        if (self.fault) |f| if (kind == blk_t_in and self.fault_lba == lba and number > f.at and number - f.at <= f.then_garbage) {
            for (here[0..len], 0..) |*b, i| b.* = @truncate(i *% 167 +% f.seed);
            return blk_s_ok;
        };
        if (self.second) |f| if (f.at == number and kind != blk_t_in) switch (f.kind) {
            .fails => return blk_s_ioerr,
            .lands_and_fails => {
                @memcpy(there, here[0..len]);
                if (self.cache) |c| c.wrote(c.context, lba, there);
                return blk_s_ioerr;
            },
            else => {},
        };
        if (self.fault) |f| if (f.at == number) {
            switch (f.kind) {
                .fails => return blk_s_ioerr,
                .lands_nothing => if (kind != blk_t_in) return blk_s_ok,
                .lands_and_fails => if (kind != blk_t_in) {
                    self.fault_lba = lba;
                    @memcpy(there, here[0..len]);
                    if (self.cache) |c| c.wrote(c.context, lba, there);
                    return blk_s_ioerr;
                },
                .torn => if (kind != blk_t_in and len > 512) {
                    const half = len / 512 / 2 * 512;
                    @memcpy(there[0..half], here[0..half]);
                    if (self.cache) |c| c.wrote(c.context, lba, there[0..half]);
                    return blk_s_ok;
                },
                .torn_tail => if (kind != blk_t_in and len > 512) {
                    const half = len / 512 / 2 * 512;
                    @memcpy(there[half..len], here[half..len]);
                    if (self.cache) |c| c.wrote(c.context, lba + half / 512, there[half..len]);
                    return blk_s_ok;
                },
                .garbage => if (kind == blk_t_in) {
                    for (here[0..len], 0..) |*b, i| b.* = @truncate(i *% 167 +% f.seed);
                    return blk_s_ok;
                },
            }
        };
        if (kind == blk_t_in) @memcpy(here[0..len], there) else {
            @memcpy(there, here[0..len]);
            if (self.cache) |c| c.wrote(c.context, lba, there);
        }
        return blk_s_ok;
    }

    /// `mem` is memory the caller owns and keeps for as long as the device is
    /// up; it must be identity-mapped, since what goes in a descriptor is a
    /// PHYSICAL address.
    pub fn init(device: virtio.Device, mem: *BlockMemory) virtio.Error!Block {
        // VIRTIO_BLK_F_SIZE_MAX and _SEG_MAX taken when offered: they change
        // nothing of the protocol, and say the most one segment may carry
        // and how many segments a request may have (178, 180.2).
        const got = try virtio.negotiateWith(device, 0, blk_f_size_max | blk_f_seg_max);
        const q = try Q.setup(device, 0, &mem.ring);
        try virtio.driverOk(device, got.st);
        const size_max: ?u32 = if (got.low & blk_f_size_max != 0) virtio.configRead32(device, 8) else null;
        const seg_max: ?u32 = if (got.low & blk_f_seg_max != 0) virtio.configRead32(device, 12) else null;
        return .{
            .device = device,
            .q = q,
            .header = &mem.header,
            .status = &mem.status,
            .capacity = virtio.configRead64(device, 0),
            .most_sectors = mostSectorsBlk(size_max, seg_max),
            .segment_bytes = if (size_max) |n| if (n != 0) n else null else null,
            // No VIRTIO_BLK_F_FLUSH negotiated: write-through.
            .write_cache = false,
        };
    }

    /// The data segments a request's chain holds besides its header and
    /// status (`Q`'s eight descriptors).
    pub const most_segments: u32 = queue_size - 2;

    /// The segments `len` bytes take at most `per` a segment (null: one).
    pub fn segmentsFor(len: u32, per: ?u32) u32 {
        const p = per orelse return 1;
        return (len + p - 1) / p;
    }

    /// **VIRTIO-BLK'S MOST** (metal-vmm QUEUE 180.2): `size_max` limits each
    /// SEGMENT, and a request may have `seg_max` of them (one where the
    /// device does not say, as Linux takes it), at most `most_segments`.
    /// `size_max` 0 is unset, as virtio-scsi's 0 is. Never more than ours.
    pub fn mostSectorsBlk(size_max: ?u32, seg_max: ?u32) u32 {
        const per = size_max orelse return most_sectors_ours;
        if (per == 0) return most_sectors_ours;
        const segments = @min(@max(seg_max orelse 1, 1), most_segments);
        return mostSectors(@as(u64, per) * segments);
    }

    /// The most sectors a request asks for, given what a device said of the
    /// most bytes one segment carries (null: it did not say): ours, or its
    /// own if less. A device that takes less than a sector answers 0, which
    /// every filesystem refuses at mount.
    pub fn mostSectors(said_bytes: ?u64) u32 {
        const said = said_bytes orelse return most_sectors_ours;
        return @intCast(@min(most_sectors_ours, said / 512));
    }

    /// One request, start to finish, polled to completion. The chain is the
    /// spec's three descriptors: the header the device reads, the data buffer,
    /// and the status byte the device writes.
    ///
    /// **`addr` IS A PHYSICAL ADDRESS AND THE DEVICE WRITES IT DIRECTLY.**
    /// That is the whole reason the door takes an address: the 512 bytes never
    /// pass through this function.
    /// One request, its status noted (193.3). On SCSI the command's own
    /// outcome is noted where it ends (`scsi.command`), so a CHECK CONDITION
    /// is not also an I/O error here; only what never reached a command is.
    fn transfer(self: *Block, kind: u32, lba: u64, addr: u64, len: u32) u8 {
        const status = self.transferOnce(kind, lba, addr, len);
        if (self.address == null or status == blk_s_ended or status == blk_s_unsupp) self.failures.noteStatus(status);
        return status;
    }

    fn transferOnce(self: *Block, kind: u32, lba: u64, addr: u64, len: u32) u8 {
        if (self.memory) |disk| return self.memoryTransfer(disk, kind, lba, addr, len);
        if (self.refuseEnded()) return blk_s_ended;
        if (self.address) |at| {
            // Set before the command: a write that fails may still have
            // landed in part, in the cache.
            if (kind != blk_t_in) self.unflushed = true;
            return scsi.transfer(self, at, kind == blk_t_in, lba, addr, len);
        }
        self.header.* = .{ .type = kind, .reserved = 0, .sector = lba };
        self.status.* = 0xFF; // so a device that writes nothing is not read as OK

        const d = &self.q.ring.desc;
        d[0] = .{ .addr = @intFromPtr(self.header), .len = @sizeOf(BlkReqHeader), .flags = virtio.desc_flag_next, .next = 1 };
        // The data, in segments of at most `segment_bytes` (180.2): the
        // request's most (`most_sectors`) keeps them within `most_segments`.
        const per = self.segment_bytes orelse len;
        // **NEVER A CHAIN PAST THE RING** (187.2): a device whose size_max
        // splits even one sector into more segments than the chain holds is
        // refused the request (a 512-byte read before the mount could
        // refuse the disk built d[8]).
        if (segmentsFor(len, self.segment_bytes) > most_segments) return blk_s_unsupp;
        var at: u32 = 0;
        var k: u16 = 1;
        while (at < len) : (k += 1) {
            const n = @min(per, len - at);
            d[k] = .{
                .addr = addr + at,
                .len = n,
                .flags = virtio.desc_flag_next | (if (kind == blk_t_in) virtio.desc_flag_write else 0),
                .next = k + 1,
            };
            at += n;
        }
        d[k] = .{ .addr = @intFromPtr(self.status), .len = 1, .flags = virtio.desc_flag_write, .next = 0 };

        const began = tsc.read();
        self.q.offer(0);
        self.q.notify();
        const ended = self.q.waitFor(virtio.wait_budget_ticks);
        virtio.ack(self.device);
        self.busy_ticks +%= tsc.read() -% began;
        self.requests +%= 1;
        if (!self.answered(ended)) return blk_s_ended;
        return self.status.*;
    }

    /// Whether a disk that stopped answering refuses this request, counted.
    pub fn refuseEnded(self: *Block) bool {
        if (self.ended == .serving) return false;
        self.refused_after_end +%= 1;
        return true;
    }

    /// Whether a wait ended in a completion; if not, the disk is ended.
    pub fn answered(self: *Block, how: Q.Ended) bool {
        switch (how) {
            .done => return true,
            .timed_out => self.ended = .timed_out,
            .needs_reset => self.ended = .needs_reset,
        }
        props.reachable(@src(), "virtio: a disk stops answering, and is ended", null);
        return false;
    }

    /// The sector at `lba` into the 512 bytes at `addr`.
    pub fn read(self: *Block, lba: u64, addr: u64) u8 {
        return self.readTried(lba, addr, 512);
    }

    /// A read, tried up to `read_tries` times while the disk answers with an
    /// error.
    fn readTried(self: *Block, lba: u64, addr: u64, len: u32) u8 {
        var status = self.transfer(blk_t_in, lba, addr, len);
        var tries: u8 = 1;
        while (status == blk_s_ioerr and tries < self.read_tries) : (tries += 1) {
            status = self.transfer(blk_t_in, lba, addr, len);
            if (status == blk_s_ok) self.reads_retried += 1;
        }
        return status;
    }

    /// **THE MOST ONE REQUEST ASKS FOR, OURS: 1 MiB** (metal-vmm QUEUE 178).
    /// It was 64 KiB, which made a 100 MB upload's write 2,017 requests in
    /// its turn (~4-8 s on prod's network volume at ~2 ms a request). A run
    /// of contiguous clusters goes as one request up to this, in one data
    /// segment (so a device's `seg_max`, at least 1, is always met); a device
    /// that says less is obeyed (`most_sectors`).
    pub const most_sectors_ours: u32 = 2048;

    /// `count` sectors from `lba` into the `count` × 512 bytes at `addr`, as ONE
    /// request. **This is what makes reading a file cost a request per run of
    /// clusters rather than a request per 512 bytes** — the soak read a 200 KB
    /// transcript on every chat send, and at a sector per request that was four
    /// hundred round trips through the emulator.
    pub fn readMany(self: *Block, lba: u64, addr: u64, count: u32) u8 {
        if (count == 0 or count > self.most_sectors) return blk_s_unsupp;
        return self.readTried(lba, addr, count * 512);
    }

    /// The 512 bytes at `addr` become the sector at `lba`.
    pub fn write(self: *Block, lba: u64, addr: u64) u8 {
        return self.transfer(blk_t_out, lba, addr, 512);
    }

    /// The `count` × 512 bytes at `addr` become `count` sectors from `lba`, as
    /// ONE request — what makes a 10 MB upload about 160 requests instead of
    /// twenty thousand.
    pub fn writeMany(self: *Block, lba: u64, addr: u64, count: u32) u8 {
        if (count == 0 or count > self.most_sectors) return blk_s_unsupp;
        return self.transfer(blk_t_out, lba, addr, count * 512);
    }

    /// **EVERY WRITE ANSWERED SO FAR, MADE DURABLE.** A SCSI disk is sent
    /// SYNCHRONIZE CACHE, unless it said it has no write cache. A virtio-blk
    /// disk writes through (see `write_cache`), so there is nothing to send;
    /// nor on a disk in memory, which counts the flush for host tests.
    /// Answers a virtio-blk status byte. `unflushed` is cleared only on
    /// success, so a failed flush is tried again before the next response.
    ///
    /// **WHAT TO DO IS `durable.step`'S** (a pure decision, driven by
    /// `durable_sim.zig`); only the SYNCHRONIZE CACHE it asks for is here.
    pub fn flush(self: *Block) u8 {
        var d = durable.Disk{ .unflushed = self.unflushed, .write_cache = self.write_cache, .asks = self.address != null };
        const s = durable.step(d);
        if (s == .none) return blk_s_ok;
        // A host test's cache: a disk whose power is cut keeps nothing more.
        if (self.cache) |c| {
            if (self.fail_after) |n| if (self.requests >= n) return blk_s_ioerr;
            if (self.fail_after_writes) |n| if (self.writes >= n) return blk_s_ioerr;
            c.flushed(c.context);
        }
        self.flushes +%= 1;
        // `synchronize` may learn the disk has no cache (ILLEGAL REQUEST),
        // and says so in `write_cache` and an ok.
        if (s == .synchronize) self.synchronizes_sent +%= 1;
        const status = if (s == .synchronize) scsi.synchronize(self, self.address.?) else blk_s_ok;
        if (durable.settle(&d, s, status == blk_s_ok)) {
            self.flush_failures +%= 1;
            // Reached under metal-vmm with VOLUME_SYNC_FAIL=1: on the host
            // every disk is in memory and writes through.
            props.reachable(@src(), "virtio: a flush fails, is counted, and the disk stays unflushed", .{ .failures = self.flush_failures });
        }
        self.unflushed = d.unflushed;
        return status;
    }
};

/// The memory a Block needs, which a caller places somewhere identity-mapped.
pub const BlockMemory = struct {
    ring: Block.Q.RingType align(16) = undefined,
    header: BlkReqHeader align(16) = undefined,
    status: u8 = 0,
    /// Used only when the Block is a disk on a SCSI controller.
    scsi: scsi.Memory = .{},

    pub fn bring(self: *BlockMemory, device: virtio.Device) virtio.Error!Block {
        return Block.init(device, self);
    }
};
