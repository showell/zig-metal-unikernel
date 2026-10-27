# Review: src/interrupts.zig, as an adversary

`src/interrupts.zig`, the MSI-X routing in `virtio.routeToProcessor`, and the
callers that rest. Every finding but one is fixed in the code; this is the one
left.

### 9. The APIC page's cache type is left to the firmware

**Where:** `boot.zig` maps the low 4 GB with 2 MB pages, present and
writable (`pde_present_write_2mb`, `0x83`), with no PCD/PWT. The APIC page
and the MSI-X table are both in that map.

**The problem:** the effective memory type is uncachable only because the
firmware's MTRRs mark the PCI hole as UC. SeaBIOS does. A firmware that
does not would leave register writes cacheable: on real hardware, an EOI
that is not seen, or MSI-X table writes that never reach the device.

**How likely:** none under SeaBIOS or KVM, where APIC accesses trap
regardless of type. Bare metal with other firmware is the risk.

**Fix shape:** map `0xC000_0000` and above with PCD set, so the device
windows are uncachable whatever the MTRRs say.
