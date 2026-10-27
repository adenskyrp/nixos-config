{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  gpuDpmLevel = "high";

  # ---------------------------------------------------------------------------
  # DESKTOP PCI IRQ PIN TABLE (Ryzen 5 5600X: 0-5 Physical, 6-11 SMT Siblings)
  # ---------------------------------------------------------------------------
  # Verified via `lscpu -e` and `/proc/interrupts`:
  # - Core 0 (CPU 0, 6): Game main thread (kept 100% free of hardware IRQs)
  # - Core 1 (CPU 1, 7): Game worker threads
  # - Core 2 (CPU 2, 8): Game worker threads
  # - Core 3 (CPU 3, 9): Game worker threads
  # - Core 4 (CPU 4, 10): Radeon RX 5700 XT (07:00.0) vblank/fence IRQ on CPU 4,
  #                       Navi 10 HDMI/DP Audio (07:00.1) + CRTC workers on CPU 10
  # - Core 5 (CPU 5, 11): Dedicated I/O & background core:
  #   * CPU 5 (Physical): 0000:09:00.3 (Matisse/Vermeer CPU xHCI -- 8KHz mouse & kbd)
  #   * CPU 11 (SMT):     0000:02:00.0 (B550 chipset xHCI), 0000:04:00.0 (Realtek enp4s0),
  #                       0000:09:00.4 (AMD HD Audio), plus backgroundCores / workqueues
  desktopIrqPinScript = pkgs.writeShellScript "desktop-hardware-irq-pin" ''
    set -u
    grep_bin=${pkgs.gnugrep}/bin/grep
    awk_bin=${pkgs.gawk}/bin/awk

    pin_pci() {
      local pci=$1
      local cpu=$2
      local irq
      for irq in $("$grep_bin" -F -- "$pci" /proc/interrupts | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'); do
        if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
          echo "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
          echo "desktop-irq-pin: $pci (irq $irq) -> cpu$cpu"
        fi
      done
    }

    # 1. 8KHz Peripherals: CPU-direct xHCI controller (0000:09:00.3) -> Physical CPU 5
    pin_pci "0000:09:00.3" 5
    # Elevate threaded xhci_hcd IRQs to SCHED_FIFO 90 so 125us microframes never jitter
    for pid in $(${pkgs.procps}/bin/pgrep -f "irq/.*-xhci_hcd" || true); do
      ${pkgs.util-linux}/bin/chrt -f -p 90 "$pid" 2>/dev/null || true
    done

    # 2. Chipset xHCI (0000:02:00.0), Realtek NIC (0000:04:00.0), Onboard Audio (0000:09:00.4) -> CPU 11
    pin_pci "0000:02:00.0" 11
    pin_pci "0000:04:00.0" 11
    pin_pci "0000:09:00.4" 11

    # 3. Qualcomm WCN785x / QCNCM865 Wi-Fi 7 (ath12k, vendor 17cb:1107) if present -> CPU 5,11
    for irq in $("$grep_bin" -E "ath12k|wlp" /proc/interrupts | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'); do
      echo "5,11" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
    done

    # 4. Radeon RX 5700 XT (Navi 10 @ 0000:07:00.0) -> CPU 4; Navi 10 Audio (0000:07:00.1) -> CPU 10
    pin_pci "0000:07:00.0" 4
    pin_pci "0000:07:00.1" 10
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^card[0-9]+-crtc/ {print $1}'); do
      ${pkgs.util-linux}/bin/taskset -pc 4,10 "$pid" >/dev/null 2>&1 || true
    done

    # 5. Sweep movable kernel housekeeping threads onto Core 5 (CPUs 5,11)
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^(jbd2\/|kswapd|kcompactd|khugepaged|ksmd|kauditd|khungtaskd|psimon|hwrng|watchdogd|usb-storage|scsi_eh_|kdevtmpfs)/ {print $1}'); do
      ${pkgs.util-linux}/bin/taskset -pc 5,11 "$pid" >/dev/null 2>&1 || true
    done
  '';
in {
  nixpkgs.config.permittedInsecurePackages = [
    "electron-40.10.5"
  ];

  # ---------------------------------------------------------------------------
  # MODULAR ARCHITECTURE IMPORTS
  # ---------------------------------------------------------------------------
  imports = [
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/gaming.nix
    ../../modules/minecraft.nix
    ../../modules/sober.nix
    ../../modules/diagnostics.nix
    ../../modules/webcam.nix
  ];

  # ---------------------------------------------------------------------------
  # HOST CPU TOPOLOGY (Ryzen 5 5600X: Single Unified 32 MB L3 CCX, CPUs 0-11)
  # ---------------------------------------------------------------------------
  # Verified via `lscpu -e`:
  # - Physical Cores 0-5 = CPUs 0,1,2,3,4,5
  # - SMT Siblings   0-5 = CPUs 6,7,8,9,10,11
  # - Cores 0-4 (0-4,6-10) are dedicated to games (`gameCoresNoSmt = "0,1,2,3,4"`).
  # - Core 5 (5,11) handles background apps (ironbar, Firefox, Vesktop), kernel
  #   workqueues, and 8KHz xHCI / NIC interrupts while sharing the same 32 MB L3.
  local.hardware = {
    gameCores = "0-4,6-10";
    gameCoresNoSmt = "0,1,2,3,4";
    backgroundCores = "5,11";
    monitors = [
      ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
    ];
  };
  networking.hostName = "desktop";

  # ---------------------------------------------------------------------------
  # BOOTLOADER & PRE-CACHED CACHYOS BORE KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Pre-built CachyOS BORE kernel directly from chaotic-nyx binary cache
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # ASRock B550M-HDV Super I/O telemetry + Qualcomm WCN785x / QCNCM865 Wi-Fi 7
  boot.kernelModules = [
    "nct6775"
    "ath12k"
  ];

  boot.kernelParams = [
    # Zen 3 CPPC active scaling & RDNA 1 RX 5700 XT (Navi 10) full PP feature mask
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"
    "amdgpu.gpu_recovery=1"
    "pcie_aspm=off"

    # Default unmanaged IRQ affinity to Core 5 (CPUs 5,11), keeping Cores 0-3 clean
    "irqaffinity=5,11"

    # Memory latency: disable zswap (zram is used) and restrict THP to madvise
    "zswap.enabled=0"
    "systemd.gpt_auto=0"
    "transparent_hugepage=madvise"

    # Low-latency scheduler & clocksource flags
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "nmi_watchdog=0"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "reboot=pci"

    # Speculative execution mitigations off
    "mitigations=off"
  ];

  boot.blacklistedKernelModules = ["sp5100_tco"];

  # ---------------------------------------------------------------------------
  # NETWORKING & PERIPHERAL POWER LOCKS (Qualcomm WCN785x + Realtek RTL8168 + 8KHz HID)
  # ---------------------------------------------------------------------------
  services.udev.extraRules = ''
    # Disable PCIe Runtime PM for AMD RX 5700 XT (Navi 10 @ 1002:731f)
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x731f", ATTR{power/control}="on"

    # Disable PCIe Runtime PM for Qualcomm WCN785x / QCNCM865 Wi-Fi 7 (17cb:1107)
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"

    # Force continuous active USB power on Compx 8K Mouse (373b:1278) & ATK RS6 Air 8K Keyboard (373b:1209)
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1278", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1209", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
  '';

  # Tune onboard Realtek RTL8111/8168 (enp4s0) for low latency (disable EEE & GRO)
  systemd.services.optimize-nic = {
    description = "Tune Realtek enp4s0 Ethernet for competitive gaming latency";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tune-desktop-nic" ''
        IFACE="enp4s0"
        if [ -d "/sys/class/net/$IFACE" ]; then
          ${pkgs.ethtool}/bin/ethtool --set-eee $IFACE eee off 2>/dev/null || true
          ${pkgs.ethtool}/bin/ethtool -K $IFACE gro off lro off 2>/dev/null || true
        fi
      '';
    };
  };

  # Pin 8KHz USB, Navi 10 GPU, and Realtek NIC interrupts off game cores
  services.irqbalance.enable = false;
  systemd.services.xhci-irq-unpin.enable = false;

  systemd.services.hardware-irq-pin = {
    description = "Pin 8KHz xHCI, Navi 10 amdgpu, and Realtek NIC IRQs to dedicated Zen 3 threads";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = desktopIrqPinScript;
    };
  };

  # ---------------------------------------------------------------------------
  # POWER MANAGEMENT & SYSFS PERFORMANCE PINS (CPUs 0-11 + RX 5700 XT Navi 10)
  # ---------------------------------------------------------------------------
  powerManagement = {
    enable = true;
    resumeCommands = ''
      ${pkgs.systemd}/bin/systemctl restart hardware-irq-pin.service || true
    '';
  };

  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-1]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-1]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
    # Confine unbound kernel workqueues to Core 5 (CPUs 5 and 11 = bitmask 0x820)
    "w /sys/devices/virtual/workqueue/cpumask - - - - 820"
    "w /sys/bus/workqueue/devices/writeback/cpumask - - - - 820"
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];

  # Confine system & user systemd managers to Core 5 (CPUs 5,11)
  systemd.settings.Manager = {
    CPUAffinity = config.local.hardware.backgroundCores;
  };
  systemd.user.settings.Manager = {
    CPUAffinity = config.local.hardware.backgroundCores;
  };
  systemd.slices."system".sliceConfig.AllowedCPUs = config.local.hardware.backgroundCores;

  # ---------------------------------------------------------------------------
  # GRAPHICS (Radeon RX 5700 XT / Navi 10 RDNA 1 / Mesa-git RADV)
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Override AQ_NO_MODIFIERS on desktop: Navi 10 (RX 5700 XT) over direct DP-1
  # supports DCC modifiers natively; forcing linear buffers blocks optimal scanout.
  environment.sessionVariables = {
    AQ_NO_MODIFIERS = lib.mkForce "0";
  };

  # ---------------------------------------------------------------------------
  # PERIPHERALS & GREETD / TUIGREET
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

  system.stateVersion = "25.11";
}
