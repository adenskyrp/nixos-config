# Hyprland, configured in Lua (hyprland.conf syntax is deprecated since 0.55).
#
# Every hl.config key and window-rule field used here was checked against the
# Hyprland 0.57.1 source. Keep doing that for new keys: hl.config reports an
# unknown scalar key, but an unknown key holding a list is skipped without a
# word. That is how `hl.config({ exec_once = { ... } })` and
# `hl.config({ bindm = { ... } })` both sat here dead. `hyprctl getoption
# <section>:<key>` confirms a key exists.
{
  pkgs,
  lib,
  osConfig,
  ...
}: let
  swayosd = "${pkgs.swayosd}/bin/swayosd-client";
  playerctl = "${pkgs.playerctl}/bin/playerctl";

  # ---------------------------------------------------------------------------
  # GAME WINDOW RULES
  # ---------------------------------------------------------------------------
  # Every game window gets tearing (`immediate`, wp_tearing_control_v1), no
  # animations, tiling and workspace 5. `exclusive` adds fullscreen_state
  # "2 2": client and compositor both fullscreen.
  windowRule = fields: "hl.window_rule({ ${lib.concatStringsSep ", " fields} })";
  gameRule = {
    class,
    exclusive ? true,
    extra ? [],
  }:
    windowRule (
      [''match = { class = "${class}" }'' "immediate = true" "no_anim = true"]
      ++ lib.optional exclusive ''fullscreen_state = "2 2"''
      ++ extra
      ++ ["tile = true" "workspace = 5"]
    );

  gameRules = map gameRule [
    # Rocket League (Proton winex11, DX11): same startup fullscreen/maximize
    # requests as osu!stable below, which launched it windowed. Pinned the
    # same way.
    {
      class = ''rocketleague\\.exe'';
      extra = ["fullscreen = true" ''suppress_event = "fullscreen maximize"''];
    }
    {
      class = "steam_app_252950";
      extra = ["fullscreen = true" ''suppress_event = "fullscreen maximize"''];
    }
    {class = "steam_app_default";} # non-Steam shortcuts
    {
      class = "steam_app_1422450"; # Deadlock
      extra = ["fullscreen = true"];
    }
    {class = "steam_app_980610";}
    # osu!stable (home/osu.nix -> Proton winex11, exclusive fullscreen).
    # Proton's winex11 names the X11 class steam_app_<id> from the launcher's
    # SteamAppId=0, falling back to the exe name, so one rule matches both.
    #
    # suppress_event ignores the client's own fullscreen AND maximize requests;
    # the rule already pins it at "2 2". A maximize request demotes mode 2
    # (fullscreen) to 1 (maximized), and winex11 can drop
    # _NET_WM_STATE_FULLSCREEN while it rewrites window state (its "KWin
    # hack"). Either one knocks the window out of solitary/tearing. SUPER+F (a
    # dispatcher, not a client event) still toggles it.
    {
      class = "^(steam_app_0|osu!\\\\.exe)$";
      extra = [
        ''name = "osu-stable"''
        "fullscreen = true"
        ''suppress_event = "fullscreen maximize"''
      ];
    }
    {class = "osu!";} # osu!lazer
    {
      class = ''aimlab_tb\\.exe'';
      exclusive = false;
    }
    {
      class = ''cs2\\.exe'';
      exclusive = false;
    }
    {class = "steam_app_2073850";} # THE FINALS
  ];
in {
  # xdg-desktop-portal-hyprland reads its own hyprlang file, not the Lua
  # config. Every captured frame makes Hyprland composite and copy the
  # output, and while a capture is live direct scanout and tearing are
  # blocked ("screen record/screenshot" in `hyprctl monitors`). Discord
  # streams at 60 fps at most, so the default cap of 120 only doubles that
  # cost on the game.
  xdg.configFile."hypr/xdph.conf".text = ''
    screencopy {
      max_fps = 60
    }
  '';

  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;
    configType = "lua";

    extraConfig = ''
      -- ======================================================================
      -- 1. OUTPUTS (local.hardware.monitors, set per host)
      -- ======================================================================
      ${lib.concatStringsSep "\n" osConfig.local.hardware.monitors}

      -- ======================================================================
      -- 2. DISPLAY, INPUT AND LOOK
      -- ======================================================================
      hl.config({
        xwayland = { force_zero_scaling = true },

        -- Direct scanout hands the client's buffer straight to the display
        -- controller, skipping the compositor's blend pass. An INT, not a bool
        -- (`hyprctl getoption render:direct_scanout` reports `int: 0`):
        -- 0 = off, 1 = on, 2 = auto.
        --
        -- CURRENTLY OFF. It has been switched between 0 and 1 several times,
        -- last on 2026-11-07. The case for 1, as measured on the omnibook on
        -- 2026-08-27: with the bar mapped the output pulled 8872 MB/s of DRAM
        -- reads, with the bar stopped 4230 MB/s, close to one 1920x1080x4
        -- framebuffer read per refresh (1920*1080*4*600 = 4977 MB/s). What
        -- remains is the composite pass, and scanout is the lever that
        -- removes it. 1 rather than 2 because `auto` gates on the client
        -- tagging its surface via wp_content_type_v1, and whether osu! lazer
        -- sets that hint is unverified.
        --
        -- Preconditions if it is turned on, all at once: fullscreen (the game
        -- rules set fullscreen_state = "2 2"), a single opaque surface, and NO
        -- mapped layer surface on the output, which is why SUPER+D stops the
        -- bar instead of hiding it. swayosd maps a surface while an OSD is
        -- shown, so expect a transient scanout drop on volume keys.
        render = { direct_scanout = 1 },

        -- Hardware cursors stay ON (an int: 0 = HW cursors, 1 = never,
        -- 2 = auto). A software cursor is composited INTO the frame, so the
        -- buffer handed to the display controller is no longer the client's
        -- own and direct scanout is defeated. The old claim that tearing needs
        -- software cursors rested on a log line,
        --   tearingBlockedBy: next frame is not torn, missing candidate, hw cursor
        -- that does not appear in the current log at all. It is only emitted
        -- when a tearing page-flip is attempted, so check with a fullscreen
        -- tearing client VISIBLE:
        --   grep -iE 'tearing|torn|blocked' \
        --     $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log
        -- Confirmed from the log instead: hardware cursors are in use
        --   aquamarine: drm: Cursor buffer imported into KMS with id 519/520
        -- Do not set this to 1 to chase tearing without first confirming
        -- tearing is actually blocked, and accepting the scanout loss.
        cursor = { no_hardware_cursors = 1 },

        general = {
          allow_tearing = true, -- master switch for wp_tearing_control_v1
          border_size = 1,
          gaps_in = 0,
          gaps_out = 0,
        },

        -- VFR stays at its default (on). It only governs whether an idle
        -- desktop is redrawn; forcing it off just burned power redrawing the
        -- bar.
        misc = {
          disable_hyprland_logo = true,
          disable_splash_rendering = true,
          force_default_wallpaper = 0,
          vrr = 0,
          background_color = 0x000000,
        },

        -- No rounding, shadows or blur: each one is a blend pass per frame.
        decoration = {
          rounding = 0,
          shadow = { enabled = false },
          blur = { enabled = false },
        },

        input = {
          sensitivity = 0.0,
          accel_profile = "flat", -- 1:1, no libinput acceleration curve
          touchpad = {
            disable_while_typing = false,
            natural_scroll = false,
          },
        },
      })

      -- ======================================================================
      -- 3. GAME WINDOW RULES (generated, see the top of home/hyprland.nix)
      -- ======================================================================
      ${lib.concatStringsSep "\n" gameRules}

      -- ======================================================================
      -- 4. KEYBINDINGS
      -- ======================================================================
      local mainMod = "SUPER"

      hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("${pkgs.kitty}/bin/kitty"))
      hl.bind(mainMod .. " + C", hl.dsp.window.close())
      hl.bind(mainMod .. " + M", hl.dsp.exit())
      hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
      hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
      hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd("${pkgs.fuzzel}/bin/fuzzel"))
      -- Toggles the waybar UNIT, not the process. Do NOT switch this to
      -- waybar's SIGUSR1 hide: hiding keeps the layer surface mapped, and
      -- direct scanout requires NO mapped layer surface on the output.
      -- Stopping the unit unmaps it, and the stopped state also survives
      -- graphical-session.target reloads.
      hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(
        "systemctl --user is-active --quiet waybar && systemctl --user stop waybar || systemctl --user start waybar"
      ))
      hl.bind("PRINT", hl.dsp.exec_cmd("screenshot-region"))

      for i = 1, 5 do
        hl.bind(mainMod .. " + " .. tostring(i), hl.dsp.focus({ workspace = tostring(i) }))
        hl.bind(mainMod .. " + SHIFT + " .. tostring(i), hl.dsp.window.move({ workspace = tostring(i) }))
      end

      -- The special ("magic") workspace is a scratchpad drawn ON TOP of the
      -- active workspace. Toggling it switches no workspace, so nothing under
      -- it is re-tiled or re-focused: a terminal or chat can be flashed up
      -- over a game and dismissed. toggle_special takes the BARE name; the
      -- move dispatcher takes the QUALIFIED `special:magic`, because it
      -- accepts ordinary workspaces too.
      hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("magic"))
      hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

      hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
      hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

      -- Drag to move / resize. The button is part of the key string and
      -- `{ mouse = true }` makes it a held bind, so the dispatcher runs for
      -- the whole drag. 272 = left, 273 = right (linux/input-event-codes.h).
      hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), {mouse = true})
      hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), {mouse = true})

      -- Volume, brightness (swayosd) and media keys (playerctl)
      hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("${swayosd} --output-volume +5"))
      hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("${swayosd} --output-volume -5"))
      hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("${swayosd} --brightness raise"))
      hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("${swayosd} --brightness lower"))
      hl.bind("XF86AudioMute", hl.dsp.exec_cmd("${swayosd} --output-volume mute-toggle"))
      hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("${swayosd} --input-volume mute-toggle"))
      hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("${playerctl} play-pause"))
      hl.bind("XF86AudioPause", hl.dsp.exec_cmd("${playerctl} play-pause"))
      hl.bind("XF86AudioNext", hl.dsp.exec_cmd("${playerctl} next"))
      hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("${playerctl} previous"))
    '';
  };

  # The polkit agent runs as a session service. It used to be listed under
  # `exec_once` inside hl.config, which Hyprland does not have: the agent never
  # started. Check with `systemctl --user status polkit-gnome`.
  services.polkit-gnome.enable = true;

  services.swayosd = {
    enable = true;
    stylePath = null;
  };
}
