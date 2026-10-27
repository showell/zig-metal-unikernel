# /admin/host and /admin/log, for agents

How an agent finds out what the running server is doing. There are two views,
behind one key:

- **`/admin/host`**: the page for Steve, in HTML. A health summary, then
  the details, then the log's newest 60 lines.
- **`/admin/log`**: the log for you, in plain text, to fetch and grep. It
  holds the whole log, this boot's and the boot before's, and it can be
  narrowed.

Both are GET only, admin only, and change nothing. Without the admin's key,
`/admin/log` sends you to sign in (anonymous), or answers 404 (a member who
is not the admin).

## Fetching

The admin's key is Steve's prod key, in `~/.gopher_api_key`. **Never print
it.** Read it inline, as below, and never `cat` or `echo` it on its own.

```bash
SITE=https://lynrummy.com
admin() { curl -s -H "Authorization: Bearer $(cat ~/.gopher_api_key)" "$SITE$1"; }

admin /admin/log                                  # the whole log, both boots
admin '/admin/log?boot=this'                      # this boot only
admin '/admin/log?since=2026-10-13T14:02'         # from 14:02 UTC on
admin '/admin/log?since=2026-10-13T14:02&until=2026-10-13T14:03'
admin '/admin/log?request=1234'                   # one request and its lines
admin '/admin/log?path=/chat/c/1_3'               # one conversation's requests
admin /admin/host                                 # the page (HTML)
```

**The filters**, each optional, all applied together:

| Filter | What it keeps |
|---|---|
| `since=` | Lines from that time on. The time is ISO UTC (`2026-10-13T14:02:07.123Z`) or any leading part of one, a year at least. |
| `until=` | Lines before that time, spelled the same way. |
| `request=N` | Request N's line and the lines indented under it. |
| `path=/prefix` | The requests whose path begins so, and the lines under them. |
| `boot=` | `this`, `before` or `both` (the default). |

**How the time filters treat lines:**
- A request's line carries its own time.
- Any other line counts as the time of the last timed line before it.
- With `since=` or `until=` set, lines before the first timed line (the
  boot's own) are left out.

A filter spelled wrong is a 400 that lists what each one takes. A `:` may
be sent as is or as `%3A`.

## What the log says

**The header.** Every line of it begins `# `, so `grep -v '^#'` gives the
log alone. It holds:
- the application's commit and zig-metal-unikernel's commit;
- when this boot began;
- the requests since boot by status class and by part of the site;
- one `# 5xx:` line for each of the last 20 answers of 500 or over;
- one `# slow:` line for each of the 5 slowest requests;
- for each boot: the bytes and lines it holds, how much was lost to the
  ring, and the time on its oldest timed line.

**A request's line** leads with its UTC time:

```
  2026-10-13T14:02:07.123Z request 12: POST /chat/c/1_3/general/upload -> ok, 200 in 41.3 ms (base: ...)
    upload: 2026-10-13T14:02:07.164Z request 12: /chat/c/1_3/general/upload, image/png, 9000 bytes, arrived in 40 ms, its turn 3 ms, 7 disk requests: ok (200)
    waited 812 us, answered in 41301 us, 7 disk requests taking 2100 us
```

- **On the request line:** after `->` comes how it ended (`ok`, or an
  error's name), its status code, and how long its answer took. `(base:
  ...)` is what memory held after it.
- **Indented under it:**
  - `body: N bytes, arrived in X ms` for a body. A chat message is logged
    this way, by its length only.
  - `upload: ...` for an upload, with its answer.
  - `waited`, the time from the connection to its head.
- **Lines that are not about a request** (boot, disks, streams ending, the
  idle check) have no time of their own.

**What is never in it.** Secrets are taken out as the log is written, so
nothing can bring them back. That covers cookies, the `Authorization`
header, passwords, keys, tokens, session values, and an upload's name in
its path (`/uploads/[redacted].png`). A message's words are never written,
nor any other part of a message: not a link, not a name, not a mention.

**How much it holds.** The ring holds 1.25 MiB, about a busy hour of
requests. When it fills, the oldest lines go. The header says how much was
lost.

## What the page says

From the top:
1. **Errors since boot**, shown only when there are any: every answer of
   500 or over, the newest first.
2. **The application**: its version and commit, and its memory. Then the
   requests since boot by status class and by part of the site (uploads,
   streams, docs, chat, games, admin, site), the 5 slowest, and the
   refusals counted at the edge.
3. **The host**: zig-metal-unikernel's own facts.
   - The clock and the processor.
   - **Address**: the address DHCP lent at boot, and for how long. The
     machine never renews it. On DigitalOcean's private network the
     address is fixed and running past the lease is harmless; elsewhere,
     "PAST ITS LEASE" with Caddy unable to reach the machine means the
     address was given to someone else.
   - Connections and streams, open now and at most.
   - **TCP since boot**: every count the TCP table keeps. Any of these
     above zero is something that happened, not a fault in itself; what
     to look at is a count that grows:
     - turned away for want of a slot: every connection slot was taken;
     - half-open gave way, revived, found no room: handshakes that did not
       finish (a lost packet, or a flood of new connections);
     - segments sent again, window probes: the network lost something
       between Caddy and the machine, or the peer stopped reading;
     - peers given up on, closes never finished: a client stopped
       answering in the middle of a connection;
     - strays reset: segments for a connection the machine no longer has;
     - dropped for a bad checksum: frames damaged on the way in. On a
       droplet's private network this should stay at zero;
     - arrived ahead of the next byte: a segment before them was lost or
       late on the way in (incoming loss); from behind: the peer sent
       again what had already come; past the window: the peer sent more
       than there was room for. Growing "ahead" is loss toward the machine.
     - resets from peers: connections the other end ended at once (Caddy
       dropping an upstream connection does this); inexact ones
       challenged: resets whose number was off, which a real peer
       follows with an exact one and a forged one does not; bad
       handshake ACKs reset: a client answered our SYN-ACK wrongly;
     - given up by the host: the machine cut a client off. "Stopped
       taking a response" is a slow or vanished reader; "streams too far
       behind" is a live stream whose reader could not keep up; "closes
       of an unfinished handshake" is a connection closed before it was
       ever open. A count that grows with no change in traffic is worth
       a look.
   - **Frames passed over**: frames that were not a TCP segment for
     this machine, by why. On a droplet's private network most are ARP
     for other machines and other ethertypes, and those are no fault.
     A damaged IP header should stay at zero (damage on the way in);
     fragments mean a sender's MTU is wrong somewhere; growing "not TCP"
     or "for another address or port" is misrouting or a scan.
   - **Rests**: how often the processor halted, how many of those halts
     the network card's interrupt ended (a frame arrived, or a buffer was
     taken back), and how many neither the timer nor the card did (an
     NMI, a spurious interrupt: should stay near zero). Ended by the card
     far more often than frames arrive is a device interrupting with
     nothing to say: an interrupt storm, which looks like a busy
     processor otherwise. Each is read off the interrupt's own handler.
   - **Sleeps** (releases from v33): the rests of a machine with nothing
     in motion, which last until the application's next wake or
     `longest_rest_ms` (10 s) (docs/designs/DESIGN-sleep.md): how many,
     how many the card ended, how many ran the whole longest rest, how
     many neither ended, and
     **missed wakes**: a sleep the timer ended after which a frame was
     waiting, one whose interrupt never came. Any missed wake is worth a
     look: it is a request that waited up to the longest rest.
   - **Restarted**: "no", or what ended the boot before this one ("a
     failure", "a panic", "a disk that stopped answering"), how many
     restarts in a row, and when. The boot before's last lines, the disk's
     own report among them, are the end of `/admin/log`. Three in a row
     within an hour, and the next waits before serving (a minute, then 5,
     then 15).
   - **Responses cut off (connection gone, rest unsent)**: a response
     whose end still waited in memory to be sent when its connection went
     (the client closed or reset it, or TCP gave up). Each is also a
     request logged as failed, not "ok". A few are clients going away;
     many, with no matching rise in let-go clients, is worth a look.
   - **Network card stalls**: sends that waited a whole second for the card
     to take a frame back, the card asking for a reset, and frames dropped
     while it took none. Any above zero means the card stopped taking
     frames for a while; TCP sends dropped frames again. "STALLED NOW"
     means it has not taken one back since.
   - **Network card ring**: entries from the card naming a buffer never
     offered (each one a receive buffer lost for good), with a length no
     frame has, and send completions for a buffer not lent. A sound card
     never does these: any above zero is the card or its emulation
     misbehaving.
   - Memory.
   - **Uploads**: a count since boot by answer, and the newest 10. The
     answers are ok, too big, over quota, a kind not taken, writes refused,
     busy, taken over by a newer upload, the client gone, failed, and
     refused.
   - Each volume:
     - free space, and its **failed sector reads and writes**: requests
       the disk did not answer OK. Any above zero is a read or write a
       request could not finish; its error went to that request;
     - its write cache, its flushes (each point a save was made durable)
       and how many of them sent SYNCHRONIZE CACHE to the disk. A disk
       that writes through needs no command, so on it that count stays at
       zero and is no fault. "Did not know the command" means the disk
       refused SYNCHRONIZE once and is treated as writing through from
       then on; on a disk that says it caches, that is worth a look;
     - whether the disk is still answering.
       "STOPPED ANSWERING" means a request went 30 s with no answer, or
       the disk asked for a reset. Nothing more is sent to it: every read
       and write after that fails, counted, and the requests that needed
       it are answered with an error. Only a restart brings it back, and
       **the machine restarts itself** at the next turn, so you
       will rarely see this row say it: you see the next boot's
       "restarted" row instead;
     - **what its failed requests ended with**: "none", or each kind with
       its count. On the boot disk (virtio-blk): I/O errors, unsupported
       requests, and requests refused after the disk stopped answering. On
       the volume (SCSI): CHECK CONDITION by sense key (MEDIUM ERROR is the
       disk's surface; UNIT ATTENTION is the disk saying it was reset or
       changed, and is normal once after attaching), with the last ASC/ASCQ
       to look up in SPC-4; a virtio-scsi response other than OK (the
       hypervisor's transport failed); another SCSI status (BUSY, ...); and
       short transfers (GOOD, but fewer bytes moved than asked). Then
       its **unit attentions** by what they said: resets (normal once
       after attaching), mode parameters changed, capacity changed (the
       volume was resized under the machine: the filesystem still uses
       the old size), LUNs changed (something re-attached), the
       thin-provisioning threshold (the backing store is filling), and
       others with the last ASC/ASCQ. "Lasted every try" is a command that
       met one three times running and failed;
     - **at boot**: reads that failed at boot and answered when tried
       again (above zero: the disk was slow or flaky as the machine came
       up), and how the FAT's two copies stood at mount. "Agreed" is the
       normal case; "differed" means a machine stopped between the
       copies' writes, or a copy reads wrong, and says which was kept and
       what was written. "REFUSED the repair" means the copies are still
       apart;
     - its idle check, with what it last found;
     - whether it takes writes. "writes: REFUSED" means its FAT copies
       could not be weighed at mount; it is weighed again once a minute.
       "Sector writes turned away" counts the writes not made meanwhile:
       above zero, saves were answered with an error.
4. **The log**: its newest 60 lines.

## Five questions, answered

**Did the upload at 14:02 work?**

```bash
admin '/admin/log?since=2026-10-13T14:02&until=2026-10-13T14:03' | grep 'upload:'
```

Each upload's line ends in its answer: `ok (200)`, `refused: over quota
(403)`, `refused: writes refused (503)`, `the client gone`, and so on. It
also says how long the upload took to arrive and how many disk requests it
cost. The `uploads` row on `/admin/host` counts every upload since boot by
answer.

**What failed since boot?**

```bash
admin '/admin/log?boot=this' | grep -E '^# (requests since boot|5xx)'
```

The first line counts the requests by status class. Each `# 5xx:` line
gives a failure's time, path, status, duration and error. To see a failure
in context, take its time from that line:

```bash
admin '/admin/log?since=2026-10-13T14:02:07&until=2026-10-13T14:02:08'
```

On the page, "Errors since boot" leads when there are any.

**Why did the machine restart?**

```bash
admin '/admin/log?boot=before' | grep -v '^#' | tail -20
admin '/admin/log?boot=this' | grep -m3 'restart'
```

The boot before's log ends with its reason (`RESTART: ...`). This boot's
own line says which boot it is and what the boot before ended on. A kernel
built with `-Drestart=false` keeps no boot before.
`# the boot before: none kept` means a first boot, or one that did not end
on purpose: a hang, a power cut, or an external reset.

**Is the disk healthy?**

```bash
admin /admin/host | grep -oE '(the volume|the boot disk|writes)[^<]*</td><td>[^<]*'
admin '/admin/log?boot=this' | grep -E 'disk check|FAT|refuses|weighed'
```

On the page, check each volume's row:
- free space;
- the cleanups and FAT copy writes that failed;
- its idle check's last finding ("no damage", or what it found first);
- whether it takes writes.

In the log, the boot's `disk check` line and any FAT line say what the
mount found.

**Who is connected?**

```bash
admin /admin/host | grep -oE '(connections|streams|requests since boot|by part of the site)</td><td>[^<]*'
```

These are counts, never names: connections open now and at most, live
streams held now and at most, and the requests by part of the site. Nothing
on either view names a person.
