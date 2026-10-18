# Mutation testing of the pure layers

*metal-vmm QUEUE items 93 and 95 (CC, 2026-10-07).* Coverage says a line
**ran**. This file says whether anything would have **noticed** if that line
were wrong. One small bug was planted at a time in `tcp`, `durable`, `ready`,
the Store, `log_ring`, `page_cache` and `fat16`. Each one was run against
`zig build test`, and if that passed, against `zig build properties` at a
reduced size (`-Dsweep-optimize=ReleaseSafe -Dseeds=30 -Dfat-seeds=8
-Dpage-seeds=40 -Dpure-seeds=60 -Dfull-seeds=4 -Dfloor-seeds=200
-Dstore-seeds=200 -Ddurable-seeds=200 -Dready-seeds=100`). The file was
restored after each run, and no mutant was committed anywhere.

**The mutants were planted on gopher-metal `a9163f2`, and every `where`
below is that commit's** (`git show a9163f2:<file>`). Every file mutated but
`durable.zig` has changed since (fat16.zig is `disk_fat.zig`, split into
several files, and much of `tcp.zig`'s timing is in `tcp_timeouts.zig`), so a line number here does
not find the line on `master`; the mutant's description and its function
do.

## The score

| module | planted | killed when planted | killed now | survivors equivalent | score (killed / planted) |
|---|---|---|---|---|---|
| tcp | 17 | 10 | 12 | 2 (T1, T7) | 12 / 17 |
| durable | 7 | 7 | 7 | 0 | 7 / 7 |
| ready | 10 | 9 | 10 | 0 | 10 / 10 |
| Store (`store`, `store_fat`) | 11 | 7 | 10 | 1 (S11 in effect) | 10 / 11 |
| log_ring | 11 | 8 | 9 | 2 (L6, L10) | 9 / 11 |
| page_cache | 13 | 10 | 11 | 0 | 11 / 13 |
| fat16 | 16 | 8 | 12 | 4 (F2, F13; F4, F11 in effect) | 12 / 16 |
| **all** | **85** | **59** | **71** | **9** | **71 / 85** |

"Killed now" counts the twelve survivors that later got an oracle: T14, T16,
R6 and S2 (item 93); F6, F10, F14 and F15 (disk_fat_test, item 107); S5 and S6
(store_test, with a disk that has a write cache, item 112); and L7 and P1
(floor_sim and page_sim, their generators widened, item 115). Each is named
in the tables below, and each was re-planted and killed. S11 turned out
equivalent in effect (item 115). Leaving out the nine equivalent mutants,
which no oracle could kill, the score is 71 of 76; fat16's is 12 of 12, and
the Store's 10 of 10.

What the run itself shows:

- **Every kill came from `zig build test`.** No mutant that survived the
  tests was caught by the reduced properties sweep. The sweep's value is in
  its range, which needs a run to reach a state first, and that is what the
  explorer (item 95) is for.
- **The simulators earn their place.** Of the 59 kills when planted, 25
  came from a simulator's handful of seeds (`tcp_sim`, `ready_sim`,
  `store_sim`, `page_sim`, `pure_sim`, `fat_sim`, `floor_sim`) or from a
  model comparison (`store_test`, `io_test`), not from a unit test.
- **The weak places are timers and accounting that nothing outside reads
  back**, not the parsers. They are: Karn's rule (T14, now checked); what is
  left on the disk past a file's end (F6); a temporary file left behind
  (S6); whether a deleted directory entry is reused (F15); and whether
  `queue` takes all the room it has (T6).
- **Two Store mutants as first written did not compile** (zig refuses an
  unused local or parameter). S8 and S11 were rewritten (`and false` added)
  and run again. The table shows the rewritten forms.

## Every mutant

| # | where | original | mutant | verdict | by |
|---|---|---|---|---|---|
| T1 | src/tcp.zig:279 | `self.start > self.rx.len / 2` | `self.start >= self.rx.len / 2` | survived | see below |
| T2 | src/tcp.zig:332 | `off < @max(self.window(), 1)` | `off <= @max(self.window(), 1)` | killed | `tcp_test`: a reset at the window's right edge is outside it, and is ignored |
| T3 | src/tcp.zig:349 | `return @as(usize, w) < @min` | `return @as(usize, w) <= @min` | survived | see below |
| T4 | src/tcp.zig:516 | `now - c.opened_at < min_rto_ns` | `now - c.opened_at <= 0` | killed | `tcp_test`: a SYN flood does not keep a real client out: the oldest half-open connection gives way |
| T5 | src/tcp.zig:517 | `c.opened_at < self.conns[oldest.?].opened_at` | `c.opened_at > self.conns[oldest.?].opened_at` | killed | `tcp_sim`: revival: item 24's seeds, rough and crowded, pass; with the ring off, each fails as before |
| T6 | src/tcp.zig:668 | ` and c.tx_start > 0)` | ` and c.tx_start > 1)` | survived | see below |
| T7 | src/tcp.zig:784 | `if (c.wnd > c.sent)` | `if (c.wnd >= c.sent + 1)` | survived | see below |
| T8 | src/tcp.zig:897 | `c.retries >= max_retries` | `c.retries > max_retries` | killed | `tcp_test`: a peer that never answers is reset after the last timeout |
| T9 | src/tcp.zig:885 | `(3 * c.rttvar_ns + off) / 4` | `(3 * c.rttvar_ns + off) / 3` | killed | `tcp_test`: the handshake is the first measurement, and the estimate is RFC 6298's |
| T10 | src/tcp.zig:921 | `advance > flight` | `advance >= flight` | killed | `tcp_test`: our FIN, then theirs acknowledging it, closes it and frees the slot |
| T11 | src/tcp.zig:944 | `if (!updated) c.wnd -= @min(c.wnd, advance);` | `if (false) c.wnd -= @min(c.wnd, advance);` | killed | `tcp_test`: an older segment with a newer acknowledgement moves the window's edge too |
| T12 | src/tcp.zig:945 | `advance > bytes` | `advance >= bytes` | killed | `tcp_test`: only what the window allows goes out, and an acknowledgement lets more go |
| T13 | src/tcp.zig:840 | `c.updates >= max_retries` | `c.updates > max_retries` | killed | `tcp_test`: a peer with nothing more to say is told a bounded number of times |
| T14 | src/tcp.zig:863 | `c.timed_at = null;` | `c.timed_at = c.timed_at;` | survived, now killed | tcp_sim Karn oracle, `3c9fceb` |
| T15 | src/tcp.zig:1234 | `d < 0x8000_0000` | `d <= 0x8000_0000` | survived | see below |
| T16 | src/tcp.zig:1220 | `len < 2 or` | `len < 1 or` | survived, now killed | floor_sim `mssSeed`, `9745fd1` |
| T17 | src/tcp.zig:1225 | `if (c.peerDone()) return self.close(i);` | `if (false) return self.close(i);` | killed | `tcp_test`: their FIN repeated before we close is acknowledged again, and after, reset |
| D1 | src/durable.zig:49 | `if (!d.unflushed) return .none;` | `if (false) return .none;` | killed | `durable`: nothing written, nothing done; written through, cleared; cached or not said, synchronized |
| D2 | src/durable.zig:50 | `!d.asks or d.write_cache == false` | `!d.asks or d.write_cache != true` | killed | `durable`: nothing written, nothing done; written through, cleared; cached or not said, synchronized |
| D3 | src/durable.zig:50 | `!d.asks or d.write_cache == false` | `!d.asks and d.write_cache == false` | killed | `store_test`: the model and the FAT store agree on every operation, and every error |
| D4 | src/durable.zig:65 | `d.unflushed = false;` | `d.unflushed = d.unflushed;` | killed | `io_test`: a write is flushed before the next response, once, and a read asks no flush |
| D5 | src/durable.zig:69 | `if (ok) d.unflushed = false else` | `if (true) d.unflushed = false else` | killed | `durable`: a failed synchronize leaves the disk unflushed, to be tried again |
| D6 | src/durable.zig:71 | `return !ok;` | `return ok;` | killed | `durable`: a failed synchronize leaves the disk unflushed, to be tried again |
| D7 | src/durable.zig:71 | `return !ok;` | `return false;` | killed | `durable`: a failed synchronize leaves the disk unflushed, to be tried again |
| R1 | src/ready.zig:62 | `if (left < @min` | `if (left <= @min` | killed | `ready`: a head the window has shut on is served, unended: a segment's room or less left |
| R2 | src/ready.zig:62 | `capacity / 2)) return .ready;` | `capacity / 3)) return .ready;` | killed | `ready_sim`: ready.zig under a seed, a handful of seeds |
| R3 | src/ready.zig:63 | `return if (peer_done) .abandoned else .waiting;` | `return .waiting;` | killed | `ready`: a peer that closed without a whole head is served, to be logged and let go |
| R4 | src/ready.zig:74 | `if (!head.method.requestHasBody()) return .ready;` | `if (false) return .ready;` | killed | `ready`: a method that takes no body is ready however it is framed |
| R5 | src/ready.zig:75 | `if (head.expect != null) return .ready;` | `if (false) return .ready;` | killed | `ready_sim`: ready.zig under a seed, a handful of seeds |
| R6 | src/ready.zig:76 | `if (head.transfer_encoding != .none) return .ready;` | `if (false) return .ready;` | survived, now killed | ready_sim chunked + length, `1a3fbc4` |
| R7 | src/ready.zig:80 | `have >= want` | `have > want` | killed | `ready`: a body still arriving is waited for, byte by byte |
| R8 | src/ready.zig:81 | `want > capacity - @min(head_len, capacity)` | `want > capacity` | killed | `ready_sim`: ready.zig under a seed, a handful of seeds |
| R9 | src/ready.zig:82 | `return if (peer_done) .abandoned else .waiting;` | `return .waiting;` | killed | `ready`: a client that closed part-way through its body is served and let go |
| R10 | src/ready.zig:78 | `orelse 0;` | `orelse 1;` | killed | `ready_sim`: ready.zig under a seed, a handful of seeds |
| S1 | src/store.zig:127 | `part.len > max_part` | `part.len > max_part + 1` | killed | `store`: paths: empty parts ignored, FAT's rules kept, the Store's prefix refused |
| S2 | src/store.zig:131 | `c < 0x20 or c == 0x7F` | `c < 0x20` | survived, now killed | store test, `051941b` |
| S3 | src/store.zig:135 | `last == '.' or last == ' '` | `last == '.'` | killed | `store`: paths: empty parts ignored, FAT's rules kept, the Store's prefix refused |
| S4 | src/store_fat.zig:52 | `error.Full, error.DirectoryFull => Error.NoSpace` | `error.DirectoryFull => Error.NoSpace` | killed | `store_sim`: store_sim: one seed, the one that fills the volume (properties: 1..1000) |
| S5 | src/store_fat.zig:133 | `if (f.vol.blk.flush() != ` | `if (false and f.vol.blk.flush() != ` | survived, now killed | store_test, a write cache that wrote back only the root's sectors, `6298c0c` |
| S6 | src/store_fat.zig:135 | `f.vol.remove(temp) catch {};` | `_ = &f;` | survived, now killed | store_test, a root with no room for the new name, `6298c0c` |
| S7 | src/store_fat.zig:109 | `f.vol.writeInto(p, e.size, bytes)` | `f.vol.writeInto(p, e.size -\| 1, bytes)` | killed | `store_test`: the model and the FAT store agree on every operation, and every error |
| S8 | src/store_fat.zig:119 | `if (e.isDirectory()) return Error.IsDirectory;` | `if (e.isDirectory() and false) return Error.IsDirectory;` | killed | `store_test`: the model and the FAT store agree on every operation, and every error |
| S9 | src/store_fat.zig:153 | `if (store.hidden(name)) continue;` | `if (false) continue;` | killed | `store_test`: the model and the FAT store agree on every operation, and every error |
| S10 | src/store_fat.zig:92 | `if (e.isDirectory()) return Error.IsDirectory;` | `if (false) return Error.IsDirectory;` | killed | `store_sim`: store_sim: one seed, the one that fills the volume (properties: 1..1000) |
| S11 | src/store_fat.zig:50 | `if (writing) Error.BadName else Error.NotFound` | `if (writing and false) Error.BadName else Error.NotFound` | survived, equivalent in effect | see below |
| L1 | src/log_ring.zig:104 | `self.total < self.buf.len` | `self.total <= self.buf.len` | killed | `pure_sim`: log_ring: a ring holding exactly its capacity reads back what it holds |
| L2 | src/log_ring.zig:99 | `self.total -\| self.buf.len` | `self.total -\| (self.buf.len + 1)` | killed | `log_ring`: once bytes are lost, a read starts at the first whole line |
| L3 | src/log_ring.zig:123 | `if (skip == self.len()) skip = 0;` | `if (false) skip = 0;` | killed | `log_ring`: a line longer than the ring keeps its tail, and is read whole as far as it is held |
| L4 | src/log_ring.zig:118 | `skip = i + 1;` | `skip = i;` | killed | `log_ring`: once bytes are lost, a read starts at the first whole line |
| L5 | src/log_ring.zig:133 | `var from = skip + (held - n);` | `var from = skip;` | killed | `log_ring`: what is written is read back, oldest first |
| L6 | src/log_ring.zig:136 | `from >= piece.len` | `from > piece.len` | survived | see below |
| L7 | src/log_ring.zig:225 | `b != self.quote and b != '\n' and b != '\r'` | `b != self.quote and b != '\n'` | survived, now killed | floor_sim `redactSeed`, `230e4cf` |
| L8 | src/log_ring.zig:229 | `' ', '\t', '"', '\'', '&', ';', ',', '\n', '\r' => self.state = .plain,` | `' ', '\t', '"', '\'', ';', ',', '\n', '\r' => self.state = .plain,` | killed | `log_ring`: a value after a key naming a secret is taken out, in a query string and in JSON |
| L9 | src/log_ring.zig:233 | `'.', '/', '?', ' ', '\t', '"', '\n', '\r' => self.state = .plain,` | `'/', '?', ' ', '\t', '"', '\n', '\r' => self.state = .plain,` | killed | `log_ring`: an upload's id is taken out of its path, and its extension kept |
| L10 | src/log_ring.zig:246 | `if (b == '\n') self.window = @splat(0);` | `if (false) self.window = @splat(0);` | survived | see below |
| L11 | src/log_ring.zig:245 | `std.ascii.toLower(b)` | `b` | killed | `log_ring`: a value after a key naming a secret is taken out, in a query string and in JSON |
| P1 | src/page_cache.zig:85 | `n + part.len > max_key` | `n + part.len > max_key + 1` | survived, now killed | page_sim, a lone part of `max_key + 1` bytes, `230e4cf` |
| P2 | src/page_cache.zig:118 | `self.used[i] = self.clock;` | `self.used[i] = self.used[i];` | killed | `page_cache`: the budget holds: the least recently used go first, and a file larger than largest is never kept |
| P3 | src/page_cache.zig:146 | `self.used[i] < self.used[oldest.?]` | `self.used[i] > self.used[oldest.?]` | killed | `page_cache`: the budget holds: the least recently used go first, and a file larger than largest is never kept |
| P4 | src/page_cache.zig:155 | `k == self.count - 1` | `k == self.count` | survived | see below |
| P5 | src/page_cache.zig:182 | `size > self.budget` | `size > self.budget + 1` | survived | see below |
| P6 | src/page_cache.zig:176 | `if (self.find(key)) \|i\| self.drop(i);` | `if (self.find(key)) \|i\| if (false) self.drop(i);` | killed | `io_test`: the page cache is the disk: every change interleaved with reads, under evictions and failed writes |
| P7 | src/page_cache.zig:245 | `offset > len` | `offset > len + 1` | killed | `floor_sim`: floor_sim: GPT, built field by field with one field wrong, a handful of seeds |
| P8 | src/page_cache.zig:253 | `end > self.bufs[i].len` | `end > self.bufs[i].len + 1` | killed | `page_cache`: the budget holds: the least recently used go first, and a file larger than largest is never kept |
| P9 | src/page_cache.zig:274 | `@max(len, end)` | `end` | killed | `io_test`: the page cache is the disk: every change interleaved with reads, under evictions and failed writes |
| P10 | src/page_cache.zig:291 | `if (to_key) \|k\| if (self.find(k)) \|i\| self.drop(i);` | `if (to_key) \|k\| if (self.find(k)) \|i\| if (false) self.drop(i);` | killed | `page_sim`: the page cache against a model of the disk, a handful of seeds |
| P11 | src/page_cache.zig:311 | `k[key.len] == '/'` | `k[key.len] != 0` | killed | `page_cache`: rename moves the copy over any at the new name; a tree removed takes everything under it, and only that |
| P12 | src/page_cache.zig:269 | `self.held += more;` | `self.held += more - 1;` | killed | `page_sim`: the page cache against a model of the disk, a handful of seeds |
| P13 | src/page_cache.zig:227 | `self.used[i] < self.used[oldest]` | `self.used[i] > self.used[oldest]` | killed | `floor_sim`: floor_sim: GPT, built field by field with one field wrong, a handful of seeds |
| F1 | src/disk_fat.zig:1091 | `self.free_clusters += 1` | `self.free_clusters += 0` | killed | `store_test`: the model and the FAT store agree on every operation, and every error |
| F2 | src/disk_fat.zig:1117 | `looked == clusters` | `looked == clusters + 1` | survived | see below |
| F3 | src/disk_fat.zig:1871 | `.kept => try self.readSector(lba, self.scratch),` | `.kept => @memset(self.scratch, 0),` | killed | `io_test`: the page cache is the disk: every change interleaved with reads, under evictions and failed writes |
| F4 | src/disk_fat.zig:1835 | `at + have >= bytes.len` | `at + have > bytes.len` | survived | see below |
| F5 | src/disk_fat.zig:1837 | `next != last + 1` | `next != last + 2` | killed | `store_sim`: store_sim: one seed, the one that fills the volume (properties: 1..1000) |
| F6 | src/disk_fat.zig:1872 | `.zeros => @memset(self.scratch, 0),` | `.zeros => try self.readSector(lba, self.scratch),` | survived, now killed | disk_fat_test: a file ending inside a sector leaves zeros past its end, not what a file before it left (mutant F6) |
| F7 | src/disk_fat.zig:1717 | `offset > entry.size` | `offset > entry.size + 1` | killed | `floor_sim`: floor_sim: GPT, built field by field with one field wrong, a handful of seeds |
| F8 | src/disk_fat.zig:1753 | `need > end.clusters` | `need > end.clusters + 1` | killed | `disk_fat_faults_test`: every operation stopped after every write leaves an outcome its doc names, and at worst leaked clusters |
| F9 | src/disk_fat.zig:2016 | `if (d.first_cluster >= 2) try self.freeChain(d.first_cluster);` | `if (false) try self.freeChain(d.first_cluster);` | killed | `fat_sim`: the same, with probes of what the volume must refuse, one seed (properties: 1..20) |
| F10 | src/disk_fat.zig:2483 | `offset >= entry.size` | `offset > entry.size` | survived, now killed | disk_fat_test: reading at a file's very end reads nothing, even where its chain ends there too (mutant F10) |
| F11 | src/disk_fat.zig:2533 | `got + have >= want` | `got + have > want` | survived | see below |
| F12 | src/disk_fat.zig:2410 | `entry.size > out.len` | `entry.size > out.len + 1` | killed | `floor_sim`: floor_sim: GPT, built field by field with one field wrong, a handful of seeds |
| F13 | src/disk_fat.zig:2470 | `out.clusters > self.max_cluster` | `out.clusters > self.max_cluster * 2` | survived | see below |
| F14 | src/disk_fat.zig:2236 | `if (n < need) self.report(.short, first, n);` | `if (n + 1 < need) self.report(.short, first, n);` | survived, now killed | disk_fat_test: the check finds a chain exactly one cluster short of its size (mutant F14) |
| F15 | src/disk_fat.zig:1211 | `first == 0x00 or first == 0xE5` | `first == 0x00` | survived, now killed | disk_fat_test: a name removed leaves its entries for the next name of the same length (mutant F15) |
| F16 | src/disk_fat.zig:1385 | `self.scratch[pos.at] = 0xE5;` | `self.scratch[pos.at] = self.scratch[pos.at];` | killed | `disk_fat_test`: a file rewritten under a name in another case keeps the name and alias it has |

## The survivors

Each survivor was diagnosed by a **difference probe**: the original line kept,
with `@panic` planted exactly where the mutant would have behaved
differently. The probe ran under `zig build test` and then under
`zig build properties` at **default** sizes (100 TCP seeds, 20 FAT, and so
on). There are three verdicts:

- **reached, unchecked**: a run gets to a state where the mutant differs, and
  nothing notices.
- **unreached**: no run gets to such a state.
- **equivalent**: no state makes the mutant differ, or the difference is
  only in speed.

| # | verdict | why it survived | what would catch it | whose |
|---|---|---|---|---|
| T1 | equivalent | Compacting the receive buffer at exactly half instead of past half moves the same bytes. | nothing can | none |
| T3 | unreached | `tight(w)` is never asked about a window of exactly `min(our_mss, rx.len / 2)`. | a `tcp_test` case at that window, or a `tcp_sim` peer that advertises exactly one MSS | box (`tcp_test`); `tcp_sim` side mine |
| T6 | reached, unchecked | With `tx_start == 1`, `queue` doesn't compact and takes less. 8 test runs reach it. Callers queue the rest later, so nothing differs on the wire. | `queue` takes `min(bytes, free room)`, checked in `tcp_sim`'s server when it queues | mine (`tcp_sim`) |
| T7 | equivalent | `wnd > sent` and `wnd >= sent + 1` agree for every u32 that can occur. | nothing can | none |
| T14 | reached, unchecked; **now killed** | Nothing checked that a resent segment is not timed (Karn). | `tcp_sim` reads every frame the table sends, `3c9fceb` | done |
| T15 | unreached | No run has sequence numbers exactly 2^31 apart. There the mutant makes `after(a, b)` and `after(b, a)` both true. | a `tcp_test` case: `after` is never true both ways | box (`tcp_test`) |
| T16 | unreached; **now killed** | No test had an option of length 1 before an MSS. | floor_sim `mssSeed`, `9745fd1` | done |
| R6 | reached, unchecked; **now killed** | Every chunked request ready_sim made had no Content-Length. | ready_sim: a chunked body that also gives a length, `1a3fbc4` | done |
| S2 | unreached; **now killed** | No test named a path with DEL (0x7F) in it. | the Store's path test, `051941b` | done |
| S5 | reached, unchecked; **now killed** | No disk in any test lost a write it hadn't flushed, so `replace` without its flush acted the same. | `test_disk.Cache`, a disk that holds writes until a flush; `store_test` cuts it after a `replace` with only the root's sectors written back, `6298c0c`. (Under `store_sim`, item 112's cached run fails on fat16 itself first; see QUEUE.md.) | done |
| S6 | reached, unchecked; **now killed** | When `replace`'s rename fails, the hidden temp file stays and its clusters leak. `list` hides it, and the model never counts clusters. | `store_test`: a root with room for the hidden copy and none for the new name; free clusters after the refusal equal those before, `6298c0c` | done |
| S11 | equivalent in effect | Every write that meets a file as a parent meets it in fat16's `makeDirIn` first, which answers `BadName` itself; `rename` is only reached once the parent was made. So `map` never sees `NotFat16` for a write. | nothing can; `store_test` pins the answer, `230e4cf` | none |
| L6 | equivalent | When `from == piece.len`, the mutant copies 0 bytes and sets `from = 0`, which is what skipping the piece does. | nothing can | none |
| L7 | unreached; **now killed** | No line ended a quoted secret with a bare `\r` before its closing quote. There the mutant drops the `\r`, which over-redacts and does not leak. | floor_sim `redactSeed`: now and then a quoted value its line ends with `\r\n` before it closes, and the `\r\n` comes out, `230e4cf` | done |
| L10 | equivalent | Every key is matched as contiguous bytes, and `\n` is not in any key, so a stale window before a newline can never match. | nothing can | none |
| P1 | unreached; **now killed** | `page_sim`'s over-long paths always had a prefix part, so `n + part.len` was never exactly `max_key + 1`. There the mutant writes `out[256]`, out of bounds. | `page_sim`: one too-long path in eight is a lone part of exactly `max_key + 1` bytes, `230e4cf` | done |
| P4 | reached, unchecked | When a growing copy is the last slot and an eviction moves it, the mutant loses track of it (8 test runs reach this). It survives because the copy is never also the oldest left, so it is never the next one evicted. | already there: `wrote`'s `self.find(key).?` panics, and `page_sim`'s model disagrees. **For the explorer.** | explorer |
| P5 | unreached | `page_sim`'s budgets are whole pages and sizes are rounded to pages, so `size == budget + 1` can't occur. | already there (`props.unreachable` "no room for a file within the budget"), once a budget can be one byte short of a page multiple | mine (`page_sim`'s budget) |
| F2 | equivalent | Looking once more at the first candidate, already found taken, changes nothing. | nothing can | none |
| F4 | equivalent in effect | When a write's run ends exactly at the end of its data, the mutant looks up one more cluster and then writes the same sectors. Unreached under the probe as well. | nothing can (one more FAT lookup) | none |
| F6 | reached, unchecked; **now killed** | A write that ends inside a new sector keeps whatever the disk held there instead of zeroing it. Bytes past the file's size are never read, so nothing notices. 150 test runs reach it. | `fat_sim`'s end of run: the bytes after each file's size in its last sector are zero | mine (`fat_sim`) |
| F10 | unreached; **now killed** | No caller reads at `offset == size`. The mutant then walks the chain to a cluster that may not exist and answers `BadChain` instead of 0. | floor_sim's `readAt` cases: at `offset == size`, with the size a whole number of clusters, expect 0 bytes | mine (`floor_sim`) |
| F11 | equivalent in effect | When a read's run ends exactly at what is wanted, the mutant follows one more link, and copies only what is wanted. | nothing can (one more FAT lookup) | none |
| F13 | equivalent | It detects a chain loop at twice the volume's cluster count instead of once. The error is the same, later. | nothing can | none |
| F14 | reached, unchecked; **now killed** | `check` misses a chain exactly one cluster short of its size. The tests that reach one (2 runs) accept `.short` but don't require it. | floor_sim `fatSeed`: a size exactly one cluster past the chain, and `check` must report `.short` | mine (`floor_sim`) |
| F15 | reached, unchecked; **now killed** | `findRun` never reuses a deleted (0xE5) entry, so a directory grows instead. On FAT16 the root fills sooner. Every outcome is still allowed, because a full directory is an accepted answer. | `fat_sim`: after a remove, a name needing no more entries than were freed fits without the directory growing | mine (`fat_sim`) |

### The fat16 survivors and the kernel

**None of the eight fat16 survivors shows a defect in kernel code.**

- **Four are equivalent** (F2, F13), or equivalent apart from speed (F4,
  F11): one more FAT lookup, or a loop detected later.
- **The other four were weak oracles**, and each now has the test that
  kills it in `disk_fat_test.zig` (metal-vmm QUEUE 107):
  - F6: no test checks what is on the disk past a file's end.
  - F10: no test reads at the very end of a file.
  - F14: no test checks the checker on a chain one cluster short.
  - F15: no test checks that deleted entries are reused.

Two of them come closest to mattering in production:

- **F6.** If `.zeros` ever stopped zeroing, an old file's bytes would sit on
  the disk past a new file's end. The kernel zeroes them today. Nothing
  would notice if it stopped.
- **F15.** If deleted entries stopped being reused, a FAT16 root that sees
  many deletes would hit `DirectoryFull` early. Again, the kernel is right
  today and nothing would notice if it changed.

The survivors whose natural test is a kernel unit test, and so the box's,
are both in **tcp**: T3 (`tight` at exactly one MSS) and T15 (`after` at
2^31). Both are unreached, and both are a one-line `tcp_test` case.

## For the explorer

*(Item 95.)* These are survivors where an **existing** oracle would fail if a
run reached the right state. Plant the patch, and see whether blind seeds or
the explorer gets there first.

1. **P4: a growing copy loses track of itself after an eviction.** The state
   has three parts: a `wrote` that grows the copy in the **last** slot, an
   eviction that moves it, and then a second eviction that needs room and
   finds it the oldest left. The tests already reach the first two (8 runs).
   The third is the rare one. `wrote`'s `self.find(key).?` panics, or
   `page_sim`'s model sees the copy gone. The patch:
   ```diff
   --- a/src/page_cache.zig
   -            if (keep_at) |k| if (k == self.count - 1) {
   +            if (keep_at) |k| if (k == self.count) {
   ```
   The choices that lead there are all in `page_sim`: the budget, the
   sizes, and the order of operations (`put`, `get`, `wrote`). Once those
   are named choices, this is the cleanest steering target in the list.

2. **P5: a budget one byte short of a page multiple.** It is unreachable
   while `page_sim`'s budget is `intRangeAtMost(1, 12) * page`. If the budget
   becomes a named choice that includes `k * page - 1`, the
   `props.unreachable` "no room for a file within the budget" fires as soon
   as a file rounds to exactly `budget + 1`. The patch:
   ```diff
   --- a/src/page_cache.zig
   -        if (size > self.budget) {
   +        if (size > self.budget + 1) {
   ```
   This is a test of whether steering can open a choice blind seeds never
   make, so it needs the budget's alternatives widened first.

3. **T6 is not a target yet.** It is reached today, but nothing fails when
   it differs. It becomes one once `tcp_sim` checks `queue`'s room. (S6 was
   here too; `store_test` kills it now.)

The unreached survivors (T3 and T15; L7, P1 and F10 are killed now, and S11
is equivalent) aren't on this list for
a different reason: no generator makes their state at all, so steering has
nothing to choose. Each needs its generator widened, as the table says.

## How it was run

The scripts are in CC's session, not this repo. For each mutant:
1. Replace the exact original text on its line, checking it occurs once.
2. Run `zig build test`. If it fails, the mutant is killed, and the failing
   test is named from the build summary.
3. If it passes, run the reduced `zig build properties` (timeout 1200 s).
4. Restore the file with `git checkout`, and check the tree is clean before
   the next mutant.

A mutant that failed to compile was recorded as stillborn and rewritten.
