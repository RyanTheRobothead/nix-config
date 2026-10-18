# This is your system's configuration file.
# Use this to configure your system environment (it replaces /etc/nixos/configuration.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
  nixpkgs-unstable,
  ...
}:
{
  # You can import other NixOS modules here
  imports = [
    # If you want to use modules your own flake exports (from modules/nixos):
    # outputs.nixosModules.example

    # Or modules from other flakes (such as nixos-hardware):
    # inputs.hardware.nixosModules.common-cpu-amd
    # inputs.hardware.nixosModules.common-ssd

    # You can also split up your configuration and import pieces of it here:
    # ./users.nix

    # Import your generated (nixos-generate-config) hardware configuration
    ./hardware-configuration-aegis.nix
    ./configuration.nix
    # aegis is the only host with an optical drive
    ../modules/nixos/audiobook-ripper.nix
    ../modules/nixos/renovate.nix
    #    <sops-nix/modules/sops>
  ];

  environment.systemPackages = with pkgs; [
    # openjdk17_headless
    wakeonlan
    amdgpu_top
    bambu-studio
    orca-slicer
    nanum
    google-chrome
    nixpkgs-unstable.lmstudio
    ghostty
    godot
    # Secrets admin: edit sops files, decrypting with the YubiKeys
    sops
    age-plugin-yubikey
    yubikey-manager
  ];

  # age-plugin-yubikey reaches the YubiKeys through pcscd
  services.pcscd.enable = true;

  # Disable UAS for ASMedia 2115 USB-SATA bridge to fix I/O errors
  # Forces the device to use standard USB Mass Storage instead
  # Applies to all drives in the DAS enclosure (174c:55aa)
  boot.kernelParams = [ "usb-storage.quirks=174c:55aa:u" ];

  # Default the power profile to performance on every boot.
  # power-profiles-daemon does persist its last profile in /var/lib, but this
  # makes the default declarative and survives that state being wiped.
  # Ordered against graphical.target rather than multi-user.target, because
  # power-profiles-daemon is itself After=multi-user.target.
  systemd.services.power-profile-performance = {
    description = "Set power-profiles-daemon to the performance profile";
    wantedBy = [ "graphical.target" ];
    requires = [ "power-profiles-daemon.service" ];
    after = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance";
    };
  };

  # The *arr stack shares gluetun's network namespace (network_mode:
  # service:gluetun). When gluetun restarts (autoheal does this when the VPN
  # fails its healthcheck) the dependents keep running in the dead namespace
  # with no network. Restarting them rejoins gluetun's current namespace, so
  # do that whenever gluetun starts, and once at startup to catch any missed.
  systemd.services.gluetun-dependents = {
    description = "Restart containers stranded by a gluetun restart";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    path = [ config.virtualisation.docker.package ];
    script = ''
      heal() {
        gid=$(docker inspect -f '{{.Id}}' gluetun 2>/dev/null) || return 0
        gpid=$(docker inspect -f '{{.State.Pid}}' gluetun)
        [ "$gpid" -gt 0 ] || return 0
        gns=$(readlink "/proc/$gpid/ns/net")
        docker ps -q | xargs -r docker inspect \
          -f '{{.Name}} {{.HostConfig.NetworkMode}} {{.State.Pid}}' |
          while read -r name mode pid; do
            [ "$mode" = "container:$gid" ] || continue
            [ "$(readlink "/proc/$pid/ns/net")" = "$gns" ] && continue
            echo "restarting ''${name#/} into gluetun's namespace"
            docker restart "''${name#/}" || true
          done
      }
      heal
      docker events --filter type=container --filter container=gluetun \
        --filter event=start --format '{{.Action}}' |
        while read -r _; do heal; done
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
  };

  # Set hostname
  networking.hostName = "aegis";
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];
    externalInterface = "enp191s0";
    enableIPv6 = true;
  };
  # The firewall only sees host listeners: Docker's published ports bypass it,
  # so those are scoped by their bind address in the compose files instead.
  # The tailnet and Docker bridges are trusted; the LAN gets SSH (opened by
  # openssh), Steam and Avahi (opened by their modules), and the ports below.
  networking.firewall.enable = true;
  networking.firewall.trustedInterfaces = [
    "tailscale0"
    "br+"
  ];
  networking.firewall.allowedTCPPorts = [
    8096 # Jellyfin (host networking)
    32400 # Plex (host networking)
  ];
  networking.firewall.allowedUDPPorts = [
    1900 # DLNA/SSDP discovery, Plex and Jellyfin
    7359 # Jellyfin client discovery
    32410 # Plex GDM discovery
    32412
    32413
    32414
  ];
  # Direct WireGuard connections instead of falling back to DERP relays
  services.tailscale.openFirewall = true;
  # Lets Docker bind admin UIs to the Tailscale address before tailscaled has
  # brought it up at boot
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
  boot.kernel.sysctl."net.ipv6.ip_nonlocal_bind" = 1;
  networking.firewall = {
    extraCommands = "
      iptables -I nixos-fw 1 -i br+ -j ACCEPT
    ";
    extraStopCommands = "
      iptables -D nixos-fw -i br+ -j ACCEPT
    ";
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "25.05";

  fileSystems."/mnt/aegis-storage" = {
    device = "/dev/disk/by-label/aegis-storage";
    fsType = "btrfs";
    options = [
      "compress=zstd" # Compression saves space on media files that aren't already compressed
      "autodefrag" # Helps with fragmentation over time
      "noatime" # Reduces unnecessary writes
    ];
  };
  fileSystems."/mnt/aegis-backup" = {
    device = "/dev/disk/by-label/aegis-backup";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "autodefrag"
      "noatime"
    ];
  };
  fileSystems."/mnt/jaina-disk-2" = {
    device = "/dev/disk/by-label/JainaDisk2";
    fsType = "ntfs-3g";
    options = [
      "r"
      "uid=1000"
    ];
  };

  # Enable Btrfs scrubbing (data integrity checks)
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [
      "/mnt/aegis-storage"
      "/mnt/aegis-backup"
    ];
    interval = "weekly";
    limit = "50M";
  };

  # Rip CD audiobooks straight into the Audiobookshelf library. See `ripbook --help`.
  services.audiobookRipper = {
    enable = true;
    user = "luckierdodge";
    # Matches the MEDIA_DIR/audiobooks bind mount in dockerfiles/aegis/compose.media.yaml
    libraryPath = "/mnt/aegis-storage/media-storage/audiobooks";
    # Keep the multi-gigabyte intermediate WAVs off the root filesystem
    workDir = "/mnt/aegis-storage/ripbook-work";
    contact = "ryandlewis.rl@gmail.com";
  };

  # sops-nix secrets configuration
  # Root-only host key; admins decrypt with the YubiKeys or the paper key instead
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.age.generateKey = false;

  sops.secrets.restic_b2_account_id = {
    format = "yaml";
    sopsFile = ../secrets/restic.yaml;
  };
  sops.secrets.restic_b2_account_key = {
    format = "yaml";
    sopsFile = ../secrets/restic.yaml;
  };
  sops.secrets.restic_password = {
    format = "yaml";
    sopsFile = ../secrets/restic.yaml;
  };

  # Template to combine B2 credentials into env file for restic
  sops.templates."restic-env" = {
    content = ''
      B2_ACCOUNT_ID=${config.sops.placeholder.restic_b2_account_id}
      B2_ACCOUNT_KEY=${config.sops.placeholder.restic_b2_account_key}
    '';
  };

  # Restic backup to Backblaze B2
  services.restic.backups.backblaze = {
    initialize = true;
    repository = "b2:ryan-the-robothead-aegis-backup";
    paths = [
      # The real mount, not the ~/aegis-backup symlink: restic stores a
      # symlink given as a path as the link itself, without its contents
      "/mnt/aegis-backup"
      "/home/luckierdodge/repos"
    ];

    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.templates."restic-env".path;

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true; # Run if missed while system was off
      RandomizedDelaySec = "1h"; # Spread load
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--keep-yearly 2"
    ];

    # Structural check after every backup; uses the local cache, so it's cheap
    checkOpts = [ "--with-cache" ];
  };

  # Fail the backup if the disk isn't mounted, rather than snapshotting an
  # empty mountpoint
  systemd.services.restic-backups-backblaze.unitConfig.RequiresMountsFor = [ "/mnt/aegis-backup" ];

  # Weekly check that downloads and verifies a random 5% of pack data, so
  # the whole repository gets read over time. Reuses the backup unit's
  # environment and credentials; --retry-lock waits out a running backup.
  systemd.services.restic-check-backblaze = {
    description = "Verify a sample of restic backup data on Backblaze B2";
    environment = removeAttrs config.systemd.services.restic-backups-backblaze.environment [ "PATH" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe config.services.restic.backups.backblaze.package} check --read-data-subset=5% --retry-lock 2h";
      EnvironmentFile = config.sops.templates."restic-env".path;
      CacheDirectory = "restic-backups-backblaze";
      CacheDirectoryMode = "0700";
      PrivateTmp = true;
    };
  };
  systemd.timers.restic-check-backblaze = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
