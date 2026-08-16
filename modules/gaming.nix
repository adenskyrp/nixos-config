# ~/nixos-config/modules/gaming.nix
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # KERNEL TUNING FOR HIGH-POLLING & HIGH-REFRESH RENDERING
  # ---------------------------------------------------------------------------
  boot.kernel.sysctl = {
    # Disables split-lock mitigation to prevent CPU micro-stutters during 
    # rapid misaligned memory accesses in Proton game threads.
    "kernel.split_lock_mitigate" = 0;

    # Massively expands virtual memory mapping capability for Esync/Fsync.
    "vm.max_map_count" = 2147483642;

    # Prevents dirty page writeback spikes from locking NVMe I/O queues.
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
  };
  boot.kernelParams = [ ];
  # ---------------------------------------------------------------------------
  # XBOX CONTROLLER PIPELINE (xpadneo)
  # ---------------------------------------------------------------------------
  # Ensures proper mapping, deadzones, and rumble translation for Xbox-protocol 
  # controllers in Proton.
  hardware.xpadneo.enable = true;

  # ---------------------------------------------------------------------------
  # STEAM & PROTON PIPELINE
  # ---------------------------------------------------------------------------
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ---------------------------------------------------------------------------
  # WAYLAND DIRECT-PRESENTATION ENVIRONMENT
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    # Forces Wine/Proton to map directly to Wayland surfaces.
    # Eliminates Xwayland translation and prevents Steam Input hooks.
    PROTON_ENABLE_WAYLAND = "1";
    SDL_VIDEODRIVER = "wayland";
    NIXOS_OZONE_WL = "1";
    WINE_FSYNC = "1";
    PROTON_NO_ESYNC = "1";
    PROTON_ENABLE_HIDRAW = "1";
    SDL_JOYSTICK_HIDAPI = "0";
    SDL_GAMECONTROLLER_IGNORE_DEVICES = "0x28de/0x11ff";
    DXVK_HUD = "0";
    DXVK_CONFIG_FILE = "/etc/dxvk.conf";
    MESA_VK_WSI_PRESENT_MODE = "immediate";
  };

  environment.etc."dxvk.conf".text = ''
    # --- PRESENTATION LATENCY ---
    dxvk.syncInterval = 0
    dxvk.tearFree = False

    # --- CPU WORKER SCHEDULING ---
    dxvk.numCompilerThreads = 20

    # --- RDNA 3.5 GPU DISPATCH ---
    dxvk.useRawSsbo = True
  '';

  environment.systemPackages = with pkgs; [
    mangohud      # Vulkan overlay for empirical frame-time analysis
    evhz
  ];
}
