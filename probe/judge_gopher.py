#!/usr/bin/env python3
"""The verdict on probe/gopher.zig: the same request, answered twice.

    judge_gopher.py <gopher.elf> <linux zig-server binary> <angry-gopher root> <work dir>

**LINUX IS THE ORACLE.** The claim is that porting angry-gopher to a machine
with no operating system changes nothing about what it serves. So every request
below goes to two servers built from the same source:

  - the kernel, booted in QEMU with the site on a GPT disk whose first
    partition is FAT16 (FAT=32: FAT32) — one boot for all the single requests,
    or one each with JUDGE_ISOLATED=1; JUDGE_DROPLET=1 boots the droplet's
    machine instead, with chat's data on a SCSI volume;
  - the ordinary Linux build, run over a copy of the same files.

and the answers must agree: status, Location, Set-Cookie, Content-Type, and the
body byte for byte. /version is compared field by field, since it names the
build and reports live memory by design.

**EVERY CASE STARTS FROM THE SAME STATE ON BOTH SIDES** — a fresh copy of the
disk for the kernel, and a fresh copy of the files and a fresh server for
Linux — because several requests write, and a write on one side must not leak
into the next case's comparison.

**A WRITE IS JUDGED TWICE.** After it, the files it touched are read back —
off the kernel's disk (mtools, below), and straight off the Linux server's
directory — and must match, and the kernel's disk must pass fsck.

**TIME.** Routes that stamp the wall clock write a different second on each
side. A Unix time is replaced with <NOW> only if it lies inside the window in
which THAT side handled the request; a kernel whose clock was wrong would leave
a bare number, and the comparison would fail. Times staged into the fixture
(1758000000) are nowhere near either window, so pages that render them are
compared exactly — including the Eastern-time formatting.

The kernel's disk is populated and read with mtools, which needs no root
(QUEUE.md item 64). JUDGE_MOUNT=1 does it through Linux's vfat driver, a loop
mount, instead: another independent reader, which needs `sudo -n`, and without
it the whole check is SKIPPED (exit 77) and says so.

Exit 0 when every case agrees, 1 when any does not, 77 when it could not run.
"""
import base64
import calendar
import hashlib
import hmac
import http.client
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import datetime
import zoneinfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import verdicts  # noqa: E402  the application's assets.zon, read once

SECTOR = 512
PART_FIRST = 2048
STAGED_TIME = 1758000000

# Two chat members, both with the bcrypt hash golang.org/x/crypto wrote for
# angry-gopher's old server — so logging in also exercises the `$2a$` path.
MEMBER_PASSWORD = "correct horse battery staple"
MEMBER_HASH = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza"
SESSION_SECRET = b"gopher-metal judge secret, 32+ bytes of it"  # bytes the pinned MACs were checked with
P1 = "gopher_uid=1"
GAME1 = "data/lynrummy/1"


def case(name, method, path, cookie=None, body=None, files=()):
    return {"name": name, "method": method, "path": path, "cookie": cookie, "body": body,
            "files": list(files)}


CASES = [
    # ── pages, identity and gates ──────────────────────────────────────────
    case("index", "GET", "/"),
    case("index as a player", "GET", "/", P1),
    case("driving (embedded)", "GET", "/driving"),
    case("chess index", "GET", "/chess"),
    case("resume (markdown from the volume)", "GET", "/steve-resume"),
    case("resume pdf (27 KB from the volume)", "GET", "/steve-resume.pdf"),
    case("safari download page", "GET", "/safari_download"),
    # The two native builds, from the site disk's downloads/ (angry-gopher's
    # ops/build_downloads): megabytes, each read whole into a request's heap.
    case("download, Windows (1 MB from the volume)", "GET", "/downloads/safari-windows.scr"),
    case("download, Linux (4.5 MB from the volume)", "GET", "/downloads/safari-linux"),
    case("download, not there", "GET", "/downloads/nope"),
    case("unknown path", "GET", "/nope"),
    case("prefix boundary", "GET", "/drivingX"),
    case("old login door", "GET", "/login"),
    case("password gate", "GET", "/login/full"),
    case("admin, anonymous", "GET", "/admin"),
    case("admin, a bare uid is not a member", "GET", "/admin", P1),
    case("version", "GET", "/version"),

]


# ── one boot, many requests ──────────────────────────────────────────────────
#
# A STORY, told to one kernel and to one Linux server. "$JAR" is the gopher_uid
# cookie that side's own earlier response set, so each side carries its own
# state forward. A step with `raw` sends those bytes on a bare socket instead of
# an HTTP request, and the answer compared is whatever comes back before close.

JAR = "$JAR"


def step(name, method, path, cookie=None, body=None, raw=None, headers=(), settle=0.0, expect=()):
    """One request in a story. `settle` waits before sending it.

    **A WAIT IS NOT A WORKAROUND HERE; IT IS THE RESOLUTION OF A FAT16 DATE.**
    /chat/recent orders conversations by file modification time, and FAT16
    stores that in whole EVEN seconds while ext4 stores nanoseconds. Two writes
    300 ms apart are ordered on Linux and tied on metal — so asking both sides
    for the same order would be asking FAT16 to be ext4. Where the story cares
    about the order of two events, it makes them far enough apart that the
    coarser clock can tell them apart, and then demands exact agreement."""
    return {"name": name, "method": method, "path": path, "cookie": cookie, "body": body,
            "raw": raw, "files": [], "headers": list(headers), "settle": settle,
            "expect": list(expect)}


# **THE WIRE, NOT THE GAME.** This was a Lyn Rummy player's story — names
# herself, plays, moves, annotates — and Lyn Rummy stays on the Linux droplet.
# What it carried that is not about the game is what a server has to survive on
# an open socket, so those steps moved into the member story below rather than
# being deleted with it.

def mint_session(uid: str, issued: int) -> str:
    """A __Host-gopher_auth cookie made HERE, from the staged secret and the format in
    users.zig's signSession — not by either server. Both must honor a fresh one
    and refuse a stale one, which is session expiry, which is what the kernel's
    wall clock exists for."""
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    mac = hmac.new(SESSION_SECRET, f"{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"__Host-gopher_auth={b64(uid.encode())}.{issued}.{b64(mac)}"


def forge_session(claimed: str, signed_for: str, issued: int) -> str:
    """A cookie that CLAIMS `claimed` but carries the valid MAC for
    `signed_for` — what someone holding their own session would try."""
    real = mint_session(signed_for, issued)            # __Host-gopher_auth=<id>.<t>.<mac>
    _, _, rest = real.partition(".")                   # <t>.<mac>
    b64 = base64.urlsafe_b64encode(claimed.encode()).rstrip(b"=").decode()
    return f"__Host-gopher_auth={b64}.{rest}"


FRESH = "$FRESH"      # minted when the story starts: must be honored
STALE = "$STALE"      # minted 400 days back: must be refused
FORGED = "$FORGED"    # a fresh one with the MAC of another id: must be refused
MEMBER2 = "$MEMBER2"  # a fresh, honest session for uid 2, a member who is not the admin
FORGED_UID = "$FORGED_UID"  # gopher_uid for p1, signed with another secret: must be no one


def mint_uid(uid: str, issued: int, secret: bytes = SESSION_SECRET) -> str:
    """A signed __Host-gopher_uid made HERE, in uid_cookie.zig's format: a
    label of its own, so no session's MAC passes as one. (An unsigned
    `gopher_uid=` in a step is the legacy spelling on purpose: it is read
    under its legacy name until angry-gopher's http.legacy_names_until_unix,
    2026-11-15, and those steps must go by then.)"""
    mac = hmac.new(secret, f"gopher_uid\n{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"__Host-gopher_uid={uid}.{issued}.{base64.urlsafe_b64encode(mac).rstrip(b'=').decode()}"

# 80 characters, the most chat_store.validSessionID allows.
LONG_TOPIC = ("a-topic-whose-name-is-as-long-as-a-topic-name-may-be-" + "x" * 80)[:80]

MEMBER_STORY = [
    step("chat, anonymous", "GET", "/chat"),
    step("a wrong password", "POST", "/login/full", None,
         "name=Steve&password=hunter2&action=login&next=%2Fchat"),
    # **A BODY THAT COMES AFTER ITS HEAD** (angry-gopher's server.zig): the
    # Linux server read such a body over its head in the read buffer, and
    # routed the request by the body's bytes (a login answered 404).
    # It asks for `Connection: close`: a raw step compares the answers' bytes,
    # headers and all, and since zig-webbox's keep-alive (metal-vmm QUEUE 213)
    # Linux may keep an HTTP/1.1 connection open where metal always closes
    # it, so unasked the two differ by that one header (`connection: close`),
    # which is not what this step is about.
    step("a wrong password, its body sent after its head", "RAW", "-", raw=[
        b"POST /login/full HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
        b"Content-Type: application/x-www-form-urlencoded\r\n"
        b"Content-Length: 65\r\n\r\n",
        b"name=Steve&password=hunter2&action=login&next=%2Fchat&pad=xxxxxxx"]),
    step("the right one (a $2a$ hash)", "POST", "/login/full", None,
         "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat"),
    step("chat, with no conversations yet", "GET", "/chat", JAR),
    step("the running server, as the admin", "GET", "/admin/host", JAR),
    step("the conversations API", "GET", "/chat/conversations", JAR),
    step("a message, as a form post", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=hello+from+bare+metal&cid=c1"),
    step("a message, async, with markdown", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=**bold**+and+%60code%60&cid=c2", headers=["X-Chat-Async: 1"]),
    step("hostile markdown is refused at the door", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=" + "%5B" * 300 + "&cid=c3", headers=["X-Chat-Async: 1"]),
    step("the conversation page", "GET", "/chat/c/1_2/general", JAR),
    step("the raw transcript", "GET", "/chat/c/1_2/general/raw", JAR),
    step("chat now resumes the conversation", "GET", "/chat", JAR),
    # 3 seconds: more than FAT16's two-second granularity, so "metal-talk was
    # written after general" is a fact both filesystems can hold. /chat/recent
    # below is judged on the order it produces.
    step("a new topic", "POST", "/chat/c/1_2/new", JAR, "topic=metal-talk", settle=3.0),
    step("a message in it", "POST", "/chat/c/1_2/metal-talk/send", JAR,
         "markdown=a+second+topic&cid=c4", headers=["X-Chat-Async: 1"]),
    # **CASE DOES NOT TELL TOPICS APART** (Steve's option 1, 2026-10-02): on
    # FAT it cannot, and angry-gopher's Store keeps that rule on Linux too. So
    # a topic asked for, or written to, in another case is the same topic on
    # both hosts.
    step("the new topic, asked for in another case", "GET", "/chat/c/1_2/METAL-TALK/raw", JAR),
    step("a message to it, in a third case", "POST", "/chat/c/1_2/Metal-Talk/send", JAR,
         "markdown=the+same+topic&cid=c5", headers=["X-Chat-Async: 1"]),
    step("the topic holds both messages", "GET", "/chat/c/1_2/metal-talk/raw", JAR),
    # **A TOPIC'S DOWNLOAD, AT THE LONGEST NAME** (QUEUE B27): its bundle's
    # names are `<topic>/<topic>.md` and `<topic>/<topic>.reactions.jsonl`,
    # past ustar's 100-byte name field at this length; cut there, they were
    # one name, and unpacking wrote the reactions over the transcript.
    step("a topic of the longest name", "POST", "/chat/c/1_2/new", JAR, "topic=" + LONG_TOPIC, settle=3.0),
    step("a message in it", "POST", f"/chat/c/1_2/{LONG_TOPIC}/send", JAR,
         "markdown=the+longest+name&cid=c6", headers=["X-Chat-Async: 1"]),
    step("a reaction in it", "POST", f"/chat/c/1_2/{LONG_TOPIC}/react", JAR, "msg=1&emoji=%F0%9F%91%8D"),
    step("its download", "GET", f"/chat/c/1_2/{LONG_TOPIC}/download", JAR),
    # `msg` is the message's number in its topic. This step once posted
    # `id=general_1`, which both hosts refused alike (400), so it reacted to
    # nothing and still compared equal; the members story now requires it to
    # land (QUEUE.md item 38).
    step("a reaction", "POST", "/chat/c/1_2/general/react", JAR, "msg=1&emoji=%F0%9F%91%8D"),
    step("the reactions file", "GET", "/chat/c/1_2/general/reactions", JAR),
    step("recent activity", "GET", "/chat/recent", JAR),
    step("docs", "GET", "/chat/docs", JAR),
    step("links", "GET", "/chat/links", JAR),
    step("settings", "GET", "/settings", JAR),
    step("the admin roster (Steve is uid 1)", "GET", "/admin", JAR),
    # Everything the Store keeps, as one tar (QUEUE.md item 35): compared by
    # its members, not its bytes, whose file times differ by host.
    # It asks for the password again (QUEUE.md item 57): the session alone is
    # a form, compared as a page; the archive is the answer to the password,
    # and must end with a manifest that holds (droplet/check_backup.py).
    step("the backup's form", "GET", "/admin/backup", JAR),
    step("the backup", "POST", "/admin/backup", JAR, "password=correct+horse+battery+staple"),
    step("the game roster", "GET", "/admin/lynrummy", JAR),
    step("someone else's DM is not his", "GET", "/chat/c/2_9/general", JAR),
    step("a session minted outside both servers", "GET", "/chat/conversations", FRESH),
    step("a session 400 days old", "GET", "/chat/conversations", STALE),
    step("a forged session", "GET", "/chat/conversations", FORGED),
    # **THE LOG AS TEXT, FOR AGENTS** (metal-vmm QUEUE 189.3): whole, by one
    # path, and a filter spelled wrong (a 400 alike on both hosts). Last
    # before logging out, so it holds the story's messages and sign-ins.
    step("the host's log as text, as the admin", "GET", "/admin/log", JAR),
    step("the host's log, this boot's chat requests", "GET", "/admin/log?path=/chat&boot=this", JAR),
    step("the host's log, a filter spelled wrong", "GET", "/admin/log?since=yesterday", JAR),
    step("logging out", "POST", "/logout", JAR, "release=no"),
    step("chat, after logging out", "GET", "/chat", JAR),
    # **ONLY THE ADMIN** (REVIEW-admin-host.md finding 2): the gate that
    # refuses /admin refuses this too, today because it is the same gate. These
    # ask /admin/host itself, so a dispatch that served it before the gate
    # fails. They come after logging out, so that nothing they set reaches a
    # later step that uses the jar.
    step("the running server, anonymous", "GET", "/admin/host"),
    step("the running server, as a bare uid", "GET", "/admin/host", P1),
    step("the running server, as a member who is not the admin", "GET", "/admin/host", MEMBER2),
    step("the host's log, anonymous", "GET", "/admin/log"),
    step("the host's log, as a bare uid", "GET", "/admin/log", P1),
    step("the host's log, as a member who is not the admin", "GET", "/admin/log", MEMBER2),
    # What arrives on a socket is not always a request, and a server that takes
    # one connection at a time has to survive each of these AND answer the next
    # caller. (These four came from the Lyn Rummy story, which is gone.)
    step("garbage on the wire", "RAW", "-", raw=b"this is not http\r\n\r\n"),
    step("still serving after garbage", "GET", "/nope"),
    step("a connection that says nothing", "RAW", "-", raw=b""),
    step("still serving after silence", "GET", "/chat"),
]


# **GOPHER_UID, SIGNED** (QUEUE.md item 51, DESIGN-signed-uid.md). The cookie
# that names a player was set in the clear, so whoever set it by hand was that
# player, or that guest. Now it is signed, and an unsigned one from before is
# re-signed once, on its owner's first GET, inside a window. The forged
# requests come FIRST, while the window is open and p1 not yet signed: the
# hole at its widest. A POST is never the re-signing, so they are no one.
UPGRADE_HEADING = b"Set a password to use chat"

UID_STORY = [
    step("a release with an unsigned cookie, before its owner's visit", "POST", "/logout",
         "gopher_uid=p1", "release=yes"),
    step("a guest upgrade with an unsigned cookie", "POST", "/login/full", "gopher_uid=7",
         "name=Gus&password=forged&action=login&next=%2F"),
    step("a member's id, hand-set", "GET", "/play", "gopher_uid=1"),
    step("a signature from another secret", "GET", "/play", FORGED_UID),
    step("a player names themselves", "POST", "/play", None, "name=Debbie&next=%2Fplay"),
    step("and is that player, signed", "GET", "/play", JAR),
    step("a legacy cookie's first visit is re-signed", "GET", "/play?next=/play", "gopher_uid=p1"),
    step("and the re-signed cookie is that player", "GET", "/play", JAR),
    # Within ten minutes the same unsigned cookie is re-signed again, so an
    # answer lost on the way recovers (item 63); a player named since item 51
    # never had an unsigned cookie, and its unsigned spelling is no one.
    step("the same unsigned cookie again, inside the grace, is re-signed again", "GET", "/play?next=/play",
         "gopher_uid=p1"),
    step("a new player's unsigned spelling is no one", "GET", "/play", "gopher_uid=p2"),
]


# **A PLAYER AT THE GAME STORE'S BOUND** (QUEUE.md item 52): one player's
# games may take 16 MiB. New games of 250,000 bytes each, until the store
# says no: every one before the bound is saved on both hosts, the first past
# it is a 507 that says why, and so is every one after. The trees then
# compare equal, so the bound fell at the same game on both.
CAP_GAME = "x" * 250_000
CAP_TRIES = 70  # 16 MiB / 250,000 bytes is 67 and a bit
P1_SIGNED = "$P1_SIGNED"

CAP_STORY = [step(f"new game {n + 1}", "POST", "/game/new-session", P1_SIGNED, CAP_GAME)
             for n in range(CAP_TRIES)] + [
    step("the player's games, listed", "GET", "/game/sessions", P1_SIGNED),
]


# **LYN RUMMY, ON BOTH** (QUEUE.md item 49). Metal serves the games too. A
# player arrives by name, starts a game and makes moves, starts a puzzle and
# moves in it, reloads both, and the admin's roster shows them. The files
# they write are compared at the end, as chat's are.
GAME_STATE = "hand:\n  AS KD 7H\nboard:\n  (empty)\n"
LYNRUMMY_STORY = [
    step("a player names themselves", "POST", "/play", None, "name=Lyn&next=%2Fgame"),
    step("the game page", "GET", "/game", JAR),
    step("a new game", "POST", "/game/new-session", JAR, GAME_STATE),
    step("a move", "POST", "/game/sessions/1/actions", JAR, "1) draw"),
    step("another move", "POST", "/game/sessions/1/actions", JAR, "2) meld AS KD"),
    step("an annotation", "POST", "/game/sessions/1/annotations", JAR, '{"note":"a good meld"}'),
    step("the game, reloaded", "GET", "/game/1", JAR),
    step("its state and moves, for the reload", "GET", "/game/sessions/1/actions", JAR),
    step("the player's games", "GET", "/game/sessions", JAR),
    step("the same, as JSON", "GET", "/game/api/sessions", JAR),
    step("the game's detail", "GET", "/game/sessions/1", JAR),
    step("a game never made", "POST", "/game/sessions/9/actions", JAR, "1) draw"),
    step("the puzzles page", "GET", "/puzzles", JAR),
    step("a puzzle's first move", "POST", "/puzzles/sessions/1/puzzles/0/actions", JAR, "1) move"),
    step("its second", "POST", "/puzzles/sessions/1/puzzles/0/actions", JAR, "2) move"),
    step("the puzzles page, reloaded", "GET", "/puzzles", JAR),
    step("the game roster", "GET", "/admin/lynrummy", FRESH),
]


# ENDURANCE: the writes, over and over, READ BACK EVERY ROUND.
#
# **STAMINA BELOW ONLY READS, AND A READ CANNOT LOSE ANYTHING.** Three GETs
# repeated 100 times prove the heaps hold steady, and prove nothing at all about
# whether what was written is still there. These rounds write to the two stores
# that matter — chat's transcript (a message appended to a conversation) and the
# game store (a move appended to a session) — and then ask for the whole thing
# back and require EVERY mark from EVERY earlier round to still be in it.
#
# So a write that lands in the wrong place, an append that truncates, a chain
# that breaks at a cluster edge, or an allocator that hands out memory twice
# shows up as a mark that has gone missing, at the round it went missing.
ENDURANCE_ROUNDS = 25


def mark(n: int) -> bytes:
    return f"mark-{n:04d}".encode()


def endurance_steps(rounds: int) -> list:
    steps = [step("log in", "POST", "/login/full", None,
                  "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat")]
    for n in range(1, rounds + 1):
        marks = [mark(i) for i in range(1, n + 1)]
        steps += [
            step(f"a message, round {n}", "POST", "/chat/c/1_2/general/send", JAR,
                 f"markdown={mark(n).decode()}&cid=e{n}", headers=["X-Chat-Async: 1"]),
            step(f"the whole transcript, round {n}", "GET", "/chat/c/1_2/general/raw", JAR,
                 expect=marks),
            step(f"the docs page, round {n}", "GET", "/chat/docs", JAR),
        ]
    return steps


ENDURANCE = endurance_steps(ENDURANCE_ROUNDS)


# STAMINA: the same few requests, many times, to one boot. Every answer must
# equal the first answer to that request, and the base heap — what survives
# between requests — must not grow once it has settled.
STAMINA_ROUNDS = 100
STAMINA = [
    step("index", "GET", "/"),
    step("the 27 KB pdf", "GET", "/steve-resume.pdf"),
    # Anonymous: stamina repeats one step a hundred times with no login before
    # it, so this asks for what a stranger gets — which must be the same answer
    # every time, which is the whole point of the boot.
    step("chat, anonymous", "GET", "/chat"),
]


# ── the site, staged once ────────────────────────────────────────────────────

def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def stage(root: str, gopher_root: str) -> None:
    # **WHAT THE APPLICATION READS AT REQUEST TIME, WHOLE** (Phase B step 3):
    # its zig-server/assets.zon names those directories (`.site`: pages/,
    # gallery/), where this named four pages by hand and a fifth would have
    # been missing here and on every image, served on Linux and not on metal.
    for d in verdicts.served_by(gopher_root)[1]:
        shutil.copytree(os.path.join(gopher_root, d), os.path.join(root, d))
    for d in ("data/lynrummy", "data/chat", "data/users", "auth"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    write(root, "data/players/1/name", "Steve")
    write(root, "auth/1/name", "Steve")
    write(root, "auth/1/password", MEMBER_HASH)
    write(root, "auth/2/name", "apoorva")
    write(root, "auth/2/password", MEMBER_HASH)
    write(root, "auth/next-id.txt", "3\n")
    # The session secret lives in auth/ now (QUEUE.md item 106): auth/ holds
    # every secret, data/ none. A tree written before the move keeps it in
    # data/chat/, and the server carries it over at boot — the `secret` gate
    # tests that migration; here the fixture is already in the new place.
    with open(os.path.join(root, "auth/_session_secret"), "wb") as f:
        f.write(SESSION_SECRET)
    write(root, "data/players/next-id.txt", "2\n")
    # **COOKIES FROM BEFORE THEY WERE SIGNED** (QUEUE.md item 51): a player
    # and a guest from then, and the window for re-signing their unsigned
    # cookies open (until 2100). This is a site before its cutover; CUTOVER.md
    # closes the window on the copy metal serves.
    write(root, "data/players/p1/name", "Nikhil")
    write(root, "auth/7/name", "Gus")
    write(root, "data/players/unsigned-window", "4102444800\n")
    # One finished game and one puzzle session for player 1, at a fixed time.
    write(root, f"{GAME1}/lynrummy-elm/sessions/1/meta",
          f"created_at: {STAGED_TIME}\nlabel: staged\n\nboard: the judge's fixture\n")
    write(root, f"{GAME1}/lynrummy-elm/sessions/1/actions.dsl", "1) draw\n2) meld\n")
    write(root, f"{GAME1}/next-session-id.txt", "2\n")
    write(root, f"{GAME1}/puzzle/sessions/1/meta", f"created_at: {STAGED_TIME}\n\ncatalog:\n  staged\n")
    write(root, f"{GAME1}/next-puzzle-id.txt", "2\n")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)


def partition_last(image: str) -> int:
    info = run(["sgdisk", "-i", "1", image]).stdout
    return int(next(l for l in info.splitlines() if l.startswith("Last sector")).split()[2])


# **THE CHAT JUDGE DEFAULTS TO FAT32** (QUEUE.md item 88): prod's data is a
# FAT32 volume now, so FAT32 is what the gate runs every time; `FAT=16` is the
# extra run, which gates.sh takes only when src/fat16*, src/io*, the judge or
# chat.py changed. build_disk formats FAT32 at 512-byte clusters, about
# 126,000 of them in 64 MiB (item 17, FAT32.md "Then the chat judge"). The
# site's own disk on the droplet machine stays FAT16 either way.
FAT_KIND = os.environ.get("FAT", "32")


def build_disk(image: str, content: str, mnt: str, size: int = 64 << 20,
               fat: str = None, cluster_sectors: int = None, label: str = "GOPHER") -> None:
    """A GPT disk of `size` bytes whose first partition is FAT16 (or FAT32
    with FAT=32, or `fat`), holding `content`, its volume label `label`.
    `cluster_sectors` is mkfs.vfat's -s: by default its own choice on FAT16,
    and 1 on FAT32, which a small judge's disk needs to reach FAT32's 65,525
    clusters."""
    fat = fat or FAT_KIND
    spc = cluster_sectors or (1 if fat == "32" else None)
    with open(image, "wb") as f:
        f.truncate(size)
    run(["sgdisk", "-o", "-n", f"1:{PART_FIRST}:0", "-t", "1:0700", "-c", "1:gopher", image])
    blocks = (partition_last(image) - PART_FIRST + 1) // 2
    run(["mkfs.vfat", "-F", fat, "-S", "512", *(["-s", str(spc)] if spc else []), "-n", label,
         "--offset", str(PART_FIRST), image, str(blocks)])
    disk_put(image, mnt, content)


def leak_a_cluster(image: str) -> int:
    """Marks the last free cluster of `image`'s volume in use in both FATs,
    with nothing holding it: what a write that stopped before its directory
    entry leaves behind. Answers the cluster.

    **ON FAT32, AS THIS MACHINE'S OWN STOPPED WRITE WOULD LEAVE IT:** the
    entry is four bytes and the end mark 0x0FFFFFFF, and FSInfo's free count
    and hint are marked unknown in both copies, which disk_fat.zig does on the
    first write a mount makes (forgetFsInfo). Left as mkfs set it, the count
    is wrong by one, and the check rightly says so as a second problem."""
    sys.path.insert(0, TOOLS_DIR)
    import fat16_read
    with open(image, "rb") as f:
        data = bytearray(f.read())
    v = fat16_read.Volume(bytes(data))
    leaked = max(c for c in range(2, v.max_cluster + 1) if v.fat(c) == 0)
    end = 0x0FFFFFFF if v.kind == "FAT32" else 0xFFFF
    for k in range(v.nfats):
        at = v.base + (v.fat_start + k * v.fat_sectors) * SECTOR + leaked * v.entry_bytes
        data[at:at + v.entry_bytes] = end.to_bytes(v.entry_bytes, "little")
    if v.kind == "FAT32":
        for lba in (v.fsinfo_sector, v.backup_boot + 1):
            at = v.base + lba * SECTOR + 488
            data[at:at + 8] = b"\xff" * 8
    with open(image, "wb") as f:
        f.write(data)
    return leaked


def fat_serial(image: str) -> str:
    """The FAT serial of `image`'s first partition, as `blkid` spells it
    (`92DE-8831`): the boot sector's volume ID, at offset 39 on FAT16 and 67
    on FAT32. A FAT32 boot sector is one with no 16-bit FAT size (offset 22)
    and its extended boot signature, 0x29, at 66, where the serial follows;
    FAT16 keeps that signature at 38."""
    with open(image, "rb") as f:
        f.seek(PART_FIRST * SECTOR)
        boot = f.read(SECTOR)
    fat32 = len(boot) > 70 and int.from_bytes(boot[22:24], "little") == 0 and boot[66] == 0x29
    at = 67 if fat32 else 39
    n = int.from_bytes(boot[at:at + 4], "little")
    return f"{n >> 16:04X}-{n & 0xFFFF:04X}"


def mount(image: str, mnt: str, writable: bool) -> None:
    """**tz=UTC**: vfat stores local times, and zig-metal-unikernel reads FAT times as
    UTC. Without it, on a host whose zone is not UTC every file written or read
    through this mount would be off by the host's offset, and chat's "recent",
    which is ordered by modification time, with it (MIGRATION.md)."""
    os.makedirs(mnt, exist_ok=True)
    opts = f"loop,offset={PART_FIRST * SECTOR},noexec,nosuid,nodev,tz=UTC,uid={os.getuid()},gid={os.getgid()}"
    if not writable:
        opts += ",ro"
    run(["sudo", "-n", "mount", "-o", opts, image, mnt])


def umount(mnt: str) -> None:
    run(["sudo", "-n", "umount", mnt])


# ── the kernel's disk, two ways (QUEUE.md item 64) ──────────────────────────
#
# **mtools BY DEFAULT, LINUX'S vfat WITH JUDGE_MOUNT=1.** Every file the judge
# puts on the kernel's disk, and every file it reads back off it, goes through
# one of two readers that are not the kernel's own: mtools, which needs no
# root and so runs anywhere (a cloud container included), or the Linux vfat
# driver through a loop mount, which needs `sudo -n`. They are independent
# oracles, and the box runs both. Each helper takes the mount point the
# mount path uses; the mtools path ignores it.

MOUNT = os.environ.get("JUDGE_MOUNT") == "1"
MTOOLS_ENV = dict(os.environ, TZ="UTC", MTOOLS_SKIP_CHECK="1")


def _at(image: str, partitioned: bool = True) -> str:
    """mtools' name for the filesystem: the partition at PART_FIRST, or a
    bare filesystem image."""
    return f"{image}@@{PART_FIRST * SECTOR}" if partitioned else image


def _mt(*args):
    return run(list(args), env=MTOOLS_ENV)


def disk_names(image: str, partitioned: bool = True) -> list:
    """The entries in the volume's root, by name."""
    out = _mt("mdir", "-b", "-i", _at(image, partitioned), "::/").stdout
    return [line[3:].rstrip("/") for line in out.splitlines() if line.startswith("::/")]


def disk_put(image: str, mnt: str, src: str, partitioned: bool = True) -> None:
    """Every entry of the folder `src` into the volume's root, with its
    modification times."""
    if MOUNT:
        if partitioned:
            mount(image, mnt, writable=True)
        else:
            os.makedirs(mnt, exist_ok=True)
            run(["sudo", "-n", "mount", "-o", f"loop,tz=UTC,uid={os.getuid()},gid={os.getgid()}", image, mnt])
        try:
            for entry in os.listdir(src):
                s_, d_ = os.path.join(src, entry), os.path.join(mnt, entry)
                if os.path.isdir(s_):
                    shutil.copytree(s_, d_, dirs_exist_ok=True)
                else:
                    shutil.copy2(s_, d_)
        finally:
            umount(mnt)
        return
    for entry in sorted(os.listdir(src)):
        _mt("mcopy", "-s", "-m", "-o", "-D", "o", "-i", _at(image, partitioned), os.path.join(src, entry), "::/")


def disk_write(image: str, mnt: str, name: str, text: str) -> None:
    """One file, `name`, in the volume's root, holding `text`."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
        disk_put(image, mnt, d)


def disk_take(image: str, mnt: str, dest: str, names=None, remove: bool = False) -> None:
    """The volume root's entries (`names`, or all of them) into the folder
    `dest`, with their times; with `remove`, they are then deleted from the
    volume (moved, not copied)."""
    os.makedirs(dest, exist_ok=True)
    if MOUNT:
        mount(image, mnt, writable=remove)
        try:
            for entry in os.listdir(mnt):
                if names is not None and entry not in names:
                    continue
                s_, d_ = os.path.join(mnt, entry), os.path.join(dest, entry)
                if remove:
                    shutil.move(s_, d_)
                elif os.path.isdir(s_):
                    shutil.copytree(s_, d_)
                else:
                    shutil.copy2(s_, d_)
        finally:
            umount(mnt)
        return
    at = _at(image)
    for entry in disk_names(image):
        if names is not None and entry not in names:
            continue
        _mt("mcopy", "-s", "-m", "-n", "-i", at, f"::/{entry}", dest)
        if remove:
            if os.path.isdir(os.path.join(dest, entry)):
                _mt("mdeltree", "-i", at, f"::/{entry}")
            else:
                _mt("mdel", "-i", at, f"::/{entry}")


def disk_read(image: str, mnt: str, rels) -> dict:
    """{rel: its bytes, or None when it is not there}, for each path."""
    out = {}
    if MOUNT:
        mount(image, mnt, writable=False)
        try:
            for rel in rels:
                out[rel] = read_or_none(os.path.join(mnt, rel))
        finally:
            umount(mnt)
        return out
    with tempfile.TemporaryDirectory() as d:
        for i, rel in enumerate(rels):
            got = os.path.join(d, str(i))
            r = subprocess.run(["mcopy", "-n", "-i", _at(image), f"::/{rel}", got],
                               env=MTOOLS_ENV, capture_output=True)
            out[rel] = read_or_none(got) if r.returncode == 0 and os.path.isfile(got) else None
    return out


# ── asking a server ─────────────────────────────────────────────────────────

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def ask_raw(port: int, payload) -> dict:
    """Bytes on a bare socket, and whatever comes back before the server closes.
    `payload` may be a list of parts, sent a fifth of a second apart: a body
    that comes after its head, as most clients send one."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=15)
    except OSError as e:
        return {"error": f"raw socket: {e}"}
    try:
        parts = payload if isinstance(payload, list) else [payload]
        for i, part in enumerate(parts):
            if i > 0:
                time.sleep(0.2)
            if part:
                s.sendall(part)
        s.shutdown(socket.SHUT_WR)
        got = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            got += chunk
    except OSError as e:
        return {"error": f"raw socket: {e}"}
    finally:
        s.close()
    return {"status": 0, "headers": {}, "body": got}


def with_jar(c: dict, jar, minted=None):
    """The step with a cookie placeholder resolved: "$JAR" is every cookie this
    side's own responses have set; the minted ones are shared by both sides."""
    cookie = c.get("cookie")
    if cookie == JAR:
        if not jar:
            return dict(c, cookie=None)
        if isinstance(jar, str):
            return dict(c, cookie=jar)
        return dict(c, cookie="; ".join(f"{k}={v}" for k, v in jar.items()))
    if minted and cookie in minted:
        return dict(c, cookie=minted[cookie])
    return c


def ask(port: int, c: dict, scratch: str, patience: int = 400) -> dict:
    """One request by Python's own HTTP client. It never follows a redirect:
    the redirect IS the answer being compared.

    **ONLY A REFUSED CONNECTION IS TRIED AGAIN**, once a second, for up to
    `patience` seconds — a guest still coming up. A request that was sent is
    never sent twice: a POST retried after a reset would write twice, and a
    failure that retrying hides is a failure the judge should report. (This
    was curl, whose process cost nine milliseconds a request and whose
    `--retry-all-errors` resent anything.) `scratch` is kept for callers that
    pass one."""
    if c.get("raw") is not None:
        return ask_raw(port, c["raw"])
    headers = {"Host": f"127.0.0.1:{port}", "User-Agent": "zig-metal-unikernel-judge", "Accept": "*/*"}
    if c["cookie"]:
        headers["Cookie"] = c["cookie"]
    body = None
    if c["body"] is not None:
        body = c["body"].encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    for h in c.get("headers", ()):
        k, v = h.split(":", 1)
        headers[k.strip()] = v.strip()
    deadline = time.time() + patience
    while True:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=min(30, patience))
        try:
            conn.connect()
            break
        except ConnectionRefusedError as e:
            conn.close()
            if time.time() + 1 > deadline:
                return {"error": f"connection refused for {patience} s: {e}"}
            time.sleep(1)
        except OSError as e:
            conn.close()
            return {"error": f"connect: {e}"}
    try:
        conn.request(c["method"], c["path"], body=body, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
    except (OSError, http.client.HTTPException) as e:
        return {"error": f"{type(e).__name__}: {e}"}
    finally:
        conn.close()
    answer_headers = {}
    for k, v in resp.getheaders():
        k, v = k.strip().lower(), v.strip()
        # Several Set-Cookie headers are several cookies; keep them all, in
        # order, rather than the last.
        answer_headers[k] = answer_headers[k] + "\n" + v if k == "set-cookie" and k in answer_headers else v
    return {"status": resp.status, "headers": answer_headers, "body": payload}


def request_limit_text(image: str, n: int, idle_timeout_ms: int = 10000, streams: int = None,
                       lose_one_sent_in: int = None, keepalive_ms: int = None) -> str:
    """zig-metal-unikernel.conf for a boot that serves `n` requests."""
    text = f"requests = {n}\nidle_timeout_ms = {idle_timeout_ms}\n"
    # On the droplet machine, the card chat will really serve on, and
    # the volume it must find: the judge's own disk, by its serial.
    if DROPLET:
        text += f"card = private\nvolume = {fat_serial(image)}\n"
    if streams is not None:
        text += f"streams = {streams}\n"
    if lose_one_sent_in is not None:
        text += f"lose_one_sent_in = {lose_one_sent_in}\n"
    if keepalive_ms is not None:
        text += f"keepalive_ms = {keepalive_ms}\n"
    return text


def set_request_limit(image: str, n: int, mnt: str, **conf) -> None:
    disk_write(image, mnt, "zig-metal-unikernel.conf", request_limit_text(image, n, **conf))


# **THE QUICK TIER.** With JUDGE_QUICK set, the machine's waits are
# test-sized — a three-second stream keepalive, sub-second silent-client
# timeouts — and the boots that exist to be long are left out. The full run
# keeps the real values; both prove the configured number is what governs.
QUICK = bool(os.environ.get("JUDGE_QUICK"))

# **ONE GATE AT A TIME, WHEN THAT IS WHAT THE QUESTION IS.** Every gate here
# boots QEMU, and the whole run is minutes; a change to one of them should be
# answerable in one of those minutes. `JUDGE_ONLY=uploads` (probe/run.sh gopher
# uploads) runs that gate and nothing else. An unknown name is an error, not a
# silently complete run.
GATES = ["cases", "members", "uids", "caps", "lynrummy", "streams-linux", "streams-metal", "budget", "churn",
         "bulk", "uploads", "lagging", "concurrent",
         "damaged", "endurance", "stamina", "admin-reset", "throttle", "retire", "secret", "shale-background"]
# The boots that exist to be long. The quick tier leaves them out; asking for
# one by name still runs it.
LONG = {"endurance", "stamina"}
# **A BOOT PER SINGLE REQUEST** — what proves an answer owes nothing to an
# earlier one. It costs fifteen boots, so it is what a push is judged on
# (`probe/run.sh gopher isolated`), not what every run pays for.
ISOLATED = bool(os.environ.get("JUDGE_ISOLATED"))

# **A PACKET CAPTURE, WHEN ASKED FOR.** With JUDGE_CAPTURE set, every boot
# writes what crossed its NIC to `net.pcap` beside its serial log, for tcpdump.
CAPTURE = bool(os.environ.get("JUDGE_CAPTURE"))


# **JUDGE_DROPLET=1: THE SAME JUDGE, ON A DROPLET'S MACHINE.** Every boot
# splits the judge's disk in two, as a droplet's are (`split_site_off`). The
# site's own files and the kernel's settings go on a droplet boot disk, as its
# partition 2 after the loader and the kernel (droplet/image.sh). The judge's
# own disk, now holding only `data/` and `auth/`, is attached as a
# DigitalOcean volume: a disk on the SCSI controller in slot 05. That is where
# the kernel keeps chat's data on a real droplet, and QEMU writes to the
# judge's disk in place, so there is nothing to copy back.
# It boots on droplet/droplet.sh's machine (a PC, devices on PCI, the BIOS
# reading the disk), on its private card (`card = private`, as the droplet's
# chat image says). Nothing else in the judge knows: every answer and every
# file is compared with Linux exactly as on microvm. The droplet machine always
# runs under KVM, as a real droplet does, so `kvm` asks nothing more of it.
DROPLET = os.environ.get("JUDGE_DROPLET") == "1"
TOOLS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
DROPLET_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "droplet")
droplet_boots = {}
# How many boots went through the boot loader and served from the volume, for
# the verdict line: a green that never took the droplet path must not read as
# one that did.
loader_boots = 0


# The application's data: what the kernel keeps on the volume, and all that
# `tree` compares. Everything else on the judge's disk is the site's own.
DATA_DIRS = ("data", "auth")


def split_site_off(image: str, scratch: str) -> str:
    """**TWO DISKS, AS ON A DROPLET.** Moves everything that is not the
    application's data off `image` (the volume) into a FAT16 filesystem image
    for the boot disk's partition 2, and returns its path. Moved, not copied:
    a kernel that looked for a page or its settings on the volume must find
    nothing there."""
    mnt = os.path.join(scratch, "split")
    site = os.path.join(scratch, "site")
    os.makedirs(site)
    names = [n for n in _root_names(image, mnt) if n not in DATA_DIRS]
    disk_take(image, mnt, site, names=names, remove=True)
    if not os.listdir(site):
        raise RuntimeError(f"nothing but data on {image}: was its site split off already?")
    fat = os.path.join(scratch, "site.fat")
    run(["mkfs.vfat", "-F", "16", "-S", "512", "-n", "SITE", "-C", fat, str(32 * 1024)])
    disk_put(fat, mnt, site, partitioned=False)
    return fat


def _root_names(image: str, mnt: str) -> list:
    """The volume root's entries, through whichever reader is in use."""
    if not MOUNT:
        return disk_names(image)
    mount(image, mnt, writable=False)
    try:
        return os.listdir(mnt)
    finally:
        umount(mnt)


def restore_site(image: str, site: str, mnt: str) -> None:
    """Puts back on `image` the site files split_site_off moved from it into
    `site`: copied, since the story's own split keeps its copy."""
    disk_put(image, mnt, site)


def droplet_start(elf: str, image: str, scratch: str, port: int, serial_log):
    disk = os.path.join(scratch, "droplet.img")
    run([os.path.join(DROPLET_DIR, "image.sh"), elf, disk, split_site_off(image, scratch)])
    # The judge's requests arrive on the private card, which is the one
    # `card = private` (set_request_limit) has the kernel serve.
    env = dict(os.environ, DISK=disk, VOLUME=image, PRIVATE_FWD=str(port), MEMORY="512",
               ACCEL="kvm" if kvm_usable() else "tcg")
    qemu = subprocess.Popen([os.path.join(DROPLET_DIR, "droplet.sh")], env=env,
                            stdout=serial_log, stderr=subprocess.STDOUT)
    droplet_boots[qemu.pid] = disk
    return qemu


def microvm_start(elf: str, image: str, scratch: str, port: int, serial_log, kvm: bool):
    return subprocess.Popen([
        # rtc=on: under KVM microvm leaves the CMOS clock out unless asked,
        # and this kernel reads it. See probe/run.sh.
        "qemu-system-x86_64", "-M", "microvm,rtc=on,pit=on", "-kernel", elf,
        *(["-enable-kvm"] if kvm else []),
        "-nographic", "-no-reboot", "-m", "512",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        # cache=unsafe: a flush is not a sync of the box's disk (droplet.sh
        # says why).
        "-drive", f"id=d,file={image},format=raw,if=none,cache=unsafe",
        "-device", "virtio-blk-device,drive=d",
        "-cpu", "max", "-device", "virtio-rng-device",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:80",
        "-device", "virtio-net-device,netdev=n0",
        *(["-object", f"filter-dump,id=cap,netdev=n0,file={os.path.join(scratch, 'net.pcap')}"]
          if CAPTURE else []),
    ], stdout=serial_log, stderr=subprocess.STDOUT)


def kvm_usable() -> bool:
    """Whether this user can open /dev/kvm right now."""
    return os.access("/dev/kvm", os.R_OK | os.W_OK)


def start_kernel(elf: str, image: str, scratch: str, kvm: bool = False):
    """Boots the kernel and returns (qemu, port, serial path) once it has said it
    is listening.

    **`kvm` IS FOR TIMING.** Without it the CPU is emulated in software (TCG),
    which is what every correctness check here has always run on and still
    does. A number meant to say how fast this machine is belongs on hardware
    virtualization — what a deployed machine would run on — so the soak asks
    for it, and refuses rather than quietly measuring TCG under KVM's name."""
    if kvm and not kvm_usable():
        raise RuntimeError("KVM was asked for and /dev/kvm is not usable by this user")
    port = free_port()
    serial = os.path.join(scratch, "serial")
    log = open(serial, "wb")
    if DROPLET:
        qemu = droplet_start(elf, image, scratch, port, log)
    else:
        qemu = microvm_start(elf, image, scratch, port, log, kvm)
    log.close()
    deadline = time.time() + 30
    while time.time() < deadline and qemu.poll() is None:
        with open(serial, "rb") as seen:
            if b"listening on port 80" in seen.read():
                break
        time.sleep(0.02)
    return qemu, port, serial


# ── the disk check (QUEUE.md item 13) ─────────────────────────────────────────
#
# **EVERY BOOT CHECKS ITS DISKS, AND EVERY BOOT SAYS SO.** gopher.zig runs
# fat16's Volume.check on each volume it mounts and prints one summary line
# each. finish_kernel requires that line for every disk the boot mounted, and
# 0 problems on it, unless the gate damaged the disk on purpose
# (`damaged=True`). What it finds goes into DISK_CHECK_FAILURES, which main
# counts and prints with the gates' failures, because finish_kernel is called
# from every gate and answers each of them the same way.

DISK_CHECK = re.compile(r"^  disk check, (.+?): (\d+) files, (\d+) directories, (\d+) clusters used, "
                        r"(\d+) leaked, (\d+) problems$", re.M)
DISK_CHECK_FAILURES = []


def disk_check_lines(log: str) -> dict:
    """Each `disk check` summary line in a boot's log, by the disk it names:
    {"the boot disk": {"files": .., "directories": .., "used": .., "leaked": ..,
    "problems": ..}}."""
    keys = ("files", "directories", "used", "leaked", "problems")
    return {m.group(1): dict(zip(keys, (int(g) for g in m.groups()[1:])))
            for m in DISK_CHECK.finditer(log)}


def image_disk(log: str) -> str:
    """Which `disk check` line is about the judge's own disk image: the volume
    on the droplet machine, where the image is chat's data and the boot disk is
    the site split off it; the boot disk everywhere else."""
    return "the volume" if "chat's data: the volume" in log else "the boot disk"


def disk_check_differences(log: str, damaged: bool = False) -> list:
    """What is wrong with a boot's disk-check lines: a mounted disk with none,
    a check that did not run, or (unless `damaged`) a problem found."""
    out = []
    lines = disk_check_lines(log)
    disks = ["the boot disk"] + (["the volume"] if "chat's data: the volume" in log else [])
    for disk in disks:
        if not re.search(rf"^  {re.escape(disk)}: FAT(16|32) at LBA", log, re.M):
            continue  # this boot never got as far as mounting it
        got = lines.get(disk)
        if got is None:
            not_run = re.search(rf"^  disk check, {re.escape(disk)}: (.*)$", log, re.M)
            out.append(f"the disk check of {disk}: " + (not_run.group(1) if not_run
                                                         else "no summary line"))
        elif got["problems"] and not damaged:
            found = re.findall(r"^    ([a-z_]+ at .*)$", log, re.M)
            out.append(f"the disk check of {disk} found {got['problems']} problem(s): "
                       + "; ".join(found[:3]))
    return out


def keep_coverage_lines(text: str):
    """**A KERNEL BUILT WITH -Dcoverage** writes its coverage properties to the
    port behind "coverage: " (COVERAGE.md). With COVERAGE_OUTPUT_DIR set,
    every boot's lines are appended to sdk.jsonl there; zig-coverage-sdk's
    tools/report.py judges the file."""
    out = os.environ.get("COVERAGE_OUTPUT_DIR")
    if not out:
        return
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "sdk.jsonl"), "a") as f:
        for l in text.splitlines():
            if l.startswith("coverage: "):
                f.write(l[len("coverage: "):].rstrip("\r") + "\n")


def use_up_requests(qemu, port: int, at_most: int) -> None:
    """**A BOOT ENDS AT ITS REQUEST LIMIT, NOT AT finish_kernel's 60 s.** A
    story that sends fewer requests than its boot's `requests =` leaves the
    guest serving, and finish_kernel then waits a minute and kills it, which
    also hides a guest that hangs. After the story, this asks `/version` until
    the guest stops on its own, at most `at_most` times; the gate then holds
    the exit to 1, the clean stop."""
    for _ in range(at_most):
        if qemu.poll() is not None:
            return
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request("GET", "/version")
            conn.getresponse().read()
            conn.close()
        except OSError:
            return


def finish_kernel(qemu, serial: str, damaged: bool = False):
    try:
        code = qemu.wait(timeout=60)
    except subprocess.TimeoutExpired:
        qemu.kill()
        qemu.wait()
        code = "timeout"
    if qemu.pid in droplet_boots:
        droplet_boots.pop(qemu.pid)
        global loader_boots
        said = open(serial, "rb").read()
        if b"zig-metal-unikernel loader" not in said:
            raise RuntimeError(f"a droplet boot that never printed the loader's line: {serial}")
        if b"chat's data: the volume" not in said:
            raise RuntimeError(f"a droplet boot that did not serve from the volume: {serial}")
        loader_boots += 1
    text = open(serial, "rb").read().decode("latin-1", "replace")
    keep_coverage_lines(text)
    lines = "\n".join(l for l in text.splitlines()
                      if l.strip() and "SeaBIOS" not in l and "\x1b" not in l)
    for d in disk_check_differences(lines, damaged):
        DISK_CHECK_FAILURES.append(f"{d} ({serial})")
    return code, lines


def ask_kernel(elf: str, image: str, c: dict, scratch: str, damaged: bool = False) -> dict:
    """One request to a fresh boot. The pristine disk says `requests = 1`, so
    the kernel stops once it has answered. `damaged`: the gate broke the disk
    on purpose, so its disk check is expected to find something."""
    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    answer = ask(port, c, os.path.join(scratch, "kernel"))
    answer["guest_exit"], answer["serial"] = finish_kernel(qemu, serial, damaged)
    answer["window"] = (int(before) - 1, int(time.time()) + 1)
    return answer


class LinuxServer:
    def __init__(self, binary: str, root: str, log: str):
        self.port = free_port()
        conf = os.path.join(root, "gopher.conf")
        with open(conf, "w") as f:
            # **RELATIVE, like the kernel's.** The server runs with cwd=root, so
            # `data` is the same directory either way — but the admin roster
            # PRINTS its data root on the page, and an absolute path here would
            # be a difference between two hosts' configuration rather than
            # between two answers.
            f.write("data_dir = data\nauth_dir = auth\n")
        # **NO FLOOR ON LINUX'S SIDE.** angry-gopher stops game writes when the
        # data's volume is under a quarter free (QUEUE.md item 52). Here that
        # volume is whatever disk this machine's temporary folder is on, which
        # says nothing about the server under test, and a full development
        # disk would refuse what the kernel, on its own image, takes.
        env = dict(os.environ, GOPHER_CONFIG=conf, GOPHER_PORT=str(self.port), GOPHER_GAME_FLOOR="off")
        self.log = open(log, "wb")
        # Popen gives the server's OWN pid, so stopping it stops it — not a
        # shell that happens to be its parent.
        self.proc = subprocess.Popen([binary], cwd=root, env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"the Linux server exited {self.proc.returncode}")
                time.sleep(0.05)
        raise RuntimeError("the Linux server never listened")

    def last_words(self) -> str:
        """The first panic in its log, or its last line."""
        self.log.flush()
        try:
            with open(self.log.name, "rb") as f:
                lines = f.read().decode("utf-8", "replace").splitlines()
        except OSError:
            return "no log"
        panics = [l for l in lines if "panic" in l]
        return (panics or lines or ["an empty log"])[0].strip()

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


def ask_linux(binary: str, content: str, c: dict, scratch: str) -> dict:
    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    before = time.time()
    server = LinuxServer(binary, root, os.path.join(scratch, "linux.log"))
    try:
        answer = ask(server.port, c, os.path.join(scratch, "linux-http"))
    finally:
        server.stop()
    answer["window"] = (int(before) - 1, int(time.time()) + 1)
    answer["root"] = root
    return answer


# ── the comparison ───────────────────────────────────────────────────────────

COMPARED_HEADERS = ("location", "set-cookie", "content-type")
UNIX_TIME = re.compile(rb"\b1[5-9]\d{8}\b")
RFC3339 = re.compile(rb"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b")
SESSION_MAC = re.compile(rb"\.<NOW>\.[A-Za-z0-9_-]{43}")


EASTERN = zoneinfo.ZoneInfo("America/New_York")


def eastern(unix: int) -> bytes:
    """angry-gopher's formatEastern, restated with Python's own time zone rules:
    `Sep 16, 2026 · 7:32 PM EDT`."""
    d = datetime.datetime.fromtimestamp(unix, EASTERN)
    return d.strftime("%b %-d, %Y · %-I:%M %p %Z").encode()


def normalize(data: bytes, window) -> bytes:
    """Replace a time with <NOW> — but only one inside `window`, the span in which
    this side handled the request. A time outside it is left as it is, so a
    wrong clock is a difference rather than a wildcard.

    Two spellings: a Unix time, and the Eastern wall-clock text the session
    pages render. The second is minute-precise, so every minute the window
    touches is tried."""
    lo, hi = window

    def sub(m):
        return b"<NOW>" if lo <= int(m.group(0)) <= hi else m.group(0)

    data = UNIX_TIME.sub(sub, data)

    def sub_rfc(m):
        t = calendar.timegm(time.strptime(m.group(0).decode(), "%Y-%m-%dT%H:%M:%SZ"))
        return b"<NOW-RFC3339>" if lo <= t <= hi else m.group(0)

    data = RFC3339.sub(sub_rfc, data)
    # A session cookie minted in the window: its MAC covers the time, so it
    # differs whenever the time does.
    data = SESSION_MAC.sub(b".<NOW>.<MAC>", data)
    for minute in range(lo - lo % 60, hi + 60, 60):
        data = data.replace(eastern(minute), b"<NOW-EASTERN>")
    return data


def differences(c: dict, metal: dict, linux: dict) -> list:
    if "error" in linux:
        return [f"the LINUX server did not answer: {linux['error']}"]
    if "error" in metal:
        return [f"the kernel did not answer: {metal['error']}"]
    out = []
    if metal["guest_exit"] != 1:
        tail = metal["serial"].splitlines()[-3:]
        out.append(f"the guest exited {metal['guest_exit']}, not cleanly: {' | '.join(tail)}")
    if metal["status"] != linux["status"]:
        out.append(f"status {metal['status']} on metal, {linux['status']} on Linux")
    for h in COMPARED_HEADERS:
        m, l = metal["headers"].get(h), linux["headers"].get(h)
        if m is not None:
            m = normalize(m.encode("latin-1"), metal["window"]).decode("latin-1")
        if l is not None:
            l = normalize(l.encode("latin-1"), linux["window"]).decode("latin-1")
        if m != l:
            out.append(f"{h}: metal {m!r}, Linux {l!r}")
    if c["path"] == "/version":
        out += version_differences(metal["body"], linux["body"])
    elif (c["path"] == "/admin/backup" and metal["status"] == 200 and linux["status"] == 200
          and "x-tar" in metal["headers"].get("content-type", "") + linux["headers"].get("content-type", "")):
        out += backup_differences(metal["body"], linux["body"], metal["window"], linux["window"])
    elif c["path"].endswith("/download") and metal["status"] == 200 and linux["status"] == 200:
        out += download_differences(c["path"], metal["body"], linux["body"], metal["window"], linux["window"])
    elif c["path"].split("?")[0] == "/admin/log" and metal["status"] == 200:
        # The text view (189.3): each host's own log, so its shape is
        # compared, its filter checked, and no secret may be in it.
        out += log_view_differences(c, metal, linux)
    elif c["path"] == "/admin/host" and metal["status"] == 200:
        # A refusal (no session, not the admin) is an ordinary page, compared
        # whole below; only the page itself differs on purpose.
        out += host_page_differences(metal["body"], linux["body"], metal.get("image"), metal.get("boot_disk"))
    else:
        mb = normalize(metal["body"], metal["window"])
        lb = normalize(linux["body"], linux["window"])
        if mb != lb:
            out.append(f"body differs: {len(mb)} bytes on metal, {len(lb)} on Linux"
                       f"{first_difference(mb, lb)}")
    return out


def version_differences(metal: bytes, linux: bytes) -> list:
    try:
        m, l = json.loads(metal), json.loads(linux)
    except ValueError as e:
        return [f"/version is not JSON: {e}"]
    out = []
    if m.keys() != l.keys():
        out.append(f"/version keys differ: {sorted(m)} vs {sorted(l)}")
    if m.get("commit") != EXPECTED_COMMIT:
        out.append(f"/version on metal names commit {m.get('commit')!r}, want {EXPECTED_COMMIT!r}, "
                   f"the angry-gopher checkout it was built from")
    for k in ("result", "version", "rejects"):
        if m.get(k) != l.get(k):
            out.append(f"/version {k}: metal {m.get(k)!r}, Linux {l.get(k)!r}")
    if set(m.get("mem", {})) != set(l.get("mem", {})):
        out.append("/version mem fields differ")
    return out


# The angry-gopher commit metal must name, set in main from the checkout being
# judged: what zig-metal-unikernel's build.zig bakes in (`commitOf`). The Linux side
# is built without -Dcommit and says "dev", so its commit is not compared.
EXPECTED_COMMIT = None


def checkout_commit(root: str) -> str:
    """`git rev-parse --short HEAD`, `+dirty` when tracked files have changed:
    build.zig's `commitOf`, in Python."""
    head = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True)
    if head.returncode != 0:
        return "unknown"
    status = subprocess.run(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"],
                            capture_output=True, text=True).stdout
    return head.stdout.strip() + ("+dirty" if status.strip() else "")


def gpt_partition_base(path: str, n: int) -> int:
    """The byte offset of partition `n` (from 1) on a GPT disk image."""
    with open(path, "rb") as f:
        f.seek(SECTOR)
        header = f.read(SECTOR)
        if header[:8] != b"EFI PART":
            raise RuntimeError(f"{path} has no GPT header")
        entries_lba, count, size = struct.unpack_from("<QII", header, 72)
        if not 1 <= n <= count:
            raise RuntimeError(f"{path} has no partition {n}")
        f.seek(entries_lba * SECTOR + (n - 1) * size)
        first_lba = struct.unpack_from("<Q", f.read(size), 32)[0]
    if first_lba == 0:
        raise RuntimeError(f"{path}'s partition {n} is empty")
    return first_lba * SECTOR


def oracle_megabytes(path: str, base: int = None) -> tuple:
    """(free, total) in MB, as tools/fat16_read.py counts the FAT at `base` in
    `path` (or the volume it finds there)."""
    sys.path.insert(0, TOOLS_DIR)
    import fat16_read
    v = fat16_read.Volume(fat16_read.open_image(path), base)
    total = ((v.max_cluster - 1) * v.cluster_bytes) >> 20
    free = (sum(1 for c in range(2, v.max_cluster + 1) if v.fat(c) == 0) * v.cluster_bytes) >> 20
    return free, total


def download_differences(path: str, metal: bytes, linux: bytes, metal_window=None, linux_window=None) -> list:
    """**A TOPIC'S DOWNLOAD, BY ITS MEMBERS** (QUEUE B27): a gzipped tar
    whose bytes carry each host's own file times, so each member is compared
    (name, size, contents normalized), and each bundle must hold the
    transcript and the reactions under their whole, distinct names."""
    import gzip
    import io
    import tarfile
    topic = path.rstrip("/").split("/")[-2]
    want = [f"{topic}/{topic}.md", f"{topic}/{topic}.reactions.jsonl"]

    def members(name, body, window):
        try:
            t = tarfile.open(fileobj=io.BytesIO(gzip.decompress(body)))
            return {m.name: (m.size, normalize(t.extractfile(m).read(), window) if window else t.extractfile(m).read())
                    for m in t.getmembers() if m.isfile()}, None
        except (OSError, EOFError, tarfile.TarError) as e:
            return {}, f"{path} on {name} is not a whole .tar.gz: {e}"

    m, merr = members("metal", metal, metal_window)
    l, lerr = members("Linux", linux, linux_window)
    out = [e for e in (merr, lerr) if e]
    if out:
        return out
    for name, got in (("metal", m), ("Linux", l)):
        for w in want:
            if w not in got:
                out.append(f"{path} on {name} has no {w} (it has {sorted(got)})")
    for name in sorted(set(m) ^ set(l)):
        out.append(f"{path}: {name} is on {'metal' if name in m else 'Linux'} only")
    for name in sorted(set(m) & set(l)):
        if m[name] != l[name]:
            out.append(f"{path}: {name} differs ({m[name][0]} bytes on metal, {l[name][0]} on Linux)")
    return out


def backup_differences(metal: bytes, linux: bytes, metal_window=None, linux_window=None) -> list:
    """**/admin/backup, BY ITS MEMBERS.** The two archives' bytes differ (each
    host stamps its own file times, FAT in two-second steps), so what is
    compared is each member: its name and kind, its size, and its contents
    with each host's own times normalized (a message's date, a last-seen),
    as every page is."""
    import io
    import tarfile

    def members(name, body, window):
        try:
            t = tarfile.open(fileobj=io.BytesIO(body))
            got = {}
            for m in t.getmembers():
                if m.name == "backup-manifest.txt":
                    continue  # each host's own hashes of its own times; checked below, alone
                data = t.extractfile(m).read() if m.isfile() else b""
                got[m.name] = ("folder" if m.isdir() else "file", m.size,
                               normalize(data, window) if window else data)
            return got, None
        except (tarfile.TarError, EOFError) as e:
            return {}, f"/admin/backup on {name} is not a whole tar: {e}"

    m, merr = members("metal", metal, metal_window)
    l, lerr = members("Linux", linux, linux_window)
    out = [e for e in (merr, lerr) if e]
    if out:
        return out
    # Each whole by its own manifest (QUEUE.md item 57): a cut archive lists
    # cleanly, so the members alone could agree on two short ones.
    sys.path.insert(0, DROPLET_DIR)
    import check_backup
    for name, body in (("metal", metal), ("Linux", linux)):
        problems = check_backup.check(body)[0]
        out += [f"/admin/backup on {name} is not whole: {p}" for p in problems]
    if not m:
        out.append("/admin/backup on metal is empty")
    for name in sorted(set(m) - set(l)):
        out.append(f"/admin/backup: {name} is on metal only")
    for name in sorted(set(l) - set(m)):
        out.append(f"/admin/backup: {name} is on Linux only")
    for name in sorted(set(m) & set(l)):
        (mk, ms, mc), (lk, ls, lc) = m[name], l[name]
        if mk != lk:
            out.append(f"/admin/backup: {name} is a {mk} on metal, a {lk} on Linux")
        elif ms != ls:
            out.append(f"/admin/backup: {name} is {ms} bytes on metal, {ls} on Linux")
        elif mc != lc:
            out.append(f"/admin/backup: {name} differs{first_difference(mc, lc)}")
    return out


# **WHAT NO LOG MAY HOLD** (metal-vmm QUEUE 189.6): every secret this story
# sends, and the words of every message it posts, which are logged by their
# length only. A session cookie's value, a password hash, the passwords, the
# session secret.
LOG_SECRETS = (b"gopher_auth=", b"$2a$", b"$2b$", b"hunter2", b"correct horse", b"correct+horse")
LOG_MESSAGES = (b"hello from bare metal", b"hello+from+bare+metal", b"a second topic", b"the same topic")


def log_leaks(text: bytes) -> list:
    """What of LOG_SECRETS, the session secret and LOG_MESSAGES is in `text`."""
    out = [f"a secret ({s.decode()!r})" for s in LOG_SECRETS + (SESSION_SECRET,) if s in text]
    out += [f"a message's words ({m.decode()!r})" for m in LOG_MESSAGES if m in text]
    return out


def log_view_differences(c, metal, linux) -> list:
    """**/admin/log, THE TEXT VIEW FOR AGENTS** (metal-vmm QUEUE 189.3, 189.7):
    each host's own log, so its shape is compared, not its lines:
      - both plain text, opening with the view's header;
      - metal says what this boot holds and holds lines of it; Linux, which
        keeps no log of its own, says so;
      - asked for one path, metal's lines are that path's requests and the
        lines under them;
      - neither holds a secret the story sent, or a message's words."""
    out = []
    head = b"# The host's log, for agents"
    for name, r in (("metal", metal), ("Linux", linux)):
        if "text/plain" not in r["headers"].get("content-type", ""):
            out.append(f"/admin/log on {name} is not plain text: {r['headers'].get('content-type')!r}")
        if not r["body"].startswith(head):
            out.append(f"/admin/log on {name} does not open with its header")
        out += [f"/admin/log on {name} holds {leak}" for leak in log_leaks(r["body"])]
    m = metal["body"]
    if b"# this boot: " not in m:
        out.append("/admin/log on metal does not say what this boot holds")
    lines = [l for l in m.split(b"\n") if l and not l.startswith(b"# ")]
    if not lines:
        out.append("/admin/log on metal holds no line of the log")
    if b"keeps no log of its own" not in linux["body"] and b"# this boot: " not in linux["body"]:
        out.append("/admin/log on Linux neither shows a log nor says it keeps none")
    query = c["path"].split("?", 1)[1] if "?" in c["path"] else ""
    want = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv).get("path")
    if want:
        for l in lines:
            if l.startswith(b"    "):
                continue
            got = re.search(rb"request \d+: \S+ (\S+)", l)
            if not got or not got.group(1).startswith(want.encode()):
                out.append(f"/admin/log?path={want} on metal holds another line: {l.decode('latin-1')!r}")
    return out


def host_page_differences(metal: bytes, linux: bytes, image: str = None, boot_disk: str = None) -> list:
    """**/admin/host DIFFERS ON PURPOSE**: its second table is each host's own
    account of itself. So what is compared is its shape: both have the
    application's half, with the same rows, and each says which host it is.

    **AND WHAT METAL SAYS ABOUT ITS DISK IS CHECKED** (REVIEW-admin-host.md
    finding 1), because the page is where an operator learns the volume is
    filling:
      - the host's report must not have failed (its one row then names the
        error), and no volume's free space may be "unreadable";
      - every "N MB free of M MB" must have 0 < M and N <= M, and there must
        be one;
      - given the disk image the kernel served from, the boot disk's total
        must be what tools/fat16_read.py makes of that image, and its free
        space within 2 MB of the oracle's count of the image at the end of
        the story: the page is asked for early, and what the story writes
        after it is kilobytes.
      - **ON THE DROPLET MACHINE** (`boot_disk`, the disk it booted from),
        `image` is chat's data volume, so the volume's row is checked against
        `image` and the boot disk's against the site on `boot_disk`'s
        partition 2. Both rows must be there."""
    rows = lambda body: re.findall(rb"<tr><td>(.*?)</td><td>", body)
    out = []
    for name, body in (("metal", metal), ("Linux", linux)):
        if b"<h2>The application</h2>" not in body or b"<h2>The host</h2>" not in body:
            out.append(f"/admin/host on {name} lacks a half")
    app = lambda body: rows(body.split(b"<h2>The host</h2>")[0])
    if app(metal) != app(linux):
        out.append(f"/admin/host's application rows differ: {app(metal)} vs {app(linux)}")
    if b"zig-metal-unikernel, with no operating system" not in metal:
        out.append("/admin/host on metal does not say it is zig-metal-unikernel")
    if b"Linux, zig-server" not in linux:
        out.append("/admin/host on Linux does not say it is Linux")
    if b"serial " not in metal:
        out.append("/admin/host on metal names no volume serial")
    # **THE LOG** (QUEUE.md item 32): its shape, not its lines. Metal shows
    # the serial ring's newest lines; Linux keeps none to show yet, and says
    # so. Neither may show a secret the ring was meant to take out.
    for name, body in (("metal", metal), ("Linux", linux)):
        if b"<h2>The log</h2>" not in body:
            out.append(f"/admin/host on {name} has no log section")
    shown = re.search(rb'<pre class="log">(.*?)</pre>', metal, re.S)
    if not shown or not shown.group(1).strip():
        out.append("/admin/host on metal shows no log lines")
    elif b"gopher_auth=" in shown.group(1) or b"$2a$" in shown.group(1) or b"$2b$" in shown.group(1):
        out.append("/admin/host on metal shows a session cookie or a password hash in its log")
    elif log_leaks(shown.group(1)):
        out.append(f"/admin/host on metal shows in its log {', '.join(log_leaks(shown.group(1)))}")
    if b'<pre class="log">' not in linux and b"keeps no log of its own" not in linux:
        out.append("/admin/host on Linux neither shows a log nor says it keeps none")

    host = metal.split(b"<h2>The host</h2>")[-1]
    figures = {}
    for label, value in re.findall(rb"<tr><td>(.*?)</td><td>(.*?)</td></tr>", host):
        if re.fullmatch(rb"the host(&#39;|')s report", label):
            out.append(f"/admin/host on metal: the host's report failed: {value.decode('latin-1')}")
        if b"unreadable" in value:
            out.append(f"/admin/host on metal: {label.decode('latin-1')}: {value.decode('latin-1')}")
        m = re.search(rb"(\d+) MB free of (\d+) MB", value)
        if m:
            free, total = int(m.group(1)), int(m.group(2))
            figures[label.replace(b"&#39;", b"'")] = (free, total)
            if total == 0 or free > total:
                out.append(f"/admin/host on metal: {label.decode('latin-1')}: {free} MB free of {total} MB")
    if not figures:
        out.append("/admin/host on metal gives no volume's free space")
    if not image:
        return out
    if boot_disk:
        checks = [(b"the boot disk (the site)", "the boot disk", boot_disk, gpt_partition_base(boot_disk, 2)),
                  (b"the volume (chat's data)", "the volume", image, None)]
    else:
        checks = [(b"the boot disk (the site)", "the boot disk", image, None)]
    for label, name, path, base in checks:
        row = figures.get(label)
        if row is None:
            if boot_disk:
                out.append(f"/admin/host on metal gives no free space for {name}")
            continue
        free, total = oracle_megabytes(path, base)
        if row[1] != total:
            out.append(f"/admin/host on metal: {name} is {row[1]} MB, and the oracle reads {total} MB")
        if abs(row[0] - free) > 2:
            out.append(f"/admin/host on metal: {name} has {row[0]} MB free, and the oracle "
                       f"counts {free} MB at the story's end")
    return out


def first_difference(a: bytes, b: bytes) -> str:
    n = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    return f"; first difference at byte {n}: {a[n:n + 40]!r} vs {b[n:n + 40]!r}"


def file_differences(c: dict, image: str, metal: dict, linux: dict, mnt: str) -> list:
    """The files a case touched, read through the Linux VFAT driver on the
    kernel's disk and straight off the Linux server's directory. A file absent
    on both sides agrees; that is how "a move into a missing session wrote
    nothing" is checked."""
    if not c["files"]:
        return []
    out = []
    on_metal = disk_read(image, mnt, c["files"])
    for rel in c["files"]:
        m = on_metal[rel]
        l = read_or_none(os.path.join(linux["root"], rel))
        nm = None if m is None else normalize(m, metal["window"])
        nl = None if l is None else normalize(l, linux["window"])
        if nm != nl:
            out.append(f"{rel}: metal wrote {abbrev(nm)}, Linux wrote {abbrev(nl)}")

    # fsck.vfat has no offset option, so it checks a copy of the partition.
    part = image + ".part"
    run(["dd", f"if={image}", f"of={part}", f"bs={SECTOR}", f"skip={PART_FIRST}",
         f"count={partition_last(image) - PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        out.append("fsck.vfat rejects the kernel's disk: "
                   + " | ".join(check.stdout.strip().splitlines()[1:4]))
    os.remove(part)
    return out


def abbrev(b):
    if b is None:
        return "nothing"
    return repr(b if len(b) <= 60 else b[:57] + b"...")


def read_or_none(path: str):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def cookie_from(answer: dict, jar):
    """The __Host-gopher_uid a response set, or the jar unchanged (a legacy
    one it clears is no cookie to keep). A legacy-named identity SET is no
    cookie either (metal-vmm QUEUE 176.2): the next step then shows that host
    as no one, where the other names its player."""
    sc = answer.get("headers", {}).get("set-cookie", "")
    m = re.search(r"(__Host-gopher_uid=[A-Za-z0-9._-]+)", sc)
    return m.group(1) if m else jar


def update_jar(answer: dict, jar: dict) -> dict:
    """Every cookie a response set, as a browser would keep them: a value
    replaces the old one, and Max-Age=0 removes it."""
    jar = dict(jar or {})
    for line in answer.get("headers", {}).get("set-cookie", "").split("\n"):
        if "=" not in line:
            continue
        pair, _, attrs = line.partition(";")
        name, _, value = pair.strip().partition("=")
        if re.search(r"(?i)max-age=0\b", attrs) or value == "":
            jar.pop(name, None)
        else:
            jar[name] = value
    return jar


def tree(root: str) -> dict:
    out = {}
    for dirpath, _, files in [w for top in ("data", "auth") for w in os.walk(os.path.join(root, top))]:
        for f in files:
            full = os.path.join(dirpath, f)
            with open(full, "rb") as fh:
                out[os.path.relpath(full, root)] = fh.read()
    return out


def run_story(elf, linux_bin, content, pristine, work, mnt, steps, label, report, minted=None,
              conf=None):
    """Tells `steps` to one kernel and one Linux server. Returns (failures,
    kernel serial log, per-step kernel answers). `conf` is more of the
    kernel's configuration."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(steps), mnt, **(conf or {}))

    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    metal_answers, jar = [], {}
    for i, s in enumerate(steps):
        if s.get("settle"):
            time.sleep(s["settle"])
        if qemu.poll() is not None:
            # The kernel is gone. Every later step is a failure, and asking
            # would only wait for a connection that will never come.
            metal_answers.append({"error": f"the kernel had already exited ({qemu.returncode})"})
            continue
        a = ask(port, with_jar(s, jar, minted), os.path.join(scratch, f"k{i}"))
        jar = update_jar(a, jar)
        metal_answers.append(a)
    code, log = finish_kernel(qemu, serial)
    metal_window = (int(before) - 1, int(time.time()) + 1)

    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    before = time.time()
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    linux_answers, jar = [], {}
    try:
        for i, s in enumerate(steps):
            if s.get("settle"):
                time.sleep(s["settle"])
            # **A SERVER THAT DIED FAILS EVERY STEP LEFT, AT ONCE**, saying
            # why: asking a closed port waits out `ask`'s patience, seven
            # minutes a step, and the run hung for hours on one panic.
            if server.proc.poll() is not None:
                linux_answers.append({"error": f"the Linux server had exited ({server.proc.returncode}): {server.last_words()}"})
                continue
            a = ask(server.port, with_jar(s, jar, minted), os.path.join(scratch, f"l{i}"))
            jar = update_jar(a, jar)
            linux_answers.append(a)
    finally:
        server.stop()
    linux_window = (int(before) - 1, int(time.time()) + 1)

    failures = 0
    # **A REQUEST THAT WAITED A SECOND WAITED ON A TIMER.** Every answer can
    # match Linux's while each one waits out a retransmission nobody needed —
    # which is how a full run once went from three minutes to seven. On a boot
    # that loses nothing on purpose, no request waits that long for its turn.
    if not (conf or {}).get("lose_one_sent_in"):
        slow = [(n + 1, w) for n, (w, _, _, _) in enumerate(request_timings(log)) if w >= WAIT_LIMIT_US]
        if slow:
            failures += 1
            report(f"FAIL  {label}: {len(slow)} requests waited a second or more for their turn "
                   f"(request {slow[0][0]}: {slow[0][1] // 1000} ms)")
    if code != 1:
        failures += 1
        report(f"FAIL  {label}: the kernel exited {code} after the story: "
               + " | ".join(log.splitlines()[-3:]))
    for s, m, l in zip(steps, metal_answers, linux_answers):
        m = dict(m, guest_exit=1, window=metal_window, serial=log, image=image,
                 boot_disk=os.path.join(scratch, "droplet.img") if DROPLET else None)
        l = dict(l, window=linux_window)
        diffs = differences(s, m, l)
        if diffs:
            failures += 1
            report(f"FAIL  {label}: {s['name']}  ({s['method']} {s['path']})")
            for d in diffs:
                report(f"        {d}")

    # **AFTER THE WRITES, THE DISK MUST STILL CHECK CLEAN**: by the oracle,
    # and by the kernel's own check on one more boot of the disk it wrote.
    oracle = subprocess.run([sys.executable, os.path.join(TOOLS_DIR, "fat16_read.py"), "check", image],
                            capture_output=True, text=True)
    if oracle.returncode != 0:
        failures += 1
        report(f"FAIL  {label}: after the story, tools/fat16_read.py finds the disk inconsistent: "
               + " | ".join(oracle.stdout.splitlines()[1:4]))
    # **A SCRATCH OF ITS OWN**: on the droplet machine a boot splits the
    # site off into its scratch (split_site_off), and the story's boot already
    # did that in this one. And there the story's disk now holds only chat's
    # data, so the site that boot moved off is put back on this copy first,
    # for this boot to split off in turn.
    rscratch = tempfile.mkdtemp(dir=scratch)
    recheck = os.path.join(rscratch, "recheck.img")
    shutil.copy(image, recheck)
    if DROPLET:
        restore_site(recheck, os.path.join(scratch, "site"), mnt)
    set_request_limit(recheck, 1, mnt)
    rq, rport, rserial = start_kernel(elf, recheck, rscratch)
    ask(rport, case("the version, on a boot of the written disk", "GET", "/version"),
        os.path.join(rscratch, "recheck"))
    rcode, rlog = finish_kernel(rq, rserial)
    if rcode != 1:
        failures += 1
        report(f"FAIL  {label}: the boot after the story exited {rcode}, not at its request limit")
    if "the boot disk" not in disk_check_lines(rlog):
        failures += 1
        report(f"FAIL  {label}: the boot after the story printed no disk check")

    # The whole data tree, both sides, at the end of the story.
    taken = tempfile.mkdtemp(dir=scratch)
    disk_take(image, mnt, taken, names=DATA_DIRS)
    metal_tree = tree(taken)
    linux_tree = tree(root)
    for rel in sorted(set(metal_tree) | set(linux_tree)):
        m = metal_tree.get(rel)
        l = linux_tree.get(rel)
        nm = None if m is None else normalize(m, metal_window)
        nl = None if l is None else normalize(l, linux_window)
        if nm != nl:
            failures += 1
            report(f"FAIL  {label}: {rel}: metal has {abbrev(nm)}, Linux has {abbrev(nl)}")

    part = image + ".part"
    run(["dd", f"if={image}", f"of={part}", f"bs={SECTOR}", f"skip={PART_FIRST}",
         f"count={partition_last(image) - PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        failures += 1
        report(f"FAIL  {label}: fsck.vfat rejects the kernel's disk: "
               + " | ".join(check.stdout.strip().splitlines()[1:4]))
    shutil.rmtree(scratch, ignore_errors=True)
    return failures, log, metal_answers, len(metal_tree)


BASE_HEAP = re.compile(
    r"request \d+: .*\(base: (\d+) live bytes, (\d+) in pages, peak (\d+)\)")


def missing_marks(steps, answers, report, label) -> int:
    """**WHAT WAS WRITTEN MUST STILL BE THERE.** Every step that carries
    `expect` is a read-back, and every mark from every earlier round must be in
    the body it returned. This is the check that does not go through Linux: two
    servers agreeing on a transcript that lost round 7 would still be wrong."""
    failures = 0
    for s, a in zip(steps, answers):
        if not s["expect"]:
            continue
        body = a.get("body")
        if body is None:
            failures += 1
            report(f"FAIL  {label}: {s['name']}: no body to read the marks out of "
                   f"({a.get('error', a.get('status'))})")
            continue
        gone = [m for m in s["expect"] if m not in body]
        if gone:
            failures += 1
            report(f"FAIL  {label}: {s['name']}: {len(gone)} of {len(s['expect'])} marks are not in "
                   f"the {len(body)}-byte body it returned, first {gone[0].decode()}")
    return failures


def parse_raw_response(raw: bytes) -> dict:
    """An HTTP response read off a bare socket, in the shape `ask` answers."""
    head, sep, body = raw.partition(b"\r\n\r\n")
    if not sep:
        return {"error": f"no complete response head in {len(raw)} bytes"}
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ", 2)
    if len(parts) < 2 or not parts[1].isdigit():
        return {"error": f"not a status line: {lines[0]!r}"}
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            k, v = k.strip().lower(), v.strip()
            headers[k] = headers[k] + "\n" + v if k == "set-cookie" and k in headers else v
    return {"status": int(parts[1]), "headers": headers, "body": body}


# **MANY CLIENTS AT ONCE.** The paths are ones the single-request cases already
# prove equal to Linux, so a difference here is about holding connections, not
# about the page.
CONCURRENT_PATHS = ["/", "/steve-resume.pdf", "/nope", "/login", "/chat",
                    "/chess", "/driving", "/admin"]
CONNECTIONS_LINE = re.compile(r"connections: at most (\d+) at once, (\d+) turned away")


def concurrent_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """Every client connects FIRST, then each sends its request — the last one
    connected sending first — and only then are the answers read. A machine that
    held one connection at a time could not get past the second connect; this
    one must hold all of them, answer each correctly, and say so in its log."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(CONCURRENT_PATHS), mnt)
    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    failures = 0
    socks = []
    try:
        for _ in CONCURRENT_PATHS:
            socks.append(socket.create_connection(("127.0.0.1", port), timeout=60))
        # Let every handshake reach the guest before anyone asks for anything.
        time.sleep(1.0)
        for sock, path in reversed(list(zip(socks, CONCURRENT_PATHS))):
            sock.sendall(f"GET {path} HTTP/1.1\r\nHost: judge\r\nConnection: close\r\n\r\n".encode())
        answers = []
        for sock in socks:
            got = b""
            try:
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    got += chunk
            except OSError as e:
                answers.append({"error": f"socket: {e}"})
                continue
            answers.append(parse_raw_response(got))
    finally:
        for sock in socks:
            sock.close()
    code, log = finish_kernel(qemu, serial)
    window = (int(before) - 1, int(time.time()) + 1)

    for path, metal in zip(CONCURRENT_PATHS, answers):
        c = case(f"concurrently: {path}", "GET", path)
        linux = ask_linux(linux_bin, content, c, tempfile.mkdtemp(dir=work))
        m = dict(metal, guest_exit=code, window=window, serial=log)
        diffs = differences(c, m, linux)
        if diffs:
            failures += 1
            report(f"FAIL  concurrent: GET {path}")
            for d in diffs:
                report(f"        {d}")

    held = CONNECTIONS_LINE.search(log)
    if held is None:
        failures += 1
        report("FAIL  concurrent: the kernel never said how many connections it held")
    elif int(held.group(1)) < len(CONCURRENT_PATHS):
        failures += 1
        report(f"FAIL  concurrent: the kernel held at most {held.group(1)} at once, "
               f"with {len(CONCURRENT_PATHS)} clients connected")
    elif int(held.group(2)) != 0:
        failures += 1
        report(f"FAIL  concurrent: the kernel turned {held.group(2)} away")
    if not failures:
        report(f"ok    {len(CONCURRENT_PATHS)} clients connected at once, each answered as Linux "
               f"answered; the kernel held {held.group(1)} at once and turned none away")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


# ── a live stream ────────────────────────────────────────────────────────────

LOGIN_BODY = "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat"


def read_until(sock, wanted: bytes, deadline: float, got: bytes = b"") -> bytes:
    """Reads a held-open stream until `wanted` has arrived or the deadline
    passes. Answers everything read so far either way."""
    while wanted not in got and time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(65536)
        except OSError:
            break
        if not chunk:
            break
        got += chunk
    return got


def sse_story(port: int, scratch: str, report, label: str) -> int:
    """**A MESSAGE SENT ON ONE CONNECTION ARRIVES ON A STREAM HELD OPEN ON
    ANOTHER.** Nothing checked that before: curl runs no JavaScript and the
    stress test only opens streams to break them. Four requests:

      1. log in
      2. send a first message, which becomes the topic's backlog
      3. open the topic's stream (held open) — the backlog must come first
      4. send a second message — it must arrive on the stream, numbered 1

    The stream's body is delimited by the connection closing, not chunked:
    the host writes live frames long after the handler returned."""
    failures = 0
    login = ask(port, step("log in", "POST", "/login/full", None, LOGIN_BODY), scratch, patience=60)
    jar = update_jar(login, {})
    cookie = "; ".join(f"{k}={v}" for k, v in jar.items())
    first = ask(port, step("a first message", "POST", "/chat/c/1_2/live/send", cookie,
                           "markdown=backlog-mark&cid=b1", headers=["X-Chat-Async: 1"]),
                scratch, patience=60)
    if first.get("status") not in (200, 204):
        report(f"FAIL  {label}: the first message was answered {first.get('status', first.get('error'))}")
        return 1

    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    try:
        sock.sendall((f"GET /chat/c/1_2/live/stream?since=0 HTTP/1.1\r\nHost: judge\r\n"
                      f"Cookie: {cookie}\r\nAccept: text/event-stream\r\n\r\n").encode())
        got = read_until(sock, b"backlog-mark", time.time() + 30)
        head = got.partition(b"\r\n\r\n")[0].decode("latin-1").lower()
        if not got.startswith(b"HTTP/1.1 200"):
            failures += 1
            report(f"FAIL  {label}: the stream answered {got[:40]!r}")
        if "content-type: text/event-stream" not in head:
            failures += 1
            report(f"FAIL  {label}: the stream is not an event stream: {head!r}")
        if "transfer-encoding: chunked" in head:
            failures += 1
            report(f"FAIL  {label}: the stream is chunked; a host-kept stream must be close-delimited")
        if b"event: backlog-size\ndata: 1" not in got or b"backlog-mark" not in got:
            failures += 1
            report(f"FAIL  {label}: the backlog did not arrive first: {got[-200:]!r}")

        second = ask(port, step("a live message", "POST", "/chat/c/1_2/live/send", cookie,
                                "markdown=live-mark&cid=l1", headers=["X-Chat-Async: 1"]),
                     scratch, patience=60)
        if second.get("status") not in (200, 204):
            failures += 1
            report(f"FAIL  {label}: the live message was answered {second.get('status', second.get('error'))}")
        before = len(got)
        got = read_until(sock, b"live-mark", time.time() + 15, got)
        live = got[before:]
        if b"live-mark" not in live:
            failures += 1
            report(f"FAIL  {label}: the live message never arrived on the open stream "
                   f"({len(live)} bytes after the backlog: {live[:120]!r})")
        elif b"id: 1\n" not in live:
            failures += 1
            report(f"FAIL  {label}: the live frame is not numbered 1: {live[:120]!r}")
    finally:
        sock.close()
    if not failures:
        report(f"ok    {label}: a stream held open got its backlog first, then the message sent on "
               f"another connection, numbered 1")
    return failures


APOORVA_LOGIN = "name=apoorva&password=correct+horse+battery+staple&action=login&next=%2Fchat"


def open_stream(port: int, path: str, cookie: str):
    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                  f"Accept: text/event-stream\r\n\r\n").encode())
    return sock


def tab_story(port: int, scratch: str, report, label: str, keepalive: float = 25) -> int:
    """**A CHAT TAB, AS A BROWSER HOLDS IT: THREE STREAMS AT ONCE**, fed by
    another user. Eight requests:

      1-2. Steve and Apoorva log in
      3.   Steve starts topic `tab`
      4-6. Apoorva opens her tab's streams: `tab`'s conversation,
           notifications, sidebar
      7.   Steve sends on `tab`: her conversation stream shows it as not hers,
           and her notifications say he sent it
      8.   Steve starts a NEW topic: her sidebar is told it was added

    Then `keepalive` + 2 quiet seconds, in which every one of the three must be
    pinged: the application's keepalive is 25, and the machine's can be set
    shorter. Presence also pushes "came online" events at
    moments nobody controls, so each check looks for its own event rather than
    for silence."""
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    def login(body):
        return update_jar(ask(port, step("log in", "POST", "/login/full", None, body), scratch,
                              patience=60), {})

    def cookie_of(jar):
        return "; ".join(f"{k}={v}" for k, v in jar.items())

    steve = cookie_of(login(LOGIN_BODY))
    apoorva = cookie_of(login(APOORVA_LOGIN))
    if not steve or not apoorva:
        fail("a login set no session cookie")
        return failures

    def send(topic, text, cid):
        a = ask(port, step(f"send {text}", "POST", f"/chat/c/1_2/{topic}/send", steve,
                           f"markdown={text}&cid={cid}", headers=["X-Chat-Async: 1"]),
                scratch, patience=60)
        if a.get("status") not in (200, 204):
            fail(f"sending {text} was answered {a.get('status', a.get('error'))}")

    send("tab", "tab-opener", "t1")
    opened = time.time()
    conv = open_stream(port, "/chat/c/1_2/tab/stream?since=0", apoorva)
    notify = open_stream(port, "/chat/notifications", apoorva)
    sidebar = open_stream(port, "/chat/sidebar/stream", apoorva)
    socks = [conv, notify, sidebar]
    try:
        got = {s: b"" for s in socks}
        got[conv] = read_until(conv, b"tab-opener", time.time() + 30)
        # The two live-only streams answer with their head and nothing else.
        for s in (notify, sidebar):
            got[s] = read_until(s, b"\r\n\r\n", time.time() + 30)
            if not got[s].startswith(b"HTTP/1.1 200"):
                fail(f"a live-only stream answered {got[s][:40]!r}")

        send("tab", "tab-live", "t2")
        got[conv] = read_until(conv, b"tab-live", time.time() + 15, got[conv])
        live = got[conv].partition(b"tab-live")[0].rpartition(b"id: ")[2] + b"tab-live"
        if b"tab-live" not in got[conv]:
            fail("the message never reached her conversation stream")
        elif b'"mine":false' not in got[conv][got[conv].rfind(b"id: "):]:
            fail(f"his message is marked as hers on her stream: {live[:120]!r}")
        got[notify] = read_until(notify, b"Steve sent you a message on tab.", time.time() + 15, got[notify])
        if b"Steve sent you a message on tab." not in got[notify]:
            fail(f"her notifications never said he sent it: {got[notify][-160:]!r}")

        send("tab-other", "other-opener", "o1")
        got[sidebar] = read_until(sidebar, b'"sid":"tab-other"', time.time() + 15, got[sidebar])
        if b'"kind":"topic-added"' not in got[sidebar] or b'"sid":"tab-other"' not in got[sidebar]:
            fail(f"her sidebar was never told the new topic was added: {got[sidebar][-160:]!r}")

        # **A PING IS RARE.** A host that pinged every turn would flood the
        # network and still deliver a ping; so none may have come before the
        # keepalive was due…
        if time.time() - opened < 0.8 * keepalive:
            for name, s in (("conversation", conv), ("notifications", notify), ("sidebar", sidebar)):
                if b": ping" in got[s]:
                    fail(f"her {name} stream was pinged within {time.time() - opened:.0f}s of opening")
        # …and after the keepalive, each is pinged — once, or at most twice.
        marks = {s: len(got[s]) for s in socks}
        deadline = time.time() + keepalive + 2
        for s in socks:
            got[s] = read_until(s, b": ping", deadline, got[s])
        for s in socks:
            got[s] = read_until(s, b"never", time.time() + 1.0, got[s])  # whatever else came
        for name, s in (("conversation", conv), ("notifications", notify), ("sidebar", sidebar)):
            pings = got[s][marks[s]:].count(b": ping")
            if pings == 0:
                fail(f"her {name} stream was not pinged in {keepalive + 2:g} quiet seconds")
            elif pings > 2:
                fail(f"her {name} stream was pinged {pings} times in {keepalive + 3:g} seconds, "
                     f"with a {keepalive:g}-second keepalive")
    finally:
        for s in socks:
            s.close()
    if not failures:
        report(f"ok    {label}: one tab's three streams at once — his message on her conversation "
               f"(not hers), in her notifications, his new topic in her sidebar, and all three "
               f"pinged after {keepalive:g} quiet seconds")
    return failures


# ── uploads ──────────────────────────────────────────────────────────────────
#
# **A PICTURE GOES ON THE VOLUME AND COMES BACK BYTE FOR BYTE**, and an upload
# too big for the machine is refused the way Linux refuses it — which is a
# statement about the request heap, not about the route. The heap this machine
# gives a request grows past what it keeps: a fixed one failed while the body
# was still being read, and answered "400, could not read the body" where Linux
# answers "413, the limit is 10 MB" — and for a big enough upload it closed the
# connection while the client was still sending, so the client saw no answer at
# all.

UPLOAD_BOUNDARY = "----gophermetaljudge"
# Bigger than the heap the machine keeps between requests (32 MB), and bigger
# than chat's own image limit, so the answer has to come from a body that was
# read whole and then refused.
OVERSIZED_UPLOAD = 40 << 20


def picture(n: int) -> bytes:
    """`n` bytes that sniff as a PNG."""
    return b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + bytes((k * 7 + 3) & 0xFF for k in range(n - 16))


def multipart(filename: str, data: bytes) -> bytes:
    head = (f"--{UPLOAD_BOUNDARY}\r\nContent-Disposition: form-data; name=\"file\"; "
            f"filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
    return head + data + f"\r\n--{UPLOAD_BOUNDARY}--\r\n".encode()


# The stored file is named at random, by each side's own generator, so that is
# the one thing about an upload's answer that cannot be compared. Everything
# else in it — the conversation it landed in, the kind, the name the client
# sent — is compared exactly.
STORED_NAME = re.compile(rb"[0-9a-f]{32}")


def named(answer: dict) -> dict:
    return dict(answer, body=STORED_NAME.sub(b"<NAME>", answer["body"]))


# The topic's first message, a picture, it read back, one sent after
# 100-continue, one not a picture, and (not QUICK) a big picture posted +
# streamed back and one bigger than the heap keeps. QUICK stops after the
# first five.
UPLOAD_STORY_REQUESTS = 8
UPLOAD_STORY_REQUESTS_QUICK = 5


def upload_story(port: int, session: str) -> dict:
    """Posts pictures to chat and reads one back. Answers what each step got,
    with the stored file's random name left out — it is random on both sides."""

    def send(method, path, body=None, ctype=None, expect_continue=False, timeout=120):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        headers = {"Host": f"127.0.0.1:{port}", "Accept": "*/*", "Cookie": session}
        if ctype:
            headers["Content-Type"] = ctype
        if expect_continue:
            headers["Expect"] = "100-continue"
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            out = {"status": r.status, "body": r.read(), "type": r.getheader("content-type")}
        except OSError as e:
            out = {"status": 0, "body": f"{type(e).__name__}: {e}".encode(), "type": None}
        finally:
            conn.close()
        return out

    def post(name, data, **kw):
        return send("POST", "/chat/c/1_2/general/upload", multipart(name, data),
                    f"multipart/form-data; boundary={UPLOAD_BOUNDARY}", **kw)

    small = picture(64 << 10)
    out = {}
    # **A TOPIC IS MADE BY ITS FIRST MESSAGE** (angry-gopher, metal-vmm QUEUE
    # 156(j)): every tail but `send` is a 404 for a topic not there, an upload
    # among them, so the pictures go to a topic a message made.
    out["the topic's first message"] = send(
        "POST", "/chat/c/1_2/general/send", b"markdown=pictures+follow&cid=u1",
        "application/x-www-form-urlencoded")
    # **THE URL IS READ BEFORE THE NAME IS NORMALIZED.** Asking for
    # `<NAME>.png` is a 404 on both sides, and two 404s agree.
    stored = post("shot.png", small)
    out["a picture"] = named(stored)
    out["it comes back"] = {"status": 0, "body": b"the upload was refused", "type": None}
    if stored["status"] == 200:
        try:
            url = json.loads(stored["body"])["url"]
        except (ValueError, KeyError) as e:
            url = None
            out["it comes back"] = {"status": 0, "body": f"the answer was not JSON: {e}".encode(), "type": None}
        if url:
            got = send("GET", url)
            same = got["body"] == small
            out["it comes back"] = {"status": got["status"], "type": got["type"],
                                    "body": b"the same bytes" if same else b"DIFFERENT bytes"}
    out["one that waits to be told to send"] = named(post("two.png", small, expect_continue=True))
    out["not a picture"] = post("notes.txt", b"just words, not a picture at all")
    if not QUICK:
        # **A PICTURE PAST THE WHOLE-READ CAP, STREAMED BACK** (QUEUE.md item
        # 105): bigger than chat_upload's `whole_read_max` (4 MiB) and under the
        # 10 MiB image cap, so the serve path streams it in pieces rather than
        # holding it whole. It must still come back byte for byte, the same on
        # both hosts — the proof the stream path is correct and composes with
        # the cache (item 102).
        big = picture(5 << 20)
        big_stored = post("big.png", big)
        out["a big picture streams back"] = {"status": 0, "body": b"not stored", "type": None}
        if big_stored["status"] == 200:
            try:
                burl = json.loads(big_stored["body"])["url"]
            except (ValueError, KeyError):
                burl = None
            if burl:
                bgot = send("GET", burl)
                out["a big picture streams back"] = {
                    "status": bgot["status"], "type": bgot["type"],
                    "body": b"the same bytes" if bgot["body"] == big else b"DIFFERENT bytes"}
        out["bigger than the heap it keeps"] = post("huge.png", picture(OVERSIZED_UPLOAD))
    return out


# ── the admin's lost password (QUEUE.md item 89) ─────────────────────────────
#
# **THE WAY BACK IN, ON BOTH HOSTS.** Metal: the boot disk's zig-metal-unikernel.conf
# carries `admin_password_reset = Steve <hash>`; the boot applies it once,
# only to a uid 1 named Steve. Linux: angry-gopher's ops/reset_admin_password
# --local, with the server stopped. Either way the new password logs in and
# the old one does not; a second boot of the same image changes nothing; and
# a reset that names someone else is refused, the old password still good.

RESET_PASSWORD = "a new password, after the drill"


def admin_hash(gopher_root: str, password: str) -> str:
    zig_server = os.path.join(gopher_root, "zig-server")
    run(["zig", "build", "hash-password"], cwd=zig_server)
    return subprocess.run([os.path.join(zig_server, "zig-out", "bin", "hash-password")],
                          input=password, capture_output=True, text=True, check=True).stdout.strip()


def logs_in(port: int, password: str) -> bool:
    """Whether Steve's `password` is answered with a session."""
    body = "name=Steve&password=" + urllib.parse.quote_plus(password) + "&action=login&next=%2Fchat"
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    conn.request("POST", "/login/full", body=body,
                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    resp = conn.getresponse()
    resp.read()
    conn.close()
    return any(k.lower() == "set-cookie" and re.match(r"__Host-gopher_auth=[^;]", v)
               for k, v in resp.getheaders())


def admin_reset_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, report) -> int:
    failures = []
    new_hash = admin_hash(gopher_root, RESET_PASSWORD)
    expect = lambda ok, what: None if ok else failures.append(what)

    # **A SCRATCH PER BOOT**: on the droplet machine a boot splits the site
    # off into its scratch (split_site_off), so a later boot of the same disk
    # gets the site put back from the earlier one's scratch first.
    def boot(image, reset_line, n, after=None):
        bscratch = tempfile.mkdtemp(dir=scratch)
        if DROPLET and after is not None:
            restore_site(image, os.path.join(after, "site"), mnt)
        disk_write(image, mnt, "zig-metal-unikernel.conf", request_limit_text(image, n) + reset_line)
        qemu, port, serial = start_kernel(elf, image, bscratch)
        return qemu, port, serial, bscratch

    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    line = f"admin_password_reset = Steve {new_hash}\n"

    # The boot that applies it.
    qemu, port, serial, first = boot(image, line, 2)
    expect(logs_in(port, RESET_PASSWORD), "metal: the reset password did not log in")
    expect(not logs_in(port, MEMBER_PASSWORD), "metal: the old password still logged in after the reset")
    code, log = finish_kernel(qemu, serial)
    expect(code == 1, f"metal: a boot exited {code}, not at its request limit")
    expect("admin password reset for Steve: applied;" in log, "metal: the boot did not say it applied the reset")

    # The same image again: once is once.
    qemu, port, serial, _ = boot(image, line, 1, after=first)
    expect(logs_in(port, RESET_PASSWORD), "metal: the reset password did not log in on the second boot")
    code, log = finish_kernel(qemu, serial)
    expect(code == 1, f"metal: a boot exited {code}, not at its request limit")
    expect("applied by an earlier boot; nothing changed" in log, "metal: the second boot did not say it had applied it before")

    # Someone else's name: refused, the old password still good.
    shutil.copy(pristine, image)
    qemu, port, serial, _ = boot(image, f"admin_password_reset = Mallory {new_hash}\n", 1)
    expect(logs_in(port, MEMBER_PASSWORD), "metal: a reset for another name changed the admin's password")
    code, log = finish_kernel(qemu, serial)
    expect(code == 1, f"metal: a boot exited {code}, not at its request limit")
    expect("REFUSED: uid 1 is not named so" in log, "metal: a reset for another name was not refused out loud")
    shutil.rmtree(scratch, ignore_errors=True)

    # Linux: ops/reset_admin_password --local, the server stopped meanwhile.
    root = tempfile.mkdtemp(dir=work)
    shutil.rmtree(root)
    shutil.copytree(content, root)
    reset = subprocess.run([os.path.join(gopher_root, "ops", "reset_admin_password"), "--local",
                            os.path.join(root, "auth"), "--yes"],
                           input=RESET_PASSWORD + "\n", capture_output=True, text=True)
    expect(reset.returncode == 0, "linux: ops/reset_admin_password failed: " + reset.stderr.strip()[-200:])
    server = LinuxServer(linux_bin, root, os.path.join(root, "server.log"))
    try:
        expect(logs_in(server.port, RESET_PASSWORD), "linux: the reset password did not log in")
        expect(not logs_in(server.port, MEMBER_PASSWORD), "linux: the old password still logged in after the reset")
    finally:
        server.stop()
    shutil.rmtree(root, ignore_errors=True)

    for f in failures:
        report(f"FAIL  admin reset: {f}")
    if not failures:
        report("ok    the admin's password reset: metal once, from its boot disk, and only for the admin; "
               "Linux by ops/reset_admin_password; the new password logs in and the old does not")
    return len(failures)


def login_throttle_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """**BOTH HOSTS HELD TO THE LOGIN THROTTLE, ON ALL THREE BCRYPT PATHS**
    (QUEUE.md items 97, 100). On each host, identically, the throttle refuses
    before the hash:
      - **sign-in:** ten wrong sign-ins answered (the 200 wrong-password page),
        the 11th refused 429, and a CORRECT one over the bound refused too (the
        refusal cannot tell right from wrong);
      - **account creation:** five accounts made from one address, the sixth
        refused 429;
      - **the admin's re-entry** on `/admin/backup`: ten wrong (the 403 page),
        the 11th refused 429 — so a stolen admin session cannot guess unbounded.
    `/version`'s `login_throttle.refused` climbing is the proof it is before the
    hash. The sign-in and admin paths both trip the per-address bound, so they
    run in SEPARATE boots (one address each); creation uses its own table and
    rides with sign-in. Each boot's lockout is this gate's alone."""
    failures = []
    expect = lambda ok, what: None if ok else failures.append(what)
    wrong = "name=apoorva&password=nope&action=login&next=%2Fchat"
    right = "name=apoorva&password=correct+horse+battery+staple&action=login&next=%2Fchat"

    def post(port, path, body, cookie=None):
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if cookie:
            headers["Cookie"] = cookie
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request("POST", path, body=body, headers=headers)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status

    def refused_count(port):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request("GET", "/version")
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return json.loads(body).get("login_throttle", {}).get("refused")

    def drive_create_and_signin(host, port):
        # Account creation (its own table): two made, the third refused.
        for i in range(2):  # login_throttle.create_max
            reg = f"name=throttlemaker{i}&password=correct+horse+battery+staple&action=register&next=%2F"
            expect(post(port, "/login/full", reg) != 429, f"{host}: account creation #{i + 1} was refused early")
        reg3 = "name=throttlemaker2&password=correct+horse+battery+staple&action=register&next=%2F"
        expect(post(port, "/login/full", reg3) == 429, f"{host}: the 3rd account creation was not refused 429")
        # Sign-in (the per-address fail bound): untouched by the creations above.
        for i in range(10):  # login_throttle.addr_fails
            st = post(port, "/login/full", wrong)
            expect(st == 200, f"{host}: wrong sign-in #{i + 1} was {st}, not the 200 wrong-password page")
        expect(post(port, "/login/full", wrong) == 429, f"{host}: the 11th wrong sign-in was not refused 429")
        expect(post(port, "/login/full", right) == 429, f"{host}: a correct sign-in over the bound was not refused 429 "
                                                        "(so the refusal is not before the hash)")
        n = refused_count(port)
        expect(n is not None and n >= 3, f"{host}: /version login_throttle.refused is {n}, did not climb to >= 3")

    def drive_admin(host, port):
        cookie = mint_session("1", int(time.time()))  # the admin's own session
        for i in range(10):  # login_throttle.addr_fails, via /admin/backup's re-entry
            st = post(port, "/admin/backup", "password=nope", cookie)
            expect(st == 403, f"{host}: admin re-entry #{i + 1} was {st}, not the 403 wrong-password page")
        expect(post(port, "/admin/backup", "password=nope", cookie) == 429,
               f"{host}: the 11th admin re-entry was not refused 429")
        n = refused_count(port)
        expect(n is not None and n >= 1, f"{host}: /version login_throttle.refused did not climb for the admin re-entry")

    def on_metal(fn):
        scratch = tempfile.mkdtemp(dir=work)
        image = os.path.join(scratch, "disk.img")
        shutil.copy(pristine, image)
        disk_write(image, mnt, "zig-metal-unikernel.conf", request_limit_text(image, 30))
        qemu, port, serial = start_kernel(elf, image, scratch)
        try:
            fn("metal", port)
            use_up_requests(qemu, port, 30)
        finally:
            code, _ = finish_kernel(qemu, serial)
        expect(code == 1, f"metal: the guest exited {code}, not at its request limit")
        shutil.rmtree(scratch, ignore_errors=True)

    def on_linux(fn):
        root = tempfile.mkdtemp(dir=work)
        shutil.rmtree(root)
        shutil.copytree(content, root)
        server = LinuxServer(linux_bin, root, os.path.join(root, "server.log"))
        try:
            fn("linux", server.port)
        finally:
            server.stop()
        shutil.rmtree(root, ignore_errors=True)

    # Two boots per host: sign-in+creation trip the address bound in one, the
    # admin re-entry in the other (a fresh address), so neither masks the other.
    for drive in (drive_create_and_signin, drive_admin):
        on_metal(drive)
        on_linux(drive)

    for f in failures:
        report(f"FAIL  login throttle: {f}")
    if not failures:
        report("ok    login throttle: sign-in, account creation and the admin's re-entry all refused before the "
               "hash past their bounds (/version counter climbed), on metal and Linux")
    return len(failures)


def retire_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, report) -> int:
    """**BOTH HOSTS RETIRE THE SAME TREE THE SAME WAY** (QUEUE.md item 104).
    `/admin/retire` is the admin screen that removes old topics and users not
    kept, through the Store's own paths — so it runs on metal, which has no
    shell, as well as on Linux. This stages one tree on each host (an old topic
    and a fresh one, a removed user's DM, a channel with the removed user, and a
    kept user's pointer into the DM that will go), drives the screen as the
    admin, and checks the two hosts agree:
      - the dry run lists the same counts on both (never a body);
      - a confirm removes exactly what the dry run listed;
      - after it, every kept user's resume pages serve (no 404/500) on both;
      - a second dry run would remove nothing (it is idempotent).
    The admin session is minted here; the password is uid 1's."""
    failures = []
    expect = lambda ok, what: None if ok else failures.append(what)
    PASSWORD = "correct+horse+battery+staple"
    old_date = "2020-01-01T00:00:00Z"
    new_date = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 2 * 86400))

    def transcript(sid, date):
        return f"MSG_{sid}_1\nfrom: Tester\ndate: {date}\n\nhello there"

    def fixture(root):
        """Stage the shared tree: keep Steve(1)+apoorva(2), remove Spammer(9)."""
        stage(root, gopher_root)
        write(root, "auth/9/name", "Spammer")
        write(root, "auth/9/password", MEMBER_HASH)
        # DM 1_2: an old topic (retired) and a fresh one (kept).
        write(root, "data/chat/1_2/sessions/oldtopic.md", transcript("oldtopic", old_date))
        write(root, "data/chat/1_2/sessions/oldtopic.uploads/pic.png", "img-bytes")
        write(root, "data/chat/1_2/sessions/freshtopic.md", transcript("freshtopic", new_date))
        # DM 1_9: the removed user's conversation — goes whole.
        write(root, "data/chat/1_9/sessions/chat.md", transcript("chat", new_date))
        # A channel the removed user is in: its line goes, the channel stays.
        write(root, "data/chat/channels/general.channel", "1\n2\n9\n")
        write(root, "data/chat/channels/general/sessions/oldchan.md", transcript("oldchan", old_date))
        # The removed user everywhere else it lives.
        for r in ("data/players/9", "data/users/9", "data/lynrummy/9"):
            write(root, r + "/marker", "x")
        write(root, "data/chat/users/9/last-conv", "1_9")
        # Kept user 1's pointer INTO the DM that will go, and one that stays.
        write(root, "data/chat/users/1/last-conv", "1_9")
        write(root, "data/chat/users/1/last-sessions/1_9", "chat")
        write(root, "data/chat/users/1/pinned-sessions/1_2", "freshtopic")

    def req(port, method, path, cookie, body=None):
        headers = {"Cookie": cookie}
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode("latin-1", "replace")
        conn.close()
        return resp.status, data

    def numbers(html_text):
        """(total, members) from the result page's summary line."""
        m = re.search(r"(?:Would remove|Removed) <strong>(\d+)</strong> thing\(s\) in all; "
                      r"<strong>(\d+)</strong> account", html_text)
        return (int(m.group(1)), int(m.group(2))) if m else (None, None)

    def counts_table(html_text):
        """{label: count} from the result page's by-kind table."""
        return {lab: int(n) for lab, n in re.findall(r"<td>([^<]+)</td><td class=\"n\">(\d+)</td>", html_text)}

    def drive(host, port):
        admin = mint_session("1", int(time.time()))
        body = f"days=30&keep=Steve%2Capoorva&password={PASSWORD}"
        # Dry run: lists, removes nothing.
        st, page = req(port, "POST", "/admin/retire", admin, body)
        expect(st == 200, f"{host}: the preview was {st}, not 200")
        total, members = numbers(page)
        table = counts_table(page)
        # The fixture is still whole after a dry run.
        _, still = req(port, "GET", "/chat/c/1_2/oldtopic/raw", admin)
        # Confirm: carries out exactly what the preview listed.
        st2, page2 = req(port, "POST", "/admin/retire", admin, body + "&confirm=1")
        expect(st2 == 200, f"{host}: the confirm was {st2}, not 200")
        done_total, _ = numbers(page2)
        expect(done_total == total, f"{host}: confirm removed {done_total}, preview listed {total}")
        # Every kept user's resume pages serve — this is the 404 the sweep stops.
        pages = {}
        for uid in ("1", "2"):
            who = mint_session(uid, int(time.time()))
            for path in ("/chat", "/chat/default"):
                ps, _ = req(port, "GET", path, who)
                pages[f"{uid} {path}"] = ps
                expect(ps < 400, f"{host}: {path} for uid {uid} was {ps} after retire")
        # A second dry run finds nothing left.
        _, again = req(port, "POST", "/admin/retire", admin, body)
        again_total, _ = numbers(again)
        expect(again_total == 0, f"{host}: a second dry run would remove {again_total}, not 0")
        return {"total": total, "members": members, "table": table, "pages": pages}

    def on_metal():
        scratch = tempfile.mkdtemp(dir=work)
        root = os.path.join(scratch, "content")
        fixture(root)
        image = os.path.join(scratch, "disk.img")
        build_disk(image, root, os.path.join(scratch, "mnt"))
        set_request_limit(image, 30, os.path.join(scratch, "mnt"), idle_timeout_ms=60000)
        qemu, port, serial = start_kernel(elf, image, scratch)
        try:
            got = drive("metal", port)
            use_up_requests(qemu, port, 30)
        finally:
            code, _ = finish_kernel(qemu, serial)
            shutil.rmtree(scratch, ignore_errors=True)
        expect(code == 1, f"metal: the guest exited {code}, not at its request limit")
        return got

    def on_linux():
        root = tempfile.mkdtemp(dir=work)
        shutil.rmtree(root)
        os.makedirs(root)
        fixture(root)
        server = LinuxServer(linux_bin, root, os.path.join(root, "server.log"))
        try:
            return drive("linux", server.port)
        finally:
            server.stop()
            shutil.rmtree(root, ignore_errors=True)

    metal = on_metal()
    linux = on_linux()
    # The two hosts agree on what retirement does — counts, by-kind, and the
    # pages that serve afterwards.
    expect(metal == linux, f"metal and linux disagreed: {metal} vs {linux}")
    # And the fixture actually exercised the interesting removals.
    expect((metal["members"] or 0) >= 1, "no account was removed — the fixture did not exercise user retirement")
    expect(metal["table"].get("old topic", 0) >= 2, "fewer than two old topics retired — the fixture did not exercise topic retirement")
    expect(metal["table"].get("direct-message conversation", 0) >= 1, "the removed user's DM was not retired")
    expect(metal["table"].get("stale last-conversation pointer", 0) >= 1, "the kept user's dangling last-conv was not swept")

    for f in failures:
        report(f"FAIL  retire: {f}")
    if not failures:
        report("ok    retire: both hosts retired the same tree identically (old topics, a removed user and its DM, "
               "a channel line, a swept pointer), kept users' pages served, and a second run was a no-op")
    return len(failures)


def secret_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, report) -> int:
    """**THE SESSION SECRET IN auth/, SAME ANSWER BEFORE AND AFTER THE MOVE**
    (QUEUE.md item 106). auth/ holds every secret now, data/ none. A tree
    written before the move keeps `_session_secret` in data/chat/; the server
    carries it to auth/ at boot so no session is lost. This boots each host two
    ways — the secret native in auth/, and seeded in the old data/chat/ — and in
    both a session minted with that secret is honored (GET /chat answers 200, not
    the login redirect). On Linux, which this can inspect, the old-place boot
    must leave the secret in auth/ and gone from data/chat/ (never two copies)."""
    failures = []
    expect = lambda ok, what: None if ok else failures.append(what)
    session = mint_session("1", int(time.time()))

    def seed(root, where):
        """Stage the tree, then put the one session secret at `where`."""
        stage(root, gopher_root)  # writes auth/_session_secret
        os.remove(os.path.join(root, "auth", "_session_secret"))
        p = os.path.join(root, *where.split("/"), "_session_secret")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(SESSION_SECRET)

    def chat_status(port):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request("GET", "/chat", headers={"Cookie": session})
        r = conn.getresponse()
        r.read()
        conn.close()
        return r.status

    def on_metal(where):
        scratch = tempfile.mkdtemp(dir=work)
        root = os.path.join(scratch, "content")
        seed(root, where)
        image = os.path.join(scratch, "disk.img")
        build_disk(image, root, os.path.join(scratch, "mnt"))
        set_request_limit(image, 5, os.path.join(scratch, "mnt"), idle_timeout_ms=60000)
        qemu, port, serial = start_kernel(elf, image, scratch)
        try:
            got = chat_status(port)
            use_up_requests(qemu, port, 5)
        finally:
            code, _ = finish_kernel(qemu, serial)
            shutil.rmtree(scratch, ignore_errors=True)
        expect(code == 1, f"metal: the guest exited {code}, not at its request limit")
        return got

    def on_linux(where):
        root = tempfile.mkdtemp(dir=work)
        shutil.rmtree(root)
        os.makedirs(root)
        seed(root, where)
        server = LinuxServer(linux_bin, root, os.path.join(root, "server.log"))
        try:
            st = chat_status(server.port)
        finally:
            server.stop()
        moved = (os.path.exists(os.path.join(root, "auth", "_session_secret"))
                 and not os.path.exists(os.path.join(root, "data", "chat", "_session_secret")))
        shutil.rmtree(root, ignore_errors=True)
        return st, moved

    # Native (auth/): the session is honored on both hosts.
    expect(on_metal("auth") == 200, "metal: a session was not honored with the secret native in auth/")
    linux_native, _ = on_linux("auth")
    expect(linux_native == 200, "linux: a session was not honored with the secret native in auth/")
    # Old place (data/chat/): the boot carries it over, and the session still works.
    expect(on_metal("data/chat") == 200, "metal: a session was lost when the secret started in data/chat/ (migration)")
    linux_old, linux_moved = on_linux("data/chat")
    expect(linux_old == 200, "linux: a session was lost when the secret started in data/chat/ (migration)")
    expect(linux_moved, "linux: after boot the secret was not in auth/ alone (migration left it in data/chat/ or nowhere)")

    for f in failures:
        report(f"FAIL  secret: {f}")
    if not failures:
        report("ok    secret: a session is honored with the secret in auth/ and when carried over from data/chat/, "
               "on metal and Linux; the move leaves it in auth/ alone")
    return len(failures)


# **A SIGNED SHALE SCRIPT, SIGNED HERE** (metal-vmm QUEUE 222): Python's
# standard library has no Ed25519, so node signs, as Dog Park's gate does.
SIGN_JS = r"""
const { generateKeyPairSync, sign, createPrivateKey } = require("node:crypto");
const [what, a, b] = process.argv.slice(1);
if (what === "keygen") {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  console.log(Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("hex"));
  console.log(privateKey.export({ format: "pem", type: "pkcs8" }).replace(/\n/g, "|"));
} else {
  const key = createPrivateKey(a.replace(/\|/g, "\n"));
  const signed = require("node:fs").readFileSync(0);
  process.stdout.write("shale-signature " + sign(null, signed, key).toString("hex") + "\n" + signed);
}
"""


def shale_node(*args, stdin=b""):
    got = subprocess.run(["node", "-e", SIGN_JS, *args], input=stdin, capture_output=True)
    if got.returncode != 0:
        raise RuntimeError(f"node could not sign: {got.stderr.decode().strip()}")
    return got.stdout.decode()


def shale_background_failures(elf, gopher_root, work, report) -> int:
    """**A BACKGROUND SHALE RUN ON METAL, BESIDE REQUESTS** (metal-vmm QUEUE
    222): lynrummy.com's route, as Dog Park's (tools/metal_gate.mjs). A
    signed `mode=background` script of 9,000 store reads (a slice each) is
    answered at once (202); while it runs, a second is refused (503 busy),
    the home page is answered, and GET /admin/script says it is running; the
    kernel steps it between requests and on idle turns until GET
    /admin/script says it finished, with what it printed."""
    label = "a background Shale run"
    failures = []
    expect = lambda ok, what: None if ok else failures.append(what)
    try:
        pub, priv = shale_node("keygen").split("\n")[:2]
    except (OSError, RuntimeError) as e:
        report(f"FAIL  {label}: {e}")
        return 1
    # The admin's (uid 1's) API key, as angry-gopher keeps one: `<uid>-<secret>`.
    api_key = "1-" + "5ca1ab1e" * 8
    scratch = tempfile.mkdtemp(dir=work)
    root = os.path.join(scratch, "content")
    stage(root, gopher_root)
    write(root, "auth/1/api-key", api_key)
    write(root, "auth/shale.conf", f"public_key = {pub}\ntarget = judge.example\n")
    write(root, "auth/shale/sequence", "0\n")
    image = os.path.join(scratch, "disk.img")
    build_disk(image, root, os.path.join(scratch, "mnt"))
    set_request_limit(image, 400, os.path.join(scratch, "mnt"), idle_timeout_ms=60000)
    qemu, port, serial = start_kernel(elf, image, scratch)
    bearer = [f"Authorization: Bearer {api_key}"]
    # 9,000 of the background budget's 10,000 reads (admin_script.zig): on
    # Linux the run takes about 0.1 s, so both envelopes are signed before
    # the first is posted, or the run is over before the second arrives.
    source = 'local n = 0\nfor i = 1, 9000 do if exists("players/1/name") then n = n + 1 end end\nprint("found", n)\n'

    def envelope(seq):
        signed = f"shale-1 target=judge.example sequence={seq} expires={int(time.time()) + 600} mode=background\n{source}"
        return shale_node("sign", priv, stdin=signed.encode())

    def post(seq, signed):
        return ask(port, step(f"a background script, {seq}", "POST", "/admin/script", None, signed, headers=bearer), scratch, patience=60)

    def state():
        return ask(port, step("the background run's state", "GET", "/admin/script", None, headers=bearer), scratch, patience=60)

    try:
        envelopes = {seq: envelope(seq) for seq in (1, 2)}
        first = post(1, envelopes[1])
        expect(first["status"] == 202, f"POST a signed background script answered {first['status']}, not 202: {first['body'][:300]!r}")
        second = post(2, envelopes[2])
        expect(second["status"] == 503 and b"refused (busy)" in second["body"],
               f"a second background script while one runs answered {second['status']}, not 503 busy: {second['body'][:300]!r}")
        home = ask(port, step("the home page, beside the run", "GET", "/"), scratch, patience=60)
        expect(home["status"] == 200, f"the home page, beside a background run, answered {home['status']}")
        seen_running, deadline, last = False, time.time() + 120, b""
        while time.time() < deadline:
            last = state()["body"]
            if b" running: " not in last:
                break
            seen_running = True
            time.sleep(0.2)
        expect(seen_running, "the background run was never seen running: it finished before any request beside it")
        expect(last.startswith(b"background seq=1 finished: "), f"the background run did not finish in 120 s: {last[:300]!r}")
        expect(b"found\t9000\n" in last, f"the background run did not print what it found: {last[:300]!r}")
    finally:
        use_up_requests(qemu, port, 400)
        code, log = finish_kernel(qemu, serial)
        shutil.rmtree(scratch, ignore_errors=True)
    expect(code == 1, f"the kernel exited {code}, not at its request limit")
    for f in failures:
        report(f"FAIL  {label}: {f}")
    if not failures:
        report(f"ok    {label}: answered at once, a second refused while it ran, the site answered beside it, "
               "stepped by the kernel to its end, its output read back")
    return len(failures)


def upload_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """The same uploads to the machine and to Linux, and their answers compared.
    The stored file's name is random on both sides, so what is compared is the
    status, the content type, and the bytes that came back."""
    session = mint_session("1", int(time.time()))
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    # Exactly the story's requests, so the kernel stops on its last answer:
    # 30 left it waiting out finish_kernel's 60 s (QUICK: 62 s of a 152 s run).
    # A story that went wrong sends fewer, and then the 60 s is the wait.
    set_request_limit(image, UPLOAD_STORY_REQUESTS_QUICK if QUICK else UPLOAD_STORY_REQUESTS, mnt)
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        metal = upload_story(port, session)
    finally:
        code, log = finish_kernel(qemu, serial)

    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    try:
        linux = upload_story(server.port, session)
    finally:
        server.stop()

    failures = 0
    if code != 1:
        failures += 1
        report(f"FAIL  uploads: the kernel exited {code}, not on the story's last answer")
    for name, want in linux.items():
        got = metal.get(name, {})
        if got != want:
            failures += 1
            report(f"FAIL  uploads: {name}: the machine said {abbrev(got.get('body', b''))} "
                   f"({got.get('status')}, {got.get('type')}), Linux said "
                   f"{abbrev(want.get('body', b''))} ({want['status']}, {want.get('type')})")
    # **AGREEING ON A FAILURE IS NOT PASSING.** Two servers that both refused
    # the upload, or both answered 404 for the stored file, agree perfectly.
    for side, answers in (("the machine", metal), ("Linux", linux)):
        got = answers.get("it comes back", {})
        if got.get("status") != 200 or got.get("body") != b"the same bytes":
            failures += 1
            report(f"FAIL  uploads: {side} did not give the picture back: "
                   f"{got.get('status')} {abbrev(got.get('body', b''))}")
    if not failures:
        sizes = "a 64 KB picture" + ("" if QUICK else f", a 5 MB one streamed back in pieces, and one of {OVERSIZED_UPLOAD >> 20} MB")
        report(f"ok    uploads: {sizes}, stored, read back byte for byte, and refused as Linux refuses them")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def linux_sse_failures(linux_bin, content, work, report) -> int:
    scratch = tempfile.mkdtemp(dir=work)
    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    try:
        failures = sse_story(server.port, scratch, report, "live stream on Linux")
        # Linux's keepalive is the application's 25 seconds, and cannot be set.
        if not QUICK:
            failures += tab_story(server.port, scratch, report, "a chat tab on Linux")
        return failures
    finally:
        server.stop()
        shutil.rmtree(scratch, ignore_errors=True)


STREAMS_LINE = re.compile(r"streams: at most (\d+) held at once, (\d+) ended, (\d+) still subscribed")
FINAL_HEAP = re.compile(r"base heap holds (\d+) live bytes in (\d+) allocations")


def metal_sse_failures(elf, pristine, work, mnt, report) -> int:
    """The same live-stream story, told to the machine — whose stream table
    keeps the stream its handler handed over. Then the story's client closes
    the stream, one more request lets the kernel reach its count, and the log
    must say the stream was ended because its client went away."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, 5, mnt)  # the story's four, and one to finish on
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        failures = sse_story(port, scratch, report, "live stream on the machine")
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
    finally:
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  live stream on the machine: the kernel exited {code}: "
               + " | ".join(log.splitlines()[-3:]))
    if "stream ended: its client went away" not in log:
        failures += 1
        report("FAIL  live stream on the machine: the kernel never ended the stream its client closed")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("1", "1", "0"):
        failures += 1
        report(f"FAIL  live stream on the machine: the kernel's stream count reads "
               f"{held.group(0) if held else 'nothing'}, want 1 held, 1 ended, 0 still subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures + metal_tab_failures(elf, pristine, work, mnt, report)


def metal_tab_failures(elf, pristine, work, mnt, report) -> int:
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    keepalive = 3 if QUICK else 25
    set_request_limit(image, 9, mnt,  # the tab's eight, and one to finish on
                      keepalive_ms=None if keepalive == 25 else keepalive * 1000)
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        failures = tab_story(port, scratch, report, "a chat tab on the machine", keepalive)
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
    finally:
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  a chat tab on the machine: the kernel exited {code}")
    if log.count("stream ended: its client went away") != 3:
        failures += 1
        report(f"FAIL  a chat tab on the machine: {log.count('stream ended: its client went away')} "
               f"streams ended because their client left, want 3")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("3", "3", "0"):
        failures += 1
        report(f"FAIL  a chat tab on the machine: the stream count reads "
               f"{held.group(0) if held else 'nothing'}, want 3 held, 3 ended, 0 still subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def boot_with(elf, pristine, work, mnt, requests, **conf):
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, requests, mnt, **conf)
    qemu, port, serial = start_kernel(elf, image, scratch)
    return scratch, qemu, port, serial


def login_cookie(port, scratch, body=LOGIN_BODY) -> str:
    jar = update_jar(ask(port, step("log in", "POST", "/login/full", None, body), scratch, patience=60), {})
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def send_live(port, scratch, cookie, topic, text, cid):
    return ask(port, step(f"send {text}", "POST", f"/chat/c/1_2/{topic}/send", cookie,
                          f"markdown={text}&cid={cid}", headers=["X-Chat-Async: 1"]),
               scratch, patience=60)


def budget_failures(elf, pristine, work, mnt, report) -> int:
    """**STREAMS CANNOT STARVE REQUESTS.** With a budget of two, a third stream
    ends the OLDEST — the browser would reconnect and resume — and the other two
    go on receiving; the site goes on answering. Seven requests: log in, a first
    message, streams A, B and C, a live message, one to finish on."""
    label = "the stream budget"
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, 7, streams=2)
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    socks = []
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "budget", "budget-opener", "b0")
        got = []
        for _ in range(3):
            sock = open_stream(port, "/chat/c/1_2/budget/stream?since=0", cookie)
            socks.append(sock)
            got.append(read_until(sock, b"budget-opener", time.time() + 30))
        # A — the oldest — was ended to make room for C: its socket reads the end.
        rest = read_until(socks[0], b"never", time.time() + 5, got[0])
        a_ended = False
        try:
            socks[0].settimeout(2)
            a_ended = socks[0].recv(64) == b""
        except OSError:
            a_ended = True
        if not a_ended:
            fail("the oldest stream was not closed when a third was opened with a budget of two")
        send_live(port, scratch, cookie, "budget", "budget-live", "b1")
        for name, k in (("B", 1), ("C", 2)):
            got[k] = read_until(socks[k], b"budget-live", time.time() + 15, got[k])
            if b"budget-live" not in got[k]:
                fail(f"stream {name}, still within the budget, never got the live message")
        if b"budget-live" in rest:
            fail("the ended stream still received the live message")
    finally:
        for sock in socks:
            sock.close()
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        fail(f"the kernel exited {code}")
    if log.count("stream ended: to make room for a newer one") != 1:
        fail(f"{log.count('stream ended: to make room for a newer one')} streams were ended to make room, want 1")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("2", "3", "0"):
        fail(f"the stream count reads {held.group(0) if held else 'nothing'}, "
             f"want at most 2 held, 3 ended, 0 still subscribed")
    if not failures:
        report(f"ok    {label}: with room for two, a third stream ended the oldest; the other two "
               f"got the live message, and nothing was left subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def churn(elf, pristine, work, mnt, n: int, report):
    """n streams opened and closed one after another — half by a polite FIN,
    half by a reset. Answers (failures, the heap's live bytes at the end)."""
    label = f"{n} streams opened and closed"
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, n + 3)
    failures = 0
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "churn", "churn-opener", "c0")
        for k in range(n):
            sock = open_stream(port, "/chat/c/1_2/churn/stream?since=0", cookie)
            read_until(sock, b"churn-opener", time.time() + 30)
            if k % 2:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
    finally:
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  {label}: the kernel exited {code}")
    went = log.count("stream ended: its client went away")
    if went != n:
        failures += 1
        report(f"FAIL  {label}: {went} ended because their client went away, want {n}")
    held = STREAMS_LINE.search(log)
    if held is None or held.group(2) != str(n) or held.group(3) != "0":
        failures += 1
        report(f"FAIL  {label}: the stream count reads {held.group(0) if held else 'nothing'}, "
               f"want {n} ended and 0 still subscribed")
    heap = FINAL_HEAP.search(log)
    shutil.rmtree(scratch, ignore_errors=True)
    return failures, (int(heap.group(1)) if heap else None)


def churn_failures(elf, pristine, work, mnt, report) -> int:
    """**NOTHING IS KEPT PER STREAM.** The same boot with 5 streams churned and
    with 25 must end holding the same number of live bytes: anything a stream
    left behind would show up 20 times over."""
    few, many = (3, 9) if QUICK else (5, 25)
    f_few, heap_few = churn(elf, pristine, work, mnt, few, report)
    f_many, heap_many = churn(elf, pristine, work, mnt, many, report)
    failures = f_few + f_many
    if heap_few is None or heap_many is None:
        failures += 1
        report("FAIL  stream churn: a boot did not report its heap")
    elif heap_few != heap_many:
        failures += 1
        report(f"FAIL  stream churn: {heap_few} live bytes after {few} streams, {heap_many} after "
               f"{many} — {(heap_many - heap_few) / (many - few):.1f} bytes kept per stream")
    if not failures:
        report(f"ok    stream churn: {few} and then {many} streams opened and closed (half by reset), every "
               f"one ended because its client went away, nothing left subscribed, and both boots "
               f"end holding {heap_few} live bytes")
    return failures


def base_heap_trace(log: str) -> list:
    """What the base heap holds after each request: LIVE bytes."""
    return [int(m.group(1)) for m in BASE_HEAP.finditer(log)]


def base_heap_taken(log: str) -> list:
    """What the machine has handed out in whole pages to hold that — always
    more, because a page is 4096 bytes and an allocator keeps slack."""
    return [int(m.group(2)) for m in BASE_HEAP.finditer(log)]


WAIT_LIMIT_US = 900_000
TIMING = re.compile(
    r"waited (\d+) us, answered in (\d+) us, (\d+) disk requests taking (\d+) us")


def request_timings(log: str) -> list:
    """**WHAT THE MACHINE SAYS EACH REQUEST COST**, in microseconds, as
    (from the connection opening to its turn — the client finishing its request,
    then the queue — answering it, disk requests made while answering, the time
    those took). Its own clock, so curl, slirp and the
    emulator's network are all on the other side of the measurement — and the
    disk's share of the answer is its own number."""
    return [(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            for m in TIMING.finditer(log)]


def base_heap_peak(log: str) -> list:
    """**THE NUMBER THAT DECIDES WHETHER THIS CAN BE DEPLOYED.** The most memory
    ever held at once. Live bytes can sit flat forever while this climbs — which
    is exactly what a bump allocator does, since its free() reclaims only the
    block it handed out last. A peak that stops rising is a machine that can
    stay up."""
    return [int(m.group(3)) for m in BASE_HEAP.finditer(log)]


def request_heap_trace(log: str) -> list:
    return [int(m.group(1)) for m in re.finditer(r"request heap: (\d+) bytes", log)]


# ── the send side ────────────────────────────────────────────────────────────
#
# Everything above fits in a few segments and in the emulator's buffers, so
# none of it can tell a TCP that respects the peer's window from one that
# ignores it, or one that retransmits from one that doesn't. These can.

BULK_MESSAGES = 8
TCP_LINE = re.compile(r"tcp: (\d+) timeouts sent something again, (\d+) window probes, "
                      r"(\d+) peers given up on, \d+ never finished, \d+ strays reset, "
                      r"(\d+) frames lost on purpose")


def bulk_name(n: int) -> bytes:
    return f"bulk-{n:02d}".encode()


def bulk_text(n: int, repeats: int = 2200) -> str:
    """About 40 KB of markdown (at the default), form-encoded, that names
    itself first. 3300 repeats is about 60 KB, near chat's 64 KB limit."""
    return bulk_name(n).decode() + "+" + "lorem+ipsum+dolor+" * repeats


def bulk_steps() -> list:
    """Large requests and large answers: eight 40 KB messages in, then the
    whole 320 KB transcript and the conversation's page out."""
    steps = [step("log in", "POST", "/login/full", None, LOGIN_BODY)]
    for n in range(1, BULK_MESSAGES + 1):
        steps.append(step(f"a 40 KB message, {n}", "POST", "/chat/c/1_2/bulk/send", JAR,
                          f"markdown={bulk_text(n)}&cid=b{n}", headers=["X-Chat-Async: 1"]))
    names = [bulk_name(n) for n in range(1, BULK_MESSAGES + 1)]
    steps.append(step("the whole transcript", "GET", "/chat/c/1_2/bulk/raw", JAR, expect=names))
    steps.append(step("the conversation's page", "GET", "/chat/c/1_2/bulk", JAR))
    return steps


BULK = bulk_steps()


def tcp_counts(log: str):
    m = TCP_LINE.search(log)
    return None if m is None else dict(zip(("retransmits", "probes", "given_up", "lost"),
                                           map(int, m.groups())))


def bulk_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """The bulk story twice: once as it comes, and once with every seventh TCP
    frame in each direction thrown away. Both must answer as Linux answered."""
    failures = 0
    runs = [("bulk", None)]
    if not QUICK:
        runs.append(("bulk, losing one frame sent in seven", {"lose_one_sent_in": 7}))
    for label, conf in runs:
        started = time.time()
        f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                           BULK, label, report, conf=conf)
        f += missing_marks(BULK, answers, report, label)
        counts = tcp_counts(log)
        if counts is None:
            f += 1
            report(f"FAIL  {label}: the kernel never gave its TCP counts")
        elif conf:
            if counts["lost"] == 0 or counts["retransmits"] == 0:
                f += 1
                report(f"FAIL  {label}: {counts['lost']} frames lost and {counts['retransmits']} "
                       f"retransmissions — the loss was not exercised")
        if counts and counts["given_up"]:
            f += 1
            report(f"FAIL  {label}: the kernel gave up on {counts['given_up']} peers")
        if not f:
            sizes = [len(a.get("body", b"")) for a in answers[-2:]]
            report(f"ok    {label}: {BULK_MESSAGES} messages of 40 KB in, a {sizes[0]}-byte transcript "
                   f"and a {sizes[1]}-byte page out, all answered as Linux answered, {files} files agree "
                   f"({counts['lost']} frames lost, {counts['retransmits']} timeouts resent, "
                   f"{time.time() - started:.0f} s)")
        failures += f
    return failures


def get_on_socket(sock, path: str, cookie: str) -> None:
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                  f"Connection: close\r\n\r\n").encode())


def small_socket(port: int):
    """A client whose receive buffer is as small as the host allows, so that
    not reading shows up at the machine as a shut window."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
    sock.settimeout(60)
    sock.connect(("127.0.0.1", port))
    return sock


def lagging_stream_failures(elf, pristine, work, mnt, report) -> int:
    """**A TAB THAT STOPS READING LOSES ITS STREAM, NOT THE SITE.** Two streams
    on one conversation; one is read all along, the other is read once and then
    ignored while 60 KB messages are published back to back — each frame about
    120 KB, bigger than a whole send queue. The ignored one must be ended as
    not keeping up once it has taken nothing for the idle time, and the read
    one must get every message: a host that moved streams only between
    requests fell behind by part of a frame per message, and its mailbox
    dropped events once it held sixteen."""
    label = "a lagging stream"
    sent_all = 60  # far past what the host buffers, and past sixteen behind
    requests = 1 + 1 + 2 + sent_all + 1
    idle_ms = 3000
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, requests,
                                            idle_timeout_ms=idle_ms)
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    stream_path = "/chat/c/1_2/lag/stream?since=0"
    got = {"reader": b""}
    stop = threading.Event()
    sent = 0
    socks = []
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "lag", "lag-opener", "l0")
        reader = open_stream(port, stream_path, cookie)
        socks.append(reader)
        got["reader"] = read_until(reader, b"lag-opener", time.time() + 30)
        lagger = small_socket(port)
        socks.append(lagger)
        lagger.sendall((f"GET {stream_path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                        f"Accept: text/event-stream\r\n\r\n").encode())
        read_until(lagger, b"lag-opener", time.time() + 30)

        def keep_reading():
            reader.settimeout(0.2)
            while not stop.is_set():
                try:
                    chunk = reader.recv(65536)
                except OSError:
                    continue
                if not chunk:
                    return
                got["reader"] += chunk

        t = threading.Thread(target=keep_reading, daemon=True)
        t.start()
        for n in range(1, sent_all + 1):
            answer = send_live(port, scratch, cookie, "lag", bulk_text(n, 3300), f"l{n}")
            sent = n
            if answer.get("status") != 204:
                fail(f"sending message {n} answered {answer.get('status') or answer.get('error')}")
        deadline = time.time() + 30
        while bulk_name(sent) not in got["reader"] and time.time() < deadline:
            time.sleep(0.1)
        # **THE IGNORED STREAM IS ENDED ONLY ONCE IT HAS BEEN STUCK FOR THE
        # IDLE TIME**, and closing it first would end it as gone instead. A
        # machine fast enough to deliver all sixty before then (the droplet's,
        # once MSI-X stopped costing an ISR read per frame) must not fail for
        # it, so the judge waits for the kernel to say so, bounded.
        deadline = time.time() + idle_ms / 1000 + 10
        while time.time() < deadline:
            with open(serial, "rb") as seen:
                if b"stream ended: its client is not keeping up" in seen.read():
                    break
            time.sleep(0.1)
        stop.set()
        t.join()
    finally:
        for sock in socks:
            sock.close()
        for _ in range(requests - 2 - 2 - sent):
            ask(port, step("to the end", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        fail(f"the kernel exited {code}")
    if log.count("stream ended: its client is not keeping up") != 1:
        endings = [l.strip() for l in log.splitlines() if "stream ended:" in l]
        fail(f"{log.count('stream ended: its client is not keeping up')} streams ended as not keeping "
             f"up after {sent} messages, want 1; the kernel ended: {endings}")
    missing = [n for n in range(1, sent + 1) if bulk_name(n) not in got["reader"]]
    if missing:
        # The evidence stays: what the reader got, beside the kernel's log.
        with open(os.path.join(scratch, "reader.bytes"), "wb") as f:
            f.write(got["reader"])
        fail(f"the stream that kept reading is missing messages {missing}; "
             f"its bytes and the kernel's log are in {scratch}")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("2", "2", "0"):
        fail(f"the stream count reads {held.group(0) if held else 'nothing'}, "
             f"want 2 held, 2 ended, 0 still subscribed")
    if not failures:
        report(f"ok    {label}: of two streams sent {sent} 60 KB messages back to back, the one nobody "
               f"read was ended as not keeping up, and the one being read got all {sent}")
        shutil.rmtree(scratch, ignore_errors=True)
    return failures


class Laps:
    """How long each part of the run took, said as each ends: the judge is
    worth running only as often as it is quick."""

    def __init__(self):
        self.start = self.at = time.time()

    def __call__(self, name: str) -> None:
        now = time.time()
        print(f"      ({name}: {now - self.at:.0f} s)", flush=True)
        self.at = now

    def total(self) -> float:
        return time.time() - self.start


# **ONE webbox, AND ONE shale, ON BOTH SIDES.** The kernel takes each from
# -Dwebbox-root and -Dshale-root (WEBBOX_ROOT, SHALE_ROOT, whose defaults
# are build.zig's: ../zig-webbox, ../shale), the Linux zig-server from its
# build.zig.zon's dependency paths: the judge refuses to compare two hosts
# built on two different libraries.
_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBBOX_ROOT = os.path.realpath(os.environ.get("WEBBOX_ROOT", os.path.join(_HERE, "..", "zig-webbox")))
SHALE_ROOT = os.path.realpath(os.environ.get("SHALE_ROOT", os.path.join(_HERE, "..", "shale")))


def two_libraries(gopher_root: str, name: str, root: str):
    """The refusal when the Linux zig-server's library `name` (the path its
    build.zig.zon names) is not `root`, the kernel's; None when they are one
    checkout."""
    zig_server = os.path.join(gopher_root, "zig-server")
    zon = os.path.join(zig_server, "build.zig.zon")
    with open(zon, encoding="utf-8") as f:
        m = re.search(r'\.' + name + r'\s*=\s*\.\{\s*\.path\s*=\s*"([^"]+)"', f.read())
    if m is None:
        return f"FAIL {name} | {zon} names no {name} path: the Linux build's library is unknown"
    linux = os.path.realpath(os.path.join(zig_server, m.group(1)))
    if linux != os.path.realpath(root):
        return (f"FAIL {name} | the kernel's {name} is {os.path.realpath(root)}, the Linux build's {linux} "
                f"({zon}): not one library")
    return None


def two_webboxes(gopher_root: str, webbox_root: str):
    """two_libraries for webbox."""
    return two_libraries(gopher_root, "webbox", webbox_root)


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip())
        return 2
    elf, linux_bin, gopher_root, work = sys.argv[1:]
    refusal = two_webboxes(gopher_root, WEBBOX_ROOT) or two_libraries(gopher_root, "shale", SHALE_ROOT)
    if refusal:
        print(refusal)
        return 1
    if FAT_KIND not in ("16", "32"):
        print(f"FAT must be 16 or 32, not {FAT_KIND}")
        return 2
    global EXPECTED_COMMIT
    EXPECTED_COMMIT = checkout_commit(gopher_root)
    if MOUNT and subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("SKIPPED: JUDGE_MOUNT=1 reads the disk through a loop mount, which needs `sudo -n`")
        return 77
    for tool in ("sgdisk", "mkfs.vfat", "fsck.vfat", "qemu-system-x86_64",
                 *(() if MOUNT else ("mcopy", "mdir", "mdel", "mdeltree"))):
        if shutil.which(tool) is None:
            print(f"SKIPPED: {tool} is not installed")
            return 77

    asked = [g for g in os.environ.get("JUDGE_ONLY", "").replace(",", " ").split()]
    unknown = [g for g in asked if g not in GATES]
    if unknown:
        print(f"no such gate: {' '.join(unknown)}. The gates are: {' '.join(GATES)}")
        return 2
    chosen = set(asked) if asked else set(GATES) - (LONG if QUICK else set())

    # **NOT `want`**: the member story below binds `want` as a loop variable for
    # the status a minted cookie must get, and shadowed this into an int.
    def running(gate: str) -> bool:
        return gate in chosen

    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    content = os.path.join(work, "content")
    stage(content, gopher_root)
    pristine = os.path.join(work, "pristine.img")
    mnt = os.path.join(work, "mnt")
    build_disk(pristine, content, mnt)
    # The kernel serves until stopped unless its volume says otherwise. One
    # request per boot for the cases; run_story rewrites this for longer boots.
    set_request_limit(pristine, 1, mnt)
    lap = Laps()
    lap("staging")

    failures = 0
    per_case = 0
    if running("cases") and not ISOLATED:
        steps = [step(c["name"], c["method"], c["path"], c["cookie"], c["body"]) for c in CASES]
        f, _, answers, _ = run_story(elf, linux_bin, content, pristine, work, mnt,
                                     steps, "single requests, one boot", print)
        failures += f
        per_case = f
        if not f:
            print(f"ok    {len(CASES)} single requests to one boot, each answered as Linux answered")
    for c in (CASES if running("cases") and ISOLATED else []):
        scratch = tempfile.mkdtemp(dir=work)
        image = os.path.join(scratch, "disk.img")
        shutil.copy(pristine, image)
        metal = ask_kernel(elf, image, c, scratch)
        linux = ask_linux(linux_bin, content, c, scratch)
        diffs = differences(c, metal, linux)
        if "error" not in metal and "error" not in linux:
            diffs += file_differences(c, image, metal, linux, mnt)
        label = f"{c['name']}  ({c['method']} {c['path']})"
        if diffs:
            failures += 1
            per_case += 1
            print(f"FAIL  {label}")
            for d in diffs:
                print(f"        {d}")
        else:
            extra = f", {len(c['files'])} file(s) agree" if c["files"] else ""
            print(f"ok    {label} -> {metal['status']}, {len(metal['body'])} bytes{extra}")
        shutil.rmtree(scratch, ignore_errors=True)

    if running("cases"):
        lap("single requests, a boot each" if ISOLATED else "single requests, one boot")

    # ── the member story ─────────────────────────────────────────────────────
    if running("members"):
        now = int(time.time())
        minted = {
            FRESH: mint_session("1", now),
            STALE: mint_session("1", now - 400 * 86400),
            FORGED: forge_session("1", "2", now),
            MEMBER2: mint_session("2", now),
        }
        f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                           MEMBER_STORY, "members", print, minted)
        failures += f
        # Each minted cookie must be answered as its name says, not merely the same
        # on both sides: two servers that both honored a stale session would agree.
        by_name = {s["name"]: a for s, a in zip(MEMBER_STORY, answers)}
        for name, want in (("a session minted outside both servers", 200),
                           ("a session 400 days old", 303), ("a forged session", 303)):
            got = by_name[name].get("status")
            if got != want:
                failures += 1
                print(f"FAIL  members: {name} answered {got}, want {want}")
        # The reaction landed, not merely the same on both sides: two hosts
        # that both refused it agreed for months. Its file is in the data
        # tree compared at the end of the story.
        if by_name["a reaction"].get("status") != 204:
            failures += 1
            print(f"FAIL  members: the reaction answered {by_name['a reaction'].get('status')}, want 204")
        if "\N{THUMBS UP SIGN}".encode() not in (by_name["the reactions file"].get("body") or b""):
            failures += 1
            print("FAIL  members: the reactions file does not hold the reaction")
        # /admin/host: the admin gets the page; nobody else does, whatever both
        # sides agree on.
        if by_name["the running server, as the admin"].get("status") != 200:
            failures += 1
            print("FAIL  members: /admin/host did not answer the admin")
        for name in ("the running server, anonymous", "the running server, as a bare uid",
                     "the running server, as a member who is not the admin"):
            a = by_name[name]
            if a.get("status") == 200 or b"<h2>The host</h2>" in (a.get("body") or b""):
                failures += 1
                print(f"FAIL  members: {name}: /admin/host answered {a.get('status')}, with the page")
        # A session the KERNEL minted must be honored by Linux: same secret, same
        # HMAC, and the kernel's clock close enough to Linux's.
        login = by_name["the right one (a $2a$ hash)"]
        metal_session = update_jar(login, {}).get("__Host-gopher_auth")
        if not metal_session:
            failures += 1
            print("FAIL  members: the kernel's login set no session cookie")
        else:
            scratch = tempfile.mkdtemp(dir=work)
            linux = ask_linux(linux_bin, content,
                              step("a kernel-minted session, on Linux", "GET", "/chat/conversations",
                                   f"__Host-gopher_auth={metal_session}"), scratch)
            if linux.get("status") != 200:
                failures += 1
                print(f"FAIL  members: Linux refused the session the kernel minted ({linux.get('status')})")
            shutil.rmtree(scratch, ignore_errors=True)
        if not f and metal_session:
            print(f"ok    the member story: {len(MEMBER_STORY)} requests to ONE boot — login, chat, topics, "
                  f"reactions, admin, logout — each answered as Linux answered, all {files} files agree; "
                  f"a fresh minted session honored, a stale and a forged one refused, "
                  f"and the kernel's own session honored by Linux")

        lap("member story")

    # ── gopher_uid, signed ───────────────────────────────────────────────────
    if running("uids"):
        minted = {FORGED_UID: mint_uid("p1", int(time.time()), b"another secret, as long as the judge's own")}
        f, _, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                         UID_STORY, "uids", print, minted)
        failures += f
        # As each step's name says, not merely alike: two hosts that both
        # honoured a forged cookie would agree.
        by_name = {s["name"]: a for s, a in zip(UID_STORY, answers)}
        playing = lambda a, who: f"Currently playing as <strong>{who}</strong>".encode() in (a.get("body") or b"")
        # Either name, a value set (a clear is Max-Age=0 and empty): a host
        # that set a legacy-named identity fails the "set a cookie" checks
        # below, and the positive ones want __Host- (metal-vmm QUEUE 176.2).
        set_uid = lambda a: re.search(r"(?:^|\n|; |\b)((?:__Host-)?gopher_uid)=([^;\s]+)", a.get("headers", {}).get("set-cookie", ""))
        wrong = []
        upgrade = by_name["a guest upgrade with an unsigned cookie"]
        if upgrade.get("status") != 200 or UPGRADE_HEADING in (upgrade.get("body") or b""):
            wrong.append(f"the guest upgrade answered {upgrade.get('status')}, not the stranger's form")
        for name, who in (("a member's id, hand-set", "Steve"), ("a signature from another secret", "Nikhil"),
                          ("a new player's unsigned spelling is no one", "Debbie")):
            if playing(by_name[name], who) or set_uid(by_name[name]):
                wrong.append(f"{name}: answered as {who}, or set a cookie")
        named = set_uid(by_name["a player names themselves"])
        if not named or named.group(1) != "__Host-gopher_uid" or named.group(2).count(".") != 2:
            wrong.append(f"naming oneself set {named.group(0) if named else 'no cookie'}, not a signed one")
        if not playing(by_name["and is that player, signed"], "Debbie"):
            wrong.append("the signed cookie /play set did not name its player")
        first = by_name["a legacy cookie's first visit is re-signed"]
        resigned = set_uid(first)
        if first.get("status") != 303 or not resigned or resigned.group(1) != "__Host-gopher_uid" or not resigned.group(2).startswith("p1."):
            wrong.append(f"the legacy cookie's first visit answered {first.get('status')}, "
                         f"setting {resigned.group(0) if resigned else 'nothing'}: not re-signed "
                         "(and so p1 did not survive the forged release)")
        if not playing(by_name["and the re-signed cookie is that player"], "Nikhil"):
            wrong.append("the re-signed cookie did not name p1")
        again = by_name["the same unsigned cookie again, inside the grace, is re-signed again"]
        if again.get("status") != 303 or not set_uid(again) or set_uid(again).group(1) != "__Host-gopher_uid" or not set_uid(again).group(2).startswith("p1."):
            wrong.append(f"the legacy cookie inside its grace answered {again.get('status')}, not re-signed again")
        for w in wrong:
            failures += 1
            print(f"FAIL  uids: {w}")
        if not f and not wrong:
            print(f"ok    the uid story: {len(UID_STORY)} requests to ONE boot, each answered as Linux "
                  f"answered, all {files} files agree; a forged release and a forged guest upgrade did "
                  f"nothing, a hand-set, a wrongly signed and a new player's unsigned cookie named no one, and a legacy cookie "
                  f"was re-signed, and again inside its grace")
        lap("uid story")

    # ── a player at the game store's bound ──────────────────────────────────
    if running("caps"):
        minted = {P1_SIGNED: mint_uid("p1", int(time.time()))}
        f, _, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                         CAP_STORY, "caps", print, minted)
        failures += f
        statuses = [a.get("status") for a in answers[:CAP_TRIES]]
        saved = statuses.index(507) if 507 in statuses else len(statuses)
        wrong = []
        if saved < 60 or saved == len(statuses):
            wrong.append(f"{saved} games saved before a 507, of {CAP_TRIES} tried: {statuses}")
        elif any(st != 200 for st in statuses[:saved]) or any(st != 507 for st in statuses[saved:]):
            wrong.append(f"not every game before the bound saved and every one after refused: {statuses}")
        elif b"16 MiB" not in (answers[saved].get("body") or b""):
            wrong.append(f"the 507 did not say why: {answers[saved].get('body')!r}")
        if answers[CAP_TRIES].get("status") != 200:
            wrong.append(f"the list of games answered {answers[CAP_TRIES].get('status')} at the bound")
        for w in wrong:
            failures += 1
            print(f"FAIL  caps: {w}")
        if not f and not wrong:
            print(f"ok    the cap story: {saved} games of 250,000 bytes saved and the next "
                  f"{CAP_TRIES - saved} refused (507, saying why) on both hosts alike, all {files} files agree")
        lap("cap story")

    # ── Lyn Rummy ────────────────────────────────────────────────────────────
    if running("lynrummy"):
        minted = {FRESH: mint_session("1", int(time.time()))}
        f, _, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                         LYNRUMMY_STORY, "lynrummy", print, minted)
        failures += f
        # As each step's name says, not merely alike on both.
        by_name = {s["name"]: a for s, a in zip(LYNRUMMY_STORY, answers)}
        body = lambda name: by_name[name].get("body") or b""
        want = {"a player names themselves": 303, "the game page": 200, "a new game": 200,
                "a move": 204, "another move": 204, "an annotation": 204, "the game, reloaded": 200,
                "its state and moves, for the reload": 200, "the player's games": 200,
                "the same, as JSON": 200, "the game's detail": 200, "a game never made": 404,
                "the puzzles page": 200, "a puzzle's first move": 204, "its second": 204,
                "the puzzles page, reloaded": 200, "the game roster": 200}
        wrong = [f"{name} answered {by_name[name].get('status')}, want {st}"
                 for name, st in want.items() if by_name[name].get("status") != st]
        if not wrong:
            if body("a new game") != b'{"session_id":1}\n':
                wrong.append(f"the new game answered {body('a new game')!r}")
            reload = body("its state and moves, for the reload")
            if b"hand:" not in reload or not reload.endswith(b"---\n1) draw\n2) meld AS KD\n"):
                wrong.append(f"the reload is not the state and both moves: {reload[-80:]!r}")
            if b"session_id: 1\\n" not in body("the puzzles page") or b"session_id: 2\\n" not in body("the puzzles page, reloaded"):
                wrong.append("the puzzles page did not offer session 1, then 2 after a move")
            if b"Lyn" not in body("the game roster"):
                wrong.append("the roster does not show the player")
        for w in wrong:
            failures += 1
            print(f"FAIL  lynrummy: {w}")
        if not f and not wrong:
            print(f"ok    the Lyn Rummy story: {len(LYNRUMMY_STORY)} requests to ONE boot — a name, a game "
                  f"and its moves, a puzzle and its moves, both reloaded, the roster — each answered as "
                  f"Linux answered, all {files} files agree")
        lap("Lyn Rummy story")

    # ── a live stream, on both ───────────────────────────────────────────────
    if running("streams-linux"):
        failures += linux_sse_failures(linux_bin, content, work, print)
        lap("streams on Linux")
    if running("streams-metal"):
        failures += metal_sse_failures(elf, pristine, work, mnt, print)
        lap("streams on the machine")
    if running("budget"):
        failures += budget_failures(elf, pristine, work, mnt, print)
        lap("stream budget")
    if running("shale-background"):
        failures += shale_background_failures(elf, gopher_root, work, print)
        lap("a background Shale run")
    if running("churn"):
        failures += churn_failures(elf, pristine, work, mnt, print)
        lap("stream churn")

    # ── the send side ────────────────────────────────────────────────────────
    if running("bulk"):
        failures += bulk_failures(elf, linux_bin, content, pristine, work, mnt, print)
        lap("bulk")
    if running("uploads"):
        failures += upload_failures(elf, linux_bin, content, pristine, work, mnt, print)
        lap("uploads")
    if running("admin-reset"):
        failures += admin_reset_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, print)
        lap("the admin's password reset")
    if running("throttle"):
        failures += login_throttle_failures(elf, linux_bin, content, pristine, work, mnt, print)
        lap("the login throttle")
    if running("retire"):
        failures += retire_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, print)
        lap("retiring old topics and users")
    if running("secret"):
        failures += secret_failures(elf, linux_bin, content, pristine, work, mnt, gopher_root, print)
        lap("the session secret in auth/")
    # ── slow and stalled readers: metal-vmm's timeouts.sh (gates.sh) ─────────
    if running("lagging"):
        failures += lagging_stream_failures(elf, pristine, work, mnt, print)
        lap("a lagging stream")

    # ── many clients at once ─────────────────────────────────────────────────
    if running("concurrent"):
        failures += concurrent_failures(elf, linux_bin, content, pristine, work, mnt, print)
        lap("many clients")

    # ── the client that says nothing: metal-vmm's timeouts.sh, in the
    # machine's time (gates.sh) ──────────────────────────────────────────────
    # ── endurance: the writes, read back every round ─────────────────────────
    if running("endurance"):
        f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                           ENDURANCE, "endurance", print)
        marks = missing_marks(ENDURANCE, answers, print, "endurance")
        failures += f + marks
        # **THE WRITES ARE WHERE THE HEAP IS ACTUALLY CHURNED.** Reads allocate and
        # free in order, and a bump allocator gives back a free that was the last
        # thing it handed out — so a read-only run can look perfectly frugal while
        # the machine has no way to reclaim anything. These numbers are the honest
        # ones, and they are reported whether or not anything failed.
        live, taken, peak = base_heap_trace(log), base_heap_taken(log), base_heap_peak(log)
        if live and peak:
            at = min(6, len(peak) - 1)
            grew = peak[-1] - peak[at]
            print(f"      endurance: {live[-1]} live bytes in {taken[-1]} bytes of pages; peak "
                  f"{peak[at]} after {at + 1} requests, {peak[-1]} after {len(peak)} "
                  f"({grew} bytes of growth over the writes)")
            # A peak that climbs with every request is a machine with a clock on it.
            # Early rise is caches filling; a bump allocator would never stop.
            if grew > 256 * 1024:
                failures += 1
                print(f"FAIL  endurance: the peak grew {grew} bytes over {len(peak)} requests — "
                      f"this machine is not reusing what it frees")
        if not f and not marks:
            reads = sum(1 for s in ENDURANCE if s["expect"])
            print(f"ok    endurance: {ENDURANCE_ROUNDS} rounds of write-then-read-it-all-back to ONE boot "
                  f"({len(ENDURANCE)} requests) — every one of the {reads} read-backs held every mark "
                  f"written before it, each answered as Linux answered, and all {files} files agree")

        lap("endurance")

    # ── stamina ──────────────────────────────────────────────────────────────
    # ── a damaged disk still boots and serves (QUEUE.md item 13) ─────────────
    if running("damaged"):
        scratch = tempfile.mkdtemp(dir=work)
        image = os.path.join(scratch, "damaged.img")
        shutil.copy(pristine, image)
        leaked = leak_a_cluster(image)
        answer = ask_kernel(elf, image, case("index, on a damaged disk", "GET", "/"), scratch,
                            damaged=True)
        log = answer.get("serial", "")
        # The leak is on `image`, which on the droplet machine is the volume.
        got = disk_check_lines(log).get(image_disk(log))
        if answer.get("status") != 200:
            failures += 1
            print(f"FAIL  damaged: a disk with a leaked cluster was not served from ({answer.get('status')})")
        elif got is None or got["leaked"] != 1 or got["problems"] != 1:
            failures += 1
            print(f"FAIL  damaged: the disk check did not report the one leaked cluster: {got}")
        elif f"    leaked at (the volume), cluster {leaked}, count 1" not in log:
            failures += 1
            print(f"FAIL  damaged: the disk check did not name cluster {leaked}")
        else:
            print(f"ok    damaged: a disk with cluster {leaked} leaked boots, says so, and serves")
        shutil.rmtree(scratch, ignore_errors=True)
        lap("damaged")

    if running("stamina"):
        rounds = STAMINA * STAMINA_ROUNDS
        f, log, answers, _ = run_story(elf, linux_bin, content, pristine, work, mnt,
                                       rounds, "stamina", print)
        failures += f
        first = {}
        drift = 0
        for s, a in zip(rounds, answers):
            key = s["path"]
            body = a.get("body")
            if key not in first:
                first[key] = body
            elif body != first[key]:
                drift += 1
        if drift:
            failures += 1
            print(f"FAIL  stamina: {drift} answers differed from the first answer to the same request")
        trace = base_heap_trace(log)
        settled = trace[len(STAMINA) * 2:]  # after two rounds, anything cached is cached
        if len(trace) != len(rounds):
            failures += 1
            print(f"FAIL  stamina: the kernel logged {len(trace)} requests, not {len(rounds)}")
        elif settled and max(settled) != min(settled):
            failures += 1
            print(f"FAIL  stamina: the base heap grew from {min(settled)} to {max(settled)} live bytes "
                  f"over {len(rounds)} requests")
        # The request heap: each request must use what the same request used in the
        # first round. One that was never reset would only ever grow.
        used = request_heap_trace(log)
        per = len(STAMINA)
        wandered = [i for i in range(per, len(used)) if used[i] != used[i % per]]
        if len(used) != len(rounds):
            failures += 1
            print(f"FAIL  stamina: the kernel logged {len(used)} request-heap figures, not {len(rounds)}")
        elif wandered:
            i = wandered[0]
            failures += 1
            print(f"FAIL  stamina: request {i + 1} ({rounds[i]['path']}) used {used[i]} bytes of its heap; "
                  f"the same request used {used[i % per]} the first time")
        if not f and not drift and len(trace) == len(rounds) and not wandered and len(used) == len(rounds) \
                and (not settled or max(settled) == min(settled)):
            print(f"ok    stamina: {len(rounds)} requests to one boot, every answer the same, "
                  f"base heap steady at {trace[-1]} live bytes, each request's heap the same every round "
                  f"({', '.join(str(u) for u in used[:per])} bytes)")
            peaks = base_heap_peak(log)
            if peaks:
                at = peaks[min(6, len(peaks) - 1)]
                print(f"      stamina: peak memory {at} bytes after seven requests, "
                      f"{peaks[-1]} after {len(peaks)} — "
                      + ("unchanged: every request's memory is reclaimed and reused"
                         if peaks[-1] == at else f"{peaks[-1] - at} bytes of growth"))

        lap("stamina")
    for d in DISK_CHECK_FAILURES:
        failures += 1
        print(f"FAIL  disk check: {d}")
    names = " ".join(g for g in GATES if g in chosen)
    took = f"{lap.total():.0f} s"
    if DROPLET:
        took += f"; on the droplet machine, {loader_boots} boot(s) through the boot loader, the site on the boot disk and chat's data on a SCSI volume"
    if failures:
        print(f"{failures} failure(s) over: {names} ({took})")
    elif chosen == set(GATES):
        boots = "a boot each" if ISOLATED else "one boot"
        print(f"{len(CASES)} of {len(CASES)} single requests ({boots}), and every other gate, "
              f"answered as Linux answered ({took})")
    else:
        print(f"answered as Linux answered: {names} ({took})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
