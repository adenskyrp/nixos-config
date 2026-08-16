{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # VIRTUAL MEMORY & SCHEDULER TUNING
  # ---------------------------------------------------------------------------
  boot.kernel.sysctl = {
    # Massively expands virtual memory mapping capability for Esync/Fsync
    "vm.max_map_count" = 2147483642;

    # Flushes dirty memory pages progressively to prevent NVMe write-burst stalls
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
  };

  # ---------------------------------------------------------------------------
  # STEAM & PROTON RUNTIME PIPELINE
  # ---------------------------------------------------------------------------
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = false;
    dedicatedServer.openFirewall = false;

    # Declaratively registers Proton-GE into Steam's compatibility directory
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ---------------------------------------------------------------------------
  # LOW-LATENCY PROTON & DRIVER ENVIRONMENT
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    # STRIX POINT TOPOLOGY LOCK:
    # Restricts Wine/Proton to the 4 Zen 5 Performance cores (Cores 0-3, Threads 0-7).
    # Completely prevents thread migration onto the lower-clock Zen 5c dense cores.
    WINE_CPU_TOPOLOGY = "4:0,1,2,3";

    # SYNCHRONIZATION PIPELINE:
    # Enforces Linux futex_waitv synchronization via Fsync; disables Esync
    WINE_FSYNC = "1";
    PROTON_NO_ESYNC = "1";

    # DIRECT HARDWARE INPUT:
    # Exposes raw /dev/hidraw nodes directly to game engines
    PROTON_ENABLE_HIDRAW = "1";
    SDL_JOYSTICK_HIDAPI = "0";

    # STEAM INPUT BYPASS:
    # Ignores Valve's virtual Steam Controller emulation device
    SDL_GAMECONTROLLER_IGNORE_DEVICES = "0x28de/0x11ff";

    # VULKAN PRESENTATION:
    DXVK_HUD = "0";
    DXVK_CONFIG_FILE = "/etc/dxvk.conf";
    # Enforces non-blocking immediate page flipping at the Vulkan WSI layer
    MESA_VK_WSI_PRESENT_MODE = "immediate";

    # Wayland native runtime for Electron/Chromium shims
    NIXOS_OZONE_WL = "1";
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE DXVK CONFIGURATION (/etc/dxvk.conf)
  # ---------------------------------------------------------------------------
  environment.etc."dxvk.conf".text = ''
    # --- PRESENTATION LATENCY ---
    # 0 disables DXVK internal vsync pacing (presentation handled by compositor)
    dxvk.syncInterval = 0
    # Disables internal swapchain tear-free buffering to enable immediate scanout
    dxvk.tearFree = False

    # --- CPU WORKER SCHEDULING ---
    # Clamped strictly to 8 threads to match the Zen 5 Performance cluster
    dxvk.numCompilerThreads = 8

    # --- RDNA 3.5 GPU DISPATCH ---
    # Enables direct Shader Storage Buffer Object (SSBO) access on Radeon 880M
    dxvk.useRawSsbo = True
  '';

  # ---------------------------------------------------------------------------
  # SYSTEM PACKAGES & TELEMETRY
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    mangohud          # Frame-time and latency analysis overlay
    evhz              # USB polling rate verification
  ];
}
