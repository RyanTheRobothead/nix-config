#!/usr/bin/env bash
# Restore test for Aegis's restic repo on B2 (see restore.md). Run as root: sudo bash restore-test.sh
# Part 1 is quick; part 2 streams the whole volume tarball (~145 GB) and takes hours.
set -euo pipefail

DEST=/var/tmp/restore-test
LOG=$DEST/restore-test.log
mkdir -p "$DEST"
exec > >(tee -a "$LOG") 2>&1

echo "== $(date -Is) snapshots"
restic-backblaze snapshots --latest 3

echo "== $(date -Is) part 1: restore one small file and compare"
F=/home/luckierdodge/repos/nix-config/flake.nix
restic-backblaze restore latest --target "$DEST/quick" --include "$F"
if cmp "$DEST/quick$F" "$F"; then
  echo "flake.nix matches live copy"
else
  echo "flake.nix differs from live copy (expected if edited since the last backup)"
fi

echo "== $(date -Is) part 2: stream the volume tarball, extract Vaultwarden only"
TARBALL=$(restic-backblaze ls latest /mnt/aegis-backup/volumes | grep '\.tar\.gz$' | sort | tail -1 || true)
if [ -z "$TARBALL" ]; then
  echo "FAIL: no volume tarball under /mnt/aegis-backup/volumes in the latest snapshot"
  exit 1
fi
echo "tarball: $TARBALL"
mkdir -p "$DEST/vw"
restic-backblaze dump latest "$TARBALL" \
  | tar -xz -C "$DEST/vw" --wildcards '*vaultwarden/data/*'

echo "== $(date -Is) checks"
DB=$(find "$DEST/vw" -name db.sqlite3 | head -1)
echo "db: $DB"
nix shell nixpkgs#sqlite --command sqlite3 "$DB" \
  'PRAGMA integrity_check;' \
  'SELECT count(*) AS users FROM users;' \
  'SELECT count(*) AS ciphers FROM ciphers;'
du -sh "$DEST/vw"
echo "== $(date -Is) done"
