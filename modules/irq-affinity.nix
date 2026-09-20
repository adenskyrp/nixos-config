{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # PIN TABLE: PCI FUNCTION -> ZEN 5C LOGICAL CPU (CPUs 8-19)
  # ---------------------------------------------------------------------------
  devicePins = {
    # xHCI / USB Controllers
    "0000:c5:00.0" = 8;  # usb3/4 -- GameSir G7 Pro, Synaptics fprint, MTK BT
    "0000:c5:00.4" = 10; # usb7/8 -- Anker dock: mouse dongle, ATK kbd, Yeti, RTL8153
    
    # Network
    "0000:c2:00.0" = 12; # MediaTek MT7925 802.11be Wi-Fi
    
    # Audio Subsystem
    "0000:c3:00.6" = 14; # AMD Ryzen HD Audio Controller
    "0000:c3:00.1" = 16; # Radeon HD Audio Controller (HDMI/DP)
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
      local pci=$1 cpu=$2 found=0 irq eff

      for irq in $(vectors_of "$pci"); do
        found=1
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

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (pci: cpu: ''pin "${pci}" ${toString cpu}'') devicePins)}

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
    description = "Pin peripheral IRQs (USB, NVMe, Net, Audio) to Zen 5c cores";
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
