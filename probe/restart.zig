//! **WHAT A RESTART KEEPS, MEASURED** (RESTART.md, QUEUE.md item 7).
//!
//! The machine restarts itself three ways in turn, and after each, on the
//! next boot, says whether it came back and what survived:
//!
//!   1. the reset control register, port 0xCF9 (PIIX3, as on a droplet);
//!   2. the keyboard controller's reset line (0xFE to port 0x64);
//!   3. a triple fault (an empty interrupt table, then an exception).
//!
//! A method that does not restart this machine is reported, and the next is
//! tried at once. It ends (PASS) once all three have been tried: which ones
//! worked is the result, read from the log, and differs by machine.
//!
//! What it looks for after each:
//!
//!   - **RAM past the kernel**: a record at `carry_address`, outside every
//!     segment the loader writes or zeroes, and outside the BIOS's memory;
//!   - **CMOS**: the byte at `cmos_stage`, which is also how this kernel knows
//!     which restart it is on. If CMOS did not survive a restart, the kernel
//!     starts over at the first method, and the run never ends: the judge's
//!     timeout says so.
//!
//! The record is checked, not trusted: a magic number, the boot count and a
//! checksum over both, so RAM full of 0xA5 (droplet.sh's DIRTY=1) reads as no
//! record rather than as one.
//!
//! **RUN IT WITHOUT `-no-reboot`.** With it, QEMU ends at the first restart,
//! which is how a judge sees that one happened, but this probe wants to see
//! the next boot.

const metal = @import("metal");
const serial = metal.serial;
const port = metal.port;

comptime {
    _ = metal.boot;
}

/// 64 MiB: past this kernel (`_kernel_end` is printed, to show it), and far
/// below the top of any machine it runs on, where SeaBIOS keeps its tables.
/// Identity-mapped like all of the first 4 GiB.
const carry_address: usize = 64 << 20;

/// A CMOS byte nothing else here uses: past the BIOS's own (memory sizes,
/// boot order, the century at 0x32), in the part QEMU leaves alone.
const cmos_stage: u8 = 0x7D;
/// Stages are written as `stage_base + n`, so a CMOS that powers up holding
/// zero, or anything below this, is "not started".
const stage_base: u8 = 0xA0;

const Carry = extern struct {
    magic: u64,
    boots: u64,
    check: u64,

    const expected_magic: u64 = 0x5952524143_4D47; // "GMCARRY", little end first

    fn sum(c: *const volatile Carry) u64 {
        return (c.magic ^ 0x9E37_79B9_7F4A_7C15) +% c.boots *% 0x100_0000_01B3;
    }

    fn valid(c: *const volatile Carry) bool {
        return c.magic == expected_magic and c.check == c.sum();
    }
};

fn carry() *volatile Carry {
    return @ptrFromInt(carry_address);
}

fn cmosRead(index: u8) u8 {
    port.outb(0x70, 0x80 | index);
    return port.inb(0x71);
}

fn cmosWrite(index: u8, value: u8) void {
    port.outb(0x70, 0x80 | index);
    port.outb(0x71, value);
}

const reset = metal.reset;
const methods = reset.methods;
const pause = reset.pause;

extern var _kernel_end: u8;

/// In `.bss`: whether the loader zeroed it on this boot. Set nonzero below, so
/// a restart that kept `.bss` shows it.
var bss_marker: u64 = 0;

pub fn kmain() noreturn {
    serial.init();
    // The pause after each method is measured once the clock is running
    // (reset.pause); without it, a fixed loop, as before.
    if (metal.pit.calibrate()) |hz| metal.io.startClock(hz) else |_| serial.put("  the clock did not start: each pause is a fixed loop\n");
    const raw = cmosRead(cmos_stage);
    const stage: usize = if (raw >= stage_base and raw < stage_base + methods.len + 1) raw - stage_base else 0;
    const c = carry();
    const kept = c.valid();
    const boots: u64 = if (kept) c.boots + 1 else 1;

    serial.put("zig-metal-unikernel restart probe: boot ");
    serial.putDec(boots);
    serial.put(", kernel ends at 0x");
    serial.putHex(@intFromPtr(&_kernel_end), 8);
    serial.put(", carry at 0x");
    serial.putHex(carry_address, 8);
    serial.put("\n  .bss on arrival: ");
    serial.put(if (@as(*volatile u64, &bss_marker).* == 0) "zero\n" else "NOT zero (the last boot's, or garbage)\n");
    @as(*volatile u64, &bss_marker).* = 0xB55_B55;

    if (stage == 0) {
        serial.put("  first boot: CMOS stage byte ");
        serial.putHex(raw, 2);
        serial.put(", carry record ");
        serial.put(if (kept) "present (left by an earlier run)\n" else "absent\n");
    } else {
        serial.put("  restarted by ");
        serial.put(methods[stage - 1].name);
        serial.put(": CMOS kept (stage ");
        serial.putDec(stage);
        serial.put("); RAM past the kernel ");
        serial.put(if (kept) "kept\n" else "NOT kept\n");
    }

    c.magic = Carry.expected_magic;
    c.boots = boots;
    c.check = c.sum();

    // Each method in turn, from the one after the last that restarted. One
    // that does not restart is said so, and the next is tried at once.
    var next = stage;
    while (next < methods.len) : (next += 1) {
        cmosWrite(cmos_stage, stage_base + @as(u8, @intCast(next + 1)));
        serial.put("  restarting by ");
        serial.put(methods[next].name);
        serial.put("\n");
        methods[next].run();
        pause();
        serial.put("  ");
        serial.put(methods[next].name);
        serial.put(" did NOT restart this machine\n");
    }
    cmosWrite(cmos_stage, 0);
    c.magic = 0;
    serial.put("  every method has been tried\n");
    serial.pass();
}

pub const panic = metal.serial.panic;
