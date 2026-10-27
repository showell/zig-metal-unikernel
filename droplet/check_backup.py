#!/usr/bin/env python3
"""Is a backup whole? A tar cut short still lists cleanly (DEPLOY.md, "Backups").

    droplet/check_backup.py ARCHIVE
    droplet/check_backup.py --self-test ZIG_SERVER_BINARY

`ARCHIVE` is what `/admin/backup` gave: a tar that, from angry-gopher
`5159c929` on, ends with `backup-manifest.txt`, which is written only after
everything before it was:

    gopher-backup manifest 1
    <sha256> <size> <path>        one line per file member, in order
    end: <N> files, <M> bytes

**A TAR CUT BETWEEN TWO MEMBERS READS AS COMPLETE**: GNU tar and Python list
it and exit 0. So this is what says whether the archive is whole: the
manifest is there and last, and every file member before it is the one it
names, with that size and SHA-256, and nothing else is. Run it before
`tar xf`.

It prints counts, and a problem by its member's number and the start of
its path's SHA-256, never a name from the data.

Exit 0 when the archive is whole, 1 when it is not, 2 for a usage error.
"""
import hashlib
import io
import os
import sys
import tarfile

MANIFEST = "backup-manifest.txt"
HEAD = "gopher-backup manifest 1"


def tag(n: int, path: str) -> str:
    return f"member {n} (#{hashlib.sha256(path.encode()).hexdigest()[:8]})"


def check(archive: bytes):
    """(problems, files, bytes): no problems means whole."""
    try:
        t = tarfile.open(fileobj=io.BytesIO(archive))
        members = [(m.name, t.extractfile(m).read()) for m in t.getmembers() if m.isfile()]
    except (tarfile.TarError, EOFError) as e:
        return [f"not a tar: {e}"], 0, 0
    if not members or members[-1][0] != MANIFEST:
        return [f"no {MANIFEST} at the end: the archive was cut short, or is from before manifests"], 0, 0
    lines = members[-1][1].decode("utf-8", "replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    files = members[:-1]
    problems = []
    if not files and lines == [f"end: 0 files, 0 bytes"]:
        return [], 0, 0
    if not lines or lines[0] != HEAD:
        return [f"the manifest does not begin `{HEAD}`"], 0, 0
    listed, end = lines[1:-1], lines[-1] if len(lines) > 1 else ""
    want_end = f"end: {len(files)} files, {sum(len(d) for _, d in files)} bytes"
    if end != want_end:
        problems.append(f"the manifest ends `{end[:40]}`; the archive holds {want_end[5:]}")
    if len(listed) != len(files):
        problems.append(f"the manifest names {len(listed)} files; the archive holds {len(files)}")
    for n, ((name, data), line) in enumerate(zip(files, listed), 1):
        parts = line.split(" ", 2)
        if len(parts) != 3:
            problems.append(f"{tag(n, name)}: its manifest line is not `sha256 size path`")
            continue
        sha, size, path = parts
        if path != name:
            problems.append(f"{tag(n, name)}: the manifest names another file in its place")
        elif size != str(len(data)):
            problems.append(f"{tag(n, name)}: {len(data)} bytes, the manifest says {size}")
        elif sha != hashlib.sha256(data).hexdigest():
            problems.append(f"{tag(n, name)}: its SHA-256 is not the manifest's")
    return problems, len(files), sum(len(d) for _, d in files)


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--self-test":
        return self_test(argv[2])
    if len(argv) != 2 or not os.path.isfile(argv[1]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        problems, files, size = check(f.read())
    for p in problems:
        print(f"NOT WHOLE  {p}")
    if problems:
        print(f"check_backup: {len(problems)} problem(s); do not restore from it")
        return 1
    print(f"check_backup: whole: {files} files, {size} bytes, each as its manifest says")
    return 0


# ── the self-test ───────────────────────────────────────────────────────────

def self_test(binary: str) -> int:
    """A real archive from a Linux server on the judge's staged site is whole;
    the same cut at a member boundary, with a byte changed, with a member
    dropped, and with its manifest removed, are each refused."""
    import subprocess
    import tarfile as tf
    import tempfile
    import time
    import urllib.parse
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(os.path.dirname(here), "probe"))
    import judge_gopher as G
    gopher_root = os.path.dirname(os.path.abspath(binary))
    while not os.path.isfile(os.path.join(gopher_root, "pages", "home.txt")):
        if gopher_root == os.path.dirname(gopher_root):
            print(f"self-test cannot run: no angry-gopher checkout above {binary}")
            return 2
        gopher_root = os.path.dirname(gopher_root)
    failures = []
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, gopher_root)
        server = G.LinuxServer(binary, site, os.path.join(d, "server.log"))
        try:
            body = "password=" + urllib.parse.quote_plus(G.MEMBER_PASSWORD)
            a = G.ask(server.port, G.step("backup", "POST", "/admin/backup",
                                          G.mint_session("1", int(time.time())), body), d)
        finally:
            server.stop()
        if a.get("status") != 200:
            print(f"self-test FAILED: the backup answered {a.get('status')}")
            return 1
        whole = a["body"]

    problems, files, size = check(whole)
    if problems or files < 5:
        failures.append(f"a whole archive: {problems}, {files} files")

    t = tf.open(fileobj=io.BytesIO(whole))
    ms = t.getmembers()
    cut = whole[:ms[-3].offset]  # just before a member: what tar reads as complete
    if not check(cut)[0]:
        failures.append("an archive cut at a member boundary passed")
    if not tarfile_lists(cut):
        failures.append("(the cut archive should still list cleanly, as the review measured)")

    def rebuild(change):
        out = io.BytesIO()
        with tf.open(fileobj=out, mode="w", format=tf.USTAR_FORMAT) as w:
            for m in ms:
                data = t.extractfile(m).read() if m.isfile() else None
                got = change(m, data)
                if got is None:
                    continue
                m2 = tf.TarInfo(m.name)
                m2.type, m2.mode, m2.mtime = m.type, m.mode, m.mtime
                if data is not None:
                    m2.size = len(got)
                    w.addfile(m2, io.BytesIO(got))
                else:
                    w.addfile(m2)
        return out.getvalue()

    secret = next(m.name for m in ms if m.name.endswith("_session_secret"))
    flipped = rebuild(lambda m, data: (bytes([data[0] ^ 1]) + data[1:]) if m.name == secret else (data if data is not None else b""))
    if not any("SHA-256" in p for p in check(flipped)[0]):
        failures.append(f"a changed byte was not caught: {check(flipped)[0]}")
    dropped = rebuild(lambda m, data: None if m.name == secret else (data if data is not None else b""))
    if not check(dropped)[0]:
        failures.append("a dropped member was not caught")
    bare = rebuild(lambda m, data: None if m.name == MANIFEST else (data if data is not None else b""))
    if not any("no backup-manifest.txt" in p for p in check(bare)[0]):
        failures.append("an archive with no manifest was not refused")
    for p in check(flipped)[0] + check(dropped)[0]:
        if "_session_secret" in p or "data/" in p:
            failures.append(f"a problem names the data: {p}")

    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"self-test passed: a real archive ({files} files) whole; cut at a member boundary, "
          "a byte changed, a member dropped and the manifest removed each refused, naming no file")
    return 0


def tarfile_lists(archive: bytes) -> bool:
    try:
        tarfile.open(fileobj=io.BytesIO(archive)).getmembers()
        return True
    except (tarfile.TarError, EOFError):
        return False


if __name__ == "__main__":
    sys.exit(main(sys.argv))
