{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # PIN TABLE: PCI FUNCTION -> LOGICAL CPU
  # ---------------------------------------------------------------------------
  # Keyed on the PCI address, never on the irq number. Vector numbers are
  # assigned at probe time and move across kernel versions, firmware updates and
  # s2idle re-enumeration; `0000:c5:00.0` is etched into the SoC's PCIe topology
  # and does not. core.nix already learned this the expensive way -- its xHCI
  # comment block documents a whole tuning decision that was made against a
  # stale irq-number-to-device mapping.
  #
  # Target selection, from /sys/devices/system/cpu topology read 2026-08-31:
  #
  #   cpu0/1   core_id 0    5090 MHz  Zen5    <- left free deliberately
  #   cpu2/3   core_id 1    5090 MHz  Zen5    <- c5:00.0 lands here
  #   cpu4/5   core_id 2    5090 MHz  Zen5    <- c5:00.4 lands here
  #   cpu6/7   core_id 3    5090 MHz  Zen5
  #   cpu8-19  core_id 8-13 3325 MHz  Zen5c   <- where both vectors sit today
  #
  # cpu2 and cpu4 are SMT siblings of *different* physical cores (core_id 1 and
  # 2), so the two controllers do not contend for one core's execution
  # resources. core 0 is skipped because short-lived system work -- timers,
  # kworkers, the first thread the scheduler reaches for -- disproportionately
  # lands there.
  #
  # Only the two busy functions are listed. c3:00.4 (irq 41, 1268 interrupts in
  # 15 h) and c5:00.3 (irq 45, 36 interrupts in the machine's lifetime) are
  # idle; pinning them would move nothing and would cost two more entries that
  # someone would later have to re-verify.
  xhciPins = {
    "0000:c5:00.0" = 2; # usb3/4 -- GameSir G7 Pro, Synaptics fprint, MTK BT
    "0000:c5:00.4" = 4; # usb7/8 -- Anker dock: mouse dongle, ATK kbd, Yeti, RTL8153
  };

  # Shell prologue shared by the apply and the revert script, so both resolve
  # binaries and read effective affinity identically.
  #
  # gnugrep/gawk are referenced by absolute store path rather than by name. A
  # systemd unit's PATH is not a login shell's: if `grep` resolved to nothing
  # the loop below would find zero vectors and the unit would report "device
  # absent" for hardware that is plainly present -- a wrong diagnosis, which is
  # worse than a crash. `cat` is deliberately not used at all; bash's `read`
  # builtin covers every sysfs read here, so this pulls in no coreutils.
  scriptPrologue = ''
    set -u

    grep_bin=${pkgs.gnugrep}/bin/grep
    awk_bin=${pkgs.gawk}/bin/awk

    # All vectors belonging to one PCI function. /proc/interrupts formats the
    # chip name as "IR-PCI-MSIX-0000:c5:00.0", so a fixed-string match on the
    # address selects exactly that function's rows; splitting on ':' and taking
    # field 1 yields the irq number, because the first colon on the line is the
    # one after the vector number. xHCI normally holds a single MSI-X vector per
    # function, but the loop handles several so a multi-vector controller does
    # not get half-pinned. Cross-check against /sys/bus/pci/devices/<addr>/msi_irqs
    # if this ever looks wrong.
    vectors_of() {
      "$grep_bin" -F -- "$1" /proc/interrupts \
        | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'
    }

    # smp_affinity_list is a *permission* mask; on x86 with interrupt remapping
    # a given MSI vector is delivered to exactly one CPU, and which one that is
    # lives in effective_affinity_list. Every success/failure message below
    # reports the effective CPU, because a mask that was accepted while delivery
    # stayed put is the specific failure mode worth catching.
    effective_cpu() {
      local eff
      if read -r eff < "/proc/irq/$1/effective_affinity_list" 2>/dev/null; then
        echo "$eff"
      else
        echo "?" # CONFIG_GENERIC_IRQ_EFFECTIVE_AFF_MASK not built in
      fi
    }
  '';

  # --- ExecStart -------------------------------------------------------------
  pinScript = pkgs.writeShellScript "xhci-irq-pin" ''
    ${scriptPrologue}

    fail=0

    pin() {
      local pci=$1 cpu=$2 found=0 irq eff

      for irq in $(vectors_of "$pci"); do
        found=1

        if [ ! -e "/proc/irq/$irq/smp_affinity_list" ]; then
          echo "xhci-irq-pin: $pci: irq $irq has no smp_affinity_list" >&2
          fail=1
          continue
        fi

        # No 2>/dev/null here on purpose: when the kernel refuses the write the
        # errno text ("Input/output error" for a kernel-managed vector,
        # "Invalid argument" for an offline cpu) is the single most useful line
        # in the journal, and swallowing it is how an affinity pin becomes a
        # silent no-op. core.nix records amdgpu's vector doing exactly this.
        if ! echo "$cpu" > "/proc/irq/$irq/smp_affinity_list"; then
          echo "xhci-irq-pin: $pci: irq $irq REJECTED write of cpu$cpu, still delivering to cpu$(effective_cpu "$irq")" >&2
          fail=1
          continue
        fi

        eff=$(effective_cpu "$irq")
        if [ "$eff" = "$cpu" ]; then
          echo "xhci-irq-pin: $pci: irq $irq pinned to cpu$cpu (effective cpu$eff)"
        else
          # The mask write returned success but delivery did not follow it.
          echo "xhci-irq-pin: $pci: irq $irq accepted cpu$cpu but effective affinity is cpu$eff" >&2
          fail=1
        fi
      done

      if [ "$found" -eq 0 ]; then
        echo "xhci-irq-pin: $pci: no vector in /proc/interrupts -- controller absent or renamed" >&2
        fail=1
      fi
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (pci: cpu: ''pin "${pci}" ${toString cpu}'')
      xhciPins)}

    # Non-zero exit puts the unit in `failed`, so `systemctl status
    # xhci-irq-pin` is a one-glance answer to "did the pin take". A missing
    # controller counts as a failure too: both of these are soldered-down root
    # complex functions, so absence means the assumption this module is built on
    # has changed, not that a peripheral was unplugged.
    exit "$fail"
  '';

  # --- ExecStop --------------------------------------------------------------
  # A oneshot that writes to /proc has no implicit undo. Without this, removing
  # the module (or rolling back the generation) would stop *creating* the pin
  # while cpu2/cpu4 stayed live in the running kernel until the next reboot --
  # so an A/B test would measure the pinned config while believing it had
  # reverted. Restoring the online-cpu mask is what makes the rollback real.
  #
  # ExecStop rather than ExecStopPost: it runs only after a successful start, so
  # a failed run leaves its partial state on the machine to be inspected instead
  # of erasing the evidence. `systemctl stop xhci-irq-pin` is therefore the
  # live, no-reboot revert.
  unpinScript = pkgs.writeShellScript "xhci-irq-unpin-managed" ''
    ${scriptPrologue}

    # "0-19" here. Read from the kernel rather than computed from nproc so an
    # offline cpu can never end up in the mask (that write returns EINVAL).
    read -r online < /sys/devices/system/cpu/online

    unpin() {
      local pci=$1 irq
      for irq in $(vectors_of "$pci"); do
        if echo "$online" > "/proc/irq/$irq/smp_affinity_list"; then
          echo "xhci-irq-pin: $pci: irq $irq released to $online (kernel chose cpu$(effective_cpu "$irq"))"
        else
          echo "xhci-irq-pin: $pci: irq $irq release REJECTED, left on cpu$(effective_cpu "$irq")" >&2
        fi
      done
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (pci: _: ''unpin "${pci}"'')
      xhciPins)}

    # Deliberately always succeeds: a stop that fails would leave the unit in a
    # state systemd will not cleanly restart, and resume re-runs it every cycle.
    exit 0
  '';
in {
  # ---------------------------------------------------------------------------
  # xHCI INTERRUPT AFFINITY (PINNED TO ZEN5 -- HYPOTHESIS UNDER TEST, 2026-08-31)
  # ---------------------------------------------------------------------------
  # WHAT THIS DOES
  # Moves the two busy xHCI controllers' MSI-X vectors off the Zen5c dense cores
  # the kernel picked for them and onto two separate Zen5 performance cores.
  #
  # THE OBSERVATION
  # /proc/interrupts, 15 h uptime, 2026-08-31:
  #
  #   irq 43  0000:c5:00.0  cpu16 (Zen5c, 3325 MHz)  49,928,896 total
  #   irq 47  0000:c5:00.4  cpu18 (Zen5c, 3325 MHz)  19,598,429 total
  #
  # Both of the system's high-rate interrupt sources are being serviced by its
  # slowest threads, at roughly 1.5x the wall-clock cost per handler invocation
  # that a Zen5 core would pay for the same work.
  #
  # WHY THEY ARE ON ZEN5C, AND WHY THAT IS NOT "STATIC PLACEMENT"
  # irqbalance is not running, but nothing pinned these either. core.nix's
  # xhci-irq-unpin unit writes the full 0-19 mask to every xhci vector at boot
  # and again after every resume; cpu16/cpu18 are simply where the kernel's
  # own vector allocator landed when handed a wide-open mask. Widening a mask on
  # x86 does not spread a vector -- MSI delivery targets exactly one CPU -- it
  # only delegates the choice. That is why this module pins to a single logical
  # CPU rather than to a range.
  #
  # THE COST, STATED HONESTLY -- AND ONE CORRECTION TO THE PREMISE
  # The counter-argument is that this parks interrupt work on the same four fast
  # cores Rocket League's UE3 render thread wants. That is the right thing to
  # worry about, but the magnitude in the brief ("~70M interrupts/second") is a
  # misread of a cumulative counter. Averaged over the same 15 h uptime:
  #
  #   irq 43   924 /s      irq 47   363 /s      (~1300 /s combined)
  #
  # ~1300 interrupts/sec is a sub-0.1% duty cycle on one Zen5 core, consistent
  # with core.nix's independent measurement (1000.4 /s and 1008.8 /s) and with a
  # 1 kHz controller plus a mouse whose 8 kHz mode is not actually engaging.
  # The real exposure is not handler CPU time, it is *placement*: `threadirqs`
  # is on the kernel command line (hosts/omnibook/configuration.nix), so each
  # vector's bottom half runs in a SCHED_FIFO priority 50 kthread --
  #
  #   $ ps -eo pid,cls,rtprio,psr,comm | grep irq/4
  #     239  FF  50  16  irq/43-xhci_hcd
  #     241  FF  50  18  irq/47-xhci_hcd
  #
  # -- and an FIFO-50 thread preempts the render thread unconditionally whenever
  # it wakes. Moving it from cpu16 to cpu2 moves those preemptions from a core
  # the game does not care about onto one it does. Short preemptions, but on the
  # critical path. Hence: isolated module, real teardown, measured empirically.
  #
  # ROLLBACK
  #   nixos-rebuild switch --rollback     (ExecStop restores the 0-19 mask)
  #   systemctl stop xhci-irq-pin         (same, live, no rebuild)
  # Removing the import line from hosts/omnibook/configuration.nix also
  # un-masks core.nix's xhci-irq-unpin, restoring the previous baseline exactly.

  # ---------------------------------------------------------------------------
  # IRQBALANCE MUST STAY OFF
  # ---------------------------------------------------------------------------
  # Not running today, declared anyway. irqbalance's entire job is to rewrite
  # smp_affinity on a timer; if anything ever pulls it in as a dependency it
  # would migrate these vectors back off cpu2/cpu4 within ~10 s of boot and this
  # module would appear to have done nothing. Declaring it false also means that
  # if some future module sets it true, evaluation fails with a conflict rather
  # than one setting quietly winning.
  services.irqbalance.enable = false;

  # ---------------------------------------------------------------------------
  # MASK THE OPPOSING UNIT IN core.nix
  # ---------------------------------------------------------------------------
  # modules/core.nix defines xhci-irq-unpin, which writes the all-CPU mask to
  # every xhci vector at boot AND is restarted from powerManagement.resumeCommands
  # after every s2idle cycle. Left enabled it does not merely race this module,
  # it reliably beats it: the boot-time ordering happens to favour us (a unit
  # WantedBy a target is implicitly ordered Before it), but the resume hook runs
  # unconditionally afterwards, so the pin would survive exactly until the first
  # time the lid closed and then silently revert.
  #
  # Masking it here rather than deleting it from core.nix is what keeps this
  # module a single-file, independently revertible change: drop the import and
  # the unpin baseline comes back on its own, comments and rationale intact.
  # core.nix's resume hook is written `|| true`, so its restart of a masked unit
  # is a harmless no-op.
  systemd.services.xhci-irq-unpin.enable = false;

  # ---------------------------------------------------------------------------
  # THE PINNING UNIT
  # ---------------------------------------------------------------------------
  systemd.services.xhci-irq-pin = {
    description = "Pin busy xHCI controller IRQs to Zen5 performance cores";

    # DEVIATION FROM THE BRIEF, DELIBERATE: this asks for After=multi-user.target
    # but is ordered after systemd-modules-load.service instead. `WantedBy` a
    # target implies `Before` that target -- verified on this machine:
    #
    #   $ systemctl show xhci-irq-unpin.service -p Before
    #   Before=multi-user.target
    #
    # so WantedBy=multi-user.target together with After=multi-user.target is a
    # two-node ordering cycle. systemd breaks cycles by deleting a job, and the
    # job it deletes would be this one: the unit would never run, with only a
    # "Found ordering cycle" line in the boot log to show for it -- the exact
    # silent no-op this module is built to avoid. systemd-modules-load is the
    # same anchor core.nix uses and is far later than the PCI probe that
    # allocates these vectors, which is all the ordering this actually needs.
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pinScript;
      ExecStop = unpinScript;
    };
  };

  # An s2idle cycle can re-enumerate the xHCI controllers, reallocate their
  # vectors and hand them a fresh default mask, so the boot-time write cannot be
  # trusted to hold across a lid close. Matching by PCI address means the
  # re-run picks up new irq numbers by itself. Same pattern, and same reasoning,
  # as the unit this replaces.
  #
  # (resumeCommands is types.lines: this concatenates with the SMU/EPP block in
  # hosts/omnibook/configuration.nix and core.nix's own hook rather than
  # clashing with them.)
  powerManagement.resumeCommands = ''
    ${pkgs.systemd}/bin/systemctl restart xhci-irq-pin.service || true
  '';
}
