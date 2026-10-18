//! Long names and subdirectories, in the shape the application actually uses.
//!
//! `angry-gopher` stores `auth/<id>/api-key` and `_session_secret` and
//! `upload-bytes` and `last-seen` — nested directories, and four names that 8.3
//! refuses. This writes exactly that, reads it back, and lists it.
//!
//! **THE VERDICT IS NOT THIS PROBE'S.** `probe/run.sh` runs `fsck.vfat` over
//! the volume afterwards. dosfstools has been reading VFAT for decades and
//! knows every way a long-name run can be wrong — the checksum, the ordering,
//! the sequence numbers, orphaned entries, `.` and `..`. Agreeing with our own
//! reader would prove very little.

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

/// The names that made this necessary: every one is refused by 8.3, and two
/// are two directories deep.
const files = [_]struct { path: []const u8, body: []const u8 }{
    .{ .path = "auth/damian/api-key", .body = "3-notarealkey" },
    .{ .path = "auth/damian/_session_secret", .body = "sixteen bytes!!!" },
    .{ .path = "users/damian/last-seen", .body = "1758038400" },
    .{ .path = "users/damian/upload-bytes", .body = "4096" },
    .{ .path = "blog-comments", .body = "none yet" },
};

const Names = struct {
    buf: [32][disk_fat.max_name]u8 = undefined,
    lens: [32]u8 = undefined,
    count: usize = 0,
    fn each(self: *Names, e: disk_fat.Entry) void {
        if (self.count >= self.buf.len) return;
        const t = e.text();
        const n = @min(t.len, disk_fat.max_name);
        @memcpy(self.buf[self.count][0..n], t[0..n]);
        self.lens[self.count] = @intCast(n);
        self.count += 1;
    }
};

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel vfat probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");

    // A bare FAT16 volume starts at sector 0; a GPT disk's starts where its
    // table says. Both are in use here, so both are tried.
    const start: u32 = if (gpt.dataPartition(&blk, &scratch) catch null) |p| p.first_lba else 0;
    var vol = disk_fat.Volume.mount(&blk, &scratch, start) catch
        serial.fail("the volume would not mount");
    serial.put("  volume at LBA ");
    serial.putDec(start);
    serial.put(", ");
    serial.putDec(vol.sectors_per_cluster);
    serial.put(" sectors a cluster\n");

    for (files) |f| {
        vol.writeFile(f.path, f.body) catch |e| {
            serial.put("  ");
            serial.put(f.path);
            serial.put(": ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail("a write failed");
        };
    }
    serial.put("  wrote ");
    serial.putDec(files.len);
    serial.put(" files, two directories deep\n");

    // Read every one back through the long name it was written under.
    for (files) |f| {
        const e = vol.open(f.path) catch serial.fail("a path would not resolve");
        const n = vol.readFile(e, &buf) catch serial.fail("a file would not read");
        if (n != f.body.len) serial.fail("a file came back the wrong length");
        for (buf[0..n], f.body) |x, y| {
            if (x != y) serial.fail("a file came back with different bytes");
        }
    }
    serial.put("  read all five back by their long names\n");

    // And the listing shows the long names, not the aliases.
    var names = Names{};
    const dir = vol.open("auth/damian") catch serial.fail("auth/damian would not resolve");
    vol.list(dir.first_cluster, &names, Names.each) catch serial.fail("the listing failed");
    serial.put("  auth/damian:");
    var i: usize = 0;
    var saw_secret = false;
    while (i < names.count) : (i += 1) {
        const t = names.buf[i][0..names.lens[i]];
        serial.put(" ");
        serial.put(t);
        if (eql(t, "_session_secret")) saw_secret = true;
    }
    serial.put("\n");
    if (!saw_secret) serial.fail("the long name did not survive the listing");

    serial.pass();
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const panic = metal.serial.panic;
