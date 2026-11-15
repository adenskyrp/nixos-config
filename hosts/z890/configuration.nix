{
  config,
  pkgs,
  lib,
  ...
}: {
  # DRAFT for the iBUYPOWER Z890 box. Written from hosts/desktop without access
  # to the machine: every line marked VERIFY must be checked on the live system
  # (lscpu -e, lspci -nnk, /proc/interrupts) before it is trusted.
  # hardware-configuration.nix is a placeholder too; regenerate it on the box.

  nixpkgs.config.permittedInsecurePackages = [
    "electron-40.10.5"
  ];

  imports = [
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/gaming.nix
    ../../modules/minecraft.nix
    ../../modules/sober.nix
    ../../modules/diagnostics.nix
    ../../modules/webcam.nix
    ../../modules/irq-affinity.nix
  ];

  # ---------------------------------------------------------------------------
  # HOST CPU TOPOLOGY (Core Ultra 7 270K Plus: 8 P-cores + 16 E-cores, no SMT)
  # ---------------------------------------------------------------------------
  # VERIFY the numbering with `lscpu -e=CPU,CORE,MAXMHZ`. This assumes the usual
  # Arrow Lake layout: CPUs 0-7 are the P-cores, 8-23 the E-cores, and E-cores
  # share an L2 in clusters of four (8-11, 12-15, 16-19, 20-23). If the P-cores
  # are not 0-7, every list below and the hex mask in tmpfiles must change.
  # z890-topology-check (below) fails at boot if the numbering is different.
  # - P-cores 0-7: games. cpu0 still takes boot-CPU-only kernel work; if that
  #   shows up in frametimes, try gameCores = "1-7".
  # - E cluster 8-11: nvidia IRQ, DRM workers.
  # - E cluster 12-15: xHCI (mouse, K7), PipeWire.
  # - E cluster 20-23: default IRQs, kthreads, workqueues.
  # AAA titles with more than 8 busy threads may prefer gameCores = "0-15".
  local.hardware = {
    gameCores = "0-7";
    gameCoresNoSmt = "0-7";
    backgroundCores = "8-23";
    allCores = "0-23";
    # Left off on purpose. On Intel, turbo ratios are chosen by how many cores
    # are out of deep C-states, so capping to C1 makes every core count as
    # active and forfeits any few-core ratio above the all-core limit. A/B this
    # against the BIOS per-core-usage ratios before turning it on.
    capCstates = false;
    monitors = [
      # VERIFY the connector name with `hyprctl monitors`; the catch-all below
      # covers it if the NVIDIA card numbers its outputs differently.
      ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
      ''hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })''
    ];
  };
  networking.hostName = "z890";

  # ---------------------------------------------------------------------------
  # IRQ PIN TABLE (modules/irq-affinity.nix)
  # ---------------------------------------------------------------------------
  local.irqAffinity = {
    enable = true;
    pins = {
      "driver:nvidia" = [8];
      "driver:snd_hda_intel" = [9];
      # One key for every xHCI until the controllers are identified. VERIFY with
      # `lspci -nnk | grep -A3 -i usb`, then split mouse and audio by
      # "pci:<vendor>:<device>" the way hosts/desktop does.
      "driver:xhci_hcd" = [12];
    };
    defaultCpus = "20";
    # The NVIDIA driver may not create `cardN-crtcM` kthreads at all, in which
    # case this matches nothing.
    crtcCpus = "8-11";
    kthreadCpus = "20-23";
    xhciThreadPriority = 90;
  };

  # ---------------------------------------------------------------------------
  # BOOT & KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 15;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  # Same kernel as the other hosts. The NVIDIA module is compiled locally
  # against it on each kernel or driver bump.
  boot.kernelPackages = pkgs.linuxPackages_cachyos-bore;

  # No NVIDIA modules in the initrd, unlike amdgpu on hosts/desktop. They are
  # large, every generation keeps its own initrd on /boot (15 here), and
  # tuigreet is a text greeter that runs fine on the firmware framebuffer until
  # udev loads the driver in stage 2. If the console ever comes up at the wrong
  # resolution, add ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"] to
  # boot.initrd.kernelModules and check `du -sh /boot`.

  boot.kernelModules = [
    "i2c-dev" # decode-dimms (SPD read-out)
    "spd5118"
    # VERIFY: add the Super I/O sensor driver `sensors-detect` reports
    # (ASUS Z890 boards are usually nct6775).
  ];

  boot.kernelParams = [
    # intel_pstate binds in active (HWP) mode by default; no parameter needed.
    "pcie_aspm=off"
    "irqaffinity=20-23"
    "zswap.enabled=0"
    "systemd.gpt_auto=0"
    "transparent_hugepage=madvise"
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "nmi_watchdog=0"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "mitigations=off"
    "snd_hda_intel.power_save=0"
    "snd_hda_intel.power_save_controller=N"
  ];

  # ---------------------------------------------------------------------------
  # GPU (RTX 5070)
  # ---------------------------------------------------------------------------
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    # RTX 50 series is only supported by the open kernel modules.
    open = true;
    modesetting.enable = true;
    # Saves and restores VRAM across suspend.
    powerManagement.enable = true;
    # package defaults to nvidiaPackages.stable for the running kernel.
  };

  # VERIFY the iGPU is off: this CPU has one, and if the firmware leaves it
  # enabled Hyprland can pick it as the render device and copy every frame to
  # the NVIDIA outputs. `ls /sys/class/drm` should show a single cardN. If it
  # shows two, disable the iGPU in the BIOS (the "multi-monitor" iGPU option).

  # No chaotic.mesa-git here: Mesa does not drive this card.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # VERIFY Sober: Flatpak needs the org.freedesktop.Platform.GL.nvidia-<version>
  # runtime extension that matches this driver exactly. It is pulled in when
  # Sober is installed, but a driver bump needs `flatpak update` before Sober
  # starts again.

  environment.sessionVariables = {
    # gaming.nix pins VK_DRIVER_FILES to the RADV ICDs, which would leave Vulkan
    # with no device on this host. VERIFY both paths exist after first boot:
    #   ls /run/opengl-driver{,-32}/share/vulkan/icd.d/
    VK_DRIVER_FILES = lib.mkForce "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.i686.json";
    AQ_NO_MODIFIERS = lib.mkForce "0";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    # VA-API through nvidia-vaapi-driver, which hardware.nvidia installs by
    # default. home.nix turns on media.ffmpeg.vaapi.enabled in Firefox; Firefox
    # may also need MOZ_DISABLE_RDD_SANDBOX=1 before it decodes on the GPU.
    # VERIFY with `vainfo`.
    LIBVA_DRIVER_NAME = "nvidia";
    # The NVIDIA counterparts of two Mesa-only variables in gaming.nix.
    # vblank_mode=0: no driver-forced vsync for OpenGL (osu! stable).
    __GL_SYNC_TO_VBLANK = "0";
    # MESA_SHADER_CACHE_MAX_SIZE=16G: the driver's shader cache limit in bytes,
    # so a large DXVK/VKD3D library is not evicted and recompiled.
    __GL_SHADER_DISK_CACHE_SIZE = "17179869184";
  };

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1278", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1209", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
  '';

  # ---------------------------------------------------------------------------
  # AUDIO (copied from hosts/desktop; see that file for the measurements)
  # ---------------------------------------------------------------------------
  services.pipewire.wireplumber.extraConfig."13-alsa-no-suspend" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "~alsa_output.*";}];
        actions = {
          update-props = {
            "session.suspend-timeout-seconds" = 0;
          };
        };
      }
    ];
  };

  services.pipewire.wireplumber.extraConfig."14-fiio-k7" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "~alsa_output.usb-GuangZhou_FiiO_Electronics_Co._Ltd_FiiO_K7.*";}];
        actions = {
          update-props = {
            "api.alsa.period-size" = 128;
            "api.alsa.period-num" = 3;
            "api.alsa.headroom" = 0;
            "priority.driver" = 3000;
          };
        };
      }
    ];
  };

  # PipeWire on the xHCI cluster, off the game cores.
  systemd.user.services.pipewire.serviceConfig.CPUAffinity = "12-15";
  systemd.user.services.pipewire-pulse.serviceConfig.CPUAffinity = "12-15";

  # ---------------------------------------------------------------------------
  # NETWORK
  # ---------------------------------------------------------------------------
  systemd.services.optimize-nic = {
    description = "Disable EEE and GRO/LRO on wired NICs";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tune-z890-nic" ''
        for dev in /sys/class/net/en*; do
          [ -e "$dev" ] || continue
          IFACE=$(basename "$dev")
          ${pkgs.ethtool}/bin/ethtool --set-eee "$IFACE" eee off 2>/dev/null || true
          ${pkgs.ethtool}/bin/ethtool -K "$IFACE" gro off lro off 2>/dev/null || true
        done
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # MEMORY, POWER, CPU ISOLATION
  # ---------------------------------------------------------------------------
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024;
      priority = 0;
    }
  ];

  powerManagement.enable = true;

  systemd.tmpfiles.rules = [
    # 0xf00000 = CPUs 20-23 (= kthreadCpus)
    "w /sys/devices/virtual/workqueue/cpumask - - - - f00000"
    "w /sys/bus/workqueue/devices/writeback/cpumask - - - - f00000"
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];

  # Every CPU list in this file assumes P-cores 0-7 and E-cores 8-23 in L2
  # clusters of four. Nothing else would notice a different numbering: games
  # would just be pinned to E-cores. Fail the unit at boot instead.
  systemd.services.z890-topology-check = {
    description = "Verify the CPU numbering this host's core lists assume";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "z890-topology-check" ''
        fail=0
        expect() {
          local got
          if ! read -r got < "$1" 2>/dev/null; then
            echo "z890-topology-check: $1 is missing" >&2
            fail=1
          elif [ "$got" != "$2" ]; then
            echo "z890-topology-check: $1 is '$got', this host assumes '$2'" >&2
            fail=1
          fi
        }
        expect /sys/devices/cpu_core/cpus 0-7
        expect /sys/devices/cpu_atom/cpus 8-23
        for first in 8 12 16 20; do
          expect "/sys/devices/system/cpu/cpu$first/cache/index2/shared_cpu_list" "$first-$((first + 3))"
        done
        if [ "$fail" -eq 0 ]; then
          echo "z890-topology-check: P-cores 0-7, E-cores 8-23 in L2 clusters of four"
        fi
        exit "$fail"
      '';
    };
  };

  # Performance governor on every policy; with intel_pstate in active mode this
  # also pins EPP to performance.
  systemd.services.cpufreq-performance = {
    description = "cpufreq: performance governor on every policy";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cpufreq-performance" ''
        shopt -s nullglob
        govs=(/sys/devices/system/cpu/cpufreq/policy*/scaling_governor)
        if [ ''${#govs[@]} -eq 0 ]; then
          echo "cpufreq-performance: WARNING no cpufreq driver bound" >&2
          exit 0
        fi
        for g in "''${govs[@]}"; do echo performance > "$g"; done
        echo "cpufreq-performance: $(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver) -> performance on ''${#govs[@]} policies"
      '';
    };
  };

  systemd.settings.Manager.CPUAffinity = config.local.hardware.backgroundCores;
  systemd.user.settings.Manager.CPUAffinity = config.local.hardware.backgroundCores;
  systemd.slices."system".sliceConfig.AllowedCPUs = config.local.hardware.backgroundCores;

  # ---------------------------------------------------------------------------
  # SESSION, PERIPHERALS, SERVICES
  # ---------------------------------------------------------------------------
  services.udev.packages = [pkgs.swayosd];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'start-hyprland'";
        user = "crazycat";
      };
    };
  };
  systemd.services.greetd = {
    wants = lib.mkForce [];
    after = lib.mkForce ["systemd-user-sessions.service"];
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
    settings.General = {
      Experimental = true;
      FastConnectable = true;
    };
  };

  services.avahi.enable = true;
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  security.pam.services.greetd.enableGnomeKeyring = true;

  local.diagnostics = {
    enable = false;
    unsafeTracing = false;
  };

  # VERIFY: set this to the NixOS release of the installer you use and never
  # change it afterwards.
  system.stateVersion = "25.11";
}
