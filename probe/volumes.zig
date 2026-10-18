//! **THE DISKS**: the boot disk found, the data volume found on its own bus
//! (virtio or SCSI), each FAT volume mounted (its partition read, its check
//! run within its budget), and the check of every volume at boot and after a
//! stop: what kmain asks before it serves, and what /admin/host says of them.

const metal = @import("metal");
const virtio = metal.virtio;
const virtio_blk = metal.virtio_blk;
const serial = metal.serial;
const scsi = metal.scsi;
const disk_fat = metal.disk_fat;
const gpt = metal.gpt;
const pages = metal.pages;
const Io = metal.io;
const std = @import("std");
const gm_build = @import("gm_build");
const webbox = @import("webbox");
const gopher = @import("gopher.zig");

/// The disk the machine was booted from, which holds the site.
pub fn bootDisk() virtio_blk.Block {
    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no disk: this kernel serves the site from a FAT16 volume");
    return gopher.blk_mem.bring(base) catch serial.fail("the block device would not come up");
}

/// **A DIGITALOCEAN VOLUME**, if one is attached: a disk on the SCSI
/// controller a droplet has whether or not one is, so finding no disk on it is
/// ordinary and said. A controller or a disk that will not work stops the
/// machine instead of quietly keeping the data on the boot disk, where the
/// next image would erase it.
pub fn dataVolume() ?virtio_blk.Block {
    const controller = virtio.find(scsi.device_id) orelse return null;
    if (scsi.bring(controller, &gopher.volume_mem)) |b| {
        const at = b.address.?;
        serial.put("  a volume: SCSI target ");
        serial.putDec(at.target);
        serial.put(", LUN ");
        serial.putDec(at.lun);
        serial.put(", ");
        serial.putDec(b.capacity / 2048);
        serial.put(" MB, requests up to ");
        serial.putDec(b.most_sectors / 2);
        serial.put(" KiB");
        if (b.disk_most_sectors) |most| {
            serial.put(" (the disk says ");
            serial.putDec(most / 2);
            serial.put(" KiB)");
        }
        serial.put("\n");
        if (b.cache_on_at_bringup) switch (metal.scsi_mode.report(b.write_cache, true)) {
            .turned_off => serial.put("  the volume's write cache is turned off: every write is on the disk when answered\n"),
            .would_not_turn_off => serial.put("  the volume's write cache would not turn off: a power cut can leave its filesystem damaged\n"),
            else => serial.put("  the volume's write cache was on, and will not say now: every save is flushed as if it were\n"),
        };
        return b;
    } else |e| switch (e) {
        error.NoDisk => {
            serial.put("  no volume attached\n");
            return null;
        },
        else => {
            serial.put("  the SCSI controller: ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail("the volume controller or its disk would not come up");
        },
    }
}

/// The FAT16 filesystem in `blk`'s first data partition, with its FAT held in
/// memory: without that every lookup is a device read, and the free-cluster
/// search re-reads its way past every cluster in use on each small file the
/// application replaces.
/// The most memory one volume's FAT may take (FAT32.md §9): about 256 GiB of
/// volume at 32 KiB clusters.
const fat_budget_bytes: usize = 32 << 20;

/// **HOW MANY TIMES BOOT TRIES A READ** (B25, Steve 2026-10-08): one refused
/// read of the partition table or the FAT stopped the machine, and a disk
/// that refused once answers the next time. Serving, a read is tried once.
pub const boot_read_tries: u8 = 3;

pub fn mountFat(blk: *virtio_blk.Block, scratch: *[disk_fat.sector_size]u8, what: []const u8) disk_fat.Volume {
    // A table that cannot be read is a disk failing, not a blank one: the
    // two are told apart.
    const part = gpt.dataPartition(blk, scratch) catch |e| {
        serial.put("  ");
        serial.put(what);
        if (e == error.ReadFailed) {
            serial.put(": its partition table cannot be read\n");
            serial.fail("a disk's partition table cannot be read");
        }
        // Said as what it is (metal-vmm QUEUE 187.2): a volume grown and
        // partitioned past 2 TiB is not one with no partition.
        if (e == error.TooLarge) {
            serial.put(": its partition reaches past sector 2^32 (2 TiB), which this machine cannot address\n");
            serial.fail("a disk's partition is past what this machine addresses");
        }
        serial.put(": no GPT partition\n");
        serial.fail("a disk has no partition to serve from");
    };
    var vol = disk_fat.Volume.mount(blk, scratch, part.first_lba) catch |e| {
        serial.put("  ");
        serial.put(what);
        if (e == error.ReadFailed) {
            serial.put(": its first partition cannot be read\n");
            serial.fail("a disk's partition cannot be read");
        }
        serial.put(": its first partition is not a FAT this machine takes (");
        serial.put(@errorName(e));
        serial.put(")\n");
        serial.fail("a disk's partition is not FAT16 or FAT32, or is one this machine refuses");
    };
    // **THE FAT IS HELD WHOLE, SO ITS SIZE IS CAPPED** (FAT32.md §9): one
    // copy is 4 bytes a cluster on FAT32, 12.5 MiB for 100 GiB at 32 KiB
    // clusters. A volume whose FAT is larger is refused, saying so, rather
    // than failing an allocation. Format larger volumes with larger clusters.
    if (vol.fatBytes() > fat_budget_bytes) {
        serial.put("  ");
        serial.put(what);
        serial.put(": its FAT is ");
        serial.putDec(vol.fatBytes() >> 20);
        serial.put(" MiB, past the ");
        serial.putDec(fat_budget_bytes >> 20);
        serial.put(" MiB set aside for it\n");
        serial.fail("a disk's FAT is too large to hold in memory; format it with larger clusters");
    }
    const fat_cache = pages.allocator.alloc(u8, vol.fatBytes()) catch
        serial.fail("no memory to hold the FAT");
    // Room for the check that weighs the FAT's copies when they differ (B26);
    // without it, the first copy is the FAT, as before.
    const weigh_room: ?[]u8 = pages.allocator.alloc(u8, vol.checkBytes()) catch null;
    defer if (weigh_room) |r| pages.allocator.free(r);
    const mirrors = vol.cacheFatChecked(fat_cache, weigh_room) catch |e| {
        serial.put("  fat cache: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the FAT could not be held in memory");
    };
    vol.mounted = mirrors;
    // Lookups read a directory up to a cluster per request (disk_fat's
    // `dir_burst`), within the most one request carries.
    const burst_sectors = @min(vol.sectors_per_cluster, vol.blk.most_sectors);
    vol.dir_burst = pages.allocator.alloc(u8, burst_sectors * disk_fat.sector_size) catch
        serial.fail("no memory to read directories in bursts");
    // Directory sectors, once read, are held (disk_fat's `dirs`): 8 MiB, sixteen
    // thousand sectors, so a send or Recent finds its folders in memory.
    // A speed-up, so memory it cannot have means serving without it, never
    // a boot that stops.
    const dir_slots = 16384;
    if (pages.allocator.alloc(u32, dir_slots)) |dir_keys| {
        if (pages.allocator.alloc(u8, dir_slots * disk_fat.sector_size)) |dir_data| {
            vol.cacheDirs(dir_keys, dir_data);
        } else |_| {
            pages.allocator.free(dir_keys);
            serial.put("  no memory to hold folders: they are read from the disk\n");
        }
    } else |_| serial.put("  no memory to hold folders: they are read from the disk\n");
    // A machine stopped between the FAT copies' writes, or a copy that
    // reads wrong, leaves them apart; the copy that checks cleaner is the
    // FAT, the first on a tie (disk_fat.cacheFatChecked).
    if (mirrors.repaired > 0) {
        serial.put("  ");
        serial.put(what);
        serial.put(": ");
        serial.putDec(mirrors.repaired);
        serial.put(" sectors of the FAT's copies differed; ");
        if (mirrors.found == .weighed or mirrors.found == .tied) {
            serial.put("checked with each copy, the first had ");
            serial.putDec(mirrors.health[0].problems);
            serial.put(" problems and ");
            serial.putDec(mirrors.health[0].leaked);
            serial.put(" leaked, the second ");
            serial.putDec(mirrors.health[1].problems);
            serial.put(" and ");
            serial.putDec(mirrors.health[1].leaked);
            serial.put("; ");
        }
        serial.put(if (mirrors.trusted == 1) "the first was written from the second\n" else "the second was written from the first\n");
    }
    if (weigh_room == null) serial.put("  no memory to weigh the FAT's copies: the first is the FAT\n");
    if (mirrors.found == .tied) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the FAT's copies differ and check alike: the first is held, neither written over\n");
    }
    if (mirrors.repair == .refused) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the disk refused a repair of the FAT's copies: the FAT is held, the copies left apart\n");
    }
    if (mirrors.found == .unweighed) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the FAT's copies differ and could not be weighed (a read failed): the first is held, neither written over; writes are refused until a weighing succeeds, tried again once a minute in idle time (metal-vmm QUEUE 188.2)\n");
    }
    serial.put("  ");
    serial.put(what);
    serial.put(if (vol.kind == .fat32) ": FAT32 at LBA " else ": FAT16 at LBA ");
    serial.putDec(part.first_lba);
    serial.put(", FAT held in memory (");
    serial.putDec(vol.fatBytes());
    serial.put(" bytes), ");
    // The reserve for small writes (metal-vmm QUEUE 132).
    serial.putDec(@as(u64, vol.reserve_clusters) * vol.sectors_per_cluster * 512 >> 20);
    serial.put(" MB kept for small writes\n");
    diskCheck(&vol, what);
    return vol;
}

/// **B15: THE VOLUMES, CHECKED AFTER EVERY REQUEST**, in a `-Dcoverage` build
/// only: the whole check, as `diskCheck` runs it at boot, with no line
/// printed. The kernel cannot tell when a run ends (metal-vmm ends it from
/// outside), so this is the nearest thing: the state after the last request
/// is the state the run ended in.
pub fn checkVolumes() void {
    // **WHICH DISK** (metal-vmm P128, 198.5): the boot disk holds the site,
    // the volume the data; each property says which it found its damage
    // on, so sweep.sh excuses it only by a fault on that disk.
    for ([_]?*disk_fat.Volume{ Io.siteVolume(), Io.dataVolume() }, [_][]const u8{ "boot", "volume" }) |maybe, disk| {
        const vol = maybe orelse continue;
        // **A CHECK THAT CANNOT RUN SAYS SO** (the normalization hunt,
        // 2026-10-10): it went quietly unrun. Memory for its marks is the
        // machine's own failing, a broken property; a read the disk refused
        // is a fault's (the sweeps refuse requests by number, the check's
        // reads among them), named and counted.
        const seen = pages.allocator.alloc(u8, vol.checkBytes()) catch {
            metal.coverage.always(@src(), false, "fat: after a request, a volume's check has the memory to run", .{ .bytes = vol.checkBytes() });
            continue;
        };
        defer pages.allocator.free(seen);
        var damage: u32 = 0;
        const Count = struct {
            fn each(n: *u32, f: disk_fat.Finding) void {
                if (f.problem.damage()) n.* += 1;
            }
        };
        _ = vol.check(seen, &damage, Count.each) catch |e| {
            couldNotCheck(e);
            continue;
        };
        metal.coverage.always(@src(), damage == 0, "fat: after a request, a volume has no damage beyond what a stop leaves", .{ .damage = damage, .disk = disk });
        // **WHAT THE VOLUME KEEPS OF ITS FAT IS WHAT THE FAT SAYS NOW**
        // (essay web-server-in-a-box; kernel-facts #8): the kept count, and
        // a hint with no free cluster below it.
        const now = vol.derive() catch |e| {
            couldNotCheck(e);
            continue;
        };
        metal.coverage.always(@src(), vol.free_clusters == now.free, "fat: after a request, the kept free count is the FAT's", .{ .kept = vol.free_clusters, .fat = now.free });
        if (now.first_free) |first| metal.coverage.always(@src(), vol.alloc_hint <= first, "fat: after a request, no free cluster lies below the allocation hint", .{ .hint = vol.alloc_hint, .first_free = first });
    }
}

/// A check after a request that stopped on an error: a read the disk refused
/// (a fault's, named), or anything else (the check's own failing, a broken
/// property).
fn couldNotCheck(e: anyerror) void {
    if (e == error.ReadFailed) {
        metal.coverage.reachable(@src(), "fat: after a request, a volume's check stops on a read the disk refused", null);
        return;
    }
    metal.coverage.always(@src(), false, "fat: after a request, a volume's check stops on nothing but a refused read", .{ .err = @errorName(e) });
}

/// **THE DISK CHECK, AT EVERY MOUNT** (`disk_fat.Volume.check`, QUEUE.md item
/// 13): one summary line per volume, then each finding. It reports and never
/// halts, and it writes nothing: a damaged volume still boots and serves, and
/// the log says what to look at with fsck.vfat on a copy. The judges read the
/// summary line on every boot (probe/judge_gopher.py, `disk_check_lines`).
///
/// It runs after `cacheFat`, so following a chain is a memory read; the walk
/// reads each directory sector once.
fn diskCheck(vol: *disk_fat.Volume, what: []const u8) void {
    serial.put("  disk check, ");
    serial.put(what);
    serial.put(": ");
    const seen = pages.allocator.alloc(u8, vol.checkBytes()) catch {
        serial.put("not run: no memory for its map of the clusters\n");
        return;
    };
    defer pages.allocator.free(seen);
    const Shown = struct {
        /// More findings than this are counted, not printed: a volume with
        /// thousands of leaked runs must not bury the rest of the boot.
        const most = 20;
        held: [most]disk_fat.Finding = undefined,
        paths: [most][256]u8 = undefined,
        n: u32 = 0,
        /// Findings that are damage (`disk_fat.Problem.damage`), all of them.
        damage: u32 = 0,
        fn each(self: *@This(), f: disk_fat.Finding) void {
            if (f.problem.damage()) self.damage += 1;
            if (self.n < most) {
                const len = @min(f.path.len, self.paths[self.n].len);
                @memcpy(self.paths[self.n][0..len], f.path[0..len]);
                self.held[self.n] = f;
                self.held[self.n].path = self.paths[self.n][0..len];
            }
            self.n += 1;
        }
    };
    var shown: Shown = .{};
    const h = vol.check(seen, &shown, Shown.each) catch |e| {
        serial.put("not run: ");
        serial.put(@errorName(e));
        serial.put("\n");
        return;
    };
    serial.putDec(h.files);
    serial.put(" files, ");
    serial.putDec(h.directories);
    serial.put(" directories, ");
    serial.putDec(h.used);
    serial.put(" clusters used, ");
    serial.putDec(h.leaked);
    serial.put(" leaked, ");
    serial.putDec(h.problems);
    serial.put(" problems\n");
    // At boot, so the last run's end: observed in every build.
    metal.coverage.always(@src(), shown.damage == 0, "fat: at boot, a volume has no damage beyond what a stop leaves", .{ .damage = shown.damage, .disk = if (std.mem.eql(u8, what, "the boot disk")) "boot" else "volume" });
    for (shown.held[0..@min(shown.n, Shown.most)]) |f| {
        serial.put("    ");
        serial.put(@tagName(f.problem));
        serial.put(" at ");
        serial.put(if (f.path.len > 0) f.path else "(the volume)");
        serial.put(", cluster ");
        serial.putDec(f.cluster);
        if (f.count != 0) {
            serial.put(", count ");
            serial.putDec(f.count);
        }
        serial.put("\n");
    }
    if (shown.n > Shown.most) {
        serial.put("    and ");
        serial.putDec(shown.n - Shown.most);
        serial.put(" more\n");
    }
}

/// **A DISK THAT STOPPED ANSWERING RESTARTS THE MACHINE** (metal-vmm QUEUE
/// 198.3; the choice, and the guard against a loop, are
/// `metal.restart.disk_ended`'s). Asked once a turn: two fields. What the
/// disk said is written first, so the kept log holds it (/admin/log, the
/// boot before), and the next boot's /admin/host says it restarted after
/// a disk that stopped answering.
pub fn diskStopped() void {
    if (metal.restart.onDiskEnded(metal.restart.disk_ended, gm_build.restart) != .restart) return;
    for (gopher.disks, 0..) |maybe, k| {
        const d = maybe orelse continue;
        if (d.ended == .serving) continue;
        const which = if (k == 0) "the boot disk" else "the volume";
        serial.put("  ");
        serial.put(which);
        serial.put(switch (d.ended) {
            .serving => unreachable,
            .timed_out => " STOPPED ANSWERING: a request went unanswered for its whole budget; ",
            .needs_reset => " STOPPED ANSWERING: it asked for a reset; ",
        });
        serial.putDec(d.refused_after_end);
        serial.put(" requests refused since; what its failed requests ended with: ");
        var line: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        d.failures.write(&w) catch {};
        serial.put(w.buffered());
        serial.put("\n");
        serial.failFor(.disk_stopped, if (k == 0) "the boot disk stopped answering: restarting, so a fresh boot negotiates it again" else "the volume stopped answering: restarting, so a fresh boot negotiates it again");
    }
}

/// The data's volume, free and total, for the game store's floor: the volume
/// when one is attached, else the boot disk, which then holds the data.
pub fn dataSpace() ?webbox.free_space.Space {
    const v = Io.dataVolume() orelse Io.siteVolume() orelse return null;
    const sp = v.space() catch return null;
    return .{ .free = sp.free, .total = sp.total };
}
