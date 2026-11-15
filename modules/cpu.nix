# CPU topology. A host states once which CPUs do what (local.hardware); this
# module derives everything that follows from it: kernel parameters, systemd
# affinity, workqueue masks, the idle-state cap and the frequency governor.
# gaming.nix, irq-affinity.nix, nix.nix and the home profile read the same
# options, so no CPU number is written twice.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.local.hardware;
  inherit (import ./lib.nix {inherit lib;}) cpuListToMask;
  housekeepingMask = cpuListToMask cfg.housekeepingCores;
in {
  options.local.hardware = {
    gameCores = lib.mkOption {
      type = lib.types.str;
      example = "0-7";
      description = "Logical CPU list reserved for latency-critical game threads.";
    };
    gameCoresNoSmt = lib.mkOption {
      type = lib.types.str;
      example = "0,2,4,6";
      description = "One logical CPU per physical game core.";
    };
    backgroundCores = lib.mkOption {
      type = lib.types.str;
      example = "8-19";
      description = "Logical CPU list for system services, the desktop and browsers.";
    };
    housekeepingCores = lib.mkOption {
      type = lib.types.str;
      example = "14-17";
      description = ''
        Subset of backgroundCores for kernel housekeeping: `irqaffinity=` and
        the unbound workqueue masks.
      '';
    };
    allCores = lib.mkOption {
      type = lib.types.str;
      example = "0-11";
      description = "Every logical CPU. Used to let nix-daemon escape backgroundCores.";
    };
    capCstates = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable deep C-states (see capCstatesLatency) at boot and resume; warns if no cpuidle driver.";
    };
    capCstatesLatency = lib.mkOption {
      type = lib.types.ints.positive;
      default = 350;
      description = "With capCstates, disable every idle state whose exit latency is >= this many us.";
    };
    capCstatesCpus = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "8-23";
      description = "With capCstates, the CPU list the cap applies to. null caps every CPU.";
    };
  };

  config = {
    # ---------------------------------------------------------------------------
    # ISOLATION: GAME CORES STAY CLEAR OF SERVICES, IRQS AND KERNEL WORK
    # ---------------------------------------------------------------------------
    boot.kernelParams = [
      # RCU callbacks for the game cores run in rcuo kthreads instead, which
      # irq-affinity.nix moves to kthreadCpus. nohz_full is deliberately not
      # used: it adds user/kernel accounting to every syscall (Wine is syscall-heavy).
      "rcu_nocbs=${cfg.gameCores}"
      # Unmanaged and platform IRQs. The kernel still adds the boot CPU to this
      # mask, which is why irq-affinity.nix sweeps the unlisted IRQs afterwards.
      "irqaffinity=${cfg.housekeepingCores}"
    ];

    # Every service, and everything a login session starts, inherits this mask.
    # Games get off it through the Proton wrapper and the desktop entries
    # (taskset -c gameCores), nix-daemon through its own slice (nix.nix).
    systemd.settings.Manager.CPUAffinity = cfg.backgroundCores;
    systemd.user.settings.Manager.CPUAffinity = cfg.backgroundCores;
    systemd.slices."system".sliceConfig.AllowedCPUs = cfg.backgroundCores;

    # Unbound kernel workqueues (ttm, gfx, events_unbound, writeback).
    systemd.tmpfiles.rules = [
      "w /sys/devices/virtual/workqueue/cpumask - - - - ${housekeepingMask}"
      "w /sys/bus/workqueue/devices/writeback/cpumask - - - - ${housekeepingMask}"
    ];

    # Required for post-resume.service, which runs every resumeCommands hook
    # (C-state cap here, IRQ pins in irq-affinity.nix, ryzenadj on the omnibook).
    powerManagement.enable = true;

    # ---------------------------------------------------------------------------
    # CPUIDLE C-STATE CEILING
    # ---------------------------------------------------------------------------
    # Without a cpuidle driver (firmware publishes no _CST, e.g. desktop BIOS with
    # Global C-state Control off) cores only ever HLT into C1, so there is nothing
    # to cap: warn instead of failing the unit, and start working as soon as the
    # firmware exposes C-states, with no config edit.
    systemd.services.cpu-idle-limit = lib.mkIf cfg.capCstates {
      description = "Cap cpuidle (disable states with exit latency >= capCstatesLatency)";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cpu-idle-limit" ''
          read -r drv < /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || drv=none
          if [ "$drv" = none ]; then
            echo "cpu-idle-limit: WARNING no cpuidle driver bound (firmware has no _CST); cores stay in C0/C1" >&2
            exit 0
          fi
          exec ${config.boot.kernelPackages.cpupower}/bin/cpupower ${lib.optionalString (cfg.capCstatesCpus != null) "-c ${cfg.capCstatesCpus} "}idle-set -D ${toString cfg.capCstatesLatency}
        '';
      };
    };

    powerManagement.resumeCommands = lib.mkIf cfg.capCstates ''
      ${pkgs.systemd}/bin/systemctl restart cpu-idle-limit.service || true
    '';

    # ---------------------------------------------------------------------------
    # FREQUENCY GOVERNOR
    # ---------------------------------------------------------------------------
    # Performance governor on every policy. With amd-pstate or intel_pstate in
    # active (EPP) mode the driver then pins EPP to performance as well, so no
    # separate energy_performance_preference write is needed. A host whose
    # firmware publishes no _CPC (the desktop) has no cpufreq driver at all:
    # warn instead of failing, and start working as soon as one binds.
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
            echo "cpufreq-performance: WARNING no cpufreq driver bound (on AMD: firmware has no _CPC, check BIOS CPPC)" >&2
            exit 0
          fi
          for g in "''${govs[@]}"; do echo performance > "$g"; done
          echo "cpufreq-performance: $(< "''${govs[0]%/*}/scaling_driver") -> performance on ''${#govs[@]} policies"
        '';
      };
    };
  };
}
