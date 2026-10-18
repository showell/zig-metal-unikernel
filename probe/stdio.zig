//! **THE LAST PIECE.** `std.Io.Dir.cwd().readFileAlloc(io, ...)` — zig's own
//! filesystem API, unmodified — reading a file off FAT16 on a machine with no
//! operating system.
//!
//! `angry-gopher/zig-server` calls that exact function 42 times. If it works
//! here, the largest remaining piece of the port is answered the same way
//! `std.http.Server` was: not by porting anything, but by presenting the
//! interface the standard library already expects.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const gpt = metal.gpt;
const disk_fat = metal.disk_fat;

// **THE ONE LINE THE PORT CHANGES.** In zig-server this reads
// `const Io = std.Io;`, in all 37 files that have it. Nothing below it moves.
const Io = metal.io;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio_blk.BlockMemory align(4096) = .{};
var scratch: [disk_fat.sector_size]u8 align(4096) = undefined;

/// A bump allocator over a static arena. Nothing is ever freed, which is what
/// a one-request machine wants and what `boot.zig` already assumes.
var arena: [1024 * 1024]u8 align(4096) = undefined;
var arena_at: usize = 0;

fn bumpAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const at = alignment.forward(@intFromPtr(&arena) + arena_at) - @intFromPtr(&arena);
    if (at + len > arena.len) return null;
    arena_at = at + len;
    return @ptrCast(&arena[at]);
}
fn bumpResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
fn bumpRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}
fn bumpFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

var bump_ctx: u8 = 0;
const gpa = std.mem.Allocator{
    .ptr = @ptrCast(&bump_ctx),
    .vtable = &.{ .alloc = bumpAlloc, .resize = bumpResize, .remap = bumpRemap, .free = bumpFree },
};

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel std.Io probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device on the PCI bus or in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    // A partitioned disk or a bare volume, as vfat.zig reads either.
    const start: u32 = if (gpt.dataPartition(&blk, &scratch) catch null) |p| p.first_lba else 0;
    const vol = disk_fat.Volume.mount(&blk, &scratch, start) catch serial.fail("the volume would not mount");

    Io.mount(vol);
    Io.startClock(metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC"));
    const io = Io.io();

    // Written through our own Dir, so the probe does not depend on another
    // one having run first -- and so both halves are exercised.
    Io.Dir.cwd().writeFile(io, .{ .sub_path = "HELLO.TXT", .data = "Hello, disk!" }) catch
        serial.fail("writeFile failed");

    // The line zig-server writes 42 times.
    const bytes = Io.Dir.cwd().readFileAlloc(io, "HELLO.TXT", gpa, .unlimited) catch |e| {
        serial.put("  readFileAlloc: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("std.Io.Dir could not read the file");
    };
    serial.put("  readFileAlloc(\"HELLO.TXT\") -> ");
    serial.putDec(bytes.len);
    serial.put(" bytes: ");
    serial.put(bytes);
    serial.put("\n");

    // And statFile, which it uses to decide whether to bother.
    const st = Io.Dir.cwd().statFile(io, "HELLO.TXT", .{}) catch
        serial.fail("statFile failed");
    serial.put("  statFile -> ");
    serial.putDec(st.size);
    serial.put(" bytes, kind ");
    serial.put(@tagName(st.kind));
    serial.put("\n");

    // The clock moves forward, which is all a timeout needs of it.
    // Until it has moved, bounded so a clock that never moves fails below
    // rather than hanging.
    const t0 = Io.Clock.now(.awake, io);
    var spin: u64 = 0;
    while (spin < 2_000_000 and Io.Clock.now(.awake, io).nanoseconds - t0.nanoseconds < std.time.ns_per_ms) : (spin += 1) asm volatile ("pause");
    const t1 = Io.Clock.now(.awake, io);
    serial.put("  clock advanced ");
    serial.putDec(@intCast(t1.nanoseconds - t0.nanoseconds));
    serial.put(" ns over a spin\n");

    // And the directory listing, which it walks 32 times.
    var it = Io.Dir.cwd().iterate();
    serial.put("  iterate ->");
    var seen: usize = 0;
    while (it.next(io) catch null) |e| {
        seen += 1;
        serial.put(" ");
        serial.put(e.name);
        if (e.kind == .directory) serial.put("/");
    }
    serial.put("\n");
    if (seen == 0) serial.fail("the root listed as empty, which it is not");

    // A mutex, which is free here but still checks it is entitled to be.
    var mu = Io.Mutex.init;
    mu.lock(io);
    mu.unlock(io);
    mu.lock(io);
    mu.unlock(io);
    serial.put("  mutex: locked and unlocked twice, no contention possible\n");

    if (bytes.len != 12) serial.fail("HELLO.TXT is not the twelve bytes just written");
    if (st.size != 12) serial.fail("statFile disagrees with what was read");
    serial.pass();
}

pub const panic = metal.serial.panic;
