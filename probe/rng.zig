//! Entropy, and the checks that it is entropy.
//!
//! A random number generator is the one component that looks identical whether
//! it works or not, so this asks it the questions that can actually fail: are
//! both sources present, do two draws differ, is a large draw free of long runs
//! and roughly balanced between zeros and ones.
//!
//! None of that proves randomness -- nothing short of a statistical suite does,
//! and one would not fit here. What these catch is the failure that matters on
//! a new machine: a source that is quietly returning a constant.

const metal = @import("metal");
const serial = metal.serial;
const rng = metal.rng;

comptime {
    _ = metal.boot;
}

var rng_mem: rng.Memory align(4096) = .{};
var a: [64]u8 = undefined;
var b: [64]u8 = undefined;
var big: [4096]u8 = undefined;

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel rng probe\n");

    rng.attach(&rng_mem);
    const s = rng.sources();
    serial.put("  virtio-rng: ");
    serial.put(if (s.host) "yes" else "no");
    serial.put("   RDRAND: ");
    serial.put(if (s.cpu) "yes" else "no");
    serial.put("\n");
    if (!s.host and !s.cpu) serial.fail("neither source is present");

    rng.fill(&a);
    rng.fill(&b);
    serial.put("  first draw: ");
    for (a[0..16]) |x| serial.putHex(x, 2);
    serial.put("\n  second    : ");
    for (b[0..16]) |x| serial.putHex(x, 2);
    serial.put("\n");

    var same = true;
    for (a, b) |x, y| {
        if (x != y) same = false;
    }
    if (same) serial.fail("two draws came back identical, which is a stuck source");

    var all_zero = true;
    for (a) |x| {
        if (x != 0) all_zero = false;
    }
    if (all_zero) serial.fail("a draw was all zeros");

    // Over 4 KB: the count of set bits should be near half, and no byte value
    // should dominate. Loose bounds -- these catch a constant, not a bias.
    rng.fill(&big);
    var ones: usize = 0;
    var counts: [256]u16 = @splat(0);
    for (big) |x| {
        ones += @popCount(x);
        counts[x] += 1;
    }
    var most: u16 = 0;
    for (counts) |c| most = @max(most, c);
    const bits = big.len * 8;
    serial.put("  over 4 KB: ");
    serial.putDec(ones);
    serial.put(" of ");
    serial.putDec(bits);
    serial.put(" bits set, commonest byte appears ");
    serial.putDec(most);
    serial.put(" times\n");

    if (ones < bits * 45 / 100 or ones > bits * 55 / 100) {
        serial.fail("the bit balance is nowhere near half, which no working source gives");
    }
    // 4096 bytes over 256 values averages 16; a constant source would give 4096.
    if (most > 64) serial.fail("one byte value dominates, which means a source is stuck");

    serial.pass();
}

pub const panic = metal.serial.panic;
