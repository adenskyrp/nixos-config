{ config, pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;

    xwayland.enable = true;

    configType = "hyprlang";

    settings = {
      monitor = [
	",highrr,auto,1"
      ];

      general = {
	allow_tearing = true;

	border_size = 2;
	gaps_in = 4;
	gaps_out = 8;
      };

      decoration = {
	rounding = 0;
	
	shadow = {
	  enabled = false;
	};

	blur = {
	  enabled = false;
	};
      };

      windowrule = [
	"immediate 1, match:class ^(rocketleague)$"
	"immediate 1, match:class ^(cs2)$"
	"immediate 1, match:class ^(osu\!)$"

	"fullscreen 1, match:class ^(Minecraft.*)$"

	"workspace 1, match:class ^(rocketleague)$"
	"workspace 1, match:class ^(osu\!)$"
	"workspace 1, match:class ^(cs2)$"
      ];

      exec-once = [
	"waybar"
      ];
      exec = [
	"systemctl --user restart kanshi"
      ];

      "$mainMod" = "SUPER";
      "$terminal" = "kitty";


      bind = [
	"$mainMod, Q, exec, $terminal"
	"$mainMod, C, killactive,"
	"$mainMod, M, exit,"
	"$mainMod, V, togglefloating,"
	"$mainMod, F, fullscreen,"

	"$mainMod, 1, workspace, 1"
	"$mainMod, 2, workspace, 2"
	"$mainMod, 3, workspace, 3"
	"$mainMod, 4, workspace, 4"
	"$mainMod, 5, workspace, 5"

	"$mainMod SHIFT, 1, movetoworkspace, 1"
	"$mainMod SHIFT, 2, movetoworkspace, 2"
	"$mainMod SHIFT, 3, movetoworkspace, 3"
	"$mainMod SHIFT, 4, movetoworkspace, 4"
	"$mainMod SHIFT, 5, movetoworkspace, 5"

	"$mainMod, SPACE, exec, rofi -show drun -show-icons"
      ];
    };
  };

  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.fira-code
    pavucontrol           # GTK Volume Mixer
    deepfilternet         # Neural-network noise cancellation filter
    lsp-plugins           # Linux Studio Plugins for 4-band parametric EQ
  ];
  services.easyeffects = {
    enable = true;
  };
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    theme = "gruvbox-dark";
  };
  programs.waybar = {
    enable = true;

    settings = {
      mainbar = {
	layer = "top";
	position = "top";
	height = 30;
	modules-left = [ "hyprland/workspaces" ];
	modules-center = [ "hyprland/window" ];
	modules-right = [ "pulseaudio" "cpu" "battery" "clock" ];

	"hyprland/workspaces" = {
	  format = "{name}";
	  disable-scroll = true;
	};

	"pulseaudio" = {
	  format = "{volume}%";
	  on-click = "pavucontrol";
	};

	"clock" = {
	  format = "{:%H:%M}";
	  tooltip-format = "{:%Y-%m-%d}";
	};
      };
    };
    style = ''
      *{
	border: none;
	border-radius: 0;
	font-family: "FiraCode Nerd Font Propo", "FiraCode Nerd Font", sans-serif;
	font-size: 13px;
	min-height: 0;
      }
      window#waybar {
	background-color: rgba(30, 30, 46, 0.9);
	color: #cdd6f4;
      }
      #workspaces button {
	padding: 0 5px;
	color: #585b70;
      }
      #workspaces button.active {
	color: #cba6f7;
      }
      #clock, #battery, #cpu, #pulseaudio {
	padding: 0 10px;
      }
    '';
  };
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    profiles.crazycat = {
      isDefault = true;
      settings = {
	"gfx.webrender.all" = true;
	"media.ffmpeg.vaapi.enabled" = true;
	"widget.use-aspect-ratio" = true;
      };
    };
  };
  services.kanshi = {
    enable = true;
    systemdTarget = "hyprland-session.target";

    settings = [
      {
	profile = {
	  name = "docked";
	  outputs = [
	    {criteria = "eDP-1"; status = "disable"; }
	    {criteria = "*"; status = "enable"; }
	  ];
	};
      }

      {
	profile = {
	  name = "undocked";
	  outputs = [
	    { criteria = "eDP-1"; status = "enable"; }
	  ];
	};
      }
    ];
  };
  home.stateVersion = "24.05";
}
