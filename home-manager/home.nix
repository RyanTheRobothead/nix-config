# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
  nixpkgs-unstable,
  ...
}:
let
  # Bumped daily by Renovate, apart from the weekly nixpkgs-unstable refresh
  claude-code-pkgs = import inputs.nixpkgs-claude-code {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  # You can import other home-manager modules here
  imports = [
    # If you want to use modules your own flake exports (from modules/home-manager):
    # outputs.homeManagerModules.example

    # Or modules exported from other flakes (such as nix-colors):
    # inputs.nix-colors.homeManagerModules.default

    # You can also split up your configuration and import pieces of it here:
    # The shell, editors and dotfiles; servers get only this
    ./core.nix
  ];

  nixpkgs = {
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      outputs.overlays.additions
      outputs.overlays.modifications
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
      # Workaround for https://github.com/nix-community/home-manager/issues/2942
      allowUnfreePredicate = _: true;
    };
  };

  # Toolchains, databases and agents: workstations only
  # programs.neovim.enable = true;
  home.packages = with pkgs; [
    gh
    redis
    pre-commit
    act
    lazydocker
    nixfmt-tree
    nixfmt
    haskellPackages.cabal-install
    ghc
    # claude-code; the only claude on PATH, so nothing user-writable can stand in for it
    claude-code-pkgs.claude-code
    nixpkgs-unstable.opencode
    nixpkgs-unstable.opencode-desktop
    nodejs
    yarn
    mongodb-tools
    postgresql
    mosh

    nix-search-cli
    cargo
    gcc
    nixpkgs-unstable.beads
    devbox
    direnv
    nix-direnv
    outputs.packages.${pkgs.stdenv.hostPlatform.system}.argoProxy
  ];

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";

  # Workstation dotfiles; the rest are in core.nix
  home.file = {
    ".config/alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;
    ".config/alacritty/themes/themes/everforest_dark.toml".source = ./dotfiles/everforest_dark.toml;
    ".config/opencode/opencode.json".source = ./dotfiles/opencode.json;
    ".sops.yaml".source = ./dotfiles/.sops.yaml;
  };
}
