//! A kernel that brings up a virtio-blk device and moves sectors on it.
//!
//! Reading proves bytes moved. Writing the last sector and comparing all 512
//! bytes back proves they moved WHERE WE SAID, which is the half a read alone
//! cannot tell you.

const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;

comptime {
    _ = metal.boot;
}

/// The rings and the request, and the sectors. All in the kernel's image,
/// which the linker places at a fixed physical address that paging maps to
/// itself -- so `&sector` is both a pointer this code can use and an address
/// the device can write.
var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var sector: [512]u8 align(4096) = undefined;
var scratch: [512]u8 align(4096) = undefined;

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel block probe\n");

    var slot: usize = 0;
    while (slot < virtio.mmio_slots) : (slot += 1) {
        const at = virtio.mmio_base + slot * virtio.mmio_stride;
        if (virtio.magicAt(at) != 0x74726976 or virtio.deviceIdAt(at) == 0) continue;
        serial.put("  slot ");
        serial.putDec(slot);
        serial.put(" @0x");
        serial.putHex(at, 8);
        serial.put(": magic ");
        serial.putHex(virtio.magicAt(at), 8);
        serial.put(" version ");
        serial.putDec(virtio.versionAt(at));
        serial.put(" id ");
        serial.putDec(virtio.deviceIdAt(at));
        serial.put("\n");
    }

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot (is -device virtio-blk-device there?)");
    serial.put("  device at 0x");
    serial.putHex(base.address(), 8);
    serial.put(" (");
    serial.put(base.describe());
    serial.put(")\n");

    var blk = blk_mem.bring(base) catch |e| switch (e) {
        error.DeviceRefused => serial.fail("the device refused the driver"),
        error.QueueTooSmall => serial.fail("the device's queue is smaller than this driver's"),
        else => serial.fail("the device would not come up"),
    };
    serial.put("  capacity: ");
    serial.putDec(blk.capacity);
    serial.put(" sectors\n");

    // Sector 0 of a FAT16 volume is its boot sector: 0x55 0xAA at the end, and
    // the OEM name at offset 3. Reading it proves the transfer moved the right
    // bytes and not merely some.
    const st = blk.read(0, @intFromPtr(&sector));
    if (st != virtio_blk.blk_s_ok) {
        serial.put("  read status ");
        serial.putDec(st);
        serial.put("\n");
        serial.fail("sector 0 did not read");
    }
    serial.put("  sector 0 oem: ");
    serial.put(sector[3..11]);
    serial.put("\n  sector 0 signature: ");
    serial.putHex(sector[510], 2);
    serial.putHex(sector[511], 2);
    serial.put("\n");
    if (sector[510] != 0x55 or sector[511] != 0xAA) serial.fail("sector 0 has no boot signature");

    // A write, then a read back, on a sector past the FAT16 volume's own data
    // so nothing anyone cares about moves. This is the half that proves the
    // device is writing where we said rather than anywhere.
    const probe_lba: u64 = blk.capacity - 1;
    for (&scratch, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    const wst = blk.write(probe_lba, @intFromPtr(&scratch));
    if (wst != virtio_blk.blk_s_ok) serial.fail("the write was refused");
    @memset(&sector, 0);
    const rst = blk.read(probe_lba, @intFromPtr(&sector));
    if (rst != virtio_blk.blk_s_ok) serial.fail("the read back was refused");
    for (sector, 0..) |b, i| {
        if (b != @as(u8, @truncate(i *% 7 +% 3))) {
            serial.put("  mismatch at byte ");
            serial.putDec(i);
            serial.put("\n");
            serial.fail("what came back is not what went out");
        }
    }
    serial.put("  wrote and read back sector ");
    serial.putDec(probe_lba);
    serial.put(": 512 bytes match\n");

    serial.pass();
}

pub const panic = metal.serial.panic;
