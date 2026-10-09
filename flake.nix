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

    # Declarative Flatpak state: remotes, installed refs, per-app sandbox
    # overrides. Consumed by modules/sober.nix.
    #
    # Pinned to a release tag rather than a branch or ?ref=latest -- this module
    # orchestrates binaries Nix does not build, so the orchestration layer
    # itself is the one part of that path that can still be pinned. (v0.7.0 and
    # the `latest` tag both resolve to 4408189 today; the tag is the stable
    # name.)
    #
    # NO `inputs.nixpkgs.follows` HERE, DELIBERATELY. nix-flatpak declares no
    # inputs at all -- its flake.nix is literally `outputs = _: { nixosModules
    # = ...; }` -- so a follows for nixpkgs has nothing to unify and nix emits
    #     warning: input nix-flatpak has an override for a non-existent input nixpkgs
    # on every evaluation, i.e. on every rebuild. Its pkgs comes from the
    # nixosSystem it is imported into, which is already this nixpkgs.
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.7.0";
  };

  # ---------------------------------------------------------------------------
  # FLAKE OUTPUTS (SYSTEM COMPILATION MATRICES)
  # ---------------------------------------------------------------------------
  outputs = {
    nixpkgs,
    chaotic,
    home-manager,
    nix-flatpak,
    ...
  } @ inputs: {
    nixosConfigurations =
      {
        # HP OmniBook Ultra 14 (AMD Ryzen AI 9 365 / Radeon 880M)
        omnibook = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          # Expose inputs to all downstream modules via specialArgs
          specialArgs = {inherit inputs;};
          modules = [
            # Chaotic Nyx repository overlay (provides linuxPackages_cachyos and mesa-git)
            chaotic.nixosModules.default

            # Declarative Flatpak module (consumed by modules/sober.nix)
            nix-flatpak.nixosModules.nix-flatpak

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
      }
      # -------------------------------------------------------------------------
      # SECONDARY DESKTOP RIG (STUB -- NOT PRESENT IN THIS TREE)
      # -------------------------------------------------------------------------
      # hosts/desktop/ does not exist yet. That is deliberate, it is documented in
      # CLAUDE.md, and it is NOT a bug to "fix" by deleting this output.
      #
      # The pathExists gate is new, and it is about the gate rather than about the
      # stub: `nix flake check` walks every nixosConfiguration and evaluates it, so
      # an unconditional `desktop` made the check fail permanently on a missing
      # import. The repo's only whole-flake gate could therefore never pass, which
      # means nobody reads it, which means it stops catching the regressions it
      # exists to catch. A gate that always fails is not a gate.
      #
      # Gating costs nothing and hides nothing: the intent stays declared right
      # here, and `desktop` reappears on its own the moment
      # hosts/desktop/configuration.nix is created. Nothing needs remembering.
      // nixpkgs.lib.optionalAttrs (builtins.pathExists ./hosts/desktop/configuration.nix) {
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
