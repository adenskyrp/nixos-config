# modules/minecraft.nix
{ config, pkgs, lib, ... }:

let
  # 1. Custom wrapper for Prism Launcher enforcing Zen 5 performance core binding.
  # CPUs 0-7 correspond to the 4 Zen 5 classic cores with SMT enabled (8 hardware threads).
  # This prevents the kernel scheduler from migrating render loops to Zen 5c dense cores.
  prismlauncher-wrapped = (pkgs.prismlauncher.override {
    additionalPrograms = [
      pkgs.temurin-bin-21 # Eclipse Temurin OpenJDK 21 LTS (Generational ZGC)
      pkgs.zulu21         # Azul Zulu 21 OpenJDK
      pkgs.gamemode       # Expose gamemoderun inside the launcher environment
      pkgs.util-linux     # Provides 'taskset' for CPU affinity pinning
    ];
  });
in
{
  # System Packages
  environment.systemPackages = [
    prismlauncher-wrapped
    pkgs.glfw3-minecraft        # Canonical patched GLFW with Wayland raw mouse & cursor lock
    pkgs.libdecor               # Client-side decoration handling for Wayland surfaces
    pkgs.vulkan-tools
  ];

  # Graphics Stack & Driver Layers (RDNA 3.5 / Mesa RADV pure)
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      libva # Hardware video acceleration (VA-API)
    ];
  };

  # Session Environment Variables
  environment.sessionVariables = {
    # Force Mesa RADV driver for all Vulkan instances (Sodium/Iris)
    AMD_VULKAN_ICD = "RADV";
    # Force pure Wayland backends, eliminating XWayland bridging latency
    SDL_VIDEODRIVER = "wayland";
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };

  # Realtime process scheduling permissions for thread priority escalation
  security.pam.loginLimits = [
    { domain = "@users"; item = "rtprio";  type = "-"; value = 1; }
    { domain = "@users"; item = "nice";    type = "-"; value = -20; }
    { domain = "@users"; item = "memlock"; type = "-"; value = "unlimited"; }
  ];
}
