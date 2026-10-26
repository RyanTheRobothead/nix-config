# Passwordless sudo for a short list of read-only diagnostics, so an agent
# (which runs as luckierdodge) can check disks, sockets and backups without the
# copy-paste-into-another-terminal dance.
#
# The agent can run anything here without asking: Claude Code's ask rule on
# sudo is a prompt in front, not a boundary (a script the agent writes can call
# sudo too). So every entry must be safe to run unsupervised:
# - Read-only, and never able to start a shell, pager or editor.
# - Exact arguments. sudoers matches an entry with arguments only against
#   exactly those arguments; a wildcard would also match spaces, letting the
#   agent append flags, so there are none here.
# - Nothing that takes a flake, path or config to act on (nixos-rebuild,
#   systemctl edit, mount, tee): those are root by another name.
# Anything else, including every change to the system, still needs a password.
{
  lib,
  ...
}:
let
  bin = "/run/current-system/sw/bin";
  btrfsMounts = [
    "/mnt/aegis-storage"
    "/mnt/aegis-backup"
  ];
  readOnlyCommands = [
    "${bin}/btrfs filesystem show"
    "${bin}/fdisk -l"
    "${bin}/ss -tulpn"
    "${bin}/restic-backblaze snapshots"
  ]
  ++ lib.concatMap (mount: [
    "${bin}/btrfs scrub status ${mount}"
    "${bin}/btrfs filesystem usage ${mount}"
    "${bin}/btrfs device stats ${mount}"
  ]) btrfsMounts;
in
{
  security.sudo.extraRules = [
    {
      users = [ "luckierdodge" ];
      runAs = "root";
      commands = map (command: {
        inherit command;
        options = [ "NOPASSWD" ];
      }) readOnlyCommands;
    }
  ];

  # Never reuse a cached ticket: an agent running as luckierdodge could otherwise
  # ride one left by a sudo typed in any of the user's terminals. Revert once
  # agents are sandboxed away from the user's ptys and zellij sessions.
  security.sudo.extraConfig = ''
    Defaults:luckierdodge timestamp_timeout=0
  '';
}
