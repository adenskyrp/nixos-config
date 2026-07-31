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
      windowrule = [
        "immediate 1, match:class ^(rocketleague)$"
        "immediate 1, match:class ^(cs2)$"
        "immediate 1, match:class ^(osu\!)$"
        
        "fullscreen 1, match:class ^(Minecraft.*)$"
        
        "workspace 5, match:class ^(rocketleague)$"
        "workspace 5, match:class ^(osu\!)$"
        "workspace 5, match:class ^(cs2)$"

	"immediate 1, match:class ^(steam_app_.*)$"      # Forces tearing/direct scanout for games
        "no_blur 1, match:class ^(steam_app_.*)$"         # Disables blur overhead on game surfaces
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
    docker-client

    # Communication
    vesktop               # Prefer Vesktop for native Wayland PipeWire screensharing
    discord               # Fallback official client
    
    # Wine Runtimes
    protonup-qt
    wineWow64Packages.staging # Fixed deprecation
    winetricks

    (writeShellScriptBin "osu-launcher" ''
      export WINEPREFIX="/home/crazycat/.wine-osu"
      export STAGING_AUDIO_DURATION="10000"
      exec ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" -devserver akatsuki.gg
    '')
  ];
  programs.ssh = {
    enable = true;

    # Opt out of legacy defaults to suppress evaluation warnings
    enableDefaultConfig = false;

    settings = {
      # Wildcard options applied globally to all SSH connections
      "*" = {
        ServerAliveInterval = 30;
        ServerAliveCountMax = 3;
        TCPKeepAlive = "yes";
      };

      # Target host mapping for the Lenovo ThinkPad media server
      "media-server" = {
        HostName = "100.126.180.74";      # Active Tailscale CGNAT IP
        User = "crazycat";                # POSIX user on Debian host
        HostKeyAlgorithms = "ssh-ed25519"; # Strictly enforce ED25519 host verification
      };
    };
  };
  programs.bash = {
    enable = true;
    shellAliases = {
      # Replace 'user' and 'debian-ip' with the actual Debian credentials.
      # This temporarily overrides the target host for a single command.
      remote-docker = "DOCKER_HOST=ssh://user@debian-ip docker";
    };
  };
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

  # ---------------------------------------------------------------------------
  # TERMINAL UTILITIES
  # ---------------------------------------------------------------------------
  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    # Enables 'y' alias to jump directories on exit
    enableBashIntegration = true; 
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
      # The complex execution is now handled by our immutable shell script
      exec = "osu-launcher"; 
      icon = "osu";
      comment = "osu! stable connected to Akatsuki private server";
      terminal = false;
      categories = [ "Game" ];
    };
  };
  home.stateVersion = "24.05";
}
