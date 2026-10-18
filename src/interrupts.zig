//! **INTERRUPTS, SO THE MACHINE CAN REST.** Without them the only way to wait
//! for a frame is to ask the network card over and over, and on a droplet that
//! costs more than the processor time: the host's own threads, which carry our
//! frames in and out, need a turn on the processor we never give back. A
//! guest that halts gives it back, and an interrupt is what wakes it.
//!
//! The machine runs with interrupts OFF, as it always has. A rest turns them
//! on only around its halt: for one instruction before it, to take what was
//! already raised (`sti; nop; cli`), then for the halt (`sti; hlt`) until the
//! `cli` after it, which a handler's `iretq` returns to with them on. So an
//! interrupt is only ever taken inside a rest, and no other code can be
//! interrupted halfway. An interrupt raised while they are off is held by the
//! local APIC and taken by the next rest, so a frame that arrives between
//! "nothing yet" and the halt ends the rest at once rather than being slept
//! through.
//!
//! What wakes it:
//!   - the network card, by MSI-X (virtio.zig routes its queues to `wake_vector`);
//!   - the local APIC's timer in TSC-deadline mode, at most `slice_ns` after
//!     the halt (`rest`), so the timers the TCP table and the streams keep are
//!     looked at at least that often; or, when the main loop finds the machine
//!     quiescent, at the deadline it chose (`restUntil`, sleep.zig), which
//!     the config's longest rest bounds.
//!
//! Every interrupt handler is the same three instructions: tell the local APIC
//! it was handled (end of interrupt), and return. The work is all done by the
//! loop that halted, when it wakes and looks again.
//!
//! `install` also gives the processor's exceptions somewhere to go: a fault
//! prints which one and where, rather than resetting the machine.
//!
//! **WHAT WAITS HERE, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md §2).
//! Interrupts carry no work, only wake-ups: every handler ends the interrupt
//! and returns, and the loop that halted finds the work by looking. So an
//! interrupt can delay work, never lose it.
//!
//! - **The machine itself, halted in `rest`.** Woken by the network card
//!   (MSI-X, `wake_vector`) or by the APIC timer. Bounded by: `slice_ns`
//!   (1 ms) — `rest` writes the timer's deadline before every halt — or, for
//!   the main loop's quiescent rest, the deadline `restUntil` is handed, at
//!   most `longest_rest_ms` away. No halt is ever without one. Before `arm`, and on a card that cannot
//!   interrupt (mmio), `rest` is one `pause` and nothing halts.
//! - **An interrupt raised while interrupts are off**, which is always,
//!   outside `rest`'s one instruction. Held by the local APIC and taken by
//!   the next halt, which then returns at once. Bounded by: the next `rest`
//!   — but what it signals (a frame) is found by the next `pump` whether or
//!   not the interrupt is ever taken.
//!
//! What a halt must never do is begin with work already owed. The callers
//! rest only after a turn of the network that found nothing: the main loop
//! when nothing arrived and nothing was served, and every wait in
//! `stream.Stream` after a `pump` that returned null.
//!
//! Intel SDM vol. 3A: §6.10-6.14 (the IDT), §11.4-11.5 (the local APIC and its
//! timer), §10.11 (MSI message format).

const apic_rule = @import("apic_rule.zig");
const rest_count = @import("rest_count.zig");
const std = @import("std");
const port = @import("port.zig");
const serial = @import("serial.zig");
const tsc = @import("tsc.zig");
const boot = @import("boot.zig");

/// The vectors this machine uses. Anything at or above 32 is free for us; the
/// first 32 are the processor's own exceptions.
pub const wake_vector: u8 = 0x40;
pub const timer_vector: u8 = 0x41;
const spurious_vector: u8 = 0xFF;

/// The local APIC's registers, at the address every PC puts them (and the
/// handler below writes to without asking).
const lapic_base: usize = apic_rule.lapic_base;
const lapic_id = 0x020;
const lapic_tpr = 0x080;
const lapic_svr = 0x0F0;
const lapic_lvt_timer = 0x320;
const lapic_lvt_lint0 = 0x350;
const lvt_masked: u32 = 1 << 16;
const msr_apic_base: u32 = 0x1B;
const msr_tsc_deadline: u32 = 0x6E0;

/// How long a rest may last before the timer looks again.
pub const slice_ns: u64 = 1_000_000;

const Gate = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8 = 0,
    /// Present, ring 0, 64-bit interrupt gate.
    kind: u8 = 0x8E,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

var idt: [256]Gate align(16) = undefined;

const IdtPointer = packed struct { limit: u16, base: u64 };
var idt_pointer: IdtPointer = undefined;

/// The vectors whose exception pushes an error code before the return address.
const hasErrorCode = apic_rule.hasErrorCode;

// The handlers. `boot.zig` loaded the 64-bit code segment as selector 0x08.
comptime {
    var text: []const u8 =
        \\.text
        \\.global gm_irq
        \\gm_irq:
        \\  pushq %rax
        \\  movabsq $0xFEE000B0, %rax
        \\  movl $0, (%rax)
        \\  popq %rax
        \\  iretq
        \\.global gm_irq_timer
        \\gm_irq_timer:
        \\  incq gm_timer_irqs(%rip)
        \\  jmp gm_irq
        \\.global gm_irq_wake
        \\gm_irq_wake:
        \\  incq gm_wake_irqs(%rip)
        \\  jmp gm_irq
        \\.global gm_spurious
        \\gm_spurious:
        \\  iretq
        \\.global gm_nmi
        \\gm_nmi:
        \\  pushq %rax
        \\  pushq %rcx
        \\  pushq %rdx
        \\  pushq %rsi
        \\  pushq %rdi
        \\  pushq %r8
        \\  pushq %r9
        \\  pushq %r10
        \\  pushq %r11
        \\  call gm_nmi_log
        \\  popq %r11
        \\  popq %r10
        \\  popq %r9
        \\  popq %r8
        \\  popq %rdi
        \\  popq %rsi
        \\  popq %rdx
        \\  popq %rcx
        \\  popq %rax
        \\  iretq
        \\gm_exception_common:
        \\  movq %rsp, %rdi
        \\  andq $-16, %rsp
        \\  call gm_exception
        \\
    ;
    // One stub per exception: it pushes its vector, and a zero where the
    // processor pushes no error code, so the frame is the same shape for all.
    for (0..32) |v| {
        text = text ++ std.fmt.comptimePrint(
            \\.global gm_exception_{d}
            \\gm_exception_{d}:
            \\{s}  pushq ${d}
            \\  jmp gm_exception_common
            \\
        , .{ v, v, if (hasErrorCode(v)) "" else "  pushq $0\n", v });
    }
    asm (text);
}

extern fn gm_irq() callconv(.naked) void;
extern fn gm_irq_timer() callconv(.naked) void;
extern fn gm_irq_wake() callconv(.naked) void;

/// **EACH WAKER COUNTS ITSELF** (rest_count.zig): the timer's handler and the
/// network card's each add one before the shared end of interrupt, so a rest
/// says which ended it from the counts, not from the clock.
export var gm_timer_irqs: u64 = 0;
export var gm_wake_irqs: u64 = 0;
extern fn gm_spurious() callconv(.naked) void;
extern fn gm_nmi() callconv(.naked) void;

/// **AN NMI IS LOGGED, AND THE MACHINE CARRIES ON.** On a droplet the
/// hypervisor can inject one — a watchdog, a console's "inject NMI" — and none
/// of them says this machine is broken, so ending the server for one would be
/// the bug. It arrives on its own stack (IST 2, below) wherever the machine
/// was, even inside `serial.put` or `screen.put`, so the handler writes to the
/// serial port alone, never the screen, and touches nothing but its count; a
/// line of it may land in the middle of another. The stub saves every
/// register the C convention lets this clobber, and the kernel is soft-float,
/// so there are no vector registers to save. The processor blocks a second
/// NMI until this one's `iretq`.
pub var nmis: u64 = 0;

export fn gm_nmi_log() callconv(.c) void {
    nmis +%= 1;
    serial.putPort("\ncpu: NMI, logged and ignored; the machine carries on\n");
}

fn exceptionStub(comptime v: usize) usize {
    const name = std.fmt.comptimePrint("gm_exception_{d}", .{v});
    return @intFromPtr(@extern(*const fn () callconv(.naked) void, .{ .name = name }));
}

fn gate(handler: usize) Gate {
    return .{
        .offset_low = @truncate(handler),
        .selector = 0x08,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

/// **TWO VECTORS RUN ON STACKS OF THEIR OWN** (the TSS's interrupt stack
/// table, SDM §7.14.5), because the stack they interrupt may be the problem:
///
///   - **the double fault** (IST 1): a fault that could not be delivered,
///     very often because `rsp` itself is bad. On the faulting stack it would
///     fault again — a triple fault, a reset, and nothing in the log, which
///     is what installing the IDT was for.
///   - **the NMI** (IST 2): it arrives at any instruction, including one
///     where `rsp` is momentarily somewhere no frame should go.
///
/// Each has 16 KB, far more than printing a line takes. They are separate so
/// that an NMI during a double fault's report cannot overwrite it.
const ist_double_fault: u3 = 1;
const ist_nmi: u3 = 2;
const ist_stack_size = 16 * 1024;
var ist_stacks: [2][ist_stack_size]u8 align(16) = undefined;

/// The 64-bit TSS (SDM §8.7): 104 bytes, of which this machine uses the IST
/// pointers and the I/O map base (set past the end: no I/O bitmap). Written
/// field by field, because it is not aligned the way an extern struct would
/// want, and `.bss` is not zero here.
var tss: [104]u8 align(16) = undefined;
var tss_loaded = false;

fn loadTss() void {
    if (tss_loaded) return; // `ltr` marks the descriptor busy; twice is a #GP
    @memset(&tss, 0);
    for ([_]u3{ ist_double_fault, ist_nmi }, 0..) |ist, k| {
        const top: u64 = @intFromPtr(&ist_stacks[k]) + ist_stack_size;
        std.mem.writeInt(u64, tss[36 + (@as(usize, ist) - 1) * 8 ..][0..8], top, .little);
    }
    std.mem.writeInt(u16, tss[102..104], tss.len, .little);

    // A 64-bit available TSS descriptor: type 9, present, in two slots.
    const base: u64 = @intFromPtr(&tss);
    const limit: u64 = tss.len - 1;
    boot.gdt[3] = (limit & 0xFFFF) | ((base & 0xFF_FFFF) << 16) | (@as(u64, 0x89) << 40) |
        (((limit >> 16) & 0xF) << 48) | (((base >> 24) & 0xFF) << 56);
    boot.gdt[4] = base >> 32;
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (boot.tss_selector),
        : .{ .memory = true });
    tss_loaded = true;
}

/// The frame an exception stub leaves: its vector, the error code (or zero),
/// then what the processor pushed.
export fn gm_exception(frame: [*]const u64) callconv(.c) noreturn {
    const vector = frame[0];
    serial.put("\ncpu exception ");
    serial.putDec(vector);
    serial.put(", error code ");
    serial.putHex(frame[1], 8);
    serial.put(", at rip ");
    serial.putHex(frame[2], 16);
    if (vector == 14) {
        serial.put(", address ");
        serial.putHex(asm volatile ("movq %%cr2, %[out]"
            : [out] "=r" (-> u64),
        ), 16);
    }
    serial.put("\n");
    serial.fail("the processor stopped on an exception");
}

/// The table of where each vector goes, loaded. Interrupts stay off.
pub fn install() void {
    loadTss();
    inline for (0..32) |v| idt[v] = gate(exceptionStub(v));
    for (32..256) |v| idt[v] = gate(@intFromPtr(&gm_irq));
    idt[spurious_vector] = gate(@intFromPtr(&gm_spurious));
    idt[timer_vector] = gate(@intFromPtr(&gm_irq_timer));
    idt[wake_vector] = gate(@intFromPtr(&gm_irq_wake));
    idt[2] = gate(@intFromPtr(&gm_nmi));
    idt[2].ist = ist_nmi;
    idt[8].ist = ist_double_fault;
    idt_pointer = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idt_pointer),
        : .{ .memory = true });
}

fn cpuid(leaf: u32) struct { ecx: u32, edx: u32 } {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    return .{ .ecx = c, .edx = d };
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// **THE DEADLINE CARRIES A MARK FOR METAL-VMM**, as `tsc.read` does, and for
/// the same reason: the write has to reach that machine's own APIC. KVM's
/// fast path for IA32_TSC_DEADLINE (on a host with the VMX preemption timer)
/// takes the write before any MSR filter sees it, so metal-vmm rewrites this
/// `wrmsr`, after `mov $"mvmd", %esi` (`BE 6D 76 6D 64`), into a port write it
/// answers. Elsewhere it is an ordinary `wrmsr`, and the `mov` costs a
/// register.
fn wrmsrDeadline(value: u64) void {
    asm volatile ("movl $0x646d766d, %%esi\n\twrmsr"
        :
        : [msr] "{ecx}" (msr_tsc_deadline),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{ .esi = true });
}

fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

fn lapicWrite(reg: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic_base + reg)).* = value;
}

fn lapicRead(reg: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(lapic_base + reg)).*;
}

/// Why the local APIC could not be used, for the log (apic_rule.zig: the
/// decisions, pure and tested, 198.2).
pub const Refusal = apic_rule.Refusal;

/// The local APIC, ready to take interrupts and to time a rest: its ID, which
/// an MSI-X message names as its destination.
pub fn startApic() union(enum) { id: u8, refused: Refusal } {
    const features = cpuid(1);
    // Every refusal is apic_rule's. In x2APIC mode the registers below are
    // not in memory at all (SDM §11.12): every write here, the handler's EOI
    // among them, would go nowhere, and the first rest would never wake.
    // The MSR is read only once CPUID says there is an APIC.
    if (features.edx & (1 << 9) == 0) return .{ .refused = .no_apic };
    const base = rdmsr(msr_apic_base);
    if (apic_rule.refusal(features.edx, features.ecx, base)) |r| return .{ .refused = r };
    wrmsr(msr_apic_base, base | (1 << 11)); // globally enabled

    // **THE BIOS'S OLD INTERRUPT CONTROLLER IS CUT OFF.** It still runs the
    // 18.2 Hz BIOS tick on vector 8, which in long mode is the double-fault
    // exception. Masking its lines is not enough: a request that drops before
    // it is acknowledged still arrives, as a spurious IRQ 7 (vector 15). So
    // it is moved to vectors 0x20-0x2F, where nothing it sends is an
    // exception, then masked, and the APIC's LINT0, its one way in, is masked
    // too. LINT1, the NMI, is left alone.
    pic8259Remap(0x20, 0x28);
    port.outb(0x21, 0xFF);
    port.outb(0xA1, 0xFF);
    lapicWrite(lapic_lvt_lint0, lvt_masked);

    lapicWrite(lapic_svr, 0x100 | @as(u32, spurious_vector));
    lapicWrite(lapic_tpr, 0);
    lapicWrite(lapic_lvt_timer, @as(u32, timer_vector) | (2 << 17)); // TSC-deadline mode
    // The mode switch above is a store, the first deadline a WRMSR, and the
    // two are not ordered (SDM §11.5.4.1): a deadline that lands first is
    // ignored, and the first rest would have no timer.
    asm volatile ("mfence" ::: .{ .memory = true });
    return .{ .id = @truncate(lapicRead(lapic_id) >> 24) };
}

/// The initialization sequence (ICW1-ICW4) for both 8259s: the master's IRQs
/// on `master..master+7`, the slave's on `slave..slave+7`, the slave on the
/// master's IRQ 2, 8086 mode.
fn pic8259Remap(master: u8, slave: u8) void {
    port.outb(0x20, 0x11);
    port.outb(0xA0, 0x11);
    port.outb(0x21, master);
    port.outb(0xA1, slave);
    port.outb(0x21, 1 << 2);
    port.outb(0xA1, 2);
    port.outb(0x21, 0x01);
    port.outb(0xA1, 0x01);
}

/// The address and data an MSI-X entry carries to interrupt this processor on
/// `vector`: fixed delivery, edge-triggered, physical destination `apic_id`.
pub fn msiAddress(apic_id: u8) u32 {
    return @as(u32, lapic_base) | (@as(u32, apic_id) << 12);
}

var slice_ticks: u64 = 0;

/// From now on `rest` halts. Only once something will wake it: the APIC
/// started and the network card routed to `wake_vector`.
pub fn arm(tsc_hz: u64) void {
    slice_ticks = apic_rule.sliceTicks(tsc_hz, slice_ns);
}

pub fn armed() bool {
    return slice_ticks != 0;
}

/// **WAIT FOR SOMETHING TO HAPPEN**: a frame, or the timer. Before `arm`, one
/// `pause`, which is what every loop here did before there was anything else.
pub fn rest() void {
    if (slice_ticks == 0) {
        asm volatile ("pause");
        return;
    }
    _ = halt(tsc.read() +% slice_ticks, .leave);
}

/// What ended a rest (rest_count.zig).
pub const Ended = rest_count.Ended;

/// **REST UNTIL A DEADLINE THE CALLER CHOSE** (sleep.zig): `deadline` is a
/// TSC value (io.zig's `tscAt`), never 0. Only the main loop's quiescent
/// rest comes here; every wait inside a serve rests a slice (`rest`).
/// Before `arm`, one `pause`, as `rest`.
pub fn restUntil(deadline: u64) Ended {
    if (slice_ticks == 0) {
        asm volatile ("pause");
        return .deadline;
    }
    return halt(deadline, .disarm);
}

/// What a halt the timer did not end does with its deadline. A slice's is
/// at most 1 ms off, and the next rest writes its own over it: left, which
/// saves a busy server an MSR write a frame. A sleep's can be 10 s off, and
/// firing during later work it would end the next rest at once: disarmed
/// (0, SDM §11.5.4.1).
const EarlyDeadline = enum { leave, disarm };

/// The halt itself, until `deadline` or a device; what ended it, from the
/// handlers' counts.
///
/// **WHAT IS ALREADY RAISED IS TAKEN FIRST** (a cold review of chunk 3):
/// interrupts are off between rests, and what is raised meanwhile waits in
/// the APIC: a slice's deadline left armed that fired during the work after
/// it, or a frame since the last turn of the network. Halting on it would
/// end the halt at once and count the stale timer as this rest's deadline.
/// So the interrupts are opened for one instruction first (`sti; nop; cli`,
/// the `nop` in `sti`'s shadow): a timer taken there is no one's; a frame
/// taken there ends this rest without a halt, as the card's, since the loop
/// rested on a turn that had not seen it. After the halt the handler's
/// `iretq` turns interrupts back on until the `cli`, so whatever was raised
/// with what ended the halt is taken there and counted too.
fn halt(deadline: u64, early_deadline: EarlyDeadline) Ended {
    const wake_seen = @atomicLoad(u64, &gm_wake_irqs, .monotonic);
    asm volatile (
        \\sti
        \\nop
        \\cli
        ::: .{ .memory = true });
    const wake_before = @atomicLoad(u64, &gm_wake_irqs, .monotonic);
    if (wake_before != wake_seen) {
        rests.note(.device);
        return .device;
    }
    const timer_before = @atomicLoad(u64, &gm_timer_irqs, .monotonic);
    wrmsrDeadline(deadline);
    asm volatile (
        \\sti
        \\hlt
        \\cli
        ::: .{ .memory = true });
    const timer_after = @atomicLoad(u64, &gm_timer_irqs, .monotonic);
    const how = rest_count.ended(timer_before, timer_after, wake_before, @atomicLoad(u64, &gm_wake_irqs, .monotonic));
    rests.note(how);
    // A deadline that fires after this read waits in the APIC, and the next
    // halt takes it first (above).
    if (timer_after == timer_before and early_deadline == .disarm) wrmsrDeadline(0);
    return how;
}

/// Every rest, and what ended each (193, gap 11).
pub var rests: rest_count.Rests = .{};
