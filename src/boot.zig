//! Getting from where QEMU drops us to where zig can run.
//!
//! **PVH, NOT MULTIBOOT.** QEMU's multiboot loader refuses a 64-bit ELF
//! outright ("Cannot load x86-64 image, give a 32bit one"), and these kernels
//! are 64-bit. PVH is the other door into the same machine and takes an ELF of
//! either width: an ELF note names a 32-bit entry point, and QEMU enters there
//! in 32-bit protected mode with paging off. It is also what Firecracker and
//! every modern microVM boot, so it is the more useful door anyway.
//!
//! The root file supplies `kmain`. Import this from it for the side effect:
//!
//!     comptime { _ = @import("boot"); }

const std = @import("std");
const root = @import("root");
const stack = @import("stack.zig");
const pvh = @import("pvh.zig");

comptime {
    // **ONE PANIC HANDLER** (serial.zig): the root names it, or the build stops.
    if (!@hasDecl(root, "panic") or root.panic != @import("serial.zig").panic)
        @compileError("a kernel's root says `pub const panic = metal.serial.panic;`");
}

comptime {
    // The stack region and the telemetry that reads it are declared there; the
    // stub below is what paints it and what points %rsp at it.
    _ = stack;
}

// The note is assembly because it must be a real SHT_NOTE section for QEMU to
// find it in a PT_NOTE segment, and `linksection` makes PROGBITS.
comptime {
    asm (
        \\.section .note.Xen, "a", @note
        \\.align 4
        \\.long 4                // namesz: "Xen" and its NUL
        \\.long 4                // descsz: a 32-bit entry address
        \\.long 18               // XEN_ELFNOTE_PHYS32_ENTRY
        \\.asciz "Xen"
        \\.align 4
        \\.long _start
        \\.align 4
    );
}

/// Identity paging for the low 4 GB in 2 MB pages. 4 GB because the virtio
/// window is at 0xFEB00000, well above the first gigabyte -- and because a
/// device is handed PHYSICAL addresses, so identity mapping is what makes a
/// pointer mean the same thing to this code and to the device.
const pde_present_write_2mb: u64 = 0x83;

export var page_directories align(4096) linksection(".data") = blk: {
    @setEvalBranchQuota(10000);
    var t: [4][512]u64 = undefined;
    for (0..4) |i| {
        for (0..512) |j| {
            t[i][j] = @as(u64, (i * 512 + j) * 0x200000) | pde_present_write_2mb;
        }
    }
    break :blk t;
};

/// In `.data`, not `.bss`: the loader does not write `.bss`, so nothing there
/// may be assumed zero, and a page table full of whatever was in RAM is a
/// triple fault.
export var pml4: [512]u64 align(4096) linksection(".data") = @splat(0);
export var pdpt: [512]u64 align(4096) linksection(".data") = @splat(0);

/// A flat GDT: a 64-bit code segment and a data segment, which is all long
/// mode looks at — and two slots for the task state segment's descriptor
/// (16 bytes in long mode), which `interrupts.install` fills and loads. The
/// TSS is there for one reason: the stacks it names, which the double fault
/// and the NMI switch to whatever state the stack they interrupted is in.
pub export var gdt align(8) linksection(".data") = [_]u64{
    0,
    0x00AF9A000000FFFF, // code: present, ring 0, executable, long
    0x00CF92000000FFFF, // data: present, ring 0, writable
    0, // the TSS, low half (selector 0x18)
    0, // the TSS, high half
};
pub const tss_selector: u16 = 0x18;

const GdtPointer = extern struct { limit: u16, base: u32 };
/// Filled by the stub, because the base is an address only the linker knows.
/// Five entries of eight bytes, so the limit is 39.
export var gdt_pointer linksection(".data") = GdtPointer{ .limit = 0, .base = 0 };

/// **WHAT THE LOADER PUT IN %ebx**, saved before anything can clobber it: a
/// pointer to the PVH start_info, which carries the machine's memory map. It
/// was thrown away for the whole life of this kernel, which is why every heap
/// here used to be a fixed array.
export var pvh_start_info: u32 linksection(".data") = 0;

/// The linker's marks: where this kernel's image begins and ends. `.bss` is
/// inside it — memory the kernel owns that the file does not carry — so a page
/// allocator that handed out `_kernel_end`-minus-a-bit would be handing out
/// this kernel's own variables.
extern var _kernel_start: u8;
extern var _kernel_end: u8;

/// The memory this kernel occupies, which nothing else may be given.
pub fn image() pvh.Region {
    const start = @intFromPtr(&_kernel_start);
    const end = @intFromPtr(&_kernel_end);
    return .{ .start = start, .len = end - start };
}

/// The machine's memory map, as the loader described it.
pub fn memoryMap() pvh.Error![]const pvh.MemmapEntry {
    return pvh.read(pvh_start_info);
}

/// The command line the machine was booted with.
pub fn commandLine() []const u8 {
    return pvh.commandLine(pvh_start_info);
}

export fn kmain_trampoline() callconv(.c) noreturn {
    root.kmain();
}

/// **WHICH BUILD THIS IS, READABLE FROM THE FILE.** `run.sh` prints it, so a
/// verdict says whether it judged the Debug kernels `-Ddev` makes for
/// iterating or the ReleaseSafe ones a commit is judged on.
export const zig_metal_unikernel_build linksection(".rodata.zig_metal_unikernel_build") =
    ("zig-metal-unikernel-build=" ++ @tagName(@import("builtin").mode)).*;

/// **THE STACK IS PAINTED BEFORE IT IS USED**, in long mode and before %rsp
/// points anywhere: `rep stosq` over the whole region, which nothing is running
/// on yet. Afterwards stack.zig can say how deep the deepest call went, because
/// what is still painted was never written. The three constants come from
/// stack.zig rather than being spelled here, so the region that is painted and
/// the region that is measured cannot drift apart.
///
/// %rsp starts 16 bytes below the top so it is 16-aligned at the `call`, which
/// is what the ABI the compiler generates for expects, and so the first frame's
/// return address is inside the region rather than one byte past it.
export fn _start() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\.code32
            \\  cli
            \\  movl %ebx, pvh_start_info
            \\  movl $pdpt, %eax
            \\  orl $3, %eax
            \\  movl %eax, pml4
            \\  movl $0, pml4 + 4
            \\  movl $page_directories, %eax
            \\  orl $3, %eax
            \\  movl %eax, pdpt + 0
            \\  movl $0, pdpt + 4
            \\  addl $4096, %eax
            \\  movl %eax, pdpt + 8
            \\  movl $0, pdpt + 12
            \\  addl $4096, %eax
            \\  movl %eax, pdpt + 16
            \\  movl $0, pdpt + 20
            \\  addl $4096, %eax
            \\  movl %eax, pdpt + 24
            \\  movl $0, pdpt + 28
            \\  movl %cr4, %eax
            \\  orl $0x620, %eax         // PAE; OSFXSR, OSXMMEXCPT: SSE runs (build.zig, `bareTarget`)
            \\  movl %eax, %cr4
            \\  movl $pml4, %eax
            \\  movl %eax, %cr3
            \\  movl $0xC0000080, %ecx   // EFER
            \\  rdmsr
            \\  orl $0x100, %eax         // LME
            \\  wrmsr
            \\  movl %cr0, %eax
            \\  orl $0x80000001, %eax    // paging + protection: long mode arms here
            \\  movl %eax, %cr0
            \\  movw $39, gdt_pointer
            \\  movl $gdt, %eax
            \\  movl %eax, gdt_pointer + 2
            \\  lgdt gdt_pointer
            \\  ljmp $0x08, $.Llong
            \\.code64
            \\.Llong:
            \\  movw $0x10, %ax
            \\  movw %ax, %ds
            \\  movw %ax, %es
            \\  movw %ax, %ss
            \\  movw %ax, %fs
            \\  movw %ax, %gs
            \\  cld
            \\  leaq kernel_stack(%rip), %rdi
            \\  movabsq ${d}, %rax
            \\  movq ${d}, %rcx
            \\  rep stosq
            \\  leaq kernel_stack(%rip), %rsp
            \\  addq ${d}, %rsp
            \\  call kmain_trampoline
            \\  hlt
        , .{ stack.paint, stack.size / 8, stack.size - 16 }));
}
