#!/usr/bin/env python3
"""**WHICH CODE WAS JUDGED, AND WHAT THE JUDGES SAID.** A release is an image
of two repos' code: this one's, and angry-gopher's server, compiled from its
checkout (Phase B step 2b: no copy). A gate that passed on other code than the image carries has proved
nothing about the image, and nothing used to say which code a gate judged.
So:

- The applications are named by one **content id**: a hash of the content
  of every file a kernel reads from their checkouts (`served_files`):
  angry-gopher's server source, the assets its build.zig embeds, pages/ and
  gallery/; and zig-webbox's. Dog Park is not judged here (Steve,
  2026-10-13: an application is not this repo's test of itself). A verdict is keyed by that, by this repo's
  and the SDK's commits (B16), and by the compiler's `zig version`, so a
  README commit in either leaves a verdict standing and an SDK or compiler
  change does not.
- `gates.sh` and `long.sh` call `pair`, which prints the two they are about
  to judge, or refuses a checkout the build cannot take (`freshness`).
  At the end they call `record`, which keeps their verdict for that pair.
- `droplet/chat.py` calls `require`, which refuses to build an image unless
  both trees are clean and both verdicts are PASS for exactly that pair.

    tools/verdicts.py pair                   (gates.sh, long.sh: print, or refuse)
    tools/verdicts.py ids                    (the pair, as the run starts)
    tools/verdicts.py fresh                  (build.zig's check: "fresh", or why not)
    VERDICT_PAIR="<ids>" tools/verdicts.py record gates|long PASS|FAIL

**A VERDICT IS FOR THE CODE THE RUN STARTED ON.** A run takes `ids` first;
`record` keeps nothing if either tree has moved since, because the run then
judged a mixture. With no copy this is what keeps a gate honest when
angry-gopher's checkout is edited under it: the build reads the checkout
live, so an edit mid-run changes the content id and the verdict is refused.

`RELEASE_UNGATED=1` lets `require` pass anyway, for an emergency fix, and
says so loudly; nothing else bypasses it.

Verdicts live in `~/build/zig-metal-unikernel/verdicts/` (GATES_VERDICT_DIR), one
file per tier and pair, so a run in another worktree of the same commit
counts.
"""
import hashlib
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.normpath(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "..", "angry-gopher")))
SRC = os.path.join(GOPHER_ROOT, "zig-server", "src")
# The webbox library's checkout (zig-webbox), which both applications and
# the kernel build compile: its source and build files.
WEBBOX_ROOT = os.path.realpath(os.environ.get("WEBBOX_ROOT", os.path.join(ROOT, "..", "zig-webbox")))
WEBBOX_SRC = os.path.join(WEBBOX_ROOT, "src")
WEBBOX_BUILT = ("src", "build.zig", "build.zig.zon")
# Shale's checkout (shale), compiled into both applications as webbox is.
SHALE_CHECKOUT = os.path.realpath(os.environ.get("SHALE_CHECKOUT", os.path.join(ROOT, "..", "shale")))
SHALE_SRC = os.path.join(SHALE_CHECKOUT, "src")
SHALE_BUILT = WEBBOX_BUILT
# cobble-webbox's checkout, whose `codex_chat` (Codex Chat, under
# /codex-chat) angry-gopher's kernel compiles, with the page it embeds.
COBBLE_ROOT = os.path.realpath(os.environ.get("COBBLE_ROOT", os.path.join(ROOT, "..", "cobble-webbox")))
COBBLE_SRC = os.path.join(COBBLE_ROOT, "src")
COBBLE_BUILT = ("src", "assets.zon", "web/chat.html", "web/uo-town.html")
VERDICT_DIR = os.environ.get("GATES_VERDICT_DIR", os.path.expanduser("~/build/zig-metal-unikernel/verdicts"))
SDK = os.environ.get("COVERAGE_SDK", os.path.join(os.path.dirname(ROOT), "zig-coverage-sdk"))
TIERS = ("gates", "long")

# **WHAT AN IMAGE READS FROM ANGRY-GOPHER** (metal-vmm QUEUE B16, Phase B
# step 3): the build compiles zig-server/src and embeds what
# zig-server/assets.zon's `.embedded` names (many generated, so not in git);
# droplet/chat.py lays its `.site` directories onto the site disk. A verdict
# is keyed by those files' content, so a commit that touches none of them (a
# README) leaves it standing, and a rebuilt asset that git cannot see does not.
ASSETS = "zig-server/assets.zon"
# An embedded row, as angry-gopher's tools/embedded_assets.py reads it, and
# every row must read (a row of another shape is refused, never skipped).
ASSET_ROW = re.compile(r'\.\{\s*\.name\s*=\s*"([^"]+)"\s*,\s*\.path\s*=\s*"([^"]+)"\s*(?:,\s*\.built_by\s*=\s*"[^"]+"\s*)?\}')
ASSET_NAME = re.compile(r'\.name\s*=\s*"')
SITE = re.compile(r'\.site\s*=\s*\.\{([^}]*)\}')


def served_by(root: str = None, assets: str = ASSETS) -> tuple:
    """(the embedded paths, relative to the assets file's directory, and the
    site directories), from the checkout's assets.zon (GOPHER_ROOT's
    zig-server/assets.zon, or `root`'s `assets`); raises ValueError naming
    what it cannot read."""
    path = os.path.join(root or GOPHER_ROOT, assets)
    with open(path) as f:
        text = f.read()
    rows = ASSET_ROW.findall(text)
    if len(rows) != len(ASSET_NAME.findall(text)):
        raise ValueError(f"{path}: {len(ASSET_NAME.findall(text))} embedded names, {len(rows)} rows read: has a row changed shape?")
    site = SITE.search(text)
    if not site:
        raise ValueError(f"{path} names no .site")
    return [p for _, p in rows], re.findall(r'"([^"]+)"', site.group(1))


def served_dirs() -> tuple:
    return ("zig-server/src", *served_by()[1])


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def commit_of(repo: str, paths: tuple = ()) -> str:
    """HEAD, with `-dirty` when tracked files under `paths` (all, if none)
    differ from it. Untracked files do not count: they are not built."""
    head = git(repo, "rev-parse", "HEAD")
    changed = git(repo, "status", "--porcelain", "--untracked-files=no", "--", *paths)
    return head + ("-dirty" if changed else "")


def walk(root: str, entries) -> list:
    """Every file under each of `entries` (a directory or a file), as paths
    from `root`."""
    files = []
    for e in entries:
        if os.path.isfile(os.path.join(root, e)):
            files.append(e)
        for dirpath, _, names in os.walk(os.path.join(root, e)):
            for n in names:
                files.append(os.path.relpath(os.path.join(dirpath, n), root))
    return files


def served_files() -> list:
    """Every angry-gopher file an image reads, as paths from its root."""
    embedded, _ = served_by()
    files = walk(GOPHER_ROOT, served_dirs()) + [ASSETS]
    for path in embedded:
        files.append(os.path.normpath(os.path.join("zig-server", path)))
    return sorted(set(files))


def content_id() -> str:
    """`content-` and a hash of every served file's repo, path and bytes, both
    applications' and the libraries' (a file named but not there counts as
    missing)."""
    h = hashlib.sha256()
    for repo, root, rels in (("angry-gopher", GOPHER_ROOT, served_files()),
                             ("zig-webbox", WEBBOX_ROOT, sorted(walk(WEBBOX_ROOT, WEBBOX_BUILT))),
                             ("shale", SHALE_CHECKOUT, sorted(walk(SHALE_CHECKOUT, SHALE_BUILT))),
                             ("cobble-webbox", COBBLE_ROOT, sorted(walk(COBBLE_ROOT, COBBLE_BUILT)))):
        for rel in rels:
            h.update(f"{repo}/{rel}".encode() + b"\0")
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    h.update(hashlib.sha256(f.read()).digest())
            except FileNotFoundError:
                h.update(b"missing")
    return "content-" + h.hexdigest()[:16]


def compiler_id() -> str:
    """`zig version` of the `zig` on PATH, which every build here runs: a
    patched release names its patches (0.17.0+patched.2), so a verdict from
    another compiler does not carry over to this one."""
    return subprocess.run(["zig", "version"], check=True, capture_output=True, text=True).stdout.strip()


def ours_id() -> str:
    """This repo's commit, the SDK's it builds against (by path), and the
    compiler."""
    return commit_of(ROOT) + ".sdk-" + commit_of(SDK) + ".zig-" + compiler_id()


def current_pair() -> tuple:
    """(this repo's and the SDK's commits, angry-gopher's content id now),
    or an error: `freshness`'s, so `pair`, `ids` and build.zig's check refuse
    the same ports (147(d))."""
    ours = ours_id()
    why = freshness()
    if why != "fresh":
        return ours, None, why
    return ours, content_id(), None


def short(c: str) -> str:
    if ".zig-" in c:
        a, b = c.split(".zig-", 1)
        return short(a) + ", Zig " + b
    if ".sdk-" in c:
        a, b = c.split(".sdk-", 1)
        return short(a) + " with the SDK at " + short(b)
    if c.startswith("content-"):
        return c
    return c[:12] + ("-dirty" if c.endswith("-dirty") else "")


def pair() -> int:
    ours, theirs, problem = current_pair()
    if problem:
        print(f"REFUSING: {problem}")
        return 2
    print(f"judging zig-metal-unikernel {short(ours)} with angry-gopher and zig-webbox {short(theirs)}")
    return 0


def verdict_path(tier: str, ours: str, theirs: str) -> str:
    return os.path.join(VERDICT_DIR, f"{tier}-{ours}-{theirs}")


def ids() -> int:
    ours, theirs, problem = current_pair()
    if problem:
        print(f"REFUSING: {problem}", file=sys.stderr)
        return 2
    print(f"{ours} {theirs}")
    return 0


def record(tier: str, outcome: str) -> int:
    if tier not in TIERS or outcome not in ("PASS", "FAIL"):
        print(f"usage: verdicts.py record {'|'.join(TIERS)} PASS|FAIL")
        return 2
    # **A SKIP IS NO PASS** (tools/skip_lib.sh): a run that left a step out
    # keeps no verdict, PASS or FAIL, so no release can stand on it.
    if os.environ.get("SKIP", "").strip():
        print(f"no verdict kept: SKIP={os.environ['SKIP']!r} left steps out")
        return 2
    ours, theirs, problem = current_pair()
    if problem:
        print(f"no verdict kept: {problem}")
        return 2
    started = os.environ.get("VERDICT_PAIR", "")
    if started != f"{ours} {theirs}":
        print(f"no verdict kept: the code is not what the run started on ({started or 'no VERDICT_PAIR'})")
        return 2
    os.makedirs(VERDICT_DIR, exist_ok=True)
    with open(verdict_path(tier, ours, theirs), "w") as f:
        f.write(f"{outcome} {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
    print(f"verdict kept: {tier} {outcome} for zig-metal-unikernel {short(ours)} with angry-gopher and zig-webbox {short(theirs)}")
    return 0


def require() -> list:
    """Why this tree may not become an image; empty when it may."""
    ours, theirs, problem = current_pair()
    if problem:
        return [problem]
    why = []
    here, sdk = ours.split(".zig-", 1)[0].split(".sdk-", 1)
    if here.endswith("-dirty"):
        why.append("zig-metal-unikernel has uncommitted changes")
    if sdk.endswith("-dirty"):
        why.append("zig-coverage-sdk has uncommitted changes")
    # An image is built from committed code: what it serves from angry-gopher
    # (the content id says which bytes; this says they are committed ones).
    # Generated assets are not in git, and are not asked to be.
    if git(GOPHER_ROOT, "status", "--porcelain", "--untracked-files=no", "--", *served_dirs(), ASSETS):
        why.append("angry-gopher's served files have uncommitted changes")
    if git(WEBBOX_ROOT, "status", "--porcelain", "--untracked-files=no", "--", *WEBBOX_BUILT):
        why.append("zig-webbox has uncommitted changes")
    if git(SHALE_CHECKOUT, "status", "--porcelain", "--untracked-files=no", "--", *SHALE_BUILT):
        why.append("shale has uncommitted changes")
    if git(COBBLE_ROOT, "status", "--porcelain", "--untracked-files=no", "--", *COBBLE_BUILT):
        why.append("cobble-webbox has uncommitted changes")
    for tier in TIERS:
        try:
            with open(verdict_path(tier, ours, theirs)) as f:
                said = f.read().split()
        except FileNotFoundError:
            said = []
        if not said:
            why.append(f"no {tier} verdict for this pair: run ./{tier}.sh")
        elif said[0] != "PASS":
            why.append(f"{tier}.sh said {said[0]} for this pair ({said[1] if len(said) > 1 else '?'})")
    return why


def fresh() -> int:
    """**CAN THE BUILD TAKE THE CHECKOUT AS IT IS?** build.zig type-checks and
    builds gopher.elf only then. Prints `fresh`, or why not; exits 0 either
    way, so build.zig reads the answer from the output."""
    try:
        print(freshness())
    except OSError as e:  # one line on every path: build.zig reads it
        print(f"cannot tell: {e}")
    return 0


# A file that names std's Io where host_io's belongs would compile here as
# std's, which has no machine under it: the sed the port once was is a
# refusal now (Phase B 2a; host_io_std.zig is the Linux host's own).
STD_IO_ALIAS = re.compile(r'const Io = (std|@import\("std"\))\.Io;')


def freshness() -> str:
    """`fresh`, or why not: the checkout, its sources' Io, and this tree's
    asset list. Not this repo's or the SDK's commits, which `pair` adds and a
    check of the build has no use for."""
    if not os.path.isdir(SRC):
        return f"no angry-gopher sources at {SRC}"
    if not os.path.isdir(WEBBOX_SRC):
        return f"no zig-webbox sources at {WEBBOX_SRC} (WEBBOX_ROOT)"
    if not os.path.isdir(SHALE_SRC):
        return f"no shale sources at {SHALE_SRC} (SHALE_CHECKOUT)"
    if not os.path.isdir(COBBLE_SRC):
        return f"no cobble-webbox sources at {COBBLE_SRC} (COBBLE_ROOT)"
    escaped = []
    # Every folder down: Shale's interpreter is in shale's src/script/.
    for src in (SRC, WEBBOX_SRC, SHALE_SRC, COBBLE_SRC):
        for folder, _, names in sorted(os.walk(src)):
            for name in sorted(names):
                if name.endswith(".zig") and name != "host_io_std.zig":
                    with open(os.path.join(folder, name)) as f:
                        if STD_IO_ALIAS.search(f.read()):
                            escaped.append(os.path.relpath(os.path.join(folder, name), src))
    if escaped:
        return "these alias std's Io, not host_io's, and would be std's here: " + " ".join(escaped)
    # **AND ITS ASSETS READ** (Phase B step 3): the build reads the same
    # table, and a row of another shape would be a name no build declared.
    try:
        served_by()
    except (OSError, ValueError) as e:
        return f"angry-gopher's assets do not read: {e}"
    return "fresh"


def main() -> int:
    args = sys.argv[1:]
    if args == ["pair"]:
        return pair()
    if args == ["ids"]:
        return ids()
    if args == ["fresh"]:
        return fresh()
    if len(args) == 3 and args[0] == "record":
        return record(args[1], args[2])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
