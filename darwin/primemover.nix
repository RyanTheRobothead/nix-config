# This is your system's configuration file.
# Use this to configure your system environment (it replaces /etc/nixos/configuration.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
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
    #inputs.home-manager.nixosModules.home-manager
    #    <sops-nix/modules/sops>
  ];

  # nix.package = pkgs.nix;

  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      #outputs.overlays.additions
      #outputs.overlays.modifications
      #outputs.overlays.unstable-packages

      # You can also add overlays exported from other flakes:
      # neovim-nightly-overlay.overlays.default

      # Or define it inline, for example:
      # (final: prev: {
      #   hi = final.hello.overrideAttrs (oldAttrs: {
      #     patches = [ ./change-hello-to-hi.patch ];
      #   });
      # })
    ];
    # Configure your nixpkgs instance
    config = {
      # Disable if you don't want unfree packages
      allowUnfree = true;
    };
  };

  nix.settings = {
    # Enable flakes and new 'nix' command
    experimental-features = "nix-command flakes";
  };
  nix.optimise.automatic = true;

  environment.systemPackages = with pkgs; [
    vim-full # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    git
    # openjdk17_headless
    tailscale
    zsh
    inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.default
    age
    python3
    graphviz
    libusb1
    pgadmin4-desktopmode
  ];

  # ZSH
  environment.shells = with pkgs; [ zsh ];
  environment.pathsToLink = [ "/share/zsh" ];
  programs.zsh.enable = true;

  # Docker
  #virtualisation.docker.enable = true;
  #virtualisation.docker.autoPrune.enable = true;
  #virtualisation.docker.autoPrune.dates = "weekly";
  #virtualisation.docker.autoPrune.flags = [ "--all" ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  #sops.defaultSopsFile = ../secrets/samba.yaml;
  # sops.age.keyFile = "/home/luckierdodge/.config/sops/age/keys.txt";
  # sops.age.generateKey = false;
  # sops.secrets.samba_password = {
  #   format = "yaml";
  #   sopsFile = ../secrets/samba.yaml;
  # };

  # Nix Maintenance
  #nix.gc = {
  #  automatic = true;
  #  dates = "daily";
  #  options = "--delete-older-than 7d";
  #};

  # Automatic Updates
  #system.autoUpgrade.enable = true;
  #system.autoUpgrade.allowReboot = true;

  # Tailscale
  #services.tailscale.enable = true;
  #networking.firewall.checkReversePath = "loose";

  users.users.luckierdodge.home = /Users/luckierdodge;
  #home-manager = {
  #  extraSpecialArgs = { inherit inputs outputs; };
  #  users = {
  #    # Import your home-manager configuration
  #    luckierdodge = import ../home-manager/home.nix;
  #  };
  #};

  # This setups a SSH server. Very important if you're setting up a headless system.
  # Feel free to remove if you don't need it.
  #services.openssh = {
  #  enable = true;
  #  settings = {
  #    # Forbid root login through SSH.
  #    PermitRootLogin = "no";
  #    # Use keys only. Remove if you want to SSH using password (not recommended)
  #    # PasswordAuthentication = false;
  #  };
  #};

  fonts.packages =
    [ ] ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);
  system.stateVersion = 6;
  system.primaryUser = "luckierdodge";
}
