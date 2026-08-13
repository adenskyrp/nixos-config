# ~/nixos-config/hosts/omnibook/configuration.nix
{ config, pkgs, lib, ... }:

let
  # Define higher APU power targets for a 65W AC power contract
  # Values are defined in milliwatts (mW)
  sustainedPowerLimit = 54000; # 54W: Maximum effective sustained ceiling for a 14" chassis
  slowPowerLimit      = 60000; # 60W: Sustained burst (tPPT) for sustained heavy workloads
  fastPowerLimit      = 65000; # 65W: Peak short burst (fPPT) matching max charger input
  temperatureLimit    = 95;    # Max allowed Tctl/Tjunc temperature in °C before throttling
in
{
  environment.systemPackages = [ pkgs.ryzenadj ];

  # Systemd service to enforce register writes to the AMD SMU (System Management Unit)
  systemd.services.amd-power-boost = {
    description = "Apply 65W performance profile to AMD Ryzen AI 9 365";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Write directly to hardware SMU mailboxes via ryzenadj
      ExecStart = ''
        ${pkgs.ryzenadj}/bin/ryzenadj \
          --stapm-limit=${toString sustainedPowerLimit} \
          --slow-limit=${toString slowPowerLimit} \
          --fast-limit=${toString fastPowerLimit} \
          --tctl-temp=${toString temperatureLimit}
      '';
    };
  };
  imports = [ 
    ./hardware-configuration.nix 
    ../../modules/core.nix
    ../../modules/gaming.nix
  ];

  # ---------------------------------------------------------------------------
  # BOOTLOADER & CACHYOS BORE KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  boot.kernelParams = [
    "ttm.pages_limit=4194304"
    "amdttm.pages_limit=4194304"
    "iomem=relaxed"
    "reboot=pci"
    "amd_pstate=active" 
    "amdgpu.ppfeaturemask=0xffffffff"
    "processor.max_cstate=1"
    "usbcore.autosuspend=-1"
    "nowatchdog"
    "nmi_watchdog=0"
    "softlockup_panic=0"
    "tsc=reliable"
    "clocksource=tsc"
    "split_lock_detect=off"
    "threadirqs"
    "idle=nomwait"
  ];

  system.stateVersion = "25.11"; 

  hardware.xone.enable = true;	

  # ---------------------------------------------------------------------------
  # AMDGPU HIGH-PERFORMANCE POWER STATE LOCK
  # ---------------------------------------------------------------------------
  systemd.services.amdgpu-performance-lock = {
    description = "Force AMDGPU into constant high performance clock state";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Forces power_dpm_force_performance_level to 'high', preventing GPU clock down-stepping
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo high > /sys/class/drm/card0/device/power_dpm_force_performance_level || true'";
    };
  };

  # ---------------------------------------------------------------------------
  # LAPTOP-SPECIFIC HARDWARE GUARDS (fprintd + Lid Switch)
  # ---------------------------------------------------------------------------
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
  # DISPLAY MANAGER & BLUETOOTH
  # ---------------------------------------------------------------------------
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd '${pkgs.util-linux}/bin/chrt -f 50 start-hyprland'";
        user = "crazycat";
      };
    };
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = { Experimental = true; FastConnectable = true; };
  };

  # ---------------------------------------------------------------------------
  # GRAPHICS PIPELINE & HARDWARE DAEMONS
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Required for laptop media keys to communicate with SwayOSD
  services.udev.packages = [ pkgs.swayosd ];

  networking.hostName = "nixos";

  # ---------------------------------------------------------------------------
  # DECLARATIVE KERNEL VIRTUAL FILE SYSTEM (sysfs) INJECTION
  # ---------------------------------------------------------------------------
  # Replaces your imperative bash script. This natively instructs systemd 
  # to write "performance" to every CPU core's EPP file during early boot.
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - performance"
  ];
}
