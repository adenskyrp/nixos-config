{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  gpuDpmLevel = "high";
in {
  nixpkgs.config.permittedInsecurePackages = [
    "electron-40.10.5"
  ];

  # ---------------------------------------------------------------------------
  # MODULAR ARCHITECTURE IMPORTS
  # ---------------------------------------------------------------------------
  # Note: modules/llm.nix (20 GiB Q4_K_M MoE) and modules/irq-affinity.nix
  # (omnibook PCI addresses) are deliberately omitted on this 16 GB RAM /
  # 8 GB VRAM desktop.
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
  # Unlike the OmniBook's split Zen 5 + Zen 5c CCXs, all 6 cores / 12 threads
  # on the 5600X share one 32 MB L3 cache at uniform boost clocks.
  # - Games get all 6 physical cores (0-11, or 0,2,4,6,8,10 without SMT).
  # - Background slices/apps default to 0-11 so BORE schedules freely across
  #   idle threads without starving 6-core workloads.
  local.hardware = {
    gameCores = "0-11";
    gameCoresNoSmt = "0,2,4,6,8,10";
    backgroundCores = "0-11";
    # Match the BenQ XL2586X+ by description or explicit connector so connector
    # renumbering across RX 6650 XT DP ports cannot drop you to 60Hz.
    monitors = [
      "desc:BNQ XL2586X+ EB3CR02979SL0, 1920x1080@599.94, 0x0, 1"
    ];
  };
  networking.hostName = "desktop";

  # ---------------------------------------------------------------------------
  # BOOTLOADER & CACHYOS BORE KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Pre-built CachyOS BORE kernel (x86_64-v3 matches Zen 3 ISA)
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # ASRock B550M-HDV Super I/O telemetry + Intel BE200 Wi-Fi 7 stack
  boot.kernelModules = [
    "nct6775"
    "iwlwifi"
    "iwlmvm"
  ];

  boot.kernelParams = [
    # Zen 3 CPPC active scaling & RDNA 2 RX 6650 XT full PP feature mask
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"
    "pcie_aspm=off"

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

    # Speculative execution mitigations off (same trade-off as omnibook)
    "mitigations=off"
  ];

  # ---------------------------------------------------------------------------
  # INTEL BE200NGW WI-FI 7 (802.11be) LOW-LATENCY DRIVER CONFIG
  # ---------------------------------------------------------------------------
  # NOTE ON ASROCK B550M-HDV (AM4): If the system fails to POST or enumerate
  # the BE200 on PCIe due to the Intel BE200 AMD chipset bug, swap the card for
  # a Qualcomm QCNCM865 (ath12k) or MediaTek MT7925 (mt7925e).
  #
  # power_scheme=1 forces iwlmvm into CAM (Continuously Active Mode), disabling
  # opportunistic 802.11 power-save sleep between beacons.
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0 disable_11ax=0 disable_11be=0
    options iwlmvm power_scheme=1
  '';

  services.udev.extraRules = ''
    # Disable PCIe Runtime PM for Intel BE200 Wi-Fi 7 (8086:272b)
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x272b", ATTR{power/control}="on"
  '';

  # ---------------------------------------------------------------------------
  # POWER MANAGEMENT & SYSFS PERFORMANCE PINS (CPUs 0-11 + RX 6650 XT)
  # ---------------------------------------------------------------------------
  powerManagement.enable = true;

  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-1]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-1]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
  ];

  # ---------------------------------------------------------------------------
  # GRAPHICS (Radeon RX 6650 XT / RDNA 2 / Mesa-git RADV)
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
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
