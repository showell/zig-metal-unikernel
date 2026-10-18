//! **WHAT THE KERNEL DOES WITH A CONNECTION'S BODY BEFORE ITS TURN**, as pure
//! decisions (metal-vmm QUEUE 171): the bytes a connection has buffered, the
//! clock, the upload slots and the small-body budget in; what the loop does
//! next out: wait, send `100 Continue`, ask who is uploading, or serve, and
//! how many buffered bytes it drained into memory (for the loop to consume,
//! reopening the window). The loop (probe/gopher.zig) keeps only the I/O: the
//! table, the queue, the asking, the clock read.
//!
//! **THE TURN NEVER WAITS ON THE NETWORK** (metal-vmm QUEUE 169, webbox's
//! body.zig, the one rule both hosts read; `Rule` is that file, as for
//! ready.zig):
//!
//!   - **A small body that fits the buffer** is waited for there, under its
//!     deadline from when its head was whole (ready.zig says which).
//!   - **A small body that does not fit** is drained into memory: room for
//!     its head and 64 KiB at first, doubling toward its most as bytes come,
//!     every byte of room charged to one budget shared by every small drain
//!     (`budget`, the rule's 64 MiB, 170.3). Past the budget a drain waits,
//!     its window shut, under its deadline.
//!   - **An upload** (a route's cap past the rule's `before_turn_most`): its
//!     asker known first (a stranger is served from the head, the body never
//!     read; an asker that cannot be told, 503), a slot taken (three, one a
//!     human; 30 s of waiting for one, then 503), `100 Continue` sent if
//!     asked, its exact length in memory at once, read under five minutes.
//!   - **A dropped phone** (170.1): an upload with no byte for 30 s gives its
//!     slot back (408), and a human's new upload takes over their old one
//!     (the old one 409), since the page uploads one file at a time.
//!   - **A turn stops the clocks it holds up** (170.2), each by at most its
//!     own length in all (175.1); a stall clock never (`pause`).
//!   - **A full budget is a 503 at once** (175.2), at a drain's beginning or
//!     its growth, as Linux answers it.
//!
//! **THE MEMORY BOUND** (175.3): three uploads at their exact length; the
//! small budget (body.zig's `small_budget`, the one constant), which holds
//! every small drain's room and every head kept to answer from; and, for the
//! moment a drain grows, its old room beside its new (a realloc that cannot
//! grow in place holds both until it copies), at most one drain at a time,
//! so at most the largest room a drain may have past the budget: its head
//! and its body's most, a Content-Length body's 1 MiB, a chunked one's
//! `body.chunkedRawMost` of its cap (1.25 MiB and 4 KiB, metal-vmm QUEUE
//! 177.5: "1 MiB" understated it).
//!
//! Every decision here is a function of what it is handed: no clock but the
//! `now` given, no I/O. So each edge is a unit test (both sides of every
//! boundary in one test, Steve's rule), and drain_sim.zig drives the whole
//! against a model of the slots and the budget over random arrivals.

const std = @import("std");
const ready = @import("ready.zig");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const ns_per_ms = std.time.ns_per_ms;

/// The first room a drain is given past its head; it doubles as bytes come.
pub const first_bytes = 64 * 1024;

/// Why a wait was told the host is busy (metal-vmm QUEUE 177.5): the
/// budget full, memory that did not come, an asker that could not be told,
/// or the slot wait run out. One 503 to the client; the simulator excuses
/// each by its own cause, and a log may say it.
pub const Busy = enum { none, budget, memory, asking, slot_wait };

/// What the host answers a request before its route runs, besides what the
/// head itself refuses.
pub const Verdict = enum {
    none,
    /// An upload by nobody the site knows: served from its head, its body
    /// never read; its route refuses it.
    stranger,
    /// No upload slot came free in time, the asker could not be told, or the
    /// memory for a body did not come.
    busy,
    /// A chunked body past what is kept of one (body.chunkedRawMost).
    too_large,
    /// An upload with no byte for `upload_stall_ms`: a dropped phone.
    stalled,
    /// An upload its human's newer one took the place of (170.1).
    replaced,
};

/// Who is uploading, as the loop learned it (from the store: the asking is
/// I/O, so it is the loop's, asked once).
pub const Who = union(enum) {
    who: u64,
    stranger,
    /// The asking failed: told the host is busy.
    unknown,
};

/// What the loop does with a connection after a decision.
pub const Then = enum {
    /// Not ready: ask again on a later pass.
    wait,
    /// Queue `100 Continue`, and say `continued` once it is queued whole.
    send_continue,
    /// Ask who is uploading (`know`), then decide again.
    ask_who,
    /// Serve it: everything its handler reads is in memory, or the host
    /// refuses it (`refusal`).
    serve,
};

pub const Step = struct {
    /// Buffered bytes moved into the drain: the loop consumes them.
    consumed: usize = 0,
    then: Then,
};

/// What the host refuses before the route, with its status.
pub const Refusal = enum {
    /// The body did not come in time: 408.
    too_slow,
    /// No slot, no memory, no word on the asker: 503.
    busy,
    /// A chunked body past what is kept: 413.
    too_large,
    /// An upload that stopped: 408.
    stalled,
    /// A newer upload by the same human: 409.
    replaced,

    pub fn status(self: Refusal) u16 {
        return switch (self) {
            .too_slow, .stalled => 408,
            .busy => 503,
            .too_large => 413,
            .replaced => 409,
        };
    }
};

/// How the handler reads the body.
pub const Handover = union(enum) {
    /// No drain: std reads the head (and a body that fit) from the buffer.
    network,
    /// Head and body in memory, the body whole to its Content-Length: handed
    /// to the handler as it is (170.5).
    whole: []u8,
    /// Head and body in memory but not to be handed over raw (a chunked one,
    /// still framed; a short one, its client gone): std reads it from memory,
    /// decoding the one and refusing the other.
    memory,
};

/// What the loop knows of a connection, for one decision.
pub const Conn = struct {
    /// Which connection it is: a slot's next connection starts afresh.
    serial: u64,
    /// What is buffered, from where the request begins.
    pending: []const u8,
    /// The client has finished sending.
    peer_done: bool,
    /// The receive buffer's size.
    capacity: usize,
};

pub fn Drains(comptime Rule: type, comptime conns: usize) type {
    return struct {
        const Self = @This();

        /// **A BODY IN MEMORY BEFORE THE TURN**: the request's head and its
        /// body as they came, drained from the connection's buffer.
        pub const Drain = struct {
            /// How a body ends: at its Content-Length, or at its last chunk.
            pub const Framing = enum { length, chunked };

            bytes: []u8,
            len: usize = 0,
            head_len: usize,
            /// A Content-Length body is whole at `head_len + want` bytes; a
            /// chunked one when its last chunk is in.
            framing: Framing,
            want: usize,
            /// The most it may hold, head and body.
            most: usize,
            began: i96,
            deadline_at: i96,
            /// When a byte last came.
            last_progress: i96,
            whole: bool = false,
            /// Its client stopped sending before it was all in: `whole`, so
            /// it is served, but it did not come (194.2).
            cut_short: bool = false,
            /// When it came whole, for the log.
            whole_at: i96 = 0,
            upload: bool,
            /// Its bytes are charged to the small budget (a small body, or a
            /// head kept to be answered from).
            charged: bool,
            /// A chunked body's scan, kept between passes, so each chunk is
            /// parsed once.
            scan: Rule.ChunkedScan = .{},

            pub fn body(d: *const Drain) []u8 {
                return d.bytes[d.head_len..d.len];
            }

            /// **CAME WHOLE, NOT ENDED SHORT** (metal-vmm QUEUE 194.2):
            /// `whole` also marks a body its client stopped sending, so it
            /// is served and its route refuses it; that one did not come.
            pub fn cameWhole(d: *const Drain) bool {
                return d.whole and !d.cut_short;
            }
        };

        /// **WHAT THE HOST KNOWS OF A CONNECTION'S BODY**, kept with its
        /// serial.
        pub const Wait = struct {
            serial: u64 = 0,
            continued: bool = false,
            /// Since when its head was whole while its body was still coming.
            head_at: ?i96 = null,
            late: bool = false,
            drain: ?Drain = null,
            /// **AN UPLOAD, WHETHER OR NOT ITS BODY WAS READ** (metal-vmm
            /// QUEUE 194.1): set as its rule says upload, so one refused
            /// from its head (busy, no memory, an asker unknown, an older
            /// retry's 409, a stranger) is still counted as an upload.
            upload_asked: bool = false,
            slot: ?usize = null,
            /// Since when an uploader has waited for a slot.
            slot_wait_since: ?i96 = null,
            /// What turns may still move its clocks on (`pause`): its running
            /// clock's own length, at most, so a loop busy for hours does not
            /// hold a silent request for hours (metal-vmm QUEUE 175.1).
            credit_left: i96 = 0,
            uploader: ?Who = null,
            /// When it asked who it is, in order (`Drains.asks`): of a
            /// human's uploads, the one that asked last is the retry.
            asked: u64 = 0,
            verdict: Verdict = .none,
            /// With `verdict` busy, why (177.5).
            busy_why: Busy = .none,

            /// The host's refusal before the route, if any. Late is first: a
            /// body that did not come is 408 whatever else was decided.
            pub fn wasUpload(w: *const Wait) bool {
                return w.upload_asked;
            }

            pub fn refusal(w: *const Wait) ?Refusal {
                if (w.late) return .too_slow;
                return switch (w.verdict) {
                    .none, .stranger => null,
                    .busy => .busy,
                    .too_large => .too_large,
                    .stalled => .stalled,
                    .replaced => .replaced,
                };
            }

            pub fn handover(w: *const Wait) Handover {
                const d = w.drain orelse return .network;
                if (w.verdict == .none and d.framing == .length and d.len - d.head_len == d.want) return .{ .whole = d.body() };
                return .memory;
            }

            /// What std reads the request from, when it is in memory.
            pub fn memory(w: *const Wait) ?[]const u8 {
                const d = w.drain orelse return null;
                return d.bytes[0..d.len];
            }

            /// Something keeps this connection: not to be let go as quiet.
            pub fn holds(w: *const Wait) bool {
                return w.head_at != null or w.drain != null or w.slot_wait_since != null;
            }
        };

        gpa: std.mem.Allocator,
        /// The route's cap on a body, from the head's target.
        limit: *const fn (target: []const u8) u64,
        /// The most small drains hold at once (170.3).
        budget: usize = Rule.small_budget,
        waits: [conns]Wait = @splat(.{}),
        slots: Rule.Slots = .{},
        /// The connection reading in each upload slot, and its serial, so a
        /// human's new upload can take over their old one.
        slot_conn: [Rule.upload_slots]?struct { i: usize, serial: u64 } = @splat(null),
        /// What small drains hold now, charged as their room grows.
        charged: usize = 0,
        /// Uploads asked who they are, so far.
        asks: u64 = 0,

        /// Connection `i`'s wait, afresh when the connection is a new one
        /// (its predecessor's memory and slot given back).
        pub fn of(self: *Self, i: usize, serial: u64) *Wait {
            const w = &self.waits[i];
            if (w.serial != serial) {
                self.release(i);
                w.* = .{ .serial = serial };
            }
            return w;
        }

        /// The memory and the slot connection `i`'s body held, given back.
        pub fn release(self: *Self, i: usize) void {
            const w = &self.waits[i];
            if (w.drain) |d| {
                if (d.charged) self.charged -= d.bytes.len;
                self.gpa.free(d.bytes);
                w.drain = null;
            }
            if (w.slot) |slot| {
                self.slots.giveBack(slot);
                self.slot_conn[slot] = null;
                w.slot = null;
            }
        }

        /// The loop queued `100 Continue` whole.
        pub fn continued(self: *Self, i: usize) void {
            self.waits[i].continued = true;
        }

        /// Who is uploading on connection `i`, as the loop learned it.
        pub fn know(self: *Self, i: usize, who: Who) void {
            self.asks += 1;
            self.waits[i].uploader = who;
            self.waits[i].asked = self.asks;
        }

        /// **A TURN STOPS THE CLOCKS IT HOLDS UP** (170.2), **AND NO MORE**
        /// (175.1): every deadline running for a body, a head or a slot moves
        /// on by the turn's length, so an honest body is never late for the
        /// loop's sake, but by at most its own length in all, so turns back
        /// to back (one busy client) cannot hold a silent request for hours.
        /// A stall clock never moves on: a drain always takes what is
        /// buffered (an upload's room is its length; a small one's growth
        /// refused is a 503), so bytes that came in the turn reset it at the
        /// next step, and a dropped phone sends none.
        pub fn pause(self: *Self, turn_ns: i96) void {
            if (turn_ns <= 0) return;
            for (&self.waits) |*w| {
                const credit = @min(turn_ns, w.credit_left);
                w.credit_left -= credit;
                if (w.head_at) |*t| t.* += credit;
                if (w.slot_wait_since) |*t| t.* += credit;
                if (w.drain) |*d| d.deadline_at += credit;
            }
        }

        /// **WHAT NEXT, FOR CONNECTION `i`** (established, unclaimed, its
        /// wait taken with `of` this pass), at `now`.
        pub fn step(self: *Self, i: usize, c: Conn, now: i96) Step {
            const w = &self.waits[i];
            std.debug.assert(w.serial == c.serial);
            if (w.verdict != .none) return .{ .then = .serve };
            if (w.drain) |d| {
                if (d.whole) return .{ .then = .serve };
                return self.stepDrain(i, c, now);
            }
            const got = ready.check(Rule, c.pending, c.peer_done, c.capacity, .{ .continued = w.continued, .limit = self.limit });
            switch (got.readiness) {
                .waiting => return .{ .then = .wait },
                .must_continue => return .{ .then = .send_continue },
                .body_coming => {
                    const since = startWait(w, &w.head_at, now, got.wait_ms);
                    if (now - since < msNs(got.wait_ms)) return .{ .then = .wait };
                    props.reachable(@src(), "drain: a body waited for in the buffer is late", null);
                    w.late = true;
                    return .{ .then = .serve };
                },
                // Late is decided at each pass: a body that came whole while
                // the turn was another's is served, not refused.
                .ready, .abandoned => {
                    w.late = false;
                    return .{ .then = .serve };
                },
                .drain => {
                    const since = startWait(w, &w.head_at, now, got.wait_ms);
                    const parsed = std.http.Server.Request.Head.parse(c.pending[0..got.head_len]) catch return .{ .then = .serve };
                    switch (self.begin(i, got.head_len, got.read.?, framingOf(parsed), self.limit(parsed.target), .small, now, since + msNs(got.wait_ms))) {
                        .begun => {},
                        // **A FULL BUDGET IS A 503, AT ONCE** (175.2), as Linux
                        // answers it (body.zig's small_budget): a wait ran to
                        // a 408 at the deadline, and drains begun starved each
                        // other.
                        .over_budget => {
                            props.reachable(@src(), "drain: a small body finds the budget full, 503", null);
                            return busy(w, .budget);
                        },
                        .no_memory => {
                            props.reachable(@src(), "drain: no memory for a small body's drain", null);
                            return busy(w, .memory);
                        },
                    }
                    return self.stepDrain(i, c, now);
                },
                .upload => return self.upload(i, c, now, got.head_len, got.read.?),
            }
        }

        fn upload(self: *Self, i: usize, c: Conn, now: i96, head_len: usize, read: Rule.Read) Step {
            const w = &self.waits[i];
            w.upload_asked = true;
            const head = c.pending[0..head_len];
            const parsed = std.http.Server.Request.Head.parse(head) catch return .{ .then = .serve };
            if (w.slot == null) {
                const who = switch (w.uploader orelse return .{ .then = .ask_who }) {
                    .who => |k| k,
                    .stranger => return self.headOnly(i, head, .stranger, now),
                    .unknown => {
                        w.busy_why = .asking;
                        return self.headOnly(i, head, .busy, now);
                    },
                };
                const taken = self.slots.take(who);
                switch (taken) {
                    .slot => |slot| {
                        w.slot = slot;
                        self.slot_conn[slot] = .{ .i = i, .serial = w.serial };
                    },
                    .all_busy, .human_has_one => {
                        // **A HUMAN'S NEW UPLOAD TAKES OVER THEIR OLD ONE**
                        // (170.1): the first is told 409, its slot given back
                        // when it is served, and taken on a later pass. New
                        // is by asking: an older retry still waiting when a
                        // newer one took the slot is the one told 409 (171's
                        // simulator: two retries took it from each other).
                        if (taken == .human_has_one) if (self.slots.heldBy(who)) |slot| if (self.slot_conn[slot]) |old| {
                            const ow = &self.waits[old.i];
                            if (old.i != i and ow.serial == old.serial) {
                                if (ow.asked > w.asked) {
                                    props.reachable(@src(), "drain: an older retry finds a newer upload in the slot", null);
                                    return self.headOnly(i, head, .replaced, now);
                                }
                                if (ow.verdict == .none and !(if (ow.drain) |od| od.whole else false)) {
                                    props.reachable(@src(), "drain: a human's retry takes over their upload", null);
                                    ow.verdict = .replaced;
                                }
                            }
                        };
                        const since = startWait(w, &w.slot_wait_since, now, Rule.slot_wait_ms);
                        if (now - since < msNs(Rule.slot_wait_ms)) return .{ .then = .wait };
                        props.reachable(@src(), "drain: an upload waits out the slot wait", null);
                        w.busy_why = .slot_wait;
                        return self.headOnly(i, head, .busy, now);
                    },
                }
            }
            // Only the expectation std knows is answered; another is refused
            // from the head (body.zig, 417) before it gets here.
            if (parsed.expect) |e| if (!w.continued and std.ascii.eqlIgnoreCase(e, "100-continue")) return .{ .then = .send_continue };
            // Its five minutes from its slot, and what turns may add to them.
            if (w.drain == null) w.credit_left = msNs(read.deadline_ms);
            switch (self.begin(i, head_len, read, framingOf(parsed), self.limit(parsed.target), .upload, now, now + msNs(read.deadline_ms))) {
                .begun => {},
                .over_budget => unreachable, // an upload has its slot, and no budget
                .no_memory => {
                    w.busy_why = .memory;
                    return self.headOnly(i, head, .busy, now);
                },
            }
            return self.stepDrain(i, c, now);
        }

        const Begun = enum { begun, over_budget, no_memory };

        /// What a drain holds: a small body, charged to the small budget as it
        /// grows, or an upload, its exact length at once in its own slot.
        const Body = enum { small, upload };

        /// How a request's head says its body ends.
        fn framingOf(head: std.http.Server.Request.Head) Drain.Framing {
            return if (head.transfer_encoding == .chunked) .chunked else .length;
        }

        fn begin(self: *Self, i: usize, head_len: usize, read: Rule.Read, framing: Drain.Framing, cap: u64, body: Body, now: i96, deadline_at: i96) Begun {
            const w = &self.waits[i];
            const is_upload = body == .upload;
            const body_most: u64 = switch (framing) {
                .chunked => Rule.chunkedRawMost(cap),
                .length => read.bytes,
            };
            const most = std.math.add(u64, head_len, body_most) catch return .no_memory;
            if (most > std.math.maxInt(usize)) return .no_memory;
            // An upload's exact length at once: its slot is its bound. A small
            // body grows as it comes, charged as it grows.
            const size: usize = if (is_upload) @intCast(most) else @intCast(@min(most, head_len + first_bytes));
            if (!is_upload and self.charged + size > self.budget) return .over_budget;
            const bytes = self.gpa.alloc(u8, size) catch return .no_memory;
            if (!is_upload) self.charged += bytes.len;
            w.drain = .{
                .bytes = bytes,
                .head_len = head_len,
                .framing = framing,
                .want = @intCast(read.bytes),
                .most = @intCast(most),
                .began = now,
                .deadline_at = deadline_at,
                .last_progress = now,
                .upload = is_upload,
                .charged = !is_upload,
            };
            return .begun;
        }

        /// A drain's room doubled toward its most, a small one's charged to
        /// the budget as it grows. `refused` when the budget or the memory
        /// says no: a 503 (175.2).
        fn grow(self: *Self, d: *Drain) enum { grown, at_most, over_budget, no_memory } {
            if (d.bytes.len >= d.most) return .at_most;
            const next = @min(d.most, d.bytes.len * 2);
            if (d.charged and self.charged + (next - d.bytes.len) > self.budget) {
                props.reachable(@src(), "drain: a small drain's growth finds the budget full, 503", null);
                return .over_budget;
            }
            const grown = self.gpa.realloc(d.bytes, next) catch return .no_memory;
            if (d.charged) self.charged += next - d.bytes.len;
            d.bytes = grown;
            return .grown;
        }

        /// What has arrived of a draining body moved into memory, and whether
        /// it is whole, late, stalled, or past what is kept.
        fn stepDrain(self: *Self, i: usize, c: Conn, now: i96) Step {
            const w = &self.waits[i];
            const d = &w.drain.?;
            if (c.pending.len > d.bytes.len - d.len) switch (self.grow(d)) {
                .grown, .at_most => {},
                .over_budget => return busy(w, .budget),
                .no_memory => return busy(w, .memory),
            };
            const n = @min(c.pending.len, d.bytes.len - d.len);
            if (n > 0) d.last_progress = now;
            @memcpy(d.bytes[d.len..][0..n], c.pending[0..n]);
            d.len += n;
            switch (d.framing) {
                .length => if (d.len - d.head_len >= d.want) {
                    d.whole = true;
                },
                .chunked => switch (d.scan.end(d.bytes[d.head_len..d.len])) {
                    .whole, .malformed => d.whole = true,
                    .partial => if (d.len == d.most) {
                        props.reachable(@src(), "drain: a chunked body passes what is kept", null);
                        w.verdict = .too_large;
                    },
                },
            }
            // The client finished sending without finishing the body: served,
            // its short body refused by its route's read.
            if (!d.whole and w.verdict == .none and c.peer_done and c.pending.len == n) {
                d.whole = true;
                d.cut_short = true;
            }
            if (d.whole) d.whole_at = now;
            w.late = !d.whole and w.verdict == .none and now >= d.deadline_at;
            // **A STALLED UPLOAD GIVES ITS SLOT BACK** (170.1): no byte for
            // the stall time is a dropped phone, which sends no FIN.
            if (d.upload and !d.whole and w.verdict == .none and now - d.last_progress >= msNs(Rule.upload_stall_ms)) {
                props.reachable(@src(), "drain: an upload stalls", null);
                w.verdict = .stalled;
            }
            if (w.late) props.reachable(@src(), "drain: a drained body is late", null);
            const ready_now = d.whole or w.verdict != .none or w.late;
            return .{ .consumed = n, .then = if (ready_now) .serve else .wait };
        }

        /// Told the host is busy, and why (177.5).
        fn busy(w: *Wait, why: Busy) Step {
            w.verdict = .busy;
            w.busy_why = why;
            return .{ .then = .serve };
        }

        /// A request to be answered from its head alone (its body never
        /// read): the head kept in memory, the verdict said.
        fn headOnly(self: *Self, i: usize, head: []const u8, verdict: Verdict, now: i96) Step {
            const w = &self.waits[i];
            // Held to the budget too (175.3): past it, a 503 with nothing
            // kept, answered before any route could read the network.
            if (self.charged + head.len > self.budget) {
                props.reachable(@src(), "drain: a head to answer from finds the budget full, 503", null);
                return busy(w, .budget);
            }
            const bytes = self.gpa.dupe(u8, head) catch {
                // No memory for even the head: told the host is busy, before
                // any route could read a body from the network.
                return busy(w, .memory);
            };
            w.verdict = verdict;
            self.charged += bytes.len;
            w.drain = .{ .bytes = bytes, .len = bytes.len, .head_len = bytes.len, .framing = .length, .want = 0, .most = bytes.len, .began = now, .deadline_at = now, .last_progress = now, .whole = true, .whole_at = now, .upload = w.upload_asked, .charged = true };
            return .{ .then = .serve };
        }
    };
}

fn msNs(n: u64) i96 {
    return @as(i96, n) * ns_per_ms;
}

/// A wait's clock started at `now` if it has none, with turns allowed to
/// move it on by at most `credit_ms` (175.1); when it started.
fn startWait(w: anytype, at: *?i96, now: i96, credit_ms: u64) i96 {
    if (at.*) |t| return t;
    at.* = now;
    w.credit_left = msNs(credit_ms);
    return now;
}

// ── the edges, each from both sides (Steve's rule from the off-by-one hunt) ──

const testing = std.testing;
const body_rule = @import("body_rule");
const TestDrains = Drains(body_rule, 70);

/// Routes as the tests have them: `/up…` an upload (101 MiB), `/doc…` the
/// largest small body (1 MiB), every other 64 KiB.
fn caps(target: []const u8) u64 {
    if (std.mem.startsWith(u8, target, "/up")) return 101 << 20;
    if (std.mem.startsWith(u8, target, "/doc")) return body_rule.before_turn_most;
    return 64 << 10;
}

fn ms(n: i96) i96 {
    return n * ns_per_ms;
}

/// A request: its head (a Content-Length, or chunked; `extra` header lines)
/// and its body.
fn request(target: []const u8, length: ?usize, extra: []const u8, body: []const u8) ![]u8 {
    const framing = if (length) |n|
        try std.fmt.allocPrint(testing.allocator, "Content-Length: {d}\r\n", .{n})
    else
        try testing.allocator.dupe(u8, "Transfer-Encoding: chunked\r\n");
    defer testing.allocator.free(framing);
    return std.fmt.allocPrint(testing.allocator, "POST {s} HTTP/1.1\r\nHost: x\r\n{s}{s}\r\n{s}", .{ target, framing, extra, body });
}

fn headLen(bytes: []const u8) usize {
    var p: std.http.HeadParser = .{};
    return p.feed(bytes);
}

/// A body of `n` bytes, each its offset's low byte, so a byte out of place
/// shows.
fn pattern(n: usize) ![]u8 {
    const b = try testing.allocator.alloc(u8, n);
    for (b, 0..) |*x, k| x.* = @truncate(k);
    return b;
}

/// A client on connection `i`: the bytes it means to send, how many have
/// arrived (`sent`), and how many the host has taken from the buffer, which
/// holds at most `capacity` of them.
const Client = struct {
    i: usize,
    serial: u64,
    bytes: []const u8,
    sent: usize = 0,
    taken: usize = 0,
    capacity: usize = 16 * 1024,
    done: bool = false,

    fn pending(c: *const Client) []const u8 {
        return c.bytes[c.taken..@min(c.sent, c.taken + c.capacity)];
    }

    /// Its FIN has come: TCP takes it in order, after every byte before it
    /// is in the buffer.
    fn finished(c: *const Client) bool {
        return c.done and c.sent == c.bytes.len and c.sent <= c.taken + c.capacity;
    }

    fn step(c: *Client, d: *TestDrains, now: i96) Then {
        _ = d.of(c.i, c.serial);
        const s = d.step(c.i, .{ .serial = c.serial, .pending = c.pending(), .peer_done = c.finished(), .capacity = c.capacity }, now);
        c.taken += s.consumed;
        return s.then;
    }

    /// Steps at `now` until it is served or waits with nothing taken.
    fn settle(c: *Client, d: *TestDrains, now: i96) Then {
        while (true) {
            const before = c.taken;
            const then = c.step(d, now);
            if (then != .wait or c.taken == before) return then;
        }
    }

    /// An upload's first steps: asked who, told, then stepped.
    fn upload(c: *Client, d: *TestDrains, who: Who, now: i96) Then {
        if (c.step(d, now) != .ask_who) return .serve;
        d.know(c.i, who);
        return c.settle(d, now);
    }
};

test "a drain's deadline: its last nanosecond waits, the deadline itself is late (408)" {
    const body = try pattern(100_000);
    defer testing.allocator.free(body);
    const req = try request("/doc", body.len, "", body);
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer d.release(0);
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = headLen(req) + 1000 };
    const t0 = ms(1000);
    try testing.expectEqual(Then.wait, c.settle(&d, t0));
    try testing.expect(d.waits[0].drain != null);
    const deadline = t0 + ms(body_rule.smallMs(body.len));
    try testing.expectEqual(Then.wait, c.step(&d, deadline - ms(1)));
    try testing.expectEqual(Then.wait, c.step(&d, deadline - 1));
    try testing.expectEqual(@as(?Refusal, null), d.waits[0].refusal());
    try testing.expectEqual(Then.serve, c.step(&d, deadline));
    try testing.expectEqual(Refusal.too_slow, d.waits[0].refusal().?);
    try testing.expectEqual(@as(u16, 408), d.waits[0].refusal().?.status());
}

test "a body waited for in the buffer: its last nanosecond waits, the deadline is late, and a body whole by then is served" {
    const req = try request("/x", 100, "", "a" ** 100);
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = headLen(req) + 10 };
    const t0 = ms(50);
    try testing.expectEqual(Then.wait, c.step(&d, t0));
    const deadline = t0 + ms(body_rule.smallMs(100));
    try testing.expectEqual(Then.wait, c.step(&d, deadline - 1));
    try testing.expectEqual(Then.serve, c.step(&d, deadline));
    try testing.expectEqual(Refusal.too_slow, d.waits[0].refusal().?);
    // Its body comes whole before its turn: served, not refused.
    c.sent = req.len;
    try testing.expectEqual(Then.serve, c.step(&d, deadline + 1));
    try testing.expectEqual(@as(?Refusal, null), d.waits[0].refusal());
    try testing.expect(d.waits[0].handover() == .network);
}

test "a body exactly the largest small cap is drained whole and handed over; one byte more is refused from its head" {
    const at_cap = try pattern(body_rule.before_turn_most);
    defer testing.allocator.free(at_cap);
    const req = try request("/doc", at_cap.len, "", at_cap);
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer d.release(0);
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len, .capacity = 64 * 1024 };
    try testing.expectEqual(Then.serve, c.settle(&d, 0));
    const w = &d.waits[0];
    try testing.expectEqual(@as(?Refusal, null), w.refusal());
    try testing.expectEqualSlices(u8, at_cap, w.handover().whole);
    try testing.expectEqual(req.len, c.taken);

    const past = try request("/doc", at_cap.len + 1, "", "");
    defer testing.allocator.free(past);
    var c2: Client = .{ .i = 1, .serial = 2, .bytes = past, .sent = past.len };
    try testing.expectEqual(Then.serve, c2.step(&d, 0));
    try testing.expect(d.waits[1].drain == null);
    const head = try std.http.Server.Request.Head.parse(past);
    try testing.expectEqual(body_rule.Refusal.too_large, body_rule.plan(&head, caps(head.target)).refused);
}

/// A chunked body of one chunk of `n` bytes and the last chunk.
fn oneChunk(n: usize) ![]u8 {
    const data = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(data);
    @memset(data, 'c');
    return std.fmt.allocPrint(testing.allocator, "{x}\r\n{s}\r\n0\r\n\r\n", .{ n, data });
}

test "a chunked drain exactly what is kept of one ends whole; one byte more is 413" {
    const most = body_rule.chunkedRawMost(caps("/x"));
    // One chunk's size line (5 hex digits), its CRLF, and "0\r\n\r\n": 14.
    inline for (.{ 0, 1 }) |over| {
        const body = try oneChunk(@intCast(most - 14 + over));
        defer testing.allocator.free(body);
        try testing.expectEqual(most + over, body.len);
        const req = try request("/x", null, "", body);
        defer testing.allocator.free(req);
        var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
        defer d.release(0);
        var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len, .capacity = 2048 };
        try testing.expectEqual(Then.serve, c.settle(&d, 0));
        const w = &d.waits[0];
        if (over == 0) {
            try testing.expect(w.drain.?.whole);
            try testing.expectEqual(@as(?Refusal, null), w.refusal());
            // Chunked: std decodes it from memory, never handed over framed.
            try testing.expect(w.handover() == .memory);
        } else {
            try testing.expectEqual(Refusal.too_large, w.refusal().?);
            try testing.expectEqual(@as(u16, 413), w.refusal().?.status());
        }
    }
}

test "a chunk ending at the buffer's edge: parsed once, then the rest; the last CRLF's last byte is the end" {
    const chunk = "400\r\n" ++ "k" ** 0x400 ++ "\r\n";
    const body = chunk ++ chunk ++ chunk ++ "0\r\n\r\n";
    const req = try request("/x", null, "", body);
    defer testing.allocator.free(req);
    const h = headLen(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer d.release(0);
    // A buffer filled unended: drained.
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len, .capacity = 1024 };
    try testing.expectEqual(Then.wait, c.step(&d, 0));
    try testing.expectEqual(@as(usize, 1024), c.taken);
    // The buffer's edge exactly at the first chunk's CRLF: that chunk is
    // scanned, and no further.
    c.sent = h + chunk.len;
    try testing.expectEqual(Then.wait, c.settle(&d, 0));
    try testing.expectEqual(chunk.len, d.waits[0].drain.?.scan.at);
    // One byte short of the second's CRLF: still the first.
    c.sent = h + 2 * chunk.len - 1;
    try testing.expectEqual(Then.wait, c.settle(&d, 0));
    try testing.expectEqual(chunk.len, d.waits[0].drain.?.scan.at);
    // All but the very last byte: not whole.
    c.sent = req.len - 1;
    try testing.expectEqual(Then.wait, c.settle(&d, 0));
    try testing.expect(!d.waits[0].drain.?.whole);
    c.sent = req.len;
    try testing.expectEqual(Then.serve, c.settle(&d, 0));
    try testing.expect(d.waits[0].drain.?.whole);
    try testing.expectEqualStrings(body, d.waits[0].drain.?.body());
}

test "an upload's stall: 29,999 ms without a byte waits, 30,000 is 408 and its slot comes back; a byte resets it" {
    const body = try pattern(10_000);
    defer testing.allocator.free(body);
    const req = try request("/up", body.len, "", body);
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = headLen(req) + 100 };
    const t0 = ms(7);
    try testing.expectEqual(Then.wait, c.upload(&d, .{ .who = 1 }, t0));
    // Its exact length at once.
    try testing.expectEqual(req.len, d.waits[0].drain.?.bytes.len);
    try testing.expectEqual(@as(usize, 0), d.charged);
    try testing.expectEqual(@as(usize, 1), d.slots.inUse());
    // A byte at 20 s: the stall counts from there.
    c.sent += 1;
    try testing.expectEqual(Then.wait, c.step(&d, t0 + ms(20_000)));
    try testing.expectEqual(Then.wait, c.step(&d, t0 + ms(20_000 + 29_999)));
    try testing.expectEqual(Then.serve, c.step(&d, t0 + ms(20_000 + 30_000)));
    try testing.expectEqual(Refusal.stalled, d.waits[0].refusal().?);
    try testing.expectEqual(@as(u16, 408), d.waits[0].refusal().?.status());
    d.release(0);
    try testing.expectEqual(@as(usize, 0), d.slots.inUse());
}

test "a human's second upload takes over the first, with slots free and with none; another human waits 29,999 ms, and at 30,000 is 503" {
    const req = try request("/up", 10, "", "");
    defer testing.allocator.free(req);
    const sent = req.len; // heads only: their bodies never come
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..6) |k| d.release(k);

    // Slots free: human 1 holds one of three, then uploads again.
    var a1: Client = .{ .i = 0, .serial = 10, .bytes = req, .sent = sent };
    try testing.expectEqual(Then.wait, a1.upload(&d, .{ .who = 1 }, 0));
    var a2: Client = .{ .i = 1, .serial = 11, .bytes = req, .sent = sent };
    try testing.expectEqual(Then.wait, a2.upload(&d, .{ .who = 1 }, ms(1)));
    try testing.expectEqual(Then.serve, a1.step(&d, ms(1)));
    try testing.expectEqual(Refusal.replaced, d.waits[0].refusal().?);
    try testing.expectEqual(@as(u16, 409), d.waits[0].refusal().?.status());
    // Until the first is served, the second waits; then it has the slot.
    try testing.expectEqual(Then.wait, a2.step(&d, ms(2)));
    try testing.expect(d.waits[1].slot == null);
    d.release(0);
    try testing.expectEqual(Then.wait, a2.step(&d, ms(3)));
    try testing.expect(d.waits[1].slot != null);

    // No slot free: humans 2 and 3 take the others; human 1 again takes over
    // their own, and human 4 waits for one, nobody replaced.
    var b: Client = .{ .i = 2, .serial = 12, .bytes = req, .sent = sent };
    var c: Client = .{ .i = 3, .serial = 13, .bytes = req, .sent = sent };
    _ = b.upload(&d, .{ .who = 2 }, ms(3));
    _ = c.upload(&d, .{ .who = 3 }, ms(3));
    try testing.expectEqual(@as(usize, 3), d.slots.inUse());
    var a3: Client = .{ .i = 4, .serial = 14, .bytes = req, .sent = sent };
    try testing.expectEqual(Then.wait, a3.upload(&d, .{ .who = 1 }, ms(4)));
    try testing.expectEqual(Verdict.replaced, d.waits[1].verdict);
    var e: Client = .{ .i = 5, .serial = 15, .bytes = req, .sent = sent };
    const t0 = ms(5);
    try testing.expectEqual(Then.wait, e.upload(&d, .{ .who = 4 }, t0));
    try testing.expectEqual(Verdict.none, d.waits[2].verdict);
    try testing.expectEqual(Verdict.none, d.waits[3].verdict);
    try testing.expectEqual(Then.wait, e.step(&d, t0 + ms(body_rule.slot_wait_ms) - 1));
    try testing.expectEqual(Then.serve, e.step(&d, t0 + ms(body_rule.slot_wait_ms)));
    try testing.expectEqual(Refusal.busy, d.waits[5].refusal().?);
    try testing.expectEqual(@as(u16, 503), d.waits[5].refusal().?.status());
}

test "an upload whole already is not taken over: it is served, and the retry waits for its slot" {
    const req = try request("/up", 4, "", "body");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..2) |k| d.release(k);
    var a1: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, a1.upload(&d, .{ .who = 1 }, 0));
    var a2: Client = .{ .i = 1, .serial = 2, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.wait, a2.upload(&d, .{ .who = 1 }, 0));
    try testing.expectEqual(Verdict.none, d.waits[0].verdict);
    try testing.expectEqualStrings("body", d.waits[0].handover().whole);
}

test "a takeover never reaches the connection that came after the old one" {
    const req = try request("/up", 10, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..2) |k| d.release(k);
    var a1: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    _ = a1.upload(&d, .{ .who = 1 }, 0);
    // Connection 0's slot is reused by a new connection, its wait not yet
    // renewed (the loop renews it on its pass): the slot still says serial 1.
    d.waits[0].serial = 99;
    var a2: Client = .{ .i = 1, .serial = 2, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.wait, a2.upload(&d, .{ .who = 1 }, 0));
    try testing.expectEqual(Verdict.none, d.waits[0].verdict);
}

/// Fills `d` with `n` small drains of `most` bytes each, head and body, all
/// whole, from connection `first` on.
fn fillDrains(d: *TestDrains, first: usize, n: usize, most: usize, body: []const u8) !void {
    // The head's length with a 7-digit length, then the length that makes
    // head and body `most`.
    const probe_head = try request("/doc", 1_000_000, "", "");
    defer testing.allocator.free(probe_head);
    const length = most - probe_head.len;
    const req = try request("/doc", length, "", body[0..length]);
    defer testing.allocator.free(req);
    try testing.expectEqual(most, req.len);
    for (first..first + n) |k| {
        var c: Client = .{ .i = k, .serial = k + 1, .bytes = req, .sent = req.len, .capacity = 64 * 1024 };
        try testing.expectEqual(Then.serve, c.settle(d, 0));
        try testing.expect(d.waits[k].drain.?.whole);
    }
}

test "the small budget charged to exactly 64 MiB is met; one byte more is 503 (metal-vmm QUEUE 175.2)" {
    const mib = 1 << 20;
    const body = try pattern(mib + 1);
    defer testing.allocator.free(body);
    {
        var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
        defer for (0..65) |k| d.release(k);
        try fillDrains(&d, 0, 64, mib, body);
        try testing.expectEqual(@as(usize, body_rule.small_budget), d.charged);
        // A 65th waits to begin.
        const req = try request("/doc", 100_000, "", body[0..100_000]);
        defer testing.allocator.free(req);
        var c: Client = .{ .i = 64, .serial = 65, .bytes = req, .sent = req.len };
        try testing.expectEqual(Then.serve, c.step(&d, 0));
        try testing.expectEqual(Refusal.busy, d.waits[64].refusal().?);
        try testing.expect(d.waits[64].drain == null);
        try testing.expectEqual(@as(usize, body_rule.small_budget), d.charged);
    }
    {
        var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
        defer for (0..64) |k| d.release(k);
        try fillDrains(&d, 0, 63, mib, body);
        // The 64th is a byte more: its last growth would charge 64 MiB + 1.
        const probe_head = try request("/doc", 1_000_000, "", "");
        defer testing.allocator.free(probe_head);
        const length = mib + 1 - probe_head.len;
        const req = try request("/doc", length, "", body[0..length]);
        defer testing.allocator.free(req);
        var c: Client = .{ .i = 63, .serial = 64, .bytes = req, .sent = req.len, .capacity = 64 * 1024 };
        try testing.expectEqual(Then.serve, c.settle(&d, 0));
        const w = &d.waits[63];
        try testing.expectEqual(Refusal.busy, w.refusal().?);
        try testing.expect(d.charged <= body_rule.small_budget);
        try testing.expect(w.drain.?.bytes.len < mib + 1);
    }
}

test "a turn's length moves a drain's deadline and a slot's wait on, and a stall only when bytes waited (metal-vmm QUEUE 170.2, 175.1)" {
    const body = try pattern(100_000);
    defer testing.allocator.free(body);
    const doc = try request("/doc", body.len, "", body);
    defer testing.allocator.free(doc);
    const up = try request("/up", body.len, "", body);
    defer testing.allocator.free(up);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..5) |k| d.release(k);
    var s: Client = .{ .i = 0, .serial = 1, .bytes = doc, .sent = headLen(doc) + 10 };
    var u: Client = .{ .i = 1, .serial = 2, .bytes = up, .sent = headLen(up) + 10 };
    var f2: Client = .{ .i = 2, .serial = 3, .bytes = up, .sent = headLen(up) };
    var f3: Client = .{ .i = 3, .serial = 4, .bytes = up, .sent = headLen(up) };
    var v: Client = .{ .i = 4, .serial = 5, .bytes = up, .sent = headLen(up) };
    try testing.expectEqual(Then.wait, s.settle(&d, 0));
    try testing.expectEqual(Then.wait, u.upload(&d, .{ .who = 1 }, 0));
    _ = f2.upload(&d, .{ .who = 2 }, 0);
    _ = f3.upload(&d, .{ .who = 3 }, 0);
    // Every slot held: human 4 waits for one.
    try testing.expectEqual(Then.wait, v.upload(&d, .{ .who = 4 }, 0));
    const turn = ms(5_000);
    d.pause(turn);
    const deadline = ms(body_rule.smallMs(body.len)) + turn;
    try testing.expectEqual(Then.wait, s.step(&d, deadline - 1));
    try testing.expectEqual(Then.serve, s.step(&d, deadline));
    // Nothing waited to be taken: its stall clock is the wall's (175.1).
    try testing.expectEqual(Then.wait, u.step(&d, ms(body_rule.upload_stall_ms) - 1));
    try testing.expectEqual(Then.serve, u.step(&d, ms(body_rule.upload_stall_ms)));
    try testing.expectEqual(Refusal.stalled, d.waits[1].refusal().?);
    try testing.expectEqual(Then.wait, v.step(&d, ms(body_rule.slot_wait_ms) + turn - 1));
    try testing.expectEqual(Then.serve, v.step(&d, ms(body_rule.slot_wait_ms) + turn));
    try testing.expectEqual(Refusal.busy, d.waits[4].refusal().?);
}

test "a stranger's upload is served from its head, its body never read; an asker that cannot be told is 503" {
    const req = try request("/up", 10_000, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    var s: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, s.upload(&d, .stranger, 0));
    const w = &d.waits[0];
    try testing.expectEqual(Verdict.stranger, w.verdict);
    try testing.expectEqual(@as(?Refusal, null), w.refusal());
    try testing.expectEqualStrings(req, w.memory().?);
    try testing.expect(w.handover() == .memory);
    try testing.expect(w.slot == null);
    try testing.expectEqual(@as(usize, 0), s.taken);
    d.release(0);
    try testing.expectEqual(@as(usize, 0), d.charged);
    var u: Client = .{ .i = 1, .serial = 2, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, u.upload(&d, .unknown, 0));
    try testing.expectEqual(Refusal.busy, d.waits[1].refusal().?);
    d.release(1);
}

test "100-continue: asked once, for a small body and for an upload (after its slot)" {
    const small = try request("/doc", 100_000, "Expect: 100-continue\r\n", "");
    defer testing.allocator.free(small);
    const up = try request("/up", 100_000, "Expect: 100-continue\r\n", "");
    defer testing.allocator.free(up);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..2) |k| d.release(k);
    var s: Client = .{ .i = 0, .serial = 1, .bytes = small, .sent = small.len };
    try testing.expectEqual(Then.send_continue, s.step(&d, 0));
    d.continued(0);
    try testing.expectEqual(Then.wait, s.settle(&d, 0));
    try testing.expect(d.waits[0].drain != null);
    var u: Client = .{ .i = 1, .serial = 2, .bytes = up, .sent = up.len };
    try testing.expectEqual(Then.ask_who, u.step(&d, 0));
    d.know(1, .{ .who = 7 });
    try testing.expectEqual(Then.send_continue, u.step(&d, 0));
    try testing.expect(d.waits[1].slot != null);
    d.continued(1);
    try testing.expectEqual(Then.wait, u.settle(&d, 0));
    try testing.expect(d.waits[1].drain != null);
}

test "no memory for an upload, nor for its head: 503, and the slot comes back when it is served" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const req = try request("/up", 10_000, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = failing.allocator(), .limit = caps };
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, c.upload(&d, .{ .who = 1 }, 0));
    try testing.expectEqual(Refusal.busy, d.waits[0].refusal().?);
    try testing.expect(d.waits[0].drain == null);
    try testing.expect(d.waits[0].handover() == .network);
    d.release(0);
    try testing.expectEqual(@as(usize, 0), d.slots.inUse());
}

test "a client that stopped short: whole as it is, never handed over raw" {
    const body = try pattern(100_000);
    defer testing.allocator.free(body);
    const req = try request("/doc", body.len, "", body);
    defer testing.allocator.free(req);
    const short = req[0 .. req.len - 50_000];
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer d.release(0);
    var c: Client = .{ .i = 0, .serial = 1, .bytes = short, .sent = short.len, .done = true };
    try testing.expectEqual(Then.serve, c.settle(&d, 0));
    try testing.expect(d.waits[0].handover() == .memory);
    try testing.expectEqual(short.len, d.waits[0].memory().?.len);
}

test "a new connection on the same slot of the table: its predecessor's memory and slot given back" {
    const req = try request("/up", 10_000, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    _ = c.upload(&d, .{ .who = 1 }, 0);
    try testing.expectEqual(@as(usize, 1), d.slots.inUse());
    _ = d.of(0, 2);
    try testing.expectEqual(@as(usize, 0), d.slots.inUse());
    try testing.expect(d.waits[0].drain == null);
}

test "a human's older retry, still waiting, never takes over their newest upload: it is the one told 409" {
    const req = try request("/up", 10, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..3) |k| d.release(k);
    var x: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    _ = x.upload(&d, .{ .who = 1 }, 0);
    // A retry: it waits, the first told 409.
    var y: Client = .{ .i = 2, .serial = 2, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.wait, y.upload(&d, .{ .who = 1 }, 0));
    try testing.expectEqual(Verdict.replaced, d.waits[0].verdict);
    // A third, before the first is served.
    var z: Client = .{ .i = 1, .serial = 3, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.wait, z.upload(&d, .{ .who = 1 }, 0));
    d.release(0);
    // The newest, stepped first, takes the slot; the older retry must not
    // take it over, and is told 409 itself.
    try testing.expectEqual(Then.wait, z.step(&d, ms(1)));
    try testing.expect(d.waits[1].slot != null);
    try testing.expectEqual(Then.serve, y.step(&d, ms(1)));
    try testing.expectEqual(Verdict.none, d.waits[1].verdict);
    try testing.expectEqual(Refusal.replaced, d.waits[2].refusal().?);
}

test "a busy loop, turns back to back, still lets a silent upload go at its stall, and a silent small body at its deadline plus at most that again (metal-vmm QUEUE 175.1)" {
    const up = try request("/up", 10_000, "", "");
    defer testing.allocator.free(up);
    const doc = try request("/doc", 100_000, "", "");
    defer testing.allocator.free(doc);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer for (0..2) |k| d.release(k);
    var u: Client = .{ .i = 0, .serial = 1, .bytes = up, .sent = up.len };
    var s: Client = .{ .i = 1, .serial = 2, .bytes = doc, .sent = doc.len };
    var now: i96 = 0;
    try testing.expectEqual(Then.wait, u.upload(&d, .{ .who = 1 }, now));
    try testing.expectEqual(Then.wait, s.settle(&d, now));
    // One busy client: a turn of 10 s, then a pass of 1 ms, over and over.
    var upload_at: ?i96 = null;
    var small_at: ?i96 = null;
    while (now < ms(10 * 60_000) and (upload_at == null or small_at == null)) {
        d.pause(ms(10_000));
        now += ms(10_000) + ms(1);
        if (upload_at == null and u.step(&d, now) == .serve) upload_at = now;
        if (small_at == null and s.step(&d, now) == .serve) small_at = now;
    }
    // Not a byte came: the stall is not credited (nothing waited to be taken).
    try testing.expect(upload_at.? <= ms(body_rule.upload_stall_ms) + ms(20_000));
    try testing.expectEqual(Refusal.stalled, d.waits[0].refusal().?);
    const deadline = ms(body_rule.smallMs(100_000));
    try testing.expect(small_at.? <= 2 * deadline + ms(20_000));
    try testing.expectEqual(Refusal.too_slow, d.waits[1].refusal().?);
}

test "a full small-body budget is 503 at once, at a drain's beginning and at its growth, as Linux answers (metal-vmm QUEUE 175.2)" {
    const body = try pattern(100_000);
    defer testing.allocator.free(body);
    const req = try request("/doc", body.len, "", body);
    defer testing.allocator.free(req);
    {
        var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps, .budget = 0 };
        defer d.release(0);
        var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
        try testing.expectEqual(Then.serve, c.step(&d, 0));
        try testing.expectEqual(Refusal.busy, d.waits[0].refusal().?);
    }
    {
        // Room for its first 64 KiB and its head, not for its growth.
        var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps, .budget = headLen(req) + first_bytes };
        defer d.release(0);
        var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
        try testing.expectEqual(Then.serve, c.settle(&d, 0));
        try testing.expectEqual(Refusal.busy, d.waits[0].refusal().?);
        try testing.expect(d.charged <= d.budget);
    }
}

test "a head kept to answer from is held to the budget too: past it, 503 with nothing kept (metal-vmm QUEUE 175.3)" {
    const req = try request("/up", 10_000, "", "");
    defer testing.allocator.free(req);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps, .budget = 10 };
    defer d.release(0);
    var c: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, c.upload(&d, .stranger, 0));
    try testing.expectEqual(Refusal.busy, d.waits[0].refusal().?);
    try testing.expect(d.waits[0].drain == null);
    try testing.expectEqual(@as(usize, 0), d.charged);
}

test "an upload refused from its head is still known to be an upload: a stranger, an asker unknown, the slot wait run out (metal-vmm QUEUE 194.1)" {
    const req = try request("/up", 10_000, "", "");
    defer testing.allocator.free(req);
    const small = try request("/doc", 100, "", "");
    defer testing.allocator.free(small);
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    var s: Client = .{ .i = 0, .serial = 1, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, s.upload(&d, .stranger, 0));
    try testing.expect(d.waits[0].wasUpload());
    d.release(0);
    var u: Client = .{ .i = 1, .serial = 2, .bytes = req, .sent = req.len };
    try testing.expectEqual(Then.serve, u.upload(&d, .unknown, 0));
    try testing.expect(d.waits[1].wasUpload());
    d.release(1);
    // Every slot held: the next uploader waits, then is told busy.
    var held: [3]Client = undefined;
    for (&held, 0..) |*h, k| {
        h.* = .{ .i = 2 + k, .serial = 10 + k, .bytes = req, .sent = req.len };
        _ = h.upload(&d, .{ .who = @intCast(10 + k) }, 0);
    }
    var e: Client = .{ .i = 5, .serial = 20, .bytes = req, .sent = req.len };
    _ = e.upload(&d, .{ .who = 30 }, 0);
    try testing.expectEqual(Then.serve, e.step(&d, ms(body_rule.slot_wait_ms)));
    try testing.expectEqual(Refusal.busy, d.waits[5].refusal().?);
    try testing.expect(d.waits[5].wasUpload());
    // A small body is not an upload.
    var p: Client = .{ .i = 6, .serial = 21, .bytes = small, .sent = small.len };
    _ = p.settle(&d, 0);
    try testing.expect(!d.waits[6].wasUpload());
    for (2..7) |k| d.release(k);
}

test "an upload cut short by its client did not come whole, and is the client gone (metal-vmm QUEUE 194.2)" {
    const uploads_seen = @import("uploads_seen.zig");
    const body = try pattern(10_000);
    defer testing.allocator.free(body);
    const req = try request("/up", body.len, "", body);
    defer testing.allocator.free(req);
    const short = req[0 .. req.len - 4_000];
    var d: TestDrains = .{ .gpa = testing.allocator, .limit = caps };
    defer d.release(0);
    var c: Client = .{ .i = 0, .serial = 1, .bytes = short, .sent = short.len, .done = true };
    try testing.expectEqual(Then.serve, c.upload(&d, .{ .who = 1 }, 0));
    const got = d.waits[0].drain.?;
    try testing.expect(got.whole); // served, so its route refuses it
    try testing.expect(!got.cameWhole());
    try testing.expectEqual(uploads_seen.Outcome.client_gone, uploads_seen.classify(400, got.cameWhole(), "ok"));
    // All of it: came whole.
    var e: Client = .{ .i = 1, .serial = 2, .bytes = req, .sent = req.len, .done = true };
    _ = e.upload(&d, .{ .who = 2 }, 0);
    try testing.expect(d.waits[1].drain.?.cameWhole());
    d.release(1);
}
