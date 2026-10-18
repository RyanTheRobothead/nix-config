# Recovery kit

The recovery kit is the way back in if Aegis, Vaultwarden and every logged-in device
are lost at once. `recovery-kit.age` is a short text file of the root secrets,
age-encrypted to the three offline admin recipients in `.sops.yaml`: YubiKeys 37817094
and 37817095, and the paper identity. Any one of them decrypts it, so the file can be
copied widely.

The kit is never committed: this repo is public.

## What's in it

The template is `recovery-kit.template`; the build script fills in the restic part.

| Secret | Why it's a root |
| --- | --- |
| Primary email password and recovery codes | Password resets for every other account go through it |
| B2 login, 2FA recovery codes, master application key | Gates every backup |
| Restic break-glass password (`admin@recovery-kit` key) | Decrypts the backups, independent of the hosts' key |
| Vaultwarden URL, master password, 2FA recovery code, admin panel password | Opens everything else once restored |
| GitHub, Linode and registrar logins and recovery codes | Needed to rebuild the VPS, DNS and the repo mirror |

Not in it: the sops paper identity (it lives on paper, and the kit is encrypted to it),
host B2 keys, SSH host keys and service credentials. Those are rebuilt from the flake or
restored from B2 once the roots are back.

Keep TOTP seeds for these accounts out of Vaultwarden and out of the kit. Use the
YubiKeys as the second factor where the service allows it, and keep its recovery codes in
the kit.

## Copies

| Copy | Where |
| --- | --- |
| USB stick 1 | Home safe |
| USB stick 2 | With Nolan, offsite |
| B2 | Its own bucket, outside the restic repository |

Each copy is a `recovery-kit/` directory holding `recovery-kit.age`, `README.txt` (from
`recovery-kit-README.txt`: how to decrypt it and the recovery order, no secrets) and
`SHA256SUMS`.

## Building it

Have Vaultwarden open, YubiKey 37817094 plugged in, and its PIN to hand. Run this in your
own terminal, since it prompts for sudo, the PIN and a touch:

```bash
bash docs/runbooks/recovery-kit.sh build
```

The script:

1. Adds a new restic key to `b2:ryan-the-robothead-aegis-backup` (host `recovery-kit`,
   user `admin`) with a random password. It then checks that this password alone opens
   the repo.
2. Writes the template, with that password filled in, under `$XDG_RUNTIME_DIR` (tmpfs).
   It opens the file in `$EDITOR` with swap, undo and backup files turned off.
3. Refuses to continue while any `FILL-ME` is left.
4. Encrypts the file to the three admin recipients and decrypts it again with YubiKey
   37817094 to check the round trip. The plaintext is shredded on exit.
5. Leaves `recovery-kit.age`, `README.txt` and `SHA256SUMS` in `~/recovery-kit/`.

Your clipboard manager may keep what you paste from Vaultwarden. Clear its history
afterwards.

Then copy the kit to each stick. Mount the stick (exFAT is fine) and run:

```bash
bash docs/runbooks/recovery-kit.sh install /run/media/$USER/<label>
```

The script drops the page cache and checks the copy on the stick against `SHA256SUMS`.

## Regenerating

Rebuild the kit whenever a root secret in it changes: a new B2 master key, new recovery
codes, a moved registrar. Start from the current kit so the break-glass password carries
over:

```bash
bash docs/runbooks/recovery-kit.sh build --from ~/recovery-kit/recovery-kit.age
```

Then replace every copy. To rotate the break-glass password itself, build without `--from`
(this adds a new key), replace every copy, then remove the old key:
`sudo restic-backblaze key list` and `sudo restic-backblaze key remove <id>`.

## Testing it

Once a year, and after each rebuild, decrypt one copy with each of the three identities:
the carried YubiKey, the safe YubiKey and the paper identity. Use the steps in
`recovery-kit-README.txt`, and log the result below.

## Printed sheet

Print one page per offsite copy and fill in the identity by hand. Never type it into a
file.

```
RECOVERY SHEET: Ryan's homelab

Paper age identity (sops admin, also decrypts the recovery kit):
AGE-SECRET-KEY-1 ________________________________________________

Recovery kit copies: USB in the home safe; USB with Nolan;
Backblaze B2 bucket ______________________.
Instructions: README.txt next to recovery-kit.age on any copy.

Order: email → B2 → restic restore → Vaultwarden → clone nix-config and rebuild.
Repo: https://github.com/RyanTheRobothead/nix-config (docs/runbooks/)
```

## Log

| Date | Event | sha256 of recovery-kit.age | Verified with |
| --- | --- | --- | --- |
| 2026-10-18 | First build; restic break-glass key `6766c700` | `5b590fbc038a4759dcc1d5b5f559b7314f3d522473ded9431212b730ff446764` | YubiKey 37817094 (round trip in the build) |
