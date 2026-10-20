//! **WHEN A CONNECTION IS READY TO BE SERVED** — a question about the bytes it
//! has buffered, and nothing else.
//!
//! The machine answers one request at a time, and a handler that has started
//! runs to the end. So a request is started only once everything it will read
//! is already in memory; until then its connection waits in the table and the
//! others are served. A client that connects and says nothing, or says half a
//! request line and stops, holds nobody up — and neither does one that sends a
//! header saying a hundred bytes are coming and then pauses.
//!
//! **A BODY IS READ BY THE ONE RULE** (angry-gopher's webbox body.zig, which
//! Linux's host reads too; metal-vmm QUEUE 166, 169). The rule comes in as a
//! parameter (`Rule`, the ported body.zig: `router.body_rule` in the kernel),
//! so this file stays a question about bytes. **THE TURN NEVER WAITS ON THE
//! NETWORK**: every body is whole in memory before its request is served.
//! With the route's cap from the head (`limit`):
//!
//!   - **A body refused from its head** (past the route's cap, or framed
//!     twice) is served at once, for the host to refuse.
//!   - **An upload** (a route whose cap is past the rule's
//!     `before_turn_most`) is the host's (`upload`): it asks who is uploading,
//!     gives them a slot, and drains the body into memory.
//!   - **A small body that fits the buffer is waited for in it**: a
//!     Content-Length one until it is all here, a chunked one until its last
//!     chunk (or it is malformed). Its wait is bounded: `wait_ms` from when
//!     the head was whole, the host's to time.
//!   - **A small body that does not fit** (or a chunked one that has filled
//!     the buffer unended) is drained by the host into memory (`drain`),
//!     which reopens the window, and served once whole.
//!   - **`Expect: 100-continue`** for a small body: the host answers it
//!     itself (`must_continue`), and asks again as `continued`.
//!
//! **NOR A HEAD THE WINDOW HAS SHUT ON.** A head that has not ended when the
//! buffer is too full for the peer to send another segment into (tcp.zig's
//! `tight`: a sender avoiding a silly window sends nothing smaller) will not
//! end while it waits. It is served as it is: the handler's reads drain the
//! buffer and reopen the window, so a head that fits ends as any other, and
//! one larger than the buffer is refused by `std.http.Server` as oversized,
//! which the host answers 431, as Linux does. It used to wait out the idle
//! time and be let go with no answer (QUEUE.md item 81, found by
//! probe/fuzz_requests.py).

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const tcp = @import("tcp.zig");

pub const Readiness = enum {
    /// Keep waiting.
    waiting,
    /// Serve it: everything the handler will read is here, or it is refused
    /// from its head.
    ready,
    /// The peer has closed without finishing: serve it anyway, so the host
    /// logs it and lets it go, as it always has.
    abandoned,
    /// The head is whole and asks to be told to send a small body: the host
    /// sends `100 Continue` and asks again, `continued`.
    must_continue,
    /// The head is whole and its small body, which fits, is still coming:
    /// wait, but no longer than `Answer.wait_ms` after the head was whole.
    body_coming,
    /// The head is whole and its small body cannot be waited for in the
    /// buffer: the host drains it into memory (`Answer.head_len`, `read`).
    drain,
    /// The head is whole and asks to upload: the host's (who, a slot, a
    /// drain into memory).
    upload,
};

pub fn Answer(comptime Rule: type) type {
    return struct {
        readiness: Readiness,
        /// For `body_coming` and `drain`: the most the host waits for the
        /// body, from when its head was whole.
        wait_ms: u64 = 0,
        /// For `drain` and `upload`: where the body begins, and what is read.
        head_len: usize = 0,
        read: ?Rule.Read = null,
    };
}

/// What the host knows of the connection besides its bytes.
pub const Known = struct {
    /// It has been sent `100 Continue` already.
    continued: bool = false,
    /// The route's cap on a body, from the head's target (a site's
    /// `bodyLimit`).
    limit: *const fn (target: []const u8) u64,
};

/// `capacity` is the connection's receive buffer — the most that can ever be
/// buffered for it at once. `Rule` is webbox's body.zig.
pub fn check(comptime Rule: type, pending: []const u8, peer_done: bool, capacity: usize, known: Known) Answer(Rule) {
    var parser: std.http.HeadParser = .{};
    const head_len = parser.feed(pending);
    const left = capacity - @min(pending.len, capacity);
    // A buffer too full for the peer to send another segment into.
    const tight = left < @min(@as(usize, tcp.our_mss), capacity / 2);
    if (parser.state != .finished) {
        if (tight) return .{ .readiness = .ready };
        return .{ .readiness = if (peer_done) .abandoned else .waiting };
    }

    // A head std cannot parse is served: the handler rejects it there, with
    // the same words Linux uses.
    const head = std.http.Server.Request.Head.parse(pending[0..head_len]) catch {
        props.reachable(@src(), "ready: a head std cannot parse is served, for the handler to refuse", null);
        return .{ .readiness = .ready };
    };
    const read = switch (Rule.plan(&head, known.limit(head.target))) {
        .none => return .{ .readiness = .ready },
        .refused => {
            props.reachable(@src(), "ready: a body refused from its head is served at once, for the host to refuse", null);
            return .{ .readiness = .ready };
        },
        .upload => |r| {
            props.reachable(@src(), "ready: an upload's head is the host's: who, a slot, a drain", null);
            return .{ .readiness = .upload, .head_len = head_len, .read = r };
        },
        .small => |r| r,
    };
    if (head.expect) |e| if (!known.continued) {
        // Only the expectation std knows is answered here; another is the
        // handler's to refuse.
        if (!std.ascii.eqlIgnoreCase(e, "100-continue")) return .{ .readiness = .ready };
        props.reachable(@src(), "ready: a head asking 100-continue for a small body is told to send it", null);
        return .{ .readiness = .must_continue };
    };
    const body_room = capacity - @min(head_len, capacity);
    const body = pending[head_len..];
    const drain: Answer(Rule) = .{ .readiness = .drain, .wait_ms = read.deadline_ms, .head_len = head_len, .read = read };
    if (head.transfer_encoding == .chunked) {
        switch (Rule.chunkedEnd(body)) {
            .whole => return .{ .readiness = .ready },
            .malformed => {
                props.reachable(@src(), "ready: a malformed chunked body is served, for the handler to refuse", null);
                return .{ .readiness = .ready };
            },
            .partial => {},
        }
        if (tight) {
            props.reachable(@src(), "ready: a chunked body that fills the buffer unended is drained", null);
            return drain;
        }
    } else {
        if (body.len >= read.bytes) return .{ .readiness = .ready };
        if (read.bytes > body_room) {
            props.reachable(@src(), "ready: a body past the buffer is drained into memory", null);
            return drain;
        }
    }
    if (peer_done) return .{ .readiness = .abandoned };
    return .{ .readiness = .body_coming, .wait_ms = read.deadline_ms };
}

const testing = std.testing;
const body_rule = @import("body_rule");

/// The cap every route has in these tests, unless one says otherwise.
fn roomy(_: []const u8) u64 {
    return 1 << 20;
}

/// `check` under webbox's rule, with every route's cap 1 MiB, not continued.
fn ask(pending: []const u8, peer_done: bool, capacity: usize) Readiness {
    return check(body_rule, pending, peer_done, capacity, .{ .limit = roomy }).readiness;
}

/// A connection's buffer, in the tests that do not care how big it is.
const room = 16 * 1024;

test "a whole head with no body is ready" {
    try testing.expectEqual(Readiness.ready, ask("GET / HTTP/1.1\r\nHost: x\r\n\r\n", false, room));
}

test "half a request is not" {
    try testing.expectEqual(Readiness.waiting, ask("GET / HTTP/1.1\r\n", false, room));
    try testing.expectEqual(Readiness.waiting, ask("GET / HTTP/1.1\r\nHost: x\r\n\r", false, room));
    try testing.expectEqual(Readiness.waiting, ask("", false, room));
}

test "a head split exactly at its end is not, until the last byte arrives" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    for (0..head.len) |n| {
        try testing.expectEqual(Readiness.waiting, ask(head[0..n], false, room));
    }
    try testing.expectEqual(Readiness.ready, ask(head, false, room));
}

test "bare newlines end a head too, as std's parser allows" {
    try testing.expectEqual(Readiness.ready, ask("GET / HTTP/1.1\nHost: x\n\n", false, room));
}

test "a head the window has shut on is served, unended: a segment's room or less left" {
    var buf: [room]u8 = undefined;
    const start = "GET / HTTP/1.1\r\nX-Long: ";
    @memcpy(buf[0..start.len], start);
    @memset(buf[start.len..], 'v');
    // Room for a whole segment: the peer can still send, so wait.
    try testing.expectEqual(Readiness.waiting, ask(buf[0 .. room - tcp.our_mss], false, room));
    // Less: a sender avoiding a silly window sends nothing more.
    try testing.expectEqual(Readiness.ready, ask(buf[0 .. room - tcp.our_mss + 1], false, room));
    try testing.expectEqual(Readiness.ready, ask(&buf, false, room));
    try testing.expectEqual(Readiness.ready, ask(&buf, true, room));
}

test "a peer that closed without a whole head is served, to be logged and let go" {
    try testing.expectEqual(Readiness.abandoned, ask("GET / HTTP/1.1\r\n", true, room));
    try testing.expectEqual(Readiness.abandoned, ask("", true, room));
}

test "a peer that closed after a whole head is served as a request" {
    try testing.expectEqual(Readiness.ready, ask("GET / HTTP/1.1\r\n\r\n", true, room));
}

test "garbage that happens to end like a head is served, and std rejects it there" {
    // The judge's "garbage on the wire" step: it must be answered, not held.
    try testing.expectEqual(Readiness.ready, ask("this is not http\r\n\r\n", false, room));
}

const post = "POST /send HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n";

test "a body still arriving is waited for, byte by byte" {
    var buf: [post.len + 10]u8 = undefined;
    @memcpy(buf[0..post.len], post);
    @memcpy(buf[post.len..], "0123456789");
    for (0..10) |n| {
        try testing.expectEqual(Readiness.body_coming, ask(buf[0 .. post.len + n], false, room));
    }
    try testing.expectEqual(Readiness.ready, ask(post ++ "0123456789", false, room));
}

test "more than the body says is ready, and the rest is the next request's problem" {
    try testing.expectEqual(Readiness.ready, ask(post ++ "0123456789GET /", false, room));
}

test "a client that closed part-way through its body is served and let go" {
    try testing.expectEqual(Readiness.abandoned, ask(post ++ "012", true, room));
}

test "a body too big for the buffer is drained into memory by the host, never read in the turn (metal-vmm QUEUE 169)" {
    // Waiting for a body that cannot fit would be waiting for the window to
    // open on its own; the host drains it, which opens it.
    const big = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 40000\r\n\r\n";
    const a = check(body_rule, big, false, room, .{ .limit = roomy });
    try testing.expectEqual(Readiness.drain, a.readiness);
    try testing.expectEqual(big.len, a.head_len);
    try testing.expectEqual(@as(u64, 40000), a.read.?.bytes);
    try testing.expectEqual(body_rule.smallMs(40000), a.wait_ms);
    // One that just fits is still waited for.
    const fits = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 16000\r\n\r\n";
    try testing.expectEqual(Readiness.body_coming, ask(fits, false, room));
    // And one that fits only because the buffer is bigger.
    try testing.expectEqual(Readiness.body_coming, ask(big, false, 64 * 1024));
}

test "an unended head in a small buffer waits with half the buffer left, and is served with one byte less" {
    // Below two segments, `tight`'s bar is half the buffer, not a segment.
    const small = 2000;
    try testing.expect(small / 2 < tcp.our_mss);
    var buf: [small]u8 = undefined;
    const start = "GET / HTTP/1.1\r\nX-Long: ";
    @memcpy(buf[0..start.len], start);
    @memset(buf[start.len..], 'v');
    try testing.expectEqual(Readiness.waiting, ask(buf[0 .. small - small / 2], false, small));
    try testing.expectEqual(Readiness.ready, ask(buf[0 .. small - small / 2 + 1], false, small));
}

test "a body that exactly fills the buffer behind its head is waited for; one byte more is drained" {
    const head_fits = "POST /upload HTTP/1.1\r\nContent-Length: 64\r\n\r\n";
    const head_over = "POST /upload HTTP/1.1\r\nContent-Length: 65\r\n\r\n";
    const capacity = head_fits.len + 64;
    try testing.expectEqual(Readiness.body_coming, ask(head_fits, false, capacity));
    try testing.expectEqual(Readiness.drain, ask(head_over, false, capacity));
    // And the one that fits, arrived whole, fills the buffer to the byte.
    try testing.expectEqual(Readiness.ready, ask(head_fits ++ &@as([64]u8, @splat('v')), false, capacity));
    try testing.expectEqual(Readiness.body_coming, ask(head_fits ++ &@as([63]u8, @splat('v')), false, capacity));
}

test "a head ending at the buffer's last byte is a request; one byte short of its end, it is served unended" {
    const head = "POST /send HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
    try testing.expectEqual(Readiness.ready, ask(head, false, head.len));
    // The buffer full and the head not ended: nothing more can come.
    try testing.expectEqual(Readiness.ready, ask(head[0 .. head.len - 1], false, head.len - 1));
    // A body of one byte behind it can never fit: drained.
    try testing.expectEqual(Readiness.drain, ask("POST /send HTTP/1.1\r\nContent-Length: 1\r\n\r\n", false, head.len));
}

test "a client waiting to be told to send a body that fits is told by the host, then waited for (metal-vmm QUEUE 166)" {
    // **BOTH SIDES WOULD WAIT**, unless the host answers the expectation
    // itself: std.http.Server answers it from inside the handler, so the
    // handler would have to start before the body comes, and the turn would
    // wait on the client.
    const expects = "POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n";
    try testing.expectEqual(Readiness.must_continue, ask(expects, false, room));
    const told: Known = .{ .continued = true, .limit = roomy };
    const coming = check(body_rule, expects, false, room, told);
    try testing.expectEqual(Readiness.body_coming, coming.readiness);
    try testing.expectEqual(body_rule.smallMs(5), coming.wait_ms);
    try testing.expectEqual(Readiness.ready, check(body_rule, expects ++ "hello", false, room, told).readiness);
    // One too big for the buffer: told too, then drained.
    const big = "POST /u HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 40000\r\n\r\n";
    try testing.expectEqual(Readiness.must_continue, ask(big, false, room));
    try testing.expectEqual(Readiness.drain, check(body_rule, big, false, room, told).readiness);
    // An expectation std does not know: served, for the handler to refuse.
    try testing.expectEqual(Readiness.ready, ask("POST /u HTTP/1.1\r\nExpect: tea\r\nContent-Length: 5\r\n\r\n", false, room));
}

test "a chunked body that fits is waited for to its last chunk (metal-vmm QUEUE 166)" {
    const chunked = "POST /send HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const body = "3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n";
    const whole = chunked ++ body;
    for (chunked.len..whole.len) |n| try testing.expectEqual(Readiness.body_coming, ask(whole[0..n], false, room));
    try testing.expectEqual(Readiness.ready, ask(chunked ++ body, false, room));
    // Cut short by a client that closed: abandoned, as a Content-Length one.
    try testing.expectEqual(Readiness.abandoned, ask(chunked ++ "3\r\nhe", true, room));
    // Malformed: served, for the handler to refuse.
    try testing.expectEqual(Readiness.ready, ask(chunked ++ "3\rX", false, room));
    // Its wait is the rule's, sized from the route's cap.
    const a = check(body_rule, chunked, false, room, .{ .limit = roomy });
    try testing.expectEqual(body_rule.smallMs(1 << 20), a.wait_ms);
}

test "a chunked body that fills the buffer without ending is drained" {
    const chunked = "POST /send HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    var buf: [room]u8 = undefined;
    @memcpy(buf[0..chunked.len], chunked);
    const size = "4000\r\n";
    @memcpy(buf[chunked.len..][0..size.len], size);
    @memset(buf[chunked.len + size.len ..], 'v');
    try testing.expectEqual(Readiness.body_coming, ask(buf[0 .. room - tcp.our_mss], false, room));
    try testing.expectEqual(Readiness.drain, ask(buf[0 .. room - tcp.our_mss + 1], false, room));
}

fn uploads(_: []const u8) u64 {
    return 4 << 20;
}

test "an upload's head is the host's, however small its body, before any expectation (metal-vmm QUEUE 169)" {
    const lim: Known = .{ .limit = uploads };
    for ([_][]const u8{
        "POST /up HTTP/1.1\r\nContent-Length: 5\r\n\r\n",
        "POST /up HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello",
        "POST /up HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 3000000\r\n\r\n",
    }) |raw| {
        const a = check(body_rule, raw, false, room, lim);
        try testing.expectEqual(Readiness.upload, a.readiness);
        try testing.expectEqual(body_rule.upload_ms, a.read.?.deadline_ms);
    }
    // Chunked (no length, 411), or past its cap: refused, served at once.
    try testing.expectEqual(Readiness.ready, check(body_rule, "POST /up HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", false, room, lim).readiness);
    try testing.expectEqual(Readiness.ready, check(body_rule, "POST /up HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n", false, room, lim).readiness);
}

fn tiny(_: []const u8) u64 {
    return 4;
}

test "a body refused from its head is served at once, for the host to refuse (metal-vmm QUEUE 167)" {
    const lim: Known = .{ .limit = tiny };
    // Past the route's cap, by its length: never waited for, never continued.
    try testing.expectEqual(Readiness.ready, check(body_rule, "POST /t HTTP/1.1\r\nContent-Length: 5\r\n\r\n", false, room, lim).readiness);
    try testing.expectEqual(Readiness.ready, check(body_rule, "POST /t HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n", false, room, lim).readiness);
    try testing.expectEqual(Readiness.body_coming, check(body_rule, "POST /t HTTP/1.1\r\nContent-Length: 4\r\n\r\n", false, room, lim).readiness);
    // Framed twice.
    try testing.expectEqual(Readiness.ready, ask("POST /t HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", false, room));
}

test "a method that takes no body is ready however it is framed" {
    // std reads no body for a GET, whatever its headers claim, so waiting for
    // one would wait for a read that never happens.
    const get = "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n";
    try testing.expectEqual(Readiness.ready, ask(get, false, room));
}

// **STD'S HEAD PARSER, PINNED AS IT IS** (HEAD-PARSER-BUG.md). A head ended
// by a bare "\n\n" is found or missed by how the bytes are split: fed in
// pieces of 32 bytes or more, a vector holding exactly two CR/LF bytes is
// checked only at its own end. This test fails when an upgraded zig fixes it;
// then probe/fuzz_requests.py's bare-LF allowance and that page can go.
test "std.http.HeadParser misses a bare-LF end in the middle of a vector (a std bug, pinned)" {
    const req = "GET /x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/ \nHost: metal.lynrummy.com\nContent-Length: 1\nContent-Length: 6\n\n\xffGET /version HTTP/1.1\r\nHost: x\r\n\r\n";
    var one_by_one: std.http.HeadParser = .{};
    var at: usize = 0;
    while (one_by_one.state != .finished) : (at += 1) _ = one_by_one.feed(req[at .. at + 1]);
    try testing.expectEqual(@as(usize, 169), at); // the "\n\n" after the headers
    var whole: std.http.HeadParser = .{};
    try testing.expectEqual(@as(usize, req.len), whole.feed(req)); // past it, to the "\r\n\r\n"
}
