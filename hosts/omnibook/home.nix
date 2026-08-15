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
      # --- UNIFIED STARTUP PROCESSES (EXEC-ONCE) ---
      exec-once = [
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
      ];
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
      misc = {
        disable_hyprland_logo = true;     # Disables the default anime mascot / logo background pass
        disable_splash_rendering = true;  # Suppresses startup splash text rendering
        force_default_wallpaper = 0;      # Disables forcing default fallback wallpapers
        background_color = "0x000000";    # Sets compositor clear-color to solid pitch black
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
      # --- UNIFIED HYPRLANG WINDOW RULES ---
      # Uses 'match:class' exclusively and 'fullscreen 2' for direct scanout presentation.
      windowrule = [
	# Rocket League
        "tile 1, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "immediate 1, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "fullscreen_state 2 2, match:class ^(steam_app_252950|rocketleague\\.exe)$"
        "workspace 5, match:class ^(steam_app_252950|rocketleague\\.exe)$"

        # osu!
        "tile 1, match:class ^(osu\\!|osu\\!\\.exe)$"
        "immediate 1, match:class ^(osu\\!|osu\\!\\.exe)$"
	"fullscreen_state 2 2, match:class ^(osu\\!|osu\\!\\.exe)$"
        "workspace 5, match:class ^(osu\\!|osu\\!\\.exe)$"

        # Aim Lab
        "tile 1, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"
	"fullscreen_state 2 2, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"
        "immediate 1, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"
        "workspace 5, match:class ^(aimlab_tb\\.exe|steam_app_714010)$"

        # Counter-Strike 2
	"tile 1, match:class ^(cs2)$"
	"fullscreen_state 2 2, match:class ^(cs2)$"
        "immediate 1, match:class ^(cs2)$"
        "workspace 5, match:class ^(cs2)$"
      ];
      # --- HARDWARE MEDIA KEYS & BINDINGS ---
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
        "$mainMod, SPACE, exec, fuzzel"
        "$mainMod, D, exec, pkill -SIGUSR1 ironbar"
      ];
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "adenskyrp";
        email = "36445815+adenskyrp@users.noreply.github.com";
      };
    };
  };
  # ---------------------------------------------------------------------------
  # INTERACTIVE SHELL ENVIRONMENT (Fish)
  # ---------------------------------------------------------------------------
  programs.fish = {
    enable = true;
    
    # Declaratively define custom user-space functions
    functions = {
      sysdeploy = ''
        # Store the current directory so we can return later
        set -l current_dir $PWD
        
        # Navigate to the flake root
        cd ~/nixos-config

        # 1. Stage all changes. Flakes CANNOT see untracked files.
        git add .

        # 2. Rebuild the system BEFORE committing to prevent pushing broken builds
        echo "--> Initiating declarative system rebuild..."
        if sudo nixos-rebuild switch --flake .#omnibook --impure
          
          # 3. Handle the commit message from function arguments
          set -l commit_msg $argv
          if test -z "$commit_msg"
            set commit_msg "chore: automated system state update"
          end
          
          # 4. Commit and Push
          git commit -m "$commit_msg"
          echo "--> Pushing new generation to GitHub..."
          git push origin main
          
          echo "--> System successfully deployed and tracked."
        else
          echo "--> Build failed. Git commit aborted. Fix your Nix syntax."
        end

        # Return to the original directory
        cd $current_dir
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # APPLICATION LAUNCHER (Fuzzel: Wayland-Native, GPU-Accelerated)
  # ---------------------------------------------------------------------------
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        font = "FiraCode Nerd Font:size=13";
        # Points Fuzzel to your exact terminal for executing CLI apps
        terminal = "${pkgs.kitty}/bin/kitty";
        prompt = ''"❯ "'';       # Requires strict quoting in Nix for strings with spaces
        layer = "top";           # Renders over fullscreen games if invoked
        lines = 10;
        width = 40;
        horizontal-pad = 20;
        vertical-pad = 20;
        inner-pad = 10;
      };
      colors = {
        # Translated Nord Theme (RRGGBBAA format for Fuzzel)
        background = "2e3440f2";       # Nord Dark
        text = "eceff4ff";             # Nord Snow Storm
        match = "88c0d0ff";            # Nord Frost (Fuzzy match highlight)
        selection = "4c566aff";        # Selection background
        selection-text = "eceff4ff";   # Selection text
        border = "4c566aff";           # Border color
      };
      border = {
        width = 2;
        radius = 8;
      };
    };
  };

  # 2. Declaratively construct the JSON configuration
  # We are omitting ALL polling modules (CPU/RAM/Temp). 
  # This bar is 100% event-driven. It will never interrupt the BORE scheduler.
  xdg.configFile."ironbar/config.json".text = builtins.toJSON {
    position = "top";
    height = 30;
    
    start = [
      {
        type = "workspaces";
        # Ironbar natively supports Hyprland workspaces
        name_map = {
          "1" = "1"; "2" = "2"; "3" = "3"; "4" = "4"; "5" = "5";
        };
      }
    ];
    
    center = [
      {
        type = "clock";
        format = "%H:%M";
      }
    ];
    
    end = [
      {
        type = "volume";
        format = "{icon} {percentage}%";
        max_volume = 100;
      }
      {
        type = "tray";
      }
    ];
  };

  # 3. Inject the CSS Stylesheet (Translating your Nord aesthetics)
  xdg.configFile."ironbar/style.css".text = ''
    * {
      font-family: "FiraCode Nerd Font Propo", "FiraCode Nerd Font", sans-serif;
      font-size: 13px;
      border: none;
      border-radius: 0;
    }
    
    window {
      background-color: rgba(46, 52, 64, 0.9); /* Nord Dark */
      color: #ECEFF4; /* Nord Snow Storm */
    }
    
    .workspace {
      padding: 0 5px;
      color: #4C566A;
    }
    
    .workspace.focused {
      color: #88C0D0; /* Nord Frost */
    }
    
    .clock, .volume {
      padding: 0 10px;
    }
  '';

  # ---------------------------------------------------------------------------
  # STATUS BAR DAEMON (Systemd Integration)
  # ---------------------------------------------------------------------------
  systemd.user.services.ironbar = {
    Unit = {
      Description = "Ironbar custom Wayland bar";
      # The core of the fix: We strictly instruct systemd to wait until 
      # Hyprland confirms the graphical session target is active and DBus is populated.
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      # Execute the binary directly from the immutable Nix store
      ExecStart = "${pkgs.ironbar}/bin/ironbar";
      # If the bar crashes (or if you manually kill it), revive it within 1 second.
      Restart = "on-failure";
      RestartSec = "1sec";
    };
    Install = {
      # Binds the daemon to Hyprland's specific session target
      WantedBy = [ "hyprland-session.target" ];
    };
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
      vim.opt.updatetime = 50 

      -- 4. LSP INITIALIZATION (Neovim 0.11+ Native API)
      -- Native core config replacing deprecated require('lspconfig')
      vim.lsp.config('nixd', {
        cmd = { "nixd" },
        settings = {
          nixd = {
            formatting = { command = { "alejandra" } },
          },
        },
      })
      vim.lsp.enable('nixd')

      -- 5. KINETIC FEEDBACK: AUTO-FORMAT ON SAVE
      vim.api.nvim_create_autocmd("BufWritePre", {
        pattern = "*.nix",
        callback = function()
          vim.lsp.buf.format()
        end,
      })

      -- 6. TELESCOPE: INSTANT AST NAVIGATION
      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})
      vim.keymap.set('n', '<leader>g', builtin.live_grep, {})
    ''; # <-- CRITICAL: Must be two single quotes + semicolon
  };
  programs.obs-studio = {
    enable = true;

    # Low-Latency Plugins Architecture:
    # 1. obs-vkcapture: Vulkan/OpenGL direct DMA-BUF capture layer
    # 2. obs-pipewire-audio-capture: Direct PipeWire graph node audio intercept
    # 3. obs-vaapi: AMD VCN Hardware-accelerated video encoding pipeline
    plugins = with pkgs.obs-studio-plugins; [
      obs-vkcapture
      obs-pipewire-audio-capture
      obs-vaapi
      obs-gstreamer
    ];
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
    docker-client playerctl overskride protonup-qt wineWow64Packages.staging
    winetricks protontricks grim slurp wl-clipboard satty adwaita-icon-theme hicolor-icon-theme
    obs-studio-plugins.obs-vkcapture libva-utils osu-lazer-bin ironbar
    (discord.override {
      withVencord = true;
      withOpenASAR = true;
    })

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
      export STEAM_COMPAT_DATA_PATH="/home/crazycat/.wine-osu"
      export PIPEWIRE_LATENCY="64/48000"

      export WAYLAND_DISPLAY="wayland-1"
      export DISPLAY="" # Unset DISPLAY to ensure X11 fallback is strictly disabled      
      export DXVK_HUD=0

      server_input=$(echo "" | ${pkgs.fuzzel}/bin/fuzzel -d -p "osu! DevServer (Leave blank for Bancho): ")

      # CRITICAL FIX: Appended "$@" so file arguments are actually passed to osu!.exe
      if [ -n "$server_input" ]; then
        exec obs-gamecapture ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" -devserver "$server_input" "$@"
      else
        exec obs-gamecapture ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" "$@"
      fi
    '')
  ];

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
  # ---------------------------------------------------------------------------
  # XDG DESKTOP ENTRIES & MIME ROUTING
  # ---------------------------------------------------------------------------
  xdg.desktopEntries = {
    osu-stable = { 
      name = "osu!stable"; 
      # THE FIX: %U tells the desktop environment to pass file paths to the script
      exec = "osu-launcher %U"; 
      icon = "osu!"; 
      comment = "osu! stable"; 
      terminal = false; 
      categories = [ "Game" ]; 
      mimeType = [
        "application/x-osu-beatmap"
        "application/x-osu-skin"
        "application/x-osu-replay"
        "application/x-extension-osz"
        "application/x-extension-osk"
        "application/x-extension-osr"
      ];
    };
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "application/x-osu-beatmap" = "osu-stable.desktop";
      "application/x-osu-skin" = "osu-stable.desktop";
      "application/x-osu-replay" = "osu-stable.desktop";
      "application/x-extension-osz" = "osu-stable.desktop";
      "application/x-extension-osk" = "osu-stable.desktop";
      "application/x-extension-osr" = "osu-stable.desktop";
    };
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
    MOZ_USE_XDG = "1";
    MESA_VK_WSI_PRESENT_MODE = "immediate";
    SDL_JOYSTICK_HIDAPI = "0";
    SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_PAD = "0";
    STEAM_DISABLE_STEAM_INPUT = "1";
  };
  home.stateVersion = "24.05";
}
