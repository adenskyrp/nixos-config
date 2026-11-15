# iBUYPOWER Z890: Core Ultra 7 270K Plus (8 P-cores + 16 E-cores, no SMT),
# NVIDIA RTX 5070.
#
# DRAFT. Written from hosts/desktop without access to the machine: every line
# marked VERIFY must be checked on the live system (lscpu -e, lspci -nnk,
# /proc/interrupts) before it is trusted. hardware-configuration.nix is a
# placeholder too; regenerate it on the box.
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
  # VERIFY the numbering with `lscpu -e=CPU,CORE,MAXMHZ`. This assumes the usual
  # Arrow Lake layout: CPUs 0-7 are the P-cores, 8-23 the E-cores, and E-cores
  # share an L2 in clusters of four (8-11, 12-15, 16-19, 20-23). If the P-cores
  # are not 0-7, every list below must change; z890-topology-check fails at
  # boot if the numbering is different.
  # - P-cores 0-7: games. cpu0 still takes boot-CPU-only kernel work; if that
  #   shows up in frametimes, try gameCores = "1-7".
  # - E cluster 8-11: nvidia IRQ, DRM workers.
  # - E cluster 12-15: xHCI (mouse, K7), PipeWire.
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
    # VERIFY with `cpupower -c 8 idle-info` and `cpupower -c 0 idle-info`.
    capCstates = true;
    capCstatesLatency = 2;
    capCstatesCpus = "8-23";
  };

  # Nothing else would notice a different CPU numbering: games would just be
  # pinned to E-cores. Fail a unit at boot instead.
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

  local.irqAffinity = {
    enable = true;
    pins = {
      "driver:nvidia" = [8];
      # One key for every xHCI until the controllers are identified. VERIFY with
      # `lspci -nnk | grep -A3 -i usb`, then split mouse and audio by
      # "pci:<vendor>:<device>" the way hosts/desktop does.
      "driver:xhci_hcd" = [12];
    };
    defaultCpus = "20";
    # The NVIDIA driver may not create `cardN-crtcM` kthreads at all, in which
    # case this matches nothing.
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
    # DMA bypasses the IOMMU (interrupt remapping stays on). Without it every
    # USB transfer (8 kHz mouse, K7 isochronous audio) and NIC packet pays an
    # IOVA map/unmap. Same trust trade as mitigations=off. No-op if VT-d is off
    # in the BIOS. VERIFY: `dmesg | grep -i 'default domain type'` should say
    # Passthrough.
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
  # VERIFY the iGPU is off: this CPU has one, and if the firmware leaves it
  # enabled Hyprland can pick it as the render device and copy every frame to
  # the NVIDIA outputs. `ls /sys/class/drm` should show a single cardN. If it
  # shows two, disable the iGPU in the BIOS (the "multi-monitor" iGPU option).
  # VERIFY the connector name with `hyprctl monitors`; stationary.nix assumes
  # DP-1 and its catch-all rule covers a different numbering.
}
