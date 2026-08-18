# modules/minecraft.nix
{ config, pkgs, lib, ... }:

let
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
    AMD_VULKAN_ICD = "RADV";
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };
}
