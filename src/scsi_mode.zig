//! **THE CACHING MODE PAGE, AS PURE LOGIC** (metal-vmm QUEUE 130): what
//! scsi.zig decides from a MODE SENSE answer, pulled out of the driver so it
//! is tested on the host. scsi.zig sends the commands; this reads and
//! builds their bytes, and says what the driver records.

const std = @import("std");

/// The caching page's code (SBC-3 §6.5.5) and the length its second byte
/// gives, past its two-byte head: SBC-3's 20-byte page.
pub const caching_code: u8 = 0x08;
pub const caching_length: u8 = 0x12;

/// The MODE SELECT(10) parameter list for turning the write cache off, built
/// in place over the MODE SENSE(10) answer in `page`, of which the disk sent
/// `got` bytes: the caching page moved up behind a zeroed header (no block
/// descriptors), PS cleared, WCE cleared. Its length, or null when there is
/// nothing safe to send.
///
/// **ONLY WHAT THE DISK SENT, AND ONLY THE PAGE IT MEANT** (metal-vmm QUEUE
/// 130): the page was taken as 20 bytes bounded by the scratch, not by
/// `got`, and its length byte was never looked at. A disk with a short or
/// older page (SCSI-2's is 0x0A) would have been sent the scratch's stale
/// bytes as the rest of it. Now the page must be the caching page, its
/// length 0x12, and all of it inside what the disk sent; anything else is
/// not sent, and the cache is left as the disk says (flushed as before).
pub fn selectList(page: []u8, got: usize) ?u16 {
    if (got < 8 or got > page.len) return null;
    const descriptors = (@as(usize, page[6]) << 8) | page[7];
    const p = 8 + descriptors;
    if (p + 2 > got) return null;
    if (page[p] & 0x3F != caching_code or page[p + 1] != caching_length) return null;
    const page_len: usize = 2 + @as(usize, caching_length);
    if (p + page_len > got) return null;
    std.mem.copyForwards(u8, page[8..][0..page_len], page[p..][0..page_len]);
    @memset(page[0..8], 0);
    page[8] &= 0x3F; // PS is reserved in MODE SELECT
    page[10] &= ~@as(u8, 0x04); // WCE
    return @intCast(8 + page_len);
}

/// **WHAT /admin/host AND THE BOOT LINE SAY OF THE CACHE** (metal-vmm QUEUE
/// 131, kernel-facts #11): derived, every time, from what the disk says now
/// (`write_cache`) and one bit of bring-up (whether it was on then). It was a
/// second stored fact, `cache_turned_off`, kept beside `write_cache` and
/// apart from it: a recheck that could not read the page left it saying
/// "turned off at boot" of a cache nothing could see (QUEUE 130).
pub const Report = enum {
    /// On at bring-up, and off now: boot turned it off (or a recheck after
    /// a reset turned it off again).
    turned_off,
    /// On at bring-up, and on now: it would not turn off.
    would_not_turn_off,
    /// Never on at bring-up, and off now.
    writes_through,
    /// Never on at bring-up, and on now (a reset turned it on, and it would
    /// not turn off again).
    caches,
    /// The disk will not say: flushed as if on.
    unknown,
};

pub fn report(write_cache: ?bool, on_at_bringup: bool) Report {
    const now = write_cache orelse return .unknown;
    if (on_at_bringup) return if (now) .would_not_turn_off else .turned_off;
    return if (now) .caches else .writes_through;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A MODE SENSE(10) answer: an 8-byte header, `descriptors` bytes of block
/// descriptors, then a caching page of `page_len` bytes after its two-byte
/// head, WCE set; the rest of the 512-byte scratch filled with 0xEE, as
/// stale bytes from an earlier command.
fn answer(buf: *[512]u8, descriptors: u16, code: u8, page_len: u8) usize {
    @memset(buf, 0xEE);
    @memset(buf[0..8], 0);
    buf[6] = @truncate(descriptors >> 8);
    buf[7] = @truncate(descriptors);
    const p = 8 + @as(usize, descriptors);
    @memset(buf[8..p], 0);
    buf[p] = 0x80 | code; // PS set, as a savable page says
    buf[p + 1] = page_len;
    @memset(buf[p + 2 ..][0..page_len], 0);
    buf[p + 2] = 0x04; // WCE
    return p + 2 + page_len;
}

test "a caching page as SBC-3 has it (0x12 bytes) is sent back with WCE and PS cleared, behind a zeroed header" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 8, 0x08, 0x12);
    try testing.expectEqual(@as(?u16, 28), selectList(&buf, got));
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), buf[0..8]);
    try testing.expectEqual(@as(u8, 0x08), buf[8]); // PS cleared
    try testing.expectEqual(@as(u8, 0x12), buf[9]);
    try testing.expectEqual(@as(u8, 0), buf[10] & 0x04); // WCE cleared
}

test "a caching page shorter than SBC-3's (SCSI-2's 0x0A) is not sent: the list would carry stale scratch bytes (QUEUE 130)" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 0, 0x08, 0x0A);
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got));
}

test "an answer cut short of its page, or not the caching page, is not sent (QUEUE 130)" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 0, 0x08, 0x12);
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got - 1));
    try testing.expectEqual(@as(?u16, null), selectList(&buf, 7));
    _ = answer(&buf, 0, 0x0A, 0x12); // the control page
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got));
}

test "the cache report is derived from what the disk says now and one bit of bring-up, never a second stored fact (metal-vmm QUEUE 131, kernel-facts #11)" {
    // On at bring-up: turned off (it says off now), or would not turn off.
    try testing.expectEqual(Report.turned_off, report(false, true));
    try testing.expectEqual(Report.would_not_turn_off, report(true, true));
    // Never on at bring-up: as it says now (a reset may have turned it on
    // and a recheck not off).
    try testing.expectEqual(Report.writes_through, report(false, false));
    try testing.expectEqual(Report.caches, report(true, false));
    // A disk that will not say, at bring-up or at a recheck after a reset
    // (QUEUE 130): unknown, never "turned off at boot".
    try testing.expectEqual(Report.unknown, report(null, true));
    try testing.expectEqual(Report.unknown, report(null, false));
}

/// **THE DISK'S OWN MOST IN ONE COMMAND** (metal-vmm QUEUE 180.1): MAXIMUM
/// TRANSFER LENGTH, in sectors, from INQUIRY's Block Limits page (B0h,
/// SBC-3 6.6.3), of which the disk sent `got` bytes. Null where it says
/// nothing: a page too short to hold the field, another page, or 0 (no
/// limit). Virtio-scsi's `max_sectors` is the controller's hint; this is
/// the disk's, which Linux's sd obeys.
pub fn blockLimitsMost(page: []const u8, got: usize) ?u32 {
    // Within what the disk sent, and within the page's own length (bytes
    // 2..3, past its 4-byte head): padding past it is not the field (187.2).
    if (@min(got, page.len) < 4) return null;
    const n = @min(got, page.len, 4 + @as(usize, std.mem.readInt(u16, page[2..4], .big)));
    if (n < 12 or page[1] != 0xB0) return null;
    const most = std.mem.readInt(u32, page[8..12], .big);
    return if (most == 0) null else most;
}

test "Block Limits: the disk's most is read from its page, and nothing is read from a page that does not say it (metal-vmm QUEUE 180.1)" {
    var page: [64]u8 = @splat(0);
    page[1] = 0xB0;
    page[3] = 0x3C;
    std.mem.writeInt(u32, page[8..12], 256, .big);
    try std.testing.expectEqual(@as(?u32, 256), blockLimitsMost(&page, 64));
    // Exactly the field, and one byte short of it.
    try std.testing.expectEqual(@as(?u32, 256), blockLimitsMost(&page, 12));
    try std.testing.expectEqual(@as(?u32, null), blockLimitsMost(&page, 11));
    // Another page, and a limit of 0: nothing said.
    page[1] = 0x83;
    try std.testing.expectEqual(@as(?u32, null), blockLimitsMost(&page, 64));
    page[1] = 0xB0;
    std.mem.writeInt(u32, page[8..12], 0, .big);
    try std.testing.expectEqual(@as(?u32, null), blockLimitsMost(&page, 64));
}

test "Block Limits: what lies past the page's own length is not read as the limit (metal-vmm QUEUE 187.2)" {
    var page: [64]u8 = @splat(0xFF);
    page[1] = 0xB0;
    // A page of 4 bytes past its head, padded: no field there.
    std.mem.writeInt(u16, page[2..4], 4, .big);
    try std.testing.expectEqual(@as(?u32, null), blockLimitsMost(&page, 64));
    // A page whose length just holds the field (8: bytes 4..11).
    std.mem.writeInt(u16, page[2..4], 8, .big);
    std.mem.writeInt(u32, page[8..12], 256, .big);
    try std.testing.expectEqual(@as(?u32, 256), blockLimitsMost(&page, 64));
    std.mem.writeInt(u16, page[2..4], 7, .big);
    try std.testing.expectEqual(@as(?u32, null), blockLimitsMost(&page, 64));
}

/// **A SENSE BUFFER, IN EITHER FORMAT** (SPC-4 §4.5; metal-vmm QUEUE 197.3):
/// fixed (response code 70h/71h: the key in byte 2, ASC and ASCQ in bytes
/// 12 and 13) or descriptor (72h/73h: the key in byte 1, ASC and ASCQ in
/// bytes 2 and 3). It was read as fixed only, so a disk answering in
/// descriptor format had its ILLEGAL REQUEST read as NO SENSE: SYNCHRONIZE
/// never marked it write-through, and a UNIT ATTENTION was never sent again.
/// A buffer too short, or of another code, says nothing.
pub const Sense = struct { key: u8 = 0, asc: u8 = 0, ascq: u8 = 0 };

pub fn senseOf(sense: []const u8) Sense {
    if (sense.len == 0) return .{};
    return switch (sense[0] & 0x7F) {
        0x70, 0x71 => .{
            .key = if (sense.len >= 3) sense[2] & 0x0F else 0,
            .asc = if (sense.len >= 14) sense[12] else 0,
            .ascq = if (sense.len >= 14) sense[13] else 0,
        },
        0x72, 0x73 => if (sense.len >= 4) .{ .key = sense[1] & 0x0F, .asc = sense[2], .ascq = sense[3] } else .{},
        else => .{},
    };
}

test "sense in descriptor format is read as such: ILLEGAL REQUEST and UNIT ATTENTION are not NO SENSE (metal-vmm QUEUE 197.3)" {
    var fixed: [18]u8 = @splat(0);
    fixed[0] = 0x70;
    fixed[2] = 0x05; // ILLEGAL REQUEST
    fixed[12] = 0x20; // invalid command operation code
    fixed[13] = 0x00;
    try std.testing.expectEqual(Sense{ .key = 5, .asc = 0x20, .ascq = 0 }, senseOf(&fixed));
    fixed[0] = 0x71; // deferred, same layout
    try std.testing.expectEqual(Sense{ .key = 5, .asc = 0x20, .ascq = 0 }, senseOf(&fixed));

    const descriptor = [_]u8{ 0x72, 0x06, 0x29, 0x00, 0, 0, 0, 0 }; // UNIT ATTENTION, power on or reset
    try std.testing.expectEqual(Sense{ .key = 6, .asc = 0x29, .ascq = 0 }, senseOf(&descriptor));
    const deferred = [_]u8{ 0x73, 0x05, 0x20, 0x00 };
    try std.testing.expectEqual(Sense{ .key = 5, .asc = 0x20, .ascq = 0 }, senseOf(&deferred));

    // Too short for what it names, or no sense at all: nothing.
    try std.testing.expectEqual(Sense{}, senseOf(&.{}));
    try std.testing.expectEqual(Sense{}, senseOf(&.{ 0x72, 0x06 }));
    try std.testing.expectEqual(Sense{ .key = 5 }, senseOf(fixed[0..3]));
    // A code that is neither format says nothing.
    var vendor = fixed;
    vendor[0] = 0x7F;
    try std.testing.expectEqual(Sense{}, senseOf(&vendor));
}

/// **WCE, FROM A MODE SENSE ANSWER** (metal-vmm QUEUE 198.2): the caching
/// page's WCE bit, or null when the answer (its first `got` bytes; the rest
/// of `page` is stale) is too short or carries no caching page, which
/// `Block.flush` treats as a cache.
pub fn wceOf(page: []const u8, got: usize) ?bool {
    if (got < 8 or got > page.len) return null;
    const descriptors = (@as(usize, page[6]) << 8) | page[7];
    const p = 8 + descriptors;
    if (p + 3 > got or page[p] & 0x3F != 0x08) return null;
    return page[p + 2] & 0x04 != 0;
}

/// What a recheck after a reset leaves (scsi.zig's `recheckCache`).
pub const Recheck = struct { write_cache: ?bool, unflushed: bool, synchronize: bool };

/// **THE CACHE AFTER A RESET** (metal-vmm QUEUE 119, 198.2): `on`, what the
/// disk said first; `taken`, whether it took MODE SELECT; `after`, what it
/// says once asked to turn the cache off. Off for certain: what the cache
/// took meanwhile is synchronized (`synchronize`). Anything else: whatever
/// it holds waits for io.durable's flush (`unflushed`).
pub fn afterReset(on: ?bool, taken: bool, after: ?bool) Recheck {
    if (on != true) return .{ .write_cache = on, .unflushed = false, .synchronize = false };
    if (!taken or after != false) return .{ .write_cache = after, .unflushed = true, .synchronize = false };
    return .{ .write_cache = false, .unflushed = false, .synchronize = true };
}

/// The synchronize after a recheck failed: flushed as if on, before every
/// answer.
pub const after_failed_sync: Recheck = .{ .write_cache = null, .unflushed = true, .synchronize = false };

/// **A COMMAND MET BY UNIT ATTENTION IS SENT AGAIN, THREE TRIES IN ALL**
/// (scsi.zig's `commandSettled`): what to do after try `tries` (from 0).
pub const Retry = enum { done, again, gave_up };
pub const attention_tries = 3;

pub fn retry(tries: u8, attention: bool) Retry {
    if (!attention) return .done;
    return if (tries + 1 >= attention_tries) .gave_up else .again;
}

/// **SYNCHRONIZE CACHE'S ANSWER** (scsi.zig's `synchronize`): GOOD is done;
/// ILLEGAL REQUEST is a disk with no cache to synchronize, written through
/// from then on; anything else failed.
pub const Synced = enum { ok, write_through, failed };

pub fn synced(good: bool, check_condition: bool, key: u8) Synced {
    if (good) return .ok;
    if (check_condition and key == 0x05) return .write_through; // ILLEGAL REQUEST
    return .failed;
}

test "WCE is read from the caching page past any block descriptors, within what the disk sent (metal-vmm QUEUE 198.2)" {
    var page: [40]u8 = @splat(0);
    page[8] = 0x08;
    page[10] = 0x04;
    try std.testing.expectEqual(@as(?bool, true), wceOf(&page, 28));
    page[10] = 0x00;
    try std.testing.expectEqual(@as(?bool, false), wceOf(&page, 28));
    // The PS bit (0x80) set: still the caching page.
    page[8] = 0x88;
    try std.testing.expectEqual(@as(?bool, false), wceOf(&page, 28));
    // Not the caching page, or short of its WCE byte, or no header: nothing.
    page[8] = 0x0A;
    try std.testing.expectEqual(@as(?bool, null), wceOf(&page, 28));
    page[8] = 0x08;
    try std.testing.expectEqual(@as(?bool, null), wceOf(&page, 10));
    try std.testing.expectEqual(@as(?bool, false), wceOf(&page, 11));
    try std.testing.expectEqual(@as(?bool, null), wceOf(&page, 7));
    // Eight bytes of block descriptors: the page is past them.
    page[7] = 8;
    page[16] = 0x08;
    page[18] = 0x04;
    try std.testing.expectEqual(@as(?bool, true), wceOf(&page, 28));
    // Descriptors that push the page past what was sent: nothing.
    page[6] = 1;
    try std.testing.expectEqual(@as(?bool, null), wceOf(&page, 28));
    // A `got` past the buffer is not believed.
    try std.testing.expectEqual(@as(?bool, null), wceOf(page[0..20], 28));
}

test "after a reset: off stays off; on and turned off is synchronized; refused or unknown waits for the flush (metal-vmm QUEUE 198.2)" {
    try std.testing.expectEqual(Recheck{ .write_cache = false, .unflushed = false, .synchronize = false }, afterReset(false, false, null));
    try std.testing.expectEqual(Recheck{ .write_cache = null, .unflushed = false, .synchronize = false }, afterReset(null, false, null));
    try std.testing.expectEqual(Recheck{ .write_cache = false, .unflushed = false, .synchronize = true }, afterReset(true, true, false));
    // Refused: still on, and what it holds is owed a flush.
    try std.testing.expectEqual(Recheck{ .write_cache = true, .unflushed = true, .synchronize = false }, afterReset(true, false, true));
    // Taken, but it still says on; or taken and then it would not say.
    try std.testing.expectEqual(Recheck{ .write_cache = true, .unflushed = true, .synchronize = false }, afterReset(true, true, true));
    try std.testing.expectEqual(Recheck{ .write_cache = null, .unflushed = true, .synchronize = false }, afterReset(true, true, null));
    // Refused though it then says off: not believed as off for certain.
    try std.testing.expectEqual(Recheck{ .write_cache = false, .unflushed = true, .synchronize = false }, afterReset(true, false, false));
}

test "a unit attention is tried three times in all; synchronize's answer read three ways (metal-vmm QUEUE 198.2)" {
    try std.testing.expectEqual(Retry.done, retry(0, false));
    try std.testing.expectEqual(Retry.again, retry(0, true));
    try std.testing.expectEqual(Retry.again, retry(1, true));
    try std.testing.expectEqual(Retry.gave_up, retry(2, true));
    try std.testing.expectEqual(Retry.done, retry(2, false));
    try std.testing.expectEqual(Synced.ok, synced(true, false, 0));
    try std.testing.expectEqual(Synced.write_through, synced(false, true, 0x05));
    try std.testing.expectEqual(Synced.failed, synced(false, true, 0x06));
    try std.testing.expectEqual(Synced.failed, synced(false, false, 0x05));
}
