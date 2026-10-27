# Finding bugs in the TCP table systematically

`src/tcp.zig` is pure: frames go in through `handle`, come out through a
`wire`, and time is a number the caller passes. So a test can own the clock,
the network and the peer, and replay any run exactly. This note is the
strategies built on that seam, numbered as the code cites them, and what
each would catch.

The yardstick is three **liveness** bugs found by reading: nothing wrong was
said on the wire, but something owed was not done in time. **A**, a close
that waited in the one-request loop for a FIN acknowledgement from a peer
known to be silent; **B**, a `pump` that stopped reading the ring early, so
timers ran with acknowledgements unread; **C**, a reopened window announced
once and never again, so a lost announcement left the peer on its persist
timer. A scenario test rarely catches these, because it stops when the
author's expected outcome is reached.

## 1. Invariants checked after every step

`src/tcp_check.zig`'s `check(table, now, phase)` names the first rule any
slot breaks. Every test in `src/tcp_test.zig` drives the table through
`handle` and `transmit` wrappers that call it, and so does every simulator;
the code is the list of rules. `check` is told **when** it is looking: some
debts (bytes just queued, a window just reopened) belong to the next
`transmit`, so after `handle` it is enough that they are owed, and after
`transmit` every deadline left must be in the future.

**The liveness rule:** every connection that is not `closed` either has an
armed deadline for what it owes (bytes or a FIN in flight, a probe, a
handshake, our FIN acknowledged and the peer's not come, a reopened window
said and not yet heard), or is idle with the host's `quiet()` as its bound.
Bug C fails it the first time a test consumes a full buffer.

**A debt needs a state of its own, or it cannot have a rule.** A timer
nobody armed looks the same as a debt nobody has, so if a connection can owe
something, some field says so for as long as it is owed: a reopened window
is `window_news: none → said_once → repeating`, a stage each.

## 2. Every queue has a drain

Every buffer, ring or flag that holds work answers three questions: what
drains it, what guarantees the drainer runs, and how soon. The answers are
kept in the code, under "What waits here, and what bounds the wait": the
headers of `src/tcp.zig`, `src/stream.zig`, `src/net.zig`,
`src/interrupts.zig` and the main loop in `probe/gopher.zig`. **Adding a
queue without its row is a review rule.**

The floor under every deadline is the 1 ms APIC timer `interrupts.rest`
arms before every `hlt`: an interrupt can delay work by at most `slice_ns`,
never lose it, as long as nothing halts with no timer armed or with work
already owed. Every call that can wait inside the loop needs its own row
too (who it waits for, and what bounds the wait); bug A is the row that
would have read "a peer already known to be silent".

## 3. A simulated network, many seeds

`src/tcp_sim.zig`: the table against a seeded network and a small RFC 9293
client of its own, written apart from `tcp.zig` so it does not share the
table's misreadings. The clock ticks a millisecond at a time; loss happens
only early in a run, so a run that does not finish is a bug, not bad luck.
The host is a model of `probe/gopher.zig`'s: it reads at its own pace and
stalls, announces a reopened window or leaves that to the table, lets go of
a connection after `idle_ns`, and closes without waiting. Rough seeds
(`Rough`) add a peer that resets, vanishes, or floods the table with SYNs;
crowd seeds run many clients at once.

**The oracles:** §1 after every step; the bytes each side delivered are
exactly what the other sent, once and in order; every connection reaches
`closed` or idle with nothing owed within a bound from the constants; and
once loss stops, the transfer completes within a few RTOs. `zig build test`
runs a handful of seeds and every regression (`seeds`); a seed that fails
and is fixed joins them. A failing seed prints its scenario and both
sides' counters.

**The table against itself**, `src/tcp_pair_sim.zig`: the table's client
(`connect`) against its server, about 300 seeds in `zig build test`, with
single chosen losses, random loss, reordering, or a peer that makes one
deadline fire. Here the turned-around peer is the thing under test, since
two kernels talk through two tables.

## 4. Small-scope exhaustive exploration

**Not built.** Shrink the buffers to a few bytes, the MSS to 1 or 2, and
enumerate every sequence of up to about ten events (the peer sends next, a
duplicate, one from the past; the network drops or delivers; time advances
to the next deadline; the host consumes, queues, finishes or abandons),
checking §1 at every node and pruning states already seen. Random
simulation finds what is likely; this finds what is possible, with a
counterexample small enough to read.

## 5. Fuzz `handle` with structure-aware segments

**Not built.** `zig build test --fuzz`, with the input decoded as choices
(flags, offsets from `rcv_nxt` and `una`, a window, a length, a time step)
built into valid, checksummed frames, biased to the edges: 0, ±1, the
window's edges, 2^31 exactly, the wrap, an acknowledgement just past
`highest()`. The oracle is §1 and no panic.

## 6. The whole suite at awkward initial sequence numbers

`zig build test` runs `src/tcp_test.zig` once per (our ISN, the peer's
first sequence number) pair (`build.zig`): where the tests were written,
zero, 16 bytes before half-way, 16 before the wrap, and each side at a
different edge. `Fixture.init` resets `fakeIsn`, so every test's first
connection starts there. **Tests compare sequence numbers only to each
other, never to a literal**, so wraparound bugs (`<` where `after()`
belongs, `-` where `-%` does) cannot hide.

## 7. A state × event matrix against RFC 9293

RFC 9293 §3.10.7, as a table: `matrix_rows` in `src/tcp_test.zig`, one row
per kind of segment and one cell per state (no connection, SYN-RECEIVED,
ESTABLISHED, FIN-WAIT-1 before and after our FIN goes, FIN-WAIT-2,
CLOSE-WAIT), each cell what must be sent and what the state becomes, run on
a fresh table at every starting sequence number of §6. **A null cell is one
of the questions below**, untested until it has an answer.

Two cells are a decision rather than the RFC's letter:

- **A SYN repeated during the handshake gets the SYN-ACK again.** RFC
  9293's first check would answer it with a bare ACK, which is no use to a
  client whose copy of our SYN-ACK was lost. Linux does the same.
- **The peer's FIN in FIN-WAIT-2 closes the connection at once.** There is
  no TIME-WAIT, as `tcp.zig`'s header says. A FIN repeated after that is
  answered with a reset.

### The open questions

1. **A SYN inside the window during the handshake** (`syn_in_window` and
   `syn_with_data` × `syn_received`). The table repeats its SYN-ACK; RFC
   9293 §3.10.7.4 sends a passively opened connection back to LISTEN (here,
   forget it and free the slot), which is cheaper under a SYN flood. Which?
2. **An acknowledgement of something never sent, on a synchronized
   connection** (`ack_future` × ESTABLISHED on). The table ignores the
   acknowledgement and still takes any data. RFC 9293 says send an ACK and
   drop the segment; RFC 5961 §5 says drop it, so a blind attacker who
   guessed the sequence number but not the acknowledgement cannot inject
   data. Should it be dropped, and the drop answered?
3. **Data ahead of RCV.NXT during the handshake** (`data_ahead` ×
   `syn_received`). The table acknowledges it and stays in SYN-RECEIVED,
   without looking at its acknowledgement; the RFC takes the
   acknowledgement first, completing the handshake. Should it?
4. **Data that straddles RCV.NXT** (`data_straddling` × the states that
   take data). The table treats it as from behind and acknowledges; the RFC
   trims the old part and takes the rest. The peer resends from our
   acknowledgement, so it costs a round trip. Worth trimming?
5. **Outside the matrix:** a segment with neither SYN, ACK nor RST from a
   peer the table does not know is answered with RST|ACK, where RFC 9293's
   LISTEN drops it; a segment to another port is ignored, where a CLOSED
   port would reset. Both look intentional for a single-port server.

## 8. Differential testing against Linux

`native/serve.zig` and `native/judge_native.py` run the table with Linux's
TCP as the peer, with `netem` dropping frames; among its checks, `burst`
(200 slow connections against 64 slots: refused, retried by Linux, all
answered, the table clean) and `stalled reader` (a client that stops
reading holds only its own slot). This is the only strategy whose peer we
did not write, so the only one that catches a bug the model peer shares
with the table. **Not built:** netem's `reorder`, `duplicate`, `corrupt`
and `rate`; Scapy for what a polite Linux client never sends (an RST at
every offset, overlapping retransmissions with different bytes, a zero
window forever); `tcpdump` on both sides through `tshark -z expert`.

## 9. Host-loop latency as a measured invariant

**Not built.** Bugs A and B were in the loop that drives the table, not in
it. Measure the longest gap between two `pump` calls, the longest a ready
connection waited beyond the requests ahead of it, and the frames still in
the ring when `transmit` ran (zero under §2; bug B would show), and have
the judge bound them, as it bounds the heaps.

## 10. Check that the tests can fail: mutation testing

`tools/mutate_tcp.py` breaks `tcp.zig` one way at a time, judged by `zig
build test` (which runs §1, §3, §6 and §7); `MUTATION.md` says how its
runs are judged. **One survives on purpose: `sample-too-early`**, an
acknowledgement one byte short of the timed segment taken as its RTT
sample, which real acknowledgements, landing on segment boundaries, never
show. **Add a mutant whenever a bug is fixed:** the mutant is the bug, and
the list keeps proving it stays fixed. A test that passes for the wrong
reason (a "lost FIN is sent again" that passed with nothing sent, the old
FIN still last on the wire) is invisible to every other strategy here.
