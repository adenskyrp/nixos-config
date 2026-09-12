# modules/minecraft.nix
{
  config,
  pkgs,
  lib,
  ...
}: let
  prismlauncher-wrapped = pkgs.prismlauncher.override {
    additionalPrograms = [
      pkgs.temurin-bin-21 # Eclipse Temurin OpenJDK 21 LTS (Generational ZGC)
      pkgs.zulu21 # Azul Zulu 21 OpenJDK
      # pkgs.gamemode IS DELIBERATELY ABSENT -- removed 2026-09-12.
      #
      # It put `gamemoderun` on PATH inside the launcher, but
      # `programs.gamemode.enable` appears nowhere in this repo, so there was no
      # daemon for it to talk to and every invocation was a silent no-op that
      # read as live configuration.
      #
      # Not re-added, and not enabled either. Every lever gamemode would pull is
      # already pinned harder and declaratively elsewhere: cpuFreqGovernor =
      # "performance", EPP via tmpfiles.rules, power_dpm_force_performance_level
      # via tmpfiles.rules, and the SMU envelope via the amd-power-boost
      # oneshot. A daemon toggling those at process start and exit would fight
      # the static config, and its failure mode is silence.
      pkgs.util-linux # Provides 'taskset' for CPU affinity pinning
    ];
  };
in {
  # System Packages
  environment.systemPackages = [
    prismlauncher-wrapped
    pkgs.glfw3-minecraft # Canonical patched GLFW with Wayland raw mouse & cursor lock
    pkgs.libdecor # Client-side decoration handling for Wayland surfaces
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
    AMD_VULKAN_ICD = "RADV";
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };
}
