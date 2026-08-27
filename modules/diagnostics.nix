{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.local.diagnostics;

  # ---------------------------------------------------------------------------
  # SHARED SYSFS / PROCFS RESOLUTION
  # ---------------------------------------------------------------------------
  # The amdgpu DRM node is not stably card0 -- on this machine it enumerates as
  # card1, and the index can move across kernel bumps because the simpledrm
  # handover node also claims a slot. Resolve by walking device/driver and
  # matching the driver name, so a renumber degrades to "na" columns rather than
  # silently sampling the wrong device.
  resolveAmdgpu = ''
    amdgpu_node=""
    for c in /sys/class/drm/card*; do
      [ -e "$c/device/driver" ] || continue
      if [ "$(basename "$(readlink -f "$c/device/driver")")" = "amdgpu" ]; then
        amdgpu_node="$c/device"
        break
      fi
    done

    hwmon=""
    if [ -n "$amdgpu_node" ]; then
      for h in "$amdgpu_node"/hwmon/hwmon*; do
        if [ -d "$h" ]; then hwmon="$h"; break; fi
      done
    fi
  '';

  # PSI exposes a monotonic microsecond counter per resource. Pull the total=
  # field off a named line without assuming field order. Always emits a number:
  # the value feeds arithmetic under `set -u`, where an empty expansion is a
  # hard error rather than a zero.
  psiTotal = ''
    psi_total() {
      # $1 = /proc/pressure/<res>, $2 = some|full
      awk -v want="$2" '
        $1 == want {
          for (i = 2; i <= NF; i++)
            if (index($i, "total=") == 1) { sub(/^total=/, "", $i); print $i; found = 1; exit }
        }
        END { if (!found) print 0 }
      ' "$1" 2>/dev/null
    }
  '';

  # /proc/interrupts carries one column per CPU, so a per-line sum has to be
  # bounded by nproc rather than by a hardcoded width -- this box has 20, and
  # the trailing columns are controller/driver names, not counts.
  irqSum = ''
    irq_sum() {
      # $1 = regex selecting the interrupt line(s)
      awk -v n="$(nproc --all)" -v re="$1" '
        $0 ~ re { s = 0; for (i = 2; i <= n + 1; i++) s += $i; t += s }
        END { print t + 0 }
      ' /proc/interrupts
    }
  '';

  # Scaled sysfs read that holds the "na, never 0" convention: an absent or
  # unreadable counter renders as "na" so a missing sensor can never be read as
  # an idle or cold one. This matters more than it looks -- mem_busy_percent
  # genuinely does not exist on this APU, and a 0 in that column would have
  # supported the exact wrong conclusion about memory-bus contention.
  readScaled = ''
    rdna() {
      # $1 = path, $2 = divisor (1 for a raw value)
      if [ ! -r "$1" ]; then echo na; return; fi
      v=$(cat "$1" 2>/dev/null || true)
      if [ -z "$v" ]; then echo na; return; fi
      echo $(( v / $2 ))
    }
  '';

  # The active DPM state is the line flagged with '*'; strip the unit so the
  # column stays numeric for whatever plots this later.
  curDpm = ''
    cur_dpm() {
      awk '/\*/ { gsub(/[^0-9]/, "", $2); print $2; found = 1; exit }
           END { if (!found) print "na" }' "$1" 2>/dev/null
    }
  '';

  # Column order is shared between stutter-trace's output and psi-calibrate's
  # parser. Declared once so the two cannot drift apart silently.
  csvHeader = "ts_ms,d_psi_cpu_some_us,d_psi_io_some_us,d_psi_io_full_us,d_psi_mem_some_us,d_psi_irq_full_us,gpu_busy_pct,mem_busy_pct,vram_used_mb,gtt_used_mb,sclk_mhz,mclk_mhz,gpu_mhz,tctl_c,gpu_w,cpu0_mhz,cpu8_mhz,pswpin,pswpout,d_irq_xhci,d_irq_amdgpu";

  # ---------------------------------------------------------------------------
  # stutter-trace -- CORRELATION SAMPLER
  # ---------------------------------------------------------------------------
  # Writes a wide CSV meant to be lined up against a MangoHud frametime log
  # after the fact. This is the *context* half of the harness: it answers "what
  # was the machine doing around the hitch", not "did a hitch happen". A 2 Hz
  # gauge cannot answer the latter -- see psi-watch below. It is also the only
  # tool here that emits every window unconditionally, which is what makes it,
  # and not psi-watch, the right instrument for calibrating a threshold.
  #
  # Deliberately does not shell out to `ryzenadj -i` in the loop. That reads the
  # SMU mailbox, which is the same mailbox the power governor drives; polling it
  # twice a second during a measurement of power-limit behaviour would perturb
  # the thing being measured. STAPM state is inferred from the sclk/power/Tctl
  # columns instead, cross-checked against MangoHud's throttling_status.
  stutterTrace = pkgs.writeShellApplication {
    name = "stutter-trace";
    runtimeInputs = with pkgs; [coreutils gawk];
    text = ''
      interval="''${1:-0.5}"
      duration="''${2:-0}"   # seconds; 0 = run until interrupted

      ${resolveAmdgpu}
      ${psiTotal}
      ${irqSum}
      ${readScaled}
      ${curDpm}

      echo "${csvHeader}"

      p_cpu=0; p_ios=0; p_iof=0; p_mem=0; p_irq=0; p_xhci=0; p_gpuirq=0
      first=1
      start_ns=$(date +%s%N)

      while :; do
        now_ns=$(date +%s%N)
        ts_ms=$(( (now_ns - start_ns) / 1000000 ))

        c_cpu=$(psi_total /proc/pressure/cpu some)
        c_ios=$(psi_total /proc/pressure/io some)
        c_iof=$(psi_total /proc/pressure/io full)
        c_mem=$(psi_total /proc/pressure/memory some)
        c_irq=$(psi_total /proc/pressure/irq full)
        c_xhci=$(irq_sum xhci_hcd)
        c_gpuirq=$(irq_sum amdgpu)

        # The first iteration only seeds the previous-counter state; emitting it
        # would print a delta measured against zero, i.e. the whole uptime.
        if [ "$first" -eq 0 ]; then
          printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$ts_ms" \
            "$((c_cpu - p_cpu))" "$((c_ios - p_ios))" "$((c_iof - p_iof))" \
            "$((c_mem - p_mem))" "$((c_irq - p_irq))" \
            "$(rdna "$amdgpu_node/gpu_busy_percent" 1)" \
            "$(rdna "$amdgpu_node/mem_busy_percent" 1)" \
            "$(rdna "$amdgpu_node/mem_info_vram_used" 1048576)" \
            "$(rdna "$amdgpu_node/mem_info_gtt_used" 1048576)" \
            "$(cur_dpm "$amdgpu_node/pp_dpm_sclk")" \
            "$(cur_dpm "$amdgpu_node/pp_dpm_mclk")" \
            "$(rdna "$hwmon/freq1_input" 1000000)" \
            "$(rdna "$hwmon/temp1_input" 1000)" \
            "$(rdna "$hwmon/power1_average" 1000000)" \
            "$(rdna /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 1000)" \
            "$(rdna /sys/devices/system/cpu/cpu8/cpufreq/scaling_cur_freq 1000)" \
            "$(awk '/^pswpin/ {print $2}' /proc/vmstat)" \
            "$(awk '/^pswpout/ {print $2}' /proc/vmstat)" \
            "$((c_xhci - p_xhci))" "$((c_gpuirq - p_gpuirq))"
        fi

        first=0
        p_cpu=$c_cpu; p_ios=$c_ios; p_iof=$c_iof; p_mem=$c_mem; p_irq=$c_irq
        p_xhci=$c_xhci; p_gpuirq=$c_gpuirq

        if [ "$duration" != "0" ] && [ "$ts_ms" -ge "$(( duration * 1000 ))" ]; then break; fi
        sleep "$interval"
      done
    '';
  };

  # ---------------------------------------------------------------------------
  # psi-calibrate -- DERIVE THRESHOLDS FROM THE *LOADED* FLOOR
  # ---------------------------------------------------------------------------
  # Run this during gameplay you judge to be SMOOTH, then feed the printed
  # thresholds to psi-watch. The idle floor is the wrong reference: measured
  # quiescent on this machine, cpu_some already sits at p50 6160 us / p99 11060
  # us per 100 ms window, and a game plus Hyprland compositing at 600 Hz across
  # ten cores raises that baseline substantially. Threshold from idle and the
  # CPU detector fires on every tick during play; raise it by guesswork and only
  # catastrophes register while the sparse hitches slip underneath.
  #
  # This exists as a tool rather than a runbook step because the obvious way to
  # do it by hand does not work: psi-watch prints only threshold crossings, so
  # it can never characterise its own floor -- setting the threshold high enough
  # to "see the baseline" is exactly what stops it emitting the samples the
  # baseline is made of. stutter-trace is the instrument that emits every window.
  psiCalibrate = pkgs.writeShellApplication {
    name = "psi-calibrate";
    runtimeInputs = with pkgs; [coreutils gawk];
    text = ''
      secs="''${1:-60}"
      out="''${2:-}"

      echo "psi-calibrate: sampling ''${secs}s at 10 Hz." >&2
      echo "psi-calibrate: do this DURING gameplay you consider smooth -- the loaded" >&2
      echo "psi-calibrate: floor is the reference, not the idle one." >&2

      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      ${stutterTrace}/bin/stutter-trace 0.1 "$secs" > "$tmp"
      if [ -n "$out" ]; then cp "$tmp" "$out"; echo "psi-calibrate: raw CSV -> $out" >&2; fi

      awk -F, '
        function pct(a, n, p,   i) { i = int(n * p); if (i < 1) i = 1; return a[i] }
        function report(label, a, n, rec,   p50, p99) {
          asort(a)
          p50 = pct(a, n, 0.50); p99 = pct(a, n, 0.99)
          printf "  %-9s p50=%-8d p90=%-8d p99=%-8d max=%-8d", \
            label, p50, pct(a, n, 0.90), p99, a[n]
          if (rec) printf "   -> suggest %d", (p99 * 3 / 2)
          printf "\n"
          return p99
        }
        NR > 1 { n++; cpu[n] = $2; ios[n] = $3; iof[n] = $4; mem[n] = $5; irq[n] = $6 }
        END {
          if (n < 10) { print "psi-calibrate: too few samples (" n ")" > "/dev/stderr"; exit 1 }
          printf "\nStall per ~100ms window, %d samples:\n", n
          cpu99 = report("cpu_some", cpu, n, 1)
          report("io_some", ios, n, 0)
          report("io_full", iof, n, 0)
          report("mem_some", mem, n, 0)
          report("irq_full", irq, n, 0)
          printf "\nSuggested invocation:\n  psi-watch 3000 %d\n", (cpu99 * 3 / 2)
          printf "\n3000us is kept for io/mem/irq deliberately: their floors sit at or\n"
          printf "near zero and barely move under load, which is what makes them the\n"
          printf "more trustworthy channels. Only cpu_some needs calibrating.\n"
        }
      ' "$tmp"
    '';
  };

  # ---------------------------------------------------------------------------
  # psi-watch -- 10 Hz EVENT DETECTOR
  # ---------------------------------------------------------------------------
  # The design point: GAUGES ALIAS, COUNTERS DO NOT. PSI's avg10/avg60 fields
  # are decayed averages, and a 2 Hz sampler reading them will routinely miss a
  # 40 ms hitch entirely -- the stall is over and averaged away before the next
  # tick lands. total= is instead a monotonic microsecond accumulator, so a
  # delta across any two reads captures every microsecond stalled in between,
  # whatever the sampling rate. This prints only threshold crossings.
  #
  # Note on cpu pressure: PSI's `full` metric is only meaningful inside a
  # cgroup. At the system root, if every runnable task were stalled on CPU there
  # would be nobody left to run, so /proc/pressure/cpu's `full` line is
  # structurally pinned at zero. Keying the CPU detector on it would be a test
  # that can never fire, whose silence reads as a passing result -- so it keys
  # on `some`.
  psiWatch = pkgs.writeShellApplication {
    name = "psi-watch";
    runtimeInputs = with pkgs; [coreutils gawk procps];
    text = ''
      # Threshold in microseconds of stall accumulated within one 100 ms window,
      # for io / memory / irq pressure. 3000 us = 3 ms, i.e. ~1.8 missed frames
      # against the 600 Hz panel's 1.67 ms budget. Measured quiescent on this
      # machine (2026-08-27, 140 windows), that clears the floor with room:
      #
      #   io_full   p50 0 us     p99 186 us    max 374 us
      #   irq_full  p50 525 us   p99 1133 us   max 1268 us
      #   mem_some  p50 0 us     (reclaim has effectively never run here)
      #
      # These three floors sit at or near zero and move little under load, which
      # is what makes them the trustworthy channels.
      thresh="''${1:-3000}"

      # cpu_some takes its own, much higher threshold and does not share the one
      # above. It accrues whenever *any* runnable task waits for a CPU, which on
      # a 20-thread box is continuous: the same quiescent run measured p50 6160
      # us, p99 11060 us. At 3000 us the CPU detector fires every single tick,
      # burying the io/irq hits this harness exists to catch.
      #
      # 25000 us clears the measured *idle* p99 -- but idle is not the reference.
      # Derive this from a loaded floor with `psi-calibrate 60` during gameplay
      # you judge smooth, and pass the number it suggests. Do not trust the
      # default for a real capture.
      cpu_thresh="''${2:-25000}"

      ${resolveAmdgpu}
      ${psiTotal}
      ${readScaled}
      ${curDpm}

      echo "psi-watch: io/mem/irq threshold ''${thresh}us, cpu_some threshold ''${cpu_thresh}us, per 100ms window" >&2
      echo "psi-watch: amdgpu=''${amdgpu_node:-none}" >&2
      if [ "$cpu_thresh" = "25000" ]; then
        echo "psi-watch: WARNING -- cpu_some threshold is the idle-derived default." >&2
        echo "psi-watch: run 'psi-calibrate 60' during gameplay and pass its value." >&2
      fi
      echo "psi-watch: wallclock  resource=stalled  sclk  gpu%  cpu0MHz  Tctl  [D-state procs]" >&2

      p_cpu=$(psi_total /proc/pressure/cpu some)
      p_ios=$(psi_total /proc/pressure/io some)
      p_iof=$(psi_total /proc/pressure/io full)
      p_mem=$(psi_total /proc/pressure/memory some)
      p_irq=$(psi_total /proc/pressure/irq full)

      while :; do
        sleep 0.1

        c_cpu=$(psi_total /proc/pressure/cpu some)
        c_ios=$(psi_total /proc/pressure/io some)
        c_iof=$(psi_total /proc/pressure/io full)
        c_mem=$(psi_total /proc/pressure/memory some)
        c_irq=$(psi_total /proc/pressure/irq full)

        d_cpu=$((c_cpu - p_cpu)); d_ios=$((c_ios - p_ios)); d_iof=$((c_iof - p_iof))
        d_mem=$((c_mem - p_mem)); d_irq=$((c_irq - p_irq))

        p_cpu=$c_cpu; p_ios=$c_ios; p_iof=$c_iof; p_mem=$c_mem; p_irq=$c_irq

        # `[ x ] && y` as a bare statement returns non-zero when the test fails,
        # which under writeShellApplication's `set -e` would exit the loop on the
        # first quiet tick -- i.e. immediately. Spelled out as `if` for that
        # reason, not for style.
        hit=""
        if [ "$d_cpu" -ge "$cpu_thresh" ]; then hit="$hit cpu_some=''${d_cpu}us"; fi
        if [ "$d_ios" -ge "$thresh" ]; then hit="$hit io_some=''${d_ios}us"; fi
        if [ "$d_iof" -ge "$thresh" ]; then hit="$hit io_full=''${d_iof}us"; fi
        if [ "$d_mem" -ge "$thresh" ]; then hit="$hit mem_some=''${d_mem}us"; fi
        if [ "$d_irq" -ge "$thresh" ]; then hit="$hit irq_full=''${d_irq}us"; fi
        if [ -z "$hit" ]; then continue; fi

        # Snapshot the state that separates the ranked hypotheses from one
        # another, taken as close to the event as the shell allows. sclk dropping
        # alongside the stall is the STAPM/PPT signature; sclk held high with an
        # io_full hit is a fence or writeback instead.
        #
        # Uninterruptible sleep is the fingerprint of a blocking kernel path: a
        # driver fence, synchronous writeback, or a reclaim stall. An empty list
        # alongside an io_full hit points at the block layer rather than a task.
        dstate=$(ps -eo state,pid,comm --no-headers 2>/dev/null \
          | awk '$1 ~ /^D/ { printf "%s(%s) ", $3, $2 }' || true)

        printf '%s%s sclk=%sMHz gpu=%s%% cpu0=%sMHz tctl=%sC%s\n' \
          "$(date +%H:%M:%S.%3N)" "$hit" \
          "$(cur_dpm "$amdgpu_node/pp_dpm_sclk")" \
          "$(rdna "$amdgpu_node/gpu_busy_percent" 1)" \
          "$(rdna /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 1000)" \
          "$(rdna "$hwmon/temp1_input" 1000)" \
          "''${dstate:+  D: $dstate}"
      done
    '';
  };
in {
  # ---------------------------------------------------------------------------
  # DIAGNOSTIC HARNESS (OPT-IN, NO STANDING BEHAVIOUR CHANGE)
  # ---------------------------------------------------------------------------
  # Measurement tooling for the intermittent-stutter investigation. Nothing here
  # alters scheduling, power or I/O behaviour; it only installs samplers. The
  # enable flag exists so the tooling can be retired in one place once the
  # investigation closes, rather than decaying into permanent system state.
  options.local.diagnostics = {
    enable = lib.mkEnableOption "stutter-investigation measurement tooling";

    unsafeTracing = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Relax kernel hardening so unprivileged perf can resolve kernel symbols.
        This genuinely weakens the machine's security posture: kptr_restrict=0
        exposes kernel pointers, defeating KASLR for anything that can read
        them, and perf_event_paranoid=-1 opens the PMU to every local process,
        which is the substrate for cache side-channel measurement. Intended to
        be switched on for a tracing session and switched back off -- never left
        as the machine's standing state.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      stutterTrace
      psiCalibrate
      psiWatch

      # Deliberately the top-level perf, not config.boot.kernelPackages.perf.
      # The latter stopped tracking the kernel in nixpkgs on 2025-08-28 -- it is
      # now a deprecation alias that warns on instantiate -- and under the
      # chaotic kernel set it resolves to a perf-linux variant currently marked
      # broken, which fails evaluation outright. See the assertion below for why
      # this is not left as a comment.
      pkgs.perf
    ];

    # perf's tracepoint layout is tied to the kernel it was built against, and
    # pkgs.perf follows nixpkgs while boot.kernelPackages follows chaotic -- two
    # inputs that bump independently. Today they happen to agree on 7.2, but
    # nothing holds them together, and a mismatch does not error: it produces
    # plausible-looking nonsense in a `perf sched` report, which is worse than a
    # failure because it gets believed. Surface the drift at eval time.
    assertions = [
      {
        assertion =
          lib.versions.majorMinor pkgs.perf.version
          == lib.versions.majorMinor config.boot.kernelPackages.kernel.version;
        message = ''
          local.diagnostics: perf ${pkgs.perf.version} does not match kernel ${config.boot.kernelPackages.kernel.version}.
          Scheduler tracing would be unreliable in a way that looks like valid output.
          Either pin a matching perf, or drop it from local.diagnostics until the
          versions reconverge.
        '';
      }
    ];

    boot.kernel.sysctl = lib.mkIf cfg.unsafeTracing {
      "kernel.perf_event_paranoid" = -1;
      "kernel.kptr_restrict" = 0;
    };
  };
}
