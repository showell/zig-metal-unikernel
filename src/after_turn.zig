//! **WHAT BECOMES OF A CONNECTION ONCE ITS HANDLER HAS RETURNED** (metal-vmm
//! QUEUE 198.1, 197.3 #4): the host's decision, pure, so tier 0 holds it.
//! probe/gopher.zig gathers the facts (the flush, the stream the handler
//! asked to keep, the spill, the connection's state, the streams' budget),
//! copies the spill for a kept stream, and does what this says.

/// What the host knows once the handler returned and the response flushed.
pub const Facts = struct {
    /// The handler asked for its stream to be kept.
    kept: bool,
    /// The response flushed into the send queue or the spill.
    flushed: bool,
    /// A write timed out, in the route or in the flush.
    timed_out: bool,
    /// Bytes of the response still in the spill.
    spill_pending: usize,
    /// For a kept stream with a spill: the spill was copied to be its carry.
    /// Ignored otherwise.
    carry_copied: bool,
    /// The connection is still established.
    established: bool,
    /// Streams held now, before this one.
    held_now: usize,
    max_streams: usize,
};

pub const Stream = enum {
    /// No stream was asked for.
    none,
    /// Held; the budget had room.
    keep,
    /// Held, after the oldest held stream is ended to make room.
    keep_displacing_oldest,
    /// Asked for, and let go: the stream ends here.
    drop,
};

pub const Conn = enum {
    /// Held open for its stream.
    stream,
    /// Reset: the client stopped taking the response.
    abandon,
    /// The response's rest is still in the spill: drained, then closed.
    drain,
    close,
};

pub const Disposition = struct {
    stream: Stream,
    conn: Conn,
    /// What the log says, when it says more than the handler's outcome.
    outcome: ?[]const u8 = null,
};

pub fn decide(f: Facts) Disposition {
    var stream: Stream = .none;
    var outcome: ?[]const u8 = null;
    if (!f.flushed) outcome = "the response would not flush";
    if (f.kept) {
        if (!f.flushed) {
            stream = .drop;
        } else if (f.spill_pending > 0 and !f.carry_copied) {
            // Kept, it would send its live frames after a head cut short:
            // ended instead, the response's rest drained as an answer's.
            stream = .drop;
            outcome = "its stream's head would not fit in memory: ended, its response sent";
        } else {
            stream = if (f.held_now >= f.max_streams) .keep_displacing_oldest else .keep;
            outcome = "ok, and its stream is kept";
        }
    }
    if (f.timed_out) outcome = "the client stopped taking the response";
    const held = stream == .keep or stream == .keep_displacing_oldest;
    const conn: Conn = if (held)
        .stream
    else if (f.timed_out)
        .abandon
    else if (f.spill_pending > 0 and f.established)
        .drain
    else
        .close;
    return .{ .stream = stream, .conn = conn, .outcome = outcome };
}

const std = @import("std");
const testing = std.testing;

const plain: Facts = .{ .kept = false, .flushed = true, .timed_out = false, .spill_pending = 0, .carry_copied = false, .established = true, .held_now = 0, .max_streams = 4 };

fn with(comptime changes: anytype) Facts {
    var f = plain;
    inline for (comptime std.meta.fieldNames(@TypeOf(changes))) |field| @field(f, field) = @field(changes, field);
    return f;
}

test "a stream whose head could not be copied is not kept with its head cut: it ends, and its response drains (metal-vmm QUEUE 198.1)" {
    const d = decide(with(.{ .kept = true, .spill_pending = 900, .carry_copied = false }));
    try testing.expectEqual(Stream.drop, d.stream);
    try testing.expectEqual(Conn.drain, d.conn);
    try testing.expectEqualStrings("its stream's head would not fit in memory: ended, its response sent", d.outcome.?);
    // Copied, it is kept, and its connection is the stream's.
    const k = decide(with(.{ .kept = true, .spill_pending = 900, .carry_copied = true }));
    try testing.expectEqual(Stream.keep, k.stream);
    try testing.expectEqual(Conn.stream, k.conn);
}

test "after the handler: every way a connection goes, and what the log says" {
    // Plain answer: closed, the handler's outcome stands.
    try testing.expectEqual(Disposition{ .stream = .none, .conn = .close }, decide(plain));
    // A rest in the spill on a live connection drains; on a dead one, closes.
    try testing.expectEqual(Conn.drain, decide(with(.{ .spill_pending = 1 })).conn);
    try testing.expectEqual(Conn.close, decide(with(.{ .spill_pending = 1, .established = false })).conn);
    // A timed-out write resets, and says so.
    const t = decide(with(.{ .timed_out = true, .spill_pending = 1 }));
    try testing.expectEqual(Conn.abandon, t.conn);
    try testing.expectEqualStrings("the client stopped taking the response", t.outcome.?);
    // Would not flush: the stream asked for is dropped, the connection goes
    // as an answer would.
    const n = decide(with(.{ .kept = true, .flushed = false }));
    try testing.expectEqual(Stream.drop, n.stream);
    try testing.expectEqual(Conn.close, n.conn);
    try testing.expectEqualStrings("the response would not flush", n.outcome.?);
    // A stream with no spill needs no copy, and is kept.
    try testing.expectEqual(Stream.keep, decide(with(.{ .kept = true })).stream);
    // At the budget, the oldest is ended to make room.
    try testing.expectEqual(Stream.keep_displacing_oldest, decide(with(.{ .kept = true, .held_now = 4 })).stream);
    try testing.expectEqualStrings("ok, and its stream is kept", decide(with(.{ .kept = true })).outcome.?);
}
