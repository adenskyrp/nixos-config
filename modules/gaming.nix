{config, pkgs, ... }:

{
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  programs.gamemode = {
    enable = true;
    settings = {
      general = {
	renice = 10;
      };
      custom = {
	start = "${pkgs.libnotify}/bin/notify-send 'GameMode' 'Optimizations Active'";
	end = "${pkgs.libnotify}/bin/notfy-send 'GameMode' 'Optimizations Deactivated'";
      };
    };
  };

  boot.kernel.sysctl = {
    "kernel.split_lock_mitigate" = 0;

    "vm.max_map_count" = 2147483642;

    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
  };

  environment.systemPackages = with pkgs; [
    mangohud
    protonup-qt
    gamescope
    gamemode
  ];
}
