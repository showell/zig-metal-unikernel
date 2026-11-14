//! A kernel that gets a DHCP lease and says so.
//!
//! This is the network half of the same idea as the block probe: put the
//! driver on virtual hardware and find out whether it works before anything is
//! built on it. QEMU's user-mode networking runs a DHCP server at 10.0.2.2
//! with nothing configured, so a lease is a checkable result that needs no
//! second machine.

const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;

comptime {
    _ = metal.boot;
}

/// The device's rings and buffers, and this kernel's scratch. All in the
/// kernel's image, which the linker places at a fixed physical address that
/// paging maps to itself, so a pointer is an address the device can use.
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var frame: [net.buffer_size]u8 align(16) = undefined;
var reply: [1024]u8 align(16) = undefined;

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel net probe\n");

    rng.attach(&rng_mem);
    const base = virtio.find(virtio.device_id_net) orelse
        serial.fail("no virtio-net device on the PCI bus or in any mmio slot");
    serial.put("  device at 0x");
    serial.putHex(base.address(), 8);
    serial.put(" (");
    serial.put(base.describe());
    serial.put(")\n");

    var nic = net.Net.init(base, &nic_mem) catch |e| switch (e) {
        error.DeviceRefused => serial.fail("the device refused the driver"),
        error.QueueTooSmall => serial.fail("the device's queues are smaller than this driver's"),
        else => serial.fail("the device would not come up"),
    };
    serial.put("  mac: ");
    serial.putMac(nic.mac);
    serial.put("\n");

    // DHCP waits a measured time for each answer before asking again.
    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    metal.io.startClock(hz);

    const lease = dhcp.acquire(&nic, &frame, &reply) catch |e| switch (e) {
        error.NoOffer => serial.fail("no DHCP offer came back"),
        error.NoAck => serial.fail("the offer was made and then not acknowledged"),
        error.Refused => serial.fail("the server refused the request"),
    };

    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  mask   : ");
    serial.putIp(lease.mask);
    serial.put("\n  router : ");
    serial.putIp(lease.router);
    serial.put("\n  dns    : ");
    serial.putIp(lease.dns);
    serial.put("\n  server : ");
    serial.putIp(lease.server);
    serial.put("\n");

    if (lease.address[0] == 0) serial.fail("the lease has no address in it");
    serial.pass();
}

pub const panic = metal.serial.panic;
