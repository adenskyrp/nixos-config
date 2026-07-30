{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    neovim
    curl
    pciutils
    lm_sensors
    htop
    kitty
    pavucontrol
  ];
}
