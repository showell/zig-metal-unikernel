# Design: a kernel that sleeps until it is needed

**Built**, in releases from v33. A quiescent machine halts until its
application's next wake, or `longest_rest_ms`, instead of waking every
`interrupts.slice_ns`. The code is `src/sleep.zig` (the decisions, pure),
`probe/gopher.zig`'s `restOrSleep`, `src/interrupts.zig` and
`src/rest_count.zig` (the rest), and zig-webbox's `wake.zig` and
`host_fetch.zig` (the application's side).

## What it is for

The Observatory wakes every 60 s, fetches Dog Park's `/version`, writes a
line, and sleeps. The goal: Linux and bare metal behave the same; most tests
simulate time; a few measure real sleep in wall time; and sleeping 60 ms is
the same problem as sleeping 60 seconds or 60 hours.

## Phase 1: sleep long only when the machine is quiescent

    if quiescent:  rest(min(app.wake, now + longest_rest))
    else:          rest(now + slice_ns)

The busy machine still notices its many clocks (TCP's timers, the body
drains, streams' pings, spilled responses) by waking every slice.
**Quiescent** is nothing in motion: no connection open, no stream held,
nothing draining, no console backlog, no fetch running, and the application
not asking for more (`src/sleep.zig`). Coverage builds recompute it from the
arrays rather than the counters at every quiescent rest, and require the two
to agree.

**The wake is counted from the last poll, not from the last quiet moment**:
a request at second 30 is served, and the machine sleeps again until the same
second 60. **Nothing unflushed sleeps**: every turn of the network flushes,
and the loop turns after every `between` call before it rests; coverage
kernels assert it. **Idle work's quiet gate is in the minimum**
(`Idle.gateAt`); its tasks' own times are not, and the cap makes them at
most `longest_rest_ms` late.

## Every rest is bounded

`interrupts.rest(until)` takes a deadline, and no rest is without one:
- the inner waits (a serve's pump, the drains, net.zig's send-stall wait)
  pass `now + slice_ns`; the quiescent branch passes the minimum above, and a
  wake already past is a turn, not a rest;
- the TSC deadline is computed from the boot's base, clamped to the cap
  first, never as "now plus a delta", which near saturation could wrap into
  the past (`src/apic_rule.zig`: a rest's ticks for any length);
- after a device ends a rest early, the deadline is disarmed, or it would end
  a later rest at once;
- what ended a rest is read off the handlers, not the clock: the timer's and
  the card's stubs each count (`gm_irq_timer`, `gm_irq_wake`), and
  `rest_count.ended` compares. What is already raised is taken before the
  halt (`sti; nop; cli`);
- a rest the cap ended after which a frame was waiting is a **missed wake**,
  counted on /admin/host.

**Why a cap, 10 s by default** (`longest_rest_ms`, `probe/config.zig`):
without one, a lost interrupt sleeps until the next wake, which for chat is
never; and metal-vmm ends a run at a halt with nothing armed, so a lost wake
would pass silently there. It costs six wakes a minute. Tests set it to a few
ms, which exercises the same path in real time. What the cap does not check
is whether a real card's interrupt arrives: that is the real-time check's.

## The application's side: `between` returns a wake

zig-webbox's `wake.zig` defines `Wake` (`more`, `at`, `idle`) and its
promise; `site.zig` takes a `between` answering `bool` (with Unix seconds)
or `Wake` (with both clocks). The contract, on both hosts:
- **`.at` is a lower bound**, not an appointment: `between` may be called
  sooner, and checks its own clock;
- **the host calls it** when it said `.more`, when `now ≥ at`, when the
  application's fetch ended, and after every served request, quiescent or
  not;
- **after every call the network turns** before any rest;
- **`.at` lives within one boot or one process**: the awake clock starts
  again at a restart, so an application never stores it;
- **the console's turn comes first**, so a large backlog can delay a due
  wake.

On Linux the between thread sleeps on a doorbell until the wake
(`futexWaitTimeout`, or `futexWait` for `.idle`); every handler's end rings
it, and so does a stop (zig-webbox `linux_host.zig`).

## The host's fetch

`between` gets no table and no wire, and a fetch inside it would hold the
turn, so **the host offers one fetch at a time**, the same shape on both
(zig-webbox `host_fetch.zig`, which has the outcomes and which host produces
each). Its end is news: `between` is called at once.

On metal one `fetch.Client` (`src/fetch.zig`) lives in the serving table,
stepped on every turn of the network, the turns inside a serve included. It
**holds its slot** until it has read its own connection's end (`Conn.ended`),
so a stranger taking the slot cannot write its end over the client's; the
table's counters are never read. A whole answer is the outcome however the
connection closes after. One slot is reserved for it
(`reserved_for_initiated`), and `quiet()` never lets go of an initiated
connection. It is on-link only, by the lease's mask. On Linux it is one
thread a fetch (zig-webbox `linux_fetch.zig`).

## Testing, fast to slow

1. **Tier 0**: `src/sleep.zig`, `src/apic_rule.zig`, `src/rest_count.zig`,
   `src/fetch.zig` against the kernel's own server in one table; zig-webbox's
   `between` paths and Linux's doorbell by counts.
2. **metal-vmm, simulated time** (`sleeps.sh`): the idle kernel's exits; the
   sleeper for a simulated hour (`GUEST_S`), each line at its exact virtual
   time; the sleeper fetching from gopher.elf, with the server silent for a
   stretch (`WIRE_SILENT_S`).
3. **QEMU, real time** (`droplet/sleeps.py`, tier 1, KVM and the PCI
   machine): the sleeper waking every 500 ms, its gaps timed on the host's
   clock, requests sent mid-sleep timed to their first byte, nothing ending a
   rest but the timer and the card, and no missed wake. The only check of a
   real TSC-deadline timer and a real MSI-X wake.

60 s and 60 h are never waited for in wall time: tier 0 holds the
arithmetic, metal-vmm the behaviour.

## Phase 2, for later

Halt until the earliest of all the busy machine's deadlines when a busy
server's slice shows up as a cost. Its oracle: every clock condition is
`now ≥ X`, monotone in time, so after each turn the timer-driven steps run at
`due - 1` must send nothing and change nothing. And `waitSeconds`, the
restart's back-off, spins on `pause`; it could rest once the machine is
armed.
