# The network: one loop over state machines

The TCP table (`src/tcp.zig`), the loop that serves it (`probe/gopher.zig`,
`src/stream.zig`, `src/ready.zig`), chat's live streams, and how each is
judged. The plan for finding the table's bugs systematically is
[`TCP_TESTING.md`](../TCP_TESTING.md); its properties and simulator are in
[`COVERAGE.md`](../COVERAGE.md).

## Every wait is a measured duration

A client that connects and then says nothing is a server's worst case. Every
wait in `src/stream.zig` is a duration of the calibrated timestamp counter,
not a spin count, and the ones that matter are host configuration in
`zig-metal-unikernel.conf` on the boot disk (`idle_timeout_ms`, `streams`,
`keepalive_ms`, and the rest: the whole list, each with its default, is
`probe/config.zig`'s comment, and the error for an unknown key names every
one).

"No progress" is the same measure in every direction: a read that gets no
bytes, a write whose peer acknowledges nothing, a close whose FIN is not
acknowledged. An unknown key stops the machine, because a timeout that was
silently not applied is exactly how a server ends up held open by one client.
`std.Io.Reader` reports both a dead NIC and a quiet client as `ReadFailed`,
so the stream keeps the detail, and the log says which:

```
  request 1: (no request) -> the client stopped sending, and was let go
```

**"It recovered" is not the claim.** The claim is that the configured number
is what governs, so the judge boots twice, with two values, and times both.

## Many connections, one request at a time

Chat holds connections open: every conversation tab keeps three streams for
as long as it is open. So the design is **state machines, and one loop over
them**: talk to the devices, move every connection along, and serve whatever
is ready. No threads, no fibers.

`src/tcp.zig` is a **table of connections** (`max_connections` in
`probe/gopher.zig`), each with its own state, receive buffer and send queue.
A SYN takes a free slot; a full table drops it, as Linux does when its accept
queue is full, and counts it. The window advertises the room actually left
in the receive buffer, so a body bigger than the buffer arrives in pieces. A
slot the host is serving is never handed to a new connection until the host
lets it go — otherwise a reader part-way through a request could find a
stranger's bytes.

The state machine is **pure**: frames go out through whatever "wire" the
caller supplies, and the initial sequence number and the time are passed in.
So it is tested on the host (`src/tcp_test.zig`, `src/tcp_check.zig`) with a
recording wire and a fake peer, and `tools/mutate_tcp.py` breaks it one way
at a time and reports any break `zig build test` does not notice.

**The host serves a connection only once the whole request has arrived**
(`src/ready.zig`, which asks `std.http.HeadParser`, the parser `receiveHead`
itself runs, so "ready" and "a whole head" cannot disagree). The oldest ready
connection is served start to finish; one that has been quiet for
`idle_timeout_ms` is let go; otherwise the network is polled, which moves
every connection at once.

**Three kinds of body cannot be waited for**, and are started at the head
with the handler reading the rest as it comes: one whose client sent
`Expect: 100-continue` (`std.http.Server` answers it from inside the
handler, so waiting here would be both sides waiting); a chunked one, whose
length nobody knows until it ends; and one too big for the connection's
receive buffer, since nothing drains that buffer until the handler runs.

## The machine keeps chat's live streams

Streams are **described by the application and kept by the host**: a stream
handler writes its head and backlog, then hands the host a `Kept` (zig-webbox
`bus.zig`: its bus subscriber, and how to render an event for this viewer)
and returns. Linux serves that on the connection's own task.

This machine keeps a **table of held streams** (`probe/gopher.zig`; what
becomes of a connection after its handler is `src/after_turn.zig`). Every
turn of the loop drains each held stream's mailbox and writes the frames;
one quiet for the keepalive gets a ping; one whose client has gone (its FIN
or reset seen by the connection table) is ended: subscriber dropped,
connection closed, slot released.

The judge holds streams open on both hosts and requires the same story from
each (`streams-linux`, `streams-metal`), including a tab as a browser holds
it: three streams at once, each getting its own event, and each pinged once
after the keepalive, never before it.

**Streams cannot starve requests.** A held stream occupies a connection slot,
so `streams = N` budgets them (by default all but 64 of the slots). When the
budget is full, a new stream ends the OLDEST: its browser reconnects, and a
conversation stream resumes from its last event.

**Nothing is kept per stream.** Streams opened and closed one after another,
by FIN and by reset, must leave nobody subscribed and end two boots holding
the same number of live bytes (`churn`).

**Streams turn with the network.** Held streams are serviced on every turn of
the network loop (`stream.after_arrivals`), including the turns taken inside a
request's reads and writes — not only between requests, where a stream would
move at most one send queue per request and a fast sender would overflow its
mailbox. A mailbox that does overflow ends its stream (the bus's `missed`
flag) rather than leaving a gap, and ending a stream never waits: its FIN is
queued and the table finishes the close.

**A tab that stops reading loses its stream, not the site.** The loop never
waits on a stream. It takes the next event from a stream's mailbox only when
it has somewhere to put it (`bus.nextFrame`), queues as much of the frame as
the connection's send queue takes, and carries the rest to the next turn. A
stream whose carry has not moved for the idle time is reset; a frame still
in flight is not a lagging tab (`lagging`).

## The send side

`Table.transmit`, called on every turn of the loop, is a state machine like
the receive side: the window, the segment size, retransmission with a
measured timer (RFC 6298), fast retransmit (RFC 5681), giving up after
`max_retries`, the FIN last. `src/tcp.zig`'s header says each, with its
departures from the RFCs and the reason for each; the timers are
`src/tcp_timeouts.zig`.

**Every waiting frame before any timer.** A busy loop finds acknowledgements
queued in the NIC's ring, and looking at the timers first calls those
segments lost (`src/stream.zig`). `JUDGE_CAPTURE=1` writes a packet capture
per boot when a case like that needs finding.

On QEMU, `bulk` sends 40 KB messages in and a 317 KB transcript out, and
again losing one frame sent in seven (`lose_one_sent_in`, which loses only
what this machine sends). Slow and stalled readers are metal-vmm's
`timeouts.sh`, in the machine's time: a reader that pauses just under the
idle setting gets the whole page with its window probed, and one that pauses
just over it is let go. That gate needs a 4 MB answer: a loopback client with
a 2 KB receive buffer still lets its sender queue 1.36 MB, and slirp holds
more, so a smaller answer never shuts the window.

## The ladder: where does a slowdown live?

`probe/ladder.zig` looks for a cost that grows one layer at a time: each rung
repeats ONE operation and prints the cost per operation of each tenth of the
run, and `probe/judge_ladder.py` fails a rung whose cheapest of its last
three tenths costs more than 1.5× the cheapest of its second to fourth, or
whose disk requests climb. `scale=N` on the kernel's command line
(`LADDER_SCALE`) multiplies every count, so a rung is asked briefly first and
at length once it has been flat.

**A connection is not finished when its FIN is acknowledged** (`tcp_conn`):
forgetting it before the peer's own FIN arrives leaves the peer in LAST-ACK,
and a peer that walks its connection list per frame — slirp does — gets
slower at everything for as long as the machine is up.

## The TCP table, on Linux, against Linux's TCP

`src/tcp.zig` touches no device, so it runs as an ordinary Linux program too
— `native/serve.zig` (`gm-serve`, `zig build native`) — with a TAP device
instead of virtio-net and **Linux's own TCP as the peer**. No emulator, no
slirp, no kernel image. `native/judge_native.py` (`probe/run.sh native`)
creates the device, starts it at 10.77.0.2, and asks, in about a minute,
for many connections in a row, a lazy close (none left in LAST-ACK on
Linux's side), concurrent clients, exact bytes fast and with a pause,
half-close, reset and keepalive, and recovery from loss each way.

**And as a client**: `native/fetch.zig` (`gm-fetch`) makes one GET with
`Table.connect` to Linux at 10.77.0.1 and exits with the outcome's code
(`src/fetch.zig`). The judge's fetch cases (`FETCH_ONLY=1` alone) hold each
to its code: refused, silent, idle and total servers let go at their
deadlines, SYNs eaten, and frames lost each way. `GM_TRACE=1` prints every
TCP frame each way.

A boot that loses nothing on purpose must have no request waiting a second
for its turn (a second is a retransmission timer, not work).

## What the TCP does not do

No congestion control, no selective acknowledgement, no window scaling, no
delayed ACK, no keep-alive of its own, no TIME-WAIT: allowed because this
machine sits behind Caddy on a private network (`src/tcp.zig`, "THE SMALL
TCP"). A connection is forgotten as soon as both sides have finished, and
anything that arrives afterwards is answered with a reset. Segments that
arrive ahead of a hole are held, up to `max_pieces` a connection
(`src/tcp_held.zig`), so a loss costs the peer one resend, not everything
after it.
