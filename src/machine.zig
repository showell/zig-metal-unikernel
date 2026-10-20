//! **A STATE THAT CHANGES ONLY BY A NAMED EVENT** (metal-vmm STATE_TRACKING.md,
//! QUEUE item 140). A machine declares its states, its events and the edges
//! between them; code reads the state freely and changes it only by `fire`,
//! which looks the next state up. Nothing chooses a state but the table.
//!
//! **EVERY CELL IS A COVERAGE SITE.** `fire` is one `switch` over every
//! (state, event) pair, each prong compiled with its own message, so the
//! catalog holds one site per cell:
//! - an edge is a `reachable`: a sweep that never took it reports it unhit,
//!   a legal transition no test drives;
//! - a pair with no edge is an `unreachable`: reached, it breaks, and a unit
//!   test fails at it (`on_broken`). The state is left as it was.
//!
//! The messages are regular, so a reader greps them:
//! `machine tcp.Fin: sent --timed_out--> resending` and
//! `machine tcp.Fin: nothing leaves acknowledged on timed_out`.
//!
//! **BUILT TO MOVE** (the box's vote: local first, promoted on its second
//! user): it imports nothing of zig-metal-unikernel's, only the coverage SDK, and
//! makes its sites the way the SDK makes them. Moving it is a file and an
//! import.
//!
//! **ONLY `fire` WRITES THE STATE.** `machine_state` is a field, since Zig
//! has none private; `tools/lint_machine.py` refuses an assignment to it
//! anywhere else, and `startingAt` (a machine made at a given state) outside
//! a test.
const std = @import("std");
const props = @import("coverage");

pub fn Edge(comptime State: type, comptime Event: type) type {
    return struct { from: State, on: Event, to: State };
}

/// **WHICH GROUPS EACH STATE IS IN** (metal-vmm 143): a field for every
/// state, each naming its groups, so a machine with a state left out does not
/// compile. A new state is placed in its groups once, where it is declared,
/// and every `in(.group)` that asks after it is right.
pub fn Membership(comptime State: type, comptime Group: type) type {
    return std.enums.EnumFieldStruct(State, []const Group, null);
}

/// **A MACHINE, DECLARED BY NAME** (`spec`, a struct literal):
///
///     .name     in its sites' messages ("tcp.Fin")
///     .State    an enum; .initial, one of its values
///     .Event    an enum
///     .edges    its only transitions: two from one state on one event are
///               refused at compile time
///     .Group    optional: an enum naming sets of states callers ask about
///               (`in`), and then .groups, which places every state
pub fn Machine(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    if (!@hasField(Spec, "name")) @compileError("a machine's spec needs .name, for its sites' messages");
    const name: []const u8 = spec.name;
    // **A SPEC SAYS WHAT IT MEANS, OR DOES NOT COMPILE** (144's review): an
    // unknown key (`.group` for `.groups`) would be ignored, and Group
    // without groups would place every state in none.
    comptime for (std.meta.fieldNames(Spec)) |f| {
        const known = [_][]const u8{ "name", "State", "Event", "Group", "initial", "edges", "groups" };
        for (known) |k| {
            if (std.mem.eql(u8, k, f)) break;
        } else @compileError("machine " ++ name ++ ": no spec key ." ++ f ++ " (name, State, Event, Group, initial, edges, groups)");
    };
    if (@hasField(Spec, "Group") != @hasField(Spec, "groups")) @compileError("machine " ++ name ++ ": .Group and .groups come together: the groups, and where each state is in them");
    const State: type = spec.State;
    const Event: type = spec.Event;
    const Group: type = if (@hasField(Spec, "Group")) spec.Group else enum {};
    const initial: State = spec.initial;
    // The literal's edges and groups are untyped tuples: each is typed here.
    const edges: []const Edge(State, Event) = comptime blk: {
        var es: [spec.edges.len]Edge(State, Event) = undefined;
        for (&es, spec.edges) |*e, given| e.* = .{ .from = given.from, .on = given.on, .to = given.to };
        const typed = es;
        break :blk &typed;
    };
    const groups: Membership(State, Group) = comptime blk: {
        var m: Membership(State, Group) = undefined;
        if (@hasField(Spec, "groups")) for (std.meta.fieldNames(@TypeOf(spec.groups))) |f| {
            if (!@hasField(State, f)) @compileError("machine " ++ name ++ ": .groups names " ++ f ++ ", which is no state");
        };
        for (std.meta.fieldNames(State)) |f| {
            if (@hasField(Spec, "groups") and !@hasField(@TypeOf(spec.groups), f)) @compileError("machine " ++ name ++ ": .groups leaves out the state " ++ f ++ "; every state says its groups, &.{} for none");
            @field(m, f) = if (@hasField(Spec, "groups")) @field(spec.groups, f) else &.{};
        }
        break :blk m;
    };
    const of = std.enums.EnumArray(State, []const Group).init(groups);
    comptime {
        for (edges, 0..) |a, i| {
            for (edges[i + 1 ..]) |b| {
                if (a.from == b.from and a.on == b.on) @compileError(std.fmt.comptimePrint(
                    "machine {s}: two edges leave {t} on {t}",
                    .{ name, a.from, a.on },
                ));
            }
        }
    }
    return struct {
        const Self = @This();

        /// Read it with `get`, `is` or `in`; only `fire` writes it.
        machine_state: State = initial,

        pub const Of = State;
        pub const On = Event;

        // **EVERY CELL IN THE CATALOG, FIRED OR NOT** (metal-vmm QUEUE 165):
        // the scan cannot read the cells' messages (made at comptime), so the
        // machine itself compiles `fire`, every prong of it, wherever the
        // machine's type is: a cell no program reaches is still a site, unhit.
        comptime {
            _ = &fire;
        }

        /// **A MACHINE MADE AT A GIVEN STATE**, not reached by its edges:
        /// for tests that build a case directly. The lint refuses it
        /// outside a test.
        pub fn startingAt(state: State) Self {
            return .{ .machine_state = state };
        }

        pub fn get(self: Self) State {
            return self.machine_state;
        }

        pub fn is(self: Self, state: State) bool {
            return self.machine_state == state;
        }

        /// Whether the state is in `group`, as `groups` placed it.
        pub fn in(self: Self, group: Group) bool {
            switch (self.machine_state) {
                inline else => |state| {
                    inline for (comptime of.get(state)) |g| {
                        if (g == group) return true;
                    }
                    return false;
                },
            }
        }

        /// The edge from `from` on `on`, if the table has one.
        pub fn target(comptime from: State, comptime on: Event) ?State {
            for (edges) |e| {
                if (e.from == from and e.on == on) return e.to;
            }
            return null;
        }

        /// **THE ONLY WAY THE STATE CHANGES.** An event with no edge from
        /// the state it finds breaks that cell's `unreachable` and changes
        /// nothing.
        pub fn fire(self: *Self, event: Event) void {
            switch (self.machine_state) {
                inline else => |from| switch (event) {
                    inline else => |on| {
                        if (comptime target(from, on)) |to| {
                            // coverage: not scanned, one site a cell, its message made at comptime, cataloged by the comptime reference to fire above
                            props.reachable(@src(), comptime edgeMessage(from, on, to), null);
                            self.machine_state = to;
                        } else {
                            // coverage: not scanned, one site a cell, its message made at comptime, cataloged by the comptime reference to fire above
                            props.@"unreachable"(@src(), comptime noEdgeMessage(from, on), null);
                        }
                    },
                },
            }
        }

        fn edgeMessage(comptime from: State, comptime on: Event, comptime to: State) [:0]const u8 {
            return std.fmt.comptimePrint("machine {s}: {t} --{t}--> {t}", .{ name, from, on, to });
        }

        fn noEdgeMessage(comptime from: State, comptime on: Event) [:0]const u8 {
            return std.fmt.comptimePrint("machine {s}: nothing leaves {t} on {t}", .{ name, from, on });
        }
    };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

const Door = Machine(.{
    .name = "test.Door",
    .State = enum { shut, open, locked },
    .Event = enum { push, pull, lock, unlock },
    .Group = enum { closed, passable },
    .initial = .shut,
    .edges = &.{
        .{ .from = .shut, .on = .push, .to = .open },
        .{ .from = .open, .on = .pull, .to = .shut },
        .{ .from = .shut, .on = .lock, .to = .locked },
        .{ .from = .locked, .on = .unlock, .to = .shut },
    },
    .groups = .{ .shut = &.{.closed}, .open = &.{.passable}, .locked = &.{.closed} },
});

/// A machine with no groups declares none.
const Switch = Machine(.{
    .name = "test.Switch",
    .State = enum { off, on },
    .Event = enum { flip },
    .initial = .off,
    .edges = &.{ .{ .from = .off, .on = .flip, .to = .on }, .{ .from = .on, .on = .flip, .to = .off } },
});

/// A machine no test fires: its cells are in the catalog all the same.
const Unfired = Machine(.{
    .name = "test.Unfired",
    .State = enum { here, there },
    .Event = enum { go },
    .initial = .here,
    .edges = &.{.{ .from = .here, .on = .go, .to = .there }},
});

test "a machine nothing fires still has every cell in the catalog, unhit" {
    _ = Unfired.Of.here;
    var cells: usize = 0;
    var it = props.catalog();
    while (it.next()) |site| {
        if (!std.mem.startsWith(u8, std.mem.span(site.message), "machine test.Unfired: ")) continue;
        cells += 1;
        try testing.expect(!site.hit());
    }
    try testing.expectEqual(@as(usize, 2), cells);
}

test "a machine with no groups needs none" {
    var s: Switch = .{};
    s.fire(.flip);
    try testing.expect(s.is(.on));
}

test "a state is in the groups its machine placed it in, and no other" {
    try testing.expect(Door.startingAt(.shut).in(.closed));
    try testing.expect(!Door.startingAt(.shut).in(.passable));
    try testing.expect(Door.startingAt(.locked).in(.closed));
    try testing.expect(Door.startingAt(.open).in(.passable));
    try testing.expect(!Door.startingAt(.open).in(.closed));
}

test "a machine moves only along its edges" {
    var d: Door = .{};
    try testing.expect(d.is(.shut));
    d.fire(.push);
    try testing.expectEqual(Door.Of.open, d.get());
    d.fire(.pull);
    d.fire(.lock);
    try testing.expect(d.is(.locked));
    d.fire(.unlock);
    try testing.expect(d.is(.shut));
}

test "an event with no edge breaks its cell and changes nothing" {
    const was = props.on_broken;
    props.on_broken = null; // broken on purpose
    defer props.on_broken = was;
    // **NO reset()**: every file's tests share one process and one catalog
    // (metal-vmm 146(e)), so this test looks at its own machine's sites only
    // and leaves every other count as it found it.

    var d = Door.startingAt(.locked);
    d.fire(.push);
    try testing.expect(d.is(.locked));

    var broken: usize = 0;
    var it = props.catalog();
    while (it.next()) |site| {
        const message = std.mem.span(site.message);
        if (!std.mem.startsWith(u8, message, "machine test.Door: ") or !site.broken()) continue;
        broken += 1;
        try testing.expectEqualStrings("machine test.Door: nothing leaves locked on push", message);
    }
    try testing.expectEqual(@as(usize, 1), broken);
}

test "every cell is a site in the catalog, each edge a reachable and each other pair an unreachable" {
    var edge_sites: usize = 0;
    var no_edge_sites: usize = 0;
    var it = props.catalog();
    while (it.next()) |site| {
        const message = std.mem.span(site.message);
        if (!std.mem.startsWith(u8, message, "machine test.Door: ")) continue;
        if (std.mem.indexOf(u8, message, "-->") != null) edge_sites += 1 else no_edge_sites += 1;
    }
    try testing.expectEqual(@as(usize, 4), edge_sites);
    try testing.expectEqual(@as(usize, 3 * 4 - 4), no_edge_sites);
}
