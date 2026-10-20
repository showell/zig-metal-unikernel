//! **A FAT DIRECTORY ENTRY, BYTE BY BYTE** (Microsoft's FAT specification,
//! "Directory Structure" and "Long File Name Implementation"): the 32-byte
//! short entry, its DOS date and time, the VFAT long-name parts and their
//! checksum, the 8.3 alias, and the case-blind name match. Pure: no volume,
//! no device, no allocation; `disk_fat.zig` places these bytes on a disk.
const std = @import("std");
const civil = @import("civil.zig");

pub const dirent_size: u32 = 32;
pub const attr_volume_label: u8 = 0x08;
pub const attr_directory: u8 = 0x10;
/// A long-name part: read-only, hidden, system and volume label at once,
/// which no real entry is (ATTR_LONG_NAME).
pub const attr_long_name: u8 = 0x0F;

/// A cluster number, and a FAT entry's value: 32 bits, so that FAT32's
/// 28-bit entries fit. FAT16's are the low 16.
pub const Cluster = u32;

pub fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

pub fn le32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .little);
}

/// The longest name this filesystem holds (VFAT allows 255): the
/// application's longest, `<sid>.reactions.jsonl` at an 80-character session
/// id (MIGRATION.md). Every entry carries a buffer this long, so it is no
/// longer than needed: 8 long-name parts.
pub const max_name: usize = 96;

/// **A DIRECTORY ENTRY'S DATE**: two 16-bit fields, packed, the year counted
/// from 1980 and the seconds in TWOS. A time written here reads back rounded
/// DOWN to an even second, the resolution of every modification time above.
///
/// **UTC, and no time zone anywhere.** DOS dates are local time by
/// convention, but nothing on this machine has a time zone, so these are
/// UTC; a Linux mount that wants to agree says `tz=UTC`.
///
/// Out of range is `none` rather than a wrong date: before 1980 there is no
/// representation, and after 2107 the year field wraps.
pub const Dos = struct {
    date: u16,
    time: u16,

    /// No date: what an entry written without a clock carries, and what
    /// `toUnix` reports as zero rather than as 1980.
    pub const none = Dos{ .date = 0, .time = 0 };

    pub const first_unix: i64 = 315532800; // 1980-01-01T00:00:00Z
    pub const last_unix: i64 = 4354819199; // 2107-12-31T23:59:59Z

    pub fn fromUnix(secs: i64) Dos {
        if (secs < first_unix or secs > last_unix) return none;
        const c = civil.fromUnix(secs);
        const year: u16 = @intCast(c.year - 1980);
        return .{
            .date = year << 9 | @as(u16, c.month) << 5 | c.day,
            .time = @as(u16, c.hour) << 11 | @as(u16, c.minute) << 5 | (@as(u16, c.second) / 2),
        };
    }

    /// Unix seconds, or 0 for an entry with no date (a date field of zero).
    pub fn toUnix(self: Dos) i64 {
        if (self.date == 0) return 0;
        const c = civil.Civil{
            .year = @as(i32, self.date >> 9) + 1980,
            .month = @intCast((self.date >> 5) & 0x0F),
            .day = @intCast(self.date & 0x1F),
            .hour = @intCast(self.time >> 11),
            .minute = @intCast((self.time >> 5) & 0x3F),
            .second = @intCast((self.time & 0x1F) * 2),
        };
        // A field can hold month 0, day 0 or hour 31: garbage on the disk must
        // not become a plausible date.
        if (c.month < 1 or c.month > 12) return 0;
        if (c.day < 1 or c.day > civil.daysInMonth(c.year, c.month)) return 0;
        if (c.hour > 23 or c.minute > 59 or c.second > 58) return 0;
        return civil.toUnix(c);
    }
};

pub const Entry = struct {
    /// The 8.3 alias, trimmed and dotted: "CODEX.CDX", "SESSIO~1".
    name: [12]u8,
    name_len: u8,
    /// The same alias as it sits on disk: eleven bytes, space padded.
    short: [11]u8 = @splat(' '),
    /// The long name, when the entry had one.
    long: [max_name]u8 = undefined,
    long_len: u8 = 0,
    attr: u8,
    first_cluster: Cluster,
    size: u32,
    /// The entry's write time; 0 when it has none.
    mtime_unix: i64 = 0,

    /// **WHERE THIS ENTRY SITS**, recorded by `Lister` as it decodes, so a
    /// change of size or chain (`setEntry`, `rename`) writes this one sector
    /// without walking the directory again.
    lba: u32 = 0,
    slot: u32 = 0,

    /// The name to show and to match on: the long one when there is one.
    pub fn text(self: *const Entry) []const u8 {
        return if (self.long_len > 0) self.long[0..self.long_len] else self.name[0..self.name_len];
    }

    pub fn alias(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isDirectory(self: *const Entry) bool {
        return self.attr & attr_directory != 0;
    }
};

/// **THE CHECKSUM THAT TIES A LONG NAME TO ITS ENTRY** (the specification's
/// ChkSum): over the alias's eleven bytes, rotate right and add, wrapping.
/// Wrong, a volume reads fine here and its long names are lost to every other
/// reader; probe/run.sh has fsck.vfat judge it.
pub fn shortChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| {
        sum = (((sum & 1) << 7) | ((sum & 0xFE) >> 1)) +% c;
    }
    return sum;
}

/// Where a long-name entry keeps its thirteen UCS-2 characters: LDIR_Name1,
/// LDIR_Name2 and LDIR_Name3, around the fields a short entry uses.
pub const long_offsets = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

/// **A LONG NAME BEING READ.** Its parts arrive before the short entry that
/// closes it, last part first, each written at its sequence number's place;
/// the checksum ties the run to that entry.
pub const LongName = struct {
    stands: Stands = .none,
    buf: [max_name]u8 = undefined,
    len: usize = 0,
    sum: u8 = 0,
    /// The number the run's next part must carry: one less than the part
    /// taken last, and 0 once part 1, the run's first characters, is in.
    next: u8 = 0,

    pub const Stands = enum {
        /// No run open: none begun, or the last one closed or let go.
        none,
        /// A run whose parts so far agree; `sum` is theirs.
        collecting,
        /// A run gone wrong (a part numbered out of range or out of turn, a
        /// checksum that differs, a character past `max_name`): nothing
        /// closes it. Only a
        /// new last part opens another.
        spoiled,
    };

    /// Takes one long-name entry.
    pub fn take(self: *LongName, e: []const u8) void {
        const seq = e[0] & 0x1F;
        // As many parts as a `max_name` name needs, rounded UP.
        if (seq == 0 or seq > (max_name + 12) / 13) {
            self.stands = .spoiled;
            return;
        }
        if (e[0] & 0x40 != 0) { // the last part, which arrives first
            self.len = 0;
            self.sum = e[13];
            self.stands = .collecting;
        } else if (self.stands != .collecting or self.sum != e[13] or seq != self.next) {
            // Parts count down by one to part 1, as Linux and fsck.fat
            // require: one out of turn would put its characters over
            // whatever the buffer held.
            self.stands = .spoiled;
            return;
        }
        self.next = seq - 1;

        const base = (@as(usize, seq) - 1) * 13;
        for (long_offsets, 0..) |off, i| {
            const c = @as(u16, e[off]) | (@as(u16, e[off + 1]) << 8);
            if (c == 0x0000 or c == 0xFFFF) break;
            const at = base + i;
            if (at >= self.buf.len) {
                self.stands = .spoiled;
                return;
            }
            // **ASCII ONLY**: a character past it reads as '?' (and `aliasFor`
            // refuses to write one).
            self.buf[at] = if (c < 128) @intCast(c) else '?';
            if (at + 1 > self.len) self.len = at + 1;
        }
    }

    /// An entry that is no part of a run (deleted, a volume label) ends it.
    pub fn letGo(self: *LongName) void {
        self.stands = .none;
        self.len = 0;
    }

    /// **THE SHORT ENTRY THAT CLOSES THE RUN**, which ends either way: the
    /// long name onto `entry` if the run is whole, its part 1 taken, and its
    /// checksum matches.
    /// A run whose checksum does not match is an orphan, and using it would
    /// put the wrong name on the wrong bytes. Answers whether it was put.
    pub fn close(self: *LongName, entry: *Entry) bool {
        const whole = self.stands == .collecting and self.next == 0 and self.len > 0 and self.sum == shortChecksum(entry.short);
        if (whole) {
            entry.long_len = @intCast(@min(self.len, entry.long.len));
            @memcpy(entry.long[0..entry.long_len], self.buf[0..entry.long_len]);
        }
        self.letGo();
        return whole;
    }

    /// The name so far.
    pub fn text(self: *const LongName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A directory entry's first cluster, both halves: DIR_FstClusLO at 26..28,
/// DIR_FstClusHI at 20..22. On FAT16 the high half is always 0, as the
/// spec wants those bytes there, so one writer serves both kinds.
pub fn putCluster(e: []u8, cluster: Cluster) void {
    e[26] = @truncate(cluster);
    e[27] = @truncate(cluster >> 8);
    e[20] = @truncate(cluster >> 16);
    e[21] = @truncate(cluster >> 24);
}

pub fn putLe16(out: *[2]u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

/// A time field then a date field, as both pairs sit on disk.
pub fn putDos(out: *[4]u8, d: Dos) void {
    putLe16(out[0..2], d.time);
    putLe16(out[2..4], d.date);
}

/// A short entry decoded: the 8.3 name trimmed and dotted. The FAT16 cluster
/// half only; `Volume.entryFrom` adds FAT32's high half.
pub fn decode(e: []const u8) Entry {
    var out: Entry = .{
        .name = @splat(0),
        .name_len = 0,
        .short = e[0..11].*,
        .attr = e[11],
        .first_cluster = le16(e[26..28]),
        .size = le32(e[28..32]),
        .mtime_unix = (Dos{ .time = le16(e[22..24]), .date = le16(e[24..26]) }).toUnix(),
    };
    var n: usize = 0;
    var base: usize = 8;
    while (base > 0 and e[base - 1] == ' ') base -= 1;
    for (e[0..base]) |c| {
        out.name[n] = c;
        n += 1;
    }
    var ext: usize = 11;
    while (ext > 8 and e[ext - 1] == ' ') ext -= 1;
    if (ext > 8) {
        out.name[n] = '.';
        n += 1;
        for (e[8..ext]) |c| {
            out.name[n] = c;
            n += 1;
        }
    }
    out.name_len = @intCast(n);

    // **THE NT CASE BITS** (DIR_NTRes): Windows and mtools store a name that
    // fits 8.3 in one case per part, `topic.md`, as its upper-case alias and
    // no long name; bit 3 says the base was lower case, bit 4 the extension.
    // That name goes in `long`, and a real long name, if found, replaces it.
    // This file writes a long name instead, as Linux's vfat does.
    const lower_base = e[12] & 0x08 != 0;
    const lower_ext = e[12] & 0x10 != 0;
    if (lower_base or lower_ext) {
        for (out.name[0..n], 0..) |c, i| {
            const in_ext = i >= base;
            out.long[i] = if ((in_ext and lower_ext) or (!in_ext and lower_base)) std.ascii.toLower(c) else c;
        }
        out.long_len = @intCast(n);
    }
    return out;
}

/// A name as an 8.3 field: eight of base, three of extension, space padded
/// and upper cased. A name that does not fit is refused, never truncated
/// into a different name.
///
/// **FITTING IS NOT ENOUGH**: `api-key` fits and reads back as `API-KEY`.
/// `needsLongName` decides, by whether the name reads back as itself.
pub fn encode(name: []const u8) error{BadName}![11]u8 {
    var out: [11]u8 = @splat(' ');
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }
    const base = name[0..dot];
    const ext = if (dot < name.len) name[dot + 1 ..] else name[0..0];
    if (base.len == 0 or base.len > 8 or ext.len > 3) return error.BadName;
    for (base, 0..) |c, i| out[i] = upper(c);
    for (ext, 0..) |c, i| out[8 + i] = upper(c);
    return out;
}

/// How many long-name entries a name needs: thirteen characters each.
pub fn longParts(name: []const u8) u32 {
    return @intCast((name.len + 12) / 13);
}

/// Whether a name needs a long name: 8.3 cannot hold it, or would read back
/// differently (any lower-case letter).
pub fn needsLongName(name: []const u8) bool {
    const short = encode(name) catch return true;
    var dotted: [12]u8 = undefined;
    const len = aliasText(short, &dotted);
    return !eqlBytes(dotted[0..len], name);
}

/// An 8.3 field as it reads back: trimmed and dotted.
fn aliasText(short: [11]u8, out: *[12]u8) usize {
    var n: usize = 0;
    var base: usize = 8;
    while (base > 0 and short[base - 1] == ' ') base -= 1;
    for (short[0..base]) |c| {
        out[n] = c;
        n += 1;
    }
    var ext: usize = 11;
    while (ext > 8 and short[ext - 1] == ' ') ext -= 1;
    if (ext > 8) {
        out[n] = '.';
        n += 1;
        for (short[8..ext]) |c| {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

pub fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

pub fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The pure functions: DOS date packing, and long-name parts. The expected
// words are computed by hand from the format; probe/run.sh checks the dates
// against an independent oracle, the Linux VFAT driver.

const testing = std.testing;

test "the fields are packed the way the format says" {
    // 2026-09-17T10:38:52Z: year 46 since 1980, month 9, day 17; hour 10,
    // minute 38, second 52 -> 26 two-second units.
    const d = Dos.fromUnix(1789641532);
    try testing.expectEqual(@as(u16, 46 << 9 | 9 << 5 | 17), d.date);
    try testing.expectEqual(@as(u16, 10 << 11 | 38 << 5 | 26), d.time);
    try testing.expectEqual(@as(i64, 1789641532), d.toUnix());
}

test "an odd second rounds DOWN, and says so on the way back" {
    const d = Dos.fromUnix(1789641533);
    try testing.expectEqual(@as(i64, 1789641532), d.toUnix());
}

test "every two-second instant of a day round-trips" {
    const midnight: i64 = 1789603200; // 2026-09-17T00:00:00Z
    var s: i64 = 0;
    while (s < 86400) : (s += 2) {
        try testing.expectEqual(midnight + s, Dos.fromUnix(midnight + s).toUnix());
    }
}

test "the ends of the range, and past them" {
    try testing.expectEqual(@as(i64, Dos.first_unix), Dos.fromUnix(Dos.first_unix).toUnix());
    try testing.expectEqual(@as(i64, Dos.last_unix - 1), Dos.fromUnix(Dos.last_unix).toUnix());
    // A year the format cannot hold is no date, never a wrapped one.
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.first_unix - 1));
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.last_unix + 1));
    try testing.expectEqual(Dos.none, Dos.fromUnix(0));
    try testing.expectEqual(@as(i64, 0), Dos.none.toUnix());
}

test "a leap day survives both directions" {
    const leap: i64 = 1582934400; // 2020-02-29T00:00:00Z
    const d = Dos.fromUnix(leap);
    try testing.expectEqual(@as(u16, 40 << 9 | 2 << 5 | 29), d.date);
    try testing.expectEqual(leap, d.toUnix());
}

test "garbage on the disk is not a plausible date" {
    // Month 0, month 13, day 0, day 31 of September, hour 31, minute 63: each
    // is a bit pattern a damaged entry can hold, and none is a time.
    const bad = [_]Dos{
        .{ .date = 46 << 9 | 0 << 5 | 17, .time = 0 },
        .{ .date = 46 << 9 | 13 << 5 | 17, .time = 0 },
        .{ .date = 46 << 9 | 9 << 5 | 0, .time = 0 },
        .{ .date = 46 << 9 | 9 << 5 | 31, .time = 0 },
        .{ .date = 46 << 9 | 2 << 5 | 30, .time = 0 }, // February 30th
        .{ .date = 46 << 9 | 9 << 5 | 17, .time = 31 << 11 },
        .{ .date = 46 << 9 | 9 << 5 | 17, .time = 63 << 5 },
    };
    for (bad) |d| try testing.expectEqual(@as(i64, 0), d.toUnix());
}

test "February 29th of a non-leap year is refused" {
    // 2100 is not a leap year; the field can still hold the 29th.
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 120 << 9 | 2 << 5 | 29, .time = 0 }).toUnix());
    // 2000 is, so the same shape 100 years earlier IS a date.
    try testing.expect((Dos{ .date = 20 << 9 | 2 << 5 | 29, .time = 0 }).toUnix() != 0);
}

test "a date of zero is no date, whatever the time field says" {
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 0, .time = 10 << 11 }).toUnix());
}

test "on disk the time word comes first, then the date word" {
    // The two words swapped read back through our own decoder as a date and
    // pass every test above; this catches it.
    const when = Dos.fromUnix(1789641532);
    var e: [dirent_size]u8 = @splat(0);
    putDos(e[22..26], when);
    try testing.expectEqual(when.time, le16(e[22..24]));
    try testing.expectEqual(when.date, le16(e[24..26]));
    try testing.expectEqual(@as(i64, 1789641532), decode(&e).mtime_unix);
}

/// The long-name entries a name is written as, last part first, as they sit
/// in a directory: what `writeEntry` writes, built here for the reader alone.
fn longEntriesFor(name: []const u8, sum: u8, out: [][32]u8) usize {
    const parts = longParts(name);
    var k: usize = 0;
    var seq: usize = parts;
    while (seq >= 1) : (seq -= 1) {
        var e: [32]u8 = @splat(0xFF);
        e[0] = @intCast(seq);
        if (seq == parts) e[0] |= 0x40;
        e[11] = attr_long_name;
        e[12] = 0;
        e[13] = sum;
        e[26] = 0;
        e[27] = 0;
        for (long_offsets, 0..) |off, i| {
            const at = (seq - 1) * 13 + i;
            const c: u16 = if (at < name.len) name[at] else if (at == name.len) 0 else 0xFFFF;
            e[off] = @truncate(c);
            e[off + 1] = @truncate(c >> 8);
        }
        out[k] = e;
        k += 1;
    }
    return k;
}

test "every name the writer accepts, the reader reads back whole" {
    var buf: [max_name]u8 = undefined;
    for (1..max_name + 1) |len| {
        for (buf[0..len], 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
        const name = buf[0..len];
        var entries: [8][32]u8 = undefined;
        const n = longEntriesFor(name, 0x5A, &entries);
        var long: LongName = .{};
        for (entries[0..n]) |*e| long.take(e);
        try testing.expectEqual(LongName.Stands.collecting, long.stands);
        try testing.expectEqualStrings(name, long.text());
    }
}

test "a long-name part numbered 0, or past the parts a max_name name needs, spoils the name it is in" {
    // A name of "ab", written as one part; a part of another number before
    // it on the disk is damage, and the name it opens is not believed.
    var entries: [1][32]u8 = undefined;
    _ = longEntriesFor("ab", 0x5A, &entries);
    for ([_]u8{ 0, (max_name + 12) / 13 + 1 }) |seq| {
        var long: LongName = .{ .stands = .collecting };
        var e = entries[0];
        e[0] = 0x40 | seq;
        long.take(&e);
        try testing.expectEqual(LongName.Stands.spoiled, long.stands);
        try testing.expectEqual(@as(usize, 0), long.len);
    }
}

test "a last part whose thirteen characters run past max_name spoils the name, not the buffer" {
    // The highest part a max_name name has, full: its characters reach past
    // max_name, which no name this filesystem writes does.
    const seq: u8 = (max_name + 12) / 13;
    try testing.expect(@as(usize, seq) * 13 > max_name);
    var e: [32]u8 = @splat(0);
    e[0] = 0x40 | seq;
    e[11] = attr_long_name;
    e[13] = 0x5A;
    for (long_offsets) |off| e[off] = 'z';
    var long: LongName = .{};
    long.take(&e);
    try testing.expectEqual(LongName.Stands.spoiled, long.stands);
}

test "LongName: a name of max_name characters reads back, one of max_name + 1 spoils" {
    var buf: [max_name + 1]u8 = undefined;
    for (&buf, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    // The writer never makes a max_name + 1 name; a rotten disk can. Its
    // parts number the same as max_name's (both 8), so only the buffer
    // check stops it.
    try testing.expectEqual(longParts(buf[0..max_name]), longParts(buf[0 .. max_name + 1]));
    var entries: [8][32]u8 = undefined;
    for ([_]usize{ max_name, max_name + 1 }, [_]LongName.Stands{ .collecting, .spoiled }) |len, want| {
        const n = longEntriesFor(buf[0..len], 0x5A, &entries);
        var long: LongName = .{};
        for (entries[0..n]) |*e| long.take(e);
        try testing.expectEqual(want, long.stands);
        if (want == .collecting) try testing.expectEqualStrings(buf[0..len], long.text());
    }
}

test "longParts: 13·k characters fill k parts, 13·k + 1 need k + 1" {
    const name: [13 * 3 + 1]u8 = @splat('x');
    try testing.expectEqual(@as(u32, 0), longParts(name[0..0]));
    try testing.expectEqual(@as(u32, 1), longParts(name[0..1]));
    for (1..4) |k| {
        try testing.expectEqual(@as(u32, @intCast(k)), longParts(name[0 .. 13 * k]));
        try testing.expectEqual(@as(u32, @intCast(k + 1)), longParts(name[0 .. 13 * k + 1]));
    }
}

test "LongName: 13·k and 13·k + 1 characters read back whole, the last part full or holding one" {
    var buf: [40]u8 = undefined;
    for (&buf, 0..) |*c, i| c.* = 'A' + @as(u8, @intCast(i % 26));
    var entries: [4][32]u8 = undefined;
    for (1..3) |k| {
        for ([_]usize{ 13 * k, 13 * k + 1 }) |len| {
            const n = longEntriesFor(buf[0..len], 0x5A, &entries);
            try testing.expectEqual(longParts(buf[0..len]), @as(u32, @intCast(n)));
            var long: LongName = .{};
            for (entries[0..n]) |*e| long.take(e);
            try testing.expectEqual(LongName.Stands.collecting, long.stands);
            try testing.expectEqualStrings(buf[0..len], long.text());
        }
    }
}

test "LongName: a part numbered (max_name + 12) / 13 is taken, one more spoils" {
    const top: u8 = (max_name + 12) / 13;
    for ([_]u8{ top, top + 1 }, [_]LongName.Stands{ .collecting, .spoiled }) |seq, want| {
        var e: [32]u8 = @splat(0); // a 0x0000 first character: the part holds nothing
        e[0] = 0x40 | seq;
        e[11] = attr_long_name;
        e[13] = 0x5A;
        var long: LongName = .{};
        long.take(&e);
        try testing.expectEqual(want, long.stands);
    }
    // Numbered 1 is the first part; 0 is none.
    for ([_]u8{ 1, 0 }, [_]LongName.Stands{ .collecting, .spoiled }) |seq, want| {
        var e: [32]u8 = @splat(0);
        e[0] = 0x40 | seq;
        e[11] = attr_long_name;
        var long: LongName = .{};
        long.take(&e);
        try testing.expectEqual(want, long.stands);
    }
}

test "encode: a base of 8 fits, 9 does not; an extension of 3 fits, 4 does not" {
    try testing.expectEqualStrings("ABCDEFGHXYZ", &(try encode("abcdefgh.xyz")));
    try testing.expectError(error.BadName, encode("abcdefghi.xyz"));
    try testing.expectError(error.BadName, encode("abcdefgh.wxyz"));
    try testing.expectEqualStrings("ABCDEFGH   ", &(try encode("abcdefgh")));
    try testing.expectError(error.BadName, encode("abcdefghi"));
    // A base of 1 fits, of 0 does not.
    try testing.expectEqualStrings("A          ", &(try encode("a")));
    try testing.expectError(error.BadName, encode(".xyz"));
    // 8.3 at full width needs no long name; one more character does.
    try testing.expect(!needsLongName("ABCDEFGH.XYZ"));
    try testing.expect(needsLongName("ABCDEFGHI.XYZ"));
    try testing.expect(needsLongName("ABCDEFGH.WXYZ"));
}

test "decode: a full 8.3 field reads all twelve bytes, a short one trims at the last space" {
    var e: [dirent_size]u8 = @splat(0);
    @memcpy(e[0..11], "ABCDEFGHXYZ");
    try testing.expectEqualStrings("ABCDEFGH.XYZ", decode(&e).alias());
    @memcpy(e[0..11], "ABCDEFG XY ");
    try testing.expectEqualStrings("ABCDEFG.XY", decode(&e).alias());
    // An extension of one character is dotted; of none, no dot.
    @memcpy(e[0..11], "A       X  ");
    try testing.expectEqualStrings("A.X", decode(&e).alias());
    @memcpy(e[0..11], "A          ");
    try testing.expectEqualStrings("A", decode(&e).alias());
    // All spaces: nothing, never a read before the field.
    @memcpy(e[0..11], "           ");
    try testing.expectEqualStrings("", decode(&e).alias());
}

test "toUnix: the last of each time field is a time, one more is garbage" {
    const date: u16 = 46 << 9 | 9 << 5 | 17; // 2026-09-17
    // Seconds in twos: 29 is 58 seconds, 30 would be 60.
    try testing.expectEqual(@as(i64, 1789603200 + 23 * 3600 + 59 * 60 + 58), (Dos{ .date = date, .time = 23 << 11 | 59 << 5 | 29 }).toUnix());
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = date, .time = 23 << 11 | 59 << 5 | 30 }).toUnix());
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = date, .time = 23 << 11 | 60 << 5 }).toUnix());
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = date, .time = 24 << 11 }).toUnix());
    // The day: September 30th is, 31st is not; month 12 is, 13 is not.
    try testing.expect((Dos{ .date = 46 << 9 | 9 << 5 | 30, .time = 0 }).toUnix() != 0);
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 46 << 9 | 9 << 5 | 31, .time = 0 }).toUnix());
    try testing.expect((Dos{ .date = 46 << 9 | 12 << 5 | 31, .time = 0 }).toUnix() != 0);
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 46 << 9 | 13 << 5 | 1, .time = 0 }).toUnix());
}

test "fromUnix: first_unix and last_unix are dates, a second outside either is none" {
    try testing.expect(!std.meta.eql(Dos.none, Dos.fromUnix(Dos.first_unix)));
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.first_unix - 1));
    const last = Dos.fromUnix(Dos.last_unix);
    try testing.expectEqual(@as(u16, 127 << 9 | 12 << 5 | 31), last.date);
    try testing.expectEqual(@as(u16, 23 << 11 | 59 << 5 | 29), last.time);
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.last_unix + 1));
}

test "LongName.close: a run counted down to part 1 puts its name, one stopped at part 2 does not" {
    // "abcdefghijklmno" is two parts; without part 1 its first thirteen
    // characters are whatever the buffer last held.
    var entries: [2][32]u8 = undefined;
    var entry = decode(&(@as([dirent_size]u8, @splat(' '))));
    _ = longEntriesFor("abcdefghijklmno", shortChecksum(entry.short), &entries);
    for ([_]usize{ 2, 1 }, [_]bool{ true, false }) |taken, put| {
        var long: LongName = .{};
        for (entries[0..taken]) |*e| long.take(e);
        entry.long_len = 0;
        try testing.expectEqual(put, long.close(&entry));
        if (put) try testing.expectEqualStrings("abcdefghijklmno", entry.text());
    }
}

test "LongName: after a last part numbered n, a part numbered n - 1 continues the name, one numbered n + 1 spoils it" {
    // A run of two parts, "abcdefghijklm" + "no", the last part first. A
    // rotten run whose second part is numbered past the first's would put
    // its characters past the name's end, over whatever the buffer held.
    var entries: [2][dirent_size]u8 = undefined;
    _ = longEntriesFor("abcdefghijklmno", 0x5A, &entries);
    try testing.expectEqual(@as(u8, 0x42), entries[0][0]);
    for ([_]u8{ 1, 3 }, [_]LongName.Stands{ .collecting, .spoiled }) |seq, want| {
        var long: LongName = .{};
        long.take(&entries[0]);
        var e = entries[1];
        e[0] = seq;
        long.take(&e);
        try testing.expectEqual(want, long.stands);
    }
}
