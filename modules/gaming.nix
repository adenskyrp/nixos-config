{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # CCX PINNING WRAPPERS (STEAM LAUNCH-OPTION PREFIXES)
  # ---------------------------------------------------------------------------
  # This CPU is two L3 domains, not one. Measured:
  #
  #   cpu0 cache/index3/shared_cpu_list = 0-7    (4x Zen 5,  5090 MHz)
  #   cpu8 cache/index3/shared_cpu_list = 8-19   (6x Zen 5c, 3325 MHz)
  #
  # A thread that migrates across that boundary therefore pays twice: a ~35%
  # clock drop AND a cold L3, because the second domain shares none of the
  # first's cache. For a game whose critical path is one hot thread -- Rocket
  # League's simulation/netcode loop -- a single migration is a visible
  # frametime spike, against a 1.667 ms budget at 599.94 Hz.
  #
  # The scheduler cannot avoid this by itself on this machine. CONFIG_SCHED_MC_PRIO=y
  # and amd_pstate does populate prefcore_ranking (208/208/202/196 across the
  # Zen 5 cores against a flat 128 on all twelve Zen 5c threads) -- but
  # /proc/sys/kernel/sched_itmt_enabled does not exist, which means
  # sched_set_itmt_support() was never called and that ranking is never promoted
  # into scheduling policy. The fast cores are, as far as placement is
  # concerned, invisible.
  #
  # ITMT would not be sufficient even if it were live, which is the reason to
  # pin rather than to go hunting for a way to enable it: SD_ASYM_PACKING biases
  # where a task is placed during idle balance. It does not reach in and pull an
  # already-running thread back off a slow core. Explicit affinity is strictly
  # stronger than the missing feature, not a workaround for it.
  #
  # LAUNCH-OPTION ONLY, DELIBERATELY -- no systemd unit, no global application.
  # Both variants have to be A/B-able per run without a rebuild, and a global
  # taskset would also pin shader compilation, Proton's own threads and every
  # background service onto the eight threads the game wants to itself.
  #
  #   Steam -> Properties -> Launch Options:
  #     zen5 %command%
  #     zen5-nosmt %command%
  #
  # Which of the two wins is workload-shaped and is NOT measured here -- that is
  # what the A/B is for. Hypothesis for nosmt: RL's hot thread stops sharing a
  # physical core's front-end and FPU with anything, at the cost of half the
  # thread count for everything else Proton is doing.
  #
  # SMT pairing verified from topology/thread_siblings_list: (0,1) (2,3) (4,5)
  # (6,7), so 0,2,4,6 really is one thread per physical Zen 5 core.
  zen5 = pkgs.writeShellScriptBin "zen5" ''
    exec ${pkgs.util-linux}/bin/taskset -c 0-7 "$@"
  '';

  zen5-nosmt = pkgs.writeShellScriptBin "zen5-nosmt" ''
    exec ${pkgs.util-linux}/bin/taskset -c 0,2,4,6 "$@"
  '';
in {
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
    # CCX pinning prefixes, defined in the `let` above. These resolve to the
    # let-bindings rather than to pkgs -- `with` only supplies names that are
    # not already bound, so a let binding of the same name wins.
    zen5
    zen5-nosmt

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
