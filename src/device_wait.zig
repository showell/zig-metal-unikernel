//! **A WAIT ON A DEVICE ENDS** (metal-vmm QUEUE 193.2). A driver that offers
//! a request spins until the device answers it; a disk that never answers
//! hung the machine with no record (191.2's gap 2). This is the decision
//! that ends the wait, pure, as a function of the clock the driver reads and
//! the device's status byte, so it is tested with no device:
//!
//!   - **wait**: neither has happened yet;
//!   - **needs_reset**: the device set DEVICE_NEEDS_RESET (virtio 1.x §2.1):
//!     it will not answer until it is reset;
//!   - **timed_out**: the budget passed with no answer.
//!
//! The driver keeps the I/O: reading the clock and the status, and what it
//! does with a request that never ended (`virtio_blk.Block` refuses every later
//! request: the device still holds the abandoned one's buffers).

const std = @import("std");

/// Virtio's device status bit: the device hit an error it cannot recover
/// from without a reset.
pub const status_needs_reset: u32 = 64;

pub const Verdict = enum { wait, needs_reset, timed_out };

/// `began` and `now` are counter readings (the TSC's), `budget` the most
/// the wait may take in the same units. The counter may wrap.
pub fn verdict(began: u64, now: u64, budget: u64, device_status: u32) Verdict {
    if (device_status & status_needs_reset != 0) return .needs_reset;
    if (now -% began >= budget) return .timed_out;
    return .wait;
}

/// How many spins between two looks at the clock and the status: the
/// status is a read the hypervisor answers (a trap), so not every spin.
pub const look_every: u32 = 4096;

const testing = std.testing;

test "device wait: it waits while time remains and the device is well" {
    try testing.expectEqual(Verdict.wait, verdict(1000, 1000, 500, 0));
    try testing.expectEqual(Verdict.wait, verdict(1000, 1499, 500, 0x0f));
}

test "device wait: the budget's end is a timeout, exactly at it, and across the counter's wrap" {
    try testing.expectEqual(Verdict.timed_out, verdict(1000, 1500, 500, 0));
    try testing.expectEqual(Verdict.timed_out, verdict(1000, 99_999, 500, 0));
    const near_end = std.math.maxInt(u64) - 100;
    try testing.expectEqual(Verdict.wait, verdict(near_end, 50, 500, 0)); // 151 ticks on
    try testing.expectEqual(Verdict.timed_out, verdict(near_end, 450, 500, 0)); // 551 ticks on
}

test "device wait: a device that asks for a reset ends the wait at once, before its budget" {
    try testing.expectEqual(Verdict.needs_reset, verdict(1000, 1001, 500, status_needs_reset | 0x0f));
    // Both at once: the reset is the reason.
    try testing.expectEqual(Verdict.needs_reset, verdict(1000, 9999, 500, status_needs_reset));
}
