//! **THE SEED EXPLORER ON A SIMULATOR, AGAINST BLIND SEEDS** (zig-coverage-sdk's
//! explore.zig; essays notes/the-seed-explorer.md, notes/steering-by-design.md).
//!
//!   zig build explore                          fat_sim, budgets 20 and 100
//!   zig build explore -Dexplore-budgets=20,100,300 -Dexplore-seed=2
//!   zig build explore -Dexplore-seeds=5 -Dexplore-reference=100   quicker
//!
//! **WHAT IT COUNTS** (metal-vmm QUEUE 98): only the simulator's own
//! properties that blind runs reach at `-Dexplore-reference` runs (300, as
//! `long.sh` sweeps FAT seeds). A property no blind sweep reaches is not one
//! the explorer can be judged on here, and counting it only hides the
//! difference.
//!
//! **ONE EXPLORATION IS ONE SAMPLE.** For each budget, each of three columns
//! (blind runs, the explorer with random flips, the explorer with aimed
//! flips) is run once for each of `-Dexplore-seeds` explorer seeds (20), each
//! from a clean catalog. A property is reported as reached in N of 20, and a
//! column by how many of the counted properties it left unreached on
//! average. Any run whose oracle failed is printed with its tape, whether it
//! drifted, whether a flip could not be written into it (`unfaithful`, so
//! that replaying it does not take the flip), and whether it fails again
//! when replayed whole.

const std = @import("std");
const coverage = @import("coverage");
const explore = @import("explore");
const fat_sim = @import("fat_sim.zig");
const store_sim = @import("store_sim.zig");
const options = @import("explore_options");

/// The properties blind seeds reach only at `long.sh`'s 300 FAT seeds.
/// What the simulators allocate from, and their `Io`: the program's, set in
/// `main` (an explorer's `RunFn` takes only its tape). The simulators took
/// `std.testing`'s, which exist only in a test, so this was a test and its
/// output was held until it ended (metal-vmm QUEUE 106).
var host_gpa: std.mem.Allocator = undefined;
var host_io: std.Io = undefined;

const targets = [_][]const u8{
    "fat: a FAT32 entry's first cluster is past 65535",
    "fat: a run of sectors fails to read",
};

fn runFat(tape: *explore.Tape) anyerror!void {
    _ = try fat_sim.runWithIn(host_gpa, host_io, tape);
}

fn runStore(tape: *explore.Tape) anyerror!void {
    try store_sim.runWithIn(host_gpa, host_io, tape);
}

const sim_is_store = std.mem.eql(u8, options.sim, "store");
const runSim: explore.RunFn = if (sim_is_store) runStore else runFat;

/// The properties the simulator is for: FAT's, or the Store's and the FAT
/// under it.
fn ours(site: *const coverage.Site) bool {
    const file = std.mem.span(site.file);
    if (sim_is_store) return std.mem.endsWith(u8, file, "store_sim.zig") or std.mem.endsWith(u8, file, "disk_fat.zig");
    return std.mem.endsWith(u8, file, "disk_fat.zig") or std.mem.endsWith(u8, file, "fat_sim.zig");
}

const Column = enum { blind, random_flips, aimed_flips };

/// The simulator's own properties a run can be reached on: its Sometimes and
/// Reachable sites.
fn counted(site: *const coverage.Site) bool {
    return ours(site) and (site.kind.basic() == .sometimes or site.kind.basic() == .reachable);
}

/// Runs one exploration from a clean catalog, prints any failure, and
/// answers its report; the catalog then holds what it reached.
fn runOnce(gpa: std.mem.Allocator, budget: u32, seed: u64, column: Column) !explore.Report {
    coverage.reset();
    var report = try explore.explore(gpa, runSim, .{
        .budget = budget,
        .seed = seed,
        .blind = if (column == .blind) 1.0 else options.blind,
        .flip = options.flip,
        .aim = column == .aimed_flips,
    });
    // **A RUN THAT DRIFTED IS NOT A STEERED RUN** (CC's review, metal-vmm
    // QUEUE 94): a simulator whose draws are not its tape's makes a
    // benchmark of luck, so none is reported.
    if (report.drifted > 0) {
        std.debug.print("  {d} runs drifted from the tape they replayed: the simulator is not a function of its tape\n", .{report.drifted});
        report.deinit(gpa);
        return error.Drifted;
    }
    for (report.failures.items) |f| {
        std.debug.print("  {s}, explorer seed {d}: a run failed its oracle: tape seed {d}, {d} fills, replayed {d} (drifted {}, unfaithful {}):", .{ @tagName(column), seed, f.seed, f.position(), f.replay_upto, f.drifted, f.unfaithful });
        for (f.choices.items) |c| std.debug.print(" [{s} = {d}]", .{ c.name, c.chosen });
        std.debug.print("\n", .{});
        var again = explore.Tape.branch(gpa, &f, f.position(), 12345, null);
        defer again.deinit();
        const replayed = if (runSim(&again)) |_| "passes" else |_| "fails again";
        std.debug.print("    replayed whole: {s}\n", .{replayed});
    }
    return report;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    host_gpa = gpa;
    host_io = init.io;
    const seeds: u32 = options.seeds;

    // What blind runs reach at the reference budget: all that is counted.
    var reference = try runOnce(gpa, options.reference, options.seed +% 0x7265_6600, .blind); // "ref"
    reference.deinit(gpa);
    var sites: std.ArrayList(*coverage.Site) = .empty;
    defer sites.deinit(gpa);
    var total: u32 = 0;
    var it = coverage.catalog();
    while (it.next()) |site| {
        if (!counted(site)) continue;
        total += 1;
        if (site.passes > 0) try sites.append(gpa, site);
    }
    std.debug.print("\n{s}_sim: blind runs against the explorer, explorer seeds {d} to {d} (blind share {d:.2}, flip share {d:.2})\n", .{ options.sim, options.seed, options.seed + seeds - 1, options.blind, options.flip });
    std.debug.print("counted: the {d} of the simulator's {d} properties that {d} blind runs reach\n", .{ sites.items.len, total, options.reference });

    const reached = try gpa.alloc([3]u32, sites.items.len);
    defer gpa.free(reached);
    var budgets = std.mem.tokenizeScalar(u8, options.budgets, ',');
    while (budgets.next()) |text| {
        const budget = try std.fmt.parseInt(u32, text, 10);
        @memset(reached, .{ 0, 0, 0 });
        var target_hits: [targets.len][3]u32 = @splat(.{ 0, 0, 0 });
        var missed: [3]u64 = .{ 0, 0, 0 };
        var failures: [3]u32 = .{ 0, 0, 0 };
        var unfaithful: [3]u32 = .{ 0, 0, 0 };
        for (0..seeds) |k| {
            inline for (comptime std.enums.values(Column)) |column| {
                const c = @backingInt(column);
                var report = try runOnce(gpa, budget, options.seed + k, column);
                failures[c] += @intCast(report.failures.items.len);
                unfaithful[c] += report.unfaithful;
                report.deinit(gpa);
                for (sites.items, reached) |site, *r| {
                    if (site.passes > 0) r[c] += 1 else missed[c] += 1;
                }
                if (!sim_is_store) for (targets, &target_hits) |t, *h| {
                    var cat = coverage.catalog();
                    while (cat.next()) |site| {
                        if (std.mem.eql(u8, std.mem.span(site.message), t) and site.passes > 0) {
                            h[c] += 1;
                            break;
                        }
                    }
                };
            }
        }
        const n: f64 = @floatFromInt(seeds);
        std.debug.print("\nbudget {d}: of {d} counted, left unreached on average: blind {d:.1}, random flips {d:.1}, aimed flips {d:.1}; failures {d}, {d}, {d}; unfaithful flips {d}, {d}\n", .{
            budget,                                 sites.items.len,
            @as(f64, @floatFromInt(missed[0])) / n, @as(f64, @floatFromInt(missed[1])) / n,
            @as(f64, @floatFromInt(missed[2])) / n, failures[0],
            failures[1],                            failures[2],
            unfaithful[1],                          unfaithful[2],
        });
        if (!sim_is_store) for (targets, target_hits) |t, h| {
            std.debug.print("  target \"{s}\": reached in {d}, {d} and {d} of {d}\n", .{ t, h[0], h[1], h[2], seeds });
        };
        // The properties some column did not reach every time: where the
        // columns can differ.
        for (sites.items, reached) |site, r| {
            if (r[0] == seeds and r[1] == seeds and r[2] == seeds) continue;
            std.debug.print("  {d:>2} {d:>2} {d:>2} of {d}  {s}\n", .{ r[0], r[1], r[2], seeds, std.mem.span(site.message) });
        }
        if (options.list_missed) {
            var cat = coverage.catalog();
            while (cat.next()) |site| {
                if (counted(site) and std.mem.indexOfScalar(*coverage.Site, sites.items, site) == null)
                    std.debug.print("  not counted (blind runs never reach it): {s}  ({s}:{d})\n", .{ std.mem.span(site.message), std.fs.path.basename(std.mem.span(site.file)), site.line });
            }
        }
    }
}
