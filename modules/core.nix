# modules/core.nix
{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # HOST CPU TOPOLOGY INTERFACE (CONSUMED BY GAMING.NIX & HOME.NIX)
  # ---------------------------------------------------------------------------
  # Abstracts core-pinning masks so asymmetric hybrid APUs (omnibook: 4x Zen 5
  # + 6x Zen 5c) and symmetric single-CCX desktops (desktop: 6x Zen 3) can share
  # gaming wrappers and desktop entries without hardcoding CPU indices.
  options.local.hardware = {
    gameCores = lib.mkOption {
      type = lib.types.str;
      default = "0-7";
      description = "Logical CPU list reserved for latency-critical game threads.";
    };
    gameCoresNoSmt = lib.mkOption {
      type = lib.types.str;
      default = "0,2,4,6";
      description = "One logical thread per physical core in the primary gaming CCX.";
    };
    backgroundCores = lib.mkOption {
      type = lib.types.str;
      default = "8-19";
      description = "Logical CPU list for background daemons, browsers, and desktop UI.";
    };
    allCores = lib.mkOption {
      type = lib.types.str;
      example = "0-11";
      description = "Every logical CPU. Used to let nix-daemon escape backgroundCores.";
    };
    monitors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
        ''hl.monitor({ output = "eDP-1", disabled = true })''
      ];
      description = "Hyprland monitor rules injected into hyprland.lua.";
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
  };

  config = {
    # ---------------------------------------------------------------------------
    # CPUIDLE C-STATE CEILING & RESUME HOOKS
    # ---------------------------------------------------------------------------
    # Without a cpuidle driver (firmware publishes no _CST, e.g. desktop BIOS with
    # Global C-state Control off) cores only ever HLT into C1, so there is nothing
    # to cap: warn instead of failing the unit, and start working as soon as the
    # firmware exposes C-states, with no config edit.
    systemd.services.cpu-idle-limit = lib.mkIf config.local.hardware.capCstates {
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
          exec ${config.boot.kernelPackages.cpupower}/bin/cpupower idle-set -D ${toString config.local.hardware.capCstatesLatency}
        '';
      };
    };

    powerManagement.resumeCommands = lib.mkIf config.local.hardware.capCstates ''
      ${pkgs.systemd}/bin/systemctl restart cpu-idle-limit.service || true
    '';

    # ---------------------------------------------------------------------------
    # CPU SCHEDULER
    # ---------------------------------------------------------------------------
    # No sched-ext scheduler is loaded: the CachyOS kernel's own BORE
    # (Burst-Oriented Response Enhancer) EEVDF variant is used as-is, which
    # measured better on this machine than scx_lavd (tested 2026-08-20).
    # Hosts must select linuxPackages_cachyos-bore explicitly; plain
    # linuxPackages_cachyos became clang-LTO without BORE (found 2026-11-08,
    # so the 08-20 comparison may have been against a non-BORE kernel).

    # ---------------------------------------------------------------------------
    # REPOSITORY EVALUATION POLICIES & FLAKE STATE
    # ---------------------------------------------------------------------------
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["root" "@wheel"];
      # 256 MiB: avoids "download buffer is full" stalls when substituting
      # large paths (kernel, mesa-git, proton) on a fast link.
      download-buffer-size = 268435456;
    };

    # ---------------------------------------------------------------------------
    # NIX BUILDS: ALL CORES, HIGH PRIORITY
    # ---------------------------------------------------------------------------
    # Every system service inherits Manager.CPUAffinity = backgroundCores, and
    # system.slice is cpuset-confined to it, so builds ran on 4 threads (desktop).
    # Builds are run when nothing latency-sensitive is, so nix-daemon gets its
    # own top-level slice with every CPU and 10x the CPU/IO weight of
    # user.slice / system.slice (weight is what arbitrates between cgroups;
    # nice only orders tasks inside one).
    systemd.slices.nixbuild = {
      description = "Nix builds (all CPUs, high weight)";
      sliceConfig = {
        AllowedCPUs = config.local.hardware.allCores;
        CPUWeight = 1000;
        IOWeight = 1000;
      };
    };
    systemd.services.nix-daemon.serviceConfig = {
      Slice = "nixbuild.slice";
      CPUAffinity = config.local.hardware.allCores;
    };
    nix.daemonIOSchedClass = "best-effort";
    nix.daemonIOSchedPriority = 0;

    # ---------------------------------------------------------------------------
    # STORE MAINTENANCE (DEFERRED, NEVER CAUGHT UP MID-SESSION)
    # ---------------------------------------------------------------------------
    # All three timers MUST have persistent = false so a missed midnight/04:00
    # window while powered off or asleep is skipped rather than saturating NVMe
    # I/O immediately after login.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      persistent = false;
      options = "--delete-older-than 3d";
    };

    nix.optimise = {
      automatic = true;
      dates = ["04:00"];
      persistent = false;
    };

    services.fstrim.enable = true;
    systemd.timers.fstrim.timerConfig.Persistent = false;

    # High-speed memory compression
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 100;
    };

    programs.dconf.enable = true;

    # ---------------------------------------------------------------------------
    # COMPETITIVE NETWORKING & WI-FI ROAMING / POWERSAVE LOCKOUT
    # ---------------------------------------------------------------------------
    networking.networkmanager = {
      enable = true;
      wifi.backend = "wpa_supplicant"; # Default, ensures iwd isn't used
    };
    networking.wireless.enable = true;

    # --- 802.11v BSS TRANSITION MANAGEMENT (ROAM STEERING) ---
    hardware.wirelessRegulatoryDatabase = true;
    networking.firewall.checkReversePath = "loose";
    networking.wireless.extraConfig = ''
      disable_btm=1
      country=US
    '';

    # --- REGULATORY DOMAIN (6 GHz UNLOCK) ---
    # Pin regulatory domain at module load so 6 GHz (Wi-Fi 6E/7) is permitted
    # before ath12k or iwlwifi evaluates band capabilities.
    boot.extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom=US
    '';

    networking.wireless.scanOnLowSignal = false;

    # ---------------------------------------------------------------------------
    # PACKET FILTER BACKEND & PROTOCOL ATTACK SURFACE
    # ---------------------------------------------------------------------------
    networking.nftables.enable = true;
    boot.blacklistedKernelModules = [
      "dccp" # Datagram Congestion Control Protocol
      "sctp" # Stream Control Transmission Protocol
      "rds" # Reliable Datagram Sockets
      "tipc" # Transparent Inter-Process Communication
    ];

    # --- KERNEL NETWORK TUNING (FQ PACING + BBR) ---
    # `fq` is the required pacing companion for BBR. `sch_cake` is deliberately
    # absent (unshaped cake adds CPU overhead without shaping the ISP bottleneck).
    boot.kernelModules = [
      "tcp_bbr"
      "ntsync"
      "uinput"
    ];

    boot.kernelParams = [
      "8250.nr_uarts=0"
      # RCU callbacks for the game cores run in rcuo kthreads instead, which
      # irq-affinity.nix moves to kthreadCpus. nohz_full is deliberately not
      # used: it adds user/kernel accounting to every syscall (Wine is syscall-heavy).
      "rcu_nocbs=${config.local.hardware.gameCores}"
    ];

    boot.kernel.sysctl = {
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";

      # Expand buffer ceilings for high-tick-rate UDP streams
      "net.core.rmem_max" = 16777216;
      "net.core.wmem_max" = 16777216;
      "net.core.rmem_default" = 262144;
      "net.core.wmem_default" = 262144;
      "net.ipv4.tcp_fastopen" = 3;
      "net.ipv4.tcp_rmem" = "4096 87380 16777216";
      "net.ipv4.tcp_wmem" = "4096 65536 16777216";
      "net.core.netdev_max_backlog" = 10000;
      "net.ipv4.tcp_window_scaling" = 1;

      # --- ANTI-SPOOFING / ANTI-AMPLIFICATION ---
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;

      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;

      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;

      "net.ipv4.tcp_syncookies" = 1;

      # Memory compaction & swapping heuristics
      "vm.compaction_proactiveness" = 0;
      "vm.watermark_boost_factor" = 0;
      "vm.swappiness" = 10;
    };

    # ---------------------------------------------------------------------------
    # UDEV HARDWARE ISOLATION & SEAT ACCESS
    # ---------------------------------------------------------------------------
    hardware.enableRedistributableFirmware = true;
    services.power-profiles-daemon.enable = false;

    hardware.graphics.enable = true;

    services.udev.extraRules = ''
      # Enforce radio power_save=off whenever any wireless netdev initializes
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*|wlp*", RUN+="${pkgs.iw}/bin/iw dev %k set power_save off"

      # Low-latency NVMe queue scheduler
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

      # Auto-authorize Thunderbolt 4 endpoints
      ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"

      # USB: Force continuous active power state (eliminates first-input wake delay)
      ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"

      # Blind the GameSir motion sensor to prevent 5000Hz gyro CPU overhead
      ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="Guangzhou Chicken Run Network Technology Co., Ltd. Wireless Controller Motion Sensors", MODE="0000", ENV{ID_INPUT_ACCELEROMETER}="0", ENV{ID_INPUT_JOYSTICK}="0"
    '';

    # --- hidraw SEAT ACCESS (priority 60, ahead of 73-seat-late.rules) ---
    services.udev.packages = [
      (pkgs.writeTextFile {
        name = "hidraw-uaccess-rules";
        destination = "/lib/udev/rules.d/60-hidraw-uaccess.rules";
        text = ''
          KERNEL=="hidraw*", SUBSYSTEM=="hidraw", TAG+="uaccess"
        '';
      })
    ];

    hardware.uinput.enable = true;

    # ---------------------------------------------------------------------------
    # LOW-LATENCY AUDIO SUBSYSTEM (PipeWire: 256 realized = 5.33 ms @ 48 kHz)
    # ---------------------------------------------------------------------------
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;

      extraConfig.pipewire = {
        "10-clock-quantum" = {
          "context.properties" = {
            "default.clock.rate" = 48000;
            # 48 kHz only: every alsa_output is pinned to audio.rate = 48000 below,
            # so allowing 44.1 kHz just let osu! drag the graph to 44100 while the
            # device stayed at 48000 (pw-top: driver 256/44100 vs S32LE 48000, xruns).
            # 44.1 kHz streams are now resampled once, in their own adapter.
            "default.clock.allowed-rates" = [48000];
            "default.clock.quantum" = 512;
            "default.clock.min-quantum" = 128;
            "default.clock.max-quantum" = 4096;
          };
        };
        "99-realtime" = {
          "context.modules" = [
            {
              name = "libpipewire-module-rt";
              args = {
                "nice.level" = -15;
                "rt.prio" = 88;
                "rt.time.soft" = -1;
                "rt.time.hard" = -1;
              };
              flags = ["ifexists" "nofail"];
            }
          ];
        };
      };

      extraConfig.pipewire-pulse = {
        "10-pulse-latency" = {
          "pulse.properties" = {
            "server.address" = ["unix:native"];
          };
          "stream.properties" = {
            "node.latency" = "256/48000";
          };
        };
      };

      wireplumber.extraConfig = {
        "11-alsa-gpu-tuning" = {
          "monitor.alsa.rules" = [
            {
              matches = [{"node.name" = "~alsa_output.*";}];
              actions = {
                update-props = {
                  "node.pause-on-idle" = false;
                  "audio.format" = "S32LE";
                  "audio.rate" = 48000;
                  "api.alsa.period-size" = 256;
                  "api.alsa.headroom" = 256;
                  "api.alsa.disable-batch" = true;
                };
              };
            }
            {
              # HD-Audio is not a batch device and reports an exact hw pointer, so
              # it needs no headroom; the 256 frames above added a flat 5.33 ms to
              # every sound on HDA outputs (desktop ALC897, GPU HDMI/DP).
              matches = [
                {
                  "node.name" = "~alsa_output.*";
                  "alsa.driver_name" = "snd_hda_intel";
                }
              ];
              actions = {
                update-props = {
                  "api.alsa.headroom" = 0;
                };
              };
            }
          ];
        };

        "12-blue-yeti-gain-lock" = {
          "monitor.alsa.rules" = [
            {
              matches = [{"node.name" = "~alsa_input.*Blue_Microphones.*";}];
              actions = {
                update-props = {
                  "node.pause-on-idle" = false;
                  "api.alsa.soft-mixer" = false;
                };
              };
            }
          ];
        };

        "10-bluetooth-policy" = {
          "wireplumber.settings" = {
            "bluetooth.autoswitch-to-headset-profile" = false;
          };
          "monitor.bluez.properties" = {
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
            "bluez5.codecs" = ["sbc_xq" "sbc"];
            "bluez5.roles" = ["a2dp_sink" "a2dp_source"];
          };
        };
      };
    };

    # ---------------------------------------------------------------------------
    # USER PRIVILEGES & REALTIME PAM LIMITS
    # ---------------------------------------------------------------------------
    users.users.crazycat = {
      isNormalUser = true;
      description = "Aden Sky";
      extraGroups = ["networkmanager" "wheel" "video" "input" "audio" "render"];
      shell = pkgs.fish;
    };

    security.polkit.enable = true;
    security.pam.loginLimits = [
      {
        domain = "@users";
        item = "nofile";
        type = "-";
        value = "1048576";
      }
      {
        domain = "@users";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
      {
        domain = "@audio";
        item = "rtprio";
        type = "-";
        value = "95";
      }
      {
        domain = "@audio";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
      {
        domain = "@audio";
        item = "nice";
        type = "-";
        value = "-19";
      }
      {
        domain = "@wheel";
        item = "rtprio";
        type = "-";
        value = "99";
      }
      {
        domain = "@wheel";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
      {
        domain = "@wheel";
        item = "nice";
        type = "-";
        value = "-20";
      }
    ];

    # ---------------------------------------------------------------------------
    # BASE PACKAGES & ENVIRONMENT
    # ---------------------------------------------------------------------------
    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";
    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };
    services.fwupd.enable = false;
    # On by default in NixOS; nothing here uses text-to-speech.
    services.speechd.enable = false;

    # `nh os switch` / `nh os build`: nixos-rebuild with an nvd package diff and
    # build tree. nh.clean stays off (nix.gc above already owns GC).
    programs.nh = {
      enable = true;
      flake = "/home/crazycat/nixos-config";
    };
    services.gnome.gnome-keyring.enable = true;
    programs.fish.enable = true;

    programs.thunar = {
      enable = true;
      plugins = with pkgs; [
        thunar-archive-plugin
      ];
    };

    programs.xfconf.enable = true;
    services.tumbler.enable = true;
    services.gvfs.enable = true;

    environment.pathsToLink = ["/share/xdg-desktop-portal" "/share/applications"];

    environment.systemPackages = with pkgs; [
      vim
      btop
      wget
      ethtool
      git
      iw
      alejandra
      nixd
      bluetui
      wireplumber
      pulsemixer
      pciutils
      lm_sensors
      htop
      kitty
      pavucontrol
      shared-mime-info
      cargo
      rustc
      gcc
      pkg-config
      systemd.dev
      libusb1
      ffmpegthumbnailer
      sshfs
      fastfetch
      acpi
      appimage-run
      ripgrep
      fd
    ];
  };
}
