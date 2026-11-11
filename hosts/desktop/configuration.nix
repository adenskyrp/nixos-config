{
  config,
  pkgs,
  lib,
  ...
}: {
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
  # HOST CPU TOPOLOGY (Ryzen 5 5600X, SMT siblings are N and N+6)
  # ---------------------------------------------------------------------------
  # One CCX / one L3, so only per-core silicon quality and interrupt load
  # matter. Single-thread boost per physical core (APERF/MPERF, PBO +200,
  # 2 runs, 2026-11-11): core0 4841, core2 4841, core1 4816, core5 4816,
  # core4 4791, core3 4766 MHz.
  # - Physical cores 1,2,4,5 (CPUs 1-2,4-5,7-8,10-11): games. Avg 4816 MHz.
  # - Physical core 0 (CPUs 0,6): ath12k Wi-Fi (single shared MSI, IRQF_NOBALANCING,
  #   hard-pinned to cpu0 by the driver) + its CE tasklets, boot-CPU-only work,
  #   8 kHz mouse xHCI (6), default IRQs, kthreads, workqueues. Core 0 is a top
  #   bin, but it is the one core the kernel and ath12k insist on using, so
  #   giving it up costs 0.3% avg game-core clock and removes every unmovable
  #   interrupt from the game cores.
  # - Physical core 3 (CPUs 3,9): worst bin. amdgpu IRQ + CRTC workers (3,9),
  #   K7 USB-audio xHCI (9), PipeWire (3,9).
  local.hardware = {
    gameCores = "1-2,4-5,7-8,10-11";
    gameCoresNoSmt = "1,2,4,5";
    backgroundCores = "0,3,6,9";
    allCores = "0-11";
    # Only POLL/C1 (exit latency < 2 us). Zen 3 desktop _CST reports CC6 as
    # "C2" at ~18 us, which the 350 us default would leave enabled. Warns and
    # does nothing while the BIOS publishes no _CST (cpu-idle-limit, core.nix).
    capCstates = true;
    capCstatesLatency = 2;
    monitors = [
      ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
      # Catch-all: if a GPU swap renumbers connectors (DP-1 -> DP-2/3), come up
      # at the highest refresh rate instead of falling back to 60 Hz.
      ''hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })''
    ];
  };
  networking.hostName = "desktop";

  # ---------------------------------------------------------------------------
  # IRQ PIN TABLE (modules/irq-affinity.nix)
  # ---------------------------------------------------------------------------
  # Driver-keyed, not BDF-keyed: the GPU swap (and any slot/BIOS change that
  # renumbers buses) needs no edit here.
  local.irqAffinity = {
    enable = true;
    pins = {
      "driver:amdgpu" = [3]; # dGPU (fence/vblank IRQs)
      "driver:snd_hda_intel" = [9]; # GPU HDMI/DP audio (onboard ALC897 is not enumerated)
      # The two xHCIs share a driver, so they are keyed by PCI ID. Split so the
      # K7's ~1.4 kHz isochronous completions never queue ahead of mouse reports.
      "pci:1022:149c" = [6]; # CPU (Matisse) xHCI: 8 kHz mouse, keyboard, tablet
      "pci:1022:43ee" = [9]; # B550 chipset xHCI: FiiO K7, Yeti, C922, BT
      # No ath12k pin: with the IOMMU off (no IRQ remapping) it gets 1 shared MSI
      # vector that the driver hard-pins to cpu0 (IRQF_NOBALANCING, so /proc
      # writes are refused). cpu0 is therefore a background CPU.
    };
    defaultCpus = "6";
    crtcCpus = "3,9";
    kthreadCpus = "0,6";
    xhciThreadPriority = 90;
  };

  # ---------------------------------------------------------------------------
  # BOOT & KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot = {
    enable = true;
    # amdgpu in the initrd grows each generation's initrd; cap /boot entries.
    configurationLimit = 15;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  # -bore explicitly: plain linuxPackages_cachyos is now the clang-LTO build
  # with BORE compiled out (no CONFIG_SCHED_BORE, no kernel.sched_bore sysctl).
  boot.kernelPackages = pkgs.linuxPackages_cachyos-bore;

  boot.kernelModules = [
    "nct6775"
    "ath12k"
  ];

  boot.kernelParams = [
    "amd_pstate=active"
    "amdgpu.gpu_recovery=1"
    "pcie_aspm=off"
    "irqaffinity=0,6"
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
    "reboot=pci"
    "mitigations=off"
    # CachyOS defaults HDA codec power-save to 10 s: the ALC897 powers down when
    # idle, so the first sound afterwards is late and pops.
    "snd_hda_intel.power_save=0"
    "snd_hda_intel.power_save_controller=N"
  ];

  boot.blacklistedKernelModules = ["sp5100_tco"];

  # ---------------------------------------------------------------------------
  # GPU (RX 5700 XT Navi 10 gfx1010; config is vendor-generic, no per-card keys)
  # ---------------------------------------------------------------------------
  hardware.amdgpu = {
    # Early KMS: amdgpu binds in stage 1, so tuigreet comes up at native
    # resolution and the DPM tmpfiles rule below never races driver probe.
    initrd.enable = true;
    # Overdrive for LACT. 0xfffd7fff = everything except GFXOFF (0x8000: no
    # GFX power-gating wake stalls) and STUTTER_MODE (0x20000: the display
    # self-refresh mode behind flicker/underflow at high refresh rates).
    overdrive = {
      enable = true;
      ppfeaturemask = "0xfffd7fff";
    };
  };

  # LACT is the ONLY owner of GPU clocks / power profile / fans (no tmpfiles
  # DPM write any more), so the card idles normally. Config is per-GPU (keyed
  # by PCI ID + subsystem + slot) in /etc/lact/config.yaml, left mutable so the
  # GUI can write it; a new card starts from stock settings.
  services.lact.enable = true;

  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.udev.extraRules = ''
    # Any AMD display controller (class 0x03xxxx): no runtime PM / BACO.
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{class}=="0x03*", ATTR{power/control}="on"
    # Qualcomm WCN785x Wi-Fi 7
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1278", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1209", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
  '';

  environment.sessionVariables = {
    AQ_NO_MODIFIERS = lib.mkForce "0";
  };

  # Keep ALSA outputs open (desktop only: costs idle wakeups, irrelevant on
  # mains power). WirePlumber otherwise closes the device after 5 s of silence,
  # and reopening it on the next sound adds startup delay.
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

  # FiiO K7 (UAC2, async, 125 us packets): small ALSA buffer. snd-usb-audio
  # sizes its URB queue from the buffer (nurbs = min(MAX_URBS, urbs/period x
  # periods/buffer)), so with PipeWire's default 32768-frame buffer it keeps
  # ~10 ms of audio on the wire regardless of period size. Measured ALSA delay
  # (silence, pw-cat, median, 2026-11-11):
  #   256 x (32768 buf), headroom 256 (old generic rule)  22.5 ms
  #   128 x (32768 buf), headroom 0                       12.6 ms
  #   128 x 2 (256 buf)                                    9.0 ms
  #    64 x 3 (192 buf)                                    5.9 ms
  # The 192-frame buffer caps the graph quantum at 64 (1.33 ms cycles) while the
  # K7 drives it. 30 s under 12-thread busy load + fsync writes: 0 device xruns.
  # If anything crackles, step back to period-num = 2 with period-size = 128.
  # The K7 has no USB volume control (only a boolean unit), so PipeWire volume
  # is software: leave it at 100% (bit-exact) and use the K7's knob.
  services.pipewire.wireplumber.extraConfig."14-fiio-k7" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "~alsa_output.usb-GuangZhou_FiiO_Electronics_Co._Ltd_FiiO_K7.*";}];
        actions = {
          update-props = {
            "api.alsa.period-size" = 128;
            "api.alsa.period-num" = 3;
            "api.alsa.headroom" = 0;
            # USB inputs default to 2109 vs 1109 for this sink, so in a call the
            # Yeti/C922 would drive the graph at their own (large) quantum and
            # this 192-frame buffer would underrun. The K7 must be the driver.
            "priority.driver" = 3000;
          };
        };
      }
    ];
  };

  # PipeWire's RT data loop on the K7's IRQ core (xHCI completion on cpu9 at
  # FIFO 90 -> data-loop FIFO 88), off the mouse core (6). pipewire-pulse
  # carries Discord/browsers/most Wine audio.
  systemd.user.services.pipewire.serviceConfig.CPUAffinity = "3,9";
  systemd.user.services.pipewire-pulse.serviceConfig.CPUAffinity = "3,9";

  # ---------------------------------------------------------------------------
  # NETWORK
  # ---------------------------------------------------------------------------
  # Applies to whatever wired NIC exists (the onboard RTL8111H is currently
  # disabled in firmware; this is a no-op until it or a PCIe NIC appears).
  systemd.services.optimize-nic = {
    description = "Disable EEE and GRO/LRO on wired NICs";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tune-desktop-nic" ''
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
      size = 8 * 1024; # 8 GiB overflow on disk
      priority = 0; # Low priority: only used when zram fills
    }
  ];

  # Required for post-resume.service (irq-affinity + cpupower resume hooks).
  powerManagement.enable = true;

  systemd.tmpfiles.rules = [
    # 0x41 = CPUs 0 and 6 (physical core 0, = kthreadCpus)
    "w /sys/devices/virtual/workqueue/cpumask - - - - 41"
    "w /sys/bus/workqueue/devices/writeback/cpumask - - - - 41"
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];

  # amd-pstate (active/EPP) only binds when the firmware publishes _CPC. As of
  # BIOS P4.10 with CPPC + CPPC Preferred Cores + Global C-state Control set to
  # Enabled (2026-11-11), the kernel still logged "_CPC object is not present"
  # and CPUID lacked the `cppc` flag, so there is no cpufreq driver and the SMU
  # runs boost on its own (4.84 GHz single-core, unaffected). CPPC and Global
  # C-state Control were then set back to Disabled on purpose. This applies the
  # performance governor (amd-pstate then pins EPP to performance) as soon as a
  # driver exists, and warns until then. With prefcore active the scheduler also
  # starts using the CPPC ranking (ITMT) inside the game-core mask.
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
          echo "cpufreq-performance: WARNING no cpufreq driver (firmware has no _CPC; check BIOS CPPC)" >&2
          exit 0
        fi
        for g in "''${govs[@]}"; do echo performance > "$g"; done
        echo "cpufreq-performance: $(< /sys/devices/system/cpu/cpu1/cpufreq/scaling_driver) -> performance on ''${#govs[@]} policies"
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

  system.stateVersion = "25.11";
}
