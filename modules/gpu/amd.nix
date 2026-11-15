# AMD graphics on Mesa (RADV + radeonsi). Imported by omnibook and desktop.
{pkgs, ...}: {
  chaotic.mesa-git.enable = true;

  environment.sessionVariables = {
    MESA_VK_WSI_PRESENT_MODE = "immediate";
    vblank_mode = "0";
    MESA_SHADER_CACHE_MAX_SIZE = "16G";
    # RADV only (skips lavapipe/other Mesa ICDs). Both arches: with only the
    # x86_64 JSON listed, 32-bit Vulkan clients (old-WoW64 Proton, i686 apps)
    # find no device at all; the loader skips the wrong-arch entry by library_arch.
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json:/run/opengl-driver-32/share/vulkan/icd.d/radeon_icd.i686.json";
  };

  environment.systemPackages = with pkgs; [
    lact
    amdgpu_top
  ];
}
