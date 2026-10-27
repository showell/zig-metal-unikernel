# zig's `std.http.HeadParser` and a bare-LF head end

A bug in Zig's standard library, still there in Zig 0.17.0. `src/ready.zig`
pins it in a test that fails once an upgraded Zig fixes it; then this page
and `probe/fuzz_requests.py`'s allowance for it go.

## What happens

`HeadParser.feed` finds the end of a request head: `\r\n\r\n`, or a bare
`\n\n`, which it also accepts. **Whether it finds a bare `\n\n` depends on how
the bytes are split between calls.**
- Fed in pieces under 32 bytes, it finds every one.
- Fed in larger pieces, it uses a vector path. When a vector holds exactly
  two (or three) CR/LF bytes, it checks only the vector's last two (or three)
  bytes. Two wrong answers follow:
  - a `\n\n` elsewhere in that vector is missed, and parsing runs on to a
    later end (`src/ready.zig`'s test);
  - a `\n\n` that is found is reported short of its end (the reproducer
    below).

## Here

Linux reads a connection in large pieces, and metal in TCP segments, so the
two hosts can answer such a request differently:
- one finds the head at the `\n\n` and rejects a bad request line;
- the other reads on, past it, and answers whatever it then finds.

**Real traffic never meets it.** Caddy, in front of both hosts, sends CRLF,
and metal is reachable only on the private network. So nothing in either
host works around it. `probe/fuzz_requests.py` and `src/ready_sim.zig`
count such cases apart, not as differences.

## For an upstream report

```zig
const std = @import("std");
test "HeadParser finds a bare-LF end whatever the read size" {
    const req = "GET /x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/ \nHost: a\nContent-Length: 1\n\n" ++
        "\xffGET / HTTP/1.1\r\nHost: x\r\n\r\n";
    var a: std.http.HeadParser = .{};
    var at: usize = 0;
    while (a.state != .finished) : (at += 1) _ = a.feed(req[at .. at + 1]);
    var b: std.http.HeadParser = .{};
    try std.testing.expectEqual(at, b.feed(req)); // fails: expected 134, found 132
}
```

**The cause:** `feed`'s `else` branch, cases `2` and `3` of `matches`. They
look only at `chunk[vector_len - 2 ..]` and `chunk[vector_len - 3 ..]`, where
the `4...vector_len` case scans every position.
