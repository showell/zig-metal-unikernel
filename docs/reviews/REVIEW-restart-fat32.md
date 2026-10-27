# Review: the restart and FAT32, as an adversary

The restart (`src/restart.zig`, `src/restarting.zig`, `src/kept_log.zig`)
and FAT32 in `src/disk_fat*.zig`. R1, F1 and F2 are fixed in the code (it
cites them); this is what is left.

### R2. NMIs stay masked on a real chipset (low)

**Where:** `rtc.zig`'s `readReg` and `restarting.cmosRead`/`cmosWrite`
write port 0x70 with bit 7 set, and nothing ever writes it clear.

**The problem:** on a real chipset, bit 7 of port 0x70 masks NMIs until it
is written clear, so after the first RTC read at boot NMIs are masked for
the whole uptime. QEMU's chipsets do not model the mask, which is why NMIs
still arrive and are counted on `/admin/host`.

**How likely:** no effect on DigitalOcean's KVM as far as is known. It
matters only on hardware.

**Fix shape:** after the last access, write the index once with bit 7
clear, in both places.
