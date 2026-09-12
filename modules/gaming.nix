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
    MESA_SHADER_CACHE_MAX_SIZE = "16G";
    PROTON_USE_NTSYNC = "1";
    DXVK_CONFIG_FILE = "/etc/dxvk.conf";
    NIXOS_OZONE_WL = "1";

    # --- FRAMETIME INSTRUMENTATION ---
    # The metric that matters on this machine is frametime CONSISTENCY, not
    # average FPS. At 599.94 Hz the budget is 1.667 ms per frame, so a 3 ms
    # hitch is two frames gone and moves a 600 FPS average by less than half a
    # percent -- it does not show up in the number people usually quote.
    # `frametime` + `frame_timing` plot the distribution; `throttling_status`,
    # `core_load` and `gpu_load` are there to attribute a spike to power,
    # thermal or scheduler rather than leaving it unexplained.
    #
    # `present_mode` is the load-bearing entry. It reports the Vulkan present
    # mode actually in use, which is precisely the measurement missing from the
    # hardware-cursor vs. tearing argument recorded in hosts/omnibook/home.nix
    # (the `cursor` / `allow_tearing` block, ~lines 80-107). That comment is
    # careful to record `tearingBlockedBy: ... hw cursor` "as a claim rather
    # than as fact", because the log line is only emitted when a tearing flip is
    # actually attempted. This settles it from the client side instead: a
    # fullscreen game reporting IMMEDIATE means tearing engaged and the hardware
    # cursor is not blocking it; MAILBOX or FIFO means wp_tearing_control_v1 is
    # not taking effect and the tradeoff documented there is being paid for
    # nothing. Check this before touching `no_hardware_cursors`.
    MANGOHUD_CONFIG = "frametime,frame_timing,present_mode,gpu_load,cpu_load,throttling_status,core_load";

    # DXVK_HUD IS DELIBERATELY UNSET -- it used to be set to "0" here.
    # "0" is not a documented value: DXVK's HUD string is a comma-separated list
    # of element names (`fps`, `frametimes`, `devinfo`, `full`, ...) plus the
    # special "1", and anything unrecognised is simply ignored. So "0" was never
    # an off switch, it was an empty HUD spelled in a way that reads like one --
    # another line that looks like configuration and is not. Unset is how the
    # same state is expressed on purpose, and MangoHud above is the overlay
    # actually doing the measuring.
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
    umu-launcher
    libnotify
    mangohud # Frame-time and latency analysis overlay

    # Per-engine GPU busy %, VRAM/GTT residency and, most usefully here, live
    # DRAM bandwidth. The repo already reasons from its output -- the ironbar
    # DRAM-bandwidth notes in hosts/omnibook/home.nix (~line 624) were built on
    # it -- but nothing installed it, so those numbers could not be reproduced
    # without a temporary `nix shell`. On an APU with no dedicated VRAM, memory
    # bandwidth is shared with the CPU and is the first thing to check when a
    # frametime spike has no thermal or power correlate.
    amdgpu_top

    usbutils
    evtest
    evhz # USB polling rate verification
    lsof
  ];
}
