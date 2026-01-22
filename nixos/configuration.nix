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
    inputs.home-manager.nixosModules.home-manager
    #    <sops-nix/modules/sops>
  ];

  nixpkgs = {
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

  # This will add each flake input as a registry
  # To make nix3 commands consistent with your flake
  nix.registry = (lib.mapAttrs (_: flake: { inherit flake; })) (
    (lib.filterAttrs (_: lib.isType "flake")) inputs
  );

  # This will additionally add your inputs to the system's legacy channels
  # Making legacy nix commands consistent as well, awesome!
  nix.nixPath = [ "/etc/nix/path" ];
  environment.etc = lib.mapAttrs' (name: value: {
    name = "nix/path/${name}";
    value.source = value.flake;
  }) config.nix.registry;

  nix.settings = {
    # Enable flakes and new 'nix' command
    experimental-features = "nix-command flakes";
  };
  nix.optimise.automatic = true;

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Chicago";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.displayManager.sddm.settings.General.DisplayServer = "wayland";
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };
  programs.noisetorch.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  environment.systemPackages = with pkgs; [
    vim-full # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    git
    tailscale
    zsh
    inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.default
    firefox
    age
    vscode
    parted
    bitwarden-cli
    steam
    discord
    slack
    slack-term
    spotify
    noisetorch
    nixpkgs-unstable.ollama
    kdePackages.audiocd-kio
    kdePackages.kaccounts-integration
    kdePackages.kaccounts-providers
    kdePackages.kdeconnect-kde
    kdePackages.kaddressbook
    asunder
    python3Packages.pip
    python3Packages.virtualenv
    python3Packages.ruff
    appimage-run
    usbutils
  ];

  programs.nix-ld.enable = true;
  # programs.nix-ld.libraries = options.programs.nix-ld.libraries.default;

  # Support running AppImage out-of-the-box
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # ZSH
  environment.shells = with pkgs; [ zsh ];
  environment.pathsToLink = [ "/share/zsh" ];
  programs.zsh.enable = true;

  # Docker
  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  virtualisation.docker.autoPrune.dates = "weekly";
  virtualisation.docker.autoPrune.flags = [ "--all" ];
  virtualisation.docker.daemon.settings = {
    experimental = true;
    ipv6 = true;
    ip6tables = true;
    default-network-opts.bridge."com.docker.network.enable_ipv6" = "true";
    fixed-cidr-v6 = "fd00::/80";
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
  # If no user is logged in, the machine will power down after 20 minutes.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.services.NetworkManager-wait-online.enable = false;

  # Nix Maintenance
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  # Automatic Updates
  system.autoUpgrade.enable = true;
  system.autoUpgrade.allowReboot = true;

  # Tailscale
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "server";
  networking.firewall.checkReversePath = "loose";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users = {
    luckierdodge = {
      # initialPassword = "correcthorsebatterystaple";
      isNormalUser = true;
      description = "Ryan D. Lewis";
      extraGroups = [
        "networkmanager"
        "wheel"
        "docker"
      ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDR+XhJiwioD5yOIROSXzPnXdq+H/gdugsEvCfGqi99p ryand@lastprism"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILIOe47H0qOPG5GHRg0PjHJCFA2BxQhzHx18Ch9iGj0A luckierdodge@lastprism"
      ];
    };
  };
  home-manager = {
    extraSpecialArgs = { inherit inputs outputs; };
    users = {
      # Import your home-manager configuration
      luckierdodge = import ../home-manager/home.nix;
    };
    backupFileExtension = "backup";
  };

  # This setups a SSH server. Very important if you're setting up a headless system.
  # Feel free to remove if you don't need it.
  services.openssh = {
    enable = true;
    settings = {
      # Forbid root login through SSH.
      PermitRootLogin = "no";
      # Use keys only. Remove if you want to SSH using password (not recommended)
      # PasswordAuthentication = false;
    };
  };

  # VSCode Server Fix
  services.vscode-server.enable = true;

  # Steam
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
  };

  # Flatpaks + Flathub
  services.flatpak.enable = true;
  services.flatpak.packages = [
    "com.github.tchx84.Flatseal"
    "com.bitwarden.desktop"
    "md.obsidian.Obsidian"
    "io.github.flattool.Warehouse"
    "io.github.alainm23.planify"
    "org.chromium.Chromium"
  ];
  xdg.portal = {
    enable = true;
    config.common.default = [
      "gtk"
    ];
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      kdePackages.xdg-desktop-portal-kde
      xdg-desktop-portal-wlr
    ];
  };
  environment.sessionVariables = {
    XDG_DATA_DIRS = [
      "/var/lib/flatpak/exports/share"
      "$HOME/.local/share/flatpak/exports/share"
      "$XDG_DATA_DIRS"
    ];
  };

}
