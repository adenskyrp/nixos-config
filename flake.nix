{
  description = "adenskyrp's Pure Declarative Infrastructure & System Configurations";

  # ---------------------------------------------------------------------------
  # FLAKE INPUTS (CHANNELS & PACKAGES)
  # ---------------------------------------------------------------------------
  inputs = {
    # Bleeding-edge rolling packages
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Chaotic Nyx: CachyOS BORE Kernel, git Mesa, and performance overlays
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Declarative user-space environment management
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # ---------------------------------------------------------------------------
  # FLAKE OUTPUTS (SYSTEM COMPILATION MATRICES)
  # ---------------------------------------------------------------------------
  outputs = {
    self,
    nixpkgs,
    chaotic,
    home-manager,
    ...
  } @ inputs: let
    # Both hosts in this flake are x86_64; Mudfish ships x86_64-only binaries.
    system = "x86_64-linux";

    # This instantiation backs the `packages` output only (i.e. `nix build
    # .#mudfish`). The NixOS hosts do NOT inherit this config -- they build
    # their own pkgs -- so modules/mudfish.nix carries its own
    # allowUnfreePredicate rather than relying on this line.
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    # -------------------------------------------------------------------------
    # PACKAGE OUTPUTS
    # -------------------------------------------------------------------------
    packages.${system} = {
      mudfish = pkgs.callPackage ./pkgs/mudfish {};
      default = self.packages.${system}.mudfish;
    };

    nixosConfigurations = {
      # HP OmniBook Ultra 14 (AMD Ryzen AI 9 365 / Radeon 880M)
      omnibook = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        # Expose inputs to all downstream modules via specialArgs
        specialArgs = {inherit inputs;};
        modules = [
          # Chaotic Nyx repository overlay (provides linuxPackages_cachyos and mesa-git)
          chaotic.nixosModules.default

          # Home Manager module integration
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.crazycat = import ./hosts/omnibook/home.nix;
          }

          # Host-specific root entrypoint (handles internal module imports)
          ./hosts/omnibook/configuration.nix
        ];
      };

      # Secondary Desktop Rig
      desktop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
        modules = [
          chaotic.nixosModules.default
          ./hosts/desktop/configuration.nix
        ];
      };
    };
  };
}
