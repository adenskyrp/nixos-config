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
    monitors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "DP-1, 1920x1080@599.94, 0x0, 1"
        "eDP-1, disable"
      ];
      description = "Hyprland monitor rules injected into hyprland.lua.";
    };
    capCstates = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable C-states with exit latency >= 350us (C3/C6) at boot and resume.";
    };
  };

  config = {
    # ---------------------------------------------------------------------------
    # CPUIDLE C-STATE CEILING & RESUME HOOKS
    # ---------------------------------------------------------------------------
    systemd.services.cpu-idle-limit = lib.mkIf config.local.hardware.capCstates {
      description = "Cap cpuidle at C2 (disable states with exit latency >= 350us)";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.boot.kernelPackages.cpupower}/bin/cpupower idle-set -D 350";
      };
    };

    powerManagement.resumeCommands = lib.mkMerge [
      (lib.mkIf config.systemd.services.xhci-irq-unpin.enable ''
        ${pkgs.systemd}/bin/systemctl restart xhci-irq-unpin.service || true
      '')
      (lib.mkIf config.local.hardware.capCstates ''
        ${config.boot.kernelPackages.cpupower}/bin/cpupower idle-set -D 350 || true
      '')
    ];

    # ---------------------------------------------------------------------------
    # CPU SCHEDULER
    # ---------------------------------------------------------------------------
    # No sched-ext scheduler is loaded: the CachyOS kernel's own BORE
    # (Burst-Oriented Response Enhancer) EEVDF variant is used as-is, which
    # measured better on this machine than scx_lavd (tested 2026-08-20).

    # ---------------------------------------------------------------------------
    # REPOSITORY EVALUATION POLICIES & FLAKE STATE
    # ---------------------------------------------------------------------------
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
    };

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
      memoryPercent = 50;
    };

    programs.dconf.enable = true;

    # ---------------------------------------------------------------------------
    # COMPETITIVE NETWORKING & WI-FI ROAMING / POWERSAVE LOCKOUT
    # ---------------------------------------------------------------------------
    networking.networkmanager = {
      enable = true;
      wifi.backend = "wpa_supplicant";
      wifi.powersave = false;
      wifi.macAddress = "permanent";
      dns = "default";

      settings = {
        device = {
          "wifi.scan-rand-mac-address" = "yes";
        };
      };
    };

    # --- 802.11v BSS TRANSITION MANAGEMENT (ROAM STEERING) ---
    hardware.wirelessRegulatoryDatabase = true;
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
    # xHCI INTERRUPT AFFINITY (UNPINNED BASELINE UNLESS OVERRIDDEN BY HOST)
    # ---------------------------------------------------------------------------
    systemd.services.xhci-irq-unpin = {
      description = "Restore default (all-CPU) IRQ affinity for xHCI controllers";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "xhci-irq-unpin" ''
          mask="0-$(($(${pkgs.coreutils}/bin/nproc --all) - 1))"
          for irq in $(${pkgs.gawk}/bin/awk -F: '/xhci_hcd/ {gsub(/ /, "", $1); print $1}' /proc/interrupts); do
            if echo "$mask" > /proc/irq/"$irq"/smp_affinity_list 2>/dev/null; then
              echo "irq $irq unpinned to $mask, now effective on cpu$(cat /proc/irq/"$irq"/effective_affinity_list)"
            else
              echo "irq $irq: affinity write rejected, left on cpu$(cat /proc/irq/"$irq"/effective_affinity_list)" >&2
            fi
          done
        '';
      };
    };

    # ---------------------------------------------------------------------------
    # LOW-LATENCY AUDIO SUBSYSTEM (PipeWire: 256 realized = 5.33 ms @ 48 kHz)
    # ---------------------------------------------------------------------------
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;

      extraConfig.pipewire = {
        "10-clock-quantum" = {
          "context.properties" = {
            "default.clock.rate" = 48000;
            "default.clock.allowed-rates" = [44100 48000 96000];
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

