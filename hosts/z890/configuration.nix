# iBUYPOWER Z890 (ASUS board): Core Ultra 7 270K Plus (8 P-cores + 16 E-cores,
# no SMT), NVIDIA RTX 5070, MediaTek MT7925 Wi-Fi 7, no wired NIC.
#
# First written from hosts/desktop without access to the machine, then checked
# against it on 2026-11-15: CPU numbering, IRQ table, monitor connector, IOMMU
# mode, idle-state cap and Vulkan driver path. Lines still marked VERIFY have
# not been checked.
{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/gpu/nvidia.nix
    ../../modules/stationary.nix
  ];

  # VERIFY: set this to the NixOS release of the installer you use and never
  # change it afterwards.
  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # CPU TOPOLOGY
  # ---------------------------------------------------------------------------
  # CPUs 0-7 are the P-cores, 8-23 the E-cores, and E-cores share an L2 in
  # clusters of four (8-11, 12-15, 16-19, 20-23). z890-topology-check confirms
  # this at every boot and fails if a firmware update ever renumbers them.
  # - P-cores 0-7: games. cpu0 still takes boot-CPU-only kernel work; if that
  #   shows up in frametimes, try gameCores = "1-7".
  # - E cluster 8-11: nvidia IRQ and the NVIDIA kernel threads.
  # - E cluster 12-15: xHCI (mouse, keyboard, K7), PipeWire.
  # - E cluster 16-19: Wi-Fi IRQ on 16.
  # - E cluster 20-23: default IRQs, kthreads, workqueues.
  # AAA titles with more than 8 busy threads may prefer gameCores = "0-15".
  local.hardware = {
    gameCores = "0-7";
    gameCoresNoSmt = "0-7";
    backgroundCores = "8-23";
    housekeepingCores = "20-23";
    allCores = "0-23";
    # C-state cap on the E-cores only. Every IRQ, PipeWire and the compositor
    # live there, so a deep idle state on those CPUs is wake-up latency on the
    # mouse, audio and GPU-interrupt paths. It costs no clock: this CPU's
    # turbo table is 55x for up to 2 active P-cores, 54x for up to 8, and a
    # flat 47x for the E-cores, and the P and E limits are counted separately.
    # The P-cores stay uncapped so a 1-2 thread game (osu!) keeps the 55x bin,
    # which needs the other P-cores out of C0/C1. Latency 2 leaves POLL + C1.
    # Confirmed in sysfs: the states are POLL, C1_ACPI, C2_ACPI, C3_ACPI; cpu8
    # has C2/C3 disabled, cpu0 has none disabled.
    capCstates = true;
    capCstatesLatency = 2;
    capCstatesCpus = "8-23";
  };

  # Nothing else would notice a different CPU numbering: games would just be
  # pinned to E-cores. Fail a unit at boot instead. Passes on this machine.
  systemd.services.z890-topology-check = {
    description = "Verify the CPU numbering this host's core lists assume";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "z890-topology-check" ''
        fail=0
        expect() {
          local got
          if ! read -r got < "$1" 2>/dev/null; then
            echo "z890-topology-check: $1 is missing" >&2
            fail=1
          elif [ "$got" != "$2" ]; then
            echo "z890-topology-check: $1 is '$got', this host assumes '$2'" >&2
            fail=1
          fi
        }
        expect /sys/devices/cpu_core/cpus 0-7
        expect /sys/devices/cpu_atom/cpus 8-23
        for first in 8 12 16 20; do
          expect "/sys/devices/system/cpu/cpu$first/cache/index2/shared_cpu_list" "$first-$((first + 3))"
        done
        if [ "$fail" -eq 0 ]; then
          echo "z890-topology-check: P-cores 0-7, E-cores 8-23 in L2 clusters of four"
        fi
        exit "$fail"
      '';
    };
  };

  # Checked on the machine on 2026-11-15 (lspci -nnk, lsusb -t,
  # /proc/interrupts, the unit's journal):
  # - 02:00.0 RTX 5070: 8 MSI-X vectors, two of them active. They exist before
  #   this unit runs at boot.
  # - 80:14.0 chipset xHCI [8086:7f6e]: every USB device is on it (two
  #   high-speed HID devices, the K7 and the Yeti behind a hub, webcam, tablet,
  #   Bluetooth). 00:0d.0 CPU xHCI [8086:7ec0] serves the Thunderbolt ports and
  #   had raised no interrupt. Its root hub has a single USB 2 port, so a USB 2
  #   device on a Thunderbolt port presumably still lands on the chipset
  #   controller: check `lsusb -t` before assuming mouse and K7 can be split
  #   across controllers the way hosts/desktop does. One driver key covers both.
  # - 83:00.0 MediaTek MT7925 Wi-Fi 7, the only network device: one MSI vector.
  # - 02:00.1 GPU HDMI/DP audio is the only snd_hda_intel device and uses a
  #   legacy IO-APIC line (IRQ 17). The pin table finds vectors by PCI address,
  #   which only MSI lines carry, so it has no pin and follows the default
  #   sweep to cpu20.
  local.irqAffinity = {
    enable = true;
    pins = {
      "driver:nvidia" = [8];
      "driver:xhci_hcd" = [12];
      "driver:mt7925e" = [16];
    };
    defaultCpus = "20";
    # For the NVIDIA kernel threads (gpuKthreadPattern in gpu/nvidia.nix).
    crtcCpus = "8-11";
    kthreadCpus = "20-23";
    xhciThreadPriority = 90;
  };

  # PipeWire on the xHCI cluster, off the game cores.
  systemd.user.services.pipewire.serviceConfig.CPUAffinity = "12-15";
  systemd.user.services.pipewire-pulse.serviceConfig.CPUAffinity = "12-15";

  # ---------------------------------------------------------------------------
  # KERNEL
  # ---------------------------------------------------------------------------
  # intel_pstate binds in active (HWP) mode by default; no parameter needed.
  boot.kernelParams = [
    # DMA bypasses the IOMMU. Without it every USB transfer (8 kHz mouse, K7
    # isochronous audio) and Wi-Fi packet pays an IOVA map/unmap. Same trust
    # trade as mitigations=off. dmesg confirms "iommu: Default domain type:
    # Passthrough". Interrupt remapping is not in use here (/proc/interrupts
    # shows plain PCI-MSI), which is why a re-pinned idle vector reports
    # "pending" until it next fires.
    "iommu.passthrough=1"
  ];

  boot.kernelModules = [
    "i2c-dev" # decode-dimms (SPD read-out)
    "spd5118"
    # VERIFY: add the Super I/O sensor driver `sensors-detect` reports
    # (ASUS Z890 boards are usually nct6775).
  ];

  # ---------------------------------------------------------------------------
  # GPU (RTX 5070, modules/gpu/nvidia.nix)
  # ---------------------------------------------------------------------------
  # The card is the only DRM device (card1; the iGPU is off in the firmware)
  # and the panel is on DP-1, which is what stationary.nix assumes.
}
