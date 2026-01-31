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
    #    <sops-nix/modules/sops>
  ];

  environment.systemPackages = with pkgs; [
    # openjdk17_headless
    wakeonlan
    amdgpu_top
    bambu-studio
    orca-slicer
    google-chrome
    nixpkgs-unstable.lmstudio
    ghostty
  ];

  # Disable UAS for ASMedia 2115 USB-SATA bridge to fix I/O errors
  # Forces the device to use standard USB Mass Storage instead
  # Applies to all drives in the DAS enclosure (174c:55aa)
  boot.kernelParams = [ "usb-storage.quirks=174c:55aa:u" ];

  # Set hostname
  networking.hostName = "aegis";
  networking.firewall.enable = false;
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];
    externalInterface = "eth0";
    enableIPv6 = true;
  };
  networking.firewall.trustedInterfaces = [ "br+" ];
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

  # sops-nix secrets configuration
  sops.age.keyFile = "/home/luckierdodge/.config/sops/age/keys.txt";
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
      "/home/luckierdodge/aegis-backups"
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
  };
}
