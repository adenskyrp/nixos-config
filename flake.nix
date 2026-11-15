{
  description = "adenskyrp's NixOS machines: low-latency Hyprland desktops";

  # No nixConfig block: chaotic.nixosModules.default already adds
  # nyx-cache.chaotic.cx to nix.settings, and a flake-level nixConfig is
  # ignored (with two warnings per command) unless accept-flake-config is set.

  inputs = {
    # Chaotic Nyx: CachyOS BORE kernel, git Mesa, and performance overlays.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Root nixpkgs is Chaotic's exact nixpkgs revision, so the kernel and
    # Mesa-git never skew ahead of Chaotic's binary cache.
    nixpkgs.follows = "chaotic/nixpkgs";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deadlock mod manager overlay.
    grimoire = {
      url = "github:Slush97/grimoire";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative Flatpak state, consumed by modules/sober.nix. No
    # `inputs.nixpkgs.follows`: nix-flatpak has zero inputs.
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.7.0";
  };

  outputs = {
    nixpkgs,
    chaotic,
    home-manager,
    grimoire,
    nix-flatpak,
    ...
  }: let
    inherit (nixpkgs) lib;

    # A host is hosts/<name>/configuration.nix on top of ./modules, with the
    # shared user profile in ./home. hosts/<name>/home.nix, where it exists,
    # adds host-only user configuration (the omnibook's kanshi profiles).
    mkHost = hostName:
      lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          chaotic.nixosModules.default
          nix-flatpak.nixosModules.nix-flatpak
          home-manager.nixosModules.home-manager
          ./modules
          ./hosts/${hostName}/configuration.nix
          {
            networking.hostName = hostName;
            nixpkgs.overlays = [grimoire.overlays.default];
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              # Move an unmanaged file aside instead of failing activation
              # when home-manager starts owning its path.
              backupFileExtension = "hm-backup";
              users.crazycat.imports =
                [./home]
                ++ lib.optional (builtins.pathExists ./hosts/${hostName}/home.nix) ./hosts/${hostName}/home.nix;
            };
          }
        ];
      };
  in {
    # omnibook: HP OmniBook Ultra 14 (Ryzen AI 9 365, Radeon 880M)
    # desktop:  AM4 tower (Ryzen 5 5600X, Radeon RX 5700 XT)
    # z890:     iBUYPOWER Z890 (Core Ultra 7 270K Plus, RTX 5070)
    nixosConfigurations = lib.genAttrs ["omnibook" "desktop" "z890"] mkHost;
  };
}
