{lib, ...}: {
  imports = [
    ../omnibook/home.nix
  ];

  # Desktop has no internal laptop panel (eDP-1) or USB-C dock switching;
  # Hyprland's native monitor rule handles the primary DisplayPort output.
  services.kanshi.enable = lib.mkForce false;
}
