# Rebuild a host from scratch

SleeperService (Linode) installs with nixos-anywhere, from Aegis or any machine
with a YubiKey. The same steps rebuild it after a loss.

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
bootloader, so it only boots in Linode's "GRUB 2" kernel mode. Install from it
as created, and switch the boot settings only after disko has written NixOS's
own GRUB.

1. Create the Linode in Cerberus's region from the stock Debian image, 2 CPU /
   4 GB, with a root password and an SSH key for root. Leave the config
   profile's defaults: kernel "GRUB 2", boot helpers on.
2. Optional, while it is powered off: delete the 512 MB swap disk and grow the
   main disk to the full plan. disko only partitions `/dev/sda`; the host uses a
   swapfile. Boot it again and check `ssh root@<ip>` works.

## Install

```bash
just provision sleeperservice <public IPv4> --no-reboot
```

This decrypts the host key into a temporary `--extra-files` tree (YubiKey
touch), runs nixos-anywhere, which kexecs into an installer, partitions the disk
and installs, and deletes the tree. `--no-reboot` leaves the installer running
so the boot settings can change first:

1. Shut the Linode down from Cloud Manager.
2. In the config profile, set the kernel to **Direct Disk**, which boots the
   disk's own GRUB (BIOS boot partition, `hosts/sleeperservice/disko.nix`).
   Turn off the Filesystem/Boot Helpers too, including Auto-configure
   networking: NixOS declares its own network config.
3. Boot it, watching Lish (Weblish or `ssh -t <user>@lish-<region>.linode.com`).

If the tailnet join fails, log in on Lish as luckierdodge. The password and the
auth key come from the same sops file, so if decryption failed neither works;
then boot Linode's Rescue Mode (Finnix) and mount `/dev/sda2` to inspect the
install.

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
