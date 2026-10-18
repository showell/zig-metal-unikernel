//! **THE MACHINE'S CONFIGURATION**: `zig-metal-unikernel.conf` on the boot
//! volume (its old name read too), each line a setting: the cards, the
//! connections, the page cache, the rest between frames; a line it does not
//! know, or a number it cannot read, said on the console. gopher.zig reads it
//! once, at boot (`readConfig`).

const app = @import("app");
const std = @import("std");
const metal = @import("metal");
const stream = metal.stream;
const Io = metal.io;
const serial = metal.serial;
const webbox = @import("webbox");
const streams = webbox.bus;
const gopher = @import("gopher.zig");

/// The largest file the cache keeps, when `page_cache_largest_kib` is absent:
/// the application's `whole_read_max` (4 MiB), the line above which a GET of an
/// upload streams instead of reading the file whole. So by default what is kept
/// and what is read whole are one number; a `page_cache_largest_kib` above it
/// keeps no bigger upload, since an upload past the line streams past the cache.
///
/// 4 MiB holds every transcript (prod's largest is 362 KB) and every picture
/// people actually load (a phone photo or a screenshot is a few MB; chat's image
/// cap is 10 MiB), so a picture read once is served from memory rather than read
/// whole from the disk on every GET — the one stall item 90 left (30-39 MB/s).
/// A file past the cap is read from the disk as before, so no single big upload
/// pushes the transcripts out. `docs/designs/DESIGN-picture-cache.md` has the
/// method and the budget cost.
const page_cache_largest_kib_default = app.hosting.whole_read_max >> 10;

pub const config_path = "zig-metal-unikernel.conf";
/// The file's name before the repo's rename (2026-10-13). A disk that has it
/// was written by an older tool, and the defaults a missing file means would
/// silently replace what it says (the public card, no volume check): its
/// presence stops the boot.
const old_config_path = "gopher-metal.conf";

/// **HOST CONFIGURATION, FROM THE BOOT DISK.** What a Linux host would read from
/// a config file or the environment, this reads from `zig-metal-unikernel.conf` on the
/// boot disk, which comes with each image — the things that are about this
/// machine rather than about the site:
///
///     requests = N            serve N and stop; absent, serve until stopped
///     idle_timeout_ms = N     how long a connection may make no progress
///     streams = N             how many live streams may be held at once
///     keepalive_ms = N        how long a stream may be quiet before a ping;
///                             absent, the application's own keepalive
///     lose_one_sent_in = N    lose every Nth TCP frame sent, to prove that
///                             what is lost is sent again
///     card = public|private   which network card to serve on: the first
///                             (public, the default) or the second (private).
///                             A droplet's are public then private in PCI slot
///                             order; chat there belongs on the private one,
///                             behind prod's Caddy.
///     page_cache_mib = N      memory for the data's files read whole
///                             (`page_cache.zig`), 64 when absent; 0 keeps
///                             none, every read from the disk, as before
///     longest_rest_ms = N     the longest a quiescent machine sleeps before
///                             it looks again, 10000 when absent (sleep.zig);
///                             a few ms in a test exercises the same path
///     page_cache_largest_kib = N
///                             the largest file the cache keeps, in KiB; 4096
///                             (4 MiB) when absent, at most 10240 (chat's image
///                             cap). Raising it keeps bigger pictures in memory
///                             at the cost of room for transcripts.
///     admin_password_reset = Steve $2b$10$…
///                             a new password hash for the admin, uid 1, if
///                             uid 1 is named so; applied once, at boot
///                             (`admin_reset.zig`, ADMIN-PASSWORD-LOST.md)
///     volume = 92DE-8831      the FAT serial (as `blkid` shows it) of the
///                             DigitalOcean volume the application's data is
///                             on. Set, that volume must be attached or the
///                             machine stops; absent, any volume is used, or
///                             the boot disk when there is none.
///
/// A key that is not one of those is a misconfiguration, and stops the machine
/// rather than being ignored: a timeout that was silently not applied is how a
/// server ends up held open by one client.
pub const Config = struct {
    requests: ?u64 = null,
    idle_ns: u64 = stream.default_idle_ns,
    keepalive_ns: u64 = streams.Subscriber.keepalive_s * std.time.ns_per_s,
    lose_one_sent_in: u32 = 0,
    /// **HOW MANY STREAMS MAY BE HELD AT ONCE.** A held stream occupies a
    /// connection slot for as long as its tab is open, so without a budget the
    /// streams alone could fill the table and every new page load would be
    /// turned away. The rest of the slots are for requests.
    streams: usize = gopher.max_connections - reserved_for_requests,
    card: Card = .public,
    /// The FAT serial of the volume the application's data is on, as `blkid`
    /// spells it: `volume = 92DE-8831`. When it is set, a volume with exactly
    /// that serial must be attached, or the machine stops.
    volume: ?u32 = null,
    /// The reverse proxy whose X-Forwarded-For names the client
    /// (`trusted_proxy = 10.0.0.2`): prod's Caddy, over the private network.
    /// Without it every request counts as the address it came from, and
    /// through Caddy that is one address for everyone, so the game store's
    /// bounds on what one address may do become bounds on the whole site.
    trusted_proxy: ?[4]u8 = null,
    /// Memory for the page cache, in MiB; 0 keeps none.
    page_cache_mib: u32 = 64,
    /// The largest file the page cache keeps, in KiB (`page_cache.zig`'s
    /// `largest`). Default 4 MiB; the box raises it toward chat's 10 MiB image
    /// cap once prod's picture sizes are measured.
    page_cache_largest_kib: u32 = page_cache_largest_kib_default,
    /// **THE LONGEST A QUIESCENT MACHINE SLEEPS** (sleep.zig): the
    /// application's wake when sooner. Every rest has a deadline, and this
    /// bounds what a lost interrupt can cost. `longest_rest_ms`.
    longest_rest_ns: u64 = gopher.default_longest_rest_ms * std.time.ns_per_ms,
    /// The admin's password reset, kept here because the text it was read
    /// from is freed: the name, and the 60-byte hash.
    reset_name: [64]u8 = undefined,
    reset_name_len: usize = 0,
    reset_hash: [60]u8 = undefined,
    reset: bool = false,
};

/// A droplet's two network cards, in PCI slot order: what `virtio.findNth` is
/// asked for.
const Card = enum(u1) { public = 0, private = 1 };

/// Connection slots no stream may take: room for a burst of page loads while
/// every stream slot is held. One of them is the machine's own fetch's
/// (`table.reserved_for_initiated`), so 63 are for requests.
const reserved_for_requests = 64;

pub fn readConfig(io: Io, alloc: std.mem.Allocator) Config {
    var conf = Config{};
    if (Io.Dir.cwd().readFileAlloc(io, old_config_path, alloc, .limited(4096))) |old| {
        alloc.free(old);
        serial.fail(old_config_path ++ " is on the disk: it is " ++ config_path ++ " now, and an older tool wrote this disk");
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => serial.fail(old_config_path ++ " is on the disk but could not be read: it is " ++ config_path ++ " now"),
    }
    // **A MISSING FILE IS THE DEFAULTS; ANY OTHER FAILURE STOPS THE BOOT**
    // (metal-vmm QUEUE B21). A refused read once meant "serve with the
    // defaults", which on a droplet is serving without the settings it was
    // given: the volume it must serve, the proxy it must trust. As
    // angry-gopher's files.zig has it, an error is not an empty file.
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return conf,
        else => {
            serial.put("  " ++ config_path ++ ": ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail(config_path ++ " is there but could not be read; serving without it would ignore what it says");
        },
    };
    // No setting keeps the text (numbers, and a card's name), so nothing needs
    // it once it is read. It
    // used to stay in the long-lived heap, where a longer file meant a bigger
    // heap for the life of the boot — which the stream-churn gate saw as one
    // byte between `requests = 8` and `requests = 28`.
    defer alloc.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var said_anything = false;
    var said: [32][]const u8 = undefined;
    var said_n: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        said_anything = true;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            serial.fail(config_path ++ ": a line with no `=`");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // **A KEY SAID TWICE STOPS THE BOOT** (the normalization hunt): the
        // last one won, silently (`volume = A` ... `volume = B`).
        for (said[0..said_n]) |k| if (std.mem.eql(u8, k, key)) serial.fail(config_path ++ ": a key said twice");
        if (said_n == said.len) serial.fail(config_path ++ ": more keys than the machine reads");
        said[said_n] = key;
        said_n += 1;
        if (std.mem.eql(u8, key, "requests")) {
            conf.requests = configNumber(u64, value) catch
                serial.fail(config_path ++ ": `requests` is not a number");
        } else if (std.mem.eql(u8, key, "idle_timeout_ms")) {
            const ms = configNumber(u64, value) catch
                serial.fail(config_path ++ ": `idle_timeout_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": an idle timeout of zero would answer nobody");
            conf.idle_ns = metal.idle.nsOfMs(ms) orelse serial.fail(config_path ++ ": `idle_timeout_ms` is too large");
        } else if (std.mem.eql(u8, key, "keepalive_ms")) {
            const ms = configNumber(u64, value) catch
                serial.fail(config_path ++ ": `keepalive_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": a keepalive of zero would ping on every turn");
            conf.keepalive_ns = metal.idle.nsOfMs(ms) orelse serial.fail(config_path ++ ": `keepalive_ms` is too large");
        } else if (std.mem.eql(u8, key, "lose_one_sent_in")) {
            conf.lose_one_sent_in = configNumber(u32, value) catch
                serial.fail(config_path ++ ": `lose_one_sent_in` is not a number");
            if (conf.lose_one_sent_in == 1) serial.fail(config_path ++ ": losing every frame would answer nobody");
        } else if (std.mem.eql(u8, key, "streams")) {
            const n = configNumber(usize, value) catch
                serial.fail(config_path ++ ": `streams` is not a number");
            if (n == 0 or n > gopher.max_connections - reserved_for_requests)
                serial.fail(config_path ++ ": `streams` must leave room for requests");
            conf.streams = n;
        } else if (std.mem.eql(u8, key, "card")) {
            conf.card = std.meta.stringToEnum(Card, value) orelse
                serial.fail(config_path ++ ": `card` is `public` or `private`");
        } else if (std.mem.eql(u8, key, "volume")) {
            conf.volume = parseSerial(value) orelse
                serial.fail(config_path ++ ": `volume` is a FAT serial, as blkid shows it: 92DE-8831");
        } else if (std.mem.eql(u8, key, "admin_password_reset")) {
            const r = metal.admin_reset.parse(value) orelse
                serial.fail(config_path ++ ": `admin_password_reset` is the admin's name, then a bcrypt hash of cost 10 or more");
            if (r.name.len > conf.reset_name.len) serial.fail(config_path ++ ": `admin_password_reset` names someone longer than 64 bytes");
            @memcpy(conf.reset_name[0..r.name.len], r.name);
            conf.reset_name_len = r.name.len;
            @memcpy(&conf.reset_hash, r.hash[0..60]);
            conf.reset = true;
        } else if (std.mem.eql(u8, key, "page_cache_mib")) {
            conf.page_cache_mib = configNumber(u32, value) catch
                serial.fail(config_path ++ ": `page_cache_mib` is a number of MiB, 0 for none");
            if (conf.page_cache_mib > 1024) serial.fail(config_path ++ ": `page_cache_mib` past 1024 is more memory than a droplet has to spare");
        } else if (std.mem.eql(u8, key, "page_cache_largest_kib")) {
            conf.page_cache_largest_kib = configNumber(u32, value) catch
                serial.fail(config_path ++ ": `page_cache_largest_kib` is a number of KiB");
            if (conf.page_cache_largest_kib == 0) serial.fail(config_path ++ ": `page_cache_largest_kib` is 0 — set `page_cache_mib = 0` to keep no files, not a zero cap");
            if (conf.page_cache_largest_kib > app.hosting.cache_largest_most >> 10) serial.fail(config_path ++ ": `page_cache_largest_kib` past " ++ std.fmt.comptimePrint("{d}", .{app.hosting.cache_largest_most >> 10}) ++ " is more than the application's largest file worth keeping (app.hosting.cache_largest_most), so no file reaches it");
        } else if (std.mem.eql(u8, key, "longest_rest_ms")) {
            const ms = configNumber(u64, value) catch
                serial.fail(config_path ++ ": `longest_rest_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": a longest rest of zero would never rest");
            if (ms > std.time.ms_per_day) serial.fail(config_path ++ ": `longest_rest_ms` past a day is no bound on a lost interrupt");
            conf.longest_rest_ns = ms * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, key, "trusted_proxy")) {
            const a = std.Io.net.Ip4Address.parse(value, 0) catch
                serial.fail(config_path ++ ": `trusted_proxy` is an IPv4 address: 10.0.0.2");
            conf.trusted_proxy = a.bytes;
        } else {
            serial.fail(config_path ++ ": the keys are `requests`, `idle_timeout_ms`, `streams`, `keepalive_ms`, `lose_one_sent_in`, `card`, `volume`, `trusted_proxy`, `page_cache_mib`, `page_cache_largest_kib`, `longest_rest_ms` and `admin_password_reset`");
        }
    }
    if (!said_anything) serial.fail(config_path ++ " is present but says nothing");
    return conf;
}

/// A config number: decimal digits and nothing else. `std.fmt.parseInt` takes
/// `+5` and `1_000` too, a spelling no setting means (the normalization hunt).
const configNumber = metal.config_text.number;

/// `92DE-8831`: two halves of four hex digits, high half first.
const parseSerial = metal.config_text.serial;
