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

  # The NVIDIA modules create no DRM `cardN-crtcM` workers. Their work runs in
  # these kthreads instead (names from `ps` on the z890, 2026-11-15): nv_queue,
  # nv_open_q, nv_mem_pool_scrubber_queue, nvidia, nvidia-modeset/kthread_q,
  # nvidia-modeset/deferred_close_kthread_q, and one nvidia-drm/timeline-<id>
  # per explicit-sync timeline. Unpinned, they were running on the game cores.
  # irq-affinity.nix moves the ones that exist when it runs to crtcCpus.
  # Timeline threads come and go with each client, so one created later starts
  # unpinned until the unit runs again (resume, Wi-Fi up, rebuild).
  local.irqAffinity.gpuKthreadPattern = "^(nv_queue|nv_open_q|nv_mem_pool|nvidia$|nvidia-modeset.|nvidia-drm.)";

  environment.sessionVariables = {
    # NVIDIA only. /run/opengl-driver also carries every Mesa ICD (lavapipe,
    # nouveau, ...), and the loader would enumerate them all. Unlike Mesa's,
    # the NVIDIA file has no architecture in its name: it is nvidia_icd.json in
    # both the 64-bit and the 32-bit tree (checked on the z890, 2026-11-15; a
    # path that does not exist here leaves Vulkan with no device at all).
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.json";
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
    # proton-cachyos force-adds "fsr4" and copies AMD's amdxcffx64.dll into
    # every prefix (WINE_UPSCALER_REPLACE=fsr4). It needs an RDNA4 GPU; "0"
    # makes check_environment drop it. DLSS upgrades are unaffected.
    PROTON_FSR4_UPGRADE = "0";
  };
}
