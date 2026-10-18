//! disk_fat_remove: renames and removes. A file renamed (and the unlink
//! undone when the new entry cannot be written), a file removed, and a tree
//! removed to the depth a path may have (split from disk_fat.zig by metal-vmm
//! QUEUE 173).

const std = @import("std");
const builtin = @import("builtin");
const props = @import("coverage");
const dirent = @import("disk_fat_dirent.zig");
const Cluster = dirent.Cluster;
const max_name = dirent.max_name;
const Entry = dirent.Entry;
const putCluster = dirent.putCluster;
const putLe16 = dirent.putLe16;
const putDos = dirent.putDos;
const longParts = dirent.longParts;
const needsLongName = dirent.needsLongName;
const eqlBytes = dirent.eqlBytes;
const eqlFold = dirent.eqlFold;
const dirent_size = dirent.dirent_size;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const Commit = Volume.Commit;
const max_dir_entries = Volume.max_dir_entries;
const sector_size = disk_fat.sector_size;
const max_tree_depth = Volume.max_tree_depth;
const hasEmptyPart = disk_fat.hasEmptyPart;
const Run = Volume.Run;
const Landing = Volume.Landing;
const Error = disk_fat.Error;
const Unlinked = Volume.Unlinked;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// **A RENAME'S UNLINK UNDONE**, its chain (`clusters`, taken) ended
/// where the undo lands, so `from` is whole again; refused and read back
/// as before, a counted leak, its long name cleared. Unknown is counted
/// by the read-back, and the long name stays, as the entry may be live.
pub fn undoUnlink(self: *Volume, held: *const Unlinked, clusters: u32) void {
    switch (held.undo(self, clusters)) {
        .landed => {
            props.reachable(@src(), "fat: a rename's unlink is undone, and from is kept", null);
            self.ended(clusters);
        },
        .before => {
            props.reachable(@src(), "fat: a rename's undo did not land, and the file's chain is left a counted leak", null);
            self.leftLeaked(clusters);
            held.forget(self);
        },
        // Its clusters counted by the read-back; its long name's parts
        // stay, the entry may be live, and are counted with them (148(f)).
        .unknown => {
            props.reachable(@src(), "fat: a rename's undo cannot be read back, and the file's chain and long name may be left", null);
            self.unsure_parts +|= held.part_count;
            if (held.part_count > 0) self.unsure_runs +|= 1;
        },
    }
}

/// **RENAMES A FILE WITHIN ITS DIRECTORY, OVER ANY FILE OF THE NEW NAME**:
/// how a file is replaced with no moment when neither old nor new is
/// there (write the new under another name, rename it over the old).
///
/// The order, and what a stop after each step leaves:
///   1. `from`'s entry goes; its chain stays taken, and its long name's
///      parts stay until `to` lands. `to` is the old file, whole, and
///      `from`'s clusters are leaked, its parts orphans.
///   2. an existing `to`'s short entry is pointed at `from`'s chain and
///      size, in one sector write. `to` is the new file, whole, and its
///      old clusters are leaked.
///   3. only then is `to`'s old chain freed.
/// When `to` does not exist, step 2 writes a new entry, and a stop
/// before it loses `from`. Never two entries on one chain.
///
/// **A WRITE THAT FAILS KEEPS `from` WHERE THE DISK SAYS IT CAN**
/// (metal-vmm 145). Each commit (`from`'s tombstone, `to`'s entry) is
/// read back where it is refused (`commitRefused`). Where `to`'s entry
/// did not land, or `from`'s tombstone landed though refused (147(g)),
/// the tombstone is undone, and its long name, not cleared until `to`
/// lands, is whole with it (`undoUnlink`). That write can fail too:
/// **a failed rename may lose `from`**, its chain then a counted leak
/// (`cleanups_failed`) for fsck.fat to recover. A stop still loses it.
///
/// An existing `to` keeps its name; a new one takes the case given; a
/// name that differs from `from`'s only in case, or is its alias, is a
/// no-op. Both must be files in one directory: a directory as `to` is
/// `IsDirectory`, as `from` `BadName`.
pub fn rename(self: *Volume, from: []const u8, to: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    const a = try self.parentOf(from);
    const b = try self.parentOf(to);
    if (a.cluster != b.cluster) {
        props.reachable(@src(), "fat: a rename across directories is refused", null);
        return Error.BadName;
    }
    if (b.name.len == 0 or b.name.len > max_name) return Error.BadName;
    const src = (try self.find(a.cluster, a.name)) orelse {
        props.reachable(@src(), "fat: a rename of a file that is not there is refused", null);
        return Error.NotFound;
    };
    if (src.isDirectory()) {
        props.reachable(@src(), "fat: a rename of a directory is refused", null);
        return Error.BadName;
    }
    // The same file, by its name in any case or by its own alias.
    if (eqlFold(src.text(), b.name) or eqlFold(src.alias(), b.name)) return;
    const dst = try self.find(b.cluster, b.name);
    if (dst) |d| if (d.isDirectory()) {
        props.reachable(@src(), "fat: a rename onto a directory is refused", null);
        return Error.IsDirectory;
    };

    // **A NEW `to` HAS ITS ROOM BEFORE `from` IS UNLINKED**, so a full
    // directory refuses with `from` intact. A rename that would fit only
    // in the slots `from` frees is refused as full.
    var room: ?struct { short: [11]u8, run: Run } = null;
    if (dst == null) {
        const short = try self.aliasFor(b.cluster, b.name);
        const parts: u32 = if (needsLongName(b.name)) longParts(b.name) else 0;
        room = .{ .short = short, .run = try self.findRun(b.cluster, parts + 1) };
    }

    // **ONCE `from`'S ENTRY IS GONE ITS CHAIN IS THE RENAME'S**, pointed
    // at by no entry until `to`'s write lands (the commit). A failure
    // before that leaves it a counted leak, never given back: fsck.fat
    // recovers a lost chain as a file, and freeing it would lose the
    // bytes for good. Counted from the size, as the ledger needs only
    // the same number at both ends.
    const per_cluster: u64 = @as(u64, self.sectors_per_cluster) * sector_size;
    const clusters: u32 = @intCast((@as(u64, src.size) + per_cluster - 1) / per_cluster);
    var gone: Landing = .before;
    var held: Unlinked = .{};
    self.unlinkEntry(a.cluster, a.name, .keep_chain, &gone, &held) catch |err| {
        // **A REFUSED TOMBSTONE THAT LANDED IS UNDONE** (147(g)): nothing
        // else is written yet, so the same undo keeps `from`, where the
        // disk lets it. **ONE WHOSE LANDING IS UNKNOWN** may have left
        // the chain and the long name with nothing to reach them, or
        // not: both may be live (148(f)).
        switch (gone) {
            .before => {},
            .landed => {
                props.reachable(@src(), "fat: a rename's refused unlink landed, and is undone", null);
                self.took(clusters);
                self.undoUnlink(&held, clusters);
            },
            .unknown => {
                props.reachable(@src(), "fat: a rename's unlink cannot be read back, and the file's chain and long name may be left", null);
                // The read-back counted the cleanup; the chain is walked,
                // as a remove's is (a chain may be longer than its size).
                self.took(clusters);
                self.ended(clusters);
                self.unlinkUnsure(src.first_cluster, @intCast(held.part_count));
            },
        }
        return err;
    };
    // **THE WALK MAY NOT FIND WHAT THE LISTER DID**: it reads the
    // directory again, by another route, and a disk that lies can
    // answer otherwise. Then nothing was unlinked and `held` points at
    // nothing: the rename stops here, having changed nothing.
    if (held.state == .not_found) {
        props.reachable(@src(), "fat: a rename's unlink does not find from, which the lookup found, and nothing is changed", null);
        return Error.NotFound;
    }
    self.took(clusters);
    var commit: Commit = .{ .clusters = clusters };
    // **A RENAME THAT DID NOT LAND KEEPS `from`** (metal-vmm 145): the
    // new entry refused and read back as it was, the tombstone is
    // undone and `from` is whole, its chain its own again. That write
    // can fail too, and then `from` is lost, its chain a counted leak.
    errdefer switch (commit.landing) {
        .before => self.undoUnlink(&held, clusters),
        .landed, .unknown => held.forget(self),
    };

    if (dst) |d| {
        props.reachable(@src(), "fat: a rename replaces a file", null);
        try self.readSector(d.lba, self.scratch);
        const e = self.scratch[d.slot..][0..dirent_size];
        const was = e.*;
        putCluster(e, src.first_cluster);
        e[28] = @truncate(src.size);
        e[29] = @truncate(src.size >> 8);
        e[30] = @truncate(src.size >> 16);
        e[31] = @truncate(src.size >> 24);
        const when = self.stamp();
        putLe16(e[18..20], when.date); // last access date
        putDos(e[22..26], when); // write time, write date
        const written = e.*;
        // The commit, read back where refused; freeing the old chain
        // after it is cleanup.
        self.writeSector(d.lba, self.scratch) catch |err| {
            commit.done(self, self.commitRefused(d.lba, d.slot, &was, &written, clusters));
            switch (commit.landing) {
                .before => {},
                .landed => if (d.first_cluster >= 2) self.freeAfterCommit(d.first_cluster),
                // `from`'s chain is counted by the read-back; `to`'s old
                // one is its file's or no one's, as the entry is.
                .unknown => self.unlinkUnsure(d.first_cluster, 0),
            }
            return err;
        };
        commit.done(self, .landed);
        held.forget(self);
        if (d.first_cluster >= 2) self.freeAfterCommit(d.first_cluster);
        return;
    }

    const r = room.?;
    try self.writeEntry(r.run, if (needsLongName(b.name)) b.name else b.name[0..0], r.short, 0x20, src.first_cluster, src.size, &commit);
    held.forget(self);
}

/// Deletes one file (`removeEntry`).
///
/// **A DIRECTORY IS REFUSED** (`IsDirectory`), empty or not, as Linux's
/// unlink refuses one: taking its entry would leak everything under it.
/// `removeTree` is how a directory goes.
pub fn remove(self: *Volume, path: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    const p = try self.parentOf(path);
    const e = (try self.find(p.cluster, p.name)) orelse {
        props.reachable(@src(), "fat: a remove of a file that is not there is refused", null);
        return Error.NotFound;
    };
    if (e.isDirectory()) {
        props.reachable(@src(), "fat: a remove of a directory is refused", null);
        return Error.IsDirectory;
    }
    try self.removeEntry(p.cluster, p.name);
}

/// **A NAME FOUND, THEN NOT, IS NO REMOVE** (metal-vmm QUEUE 172): the
/// lookup and the unlink are two walks of the directory, and a disk that
/// answers the second with other bytes leaves the name standing; "done"
/// would be a lie, so it is NotFound, as `rename` says (3255).
pub fn walkFound(gone: Landing) Error!void {
    if (gone != .before) return;
    props.reachable(@src(), "fat: a remove's second walk misses the name its lookup found", null);
    return Error.NotFound;
}

/// Deletes a directory and everything under it, or a file.
///
/// **ONE ENTRY AT A TIME, RE-LISTING EACH ROUND.** `list`'s callback
/// cannot fail, so it cannot remove, and there is no allocator to copy
/// a listing into; so each round finds the FIRST entry, removes it, and
/// lists again. Quadratic in the entries.
///
/// **ONLY ABSENCE IS FINE**: a missing path is success; every other
/// error is the caller's.
pub fn removeTree(self: *Volume, path: []const u8) Error!void {
    defer self.balanced();
    if (self.writes == .refused) return Error.WritesRefused;
    // A path with an empty part names nothing to `open`, which is
    // absence, which is done: refused first, as every path operation
    // refuses it (metal-vmm QUEUE 172).
    if (hasEmptyPart(path)) return Error.BadName;
    const entry = self.open(path) catch |e| switch (e) {
        Error.NotFound => return,
        else => return e,
    };
    if (!entry.isDirectory()) return self.remove(path);
    // The emptied directory, by its entry (`remove` refuses one).
    const p = try self.parentOf(path);
    try self.removeDirectoryIn(p.cluster, p.name, entry.first_cluster, 0);
}

/// A directory emptied (`removeTreeAt`), then its entry removed from
/// `parent`. **WHAT IT HELD IS COUNTED WHERE IT CAN BE FOUND**
/// (148(b)): long-name parts its emptying left orphaned in it are found
/// by nothing once its entry goes, and are counted no more; where that
/// tombstone's landing is unknown, they may be found or not.
pub fn removeDirectoryIn(self: *Volume, parent: Cluster, name: []const u8, dir_cluster: Cluster, depth: u32) Error!void {
    const orphans_before = self.orphaned_parts;
    const unsure_before = self.unsure_parts;
    const runs_before = self.orphaned_runs;
    const unsure_runs_before = self.unsure_runs;
    try self.removeTreeAt(dir_cluster, depth);
    const inside = self.orphaned_parts -| orphans_before;
    const unsure_inside = self.unsure_parts -| unsure_before;
    const runs_inside = self.orphaned_runs -| runs_before;
    const unsure_runs_inside = self.unsure_runs -| unsure_runs_before;
    var gone: Landing = .before;
    defer switch (gone) {
        .before => {},
        .landed => {
            self.orphaned_parts -|= inside;
            self.unsure_parts -|= unsure_inside;
            self.orphaned_runs -|= runs_inside;
            self.unsure_runs -|= unsure_runs_inside;
        },
        .unknown => {
            self.orphaned_parts -|= inside;
            self.unsure_parts +|= inside;
            self.orphaned_runs -|= runs_inside;
            self.unsure_runs +|= runs_inside;
        },
    };
    try self.unlinkEntry(parent, name, .free_chain, &gone, null);
    return walkFound(gone);
}

pub fn removeTreeAt(self: *Volume, dir_cluster: Cluster, depth: u32) Error!void {
    if (depth >= max_tree_depth) {
        props.reachable(@src(), "fat: a tree too deep to remove is refused", null);
        return Error.BadChain;
    }

    const First = struct {
        entry: ?Entry = null,
        fn each(s: *@This(), e: Entry) void {
            if (s.entry != null) return;
            const text = e.text();
            if (eqlBytes(text, ".") or eqlBytes(text, "..")) return;
            s.entry = e;
        }
    };

    var rounds: u32 = 0;
    // One round removes one entry: a directory holds at most
    // `max_dir_entries`, so more rounds than that is a broken volume.
    while (rounds <= max_dir_entries) : (rounds += 1) {
        var first = First{};
        try self.list(dir_cluster, &first, First.each);
        const entry = first.entry orelse return; // empty
        if (entry.isDirectory()) {
            try self.removeDirectoryIn(dir_cluster, entry.text(), entry.first_cluster, depth + 1);
        } else try self.removeEntry(dir_cluster, entry.text());
    }
    props.reachable(@src(), "fat: a directory yields more entries than a directory holds, removing a tree, and is refused as broken", null);
    return Error.BadChain;
}
