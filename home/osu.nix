# osu!: lazer (native) and stable (Proton), both pinned to the game cores.
{
  config,
  pkgs,
  osConfig,
  ...
}: let
  inherit (osConfig.local.hardware) gameCores;

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
      # pipewire: osu! runs as an i386-unix (old WoW64) process, so Proton's
      # winepipewire.drv needs a 32-bit libpipewire-0.3.so.0. Without it mmdevapi
      # falls back to winealsa -> pipewire-alsa plugin, which ignores
      # PIPEWIRE_LATENCY and runs at Wine's fixed 10 ms WASAPI period
      # (pw-top showed alsa_playback.osu! at 441/44100).
      extraLibraries = pkgs:
        with pkgs; [
          freetype
          fontconfig
          libpulseaudio
          alsa-lib
          alsa-plugins
          pipewire
        ];
    }).run;

  # osu!lazer is native (BASS -> libasound -> pipewire-alsa), so PIPEWIRE_LATENCY
  # does nothing; osu-framework asks BASS for a 10 ms buffer at 44.1 kHz (pw-top:
  # alsa_playback.osu! 441/44100, resampled to the 48 kHz graph). PIPEWIRE_ALSA
  # constrains the plugin's hw params instead: 48 kHz, <=256-frame buffer in
  # 128-frame periods (F32 stereo = 8 B/frame). Measured 128/48000, ERR 0 on the
  # desktop ALC897 (2026-11-08). If it crackles, raise buffer-bytes to 4096.
  osuLazer = pkgs.symlinkJoin {
    name = "osu-lazer-bin-lowlatency";
    paths = [pkgs.osu-lazer-bin];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/osu!" \
        --set PIPEWIRE_ALSA '{ alsa.rate=48000 alsa.buffer-bytes=2048 alsa.period-bytes=1024 }'
    '';
  };

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
    else
      sed -i "s/^CredentialEndpoint[^\r]*/CredentialEndpoint =/" "$OSU_DIR"/osu!.*.cfg 2>/dev/null || true
    fi
    # osu!auth.dll stays enabled on private servers too: with it disabled (=d) osu!
    # has no anticheat result to send and shows the "test signing" no-submit warning.
    export WINEDLLOVERRIDES="mscoree=n;xalia.exe=d"

    # 3. Proton environment
    export STEAM_COMPAT_DATA_PATH="$COMPAT_DATA"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
    export SteamAppId="0"

    # Old (i386-unix) WoW64, not new WoW64: since the 2026-08-31 update osu!auth.dll
    # makes native Linux `int $0x80` syscalls from 32-bit code. In a new-WoW64
    # (64-bit) process Wine's Syscall User Dispatch traps and misdispatches them,
    # osu!auth's Linux detection fails, and it reports "disable test signing to
    # submit scores". A true i386 process doesn't use SUD, so the syscalls hit the kernel.
    export PROTON_USE_WOW64=0
    export PROTONFIXES_DISABLE=1
    export PROTON_NO_XALIA=1
    export PROTON_FSR4_UPGRADE=0

    unset WINE_BLOCK_GET_VERSION
    sed -i '/"HideWineExports"/d' "$PFX/user.reg" "$PFX/system.reg" 2>/dev/null || true

    # GrabPointer=N for osu!.exe only. Without it the main thread spins forever
    # at startup (3M+ set_cursor server calls in 35 s, window frozen): osu! calls
    # ClipCursor(NULL), win32u's single-monitor fullscreen auto-clip re-clips
    # (SET_CURSOR_CLIP|FSCLIP), osu! releases again, and so on. Side effect: osu!'s
    # ConfineMouse does nothing, which doesn't matter for a fullscreen window on one monitor.
    if ! grep -qF '[Software\\Wine\\AppDefaults\\osu!.exe\\X11 Driver]' "$PFX/user.reg" 2>/dev/null; then
      printf '\n[Software\\\\Wine\\\\AppDefaults\\\\osu!.exe\\\\X11 Driver]\n"GrabPointer"="N"\n' >> "$PFX/user.reg"
    fi

    export SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt"
    export NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt"

    # 4. Low-latency audio & display
    # Only honoured on the winepipewire path (see osuFhs). Verify with `pw-top`
    # during play: osu! should be a native stream at 128/48000, not
    # alsa_playback.osu! at 441/44100.
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
    # OpenGL instead of the ANGLE -> D3D9 -> DXVK path.
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
  home.packages = [
    osuLazer
    osuStableLauncher
  ];

  xdg.desktopEntries = {
    "osu!" = {
      name = "osu!";
      exec = "${pkgs.util-linux}/bin/taskset -c ${gameCores} ${osuLazer}/bin/osu! %U";
      terminal = false;
      type = "Application";
      icon = "osu";
      categories = ["Game"];
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
}
