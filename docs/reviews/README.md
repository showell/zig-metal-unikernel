# Reviews

Adversarial reviews, kept for the findings still open: each finding names
the failure it causes and how likely it is, with a fix shape; nothing is
fixed in a review itself (metal-vmm's `CLOUD_WORK.md`, "Limits"). Code and
scripts cite these by filename and finding number ("REVIEW-restart-fat32.md
R1"); a finding fixed is dropped from its review.

- [REVIEW-interrupts.md](REVIEW-interrupts.md) — `src/interrupts.zig`: the APIC page's cache type.
- [REVIEW-two-disks.md](REVIEW-two-disks.md) — the boot disk found by position.
- [REVIEW-store.md](REVIEW-store.md) — the Store (zig-webbox `store.zig`): a miss's listing, a create race, `..` mid-path.
- [REVIEW-restart-fat32.md](REVIEW-restart-fat32.md) — NMIs masked on a real chipset.
- [REVIEW-first-line.md](REVIEW-first-line.md) — the boot that printed its first line and stopped; a memory map's length.
- [REVIEW-signed-uid-and-limits.md](REVIEW-signed-uid-and-limits.md) — the signed `gopher_uid` and the game store's limits.
