{
  config,
  pkgs,
  lib,
  osConfig,
  ...
}: let
  gameCores = osConfig.local.hardware.gameCores;
  bgCores = osConfig.local.hardware.backgroundCores;
  luaMonitors = lib.concatStringsSep "
      " osConfig.local.hardware.monitors;
  osuFhs =
    (pkgs.steam.override {
      extraPkgs = pkgs:
        with pkgs; [
          gnutls
          cacert
          freetype
          fontconfig
          corefonts
          libpulseaudio
          alsa-lib
          alsa-plugins
        ];
      extraLibraries = pkgs:
        with pkgs; [
          freetype
          fontconfig
          libpulseaudio
          alsa-lib
          alsa-plugins
        ];
    }).run;

  osuStableLauncher = pkgs.writeShellScriptBin "osu-stable" ''
    COMPAT_DATA="$HOME/Games/osu-stable"
    PFX="$COMPAT_DATA/pfx"
    OSU_DIR="$PFX/drive_c/users/steamuser/AppData/Local/osu!"
    OSU_EXE="$OSU_DIR/osu!.exe"

    if [ ! -f "$OSU_EXE" ]; then
      echo "osu!stable Error: Could not find osu!.exe at $OSU_EXE" >&2
      exit 1
    fi

    # 1. Move stuck osu! updates out of _pending FIRST before touching auth files
    if [ -d "$OSU_DIR/_pending" ] && [ -n "$(ls -A "$OSU_DIR/_pending" 2>/dev/null)" ]; then
      cp -rf "$OSU_DIR/_pending/"* "$OSU_DIR/"
      rm -rf "$OSU_DIR/_pending"
    fi

    # Restore backup if a previous run moved osu!auth.dll away
    if [ -f "$OSU_DIR/osu!auth.dll.bancho" ] && [ ! -f "$OSU_DIR/osu!auth.dll" ]; then
      mv -f "$OSU_DIR/osu!auth.dll.bancho" "$OSU_DIR/osu!auth.dll"
    fi

    # 2. Server selection menu
    if [ -z "''${1:-}" ]; then
      SERVER=$(printf "Bancho (Official)\nakatsuki.gg\ngatari.pw\nripple.moe\ntitanic.sh" | \
      ${pkgs.fuzzel}/bin/fuzzel --dmenu --prompt="osu! server > ")

      [ -z "$SERVER" ] && exit 0
    else
      SERVER="$1"
    fi

    ARGS=()
    if [ "$SERVER" != "Bancho (Official)" ]; then
      ARGS+=("-devserver" "$SERVER")
      sed -i "s/^CredentialEndpoint[^\r]*/CredentialEndpoint = $SERVER/" "$OSU_DIR"/osu!.*.cfg 2>/dev/null || true
      export WINEDLLOVERRIDES="mscoree=n;xalia.exe=d;osu!auth.dll=d"
    else
      sed -i "s/^CredentialEndpoint[^\r]*/CredentialEndpoint =/" "$OSU_DIR"/osu!.*.cfg 2>/dev/null || true
      export WINEDLLOVERRIDES="mscoree=n;xalia.exe=d"
    fi

    # 3. Proton environment
    export STEAM_COMPAT_DATA_PATH="$COMPAT_DATA"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
    export SteamAppId="0"

    export PROTON_USE_WOW64=1
    export PROTONFIXES_DISABLE=1
    export PROTON_NO_XALIA=1
    export PROTON_FSR4_UPGRADE=0

    unset WINE_BLOCK_GET_VERSION
    sed -i '/"HideWineExports"/d' "$PFX/user.reg" "$PFX/system.reg" 2>/dev/null || true

    export SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt"
    export NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt"

    # 4. Low-latency audio & display
    export PIPEWIRE_LATENCY="128/48000"

    # Exclusive fullscreen (Fullscreen = 1) at the focused output's real mode.
    # Proton's win32u emulates display-mode changes (EmulateModeset), so osu!'s
    # fullscreen ChangeDisplaySettings never reaches XRandR/KMS; the old
    # "borderless so Wine never mode-switches" rationale does not apply.
    # Matching Width/Height AND RefreshRate to the live mode means the fshack has
    # nothing to scale and osu! asks for no mode change at all (the cfg shipped
    # RefreshRate = 60 against a 599.94 Hz panel). Wine rounds 599.94 to 600,
    # hence `round`. Falls back to 1920x1080 / untouched RefreshRate if
    # hyprctl is unreachable.
    MON_W="" MON_H="" MON_HZ=""
    read -r MON_W MON_H MON_HZ < <(
      ${config.wayland.windowManager.hyprland.finalPackage}/bin/hyprctl monitors -j 2>/dev/null |
        ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | "\(.width) \(.height) \(.refreshRate | round)"'
    ) || true
    MON_W="''${MON_W:-1920}"
    MON_H="''${MON_H:-1080}"

    # One pass over the cfg. The file is CRLF: match `[^\r]*`, not `.*`, or
    # rewritten lines lose their \r. CompatibilityContext = 0 keeps osu! on native
    # OpenGL (radeonsi) instead of the ANGLE -> D3D9 -> DXVK path.
    SED_ARGS=(
      -e 's/^CompatibilityContext\s*=[^\r]*/CompatibilityContext = 0/'
      -e 's/^Fullscreen\s*=[^\r]*/Fullscreen = 1/'
      -e "s/^Width\s*=[^\r]*/Width = $MON_W/"
      -e "s/^Height\s*=[^\r]*/Height = $MON_H/"
      -e "s/^WidthFullscreen\s*=[^\r]*/WidthFullscreen = $MON_W/"
      -e "s/^HeightFullscreen\s*=[^\r]*/HeightFullscreen = $MON_H/"
      -e 's/^Letterboxing\s*=[^\r]*/Letterboxing = 0/'
    )
    [ -n "$MON_HZ" ] && SED_ARGS+=(-e "s/^RefreshRate\s*=[^\r]*/RefreshRate = $MON_HZ/")
    sed -i -E "''${SED_ARGS[@]}" "$OSU_DIR"/osu!.*.cfg 2>/dev/null || true

    if [ -f "$COMPAT_DATA/dotnet-backup/mscoree32.dll" ]; then
      cp -f "$COMPAT_DATA/dotnet-backup/mscoree64.dll" "$PFX/drive_c/windows/system32/mscoree.dll"
      cp -f "$COMPAT_DATA/dotnet-backup/mscoree32.dll" "$PFX/drive_c/windows/syswow64/mscoree.dll"
    fi

    cd "$OSU_DIR" || exit 1

    exec ${pkgs.util-linux}/bin/taskset -c ${gameCores} \
      ${osuFhs}/bin/steam-run bash -c '
      "${pkgs.proton-cachyos-slr}/proton" waitforexitandrun "$@"
      WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx" "${pkgs.proton-cachyos-slr}/files/bin/wineserver" -w
      ' -- "$OSU_EXE" "''${ARGS[@]}"
  '';
in {
  # ---------------------------------------------------------------------------
  # HYPRLAND: NATIVE LUA COMPOSITOR CONFIGURATION
  # ---------------------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;

    # Compiles extraConfig directly into ~/.config/hypr/hyprland.lua in the Nix store
    configType = "lua";

    extraConfig = ''
           -- ======================================================================
           -- 1. DISPLAY ENGINE & SCANOUT PIPELINE
           -- ======================================================================
      ${luaMonitors}
           hl.config({
             autogenerated = 0,
      xwayland = {
              force_zero_scaling = true,
             },
             -- Deterministic Hardware Binding:
             -- The output is DP-1, confirmed by `hyprctl monitors`. This rule named
             -- DP-2 until 2026-08-27 and was therefore dead. Note DP-2 is not a
             -- typo for a nonexistent connector -- it genuinely exists in the DRM
             -- topology, because the panel hangs off a DisplayPort MST hub and the
             -- adapter exposes a second branch. The log shows it as
             --   drm: connector DP-2, has crtc -1, will be rechecked
             -- i.e. present but with no CRTC assigned, so no monitor rule for it can
             -- ever apply. A dead rule that names a real connector is worse than one
             -- naming a fake, since grepping for the name finds it and the rule looks
             -- live.
             --
             -- kanshi is the authority for mode setting (it matches on the EDID
             -- string, which survives connector renumbering across MST re-enumeration
             -- in a way DP-N does not). This rule is a deliberate fallback so
             -- Hyprland comes up at the right mode before kanshi's profile lands --
             -- with the rule dead, startup did eDP-1@60 -> DP-1@60 -> DP-1@599.94,
             -- i.e. an extra modeset that kanshi had to correct. The duplication is
             -- intentional, not drift.
             --
             -- eDP-1 is explicitly disabled when docked to free APU display engine
             -- bandwidth.
             -- Direct scanout hands the client's buffer straight to the display
             -- controller, skipping the compositor's blend pass entirely. Measured
             -- 2026-08-27: with ironbar mapped this output was pulling 8872 MB/s DRAM
             -- reads; killing ironbar dropped it to 4230 MB/s, which is close to one
             -- 1920x1080x4 framebuffer read per refresh (1920*1080*4*600 = 4977 MB/s)
             -- -- i.e. what remains is the composite pass itself. Scanout is the lever
             -- that removes that, on a bus the APU shares with the CPU.
             --
             -- This is an INT, not a bool (`hyprctl getoption render:direct_scanout`
             -- reports `int: 0`): 0 = off, 1 = on, 2 = auto. Writing `true` here would
             -- be a type error or a silent coercion.
             --
             -- 1 rather than 2 deliberately. `auto` gates on the client tagging its
             -- surface via wp_content_type_v1 (Hyprland 0.56.2 does implement the
             -- protocol), and whether osu! lazer sets that hint is unverified -- so 2
             -- risks being a silent no-op, which is the failure mode this repo keeps
             -- getting bitten by. 1 attempts scanout for any eligible fullscreen
             -- surface and is unambiguous.
             --
             -- Preconditions, all of which must hold simultaneously: fullscreen (the
             -- osu! window rules set fullscreen_state = "2 2"), a single opaque
             -- surface, and NO mapped layer surface on the output -- which is why
             -- the bar (waybar) has to be stopped, not merely hidden. swayosd-server maps a
             -- surface when a volume/brightness OSD appears, so expect a transient
             -- scanout drop on those keypresses; that is acceptable and not worth
             -- fixing.
             render = {
               direct_scanout = 0,
             },

             -- HARDWARE CURSORS ARE KEPT ON, AND THIS CONFLICTS WITH TEARING. Read
             -- before changing either this or render.direct_scanout above.
             --
             -- The comment that stood here until 2026-08-27 argued at length that
             -- software cursors were required for wp_tearing_control_v1 to engage,
             -- citing a runtime log line:
             --   tearingBlockedBy: next frame is not torn, missing candidate, hw cursor
             -- That line does not appear anywhere in the current Hyprland log, at any
             -- point, including with osu! running. It is unverified, so the reasoning
             -- is recorded as a claim rather than as fact. `tearingBlockedBy` is only
             -- emitted when a tearing page-flip is actually attempted, so the check
             -- has to be run with a fullscreen tearing client VISIBLE on DP-1:
             --   grep -iE 'tearing|torn|blocked' \
             --     $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log
             --
             -- What IS confirmed from the log is that hardware cursors win today:
             --   aquamarine: drm: Cursor buffer imported into KMS with id 519/520
             --
             -- The two goals pull in opposite directions, and that is the real reason
             -- to leave this alone. A software cursor is composited INTO the frame,
             -- which means the surface handed to the display controller is no longer
             -- the client's unmodified buffer -- so software cursors DEFEAT direct
             -- scanout. Scanout is worth ~4.2 GB/s of measured shared bandwidth;
             -- tearing is worth up to one frame of latency at 1.67 ms and is
             -- currently unverified. Keeping the hardware cursor plane (2 = auto,
             -- which resolves to HW here) buys the measured win over the speculative
             -- one. Do not flip this to 1 to chase tearing without first confirming
             -- tearing is actually blocked, and accepting the scanout loss.
             cursor = {
               -- Renamed upstream: the key is `no_hardware_cursors` on Hyprland 0.56,
               -- and it is an int (0 = HW cursors, 1 = never, 2 = auto), not a bool.
               no_hardware_cursors = 0,
             },

             -- Master switch for wp_tearing_control_v1 protocol negotiation
             general = {
               allow_tearing = true,
               border_size = 1,
               gaps_in = 0,
               gaps_out = 0,
             },

             -- VFR left at its default (enabled). It governs whether Hyprland skips
             -- redrawing an idle *desktop*, not how the game's frames reach the
             -- display -- once direct scanout takes over the fullscreen surface,
             -- in-game latency comes from the tearing/immediate/scanout trio above.
             -- Forcing it off only burned shared-TDP headroom redrawing the bar.

             misc = {
               disable_hyprland_logo = true,
               disable_splash_rendering = true,
               force_default_wallpaper = 0,
               vrr = 0,
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
               accel_profile = "flat", -- 1:1 raw bypass; eliminates libinput software curves
               touchpad = {
                 disable_while_typing = false,
                 natural_scroll = false,
               },
             },
           })

           -- ======================================================================
           -- 3. ASYNCHRONOUS TEARING & WORKSPACE RULES (NATIVE LUA TABLE API)
           -- ======================================================================
           -- Bypasses deprecated windowrulev2 string parsers. Tables are compiled
           -- directly into internal CWindowRule structs by the Hyprland Lua engine.

           -- Rocket League (DX11 / Proton Swapchain)
           hl.window_rule({
             match = { class = "rocketleague\\.exe" },
             immediate = true,          -- Triggers wp_tearing_control_v1 async scanout
             no_anim = true,           -- snake_case per Hyprland Lua API (not "noanim")
             fullscreen_state = "2 2",  -- Forces client + compositor exclusive fullscreen
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "steam_app_252950" },
             immediate = true,
             no_anim = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "steam_app_default" },
             immediate = true,
             no_anim = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "steam_app_1422450" },
             immediate = true,
             no_anim = true,
             fullscreen = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "steam_app_980610" },
             immediate = true,
             no_anim = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })
           -- osu!stable (osuStableLauncher -> Proton winex11, exclusive fullscreen).
           -- Proton's winex11 names the X11 class steam_app_<id> from the
           -- launcher's SteamAppId=0, falling back to the exe name, so one rule
           -- matches both instead of two diverging copies.
           hl.window_rule({
             name = "osu-stable",
             match = { class = "^(steam_app_0|osu!\\.exe)$" },
             immediate = true,
             no_anim = true,
             fullscreen = true,
             fullscreen_state = "2 2",
             -- Ignore the client's own fullscreen AND maximize requests; this rule
             -- already pins it at "2 2". A maximize request demotes mode 2
             -- (fullscreen) to 1 (maximized), and winex11 can drop
             -- _NET_WM_STATE_FULLSCREEN while it rewrites window state (its "KWin
             -- hack"). Either one knocks the window out of solitary/tearing.
             -- Space-separated list per the v3 rule syntax. SUPER+F (a dispatcher,
             -- not a client event) still toggles it.
             suppress_event = "fullscreen maximize",
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "osu!" },
             immediate = true,
             no_anim = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })

           -- Counter-Strike 2 & Aim Lab
           hl.window_rule({
             match = { class = "aimlab_tb\\.exe" },
             immediate = true,
             no_anim = true,
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "cs2\\.exe" },
             immediate = true,
             no_anim = true,
             tile = true,
             workspace = 5,
           })
           hl.window_rule({
             match = { class = "steam_app_2073850" },
             immediate = true,
             no_anim = true,
             fullscreen_state = "2 2",
             tile = true,
             workspace = 5,
           })
           -- ======================================================================
           -- 4. STARTUP PROCESSES & SYSTEM HOOKS (EXEC-ONCE)
           -- ======================================================================
           -- `exec` (as opposed to `exec_once`) fires on EVERY Hyprland config
           -- reload, and it used to carry "systemctl --user restart kanshi". A kanshi
           -- restart re-applies the output profile, which can trigger a modeset --
           -- and a modeset at 599.94 Hz across a DisplayPort MST link is a
           -- multi-second black-and-recover, which matches the reported symptom
           -- ("dropping to really low FPS for a short amount of time, similar to
           -- unplugging it from the wall and plugging it back in") closely enough to
           -- be a prime suspect for the drops themselves.
           --
           -- It was redundant as well as harmful: services.kanshi.systemdTarget is
           -- set to hyprland-session.target, so the unit already starts with the
           -- session and needs no help from here.
           hl.config({
             exec_once = {
               "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1",
             },
           })

           -- ======================================================================
           -- 5. NATIVE LUA KEYBINDINGS (C++ DISPATCHER INTERFACE)
           -- ======================================================================
           local mainMod = "SUPER"

           -- Core Dispatchers
           hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("${pkgs.kitty}/bin/kitty"))
           hl.bind(mainMod .. " + C", hl.dsp.window.close())
           hl.bind(mainMod .. " + M", hl.dsp.exit())
           hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
           hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
           hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd("${pkgs.fuzzel}/bin/fuzzel"))
           -- Toggles the waybar UNIT, not the process. Do NOT switch this to
           -- waybar's SIGUSR1 hide: hiding keeps the layer surface mapped, and
           -- render.direct_scanout above requires NO mapped layer surface on the
           -- output. Stopping the unit unmaps it, and the stopped state also
           -- survives graphical-session.target reloads.
           hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(
             "systemctl --user is-active --quiet waybar && systemctl --user stop waybar || systemctl --user start waybar"
           ))
           -- Screenshot lived on SUPER + SHIFT + S until 2026-08-30. It moved here to
           -- free that chord for the special-workspace move below, which is where
           -- upstream's own bundled example config puts it. PRINT was unbound, and is
           -- the obvious home for a screenshot key anyway.
           hl.bind("PRINT", hl.dsp.exec_cmd("screenshot-region"))

           -- Workspaces 1-5 Dispatcher Mapping
           for i = 1, 5 do
             hl.bind(mainMod .. " + " .. tostring(i), hl.dsp.focus({ workspace = tostring(i) }))
             hl.bind(mainMod .. " + SHIFT + " .. tostring(i), hl.dsp.window.move({ workspace = tostring(i) }))
           end

           -- Special ("magic") Workspace -- the scratchpad overlay
           --
           -- A special workspace is not one of the numbered ones. It renders as an
           -- overlay ON TOP of whichever workspace is currently active, and toggling
           -- it away leaves that underlying workspace focused and untouched -- no
           -- workspace switch, so nothing below it gets re-tiled or re-focused. That
           -- is what makes it usable mid-game: flash up a terminal or a chat window
           -- over Rocket League and dismiss it without the game's workspace ever
           -- changing under it.
           --
           -- "magic" is just the workspace's name -- any string works. The only
           -- requirement is that the two binds agree, and note they spell it
           -- differently on purpose: toggle_special takes the BARE name, while the
           -- window-move dispatcher takes the QUALIFIED `special:magic`, because it
           -- accepts ordinary workspaces too and needs the prefix to disambiguate.
           --
           -- These are the native Lua dispatchers, matching upstream's bundled
           -- example config for 0.56.2. The `togglespecialworkspace` / `movetoworkspace`
           -- spellings in the Hyprland wiki are hyprland.conf syntax and do not apply
           -- to this file -- see the mouse binds below for what happens when
           -- hyprland.conf syntax is pasted into a Lua config.
           hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("magic"))
           hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

           -- Scroll Wheel Workspace Switching
           hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
           hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

           -- ======================================================================
           -- MOUSE WINDOW OPERATIONS
           -- ======================================================================
           -- These two were previously written as
           --     hl.config({ bindm = { "SUPER, mouse:272, movewindow", ... } })
           -- which was DEAD CONFIG. `bindm` is an hyprland.conf keyword, not a Lua
           -- config variable, and hl.config() drops keys it does not recognise
           -- without warning -- nothing appeared in the log, so it looked live. It
           -- was not: `hyprctl binds` listed thirty binds and not one mouse bind, and
           -- SUPER + drag had silently done nothing since the Lua migration.
           --
           -- The Lua form takes the button as part of the key string and needs
           -- `{ mouse = true }` to register as a held bind rather than a press. Held
           -- is the whole point here: the dispatcher runs for the duration of the
           -- drag and ends on button release, which is what makes drag-to-move and
           -- drag-to-resize continuous instead of one-shot.
           --
           -- 272 is left button, 273 is right (BTN_LEFT / BTN_RIGHT, linux/input-event-codes.h).
           -- window.drag / window.resize are the Lua names for what hyprland.conf
           -- calls movewindow / resizewindow.
           hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), {mouse = true})
           hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), {mouse = true})

           -- SwayOSD Audio & Brightness Integration
           hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --output-volume +5"))
           hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --output-volume -5"))
           hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --brightness raise"))
           hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --brightness lower"))

           -- Playerctl Media Controls
           hl.bind("XF86AudioMute", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle"))
           hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("${pkgs.swayosd}/bin/swayosd-client --input-volume mute-toggle"))
           hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("${pkgs.playerctl}/bin/playerctl play-pause"))
           hl.bind("XF86AudioPause", hl.dsp.exec_cmd("${pkgs.playerctl}/bin/playerctl play-pause"))
           hl.bind("XF86AudioNext", hl.dsp.exec_cmd("${pkgs.playerctl}/bin/playerctl next"))
           hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("${pkgs.playerctl}/bin/playerctl previous"))
    '';
  };

  # ---------------------------------------------------------------------------
  # INTERACTIVE SHELL & REBUILD PIPELINE
  # ---------------------------------------------------------------------------
  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
  };
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

        set -l target_host (hostname)
        echo "--> Initiating declarative system rebuild for host: $target_host..."
        if sudo nixos-rebuild switch --no-write-lock-file --flake .#$target_host
          set -l commit_msg "$argv"
          if test -z "$commit_msg"
            set commit_msg "chore($target_host): automated system state update"
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
  # STATUS BAR (Waybar, GTK3 layer-shell)
  # ---------------------------------------------------------------------------
  # Replaced ironbar 0.19.1 on 2026-11-07. Hyprland 0.57 sends workspace
  # events as `createworkspacev2>>ADDRESS,NAME` where ADDRESS is the
  # addressable name (src/workspace/HLWorkspace.cpp:100) -- "special:magic" for
  # the scratchpad -- and `hyprctl workspaces -j` no longer gives special
  # workspaces an "id". ironbar's hyprland-rs parses that field as an integer,
  # logged `Failed to start listener: WorkspaceAddedV2: invalid integer error`,
  # and its event listener died for the rest of the session: workspace buttons
  # froze, and relaunching started from a broken snapshot. Waybar 0.15
  # (modules/hyprland/workspaces.cpp parseWorkspaceId) wraps the parse in
  # try/catch and skips non-numeric workspaces, and hides specials by default.
  #
  # GTK3 renders with Cairo only, so the bar never opens a Vulkan device (the
  # reason ironbar needed GSK_RENDERER=cairo).
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
        on-scroll-up = "${pkgs.swayosd}/bin/swayosd-client --output-volume +2";
        on-scroll-down = "${pkgs.swayosd}/bin/swayosd-client --output-volume -2";
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
    # DRAM reads 8872 -> 4230 MB/s, GPU power 19 -> 13 W. Stopping the unit
    # (SUPER+D) is what frees direct scanout entirely. Child elements keep
    # their alpha: they blend inside GTK against the opaque root.
    style = ''
      * {
        font-family: "FiraCode Nerd Font", monospace;
        font-size: 13px;
        border: none;
        border-radius: 0;
        box-shadow: none;
        text-shadow: none;
        min-height: 0;
        transition: none;
      }

      window#waybar {
        background-color: rgb(40, 44, 52);
        color: #abb2bf;
        border-bottom: 1px solid rgb(56, 60, 70);
      }

      #workspaces {
        background-color: rgba(30, 34, 42, 0.7);
        border: 1px solid rgba(255, 255, 255, 0.05);
        border-radius: 6px;
        padding: 2px;
        margin: 2px 8px 2px 6px;
      }

      #workspaces button {
        background: transparent;
        color: #abb2bf;
        padding: 2px 10px;
        border-radius: 4px;
        font-weight: 500;
      }

      #workspaces button:hover {
        background: rgba(255, 255, 255, 0.12);
        color: #ffffff;
      }

      #workspaces button.active {
        background-color: #ffffff;
        color: #1e222a;
        font-weight: 700;
      }

      #workspaces button.urgent {
        background-color: #e06c75;
        color: #1e222a;
        font-weight: bold;
      }

      .modules-right {
        background-color: rgba(30, 34, 42, 0.7);
        border: 1px solid rgba(255, 255, 255, 0.05);
        border-radius: 6px;
        padding: 2px 4px;
        margin: 2px 6px 2px 0;
      }

      #pulseaudio, #tray, #clock {
        background: transparent;
        color: #ffffff;
        padding: 2px 8px;
      }

      #tray {
        padding: 2px 4px;
      }
    '';
  };

  systemd.user.services.waybar.Service.CPUAffinity = bgCores;

  # Mic filter chain. No preset is forced: EasyEffects restores the last-used
  # input chain from ~/.config/easyeffects/db on start.
  services.easyeffects.enable = true;

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
      ripgrep
      fd
    ];

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
  # USER-SPACE PACKAGES & LOW-LATENCY HELPERS
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
    celluloid
    claude-code
    tor-browser
    p7zip
    xarchiver
    unzip
    file-roller
    unrar
    zip
    ark
    scrcpy
    android-tools
    pear-desktop
    blender
    en-croissant
    stockfish
    grimoire
    bitwig-studio
    yabridge
    yabridgectl
    aria2
    osuStableLauncher
    (discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    google-cloud-sdk
    (writeShellApplication {
      name = "update-proton-cachyos";
      runtimeInputs = [curl jq nix];
      text = ''
         set -euo pipefail

         # Point directly to the new modules folder
         CONFIG_DIR="/home/crazycat/nixos-config"
         JSON_FILE="$CONFIG_DIR/modules/proton-cachyos.json"

         echo "Fetching latest Proton-CachyOS release metadata..."
         RELEASE_JSON=$(curl -sSL "https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest")
         VERSION=$(echo "$RELEASE_JSON" | jq -r .tag_name)

         # Ensure we specifically grab the x86_64_v3 SLR package
        ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | test("slr-x86_64_v3\\.tar\\.xz$")) | .browser_download_url')

         if [ -f "$JSON_FILE" ]; then
           CURRENT_VERSION=$(jq -r .version "$JSON_FILE")
           if [ "$CURRENT_VERSION" = "$VERSION" ]; then
             echo "Already up-to-date: $VERSION"
             exit 0
           fi
         fi

         echo "New version found: $VERSION"
         echo "Prefetching SRI hash..."
         HASH=$(nix store prefetch-file "$ASSET_URL" --json | jq -r .hash)

         jq -n \
           --arg version "$VERSION" \
           --arg url "$ASSET_URL" \
           --arg hash "$HASH" \
           '{version: $version, url: $url, hash: $hash}' > "$JSON_FILE"

         echo "Updated $JSON_FILE to $VERSION ($HASH)"
      '';
    })

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

  services.swayosd = {
    enable = true;
    stylePath = null;
  };

  # ---------------------------------------------------------------------------
  # DYNAMIC OUTPUT MANAGEMENT (Kanshi Daemon)
  # ---------------------------------------------------------------------------
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
              criteria = "BNQ XL2586X+ EB3CR02979SL0";
              mode = "1920x1080@599.94Hz";
              position = "0,0";
              scale = 1.0;
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
              mode = "2240x1400@60.00Hz";
              position = "0,0";
              scale = 1.0;
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

  xdg.desktopEntries = {
    firefox = {
      name = "Firefox";
      genericName = "Web Browser";
      exec = "${pkgs.coreutils}/bin/nice -n 0 ${pkgs.util-linux}/bin/taskset -c ${bgCores} firefox %U";
      terminal = false;
      type = "Application";
      icon = "firefox";
    };
    "com.github.th-ch.youtube-music" = {
      name = "Pear Desktop";
      exec = "${pkgs.coreutils}/bin/nice -n 0 ${pkgs.util-linux}/bin/taskset -c ${bgCores} ${pkgs.pear-desktop}/bin/pear-desktop %U";
      terminal = false;
      type = "Application";
      icon = "pear-desktop";
    };
    "discord" = {
      name = "Discord";
      genericName = "Internet Messenger";
      exec = "${pkgs.util-linux}/bin/taskset -c ${bgCores} ${pkgs.discord}/bin/discord %U";
      terminal = false;
      type = "Application";
      icon = "discord";
    };
    steam = {
      name = "Steam";
      genericName = "Application Store";
      # Do NOT wrap Steam in taskset -c bgCores: child game processes inherit
      # Steam's CPU affinity mask across fork/exec!
      exec = "steam %U";
      terminal = false;
      type = "Application";
      icon = "steam";
    };
    "osu!" = {
      name = "osu!";
      exec = "${pkgs.util-linux}/bin/taskset -c ${gameCores} osu! %U";
      terminal = false;
      type = "Application";
      icon = "osu";
      categories = ["Game"];
    };
    "org.vinegarhq.Sober" = {
      name = "Sober";
      exec = "${pkgs.util-linux}/bin/taskset -c ${gameCores} flatpak run org.vinegarhq.Sober %U";
      icon = "org.vinegarhq.Sober";
      terminal = false;
      categories = ["Game"];
      mimeType = ["x-scheme-handler/roblox" "x-scheme-handler/roblox-player"];
    };
    "grimoire" = {
      name = "Grimoire";
      genericName = "Deadlock Mod Manager";
      exec = "${pkgs.grimoire}/bin/grimoire";
      icon = "grimoire";
      terminal = false;
      categories = ["Game" "Utility"];
    };
    "osu-stable" = {
      name = "osu! (Stable)";
      comment = "Launch osu!stable via Proton";
      exec = "${osuStableLauncher}/bin/osu-stable";
      icon = "osu";
      terminal = false;
      categories = ["Game"];
    };
  };

  # ---------------------------------------------------------------------------
  # XDG MIME ROUTING & THEMES
  # ---------------------------------------------------------------------------

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
