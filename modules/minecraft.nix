# Minecraft: Prism Launcher with two Java 21 runtimes and a Wayland-patched GLFW.
{pkgs, ...}: let
  prismlauncher-wrapped = pkgs.prismlauncher.override {
    additionalPrograms = [
      pkgs.temurin-bin-21 # Eclipse Temurin OpenJDK 21 LTS (Generational ZGC)
      pkgs.zulu21 # Azul Zulu 21 OpenJDK
      # pkgs.gamemode is deliberately absent (removed 2026-09-12). Nothing
      # enables programs.gamemode, so `gamemoderun` was a silent no-op, and
      # every lever it would pull (governor, EPP, GPU power level, power
      # limits) is already pinned statically in cpu.nix and the host files; a
      # daemon toggling them at process start and exit would fight that.
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

  # VA-API loader next to the drivers in /run/opengl-driver.
  hardware.graphics.extraPackages = [pkgs.libva];

  # Session Environment Variables
  environment.sessionVariables = {
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };
}
