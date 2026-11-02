# Base for headless NixOS hosts. Aegis is a desktop and keeps its own
# nixos/configuration.nix; this lifts the parts of it that every host needs.
{
  inputs,
  lib,
  config,
  pkgs,
  ...
}:
{
  # Flake inputs as registries and channels, so nix3 and legacy commands
  # agree with the flake
  nix.registry = (lib.mapAttrs (_: flake: { inherit flake; })) (
    (lib.filterAttrs (_: lib.isType "flake")) inputs
  );
  nix.nixPath = [ "/etc/nix/path" ];
  environment.etc = lib.mapAttrs' (name: value: {
    name = "nix/path/${name}";
    value.source = value.flake;
  }) config.nix.registry;

  nix.settings = {
    experimental-features = "nix-command flakes";
    # nixos-rebuild --target-host copies unsigned paths as the SSH user
    trusted-users = [ "@wheel" ];
  };
  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  # Automatic updates: nightly switch to whatever is on GitHub's main.
  # A bridge until comin takes over; flake inputs only move when flake.lock is
  # pushed. Unlike Aegis, servers reboot themselves for kernel updates.
  system.autoUpgrade = {
    enable = true;
    flake = "github:RyanTheRobothead/nix-config";
    dates = "03:40";
    allowReboot = true;
    rebootWindow = {
      lower = "03:30";
      upper = "05:00";
    };
  };

  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    dnsutils
  ];

  environment.shells = with pkgs; [ zsh ];
  programs.zsh.enable = true;

  # Tailscale until the Headscale cutover. authKeyFile joins the tailnet on
  # first boot, since SSH is only open on the mesh.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets.tailscale_authkey.path;
  };
  networking.firewall.checkReversePath = "loose";

  # The host's SSH key is its age identity, placed by nixos-anywhere
  # --extra-files before first boot
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.age.keyFile = null;
  sops.gnupg.sshKeyPaths = [ ];

  users.users.luckierdodge = {
    isNormalUser = true;
    description = "Ryan D. Lewis";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    # Used for sudo and for logging in on the Lish console
    hashedPasswordFile = config.sops.secrets.luckierdodge_password_hash.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFA2LMlWKHE6wMXqoWENyBdtnIwPx5krhMsbDq8CX+CA cargocult (Termius)"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIv9qQs3Xrlxg3UnN8mflkM8m2z+B4dnR7ys0843aJlO pixel-10-pro-fold"
      # Emergency access; private key is stored in Vaultwarden
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN/A3L/EO1VBlLCnnO00tY42jviieS0lDN2DlpmOEBES emergency@ryandlewis.dev"
    ];
  };

  environment.sessionVariables.EDITOR = "vim";
  # nixpkgs' certifi ships plain pkgs.cacert, not the bundle security.pki
  # filters (eMudhra, CVE-2026-111943), and reads this variable instead
  environment.sessionVariables.NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
  systemd.globalEnvironment.NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
}
