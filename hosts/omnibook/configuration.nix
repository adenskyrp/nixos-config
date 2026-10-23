{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # GPU DPM level, applied at boot and re-applied on resume.
  gpuDpmLevel = "high";

  ryzenadjCmd = "${pkgs.ryzenadj}/bin/ryzenadj -a 45000 -b 57000 -c 45000 -f 100 --vrm-current=70000 --vrmmax-current=70000 --stapm-time=0xffffffff --slow-time=0xffffffff --max-performance";
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
    ../../modules/llm.nix
    ../../modules/webcam.nix
    ../../modules/irq-affinity.nix
  ];

  # ---------------------------------------------------------------------------
  # HOST CPU TOPOLOGY (Ryzen AI 9 365: 4x Zen 5 [0-7] + 6x Zen 5c [8-19])
  # ---------------------------------------------------------------------------
  local.hardware = {
    gameCores = "0-7";
    gameCoresNoSmt = "0,2,4,6";
    backgroundCores = "8-9,14-17";
  };
  networking.hostName = "omnibook";

  # ---------------------------------------------------------------------------
  # APU POWER ENVELOPE (ONESHOOT AT BOOT & RESUME -- NO 10s SMU POLLING)
  # ---------------------------------------------------------------------------
  # Calling ryzenadj every 10s via a timer contended with the SMU mailbox
  # mid-game. Because --stapm-time=0xffffffff and --slow-time=0xffffffff pin
  # the time constants permanently, we apply once at boot and re-apply on
  # s2idle resume via powerManagement.resumeCommands.
  boot.blacklistedKernelModules = ["amd_pmf" "amdxdna"];

  systemd.services.ryzenadj-tdp-unlock = {
    description = "Unlock APU Power Limits (boot & resume)";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = ryzenadjCmd;
    };
  };

  environment.systemPackages = with pkgs; [
    ryzenadj
    ethtool
  ];

  # Thunderbolt 4 / USB4 daemon for the Anker dock
  services.hardware.bolt.enable = true;

  systemd.services.optimize-nic = {
    description = "Tune USB Ethernet adapter for competitive gaming latency";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "tune-nic" ''
        IFACE="eth0"
        if [ -d "/sys/class/net/$IFACE" ]; then
          ${pkgs.ethtool}/bin/ethtool -C $IFACE rx-usecs 15000 || true
          ${pkgs.ethtool}/bin/ethtool --set-eee $IFACE eee off || true
          ${pkgs.ethtool}/bin/ethtool -K $IFACE gro off || true
          USB_DEV=$(readlink -f /sys/class/net/$IFACE/device)
          echo 0 > "$USB_DEV/power/usb3_lpm_u1_permit" 2>/dev/null || true
          echo 0 > "$USB_DEV/power/usb3_lpm_u2_permit" 2>/dev/null || true
        fi
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # BOOTLOADER & CACHYOS BORE KERNEL (BINARY CACHE HIT)
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Uses pre-built Chaotic-Nyx BORE kernel directly from the binary cache
  # instead of .cachyOverride (which invalidated the binary cache and forced a
  # full local kernel compile on every flake update).
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  boot.kernelParams = [
    # --- APU DYNAMIC VRAM (GTT) SIZING (24 GiB ceiling for 32 GB RAM) ---
    "ttm.pages_limit=6291456"
    "ttm.page_pool_size=6291456"
    "amdgpu.gttsize=24576"

    # Driver Performance: Active autonomous CPPC power scaling
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"
    "pcie_aspm=off"

    # Route all unmanaged/platform IRQs (I2C, ACPI, RTC, speaker amp) and RCU
    # offload threads to background Zen 5c cores (8-9,14-17), keeping Zen 5
    # game cores (0-7) and dedicated USB/Wi-Fi 7 IRQ cores (10-13,18-19) clean.
    "irqaffinity=14-17"

    # Memory latency: disable zswap (zram is used) and restrict THP to explicit
    # madvise() calls so background khugepaged scans never stall LPDDR5X.
    "zswap.enabled=0"
    "transparent_hugepage=madvise"

    # Interrupt & Clock Optimization
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "nmi_watchdog=0"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "reboot=pci"

    # --- SPECULATIVE EXECUTION MITIGATIONS: OFF (KNOWN SECURITY TRADE-OFF) ---
    "mitigations=off"

    # --- DISPLAY SCATTER-GATHER: OFF (CANDIDATE FIX FOR MST 600Hz SCANOUT) ---
    "amdgpu.sg_display=0"
  ];
  # ---------------------------------------------------------------------------
  # WI-FI RADIO LINK (MediaTek MT7925 / Filogic 360, 2x2 802.11be)
  # ---------------------------------------------------------------------------
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"
  '';
  # ---------------------------------------------------------------------------
  # POWER MANAGEMENT & S2IDLE RESUME HOOKS
  # ---------------------------------------------------------------------------
  # MUST be true so NixOS generates post-resume.service and executes
  # powerManagement.resumeCommands (for hardware-irq-pin and ryzenadj).
  powerManagement = {
    enable = true;
    resumeCommands = ''
      ${ryzenadjCmd} || true
      ${config.boot.kernelPackages.cpupower}/bin/cpupower idle-set -D 350 || true
    '';
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE SYSFS REGISTER INJECTION (tmpfiles.rules)
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "w /sys/firmware/acpi/platform_profile - - - - performance"
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu[0-9]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-9]/cpufreq/scaling_governor - - - - performance"
    "w /sys/devices/system/cpu/cpu1[0-9]/cpufreq/energy_performance_preference - - - - performance"
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
    # Confine all unbound kernel workqueues (ttm, gfx, events_unbound, writeback)
    # to CPUs 14-17 (0x3c000), keeping them off Zen 5 game cores (0-7) AND off
    # dedicated GPU/USB/Wi-Fi 7 IRQ cores (8-13,18-19).
    "w /sys/devices/virtual/workqueue/cpumask - - - - 3c000"
    "w /sys/bus/workqueue/devices/writeback/cpumask - - - - 3c000"
    # Never stall on synchronous THP compaction
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];
  # --- ASYMMETRIC CPU ISOLATION (ZEN 5C SYSTEM & AUDIO DAEMONS: CPUs 8-19) ---
  systemd.settings.Manager = {
    CPUAffinity = config.local.hardware.backgroundCores;
  };
  systemd.user.settings.Manager = {
    CPUAffinity = config.local.hardware.backgroundCores;
  };
  systemd.slices."system".sliceConfig.AllowedCPUs = config.local.hardware.backgroundCores;

  # ---------------------------------------------------------------------------
  # GRAPHICS & BLEEDING-EDGE MESA STACK
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ---------------------------------------------------------------------------
  # PERIPHERALS & GREETD / TUIGREET COMPOSITOR LAUNCHER
  # ---------------------------------------------------------------------------
  services.udev.packages = [pkgs.swayosd];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
	command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd '${pkgs.util-linux}/bin/taskset -c ${config.local.hardware.backgroundCores} start-hyprland'";
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

  # ---------------------------------------------------------------------------
  # STUTTER INVESTIGATION HARNESS
  # ---------------------------------------------------------------------------
  local.diagnostics = {
    enable = false;
    unsafeTracing = false;
  };

  system.stateVersion = "25.11";
}
