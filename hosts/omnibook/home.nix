{
  config,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------------------------
  # HYPRLAND: EXTREME LOW-LATENCY COMPOSITOR PIPELINE
  # ---------------------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;
    configType = "lua";

    # ---------------------------------------------------------------------------
    # DECLARATIVE HYPRLAND LUA CONFIGURATION (~/.config/hypr/hyprland.lua)
    # ---------------------------------------------------------------------------
    # This block compiles your complete compositor configuration into an immutable
    # Nix store derivation symlinked directly to your XDG user profile.
    extraConfig = ''
      -- ======================================================================
      -- 1. DISPLAY TOPOLOGY & SCANOUT ENGINE (540Hz BenQ ZOWIE)
      -- ======================================================================
      hl.config({
        monitor = {
          ",highrr,auto,1",
        },

        -- Direct scanout bypasses compositor rendering passes on fullscreen
        render = {
          direct_scanout = true,
        },

        -- Master switch for wp_tearing_control_v1 protocol negotiation
        general = {
          allow_tearing = true,
          border_size = 2,
          gaps_in = 4,
          gaps_out = 8,
        },

        debug = {
          vfr = false,
        },

        misc = {
          disable_hyprland_logo = true,
          disable_splash_rendering = true,
          force_default_wallpaper = 0,
          background_color = 0x000000,
        },

        decoration = {
          rounding = 0,
          shadow = { enabled = false },
          blur = { enabled = false },
        },
      })

      -- ======================================================================
      -- 2. HARDWARE SENSOR & 8000Hz POLLING INPUT PIPELINE
      -- ======================================================================
      hl.config({
        input = {
          sensitivity = 0.0,
          accel_profile = "flat",
          touchpad = {
            disable_while_typing = true,
            natural_scroll = false,
          },
        },
      })

      -- ======================================================================
      -- 3. ASYNCHRONOUS TEARING WINDOW RULES (LUA API)
      -- ======================================================================
      hl.window_rule({
        match = { class = "rocketleague.exe" },
        immediate = true,
        tile = true,
        workspace = 5,
      })
      hl.window_rule({
        match = { class = "steam_app_252950" },
        immediate = true,
        tile = true,
        workspace = 5,
      })
      hl.window_rule({
        match = { class = "osu!.exe" },
        immediate = true,
        tile = true,
        workspace = 5,
      })
      hl.window_rule({
        match = { class = "aimlab_tb.exe" },
        immediate = true,
        tile = true,
        workspace = 5,
      })
      hl.window_rule({
        match = { class = "cs2" },
        immediate = true,
        tile = true,
        workspace = 5,
      })

      -- ======================================================================
      -- 4. STARTUP PROCESSES & SYSTEM HOOKS (EXEC-ONCE)
      -- ======================================================================
      hl.config({
        exec_once = {
          "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1",
        },
        exec = {
          "systemctl --user restart kanshi",
        }
      })

      -- ======================================================================
      -- 5. KEYBINDINGS & MEDIA INTEGRATION
      -- ======================================================================
      local mainMod = "SUPER"
      local terminal = "kitty"

      hl.bind("SUPER", "Q", "exec", "kitty")
      hl.bind("SUPER", "C", "killactive")
      hl.bind("SUPER", "M", "exit")
      hl.bind("SUPER", "V", "togglefloating")
      hl.bind("SUPER", "F", "fullscreen")
      hl.bind("SUPER", "SPACE", "exec", "fuzzel")
      hl.bind("SUPER", "D", "exec", "pkill -SIGUSR1 ironbar")
      hl.bind("SUPERSHIFT", "S", "exec", "screenshot-region")

      hl.bind("SUPER", "1", "workspace", "1")
      hl.bind("SUPER", "2", "workspace", "2")
      hl.bind("SUPER", "3", "workspace", "3")
      hl.bind("SUPER", "4", "workspace", "4")
      hl.bind("SUPER", "5", "workspace", "5")

      hl.bind("SUPERSHIFT", "1", "movetoworkspace", "1")
      hl.bind("SUPERSHIFT", "2", "movetoworkspace", "2")
      hl.bind("SUPERSHIFT", "3", "movetoworkspace", "3")
      hl.bind("SUPERSHIFT", "4", "movetoworkspace", "4")
      hl.bind("SUPERSHIFT", "5", "movetoworkspace", "5")

      hl.bind("SUPER", "mouse_down", "workspace", "e+1")
      hl.bind("SUPER", "mouse_up", "workspace", "e-1")

      hl.bindm("SUPER", "mouse:272", "movewindow")
      hl.bindm("SUPER", "mouse:273", "resizewindow")

      hl.bindm(mainMod, "mouse:272", "movewindow")
      hl.bindm(mainMod, "mouse:273", "resizewindow")

      hl.bindel("", "XF86AudioRaiseVolume", "exec", "${pkgs.swayosd}/bin/swayosd-client --output-volume +5")
      hl.bindel("", "XF86AudioLowerVolume", "exec", "${pkgs.swayosd}/bin/swayosd-client --output-volume -5")
      hl.bindel("", "XF86MonBrightnessUp", "exec", "${pkgs.swayosd}/bin/swayosd-client --brightness raise")
      hl.bindel("", "XF86MonBrightnessDown", "exec", "${pkgs.swayosd}/bin/swayosd-client --brightness lower")

      hl.bindl("", "XF86AudioMute", "exec", "${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle")
      hl.bindl("", "XF86AudioMicMute", "exec", "${pkgs.swayosd}/bin/swayosd-client --input-volume mute-toggle")
      hl.bindl("", "XF86AudioPlay", "exec", "${pkgs.playerctl}/bin/playerctl play-pause")
      hl.bindl("", "XF86AudioPause", "exec", "${pkgs.playerctl}/bin/playerctl play-pause")
      hl.bindl("", "XF86AudioNext", "exec", "${pkgs.playerctl}/bin/playerctl next")
      hl.bindl("", "XF86AudioPrev", "exec", "${pkgs.playerctl}/bin/playerctl previous")
    '';
  };
  # ---------------------------------------------------------------------------
  # INTERACTIVE SHELL & REBUILD PIPELINE
  # ---------------------------------------------------------------------------
  programs.git = {
    enable = true;
    settings.user = {
      name = "adenskyrp";
      email = "36445815+adenskyrp@users.noreply.github.com";
    };
  };

  programs.fish = {
    enable = true;
    functions = {
      sysdeploy = ''
        set -l current_dir $PWD
        cd ~/nixos-config

        git add .
        echo "--> Initiating declarative system rebuild..."
        if sudo nixos-rebuild switch --flake .#omnibook --impure
          set -l commit_msg $argv
          if test -z "$commit_msg"
            set commit_msg "chore: automated system state update"
          end
          git commit -m "$commit_msg"
          echo "--> Pushing new generation to GitHub..."
          git push origin main
          echo "--> System successfully deployed and tracked."
        else
          echo "--> Build failed. Git commit aborted. Fix your Nix syntax."
        end

        cd $current_dir
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # WAYLAND APPLICATION LAUNCHER (Fuzzel)
  # ---------------------------------------------------------------------------
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        font = "FiraCode Nerd Font:size=13";
        terminal = "${pkgs.kitty}/bin/kitty";
        prompt = ''"❯ "'';
        layer = "top";
        lines = 10;
        width = 40;
        horizontal-pad = 20;
        vertical-pad = 20;
        inner-pad = 10;
      };
      colors = {
        background = "2e3440f2";
        text = "eceff4ff";
        match = "88c0d0ff";
        selection = "4c566aff";
        selection-text = "eceff4ff";
        border = "4c566aff";
      };
      border = {
        width = 2;
        radius = 8;
      };
    };
  };

  # ---------------------------------------------------------------------------
  # EVENT-DRIVEN STATUS BAR (Ironbar)
  # ---------------------------------------------------------------------------
  xdg.configFile."ironbar/config.json".text = builtins.toJSON {
    position = "top";
    height = 30;
    start = [
      {
        type = "workspaces";
        name_map = {
          "1" = "1";
          "2" = "2";
          "3" = "3";
          "4" = "4";
          "5" = "5";
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

  xdg.configFile."ironbar/style.css".text = ''
    * {
      font-family: "FiraCode Nerd Font Propo", "FiraCode Nerd Font", sans-serif;
      font-size: 13px;
      border: none;
      border-radius: 0;
    }
    window {
      background-color: rgba(46, 52, 64, 0.9);
      color: #ECEFF4;
    }
    .workspace {
      padding: 0 5px;
      color = #4C566A;
    }
    .workspace.focused {
      color: #88C0D0;
    }
    .clock, .volume {
      padding: 0 10px;
    }
  '';

  systemd.user.services.ironbar = {
    Unit = {
      Description = "Ironbar custom Wayland bar";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${pkgs.ironbar}/bin/ironbar";
      Restart = "on-failure";
      RestartSec = "1sec";
    };
    Install = {
      WantedBy = ["hyprland-session.target"];
    };
  };

  # ---------------------------------------------------------------------------
  # LOW-LATENCY EDITOR (Neovim)
  # ---------------------------------------------------------------------------
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    withPython3 = false;
    withRuby = false;

    extraPackages = with pkgs; [
      nixd
      alejandra
      ripgrep
      fd
    ];

    plugins = with pkgs.vimPlugins; [
      nvim-treesitter.withAllGrammars
      nvim-lspconfig
      telescope-nvim
      plenary-nvim
    ];

    initLua = ''
      vim.opt.clipboard = "unnamedplus"
      vim.g.mapleader = " "
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.expandtab = true
      vim.opt.updatetime = 50

      vim.lsp.config('nixd', {
        cmd = { "nixd" },
        settings = {
          nixd = {
            formatting = { command = { "alejandra" } },
          },
        },
      })
      vim.lsp.enable('nixd')

      vim.api.nvim_create_autocmd("BufWritePre", {
        pattern = "*.nix",
        callback = function()
          vim.lsp.buf.format()
        end,
      })

      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})
      vim.keymap.set('n', '<leader>g', builtin.live_grep, {})
    '';
  };

  # ---------------------------------------------------------------------------
  # BROADCAST & CAPTURE PIPELINE (OBS Studio)
  # ---------------------------------------------------------------------------
  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      obs-vkcapture
      obs-pipewire-audio-capture
      obs-vaapi
      obs-gstreamer
    ];
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE BROWSER (Firefox)
  # ---------------------------------------------------------------------------
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";

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
      };

      ExtensionSettings = {
        "*" = {installation_mode = "allowed";};
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

    profiles.crazycat = {
      id = 0;
      isDefault = true;

      settings = {
        "gfx.webrender.all" = true;
        "gfx.webrender.compositor" = true;
        "gfx.webrender.compositor.force-enabled" = true;
        "widget.use-aspect-ratio" = true;
        "widget.dmabuf.wayland-hardware-efficient" = true;
        "media.ffmpeg.vaapi.enabled" = true;
        "media.hardware-video-decoding.enabled" = true;
        "media.av1.enabled" = true;
        "layers.acceleration.force-enabled" = true;

        "layout.frame_rate" = 0;
        "apz.overscroll.enabled" = true;
        "nglayout.initialpaint.delay" = 0;
        "browser.preferences.defaultPerformanceSettings.enabled" = false;
        "image.mem.shared" = true;

        "browser.cache.disk.enable" = true;
        "browser.cache.disk.capacity" = 1048576;
        "browser.cache.memory.enable" = true;

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
  # USER-SPACE PACKAGES
  # ---------------------------------------------------------------------------
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.fira-code
    pavucontrol
    deepfilternet
    lsp-plugins
    polkit_gnome
    docker-client
    playerctl
    overskride
    # PURGED: protonup-qt (Managed via programs.steam.extraCompatPackages)
    wineWow64Packages.staging
    winetricks
    protontricks
    grim
    slurp
    wl-clipboard
    satty
    adwaita-icon-theme
    hicolor-icon-theme
    obs-studio-plugins.obs-vkcapture
    libva-utils
    osu-lazer-bin
    ironbar
    celluloid

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
      export DXVK_HUD=0

      server_input=$(echo "" | ${pkgs.fuzzel}/bin/fuzzel -d -p "osu! DevServer (Leave blank for Bancho): ")

      if [ -n "$server_input" ]; then
        exec obs-gamecapture ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" -devserver "$server_input" "$@"
      else
        exec obs-gamecapture ${pkgs.wineWow64Packages.staging}/bin/wine "/home/crazycat/Games/osu/osu!.exe" "$@"
      fi
    '')
  ];

  services.swayosd = {
    enable = true;
    stylePath = null;
  };

  services.kanshi = {
    enable = true;
    systemdTarget = "hyprland-session.target";
    settings = [
      {
        profile = {
          name = "docked";
          outputs = [
            {
              criteria = "eDP-1";
              status = "disable";
            }
            {
              criteria = "*";
              status = "enable";
            }
          ];
        };
      }
      {
        profile = {
          name = "undocked";
          outputs = [
            {
              criteria = "eDP-1";
              status = "enable";
            }
          ];
        };
      }
    ];
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ServerAliveInterval = 30;
        ServerAliveCountMax = 3;
        TCPKeepAlive = "yes";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # XDG MIME ROUTING & THEMES
  # ---------------------------------------------------------------------------
  xdg.desktopEntries = {
    osu-stable = {
      name = "osu!stable";
      exec = "osu-launcher %U";
      icon = "osu!";
      comment = "osu! stable";
      terminal = false;
      categories = ["Game"];
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

  gtk = {
    enable = true;
    gtk4.theme = null;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  home.sessionVariables = {
    MOZ_USE_XDG = "1";
  };

  home.stateVersion = "25.11";
}
