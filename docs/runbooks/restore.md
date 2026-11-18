# Restoring from backup

Aegis backs up to Backblaze B2 with restic (`services.restic.backups.backblaze` in
`nixos/aegis.nix`). Last tested 2026-10-17: Vaultwarden restored from B2 intact.

## What is backed up

| Data | Where it lives | How it reaches B2 |
| --- | --- | --- |
| Docker volumes (Vaultwarden, Paperless, Immich, ...) | `~/aegis-data/<service>/` | `offen/docker-volume-backup` container writes one weekly gzip tarball (Sat 03:30) to `/mnt/aegis-backup/volumes/`; restic uploads it nightly |
| Repos | `~/repos` | restic, nightly |

Schedule: nightly backup with `forget --prune` (7 daily, 4 weekly, 6 monthly,
2 yearly) and `check --with-cache`; weekly `restic check --read-data-subset=5%`
(`restic-check-backblaze.timer`, Sun 04:00).

The volume tarball is about 145 GB and gzip can't seek, so restoring any single
service streams the whole tarball from B2. At home bandwidth that took about
90 minutes.

## Commands

Run as root. `restic-backblaze` is a wrapper that already has the repo, password
and B2 credentials set.

```bash
sudo restic-backblaze snapshots
sudo restic-backblaze ls latest /mnt/aegis-backup/volumes   # list volume tarballs

# One file or directory from ~/repos
sudo restic-backblaze restore latest --target /var/tmp/restore \
  --include /home/luckierdodge/repos/nix-config

# One service from the volume tarball, streamed without writing the tarball to disk
TARBALL=/mnt/aegis-backup/volumes/backup-YYYY-MM-DDT03-30-00.tar.gz
sudo restic-backblaze dump latest "$TARBALL" \
  | sudo tar -xz -C /var/tmp/restore --wildcards '*vaultwarden/data/*'
```

Inside the tarball, services sit under `backup/data_dir/<service>/`, mirroring
`~/aegis-data/<service>/`.

If the backup disk is healthy, skip B2: the same tarballs are in
`/mnt/aegis-backup/volumes/` and extract the same way with `tar -xzf`.

## Putting a service back

1. Stop the service's containers (`docker compose stop` in its stack).
2. Move the current data aside: `mv ~/aegis-data/<service> ~/aegis-data/<service>.old`.
3. Copy the restored directory into place, preserving ownership (`cp -a`).
4. Start the containers and check the app. Delete the `.old` copy after a week.

For Vaultwarden, check the database before starting:
`sqlite3 db.sqlite3 'PRAGMA integrity_check;'` should print `ok`.

## Restore test

`docs/runbooks/restore-test.sh` restores one file from `~/repos` and compares it
with the live copy. It then streams the newest volume tarball, extracts Vaultwarden
and checks its database. Run it in tmux; output goes to
`/var/tmp/restore-test/restore-test.log`.

```bash
sudo bash docs/runbooks/restore-test.sh
```

| Date | Snapshot | Result |
| --- | --- | --- |
| 2026-10-17 | `1014ab16` | Pass. `flake.nix` matched. Vaultwarden from the 2026-10-10 tarball: integrity `ok`, 2 users and 462 items, same as live. Streaming took 87 minutes. |
| 2026-10-16 | `9eb2080b` | Fail: no volume data in B2. Since 2026-01-31 restic had been given the `~/aegis-backup` symlink, which it stores as a link without its contents. Fixed in `aa8d644`. |

## SleeperService

SleeperService has its own repository, `b2:ryan-the-robothead-sleeperservice-backup`
(`modules/infra/backup.nix`), with the same schedule, checks and wrapper name,
so `sudo restic-backblaze ...` works there too. Its password is in
`secrets/sleeperservice/restic.yaml`, which either YubiKey or the paper identity
decrypts; the recovery kit's break-glass key covers Aegis's repository only.

| Data | Where it lives | In the snapshot |
| --- | --- | --- |
| Headscale nodes and pre-auth keys | `/var/lib/headscale/db.sqlite` | `/var/lib/backup-staging/headscale.sqlite`, copied with `sqlite3 .backup` before each run |
| Gatus history | `/var/lib/private/gatus/data.db` | `/var/lib/backup-staging/gatus.sqlite`, the same way |
| ACME account and certificates | `/var/lib/acme` | as is |

Headscale's keys and users, ntfy's users and tokens, and everything else come
from the flake and sops. A failed backup or check posts to ntfy's `alerts` topic.

To put Headscale's database back, on the host:

```bash
sudo restic-backblaze restore latest --target /var/tmp/restore \
  --include /var/lib/backup-staging/headscale.sqlite
sudo sqlite3 /var/tmp/restore/var/lib/backup-staging/headscale.sqlite 'PRAGMA integrity_check'
sudo systemctl stop headscale
sudo rm -f /var/lib/headscale/db.sqlite-wal /var/lib/headscale/db.sqlite-shm
sudo install -o headscale -g headscale -m 640 \
  /var/tmp/restore/var/lib/backup-staging/headscale.sqlite /var/lib/headscale/db.sqlite
sudo systemctl start headscale
sudo headscale nodes list
```

Gatus's database goes back the same way, with Gatus stopped; its history is
the only thing lost without it. Gatus is a DynamicUser, so there's no fixed
owner to install as: give the file its directory's owner. systemd only fixes
ownership under `/var/lib/private/gatus` when the directory itself is wrong,
so a root-owned `data.db` stays root's and Gatus panics with "unable to open
database file (14)".

```bash
sudo restic-backblaze restore <snapshot> --target /var/tmp/restore \
  --include /var/lib/backup-staging/gatus.sqlite
sudo sqlite3 /var/tmp/restore/var/lib/backup-staging/gatus.sqlite 'PRAGMA integrity_check'
sudo systemctl stop gatus
sudo rm -f /var/lib/private/gatus/data.db-wal /var/lib/private/gatus/data.db-shm
sudo install -m 600 /var/tmp/restore/var/lib/backup-staging/gatus.sqlite /var/lib/private/gatus/data.db
sudo chown --reference=/var/lib/private/gatus /var/lib/private/gatus/data.db
sudo systemctl start gatus
```

After a rebuild, the newest snapshot holds the fresh, empty databases: restore
the last one from before it by ID (`restic-backblaze snapshots`), not `latest`.

| Date | Snapshot | Result |
| --- | --- | --- |
| 2026-11-17 | `c1c512f6` | Pass. First snapshot, restored in full to `/var/tmp`. Both databases `ok`; Headscale has 1 node (same as live) and user `luckierdodge`, Gatus 4,248 results; `/var/lib/acme` identical to live. |
| 2026-11-17 | `c1c512f6` | Pass, into production. Gatus's history put back on the rebuilt host: back to 17:35 CST, losing 19:13 to 21:18. The first try left `data.db` owned by root and Gatus panicked ("unable to open database file (14)") until it was given its directory's owner; the steps above now do that. |

## Gotchas

- Give restic real paths, never symlinks: it stores a symlink passed as a backup
  path as the link itself. The backup unit also has `RequiresMountsFor` on
  `/mnt/aegis-backup`, so an unmounted disk fails the job instead of silently
  backing up an empty directory.
- `forget` groups snapshots by host and paths, so changing `paths` starts a new
  group and the old group's snapshots are never pruned. Clean those up by ID with
  `restic forget` and then `restic prune`, but only after the new group has a
  verified restore.
- The January 2026 snapshots under `~/aegis-storage/aegis-backups` were the only
  off-site volume data until 2026-10-16. They can be forgotten now that
  `2d98382a` and later are verified.
