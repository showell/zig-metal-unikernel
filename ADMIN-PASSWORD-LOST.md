# If the admin password is lost

One page, for the day it is needed. Releases are DEPLOY.md.

## What is locked

The admin is uid 1. Without the admin password there is:
- no backup (`/admin/backup` asks for it);
- no change of the session secret (`/admin/secret` and
  `droplet/rotate_secret.py` ask for it);
- no way to sign in as the admin from a new browser.

The password is stored only as a bcrypt hash, so it cannot be read back.
Metal has no shell to log in to. **A browser still signed in as the admin
is not a way back:** the pages above ask for the password again.

**The way back cannot be started by a request to the site.** It needs a
new boot image.

## The reset, by a boot image

Metal reads the reset from its boot disk, so it takes a deploy. From the
machine that builds images, with angry-gopher beside this checkout:

**1. Build the image with the reset in it:**

    droplet/chat.py chat.img --reset-admin-password Steve

It asks for the new password twice, and hashes it here. The image then
carries `admin_password_reset = Steve <hash>` in its zig-metal-unikernel.conf.
Only the hash is in the image, and nothing goes into the repository.

**2. Deploy it** as any image (DEPLOY.md, "A lynrummy.com release").

**3. Watch the boot.** It must say:

    admin password reset for Steve: applied; the old hash is auth/1/password.before-reset

Any other line means nothing changed:
- `applied by an earlier boot`: this same hash was applied before. A
  password changed since then is kept;
- `REFUSED: uid 1 is not named so`: the name on the command line is not
  uid 1's name on this volume (it is matched exactly, case included);
- `REFUSED: uid 1 has no password`: there is no admin on this volume;
- `FAILED`: the volume would not read or write. The next boot tries
  again.

**4. Log in** with the new password.

**5. Deploy once more without the flag**, so the next image no longer
carries the hash. Leaving it in changes nothing, because the reset is
applied once, but nothing needs to carry it.

## Undoing it

The hash replaced is kept beside the new one, as
`auth/1/password.before-reset`. Putting it back is a change to the data:
from a backup, or the volume, as any file of it.

## Tested

angry-gopher's `ops/test_reset_admin_password`, against a real server;
here, `src/io_test.zig`'s reset tests and the judge's `admin-reset` gate on
both hosts (`probe/run.sh gopher admin-reset`).
