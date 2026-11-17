# HP OmniBook Ultra 14: Ryzen AI 9 365 (4x Zen 5 + 6x Zen 5c), Radeon 880M,
# 32 GB LPDDR5X, Qualcomm WCN785x Wi-Fi 7. Usually docked (Anker dock) to the
# 600 Hz panel.
{pkgs, ...}: let
  ryzenadjCmd = "${pkgs.ryzenadj}/bin/ryzenadj -a 45000 -b 57000 -c 45000 -f 100 --vrm-current=70000 --vrmmax-current=70000 --stapm-time=0xffffffff --slow-time=0xffffffff --max-performance";
in {
  imports = [
    ./hardware-configuration.nix
    ../../modules/gpu/amd.nix
    ../../modules/llm.nix
  ];

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # CPU TOPOLOGY (Zen 5 = CPUs 0-7, Zen 5c = CPUs 8-19, SMT siblings adjacent)
  # ---------------------------------------------------------------------------
  # - CPUs 0-7   (Zen 5): games
  # - CPUs 8-9   (Zen 5c core 1): Radeon 880M, DP audio, card*-crtc* workers
  # - CPUs 10-11 (Zen 5c core 2): 8 kHz USB dock on 10, internal USB on 11
  # - CPUs 12-13 (Zen 5c core 3): Wi-Fi 7, even MSI-X vectors on 12
  # - CPUs 14-17 (Zen 5c cores 4-5): unlisted IRQs, systemd, workqueues
  # - CPUs 18-19 (Zen 5c core 6): Wi-Fi 7, odd MSI-X vectors on 18
  local.hardware = {
    gameCores = "0-7";
    gameCoresNoSmt = "0,2,4,6";
    backgroundCores = "8-9,14-17";
    housekeepingCores = "14-17";
    allCores = "0-19";
    monitors = [
      # Fallback so Hyprland comes up at the right mode before kanshi's profile
      # lands (hosts/omnibook/home.nix); kanshi matches on EDID and stays the
      # authority. DP-2 also exists (the panel hangs off an MST hub) but never
      # gets a CRTC, so a rule naming it would be dead.
      ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
      # Off while docked, to free APU display-engine bandwidth.
      ''hl.monitor({ output = "eDP-1", disabled = true })''
    ];
  };

  local.irqAffinity = {
    enable = true;
    pins = {
      "0000:c3:00.0" = [8]; # Radeon 880M (amdgpu)
      "0000:c3:00.1" = [9]; # Radeon HD Audio Controller (HDMI/DP)
      "0000:c5:00.4" = [10]; # usb7/8 -- Anker dock: 8kHz mouse, ATK kbd, Yeti
      "0000:c5:00.0" = [11]; # usb3/4 -- GameSir G7 Pro, Synaptics fprint, BT
      "0000:c2:00.0" = [12 18]; # Qualcomm WCN785x Wi-Fi 7 (15 MSI-X vectors)
      "0000:c3:00.6" = [14]; # AMD Ryzen HD Audio Controller
    };
    crtcCpus = "8-9";
  };

  # ---------------------------------------------------------------------------
  # APU POWER ENVELOPE (ONESHOT AT BOOT & RESUME -- NO 10s SMU POLLING)
  # ---------------------------------------------------------------------------
  # Calling ryzenadj every 10s via a timer contended with the SMU mailbox
  # mid-game. --stapm-time=0xffffffff and --slow-time=0xffffffff pin the time
  # constants permanently, so it is applied once at boot and again on s2idle
  # resume.
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
  powerManagement.resumeCommands = ''
    ${ryzenadjCmd} || true
  '';

  systemd.tmpfiles.rules = [
    "w /sys/firmware/acpi/platform_profile - - - - performance"
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - high"
  ];

  # ---------------------------------------------------------------------------
  # KERNEL & GRAPHICS
  # ---------------------------------------------------------------------------
  boot.kernelParams = [
    # APU dynamic VRAM (GTT) sizing: 24 GiB ceiling for 32 GB RAM.
    "ttm.pages_limit=6291456"
    "ttm.page_pool_size=6291456"
    "amdgpu.gttsize=24576"
    "amdgpu.ppfeaturemask=0xffffffff"
    # Display scatter-gather off: candidate fix for MST 600 Hz scanout.
    "amdgpu.sg_display=0"
    "amd_pstate=active"
    "reboot=pci"
  ];

  # Aquamarine (Hyprland's backend) allocates scanout buffers without DRM
  # format modifiers. Only this host sets it.
  environment.sessionVariables.AQ_NO_MODIFIERS = "1";

  # ---------------------------------------------------------------------------
  # PERIPHERALS
  # ---------------------------------------------------------------------------
  # Thunderbolt 4 / USB4 daemon for the Anker dock
  services.hardware.bolt.enable = true;

  services.udev.extraRules = ''
    # Qualcomm WCN785x Wi-Fi 7: no runtime PM
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"
  '';

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

  environment.systemPackages = with pkgs; [
    ryzenadj
    wireguard-tools
    openresolv
  ];
}
