# ~/nixos-config/hosts/omnibook/configuration.nix
{ config, pkgs, lib, ... }:

{
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
    "reboot=pci"
    "amd_pstate=active" 
    "usbcore.autosuspend=-1" 
    "nowatchdog"
    "nmi_watchdog=0"
    "softlockup_panic=0"
    "tsc=reliable"
    "clocksource=tsc"
    "split_lock_detect=off"
    "threadirqs"
  ];

  system.stateVersion = "25.11"; 

  hardware.xone.enable = true;	

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
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd start-hyprland";
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

  systemd.services.tailscaled.wantedBy = lib.mkForce [ ];

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
