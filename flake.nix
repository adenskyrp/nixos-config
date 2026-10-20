{
  description = "adenskyrp's Pure Declarative Infrastructure & System Configurations";

  # ---------------------------------------------------------------------------
  # FLAKE INPUTS (CHANNELS & PACKAGES)
  # ---------------------------------------------------------------------------
  inputs = {
    # Chaotic Nyx: CachyOS BORE Kernel, git Mesa, and performance overlays
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Unify root nixpkgs onto Chaotic's exact nixpkgs revision so kernel module
    # aggregation and Mesa-git never skew ahead of Chaotic's binary cache.
    nixpkgs.follows = "chaotic/nixpkgs";
    # Deadlock Mod Manager overlay -- unified onto root nixpkgs to avoid evaluating a second nixpkgs tree
    grimoire = {
      url = "github:Slush97/grimoire";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative user-space environment management
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative Flatpak state: remotes, installed refs, per-app sandbox
    # overrides. Consumed by modules/sober.nix.
    # NO `inputs.nixpkgs.follows` HERE, DELIBERATELY (nix-flatpak has zero inputs).
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.7.0";
  };

  # ---------------------------------------------------------------------------
  # FLAKE OUTPUTS (SYSTEM COMPILATION MATRICES)
  # ---------------------------------------------------------------------------
  outputs = {
    self,
    nixpkgs,
    chaotic,
    home-manager,
    grimoire,
    nix-flatpak,
    ...
  } @ inputs: let
    mkHost = {
      hostName,
      extraModules ? [],
    }:
      nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
        modules =
          [
            {
              nixpkgs.overlays = [
                grimoire.overlays.default
              ];
            }
            chaotic.nixosModules.default
            nix-flatpak.nixosModules.nix-flatpak
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.crazycat = import ./hosts/${hostName}/home.nix;
            }
            ./hosts/${hostName}/configuration.nix
          ]
          ++ extraModules;
      };
  in {
    nixosConfigurations = {
      # HP OmniBook Ultra 14 (AMD Ryzen AI 9 365 / Radeon 880M)
      omnibook = mkHost {hostName = "omnibook";};

      # Custom AM4 Desktop (AMD Ryzen 5 5600X / Radeon RX 6650 XT / ASRock B550M-HDV / Intel BE200)
      desktop = mkHost {hostName = "desktop";};
    };
  };
}
