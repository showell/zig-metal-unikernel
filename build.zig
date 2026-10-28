// zig-metal-unikernel's kernels. Everything here targets x86_64-freestanding: no OS,
// no libc, no syscalls. A kernel is one root file over src/, linked with
// probe/link.ld and booted by QEMU through the PVH note it carries.
//
//   zig build kernels   every probe kernel into probe/ (`zig build --help` lists each)
//   zig build gopher    the real server, from angry-gopher's checkout
const std = @import("std");

/// A kernel's root module: bare metal, no red zone, and **ONE THREAD, AND
/// THERE WILL NOT BE ANOTHER.** A freestanding target is not single-threaded
/// by default, so without it std keeps the threaded lowerings (real atomic
/// instructions, thread-local storage) for a machine that has one core, no
/// preemption and no scheduler. Saying so is what entitles src/io.zig to
/// stub the whole concurrency family. The built kernels and `check`'s
/// type-checked ones are made here, so the two cannot drift.
fn kernelModule(b: *std.Build, root: std.Build.LazyPath, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = root,
        .target = bareTarget(b),
        .optimize = optimize,
        .sanitize_c = .off,
        .pic = false,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .imports = imports,
    });
}

/// **THE PATCHED compiler_rt IS FOR ZIG 0.17.0 ONLY** (compiler_rt_0_17_0/README.md).
/// 0.17.0's own compiler_rt does not compile for this soft-float target
/// (ziglang/zig#37006), so every kernel links the patched copy instead.
/// Under any other Zig the build stops: the copy must go, and the stock
/// compiler_rt be judged again, before this builds.
const patched_runtime_zig: std.SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };

fn requirePatchedRuntimeZig() void {
    const running = @import("builtin").zig_version;
    if (running.order(patched_runtime_zig) == .eq) return;
    std.process.fatal("zig-metal-unikernel links compiler_rt_0_17_0/, a patched compiler_rt for Zig 0.17.0 only, and this is Zig {f}: delete compiler_rt_0_17_0/ and linkPatchedRuntime (build.zig), build the kernels with Zig's stock compiler_rt, and judge them (the metal gate); see compiler_rt_0_17_0/README.md", .{running});
}

/// `exe` linked with compiler_rt_0_17_0/ in place of Zig's own compiler_rt;
/// `kb` is this repo's builder (an application's kernel is made from its
/// build, with this repo a dependency).
fn linkPatchedRuntime(b: *std.Build, kb: *std.Build, exe: *std.Build.Step.Compile) void {
    requirePatchedRuntimeZig();
    exe.bundle_compiler_rt = false;
    // As Zig builds its own: optimized whatever the kernel's mode, no stack
    // probes or builtins (its memcpy must not call memcpy), and the
    // kernel's code model.
    const rt = b.addObject(.{ .name = "compiler_rt", .root_module = b.createModule(.{
        .root_source_file = kb.path("compiler_rt_0_17_0/lib/compiler_rt.zig"),
        .target = bareTarget(b),
        .optimize = .fast,
        .strip = true,
        .stack_check = false,
        .no_builtin = true,
        .pic = false,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
    }) });
    rt.bundle_compiler_rt = false;
    rt.use_llvm = true;
    exe.root_module.addObject(rt);
}

/// The one target: a 64-bit machine with no operating system, and no SSE in
/// the kernel's own code (soft float, no SIMD), because the kernel saves no
/// SSE state on an interrupt or a switch: compiled for SSE, it would reach
/// for xmm registers in memcpy unless told not to. **SSE is enabled all the
/// same** (boot.zig sets CR4's OSFXSR and OSXMMEXCPT), so a linked object
/// built for x86-64's baseline (SSE2, no AVX) runs: Dog Park's physics,
/// compiled by Roc for its `x64v1elf` target; with the bits clear, its first
/// SSE instruction is an invalid-opcode fault. Saving no state holds while
/// that physics, run inside one handler at a time, is the only code that
/// touches an SSE register.
fn bareTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .sse, .sse2, .avx, .avx2 }),
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
    });
}

/// The plants (src/plant.zig): one at most, by `-Dplant=<name>`.
const Plant = enum { none, disk_write_swallowed, net_goback_byte, counted_leak_short, client_ack_off_by_one };

pub fn build(b: *std.Build) void {
    requirePatchedRuntimeZig();
    // **NOT Debug.** A Debug build pulls in zig's UBSan runtime, which wants
    // 128-bit float conversions and therefore the SSE registers this target has
    // switched off. ReleaseSafe keeps the bounds checks and leaves that out.
    //
    // **`-Ddev` IS FOR ITERATING.** Debug with the C sanitizer off — nothing
    // here is C — builds in a fraction of ReleaseSafe's time, with Debug's
    // safety checks. Commits are judged on ReleaseSafe.
    const dev = b.option(bool, "dev", "Debug kernels, for a fast rebuild while iterating") orelse false;
    const optimize: std.builtin.OptimizeMode = if (dev) .debug else .safe;
    const copy = b.addUpdateSourceFiles();

    // One module for everything under src/, so a type from virtio.zig is the
    // same type wherever it is used.
    // **NO RED ZONE.** x86-64 code may keep a function's scratch in the 128
    // bytes below the stack pointer, and an interrupt pushes its frame exactly
    // there. src/interrupts.zig takes interrupts only inside `rest`, but a
    // kernel that takes them at all must not be compiled to assume nothing
    // writes below its stack.
    // **THE COVERAGE SDK** (github.com/showell/zig-coverage-sdk; a sibling
    // checkout, build.zig.zon): `always`/`sometimes` properties of a whole run
    // (COVERAGE.md). No red zone, as for the kernel's own code: it runs inside
    // the kernel too. **THE CATALOG** is its scanner's reading of the files
    // below, so an assertion in code nothing calls is still reported; every
    // module that compiles one of them imports both.
    const sdk = b.dependency("zig_coverage_sdk", .{});
    pinnedSdk(b, rootOf(sdk.builder));
    const coverage = sdk.module("coverage");
    coverage.red_zone = false;
    // The seed explorer (zig-coverage-sdk's explore.zig): simulators only.
    const explore = sdk.module("explore");
    const coverage_catalog = @import("zig_coverage_sdk").addCatalog(b, sdk.artifact("coverage-scan"), coverage, b.path("src"), catalogFiles(b));
    // **ONE PLANT AT MOST** (src/plant.zig): every compilation that holds
    // disk_fat.zig or tcp.zig takes it beside the coverage SDK.
    const plant_opts = b.addOptions();
    const plant = b.option(Plant, "plant", "a deliberate bug the judge must catch, for metal-vmm's plants.sh (src/plant.zig); needs -Dcoverage in gopher.elf") orelse .none;
    plant_opts.addOption(Plant, "plant", plant);
    const plant_options = plant_opts.createModule();
    const with_coverage = [_]std.Build.Module.Import{
        .{ .name = "coverage", .module = coverage },
        .{ .name = "plant_options", .module = plant_options },
        .{ .name = "coverage_catalog", .module = coverage_catalog },
    };
    const metal = b.addModule("metal", .{
        .root_source_file = b.path("src/metal.zig"),
        .red_zone = false,
        .imports = &with_coverage,
    });

    // `cache_fat` builds the same probe with the FAT held in memory, so one
    // source judges both paths — and run.sh can require the two to leave
    // byte-identical volumes.
    const kernels = [_]struct { name: []const u8, root: []const u8, step: []const u8, help: []const u8, cache_fat: bool = false }{
        .{ .name = "block.elf", .root = "probe/block.zig", .step = "block", .help = "the virtio-blk probe kernel" },
        .{ .name = "stdio.elf", .root = "probe/stdio.zig", .step = "stdio", .help = "std.Io.Dir over FAT16" },
        .{ .name = "vfat.elf", .root = "probe/vfat.zig", .step = "vfat", .help = "long names and subdirectories, judged by fsck.vfat" },
        .{ .name = "append.elf", .root = "probe/append.zig", .step = "append", .help = "the append the application makes, judged by fsck.vfat and Linux" },
        .{ .name = "replace.elf", .root = "probe/replace.zig", .step = "replace", .help = "replace, delete and delete-tree, in a fragmented directory" },
        .{ .name = "replace_cached.elf", .root = "probe/replace.zig", .step = "replace_cached", .help = "the same, with the FAT held in memory", .cache_fat = true },
        .{ .name = "restore.elf", .root = "probe/restore.zig", .step = "restore", .help = "reading a volume Linux wrote" },
        .{ .name = "clock.elf", .root = "probe/clock.zig", .step = "clock", .help = "the clocks, and .real once it is told" },
        .{ .name = "realunset.elf", .root = "probe/realunset.zig", .step = "realunset", .help = "MUST PANIC: .real before anyone set it" },
        .{ .name = "memory.elf", .root = "probe/memory.zig", .step = "memory", .help = "the machine's RAM, discovered and handed out" },
        .{ .name = "rng.elf", .root = "probe/rng.zig", .step = "rng", .help = "entropy from virtio-rng and RDRAND" },
        .{ .name = "net.elf", .root = "probe/net.zig", .step = "net", .help = "the virtio-net and DHCP probe kernel" },
        .{ .name = "http.elf", .root = "probe/http.zig", .step = "http", .help = "the one-request web server probe kernel" },
        .{ .name = "fetch.elf", .root = "probe/fetch.zig", .step = "fetch", .help = "the client kernel: one GET with tcp.zig's connect, its outcome the exit code (metal-vmm QUEUE 225)" },
        .{ .name = "ladder.elf", .root = "probe/ladder.zig", .step = "ladder", .help = "one operation many times, at a flat cost" },
        .{ .name = "stdhttp.elf", .root = "probe/stdhttp.zig", .step = "stdhttp", .help = "the same, but with zig's own std.http.Server" },
        .{ .name = "backoff.elf", .root = "probe/backoff.zig", .step = "backoff", .help = "the restart end to end: four restarts, then the back-off (RESTART.md)" },
        .{ .name = "restart.elf", .root = "probe/restart.zig", .step = "restart", .help = "what each way of restarting keeps (RESTART.md)" },
        .{ .name = "hello.elf", .root = "droplet/hello.zig", .step = "hello", .help = "for a real droplet: both cards, every request, forever" },
    };

    // **THE REAL SERVER**, compiled from angry-gopher's checkout as it is
    // (Phase B step 2b: no copy): this repo holds the machine, not the code
    // it serves. -Dgopher-root=<dir> names another checkout.
    const gopher_root = b.option([]const u8, "gopher-root", "the angry-gopher checkout") orelse
        pathFromRoot(b, "../angry-gopher");
    const gopher_src = b.fmt("{s}/zig-server/src", .{gopher_root});
    // **THE LIBRARY**, webbox, from its own checkout (zig-webbox): the kernel
    // compiles its sources with this machine's `host_io`. -Dwebbox-root=<dir>
    // names another checkout.
    const webbox_root = b.option([]const u8, "webbox-root", "the zig-webbox checkout") orelse
        pathFromRoot(b, "../zig-webbox");
    const webbox_src = b.fmt("{s}/src", .{webbox_root});
    // **SHALE**, the script language an application runs on its own data,
    // from its own checkout (shale), compiled as webbox is, with this
    // machine's `host_io`. -Dshale-root=<dir> names another checkout.
    const shale_root = b.option([]const u8, "shale-root", "the shale checkout") orelse
        pathFromRoot(b, "../shale");
    // **CODEX CHAT**, cobble-webbox's `codex_chat`, which angry-gopher serves
    // under /codex-chat, from its own checkout, compiled as webbox is, with
    // this machine's `host_io`. -Dcobble-root=<dir> names another checkout.
    const cobble_root = b.option([]const u8, "cobble-root", "the cobble-webbox checkout") orelse
        pathFromRoot(b, "../cobble-webbox");
    // **THE CHAT'S MARKDOWN AND ITS BROWSER CLIENT**, each its own checkout
    // (chat-markdown, chat-client), which angry-gopher's chat imports as
    // `chat_markdown` and `chat_client`: nothing but std, compiled as they
    // are. -Dchat-markdown-root=<dir> and -Dchat-client-root=<dir> name
    // others.
    const markdown_root = b.option([]const u8, "chat-markdown-root", "the chat-markdown checkout") orelse
        pathFromRoot(b, "../chat-markdown");
    const client_root = b.option([]const u8, "chat-client-root", "the chat-client checkout") orelse
        pathFromRoot(b, "../chat-client");

    const all = b.step("kernels", "every kernel");
    for (kernels) |k| {
        const probe_opts = b.addOptions();
        probe_opts.addOption(bool, "cache_fat", k.cache_fat);
        const exe = b.addExecutable(.{ .name = k.name, .root_module = kernelModule(b, b.path(k.root), optimize, &.{
            .{ .name = "metal", .module = metal },
            .{ .name = "probe_options", .module = probe_opts.createModule() },
        }) });
        exe.use_llvm = true;
        linkPatchedRuntime(b, b, exe);
        exe.setLinkerScript(b.path("probe/link.ld"));
        exe.entry = .{ .symbol_name = "_start" };

        const one = b.addUpdateSourceFiles();
        one.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
        b.step(k.step, k.help).dependOn(&one.step);
        all.dependOn(&one.step);
        copy.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
    }

    // The application's own modules, each importing `metal` for its Io.
    //
    // **NOT part of `kernels`**, and not depended on by the install step: this
    // needs angry-gopher's checkout, and a checkout without angry-gopher
    // beside it should still build everything else. `zig build gopher` says
    // plainly what is missing when it is missing.
    // What the application's own build.zig supplies and this one must too: a
    // `build_options` module, and the front-end artifacts each page embeds by
    // name. That table is angry-gopher's zig-server/assets.zon, which its
    // build.zig and this one both read (`servedBy`), so the two cannot drift.
    //
    // **THIS IS THE PART OF THE PORT THAT IS NOT ABOUT THE MACHINE.** The
    // modules compile freestanding unchanged, handed this machine's `host_io`;
    // what is left is build-graph plumbing, and it is the same plumbing on
    // Linux.
    // **THE COMMITS, BAKED IN**, for /version and /admin/host: angry-gopher's
    // (the application's own option, as its ops/deploy sets it on Linux) and
    // this repository's, each marked `+dirty` when its tree had uncommitted
    // changes, so a page never names a commit the machine is not running.
    // **-Dstamp=off STAMPS NEITHER** (Steve, 2026-10-18): both commits read
    // `unstamped`, so two builds of the same code are the same bytes
    // whatever the commits or the trees' state. For comparing executables
    // (a refactor judged, a build reproduced); a stamp of a different length
    // (`+dirty`) moved what followed it. Never deployed: /version would say
    // `unstamped`. dog-park's build passes its own `-Dstamp` here.
    const stamp = b.option(Stamp, "stamp", "on (the default): the commits baked in, for /version; off: `unstamped`, so two builds of the same code are byte-identical") orelse .on;
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "commit", stampOf(b, stamp, gopher_root));
    const gm_opts = b.addOptions();
    gm_opts.addOption([]const u8, "commit", stampOf(b, stamp, pathFromRoot(b, ".")));
    // **ON BY DEFAULT** (RESTART.md): a guest's reset restarts a real
    // droplet, measured 2026-10-03; -Drestart=false halts instead.
    gm_opts.addOption(bool, "restart", b.option(bool, "restart", "gopher.elf restarts on a failure while serving (RESTART.md; measured on a real droplet 2026-10-03); -Drestart=false halts instead") orelse true);
    // **COVERAGE PROPERTIES ON THE SERIAL PORT** (COVERAGE.md): off in
    // anything deployed, where the declarations alone would fill the log
    // ring /admin/host shows. tools/coverage_jsonl.sh lifts them out.
    gm_opts.addOption(bool, "coverage", b.option(bool, "coverage", "gopher.elf writes its coverage-property lines to the serial port") orelse false);
    build_opts.addOption(bool, "fake_leak", false);

    // **THE `webbox` LIBRARY, ITS OWN MODULE**, as the application's build
    // makes it: the application's files import it by name (`@import("webbox")`),
    // never its files by path (angry-gopher's tools/lint_portable.py), so each
    // of its files belongs to one module. Its Linux half (`webbox_linux`) sits
    // beside the rest and is never compiled here: nothing imports it.
    // **`host_io`, THIS MACHINE'S** (src/host_io_metal.zig): the one file the
    // application's sources take their `Io` from, std's on Linux, this
    // machine's here. Nothing in them is rewritten.
    const host_io = b.addModule("host_io", .{
        .root_source_file = b.path("src/host_io_metal.zig"),
        .red_zone = false,
        .imports = &.{.{ .name = "metal", .module = metal }},
    });
    const webbox = b.addModule("webbox", .{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/webbox.zig", .{webbox_src}) },
        .red_zone = false,
        .imports = &.{.{ .name = "host_io", .module = host_io }},
    });
    _ = b.addModule("shale", .{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/shale.zig", .{shale_root}) },
        .red_zone = false,
        .imports = &.{ .{ .name = "host_io", .module = host_io }, .{ .name = "webbox", .module = webbox } },
    });
    // angry-gopher's guests, which its router.zig mounts (webbox's combo):
    // cobble-webbox's Codex Chat and UO town from that checkout, made this
    // machine's as the gopher kernel's `parts`, their pages from
    // cobble-webbox's assets.zon.
    const codex_chat = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/chat_app.zig", .{cobble_root}) } });
    const uo_town = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/uo_app.zig", .{cobble_root}) } });
    const cobble_assets: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/assets.zon", .{cobble_root}) };
    // The kernel's parts every application's kernel shares, exported for
    // `addAppKernel` (a dependent package reaches them through it, not by
    // name): `metal`, `host_io`, `webbox` and `shale` above, and `gm_build`.
    const gm_build = gm_opts.createModule();
    b.modules.put(b.allocator, b.dupe("gm_build"), gm_build) catch @panic("out of memory");
    // **THE APPLICATION, ANY APPLICATION** (Phase B step 4): an application
    // is its root (exporting `site` and `hosting`) and its assets.zon; the
    // kernel around it is probe/gopher.zig for every one. angry-gopher's chat
    // is built here through the same API another repository calls
    // (`addAppKernel`, below).
    const gopher_app = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/router.zig", .{gopher_src}) },
        .imports = &.{
            .{ .name = "build_options", .module = build_opts.createModule() },
            .{ .name = "codex_chat", .module = codex_chat },
            .{ .name = "uo_town", .module = uo_town },
            .{ .name = "chat_markdown", .module = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/markdown.zig", .{markdown_root}) }, .red_zone = false }) },
            .{ .name = "chat_client", .module = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/js/bundles.zig", .{client_root}) }, .red_zone = false }) },
        },
    });
    const gopher = appKernel(b, b, .{
        .name = "gopher.elf",
        .module = gopher_app,
        // assets.zon's embedded paths are relative to zig-server/.
        .assets = .{ .cwd_relative = b.fmt("{s}/zig-server/assets.zon", .{gopher_root}) },
        .optimize = optimize,
        .parts = &.{
            .{ .module = codex_chat, .assets = cobble_assets },
            .{ .module = uo_town, .assets = cobble_assets },
        },
    });
    const gopher_imports = [_]std.Build.Module.Import{
        .{ .name = "metal", .module = metal },
        .{ .name = "app", .module = gopher_app },
        .{ .name = "webbox", .module = webbox },
        .{ .name = "gm_build", .module = gm_build },
    };
    const gopher_copy = b.addUpdateSourceFiles();
    gopher_copy.addCopyFileToSource(gopher.getEmittedBin(), "probe/gopher.elf");
    const gopher_step = b.step("gopher", "the real server, compiled from angry-gopher's checkout as it is now");
    gopher_step.dependOn(&gopher_copy.step);

    // **THE SLEEPER** (probe/sleeper/, docs/designs/DESIGN-sleep.md): an
    // application that only wakes, every `period_ms`, and writes a line
    // each time; the test of a sleeping kernel, through the same API.
    const sleeper = appKernel(b, b, .{
        .name = "sleeper.elf",
        .module = b.createModule(.{ .root_source_file = b.path("probe/sleeper/sleeper.zig") }),
        .assets = b.path("probe/sleeper/assets.zon"),
        .optimize = optimize,
    });
    const sleeper_copy = b.addUpdateSourceFiles();
    sleeper_copy.addCopyFileToSource(sleeper.getEmittedBin(), "probe/sleeper.elf");
    b.step("sleeper", "the sleeper (probe/sleeper/): an application that only wakes, the test of a sleeping kernel").dependOn(&sleeper_copy.step);

    // **EVERY KERNEL TYPE-CHECKED, ON EVERY `zig build test`** (metal-vmm
    // B34): a field renamed in src/ broke gopher.elf (b4463a9) and native
    // (140's Fin) with every unit test green, since no test compiles a
    // kernel. Debug, and no binary asked for, so nothing is generated: only
    // analysis.
    //
    // **ANALYSIS, NOT CODEGEN OR THE LINK.** What only LLVM or the linker
    // sees passes here and fails `zig build kernels`: a symbol named only in
    // an asm string or link.ld (a rename of `pvh_start_info`), a bad
    // mnemonic, an extern nothing defines (a cold review found each). Code
    // behind `builtin.mode != .Debug` is not analyzed either. native and
    // droplet are host programs, and are built and linked whole.
    //
    // gopher.elf needs angry-gopher's checkout, its sources and its
    // assets.zon; without them it is not checked, and the step says so rather than
    // pass in silence.
    const check_step = b.step("check", "type-check this repo's own kernels (analysis only, not codegen or link), and build native and droplet (part of `test`)");
    // **THE APPLICATIONS' KERNELS, A TIER OF THEIR OWN** (metal-vmm QUEUE
    // 197): gopher.elf needs angry-gopher's, zig-webbox's and shale's checkouts, so
    // its check is tier 3's (tier3.sh), never `test`'s: a missing sibling
    // must not fail tier 0.
    const check_apps = b.step("check-apps", "type-check the applications' kernels (gopher.elf), from their checkouts (tier 3)");
    // **EVERY PLANT TYPE-CHECKED** (src/plant.zig): a plant's code is
    // analysed only when it is on, so each is checked by a `check` of its
    // own (and with check-apps, gopher.elf too: `check` is this repo's
    // kernels alone since 197), with -Dcoverage as gopher.elf requires. Run it after touching a
    // plant's lines, and before plants.sh, which does not run it itself.
    const check_plants = b.step("check-plants", "type-check every kernel once with each plant on (src/plant.zig)");
    for (std.enums.values(Plant)) |p| {
        if (p == .none) continue;
        // The same port and checkout as this build's, or gopher.elf is
        // checked against the defaults' (or not at all) for every plant.
        const one = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "check", "check-apps", "-Dcoverage", b.fmt("-Dplant={s}", .{@tagName(p)}), b.fmt("-Dgopher-root={s}", .{gopher_root}), b.fmt("-Dwebbox-root={s}", .{webbox_root}), b.fmt("-Dshale-root={s}", .{shale_root}), b.fmt("-Dcobble-root={s}", .{cobble_root}), b.fmt("-Dchat-markdown-root={s}", .{markdown_root}), b.fmt("-Dchat-client-root={s}", .{client_root}) });
        one.setCwd(b.path("."));
        check_plants.dependOn(&one.step);
    }
    for (kernels) |k| {
        const probe_opts = b.addOptions();
        probe_opts.addOption(bool, "cache_fat", k.cache_fat);
        const exe = b.addExecutable(.{ .name = k.name, .root_module = kernelModule(b, b.path(k.root), .Debug, &.{
            .{ .name = "metal", .module = metal },
            .{ .name = "probe_options", .module = probe_opts.createModule() },
        }) });
        linkPatchedRuntime(b, b, exe);
        check_step.dependOn(&exe.step);
    }
    var port_code: u8 = 0;
    // **ONLY A CHECKOUT THIS BUILD CAN TAKE** (metal-vmm 146(a), Phase B 2b):
    // its sources take their Io from host_io, never std's, and this tree's
    // asset list is its table. tools/verdicts.py says whether it is fresh, as
    // gates.sh asks it, and one not fresh fails the check.
    const port_state: []const u8 = blk: {
        const out = b.runAllowFail(&.{ "env", b.fmt("GOPHER_ROOT={s}", .{gopher_root}), b.fmt("WEBBOX_ROOT={s}", .{webbox_root}), b.fmt("SHALE_CHECKOUT={s}", .{shale_root}), b.fmt("COBBLE_ROOT={s}", .{cobble_root}), b.fmt("CHAT_MARKDOWN_ROOT={s}", .{markdown_root}), b.fmt("CHAT_CLIENT_ROOT={s}", .{client_root}), "python3", pathFromRoot(b, "tools/verdicts.py"), "fresh" }, &port_code, .ignore) catch break :blk "tools/verdicts.py could not be run";
        break :blk std.mem.trim(u8, out, " \t\r\n");
    };
    if (std.mem.eql(u8, port_state, "fresh")) {
        const exe = b.addExecutable(.{ .name = "gopher.elf", .root_module = kernelModule(b, b.path("probe/gopher.zig"), .Debug, &gopher_imports) });
        linkPatchedRuntime(b, b, exe);
        check_apps.dependOn(&exe.step);
    } else {
        // **A KERNEL NOT CHECKED FAILS THE CHECK** (Steve, 2026-10-10: fail,
        // never warn). It printed and passed; a stale port then hid a kernel
        // that did not build (48a167f).
        const fail = b.addFail(b.fmt("check: gopher.elf NOT type-checked: {s} (checkout {s}): -Dgopher-root=<dir> for another checkout", .{ port_state, gopher_root }));
        check_apps.dependOn(&fail.step);
        // **NOR BUILT** (the protocols-in-prose hunt, K10), with
        // probe/gopher.elf left as it was: a kernel of a port that is not
        // the checkout's would be judged as if it were.
        const no_build = b.addFail(b.fmt("gopher: NOT built: {s} (checkout {s}): -Dgopher-root=<dir> for another checkout", .{ port_state, gopher_root }));
        gopher_copy.step.dependOn(&no_build.step);
    }

    b.getInstallStep().dependOn(&copy.step);

    // **THE TCP TABLE ON LINUX.** native/serve.zig runs src/'s network code as
    // an ordinary Debug program behind a TAP device, with Linux's TCP as the
    // peer; native/judge_native.py asks it questions in seconds.
    const netcore = b.createModule(.{
        .root_source_file = b.path("src/netcore.zig"),
        .target = b.graph.host,
        .imports = &with_coverage,
    });
    const serve = b.addExecutable(.{
        .name = "gm-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/serve.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "netcore", .module = netcore }},
        }),
    });
    // native/fetch.zig, the table as a client (metal-vmm QUEUE 225, chunk 8).
    const fetch_native = b.addExecutable(.{
        .name = "gm-fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/fetch.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "netcore", .module = netcore }},
        }),
    });
    const native_step = b.step("native", "the TCP table as a Linux program behind a TAP device: gm-serve, and gm-fetch, its client");
    native_step.dependOn(&b.addInstallArtifact(serve, .{}).step);
    native_step.dependOn(&b.addInstallArtifact(fetch_native, .{}).step);

    // **A DISK A DROPLET CAN BOOT.** droplet/image.zig puts the boot loader
    // and a kernel on a GPT disk; droplet/boot.sh assembles the loader and
    // runs the result on the droplet-shaped QEMU.
    const kernel_partition = b.createModule(.{ .root_source_file = b.path("src/kernel_partition.zig") });
    const image = b.addExecutable(.{
        .name = "gm-image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("droplet/image.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "kernel_partition", .module = kernel_partition }},
        }),
    });
    b.step("droplet", "the disk-image builder for a droplet").dependOn(&b.addInstallArtifact(image, .{}).step);
    check_step.dependOn(&serve.step);
    check_step.dependOn(&fetch_native.step);
    check_step.dependOn(&image.step);

    // **HOST TESTS** for the parts of src/ that are pure — no ports, no
    // virtqueues — and so can run here rather than in a guest. Every mode a
    // device can report in is a way to be silently wrong, and those modes are
    // cheaper to enumerate on the host than to provoke in QEMU.
    const test_step = b.step("test", "host unit tests for the pure parts of src/");
    // One file's tests in seconds, while working on it: the whole step takes
    // minutes. A name that matches none of the files is an error.
    const test_file = b.option([]const u8, "test-file", "run only this file's unit tests (src/io_test.zig)");
    // **THE WHOLE-TREE CHECKS ARE THE WHOLE STEP'S** (metal-vmm 146(b),(c)):
    // every kernel analyzed, the formatter and the machine lint. One file's
    // run (-Dtest-file) skips them, so it is seconds again; -Dcheck=false
    // skips the kernels, for the mutation tools, which judge a mutant by the
    // tests and rebuild every one from nothing.
    const with_check = b.option(bool, "check", "zig build test analyzes every kernel too (default; -Dcheck=false for mutation runs)") orelse true;
    if (test_file == null) {
        if (with_check) test_step.dependOn(check_step);
        // **`zig fmt --check src` IS PART OF THE TESTS**, so src/ stays the
        // way the formatter writes it. It was let slip once (three files,
        // QUEUE.md item 10), and a separate step nobody runs would let it
        // slip again.
        test_step.dependOn(&b.addFmt(.{ .paths = &.{b.path("src")}, .check = true }).step);
        // **ONLY `fire` CHANGES A MACHINE'S STATE** (src/machine.zig): Zig
        // has no private fields, so tools/lint_machine.py is the guard.
        const lint_machine = b.addSystemCommand(&.{ "python3", "tools/lint_machine.py" });
        lint_machine.has_side_effects = true;
        test_step.dependOn(&lint_machine.step);
        // And its own cases: each write it must refuse, refused (147(f)).
        const lint_cases = b.addSystemCommand(&.{ "python3", "tools/lint_machine.py", "--self-test" });
        lint_cases.has_side_effects = true;
        test_step.dependOn(&lint_cases.step);
    }
    var test_file_found = test_file == null;
    // **EACH TEST BINARY'S CPU TIME** (metal-vmm QUEUE 198.12): with
    // -Dtest-cpu-dir, every binary below runs under tools/cpu_time.py, which
    // writes its user and system time there, for tier 0's budget
    // (tools/test_budget.py). Wall time under -j on 2 cores was half
    // contention; CPU time is the test's own.
    test_cpu_dir = b.option([]const u8, "test-cpu-dir", "record each test binary's CPU time in this directory (tier0.sh's budget)");
    // **WHICH LINES OF THE TCP TABLE ITS UNIT TESTS RUN** (`zig build
    // tcp-coverage`): tcp_test.zig at every start below, each run once under
    // the coverage SDK's `linecov`; the lines with code that none of them ran
    // are listed, for each of the table's four files (metal-vmm QUEUE 225,
    // chunk 3a). One run of each binary over all its files (`<files> --
    // <binaries>`), as Shale's script-coverage runs it (metal-vmm QUEUE 243).
    const tcp_files = [_][]const u8{ "src/tcp.zig", "src/tcp_segment.zig", "src/tcp_arrives.zig", "src/tcp_timeouts.zig" };
    const tcp_coverage = lineCoverage(b, sdk, &tcp_files);
    b.step("tcp-coverage", "the lines of the TCP table (tcp.zig and the files split from it) its unit tests never run").dependOn(&tcp_coverage.step);
    // The same for the FAT: disk_fat.zig and disk_fat_dirent.zig, over the
    // merged unit binary (which also runs the simulators and store tests that
    // reach the FAT, so a line only a simulator runs counts as run) and
    // disk_fat_test and the faults and lies binaries.
    // disk_fat.zig is split by the 1,000-line rule (metal-vmm QUEUE 173):
    // each of its files is listed, over the same binaries.
    const fat_files = [_][]const u8{ "src/disk_fat.zig", "src/disk_fat_fat.zig", "src/disk_fat_chain.zig", "src/disk_fat_dir.zig", "src/disk_fat_file.zig", "src/disk_fat_remove.zig", "src/disk_fat_check.zig", "src/disk_fat_dirent.zig" };
    const fat_coverage = lineCoverage(b, sdk, &fat_files);
    b.step("fat-coverage", "the lines of disk_fat.zig, its split files and disk_fat_dirent.zig no host test runs (the unit binary, simulators included, and the FAT test binaries)").dependOn(&fat_coverage.step);
    // **ONE BINARY FOR THE FILES' OWN TESTS** (src/unit_tests.zig, metal-vmm
    // QUEUE 142): one compile of the runner, std and the shared imports,
    // and each file's tests run once, not in every binary that imports it.
    // This list is the authority; unit_tests.zig must import exactly it.
    const unit_files = [_][]const u8{ "src/rtc.zig", "src/pit.zig", "src/gpt.zig", "src/stack.zig", "src/civil.zig", "src/disk_fat.zig", "src/disk_fat_dirent.zig", "src/machine.zig", "src/seq.zig", "src/ring_pieces.zig", "src/pvh.zig", "src/pages.zig", "src/tcp.zig", "src/tcp_check.zig", "src/tcp_sim.zig", "src/tcp_pair_sim.zig", "src/fat_sim.zig", "src/page_sim.zig", "src/pure_sim.zig", "src/ready_sim.zig", "src/durable_sim.zig", "src/durable.zig", "src/scsi_mode.zig", "src/floor_sim.zig", "src/store.zig", "src/store_model.zig", "src/store_test.zig", "src/store_linux.zig", "src/store_sim.zig", "src/scratch_dir.zig", "src/io_test.zig", "src/log_ring.zig", "src/restart.zig", "src/kept_log.zig", "src/ready.zig", "src/drain.zig", "src/drain_sim.zig", "src/request_heap.zig", "src/page_cache.zig", "src/admin_reset.zig", "src/dhcp.zig", "src/screen.zig", "src/serial_gate.zig", "src/net.zig", "src/idle.zig", "src/idle_check.zig", "src/request_line.zig", "src/uploads_seen.zig", "src/device_wait.zig", "src/disk_failures.zig", "src/boot_facts.zig", "src/rest_count.zig", "src/config_text.zig", "src/virtio.zig", "src/serial.zig", "src/after_turn.zig", "src/spill_rule.zig", "src/apic_rule.zig", "src/failed_seeds.zig", "src/tcp_segment.zig", "src/arp.zig", "src/tcp_held.zig", "src/fetch.zig", "src/sleep.zig" };
    comptime {
        @setEvalBranchQuota(1_000_000);
        const root = @embedFile("src/unit_tests.zig");
        // Each import a line of its own, as `zig fmt` leaves it, so one
        // commented out (`// _ = @import(...)`) is not counted.
        if (std.mem.count(u8, root, "\n    _ = @import(") != unit_files.len) @compileError("src/unit_tests.zig imports other than build.zig's unit_files");
        for (unit_files) |path| {
            if (std.mem.indexOf(u8, root, "\n    _ = @import(\"" ++ path["src/".len..] ++ "\");") == null) @compileError("src/unit_tests.zig does not import " ++ path);
        }
    }
    // Outside src/, so not importable from unit_tests.zig: its own binary.
    const own_binary = [_][]const u8{"droplet/image.zig"};
    // **THE ONE BODY RULE** (zig-webbox's body.zig, metal-vmm QUEUE
    // 166): ready.zig takes it as a parameter, which the kernel passes as
    // `webbox.body`. The unit tests take src/pinned/webbox_body.zig, that
    // file byte for byte, so tier 0 needs no zig-webbox checkout (metal-vmm
    // QUEUE 197); `zig build pinned` (tier 3) fails when the two differ.
    const body_rule = b.createModule(.{ .root_source_file = b.path("src/pinned/webbox_body.zig") });
    // `between`'s answer (zig-webbox's wake.zig, DESIGN-sleep.md): sleep.zig
    // takes it as a parameter, which the kernel passes as `webbox.site.Wake`;
    // the unit tests take the pinned copy.
    const wake_rule = b.createModule(.{ .root_source_file = b.path("src/pinned/webbox_wake.zig") });
    const pinned = b.addSystemCommand(&.{ "python3", "tools/pinned.py", webbox_src });
    pinned.has_side_effects = true;
    b.step("pinned", "src/pinned/ against the zig-webbox checkout it was copied from (tier 3)").dependOn(&pinned.step);
    const unit_imports = [_]std.Build.Module.Import{
        .{ .name = "body_rule", .module = body_rule },
        .{ .name = "wake_rule", .module = wake_rule },
        .{ .name = "kernel_partition", .module = kernel_partition },
        .{ .name = "coverage", .module = coverage },
        .{ .name = "plant_options", .module = plant_options },
        .{ .name = "coverage_catalog", .module = coverage_catalog },
        .{ .name = "explore", .module = explore },
    };
    const unit_roots: []const []const u8 = if (test_file) |only| blk: {
        for (unit_files ++ own_binary) |path| if (std.mem.eql(u8, only, path)) break :blk &.{path};
        break :blk &.{};
    } else &(.{"src/unit_tests.zig"} ++ own_binary);
    for (unit_roots) |path| {
        test_file_found = true;
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .imports = &unit_imports,
        }) });
        test_step.dependOn(&runTest(unit, path).step);
        // disk_fat's lines run in the merged binary, or in its own.
        if (std.mem.eql(u8, path, "src/unit_tests.zig") or std.mem.eql(u8, path, "src/disk_fat.zig") or std.mem.eql(u8, path, "src/disk_fat_dirent.zig")) {
            fat_coverage.addArtifactArg(unit);
        }
    }
    // **WHICH LINES OF THE STORE'S ORACLE ITS OWN TESTS RUN** (`zig build
    // store-model-coverage`): store_model.zig's tests alone, not the
    // simulators that lean on it, so the oracle is proven by its own tests
    // before it judges anything else.
    const model_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/store_model.zig"),
        .target = b.graph.host,
        .imports = &unit_imports,
    }) });
    const model_coverage = lineCoverage(b, sdk, &.{"src/store_model.zig"});
    model_coverage.addArtifactArg(model_unit);
    b.step("store-model-coverage", "the lines of store_model.zig its own tests never run").dependOn(&model_coverage.step);
    // The test files built on their own, below.
    for ([_][]const u8{ "src/disk_fat_test.zig", "src/disk_fat_faults_test.zig", "src/tcp_test.zig" }) |path| {
        if (test_file) |only| if (std.mem.eql(u8, only, path)) {
            test_file_found = true;
        };
    }
    if (!test_file_found) @panic("-Dtest-file names no file the unit tests run");

    // **THE STORE PRODUCTION RUNS, JUDGED** (src/store_judge.zig):
    // angry-gopher's store.zig over Linux and, handed this machine's
    // host_io, over this repo's io.zig, against the model. Needs the
    // sibling angry-gopher checkout, so it is a step of its own,
    // not part of `test`, and not yet in gates.sh: its model is still
    // zig-metal-unikernel's Store, not the seam's (STORE.md).
    const judge_world = b.createModule(.{
        .root_source_file = b.path("src/judge_world.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "coverage", .module = coverage },
            .{ .name = "plant_options", .module = plant_options },
            .{ .name = "coverage_catalog", .module = coverage_catalog },
        },
    });
    // The judges' `host_io`: this machine's file, its `metal` the simulated
    // world.
    const judge_host_io = b.createModule(.{
        .root_source_file = b.path("src/host_io_metal.zig"),
        .imports = &.{.{ .name = "metal", .module = judge_world }},
    });
    const store_judge = b.addTest(.{
        .name = "store-judge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_judge.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "judge_world", .module = judge_world },
                .{ .name = "ag_store_linux", .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/store.zig", .{webbox_src}) },
                    .imports = &.{.{ .name = "host_io", .module = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/host_io_std.zig", .{webbox_src}) } }) }},
                }) },
                .{ .name = "ag_store_metal", .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/store.zig", .{webbox_src}) },
                    .imports = &.{.{ .name = "host_io", .module = judge_host_io }},
                }) },
            },
        }),
    });
    b.step("store-judge", "zig-webbox's store on Linux and on metal against the model (needs ../zig-webbox and a port)").dependOn(&b.addRunArtifact(store_judge).step);

    // **WHAT EACH STORE CALL COSTS THE DISK** (src/store_cost.zig, metal-vmm
    // 151): angry-gopher's store over io.zig, the disk requests of each call
    // and of four common requests, by kind and place. A bench, not a gate.
    const store_cost = b.addTest(.{
        .name = "store-cost",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_cost.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "judge_world", .module = judge_world },
                .{ .name = "ag_store_metal", .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/store.zig", .{webbox_src}) },
                    .imports = &.{.{ .name = "host_io", .module = judge_host_io }},
                }) },
            },
        }),
    });
    b.step("store-cost", "the disk requests each store call and four common requests make (needs a port)").dependOn(&b.addRunArtifact(store_cost).step);

    // **THE SEED EXPLORER AGAINST BLIND SEEDS** (src/explore_bench.zig): a
    // tool, not a gate (Steve, 2026-10-07). ReleaseSafe by default: it is
    // nearly all running.
    const explore_opts = b.addOptions();
    explore_opts.addOption([]const u8, "sim", b.option([]const u8, "explore-sim", "which simulator `explore` runs: fat or store") orelse "fat");
    explore_opts.addOption([]const u8, "budgets", b.option([]const u8, "explore-budgets", "comma-separated run budgets `explore` compares at") orelse "20,100");
    explore_opts.addOption(u64, "seed", b.option(u64, "explore-seed", "the explorer's own seed") orelse 1);
    explore_opts.addOption(f32, "blind", b.option(f32, "explore-blind", "the share of the explorer's runs that are blind") orelse 0.2);
    explore_opts.addOption(bool, "list_missed", b.option(bool, "explore-list-missed", "list the properties neither reached") orelse false);
    explore_opts.addOption(f32, "flip", b.option(f32, "explore-flip", "of the rest, the share that flip a named choice") orelse 0.5);
    explore_opts.addOption(u32, "seeds", b.option(u32, "explore-seeds", "explorer seeds each column is run from (one exploration is one sample)") orelse 20);
    explore_opts.addOption(u32, "reference", b.option(u32, "explore-reference", "blind runs that decide what is counted: what they reach") orelse 300);
    const explore_bench = b.addExecutable(.{
        .name = "explore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore_bench.zig"),
            .target = b.graph.host,
            .optimize = b.option(std.builtin.OptimizeMode, "explore-optimize", "how `explore` is compiled") orelse .safe,
            .imports = &.{
                .{ .name = "explore_options", .module = explore_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
            },
        }),
    });
    b.step("explore", "the seed explorer against blind seeds on fat_sim (a tool, not a gate)").dependOn(&b.addRunArtifact(explore_bench).step);

    // **THE SOAK** (src/explore_soak.zig): the explorer and blind runs on the
    // simulators, round after round; overnight, through tools/soak.sh.
    const soak_opts = b.addOptions();
    soak_opts.addOption([]const u8, "sims", b.option([]const u8, "soak-sims", "the simulators the soak runs: any of fat, store, tcp, tcp_pair") orelse "fat,store,tcp,tcp_pair");
    soak_opts.addOption(u32, "runs", b.option(u32, "soak-runs", "runs per exploration in the soak") orelse 1000);
    soak_opts.addOption(u32, "rounds", b.option(u32, "soak-rounds", "rounds the soak makes") orelse 1000);
    soak_opts.addOption(u32, "hours", b.option(u32, "soak-hours", "no round of the soak starts after this many hours") orelse 7);
    soak_opts.addOption(u64, "seed", b.option(u64, "soak-seed", "the explorer seed of the soak's first round") orelse 1);
    const soak = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore_soak.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "soak_options", .module = soak_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
                .{ .name = "kernel_partition", .module = kernel_partition },
            },
        }),
    });
    b.step("soak", "the seed explorer and blind runs on fat, store, tcp and tcp_pair, round after round (overnight; tools/soak.sh)").dependOn(&b.addRunArtifact(soak).step);
    // **THE SOAK'S BINARY, NOT RUN** (zig-out/bin/soak), for tools/soak.sh
    // to run detached. An ordinary program since metal-vmm QUEUE 106: as a
    // test, `zig build soak` held everything it printed until it exited.
    b.step("soak-build", "build the soak's binary into zig-out/bin, for tools/soak.sh to run").dependOn(&b.addInstallArtifact(soak, .{}).step);

    // **COVERAGE PROPERTIES** (COVERAGE.md): the TCP and FAT simulators over
    // a sweep of seeds, then every assertion they reach judged. Not part of `test`: its report is read, not gated on, while it
    // is a proof of concept (a `sometimes` never met is a gap, not a bug).
    const props_opts = b.addOptions();
    props_opts.addOption(bool, "trace_reach", b.option(bool, "trace-reach", "`properties` prints, for each floor line, the simulators that reach it and the first seed each did (measuring, slower)") orelse false);
    props_opts.addOption([]const u8, "sims", b.option([]const u8, "sims", "only these simulators, comma-separated, as properties.zig names them (a shard of the sweep; long.sh)") orelse "");
    props_opts.addOption(u64, "seeds", b.option(u64, "seeds", "how many tcp_sim seeds `properties` sweeps") orelse 100);
    // Every seed runs as a crowd too, unless asked for fewer: revival
    // (tcp.zig) made item 24's crowd seeds green (tcp_sim.zig, `crowd_red`).
    props_opts.addOption(u64, "crowd_seeds", b.option(u64, "crowd-seeds", "how many of the tcp_sim seeds `properties` also runs as a crowd") orelse std.math.maxInt(u64));
    props_opts.addOption(u64, "fat_seeds", b.option(u64, "fat-seeds", "how many fat_sim seeds `properties` sweeps") orelse 20);
    props_opts.addOption(u64, "page_seeds", b.option(u64, "page-seeds", "how many page_sim seeds `properties` sweeps") orelse 100);
    props_opts.addOption(u64, "pure_seeds", b.option(u64, "pure-seeds", "how many pure_sim seeds `properties` sweeps") orelse 200);
    props_opts.addOption(u64, "full_seeds", b.option(u64, "full-seeds", "how many tcp_sim seeds `properties` runs as a crowd the size of the kernel's table") orelse 20);
    props_opts.addOption(u64, "floor_seeds", b.option(u64, "floor-seeds", "how many floor_sim seeds `properties` sweeps") orelse 1000);
    // **50, BY MEASUREMENT** (metal-vmm QUEUE 224, Steve's call): the one
    // floor line only store_sim reaches comes at seed 5; 1,000 were 154 s.
    props_opts.addOption(u64, "store_seeds", b.option(u64, "store-seeds", "how many store_sim seeds `properties` sweeps") orelse 50);
    props_opts.addOption(u64, "durable_seeds", b.option(u64, "durable-seeds", "how many durable_sim seeds `properties` sweeps") orelse 1000);
    // **300** (metal-vmm QUEUE 225, chunk 6): as `zig build test` runs, about 5 s.
    props_opts.addOption(u64, "pair_seeds", b.option(u64, "pair-seeds", "how many tcp_pair_sim seeds `properties` sweeps") orelse 300);
    props_opts.addOption(u64, "ready_seeds", b.option(u64, "ready-seeds", "how many ready_sim seeds `properties` sweeps") orelse 300);
    // **20** (metal-vmm QUEUE 224, Steve's call): no floor line needs drain_sim.
    props_opts.addOption(u64, "drain_seeds", b.option(u64, "drain-seeds", "how many drain_sim seeds `properties` sweeps (each about a second in Debug)") orelse 20);
    props_opts.addOption([]const u8, "sdk_jsonl", b.option([]const u8, "sdk-jsonl", "where `properties` writes its JSONL") orelse "");
    // The floor (coverage/floor-sim.txt, COVERAGE.md): what the long tier
    // must reach. Unset, a MISS is reported and never fails the step.
    const floor = b.option([]const u8, "floor", "a coverage floor `properties` must reach (long.sh)");
    props_opts.addOption([]const u8, "floor", if (floor) |f| pathFromRoot(b, f) else "");
    const props = b.addTest(.{
        .name = "properties",
        // Only the sweep: the files it imports carry tests of their own,
        // whose sites would join its catalog and its verdict.
        .filters = &.{"the properties over a sweep of seeds"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/properties.zig"),
            .target = b.graph.host,
            // **DEBUG, AS EVERY HOST TEST IS** (Steve, 2026-10-05): test code
            // is iterated on, and Debug builds in a fraction of the time. A
            // sweep is nearly all running, though, about three times slower in
            // Debug: long.sh asks for ReleaseSafe for its 10,000 seeds.
            .optimize = b.option(std.builtin.OptimizeMode, "sweep-optimize", "how `properties` is built (Debug; long.sh: ReleaseSafe)") orelse .debug,
            .imports = &.{
                .{ .name = "tcp_properties_options", .module = props_opts.createModule() },
                // ready_sim's rule (metal-vmm QUEUE 166), as the unit tests
                // have it.
                .{ .name = "body_rule", .module = body_rule },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
            },
        }),
    });
    // **THE TCP TABLE'S GOLDEN TRACES** (metal-vmm QUEUE 225, chunk 1):
    // src/tcp_traces.zig against coverage/tcp-traces.txt, ReleaseSafe.
    const traces_opts = b.addOptions();
    traces_opts.addOption(bool, "write", b.option(bool, "tcp-traces-write", "write coverage/tcp-traces.txt again instead of checking it") orelse false);
    const traces = b.addTest(.{
        .name = "tcp-traces",
        .filters = &.{"the golden traces"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tcp_traces.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "tcp_traces_options", .module = traces_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
            },
        }),
    });
    const traces_run = b.addRunArtifact(traces);
    traces_run.has_side_effects = true;
    b.step("tcp-traces", "tcp_sim's golden traces (coverage/tcp-traces.txt), checked; -Dtcp-traces-write writes them").dependOn(&traces_run.step);

    const props_run = b.addRunArtifact(props);
    props_run.has_side_effects = true;
    b.step("properties", "the coverage properties over a sweep of tcp_sim, fat_sim, page_sim and pure_sim seeds").dependOn(&props_run.step);

    // **THE TCP TABLE'S TESTS, AT AWKWARD SEQUENCE NUMBERS** (TCP_TESTING.md
    // §6). Every number on the wire is modulo 2^32, and a `<` where `after()`
    // belongs, or a `-` where `-%` belongs, is invisible a thousand bytes from
    // zero. So the whole suite runs once per pair below: where our first
    // initial sequence number is, and where the peer's first byte is. Every
    // scenario then crosses zero, or the half-way point that decides which
    // of two numbers comes first, within its first few segments.
    // **FAT16 ON AN IN-MEMORY DISK.** With -Dfat16-images=<dir>, every image
    // the tests made is also written there, for tools/fat16_read.py to check:
    // tools/check_fat16_images.sh does both.
    const disk_fat_opts = b.addOptions();
    disk_fat_opts.addOption([]const u8, "images_dir", b.option([]const u8, "fat16-images", "where disk_fat_test writes its disk images") orelse "");
    // **THE FAULT SWEEPS, SAMPLED IN TIER 0** (metal-vmm QUEUE 198.11):
    // every request a fault can land on under -Dfault-sweep=full, as long.sh
    // runs them; the ends and two dozen between otherwise.
    disk_fat_opts.addOption(bool, "fault_sweep_full", b.option(bool, "fault-sweep-full", "disk_fat_faults_test stops at every request, not a sample (long.sh)") orelse false);
    disk_fat_opts.addOption([]const u8, "foreign_dir", b.option([]const u8, "fat16-foreign", "volumes other tools made, for disk_fat_test's check to judge") orelse "");
    // **Debug, like every other test** (metal-vmm QUEUE 136): these were
    // ReleaseSafe for a run a third as long (12.5 s, not 33 s), but its
    // compiles cost 72 s of a 2-core box's time for the three binaries, to
    // save 20 s of running. Debug: 1-2 s of compiling each, 37 s of running.
    const disk_fat_unit = b.addTest(.{
        .name = "disk_fat_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disk_fat_test.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "disk_fat_test_options", .module = disk_fat_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
            },
        }),
    });
    if (wanted(test_file, "src/disk_fat_test.zig")) test_step.dependOn(&runTest(disk_fat_unit, disk_fat_unit.name).step);
    fat_coverage.addArtifactArg(disk_fat_unit);
    // The stops and the lying disk (QUEUE.md items 79-80): hundreds of runs
    // each, so binaries of their own, run beside disk_fat_test's: one for the
    // stops and the failed requests, one for the lies. Every test in the file
    // is named by one filter or the other.
    const disk_fat_faults_opts = disk_fat_opts.createModule();
    // **EVERY TEST IN THE FILE RUNS UNDER ONE FILTER OR THE OTHER**, or the
    // build stops: a test named outside them would never run, and say nothing.
    const faults_filters = [_][]const u8{ "every operation stopped after every write", "a request that fails is an error", "a request that fails before a write's commit", "a request that fails or lies leaves no cluster lost", "a sampled sweep" };
    const lies_filters = [_][]const u8{ "a disk that lies", "a write that lands and answers failure" };
    everyTestFiltered(b, "src/disk_fat_faults_test.zig", &(faults_filters ++ lies_filters));
    for ([_][]const []const u8{
        faults_filters[0..],
        lies_filters[0..],
    }, [_][]const u8{ "disk_fat_faults_test", "disk_fat_lies_test" }) |filters, name| {
        const unit = b.addTest(.{
            .name = name,
            .filters = filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/disk_fat_faults_test.zig"),
                .target = b.graph.host,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "disk_fat_test_options", .module = disk_fat_faults_opts },
                    .{ .name = "coverage", .module = coverage },
                    .{ .name = "plant_options", .module = plant_options },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
            }),
        });
        if (wanted(test_file, "src/disk_fat_faults_test.zig")) test_step.dependOn(&runTest(unit, name).step);
        fat_coverage.addArtifactArg(unit);
    }

    const starts = [_]struct { isn: u32, peer: u32 }{
        .{ .isn = 2000, .peer = 5000 }, // where the tests were written
        .{ .isn = 0, .peer = 0 },
        .{ .isn = 0x7FFF_FFF0, .peer = 0x7FFF_FFF0 }, // 16 bytes before half-way
        .{ .isn = 0xFFFF_FFF0, .peer = 0xFFFF_FFF0 }, // 16 bytes before the wrap
        .{ .isn = 0xFFFF_FFF0, .peer = 0x7FFF_FFF0 }, // each side at its own edge
        .{ .isn = 0x7FFF_FFF0, .peer = 0xFFFF_FFF0 },
    };
    for (starts) |start| {
        const options = b.addOptions();
        options.addOption(u32, "isn", start.isn);
        options.addOption(u32, "peer", start.peer);
        const unit = b.addTest(.{
            .name = b.fmt("tcp_test isn={x} peer={x}", .{ start.isn, start.peer }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tcp_test.zig"),
                .target = b.graph.host,
                .imports = &.{
                    .{ .name = "tcp_test_start", .module = options.createModule() },
                    .{ .name = "coverage", .module = coverage },
                    .{ .name = "plant_options", .module = plant_options },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
            }),
        });
        if (wanted(test_file, "src/tcp_test.zig")) test_step.dependOn(&runTest(unit, unit.name).step);
        tcp_coverage.addArtifactArg(unit);
    }
}

/// -Dtest-cpu-dir, read where the test step is declared.
var test_cpu_dir: ?[]const u8 = null;

/// `unit`'s run, through tools/cpu_time.py, which records its CPU time
/// under `name` in -Dtest-cpu-dir; without the option, the plain run.
fn runTest(unit: *std.Build.Step.Compile, name: []const u8) *std.Build.Step.Run {
    const b = unit.step.owner;
    const dir = test_cpu_dir orelse return b.addRunArtifact(unit);
    const run = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{unit.name}));
    run.producer = unit;
    run.addArgs(&.{ "python3", pathFromRoot(b, "tools/cpu_time.py"), pathFromRoot(b, dir), name });
    run.addArtifactArg(unit);
    // As addRunArtifact sets a test's run: the build speaks to the test
    // runner over its stdin and stdout, which cpu_time.py passes through.
    run.enableTestRunnerMode();
    return run;
}

/// Whether `zig build test` runs `path`'s tests: all of them, or only
/// `-Dtest-file`'s.
fn wanted(test_file: ?[]const u8, path: []const u8) bool {
    const only = test_file orelse return true;
    return std.mem.eql(u8, only, path);
}

/// **ONE APPLICATION, AS `addAppKernel` TAKES IT**: what its own build makes.
pub const App = struct {
    /// The kernel's file name (`gopher.elf`).
    name: []const u8,
    /// The application, built by its own build.zig with its own options and
    /// imports. Its root exports `site` and `hosting` (probe/gopher.zig's
    /// host contract). It names no target or optimize mode: it takes the
    /// kernel's. It imports neither `host_io`, `webbox` nor `shale`: those
    /// are this machine's, and `addAppKernel` adds them.
    module: *std.Build.Module,
    /// Its assets.zon, a file in a checkout (not a generated one): read at
    /// configure time, as every build of the application reads it. Each
    /// `.embedded` path is relative to the file's own directory.
    assets: std.Build.LazyPath,
    /// ReleaseSafe for anything served; Debug only to iterate (`-Ddev`
    /// says why the kernel cannot take Debug's C sanitizer).
    optimize: std.builtin.OptimizeMode,
    /// **THE APPLICATIONS A COMBINATION IS MADE OF** (webbox's combo): the
    /// modules `module` imports that are applications themselves, each with
    /// its own assets.zon, each taking this machine's `host_io`, `webbox`
    /// and `shale` as `module` does. None for one application.
    parts: []const Part = &.{},

    pub const Part = struct { module: *std.Build.Module, assets: std.Build.LazyPath };
};

/// **ANY APPLICATION, AS A KERNEL: THE PUBLIC BUILD API.** Another
/// repository's build.zig calls it with this package as a dependency:
///
///     const zmu = @import("zig_metal_unikernel");
///     const kernel = b.dependency("zig_metal_unikernel", .{});
///     const elf = zmu.addAppKernel(b, kernel, .{ .name = "x.elf", .module = app, .assets = b.path("assets.zon"), .optimize = .safe });
///
/// The kernel's parts stay the kernel's: probe/gopher.zig as the root, its
/// link script and entry, and its `metal`, `host_io`, `webbox`, `shale`
/// and `gm_build` modules (this package's `-Dwebbox-root`, `-Dshale-root`,
/// `-Drestart` and `-Dcoverage` are the dependency's options). The caller hands over only
/// the application.
///
/// **AN EMBEDDED NAME THE MODULE ALREADY IMPORTS IS THE CALLER'S**: a file
/// its own build graph makes (a wasm compiled in the same `zig build`) is
/// imported by the caller from that step's output, and assets.zon's path
/// for it is not read. Every other `.embedded` row is added from its path.
pub fn addAppKernel(b: *std.Build, kernel: *std.Build.Dependency, app: App) *std.Build.Step.Compile {
    return appKernel(b, kernel.builder, app);
}

/// `addAppKernel` with the kernel's own builder: `kb` is this package's,
/// whether it is the root build (gopher.elf) or a dependency.
fn appKernel(b: *std.Build, kb: *std.Build, a: App) *std.Build.Step.Compile {
    const m = a.module;
    machineImports(b, kb, a.name, m, a.assets);
    for (a.parts) |part| machineImports(b, kb, a.name, part.module, part.assets);
    const exe = b.addExecutable(.{ .name = a.name, .root_module = kernelModule(b, kb.path("probe/gopher.zig"), a.optimize, &.{
        .{ .name = "metal", .module = exported(kb, "metal") },
        .{ .name = "app", .module = m },
        .{ .name = "webbox", .module = exported(kb, "webbox") },
        .{ .name = "gm_build", .module = exported(kb, "gm_build") },
    }) });
    // Zig's own x86 backend, which Debug would otherwise pick, cannot yet
    // assemble this kernel's AT&T or its soft-float.
    exe.use_llvm = true;
    linkPatchedRuntime(b, kb, exe);
    exe.setLinkerScript(kb.path("probe/link.ld"));
    exe.entry = .{ .symbol_name = "_start" };
    return exe;
}

/// An application's module (the whole, or a combination's part) made this
/// machine's: the kernel's target and mode, its `host_io`, `webbox` and
/// `shale`, and the files its assets.zon embeds by name.
fn machineImports(b: *std.Build, kb: *std.Build, kernel: []const u8, m: *std.Build.Module, assets: std.Build.LazyPath) void {
    if (m.resolved_target != null or m.optimize != null)
        std.process.fatal("addAppKernel({s}): the application's module names a target or optimize mode; it takes the kernel's (leave both unset)", .{kernel});
    for ([_][]const u8{ "host_io", "webbox", "shale" }) |lib| {
        if (m.import_table.contains(lib))
            std.process.fatal("addAppKernel({s}): the application's module imports `{s}` itself; the kernel supplies this machine's (drop the import)", .{ kernel, lib });
    }
    m.red_zone = false;
    // The machine's imports first, then the caller's: the order the
    // compiler meets them in is the order it numbers its generated types,
    // which name symbols in the kernel's debug info.
    const callers = m.import_table;
    m.import_table = .empty;
    m.addImport("host_io", exported(kb, "host_io"));
    m.addImport("webbox", exported(kb, "webbox"));
    m.addImport("shale", exported(kb, "shale"));
    for (callers.keys(), callers.values()) |name, module| m.addImport(name, module);
    // A page embeds these by name, and a name that no build graph declared is
    // a compile error with a confusing message.
    const assets_path = sourcePath(assets);
    const base = std.fs.path.dirname(assets_path) orelse ".";
    for (servedBy(b, assets_path).embedded) |e| {
        if (m.import_table.contains(e.name)) continue;
        m.addAnonymousImport(e.name, .{
            .root_source_file = .{ .cwd_relative = b.fmt("{s}/{s}", .{ base, e.path }) },
        });
    }
}

fn exported(kb: *std.Build, name: []const u8) *std.Build.Module {
    return kb.modules.get(name) orelse std.process.fatal("zig-metal-unikernel's build exports no module `{s}`", .{name});
}

/// **WHAT AN APPLICATION SERVES BESIDES ITS CODE** (Phase B step 3): its
/// zig-server/assets.zon, read here as its own build.zig reads it, so the
/// two cannot drift: `.embedded`, compiled in by name; `.site`, directories
/// its routes read at request time (laid onto the site disk by
/// droplet/chat.py and the judge). A checkout without one serves nothing
/// extra here, and tools/verdicts.py's freshness refuses to build it.
const Served = struct {
    embedded: []const struct { name: []const u8, path: []const u8, built_by: []const u8 = "" } = &.{},
    site: []const []const u8 = &.{},
};

fn servedBy(b: *std.Build, path: []const u8) Served {
    // Read at configure time, which 0.17 caches: a row added must configure
    // the build again, or the kernel compiles with the old list. A file
    // that is not there (tier 0 builds the kernel alone) cannot be a
    // dependency, so that configure is never cached instead.
    const io = b.graph.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(1 << 20)) catch {
        b.graph.poisonCache();
        return .{};
    };
    b.dependOnFileContents(.{ .cwd_relative = path });
    const z = b.allocator.dupeSentinel(u8, text, 0) catch @panic("out of memory");
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Served, .{ .gpa = b.allocator, .arena = b.allocator, .source = z, .diagnostics = &diag }) catch
        std.process.fatal("{s} does not read as an application's assets (.embedded and .site)", .{path});
}

/// Whether a build bakes its commits in (`-Dstamp`).
pub const Stamp = enum { on, off };

/// The commit a build says it is: `dir`'s, or `unstamped` (`-Dstamp=off`).
fn stampOf(b: *std.Build, stamp: Stamp, dir: []const u8) []const u8 {
    return switch (stamp) {
        .on => commitOf(b, dir),
        .off => "unstamped",
    };
}

/// `git rev-parse --short HEAD` in `dir`, with `+dirty` when its tree has
/// uncommitted changes; `unknown` when git cannot say.
fn commitOf(b: *std.Build, dir: []const u8) []const u8 {
    // Asked at configure time, which 0.17 caches: a commit, or a tree that
    // turned clean, must configure the build again, or it bakes in the old
    // answer (v36 said `cb198ca+dirty`, built at b70f9d6 clean). Whether a
    // tree is dirty rests on every file in it, which no dependency names.
    b.graph.poisonCache();
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const short = std.mem.trim(u8, head, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", dir, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch return short;
    return if (std.mem.trim(u8, status, " \n").len == 0) short else b.fmt("{s}+dirty", .{short});
}

/// **THE COVERAGE SDK IS PINNED, BY ITS CONTENT** (Steve, 2026-10-10; by
/// content, Steve, 2026-10-17): build.zig.zon names it by path, a sibling
/// checkout, so a build used whatever that checkout held. A cloud session ran
/// a day of tests against one from before `on_broken`, which fails a unit
/// test at a property it breaks, and nothing said so. The pin is a SHA-256 of
/// what a build takes from the SDK: every file git tracks in its `build.zig`,
/// `build.zig.zon`, `src/` and `tools/` (the scanner the catalog runs), each
/// path and its bytes as the checkout holds them. A commit there that changes
/// none of them (a README) leaves the pin standing; a change to one, committed
/// or not, stops the build and says the hash the checkout now has. Moving the
/// SDK is moving this line, in the same commit as whatever needed the move.
/// `-Dcoverage-sdk-unpinned` builds against anything, and says so.
/// The coverage SDK's `linecov` over `files`, its binaries added after: `linecov
/// <files> -- <binaries>`, each binary run once for all of them.
fn lineCoverage(b: *std.Build, sdk: *std.Build.Dependency, files: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(sdk.artifact("linecov"));
    for (files) |f| {
        run.addArg(f);
        run.addFileInput(b.path(f));
    }
    run.addArg("--");
    run.has_side_effects = true;
    return run;
}

const coverage_sdk_pin = "b7fde03fbe8e84f4e45041e099dbb3578be0d173a98c3dcc4a6b3bad492296ce";

/// The SDK's content hash, as the pin is made (above), in hex.
fn sdkContent(b: *std.Build, sdk_path: []const u8) ![64]u8 {
    var code: u8 = undefined;
    const listed = try b.runAllowFail(&.{ "git", "-C", sdk_path, "ls-files", "--", "build.zig", "build.zig.zon", "src", "tools" }, &code, .ignore);
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, listed, '\n');
    while (it.next()) |n| try names.append(b.allocator, n);
    if (names.items.len == 0) return error.NothingTracked;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const io = b.graph.io;
    var dir = try std.Io.Dir.cwd().openDir(io, sdk_path, .{});
    defer dir.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    // The configure step 0.17 caches reads these, and the list git gives.
    for ([_][]const u8{ "", "src", "tools" }) |sub| b.dependOnDirectoryContents(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, sub }) });
    for (names.items) |n| {
        b.dependOnFileContents(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, n }) });
        const bytes = try dir.readFileAlloc(io, n, b.allocator, .limited(64 << 20));
        var each: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &each, .{});
        h.update(n);
        h.update(&.{0});
        h.update(&each);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn pinnedSdk(b: *std.Build, sdk_path: []const u8) void {
    const unpinned = b.option(bool, "coverage-sdk-unpinned", "build against whatever ../zig-coverage-sdk holds, not the content build.zig pins") orelse false;
    const got = sdkContent(b, sdk_path) catch |e| {
        if (unpinned) return;
        std.process.fatal("the coverage SDK at {s}: its content cannot be read ({t}); build.zig pins {s} (-Dcoverage-sdk-unpinned builds without the check)", .{ sdk_path, e, coverage_sdk_pin });
    };
    if (std.mem.eql(u8, &got, coverage_sdk_pin)) return;
    if (unpinned) {
        std.debug.print("the coverage SDK at {s} holds {s}, not the pinned {s}: building anyway (-Dcoverage-sdk-unpinned)\n", .{ sdk_path, &got, coverage_sdk_pin });
        return;
    }
    std.process.fatal("the coverage SDK at {s} holds content {s}, but build.zig pins {s}: check out the SDK this kernel was verified with, or move the pin (paste the first hash into coverage_sdk_pin) with the change that needs it (-Dcoverage-sdk-unpinned builds anyway)", .{ sdk_path, &got, coverage_sdk_pin });
}

/// **THE CATALOG IS EVERY FILE IN src/ THAT DECLARES PROPERTIES** (the
/// protocols-in-prose hunt, 2026-10-10): it was a hand list of 26, and nine
/// served files had properties outside it (stream, scsi, virtio, io, pci,
/// machine, idle, idle_check, store_model), so a property there never reached
/// was never declared, and never showed as a MISS. Now every file that
/// imports the coverage SDK is cataloged, but those named here with why; a
/// name here that is not a file in src/ stops the build.
const not_cataloged = [_]struct { file: []const u8, why: []const u8 }{
    .{ .file = "metal.zig", .why = "the kernel's module root: it re-exports, it declares nothing" },
    .{ .file = "properties.zig", .why = "the properties tier's driver, host only: its own runs, not the kernel's" },
    .{ .file = "explore_bench.zig", .why = "a benchmark of the seed explorer, host only" },
    .{ .file = "explore_soak.zig", .why = "a soak of the seed explorer, host only" },
    .{ .file = "tcp_test.zig", .why = "tests: what they assert is theirs, not a site the sweeps should reach" },
    .{ .file = "disk_fat_faults_test.zig", .why = "tests, as tcp_test.zig" },
};

fn catalogFiles(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var src = b.root.root_dir.handle.openDir(io, "src", .{ .iterate = true }) catch |e|
        std.process.fatal("src/ cannot be listed for the coverage catalog ({t})", .{e});
    defer src.close(io);
    // A file added to src/, or one that starts declaring properties, must
    // configure the build again (0.17 caches the configure step).
    b.dependOnDirectoryContents(b.path("src"));
    var out: std.ArrayList([]const u8) = .empty;
    var it = src.iterate();
    while (it.next(io) catch |e| std.process.fatal("src/ cannot be listed ({t})", .{e})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        b.dependOnFileContents(b.path(b.pathJoin(&.{ "src", entry.name })));
        const text = src.readFileAlloc(io, entry.name, b.allocator, .limited(1 << 22)) catch |e|
            std.process.fatal("src/{s}: cannot be read for the coverage catalog ({t})", .{ entry.name, e });
        if (std.mem.indexOf(u8, text, "@import(\"coverage\")") == null) continue;
        for (not_cataloged) |n| {
            if (std.mem.eql(u8, n.file, entry.name)) break;
        } else out.append(b.allocator, b.dupe(entry.name)) catch @panic("out of memory");
    }
    for (not_cataloged) |n| {
        src.access(io, n.file, .{}) catch std.process.fatal("build.zig's not_cataloged names src/{s}, which is not there", .{n.file});
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out.items;
}

/// Stops the build when a `test "..."` in `path` contains none of `filters`:
/// a test binary built with filters runs only the tests they name.
fn everyTestFiltered(b: *std.Build, path: []const u8, filters: []const []const u8) void {
    b.dependOnFileContents(b.path(path));
    const text = b.root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 22)) catch |e|
        std.process.fatal("{s}: cannot be read to check its test names ({t})", .{ path, e });
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "test \"")) continue;
        for (filters) |f| {
            if (std.mem.indexOf(u8, line, f) != null) break;
        } else std.process.fatal("{s}: a test no filter in build.zig names, so it would never run: {s}", .{ path, line });
    }
}

/// `builder`'s build root as an absolute path: 0.17's `b.root` may hold a
/// relative one, and these paths are handed to other processes and builds.
fn rootOf(builder: *std.Build) []const u8 {
    return builder.root.root_dir.handle.realPathFileAlloc(builder.graph.io, builder.root.subPathOrDot(), builder.allocator) catch |e|
        std.debug.panic("the build root {f}: {t}", .{ builder.root, e });
}

/// `sub` under this build's root, absolute (0.17 removed `b.pathFromRoot`).
fn pathFromRoot(b: *std.Build, sub: []const u8) []const u8 {
    return b.pathJoin(&.{ rootOf(b), sub });
}

/// A checked-in file's absolute path, for reading it while the build graph
/// is made (0.17 removed `LazyPath.getPath`); a generated file has no path
/// until its step runs.
fn sourcePath(lp: std.Build.LazyPath) []const u8 {
    return switch (lp) {
        .src_path => |p| p.owner.pathJoin(&.{ rootOf(p.owner), p.sub_path }),
        .dependency => |d| d.dependency.builder.pathJoin(&.{ rootOf(d.dependency.builder), d.sub_path }),
        .cwd_relative => |p| p,
        .generated, .relative => std.debug.panic("{f} is not a checked-in file, so it cannot be read before the build runs", .{lp}),
    };
}
