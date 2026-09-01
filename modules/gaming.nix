{
  config,
  pkgs,
  lib,
  ...
}: {
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
    AMD_VULKAN_ICD = "RADV";
    MESA_SHADER_CACHE_MAX_SIZE = "16G";
    WINE_FSYNC = "1";
    PROTON_NO_ESYNC = "1";
    PROTON_ENABLE_WAYLAND = "1";
    SDL_GAMECONTROLLER_IGNORE_DEVICES = "0x28de/0x11ff";
    DXVK_HUD = "0";
    DXVK_CONFIG_FILE = "/etc/dxvk.conf";
    MESA_VK_WSI_PRESENT_MODE = "immediate";
    NIXOS_OZONE_WL = "1";
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE DXVK ENGINE CONFIGURATION (/etc/dxvk.conf)
  # ---------------------------------------------------------------------------
  # Globally applied to all DX9/DX11 titles running through Proton / Wine DXVK.
  environment.etc."dxvk.conf".text = ''
    # --- PRESENTATION & FRAME QUEUE LATENCY ---
    # Disables internal swapchain tear-free buffering and VSync
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

    # --- RDNA 3.5 / RADV HARDWARE PIPELINE ---
    # Enables direct Shader Storage Buffer Object (SSBO) access on Radeon 880M
    dxvk.useRawSsbo = True

    # Allows relaxed Vulkan memory barriers to eliminate pipeline stall bubbles
    d3d11.relaxedBarriers = True

    # Disables Nvidia GPU spoofing to prevent redundant NVAPI/DLSS wrapper checks
    dxgi.nvapiHack = False

    # Disables pipeline lifetime tracking to reduce internal hashmap lookups
    dxvk.trackPipelineLifetime = False

    # Optimizes D3D9 sampler state setup for titles like osu! stable
    d3d9.samplerAnisotropy = 0
    d3d9.deferSurfaceCreation = True
  '';

  # ---------------------------------------------------------------------------
  # SYSTEM PACKAGES & TELEMETRY
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    heroic
    protonup-qt
    mangohud # Frame-time and latency analysis overlay
    usbutils
    evtest
    evhz # USB polling rate verification
  ];
}
