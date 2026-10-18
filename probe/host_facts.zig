//! **WHAT /admin/host SAYS OF THE MACHINE** (`metalFacts`): the host's
//! facts, a line each, for the application's admin page: what is served and
//! held, the disks and their checks, the uploads, the rest between frames;
//! each fact checked (`checkFact`) before it is said.

const std = @import("std");
const metal = @import("metal");
const webbox = @import("webbox");
const Io = metal.io;
const gm_build = @import("gm_build");
const interrupts = metal.interrupts;
const tcp = metal.tcp;
const pages = metal.pages;
const app = @import("app");
const gopher = @import("gopher.zig");
const stream = metal.stream;
const disk_fat = metal.disk_fat;
const serialText = metal.config_text.serialText;

/// How many of them /admin/host shows; the log has every one.
const uploads_shown = 10;

/// A volume's idle check, as /admin/host says it.
fn checkFact(alloc: std.mem.Allocator, c: *const metal.idle_check.VolumeCheck) ![]const u8 {
    const hs = webbox.host_facts;
    const last = if (c.last) |l| blk: {
        const ago: i64 = @intCast(@divFloor(gopher.awakeNow() - l.at, std.time.ns_per_s));
        const damage = if (l.tally.first) |f|
            try std.fmt.allocPrint(alloc, "{d} damaged, the first {s} at cluster {d}", .{ l.tally.damage, @tagName(f.problem), f.cluster })
        else
            "no damage";
        break :blk try std.fmt.allocPrint(alloc, "last finished {s} ago: {d} files, {d} folders, {s}, {d} clusters leaked, {d} problems in all", .{
            try hs.duration(alloc, ago), l.health.files, l.health.directories, damage, l.health.leaked, l.health.problems,
        });
    } else "not finished yet";
    return std.fmt.allocPrint(alloc, "{s}; {d} finished, {d} started again (a write under it), {d} ended by a read that failed; {d} steps, the longest {d} ms", .{
        last, c.finished, c.restarts, c.failed, c.task.steps, c.task.longest_ns / std.time.ns_per_ms,
    });
}

pub fn metalFacts(io: Io, alloc: std.mem.Allocator) anyerror![]const webbox.host_facts.Fact {
    const hs = webbox.host_facts;
    var facts: std.ArrayList(hs.Fact) = .empty;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const add = struct {
        fn f(list: *std.ArrayList(hs.Fact), a: std.mem.Allocator, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try list.append(a, .{ .label = label, .value = try std.fmt.allocPrint(a, fmt, args) });
        }
    }.f;
    try add(&facts, alloc, "host", "zig-metal-unikernel, with no operating system", .{});
    try add(&facts, alloc, "zig-metal-unikernel commit", "{s}", .{gm_build.commit});
    try add(&facts, alloc, "booted", "{s}", .{try hs.utc(alloc, gopher.booted_unix)});
    try add(&facts, alloc, "up for", "{s}", .{try hs.duration(alloc, now - gopher.booted_unix)});
    // **WHY THIS BOOT** (198.3): a restart says what ended the boot before.
    if (gm_build.restart) try add(&facts, alloc, "restarted", "{s}", .{if (gopher.restart_record) |r|
        try std.fmt.allocPrint(alloc, "yes, after {s} (restart {d} in a row{s}{s}); the boot before's log is the end of /admin/log", .{
            r.reason.text(),                   r.count,
            if (r.at != null) ", at " else "", if (r.at) |m| try hs.utc(alloc, metal.restart.unixOfMinutes(m)) else "",
        })
    else
        "no: this boot was not a restart"});
    try add(&facts, alloc, "its clock now", "{s} (set from the hardware clock at boot, never corrected)", .{try hs.utc(alloc, now)});
    try add(&facts, alloc, "processor", "TSC at {d} MHz; {s}", .{
        gopher.tsc_hz_seen / 1_000_000,
        if (interrupts.armed()) "rests between frames" else "never rests (polls)",
    });
    // **THE LEASE IS NEVER RENEWED** (193, gap 12): its length, and
    // whether the machine has run past it.
    if (gopher.lease_held) |l| try add(&facts, alloc, "address", "{d}.{d}.{d}.{d} from DHCP, never renewed; {s}", .{
        l.address[0], l.address[1], l.address[2], l.address[3],
        if (l.seconds) |lent|
            if (now - gopher.booted_unix > lent)
                try std.fmt.allocPrint(alloc, "lent for {s}, and the machine has run PAST ITS LEASE", .{try hs.duration(alloc, lent)})
            else
                try std.fmt.allocPrint(alloc, "lent for {s}", .{try hs.duration(alloc, lent)})
        else
            "the server did not say for how long",
    });
    try add(&facts, alloc, "requests served", "{d}", .{gopher.served});
    try add(&facts, alloc, "connections", "{d} open now, {d} at most, of {d}", .{ gopher.open_now, gopher.busiest, gopher.max_connections });
    if (gopher.serving_table) |t| {
        var counts: std.Io.Writer.Allocating = .init(alloc);
        try tcp.writeCounts(t, &counts.writer);
        try facts.append(alloc, .{ .label = "tcp since boot", .value = counts.written() });
        // **FRAMES PASSED OVER** (193, gap 8), by why.
        var passed: std.Io.Writer.Allocating = .init(alloc);
        try t.passed.write(&passed.writer);
        try facts.append(alloc, .{ .label = "frames passed over", .value = passed.written() });
    }
    try add(&facts, alloc, "streams", "{d} held now, {d} at most, {d} ended", .{ gopher.held_now, gopher.held_most, gopher.streams_ended });
    const p = pages.stats();
    try add(&facts, alloc, "memory (pages)", "{d} MB taken now, {d} MB at most, of {d} MB", .{
        p.bytes_taken >> 20, (p.pages_high_water * pages.page_size) >> 20, p.bytes_total >> 20,
    });
    // **UPLOADS** (189.4): every one counted by its answer, then the newest.
    {
        var counts: std.Io.Writer.Allocating = .init(alloc);
        try gopher.uploads.writeCounts(&counts.writer);
        try facts.append(alloc, .{ .label = "uploads", .value = counts.written() });
        var k: usize = 0;
        while (gopher.uploads.newest(k)) |u| : (k += 1) {
            if (k == uploads_shown) break;
            var one: std.Io.Writer.Allocating = .init(alloc);
            try u.write(&one.writer);
            try facts.append(alloc, .{ .label = if (k == 0) "an upload, the newest first" else "", .value = one.written() });
        }
    }
    if (Io.siteVolume()) |v| try addVolume(&facts, alloc, "the boot disk (the site)", "the boot disk's write cache", "the boot disk's folders in memory", "the boot disk at boot", v);
    if (Io.dataVolume()) |v| {
        try addVolume(&facts, alloc, "the volume (" ++ app.hosting.data_name ++ ")", "the volume's write cache", "the volume's folders in memory", "the volume at boot", v);
    } else try add(&facts, alloc, "the volume (" ++ app.hosting.data_name ++ ")", "none attached: the data is on the boot disk", .{});
    const kept = Io.siteCache();
    try add(&facts, alloc, "site files in memory", "{d} kept, {d} KB of {d} KB; {d} reads answered from them", .{
        kept.count, kept.used >> 10, @as(usize, Io.SiteCache.capacity) >> 10, kept.hits,
    });
    if (Io.pageCache()) |pc| {
        try add(&facts, alloc, "data files in memory", "{d} kept, {d} MB of {d} MB, files up to {d} KiB; {d} reads answered from them, {d} from the disk; {d} pushed out", .{
            pc.count, pc.held >> 20, pc.budget >> 20, pc.largest >> 10, pc.hits, pc.misses, pc.evicted,
        });
    } else try add(&facts, alloc, "data files in memory", "none (page_cache_mib = 0)", .{});
    try add(&facts, alloc, "idle time", "{d} steps in quiet moments, {d} over the {d} ms budget", .{
        gopher.idle_work.steps, gopher.idle_work.overruns, gopher.idle_work.budget_ns / std.time.ns_per_ms,
    });
    try add(&facts, alloc, "between requests", "{d} calls of the application's work, {d} over the {d} ms target, the longest {d} ms", .{
        gopher.between.calls, gopher.between.overruns, gopher.between_target_ns / std.time.ns_per_ms, gopher.between.longest_ns / std.time.ns_per_ms,
    });
    for (&gopher.volume_checks, gopher.volume_check_names) |*maybe, name| {
        if (maybe.*) |*c| try facts.append(alloc, .{ .label = name, .value = try checkFact(alloc, c) });
    }
    const work = gopher.diskWork();
    try add(&facts, alloc, "disk requests", "{d}, busy {d} ms in all", .{ work.requests, @divTrunc(Io.ticksToNs(work.ticks), std.time.ns_per_ms) });
    // **THE MOST ONE REQUEST CARRIES**, each disk's (metal-vmm QUEUE 178): 1
    // MiB unless the device said less, which it is obeyed in.
    try add(&facts, alloc, "disk request most", "boot {d} KiB, volume {d} KiB (the volume's own: {s})", .{
        if (gopher.disks[0]) |d| d.most_sectors / 2 else 0,
        if (gopher.disks[1]) |d| d.most_sectors / 2 else 0,
        if (gopher.disks[1]) |d| if (d.disk_most_sectors) |m| try std.fmt.allocPrint(alloc, "{d} KiB", .{m / 2}) else "not said" else "no volume",
    });
    try add(&facts, alloc, "NMIs", "{d}", .{interrupts.nmis});
    // **WAKES** (193, gap 11): a device that interrupts endlessly shows as
    // wakes by a device far past the frames that came.
    if (interrupts.armed()) try add(&facts, alloc, "rests", "{d}, {d} of them ended by a device, {d} by neither the timer nor the card", .{ interrupts.rests.rests, interrupts.rests.woken_by_device, interrupts.rests.woken_by_other });
    // **SLEEPS** (sleep.zig): the quiescent machine's long rests, and a wake
    // that came without its interrupt.
    if (interrupts.armed()) try add(&facts, alloc, "sleeps", "{d} while quiescent, {d} ended by a device, {d} by the longest rest ({d} ms), {d} by neither the timer nor the card, {d} missed wakes (a frame waiting after the timer ended one)", .{
        gopher.sleeps.sleeps, gopher.sleeps.by_device, gopher.sleeps.by_longest, gopher.longest_rest_ms_now, gopher.sleeps.by_other, gopher.sleeps.missed,
    });
    if (gopher.turning) |t| try add(&facts, alloc, "frames refused (too long to send)", "{d}", .{t.wire.nic.oversized});
    // **A RESPONSE CUT OFF BEHIND ITS SPILL** (198.1): the connection went
    // while part of the response still waited to be sent.
    try add(&facts, alloc, "responses cut off (connection gone, rest unsent)", "{d}", .{stream.gone_behind_spill});
    // **A CARD THAT STOPPED TAKING FRAMES** (193.2): sends that waited out
    // their budget, the card asking for a reset, and frames dropped since.
    if (gopher.turning) |t| try add(&facts, alloc, "network card stalls", "{d} sends waited out their second, {d} times the card asked for a reset, {d} frames dropped while it took none back{s}", .{
        t.wire.nic.send_stalls, t.wire.nic.reset_asked, t.wire.nic.dropped_stalled, if (t.wire.nic.stalled) "; STALLED NOW" else "",
    });
    // **THE CARD'S RING** (193.5): entries no sound card makes.
    if (gopher.turning) |t| try add(&facts, alloc, "network card ring", "{d} received into a buffer never offered, {d} with a length no frame has, {d} send completions for a buffer not lent", .{
        t.wire.nic.rx_strange_ids, t.wire.nic.rx_bad_lengths, t.wire.nic.tx_strange_completions,
    });
    return facts.items;
}

fn kindName(v: *const disk_fat.Volume) []const u8 {
    return if (v.kind == .fat32) "FAT32" else "FAT16";
}

fn addVolume(facts: *std.ArrayList(webbox.host_facts.Fact), alloc: std.mem.Allocator, label: []const u8, cache_label: []const u8, dirs_label: []const u8, boot_label: []const u8, v: *disk_fat.Volume) !void {
    var serial_text: [9]u8 = undefined;
    const named = if (v.serial) |n| serialText(&serial_text, n) else "no serial";
    const value = if (v.space()) |sp|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: {d} MB free of {d} MB, {d} MB of it kept for small writes; {d} cleanups after a commit failed (leaks, {d} clusters counted, {d} more may be live; {d} long names left orphaned, {d} more may be), {d} FAT copy writes failed (copies apart); {d} sector reads failed, {d} sector writes failed", .{
            kindName(v),                                                      named,             sp.free >> 20,       sp.total >> 20,
            @as(u64, v.reserve_clusters) * v.sectors_per_cluster * 512 >> 20, v.cleanups_failed, v.leaked_clusters,   v.unsure_clusters,
            v.orphaned_runs,                                                  v.unsure_runs,     v.fat_copies_failed, v.read_failures,
            v.write_failures,
        })
    else |e|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: free space unreadable ({s})", .{ kindName(v), named, @errorName(e) });
    try facts.append(alloc, .{ .label = label, .value = value });
    // **WHAT THE BOOT FOUND** (193, gap 10): once only boot log lines.
    {
        var boot: std.Io.Writer.Allocating = .init(alloc);
        try metal.boot_facts.write(&boot.writer, v.blk.reads_retried, v.mounted);
        try facts.append(alloc, .{ .label = boot_label, .value = boot.written() });
    }
    // **A VOLUME THAT REFUSES WRITES SAYS SO** (metal-vmm QUEUE 188.2).
    if (v.writes == .refused or v.reweighs > 0) try facts.append(alloc, .{
        .label = "writes",
        .value = try std.fmt.allocPrint(alloc, "{s}; the FAT's copies weighed again {d} times, {d} failed; {d} sector writes turned away while refused", .{
            if (v.writes == .refused) "REFUSED: the FAT's copies differ and could not be weighed; reads are served, and the weighing is tried again once a minute" else "taken: a weighing succeeded",
            v.reweighs,
            v.reweighs_failed,
            v.writes_turned_away,
        }),
    });
    // **WHETHER A SAVE IS DURABLE BEFORE IT IS ANSWERED** (io.durable): what
    // the disk says of its write cache, and the flushes sent to it.
    const cache: []const u8 = switch (metal.scsi_mode.report(v.blk.write_cache, v.blk.cache_on_at_bringup)) {
        .would_not_turn_off => "on, and it would not turn off: writes wait in it until flushed, and a power cut can damage the filesystem",
        .turned_off => "turned off at boot: it writes through",
        .caches => "on: writes wait in it until flushed",
        .writes_through => "off: it writes through",
        .unknown => "not said: flushed as if on",
    };
    try facts.append(alloc, .{
        .label = cache_label,
        .value = try std.fmt.allocPrint(alloc, "{s}; {d} flushes, {d} of them SYNCHRONIZE CACHE sent{s}, {d} failed; looked at again after {d} resets; {s}; what its failed requests ended with (193.3): {s}", .{
            cache, v.blk.flushes, v.blk.synchronizes_sent, if (v.blk.synchronize_unknown) " (the disk did not know the command, and is treated as writing through)" else "", v.blk.flush_failures, v.blk.cache_rechecks,
            // **A DISK THAT STOPPED ANSWERING** (193.2).
            switch (v.blk.ended) {
                .serving => "answering",
                .timed_out => try std.fmt.allocPrint(alloc, "STOPPED ANSWERING: a request went 30 s unanswered; {d} requests refused since", .{v.blk.refused_after_end}),
                .needs_reset => try std.fmt.allocPrint(alloc, "STOPPED ANSWERING: it asked for a reset; {d} requests refused since", .{v.blk.refused_after_end}),
            },
            blk: {
                var failed: std.Io.Writer.Allocating = .init(alloc);
                try v.blk.failures.write(&failed.writer);
                break :blk failed.written();
            },
        }),
    });
    if (v.dirs) |d| try facts.append(alloc, .{
        .label = dirs_label,
        .value = try std.fmt.allocPrint(alloc, "{d} sectors held at most; {d} sector reads answered from it, {d} from the disk (every sector read asks it, folders or not)", .{ d.keys.len, d.hits, d.misses }),
    });
}
