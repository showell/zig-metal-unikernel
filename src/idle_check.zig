//! **A VOLUME'S CHECK, IN IDLE TIME** (essay `idle-time-on-metal`): the
//! boot's check (`disk_fat.Volume.check`) asked again while the machine
//! serves, a slice per idle step (`disk_fat.Volume.CheckRun`), so production
//! says what is wrong with its volumes now, not only what was wrong at boot.
//!
//! It reads and writes nothing else: the findings go to `/admin/host` as
//! counts. One full check, then a rest of `period_ns`, then again. A write to
//! the volume under a check starts it again; a read that fails ends this
//! one, counted, and the next starts after the rest.

const std = @import("std");
const props = @import("coverage");
const disk_fat = @import("disk_fat.zig");
const idle = @import("idle.zig");

pub const VolumeCheck = struct {
    vol: *disk_fat.Volume,
    /// The marks (`checkBytes` long), owned by the caller, kept between steps.
    seen: []u8,
    /// What a step reads: directory sectors while it walks the tree (a
    /// request each, ~1 ms on production's volume, where the whole walk was
    /// 548 ms in one step), then FAT runs (`run_sectors` sectors, each copy:
    /// two requests a run, ~12 ms).
    slice: disk_fat.Volume.CheckRun.Slice = .{ .sectors = 64, .runs = 8 },
    period_ns: u64 = std.time.ns_per_hour,
    task: idle.Task = undefined,
    run: disk_fat.Volume.CheckRun = .{},
    state: enum { waiting, running } = .waiting,
    /// When the next check may start; the first is due once the machine
    /// first goes quiet.
    next_at: i96 = 0,
    /// **A VOLUME REFUSING WRITES IS WEIGHED AGAIN** (metal-vmm QUEUE 188.2):
    /// one whose FAT copies the mount could not weigh serves reads and
    /// refuses writes (`disk_fat.Volume.writes`). Each quiet moment
    /// at least `reweigh_ns` after the last try weighs it again
    /// (`disk_fat.Volume.reweigh`), whole in one step: the FAT read afresh
    /// and checked once or twice, as at mount. Before any check, which can
    /// wait. The counts are the volume's (`reweighs`, `reweighs_failed`).
    reweigh_ns: u64 = std.time.ns_per_min,
    reweigh_at: i96 = 0,

    /// Checks finished, started again because the volume changed, and ended
    /// by a read that failed.
    finished: u64 = 0,
    restarts: u64 = 0,
    failed: u64 = 0,
    /// The last finished check: when, and what it found.
    last: ?struct { at: i96, health: disk_fat.Health, tally: disk_fat.Volume.CheckRun.Tally } = null,

    /// Its task, for `idle.Idle.add`. `self` must not move afterwards.
    pub fn init(self: *VolumeCheck, name: []const u8) *idle.Task {
        self.task = .{ .name = name, .ctx = self, .stepFn = step };
        return &self.task;
    }

    fn step(ctx: *anyopaque, now: i96) idle.Outcome {
        const self: *VolumeCheck = @ptrCast(@alignCast(ctx));
        if (self.vol.writes == .refused) {
            if (now < self.reweigh_at) return .resting;
            self.reweigh_at = now + self.reweigh_ns;
            if (self.vol.reweigh(self.seen)) |m| {
                if (m.found == .unweighed) props.reachable(@src(), "idle: a volume refusing writes is weighed again, and the weighing fails", null) else props.reachable(@src(), "idle: a volume refusing writes is weighed again, and takes writes", null);
            } else |_| props.reachable(@src(), "idle: a volume refusing writes is weighed again, and a read fails", null);
            return .worked;
        }
        if (self.state == .waiting) {
            if (now < self.next_at) return .resting;
            self.run.begin(self.vol, self.seen) catch {
                self.failed += 1;
                self.next_at = now + self.period_ns;
                return .resting;
            };
            self.state = .running;
        }
        const outcome = self.run.step(self.slice) catch {
            // A read that failed: nothing found is said, and the next check
            // waits its period.
            props.reachable(@src(), "idle: a volume's check ends on a read that failed", null);
            self.failed += 1;
            self.state = .waiting;
            self.next_at = now + self.period_ns;
            return .worked;
        };
        switch (outcome) {
            .more => {},
            .changed => {
                self.restarts += 1;
                self.state = .waiting; // due at once: next_at has passed
            },
            .done => {
                self.finished += 1;
                self.last = .{ .at = now, .health = self.run.health(), .tally = self.run.tally };
                self.state = .waiting;
                self.next_at = now + self.period_ns;
            },
        }
        return .worked;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_disk = @import("test_disk.zig");

var clock_now: i96 = 0;
fn clock() i96 {
    return clock_now;
}

test "idle check: a volume is checked in quiet moments, a slice a step, then again after its period" {
    const d = try test_disk.Disk.make("idle-check", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("data/a.md", "hello");
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .slice = .{ .sectors = 1, .runs = 1 }, .period_ns = std.time.ns_per_s };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));

    var now: i96 = std.time.ns_per_s;
    var steps: u32 = 0;
    while (check.finished == 0) : (steps += 1) {
        clock_now = now;
        try testing.expect(q.turn(now, clock));
        try testing.expect(steps < 10_000);
    }
    try testing.expect(steps >= 2);
    try testing.expect(check.last.?.health.clean());
    try testing.expectEqual(@as(u32, 0), check.last.?.tally.damage);
    try testing.expectEqual(@as(u32, 1), check.last.?.health.files);
    // Waiting out its period: the turn takes no step, so the loop rests.
    try testing.expect(!q.turn(now, clock));
    now += std.time.ns_per_s;
    clock_now = now;
    try testing.expect(q.turn(now, clock));
}

test "idle check: a write under a check starts it again, and the next one finishes" {
    const d = try test_disk.Disk.make("idle-check-changed", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("data/a.md", "hello");
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .slice = .{ .sectors = 1, .runs = 1 } };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    const now: i96 = std.time.ns_per_s;
    clock_now = now;
    try testing.expect(q.turn(now, clock)); // the walk
    try d.vol.writeFile("data/b.md", "a request wrote this");
    try testing.expect(q.turn(now, clock)); // finds the change
    try testing.expectEqual(@as(u64, 1), check.restarts);
    while (check.finished == 0) try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u32, 2), check.last.?.health.files);
}

test "idle check: damage is counted, the first kind said" {
    const d = try test_disk.Disk.make("damaged-idle-check", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("short", &@as([1000]u8, @splat('x')));
    const e = try d.vol.open("short");
    // The entry's size on the disk, past what its chain holds.
    std.mem.writeInt(u32, d.bytes[e.lba * test_disk.sector + e.slot + 28 ..][0..4], 5000, .little);
    try d.mount(true);
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    const now: i96 = std.time.ns_per_s;
    clock_now = now;
    while (check.finished == 0) try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u32, 1), check.last.?.tally.damage);
    try testing.expectEqual(disk_fat.Problem.short, check.last.?.tally.first.?.problem);
}

test "idle check: a volume refusing writes is weighed again once a minute, stays refused while the weighing fails, and takes writes once it succeeds (metal-vmm QUEUE 188.2)" {
    const d = try test_disk.Disk.make("idle-reweigh", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("data/a.md", "hello");
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .slice = .{ .sectors = 1, .runs = 1 } };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    // As a mount leaves it whose weighing failed.
    d.vol.writes = .refused;
    var now: i96 = std.time.ns_per_s;
    clock_now = now;
    // The disk answers nothing: the weighing fails, the volume stays refused.
    d.blk.fail_after = d.blk.requests;
    try testing.expect(q.turn(now, clock));
    try testing.expect(d.vol.writes == .refused);
    try testing.expectEqual(@as(u64, 1), d.vol.reweighs);
    try testing.expectEqual(@as(u64, 1), d.vol.reweighs_failed);
    try testing.expectError(disk_fat.Error.WritesRefused, d.vol.writeFile("data/b.md", "no"));
    // The disk answers again, but the next weighing waits its minute: no
    // request until then, and no check runs ahead of it.
    d.blk.fail_after = null;
    const requests = d.blk.requests;
    now += std.time.ns_per_min - 1;
    clock_now = now;
    _ = q.turn(now, clock);
    try testing.expectEqual(requests, d.blk.requests);
    try testing.expectEqual(@as(u64, 1), d.vol.reweighs);
    now += 1;
    clock_now = now;
    try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u64, 2), d.vol.reweighs);
    try testing.expectEqual(@as(u64, 1), d.vol.reweighs_failed);
    try testing.expect(d.vol.writes == .taken);
    try d.vol.writeFile("data/b.md", "yes");
}

test "idle check: a volume taking writes is never weighed again" {
    const d = try test_disk.Disk.make("idle-no-reweigh", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .slice = .{ .sectors = 1, .runs = 1 } };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    const now: i96 = std.time.ns_per_s;
    clock_now = now;
    while (check.finished == 0) try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u64, 0), d.vol.reweighs);
}
