#!/usr/bin/env python3
"""**THE LIMITS WEBBOX COPIES FROM THIS REPO, CHECKED** (gates.sh).

zig-webbox's `src/store.zig` keeps FAT's rules on every host, so
it restates three of this repo's limits, each with a comment naming where it
came from. Nothing else ties them: B5 moved the depth limit on 2026-10-05,
and the store's copy stayed right only because the two count depth
differently and the move happened to land on the same answer. This compares
them, so the next move cannot leave one behind.

    tools/check_limits.py [zig-webbox's src]

- the longest name: store.zig's `max_name` is disk_fat_dirent.zig's `max_name`;
- the longest path: store.zig's `max_path` is io.zig's `max_path`;
- the deepest file: store.zig's `max_depth` counts the parts of a path from
  the root's own name ("data") to the file, so a file `max_depth` parts deep
  sits in `max_depth - 1` folders, `data` among them; disk_fat.zig's makePath
  makes at most `max_path_depth` folders. They agree when
  `max_depth - 1 == max_path_depth`.

Exits 0 when all three agree, 1 with what differs, 2 if a constant is not
where it is looked for.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
AG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "zig-webbox", "src")


def const(path: str, name: str) -> int:
    """The value of `[pub] const name[: T] = <int>[ - 1];` in `path`, or of
    `max_tree_depth - 1` for a constant defined that way, or of
    `module.name` for one defined in a file `path` imports (`const module =
    @import("file.zig");`), followed there: a constant moved to a split
    file and named from where it was still reads."""
    text = open(path).read()
    m = re.search(rf"^\s*(?:pub\s+)?const\s+{name}\s*(?::\s*\w+)?\s*=\s*([^;]+);", text, re.M)
    if not m:
        print(f"check_limits: no `{name}` in {path}")
        sys.exit(2)
    expr = m.group(1).strip()
    if re.fullmatch(r"\d+", expr):
        return int(expr)
    m2 = re.fullmatch(r"(\w+)\s*-\s*(\d+)", expr)
    if m2:
        return const(path, m2.group(1)) - int(m2.group(2))
    m3 = re.fullmatch(r"(\w+)\.(\w+)", expr)
    if m3:
        imp = re.search(rf'^\s*(?:pub\s+)?const\s+{m3.group(1)}\s*=\s*@import\("([^"]+\.zig)"\);', text, re.M)
        if imp:
            return const(os.path.join(os.path.dirname(path), imp.group(1)), m3.group(2))
    print(f"check_limits: `{name}` in {path} is `{expr}`, which this does not read")
    sys.exit(2)


def main() -> int:
    store = os.path.join(AG, "store.zig")
    disk_fat = os.path.join(ROOT, "src", "disk_fat.zig")
    dirent = os.path.join(ROOT, "src", "disk_fat_dirent.zig")
    io = os.path.join(ROOT, "src", "io.zig")
    pairs = [
        ("the longest name", const(store, "max_name"), const(dirent, "max_name"), "store.zig max_name", "disk_fat_dirent.zig max_name"),
        ("the longest path", const(store, "max_path"), const(io, "max_path"), "store.zig max_path", "io.zig max_path"),
        ("the deepest file's folders", const(store, "max_depth") - 1, const(disk_fat, "max_path_depth"), "store.zig max_depth - 1", "disk_fat.zig max_path_depth"),
    ]
    bad = 0
    for what, a, b, an, bn in pairs:
        if a == b:
            print(f"  {what}: {a} ({an} = {bn})")
        else:
            print(f"  {what}: {an} is {a}, {bn} is {b}")
            bad += 1
    if bad:
        print(f"LIMITS: {bad} differ: angry-gopher would accept what metal refuses, or the reverse")
        return 1
    print("LIMITS: webbox's store keeps metal's limits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
