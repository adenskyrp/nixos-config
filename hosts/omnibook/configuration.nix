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

  # GPU DPM level, applied at boot and re-applied on resume.
  # "auto" lets the SMU shift the shared 54-65W envelope toward the CPU when the
  # iGPU is not the bottleneck (Rocket League at 1080p is CPU/netcode-bound).
  # "high" pins maximum GPU clocks instead, at the cost of CPU thermal headroom.
  gpuDpmLevel = "auto";

  # Shared by the boot-time oneshot and the resume hook so both paths inject an
  # identical envelope rather than drifting apart.
  applySmuLimits = pkgs.writeShellScript "set-smu-limits" ''
    ${pkgs.ryzenadj}/bin/ryzenadj \
      --stapm-limit=${toString sustainedPowerLimit} \
      --slow-limit=${toString slowPowerLimit} \
      --fast-limit=${toString fastPowerLimit} \
      --tctl-temp=${toString temperatureLimit}
  '';
in {
  # ---------------------------------------------------------------------------
  # MODULAR ARCHITECTURE IMPORTS
  # ---------------------------------------------------------------------------
  imports = [
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/gaming.nix
    ../../modules/minecraft.nix
    ../../modules/diagnostics.nix
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

    # Driver Performance: Active autonomous CPPC power scaling
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"

    # Interrupt & Clock Optimization: Eliminate scheduler jitter and polling latency
    # split_lock_mitigate is Intel-only and was being rejected outright ("Unknown
    # kernel command line parameters", visible in dmesg on every boot) -- it is
    # dropped. split_lock_detect is kept: it parses on x86 generally and on Zen 5
    # gates the bus-lock detector this CPU does advertise (bus_lock_detect in
    # /proc/cpuinfo flags), where a trap on a misaligned locked access would cost
    # a hard #DB round trip mid-frame.
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "reboot=pci"
  ];

  # ---------------------------------------------------------------------------
  # WI-FI RADIO LINK (MediaTek MT7925 / Filogic 360, 2x2 802.11be)
  # ---------------------------------------------------------------------------
  # PCIe ASPM lets the radio drop the link into L1/L1.2 between packets. The
  # mt76 driver has to re-arm its DMA rings on every exit, so on an otherwise
  # idle link — precisely the traffic shape of a game's 60 Hz UDP tick — the
  # first packet after each idle gap eats the wake-up penalty and shows up as a
  # sporadic multi-millisecond spike. This part is also the one the mt7921/7925
  # family's ASPM firmware hangs are attributed to. Pin the link awake; the
  # sub-watt cost is noise against a 65 W SMU envelope and a performance
  # governor that already forbids deep C-states.
  #
  # CLC (Country Location Control) is MediaTek's own regulatory gate, layered on
  # top of cfg80211's. It is evaluated when the driver registers the wiphy —
  # which happens while cfg80211 is still on the "00" world domain — and the
  # result is that all 60 channels of band 4 come up permanently `(disabled)`,
  # even after the domain is later corrected to US. This card is 802.11be 2x2 and
  # the AP here beacons a 6 GHz BSS (operating class 134, channel 101), so the
  # band is worth having: it is uncontended and has no 2.4/5 GHz legacy traffic
  # to share airtime with. cfg80211's US rules still bound transmit power.
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=1
    options mt7925_common disable_clc=1
  '';

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

    # Apply the chosen GPU DPM level across all detected DRM card nodes
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
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
      ExecStart = applySmuLimits;
    };
  };

  # ---------------------------------------------------------------------------
  # SUSPEND/RESUME POWER STATE RE-APPLICATION
  # ---------------------------------------------------------------------------
  # tmpfiles.rules and the oneshot above only run at boot. On a laptop, amdgpu
  # resets power_dpm_force_performance_level and the SMU can fall back to stock
  # wattage envelopes across an s2idle cycle -- so closing the lid between
  # matches would silently drop the machine to default power limits with no
  # visible indication. Re-inject the same registers after every resume.
  powerManagement.resumeCommands = ''
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      echo performance > "$f" || true
    done
    for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
      echo ${gpuDpmLevel} > "$f" || true
    done
    ${applySmuLimits} || true
  '';

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
    powerOnBoot = false;
    settings.General = {
      Experimental = true;
      FastConnectable = true;
    };
  };

  # ---------------------------------------------------------------------------
  # STUTTER INVESTIGATION HARNESS (TEMPORARY, OPENED 2026-08-27)
  # ---------------------------------------------------------------------------
  # Installs stutter-trace / psi-watch / perf for the intermittent-frame-hitch
  # measurement. Purely additive -- no scheduling, power or I/O behaviour
  # changes -- so it is safe to leave on across the investigation. Turn it off
  # once the cause is bucketed rather than letting the tooling become permanent
  # system state.
  #
  # unsafeTracing is left off deliberately: it drops perf_event_paranoid to -1
  # and kptr_restrict to 0, which weakens KASLR and opens the PMU to every local
  # process. Switch it on only for the duration of a perf session that actually
  # needs kernel symbols, then switch it back.
  local.diagnostics = {
    enable = true;
    unsafeTracing = false;
  };

  system.stateVersion = "25.11";
}
