# /etc/nixos/hosts/omnibook/home.nix
{ config, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # HYPRLAND COMPOSITOR & INPUT PIPELINE
  # ---------------------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;
    configType = "hyprlang";

    settings = {
      # Binds to your 600Hz panel at maximum resolution and refresh rate
      monitor = [
        ",highrr,auto,1"
      ];

      # --- RAW INPUT SUBSYSTEM ---
      input = {
        sensitivity = 0.0;
        accel_profile = "flat";
        force_no_accel = true;
        touchpad = {
          disable_while_typing = true;
          natural_scroll = false;
        };
      };

      # --- 8000Hz MOUSE HARDWARE ISOLATION ---
      device = [
        {
          name = "compx-wireless-mouse-8k-dongle-l-mouse";
          sensitivity = 0.0;
          accel_profile = "flat";
        }
      ];

      # --- RENDERER OPTIMIZATIONS ---
      general = {
        allow_tearing = true;
        border_size = 2;
        gaps_in = 4;
        gaps_out = 8;
      };

      decoration = {
        rounding = 0;
        shadow = { enabled = false; };
        blur = { enabled = false; };
      };

      # --- WINDOW RULES (Modern V2 Regex Syntax) ---
      windowrulev2 = [
        "immediate, class:^(rocketleague)$"
        "immediate, class:^(cs2)$"
        "immediate, class:^(osu\!)$"
        
        "fullscreen, class:^(Minecraft.*)$"
        
        "workspace 1, class:^(rocketleague)$"
        "workspace 1, class:^(osu\!)$"
        "workspace 1, class:^(cs2)$"
      ];

      # --- DAEMON INITIALIZATION ---
      exec-once = [
        "easyeffects --gapplication-service"
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
      ];

      exec = [
        "systemctl --user restart kanshi"
      ];

      # --- KEYBINDS ---
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

  # ---------------------------------------------------------------------------
  # UNIFIED USER PACKAGES & COMPETITIVE CLIENTS
  # ---------------------------------------------------------------------------
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.fira-code
    pavucontrol           
    deepfilternet         
    lsp-plugins           
    polkit_gnome
    gamescope
    
    # Communication
    vesktop               # Prefer Vesktop for native Wayland PipeWire screensharing
    discord               # Fallback official client
    
    # Wine Runtimes
    protonup-qt
    wineWow64Packages.staging # Fixed deprecation
    winetricks
  ];

  # ---------------------------------------------------------------------------
  # BACKGROUND SERVICES & DAEMONS
  # ---------------------------------------------------------------------------
  services.easyeffects.enable = true;

  programs.rofi = {
    enable = true;
    package = pkgs.rofi; # Fixed XWayland penalty
    theme = "gruvbox-dark";
  };

  programs.waybar = {
    enable = true;
    systemd = {
      enable = true;
      targets = [ "hyprland-session.target" ];
    };
    settings = {
      mainbar = {
        layer = "top";
        position = "top";
        height = 30;
        output = [ "DP-1" "*" ];
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
      * {
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
    configPath = ".mozilla/firefox";
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

  # ---------------------------------------------------------------------------
  # XDG DESKTOP ENTRIES
  # ---------------------------------------------------------------------------
  xdg.desktopEntries = {
    osu-akatsuki = {
      name = "osu! (Akatsuki)";
      exec = "env WINEPREFIX=\"/home/crazycat/.wine-osu\" STAGING_AUDIO_DURATION=\"10000\" ${pkgs.wineWow64Packages.staging}/bin/wine /home/crazycat/Games/osu/osu\\!.exe -devserver akatsuki.gg";
      icon = "osu";
      comment = "osu! stable connected to Akatsuki private server";
      terminal = false;
      categories = [ "Game" ];
    };
  };

  home.stateVersion = "24.05";
}
