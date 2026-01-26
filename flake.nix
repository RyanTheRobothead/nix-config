{
  description = "Nix configs for my various NixOS, nix-darwin, and HomeManager-powered machines";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:nixos/nixpkgs/nixpkgs-25.11-darwin";
    # nixpkgs-legacy.url = "github:nixos/nixpkgs/nixos-23.11";
    # You can access packages and modules from different nixpkgs revs
    # at the same time. Here's an working example:
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # Also see the 'unstable-packages' overlay at 'overlays/default.nix'.

    # Home manager
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    vscode-server.url = "github:nix-community/nixos-vscode-server";
    # TODO: Add any other flake you might need
    # hardware.url = "github:nixos/nixos-hardware";

    # Shameless plug: looking for a way to nixify your themes and make
    # everything match nicely? Try nix-colors!
    # nix-colors.url = "github:misterio77/nix-colors";

    # sops-nix
    sops-nix.url = "github:Mic92/sops-nix";

    # darwin (for supporting Mac's ugh)
    darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

    # nix-flatpak
    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      sops-nix,
      vscode-server,
      darwin,
      nix-flatpak,
      ...
    }@inputs:
    let
      inherit (self) outputs;
      # Supported systems for your flake packages, shell, etc.
      systems = [
        "aarch64-linux"
        "i686-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      # This is a function that generates an attribute by calling a function you
      # pass to it, with each system as an argument
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # Helper function to create nixpkgs-unstable with unfree packages allowed
      mkUnstablePkgs =
        system:
        import nixpkgs-unstable {
          inherit system;
          config = {
            allowUnfree = true;
            allowUnfreePredicate = _: true;
          };
        };
    in
    {
      # Your custom packages
      # Accessible through 'nix build', 'nix shell', etc
      packages = forAllSystems (system: import ./pkgs nixpkgs.legacyPackages.${system});
      # Formatter for your nix files, available through 'nix fmt'
      # Other options beside 'alejandra' include 'nixpkgs-fmt'
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      # Your custom packages and modifications, exported as overlays
      #overlays = import ./overlays {inherit inputs;};
      # Reusable nixos modules you might want to export
      # These are usually stuff you would upstream into nixpkgs
      #nixosModules = import ./modules/nixos;
      # Reusable home-manager modules you might want to export
      # These are usually stuff you would upstream into home-manager
      #homeManagerModules = import ./modules/home-manager;

      # NixOS configuration entrypoint
      # Available through 'nixos-rebuild --flake .#your-hostname'
      nixosConfigurations = {
        aegis =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          nixpkgs.lib.nixosSystem {
            specialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              # > Our main nixos configuration file <
              ./nixos/aegis.nix
              home-manager.nixosModules.home-manager
              (
                { config, pkgs, ... }:
                {
                  home-manager.useUserPackages = true;
                  home-manager.extraSpecialArgs = {
                    nixpkgs-unstable = nixpkgsUnstableWithUnfree;
                  };
                  home-manager.users.luckierdodge =
                    let
                      lib = pkgs.lib;
                    in
                    import ./home-manager/home.nix {
                      inherit
                        config
                        pkgs
                        lib
                        inputs
                        outputs
                        ;
                      nixpkgs-unstable = nixpkgsUnstableWithUnfree;
                    };
                }
              )
              nix-flatpak.nixosModules.nix-flatpak
              sops-nix.nixosModules.sops
              vscode-server.nixosModules.default
              (
                { config, pkgs, ... }:
                {
                  services.vscode-server.enable = true;
                }
              )
            ];
          };
        killingtime =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          nixpkgs.lib.nixosSystem {
            specialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              # > Our main nixos configuration file <
              ./nixos/killingtime.nix
              home-manager.nixosModules.home-manager
              (
                { config, pkgs, ... }:
                {
                  home-manager.useUserPackages = true;
                  home-manager.users.luckierdodge =
                    let
                      lib = pkgs.lib;
                    in
                    import ./home-manager/home.nix {
                      inherit
                        config
                        pkgs
                        lib
                        inputs
                        outputs
                        ;
                      nixpkgs-unstable = nixpkgsUnstableWithUnfree;
                    };
                }
              )
              sops-nix.nixosModules.sops
              nix-flatpak.nixosModules.nix-flatpak
              vscode-server.nixosModules.default
              (
                { config, pkgs, ... }:
                {
                  services.vscode-server.enable = true;
                }
              )
            ];
          };
        bigbox =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          nixpkgs.lib.nixosSystem {
            specialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              # > Our main nixos configuration file <
              ./nixos/bigbox.nix
              home-manager.nixosModules.home-manager
              (
                { config, pkgs, ... }:
                {
                  home-manager.useUserPackages = true;
                  home-manager.users.luckierdodge =
                    let
                      lib = pkgs.lib;
                    in
                    import ./home-manager/home.nix {
                      inherit
                        config
                        pkgs
                        lib
                        inputs
                        outputs
                        ;
                      nixpkgs-unstable = nixpkgsUnstableWithUnfree;
                    };
                }
              )
              sops-nix.nixosModules.sops
              nix-flatpak.nixosModules.nix-flatpak
              vscode-server.nixosModules.default
              (
                { config, pkgs, ... }:
                {
                  services.vscode-server.enable = true;
                }
              )
            ];
          };
      };

      # Nix Darwin Configurations, for our Mac's (ugh)
      darwinConfigurations = {
        primemover =
          let
            system = "aarch64-darwin";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          darwin.lib.darwinSystem {
            specialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              ./darwin/primemover.nix
              home-manager.darwinModules.home-manager
              (
                { config, pkgs, ... }:
                {
                  home-manager.useUserPackages = true;
                  home-manager.users.luckierdodge =
                    let
                      lib = pkgs.lib;
                    in
                    import ./home-manager/home.nix {
                      inherit
                        config
                        pkgs
                        lib
                        inputs
                        outputs
                        ;
                      nixpkgs-unstable = nixpkgsUnstableWithUnfree;
                    };
                }
              )
            ];
            specialArgs = {
              system.stateVersion = 4;
            };
          };
      };

      # Standalone home-manager configuration entrypoint
      # Available through 'home-manager --flake .#your-username@your-hostname'
      homeConfigurations = {
        "luckierdodge@stark" =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          home-manager.lib.homeManagerConfiguration {
            pkgs = nixpkgs.legacyPackages.${system};
            extraSpecialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              # > Our main home-manager configuration file <
              ./home-manager/home.nix
              ./home-manager/stark.nix
            ];
          };
        "luckierdodge@lastprism" =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          home-manager.lib.homeManagerConfiguration {
            pkgs = nixpkgs.legacyPackages.${system};
            extraSpecialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              ./home-manager/home.nix
              ./home-manager/lastprism.nix
            ];
          };
        "luckierdodge@cerberus" =
          let
            system = "x86_64-linux";
            nixpkgsUnstableWithUnfree = mkUnstablePkgs system;
          in
          home-manager.lib.homeManagerConfiguration {
            pkgs = nixpkgs.legacyPackages.${system};
            extraSpecialArgs = {
              inherit inputs outputs;
              nixpkgs-unstable = nixpkgsUnstableWithUnfree;
            };
            modules = [
              ./home-manager/home.nix
              ./home-manager/cerberus.nix
            ];
          };
      };
    };
}
