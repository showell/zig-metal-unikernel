#!/bin/bash
# **A BACKUP OF METAL, BY HAND, ON PROD** (DEPLOY.md, "Backups"). Run on
# <prod>, over the private network, where metal answers nothing else while it
# streams:
#
#   droplet/backup.sh HOST [DIR]
#
# HOST  where metal answers on the private network, e.g. http://10.100.0.4
# DIR   where the encrypted backups are kept (default ./gopher-backups)
#
# It asks for the admin password (twice over the wire: to log in, then for the
# archive), fetches /admin/backup, checks it is whole (check_backup.py), encrypts
# it with a passphrase it also asks for (`age -p`), keeps the newest few and
# shreds the rest, and **never leaves a plaintext tar behind, even on failure** —
# a trap shreds it whatever happens. The passwords are read with `read -rs` and
# handed to curl on stdin, so neither is ever in argv or the environment.
#
# It needs: curl, age, shred, python3 (for check_backup.py). The admin name
# defaults to Steve (`GOPHER_ADMIN` to change it); KEEP is how many to keep.
set -euo pipefail

HOST="${1:?usage: droplet/backup.sh HOST [DIR]   (HOST e.g. http://10.100.0.4)}"
DIR="${2:-gopher-backups}"
NAME="${GOPHER_ADMIN:-Steve}"
KEEP="${GOPHER_BACKUP_KEEP:-7}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DIR"
TMP="$(mktemp "$DIR/.gopher-backup.XXXXXX.tar")"
JAR="$(mktemp)"
# **NO PLAINTEXT LEFT BEHIND.** The tar holds every password hash and the
# session secret; the jar holds a live session. Shred both on any exit — a
# failed fetch, a Ctrl-C, or success.
cleanup() {
    [ -e "$TMP" ] && shred -u "$TMP" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
    [ -e "$JAR" ] && shred -u "$JAR" 2>/dev/null || rm -f "$JAR" 2>/dev/null || true
}
trap cleanup EXIT

# The admin password, once, unechoed and out of the shell's history. The prompt
# goes to the terminal (stderr); the read is from the terminal if there is one,
# else from stdin (so a test can drive it). It is never on a command line.
if [ -r /dev/tty ]; then
    read -rsp "admin password: " PW < /dev/tty
else
    printf "admin password: " >&2
    read -rs PW
fi
echo >&2

# Log in (a session), then ask for the archive with the same password. Both go
# over stdin (`password@-`), never argv or the environment.
printf %s "$PW" | curl -fsS -c "$JAR" -d "name=$NAME&action=login" \
    --data-urlencode password@- "$HOST/login/full" > /dev/null
printf %s "$PW" | curl -fsS -b "$JAR" \
    --data-urlencode password@- -o "$TMP" "$HOST/admin/backup"
unset PW

# Whole, or stop here (a cut-short tar still lists cleanly in `tar`).
python3 "$HERE/check_backup.py" "$TMP"

# Encrypt at rest with a passphrase `age` asks for itself (prompted on the
# terminal, never on a command line). The plaintext is shredded the moment the
# ciphertext is written; the trap is the backstop.
OUT="$DIR/gopher-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.age"
age -p -o "$OUT" "$TMP"
shred -u "$TMP"

# Keep the newest KEEP; shred the rest, so a retired hash does not linger.
mapfile -t all < <(ls -1t "$DIR"/*.tar.age 2>/dev/null || true)
for old in "${all[@]:$KEEP}"; do shred -u "$old"; done

kept=$(ls -1 "$DIR"/*.tar.age 2>/dev/null | wc -l | tr -d ' ')
echo "backup: $OUT written, checked whole, encrypted; $kept kept (newest $KEEP), older shredded" >&2
