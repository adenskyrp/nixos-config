# ~/nixos-config/hosts/omnibook/home.nix
{ config, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # HYPRLAND: EXTREME LOW-LATENCY COMPOSITOR PIPELINE
  # ---------------------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;
    configType = "hyprlang";    

    settings = {
      # --- HARDWARE ENVIRONMENT VARIABLES ---
      env = [
        # Forces AMD GPU to use Legacy KMS for Hyprland.
        # This is strictly required on Radeon hardware to allow asynchronous 
        # page flips (screen tearing) for zero-latency fullscreen rendering.
        "WLR_DRM_NO_ATOMIC,1"
      ];    
      # Binds to the BenQ Zowie at maximum refresh rate (600Hz)
      monitor = [
        ",highrr,auto,1"
      ];
      # --- COMPOSITOR DEBUG OVERRIDES ---
      debug = {
        vfr = false;
      };
      # --- SCHEDULING & SCANOUT OPTIMIZATIONS (CRITICAL FOR 8KHz) ---
      render = {
        # Manages direct presentation. Leaving this to its optimized default 
        # or explicitly setting it ensures zero-copy rendering paths for fullscreen games.
        direct_scanout = false; 
      };
      # --- RAW INPUT SUBSYSTEM ---
      input = {
        # 'flat' ensures a 1:1 mapping of your ATK sensor to the screen 
        # with zero software acceleration curves.
        sensitivity = 0.0;
        accel_profile = "flat";
        
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
        # Allows async page flips (tearing) for uncapped frame rates in games
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
      # --- UNIFIED HYPRLANG WINDOW RULES (Bleeding-Edge Syntax) ---
      # Rules are explicitly split into props (match:class) and effects (tile 1)
      windowrule = [
        # Rocket League
        "tile 1, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "immediate 1, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "fullscreen 1, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "workspace 5, match:class ^(steam_app_252950|rocketleague\\.exe)$"

        # osu!
        "tile 1, match:class ^(osu\\!\\.exe)$"
        "immediate 1, match:class ^(osu\\!\\.exe)$"
        "fullscreen 1, match:class ^(osu\\!\\.exe)$"
        "workspace 5, match:class ^(osu\\!\\.exe)$"

        # Aim Lab
        "tile 1, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"
        "immediate 1, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"
        "workspace 5, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"

        # Counter-Strike 2
        "tile 1, match:class ^(steam_app_730|cs2\\.exe)$"
        "immediate 1, match:class ^(steam_app_730|cs2\\.exe)$"
        "workspace 5, match:class ^(steam_app_730|cs2\\.exe)$"
      ];      # --- HARDWARE MEDIA KEYS & BINDINGS ---
      bindel = [
        ", XF86AudioRaiseVolume, exec, ${pkgs.swayosd}/bin/swayosd-client --output-volume +5"
        ", XF86AudioLowerVolume, exec, ${pkgs.swayosd}/bin/swayosd-client --output-volume -5"
        ", XF86MonBrightnessUp, exec, ${pkgs.swayosd}/bin/swayosd-client --brightness raise"
        ", XF86MonBrightnessDown, exec, ${pkgs.swayosd}/bin/swayosd-client --brightness lower"
      ];
      bindl = [
        ", XF86AudioMute, exec, ${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle"
        ", XF86AudioMicMute, exec, ${pkgs.swayosd}/bin/swayosd-client --input-volume mute-toggle"
        ", XF86AudioPlay, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
        ", XF86AudioPause, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
        ", XF86AudioNext, exec, ${pkgs.playerctl}/bin/playerctl next"
        ", XF86AudioPrev, exec, ${pkgs.playerctl}/bin/playerctl previous"
      ];
      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];

      exec-once = [
        "easyeffects --gapplication-service"
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
      ];
      exec = [ "systemctl --user restart kanshi" ];

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
        "$mainMod, mouse_down, workspace, e+1"
        "$mainMod, mouse_up, workspace, e-1"
        "$mainMod SHIFT, 1, movetoworkspace, 1"
        "$mainMod SHIFT, 2, movetoworkspace, 2"
        "$mainMod SHIFT, 3, movetoworkspace, 3"
        "$mainMod SHIFT, 4, movetoworkspace, 4"
        "$mainMod SHIFT, 5, movetoworkspace, 5"
        "$mainMod SHIFT, S, exec, screenshot-region"
        "$mainMod, SPACE, exec, rofi -show drun -show-icons"
        "$mainMod, D, exec, pkill -SIGUSR1 waybar"
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # APPLICATION LAUNCHER (Rofi Wayland Native with Nord Theme)
  # ---------------------------------------------------------------------------
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    theme = let
      inherit (config.lib.formats.rasi) mkLiteral;
    in {
      "*" = {
        background-color = mkLiteral "#2E3440F2"; # Nord Dark background (95% opacity)
        foreground-color = mkLiteral "#ECEFF4";   # Nord Snow Storm primary text
        text-color       = mkLiteral "#ECEFF4";
        border-color     = mkLiteral "#4C566A";   # Nord polar night border
        font             = "FiraCode Nerd Font 13";
      };

      "window" = {
        background-color = mkLiteral "#2E3440F2";
        border           = mkLiteral "2px";
        border-radius    = mkLiteral "8px";       # Rounded corners
        width            = mkLiteral "35%";
      };

      "element selected" = {
        background-color = mkLiteral "#88C0D0";   # Nord Frost accent for selection
        text-color       = mkLiteral "#2E3440";   # Dark text on bright accent
      };

      "inputbar" = {
        children         = map mkLiteral [ "prompt" "entry" ];
        background-color = mkLiteral "#3B4252";
        padding          = mkLiteral "10px";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # STATUS BAR (Waybar Layer-Shell Compositor Bar & CSS Stylesheet)
  # ---------------------------------------------------------------------------
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
        modules-right = [ "pulseaudio" "cpu" "memory" "temperature" "battery" "clock" ];

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
      #clock, #battery, #cpu, #memory, #temperature, #pulseaudio {
        padding: 0 10px;
      }
    '';
  };  
  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    # Fixed: Aligning shell integrations with your actual environment (Fish)
    enableFishIntegration = true; 
  };

  # ---------------------------------------------------------------------------
  # NEOVIM: EXTREME LOW-LATENCY EDITOR & NIX LSP
  # ---------------------------------------------------------------------------
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    # Explicitly disable bloated, legacy language providers
    withPython3 = false; 
    withRuby = false;
    # --- DEPENDENCY INJECTION (Sterile Sandbox) ---
    extraPackages = with pkgs; [
      nixd        # Bleeding-edge Nix LSP
      alejandra   # Uncompromising Nix code formatter
      ripgrep     # C-based, multithreaded regex searcher (for Telescope)
      fd          # Rust-based, hardware-accelerated file finder (for Telescope)
    ];

    # --- DECLARATIVE PLUGIN REGISTRY ---
    plugins = with pkgs.vimPlugins; [
      nvim-treesitter.withAllGrammars 
      nvim-lspconfig                  
      telescope-nvim                  # Instantaneous fuzzy-finding
      plenary-nvim                    # Required async Lua library for Telescope
    ];

    # --- LUA KERNEL CONFIGURATION ---
    initLua = ''
      -- 1. HARDWARE-ACCELERATED CLIPBOARD
      vim.opt.clipboard = "unnamedplus"

      -- 2. ERGONOMICS & PACING
      vim.g.mapleader = " "         -- Sets spacebar as the master key for shortcuts
      vim.opt.number = true
      vim.opt.relativenumber = true 
      vim.opt.shiftwidth = 2        
      vim.opt.tabstop = 2
      vim.opt.expandtab = true      
      
      -- 3. THE EVENT LOOP (8000Hz Input Optimization)
      -- By default, Neovim waits 4000ms after you stop typing to trigger Swap writes
      -- and CursorHold events (like LSP hover diagnostics). We drop this to 50ms.
      -- With an 8KHz keyboard, you want immediate diagnostic feedback the millisecond
      -- your finger lifts off the switch.
      vim.opt.updatetime = 50 

      -- NOTE ON LAZYREDRAW: 
      -- Many internet configs recommend 'vim.opt.lazyredraw = true' for speed. 
      -- DO NOT USE THIS. On a 600Hz panel using GPU-accelerated Kitty, lazyredraw 
      -- batches render calls incorrectly and introduces micro-stutters. 
      -- We leave it false to allow 1:1 frame pacing.

      -- 4. LSP INITIALIZATION (The "No Black Box" Setup)
      require('lspconfig').nixd.setup{
        cmd = { "nixd" },
        settings = {
          nixd = {
            formatting = { command = { "alejandra" } },
          },
        },
      }

      -- 5. KINETIC FEEDBACK: AUTO-FORMAT ON SAVE
      vim.api.nvim_create_autocmd("BufWritePre", {
        pattern = "*.nix",
        callback = function()
          vim.lsp.buf.format()
        end,
      })

      -- 6. TELESCOPE: INSTANT AST NAVIGATION
      -- Binds Space + f to instantly search all files in your NixOS config.
      -- Binds Space + g to live-grep text across your entire project in milliseconds.
      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})
      vim.keymap.set('n', '<leader>g', builtin.live_grep, {})
    '';
  };

  # ---------------------------------------------------------------------------
  # FIREFOX: EXTREME PERFORMANCE & DECLARATIVE POLICY ENGINE
  # ---------------------------------------------------------------------------
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";

    # --- ENTERPRISE POLICIES ---
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      
      EnableTrackingProtection = {
        Value = true;
        Locked = true;
        Cryptomining = true;
        # REMOVED: Fingerprinting = true. We must disable this to allow 
        # persistent DOM storage (cookies and logins) to function properly.
      };

      ExtensionSettings = {
        "*" = { installation_mode = "allowed"; };
        "uBlock0@raymondhill.net" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
          installation_mode = "force_installed";
        };
        "{d8293796-0370-4f51-b845-89498a442750}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/youtube-music-enhancer/latest.xpi";
          installation_mode = "force_installed";
        };
      };
    };

    # --- USER PROFILE PREFERENCES ---
    profiles.crazycat = {
      id = 0;           # CRITICAL: Mathematically locks this as the Master Profile
      isDefault = true;

      settings = {
        # 1. WAYLAND ZERO-COPY & HARDWARE DECODING
        "gfx.webrender.all" = true;
        "gfx.webrender.compositor" = true;
        "gfx.webrender.compositor.force-enabled" = true;
        "widget.use-aspect-ratio" = true;
        "widget.dmabuf.wayland-hardware-efficient" = true;
        "media.ffmpeg.vaapi.enabled" = true;
        "media.hardware-video-decoding.enabled" = true;
        "media.av1.enabled" = true;
        "layers.acceleration.force-enabled" = true;

        # 2. HIGH-REFRESH RATE FRAME PACING & INPUT
        "layout.frame_rate" = 600;
        "apz.overscroll.enabled" = true;
        "nglayout.initialpaint.delay" = 0;
        "browser.preferences.defaultPerformanceSettings.enabled" = false;
        "image.mem.shared" = true;
        
        # 3. DOM STORAGE & CACHING
        # We re-enable the disk cache so places.sqlite (History) and IndexedDB 
        # can write to the NVMe, but we strictly cap the capacity to 1GB to 
        # prevent I/O bloat, letting your ZRAM handle the heavy lifting.
        "browser.cache.disk.enable" = true;
        "browser.cache.disk.capacity" = 1048576;
        "browser.cache.memory.enable" = true;

        # 4. TELEMETRY & UI DENSITY
        "extensions.pocket.enabled" = false;
        "browser.newtabpage.activity-stream.showSponsored" = false;
        "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
        "browser.newtabpage.activity-stream.feeds.telemetry" = false;
        "toolkit.telemetry.enabled" = false;
        "browser.ping-centre.telemetry" = false;
        "browser.compactmode.show" = true;
        "browser.uidensity" = 1;            
        "browser.tabs.firefox-view" = false; 
      };
    };
  };
  # ---------------------------------------------------------------------------
  # SYSTEM PACKAGES & RUNTIMES
  # ---------------------------------------------------------------------------
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.fira-code pavucontrol deepfilternet lsp-plugins polkit_gnome
    docker-client playerctl overskride vesktop protonup-qt wineWow64Packages.staging
    winetricks protontricks grim slurp wl-clipboard satty adwaita-icon-theme hicolor-icon-theme

    (writeShellScriptBin "screenshot-region" ''
      FILENAME="/home/crazycat/Pictures/Screenshots/$(date +'%Y-%m-%d_%H-%M-%S').png"
      ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | tee "$FILENAME" | ${pkgs.wl-clipboard}/bin/wl-copy
      if command -v notify-send &> /dev/null; then
        notify-send "Screenshot Captured" "Saved to ~/Pictures/Screenshots and copied to clipboard." --icon=camera
      fi
    '')

    (writeShellScriptBin "osu-launcher" ''
      export WINEPREFIX="/home/crazycat/.wine-osu"
      export STAGING_AUDIO_DURATION="10000"

      # -----------------------------------------------------------------------
      # WAYLAND-NATIVE GUI PROMPT
      # -----------------------------------------------------------------------
      # Since this script is executed in the background without a TTY, we use 
      # Rofi's dmenu mode to capture standard output. It will present a clean 
      # input bar in the center of your screen.
      server_input=$(echo "" | ${pkgs.rofi}/bin/rofi -dmenu -p "osu! DevServer (Leave blank for Bancho):")

      # -----------------------------------------------------------------------
      # EXECUTION PIPELINE
      # -----------------------------------------------------------------------
      # If you press ESC, Rofi returns an exit code of 1, and server_input is null.
      # If you hit ENTER with no text, it returns an empty string. 
      if [ -n "$server_input" ]; then
        exec ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" -devserver "$server_input"
      else
        exec ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe"
      fi
    '')
  ];

  services.easyeffects.enable = true;
  services.swayosd = { enable = true; stylePath = null; };

  services.kanshi = {
    enable = true;
    systemdTarget = "hyprland-session.target";
    settings = [
      { profile = { name = "docked"; outputs = [ { criteria = "eDP-1"; status = "disable"; } { criteria = "*"; status = "enable"; } ]; }; }
      { profile = { name = "undocked"; outputs = [ { criteria = "eDP-1"; status = "enable"; } ]; }; }
    ];
  };

  programs.ssh = { enable = true; enableDefaultConfig = false; settings = { "*" = { ServerAliveInterval = 30; ServerAliveCountMax = 3; TCPKeepAlive = "yes"; }; }; };

  xdg.desktopEntries = {
    osu-stable = { name = "osu!stable"; exec = "osu-launcher"; icon = "osu!"; comment = "osu! stable"; terminal = false; categories = [ "Game" ]; };
  };
  # ---------------------------------------------------------------------------
  # GTK & ICON THEME ARCHITECTURE
  # ---------------------------------------------------------------------------
  # Forces GTK/Libadwaita applications to locate system icons correctly.
  gtk = {
    enable = true;
    gtk4.theme.name = "Adwaita-dark"; # Or set to null per the warning spec
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };
  # ---------------------------------------------------------------------------
  # WAYLAND SESSION VARIABLES
  # ---------------------------------------------------------------------------
  home.sessionVariables = {
    # Strictly enforces XDG compliance. Without this, Firefox will ignore 
    # your declarative profile in ~/.config and create a ghost profile in ~/.mozilla.
    MOZ_USE_XDG = "1";
  };
  home.stateVersion = "24.05";
}
