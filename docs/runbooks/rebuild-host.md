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

An expired auth key only matters at install: once joined, the node stays joined.
Mint a new one before a rebuild and `sops set` it into `host.yaml`.

## Linode

1. Create the Linode in Cerberus's region from the stock Debian image, 2 CPU /
   4 GB, with a root password and an SSH key for root.
2. In the config profile, set the kernel to **Direct Disk**. The disk has its own
   GRUB (BIOS boot partition, `hosts/sleeperservice/disko.nix`); Linode's
   "GRUB 2" mode would read `/boot/grub/grub.cfg` with its own GRUB instead.
3. Delete the 512 MB swap disk and grow the main disk to the full plan. disko
   only partitions `/dev/sda`; the host uses a swapfile.

## Install

```bash
just provision sleeperservice <public IPv4>
```

This decrypts the host key into a temporary `--extra-files` tree (YubiKey
touch), runs nixos-anywhere, which kexecs into an installer, partitions the disk
and installs, and deletes the tree. Keep Lish open: if the tailnet join fails,
log in there as luckierdodge.

After first boot, from a tailnet machine:

```bash
ssh sleeperservice
tailscale status        # on the host: joined, with the expected tags
just deploy sleeperservice
```

`just deploy` builds locally and switches over SSH. Day to day, the host also
follows `main` through `system.autoUpgrade` (03:40, rebooting between 03:30 and
05:00 when a kernel changes) until comin replaces it.

## After a rebuild

The host key is the same, so nothing in sops needs re-encrypting and SSH clients
see the same host key. Remove the old node from the tailnet admin console if it
still appears.
