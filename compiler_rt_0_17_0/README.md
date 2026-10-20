# compiler_rt for Zig 0.17.0, patched: DELETE ON THE NEXT ZIG

**This folder exists only because Zig 0.17.0 cannot build its own
compiler_rt for this kernel's target.** The build refuses to run under any
other Zig version, so it can't outlive 0.17.0 by accident
(`requirePatchedRuntimeZig` in `build.zig`).

## What compiler_rt is

compiler_rt is the runtime library Zig links into every program. It holds
the functions the compiler calls when the CPU can't do something in one
instruction. Under soft float, `a - b` on doubles is a call to `__subdf3`.
128-bit division is `__udivti3`. The library also provides `memcpy`,
`memset` and `memmove`, which a freestanding kernel has nobody else to
supply. It's ordinary Zig source in Zig's install (`lib/compiler_rt.zig` and
`lib/compiler_rt/`), compiled for each target alongside the program.

## Why it is patched

The kernel compiles for soft float: no SSE or x87 in its own code, because
it saves no floating-point registers on an interrupt (`bareTarget` in
`build.zig`). For that target, 0.17.0's compiler_rt fails twice:

1. Its long-double functions (`truncl`, `sinl`, `logl`, ...) are exported
   unconditionally, and 0.17 refuses `c_longdouble` in a C-ABI function
   under soft float. This is
   [ziglang/zig#37006](https://codeberg.org/ziglang/zig/issues/37006), a
   regression listed in 0.17.0's release notes. The fix is
   [PR #37324](https://codeberg.org/ziglang/zig/pulls/37324), aimed at 0.17.1.
2. With (1) fixed, LLVM still rejects `mulc3.zig` and `divc3.zig` (complex
   multiply and divide) for soft float: "Intrinsic has incorrect argument
   type ... Broken module". #37324 doesn't touch these files, so 0.17.1 may
   still fail here.

The kernel calls none of the failing functions. Zig builds the library as
one unit, though, so a single failing file stops every kernel image.

## What the patch is

`lib/` is 0.17.0's `lib/compiler_rt.zig` and `lib/compiler_rt/`, unchanged
except for 21 files. `PATCH.diff` is the whole difference from stock:

- **PR #37324's compiler_rt part:** a `have_c_longdouble` flag, false for an
  80-bit `long double` under soft float, guarding every `*l` export.
- **Two local lines:** `mulc3.zig` and `divc3.zig` skip their exports on
  soft-float x86. These are ours and not upstream.

`linkPatchedRuntime` in `build.zig` builds `lib/compiler_rt.zig` as an
object, the way Zig builds its own (optimized, no stack probes, no
builtins), and links it into every kernel with Zig's own compiler_rt turned
off. std and the compiler stay stock.

## When the next Zig arrives

The build stops with a message pointing here. Then:

1. Delete this folder, `requirePatchedRuntimeZig`, `linkPatchedRuntime`
   and its calls in `build.zig`.
2. Build the kernels with the stock compiler_rt (`zig build kernels`).
3. If it fails in `mulc3`/`divc3` (failure 2 above), the bug is still
   upstream. Report it there if nobody has, and make a new patch for that
   version on purpose, under a folder named for that version.
4. Judge the kernels as for any toolchain change: the probes
   (`probe/run.sh`) and the metal gate.
