# AM4 desktop: Ryzen 5 5600X (6x Zen 3), Radeon RX 5700 XT (Navi 10),
# ASRock B550M-HDV, 32 GB DDR4, Qualcomm WCN785x Wi-Fi 7, FiiO K7 on the
# chipset xHCI.
{...}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/gpu/amd.nix
    ../../modules/stationary.nix
  ];

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # CPU TOPOLOGY (SMT siblings are N and N+6)
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
    housekeepingCores = "0,6";
    allCores = "0-11";
    # Only POLL/C1 (exit latency < 2 us). Zen 3 desktop _CST reports CC6 as
    # "C2" at ~18 us, which the 350 us default would leave enabled. Warns and
    # does nothing while the BIOS publishes no _CST (cpu-idle-limit, cpu.nix).
    capCstates = true;
    capCstatesLatency = 2;
  };

  # Driver-keyed, not BDF-keyed: a GPU swap (and any slot/BIOS change that
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

  # PipeWire's RT data loop on the K7's IRQ core (xHCI completion on cpu9 at
  # FIFO 90 -> data-loop FIFO 88), off the mouse core (6). pipewire-pulse
  # carries Discord/browsers/most Wine audio.
  systemd.user.services.pipewire.serviceConfig.CPUAffinity = "3,9";
  systemd.user.services.pipewire-pulse.serviceConfig.CPUAffinity = "3,9";

  # ---------------------------------------------------------------------------
  # KERNEL
  # ---------------------------------------------------------------------------
  boot.kernelModules = [
    "nct6775"
    "ath12k"
  ];

  boot.kernelParams = [
    # amd-pstate (active/EPP) only binds when the firmware publishes _CPC. As of
    # BIOS P4.10 with CPPC + CPPC Preferred Cores + Global C-state Control set
    # to Enabled (2026-11-11), the kernel still logged "_CPC object is not
    # present" and CPUID lacked the `cppc` flag, so there is no cpufreq driver
    # and the SMU runs boost on its own (4.84 GHz single-core, unaffected).
    # CPPC and Global C-state Control were then set back to Disabled on
    # purpose. cpufreq-performance (cpu.nix) warns every boot until a driver
    # exists; with prefcore active the scheduler would also start using the
    # CPPC ranking (ITMT) inside the game-core mask.
    "amd_pstate=active"
    "amdgpu.gpu_recovery=1"
    "reboot=pci"
  ];

  boot.blacklistedKernelModules = ["sp5100_tco"];

  # ---------------------------------------------------------------------------
  # GPU (RX 5700 XT Navi 10 gfx1010; config is vendor-generic, no per-card keys)
  # ---------------------------------------------------------------------------
  hardware.amdgpu = {
    # Early KMS: amdgpu binds in stage 1, so tuigreet comes up at native
    # resolution. It grows each generation's initrd, hence the /boot entry cap
    # in core.nix.
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

  services.udev.extraRules = ''
    # Any AMD display controller (class 0x03xxxx): no runtime PM / BACO.
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{class}=="0x03*", ATTR{power/control}="on"
    # Qualcomm WCN785x Wi-Fi 7: no runtime PM
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"
  '';
}
