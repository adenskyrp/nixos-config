# What the desktop looks like: bar, launcher, terminal, GTK, cursor, fonts.
# All colours come from theme.nix.
{pkgs, ...}: let
  theme = import ./theme.nix;
  swayosd = "${pkgs.swayosd}/bin/swayosd-client";
in {
  # ---------------------------------------------------------------------------
  # FONTS, GTK, CURSOR
  # ---------------------------------------------------------------------------
  fonts.fontconfig.enable = true;

  gtk = {
    enable = true;
    # Dark for GTK 3 (theme below) and for GTK 4 / libadwaita apps, which
    # ignore gtk-theme-name and follow the colour-scheme preference instead.
    colorScheme = "dark";
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

  # One pointer theme and size for GTK, XWayland and the compositor, instead of
  # each falling back to its own. Hyprland loads the "default" XCursor theme,
  # which the ~/.icons/default/index.theme written here points at Adwaita.
  home.pointerCursor = {
    enable = true;
    name = "Adwaita";
    package = pkgs.adwaita-icon-theme;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  home.packages = with pkgs; [
    nerd-fonts.fira-code
    hicolor-icon-theme
    playerctl
    grim
    slurp
    wl-clipboard
    satty

    (writeShellScriptBin "screenshot-region" ''
      SCREENSHOT_DIR="$HOME/Pictures/Screenshots"
      mkdir -p "$SCREENSHOT_DIR"
      FILENAME="$SCREENSHOT_DIR/$(date +'%Y-%m-%d_%H-%M-%S').png"

      ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | tee "$FILENAME" | ${pkgs.wl-clipboard}/bin/wl-copy
      if command -v notify-send &> /dev/null; then
        notify-send "Screenshot Captured" "Saved to $FILENAME and copied to clipboard." --icon=camera
      fi
    '')
  ];

  # ---------------------------------------------------------------------------
  # TERMINAL (kitty)
  # ---------------------------------------------------------------------------
  programs.kitty = {
    enable = true;
    font = {
      name = theme.font;
      size = 11;
    };
    settings =
      {
        window_padding_width = 6;
        background = "#${theme.bg}";
        foreground = "#${theme.fg}";
        cursor = "#${theme.fg}";
        cursor_text_color = "#${theme.bg}";
        selection_background = "#${theme.selection}";
        selection_foreground = "#${theme.fgBright}";
        url_color = "#${theme.blue}";
      }
      // builtins.listToAttrs (
        builtins.genList (i: {
          name = "color${toString i}";
          value = "#${builtins.elemAt theme.ansi i}";
        })
        16
      );
  };

  # ---------------------------------------------------------------------------
  # LAUNCHER (fuzzel)
  # ---------------------------------------------------------------------------
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        font = "${theme.font}:size=13";
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
        background = "${theme.bg}f2";
        text = "${theme.fg}ff";
        match = "${theme.blue}ff";
        selection = "${theme.selection}ff";
        selection-text = "${theme.fgBright}ff";
        border = "${theme.border}ff";
      };
      border = {
        width = 2;
        radius = 8;
      };
    };
  };

  # ---------------------------------------------------------------------------
  # STATUS BAR (Waybar, GTK3 layer-shell)
  # ---------------------------------------------------------------------------
  # Replaced ironbar 0.19.1 on 2026-11-07. Hyprland 0.57 sends workspace
  # events as `createworkspacev2>>ADDRESS,NAME` where ADDRESS is the
  # addressable name (src/workspace/HLWorkspace.cpp:100) -- "special:magic" for
  # the scratchpad -- and `hyprctl workspaces -j` no longer gives special
  # workspaces an "id". ironbar's hyprland-rs parses that field as an integer,
  # logged `Failed to start listener: WorkspaceAddedV2: invalid integer error`,
  # and its event listener died for the rest of the session. Waybar 0.15
  # (modules/hyprland/workspaces.cpp parseWorkspaceId) wraps the parse in
  # try/catch and skips non-numeric workspaces, and hides specials by default.
  #
  # GTK3 renders with Cairo only, so the bar never opens a Vulkan device.
  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 32;
      spacing = 0;
      modules-left = ["hyprland/workspaces"];
      modules-right = ["pulseaudio" "tray" "clock"];

      "hyprland/workspaces" = {
        format = "{name}";
        all-outputs = false;
        show-special = false;
        sort-by-number = true;
      };

      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "󰝟 {volume}%";
        format-icons.default = ["󰕿" "󰖀" "󰕾"];
        max-volume = 100;
        on-scroll-up = "${swayosd} --output-volume +2";
        on-scroll-down = "${swayosd} --output-volume -2";
        tooltip = false;
      };

      tray = {
        icon-size = 16;
        spacing = 6;
      };

      clock = {
        format = "{:%H:%M}";
        interval = 60;
        tooltip = false;
      };
    };

    # The root surface is opaque and square ON PURPOSE -- compositing cost, not
    # looks. An opaque rectangular layer surface lets the compositor take its
    # opaque-region shortcut and skip the blend pass; alpha, rounded corners
    # and hover transitions all defeat it, and at 599.94 Hz that cost is paid
    # 600x a second. Measured 2026-08-27 (omnibook), bar mapped vs stopped:
    # DRAM reads 8872 -> 4230 MB/s, GPU power 19 -> 13 W. Child elements keep
    # their alpha: they blend inside GTK against the opaque root.
    style = ''
      @define-color bg #${theme.bg};
      @define-color bg_dark #${theme.bgDark};
      @define-color border #${theme.border};
      @define-color fg #${theme.fg};
      @define-color fg_bright #${theme.fgBright};
      @define-color urgent #${theme.red};

      * {
        font-family: "${theme.font}", monospace;
        font-size: 13px;
        border: none;
        border-radius: 0;
        box-shadow: none;
        text-shadow: none;
        min-height: 0;
        transition: none;
      }

      window#waybar {
        background-color: @bg;
        color: @fg;
        border-bottom: 1px solid @border;
      }

      #workspaces,
      .modules-right {
        background-color: alpha(@bg_dark, 0.7);
        border: 1px solid alpha(@fg_bright, 0.05);
        border-radius: 6px;
      }

      #workspaces {
        padding: 2px;
        margin: 2px 8px 2px 6px;
      }

      .modules-right {
        padding: 2px 4px;
        margin: 2px 6px 2px 0;
      }

      #workspaces button {
        background: transparent;
        color: @fg;
        padding: 2px 10px;
        border-radius: 4px;
        font-weight: 500;
      }

      #workspaces button:hover {
        background: alpha(@fg_bright, 0.12);
        color: @fg_bright;
      }

      #workspaces button.active {
        background-color: @fg_bright;
        color: @bg_dark;
        font-weight: 700;
      }

      #workspaces button.urgent {
        background-color: @urgent;
        color: @bg_dark;
        font-weight: bold;
      }

      #pulseaudio,
      #tray,
      #clock {
        background: transparent;
        color: @fg_bright;
        padding: 2px 8px;
      }

      #tray {
        padding: 2px 4px;
      }
    '';
  };
}
