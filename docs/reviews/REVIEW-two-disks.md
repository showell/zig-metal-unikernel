# Review: two disks, read as an adversary

The site on the boot disk, chat's data on the volume (`src/io.zig`'s
routing, `probe/volumes.zig`'s boot path). Every finding but one is fixed or
recorded in the code; this is the one left.

### 6. The boot disk is the first virtio-blk device, by position

**Where:** `bootDisk` (`probe/volumes.zig`) → `virtio.find(device_id_block)`.

**The problem:** on a droplet the boot disk is the only virtio-blk device, and
volumes arrive on SCSI. Nothing checks that the disk found is the one the
machine booted from.

**Failure:** on a machine with a second virtio-blk disk, which some QEMU
setups and other hosts have, the site could be read from the wrong one.

**How likely:** not on a droplet as DigitalOcean builds them today.

**Fix shape:** confirm the boot disk by what it holds: the loader can pass
the disk's GPT GUID, or the kernel can look for its own image in its
partition (`src/kernel_partition.zig`). Or record the assumption beside
`bootDisk`.
