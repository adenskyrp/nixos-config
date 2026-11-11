# modules/irq-affinity.nix
#
# Static IRQ / kthread pinning, shared by every host (replaces irqbalance).
# Each host supplies its own pin table via `local.irqAffinity`.
#
# Pin keys are an exact PCI function ("0000:c3:00.0"), "driver:<name>", which
# expands at runtime to every PCI function currently bound to that driver, or
# "pci:<vendor>:<device>" (e.g. "pci:1022:149c"), every function with that ID.
# Prefer driver keys, then ID keys (for two controllers sharing a driver): both
# survive GPU swaps, BIOS updates, and slot moves that renumber PCI buses (a
# hardcoded-BDF table on the desktop silently pinned nothing for months because
# of exactly that).
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.local.irqAffinity;

  scriptPrologue = ''
    set -u
    grep_bin=${pkgs.gnugrep}/bin/grep
    awk_bin=${pkgs.gawk}/bin/awk

    # "driver:amdgpu" -> every bound PCI function; "pci:1022:149c" -> every
    # function with that vendor:device ID; "0000:07:00.0" -> itself.
    functions_of() {
      local key=$1 dev id want vendor device
      case "$key" in
        driver:*)
          for dev in /sys/bus/pci/drivers/"''${key#driver:}"/0000:*; do
            [ -e "$dev" ] && basename "$dev"
          done
          ;;
        pci:*)
          id=''${key#pci:}
          want="0x''${id%%:*}:0x''${id#*:}"
          for dev in /sys/bus/pci/devices/0000:*; do
            read -r vendor < "$dev/vendor" && read -r device < "$dev/device" || continue
            [ "$vendor:$device" = "$want" ] && basename "$dev"
          done
          ;;
        *) echo "$key" ;;
      esac
    }

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

    # "14-17" / "5,11" -> hex bitmask for /proc/irq/default_smp_affinity
    cpulist_to_mask() {
      local mask=0 part a b i
      local IFS=,
      for part in $1; do
        a=''${part%-*}
        b=''${part#*-}
        for ((i = a; i <= b; i++)); do mask=$((mask | (1 << i))); done
      done
      printf '%x' "$mask"
    }
  '';

  pinLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      key: cpus: ''pin "${key}" ${lib.concatMapStringsSep " " toString cpus}''
    )
    cfg.pins
  );

  pinScript = pkgs.writeShellScript "hardware-irq-pin" ''
    ${scriptPrologue}
    fail=0

    ${lib.optionalString (cfg.defaultCpus != null) ''
      # The kernel force-adds the boot CPU (cpu0) to irqaffinity=, so without
      # this sweep every IRQ not in the pin table lands on cpu0 -- a game core.
      # Managed IRQs (NVMe per-queue vectors) reject the write; that is fine,
      # they only fire on the CPU that submitted the I/O.
      echo "$(cpulist_to_mask "${cfg.defaultCpus}")" 2>/dev/null > /proc/irq/default_smp_affinity || true
      for d in /proc/irq/[0-9]*; do
        echo "${cfg.defaultCpus}" 2>/dev/null > "$d/smp_affinity_list" || true
      done
      echo "hardware-irq-pin: default + unlisted movable IRQs -> cpu ${cfg.defaultCpus}"
    ''}

    pin() {
      local key=$1
      shift
      local cpus=("$@")
      local n_cpus=''${#cpus[@]}
      local idx=0 found=0 fn irq cpu eff

      for fn in $(functions_of "$key"); do
        for irq in $(vectors_of "$fn"); do
          found=1
          cpu=''${cpus[$((idx % n_cpus))]}
          idx=$((idx + 1))

          if ! echo "$cpu" 2>/dev/null > "/proc/irq/$irq/smp_affinity_list"; then
            echo "hardware-irq-pin: $key ($fn): irq $irq REJECTED cpu$cpu, still on cpu$(effective_cpu "$irq")" >&2
            fail=1
            continue
          fi

          eff=$(effective_cpu "$irq")
          if [ "$eff" = "$cpu" ]; then
            echo "hardware-irq-pin: $key ($fn): irq $irq -> cpu$cpu"
          elif [ "$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)" = "$cpu" ]; then
            # Without interrupt remapping, x86 moves an MSI lazily from inside its
            # next interrupt, so an idle vector keeps its old effective CPU until
            # it fires. The request is stored; that is success.
            echo "hardware-irq-pin: $key ($fn): irq $irq -> cpu$cpu (pending; effective cpu$eff until next interrupt)"
          else
            echo "hardware-irq-pin: $key ($fn): irq $irq accepted cpu$cpu but effective is cpu$eff" >&2
            fail=1
          fi
        done
      done

      if [ "$found" -eq 0 ]; then
        echo "hardware-irq-pin: $key: no vector in /proc/interrupts -- absent, unbound, or renamed" >&2
        fail=1
      fi
    }

    ${pinLines}

    ${lib.optionalString (cfg.xhciThreadPriority != null) ''
      # threadirqs: raise xHCI IRQ threads above the SCHED_FIFO 50 default so
      # 8 kHz mouse reports are never queued behind other threaded handlers.
      for pid in $(${pkgs.procps}/bin/pgrep -f 'irq/.*-xhci_hcd' || true); do
        ${pkgs.util-linux}/bin/chrt -f -p ${toString cfg.xhciThreadPriority} "$pid" 2>/dev/null || true
      done
    ''}

    # amdgpu DRM atomic-commit (SCHED_FIFO) CRTC workers share L1/L2 with the
    # amdgpu IRQ and stay off the game cores.
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^card[0-9]+-crtc/ {print $1}'); do
      if ${pkgs.util-linux}/bin/taskset -pc ${cfg.crtcCpus} "$pid" >/dev/null 2>&1; then
        echo "hardware-irq-pin: DRM worker pid $pid pinned to cpu ${cfg.crtcCpus}"
      fi
    done

    # Movable non-per-CPU kernel daemons -> kthreadCpus. rcuo[gp]/N are the
    # RCU callback-offload threads created for the rcu_nocbs= CPUs (core.nix);
    # left unpinned they could run the offloaded work right back on game cores.
    for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^(jbd2\/|kswapd|kcompactd|khugepaged|ksmd|kauditd|khungtaskd|psimon|hwrng|watchdogd|usb-storage|scsi_eh_|kdevtmpfs|rcuo)/ {print $1}'); do
      ${pkgs.util-linux}/bin/taskset -pc ${cfg.kthreadCpus} "$pid" >/dev/null 2>&1 || true
    done
    echo "hardware-irq-pin: movable kthreads -> cpu ${cfg.kthreadCpus}"

    exit "$fail"
  '';

  unpinScript = pkgs.writeShellScript "hardware-irq-unpin" ''
    ${scriptPrologue}
    read -r online < /sys/devices/system/cpu/online
    for key in ${lib.escapeShellArgs (lib.attrNames cfg.pins)}; do
      for fn in $(functions_of "$key"); do
        for irq in $(vectors_of "$fn"); do
          echo "$online" 2>/dev/null > "/proc/irq/$irq/smp_affinity_list" || true
        done
      done
    done
    exit 0
  '';
in {
  options.local.irqAffinity = {
    enable = lib.mkEnableOption "static IRQ, DRM CRTC worker, and kthread pinning";

    pins = lib.mkOption {
      type = with lib.types; attrsOf (nonEmptyListOf ints.unsigned);
      default = {};
      example = {
        "driver:amdgpu" = [4];
        "0000:c2:00.0" = [12 18];
      };
      description = ''
        IRQ pin table. Key: a PCI function address, `driver:<name>` (all PCI
        functions bound to that driver) or `pci:<vendor>:<device>` (all
        functions with that PCI ID, lowercase hex). Value: CPUs; a device's
        vectors are spread round-robin across the list.
      '';
    };

    defaultCpus = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "14-17";
      description = ''
        CPU list for /proc/irq/default_smp_affinity and every movable IRQ not in
        `pins`. Needed because `irqaffinity=` always gets the boot CPU added.
      '';
    };

    crtcCpus = lib.mkOption {
      type = lib.types.str;
      description = "CPU list for amdgpu `cardN-crtcM` atomic-commit kthreads.";
    };

    kthreadCpus = lib.mkOption {
      type = lib.types.str;
      default = config.local.hardware.backgroundCores;
      defaultText = lib.literalExpression "config.local.hardware.backgroundCores";
      description = "CPU list for movable housekeeping kthreads (jbd2, kswapd, ...).";
    };

    xhciThreadPriority = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 1 99);
      default = null;
      description = "If set, SCHED_FIFO priority for xHCI threaded IRQ handlers.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.irqbalance.enable = false;

    systemd.services.hardware-irq-pin = {
      description = "Pin peripheral IRQs, DRM CRTC workers, and kthreads";
      wantedBy = ["multi-user.target"];
      # sound.target / network.target: wait for the udev-loaded drivers
      # (snd_hda_intel, ath12k) to bind so their vectors exist.
      after = ["systemd-modules-load.service" "systemd-udev-trigger.service" "sound.target" "network.target"];

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

    # ath11k/ath12k re-set their MSI affinity hint to cpu0 whenever the firmware
    # (re)starts, which happens after the boot-time pin has already run. Re-pin
    # every time a Wi-Fi link comes up.
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        type = "basic";
        source = pkgs.writeShellScript "irq-repin-on-wifi-up" ''
          case "$1:$2" in
            wl*:up) ${pkgs.systemd}/bin/systemctl --no-block restart hardware-irq-pin.service ;;
          esac
        '';
      }
    ];
  };
}
