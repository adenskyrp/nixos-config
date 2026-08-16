{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ---------------------------------------------------------------------------
  # STRIX POINT APU SMU POWER TARGETS (65W AC CONTRACT)
  # ---------------------------------------------------------------------------
  # Defined in milliwatts (mW) for direct register injection via ryzenadj.
  sustainedPowerLimit = 54000; # 54W: Maximum sustained thermal envelope for 14" chassis
  slowPowerLimit = 60000; # 60W: Short sustained burst (tPPT) for intensive compute
  fastPowerLimit = 65000; # 65W: Peak immediate burst (fPPT) matching 65W AC charger
  temperatureLimit = 90; # 90°C: Maximum allowed junction temperature (Tctl)
in {
  # ---------------------------------------------------------------------------
  # MODULAR ARCHITECTURE IMPORTS
  # ---------------------------------------------------------------------------
  imports = [
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/gaming.nix
  ];

  # Synchronize hostname with flake output schema
  networking.hostName = "omnibook";

  # ---------------------------------------------------------------------------
  # BOOTLOADER & CACHYOS BORE KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # CachyOS kernel with BORE (Burst-Oriented Response Enhancer) scheduler
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # Low-latency kernel parameters mapped to Zen 5 & RDNA 3.5 APU silicon
  boot.kernelParams = [
    # APU Dynamic VRAM: Expand Translation Table Maps buffer for unified LPDDR5X
    "ttm.pages_limit=4194304"
    "amdttm.pages_limit=4194304"

    # CPU Latency & C-State Pinning: Prevent deep CPU sleep wake-up penalties
    "processor.max_cstate=1"
    "idle=nomwait"

    # Driver Performance: Active autonomous CPPC power scaling
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"

    # Interrupt & Clock Optimization: Eliminate scheduler jitter and polling latency
    "split_lock_mitigate=0"
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "nmi_watchdog=0"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "reboot=pci"
  ];

  # ---------------------------------------------------------------------------
  # CPU & GPU POWER STATE GOVERNOR
  # ---------------------------------------------------------------------------
  powerManagement = {
    enable = true;
    cpuFreqGovernor = "performance";
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE SYSFS REGISTER INJECTION (tmpfiles.rules)
  # ---------------------------------------------------------------------------
  # Writes register values to sysfs during early boot before services launch.
  # Replaces multiple conflicting bash services.
  systemd.tmpfiles.rules = [
    # Set AMD Energy-Performance Preference (EPP) to raw performance across all 10 cores
    "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - performance"

    # Force GPU DPM to maximum clock state across all detected DRM card nodes
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - high"
  ];

  # ---------------------------------------------------------------------------
  # SMU MAILBOX REGISTER OVERRIDES (ryzenadj)
  # ---------------------------------------------------------------------------
  # Writes sustained wattage envelopes directly to the AMD System Management Unit.
  systemd.services.amd-power-boost = {
    description = "Apply 65W SMU power envelope to AMD Ryzen AI 9 365";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "set-smu-limits" ''
        ${pkgs.ryzenadj}/bin/ryzenadj \
          --stapm-limit=${toString sustainedPowerLimit} \
          --slow-limit=${toString slowPowerLimit} \
          --fast-limit=${toString fastPowerLimit} \
          --tctl-temp=${toString temperatureLimit}
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # GRAPHICS & BLEEDING-EDGE MESA STACK
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ---------------------------------------------------------------------------
  # PERIPHERALS & LAPTOP HARDWARE GUARDS
  # ---------------------------------------------------------------------------
  services.udev.packages = [pkgs.swayosd];
  environment.systemPackages = [pkgs.ryzenadj];

  # Fingerprint reader daemon with lid-safety check
  services.fprintd.enable = true;
  systemd.services.fprintd = {
    serviceConfig = {
      ExecStartPre = pkgs.writeShellScript "check-display-and-lid" ''
        if grep -q "closed" /proc/acpi/button/lid/*/state 2>/dev/null; then
          exit 1
        fi
        EDP_STATUS=$(cat /sys/class/drm/card*-eDP-*/enabled 2>/dev/null | head -n 1)
        if [ "$EDP_STATUS" = "disabled" ]; then
          exit 1
        fi
        exit 0
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # GREETD / TUIGREET COMPOSITOR LAUNCHER
  # ---------------------------------------------------------------------------
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'start-hyprland'";
        user = "crazycat";
      };
    };
  };
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = {
      Experimental = true;
      FastConnectable = true;
    };
  };

  system.stateVersion = "25.11";
}
