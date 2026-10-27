# Coverage properties

`always` and `sometimes` properties of a whole run, from
[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk). Its README
covers the API, the catalog, and where it differs from Antithesis. This file
covers what zig-metal-unikernel does with it.

**The SDK is a path dependency** (`build.zig.zon`) on a sibling checkout,
`../zig-coverage-sdk`. Its scanner reads every file in `src/` that imports
the SDK (`build.zig` `catalogFiles`, but those `not_cataloged` names with why:
tests, benches, the module root), so their properties are in the catalog even
in code a program never calls, and one never reached shows as a MISS; every
module that compiles one imports `"coverage"` and `"coverage_catalog"`.

## Decisions

- **A FAIL fails every tier.** A FAIL is a broken `always`, or an
  `unreachable` that was reached. **A MISS** (a property the run never got
  to) **fails only the long tier, and only for a property on its floor**
  (`coverage/`). Antithesis treats the two alike; we don't, on purpose
  (the SDK's README).
- **Three tiers, one set of properties.** `zig build test` runs a few seeds
  of each simulator; `zig build properties` sweeps every simulator at the
  seed counts its `-D…-seeds` options default to (`zig build --help`), in
  20 minutes in Debug and 5 with `-Dsweep-optimize=ReleaseSafe`;
  `./long.sh` runs it at its `SEEDS`, `CROWD_SEEDS` and `FAT_SEEDS`, and
  the real kernel's lossy sweep. Each reads the same properties with a
  bigger budget.
- **Debug for test code:** it builds in a fraction of the time. A sweep is
  nearly all running, about three times slower in Debug, so `long.sh`
  builds its with `-Dsweep-optimize=ReleaseSafe`. Shipping kernels are
  ReleaseSafe.
- **QEMU stays mostly on the happy path.** The judge checks that metal
  answers as Linux does, on a clean network. **The budget for covering
  every scenario goes to metal-vmm**, where every frame, disk request and
  clock tick is ours to choose and a run repeats exactly, and to the
  simulators on Linux.
- **Nothing deployed writes the lines.** `-Dcoverage` is off by default:
  the declarations alone would fill the log ring `/admin/host` shows. The
  counters are still kept, at the cost of one add per site reached.

## Running it

**On Linux, against the simulators** (`src/properties.zig`):

    zig build properties
    zig build properties -Dseeds=5000 -Dfat-seeds=300 -Dsweep-optimize=ReleaseSafe
    zig build properties -Dsdk-jsonl=out/sdk.jsonl
    zig build properties -Dtrace-reach      # which simulators reach each floor line, and the first seed

A seed whose oracle fails is a false `always` with its seed in the details,
and the sweep goes on. Only a FAIL fails the step. (zig's build runner prints
"failed command" for any test that writes to stderr, so read the summary
line instead.)

**On metal:**

    zig build gopher -Dcoverage
    COVERAGE_OUTPUT_DIR=out probe/run.sh gopher uploads
    ../zig-coverage-sdk/tools/report.py out/sdk.jsonl

The kernel writes each line to the serial port behind `coverage: `: the port
only, not the log ring. The judge appends every boot's lines to
`$COVERAGE_OUTPUT_DIR/sdk.jsonl`. `tools/coverage_jsonl.sh` does the same for
any serial log, such as a droplet's.

A gopher.elf built `-Dcoverage` also checks `tcp_check`'s rules after every
`handle` and `transmit` (`stream.checkTable`, as the simulators do: "tcp:
the table's invariants hold"), and the volumes after every request ("fat:
after a request, a volume has no damage beyond what a stop leaves",
`probe/volumes.zig`). Every build checks at boot. A production build
compiles no per-turn or per-request check (`coverage_checks` is comptime).

**The long tier, for bug hunting and before a deploy:**

    ./long.sh              # about 10 minutes
    SEEDS=50000 ./long.sh
    ./long.sh sim | metal  # one half

- **The simulators** (ReleaseSafe), at the counts at the top of `long.sh`,
  each with the measurement that chose it, against
  `coverage/floor-sim.txt` (`zig build properties -Dfloor=...`).
- **The real kernel**, gopher.elf built `-Dcoverage`, on metal-vmm's
  PC-shaped machine (`TRANSPORT=pci`: halting between frames and woken by
  interrupts, as on a droplet), over a 5 ms wire, with a copy of the site
  volume attached. For each of three routes the wire eats the guest's 1st
  frame, then its 2nd, through a sample of the frames the route sends, one
  deterministic run each, and **every run must still serve the page an
  unhurt run serves.** The runs' properties are judged against
  `coverage/floor-metal.txt` by the SDK's `tools/report.py --floor`.

A floor line naming no property fails too: a floor goes stale loudly.

**The seed explorer** (zig-coverage-sdk's `explore.zig`) runs the
simulators from a recorded tape instead of a seed (`runWith`), so it can
return to a run and steer it. Two tools, neither a gate:

    zig build explore      # the explorer against blind seeds on fat_sim or store_sim (-Dexplore-sim)
    tools/soak.sh          # OVERNIGHT, detached: explorer and blind columns on fat, store, tcp and tcp_pair, 7 hours, log in ~/soak-logs/

The soak prints, round by round, what only some columns reached and every
failure with its recipe (simulator, column, explorer seed); stop it (its
PID) before a morning's gates.

## The floor

Every refusal is named with a `reachable` and every invariant with an
`always`, and each is reached by a simulator or a host test, so a report
says which any run has met. `tcp_sim`'s rough seeds (`Rough`) are there so
the table's resets, challenge ACKs, give-ups and SYN floods are met under
loss and reordering; `floor_sim` builds damaged inputs field by field (a
GPT, a boot sector, a UDP datagram, an ARP request, a PVH start info). A module that
imports `io.zig`, a driver or interrupts (`stream`, `scsi`, `virtio`,
`io`'s flush, `pci`, `rng`, the RTC chip and the PIT's timer) cannot be
driven by a simulator, so its properties are off `floor-sim.txt` and
listed below. A few of `disk_fat`'s are met only by `disk_fat_test.zig`,
which `properties` does not run, or only at the long tier's FAT seeds.

## For the box

Properties that only a real device reaches. Each one's knob, for a
metal-vmm run in `long.sh`; once a run reaches it, it goes on
`floor-metal.txt`. A refusal with no knob says so: that is a proposal for one.

| property | module | knob |
|---|---|---|
| virtio: a flush fails, is counted, and the disk stays unflushed | `virtio_blk.zig` | `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_SYNC_FAIL=1`, and a chat post |
| (no property) The Store's `replace` flushes before it renames | `store_fat.zig` | `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_CUT_AT_EXIT=1` around a `replace`: in memory a flush does nothing, so only a write cache shows that the rename cannot reach the media before the data. Needs a kernel that calls the Store, which none does yet |
| stream: a read finds the peer closed or done, so nothing more is coming | `stream.zig` | `PEER_RESET_AT=<before the request ends>` (unverified) |
| stream: a read waits idle_ns for a byte, and gives up | `stream.zig` | `PEER_DRIP_US=11000000` with a request of several segments (`PEER_MSS`), each later than `idle_ns` (10 s) (unverified) |
| stream: a write finds the connection gone | `stream.zig` | `PEER_RESET_AT=<while the answer goes out>` (unverified) |
| stream: a write finds the connection gone, with a spill | `stream.zig` | the same, on a large answer (unverified) |
| stream: a write waits idle_ns with nothing taken, and gives up | `stream.zig` | `PEER_SHUT_AFTER=1000 PEER_SHUT_FOR_US=11000000`, or `PEER_VANISH_AFTER=1000` (unverified) |
| stream: a spill too full to keep more is drained first | `stream.zig` | a large answer (a picture) and `PEER_SHUT_AFTER` small (unverified) |
| stream: draining a spill finds the connection gone; and waits idle_ns and gives up | `stream.zig` | the two above, together (unverified) |
| tcp: the table's invariants hold | `stream.zig` (B15) | any run of a `-Dcoverage` gopher.elf; every rough-peer run in `long.sh` |
| fat: after a request, a volume has no damage beyond what a stop leaves | `probe/gopher.zig` (B15) | any run of a `-Dcoverage` gopher.elf that serves a request; with `VOLUME_CUT_AFTER` or `DISK_CUT_AFTER` and a remount, it judges what a cut left |
| scsi: a controller with no disk on it | `scsi.zig` | `VOLUME=<copy> VOLUME_GONE_AT=1`: INQUIRY answers BAD_TARGET (unverified) |
| scsi: a disk that will not say how big it is | `scsi.zig` | `VOLUME_GONE_AT=<READ CAPACITY's command number>`, about 2 or 3 after a UNIT ATTENTION (unverified) |
| scsi: a disk that does not answer MODE SENSE is taken to cache | `scsi.zig` | `VOLUME_GONE_AT=<MODE SENSE's command number>`, one after READ CAPACITY (unverified) |
| scsi: a MODE SENSE answer without the caching page is taken to cache | `scsi.zig` | `VOLUME=<copy> VOLUME_MODE_PAGES=none` |
| scsi: a controller whose CDB or sense size is not the default | `scsi.zig` | **no knob**: a proposal, metal-vmm's virtio-scsi config with other sizes |
| scsi: a disk whose sectors are not 512 bytes, or too many to count | `scsi.zig` | `VOLUME=<copy> VOLUME_SECTOR=4096` |
| virtio: an mmio or a pci queue smaller than this driver needs, or none | `virtio.zig` | **no knob**: a proposal, a device whose `queue_num_max` is small |
| virtio: a device without VIRTIO_F_VERSION_1, or without a feature this driver needs, is refused | `virtio.zig` | **no knob**: a proposal, a device that offers fewer features |
| virtio: a device that will not keep FEATURES_OK; that fails at DRIVER_OK | `virtio.zig` | **no knob**: a proposal, a device that clears or fails a status bit |
| rtc: no chip answers | `rtc.zig` | `RTC_ABSENT=1` |
| rtc: the chip says it is updating for half a second | `rtc.zig` | `RTC_STUCK=1` |
| rtc: two readings never agreed; the seconds never changed | `rtc.zig` | **no knob**: a proposal, an RTC whose registers change between two reads, or whose seconds stand still |
| pit: the count never moves, so no timer | `pit.zig` | `PIT_FROZEN=1` |
| pit: it wrapped; no round settled | `pit.zig` | **no knob**: a proposal, a PIT that counts too fast or unevenly |
| pci: a BAR past the sixth; an I/O BAR; a 64-bit BAR in the last slot | `pci.zig` | **no knob**: a proposal, metal-vmm's PCI devices with such BARs |
| rng: a virtio-rng device that will not come up is left alone | `rng.zig` | **no knob**: a proposal, an entropy device that refuses negotiation |
| admin reset: the boot disk has no admin to reset; a step on the boot disk failed | `admin_reset.zig` | a boot disk with `data/admin-reset` and no admin, and `DISK_REFUSE` during the reset; `admin_reset.zig`'s own host tests meet both |
| io: a flush failed, and the response goes out anyway | `io.zig` | the same, for the volume. **No knob fails a flush of the boot disk**: it is virtio-blk and writes through (virtio 1.2 §5.2.5.1), so nothing is sent; a knob would need metal-vmm's `DISK_CACHE` to offer FLUSH and fail it (a proposal) |
