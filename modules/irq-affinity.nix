# modules/irq-affinity.nix
{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # PIN TABLE: PCI FUNCTION -> ZEN 5C LOGICAL CPU(S) (CPUs 8-19)
  # ---------------------------------------------------------------------------
  # - CPUs 8-9   (Zen 5c Core 1): Radeon 880M (c3:00.0), DP Audio (c3:00.1), card*-crtc*
  # - CPUs 10-11 (Zen 5c Core 2): 8kHz USB dock (c5:00.4) on 10, internal USB (c5:00.0) on 11
  # - CPUs 12-13 (Zen 5c Core 3): Wi-Fi 7 (c2:00.0) even MSI-X vectors on 12
  # - CPUs 14-17 (Zen 5c Cores 4-5): Userspace backgroundCores, systemd, workqueues, kthreads
  # - CPUs 18-19 (Zen 5c Core 6): Wi-Fi 7 (c2:00.0) odd MSI-X vectors on 18
  devicePins = {
    # Graphics / Display Engine (600Hz vblank + RADV fence completions)
    "0000:c3:00.0" = [8]; # Radeon 880M (amdgpu)
    "0000:c3:00.1" = [9]; # Radeon HD Audio Controller (HDMI/DP)

    # xHCI / USB Controllers
    "0000:c5:00.4" = [10]; # usb7/8 -- Anker dock: 8kHz mouse, ATK kbd, Yeti
    "0000:c5:00.0" = [11]; # usb3/4 -- GameSir G7 Pro, Synaptics fprint, BT

    # Network (Qualcomm WCN785x / FastConnect 7800 Wi-Fi 7, 15 MSI-X vectors)
    "0000:c2:00.0" = [12 18];

    # Audio Subsystem
    "0000:c3:00.6" = [14]; # AMD Ryzen HD Audio Controller
  };

  scriptPrologue = ''
    set -u
    grep_bin=${pkgs.gnugrep}/bin/grep
    awk_bin=${pkgs.gawk}/bin/awk

    vectors_of() {
      "$grep_bin" -F -- "$1" /proc/interrupts \
        | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'
    }

    effective_cpu() {
      local eff
      if read -r eff < "/proc/irq/$1/effective_affinity_list" 2>/dev/null; then
        echo "$eff"
      else
        echo "?"
      fi
    }
  '';

  pinScript = pkgs.writeShellScript "hardware-irq-pin" ''
    ${scriptPrologue}
    fail=0

    pin() {
      local pci=$1
      shift
      local cpus=("$@")
      local n_cpus=''${#cpus[@]}
      local idx=0 found=0 irq cpu eff

      for irq in $(vectors_of "$pci"); do
        found=1
        cpu=''${cpus[$((idx % n_cpus))]}
        idx=$((idx + 1))

        if [ ! -e "/proc/irq/$irq/smp_affinity_list" ]; then
          echo "hardware-irq-pin: $pci: irq $irq has no smp_affinity_list" >&2
          fail=1
          continue
        fi

        if ! echo "$cpu" > "/proc/irq/$irq/smp_affinity_list"; then
          echo "hardware-irq-pin: $pci: irq $irq REJECTED write of cpu$cpu, still delivering to cpu$(effective_cpu "$irq")" >&2
          fail=1
          continue
        fi

        eff=$(effective_cpu "$irq")
        if [ "$eff" = "$cpu" ]; then
          echo "hardware-irq-pin: $pci: irq $irq pinned to cpu$cpu (effective cpu$eff)"
        else
          echo "hardware-irq-pin: $pci: irq $irq accepted cpu$cpu but effective affinity is cpu$eff" >&2
          fail=1
        fi
      done

      if [ "$found" -eq 0 ]; then
        echo "hardware-irq-pin: $pci: no vector in /proc/interrupts -- absent or renamed" >&2
        fail=1
      fi
    }

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        pci: cpus: let
          cpuList = lib.toList cpus;
        in ''pin "${pci}" ${lib.concatMapStringsSep " " toString cpuList}''
      )
      devicePins
    )}

    # Pin amdgpu DRM atomic-commit real-time (SCHED_FIFO 50) CRTC workers to
    # CPUs 8-9 so they share L1/L2 cache with irq/141-amdgpu (cpu8) and never
    # preempt Wi-Fi 7 (cpu12), 8kHz USB (cpu10), or Zen 5 game cores (0-7).
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^card[0-9]+-crtc/ {print $1}'); do
      if ${pkgs.util-linux}/bin/taskset -pc 8-9 "$pid" >/dev/null 2>&1; then
        echo "hardware-irq-pin: DRM worker pid $pid ($(cat /proc/$pid/comm 2>/dev/null || echo ?)) pinned to cpu 8-9"
      fi
    done

    # Sweep movable non-per-CPU kernel daemons (ext4 jbd2 journal, kswapd0,
    # kcompactd0, khugepaged, ksmd, kauditd, khungtaskd, psimon, hwrng,
    # watchdogd, usb-storage, scsi_eh, kdevtmpfs) onto backgroundCores (14-17).
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^(jbd2\/|kswapd|kcompactd|khugepaged|ksmd|kauditd|khungtaskd|psimon|hwrng|watchdogd|usb-storage|scsi_eh_|kdevtmpfs)/ {print $1}'); do
      if ${pkgs.util-linux}/bin/taskset -pc ${config.local.hardware.backgroundCores} "$pid" >/dev/null 2>&1; then
        echo "hardware-irq-pin: kthread pid $pid ($(cat /proc/$pid/comm 2>/dev/null || echo ?)) pinned to cpu ${config.local.hardware.backgroundCores}"
      fi
    done

    exit "$fail"
  '';

  unpinScript = pkgs.writeShellScript "hardware-irq-unpin" ''
    ${scriptPrologue}
    read -r online < /sys/devices/system/cpu/online

    unpin() {
      local pci=$1 irq
      for irq in $(vectors_of "$pci"); do
        if echo "$online" > "/proc/irq/$irq/smp_affinity_list"; then
          echo "hardware-irq-pin: $pci: irq $irq released to $online (kernel chose cpu$(effective_cpu "$irq"))"
        else
          echo "hardware-irq-pin: $pci: irq $irq release REJECTED, left on cpu$(effective_cpu "$irq")" >&2
        fi
      done
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (pci: _: ''unpin "${pci}"'') devicePins)}
    exit 0
  '';
in {
  services.irqbalance.enable = false;
  systemd.services.xhci-irq-unpin.enable = false;

  systemd.services.hardware-irq-pin = {
    description = "Pin peripheral IRQs, DRM CRTC workers, and kthreads to Zen 5c cores";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pinScript;
      ExecStop = unpinScript;
    };
  };

  powerManagement.resumeCommands = ''
    ${pkgs.systemd}/bin/systemctl restart hardware-irq-pin.service || true
  '';
}
