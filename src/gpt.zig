//! Finding a partition on a GPT disk.
//!
//! **SECTOR 0 IS NOT THE FILESYSTEM.** On a GPT disk, LBA 0 is a protective
//! MBR whose only job is to stop old tools thinking the disk is empty; the
//! real table is at LBA 1 and the volume starts wherever it says. Cobblestone's
//! fixtures are laid out this way — one "EFI System" partition at LBA 2048 —
//! which is why its `Fat16` cites a `Gpt` chapter, and why a FAT16 reader that
//! mounts sector 0 gets a boot sector of zeros and concludes, correctly and
//! uselessly, that the volume is not FAT16.
//!
//! Only what is needed to answer "where does the data partition start?": the
//! first partition that is not zig-metal-unikernel's own kernel partition (a droplet's
//! disk has both; Cobblestone's fixtures and the judge's volumes have only the
//! data). That one type GUID is the only one interpreted; no CRCs are
//! checked, and nothing is written.

const std = @import("std");
const props = @import("coverage");
const virtio_blk = @import("virtio_blk.zig");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const kernel_partition = @import("kernel_partition.zig");

pub const sector_size: u32 = 512;
/// `TooLarge`: a partition that reaches past sector 2^32, which this
/// machine's 32-bit sector numbers cannot address (metal-vmm QUEUE 182.2,
/// as `disk_fat.Volume.mount` refuses a volume past it).
pub const Error = error{ ReadFailed, NotGpt, NoPartition, TooLarge };

const header_lba: u32 = 1;
const signature = "EFI PART";

pub const Partition = struct {
    first_lba: u32,
    last_lba: u32,

    pub fn sectors(self: Partition) u32 {
        return self.last_lba - self.first_lba + 1;
    }
};

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn eql16(a: *const [16]u8, b: *const [16]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// A 64-bit little-endian field, whole: an address past 32 bits is refused
/// where it is read (metal-vmm QUEUE 182), never cast and never truncated.
fn le64(b: []const u8) u64 {
    return @as(u64, le32(b[0..4])) | (@as(u64, le32(b[4..8])) << 32);
}

/// The first partition in the table that is not the kernel's, or an error.
/// `scratch` is one sector of identity-mapped memory the device writes into.
pub fn dataPartition(blk: *virtio_blk.Block, scratch: *[sector_size]u8) Error!Partition {
    if (blk.read(header_lba, @intFromPtr(scratch)) != virtio_blk.blk_s_ok) {
        props.reachable(@src(), "gpt: the header cannot be read", null);
        return Error.ReadFailed;
    }
    for (signature, 0..) |c, i| {
        if (scratch[i] != c) {
            props.reachable(@src(), "gpt: no EFI PART signature, so not GPT", null);
            return Error.NotGpt;
        }
    }

    const entries_lba = le64(scratch[72..80]);
    const entry_count = le32(scratch[80..84]);
    const entry_size = le32(scratch[84..88]);
    if (entry_count == 0 or entry_size < 128 or entry_size > sector_size) {
        props.reachable(@src(), "gpt: a table with no entries, or entries of a size this reader refuses", .{ .count = entry_count, .size = entry_size });
        return Error.NotGpt;
    }

    const per_sector = sector_size / entry_size;
    // **THE ENTRIES' LAST SECTOR, ADDRESSABLE** (metal-vmm QUEUE 182.1): a
    // header naming entries past sector 2^32 is no table this machine reads.
    // The start alone first, so the sum fits u64 (187.2: one near 2^64 overflowed the guard).
    if (entries_lba > std.math.maxInt(u32) or entries_lba + (entry_count - 1) / per_sector > std.math.maxInt(u32)) {
        props.reachable(@src(), "gpt: a table whose entries are past sector 2^32 is not one this machine reads", null);
        return Error.NotGpt;
    }
    var index: u32 = 0;
    while (index < entry_count) : (index += 1) {
        const lba: u32 = @intCast(entries_lba + index / per_sector);
        if (index % per_sector == 0) {
            if (blk.read(lba, @intFromPtr(scratch)) != virtio_blk.blk_s_ok) {
                props.reachable(@src(), "gpt: a sector of entries cannot be read", .{ .lba = lba });
                return Error.ReadFailed;
            }
        }
        const e = scratch[(index % per_sector) * entry_size ..][0..128];

        // An all-zero type GUID is an unused slot, and the table is mostly
        // unused slots.
        var used = false;
        for (e[0..16]) |b| {
            if (b != 0) used = true;
        }
        if (!used) continue;
        if (eql16(e[0..16], &kernel_partition.type_guid)) {
            props.reachable(@src(), "gpt: the kernel's own partition is passed over", null);
            continue;
        }

        const first = le64(e[32..40]);
        const last = le64(e[40..48]);
        if (first == 0 or last < first) {
            props.reachable(@src(), "gpt: a partition with no first sector, or ending before it starts, is passed over", null);
            continue;
        }
        if (last > std.math.maxInt(u32)) {
            props.reachable(@src(), "gpt: a partition reaching past sector 2^32 is refused", null);
            return Error.TooLarge;
        }
        props.alwaysLessThanOrEqualTo(@src(), first, last, "gpt: a partition answered starts no later than it ends", null);
        return .{ .first_lba = @intCast(first), .last_lba = @intCast(last) };
    }
    props.reachable(@src(), "gpt: no partition but the kernel's, so no data partition", .{ .entries = entry_count });
    return Error.NoPartition;
}

// ---- addresses past 32 bits, refused rather than a panic (metal-vmm QUEUE 182) ----

/// A disk of eight sectors: a GPT header at 1 naming `entries_lba`, and one
/// partition entry at sector 2 from `first` to `last`.
fn testDisk(bytes: *[8 * sector_size]u8, entries_lba: u64, first: u64, last: u64) virtio_blk.Block {
    @memset(bytes, 0);
    const h = bytes[sector_size..][0..sector_size];
    @memcpy(h[0..8], signature);
    std.mem.writeInt(u64, h[72..80], entries_lba, .little);
    std.mem.writeInt(u32, h[80..84], 4, .little);
    std.mem.writeInt(u32, h[84..88], 128, .little);
    const e = bytes[2 * sector_size ..][0..128];
    e[0] = 0xAF; // any type but the kernel's
    std.mem.writeInt(u64, e[32..40], first, .little);
    std.mem.writeInt(u64, e[40..48], last, .little);
    return virtio_blk.Block.inMemory(bytes);
}

test "a GPT whose entries are past sector 2^32 is not one this machine reads (metal-vmm QUEUE 182.1)" {
    var bytes: [8 * sector_size]u8 align(16) = undefined;
    var scratch: [sector_size]u8 align(16) = undefined;
    // The last address that fits reads on (to sector 2 here, the edge's
    // other side checked by its value); one past it is NotGpt, never a panic.
    var blk = testDisk(&bytes, 2, 3, 7);
    try std.testing.expectEqual(Partition{ .first_lba = 3, .last_lba = 7 }, try dataPartition(&blk, &scratch));
    blk = testDisk(&bytes, 1 << 32, 3, 7);
    try std.testing.expectError(Error.NotGpt, dataPartition(&blk, &scratch));
    blk = testDisk(&bytes, (1 << 32) - 1 + 0, 3, 7);
    try std.testing.expectError(Error.ReadFailed, dataPartition(&blk, &scratch)); // fits, and is past this disk
}

test "a partition reaching past sector 2^32 is refused, as a FAT volume past it is: a whole volume over 2 TiB (metal-vmm QUEUE 182.2)" {
    var bytes: [8 * sector_size]u8 align(16) = undefined;
    var scratch: [sector_size]u8 align(16) = undefined;
    const most: u64 = std.math.maxInt(u32);
    var blk = testDisk(&bytes, 2, 3, most);
    try std.testing.expectEqual(Partition{ .first_lba = 3, .last_lba = @intCast(most) }, try dataPartition(&blk, &scratch));
    blk = testDisk(&bytes, 2, 3, most + 1);
    try std.testing.expectError(Error.TooLarge, dataPartition(&blk, &scratch));
    blk = testDisk(&bytes, 2, most + 1, most + 2);
    try std.testing.expectError(Error.TooLarge, dataPartition(&blk, &scratch));
}

test "a GPT whose entries are near sector 2^64 is NotGpt, its guard never an overflow (metal-vmm QUEUE 187.2)" {
    var bytes: [8 * sector_size]u8 align(16) = undefined;
    var scratch: [sector_size]u8 align(16) = undefined;
    var blk = testDisk(&bytes, std.math.maxInt(u64), 3, 7);
    // Five entries, past one sector: the guard's own sum passed u64.
    std.mem.writeInt(u32, bytes[sector_size + 80 ..][0..4], 5, .little);
    try std.testing.expectError(Error.NotGpt, dataPartition(&blk, &scratch));
}
