# Applications: editor, browser, capture, audio production, chat.
{
  config,
  pkgs,
  osConfig,
  ...
}: let
  inherit (osConfig.local.hardware) backgroundCores gameCores;
  taskset = "${pkgs.util-linux}/bin/taskset";

  # One Discord build for both the profile and the launcher entry. The entry
  # used to start plain pkgs.discord, bypassing OpenASAR and Vencord.
  discord = pkgs.discord.override {
    withOpenASAR = true;
    withVencord = true;
  };

  # services.pipewire.jack.enable is deprecated (global LD_LIBRARY_PATH), so JACK
  # clients go through pw-jack instead. The .desktop entry runs a bare
  # `bitwig-studio`, so wrapping the bin also covers the launcher. yabridge
  # plugin hosts inherit the env from Bitwig.
  bitwigPwJack = pkgs.symlinkJoin {
    name = "bitwig-studio-pw-jack";
    paths = [pkgs.bitwig-studio];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      rm $out/bin/bitwig-studio
      makeWrapper ${pkgs.pipewire.jack}/bin/pw-jack $out/bin/bitwig-studio \
        --add-flags ${pkgs.bitwig-studio}/bin/bitwig-studio
    '';
  };
in {
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

    plugins = with pkgs.vimPlugins; [
      (nvim-treesitter.withPlugins (p: [
        p.bash
        p.c
        p.cpp
        p.css
        p.fish
        p.json
        p.lua
        p.markdown
        p.markdown_inline
        p.nix
        p.python
        p.rust
        p.toml
        p.vim
        p.vimdoc
        p.yaml
      ]))
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
      input-overlay
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
        "media.webspeech.synth.enabled" = false;
        "gfx.webrender.all" = true;
        "gfx.webrender.compositor" = true;
        "gfx.webrender.compositor.force-enabled" = false;
        "widget.use-aspect-ratio" = true;
        "widget.dmabuf.wayland-hardware-efficient" = true;
        "media.ffmpeg.vaapi.enabled" = true;
        "media.hardware-video-decoding.enabled" = true;
        "media.av1.enabled" = true;
        "layers.acceleration.force-enabled" = true;

        # 0 = unthrottled repaint; -1 = follow hardware vsync. Firefox holds
        # 58 MiB VRAM / 157 MiB GTT and sits in the background during play, so
        # unthrottled repaint is spending shared APU memory bandwidth on a
        # window nobody is looking at.
        "layout.frame_rate" = -1;
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
  # PACKAGES
  # ---------------------------------------------------------------------------
  home.packages = with pkgs; [
    discord
    pear-desktop
    tor-browser
    celluloid
    overskride
    blender
    en-croissant
    stockfish
    grimoire

    # Audio production
    bitwigPwJack
    yabridge
    yabridgectl
    deepfilternet
    lsp-plugins

    # Wine outside Proton
    wineWow64Packages.staging
    winetricks

    # Archive managers
    xarchiver
    file-roller
    kdePackages.ark # top-level `ark` is now the Posit R Jupyter kernel

    # Also listed in programs.obs-studio.plugins. This entry puts the
    # obs-gamecapture wrapper and the Vulkan capture layer in the profile,
    # where games can find them.
    obs-studio-plugins.obs-vkcapture
  ];

  # ---------------------------------------------------------------------------
  # LAUNCHER ENTRIES WITH CPU PINNING
  # ---------------------------------------------------------------------------
  # The session already runs on backgroundCores (cpu.nix); the explicit pin on
  # the three heaviest background apps keeps that true however they are
  # started. Steam has no entry here on purpose: games inherit Steam's
  # affinity across fork/exec, so it must never be pinned to backgroundCores.
  xdg.desktopEntries = {
    firefox = {
      name = "Firefox";
      genericName = "Web Browser";
      exec = "${taskset} -c ${backgroundCores} firefox %U";
      terminal = false;
      type = "Application";
      icon = "firefox";
    };
    "com.github.th-ch.youtube-music" = {
      name = "Pear Desktop";
      exec = "${taskset} -c ${backgroundCores} ${pkgs.pear-desktop}/bin/pear-desktop %U";
      terminal = false;
      type = "Application";
      icon = "pear-desktop";
    };
    discord = {
      name = "Discord";
      genericName = "Internet Messenger";
      exec = "${taskset} -c ${backgroundCores} ${discord}/bin/discord %U";
      terminal = false;
      type = "Application";
      icon = "discord";
    };
    grimoire = {
      name = "Grimoire";
      genericName = "Deadlock Mod Manager";
      exec = "${pkgs.grimoire}/bin/grimoire";
      icon = "grimoire";
      terminal = false;
      categories = ["Game" "Utility"];
    };
  };

  # In XDG_DATA_HOME, not desktopEntries: Flatpak's unpinned export of the same ID precedes the profile.
  xdg.dataFile."applications/org.vinegarhq.Sober.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Sober
    Exec=${taskset} -c ${gameCores} flatpak run org.vinegarhq.Sober %U
    Icon=org.vinegarhq.Sober
    Terminal=false
    Categories=Game;
    MimeType=x-scheme-handler/roblox;x-scheme-handler/roblox-player;
  '';

  home.sessionVariables.MOZ_USE_XDG = "1";
}
