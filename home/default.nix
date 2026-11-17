# The user profile every host shares (home-manager). Host-only additions go in
# hosts/<name>/home.nix, which flake.nix imports when it exists.
{
  imports = [
    ./hyprland.nix
    ./desktop.nix
    ./apps.nix
    ./osu.nix
    ./cli.nix
  ];

  home.stateVersion = "25.11";
}
