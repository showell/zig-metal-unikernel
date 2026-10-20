//! **A DISK A DROPLET CAN BOOT.** Takes the boot loader (`loader.S`,
//! assembled) and a zig-metal-unikernel kernel (a PVH ELF), and writes a raw disk
//! image DigitalOcean can import as a custom image:
//!
//!   LBA 0          protective MBR: the loader's first stage, the kernel
//!                  partition's LBA at byte 432, and one 0xEE entry
//!   LBA 1          the GPT header        LBA 2-33   its 128 entries
//!   LBA 34-2047    the loader's second stage, in the gap no partition may use
//!                  (the header says the first usable LBA is 2048)
//!   LBA 2048-      the kernel partition, GPT entry 1, of the type in
//!                  src/kernel_partition.zig. **Entry 1, not 2**: with entry 1
//!                  empty, DigitalOcean's import took the disk for a bare
//!                  filesystem and wrapped it in a new disk whose boot code
//!                  was zeros. gpt.zig mounts the first partition that is not
//!                  this type, so the site's files can go in entry 2.
//!   then           the site's files, GPT entry 2, when one is given: a FAT16
//!                  filesystem image copied in whole, typed "basic data"
//!                  (what sgdisk calls 0700, as the judge's disks are)
//!   the end        the backup entries and header
//!
//! The kernel partition is what the loader reads, so it is laid out for a
//! loader with no ELF parser: a one-sector header ("GMKERNEL", the PVH entry,
//! the segment count, then each segment's physical address, first sector,
//! file size and memory size, all u32), then each loadable segment's bytes
//! from a sector boundary. Taking the ELF apart here, in zig, is what keeps
//! the 16-bit side to a copy loop.
//!
//! Every byte is a function of the two inputs, so the same loader and kernel
//! always make the same image.
//!
//!   gm-image <loader.bin> <kernel.elf> <out.img> [volume.fat]

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const kernel_partition = @import("kernel_partition");

const sector: usize = 512;
const entry_count: usize = 128;
const entry_size: usize = 128;
const entries_sectors: usize = entry_count * entry_size / sector; // 32
const stage2_lba: usize = 34;
const first_usable: usize = 2048;
const kernel_first_lba: usize = 2048;
/// Where in sector 0 the loader reads the kernel partition's LBA. loader.S
/// puts `kernel_lba` there with `.org 432`.
const kernel_lba_field: usize = 432;
/// The MBR's own bytes start at 440: a disk signature, then the table.
const loader_stage1_bytes: usize = 440;

/// zig-metal-unikernel's kernel partition, shared with gpt.zig, which skips it.
pub const kernel_type = kernel_partition.type_guid;
/// Fixed rather than random, so an image is a function of its inputs. Two
/// droplets with the same disk GUID never meet: each is its own machine.
const disk_guid = guid("6f9c1e2a-4d7b-4c38-9a51-2e8d0b7f3c64");
const kernel_unique = guid("1b7e4f90-3c2d-4a6e-8f15-7d9a2c4b6e03");
/// Chat's volume: the type every FAT partition on a GPT disk has.
pub const data_type = guid("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
const data_unique = guid("8e2a6c14-5b7d-4f39-a0c2-3d61e9b47f58");

/// A GUID as GPT stores it: the first three fields little-endian, the last
/// two as written.
pub fn guid(comptime text: []const u8) [16]u8 {
    return comptime parseGuid(text);
}

fn parseGuid(comptime text: []const u8) [16]u8 {
    @setEvalBranchQuota(10_000);
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        hex[n] = c;
        n += 1;
    }
    if (n != 32) @compileError("a GUID is 32 hex digits");
    var raw: [16]u8 = undefined;
    for (0..16) |i| raw[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch @compileError("not hex");
    return .{ raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6] } ++ raw[8..16].*;
}

// ── the kernel's ELF ─────────────────────────────────────────────────────────

const ElfHeader = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,

    const load: u32 = 1;
    const note: u32 = 4;
};

const NoteHeader = extern struct {
    namesz: u32,
    descsz: u32,
    type: u32,

    /// Xen's number for "the 32-bit entry point".
    const phys32_entry: u32 = 18;
};

pub const Segment = struct { paddr: u32, bytes: []const u8, memsz: u32 };

pub const Kernel = struct {
    entry: u32,
    segments: [max_segments]Segment = undefined,
    count: usize = 0,

    /// What one header sector holds: 16 bytes of header, 16 per segment.
    pub const max_segments = (sector - 16) / 16;
};

pub const Error = error{ NotAnElf, NotX86_64, NoPvhNote, TooManySegments, PastFourGigabytes, LoaderTooSmall, LoaderTooBig, VolumeNotWholeSectors };

/// The loadable segments and the PVH entry, which is all a loader needs.
/// **A segment goes to `paddr`, not `vaddr`**, as QEMU's PVH loader and
/// metal-vmm place it.
pub fn readKernel(image: []const u8) Error!Kernel {
    if (image.len < @sizeOf(ElfHeader)) return error.NotAnElf;
    const head: *align(1) const ElfHeader = @ptrCast(image.ptr);
    if (!std.mem.eql(u8, head.ident[0..4], "\x7fELF")) return error.NotAnElf;
    if (head.ident[4] != 2 or head.machine != 62) return error.NotX86_64;

    var kernel = Kernel{ .entry = 0 };
    var entry: ?u32 = null;
    for (0..head.phnum) |i| {
        const at = head.phoff + i * head.phentsize;
        if (at + @sizeOf(ProgramHeader) > image.len) return error.NotAnElf;
        const ph: *align(1) const ProgramHeader = @ptrCast(image.ptr + at);
        switch (ph.type) {
            ProgramHeader.load => {
                if (ph.memsz == 0) continue;
                if (ph.paddr + ph.memsz > std.math.maxInt(u32)) return error.PastFourGigabytes;
                if (ph.offset + ph.filesz > image.len or ph.filesz > ph.memsz) return error.NotAnElf;
                if (kernel.count == Kernel.max_segments) return error.TooManySegments;
                kernel.segments[kernel.count] = .{
                    .paddr = @intCast(ph.paddr),
                    .bytes = image[@intCast(ph.offset)..][0..@intCast(ph.filesz)],
                    .memsz = @intCast(ph.memsz),
                };
                kernel.count += 1;
            },
            ProgramHeader.note => if (pvhEntry(image, ph.*)) |found| {
                entry = found;
            },
            else => {},
        }
    }
    kernel.entry = entry orelse return error.NoPvhNote;
    return kernel;
}

fn pvhEntry(image: []const u8, ph: ProgramHeader) ?u32 {
    var at: usize = @intCast(ph.offset);
    const end = at + @as(usize, @intCast(ph.filesz));
    while (at + @sizeOf(NoteHeader) <= end and end <= image.len) {
        const note: *align(1) const NoteHeader = @ptrCast(image.ptr + at);
        const name_at = at + @sizeOf(NoteHeader);
        const desc_at = name_at + std.mem.alignForward(usize, note.namesz, 4);
        const next = desc_at + std.mem.alignForward(usize, note.descsz, 4);
        if (next > end) return null;
        const name = image[name_at..][0..note.namesz];
        if (note.type == NoteHeader.phys32_entry and std.mem.startsWith(u8, name, "Xen") and note.descsz == 4) {
            return std.mem.readInt(u32, image[desc_at..][0..4], .little);
        }
        at = next;
    }
    return null;
}

// ── the disk ─────────────────────────────────────────────────────────────────

fn sectorsFor(bytes: usize) usize {
    return (bytes + sector - 1) / sector;
}

fn mib(sectors: usize) usize {
    return std.mem.alignForward(usize, sectors, 2048);
}

fn kernelSectors(kernel: *const Kernel) usize {
    var used: usize = 1; // the header
    for (kernel.segments[0..kernel.count]) |s| used += sectorsFor(s.bytes.len);
    return used;
}

/// Where the site's files start: the megabyte after the kernel partition.
fn dataFirstLba(kernel: *const Kernel) usize {
    return kernel_first_lba + mib(kernelSectors(kernel));
}

/// How big the image is, in sectors, for this kernel and volume.
pub fn diskSectors(kernel: *const Kernel, volume_bytes: usize) usize {
    // Each partition rounded to a megabyte, then a megabyte for the backup
    // table at the end.
    return dataFirstLba(kernel) + mib(sectorsFor(volume_bytes)) + 2048;
}

/// Writes the whole disk into `disk`, which is `diskSectors(kernel, volume.len)`
/// sectors of zeroes. An empty `volume` is no data partition at all.
pub fn build(disk: []u8, loader: []const u8, kernel: *const Kernel, volume: []const u8) Error!void {
    if (loader.len <= sector) return error.LoaderTooSmall;
    if (volume.len % sector != 0) return error.VolumeNotWholeSectors;
    if (stage2_lba + sectorsFor(loader.len - sector) > first_usable) return error.LoaderTooBig;
    const total = disk.len / sector;
    const last = total - 1;

    // The kernel partition: its header, then the segments.
    const part = disk[kernel_first_lba * sector ..];
    @memcpy(part[0..8], "GMKERNEL");
    put32(part[8..], kernel.entry);
    put32(part[12..], @intCast(kernel.count));
    var next: usize = 1;
    for (kernel.segments[0..kernel.count], 0..) |s, i| {
        const row = part[16 + i * 16 ..];
        put32(row[0..], s.paddr);
        put32(row[4..], @intCast(next));
        put32(row[8..], @intCast(s.bytes.len));
        put32(row[12..], s.memsz);
        @memcpy(part[next * sector ..][0..s.bytes.len], s.bytes);
        next += sectorsFor(s.bytes.len);
    }
    const kernel_last = kernel_first_lba + mib(next) - 1;

    // Sector 0: the loader's first stage, where to find the kernel, and a
    // protective MBR around them.
    @memcpy(disk[0..loader_stage1_bytes], loader[0..loader_stage1_bytes]);
    put32(disk[kernel_lba_field..], @intCast(kernel_first_lba));
    const mbr = disk[446..];
    mbr[0] = 0x00; // not active
    mbr[1] = 0x00;
    mbr[2] = 0x02;
    mbr[3] = 0x00; // CHS 0/0/2
    mbr[4] = 0xEE; // "this disk is GPT"
    mbr[5] = 0xFF;
    mbr[6] = 0xFF;
    mbr[7] = 0xFF;
    put32(mbr[8..], 1);
    put32(mbr[12..], @intCast(@min(total - 1, std.math.maxInt(u32))));
    disk[510] = 0x55;
    disk[511] = 0xAA;

    // The second stage, in the gap.
    @memcpy(disk[stage2_lba * sector ..][0 .. loader.len - sector], loader[sector..]);

    // The table: entry 1 is the kernel.
    var entries: [entry_count * entry_size]u8 = @splat(0);
    const e = entries[0..entry_size];
    @memcpy(e[0..16], &kernel_type);
    @memcpy(e[16..32], &kernel_unique);
    put64(e[32..], kernel_first_lba);
    put64(e[40..], kernel_last);
    put64(e[48..], 1); // "required by the platform": leave it alone
    for ("zig-metal-unikernel kernel", 0..) |c, i| e[56 + i * 2] = c;
    if (volume.len > 0) {
        const first = dataFirstLba(kernel);
        @memcpy(disk[first * sector ..][0..volume.len], volume);
        const d = entries[entry_size..][0..entry_size];
        @memcpy(d[0..16], &data_type);
        @memcpy(d[16..32], &data_unique);
        put64(d[32..], first);
        put64(d[40..], first + volume.len / sector - 1);
        for ("zig-metal-unikernel data", 0..) |c, i| d[56 + i * 2] = c;
    }
    const entries_crc = std.hash.Crc32.hash(&entries);

    @memcpy(disk[2 * sector ..][0..entries.len], &entries);
    @memcpy(disk[(last - entries_sectors) * sector ..][0..entries.len], &entries);
    header(disk[1 * sector ..][0..sector], 1, last, 2, total, entries_crc);
    header(disk[last * sector ..][0..sector], last, 1, last - entries_sectors, total, entries_crc);
}

fn header(out: *[sector]u8, mine: usize, other: usize, entries_lba: usize, total: usize, entries_crc: u32) void {
    @memcpy(out[0..8], "EFI PART");
    put32(out[8..], 0x00010000);
    put32(out[12..], 92);
    put64(out[24..], mine);
    put64(out[32..], other);
    put64(out[40..], first_usable);
    put64(out[48..], total - entries_sectors - 2);
    @memcpy(out[56..72], &disk_guid);
    put64(out[72..], entries_lba);
    put32(out[80..], entry_count);
    put32(out[84..], entry_size);
    put32(out[88..], entries_crc);
    put32(out[16..], std.hash.Crc32.hash(out[0..92]));
}

fn put32(out: []u8, v: u32) void {
    std.mem.writeInt(u32, out[0..4], v, .little);
}

fn put64(out: []u8, v: usize) void {
    std.mem.writeInt(u64, out[0..8], v, .little);
}

// ── the program ──────────────────────────────────────────────────────────────

fn mapFile(path: [*:0]const u8) ![]align(std.heap.page_size_min) const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.CannotOpen;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0) return error.CannotSize;
    return posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
}

fn writeFile(path: [*:0]const u8, bytes: []const u8) !void {
    const opened = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.CannotCreate;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = linux.write(fd, bytes[at..].ptr, bytes.len - at);
        if (linux.errno(rc) != .SUCCESS) return error.CannotWrite;
        at += rc;
    }
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    if (argv.len != 4 and argv.len != 5) {
        std.debug.print("usage: gm-image <loader.bin> <kernel.elf> <out.img> [volume.fat]\n", .{});
        return 2;
    }
    const loader = mapFile(argv[1]) catch |e| return fail("cannot read the loader", e);
    const elf = mapFile(argv[2]) catch |e| return fail("cannot read the kernel", e);
    const kernel = readKernel(elf) catch |e| return fail("not a kernel this loader can start", e);
    const volume: []const u8 = if (argv.len == 5) (mapFile(argv[4]) catch |e| return fail("cannot read the volume", e)) else "";
    const disk = try std.heap.page_allocator.alloc(u8, diskSectors(&kernel, volume.len) * sector);
    @memset(disk, 0);
    build(disk, loader, &kernel, volume) catch |e| return fail("cannot lay the disk out", e);
    writeFile(argv[3], disk) catch |e| return fail("cannot write the image", e);
    std.debug.print("gm-image: {d} segment(s), entry 0x{x}, {d} MB\n", .{ kernel.count, kernel.entry, disk.len >> 20 });
    return 0;
}

fn fail(what: []const u8, e: anyerror) u8 {
    std.debug.print("gm-image: {s}: {s}\n", .{ what, @errorName(e) });
    return 1;
}

// ── what can be checked without a disk ───────────────────────────────────────

const testing = std.testing;

test "the kernel partition's type is the GUID it says it is" {
    try testing.expectEqualSlices(u8, &guid("503d64ca-6a8a-48a9-b509-a23323b6de20"), &kernel_type);
}

test "a GUID is stored the way GPT stores it" {
    // The EFI System partition's type, as every GPT disk writes it.
    const esp = guid("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
    try testing.expectEqualSlices(u8, &.{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B }, &esp);
}

test "the kernel header says where every segment went" {
    var loader: [sector + 3]u8 = @splat(0x90);
    var kernel = Kernel{ .entry = 0x100020 };
    kernel.segments[0] = .{ .paddr = 0x100000, .bytes = repeated("abc", 200), .memsz = 4096 };
    kernel.segments[1] = .{ .paddr = 0x200000, .bytes = "z", .memsz = 1 };
    kernel.count = 2;
    const disk = try testing.allocator.alloc(u8, diskSectors(&kernel, 0) * sector);
    defer testing.allocator.free(disk);
    @memset(disk, 0);
    try build(disk, &loader, &kernel, "");

    const part = disk[kernel_first_lba * sector ..];
    try testing.expectEqualStrings("GMKERNEL", part[0..8]);
    try testing.expectEqual(@as(u32, 0x100020), std.mem.readInt(u32, part[8..12], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, part[12..16], .little));
    // 600 bytes is two sectors, so the second segment starts at sector 3.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, part[20..24], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, part[36..40], .little));
    try testing.expectEqualStrings("abc", part[sector..][0..3]);
    try testing.expectEqual(@as(u8, 'z'), part[3 * sector]);
    // Where the loader looks for the partition, and the boot signature.
    try testing.expectEqual(@as(u32, kernel_first_lba), std.mem.readInt(u32, disk[kernel_lba_field..][0..4], .little));
    try testing.expectEqual(@as(u8, 0xAA), disk[511]);
    // The second stage, behind the table.
    try testing.expectEqual(@as(u8, 0x90), disk[stage2_lba * sector]);
    // The kernel is partition entry 1: an empty entry 1 is what made
    // DigitalOcean wrap the disk.
    try testing.expectEqualSlices(u8, &kernel_type, disk[2 * sector ..][0..16]);
}

test "a loader whose second stage would reach the first partition is refused" {
    const loader = try testing.allocator.alloc(u8, sector + (first_usable - stage2_lba + 1) * sector);
    defer testing.allocator.free(loader);
    var kernel = Kernel{ .entry = 0x100020 };
    kernel.segments[0] = .{ .paddr = 0x100000, .bytes = "x", .memsz = 1 };
    kernel.count = 1;
    const disk = try testing.allocator.alloc(u8, diskSectors(&kernel, 0) * sector);
    defer testing.allocator.free(disk);
    try testing.expectError(error.LoaderTooBig, build(disk, loader, &kernel, ""));
}

test "the site's files are entry 2, a megabyte after the kernel, copied whole" {
    var loader: [sector + 3]u8 = @splat(0x90);
    var kernel = Kernel{ .entry = 0x100020 };
    kernel.segments[0] = .{ .paddr = 0x100000, .bytes = "k", .memsz = 1 };
    kernel.count = 1;
    var volume: [3 * sector]u8 = undefined;
    for (&volume, 0..) |*b, i| b.* = @truncate(i);
    const disk = try testing.allocator.alloc(u8, diskSectors(&kernel, volume.len) * sector);
    defer testing.allocator.free(disk);
    @memset(disk, 0);
    try build(disk, &loader, &kernel, &volume);

    const d = disk[2 * sector + entry_size ..][0..entry_size];
    try testing.expectEqualSlices(u8, &data_type, d[0..16]);
    const first = std.mem.readInt(u64, d[32..40], .little);
    const last = std.mem.readInt(u64, d[40..48], .little);
    try testing.expectEqual(@as(u64, kernel_first_lba + 2048), first);
    try testing.expectEqual(first + 2, last);
    try testing.expectEqualSlices(u8, &volume, disk[first * sector ..][0..volume.len]);
}

test "a volume that is not whole sectors is refused" {
    var loader: [sector + 3]u8 = @splat(0x90);
    var kernel = Kernel{ .entry = 0x100020 };
    kernel.segments[0] = .{ .paddr = 0x100000, .bytes = "k", .memsz = 1 };
    kernel.count = 1;
    const disk = try testing.allocator.alloc(u8, diskSectors(&kernel, 1024) * sector);
    defer testing.allocator.free(disk);
    try testing.expectError(error.VolumeNotWholeSectors, build(disk, &loader, &kernel, "odd"));
}

/// `s` repeated `n` times, built at comptime (Zig 0.17 removed `s ** n`).
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        var a: [s.len * n]u8 = undefined;
        @setEvalBranchQuota(1000 + n);
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}
