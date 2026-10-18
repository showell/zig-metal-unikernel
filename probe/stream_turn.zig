//! **THE STREAMS' TURN** (`streamTurn`), between requests: each live stream
//! served its next frame, a draining connection let go when its last write
//! is out, and a fetch the host started stepped and its outcome said, so a
//! stream never waits on a request and a request never waits on a stream.

const std = @import("std");
const metal = @import("metal");
const stream = metal.stream;
const tcp = metal.tcp;
const serial = metal.serial;
const Io = metal.io;
const webbox = @import("webbox");
const Hub = webbox.bus.Hub;
const streams = webbox.bus;
const config_file = @import("config.zig");
const Config = config_file.Config;
const gopher = @import("gopher.zig");

/// One pass over the responses still on their way: queue more of each, close
/// the ones that are done, reset the ones whose peer stopped taking them.
fn serviceDraining(wire: *stream.Wire, table: *tcp.Table, now: i96, idle_ns: u64) void {
    if (gopher.draining_now == 0) return;
    for (&gopher.draining, 0..) |*slot, i| {
        const d = if (slot.*) |*d| d else continue;
        const c = &table.conns[i];
        var done = false;
        if (c.state != .established) {
            done = true;
        } else {
            if (d.spill.push(table, i) > 0 or c.una != d.una) {
                d.since = now;
                d.una = c.una;
            }
            if (d.spill.pending().len == 0) {
                gopher.close(wire, table, i);
                done = true;
            } else if (now - d.since >= idle_ns) {
                table.abandon(wire, i, .slow_client);
                serial.put("  let go: the client stopped taking the response\n");
                done = true;
            }
        }
        if (done) {
            d.spill.deinit();
            table.release(i);
            slot.* = null;
            gopher.draining_now -= 1;
        }
    }
}

var in_turn = false;

/// Called by every turn of the network (`stream.after_arrivals`). A turn does
/// not start another: ending a stream never waits, but it is simpler to know
/// that than to prove it each time.
pub fn streamTurn() void {
    const t = if (gopher.turning) |*t| t else return;
    if (in_turn) return;
    in_turn = true;
    defer in_turn = false;
    const now = Io.awakeNs() orelse 0;
    fetchStep(t.table, t.wire, now);
    serviceStreams(t.wire, t.table, t.hub, t.scratch.allocator(), now, t.conf);
    t.scratch.reset();
    serviceDraining(t.wire, t.table, now, t.conf.idle_ns);
}

/// One pass over the held streams: end the ones whose client has gone, queue
/// what has arrived for the rest, ping the quiet ones. `scratch` holds the
/// rendered frames for this pass only.
///
/// **NOTHING HERE WAITS.** A frame goes into its connection's send queue as far
/// as there is room, and the rest is carried to the next turn. A stream whose
/// carry has not moved for the idle time is ended: its tab is not reading, and
/// its browser will reconnect and resume. So is one whose mailbox overflowed —
/// a stream with a gap in it is worse than one that starts again.
fn serviceStreams(wire: *stream.Wire, table: *tcp.Table, hub: *Hub, scratch: std.mem.Allocator, now: i96, conf: Config) void {
    // A frame shows others what was just saved: the save is durable first,
    // as for any response (`io.durable`). These frames, and the keepalive
    // ping below, are queued here, not through a Stream, so this one call
    // covers all three of this function's queues.
    Io.durable();
    for (&gopher.held) |*slot| {
        const h = if (slot.*) |*h| h else continue;
        const c = &table.conns[h.conn];
        if (!c.open() or c.peerDone()) {
            gopher.endStream(slot, wire, table, hub, .client_left);
            continue;
        }
        var wrote = false;
        while (true) {
            if (h.carry_at < h.carry.len) {
                const n = table.queue(h.conn, h.carry[h.carry_at..]);
                h.carry_at += n;
                wrote = wrote or n > 0;
                if (h.carry_at < h.carry.len) break;
                hub.gpa.free(h.carry);
                h.carry = &.{};
                h.carry_at = 0;
            }
            const next = streams.nextFrame(h.kept, scratch) catch |e| {
                gopher.endStream(slot, wire, table, hub, if (e == error.EventsMissed) .missed_events else .no_room_to_render);
                break;
            };
            const frame = next orelse break;
            const n = table.queue(h.conn, frame);
            wrote = wrote or n > 0;
            if (n == frame.len) continue;
            h.carry = hub.gpa.dupe(u8, frame[n..]) catch {
                gopher.endStream(slot, wire, table, hub, .no_room_to_render);
                break;
            };
        }
        const still = if (slot.*) |*left| left else continue;
        if (wrote) still.last_write = now;
        if (still.carry.len == 0) {
            still.stuck_since = null;
            if (!wrote and now - still.last_write >= conf.keepalive_ns and c.queueRoom() >= streams.ping.len) {
                _ = table.queue(still.conn, streams.ping);
                still.last_write = now;
            }
            continue;
        }
        if (still.stuck_since == null or c.una != still.stuck_una or wrote) {
            still.stuck_since = now;
            still.stuck_una = c.una;
        } else if (now - still.stuck_since.? >= conf.idle_ns) {
            gopher.endStream(slot, wire, table, hub, .lagging);
        }
    }
}

/// One step of the application's fetch, if one runs: on every turn of the
/// network (`streamTurn`), the turns inside a serve included, so a long serve
/// holds up its request and its reading no more than any connection's, and
/// its deadlines never run out on a fetch nobody stepped.
fn fetchStep(table: *tcp.Table, wire: *stream.Wire, now: i96) void {
    const c = if (gopher.fetching.client) |*c| c else return;
    // Past what is kept, the rest is not read: the connection is let go,
    // and the next step says how it ended (too_long, below).
    if (gopher.fetching.too_long) if (c.slot) |i| if (table.conns[i].state != .closed) table.abandon(wire, i, .unfinished);
    const o = c.step(table, wire, now, &gopher.fetching) orelse return;
    const status = c.answer.status;
    gopher.fetching.end(if (gopher.fetching.too_long) .too_long else hostOutcome(o), status);
}

/// The kernel's client's word, as webbox says it: every one has its twin.
fn hostOutcome(o: metal.fetch.Outcome) webbox.host_fetch.Outcome {
    comptime for (std.enums.values(metal.fetch.Outcome)) |k| {
        if (!@hasField(webbox.host_fetch.Outcome, @tagName(k))) @compileError("webbox's host_fetch has no outcome " ++ @tagName(k));
    };
    return switch (o) {
        inline else => |k| @field(webbox.host_fetch.Outcome, @tagName(k)),
    };
}
