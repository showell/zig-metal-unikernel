#!/usr/bin/env python3
"""Real traffic as the judge's input (QUEUE.md item 48): the GETs in a Caddy
access log, asked again of two hosts serving the same data, and compared.

    droplet/replay.py LOG A_URL B_URL [--host lynrummy.com] [--netns NAME] [--unique]
    droplet/replay.py --self-test ZIG_SERVER_BINARY

`LOG` is Caddy's access log, one JSON object a line (`log { format json }`;
`format` is JSON by default). **PROD WRITES NONE TODAY:** its Caddyfile has
no `log` directive, so one has to be added there
before there is anything to replay.

**KEPT:** a request whose `request.method` is GET and whose
`request.headers` holds no `Cookie` and no `Authorization`, whatever their
value (Caddy writes `REDACTED` in place of a credential, so it is never
here to send). With `--host`, only that `request.host`. Left out, and
counted by why:
- anything carrying a credential, and anything that is not a GET;
- a stream (`Accept: text/event-stream`, or a path ending `/stream`),
  which does not end;
- `/version` and `/admin/host`, which describe each host and differ by
  design, as compare_hosts.py leaves them out;
- a line that is not a Caddy request.
With `--unique`, a target asked once already is not asked again.

Each kept request is asked of A and then of B, in the log's order, with
no cookie, redirects not followed. They are compared by status and by the
SHA-256 of the body. With `--netns NAME`, B is asked through `ip netns exec
NAME`, as the box reaches metal's private card.

**IT PRINTS COUNTS AND ANONYMISED LABELS ONLY.** A target can hold a
topic's or a person's name, so a difference is named by its line in the
log, its first path segment, and the start of its target's SHA-256:
`line 812, /chat/... (#3fa9c1d2)`. The operator finds it in the log with
the line number.

**A GET WITH NO CREDENTIAL WRITES NOTHING** on angry-gopher from item 52
on (a puzzle session is made by its first move). The one GET that writes,
re-signing a legacy `gopher_uid` (item 51), needs a cookie, so it is never
kept. Replaying is read-only on both hosts.

Exit status: 0 when every kept request answered alike, 1 when any
differed, 2 for a usage error.
"""
import collections
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DESCRIBES_ITSELF = ("/version", "/admin/host")


def header(headers: dict, name: str) -> list:
    """A header's values from Caddy's map, whatever its case."""
    for k, v in (headers or {}).items():
        if k.lower() == name.lower():
            return v if isinstance(v, list) else [v]
    return []


def keep(entry, host: str = None):
    """(target, None) for a request to replay, or (None, why it is not)."""
    req = entry.get("request") if isinstance(entry, dict) else None
    if not isinstance(req, dict) or not isinstance(req.get("uri"), str):
        return None, "not a Caddy request"
    if host and req.get("host") != host:
        return None, "another host"
    if req.get("method") != "GET":
        return None, "not a GET"
    headers = req.get("headers") or {}
    if header(headers, "Cookie") or header(headers, "Authorization"):
        return None, "a credential"
    uri = req["uri"]
    path = uri.split("?", 1)[0]
    if path.endswith("/stream") or any("text/event-stream" in a for a in header(headers, "Accept")):
        return None, "a stream"
    if path in DESCRIBES_ITSELF:
        return None, "describes the host"
    if not uri.startswith("/"):
        return None, "not a Caddy request"
    return uri, None


def requests(lines, host: str = None, unique: bool = False):
    """[(line number, target)] to replay, and a Counter of why the rest are not."""
    out, dropped, seen = [], collections.Counter(), set()
    for n, line in enumerate(lines, 1):
        try:
            entry = json.loads(line)
        except ValueError:
            dropped["not a Caddy request"] += 1
            continue
        uri, why = keep(entry, host)
        if why:
            dropped[why] += 1
        elif unique and uri in seen:
            dropped["asked already (--unique)"] += 1
        else:
            seen.add(uri)
            out.append((n, uri))
    return out, dropped


def ask(base: str, target: str, netns: str = None) -> tuple:
    """(status, sha256 of the body), by curl, with no cookie, redirects not
    followed: a redirect is an answer to compare."""
    cmd = ["curl", "-sS", "--path-as-is", "-o", "-", "-w", "\n%{http_code}", base.rstrip("/") + target]
    if netns:
        cmd = ["ip", "netns", "exec", netns] + cmd
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        return ("no answer", "")
    body, _, status = r.stdout.rpartition(b"\n")
    return (status.decode(), hashlib.sha256(body).hexdigest())


def label(n: int, target: str) -> str:
    """`line N, /first/... (#hash)`: findable in the log, and naming nothing."""
    first = target.split("?", 1)[0].split("/")[1] if target.count("/") >= 1 else ""
    shape = f"/{first}" + ("/..." if target.split("?", 1)[0].rstrip("/") != f"/{first}" else "")
    if "?" in target:
        shape += "?..."
    # The first segment is the site's own route name, unless it is not one
    # of them, in which case it is not printed either.
    if first not in ROUTES:
        shape = "/(not a route)"
    return f"line {n}, {shape} (#{hashlib.sha256(target.encode()).hexdigest()[:8]})"


# angry-gopher's first path segments (router.zig), the only words printed.
ROUTES = {"", "driving", "delivery", "chess", "puzzles", "game", "chat", "channel", "settings",
          "admin", "gallery", "downloads", "steve-resume", "steve-resume.pdf",
          "safari_download", "login", "logout", "play", "favicon.ico", "robots.txt", "version"}


def replay(log_lines, a: str, b: str, host: str = None, netns: str = None, unique: bool = False):
    """(kept, dropped, differences as [(label, what)])."""
    kept, dropped = requests(log_lines, host, unique)
    differ = []
    for n, target in kept:
        sa, ha = ask(a, target)
        sb, hb = ask(b, target, netns)
        if sa != sb:
            differ.append((label(n, target), f"status {sa} on A, {sb} on B"))
        elif ha != hb:
            differ.append((label(n, target), f"both {sa}, bodies differ"))
    return kept, dropped, differ


def report(kept, dropped, differ, out=print):
    for lab, what in differ:
        out(f"DIFFERS  {lab}: {what}")
    left = ", ".join(f"{c} {why}" for why, c in sorted(dropped.items()))
    out(f"replay: {len(kept)} requests asked of both, {len(kept) - len(differ)} alike, "
        f"{len(differ)} different; left out: {left or 'nothing'}")


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--self-test":
        return self_test(argv[2])
    args = argv[1:]
    unique = "--unique" in args
    if unique:
        args.remove("--unique")
    opts = {"--host": None, "--netns": None}
    for flag in list(opts):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 3 or not os.path.isfile(args[0]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(args[0], encoding="utf-8", errors="replace") as f:
        kept, dropped, differ = replay(f, args[1], args[2], opts["--host"], opts["--netns"], unique)
    report(kept, dropped, differ)
    return 1 if differ else 0


# ── the self-test ───────────────────────────────────────────────────────────

def caddy_line(uri: str, method: str = "GET", host: str = "lynrummy.com", headers: dict = None) -> str:
    """One line as Caddy's JSON access log writes it (the fields replay reads,
    and a few it does not)."""
    return json.dumps({
        "level": "info", "ts": 1790000000.5, "logger": "http.log.access.log0", "msg": "handled request",
        "request": {"remote_ip": "203.0.113.7", "remote_port": "51234", "client_ip": "203.0.113.7",
                    "proto": "HTTP/2.0", "method": method, "host": host, "uri": uri,
                    "headers": headers or {"User-Agent": ["Mozilla/5.0"], "Accept": ["text/html"]}},
        "bytes_read": 0, "user_id": "", "duration": 0.002, "size": 1234, "status": 200,
        "resp_headers": {"Content-Type": ["text/html; charset=utf-8"]}})


def self_test(binary: str) -> int:
    """With two Linux servers on the judge's staged site: a log with every
    kind of line is replayed, identical copies answer alike, a changed copy
    is caught, and the output holds nothing from the targets but route
    names."""
    sys.path.insert(0, os.path.join(ROOT, "probe"))
    import judge_gopher as G
    gopher_root = os.path.dirname(os.path.abspath(binary))
    while not os.path.isfile(os.path.join(gopher_root, "pages", "home.txt")):
        if gopher_root == os.path.dirname(gopher_root):
            print(f"self-test cannot run: no angry-gopher checkout above {binary}")
            return 2
        gopher_root = os.path.dirname(gopher_root)
    secret_word = "quiet-plans-of-nikhil"
    log = [
        caddy_line("/"),
        caddy_line("/driving"),
        caddy_line("/driving?v=zig"),
        caddy_line("/steve-resume"),
        caddy_line(f"/chat/c/1_2/{secret_word}"),       # a redirect to log in, on both
        caddy_line("/"),                                # again: asked again, unless --unique
        caddy_line("/nope"),
        caddy_line(f"/{secret_word}"),                  # not a route: a 404, and never printed
        caddy_line("/chat", headers={"Cookie": ["REDACTED"]}),
        caddy_line("/admin", headers={"Authorization": ["REDACTED"]}),
        caddy_line("/play", method="POST"),
        caddy_line("/chat/c/1_2/general/stream", headers={"Accept": ["text/event-stream"]}),
        caddy_line("/version"),
        caddy_line("/", host="roc.lynrummy.com"),
        "this line is not JSON",
        json.dumps({"level": "info", "msg": "a line that is not a request"}),
    ]
    failures, printed = [], []
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, gopher_root)
        copies = []
        for name in ("a", "b", "c"):
            path = os.path.join(d, name)
            shutil.copytree(site, path)
            copies.append(path)
        # C differs in one page the log asks for.
        with open(os.path.join(copies[2], "pages", "steve-resume.md"), "a") as f:
            f.write("\none more line, on C only\n")
        servers = [G.LinuxServer(binary, c, os.path.join(d, f"{i}.log")) for i, c in enumerate(copies)]
        try:
            a, b, c = (f"http://127.0.0.1:{s.port}" for s in servers)
            kept, dropped, differ = replay(log, a, b, host="lynrummy.com")
            report(kept, dropped, differ, printed.append)
            if len(kept) != 8 or differ:
                failures.append(f"A and B: {len(kept)} asked (want 8), {len(differ)} different (want 0)")
            want = {"a credential": 2, "not a GET": 1, "a stream": 1, "describes the host": 1,
                    "another host": 1, "not a Caddy request": 2}
            if dict(dropped) != want:
                failures.append(f"left out {dict(dropped)}, want {want}")
            kept_u, dropped_u, _ = replay(log, a, b, host="lynrummy.com", unique=True)
            if len(kept_u) != 7 or dropped_u["asked already (--unique)"] != 1:
                failures.append(f"--unique asked {len(kept_u)} (want 7)")
            kept, dropped, differ = replay(log, a, c, host="lynrummy.com")
            report(kept, dropped, differ, printed.append)
            if [lab for lab, _ in differ] != ["line 4, /steve-resume (#" + hashlib.sha256(b"/steve-resume").hexdigest()[:8] + ")"]:
                failures.append(f"A and C: {differ}, want the resume, line 4, only")
            # Were the answers real pages, not two servers refusing alike?
            if ask(a, "/steve-resume")[0] != "200" or ask(a, "/")[0] != "200":
                failures.append("the resume or the index did not answer 200")
        finally:
            for s in servers:
                s.stop()
    text = "\n".join(printed)
    if secret_word in text or "1_2" in text:
        failures.append("the output names a target")
    print(text)
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: 8 of 16 log lines replayed on two Linux servers, alike on identical copies, "
          "the one changed page caught by its line, every other kind of line left out and counted, "
          "and no target's text printed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
