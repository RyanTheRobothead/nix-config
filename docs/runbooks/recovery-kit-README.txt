RECOVERY KIT

recovery-kit.age holds the root secrets for Ryan's homelab: email and Backblaze B2
recovery, the restic break-glass password, the Vaultwarden master password, and the
GitHub, Linode and registrar logins. It is encrypted with age and is useless without
one of these:

  - YubiKey serial 37817094 (carried) or 37817095 (home safe), plus its PIN
  - the paper age identity in the home safe (a line starting AGE-SECRET-KEY-1)

If you are not Ryan and are holding this for him, keep it somewhere dry and give it
back when asked. Nothing else needs doing.

1. Get the tools
   On any machine with Nix:   nix shell nixpkgs#age nixpkgs#age-plugin-yubikey
   Otherwise:                 https://github.com/FiloSottile/age/releases
                              https://github.com/str4d/age-plugin-yubikey/releases
   Linux also needs pcscd running for the YubiKey.

2. Check the file
   sha256sum -c SHA256SUMS

3. Decrypt
   With a YubiKey:
     age-plugin-yubikey --identity > yubikey-id.txt
     age -d -i yubikey-id.txt recovery-kit.age > recovery-kit.txt
     (enter the PIN, touch the key when it blinks)
   With the paper identity:
     type the AGE-SECRET-KEY-1... line into paper-id.txt
     age -d -i paper-id.txt recovery-kit.age > recovery-kit.txt
   Work on a tmpfs or an encrypted disk, and delete recovery-kit.txt and
   paper-id.txt when done.

4. Recover, in this order
   a. Email, using its recovery codes.
   b. Backblaze B2, using its login and recovery codes.
   c. Restic: restore Aegis's data with the B2 master key and the break-glass
      password (both in the kit; the exact command is in the kit).
   d. Vaultwarden: extract it from the newest volume tarball and start it in a
      temporary container. Steps: docs/runbooks/restore.md in the repo below.
   e. Clone https://github.com/RyanTheRobothead/nix-config, decrypt its sops
      secrets with the YubiKey or paper identity, and rebuild the hosts.

Copies of this kit: a USB stick at home, a USB stick with Nolan, and a B2 bucket
separate from the backups.
