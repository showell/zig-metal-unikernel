# The host: what Linux and metal both promise the application

The contract between an application's route table and the host it runs
on, Linux or metal; STORE.md is the data's part of it.

**The aim is that Linux and metal agree.** Every rule here exists so that something which works on a laptop
works the same on the droplet, and something that would fail on the droplet
fails on the laptop first.

## What a host does before the first request

The `webbox` library (zig-webbox) declares the host contract (`site.zig`). A
host takes two modules: the library, `webbox`, and the application's root,
`app`, which exports `site` (its `Site(App)`: `start`, `route`, the body
rule's two questions, `bodyLimit` and `uploader`) and `hosting` (what only it
can say: its data's name, its largest whole read, its setup's report in
words, and, optionally, its `name` for metal's boot banner, "<name>'s route
table", which says "angry-gopher" when none is declared). Linux is zig-webbox's `linux_host.zig` (`Server(S).run`, which
angry-gopher's `server.zig` calls with its names and settings), with
`linux_durable.zig` beside it; metal is `probe/gopher.zig`. Four calls:

1. `mem_meter.init(base)`: the process-lifetime allocator, before anything
   else.
2. `start(io, Host)`: once, before the first request. Everything the host
   supplies is in one `Host`: where the data is, how to read its free space,
   the trusted proxy, the host's own facts and log, and its fetch. The setup is done in
   the one right order, and the answer is the `Hub` live streams publish
   through.
3. Per request, `route`, then serve the stream it answered, if any
   (zig-webbox's `bus.zig`: `bus.serveKept` for a host with a task per
   connection, `bus.nextFrame` for a host with one loop; `bus.drop` ends it
   either way).
4. Between handlers, `between`, when the application's wake says so
   (below, "Between handlers, and the host's fetch").

## One handler at a time

**A handler runs to its end with no other handler interleaved, on both
hosts.** What runs around the handlers differs:

- **Metal** has one loop. It reads, runs one handler, and serves kept
  streams (`bus.nextFrame`), one thing at a time: a kept stream is served
  between handlers, never during one.
- **Linux** runs each connection as its own task and holds one lock, the
  turn (zig-webbox `linux_host.zig`, `turn`), around `route` alone.
  Everything else a connection does runs on its own task, at the same time
  as whichever handler holds the turn: reading the head and the body; asking
  who is uploading (the site's `uploader`, from the head's cookies); and
  serving a kept stream, `bus.serveKept`, which renders each event with the
  stream's `render` (angry-gopher's `chat_sse.renderLive`, or webbox's
  `sse.forward`'s `renderForward`) and writes it, until `bus.drop`. A kept
  stream is served during handlers, not between them.

So what Linux runs outside the turn may reach only its own state and the
library's, under the library's own locks: the bus's (the hub's registry, and
each subscriber's mailbox) and the host's (the streams held, the upload
slots, the small-body budget). The application holds no lock: what it shares
is reached only from handlers, and from its setup before the listener
opens. A `render` or an `uploader` that reached shared application state
would need a lock again.

**Every body is whole in memory before the turn, on both hosts** (webbox's
`body.zig`, the one rule both read): the turn never waits on the network.
Metal starts a request only once its body is here (`ready.zig`): a small one
that fits the connection's buffer is waited for in it, a larger one is
drained into memory by the host, and an upload is read by the host into one
of its slots once its uploader is known. Linux reads every body on the
connection's task before taking the turn (`bodyBeforeTurn`). A stranger's
upload is never read, on either host, and its route refuses it.

Cost: Linux loses request parallelism. At lynrummy.com's load (a handful of
people, requests answered in milliseconds) that costs nothing measurable,
and a slow handler is a bug on metal already.

## Durability

**No response leaves before the writes ahead of it are durable.** The
application never flushes; the host flushes at the one moment that matters,
before any byte of a response or of a kept stream's frame goes out. A failed
flush is logged and counted, the response still goes, and the next one
tries again.

- **Metal:** `io.durable` (`src/io_volumes.zig`, re-exported by `src/io.zig`), called from `Stream.sendAll`
  (`src/stream.zig`), flushes each disk that has writes it may not have
  kept. Failed flushes are counted per disk and shown on `/admin/host`.
- **Linux:** the store counts every call that may have changed the disk
  (zig-webbox `store.changes`); each connection's writer
  (`linux_durable.zig`) runs `syncfs` before passing bytes on when that
  count is past what the last finished sync covered. `syncfs` syncs the whole
  filesystem under each of the data and auth roots (the working directory's,
  in a run with no roots), so more than the request wrote, and twice over
  when both roots share a filesystem. Two senders at once may both sync.
  Failed syncs are counted (`Durable.failures`), and `/admin/host` shows
  the count as "data syncs failed".

## Limits: one source of truth

**Each limit is defined once**, and every other place either reads it or is
checked against it. The application's caps are angry-gopher's
(`zig-server/src/limits.zig`); the head's size is the library's
(`webbox.http.head_bytes`, which limits.zig names); a store path's limits
are the FAT driver's, which the library restates:

| limit | defined | read or checked by |
|---|---|---|
| a request's head (16 KiB) | webbox's `http.zig` (`head_bytes`), named by `limits.zig` | both hosts size their head buffers from it (`webbox.http.head_bytes`); metal asserts at compile time that a connection's receive buffer holds one |
| an ordinary body, per route | `limits.zig` | every route's `http.readLimitedBody`; Caddy's `request_body`, held to it by `tools/check_caddy_limits.py` in `ops/check_zig` |
| an upload (10 MiB images, 100 MiB video) | `limits.zig` (`upload_image`, `upload_video`) | `chat_upload.zig`'s kinds; Caddy, by the same script |
| a name, a path, a depth (96, 256, 16) | metal's `disk_fat_dirent.zig`, `io.zig` and `disk_fat.zig` | zig-webbox's `store.zig` restates them for every host; `tools/check_limits.py` holds the two together, in tier 3 |

The Caddy check fails if Caddy's caps are below the application's (a request
the app allows would be refused at the door) or far above them (harmless,
but one of the two is stale).

## Live streams

The application describes a stream; the host keeps it (`bus.zig`). The
contract, as `bus.zig` has it and both hosts serve it:

- **Live-only.** A reader whose queue is full misses the event; a reload
  derives it again. Nothing is owed to a reader that wasn't listening.
- **Each key's events in the order they were published.**
- **A stream ends** when its reader goes away, or when the host gives up on
  it: metal, a reader that has stopped reading for `idle_timeout_ms`; Linux,
  the oldest of `streams_most` (64) held streams when another is kept. Linux
  has no write deadline, so a reader that stays connected and stops reading
  holds its task until then.

**Simulated** (zig-webbox `bus.zig`, "the mailbox contract over seeded
runs", 300 runs, slow readers included so the overflow is met): a reader
sees exactly its key's events since it opened, in order, nothing skipped,
and ends with `EventsMissed` if and only if its mailbox was full when an
event arrived. On both hosts an overflow ends the stream, and the browser
resumes.

## The clock and random bytes

- **Wall time** for what people read (timestamps), and for the
  application's windows (the login throttle's, the game limits' hours,
  presence's five minutes: `login_throttle.zig`, `game_limits.zig`,
  `presence.zig`); **monotonic time** for the hosts' timeouts. Metal sets wall time from the hardware clock at
  boot and never corrects it; metal-vmm decides it.
- **Random bytes are cryptographic** on both hosts (metal: virtio-rng and
  RDRAND; Linux: the OS). In tests both come from the tape, so the seed
  explorer can steer them.

## Config

A value by name, typed when read.

- **Metal** (`probe/gopher.zig`, `readConfig`): a malformed value stops the
  boot; **so does a file that exists but can't be read**. A missing file is the defaults.
- **Linux** (zig-webbox `linux_config.zig`, `linux_host.zig`): the file
  names only the data and auth roots, and the rest are environment
  variables. No file named is the defaults; a file named that is missing or
  won't read stops the start, and so does a malformed bind or keepalive. A
  line with no `=`, and a key other than the two, are skipped, and a port
  that is not a port is the default port.

## Idle time (metal only)

**Work that is not time-critical runs when the machine is quiet**, a step at
a time, under a request's rules: a step is bounded (200 ms), and a request
that arrives meanwhile waits for at most one step. Metal's loop gives the
next task a step when it would otherwise rest and nothing has arrived for
200 ms (`src/idle.zig`); `/admin/host` says the steps, the overruns, and each
task's state.

- **It is the host's alone:** the one task is each volume's check,
  asked again while the machine serves (`src/idle_check.zig`), reading and
  writing nothing else. A write under a check starts it again. Linux runs
  no idle task.
- **The application's own work between requests is `between`** (below),
  not an idle task.
- **A task that writes** would need the fault testing a request gets; the
  one task only reads.

## Between handlers, and the host's fetch

**The application's work between requests** is its site's `between`
(zig-webbox `site.zig`, `Site.between`): called under the turn, one slice
at a time, so a request that arrives waits at most one slice. It is handed
two clocks (`Now`: the awake clock and Unix seconds) and answers when it
next needs a turn (`Wake`, zig-webbox `wake.zig`):

- `.more`: call again on the next free turn;
- `.at`: nothing before this time on the awake clock, unless a request
  comes first;
- `.idle`: nothing until a request, or the end of the application's fetch.

An application with no `between` is `.idle`. An older one that answers
`bool` (angry-gopher's background Shale run) is `.more` or `.idle`.

- **Metal** calls it from its one loop (`probe/gopher.zig`,
  `betweenSlice`), and a quiescent machine sleeps until the wake, at most
  `longest_rest_ms` (docs/designs/DESIGN-sleep.md).
- **Linux** calls it on a thread of its own (zig-webbox `linux_host.zig`,
  `betweenLoop`), once before the first connection is accepted, then after
  each call it lets a waiting handler go first and sleeps until the wake or
  a doorbell that every handler's end rings.

**The host's fetch** (zig-webbox `host_fetch.zig`): one HTTP GET at a
time, which the application starts from `between` and reads the result of
on a later call; the host calls `between` as soon as the fetch ends. Each
fetch has three deadlines (connect, silence, total). The outcomes are the
same words on both hosts. Metal's fetch is the kernel's own TCP client, on
the machine's own network only, in a connection slot kept for it
(`probe/gopher.zig`, `fetchStart`); Linux's is zig-webbox's
`linux_fetch.zig`. A host with no fetch passes none, and `start` answers
`NoFetch`.

Both are served; no served application fetches yet.
