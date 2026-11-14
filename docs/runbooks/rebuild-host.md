# Rebuild a host from scratch

SleeperService (Linode) installs with nixos-anywhere, driven through the Linode
API by `just provision`, from Aegis's desktop session. The same command
rebuilds it after a loss.

## What the host needs from sops

- `secrets/sleeperservice/ssh_host_ed25519_key.json`: the SSH host key, which is
  also the host's age identity. Encrypted to the admin keys only. Its public half
  is `ssh_host_ed25519_key.pub` beside it, and its age recipient is
  `server_sleeperservice` in `.sops.yaml`.
- `secrets/sleeperservice/host.yaml`:
  - `tailscale_authkey`: a reusable or one-off Tailscale auth key, pre-approved,
    so the host joins the tailnet on first boot. SSH is only open on the mesh.
  - `luckierdodge_password_hash`: a yescrypt hash (`mkpasswd -m yescrypt`), for
    sudo and for logging in on the Lish console.
- `secrets/sleeperservice/headscale.yaml`: Headscale's Noise and DERP private
  keys (`headscale generate private-key`). Keeping them means a rebuilt server
  is the same control server to its clients.

An expired auth key only matters at install: once joined, the node stays joined.
Mint a new one before a rebuild and `sops set` it into `host.yaml`.

## Linode

The stock Debian image is a bare ext4 filesystem with no partition table or
bootloader, so it only boots in Linode's "GRUB 2" kernel mode. NixOS installs
from it, and the boot settings switch to "Direct Disk" only after disko has
written NixOS's own GRUB (BIOS boot partition, `modules/profiles/linode-disko.nix`).
`just provision` does all of it through the Linode API:

```bash
just provision sleeperservice           # wipe and reinstall the existing Linode
just provision sleeperservice --create  # the Linode is gone: make a new one
```

The Linode's label, region, plan and image come from `hosts/<host>/linode.json`.
The API token is in `secrets/linode.yaml` (`linode_token`, admin keys only), so
run it from a desktop session on Aegis: it and the host key each want a YubiKey
touch. The script:

1. Rebuilds the Linode from the image, after showing it and asking for its
   label (`--yes` skips that). The ID and both addresses stay, so DNS and
   Headscale's DERP addresses need no change. `--create` makes a new Linode
   with no swap disk instead, and refuses if the label is taken. A rebuild
   keeps Linode's 512 MB swap disk as `/dev/sdb`, which disko leaves alone.
2. Waits until Debian answers SSH as root, with a one-time random root password
   and `~/.ssh/id_ed25519.pub`.
3. Runs `just install <host> <ip> --no-reboot`. This decrypts the host key into a
   temporary `--extra-files` tree and runs nixos-anywhere, which kexecs into an
   installer, partitions the disk and installs.
4. Shuts the Linode down, sets the config profile's kernel to Direct Disk with
   every boot helper off (NixOS declares its own network and filesystems), and
   boots it.
5. Waits for the new system: for SleeperService, a tailnet node of its name
   created since the boot, with a matching uptime; for NervousEnergy, root SSH
   on the public address.

On `--create` it prints the new addresses: put them in `dns/dnsconfig.js` and
the DERP `ipv4`/`ipv6` in `modules/infra/headscale.nix`. If the old tailnet
node still exists, the new one joins as `sleeperservice-1`; the script says so.
Remove the old node, then rename the new one.

To rehearse, use NervousEnergy (`hosts/nervousenergy/`): the same Linode
profile with no secrets, tailnet or services, on a 2 GB plan billed hourly.
`just provision nervousenergy --create`, then `just provision nervousenergy`
to rebuild it, then `just deprovision nervousenergy` to delete it. Deleting
asks for the label too, and the addresses go back to Linode for good, so never
deprovision SleeperService to rebuild it: `just provision` keeps them.

Run these from a terminal, not Claude Code's `!`: the YubiKey PIN prompt and
the label confirmation need a TTY.

If the boot fails, watch Lish (Weblish or
`ssh -t <user>@lish-<region>.linode.com`) and log in as luckierdodge. The
password and the auth key come from the same sops file, so if decryption failed
neither works; then boot Linode's Rescue Mode (Finnix) and mount `/dev/sda2` to
inspect the install. Without the API, the same steps work by hand in Cloud
Manager around `just install <host> <ip> --no-reboot`.

After first boot, from a tailnet machine:

```bash
ssh sleeperservice
tailscale status        # on the host: joined, with the expected tags
just deploy sleeperservice
```

`just deploy` builds locally and switches over SSH. Day to day, the host also
follows `main` through `system.autoUpgrade` (03:40, rebooting between 03:30 and
05:00 when a kernel changes) until comin replaces it.

## Deploys from Aegis

`just deploy` copies paths as luckierdodge, who is not a trusted Nix user on the
servers: trusting the SSH user would make it root-equivalent without the sudo
password, and agents on Aegis can use the same SSH key. Instead Aegis's daemon
signs every path it builds with `/var/lib/nix-signing/aegis-1.sec` (root-only),
and the servers trust its public half (`modules/profiles/server.nix`).

Making the key (once, or after losing Aegis):

```bash
sudo install -d -m 700 /var/lib/nix-signing
sudo sh -c 'umask 077; nix key generate-secret --key-name aegis-1 > /var/lib/nix-signing/aegis-1.sec'
sudo sh -c 'nix key convert-secret-to-public < /var/lib/nix-signing/aegis-1.sec'
```

Put the public key in `extra-trusted-public-keys`, then `just switch aegis`.
Paths built before the key existed are unsigned; sign a host's closure once:

```bash
sudo nix store sign -r --key-file /var/lib/nix-signing/aegis-1.sec \
  "$(nix build --no-link --print-out-paths .#nixosConfigurations.sleeperservice.config.system.build.toplevel)"
```

## After a rebuild

The host key is the same, so nothing in sops needs re-encrypting and SSH clients
see the same host key. Remove the old node from the tailnet admin console if it
still appears.

Headscale comes back with its keys and its users (`headscale-users` creates
them), but its nodes and pre-auth keys are in `/var/lib/headscale/db.sqlite`.
Until that database is in a restic set, a rebuild means re-registering every
Headscale device: `sudo headscale preauthkeys create --user <id>` on the host
(`headscale users list` shows the ID), then
`tailscale up --login-server https://hs.ryandlewis.dev --auth-key <key>` on the
device.

A rebuild onto a new Linode gets new public addresses. Change them in both
`dns/dnsconfig.js` and the DERP `ipv4`/`ipv6` in `modules/infra/headscale.nix`.
