# Review: the boot that printed its first line and stopped

One boot printed its first line and then nothing for a minute, 1 of 27,
not reproduced. The likeliest cause, a serial port given up on for good and
silently, is fixed: `src/serial_gate.zig` tries a full port again and, when
it drains, says how many bytes were dropped. The screen and the ring always
had every byte. A boot that stops on the screen too was not this. What is
left:

### 2. A loader's memory map is trusted for its length (low)

**Where:** `pvh.read` returns `memmap_entries` entries from the start
info, and `largestFree` and `totalRam` loop over them.

**The problem:** a garbage count, from a loader bug, would make those
loops long, though not endless (a u32 count). Both of this machine's
loaders write the map themselves, and nothing else hands it one.

**Fix shape:** refuse a count over a sane bound (128), with a message, in
`pvh.read`.
