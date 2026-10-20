//! `Io` for this machine: the same surface `angry-gopher/zig-server` calls,
//! backed by FAT16 and the timestamp counter instead of by Linux.
//!
//! **THE FIRST ATTEMPT AT THIS WAS THE WRONG SEAM, AND IT IS WORTH SAYING WHY.**
//! `std.Io` looks like an interface — a vtable you can implement — and it is
//! not one. It has 117 function pointers and no defaults, its handles are
//! literally `std.posix.fd_t`, and `std.Io.Dir.cwd()` reaches for
//! `std.posix.AT.FDCWD`, which does not exist on a freestanding target. It does
//! not fail to work there; **it fails to compile**, whatever vtable you supply.
//! `std.Io` is a portable spelling of the POSIX syscalls, not an abstraction
//! over storage.
//!
//! The real seam is one line higher, and the application hands it to us: every
//! one of its 121 filesystem calls is spelled `Io.Dir.cwd().something(io, ...)`,
//! and 37 files open with
//!
//!     const Io = std.Io;
//!
//! Point that at this module instead and **not one call site changes**. That is
//! the port: 37 single-line edits, zero touched call sites, and a `Dir` that
//! answers the eleven operations the application actually asks for.
//!
//! Note what this does NOT change. `std.http.Server` still runs unmodified,
//! because `std.Io.Reader` and `std.Io.Writer` are genuine interfaces — one
//! required method each, defaults for the rest, no POSIX in their types. The
//! difference between those two designs is the whole lesson here.

const std = @import("std");
const serial = @import("serial.zig");
const stack = @import("stack.zig");
const PageCache = @import("page_cache.zig").PageCache;
const disk_fat = @import("disk_fat.zig");
const rng = @import("rng.zig");
const tsc = @import("tsc.zig");
const sleep = @import("sleep.zig");
const io_volumes = @import("io_volumes.zig");
pub const keepPages = io_volumes.keepPages;
pub const pageCache = io_volumes.pageCache;
pub const durable = io_volumes.durable;
pub const durableChecked = io_volumes.durableChecked;
pub const siteVolume = io_volumes.siteVolume;
pub const dataVolume = io_volumes.dataVolume;
pub const SiteCache = io_volumes.SiteCache;
pub const siteCache = io_volumes.siteCache;
pub const Error = io_volumes.Error;
pub const max_path = io_volumes.max_path;
const pagesFor = io_volumes.pagesFor;
const reading = io_volumes.reading;
const openEntry = io_volumes.openEntry;
const writing = io_volumes.writing;
const throughFile = io_volumes.throughFile;
const Place = io_volumes.Place;
const placeOf = io_volumes.placeOf;
const volumeAt = io_volumes.volumeAt;
const cacheable = io_volumes.cacheable;

/// **THE VALUE THREADED THROUGH EVERY CALL IS THIS MODULE ITSELF.** On Linux it
/// carries an event loop; here there is one machine and one disk, so it carries
/// nothing — but it is still a value, so the call sites keep their shape.
///
/// It has to be the module and not a struct inside it, and that cost a build.
/// The ported application opens with `const Io = @import("host_io").Io;`
/// (src/host_io_metal.zig: this module) and then spells its parameters
/// `io: Io` — so the type it threads IS the module. A
/// separate `pub const Io = struct {}` type-checked for this machine's own
/// probes, which pass what they are given, and failed the moment the real
/// application threaded its own `io` into `Io.Dir` — which is to say, the
/// moment anything ported actually touched the filesystem.
const Self = @This();

pub fn io() Self {
    return .{};
}

/// **THE ONE FUNCTION THE PASSWORD SYSTEM NEEDS FROM THIS MACHINE.**
/// `angry-gopher/zig-server` calls it in exactly two places -- a session token
/// in `users.zig` and an upload id in `chat_upload.zig` -- and spells it the
/// same way Linux does. Everything else its identity layer uses is pure: bcrypt
/// from `std.crypto.pwhash`, HMAC-SHA256 for the cookie, and a constant-time
/// compare. Those already compile freestanding untouched.
pub fn random(_: Self, buf: []u8) void {
    rng.fill(buf);
}

/// The volume every path is resolved against, until `keepData` names the
/// directories that are the application's data.
pub fn mount(v: disk_fat.Volume) void {
    if (io_volumes.page_cache) |pc| pc.clear();
    io_volumes.site = v;
    io_volumes.site_cache.clear(); // what it kept was another volume's
    // **THE FILESYSTEM GETS THIS MACHINE'S CLOCK.** FAT16 entries carry a date,
    // and the application's "recent activity" is built entirely out of file
    // modification times. disk_fat.zig has no clock of its own and must not invent
    // one, so it asks this — which answers null until the host has read the RTC,
    // and files written before then honestly carry no date.
    io_volumes.site.?.clock = realUnixOrNull;
}

/// **THE APPLICATION'S DATA: `dirs`, on `on`** (null: on the site's volume).
/// From here on nothing outside `dirs` is written: whatever is there is the
/// site's, and on a droplet the next image replaces it, so a write there would
/// be lost without anyone being told. Such a write is refused and logged.
pub fn keepData(dirs: []const []const u8, on: ?disk_fat.Volume) void {
    io_volumes.data_dirs = dirs;
    io_volumes.data = on;
    if (io_volumes.data) |*d| d.clock = realUnixOrNull;
    // Another volume, or the same one read afresh: nothing kept is known to
    // be its.
    if (io_volumes.page_cache) |pc| pc.clear();
}

/// The wall clock in whole seconds, or null if nothing has set it yet. Unlike
/// `Clock.now(.real)` this does not panic: a file write is not a session check,
/// and a probe kernel with no clock still writes files.
fn realUnixOrNull() ?i64 {
    if (!realTimeIsSet()) return null;
    return @intCast(@divFloor(Clock.now(.real, io()).nanoseconds, 1_000_000_000));
}

pub const Limit = enum(u64) {
    unlimited = std.math.maxInt(u64),
    _,
    /// `limited` is std's spelling, and the application uses it at every capped
    /// read — `.limited(4096)` for a name, `.limited(64)` for a counter. `of` is
    /// this machine's own older name for it, kept because the probes call it.
    pub fn limited(n: u64) Limit {
        return @fromBackingInt(@intCast(n));
    }
    pub fn of(n: u64) Limit {
        return limited(n);
    }
};

/// Kind is std's `File.Kind`, ALL of it, though this machine only ever answers
/// `.file` or `.directory`. The application switches over it with an
/// `else => {}` prong — correct against std's eleven members — and against a
/// two-member enum that prong is unreachable, which zig refuses to compile.
pub const Kind = enum {
    block_device,
    character_device,
    directory,
    named_pipe,
    sym_link,
    file,
    unix_domain_socket,
    whiteout,
    door,
    event_port,
    unknown,
};

pub const Stat = struct {
    size: u64,
    kind: Kind,

    /// **FAT16 HAS NO NANOSECONDS, BUT IT HAS A DATE, AND THIS MACHINE WRITES
    /// IT.** A directory entry carries a DOS timestamp with two-second
    /// resolution and nothing finer, so this is always a whole even number of
    /// seconds in nanoseconds. Two things read it: reading_list's cache, which
    /// re-parses a document when its mtime has ADVANCED, and chat's "recent
    /// activity", whose whole model is which files were written last. An entry
    /// that nothing with a clock ever wrote reads as zero.
    mtime: Timestamp = .{ .nanoseconds = 0 },
};

pub const File = struct {
    entry: disk_fat.Entry,

    /// **A FILE REMEMBERS ITS PATH**, because a write here names a path rather
    /// than holding a descriptor: there are no open files on this machine, only
    /// a volume and a directory walk.
    path: [max_path]u8 = undefined,
    path_len: usize = 0,

    /// at is the ONLY way a File is made, so none can exist without its path.
    /// openFile once built one without it, and every positional read through
    /// that handle would have looked up the empty path.
    fn at(entry: disk_fat.Entry, path: []const u8) Error!File {
        if (path.len > max_path) return Error.NameTooLong;
        var f = File{ .entry = entry, .path_len = path.len };
        @memcpy(f.path[0..path.len], path);
        return f;
    }

    pub fn close(_: File, _: Self) void {}

    pub fn stat(self: File, _: Self) Error!Stat {
        return .{
            .size = self.entry.size,
            .kind = if (self.entry.isDirectory()) .directory else .file,
            .mtime = .{ .nanoseconds = @as(i96, self.entry.mtime_unix) * 1_000_000_000 },
        };
    }

    /// Reads until `buffer` is full or the file ends, starting at `offset`, and
    /// answers how many bytes that was — std's `File.readPositionalAll`, which
    /// chat_upload calls to serve a picture whole (a plain GET) or a slice of a
    /// video (a Range request).
    ///
    /// It re-opens by PATH rather than trusting the entry captured at open: an
    /// append since then has moved the size, and a read must see it.
    ///
    /// **A WHOLE-FILE READ BRINGS THE FILE IN** (QUEUE.md item 102, picture
    /// lever 1), exactly as `readFileAlloc` does: a picture served by a plain
    /// GET (offset 0, the buffer holding all of it) is kept, so the next GET of
    /// it is served from memory, not read whole from the disk again — the one
    /// stall item 90 left (a big picture at 30-39 MB/s on each request). A Range
    /// read does not keep the file: it is a seek into a video (offset past the
    /// start, or a buffer too small to have held the whole file), and a video is
    /// past `largest` anyway. Keeping obeys `largest`, so a picture over the cap
    /// is read from the disk as before.
    pub fn readPositionalAll(self: File, _: Self, buffer: []u8, offset: u64) Error!usize {
        const path = self.path[0..self.path_len];
        const pc = pagesFor(path);
        if (pc) |c| if (c.get(path)) |kept| {
            if (offset >= kept.len) return 0;
            const n = @min(buffer.len, kept.len - @as(usize, @intCast(offset)));
            @memcpy(buffer[0..n], kept[@intCast(offset)..][0..n]);
            return n;
        };
        const v = try reading(path);
        const e = try openEntry(v, path);
        if (e.isDirectory()) return Error.IsDir;
        if (offset >= e.size) return 0;
        const n = v.readAt(e, @intCast(offset), buffer) catch return Error.ReadFailed;
        if (pc) |c| if (offset == 0 and n == e.size) c.put(path, buffer[0..n]);
        return n;
    }

    /// **THE APPEND.** Every write the application makes that is not a whole
    /// file is this, and always at the end:
    ///
    ///     var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    ///     const st = try file.stat(io);
    ///     try file.writePositionalAll(io, bytes, st.size);
    ///
    /// — a chat message, a game action, an uploaded chunk. `offset` may also be
    /// inside the file (an overwrite); it may not be past the end, because FAT
    /// has no sparse files and the hole would be whatever those clusters last
    /// held. See disk_fat.writeInto.
    pub fn writePositionalAll(self: File, _: Self, bytes: []const u8, offset: u64) Error!void {
        if (offset > 0xFFFF_FFFF) return Error.NoSpaceLeft;
        const path = self.path[0..self.path_len];
        const v = try writing(path);
        const pc = pagesFor(path);
        v.writeInto(path, @intCast(offset), bytes) catch |e| {
            if (try throughFile(v, path)) return Error.NotDir;
            if (pc) |c| c.forget(path);
            return switch (e) {
                error.NotFound => Error.FileNotFound,
                error.BadName => Error.NameTooLong,
                error.Full, error.DirectoryFull, error.TooBig => Error.NoSpaceLeft,
                error.WritesRefused => Error.ReadOnlyFileSystem,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.wrote(path, @intCast(offset), bytes);
    }
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// Walking a directory. The names it hands out point into the iterator, so a
/// caller that wants to keep one copies it -- which is what
/// `std.Io.Dir.Iterator` also requires.
///
/// **A CURSOR, WITH NO CEILING.** This decoded the whole directory up front
/// into 256 slots and stopped the machine past them, which the application
/// reaches: a player may keep 500 game sessions in one folder, and nothing
/// bounds the players (QUEUE.md item 50). It now reads the directory as it is
/// asked (disk_fat's `Lister`), so its size is one sector and one name whatever
/// the directory holds, and a directory that will not read says so at the
/// entry it fails on.
pub const Iterator = struct {
    lister: ?disk_fat.Volume.Lister = null,
    /// **A DIRECTORY THAT CANNOT BE LISTED IS NOT AN EMPTY ONE** (metal-vmm
    /// QUEUE 104). `iterate` cannot answer an error (its shape is std's), so
    /// a volume that is not there, or a directory disk_fat will not walk (an
    /// entry naming a cluster outside the data), is kept here and is what
    /// the first `next` answers.
    failed: ?Error = null,
    /// **THE LONG NAME, NOT THE 8.3 ALIAS.** This stored `e.name` -- the alias
    /// -- and the application read its own directories back in upper case:
    /// chat's topic list came out `GENERAL` instead of `general`, so /chat
    /// resumed to a conversation that does not exist. The alias is an artifact
    /// of how FAT16 stores a name; `text()` is the name the file was created
    /// with, and the name every other operation here matches on.
    name: [disk_fat.max_name]u8 = undefined,

    pub fn next(self: *Iterator, _: Self) Error!?Entry {
        if (self.failed) |e| return e;
        const l = if (self.lister) |*l| l else return null;
        while (true) {
            const e = (l.next() catch return Error.ReadFailed) orelse return null;
            // **"." AND ".." ARE NOT ENTRIES A DIRECTORY ITERATOR RETURNS.**
            // Every FAT16 subdirectory holds them, and `std.Io.Dir.Iterator` on
            // Linux does not report them -- so the application, which recurses
            // into every directory a listing hands it, recursed into "."
            // forever. That is not a hang: it walks the stack past its end,
            // through `.bss` and into the page tables, and the machine
            // triple-faults with nothing in the log. disk_fat.zig's own removeTree
            // already knew this; the knowledge just did not reach the layer
            // that hands names to the application.
            const name = e.text();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            @memcpy(self.name[0..name.len], name);
            return .{ .name = self.name[0..name.len], .kind = if (e.isDirectory()) .directory else .file };
        }
    }
};

/// **THE OPTION STRUCTS ARE std's, FIELD FOR FIELD, FOR THE FIELDS THE
/// APPLICATION WRITES** — with std's defaults. They were `anytype` until the
/// route table was compiled against them, and `anytype` fails twice over:
///
///   - a literal with no result type cannot hold `@enumFromInt(0o600)` or a
///     decl literal, so `users.zig`'s api-key write did not compile; and
///   - a default has to be CHOSEN, and this file chose wrong: createFile
///     treated a missing `.truncate` as false, where std's default is true. No
///     call in the application omits it today, so nothing was corrupted — but
///     `createFile(io, p, .{})` would have kept old bytes here and emptied the
///     file on Linux.
///
/// A field the application does not use is left out on purpose: writing one is
/// then a compile error here, rather than an option quietly ignored.
pub const OpenOptions = struct {
    iterate: bool = false,
};

pub const Mode = enum { read_only, write_only, read_write };

pub const OpenFileOptions = struct {
    mode: Mode = .read_only,
};

/// FAT16 has no permission bits. The value is accepted so the application's
/// `@enumFromInt(0o600)` on the password and api-key files compiles, and it is
/// IGNORED — there is no other process here to read those files.
pub const Permissions = enum(u32) {
    default_file = 0o666,
    _,
};

pub const CreateFileOptions = struct {
    truncate: bool = true,
    permissions: Permissions = .default_file,
    /// Refuse a file that is there (PathAlreadyExists), as std.Io's does:
    /// webbox's `store.createNew`, a new site's first secret. One task runs
    /// here, so asking and then making cannot be overtaken.
    exclusive: bool = false,
};

pub const WriteFileOptions = struct {
    sub_path: []const u8,
    data: []const u8,
    flags: CreateFileOptions = .{},
};

pub const StatFileOptions = struct {};
pub const AccessOptions = struct {};

/// Whether a path names something on its volume. Absent is an answer; a disk
/// that would not say is an error, never taken for absent.
fn present(v: *disk_fat.Volume, sub_path: []const u8) Error!bool {
    _ = openEntry(v, sub_path) catch |e| switch (e) {
        Error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

pub const Dir = struct {
    /// The cluster this directory starts at; zero is the root.
    cluster: disk_fat.Cluster = 0,
    /// The volume it is on, which is where `iterate` lists it.
    place: Place = .site,

    pub fn cwd() Dir {
        return .{ .cluster = 0 };
    }

    pub fn close(_: Dir, _: Self) void {}

    /// **EVERY PATH HERE IS FROM THE ROOT**, whatever `Dir` it is asked of:
    /// the application spells every call `Io.Dir.cwd().…`, and uses a `Dir`
    /// it opened only to `iterate` it. A path asked of any other `Dir` would
    /// be resolved from the root of whichever disk its first directory names
    /// — the wrong file, perhaps on the wrong disk — so it stops the machine
    /// instead, saying why.
    fn fromRoot(self: Dir) void {
        if (self.cluster != 0 or self.place != .site)
            @panic("a path was asked of a Dir opened below the root; on this machine only cwd() resolves paths");
    }

    pub fn openDir(self: Dir, _: Self, sub_path: []const u8, _: OpenOptions) Error!Dir {
        self.fromRoot();
        const place = placeOf(sub_path) orelse return Error.FileNotFound;
        const v = try volumeAt(place);
        const e = try openEntry(v, sub_path);
        if (!e.isDirectory()) return Error.NotDir;
        return .{ .cluster = e.first_cluster, .place = place };
    }

    pub fn openFile(self: Dir, _: Self, sub_path: []const u8, _: OpenFileOptions) Error!File {
        self.fromRoot();
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        if (e.isDirectory()) return Error.IsDir;
        return File.at(e, sub_path);
    }

    pub fn statFile(self: Dir, _: Self, sub_path: []const u8, _: StatFileOptions) Error!Stat {
        self.fromRoot();
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        return .{
            .size = e.size,
            .kind = if (e.isDirectory()) .directory else .file,
            .mtime = .{ .nanoseconds = @as(i96, e.mtime_unix) * 1_000_000_000 },
        };
    }

    pub fn access(self: Dir, ignored: Self, sub_path: []const u8, _: AccessOptions) Error!void {
        _ = try self.statFile(ignored, sub_path, .{});
    }

    /// The call the application makes 42 times. The bytes are allocated from
    /// `gpa` and the caller owns them.
    pub fn readFileAlloc(self: Dir, ignored: Self, sub_path: []const u8, gpa: std.mem.Allocator, limit: Limit) Error![]u8 {
        self.fromRoot();
        _ = ignored;
        const pc = pagesFor(sub_path);
        if (pc) |c| if (c.get(sub_path)) |kept| {
            if (kept.len > @backingInt(limit)) return Error.StreamTooLong;
            const out = gpa.alloc(u8, kept.len) catch return Error.OutOfMemory;
            @memcpy(out, kept);
            return out;
        };
        const keepable = cacheable(sub_path);
        if (keepable) if (io_volumes.site_cache.find(sub_path)) |kept| {
            if (kept.len > @backingInt(limit)) return Error.StreamTooLong;
            const out = gpa.alloc(u8, kept.len) catch return Error.OutOfMemory;
            @memcpy(out, kept);
            io_volumes.site_cache.hits += 1;
            return out;
        };
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        if (e.isDirectory()) return Error.IsDir;
        if (e.size > @backingInt(limit)) return Error.StreamTooLong;

        var out = gpa.alloc(u8, e.size) catch return Error.OutOfMemory;
        // A read that fails gives back what it took (metal-vmm QUEUE 172: the
        // caller, told ReadFailed, had nothing to free), and one short of the
        // entry's size is its own allocation, so the caller frees what it was
        // given.
        errdefer gpa.free(out);
        const n = v.readFile(e, out) catch return Error.ReadFailed;
        if (n != out.len) out = gpa.realloc(out, n) catch return Error.OutOfMemory;
        if (keepable) io_volumes.site_cache.keep(sub_path, out);
        if (pc) |c| if (n == e.size) c.put(sub_path, out);
        return out;
    }

    /// The other half: a whole file, written at once. FAT16 has no journal, so
    /// the directory entry is written after the data -- a machine that stops
    /// mid-write has lost a file rather than corrupted one.
    ///
    /// **THE OPTIONS STRUCT IS THE APPLICATION'S SPELLING**, and std's:
    /// `writeFile(io, .{ .sub_path = p, .data = b })`. This took
    /// `(io, sub_path, bytes)` until the route table was compiled against it,
    /// because the only callers until then were this machine's own probes,
    /// which pass whatever the declaration asks for. That is the same way the
    /// `Io` value, `Limit.limited`, `Clock.now` and `Mutex.lockUncancelable`
    /// were all wrong: self-consistent, and answering a question the
    /// application does not ask.
    ///
    /// `.flags.permissions` is accepted and IGNORED. FAT16 has no permission
    /// bits at all, so a 0o600 on the password file cannot be honoured here —
    /// and the caller must not be told it was. What protects that file on this
    /// machine is that there is no other process to read it.
    pub fn writeFile(self: Dir, _: Self, options: WriteFileOptions) Error!void {
        self.fromRoot();
        // A whole-file write that keeps the old tail is a different operation,
        // and nothing in the application asks for it. Refuse rather than
        // quietly replacing the file anyway.
        if (!options.flags.truncate) @panic("writeFile with .flags.truncate = false is not implemented on this machine");
        const v = try writing(options.sub_path);
        if (options.flags.exclusive and try present(v, options.sub_path)) return Error.PathAlreadyExists;
        const pc = pagesFor(options.sub_path);
        v.writeFile(options.sub_path, options.data) catch |e| {
            if (try throughFile(v, options.sub_path)) return Error.NotDir;
            if (pc) |c| c.forget(options.sub_path);
            return switch (e) {
                error.BadName => Error.NameTooLong,
                error.IsDirectory => Error.IsDir,
                error.Full, error.DirectoryFull => Error.NoSpaceLeft,
                error.WritesRefused => Error.ReadOnlyFileSystem,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.replaced(options.sub_path, options.data);
    }

    /// mkdir -p. The application calls it before nearly every write, because
    /// its stores are directory trees keyed by id and the parent usually does
    /// not exist yet. disk_fat.makePath already walks and creates, so this is a
    /// rename with error translation.
    pub fn createDirPath(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        _ = v.makePath(sub_path) catch |e| {
            // A folder path that runs through a file, or is one, is NotDir,
            // as std.Io's createDirPath answers it on Linux.
            const is_file = if (v.open(sub_path)) |found| !found.isDirectory() else |_| false;
            if (is_file or try throughFile(v, sub_path)) return Error.NotDir;
            switch (e) {
                error.BadName => return Error.NameTooLong,
                error.Full, error.DirectoryFull => return Error.NoSpaceLeft,
                error.WritesRefused => return Error.ReadOnlyFileSystem,
                else => return Error.WriteFailed,
            }
        };
    }

    /// Open-or-create, for the append pattern documented on
    /// `File.writePositionalAll`. `.truncate` is honoured: false keeps what is
    /// there (the only way the application calls it), true empties the file
    /// first.
    ///
    /// The returned File carries the PATH, not a descriptor — see File.
    pub fn createFile(self: Dir, ignored: Self, sub_path: []const u8, opts: CreateFileOptions) Error!File {
        // Checked HERE as well as in File.at: this call has a side effect, and a
        // path too long for a handle must be refused before the file is made.
        if (sub_path.len > max_path) return Error.NameTooLong;
        const v = try writing(sub_path);
        const truncate = opts.truncate;

        // Absent: made. A disk that would not say is an error, never taken
        // for absent: that emptied a file that was there (QUEUE.md item 89).
        const existing: ?disk_fat.Entry = openEntry(v, sub_path) catch |e| switch (e) {
            Error.FileNotFound => null,
            else => return e,
        };
        if (existing) |e| {
            if (e.isDirectory()) return Error.IsDir;
        }
        // Create it, or empty it, when there is nothing to keep. An empty file
        // holds no chain at all; the first append is also its allocation.
        if (existing == null or truncate) {
            try self.writeFile(ignored, .{ .sub_path = sub_path, .data = "" });
        }

        const e = try openEntry(v, sub_path);
        return File.at(e, sub_path);
    }

    /// deleteFile removes one file. The application spells every call
    /// `catch {}` — it is clearing a bookmark or an api-key, and a file that is
    /// already gone is the outcome it wanted.
    pub fn deleteFile(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        if (pagesFor(sub_path)) |c| c.forget(sub_path);
        v.remove(sub_path) catch |e| {
            if (try throughFile(v, sub_path)) return Error.NotDir;
            switch (e) {
                error.NotFound => return Error.FileNotFound,
                // As std.Io answers a directory given to deleteFile.
                error.IsDirectory => return Error.IsDir,
                error.WritesRefused => return Error.ReadOnlyFileSystem,
                else => return Error.WriteFailed,
            }
        };
    }

    /// rename moves a file to another name in the same directory, over any
    /// file of that name: how angry-gopher's `store.replace` makes a rewrite
    /// survive a stop (disk_fat.rename says what each stop leaves). std.Io's
    /// shape, `io` last; both paths from the root, on one volume, in one
    /// directory.
    pub fn rename(self: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, _: Self) Error!void {
        self.fromRoot();
        new_dir.fromRoot();
        const v = try writing(old_sub_path);
        if (try writing(new_sub_path) != v) return Error.WriteFailed;
        const pc = pagesFor(old_sub_path) orelse pagesFor(new_sub_path);
        v.rename(old_sub_path, new_sub_path) catch |e| {
            if (pc) |c| {
                c.forget(old_sub_path);
                c.forget(new_sub_path);
            }
            return switch (e) {
                error.NotFound => Error.FileNotFound,
                error.IsDirectory => Error.IsDir,
                error.BadName => Error.NameTooLong,
                error.Full, error.DirectoryFull => Error.NoSpaceLeft,
                error.WritesRefused => Error.ReadOnlyFileSystem,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.renamed(old_sub_path, new_sub_path);
    }

    /// renamePreserve is `rename` that refuses a name that is there
    /// (PathAlreadyExists), leaving both files as they were: webbox's
    /// `store.createNew`, which must not replace a secret another start
    /// made. One task runs here, so asking and then renaming cannot be
    /// overtaken.
    pub fn renamePreserve(self: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, ignored: Self) Error!void {
        new_dir.fromRoot();
        if (try present(try writing(new_sub_path), new_sub_path)) return Error.PathAlreadyExists;
        return self.rename(old_sub_path, new_dir, new_sub_path, ignored);
    }

    /// deleteTree removes a directory and everything under it — a released
    /// account's game data, a deleted player. See disk_fat.removeTree for why it
    /// re-lists each round instead of walking a snapshot.
    pub fn deleteTree(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        if (pagesFor(sub_path)) |c| c.forgetTree(sub_path);
        // A tree that is not there is gone already; one through a file is
        // NotDir, as std.Io's deleteTree answers on Linux.
        if (try throughFile(v, sub_path)) return Error.NotDir;
        v.removeTree(sub_path) catch |e| return if (e == error.WritesRefused) Error.ReadOnlyFileSystem else Error.WriteFailed;
    }

    /// This directory, a cursor over it: see `Iterator`. A directory whose
    /// first sector cannot be found answers empty, which is what `list`
    /// always did for a cluster it cannot follow; one that fails later says
    /// so at that entry.
    ///
    /// **NO `io` HERE**, because std's `Dir.iterate()` takes none and the
    /// application calls it bare: `var it = dir.iterate();`. The io arrives one
    /// level down, at `it.next(io)`. This took one until the route table was
    /// compiled against it — the same way `writeFile`'s options struct and the
    /// four shapes in a1c2492 were all wrong, and for the same reason: the only
    /// callers were this machine's own probes.
    ///
    /// `cwd().iterate()` lists the boot disk's root, so with a volume attached
    /// `data` and `auth` are not in it. The application never lists the root.
    ///
    /// **EVERY DIRECTORY WALK CHECKS THAT THERE IS STACK LEFT.** The
    /// application recurses through the trees it lists -- the admin roster sums
    /// a player's disk usage that way -- and how deep a tree goes is data, not
    /// code. On Linux a guard page turns that into a clean SIGSEGV; here there
    /// is no guard page and no fault handler, so the alternative to saying so
    /// is a silent reset. This is the chokepoint because every level of every
    /// such walk passes through it, and the check costs one comparison.
    pub fn iterate(self: Dir) Iterator {
        if (stack.nearTheEnd())
            serial.fail("a directory walk has recursed to within the stack's guard: the tree is deeper than this machine can walk");
        const v = volumeAt(self.place) catch |e| return .{ .failed = e };
        return .{ .lister = v.lister(self.cluster) catch return .{ .failed = Error.ReadFailed } };
    }
};

// ---- time ----------------------------------------------------------------

/// **THE RATE IS MEASURED, AND THERE IS NO DEFAULT.** The timestamp counter
/// moves forward and never goes back, which is what a timeout needs; its rate
/// is the CPU's and has to be measured against something whose rate is known
/// (pit.zig). This used to ASSUME two gigahertz. On this box the TSC runs at
/// 2,494 MHz, so every duration ran 25% fast. A host now passes the measured
/// rate, and asking for any clock before it has panics.
var tsc_hz: u64 = 0;
var tsc_base: u64 = 0;

const clock_unset_msg = "Io.Clock.now before startClock(tsc_hz): this machine does not know how fast its timestamp counter runs";

pub fn startClock(measured_tsc_hz: u64) void {
    tsc_hz = measured_tsc_hz;
    tsc_base = tsc.read();
}

pub fn clockIsStarted() bool {
    return tsc_hz != 0;
}

/// Nanoseconds since `startClock`, or null if this machine has not measured its
/// timestamp counter yet.
///
/// **UNLIKE `Clock.now`, THIS DOES NOT PANIC.** A deadline is something code
/// may reasonably ask about before deciding whether it can have one — and the
/// answer "this machine cannot measure a duration yet" is a fact, not a fault.
/// Session expiry is a different matter, which is why `.real` still panics.
pub fn awakeNs() ?i96 {
    if (tsc_hz == 0) return null;
    return sinceBoot();
}

/// Nanoseconds between two TSC readings, at the measured rate. Public so a host
/// can turn a tick count it kept — the block device's, say — into a duration.
pub fn ticksToNs(ticks: u64) i96 {
    if (tsc_hz == 0) @panic(clock_unset_msg);
    return @intCast(@divTrunc(@as(i128, ticks) * 1_000_000_000, @as(i128, tsc_hz)));
}

/// **THE TSC VALUE AT `awake_ns` ON THE AWAKE CLOCK** (sleep.zig): a rest's
/// deadline, counted from the boot's base, rounded up, never 0.
pub fn tscAt(awake_ns: i96) u64 {
    if (tsc_hz == 0) @panic(clock_unset_msg);
    return sleep.deadlineTicks(tsc_base, tsc_hz, awake_ns);
}

/// Whether a volume has writes not yet flushed: the machine does not sleep
/// on them (sleep.zig's `Facts.unflushed`).
pub fn unflushed() bool {
    for ([_]?disk_fat.Volume{ io_volumes.site, io_volumes.data }) |maybe| {
        const v = maybe orelse continue;
        if (v.blk.unflushed) return true;
    }
    return false;
}

/// sinceBoot is nanoseconds since startClock().
fn sinceBoot() i96 {
    return ticksToNs(tsc.read() -% tsc_base);
}

/// **THE WALL CLOCK IS NOT SINCE-BOOT, AND IT REFUSES TO PRETEND.**
///
/// Nine places in the application ask for `Clock.now(.real, io)` — creation
/// times, last-seen, presence, and `users.zig`'s SESSION EXPIRY, which checks
/// `now - issued > max_age`. This clock used to answer every clock with time
/// since boot. With `now` a few seconds and `issued` a Unix time near 1.8e9,
/// that difference is enormously negative, so every session cookie — however
/// old — would have been accepted forever.
///
/// So `.real` needs to be TOLD: a host calls `setRealTime` once, with Unix
/// seconds from somewhere that knows them, and `.real` is that plus the time
/// since. Asking before anyone has told it panics, naming the fix, for the same
/// reason mem_meter does: a wrong answer here is silent and a panic is not.
var real_base_ns: ?i96 = null;
var real_set_at: i96 = 0;

const real_unset_msg = "Io.Clock.now(.real) before setRealTime(): this machine does not know the wall-clock time, and answering with time-since-boot would silently disable session expiry";

pub fn setRealTime(unix_seconds: i64) void {
    setRealTimeAt(unix_seconds, tsc.read());
}

/// setRealTimeAt says the wall clock read `unix_seconds` at the moment the TSC
/// read `at_tsc`. A host that waited for the RTC's seconds to tick over passes
/// the TSC it captured AT that edge, so the anchor is as exact as the polling
/// rather than up to a second late.
pub fn setRealTimeAt(unix_seconds: i64, at_tsc: u64) void {
    real_set_at = ticksToNs(at_tsc -% tsc_base);
    real_base_ns = @as(i96, unix_seconds) * 1_000_000_000;
}

pub fn realTimeIsSet() bool {
    return real_base_ns != null;
}

/// Timestamp is std's `Io.Timestamp`: what `Clock.now` answers and what
/// `Stat.mtime` holds. A struct, because the application reads
/// `.now(.real, io).nanoseconds`.
pub const Timestamp = struct { nanoseconds: i96 };

/// Duration is std's `Io.Duration`, with the one constructor the application
/// uses (chat's bus: a keepalive in seconds).
pub const Duration = struct {
    nanoseconds: i96,

    pub fn fromSeconds(s: i64) Duration {
        return .{ .nanoseconds = @as(i96, s) * 1_000_000_000 };
    }
};

/// Clock is std's `Io.Clock`: an ENUM, so `Io.Clock.now(.real, io)` passes the
/// clock as a value. It was a struct with a `now(anytype, …)` until the route
/// table was compiled against it, and a struct cannot give `.fromSeconds(…)`
/// inside a timeout literal a type to resolve against.
///
/// One core and one process: `.awake`, `.boot`, `.cpu_process` and
/// `.cpu_thread` are all time since startClock(). Only `.real` differs.
pub const Clock = enum {
    real,
    awake,
    boot,
    cpu_process,
    cpu_thread,

    pub fn now(clock: Clock, _: Self) Self.Timestamp {
        return switch (clock) {
            .real => .{ .nanoseconds = (real_base_ns orelse @panic(real_unset_msg)) + (sinceBoot() - real_set_at) },
            .awake, .boot, .cpu_process, .cpu_thread => .{ .nanoseconds = sinceBoot() },
        };
    }

    pub const Duration = struct { raw: Self.Duration, clock: Clock };
    pub const Timestamp = struct { raw: Self.Timestamp, clock: Clock };
};

/// Timeout is std's `Io.Timeout`, so the application's literal
/// `.{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } }` has a type.
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,
    deadline: Clock.Timestamp,
};

/// **THIS MACHINE HAS NO THREADS, AND DOES NOT WANT ANY.**
///
/// A large share of `std.Io`'s 117 entries are the concurrency family -- async,
/// concurrent, await, cancel, four more for groups, three futex operations,
/// batching, and cancellation plumbing threaded through everything else. None
/// of it applies here. One core, no preemption, one connection at a time.
///
/// So "run this concurrently" becomes "run this now", which is not a
/// compromise: on a single core with no preemption there is no overlap to
/// lose. The application is already built for it -- its accept loop is
/// single-threaded by its own comment, and it already falls back to serving
/// inline when its task pool is exhausted, so this is the path it takes on a
/// busy Linux box too.
///
/// The one thing this cannot do is hold several connections open at once,
/// which is what chat's SSE needs. That is the stage this was always going to
/// be deferred to, and it wants a scheduler rather than threads.
pub const Group = struct {
    pub const init = Group{};

    pub fn concurrent(_: *Group, ignored: Self, comptime f: anytype, args: anytype) error{}!void {
        _ = ignored;
        @call(.auto, f, args);
    }

    pub fn async(_: *Group, ignored: Self, comptime f: anytype, args: anytype) error{}!void {
        _ = ignored;
        @call(.auto, f, args);
    }

    pub fn wait(_: *Group, _: Self) void {}
    pub fn cancel(_: *Group, _: Self) void {}
};

/// **THE FUTEX IS THE WAKEUP EDGE, AND THERE IS NOTHING TO WAKE.**
///
/// chat's bus (bus.zig) publishes to subscribers and wakes them through a futex
/// on a sequence counter. One core with no preemption has no other task blocked
/// on that counter: whatever would have been woken is the very code that called
/// wake, further down its own stack. So the wake is a no-op and the wait returns
/// at once — which is the honest answer, not a shortcut. A wait that actually
/// blocked here would block the machine.
///
/// When SSE arrives this is the first thing that has to change, and it changes
/// into an event loop rather than a thread.
pub fn futexWake(_: Self, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void {
    _ = ptr;
    _ = max_waiters;
}

/// Answers at once, with std's error set so the caller's `catch {}` compiles.
/// It never reports Canceled: nothing here cancels.
pub fn futexWaitTimeout(_: Self, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: Timeout) error{Canceled}!void {
    _ = ptr;
    _ = expected;
    _ = timeout;
}

/// **A MUTEX HERE IS FREE, AND IT CHECKS THAT IT IS ENTITLED TO BE.**
///
/// The application holds ten of these. They exist because Linux threads
/// interleave; one core with no preemption and an explicit event loop cannot
/// interleave, so every one of them costs nothing.
///
/// The temptation is to delete the calls from the application. That is worse
/// than keeping them, for two reasons.
///
/// **They carry information we would have to rediscover.** Each lock marks a
/// critical section somebody identified. When SSE arrives, concurrency comes
/// back -- not as threads, but as several connections interleaved in one event
/// loop, which is exactly when those sections matter again. Deleting the calls
/// throws away the map and leaves the territory.
///
/// **And a lock that quietly does nothing is a lie.** So this one is not
/// quiet: it records that it is held, and a second lock without an unlock is a
/// genuine re-entrancy that would deadlock on Linux. On this machine it cannot
/// happen -- so if it does, the assumption this whole design rests on is
/// wrong, and the machine says so instead of carrying on.
pub const Mutex = struct {
    held: bool = false,

    pub const init = Mutex{};

    /// lockUncancelable is std's name for "take it, and do not let a cancelled
    /// task abandon it half-held". With no threads and no cancellation there is
    /// nothing to distinguish, so it is `lock` — but the application calls it by
    /// this name at every read-add-write counter, so the name has to be here.
    pub fn lockUncancelable(self: *Mutex, io_: Self) void {
        self.lock(io_);
    }

    pub fn lock(self: *Mutex, _: Self) void {
        if (self.held) {
            serial.fail("a mutex was locked twice without being unlocked: this machine has no preemption, so that is re-entrancy, and on a threaded host it would be a deadlock");
        }
        self.held = true;
    }

    pub fn unlock(self: *Mutex, _: Self) void {
        self.held = false;
    }
};
