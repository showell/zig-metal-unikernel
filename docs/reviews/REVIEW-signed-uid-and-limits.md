# Review: signed gopher_uid and the game store's limits, as an adversary

angry-gopher's `uid_cookie.zig` and `game_limits.zig`. Findings 1-3 and 7
(the sweep, the redirect, a lost answer, sibling sites: now `__Host-`
cookies) are fixed, 11 is by design (a count errs toward refusing early),
and 12 was a stale comment. These are left, all low unless said.

### 4. With IPv6, an address is not one client (medium, if prod has IPv6)

`game_limits.seenSlot` keys on the full address text. An IPv6 client
usually holds a /64, so each new address gets its own players and bytes an
hour, and the per-address bounds bind nothing for it. Whether prod is
reachable over IPv6 was not checked. **Fix shape:** key an IPv6 address by
its first 64 bits.

### 5. Registering bypasses the bound on new players

A new member gets a game identity at login, and registering is not counted
by `admitPlayer` (only `/play` asks it). The bytes an hour still bound what
one address writes to the game store; the account store, a few small files
per account, is unbounded. **Fix shape:** count a registration in
`admitPlayer` too.

### 6. A member's signed gopher_uid is a game login that outlives the session

`player.current` reads the signed uid cookie before the session. A copy plays
as the member and survives logging out elsewhere and a password change. It
does not reach chat, and release refuses it. **Fix shape:** for an id that
is an account, take the games' identity from the session only.

### 8. The usage table can be made to walk folders under its lock

`game_limits.slot` measures a player not in its table (`slots`, 256) under
`mu`. With more players than that writing in turn, each write can push one
out and walk another's folder, while every game write waits on the lock; on
metal, each walk is disk reads in the one loop. **Fix shape:** a bigger
table, or a usage file per player updated with each write.

### 9. The floor goes quiet, and covers the game store only

A host that cannot read free space has no floor, and nothing says so. The
floor also stops only game writes, by design, so chat's uploads can still
fill the volume. **Fix shape:** log once when free space cannot be read, and
show it on /admin/host. Whether uploads need a floor is Steve's call.

### 10. The unsigned window starts again if its file goes

`uid_cookie.windowOpen` opens the 30-day window for unsigned cookies the
first time one is checked, and a lost `unsigned-window` file (a restore of
the players' folder from before it existed) opens a new one. **Fix shape:**
treat a missing file as closed once a marker exists.
