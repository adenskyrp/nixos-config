{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # CCX PINNING WRAPPERS (STEAM LAUNCH-OPTION PREFIXES)
  # ---------------------------------------------------------------------------
  # Reads host-specific core masks from config.local.hardware:
  # - omnibook (Ryzen AI 9 365): gameCores = "0-7" (Zen 5), gameCoresNoSmt = "0,2,4,6"
  # - desktop (Ryzen 5 5600X):   gameCores = "0-11" (Zen 3 unified L3), gameCoresNoSmt = "0,2,4,6,8,10"
  zen5 = pkgs.writeShellScriptBin "zen5" ''
    exec ${pkgs.util-linux}/bin/taskset -c ${config.local.hardware.gameCores} "$@"
  '';

  zen5-nosmt = pkgs.writeShellScriptBin "zen5-nosmt" ''
    exec ${pkgs.util-linux}/bin/taskset -c ${config.local.hardware.gameCoresNoSmt} "$@"
  '';

  protonData = builtins.fromJSON (builtins.readFile ./proton-cachyos.json);
in {
  # Expose proton-cachyos-slr on pkgs so both Steam extraCompatPackages and
  # osuStableLauncher in home.nix consume the exact same derivation.
  nixpkgs.overlays = [
    (final: prev: {
      proton-cachyos-slr = final.stdenvNoCC.mkDerivation {
        pname = "proton-cachyos";
        inherit (protonData) version;

        src = final.fetchurl {
          inherit (protonData) url hash;
        };

        nativeBuildInputs = [final.xz final.gnutar];

	buildCommand = ''
          mkdir -p $out
          tar -xf $src -C $out --strip-components=1
          if ! grep -q 'threads = os.cpu_count()' "$out/proton"; then
            echo "ERROR: proton-cachyos upstream changed 'threads = os.cpu_count()' in $out/proton; sed patch would be a silent no-op!" >&2
            exit 1
          fi
          sed -i 's/threads = os.cpu_count().*/threads = 4/' "$out/proton"

          # Automatically pin all Proton games to gameCores (0-4,6-10 on desktop)
          # while keeping Steam/Heroic web helpers confined to backgroundCores (5,11)
          mv "$out/proton" "$out/.proton-real"
          cat << 'EOF' > "$out/proton"
#!/bin/sh
exec ${final.util-linux}/bin/taskset -c ${config.local.hardware.gameCores} "$(dirname "$0")/.proton-real" "$@"
EOF
          chmod +x "$out/proton"
        '';
      };
    })
  ];

  # ---------------------------------------------------------------------------
  # VIRTUAL MEMORY & SCHEDULER TUNING
  # ---------------------------------------------------------------------------
  boot.kernel.sysctl = {
    "vm.max_map_count" = 2147483642;
    # Fixed byte thresholds (64 MiB background / 256 MiB synchronous) instead of
    # 5%/10% ratios (which allowed 1.6 GiB / 3.2 GiB writeback stalls on 32 GB RAM).
    "vm.dirty_background_bytes" = 67108864;
    "vm.dirty_bytes" = 268435456;
    # Reduce per-CPU vmstat shepherd timer wakeups from 1Hz to 0.1Hz (every 10s).
    "vm.stat_interval" = 10;
  };

  # ==========================================
  # 1. OpenTabletDriver & uinput (osu!)
  # ==========================================
  hardware.opentabletdriver = {
    enable = true;
    daemon.enable = true;
  };

  hardware.uinput.enable = true;

  # ---------------------------------------------------------------------------
  # STEAM & PROTON RUNTIME PIPELINE
  # ---------------------------------------------------------------------------
  programs.steam = {
    enable = true;
    protontricks.enable = true;
    remotePlay.openFirewall = false;
    dedicatedServer.openFirewall = false;
    extraCompatPackages = [pkgs.proton-cachyos-slr];
  };

  hardware.steam-hardware.enable = lib.mkForce false;

  # ---------------------------------------------------------------------------
  # LOW-LATENCY PROTON & DRIVER ENVIRONMENT
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    AQ_NO_MODIFIERS = "1";
    MESA_VK_WSI_PRESENT_MODE = "immediate";
    SDL_VIDEO_WAYLAND_ALLOW_TEARING = "1";
    vblank_mode = "0";
    RADV_PERFTEST = "nggc";
    PROTON_USE_NTSYNC = "1";
    PROTON_NO_ESYNC = "1";
    PROTON_USE_SDL = "1";
    PROTON_VKD3D_LOWLATENCY = "1";
    PROTON_DXVK_LOWLATENCY = "1";
    # Must be an absolute path so DXVK resolves /etc/dxvk.conf regardless of cwd
    DXVK_CONFIG_FILE = "/etc/dxvk.conf";
    MESA_SHADER_CACHE_MAX_SIZE = "16G";
    NIXOS_OZONE_WL = "1";
    DISABLE_VK_LAYER_VALVE_steam_overlay_1 = "1";
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
    SDL_JOYSTICK_HIDAPI = "0";
    SDL_GAMECONTROLLERCONFIG = "";
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE DXVK ENGINE CONFIGURATION (/etc/dxvk.conf)
  # ---------------------------------------------------------------------------
  environment.etc."dxvk.conf".text = ''
    # --- PRESENTATION & FRAME QUEUE LATENCY ---
    dxvk.numCompilerThreads = 4
    dxvk.enableAsync = true
    d3d9.enableAsync = true
    dxvk.syncInterval = 0
    dxvk.tearFree = False
    dxgi.syncInterval = 0
    d3d9.presentInterval = 0

    # Strict 1-frame queue depth: eliminates CPU buffer queuing lag
    dxgi.maxFrameLatency = 1
    d3d9.maxFrameLatency = 1

    # Prevents software thread sleep throttling in DXVK's swapchain loop
    dxgi.maxFrameRate = 0
    d3d9.maxFrameRate = 0

    # --- RDNA / RADV HARDWARE PIPELINE ---
    dxvk.useRawSsbo = True
    d3d11.relaxedBarriers = True
    dxgi.nvapiHack = False
    dxvk.trackPipelineLifetime = False

    # Optimizes D3D9 sampler state setup for titles like osu! stable
    d3d9.samplerAnisotropy = 0
    d3d9.deferSurfaceCreation = True
  '';

  # ---------------------------------------------------------------------------
  # SYSTEM PACKAGES & TELEMETRY
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    zen5
    zen5-nosmt
    lact
    heroic
    umu-launcher
    libnotify
    mangohud
    amdgpu_top
    usbutils
    evtest
    evhz
    lsof
  ];
}
