# Deploying lynrummy.com and Dog Park

How we run our two sites from the dev box: the machines, where the secrets
live, a release step by step, the way back, Shale scripts, prod's Caddy,
backups, and the dev box's own servers. This is the operator's doc, specific to our
setup; the README says what the kernel is. dog-park's
[`DEPLOY.md`](https://github.com/showell/dog-park/blob/main/DEPLOY.md) is
Dog Park's own. **Running your own copies?** Start at the last section.

## The machines

| | role | address | how it is reached |
|---|---|---|---|
| **the dev box** | every build, gate and image; nothing serves from it publicly except a port the owner opens for an image download | its public address: `curl -s https://ifconfig.me` on it | ssh, as the owner |
| **prod** | Caddy: HTTPS for every site, proxying over the private network; the watchdog script; the Observatory, as a Linux program watching Dog Park (observatory's README, "Where it runs") | public `162.243.1.123`, private `10.100.0.2` | `ssh 162.243.1.123` from the dev box; passwordless sudo |
| **metal** (the droplet named `gopher-metal`) | lynrummy.com: this kernel, chat's data on a DigitalOcean volume (FAT32, serial in `droplet/volume-serial`) | private `10.100.0.4` only | through Caddy, or from prod over the private network; DigitalOcean's recovery console |
| **dogpark** | dogpark.lynrummy.com: this kernel with Dog Park built in, one disk | private `10.100.0.3` only | the same |

**The droplets with no Linux have no ssh.** They listen only on port 80 of
their private card. Their facts come from `/admin/host`, their insides
from Shale scripts. The dev box is in nyc1 and **cannot reach the private
network**, which is nyc2's; prod can.

**One heavy job at a time on the dev box** (a gate, a long tier, an image
build). **Never run a compute or QEMU job on prod.**

## Who does what

- **The agent (on the dev box):** merges, gates, the long tier, building
  and checksumming the image, tagging, Caddy changes on prod over ssh,
  reading `/admin/host`, sending Shale scripts.
- **The owner (Steve), and only the owner:**
  - says go for a release;
  - opens the download port;
  - snapshots the volume, imports the image, rebuilds the droplet;
  - runs anything destructive in a home folder.

  The agent hands the owner the exact commands and the URL. **Never
  `RELEASE_UNGATED=1` without the owner's word.**

## Secrets on the dev box

Each is a file in the owner's home, mode 600. **Never print one**: use it
inline, as `$(cat <file>)`, and never echo, log or commit it.

| file | what | used for |
|---|---|---|
| `~/.gopher_api_key` | lynrummy.com, uid 1 (the owner), an admin key | `/admin/*` as a bearer token |
| `~/.claude_gopher_api_key` | lynrummy.com, uid 3 (the agent's account) | the chat API as Claude |
| `~/.shale_signing_key` | lynrummy.com's Shale signing key (private half; the site holds the public half) | `shale-sign … lynrummy.com` |
| `~/.shale_signing_key.dogpark.lynrummy.com` | Dog Park's own Shale key, never lynrummy's; the image carries the public half | `shale-sign … dogpark.lynrummy.com` |
| `~/.dogpark_admin_key` | Dog Park's admin key | Dog Park's `/admin/*` |

The repos are pushed with the dev box's deploy key. Prod data leaves a
machine only encrypted.

## A lynrummy.com release, step by step

A release is a **boot image** and a **tag**. `vN` is the next number after
the last tag (`git -C ~/showell_repos/zig-metal-unikernel tag -l 'v*'`).
The image compiles angry-gopher's `zig-server/src`, zig-webbox's `src`,
shale's `src` and cobble-webbox's `src` (Codex Chat and the UO town, which
angry-gopher's router mounts with webbox's `combo.Mount`) from their sibling
checkouts, so a release names each of their commits and this repo's, plus
zig-coverage-sdk's, which the verdicts also key on (`tools/verdicts.py`).

1. **Merge** what ships into each repo's master, and push. Then build
   angry-gopher's site files that git does not track:
   `~/showell_repos/angry-gopher/ops/build_downloads` (the Safari downloads;
   every site disk, the gates' and the image's, copies `downloads/`, and
   both refuse without it), and `~/showell_repos/angry-gopher/ops/build_embedded`
   (what the server embeds that git does not track, Shale's pages from the
   shale checkout among them: a copy left from an older build would ship as
   it is). Then **angry-gopher's own checks**,
   `~/showell_repos/angry-gopher/ops/check_zig`: its lints, its unit tests
   and zig-webbox's, which the gates below do not run (they judge metal
   against Linux). It must pass before step 2.
2. **The checks**, on the code as committed, detached. **Nothing in the
   sibling checkouts is edited while they run**, and each attempt gets a
   fresh folder (the summary is appended to):

       D=~/build/zig-metal-unikernel/release-vN-1     # -2, -3 … for a rerun
       mkdir -p $D && cd ~/showell_repos/zig-metal-unikernel && \
           setsid nohup ./release-check.sh $D > /dev/null 2>&1 < /dev/null &

   It runs `gates.sh` (tiers 0-3, about 20 min), then `long.sh` (about 10
   min) only if the gates pass. **It is done when `$D/summary` has a `LONG
   EXIT` line, or a `GATES EXIT` that is not 0.** Both `0` is a pass, and
   each records its verdict for exactly this code (`tools/verdicts.py`). A
   failure: read `$D/gates.log` or `$D/long.log`, fix, commit, rerun in a
   new folder. **A run with `SKIP` set, or a partial `long.sh`, is not a
   pass and records nothing** (README, "Skipping a slow step").
3. **The image**, once both pass. `droplet/chat.py` builds gopher.elf
   itself from this tree, and **refuses unless both verdicts passed for
   exactly this code** and the trees are clean. It also refuses without
   `droplet/trusted-proxy`, prod's private address: without it every request
   through Caddy is one client address, and per-address limits bind the
   whole site.

       mkdir -p ~/build/zig-metal-unikernel/droplet-image && cd ~/build/zig-metal-unikernel/droplet-image
       ~/showell_repos/zig-metal-unikernel/droplet/chat.py vN.img
       gzip -k vN.img && sha256sum vN.img.gz

   **Name it `vN.img.gz`, short:** DigitalOcean's import screen cuts long
   names off. The previous release's image lives in DigitalOcean's Custom
   Images, so nothing need be kept here.
   `droplet/app_image.py` lays the disk out, and is any application's
   builder (Dog Park's too).
4. **Hand the owner** the URL (`http://<the dev box's public address>:9301/vN.img.gz`),
   the sha256, and these steps:
   - on the dev box: `cd ~/build/zig-metal-unikernel/droplet-image && python3 -m http.server 9301`
     (stopped once the import finishes);
   - snapshot the volume (DigitalOcean → Volumes → the volume → Take
     snapshot);
   - Backups & Snapshots → Custom Images → **Import via URL**: the URL,
     Distribution **Unknown**, region **nyc2**, name `vN`;
   - on the **`gopher-metal`** droplet (check the name: the chat image on
     `dogpark` wipes Dog Park's disk, and the kernel then refuses to serve
     with "no volume attached"), Destroy →
     **Restore base image** from `vN`. The volume stays attached and
     untouched.
5. **Check it serves:**
   - `curl -s https://lynrummy.com/version` shows a new `started_ms`;
   - `curl -s -H "Authorization: Bearer $(cat ~/.gopher_api_key)" https://lynrummy.com/admin/host`
     shows this repo's commit and angry-gopher's (zig-webbox's is in the
     tag message, not on the page);
   - each mounted application answers its page: `/codex-chat/` and
     `/uo/town/`;
   - run the watchdog once: `ssh 162.243.1.123 python3 watchdog.py`. It
     lives in prod's home, kept current by angry-gopher's `ops/deploy`, and
     reads metal's address from `~/metal-url` there. **Right after a
     release it reports `metal RESTARTED since last check` and exits
     non-zero: expected, once.** Run it again; every other line must be OK.
6. **Tag** the released commit `vN`, annotated, in zig-metal-unikernel and
   in angry-gopher, and push the tags. The message is the release note;
   the previous tag's (`git show <previous tag> --no-patch`) is the model: the date, the image and its
   sha256, every checkout's commit, where the passing checks' logs are, what is
   new. **What serves is the tag**; master may be ahead of it.
7. **Nothing in the README changes**: the tag is the record (README,
   "Where it stands").
8. **After it serves:** a read-only Shale script or two (below), and
   `ops/knocks` (angry-gopher) for the access logs.

## The way back

**Restore the droplet's base image from the previous release** (Custom
Images keeps every imported one). The data is on the volume, which a rebuild does not touch;
step 4's snapshot covers a release that wrote something bad.

**Prod's Linux server is the last resort only.** It is stopped, with its
`data/` and `auth/` frozen as they were when metal took over on
2026-10-04, so every write since is lost unless it is carried across.
**Never start it while metal serves:** two hosts writing two copies of the
same data cannot be merged. angry-gopher's `ops/deploy` and the watchdog
treat Linux as serving only while `~/linux-serves` exists on prod
(angry-gopher's `deploy/README.md`). If it must serve again:
1. **Freeze metal:** point Caddy at a maintenance page, or at nothing, so
   no more writes land.
2. **Take the data off it**, either way:
   - a backup (below), and only once `droplet/check_backup.py` says it is
     whole, `tar xf <backup>.tar -C back/` (tar keeps the modification
     times);
   - or the whole volume: from the recovery console, `dd if=/dev/sdX1` to
     a file, fetched to the dev box, then `droplet/extract_volume.py
     volume.img back/`, which writes every name in its stored case, every
     byte and time, and checks the result against the volume.
3. **Put it on prod beside the frozen trees:** copy `back/` (holding
   `data/` and `auth/`) to `~/AngryGopher/back`. Keep a copy of
   `~/AngryGopher/gopher.conf` as it is, then set in it `data_dir =
   /home/steve/AngryGopher/back/data` and `auth_dir =
   /home/steve/AngryGopher/back/auth`. Then `touch ~/linux-serves` and
   `sudo systemctl start gopher-server`.
4. **Compare before switching:** on the backup path metal still serves, so
   `droplet/compare_hosts.py back http://127.0.0.1:9001 http://10.100.0.4`
   (run on prod) must end `0 different`; on the volume path,
   `extract_volume.py`'s own check is the comparison, and the writes made
   on metal must show on prod.
5. **Point Caddy back at prod's own server** (`localhost:9001`, angry-gopher's
   `deploy/Caddyfile`) and reload it. `/admin/host` then says `Linux,
   zig-server`.

## Backups

Two kinds, for two kinds of loss. **No routine schedule is set up:** both
are taken by hand.

- **A DigitalOcean volume snapshot** (Volumes → the volume → Take
  snapshot), by the owner, before every release (step 4). It restores the
  whole volume: the answer to the droplet or the volume being gone.
  DigitalOcean's scheduled backups are a droplet feature and do not cover
  volumes.
- **A `/admin/backup` tar**, the answer to "I need yesterday's data back",
  and the only copy that leaves DigitalOcean. **`droplet/backup.sh`** takes
  it on prod, over the private network:

      droplet/backup.sh http://10.100.0.4 [DIR]

  It asks for the admin password (never on a command line or in the
  environment), fetches the tar, checks it is whole with
  `droplet/check_backup.py` (a tar cut short still lists cleanly, so this
  is the only proof), encrypts it with a passphrase it also asks for
  (`age -p`), keeps the newest `GOPHER_BACKUP_KEEP` (7) and shreds the
  rest. **It never leaves a plaintext tar**, even on failure. The admin
  password is not stored on prod, so this cannot be a cron.

**Every tar holds the session secret and every password hash.** Keep only
the `.age`, keep the passphrase away from the backups (a password manager),
and keep the backups off the droplet. A leaked one: `SECRET-LEAK.md`.

**Restoring.** A snapshot: restore the volume in the console, then check
`/admin/host`'s disk report. A tar: decrypt it (`age -d`), check it whole,
unpack it, check the tree with `droplet/check_volume_tree.py <tree> --fat
32 --gib 16` (what a FAT volume cannot hold: [`FAT32.md`](FAT32.md)), and
build a volume image from it with
`droplet/build_volume.py <tree> <out.img> --fat 32 --gib 16`. The new volume has a new FAT serial, so
`droplet/volume-serial` and the boot image change too. Restoring a tar onto
metal has not been run end to end.

## Shale scripts: looking inside a droplet

A signed script sent to `/admin/script` runs on the droplet and prints
what it found.
- **On lynrummy.com:** `sign` makes an atomic run (500 store reads,
  answered in the response); `background` makes a run stepped between
  requests (10,000 reads), read back with a `GET`.
- **On Dog Park:** background only.
- **The cookbook:** shale's `src/script/examples/` (lynrummy.com),
  dog-park's `tools/shale/`.

```
cd <a scratch folder> && cp <script>.shale .
~/showell_repos/shale/zig-out/bin/shale-sign sign <script>.shale lynrummy.com   # or: background
SHALE_ADMIN_KEY=$(cat ~/.gopher_api_key) sh -c '<the curl line it printed>'
curl -sS -H "Authorization: Bearer $(cat ~/.gopher_api_key)" https://lynrummy.com/admin/script   # a background run's state and output
```

- **`shale-sign`** picks the key by the target name (lynrummy.com's,
  or `~/.shale_signing_key.<target>`).
- **The request** is good for 10 minutes and runs once.
- **For Dog Park**, the target is `dogpark.lynrummy.com` and
  `SHALE_ADMIN_KEY` is `$(cat ~/.dogpark_admin_key)`.
- **One background run at a time.** `shale-sign kill <target>` writes a
  `kill.<sequence>.req` that is sent the same way, and ends the run going.
- Every run is logged under `auth/shale/` on the site's disk.

**A new site's key, once:**
1. `shale-sign keygen [target]` makes the pair; the private key goes to
   the file above and is never printed.
2. `shale-sign pubkey [target]` prints `public_key = <64 hex>`.
3. Sign in as the admin, open `/admin/script-key`, paste the hex, give
   the target, type the admin password, Set.
4. Changing the key is step 3 again; the old key's scripts are refused
   from then on.

Dog Park's image carries its public key instead (dog-park `droplet/image.mjs`).

## Prod's Caddy

**Where the configuration lives:**
- angry-gopher's `deploy/Caddyfile` (with the shared `access_log`
  snippet), and its `deploy/README.md` for installing it;
- dog-park's `droplet/dogpark.lynrummy.com.caddy`;
- roc-apps' `<roc-apps>/ops/roc.lynrummy.com.caddy`.

On prod they are installed under `/etc/caddy/`, with the site blocks in
`/etc/caddy/sites/`. **A new access log must exist and be Caddy's before
`caddy validate`**, which runs as root and would make it root's:

    sudo install -o caddy -g caddy -m 640 /dev/null /var/log/caddy/<name>-access.log
    sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

`ops/knocks` (angry-gopher, run on the dev box) reads prod's access logs
and sshd: scanners are weather; a login from a stranger is an event.

## Dog Park

dog-park's [`DEPLOY.md`](https://github.com/showell/dog-park/blob/main/DEPLOY.md)
has the first deploy and "A new release". In short: `zig build metal-gate`
last, then `droplet/image.mjs`, then the owner rebuilds the `dogpark`
droplet (Destroy → Restore base image). It has **one disk: a release starts every game over**
(persistence waits until it is earned).

## The dev box's own servers

- **Dog Park's dev server, :9103:**
  - It runs a copy of the binary, `~/dogpark-test/play/dog-park-play`,
    with `data/`, `PID`, `log` and `config` beside it, and the checkout as
    its working directory, so it reads `solo/` on every request.
  - **A JS change** needs only a browser reload.
  - **A server or physics change:** `zig build` in the checkout, copy
    `zig-out/bin/dog-park-play` over the copy, then restart it detached:

        DOGPARK_PORT=9103 DOGPARK_CONFIG=~/dogpark-test/play/config DOGPARK_INSECURE_COOKIE=yes \
            setsid nohup ~/dogpark-test/play/dog-park-play >> ~/dogpark-test/play/log 2>&1 < /dev/null &

    Kill the old one by the PID in `PID`, never by pattern. Write the new
    PID (from `ss -ltnp`) back to `PID`.
  - An open page then says "the server restarted: reload": expected.
- **The essay surface, :9100:** essay-repl-server, `notes/<slug>.md`
  (CLAUDE.md).

## Running your own copies

Everything above is ours. To stand up your own lynrummy.com (Gopher Chat)
or Dog Park:

- **Fork and check out side by side:** zig-metal-unikernel, zig-webbox,
  zig-coverage-sdk, shale, and angry-gopher (with cobble-webbox, which it
  mounts) or dog-park; metal-vmm too, for tiers
  2-3 and the long tier. Zig 0.17. The README's "What you need" lists the
  rest (QEMU, mtools, dosfstools, KVM for metal-vmm).
- **Try it locally first:** angry-gopher's `ops/start` (Linux, :9001), or
  dog-park's `zig build play` (:9103). Then `./tier0.sh`.
- **Your proxy:** a Linux droplet with Caddy, **its Caddyfile installed
  first** (angry-gopher `deploy/README.md`), then a site block each, with
  your domain and your droplet's private address. DNS: an A record for
  each site, pointing at the proxy, not at the kernel's droplet.
- **Your settings, committed in your fork** (`chat.py` and `image.mjs`
  refuse a dirty tree):
  - `droplet/volume-serial` (zig-metal-unikernel): your volume's serial,
    printed by `droplet/new_volume.py`;
  - `droplet/trusted-proxy` (zig-metal-unikernel, and dog-park's own): your
    proxy's private address;
  - Dog Park's domain, in dog-park `droplet/image.mjs`.
- **lynrummy.com's first deploy** differs from a release:
  1. Create a DigitalOcean volume, 16 GiB, in the region of your private
     network.
  2. Build its image: `droplet/new_volume.py out.img --fat 32 --gib 16`.
     It prints the serial for `droplet/volume-serial`.
  3. Write it from a droplet's recovery console, as `new_volume.py`'s
     header shows.
  4. Create the kernel's droplet from your first image, with the volume
     attached, on the private network.
  5. Check it answers from your proxy: `curl http://<private address>/`.

  Then the release steps above, with your own names.
- **Change the test credentials at once: the new volume is the judge's
  test site, not an empty one.** It has two accounts with a known test
  password and the judge's session secret, which are public in this repo.
  Before anyone else can reach it:
  1. Build the image with `droplet/chat.py vN.img --reset-admin-password Steve`.
     It asks for a new password, and only its hash goes in the image.
  2. Sign in, and rotate the session secret with
     `droplet/rotate_secret.py <url> --days 0`, run from your proxy.
  3. Make yourself an API key on `/admin`.
  4. Remove or re-password the second test account (`apoorva`).
- **Your keys, made fresh:**
  - an admin API key from `/admin`;
  - a Shale key pair (above, "A new site's key");
  - for Dog Park, `droplet/image.mjs` makes the pair the first time.

  Never reuse someone else's keys; a site's key is its own.
- **Your watchdog** (optional): angry-gopher's `deploy/watchdog.py` on
  your proxy, with your kernel's private URL in `~/metal-url`.
