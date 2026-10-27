# Instructions for Claude

The README is the orientation. Work happens on the dev box, with Steve.

If you are a Claude Code **cloud** session ("CC"): you work here on the
**simulators and properties only**, plus **the Store** (its interface, model, FAT and strict Linux
implementations, and `store_sim`, none of them in the image). Your charter,
the branch map and the one shared queue live in metal-vmm, not here: read
metal-vmm's `CLOUD_WORK.md` ("zig-metal-unikernel: the simulators") and its
`QUEUE.md` on `master` (github.com/showell/metal-vmm). Branch from
`master`, push only `claude/*` branches, and never push to `master` or a
`vN` tag: the box merges. What serves lynrummy.com is a tag, never a
branch (README, "Where it stands"). Releases and operations are the box's:
[`DEPLOY.md`](DEPLOY.md).

**THE SIMULATORS ARE THERE TO KEEP THE LAYERS HONEST.** A simulator can only
drive code that is pure logic: no `io.zig`, no driver, no device, no clock but
the one it is handed. That is the point of them, not a limitation: every
simulator here is a reason for the code it drives to stay a layer that needs
nothing below it. So when a module you want to simulate reaches into I/O,
do not mock the I/O; propose the seam (the pure decision pulled out, the I/O
left behind) under "Proposed" in metal-vmm's QUEUE.md, and the box decides.
The kernel, the boot path, the drivers and deploys are the box's.
