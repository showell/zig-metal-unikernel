# Mutation testing of the pure layers

Coverage says a line **ran**. Mutation testing says whether anything would
have **noticed** if that line were wrong: one small bug planted at a time,
then the tests run.

## The tools

- **`tools/mutate_tcp.py`** breaks the TCP table (`src/tcp.zig` and the
  files split from it) one way at a time; **`tools/mutate_guards.py`** does
  the same for the guards between data and the machine (`io.zig`'s,
  `disk_fat.zig`'s refusals, the kept log's header, the restart record).
  The oracle is `zig build test`. A mutant is killed only by a test that
  fails (`tools/mutate_run.py`); one that does not compile, times out, or
  fails another way is reported apart and fails the run. `--list` names
  them. Each puts the file back with `git checkout` and refuses to start
  over uncommitted changes in a file it would touch. Not in any tier: a
  whole run takes a quarter of an hour or more. Exit 0 when every mutant
  is killed.
- **The plants** (`src/plant.zig`, `-Dplant=<name>`) are deliberate bugs
  kept in the source, which metal-vmm's `plants.sh` requires the judge to
  catch. A kernel with one on must be built `-Dcoverage`, so no release
  image can hold one; `zig build check-plants` type-checks each.

## The survivors still open

A one-off run planted 85 mutants in `tcp`, `durable`, `ready`, the Store,
`log_ring`, `page_cache` and the FAT. Every mutant id the tests cite (S4,
S11, P1, L7, F6, F10, F14, F15 and the rest) is from that run, and its
whole table, with what killed each, is `git show 3658e15:MUTATION.md`.
Nine survivors are equivalent (no oracle could kill them). These four were
not, and no test has been named for them since (T15, `after` at exactly
half the circle, now meets `src/seq.zig`'s tests):

| # | where | the mutant | why it survives | what would catch it |
|---|---|---|---|---|
| T3 | `tcp`, `tight(w)` | `<` becomes `<=` | never asked about a window of exactly `min(our_mss, rx.len / 2)` | a `tcp_test` case at that window, or a `tcp_sim` peer advertising exactly one MSS |
| T6 | `tcp`, `queue` | compacts only past `tx_start > 1` | reached, but callers queue the rest later, so the wire is the same | `tcp_sim` checking that `queue` takes `min(bytes, free room)` |
| P4 | `page_cache`, the eviction that moves a growing copy | `k == self.count - 1` becomes `k == self.count` | the copy in the last slot, once moved, is never the next evicted | already there (`wrote`'s `self.find(key).?`, and `page_sim`'s model) once a run reaches a second eviction: a target for the explorer |
| P5 | `page_cache`, the budget | `size > self.budget` becomes `size > self.budget + 1` | `page_sim`'s budgets are whole pages, so `size == budget + 1` cannot occur | already there (`props.unreachable`, "no room for a file within the budget") once a budget can be one byte short of a page multiple |

**Where mutants have survived, the weak places were timers and accounting
that nothing outside reads back**, not the parsers: what is left on the
disk past a file's end, a temporary left behind, whether a deleted
directory entry is reused. Every kill in that run came from `zig build
test`; the properties sweep at a reduced size caught nothing the tests
missed.
