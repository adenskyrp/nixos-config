# NVIDIA graphics on the proprietary userspace and the open kernel modules.
# Imported by z890. Mesa does not drive this card, so there is no mesa-git and
# none of the Mesa variables from gpu/amd.nix; each has its NVIDIA counterpart
# below.
{...}: {
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    # RTX 50 series is only supported by the open kernel modules.
    open = true;
    modesetting.enable = true;
    # Saves and restores VRAM across suspend.
    powerManagement.enable = true;
    # package defaults to nvidiaPackages.stable for the running kernel.
    # No NVreg_RegistryDwords tuning: RMIntrLockingMode (the interrupt-locking
    # mode that cuts stutter) has been on by default since driver 580.
  };

  # No NVIDIA modules in the initrd. They are large, every generation keeps its
  # own initrd on /boot, and tuigreet is a text greeter that runs fine on the
  # firmware framebuffer until udev loads the driver in stage 2. If the console
  # ever comes up at the wrong resolution, add
  # ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"] to
  # boot.initrd.kernelModules and check `du -sh /boot`.

  environment.sessionVariables = {
    # VERIFY both paths exist after first boot:
    #   ls /run/opengl-driver{,-32}/share/vulkan/icd.d/
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.i686.json";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    # VA-API through nvidia-vaapi-driver, which hardware.nvidia installs by
    # default. The Firefox profile turns on media.ffmpeg.vaapi.enabled; Firefox
    # may also need MOZ_DISABLE_RDD_SANDBOX=1 before it decodes on the GPU.
    # VERIFY with `vainfo`.
    LIBVA_DRIVER_NAME = "nvidia";
    # vblank_mode=0 on Mesa: no driver-forced vsync for OpenGL (osu! stable).
    __GL_SYNC_TO_VBLANK = "0";
    # MESA_SHADER_CACHE_MAX_SIZE=16G on Mesa: the shader cache limit in bytes,
    # so a large DXVK/VKD3D library is not evicted and recompiled.
    __GL_SHADER_DISK_CACHE_SIZE = "17179869184";
  };
}
