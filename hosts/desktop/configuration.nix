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
  # - Physical cores 0-3 (CPUs 0-3,6-9): game main & worker threads
  # - Physical core 4    (CPUs 4,10):    amdgpu IRQ + CRTC workers / HDA audio
  # - Physical core 5    (CPUs 5,11):    xHCI (8 kHz mouse), Wi-Fi, kthreads
  local.hardware = {
    gameCores = "0-3,6-9";
    gameCoresNoSmt = "0-3";
    backgroundCores = "4,5,10,11";
    allCores = "0-11";
    # No cpuidle driver binds (see tmpfiles note below), so `cpupower idle-set`
    # had nothing to act on. Cores already never leave C0/C1.
    capCstates = false;
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
      "driver:amdgpu" = [4]; # dGPU (fence/vblank IRQs)
      "driver:snd_hda_intel" = [10]; # GPU HDMI/DP audio + onboard Realtek HDA
      "driver:xhci_hcd" = [5]; # CPU (Matisse) + chipset xHCI: 8 kHz mouse
      # No ath12k pin: with the IOMMU off (no IRQ remapping) it gets 1 shared MSI
      # vector, which the driver pins to cpu0 and the kernel won't let us move.
      # Enable IOMMU in BIOS to get multi-MSI, then re-add "driver:ath12k_wifi7_pci" = [11].
    };
    defaultCpus = "11";
    crtcCpus = "4,10";
    kthreadCpus = "5,11";
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
    "irqaffinity=5,11"
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
    # No cpufreq governor/EPP rules: the firmware publishes no _CPC/_PSS/_CST
    # (Global C-state Control off drops the CPU power SSDT), so no cpufreq or
    # cpuidle driver binds and those writes were dead. Re-add them (and set
    # local.hardware.capCstates = true) if Global C-state Control is turned on.
    # Boost is unaffected (measured 4.85 GHz, PBO +200).
    # 0x820 = CPUs 5 and 11 (physical core 5)
    "w /sys/devices/virtual/workqueue/cpumask - - - - 820"
    "w /sys/bus/workqueue/devices/writeback/cpumask - - - - 820"
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];

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
