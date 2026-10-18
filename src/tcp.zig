//! TCP (RFC 9293) for a server that holds many connections and answers one
//! request at a time; the others wait in the table, not at the door.
//!
//! **NOTHING HERE WAITS.** Arriving frames go to `handle`; what we have to
//! say goes into a connection's send queue with `queue`; and `transmit`,
//! called every turn of the loop, sends what the peer's window allows,
//! retransmits what timed out, and gives up on a peer that stopped answering.
//!
//! **THE SEND SIDE:**
//!
//! - **The window.** Nothing is sent past the peer's last-advertised window.
//!   A shut window is probed with one byte when the timer runs out.
//! - **The segment size.** Each side's SYN carries its MSS; a peer that sends
//!   none is sent 536-byte segments (RFC 9293 §3.7.1).
//! - **Retransmission.** Sent bytes stay in our custody until acknowledged.
//!   On a timeout the oldest segment is sent again, then twice as much for
//!   each acknowledgement (`recovery`), and the timeout doubles. A shut
//!   window's timeout is a probe, not a loss.
//! - **Giving up.** After `max_retries` timeouts with no progress the
//!   connection is reset: so a vanished peer is noticed, and one that stops
//!   reading is let go, even while it answers every probe (a departure for
//!   a reason below: bounded).
//! - **The FIN goes last**, after every queued byte. Once it is acknowledged
//!   we wait up to `fin_wait_ns` for the peer's. There is no TIME-WAIT: a FIN
//!   repeated after the close is answered with a reset.
//! - **A segment for no connection is answered with a reset**, so a peer
//!   never waits on a connection this side has forgotten.
//! - **A reopened window is said again until the peer sends.** The
//!   announcement is a bare ACK, which nothing acknowledges; if it is lost,
//!   the peer waits on its own persist timer, which backs off to minutes.
//!
//! **THE SMALL TCP**, allowed because this box sits behind Caddy on a private
//! network: no congestion control, no SACK, no window scaling, no delayed
//! ACK. Segments ahead of a hole are held, a few a connection, in the
//! receive buffer itself (`tcp_held.zig`). It does have fast retransmit.
//!
//! **WHY IT DEPARTS FROM THE RFCs.** Each `DEPARTS (reason):` line names one
//! of five reasons, and no other:
//! - **bounded**: a hostile or broken peer cannot make the table hold more,
//!   answer more, or wait longer: no reply to junk, nothing for a scanner,
//!   no connection pinned by a reader that never reads (denial of service);
//! - **fast**: our networks are short and private (a private network to
//!   Caddy, a 5 ms test wire), so timers are seconds where the RFC's are
//!   minutes, and a confused peer hears at once;
//! - **simpler**: a simpler path whose cost is a frame or a round trip,
//!   never a wrong byte, because a correct peer's own rules recover it;
//! - **stricter**: the table takes or believes less than the RFC allows;
//! - **scale**: a handful of connections to peers we name, one at a time,
//!   with nobody to share the path with.
//!
//! **PURE, SO IT IS TESTED ON THE HOST.** Frames go out through the caller's
//! `wire` (anything with `send([]const u8)`), the ISN comes from a function
//! the caller supplies, and the time is a number the caller passes.
//!
//! **WHAT WAITS IN THE TABLE, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md §2;
//! tcp_check.zig's `liveness` table is this list, checked). Each entry is a
//! **debt**: no debt without a clock, no clock without a debt, no clock
//! without a give-up. Deadlines are looked at only in `transmit`, so each
//! bound is "the deadline, plus the time to the next `transmit`", which the
//! host bounds (stream.zig).
//!
//! - **Bytes queued, not yet sent** (`tx` past `sent`). Sent by the next
//!   `transmit` as the window allows. Bounded by: while the window is shut,
//!   a probe at `rto_at` and a reset after `max_retries` fruitless timeouts.
//! - **Bytes and a FIN on the wire, unacknowledged** (`tx` up to `high`).
//!   Sent again at `rto_at` (measured, `min_rto_ns` to `max_rto_ns`,
//!   doubling), or at once on three duplicate ACKs. Bounded by: a reset after
//!   `max_retries` timeouts with nothing acknowledged: about 16 s from a
//!   200 ms clock, 35 s at most.
//! - **Our FIN, queued** (`fin == .queued`). Sent by the first `transmit`
//!   that finds every queued byte sent. Bounded by: the bytes ahead of it.
//! - **Our SYN-ACK, unanswered** (`syn_received`). Sent again at `rto_at`.
//!   Bounded by: `max_retries`, as above; and, when the table is full, by the
//!   next SYN, to which the oldest half-open older than `min_rto_ns` gives way.
//! - **Our SYN, unanswered** (`syn_sent`). Sent again at `rto_at`, from
//!   `syn_first_rto_ns` (25 ms), doubling. Bounded by: the connection's
//!   `deadlines.connect_ns`, and `max_retries`.
//! - **A connection of our own** (`deadlines`). Bounded by: its
//!   `Deadlines`, after which it is let go (`pastDeadline`).
//! - **The peer's FIN, after ours was acknowledged.** Bounded by:
//!   `fin_wait_until` (`fin_wait_ns`, 30 s), then a reset.
//! - **A reopened window the peer may not have seen** (`window_news`).
//!   `.said_once` is timed by the next `transmit`; `.repeating` is said again
//!   at `update_at`, doubling. Bounded by: the peer sending data or its FIN,
//!   the window shutting again, or `max_retries` repeats, after which the
//!   debt lapses.
//! - **Bytes held ahead of a hole** (`held`, past `end`). Bounded by: the
//!   peer, whose timer resends the hole; until then they cost nothing but
//!   room the window already promised.
//! - **Bytes received, not yet read** (`rx[start..end]`), in custody for the
//!   reader. Bounded by: the host (probe/gopher.zig serves a connection once
//!   its request is whole, and lets go of one silent for `idle_ns`). While
//!   the buffer is full the window is shut and the peer's persist timer waits.
//!
//! **NOT QUEUED AT ALL**, so nothing is left waiting: an ACK (every in-order
//! segment is acknowledged as it is taken), a segment ahead that finds
//! the held pieces full (dropped and re-acknowledged; the peer resends it),
//! and a SYN that finds no
//! free slot and no stuck half-open to replace (dropped and counted; the
//! peer's SYN timer retries).

const proto = @import("proto.zig");
const props = @import("coverage");
const plant = @import("plant.zig");
const machine = @import("machine.zig");
/// Sequence numbers modulo 2^32 (seq.zig): every "after" here is one of these.
const sq = @import("seq.zig").Seq(u32);

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// RFC 9293 §3.1's segment, read and written (tcp_segment.zig).
const tcp_segment = @import("tcp_segment.zig");
pub const Segment = tcp_segment.Segment;
pub const Ctl = tcp_segment.Ctl;
pub const header_len = tcp_segment.header_len;
pub const segment_at: usize = proto.eth_header_len + proto.ip_header_len;

pub const flag_fin = tcp_segment.flag_fin;
pub const flag_syn = tcp_segment.flag_syn;
pub const flag_rst = tcp_segment.flag_rst;
pub const flag_psh = tcp_segment.flag_psh;
pub const flag_ack = tcp_segment.flag_ack;

/// The MSS for a peer whose SYN names none (RFC 9293 §3.7.1).
pub const default_mss: u16 = 536;
/// Ours: an ethernet frame's worth, which the NIC's receive buffers hold.
pub const our_mss: u16 = 1460;
/// **THE LEAST SEGMENT SIZE A PEER IS SENT** (Linux's TCP_MIN_MSS): a peer
/// that names less (0 sized every send to nothing, and each took the shut
/// window's path, a byte a retransmission timeout) is sent this much. A peer
/// is a stranger: its size is raised, named here, not refused (the
/// normalization hunt, 2026-10-10).
pub const min_mss: u16 = 88;
pub const mss_option = [4]u8{ 2, 4, our_mss >> 8, our_mss & 0xFF };
/// Where ephemeral ports start unless the host seeds another start: the
/// dynamic range's first (RFC 6335 §6).
pub const ephemeral_first: u16 = 49152;

// **THE RETRANSMISSION CLOCK AND ITS BOUNDS** (RFC 6298, RFC 5681;
// tcp_timeouts.zig).
const timeouts = @import("tcp_timeouts.zig");
/// **WHAT ARRIVED AHEAD OF A HOLE** (tcp_held.zig, metal-vmm QUEUE 226).
const held_queue = @import("tcp_held.zig");
pub const min_rto_ns = timeouts.min_rto_ns;
pub const first_rto_ns = timeouts.first_rto_ns;
pub const max_rto_ns = timeouts.max_rto_ns;
pub const max_retries = timeouts.max_retries;
pub const dupacks_before_resend = timeouts.dupacks_before_resend;
pub const syn_first_rto_ns = timeouts.syn_first_rto_ns;
pub const Deadlines = timeouts.Deadlines;
pub const Deadline = timeouts.Deadline;
pub const pastDeadline = timeouts.pastDeadline;
/// How long FIN-WAIT-2 waits for the peer's FIN. RFC 9293 sets no bound;
/// Linux's `tcp_fin_timeout` is the same idea.
pub const fin_wait_ns: u64 = 30 * ns_per_s;
pub const ns_per_ms = 1_000_000;
pub const ns_per_s = 1_000_000_000;

/// RFC 9293's states, fewer of them: the table as a whole is LISTEN, and the
/// closing states are told apart by `fin` and `peer_half` rather than by name.
pub const State = enum {
    /// CLOSED. The slot is free — unless the host still holds it (`claimed`).
    closed,
    /// SYN-RECEIVED: our SYN-ACK is out, its acknowledgement not yet in.
    syn_received,
    /// SYN-SENT: our SYN is out (an active OPEN, `Table.connect`), the
    /// peer's SYN-ACK not yet in.
    syn_sent,
    /// ESTABLISHED, and CLOSE-WAIT once the peer has finished.
    established,
    /// Our FIN is queued, sent or acknowledged: FIN-WAIT-1, FIN-WAIT-2
    /// (`fin` acknowledged), and CLOSING or LAST-ACK (the peer finished). With
    /// both FINs acknowledged the slot is CLOSED at once: no TIME-WAIT.
    closing,
};

/// **WHERE OUR FIN IS**, as a machine (machine.zig): changed only by these
/// events, each cell a coverage site. `resending` is a FIN sent and then
/// rewound by a timeout or an early resend, owed again; it still holds a
/// sequence number, which `queued` (never sent) does not.
pub const Fin = enum { none, queued, sent, resending, acknowledged };
pub const FinEvent = enum {
    /// The host closes its half (`finish`).
    host_finished,
    /// Every queued byte is out, and the FIN goes after them.
    fin_emitted,
    /// The retransmission timer fires: go back to `una`, FIN included.
    timed_out,
    /// Duplicate ACKs resend early, the same go-back.
    resent_early,
    /// An ACK covers every byte and the FIN.
    fin_acknowledged,
};
/// What callers ask of where our FIN is: `owed`, to the wire (never sent,
/// or sent and rewound); `numbered`, holding a sequence number (sent, or sent
/// and rewound).
pub const FinGroup = enum { owed, numbered };
pub const FinMachine = machine.Machine(.{
    .name = "tcp.Fin",
    .State = Fin,
    .Event = FinEvent,
    .Group = FinGroup,
    .initial = .none,
    .edges = &.{
        .{ .from = .none, .on = .host_finished, .to = .queued },
        .{ .from = .queued, .on = .fin_emitted, .to = .sent },
        .{ .from = .resending, .on = .fin_emitted, .to = .sent },
        .{ .from = .sent, .on = .timed_out, .to = .resending },
        .{ .from = .sent, .on = .resent_early, .to = .resending },
        .{ .from = .sent, .on = .fin_acknowledged, .to = .acknowledged },
        // The first FIN's ACK, arriving after a go-back.
        .{ .from = .resending, .on = .fin_acknowledged, .to = .acknowledged },
    },
    .groups = .{
        .none = &.{},
        .queued = &.{.owed},
        .sent = &.{.numbered},
        .resending = &.{ .owed, .numbered },
        .acknowledged = &.{},
    },
});

/// **THE PEER'S HALF OF THE CONNECTION** (metal-vmm 144): open, until its FIN
/// arrives. Never back: a slot reused is a new `Conn` (`reset`).
pub const PeerHalf = enum { open, finished };
pub const PeerMachine = machine.Machine(.{
    .name = "tcp.Peer",
    .State = PeerHalf,
    .Event = enum { fin_received },
    .initial = .open,
    .edges = &.{.{ .from = .open, .on = .fin_received, .to = .finished }},
});

/// **WHO OPENED THE CONNECTION** (RFC 9293 §3.10.1, OPEN): the peer, to
/// the port the table listens on (`accepted`, a passive OPEN), or this
/// machine (`initiated`, an active OPEN, from a port of its own). The host
/// serves only what it accepted.
pub const Role = enum { accepted, initiated };

/// How a connection ended: closed cleanly (both FINs), reset by its peer, or
/// given up on by this machine, and why (`Table.Abandon`).
pub const End = union(enum) { closed, reset_by_peer, abandoned: Table.Abandon };

/// A slot's last connection's end, and whose it was: its role and local port
/// (an initiated connection's port is its own, so a client knows its own).
pub const Ended = struct { role: Role, local_port: u16, how: End };

pub const Conn = struct {
    state: State = .closed,
    role: Role = .accepted,
    // The remote half of the socket pair.
    peer_ip: [4]u8 = proto.ip_any,
    peer_mac: [6]u8 = proto.mac_broadcast,
    peer_port: u16 = 0,
    /// The local half's port: the table's own for an accepted connection, an
    /// ephemeral one for an initiated one. (The local address is the
    /// table's.) A connection is found by all four (`Table.find`).
    local_port: u16 = 0,

    /// RCV.NXT. There is no IRS field; the SYN sets this to IRS + 1.
    rcv_nxt: u32 = 0,

    /// **RECEIVED AND NOT YET READ: `rx[start..end]`**, in custody for the
    /// reader: we acknowledged these bytes, so the peer will not resend them.
    /// RCV.WND is `window()`.
    rx: []u8,
    start: usize = 0,
    end: usize = 0,
    /// **HELD AHEAD OF A HOLE** (RFC 9293 §3.10.7.4, SHLD-31; metal-vmm
    /// QUEUE 226): the pieces past RCV.NXT already in `rx`, past `end`, at
    /// their own places, and a FIN behind them. Delivered when the hole
    /// fills.
    held: held_queue.Held = .{},

    /// **QUEUED AND NOT YET ACKNOWLEDGED: `tx[tx_start..tx_end]`**, in our
    /// custody until the peer acknowledges them. `tx[tx_start]` is the byte
    /// numbered `una`; the first `sent` are on the wire.
    tx: []u8,
    tx_start: usize = 0,
    tx_end: usize = 0,
    /// Where the next segment starts, as a count past `una`. A timeout or a
    /// fast retransmit sets it back to 0. It is not SND.NXT: that never goes
    /// back, and is `highest()`.
    sent: usize = 0,
    /// The most bytes past `una` ever on the wire, so an ACK of bytes sent
    /// before `sent` was rewound still counts.
    high: usize = 0,
    /// **RECOVERING FROM A LOSS** (RFC 6298 (5.4); metal-vmm QUEUE 225,
    /// chunk 0a): how many bytes past `una` may be on the wire, or null when
    /// not recovering. A timeout or a fast retransmit sets it to one segment,
    /// so only the oldest is sent again; each acknowledgement of `acked`
    /// bytes makes it `(recovery - acked) + 2 * acked`, doubling it each
    /// round trip, until it covers `high` and sending is as before. A go-back
    /// of the whole window instead phase-locked with a loss of every 13th
    /// frame: each timeout resent the same window, and the same frame was
    /// lost again, until the retries ran out (the native judge, 2026-10-16).
    recovery: ?usize = null,
    /// SND.UNA. In SYN-RECEIVED it is ISS; there is no ISS field.
    una: u32 = 0,
    fin: FinMachine = .{},
    /// SND.WND, always measured from `una` (see `acknowledge`). At most
    /// 0xFFFF: no window scaling.
    wnd: u32 = 0,
    /// SND.WL1 and SND.WL2: the sequence and acknowledgement numbers of the
    /// segment that last set `wnd`, so an older segment cannot overrule it.
    wl1: u32 = 0,
    wl2: u32 = 0,
    /// SendMSS (RFC 9293 §3.7.1), never more than `our_mss`.
    mss: u16 = default_mss,
    /// The retransmission timer (RFC 6298 §5), also the persist timer and
    /// the SYN-ACK's. Null when nothing is owed to the peer.
    rto_at: ?i96 = null,
    /// RTO (RFC 6298 §2), doubled by each timeout.
    rto_ns: u64 = first_rto_ns,
    /// Timeouts since the peer last acknowledged anything: `rto_at`'s
    /// give-up, against `max_retries`.
    retries: u8 = 0,
    /// SRTT and RTTVAR (RFC 6298). Zero until the first sample.
    srtt_ns: u64 = 0,
    rttvar_ns: u64 = 0,
    /// The one segment being timed: when it went out, and the sequence
    /// number just past it. Null when nothing is timed, including after a
    /// retransmit (Karn's algorithm).
    timed_at: ?i96 = null,
    timed_seq: u32 = 0,
    /// Duplicate ACKs in a row (RFC 5681).
    dupacks: u8 = 0,
    /// This run of duplicates: still `counting`, or `answered` by a resend,
    /// until `una` moves.
    duplicates: enum { counting, answered } = .counting,
    /// FIN-WAIT-2's deadline for the peer's FIN.
    fin_wait_until: ?i96 = null,

    /// **THE PEER'S HALF** (`PeerMachine`): `finished` once its FIN has
    /// arrived (and is counted in `rcv_nxt`); what came before it may still
    /// be unread. Asked by `peerDone`.
    peer_half: PeerMachine = .{},

    /// The window in the last segment we sent: RCV.WND as the peer last saw it.
    told_wnd: u16 = 0xFFFF,
    /// **WHAT WE STILL OWE THE PEER ABOUT OUR WINDOW.** A segment that
    /// reopens a window the peer last saw too small makes it `.said_once`;
    /// the next `transmit` makes it `.repeating` and arms `update_at`. It
    /// ends when the peer sends data or its FIN, the window shuts again, or
    /// `max_retries` repeats pass. Not in RFC 9293, where a lost window
    /// update is recovered only by the peer's persist timer (§3.8.6.1).
    window_news: WindowNews = .none,
    /// When the reopened window is said again. Armed exactly while
    /// `window_news` is `.repeating`.
    update_at: ?i96 = null,
    /// Repeats so far: `update_at`'s give-up, against `max_retries`.
    updates: u8 = 0,

    // ── The host's marks on the slot, not TCP's. `reset()` keeps `claimed`;
    // the rest are set when a connection takes the slot.
    /// **HELD BY THE HOST.** A slot being served is never handed to a new
    /// connection, even after this one ends, or a reader part-way through a
    /// request could find a stranger's bytes in its buffer.
    claimed: bool = false,

    /// When the handshake started and when the peer was last heard from:
    /// the host serves oldest first and lets go of the quiet.
    opened_at: i96 = 0,
    heard_at: i96 = 0,
    /// **A CONNECTION OF OUR OWN'S BOUNDS** (`connect`), measured from
    /// `opened_at` and `heard_at`: null for an accepted one, which the host
    /// bounds instead.
    deadlines: ?Deadlines = null,
    /// Arrival order, breaking ties within a clock tick.
    serial: u64 = 0,
    /// **HOW THE SLOT'S LAST CONNECTION ENDED**, kept past its reset (and
    /// past the slot's next connection, until that one ends): what a client
    /// of its own reads to say how its fetch ended (fetch.zig), by the role
    /// and port it had. The table's counters are the whole table's: another
    /// connection given up meanwhile moves them too.
    ended: ?Ended = null,

    pub fn pending(self: *const Conn) []u8 {
        return self.rx[self.start..self.end];
    }

    /// Releases `n` pending bytes. The buffer is compacted once `start`
    /// passes half of it, so the window reopens while a request is read.
    pub fn consume(self: *Conn, n: usize) void {
        // More than is pending is the caller's bug (a parser that miscounted),
        // said, and held to what there is (the normalization hunt).
        props.always(@src(), n <= self.end - self.start, "tcp: a caller consumes no more than is pending", .{ .n = n, .pending = self.end - self.start });
        self.start += @min(n, self.end - self.start);
        if (self.start == self.end) {
            // Everything read: back to the buffer's start, and the pieces
            // held past `end` with it.
            const ahead_len = self.held.extent();
            std.mem.copyForwards(u8, self.rx[0..ahead_len], self.rx[self.end .. self.end + ahead_len]);
            self.start = 0;
            self.end = 0;
        } else if (self.start > self.rx.len / 2) {
            // The pieces held past `end` move with it.
            const len = self.end - self.start;
            const ahead_len = self.held.extent();
            std.mem.copyForwards(u8, self.rx[0 .. len + ahead_len], self.rx[self.start .. self.end + ahead_len]);
            self.start = 0;
            self.end = len;
        }
    }

    /// **`consume`, AND WHETHER THE WINDOW REOPENED** (metal-vmm QUEUE
    /// 197.3): true when the window was `tight` before and is not after, so
    /// the caller announces it (`Table.ack`) and a peer that filled it does
    /// not sit waiting for its own probe. The one rule: the host's stream,
    /// its drain and tcp_sim's host each wrote it, and the sim another way.
    pub fn consumeReopens(self: *Conn, n: usize) bool {
        const was_tight = self.tight(self.window());
        self.consume(n);
        return was_tight and !self.tight(self.window());
    }

    /// Free space at the end of the receive buffer: what arriving bytes go
    /// into and what the window advertises. Space freed at the front counts
    /// only once `consume` compacts.
    pub fn room(self: *const Conn) usize {
        return self.rx.len - self.end;
    }

    /// Queued bytes the peer has not acknowledged, sent or not.
    pub fn queued(self: *const Conn) usize {
        return self.tx_end - self.tx_start;
    }

    pub fn queueRoom(self: *const Conn) usize {
        return self.tx.len - self.queued();
    }

    pub fn open(self: *const Conn) bool {
        return self.state == .established or self.state == .syn_received or self.state == .syn_sent;
    }

    /// **SND.NXT: just past the furthest thing we have ever sent** (BSD's
    /// `snd_max`). A segment carrying nothing, an ACK or a reset, is numbered
    /// here. `una + sent` is not it: after a rewind, a segment numbered there
    /// is from behind to the peer, and is dropped (a reset) or draws a
    /// duplicate ACK.
    pub fn highest(self: *const Conn) u32 {
        var n = self.una +% @as(u32, @intCast(self.high));
        if (self.state == .syn_received or self.state == .syn_sent) n +%= 1; // the SYN takes one
        if (self.fin.in(.numbered)) n +%= 1;
        return n;
    }

    /// Starts timing a segment unless one is already timed: one sample per
    /// round trip, as RFC 6298 allows without timestamps.
    fn time(self: *Conn, now: i96, past_it: u32) void {
        if (self.timed_at != null) return;
        self.timed_at = now;
        self.timed_seq = past_it;
    }

    /// **AHEAD**: past `rcv_nxt` but inside the window we advertise, so
    /// acceptable to RFC 9293's sequence test (§3.10.7.4) but not the next
    /// byte. A shut window has nothing ahead.
    pub fn ahead(self: *const Conn, seq: u32) bool {
        return seq != self.rcv_nxt and sq.within(seq, self.rcv_nxt, @max(self.window(), 1));
    }

    fn reset(self: *Conn) void {
        const rx = self.rx;
        const tx = self.tx;
        const claimed = self.claimed;
        const ended = self.ended;
        self.* = .{ .rx = rx, .tx = tx, .claimed = claimed, .ended = ended };
    }

    /// Notes how this connection ended, before its reset.
    fn noteEnd(self: *Conn, how: End) void {
        self.ended = .{ .role = self.role, .local_port = self.local_port, .how = how };
    }

    /// The peer has finished: its FIN arrived.
    pub fn peerDone(self: *const Conn) bool {
        return self.peer_half.is(.finished);
    }

    /// RCV.WND: `room()`, as much as the 16-bit field carries.
    pub fn window(self: *const Conn) u16 {
        return @intCast(@min(self.room(), 0xFFFF));
    }

    /// Too small for the peer to send a full segment into, or half the
    /// buffer when the buffer is smaller than that.
    pub fn tight(self: *const Conn, w: u16) bool {
        return @as(usize, w) < @min(@as(usize, our_mss), self.rx.len / 2);
    }

    /// Nothing more is owed about our window: the peer has sent since, or
    /// there is no open window to announce.
    fn heard(self: *Conn) void {
        self.window_news = .none;
        self.update_at = null;
    }
};

/// The window debt as a state of its own, so each stage has a deadline the
/// checker can ask for.
pub const WindowNews = enum {
    none,
    /// A reopened window was just said, once; the next turn times its repeat.
    said_once,
    /// Said again at `update_at`, doubling.
    repeating,
};

pub const Result = struct {
    event: Event,
    /// Meaningless for `.nothing`.
    index: usize = 0,
};

/// What `handle` decided a frame meant.
/// What one segment did, the most of it: a segment that opens a connection
/// and carries the peer's FIN reports `.peer_done`, not `.opened`. A host
/// that must see every change reads the connection (`pending`, `peerDone`,
/// `state`), as probe/gopher.zig does.
pub const Event = enum {
    nothing,
    /// A handshake completed.
    opened,
    /// A connection's pending bytes grew.
    data,
    /// The peer's FIN arrived; what it sent before it may still be pending.
    peer_done,
    closed,
};

/// Given-way half-opens kept to be revived: 256 covers a 1024-SYN flood at
/// 1 ms apart with room to spare.
pub const revival_slots = 256;

/// What a given-way half-open's completing ACK needs of it.
pub const Revivable = struct {
    ip: [4]u8 = @splat(0),
    mac: [6]u8 = @splat(0),
    port: u16 = 0,
    /// Our ISS: the ACK must name ISS + 1, the one acknowledgement
    /// `syn_received` would not have answered with a reset.
    iss: u32 = 0,
    rcv_nxt: u32 = 0,
    wl1: u32 = 0,
    mss: u16 = 0,
    wnd: u32 = 0,
    told_wnd: u16 = 0,
};

// **SEGMENT ARRIVES' PURE DECISIONS** (RFC 9293 §3.10.7; tcp_arrives.zig):
// what a segment means for a connection; `Table` acts on the answer.
const arrives = @import("tcp_arrives.zig");
pub const Acceptability = arrives.Acceptability;
pub const acceptability = arrives.acceptability;
pub const ResetCheck = arrives.ResetCheck;
pub const resetCheck = arrives.resetCheck;
pub const AckCheck = arrives.AckCheck;
pub const ackCheck = arrives.ackCheck;
pub const SynSent = arrives.SynSent;
pub const synSent = arrives.synSent;

pub const Table = struct {
    local_ip: [4]u8,
    local_mac: [6]u8,
    /// The port the table listens on (LISTEN, a passive OPEN).
    port: u16,
    conns: []Conn,
    /// **SLOTS KEPT FOR THIS MACHINE'S OWN CONNECTIONS** (metal-vmm QUEUE
    /// 225, chunk 4; one, decided): an accepted connection never takes the
    /// last this many free slots (`free`). Zero, the server alone, is the
    /// table as it always was.
    reserved_for_initiated: usize = 0,
    /// Scratch for one outgoing frame.
    out: []u8,
    /// The ISN source. It must be unpredictable: a guessable ISN lets an
    /// off-path attacker inject into a connection.
    isn: *const fn () u32,

    arrivals: u64 = 0,
    /// SYNs dropped because every slot was taken and none could give way, as
    /// Linux drops on a full accept queue. The peer retries.
    refused: u64 = 0,
    /// Half-opens that gave way to a new SYN (see `oldestHalfOpen`).
    half_open_given_way: u64 = 0,
    /// **THIS MACHINE'S OWN CONNECTIONS** (`connect`, metal-vmm QUEUE 225):
    /// opened; refused by the peer's reset; SYN-ACKs whose ACK named
    /// something else, reset; and simultaneous opens, dropped.
    connects: u64 = 0,
    connects_refused: u64 = 0,
    syn_sent_bad_acks: u64 = 0,
    simultaneous_opens_refused: u64 = 0,
    /// **HELD AHEAD OF A HOLE** (`holdAhead`, QUEUE 226): segments held,
    /// bytes delivered from the held pieces once a hole filled, and segments
    /// dropped because the pieces were full.
    held_segments: u64 = 0,
    held_delivered: u64 = 0,
    held_refused_full: u64 = 0,
    /// Connections of our own let go at a deadline (`Deadlines`): not
    /// established in time, the peer silent too long, or too long in all.
    connect_deadlines: u64 = 0,
    idle_deadlines: u64 = 0,
    total_deadlines: u64 = 0,
    /// **THE NEXT EPHEMERAL PORT** (RFC 6056): seeded by the host, counted
    /// up from there, never reused while the run has others to give.
    ephemeral_next: u16 = ephemeral_first,
    /// **THE RECENTLY GIVEN WAY, KEPT TO BE REVIVED**, newest over oldest. A
    /// real client whose handshake outlasted `min_rto_ns` (a lost SYN-ACK or
    /// ACK) can lose its slot to a flood's SYN; its ACK finds its entry here
    /// and the connection is rebuilt.
    /// Null where nothing is kept.
    revivable: [revival_slots]?Revivable = @splat(null),
    /// How many of `revivable` are used: all in the kernel, fewer where a
    /// simulator measures a smaller ring.
    revival_cap: u16 = revival_slots,
    revival_next: u16 = 0,
    /// Half-opens revived, and matching ACKs that found no slot (dropped,
    /// not reset).
    revived: u64 = 0,
    revival_no_room: u64 = 0,
    /// Retransmissions, by timer or by duplicate ACKs.
    retransmits: u64 = 0,
    /// Those the duplicate ACKs asked for.
    fast_retransmits: u64 = 0,
    /// Window probes.
    probes: u64 = 0,
    /// Connections reset because the peer stopped acknowledging.
    given_up: u64 = 0,
    /// Connections reset because the peer's FIN never came.
    fin_waits_expired: u64 = 0,
    /// Segments for no connection, answered with a reset.
    strays: u64 = 0,
    /// Segments dropped for a bad checksum.
    damaged: u64 = 0,
    /// **WHAT ARRIVES OUT OF ORDER** (metal-vmm QUEUE 193.4): a segment
    /// ahead of the next byte expected (one before it was lost, or is late:
    /// the card or the network dropped it), one from behind (a resend of what
    /// was already taken), and one carrying more than the window holds.
    arrived_ahead: u64 = 0,
    arrived_behind: u64 = 0,
    past_window: u64 = 0,
    /// **RESETS, BY WHO AND WHY** (metal-vmm QUEUE 193, gap 6): exact
    /// resets from the peer (each one a connection it ended), inexact ones
    /// answered with a challenge ACK, and our resets of a SYN-RECEIVED
    /// peer whose ACK named the wrong number.
    resets_received: u64 = 0,
    /// Frames that were not a TCP segment for us, by why (gap 8).
    passed: proto.Passed = .{},
    challenge_acks: u64 = 0,
    bad_ack_resets: u64 = 0,
    /// Connections the host gave up on, by its reason (`abandon`): a client
    /// that stopped taking its response, a stream that fell too far behind,
    /// and a close of a connection that never finished its handshake. A
    /// silent peer and an unanswered FIN are `given_up` and
    /// `fin_waits_expired`.
    abandoned_slow_client: u64 = 0,
    abandoned_stream_behind: u64 = 0,
    abandoned_unfinished: u64 = 0,
    /// Reopened windows said again.
    window_updates: u64 = 0,
    /// Round trips measured, and the newest SRTT.
    samples: u64 = 0,
    measured_ns: u64 = 0,

    pub fn init(ip: [4]u8, mac: [6]u8, port: u16, conns: []Conn, out: []u8, isn: *const fn () u32) Table {
        return .{ .local_ip = ip, .local_mac = mac, .port = port, .conns = conns, .out = out, .isn = isn };
    }

    /// How many slots hold a connection or are held by the host.
    pub fn inUse(self: *const Table) usize {
        var n: usize = 0;
        for (self.conns) |c| {
            if (c.state != .closed or c.claimed) n += 1;
        }
        return n;
    }

    /// **THE CONNECTION A SEGMENT IS FOR**, by the socket pair whole: the
    /// peer's address and port and our port (RFC 9293 §3.10.7). Two polls of
    /// one site's port 80 from two of our ports are two connections, one of
    /// them maybe still closing.
    fn find(self: *Table, ip: [4]u8, port: u16, local_port: u16) ?usize {
        for (self.conns, 0..) |c, i| {
            if (c.state != .closed and c.peer_port == port and c.local_port == local_port and eql(&c.peer_ip, &ip)) return i;
        }
        return null;
    }

    /// A free slot for a connection of `role`. **ONE IS KEPT FOR THIS
    /// MACHINE'S OWN** (`reserved_for_initiated`): an accepted connection
    /// takes a slot only while more than that many are free, so a flood of
    /// SYNs cannot starve the connections this machine opens.
    fn free(self: *Table, role: Role) ?usize {
        var first: ?usize = null;
        var n: usize = 0;
        for (self.conns, 0..) |c, i| {
            if (c.state == .closed and !c.claimed) {
                if (first == null) first = i;
                n += 1;
            }
        }
        if (role == .accepted and n <= self.reserved_for_initiated) return null;
        return first;
    }

    /// Whether a connection this machine opened has `port` as its own.
    fn initiatedOn(self: *const Table, port: u16) bool {
        for (self.conns) |c| {
            if (c.state != .closed and c.role == .initiated and c.local_port == port) return true;
        }
        return false;
    }

    /// **A FULL TABLE GIVES WAY TO A NEW SYN AT ITS OLDEST STUCK HALF-OPEN.**
    /// A half-open holds its slot through `max_retries` timeouts, 16 to 35 s,
    /// so spoofed SYNs, which never answer, could otherwise fill every slot
    /// and keep real clients out.
    ///
    /// **ONLY A STUCK ONE: older than `min_rto_ns`.** A real client completes
    /// its handshake in one round trip, far less; evicting it mid-handshake
    /// would make its ACK draw a reset (native/judge_native.py's burst). When
    /// every half-open is that fresh the SYN is refused: a real burst
    /// retries, a flood is thinned. The one given way gets no reset (to a
    /// spoofed address that is a reset to someone else) and goes into the
    /// revival ring. An established connection never gives way.
    fn oldestHalfOpen(self: *Table, now: i96) ?usize {
        var oldest: ?usize = null;
        for (self.conns, 0..) |c, i| {
            if (c.state != .syn_received or c.claimed) continue;
            if (now - c.opened_at < min_rto_ns) continue;
            if (oldest == null or c.opened_at < self.conns[oldest.?].opened_at) oldest = i;
        }
        const i = oldest orelse return null;
        self.keepRevivable(&self.conns[i]);
        self.conns[i].noteEnd(.{ .abandoned = .gave_way });
        self.conns[i].state = .closed;
        self.half_open_given_way += 1;
        props.reachable(@src(), "tcp: a stuck half-open connection gives way to a new SYN", .{ .conn = i });
        return i;
    }

    /// Sends one segment on connection `i`, numbered `seq`, and keeps the
    /// window debt: a window that reopens one the peer last saw too small
    /// starts it; a tight window or a finished peer ends it.
    fn emit(self: *Table, wire: anytype, i: usize, flags: u8, seq: u32, payload: []const u8) void {
        const c = &self.conns[i];
        const w = c.window();
        if (c.tight(w) or c.peerDone()) {
            // A peer that has sent its FIN is owed no window.
            c.heard();
        } else if (c.tight(c.told_wnd)) {
            c.window_news = .said_once;
            c.update_at = null;
            c.updates = 0;
        }
        c.told_wnd = w;
        self.segment(wire, .{
            .mac = c.peer_mac,
            .ip = c.peer_ip,
            .port = c.peer_port,
            .from = c.local_port,
        }, flags, seq, c.rcv_nxt, w, payload);
    }

    /// Keeps the half-open `c`, about to give way, in the ring, over the
    /// oldest entry.
    fn keepRevivable(self: *Table, c: *const Conn) void {
        const cap = @min(self.revival_cap, revival_slots);
        if (cap == 0) return;
        const at = self.revival_next % cap;
        self.revivable[at] = .{
            .ip = c.peer_ip,
            .mac = c.peer_mac,
            .port = c.peer_port,
            .iss = c.una,
            .rcv_nxt = c.rcv_nxt,
            .wl1 = c.wl1,
            .mss = c.mss,
            .wnd = c.wnd,
            .told_wnd = c.told_wnd,
        };
        self.revival_next = (at + 1) % cap;
    }

    /// The given-way half-open that would not have reset this segment: same
    /// address and port, its ACK naming ISS + 1. Whatever its sequence
    /// number, the revived `syn_received` treats it as the original would.
    /// A blind sender must still guess the 32-bit ISS. The caller asks only
    /// for an ACK without SYN; resets are handled before.
    fn revivableFor(self: *Table, ip: [4]u8, port: u16, number: u32) ?*?Revivable {
        for (&self.revivable) |*slot| {
            const e = slot.* orelse continue;
            if (e.port != port or !eql(&e.ip, &ip)) continue;
            if (number != e.iss +% 1) continue;
            return slot;
        }
        return null;
    }

    /// **A CONNECTION ENTERS SYN-RECEIVED**, a SYN taken or a half-open
    /// revived: its clocks start (opened, heard, the retransmission timer),
    /// it is counted an arrival, its serial that count, and the slots noted.
    /// Every way into SYN-RECEIVED goes through here, so none forgets one.
    fn enterSynReceived(self: *Table, c: *Conn, now: i96) void {
        c.state = .syn_received;
        c.opened_at = now;
        c.heard_at = now;
        c.rto_at = now + c.rto_ns;
        self.arrivals += 1;
        c.serial = self.arrivals;
        self.noteSlots();
    }

    /// Rebuilds `e` as `syn_received` in a free slot, else in a stuck
    /// half-open's (almost certainly a flood's: an ACK proves its sender is
    /// real, a half-open proves nothing). Null with neither.
    fn revive(self: *Table, e: Revivable, now: i96) ?usize {
        const slot = self.free(.accepted) orelse self.oldestHalfOpen(now) orelse return null;
        const c = &self.conns[slot];
        c.reset();
        c.local_port = self.port;
        c.peer_ip = e.ip;
        c.peer_mac = e.mac;
        c.peer_port = e.port;
        c.rcv_nxt = e.rcv_nxt;
        c.wl1 = e.wl1;
        c.una = e.iss;
        c.mss = e.mss;
        c.wnd = e.wnd;
        c.told_wnd = e.told_wnd;
        self.enterSynReceived(c, now);
        return slot;
    }

    /// Where a segment goes: the peer's address and port, and `from`, our
    /// port it is sent from.
    const Peer = struct { mac: [6]u8, ip: [4]u8, port: u16, from: u16 };

    /// Builds and sends one segment to `to`. A SYN carries our MSS.
    fn segment(self: *Table, wire: anytype, to: Peer, flags: u8, seq: u32, ack_number: u32, window: u16, payload: []const u8) void {
        const s: Segment = .{
            .src_port = to.from,
            .dst_port = to.port,
            .seq = seq,
            .ack = ack_number,
            .ctl = Ctl.of(flags),
            .window = window,
            .options = if (flags & flag_syn != 0) &mss_option else &.{},
            .data = payload,
        };
        const frame_len = proto.writeIpv4(
            self.out,
            self.local_mac,
            to.mac,
            self.local_ip,
            to.ip,
            proto.proto_tcp,
            s.len(),
        );
        const t = self.out[segment_at..][0..s.len()];
        s.write(t);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.local_ip, to.ip, proto.proto_tcp, t)));

        wire.send(self.out[0..frame_len]);
    }

    /// **A SEGMENT FOR NO CONNECTION** is answered with a reset (RFC 9293
    /// §3.10.7.1): numbered by its ACK if it has one, else acknowledging
    /// everything it carried.
    fn refuse(self: *Table, wire: anytype, to: Peer, seq: u32, ack_number: u32, flags: u8, data_len: usize) void {
        self.strays += 1;
        if (flags & flag_ack != 0) {
            self.segment(wire, to, flag_rst, ack_number, 0, 0, "");
        } else {
            var through = seq +% @as(u32, @intCast(data_len));
            if (flags & flag_syn != 0) through +%= 1;
            if (flags & flag_fin != 0) through +%= 1;
            self.segment(wire, to, flag_rst | flag_ack, 0, through, 0, "");
        }
    }

    /// The peer an active OPEN is to.
    pub const Remote = struct { mac: [6]u8, ip: [4]u8, port: u16 };

    /// **AN ACTIVE OPEN** (RFC 9293 §3.10.1, OPEN, active): a slot, which
    /// may be the one kept for this machine (`reserved_for_initiated`), an
    /// ephemeral port of its own, ISS from the table's source, and the SYN,
    /// with our segment size: <SEQ=ISS><CTL=SYN>. The connection is
    /// SYN-SENT until the peer answers (`synSent`), and its SYN is sent
    /// again by the retransmission timer, first after `syn_first_rto_ns`.
    /// It is let go at the first of its `deadlines` to pass. Null when no
    /// slot is free.
    pub fn connect(self: *Table, wire: anytype, to: Remote, deadlines: Deadlines, now: i96) ?usize {
        const slot = self.free(.initiated) orelse return null;
        const c = &self.conns[slot];
        c.reset();
        c.role = .initiated;
        c.peer_ip = to.ip;
        c.peer_mac = to.mac;
        c.peer_port = to.port;
        c.local_port = self.nextEphemeral();
        c.una = self.isn(); // ISS; SND.NXT is ISS + 1 once the SYN is out
        c.state = .syn_sent;
        c.deadlines = deadlines;
        c.opened_at = now;
        c.heard_at = now;
        c.rto_ns = syn_first_rto_ns;
        c.rto_at = now + c.rto_ns;
        self.connects += 1;
        self.arrivals += 1;
        c.serial = self.arrivals;
        self.noteSlots();
        self.emit(wire, slot, flag_syn, c.una, "");
        // The handshake is the first RTT sample, as for an accepted one.
        c.time(now, c.una +% 1);
        return slot;
    }

    /// The next ephemeral port no connection holds, counting up and
    /// wrapping within the dynamic range (RFC 6335 §6: 49152-65535). RFC
    /// 6056 §3.2:
    ///
    /// > As mentioned in Section 2.1, the dynamic ports consist of the range
    /// > 49152-65535.  However, ephemeral port selection algorithms should use
    /// > the whole range 1024-65535.
    ///
    /// DEPARTS (scale): only the dynamic range, counting up by one from where the
    /// host seeds `ephemeral_next`, where RFC 6056 §3.3 picks each port by
    /// an obfuscating algorithm: this machine opens a handful of
    /// connections to peers it names, behind a private network.
    fn nextEphemeral(self: *Table) u16 {
        while (true) {
            const port = self.ephemeral_next;
            self.ephemeral_next = if (port == 0xFFFF) ephemeral_first else port + 1;
            if (port == self.port or self.initiatedOn(port)) continue;
            return port;
        }
    }

    /// **WHAT SYN-SENT DOES WITH THE ANSWER** (RFC 9293 §3.10.7.3): `synSent`
    /// decides, and this acts.
    fn synSentArrives(self: *Table, wire: anytype, i: usize, seg: Segment, now: i96) Result {
        const c = &self.conns[i];
        switch (arrives.synSent(c, seg)) {
            .drop => return .{ .event = .nothing },
            .reset_it => {
                // <SEQ=SEG.ACK><CTL=RST>
                self.syn_sent_bad_acks +%= 1;
                self.segment(wire, .{ .mac = c.peer_mac, .ip = c.peer_ip, .port = c.peer_port, .from = c.local_port }, flag_rst, seg.ack, 0, 0, "");
                return .{ .event = .nothing };
            },
            .refused => {
                props.reachable(@src(), "tcp: a connection of our own is refused by the peer's reset", .{ .conn = i });
                self.abandon(wire, i, .refused);
                return .{ .event = .closed, .index = i };
            },
            .simultaneous_open => {
                self.simultaneous_opens_refused +%= 1;
                return .{ .event = .nothing };
            },
            .established => {
                // "RCV.NXT is set to SEG.SEQ+1, IRS is set to SEG.SEQ. SND.UNA
                // should be advanced to equal SEG.ACK", and the window and
                // segment size are the SYN-ACK's.
                c.rcv_nxt = seg.seq +% 1;
                // PLANT (src/plant.zig): our ACK of the SYN-ACK names the
                // server's ISS, not ISS + 1, so the server refuses the
                // handshake (native/judge_native.py's fetch cases).
                if (comptime plant.on == .client_ack_off_by_one) {
                    props.reachable(@src(), "PLANT: client-ack-off-by-one fires", null);
                    c.rcv_nxt = seg.seq;
                }
                c.una = seg.ack;
                c.wnd = seg.window;
                c.wl1 = seg.seq;
                c.wl2 = seg.ack;
                const named = parseMss(seg.options) orelse default_mss;
                c.mss = std.math.clamp(named, min_mss, our_mss);
                c.rto_at = null;
                c.retries = 0;
                c.heard_at = now;
                self.measure(c, seg.ack, now);
                if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
                c.state = .established;
                props.reachable(@src(), "tcp: a connection of our own is established", .{ .conn = i });
                // <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
                self.emit(wire, i, flag_ack, c.highest(), "");
                return .{ .event = .opened, .index = i };
            },
        }
    }

    /// Queues as much of `bytes` as fits and returns how much; `transmit`
    /// sends it. Takes nothing unless established with no FIN queued.
    pub fn queue(self: *Table, i: usize, bytes: []const u8) usize {
        const c = &self.conns[i];
        if (c.state != .established or !c.fin.is(.none)) return 0;
        if (c.tx_end + bytes.len > c.tx.len and c.tx_start > 0) {
            const len = c.queued();
            std.mem.copyForwards(u8, c.tx[0..len], c.tx[c.tx_start..c.tx_end]);
            c.tx_start = 0;
            c.tx_end = len;
        }
        const n = @min(bytes.len, c.tx.len - c.tx_end);
        @memcpy(c.tx[c.tx_end..][0..n], bytes[0..n]);
        c.tx_end += n;
        return n;
    }

    /// Tells the peer the window now. The reader calls it after consuming,
    /// so a peer that filled the window need not wait for its own probe.
    pub fn ack(self: *Table, wire: anytype, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established and c.state != .closing) return;
        self.emit(wire, i, flag_ack, c.highest(), "");
    }

    /// Queues our FIN behind the last queued byte. The connection closes once
    /// the FIN is acknowledged and the peer's has arrived, after
    /// `fin_wait_ns` without the peer's, or when the host abandons it.
    pub fn finish(self: *Table, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established) return;
        c.fin.fire(.host_finished);
        c.state = .closing;
    }

    /// Why a connection is given up on, for its count.
    /// `refused`: the peer answered our SYN with a reset (RFC 9293
    /// §3.10.7.3, "error: connection reset"), so nothing is sent back.
    /// `connect_deadline`, `idle_deadline`, `total_deadline`: a connection of
    /// our own past one of its `Deadlines`. One still SYN-SENT is let go
    /// with no reset (RFC 9293 §3.10.5, ABORT: "SYN-SENT STATE ... delete
    /// the TCB"); one past it is reset, as any ABORT is.
    pub const Abandon = enum { silent_peer, fin_wait, slow_client, stream_behind, unfinished, refused, connect_deadline, idle_deadline, total_deadline, gave_way };

    /// Gives up on connection `i` with a reset, so a peer waiting for the
    /// rest of an answer, or for its handshake, does not wait out its timer.
    pub fn abandon(self: *Table, wire: anytype, i: usize, why: Abandon) void {
        switch (why) {
            .silent_peer, .fin_wait, .gave_way => {}, // `given_up`, `fin_waits_expired`, `half_open_given_way`
            .slow_client => self.abandoned_slow_client +%= 1,
            .stream_behind => self.abandoned_stream_behind +%= 1,
            .unfinished => self.abandoned_unfinished +%= 1,
            .refused => self.connects_refused +%= 1,
            .connect_deadline => self.connect_deadlines +%= 1,
            .idle_deadline => self.idle_deadlines +%= 1,
            .total_deadline => self.total_deadlines +%= 1,
        }
        const c = &self.conns[i];
        if (c.state != .closed and c.state != .syn_sent and why != .refused) {
            self.emit(wire, i, flag_rst | flag_ack, c.highest(), "");
        }
        c.noteEnd(.{ .abandoned = why });
        c.reset();
    }

    /// **HOW FULL THE TABLE CAME**, each time a slot is taken: slots in use
    /// and half-opens against the table's size, as zig-coverage-sdk
    /// comparisons. Properties only; they show how far a run's table came
    /// toward the kernel's 256 slots.
    fn noteSlots(self: *const Table) void {
        var in_use: usize = 0;
        var half_open: usize = 0;
        for (self.conns) |c| {
            if (c.state != .closed or c.claimed) in_use += 1;
            if (c.state == .syn_received) half_open += 1;
        }
        props.alwaysLessThanOrEqualTo(@src(), in_use, self.conns.len, "tcp: slots in use stay within the table", null);
        props.alwaysLessThanOrEqualTo(@src(), half_open, self.conns.len, "tcp: half-open connections stay within the table", null);
    }

    /// The host is serving connection `i`: its slot is not to be reused.
    pub fn claim(self: *Table, i: usize) void {
        self.conns[i].claimed = true;
    }

    /// The host is done with connection `i`; its slot is free once closed.
    pub fn release(self: *Table, i: usize) void {
        self.conns[i].claimed = false;
    }

    /// One turn of the send side for every connection.
    pub fn transmit(self: *Table, wire: anytype, now: i96) void {
        for (self.conns, 0..) |c, i| {
            if (c.state == .closed) continue;
            self.transmitOne(wire, i, now);
        }
    }

    fn transmitOne(self: *Table, wire: anytype, i: usize, now: i96) void {
        // A connection of our own past a deadline sends nothing more.
        if (pastDeadline(&self.conns[i], now)) |which| {
            props.reachable(@src(), "tcp: a connection of our own is let go at a deadline", .{ .conn = i, .which = which });
            return self.abandon(wire, i, switch (which) {
                .connect => .connect_deadline,
                .idle => .idle_deadline,
                .total => .total_deadline,
            });
        }
        self.announce(wire, i, now);
        const c = &self.conns[i];
        const expired = if (c.rto_at) |at| now >= at else false;

        if (c.fin.is(.acknowledged)) {
            // FIN-WAIT-2: nothing of ours in flight.
            if (c.fin_wait_until) |until| if (now >= until) {
                self.fin_waits_expired += 1;
                self.abandon(wire, i, .fin_wait);
            };
            return;
        }

        if (c.state == .syn_sent) {
            // Our SYN was lost, or its SYN-ACK was (RFC 9293 §3.8.1).
            if (!expired) return;
            if (!timeouts.backoff(c, now)) return self.giveUp(wire, i);
            self.retransmits += 1;
            props.reachable(@src(), "tcp: a lost SYN is sent again", .{ .conn = i });
            c.timed_at = null; // Karn: no telling which copy the SYN-ACK answers
            self.emit(wire, i, flag_syn, c.una, "");
            return;
        }

        if (c.state == .syn_received) {
            // The SYN-ACK was lost, or its answer was.
            if (!expired) return;
            if (!timeouts.backoff(c, now)) return self.giveUp(wire, i);
            self.retransmits += 1;
            props.reachable(@src(), "tcp: a lost SYN-ACK is sent again", .{ .conn = i });
            c.timed_at = null; // Karn: no telling which copy the ACK answers
            self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            return;
        }

        // A timeout owes the window one probe, if it is shut: one byte.
        var probe: enum { none, owed } = .none;
        if (expired) {
            if (!timeouts.backoff(c, now)) return self.giveUp(wire, i);
            // **THE OLDEST SEGMENT AGAIN** (RFC 6298 (5.4): "Retransmit the
            // earliest segment that has not been acknowledged by the TCP
            // receiver"): from `una`, and no further than one segment until
            // the peer acknowledges it (`recovery`).
            // **A SHUT WINDOW IS NOT A LOSS** (metal-vmm QUEUE 227): its
            // timeout is the persist timer's, and owes a probe, not a
            // recovery; what the window refused goes again whole when it
            // opens.
            c.sent = 0;
            if (c.wnd != 0) timeouts.recover(c);
            if (c.fin.is(.sent)) c.fin.fire(.timed_out);
            c.timed_at = null; // Karn: no telling which copy is answered
            self.retransmits += 1;
            props.reachable(@src(), "tcp: the timer goes back to the oldest unacknowledged byte", .{ .conn = i, .retries = c.retries });
            probe = .owed;
            // PLANT (src/plant.zig): every go-back with data overwrites the
            // oldest unacknowledged byte, so a copy the peer never had
            // arrives wrong ('#' or '$', never back to what it was: a flip
            // undoes itself on an even number of go-backs).
            if (comptime plant.on == .net_goback_byte) if (c.queued() > 0) {
                props.reachable(@src(), "PLANT: net-goback-byte fires", null);
                c.tx[c.tx_start] = if (c.tx[c.tx_start] == '#') '$' else '#';
            };
        }

        while (c.queued() > c.sent) {
            // While recovering, nothing past `una + recovery`: checked before
            // the window rule, so a cap reached is never taken for a shut
            // window and probed past.
            if (c.recovery) |cap| if (c.sent >= cap) break;
            const usable = if (c.wnd > c.sent) c.wnd - c.sent else 0;
            var n = @min(c.queued() - c.sent, usable, c.mss);
            if (c.recovery) |cap| n = @min(n, cap - c.sent);
            if (n == 0) {
                // **A SHUT WINDOW IS PROBED WHEN THE TIMER RUNS OUT** (RFC
                // 9293 §3.8.6.1), with one byte; the answer carries the window.
                if (probe == .none) {
                    if (c.rto_at == null) c.rto_at = now + c.rto_ns;
                    break;
                }
                self.probes += 1;
                props.reachable(@src(), "tcp: a shut window is probed", .{ .conn = i });
                // **A PROBE IS A QUESTION, NOT A SEND** (metal-vmm QUEUE
                // 227): its byte is `high`'s, so an ACK that takes it counts,
                // but not `sent`'s, since a shut window takes nothing. RFC
                // 9293 §3.4:
                // > Note that when the receive window is zero no segments should be
                // > acceptable except ACK segments.
                // Counted as sent, a refused probe left a hole at `una` when
                // the window opened. It is never timed: its byte goes again,
                // in the probe after it or the segment that follows the
                // opening (Karn).
                const seq = c.una +% @as(u32, @intCast(c.sent));
                self.emit(wire, i, flag_psh | flag_ack, seq, c.tx[c.tx_start + c.sent ..][0..1]);
                c.high = @max(c.high, c.sent + 1);
                if (c.rto_at == null) c.rto_at = now + c.rto_ns;
                break;
            }
            probe = .none;
            const first_time = c.sent + n > c.high;
            self.emit(wire, i, flag_psh | flag_ack, c.una +% @as(u32, @intCast(c.sent)), c.tx[c.tx_start + c.sent ..][0..n]);
            c.sent += n;
            if (first_time) c.time(now, c.una +% @as(u32, @intCast(c.sent)));
            c.high = @max(c.high, c.sent);
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }

        if (c.fin.in(.owed) and c.sent == c.queued()) {
            self.emit(wire, i, flag_fin | flag_ack, c.una +% @as(u32, @intCast(c.sent)), "");
            c.fin.fire(.fin_emitted);
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }
        // No debt without a clock: whatever the peer has not acknowledged
        // is timed.
        props.always(@src(), c.highest() == c.una or c.rto_at != null, "tcp: what is outstanding has its retransmission timer", .{ .conn = i });
    }

    /// **THE RECEIVE SIDE'S ONE TIMER.** A window the peer last saw too small,
    /// with room again, is announced (here, if the reader's `ack` did not),
    /// then repeated from `rto_ns`, doubling, until the peer sends data or
    /// its FIN, or `max_retries` repeats pass.
    fn announce(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        if (c.state != .established and c.state != .closing) return;
        if (c.peerDone()) return c.heard();
        if (c.tight(c.told_wnd) and !c.tight(c.window())) {
            self.emit(wire, i, flag_ack, c.highest(), "");
        }
        switch (c.window_news) {
            .none => return,
            .said_once => {
                c.window_news = .repeating;
                c.update_at = now + c.rto_ns;
                return;
            },
            .repeating => {},
        }
        props.always(@src(), c.update_at != null, "tcp: a reopened window said again has its clock", .{ .conn = i });
        const at = c.update_at orelse return;
        if (now < at) return;
        if (c.updates >= max_retries) {
            // The peer has nothing more to send: the debt lapses.
            c.heard();
            return;
        }
        c.updates += 1;
        self.window_updates += 1;
        props.reachable(@src(), "tcp: a reopened window is announced again", .{ .conn = i, .updates = c.updates });
        const wait = @min(c.rto_ns * (@as(u64, 1) << @intCast(c.updates)), max_rto_ns);
        // Set before the emit, which clears it if the window has shut again.
        c.update_at = now + wait;
        self.emit(wire, i, flag_ack, c.highest(), "");
    }

    /// RFC 5681's fast retransmit: the oldest segment again, now, without
    /// touching the backoff, since a hole is not evidence of a slower path.
    /// It recovers as a timeout does (`recovery`, one segment and doubling;
    /// metal-vmm QUEUE 225, chunk 0b), where it once went back over the
    /// whole window; with no congestion control there is no fast recovery.
    fn resend(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        c.dupacks = 0;
        c.duplicates = .answered;
        c.sent = 0;
        timeouts.recover(c);
        if (c.fin.is(.sent)) c.fin.fire(.resent_early);
        c.timed_at = null; // Karn, the same as after a timeout
        c.rto_at = now + c.rto_ns;
        self.retransmits += 1;
        self.fast_retransmits += 1;
        props.reachable(@src(), "tcp: three duplicate ACKs resend at once", .{ .conn = i });
        self.transmitOne(wire, i, now);
    }

    /// Takes the sample if this ACK covers the timed segment, folded in as
    /// RFC 6298 §2 says (alpha 1/8, beta 1/4).
    fn measure(self: *Table, c: *Conn, number: u32, now: i96) void {
        const at = c.timed_at orelse return;
        if (!sq.atOrAfter(number, c.timed_seq)) return; // not there yet
        c.timed_at = null;
        timeouts.fold(c, @intCast(@max(0, now - at)));
        self.samples += 1;
        self.measured_ns = c.srtt_ns;
    }

    fn giveUp(self: *Table, wire: anytype, i: usize) void {
        self.given_up += 1;
        props.reachable(@src(), "tcp: a silent peer is given up on", .{ .conn = i });
        self.abandon(wire, i, .silent_peer);
    }

    /// Takes the peer's ACK and window as RFC 9293 §3.10.7.4 does in
    /// ESTABLISHED: SND.UNA < SEG.ACK =< SND.NXT moves `una`, and SND.WL1/WL2
    /// decide whether `wnd` moves. True if this ACK covers our FIN.
    fn acknowledge(self: *Table, c: *Conn, seq: u32, number: u32, window: u16, now: i96) bool {
        const check = ackCheck(c, number);
        const advance = sq.offset(c.una, number);
        // An ACK of something never sent, or an old one (wrapping to a huge
        // advance), is ignored, window included. The RFC also drops and
        // answers a segment that acknowledges what was never sent; here only
        // its ACK is ignored.
        if (check == .ignore) return false;
        const updated = sq.after(seq, c.wl1) or (seq == c.wl1 and !sq.after(c.wl2, number));
        const was_shut = c.wnd == 0;
        if (updated) {
            c.wnd = window;
            c.wl1 = seq;
            c.wl2 = number;
        }
        // **A WINDOW THAT REOPENS ON AN ACK OF NOTHING NEW REFUSED WHAT WAS
        // SENT PAST `una`** (metal-vmm QUEUE 227): the probe byte, and any
        // segment that reached it shut. RFC 9293 §3.8.6.1:
        // > When the receiving TCP peer has a zero window and a segment arrives,
        // > it must still send an acknowledgment showing its next expected
        // > sequence number and current window (zero).
        // So sending starts again at `una`; otherwise the next segment
        // starts past the refused byte, is dropped as ahead of a hole, and
        // draws one duplicate ACK where three resend, leaving the rest to
        // the backed-off timer.
        if (check == .duplicate and was_shut and c.wnd > 0 and c.sent > 0) {
            props.reachable(@src(), "tcp: a window reopens on an ACK of nothing new, and sending starts again at una", .{ .sent = c.sent });
            c.sent = 0;
            c.timed_at = null; // Karn: what goes now is sent again
        }
        if (check == .duplicate) return false;

        const bytes = @min(advance, c.queued());
        c.tx_start += bytes;
        // An ACK may cover more than `sent`, and rightly: a go-back sets
        // `sent` to 0, and a late ACK then covers bytes this pass has not
        // sent again. So each is held at 0, not past it.
        c.sent -= @min(c.sent, bytes);
        c.high -= @min(c.high, bytes);
        if (c.tx_start == c.tx_end) {
            c.tx_start = 0;
            c.tx_end = 0;
        }
        c.una +%= advance;
        // DEPARTS (stricter): `wnd` shrinks by each advance the window rule skips, so
        // the right edge stays where the peer put it, where RFC 9293 keeps
        // SND.WND and lets SND.UNA + SND.WND move forward.
        // **THE WINDOW IS MEASURED FROM `una`.** When the window rule skipped
        // this segment's window, `wnd` shrinks by the advance, so the right
        // edge stays where the peer put it. (RFC 9293's SND.UNA + SND.WND
        // would let it move forward.)
        if (!updated) c.wnd -= @min(c.wnd, advance);
        if (advance > bytes) {
            // Past every byte, an ACK can cover only our FIN, which takes one.
            props.always(@src(), c.fin.in(.numbered) and advance == @as(u32, @intCast(bytes)) + 1, "tcp: an ACK past every byte covers our FIN and nothing more", .{ .advance = advance, .bytes = bytes });
            c.fin.fire(.fin_acknowledged);
            c.high = 0;
            c.sent = 0;
        }

        // **RECOVERY GROWS BY TWICE WHAT WAS ACKNOWLEDGED** (RFC 6298 (5.4)'s
        // one segment, then doubling each round trip), and ends once it
        // covers all that was sent (`high`, after this ACK).
        timeouts.recovered(c, advance);
        c.retries = 0;
        self.measure(c, number, now);
        if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
        c.rto_at = if (c.highest() != c.una) now + c.rto_ns else null;
        props.always(@src(), c.sent <= c.high and c.high <= c.queued(), "tcp: after an ACK, what was sent lies within what is queued", .{ .sent = c.sent, .high = c.high, .queued = c.queued() });
        return c.fin.is(.acknowledged);
    }

    /// **WHAT `handle` TAKES OF A FRAME**: an IPv4 TCP segment for this
    /// machine, on a port the table holds, its checksum good. Anything else is
    /// counted where it is passed by, and null.
    fn admit(self: *Table, frame: []const u8) ?proto.Packet {
        const pkt = switch (proto.readIpv4(frame)) {
            .packet => |p| p,
            .not => |why| {
                self.passed.note(why);
                return null;
            },
        };
        if (pkt.protocol != proto.proto_tcp) {
            self.passed.not_tcp +%= 1;
            return null;
        }
        if (!eql(&pkt.dst_ip, &self.local_ip)) {
            self.passed.not_for_us +%= 1;
            return null;
        }
        if (pkt.payload.len < header_len) {
            self.passed.malformed_ip +%= 1;
            return null;
        }

        const t = pkt.payload;
        // RFC 9293 §3.10.7.1, CLOSED STATE:
        // > If the state is CLOSED (i.e., TCB does not exist), then
        // >
        // >    all data in the incoming segment is discarded.  An incoming
        // >    segment containing a RST is discarded.  An incoming segment not
        // >    containing a RST causes a RST to be sent in response.  The
        // >    acknowledgment and sequence field values are selected to make the
        // >    reset sequence acceptable to the TCP endpoint that sent the
        // >    offending segment.
        // >
        // >    If the ACK bit is off, sequence number zero is used,
        // >
        // >       <SEQ=0><ACK=SEG.SEQ+SEG.LEN><CTL=RST,ACK>
        // >
        // >    If the ACK bit is on,
        // >
        // >       <SEQ=SEG.ACK><CTL=RST>
        // >
        // >    Return.
        // DEPARTS (bounded): a segment to a port nobody listens on is dropped silently,
        // where CLOSED (RFC 9293 §3.10.7.1) answers it with a reset.
        const dst_port = proto.readBe16(t[2..4]);
        if (dst_port != self.port and !self.initiatedOn(dst_port)) {
            self.passed.not_for_us +%= 1;
            return null;
        }
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) {
            self.damaged += 1;
            props.reachable(@src(), "tcp: a damaged segment is dropped", null);
            return null;
        }
        return pkt;
    }

    /// **A SYN FOR NO CONNECTION OPENS ONE** (LISTEN, `handle`): a free slot,
    /// or the oldest half-open's, given way; the peer's segment size held to
    /// ours and the least; SYN-RECEIVED, and our SYN-ACK, the handshake the
    /// first RTT sample. With no slot to take, refused.
    fn accept(self: *Table, wire: anytype, pkt: proto.Packet, seg: Segment, now: i96) void {
        const src_port = seg.src_port;
        const seq = seg.seq;
        const window = seg.window;
        const slot = self.free(.accepted) orelse self.oldestHalfOpen(now) orelse {
            self.refused += 1;
            props.reachable(@src(), "tcp: a SYN finds the table full, and nothing to give way", null);
            return;
        };
        const c = &self.conns[slot];
        c.reset();
        c.peer_ip = pkt.src_ip;
        c.peer_mac = pkt.src_mac;
        c.peer_port = src_port;
        c.local_port = self.port;
        c.rcv_nxt = seq +% 1; // their SYN takes one
        c.wl1 = seq;
        c.una = self.isn();
        const named = parseMss(seg.options) orelse default_mss;
        if (named < min_mss) props.reachable(@src(), "tcp: a peer names a segment size under the least, and is sent the least", .{ .named = named });
        c.mss = std.math.clamp(named, min_mss, our_mss);
        c.wnd = window;
        self.enterSynReceived(c, now);
        self.emit(wire, slot, flag_syn | flag_ack, c.una, "");
        // The handshake is the first RTT sample.
        c.time(now, c.una +% 1);
    }

    /// **THE HANDSHAKE COMPLETES** (SYN-RECEIVED, `handle`): the peer's ACK
    /// of our SYN, checked already, takes `una` and the window, and the
    /// connection is ESTABLISHED.
    fn establish(self: *Table, c: *Conn, seg: Segment, now: i96) void {
        const seq = seg.seq;
        const number = seg.ack;
        const window = seg.window;
        c.una = number;
        c.wnd = window;
        c.wl1 = seq;
        c.wl2 = number;
        c.rto_at = null;
        c.retries = 0;
        self.measure(c, number, now);
        if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
        c.state = .established;
    }

    /// **AN ACK IN A SYNCHRONIZED STATE** (`handle`): acknowledged
    /// (`acknowledge`), and a duplicate counted toward the resend. True when
    /// it acknowledged our FIN.
    fn takeAck(self: *Table, wire: anytype, i: usize, seg: Segment, now: i96) bool {
        const c = &self.conns[i];
        const seq = seg.seq;
        const number = seg.ack;
        const flags = seg.ctl.byte();
        const window = seg.window;
        const data = seg.data;
        const was = c.una;
        const held = c.wnd;
        const fin_acknowledged = self.acknowledge(c, seq, number, window, now);
        // **A DUPLICATE ACK** (RFC 5681 §2): no data, SYN or FIN; names
        // SND.UNA exactly; leaves the window unchanged; and something of
        // ours is outstanding. It says the peer received what came after
        // a hole; the third resends at once.
        //
        // **NOT WHILE THE WINDOW IS SHUT, AND ONCE PER LOSS.** A peer
        // with no room answers every probe with the same ACK, which is no
        // news of a loss; and a peer repeating itself forever must not
        // hold the connection open by pushing the timer out, so there is
        // no second resend until `una` moves.
        const bare = data.len == 0 and flags & flag_fin == 0 and flags & flag_syn == 0;
        if (c.una != was) {
            c.dupacks = 0;
            c.duplicates = .counting;
        } else if (bare and number == c.una and c.wnd == held and c.wnd != 0 and c.highest() != c.una) {
            // Counted to the resend and no further: a peer repeating
            // itself forever must not overflow the count.
            if (c.dupacks < dupacks_before_resend) c.dupacks += 1;
            props.alwaysLessThanOrEqualTo(@src(), c.dupacks, dupacks_before_resend, "tcp: duplicate ACKs are counted to the resend and no further", null);
            if (c.dupacks == dupacks_before_resend and c.duplicates == .counting) self.resend(wire, i, now);
        }
        return fin_acknowledged;
    }

    /// **THE SEGMENT'S TEXT, TAKEN** (`handle`, the next segment's): what
    /// fits, and what it makes whole of the text held ahead. Gives how much of
    /// `data` was taken; the ACK that follows names the new RCV.NXT.
    fn takeText(self: *Table, c: *Conn, data: []const u8) usize {
        // **WHAT FITS IS TAKEN, AND ONLY THAT IS ACKNOWLEDGED.** The peer
        // resends the rest once the reader makes room; a FIN behind the
        // untaken part waits for it.
        const n = @min(c.room(), data.len);
        props.sometimes(@src(), n < data.len, "tcp: a peer sends past the window and only what fits is taken", .{ .room = c.room(), .len = data.len });
        if (n < data.len) self.past_window +%= 1;
        @memcpy(c.rx[c.end..][0..n], data[0..n]);
        c.end += n;
        c.rcv_nxt +%= @intCast(n);
        if (n > 0) c.heard();
        // **WHAT IT MAKES WHOLE IS TAKEN TOO**, and the one ACK after it
        // names the new RCV.NXT. RFC 5681 §4.2:
        // > provide feedback to senders recovering from losses, the receiver
        // > SHOULD send an immediate ACK when it receives a data segment that
        // > fills in all or part of a gap in the sequence space.
        if (n > 0 and !c.held.empty()) {
            const more = c.held.advance(@intCast(n));
            if (more > 0) {
                c.end += more;
                c.rcv_nxt +%= more;
                self.held_delivered +%= more;
                props.reachable(@src(), "tcp: a hole filled delivers what was held behind it", .{ .bytes = more });
            }
        }
        return n;
    }

    /// Feeds one received frame in. `now` is the caller's clock.
    pub fn handle(self: *Table, wire: anytype, frame: []const u8, now: i96) Result {
        const pkt = self.admit(frame) orelse return .{ .event = .nothing };
        const t = pkt.payload;
        const dst_port = proto.readBe16(t[2..4]);
        const seg = Segment.parse(t) orelse return .{ .event = .nothing };
        const src_port = seg.src_port;
        const seq = seg.seq;
        const number = seg.ack;
        const flags = seg.ctl.byte();
        const window = seg.window;
        const data = seg.data;

        var found = self.find(pkt.src_ip, src_port, dst_port);

        // **SYN-SENT FIRST** (RFC 9293 §3.10.7.3): a connection of our own,
        // waiting for its SYN-ACK, is decided by `synSent` before the RST
        // and SYN checks below, which are the synchronized states'.
        if (found) |i| if (self.conns[i].state == .syn_sent) return self.synSentArrives(wire, i, seg, now);

        // RFC 9293 §3.10.7.4, the synchronized states' RST check, which this
        // block does (`resetCheck` quotes the RFC 5961 checks):
        // > Second, check the RST bit:
        // >
        // > -  RFC 5961 [9], Section 3 describes a potential blind reset
        // >    attack and optional mitigation approach.  This does not provide
        // >    a cryptographic protection (e.g., as in IPsec or TCP-AO) but
        // >    can be applicable in situations described in RFC 5961.  For
        // >    stacks implementing the protection described in RFC 5961, the
        // >    three checks below apply; otherwise, processing for these
        // >    states is indicated further below.
        // And in LISTEN (§3.10.7.2), where a reset finds no connection:
        // > First, check for a RST:
        // >
        // > -  An incoming RST segment could not be valid since it could not
        // >    have been sent in response to anything sent by this incarnation
        // >    of the connection.  An incoming RST should be ignored.  Return.
        // DEPARTS (stricter): RST is checked first, before the sequence number's
        // acceptability (RFC 9293 §3.10.7.4 checks the sequence first, then
        // RST); `resetCheck` asks the same question of a reset's number.
        if (flags & flag_rst != 0) {
            // **A RESET MUST NAME RCV.NXT EXACTLY** (RFC 9293 §3.10.7.4,
            // after RFC 5961). One ahead draws a challenge ACK, which a
            // genuine peer answers with an exact reset; others are ignored.
            const i = found orelse return .{ .event = .nothing };
            const c = &self.conns[i];
            const check = resetCheck(c, seq);
            props.sometimes(@src(), check == .exact, "tcp: an exact reset closes a connection", null);
            props.sometimes(@src(), check == .challenge, "tcp: an inexact reset in the window draws a challenge ACK", null);
            switch (check) {
                .exact => {
                    self.resets_received +%= 1;
                    return self.close(i, .reset_by_peer);
                },
                .challenge => {
                    self.challenge_acks +%= 1;
                    self.emit(wire, i, flag_ack, c.highest(), "");
                },
                .ignore => {},
            }
            return .{ .event = .nothing };
        }

        // **REVIVED BY ITS CLIENT'S ACK**: an ACK for no connection that a
        // given-way half-open would have taken rebuilds it, and the segment
        // is handled as usual. With no room it is dropped without a reset,
        // so the client sends again and may find room then.
        if (found == null and flags & flag_ack != 0 and flags & flag_syn == 0) {
            if (self.revivableFor(pkt.src_ip, src_port, number)) |slot| {
                // The entry leaves the ring first: a revival into a stuck
                // half-open's slot puts that one in the ring, maybe here.
                // With no room nothing gave way, and the entry goes back.
                const kept = slot.*.?;
                slot.* = null;
                found = self.revive(kept, now) orelse {
                    slot.* = kept;
                    self.revival_no_room += 1;
                    props.reachable(@src(), "tcp: a revival finds no slot, and the ACK is dropped", null);
                    return .{ .event = .nothing };
                };
                self.revived += 1;
                props.reachable(@src(), "tcp: a given-way half-open is revived by its client's ACK", .{ .conn = found.? });
            }
        }

        // RFC 9293 §3.10.7.2, LISTEN STATE (its first step, the RST, is
        // above):
        // > Second, check for an ACK:
        // >
        // > -  Any acknowledgment is bad if it arrives on a connection still
        // >    in the LISTEN state.  An acceptable reset segment should be
        // >    formed for any arriving ACK-bearing segment.  The RST should be
        // >    formatted as follows:
        // >
        // >       <SEQ=SEG.ACK><CTL=RST>
        // >
        // > -  Return.
        //
        // > Third, check for a SYN:
        // >
        // > -  If the SYN bit is set, check the security.  If the security/
        // >    compartment on the incoming segment does not exactly match the
        // >    security/compartment in the TCB, then send a reset and return.
        // >
        // >       <SEQ=0><ACK=SEG.SEQ+SEG.LEN><CTL=RST,ACK>
        // >
        // > -  Set RCV.NXT to SEG.SEQ+1, IRS is set to SEG.SEQ, and any other
        // >    control or text should be queued for processing later.  ISS
        // >    should be selected and a SYN segment sent of the form:
        // >
        // >       <SEQ=ISS><ACK=RCV.NXT><CTL=SYN,ACK>
        // >
        // > -  SND.NXT is set to ISS+1 and SND.UNA to ISS.  The connection
        // >    state should be changed to SYN-RECEIVED.  Note that any other
        // >    incoming control or data (combined with SYN) will be processed
        // >    in the SYN-RECEIVED state, but processing of SYN and ACK should
        // >    not be repeated.  If the listen was not fully specified (i.e.,
        // >    the remote socket was not fully specified), then the
        // >    unspecified fields should be filled in now.
        //
        // > Fourth, other data or control:
        // >
        // > -  This should not be reached.  Drop the segment and return.  Any
        // >    other control or data-bearing segment (not containing SYN) must
        // >    have an ACK and thus would have been discarded by the ACK
        // >    processing in the second step, unless it was first discarded by
        // >    RST checking in the first step.
        // The security check does not apply: there are no compartments.
        // The table is LISTEN (RFC 9293 §3.10.7.2) on its own port: a SYN for
        // no connection opens one if there is a slot; anything else is
        // refused. A port of this machine's own connections listens for
        // nothing: what is not for one of them is dropped, as for no port.
        const i = found orelse {
            if (dst_port != self.port) {
                self.passed.not_for_us +%= 1;
                return .{ .event = .nothing };
            }
            // DEPARTS (fast): a segment with neither SYN nor ACK is answered with a
            // reset (`refuse`, RST|ACK, as CLOSED answers it), where LISTEN
            // (RFC 9293 §3.10.7.2, fourth) drops it.
            if (flags & flag_syn == 0 or flags & flag_ack != 0) {
                props.reachable(@src(), "tcp: a segment for no connection is refused", null);
                self.refuse(wire, .{ .mac = pkt.src_mac, .ip = pkt.src_ip, .port = src_port, .from = dst_port }, seq, number, flags, data.len);
                return .{ .event = .nothing };
            }
            self.accept(wire, pkt, seg, now);
            return .{ .event = .nothing };
        };

        const c = &self.conns[i];

        // RFC 9293 §3.10.7.4:
        // > Fourth, check the SYN bit:
        // >
        // > -  SYN-RECEIVED STATE
        // >
        // >    o  If the connection was initiated with a passive OPEN, then
        // >       return this connection to the LISTEN state and return.
        // >       Otherwise, handle per the directions for synchronized states
        // >       below.
        //
        // > o  If the SYN bit is set in these synchronized states, it may
        // >    be either a legitimate new connection attempt (e.g., in the
        // >    case of TIME-WAIT), an error where the connection should be
        // >    reset, or the result of an attack attempt, as described in
        // >    RFC 5961 [9].  For the TIME-WAIT state, new connections can
        // >    be accepted if the Timestamp Option is used and meets
        // >    expectations (per [40]).  For all other cases, RFC 5961
        // >    provides a mitigation with applicability to some situations,
        // >    though there are also alternatives that offer cryptographic
        // >    protection (see Section 7).  RFC 5961 recommends that in
        // >    these synchronized states, if the SYN bit is set,
        // >    irrespective of the sequence number, TCP endpoints MUST send
        // >    a "challenge ACK" to the remote peer:
        // >
        // >    <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
        // >
        // > o  After sending the acknowledgment, TCP implementations MUST
        // >    drop the unacceptable segment and stop processing further.
        // >    Note that RFC 5961 and Errata ID 4772 [99] contain
        // >    additional ACK throttling notes for an implementation.
        // DEPARTS (stricter): SYN is checked before the sequence number's acceptability
        // (RFC 9293 §3.10.7.4 checks the SYN fourth).
        // A repeated SYN in SYN-RECEIVED means our SYN-ACK was lost or is
        // late: it is sent again, from ISS, as Linux does (the RFC's
        // sequence test would send a bare ACK). In any later state it draws
        // a challenge ACK (RFC 9293, after RFC 5961 §4).
        if (flags & flag_syn != 0) {
            if (c.state == .syn_received) {
                c.timed_at = null; // Karn, as when the timer sends it again
                self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            } else self.emit(wire, i, flag_ack, c.highest(), "");
            return .{ .event = .nothing };
        }

        // > Fifth, check the ACK field:
        // >
        // > -  if the ACK bit is off, drop the segment and return
        // No ACK bit: dropped (RFC 9293 §3.10.7.4, fifth check).
        // DEPARTS (bounded): dropped before the first check's answer, so an
        // unacceptable segment with no ACK draws no ACK in reply.
        if (flags & flag_ack == 0) return .{ .event = .nothing };

        // RFC 9293 §3.10.7.4, "First, check sequence number" (quoted whole
        // at `acceptability`, tcp_arrives.zig):
        // > o  If an incoming segment is not acceptable, an acknowledgment
        // >    should be sent in reply (unless the RST bit is set, if so
        // >    drop the segment and return):
        // >
        // >    <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
        // >
        // > o  After sending the acknowledgment, drop the unacceptable
        // >    segment and return.
        // Third, the security check, does not apply: there are no
        // compartments.
        //
        // **A SEGMENT THAT IS NOT THE NEXT ONE IS ANSWERED, NOT TAKEN.**
        //
        // - **the next** (`seq == rcv_nxt`): acceptable, and taken;
        // - **ahead** (`c.ahead(seq)`): acceptable, so its ACK and window
        //   count, and its data and FIN are held until the hole before them
        //   fills (`holdAhead`, QUEUE 226), and re-acknowledged;
        // - **from behind** (a repeated FIN, a keepalive) or beyond the
        //   window: not acceptable, and answered with an ACK.
        //
        // A segment that starts behind and runs past `rcv_nxt` is from behind
        // here; the RFC would trim it and take the new part, which the peer
        // instead resends.
        //
        // From behind, its ACK still counts if it moves `una`, where the RFC
        // drops the segment whole: ACKs are cumulative, and a peer repeating
        // its FIN after ours was acknowledged would otherwise wait on a timer
        // for nothing. (WL1/WL2 keep it from setting the window.)
        const acceptable = acceptability(c, seq);
        const early = acceptable == .ahead;
        props.sometimes(@src(), early, "tcp: a segment arrives ahead of the next expected byte", null);
        if (acceptable == .behind or acceptable == .beyond) {
            // A resend of what was taken (a bare ACK carries nothing to count).
            if (data.len > 0 or flags & flag_fin != 0) self.arrived_behind +%= 1;
            props.reachable(@src(), "tcp: a segment from behind is answered, not taken", .{ .conn = i });
            // **ONLY FROM BEHIND, NOT BEYOND.** The peer cannot yet have
            // sent a segment past our window; taking its ACK would let a
            // forged one set SND.WL1 to a sequence the peer never reaches,
            // after which the window rule rejects every genuine update.
            // At or before rcv_nxt; half the circle away is neither, and not behind.
            // DEPARTS (fast): from behind, its ACK still counts, where the RFC drops
            // an unacceptable segment whole (the paragraph above).
            const behind = acceptable == .behind;
            const done = behind and c.state != .syn_received and
                self.acknowledge(c, seq, number, window, now);
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (done) return self.settle(i, .nothing, true, now);
            return .{ .event = .nothing };
        }
        c.heard_at = now;

        var event: Event = .nothing;
        var fin_acknowledged = false;
        if (c.state == .syn_received) {
            // DEPARTS (simpler): a segment ahead in SYN-RECEIVED is answered and
            // dropped, its ACK not taken: the handshake completes only on the
            // next byte.
            if (early) {
                self.emit(wire, i, flag_ack, c.highest(), "");
                return .{ .event = .nothing };
            }
            if (ackCheck(c, number) == .reset_it) {
                // An unacceptable ACK draws <SEQ=SEG.ACK><CTL=RST> (RFC 9293
                // §3.10.7.4, SYN-RECEIVED).
                self.bad_ack_resets +%= 1;
                self.segment(wire, .{ .mac = c.peer_mac, .ip = c.peer_ip, .port = c.peer_port, .from = c.local_port }, flag_rst, number, 0, 0, "");
                return .{ .event = .nothing };
            }
            self.establish(c, seg, now);
            event = .opened;
            // The ACK may carry the first data: fall through.
        } else fin_acknowledged = self.takeAck(wire, i, seg, now);

        if (early) {
            // **AHEAD: HELD, AND RE-ACKNOWLEDGED AT ONCE** (metal-vmm QUEUE
            // 226), the duplicate ACK asking for the next byte. RFC 5681 §4.2:
            // > Out-of-order data segments SHOULD be acknowledged immediately, in
            // > order to accelerate loss recovery.  To trigger the fast retransmit
            // > algorithm, the receiver SHOULD send an immediate duplicate ACK when
            // > it receives a data segment above a gap in the sequence space.  To
            if (data.len > 0 or flags & flag_fin != 0) {
                self.arrived_ahead +%= 1;
                self.holdAhead(c, seq, data, flags & flag_fin != 0);
                self.emit(wire, i, flag_ack, c.highest(), "");
            }
            return self.settle(i, event, fin_acknowledged, now);
        }

        // RFC 9293 §3.10.7.4:
        // > Sixth, check the URG bit:
        // >
        // > -  ESTABLISHED STATE
        // >
        // > -  FIN-WAIT-1 STATE
        // >
        // > -  FIN-WAIT-2 STATE
        // >
        // >    o  If the URG bit is set, RCV.UP <- max(RCV.UP,SEG.UP), and
        // >       signal the user that the remote side has urgent data if the
        // >       urgent pointer (RCV.UP) is in advance of the data consumed.
        // >       If the user has already been signaled (or is still in the
        // >       "urgent mode") for this continuous sequence of urgent data,
        // >       do not signal the user again.
        // Not applicable: URG is neither read nor sent.
        //
        // > Seventh, process the segment text:
        // >
        // > -  ESTABLISHED STATE
        // >
        // > -  FIN-WAIT-1 STATE
        // >
        // > -  FIN-WAIT-2 STATE
        // >
        // >    o  Once in the ESTABLISHED state, it is possible to deliver
        // >       segment data to user RECEIVE buffers.  Data from segments
        // >       can be moved into buffers until either the buffer is full or
        // >       the segment is empty.  If the segment empties and carries a
        // >       PUSH flag, then the user is informed, when the buffer is
        // >       returned, that a PUSH has been received.
        // >
        // >    o  When the TCP endpoint takes responsibility for delivering
        // >       the data to the user, it must also acknowledge the receipt
        // >       of the data.
        // >
        // >    o  Once the TCP endpoint takes responsibility for the data, it
        // >       advances RCV.NXT over the data accepted, and adjusts RCV.WND
        // >       as appropriate to the current buffer availability.  The
        // >       total of RCV.NXT and RCV.WND should not be reduced.
        // >
        // >    o  A TCP implementation MAY send an ACK segment acknowledging
        // >       RCV.NXT when a valid segment arrives that is in the window
        // >       but not at the left window edge (MAY-13).
        // >
        // >    o  Please note the window management suggestions in
        // >       Section 3.8.
        // >
        // >    o  Send an acknowledgment of the form:
        // >
        // >       <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
        if (data.len > 0) {
            if (c.peerDone()) {
                self.emit(wire, i, flag_ack, c.highest(), "");
                return self.settle(i, event, fin_acknowledged, now);
            }
            const n = self.takeText(c, data);
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (n > 0 and event == .nothing) event = .data;
            if (n < data.len) return self.settle(i, event, fin_acknowledged, now);
        }

        // > Eighth, check the FIN bit:
        // >
        // > -  Do not process the FIN if the state is CLOSED, LISTEN, or SYN-
        // >    SENT since the SEG.SEQ cannot be validated; drop the segment
        // >    and return.
        // >
        // > -  If the FIN bit is set, signal the user "connection closing" and
        // >    return any pending RECEIVEs with same message, advance RCV.NXT
        // >    over the FIN, and send an acknowledgment for the FIN.  Note
        // >    that FIN implies PUSH for any segment text not yet delivered to
        // >    the user.
        // No TIME-WAIT is kept: a connection whose FIN is acknowledged closes
        // when the peer's FIN arrives (`close`).
        // DEPARTS (simpler): text and a FIN in one segment draw two ACKs, the text's
        // and the FIN's, where RFC 9293 §3.10.7.4 sends one after both.
        // A FIN held ahead (`holdAhead`) is taken when the bytes before it
        // are: by this segment's text, or by what that text made whole.
        const fin_here = flags & flag_fin != 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt;
        const fin_held = c.held.finReached();
        if (fin_held) {
            c.held.fin_at = null;
            props.reachable(@src(), "tcp: a FIN held ahead is taken once the bytes before it are", null);
        }
        if ((fin_here or fin_held) and !c.peerDone()) {
            c.rcv_nxt +%= 1; // their FIN takes one
            c.peer_half.fire(.fin_received);
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (c.fin.is(.acknowledged)) return self.close(i, .closed);
            return .{ .event = .peer_done, .index = i };
        }

        return self.settle(i, event, fin_acknowledged, now);
    }

    /// **A SEGMENT AHEAD OF A HOLE, HELD** (metal-vmm QUEUE 226): its bytes
    /// into the receive buffer at their own place past RCV.NXT, as far as
    /// the room we advertise reaches, and noted in `held`; a FIN behind
    /// them, if all of them fit. One that touches no piece when
    /// `held_queue.max_pieces` are held is dropped as before 226, counted.
    fn holdAhead(self: *Table, c: *Conn, seq: u32, data: []const u8, fin: bool) void {
        if (c.peerDone()) return; // nothing comes after the peer's FIN
        const off = seq -% c.rcv_nxt;
        const room = c.room();
        if (off >= room) return;
        const fit: u32 = @intCast(@min(data.len, room - off));
        if (fit > 0) {
            switch (c.held.add(off, fit)) {
                .held => {
                    @memcpy(c.rx[c.end + off ..][0..fit], data[0..fit]);
                    self.held_segments +%= 1;
                    props.reachable(@src(), "tcp: a segment ahead of a hole is held", .{ .off = off, .len = fit });
                },
                .repeat => {},
                .full => {
                    self.held_refused_full +%= 1;
                    props.reachable(@src(), "tcp: a segment ahead finds the held pieces full, and is dropped", null);
                    return;
                },
            }
        }
        if (fin and fit == data.len) c.held.fin_at = off + fit;
    }

    /// Reports `event`, unless our FIN was just acknowledged: then the
    /// connection closes if the peer has finished too, and otherwise starts
    /// FIN-WAIT-2's clock.
    fn settle(self: *Table, i: usize, event: Event, fin_acknowledged: bool, now: i96) Result {
        if (!fin_acknowledged) return .{ .event = event, .index = i };
        const c = &self.conns[i];
        if (c.peerDone()) return self.close(i, .closed);
        c.fin_wait_until = now + fin_wait_ns;
        return .{ .event = event, .index = i };
    }

    fn close(self: *Table, i: usize, how: End) Result {
        self.conns[i].noteEnd(how);
        self.conns[i].reset();
        return .{ .event = .closed, .index = i };
    }
};

/// The MSS a SYN's options carry, if any.
pub fn parseMss(options: []const u8) ?u16 {
    var k: usize = 0;
    while (k < options.len) {
        switch (options[k]) {
            0 => return null, // end of options
            1 => k += 1, // padding
            else => {
                if (k + 1 >= options.len) return null;
                const len = options[k + 1];
                if (len < 2 or k + len > options.len) return null;
                if (options[k] == 2 and len == 4) return proto.readBe16(options[k + 2 .. k + 4]);
                k += len;
            },
        }
    }
    return null;
}

const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// **EVERY COUNT THE TABLE KEEPS, IN ONE LINE** (metal-vmm QUEUE 193.1), for
/// /admin/host: they were said only by the run's closing log, which a
/// server that serves until stopped never writes.
pub fn writeCounts(t: *const Table, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d} connections arrived, {d} turned away for want of a slot, {d} half-open gave way to a new one ({d} revived, {d} found no room); ", .{
        t.arrivals, t.refused, t.half_open_given_way, t.revived, t.revival_no_room,
    });
    try w.print("{d} segments sent again ({d} of them asked for by duplicate ACKs), {d} window probes, {d} reopened windows said again; ", .{
        t.retransmits, t.fast_retransmits, t.probes, t.window_updates,
    });
    try w.print("{d} peers given up on, {d} closes never finished, {d} strays reset, {d} segments dropped for a bad checksum; ", .{
        t.given_up, t.fin_waits_expired, t.strays, t.damaged,
    });
    try w.print("{d} segments arrived ahead of the next byte (one before them lost or late), {d} from behind (resends), {d} past the window; ", .{
        t.arrived_ahead, t.arrived_behind, t.past_window,
    });
    try w.print("{d} segments held ahead of a hole, {d} bytes delivered from them, {d} dropped with the held pieces full; ", .{
        t.held_segments, t.held_delivered, t.held_refused_full,
    });
    try w.print("{d} resets from peers ({d} inexact ones challenged), {d} bad handshake ACKs reset; given up by the host: {d} clients that stopped taking a response, {d} streams too far behind, {d} closes of an unfinished handshake; ", .{
        t.resets_received, t.challenge_acks, t.bad_ack_resets, t.abandoned_slow_client, t.abandoned_stream_behind, t.abandoned_unfinished,
    });
    try w.print("{d} connections of our own opened ({d} refused, {d} bad SYN-ACKs reset, {d} simultaneous opens dropped; let go at a deadline: {d} not established, {d} idle, {d} too long in all); ", .{
        t.connects, t.connects_refused, t.syn_sent_bad_acks, t.simultaneous_opens_refused, t.connect_deadlines, t.idle_deadlines, t.total_deadlines,
    });
    try w.print("{d} round trips measured, the newest {d} ns", .{ t.samples, t.measured_ns });
}

test "tcp: the host page's line says every count the table keeps, each by its own value" {
    var conns: [1]Conn = undefined;
    var out: [64]u8 = undefined;
    const isn = struct {
        fn f() u32 {
            return 1;
        }
    }.f;
    var t = Table.init(.{ 10, 0, 0, 1 }, .{0} ** 6, 80, &conns, &out, isn);
    // Each counter a value of its own, from the table's own fields, so a
    // counter added later and left off the line fails here.
    comptime var n: u64 = 1001;
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        if (f.type == u64) {
            @field(t, f.name) = n;
            n += 1;
        }
    }
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCounts(&t, &w);
    const line = w.buffered();
    var k: u64 = 1001;
    while (k < n) : (k += 1) {
        var num: [24]u8 = undefined;
        const want = std.fmt.bufPrint(&num, "{d}", .{k}) catch unreachable;
        if (std.mem.indexOf(u8, line, want) == null) {
            std.debug.print("the line leaves out the counter set to {d}: {s}\n", .{ k, line });
            return error.TestExpectedEqual;
        }
    }
}

test "tcp: a consume that reopens a tight window says so, by `tight`'s rule, a segment or half the buffer (metal-vmm QUEUE 197.3)" {
    var rx: [2048]u8 = undefined;
    var tx: [16]u8 = undefined;
    var c: Conn = .{ .rx = &rx, .tx = &tx };
    // 49 bytes of room: tight. Consuming 51 compacts 948 pending to the
    // front: 1100 of room, past half the buffer (1024) though under a
    // segment (1460). It reopened, as `tight` has it.
    c.start = 1000;
    c.end = 1999;
    try std.testing.expect(c.tight(c.window()));
    try std.testing.expect(c.consumeReopens(51));
    try std.testing.expectEqual(@as(usize, 1100), c.room());
    // Not tight before: nothing to say.
    try std.testing.expect(!c.consumeReopens(10));
    // Tight before and still tight after (no compaction): nothing to say.
    c.start = 0;
    c.end = 2040;
    try std.testing.expect(!c.consumeReopens(10));
    try std.testing.expect(c.tight(c.window()));
}
