{lib, ...}: {
  imports = [
    ../omnibook/home.nix
  ];

  # No internal laptop panel (eDP-1) or dock switching; Hyprland's native
  # monitor rule handles the DisplayPort output.
  services.kanshi.enable = lib.mkForce false;
}
