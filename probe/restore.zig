//! Reading what Linux wrote.
//!
//! The backup story has two halves and only one of them is `cp -r`. This is the
//! other: a volume written by the Linux kernel's own VFAT driver, with long
//! names and a directory it created, read back by this machine. If that works,
//! a backup taken on Linux can be restored here — which is the whole point of
//! the volume being a real filesystem rather than a private format.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const gpt = metal.gpt;
const disk_fat = metal.disk_fat;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var scratch: [disk_fat.sector_size]u8 align(4096) = undefined;
var buf: [4096]u8 align(4096) = undefined;

/// What `probe/run.sh` asked Linux to write, and what it put in it.
const path = "restored/written-by-linux.txt";
const want = "linux wrote this, with a name 8.3 cannot hold\n";

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel restore probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    const start: u32 = if (gpt.dataPartition(&blk, &scratch) catch null) |p| p.first_lba else 0;
    var vol = disk_fat.Volume.mount(&blk, &scratch, start) catch
        serial.fail("the volume would not mount");

    const e = vol.open(path) catch serial.fail("the path Linux wrote would not resolve");
    serial.put("  ");
    serial.put(path);
    serial.put(": ");
    serial.putDec(e.size);
    serial.put(" bytes\n");

    const n = vol.readFile(e, &buf) catch serial.fail("the file would not read");
    serial.put("  contents: ");
    serial.put(buf[0..n]);
    if (n != want.len) serial.fail("the file came back the wrong length");
    for (buf[0..n], want) |x, y| {
        if (x != y) serial.fail("the file came back with different bytes");
    }

    // And our own files are still there and still correct after Linux touched
    // the volume, which is the half a one-way check would miss.
    const ours = vol.open("auth/damian/_session_secret") catch
        serial.fail("our own file did not survive Linux writing to the volume");
    const m = vol.readFile(ours, &buf) catch serial.fail("our own file would not read");
    serial.put("  auth/damian/_session_secret still reads: ");
    serial.put(buf[0..m]);
    serial.put("\n");

    serial.pass();
}

pub const panic = metal.serial.panic;
