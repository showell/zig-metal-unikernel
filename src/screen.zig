//! **THE SCREEN, FOR A MACHINE WHOSE ONLY WINDOW IS ITS SCREEN.** A droplet's
//! serial port goes nowhere anyone can read; DigitalOcean's recovery console
//! shows the screen. So everything the console says is also written here.
//!
//! After the BIOS, a PC's screen is in text mode 3: 80 columns by 25 rows,
//! two bytes a character (the character, then its colours), in text memory
//! from physical 0xB8000. The boot loader printed through the BIOS, and the
//! BIOS keeps its cursor in its data area (column at 0x450, row at 0x451), so
//! this carries on below the loader's lines rather than over them.
//!
//! **IT SCROLLS BY MOVING THE WINDOW, NOT THE TEXT.** On a virtual machine
//! every access to text memory is a trip out to the hypervisor. Scrolling by
//! copying 24 rows up is about 4,000 of them per line, and the chat server
//! logs after every request: on the droplet-shaped QEMU a request took 250 ms
//! with the screen and 6.4 ms without (2026-10-01). Text memory holds 32 KB,
//! about 200 rows, of which the display controller shows the 25 starting at
//! its start address (CRTC registers 0x0C/0x0D). So a new line is written into
//! the next row down and the start address moved one row: one row of writes
//! and two port writes. Only when the window reaches the end of text memory
//! are the visible rows copied back to the top, once in about 175 lines.
//!
//! **ONLY A MACHINE THAT HAS A SCREEN IS WRITTEN TO.** On QEMU's microvm or
//! metal-vmm, 0xB8000 may be ordinary memory, and text written there would
//! land in whatever the page allocator handed out. `attach` turns the screen
//! on only when the PCI bus lists a display controller (class 03), which a
//! droplet does in slot 02.

const pci = @import("pci.zig");
const port = @import("port.zig");

const columns = 80;
const rows = 25;
/// Rows of text memory used: 32 KB is 204 rows of 80; a round number below it.
const stored_rows = 200;
/// Light grey on black: what the BIOS left, so the two halves match.
const colour: u16 = 0x07 << 8;

var on = false;
/// The row of text memory shown at the top of the screen.
var origin: usize = 0;
/// The cursor, on the screen (row 0 is the top line shown).
var row: usize = 0;
var column: usize = 0;
/// The text memory. A host test points it at an array; on the machine it is
/// the screen, whose start address and cursor are set through the display
/// controller's ports.
var buffer: [*]volatile u16 = @ptrFromInt(0xB8000);
/// Cells read or written since a host test zeroed it: what scrolling costs.
var touched: usize = 0;

/// Row `r` of the screen as shown, column `c`.
fn cell(r: usize, c: usize) *volatile u16 {
    if (@import("builtin").is_test) touched += 1;
    return &buffer[(origin + r) * columns + c];
}

/// Turns the screen on if this machine has one, starting where the BIOS's
/// cursor was left.
pub fn attach() void {
    if (!pci.present()) return;
    var scan = pci.Scan{};
    while (scan.next()) |f| {
        if (f.read8(0x0B) == 0x03) {
            on = true;
            origin = 0;
            column = @min(@as(*volatile u8, @ptrFromInt(0x450)).*, columns - 1);
            row = @min(@as(*volatile u8, @ptrFromInt(0x451)).*, rows - 1);
            controller(0x0C, 0); // the BIOS's start address, said rather than assumed
            controller(0x0D, 0);
            return;
        }
    }
}

pub fn present() bool {
    return on;
}

pub fn put(bytes: []const u8) void {
    if (!on) return;
    for (bytes) |b| putChar(b);
    const at: u16 = @intCast((origin + row) * columns + @min(column, columns - 1));
    controller(0x0E, @truncate(at >> 8));
    controller(0x0F, @truncate(at));
}

fn putChar(b: u8) void {
    switch (b) {
        '\r' => column = 0,
        '\n' => newLine(),
        else => {
            // **A FULL ROW WRAPS ON THE NEXT CHARACTER, NOT ON THE LAST ONE**,
            // as a terminal does: an 80-character line followed by its own
            // newline is one row, not a row and a blank one.
            if (column == columns) newLine();
            cell(row, column).* = colour | b;
            column += 1;
        },
    }
}

fn newLine() void {
    column = 0;
    if (row + 1 < rows) {
        row += 1;
        return;
    }
    if (origin + rows < stored_rows) {
        origin += 1;
    } else {
        // The window is at the end of text memory: the rows that stay on
        // screen go back to the top, and the window with them.
        for (1..rows) |r| {
            for (0..columns) |c| buffer[(r - 1) * columns + c] = buffer[(origin + r) * columns + c];
        }
        if (@import("builtin").is_test) touched += 2 * (rows - 1) * columns;
        origin = 0;
    }
    for (0..columns) |c| cell(rows - 1, c).* = colour | ' ';
    const start: u16 = @intCast(origin * columns);
    controller(0x0C, @truncate(start >> 8));
    controller(0x0D, @truncate(start));
}

/// One of the display controller's registers, through its index and data
/// ports. A host test has no controller, and its compiler no I/O ports.
fn controller(index: u8, value: u8) void {
    if (@import("builtin").is_test) return;
    port.outb(0x3D4, index);
    port.outb(0x3D5, value);
}

// ── what can be checked without a screen ─────────────────────────────────────

const std = @import("std");

fn fresh(memory: *[stored_rows * columns]u16) void {
    @memset(memory, colour | ' ');
    buffer = memory;
    on = true;
    origin = 0;
    row = 0;
    column = 0;
    touched = 0;
}

fn rowText(r: usize, out: *[columns]u8) []const u8 {
    for (0..columns) |c| out[c] = @truncate(cell(r, c).*);
    return std.mem.trimEnd(u8, out, " ");
}

test "thirty lines on a twenty-five row screen keep the last twenty-five, in order" {
    var memory: [stored_rows * columns]u16 = undefined;
    fresh(&memory);
    defer on = false;

    var line: [16]u8 = undefined;
    for (1..31) |n| put(try std.fmt.bufPrint(&line, "line {d}\n", .{n}));

    var text: [columns]u8 = undefined;
    for (0..rows - 1) |r| {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&line, "line {d}", .{r + 7}), rowText(r, &text));
    }
    // The cursor sits on the empty bottom row the last newline made.
    try std.testing.expectEqualStrings("", rowText(rows - 1, &text));
    try std.testing.expectEqual(@as(usize, rows - 1), row);
}

test "a scroll writes one row, not the screen" {
    var memory: [stored_rows * columns]u16 = undefined;
    fresh(&memory);
    defer on = false;
    for (0..rows) |_| put("x\n");
    touched = 0;
    put("one more line\n");
    // Its 13 characters and the cleared bottom row: nothing else is touched.
    try std.testing.expectEqual(@as(usize, 13 + columns), touched);
}

test "past the end of text memory the window goes back to the top, text intact" {
    var memory: [stored_rows * columns]u16 = undefined;
    fresh(&memory);
    defer on = false;

    var line: [16]u8 = undefined;
    for (1..1001) |n| put(try std.fmt.bufPrint(&line, "line {d}\n", .{n}));

    var text: [columns]u8 = undefined;
    for (0..rows - 1) |r| {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&line, "line {d}", .{r + 977}), rowText(r, &text));
    }
    try std.testing.expectEqualStrings("", rowText(rows - 1, &text));
    try std.testing.expect(origin + rows <= stored_rows);
}

test "a full row followed by its newline is one row, not two" {
    var memory: [stored_rows * columns]u16 = undefined;
    fresh(&memory);
    defer on = false;

    put(&@as([columns]u8, @splat('x')) ++ "\nnext\n");
    var text: [columns]u8 = undefined;
    try std.testing.expectEqualStrings(&@as([columns]u8, @splat('x')), rowText(0, &text));
    try std.testing.expectEqualStrings("next", rowText(1, &text));
}
