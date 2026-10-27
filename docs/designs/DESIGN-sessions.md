# Sessions: options for Steve

An open decision; no code here. Changing the secret is built
(`/admin/secret`, [SECRET-LEAK.md](../../SECRET-LEAK.md)); session lifetime
and revocation are not.

## As it stands

- **`gopher_auth`**, a member's session: `<id>.<issued>.<mac>`, with mac =
  HMAC(secret, id, issued), good for **365 days** from `issued`
  (angry-gopher `users_session.zig`, `session_max_age_secs`).
- Nothing on the server records a session, so **nothing can revoke one**.
  Logging out clears the browser's copy only; a copy taken before still
  works, and so does one taken after a password change. Only a change of
  the secret ends them all.
- **`gopher_uid`**, a player's identity, is signed with the same secret,
  good for a year and re-signed on a GET past half its life (angry-gopher
  `uid_cookie.zig`). For a player it is the only thing that says who they
  are, and it cannot be revoked either.

## Shorter or revocable sessions: three shapes

**A. Shorter, renewed on use.** The max age drops to, say, 30 days, and a
request with a session older than a week gets a fresh cookie.
- A member who visits monthly never notices.
- A copied cookie lasts at most 30 days, unless the thief keeps using it,
  since renewal works for them too.
- Revocation: still none.
- Cost: a few lines in `users_session.zig`, and a Set-Cookie now and then.

**B. A per-member generation number.** `auth/<id>/session-gen` is a
number, and it goes into the session's MAC.
- Bumping it kills every session of that member at once: on a password
  change, and by a new "log out everywhere" button.
- The same works for a player, with `data/players/<id>/gen`, bumped by
  "log out everywhere" on /play. A player cannot then get back in
  without a cookie, so that button would say so.
- Revocation: per person, at once.
- Cost: one more small file read when a session is checked (the account's
  files are read anyway), and existing cookies re-signed once.

**C. Sessions kept on the server.** A random token in the cookie, looked
up in `data/sessions/`.
- Every session can be listed, ended, and shown to its owner.
- Cost: a file written per login and per renewal, many small files on FAT;
  every request reads one; the backup then holds live tokens as well as the
  secret. It is the most code, and it changes what a cookie is.

**CC's recommendation:** A and B together (30 days renewed on use, and a
generation number bumped by a password change and by "log out
everywhere"). C buys little more at this site's size: one admin and a few
members.

## For Steve to decide

1. The session's max age: 365 days as now, or shorter with renewal (A)?
2. Revocation: none as now, per person (B), or kept on the server (C)?
