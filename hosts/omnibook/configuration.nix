{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ---------------------------------------------------------------------------
  # STRIX POINT APU SMU POWER TARGETS (65W AC CONTRACT)
  # ---------------------------------------------------------------------------
  # Defined in milliwatts (mW) for direct register injection via ryzenadj.
  sustainedPowerLimit = 54000; # 54W: Maximum sustained thermal envelope for 14" chassis
  slowPowerLimit = 60000; # 60W: Short sustained burst (tPPT) for intensive compute
  fastPowerLimit = 65000; # 65W: Peak immediate burst (fPPT) matching 65W AC charger
  temperatureLimit = 90; # 90°C: Maximum allowed junction temperature (Tctl)

  # STAPM IS NOT A SLIDING WINDOW ON THIS MACHINE. Measured with `ryzenadj -i`
  # during osu! (2026-08-27): StapmTimeConst = 0.000. STAPM's whole mechanism is
  # a time-averaged power limit, and a zero time constant disables the averaging
  # -- so the "sliding time-averaged power limit" a laptop normally imposes, and
  # which the earlier stutter investigation ranked as its #1 hypothesis, cannot
  # fire here at all.
  #
  # The same sample: STAPM 19.2/21.9 W, PPT slow 18.4/45 W, Tctl 66 °C, cores
  # holding 5042 MHz. Nowhere near any of the ceilings below. That both
  # eliminates power throttling as a cause of the frame drops and retroactively
  # validates these limits -- they are not being hit, so they are not the thing
  # to tune. Re-check with `ryzenadj -i` before blaming power again.

  # GPU DPM level, applied at boot and re-applied on resume.
  # "auto" lets the SMU shift the shared 54-65W envelope toward the CPU when the
  # iGPU is not the bottleneck (Rocket League at 1080p is CPU/netcode-bound).
  # "high" pins maximum GPU clocks instead, at the cost of CPU thermal headroom.
  gpuDpmLevel = "auto";

  # Shared by the boot-time oneshot and the resume hook so both paths inject an
  # identical envelope rather than drifting apart.
  applySmuLimits = pkgs.writeShellScript "set-smu-limits" ''
    ${pkgs.ryzenadj}/bin/ryzenadj \
      --stapm-limit=${toString sustainedPowerLimit} \
      --slow-limit=${toString slowPowerLimit} \
      --fast-limit=${toString fastPowerLimit} \
      --tctl-temp=${toString temperatureLimit}
  '';
in {
  # ---------------------------------------------------------------------------
  # MODULAR ARCHITECTURE IMPORTS
  # ---------------------------------------------------------------------------
  imports = [
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/gaming.nix
    ../../modules/minecraft.nix
    ../../modules/sober.nix
    ../../modules/diagnostics.nix
    ../../modules/llm.nix

    # Pixel-as-webcam: v4l2loopback sink fed by scrcpy over adb. Host-independent
    # behaviour, so it is a shared module rather than inline here -- but note it
    # reads boot.kernelPackages (set below) to build the out-of-tree loopback
    # module against this machine's CachyOS kernel rather than nixpkgs' default.
    ../../modules/webcam.nix

    # xHCI interrupt affinity pin (Zen5 cores). Imported here rather than from
    # flake.nix because it names this machine's PCI addresses -- it is host
    # hardware, not host-independent behaviour. Deleting this one line is the
    # full revert: it also un-masks core.nix's xhci-irq-unpin baseline.
    ../../modules/irq-affinity.nix
  ];

  # Synchronize hostname with flake output schema
  networking.hostName = "omnibook";

  # ---------------------------------------------------------------------------
  # BOOTLOADER & CACHYOS BORE KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # CachyOS kernel with BORE (Burst-Oriented Response Enhancer) scheduler
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # Low-latency kernel parameters mapped to Zen 5 & RDNA 3.5 APU silicon
  boot.kernelParams = [
    # --- APU DYNAMIC VRAM (GTT) SIZING ---
    # There is no meaningful VRAM carveout on this machine: the BIOS hands
    # amdgpu a 512 MB UMA aperture ("VRAM: 512M ... 512M used" in dmesg) and
    # every other buffer the iGPU touches is GTT -- ordinary LPDDR5X mapped
    # through the GART. GTT *is* the VRAM budget here, so it is what caps how
    # large a model llama.cpp's Vulkan backend can hold resident.
    #
    # amdgpu sizes GTT as min(its own default, ttm_tt_pages_limit()), which is
    # why the previous 4194304 produced exactly "16384M of GTT memory ready":
    # 4194304 * 4 KiB = 16 GiB, the TTM cap, not an amdgpu decision. 6291456
    # pages = 24 GiB, sized to hold a ~20 GiB Q4_K_M MoE plus its KV cache and
    # compute buffers.
    #
    # 24 of 30.65 GiB usable is aggressive, and it is a ceiling rather than a
    # reservation -- nothing leaves the system until the GPU actually allocates
    # it. But a fully resident 20 GiB model does leave only ~7 GiB for
    # everything else. If the desktop starts swapping while serving, shrink the
    # model or the server's --ctx-size; shrinking this below the model size just
    # converts the symptom into a Vulkan allocation failure.
    "ttm.pages_limit=6291456"

    # TTM's free-page cache, in pages. Defaults to half of RAM. Matching it to
    # pages_limit stops TTM handing pages back to the kernel and re-zeroing them
    # on the next allocation, which is pure overhead for a workload that claims
    # ~20 GiB once and then holds it. Shrinker-backed, so the kernel can still
    # reclaim under pressure.
    "ttm.page_pool_size=6291456"

    # amdgpu's own GTT ceiling, in MiB, kept in step with the TTM cap. Belt and
    # braces: TTM is the binding constraint today, but amdgpu's internal default
    # has moved between releases, and pinning both means a kernel bump cannot
    # silently shrink the budget underneath the inference server.
    "amdgpu.gttsize=24576"

    # THE `amdttm.pages_limit` LINE THAT USED TO SIT HERE IS GONE, DELIBERATELY.
    # amdttm is the symbol-renamed TTM that ships with AMD's out-of-tree amdgpu
    # (the DKMS/ROCm packaging). This kernel uses the in-tree driver: `lsmod`
    # shows a plain `ttm` bound to amdgpu, and /sys/module/amdttm does not
    # exist. The parameter was parsed and discarded on every boot. Restore it
    # only if boot.kernelPackages ever moves to a kernel that builds amdttm.

    # Driver Performance: Active autonomous CPPC power scaling
    "amd_pstate=active"
    "amdgpu.ppfeaturemask=0xffffffff"
    "pcie_aspm=off"
    # Interrupt & Clock Optimization: Eliminate scheduler jitter and polling latency
    # split_lock_mitigate is Intel-only and was being rejected outright ("Unknown
    # kernel command line parameters", visible in dmesg on every boot) -- it is
    # dropped. split_lock_detect is kept: it parses on x86 generally and on Zen 5
    # gates the bus-lock detector this CPU does advertise (bus_lock_detect in
    # /proc/cpuinfo flags), where a trap on a misaligned locked access would cost
    # a hard #DB round trip mid-frame.
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    "reboot=pci"

    # --- SPECULATIVE EXECUTION MITIGATIONS: OFF ---
    # THIS IS A SECURITY TRADE, MADE KNOWINGLY. Stated plainly so a future
    # reader sees a decision and not an oversight:
    #
    # `mitigations=off` disables the Spectre/Meltdown-class mitigations
    # wholesale -- IBPB/IBRS/STIBP, retpolines, the various store-bypass and
    # MDS/TAA buffer clears, and whatever else the umbrella covers on a given
    # kernel. This machine runs Firefox, Discord and tor-browser. Turning these
    # off re-opens speculative side channels to ANY local process, and the
    # realistic attacker here is not a local login, it is JavaScript in a tab.
    #
    # It is also a blunt switch by construction: it covers vulnerabilities this
    # CPU may not even have, and it will silently cover future ones the same
    # way, because it is defined as "off by default for everything" rather than
    # as a list. The granular form (`spectre_v2=off retbleed=off
    # spec_store_bypass_disable=off` and so on) exists if that is ever wanted;
    # deliberately not doing that now.
    #
    # Revert is deleting this one line and rebooting. Audit the current state
    # with:  grep . /sys/devices/system/cpu/vulnerabilities/*
    #
    # HYPOTHESIS, NOT MEASURED HERE: 2-8% on CPU-bound workloads on Zen 5.
    # Rocket League is single-thread/netcode bound, which is where mitigation
    # overhead concentrates (syscall and context-switch paths), so this is
    # expected to land on the critical path rather than on throughput. Nothing
    # on this machine has been A/B'd yet -- that is what Change 1's MangoHud
    # frametime capture is for.
    "mitigations=off"
  ];

  # ---------------------------------------------------------------------------
  # WI-FI RADIO LINK (MediaTek MT7925 / Filogic 360, 2x2 802.11be)
  # ---------------------------------------------------------------------------
  # PCIe ASPM lets the radio drop the link into L1/L1.2 between packets. The
  # mt76 driver has to re-arm its DMA rings on every exit, so on an otherwise
  # idle link — precisely the traffic shape of a game's 60 Hz UDP tick — the
  # first packet after each idle gap eats the wake-up penalty and shows up as a
  # sporadic multi-millisecond spike. This part is also the one the mt7921/7925
  # family's ASPM firmware hangs are attributed to. Pin the link awake; the
  # sub-watt cost is noise against the SMU envelope set in the `let` above.
  #
  # CORRECTION (2026-09-12): this paragraph used to end "...and a performance
  # governor that already forbids deep C-states". That was simply wrong, and it
  # is the kind of wrong that hides a real cost -- cpufreq governors select
  # P-states (voltage/frequency); C-states belong to cpuidle, an independent
  # subsystem the governor does not touch. With `performance` active this
  # machine was still entering C3 tens of millions of times per boot. That is
  # now capped explicitly; see CPUIDLE C-STATE CEILING below.
  #
  # CLC (Country Location Control) is MediaTek's own regulatory gate, layered on
  # top of cfg80211's. It is evaluated when the driver registers the wiphy —
  # which happens while cfg80211 is still on the "00" world domain — and the
  # result is that all 60 channels of band 4 come up permanently `(disabled)`,
  # even after the domain is later corrected to US. This card is 802.11be 2x2 and
  # the AP here beacons a 6 GHz BSS (operating class 134, channel 101), so the
  # band is worth having: it is uncontended and has no 2.4/5 GHz legacy traffic
  # to share airtime with. cfg80211's US rules still bound transmit power.
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=1
    options mt7925_common disable_clc=1
  '';

  # ---------------------------------------------------------------------------
  # CPU & GPU POWER STATE GOVERNOR
  # ---------------------------------------------------------------------------
  powerManagement = {
    enable = true;
    cpuFreqGovernor = "performance";
  };

  # ---------------------------------------------------------------------------
  # DECLARATIVE SYSFS REGISTER INJECTION (tmpfiles.rules)
  # ---------------------------------------------------------------------------
  # Writes register values to sysfs during early boot before services launch.
  # Replaces multiple conflicting bash services.
  systemd.tmpfiles.rules = [
    # Set AMD Energy-Performance Preference (EPP) to raw performance across all 10 cores
    "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - performance"

    # Apply the chosen GPU DPM level across all detected DRM card nodes
    "w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
  ];

  # ---------------------------------------------------------------------------
  # SMU MAILBOX REGISTER OVERRIDES (ryzenadj)
  # ---------------------------------------------------------------------------
  # Writes sustained wattage envelopes directly to the AMD System Management Unit.
  systemd.services.amd-power-boost = {
    description = "Apply 65W SMU power envelope to AMD Ryzen AI 9 365";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = applySmuLimits;
    };
  };

  # ---------------------------------------------------------------------------
  # CPUIDLE C-STATE CEILING
  # ---------------------------------------------------------------------------
  # cpufreq and cpuidle are independent. `cpuFreqGovernor = "performance"` above
  # pins P-states and has no bearing whatsoever on C-states, which is why this
  # needs its own mechanism. Measured with the performance governor active:
  #
  #   state2  C2  latency  18 us   usage 106,107,508
  #   state3  C3  latency 350 us   usage  34,036,190
  #
  # C3 is being entered tens of millions of times per boot, and its 350 us exit
  # latency is 21% of the 1.667 ms frame budget at 599.94 Hz. A wake-up that
  # lands on the wrong side of a frame boundary is a dropped frame.
  #
  # -D 350 disables every state whose exit latency is >= 350 us, which on this
  # CPU is C3 and only C3 -- C2 at 18 us survives, so cores still clock-gate
  # between frames and this is not a "disable idle entirely" hammer. The
  # threshold is chosen to sit under the frame budget and nothing else: re-derive
  # it if the refresh rate changes, rather than treating 350 as magic.
  #
  # THIS IS A MICRO-STUTTER FIX AND NOTHING MORE. 350 us cannot explain the
  # multi-second black-and-recover symptom in the open frame-drop investigation;
  # that is a different bug and this change must not be credited with it.
  systemd.services.cpu-idle-limit = {
    description = "Cap cpuidle at C2 (C3 exit latency 350us vs 1.667ms frame)";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # cpupower MUST come from boot.kernelPackages. Verified against this
      # flake.lock: `pkgs.cpupower` does not exist at all (nix suggests
      # "upower"), and `pkgs.linuxPackages.cpupower` resolves to a 6.18.51 build
      # -- the wrong kernel for a machine running CachyOS 7.2.4.
      ExecStart = "${config.boot.kernelPackages.cpupower}/bin/cpupower idle-set -D 350";
    };
  };

  # ---------------------------------------------------------------------------
  # SUSPEND/RESUME POWER STATE RE-APPLICATION
  # ---------------------------------------------------------------------------
  # tmpfiles.rules and the oneshot above only run at boot. On a laptop, amdgpu
  # resets power_dpm_force_performance_level and the SMU can fall back to stock
  # wattage envelopes across an s2idle cycle -- so closing the lid between
  # matches would silently drop the machine to default power limits with no
  # visible indication. Re-inject the same registers after every resume.
  powerManagement.resumeCommands = ''
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      echo performance > "$f" || true
    done
    for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
      echo ${gpuDpmLevel} > "$f" || true
    done
    ${applySmuLimits} || true

    # cpuidle re-enables every state across s2idle, exactly like the SMU and EPP
    # registers above -- so without this the C3 cap silently lapses on the first
    # lid close and never comes back until reboot. Written into this block
    # rather than as a second `powerManagement.resumeCommands` assignment
    # because both would live in this one attrset, where a repeated attribute is
    # an eval error regardless of the option's merge type.
    ${pkgs.systemd}/bin/systemctl restart cpu-idle-limit.service || true
  '';

  # ---------------------------------------------------------------------------
  # GRAPHICS & BLEEDING-EDGE MESA STACK
  # ---------------------------------------------------------------------------
  chaotic.mesa-git.enable = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ---------------------------------------------------------------------------
  # PERIPHERALS & LAPTOP HARDWARE GUARDS
  # ---------------------------------------------------------------------------
  services.udev.packages = [pkgs.swayosd];
  environment.systemPackages = [pkgs.ryzenadj];

  # FINGERPRINT READER (fprintd) IS DELIBERATELY ABSENT -- removed 2026-08-30.
  #
  # It used to be enabled here with an ExecStartPre guard that refused to start
  # the daemon while the lid was shut or eDP-1 was disabled. That is the normal
  # state on this machine -- it runs docked, driving DP-1 with the internal panel
  # off -- so the guard fired on every boot and the unit sat permanently
  # `failed`. Fingerprint auth was already dead in practice, not just unused.
  #
  # Nothing has to be deleted on the PAM side to finish unwinding this. nixpkgs
  # declares (nixos/modules/security/pam.nix)
  #     security.pam.services.<name>.fprintAuth.default = services.fprintd.enable;
  # so dropping the line above retracts `auth sufficient pam_fprintd.so` from
  # every generated stack on its own. `sufficient` is the load-bearing word: the
  # fprintd entry could only ever ADD a way to authenticate, never gate one, so
  # pam_unix.so was already the fallback everywhere and is now the sole auth
  # module ahead of pam_deny.so. Password auth for login/greetd/sudo/su/polkit
  # is unaffected. Do not re-add without also re-checking those five stacks.

  # ---------------------------------------------------------------------------
  # GREETD / TUIGREET COMPOSITOR LAUNCHER
  # ---------------------------------------------------------------------------
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'start-hyprland'";
        user = "crazycat";
      };
    };
  };
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
    settings.General = {
      Experimental = true;
      FastConnectable = true;
    };
  };
  # ---------------------------------------------------------------------------
  # FIRMWARE UPDATES (fwupd)
  # ---------------------------------------------------------------------------
  # Here for visibility over the NVMe and the USB4/DisplayPort retimer firmware,
  # not for the BIOS -- W81 Ver. 01.01.21 (2026-06-15) is current, and HP exposes
  # no UMA/VRAM-carveout setting to go looking for anyway. The dock sits directly
  # in the video path (the 599.94 Hz panel reaches the APU over DisplayPort MST
  # through a USB-C adapter), which makes retimer firmware a legitimate suspect
  # for a link-level fault, so `fwupdmgr get-devices` is worth having.
  #
  # lvfs-testing widens the remote to firmware that has not cleared LVFS's
  # stable gate. Enabling a remote flashes nothing on its own, so this is inert
  # until `fwupdmgr update` is run by hand -- but note that while the frame-drop
  # cause is still unidentified, taking a testing-channel update means adding a
  # variable to an open experiment. Prefer flashing from stable, or after the
  # drops are understood.
  services.fwupd = {
    enable = true;
    extraRemotes = ["lvfs-testing"];
  };
  # ---------------------------------------------------------------------------
  # STUTTER INVESTIGATION HARNESS (TEMPORARY, OPENED 2026-08-27)
  # ---------------------------------------------------------------------------
  # Installs stutter-trace / psi-watch / perf for the intermittent-frame-hitch
  # measurement. Purely additive -- no scheduling, power or I/O behaviour
  # changes -- so it is safe to leave on across the investigation. Turn it off
  # once the cause is bucketed rather than letting the tooling become permanent
  # system state.
  #
  # unsafeTracing is left off deliberately: it drops perf_event_paranoid to -1
  # and kptr_restrict to 0, which weakens KASLR and opens the PMU to every local
  # process. Switch it on only for the duration of a perf session that actually
  # needs kernel symbols, then switch it back.
  local.diagnostics = {
    enable = false;
    unsafeTracing = false;
  };

  system.stateVersion = "25.11";
}
