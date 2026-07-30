{
  description = "adenskyrp's Infrastructure Declarations and System Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, chaotic, home-manager, ... }@inputs: {

    nixosConfigurations = {

      # HP OmniBook Ultra 14
      omnibook = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          chaotic.nixosModules.default

	  home-manager.nixosModules.home-manager
	  {
	    home-manager.useGlobalPkgs = true;
	    home-manager.useUserPackages = true;
	    home-manager.users.crazycat = import ./hosts/omnibook/home.nix;
	  }
          ./hosts/omnibook/hardware-configuration.nix
          ./hosts/omnibook/configuration.nix
          ./modules/core.nix
          ./modules/gaming.nix
        ];
      };

      # Desktop Rig
      desktop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          chaotic.nixosModules.default

          ./hosts/desktop/hardware-configuration.nix
          ./hosts/desktop/configuration.nix
          ./modules/core.nix
          ./modules/gaming.nix
        ];
      };
    };
  };
}
