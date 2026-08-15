# ~/nixos-config/modules/core.nix
{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # REPOSITORY EVALUATION POLICIES
  # ---------------------------------------------------------------------------
  # MUST BE AT THE ROOT LEVEL. Grants the evaluator permission to compile
  # closed-source binaries (Steam, Proton, etc.) across the entire flake.
  nixpkgs.config.allowUnfree = true;

  # ---------------------------------------------------------------------------
  # NIX ARCHITECTURE & STATE
  # ---------------------------------------------------------------------------
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
  };

  nix.gc = {
    automatic = true;
    # Run weekly. We don't want to run this daily; maintaining a 
    # short history of recent generations is critical for your rollback safety net.
    dates = "weekly";
    
    # We explicitly tell the collector to only wipe generations older than 7 days.
    # If a CachyOS kernel patch breaks your Wayland session on a Tuesday, 
    # you still have last week's working generation in the bootloader.
    options = "--delete-older-than 7d";
  };

  nix.optimise = {
    automatic = true;
    # We schedule this for an obscure time (e.g., 4:00 AM) or let systemd 
    # catch up when the laptop wakes. We do NOT use 'nix.settings.auto-optimise-store = true'
    # on a gaming machine, because that triggers deduplication during every 
    # rebuild, artificially slowing down your development loop.
    dates = [ "04:00" ];
  };

  services.fstrim = {
    enable = true;
    # Runs weekly by default. This prevents write amplification and 
    # keeps your disk latency at absolute minimums.
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  programs.dconf.enable = true;

  networking.nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ];

  # ---------------------------------------------------------------------------
  # COMPETITIVE NETWORKING & STRICT DOT DNS ISOLATION
  # ---------------------------------------------------------------------------
  networking.networkmanager = {
    # Line 36
    enable = true;
    wifi.powersave = false;
    wifi.macAddress = "permanent";

    # Strip NetworkManager of /etc/resolv.conf authority
    dns =  "systemd-resolved";

    # STRUCTURED NETWORKMANAGER CONFIGURATION
    settings = {
      device = {
        "wifi.scan-rand-mac-address" = "no";
      };

      connection = {
        "wifi.bgscan" = "ignore";
        "ipv4.ignore-auto-dns" = "true";
        "ipv6.ignore-auto-dns" = "true";
      };
    };
  };

  networking.firewall.allowedUDPPorts = [ 41641 ];
  networking.firewall.checkReversePath = "loose";
  # ---------------------------------------------------------------------------
  # THUNDERBOLT 4 / USB4 SYSTEM DAEMON & DMA PROTECTION
  # ---------------------------------------------------------------------------
  # Thunderbolt 4 tunnels raw PCIe lanes directly into your Strix Point SoC.
  # Bolt handles device authorization, IOMMU DMA isolation, and secure pairing.
  services.hardware.bolt.enable = true;
  # Rule to automatically authorize Thunderbolt 4 devices when physically connected,
  # bypassing manual CLI authorization while maintaining hardware safety.
  services.tailscale.enable = true;
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="3537", ATTR{idProduct}=="10c5", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1209", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1278", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="09", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"
    SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance"
    SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05a7", ATTRS{idProduct}=="40fe", TAG+="uaccess"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05a7", ATTRS{idProduct}=="400d", TAG+="uaccess"
    KERNEL=="card0", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"
  '';

  systemd.services.disable-usb-autosuspend = {
    description = "Force all USB bus power nodes to active state (disable autosuspend)";
    wantedBy = ["multi-user.target"];
    after = ["systemd-udev-settle.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'for dev in /sys/bus/usb/devices/*/power/control; do [ -f \"$dev\" ] && echo on > \"$dev\"; done'";
    };
  };

  services.resolved = {
    enable = true;

    settings = {
      Resolve = {
        # Primary upstream resolvers with explicit DoT SNI hostnames
        DNS = "9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com";

        # Fallback resolvers if primary endpoints fail to respond
        FallbackDNS = "149.112.112.112#dns.quad9.net 1.0.0.1#cloudflare-dns.com";

        # Force strict DNSSEC validation on all queries
        DNSSEC = "true";

        # STRICT DoT MODE: Enforces TLS encryption on Port 853.
        # Queries WILL FAIL rather than fallback to plain-text UDP/53.
        DNSOverTLS = "yes";

        # Route ALL Top-Level Domains (~.) through these DoT resolvers
        Domains = "~.";

        Cache = "yes";
        CacheFromLocalhost = "no";
      };
    };
  };
  # --- KERNEL NETWORK TUNING ---
  # TCP BBR requires the 'tcp_bbr' kernel module to be loaded BEFORE sysctl applies.
  # Without this, systemd-sysctl silently fails and defaults back to CUBIC.
  boot.kernelModules = ["tcp_bbr" "sch_cake"];
  boot.kernel.sysctl = {
    # Forces Fair Queueing to prioritize UDP game packets over bulk TCP traffic
    "net.core.default_qdisc" = "cake";
    # Uses Google's BBR algorithm for TCP, reducing generic network latency
    "net.ipv4.tcp_congestion_control" = "bbr";

    # Expands UDP buffer sizes to 16MB for high-tick-rate games (Rocket League/CS2)
    # Prevents dropped packets during violent network spikes on shared infrastructure
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "vm.compaction_proactiveness" = 20; # Aggressively compact memory in background
    "vm.watermark_boost_factor" = 1; # Reduce allocation latency under high VRAM pressure
    "vm.swappiness" = 10; # Prevent kernel from swapping active process memory
    "kernel.sched_mitigation_cost_ns" = 500000;
  };

  services.upower.enable = true;

  # ---------------------------------------------------------------------------
  # LOW-LATENCY AUDIO SUBSYSTEM (PipeWire 1.33ms Quantum)
  # ---------------------------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;

    # Enforce extreme low-latency PipeWire quantum limits
    extraConfig.pipewire = {
      "10-clock-quantum" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.allowed-rates" = [48000 96000];
          "default.clock.quantum" = 64;
          "default.clock.min-quantum" = 64;
          "default.clock.max-quantum" = 1024; # Prevent fallback to high buffers
        };
      };
    };

    # Optimize PipeWire-Pulse interface for minimum latency
    extraConfig.pipewire-pulse = {
      "10-pulse-latency" = {
        "pulse.properties" = {
          "server.address" = ["unix:native"];
        };
        "stream.properties" = {
          # Request 1.33ms latency from PulseAudio wrapper clients (like older games)
          "node.latency" = "64/48000";
        };
      };
    };

    wireplumber.extraConfig = {
      # The ALSA Hardware Overrides for the Radeon GPU Sink
      "11-alsa-gpu-tuning" = {
        "monitor.alsa.rules" = [
          {
            matches = [{"node.name" = "~alsa_output.*";}];
            actions = {
              update-props = {
                "node.pause-on-idle" = false;

                # Force pure 32-bit little-endian to match GPU DAC handling
                "audio.format" = "S32LE";
                "audio.rate" = 48000;

                # Lock hardware interrupt period to match the quantum
                "api.alsa.period-size" = 64;

                # Zero headroom. No safety buffer.
                "api.alsa.headroom" = 0;

                # Reduce CPU interrupt storms for tight buffers
                "api.alsa.disable-batch" = false;
              };
            };
          }
        ];
      };

      # Preserved your existing Bluetooth settings
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
  # PAM REALTIME PRIVILEGES & ACCOUNTS
  # ---------------------------------------------------------------------------
  users.users.crazycat = {
    isNormalUser = true;
    description = "Aden Sky";
    # ADDED: "audio" group. Without this, the PAM limits below are utterly useless to you.
    extraGroups = ["networkmanager" "wheel" "video" "input" "audio"];

    # Bind the Fish shell to your user profile natively.
    shell = pkgs.fish;
  };

  security.polkit.enable = true;
  security.pam.loginLimits = [
    {
      domain = "*";
      item = "nofile";
      type = "soft";
      value = "1048576";
    }
    {
      domain = "*";
      item = "nofile";
      type = "hard";
      value = "1048576";
    }

    # Audio Group Limits (PipeWire / WirePlumber)
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

    # Administrative Group Limits (Hyprland / Real-time Game Engines)
    # Allows administrative processes launched via chrt or gamemode to claim SCHED_FIFO
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
  # LOCALIZATION & BASE UTILITIES
  # ---------------------------------------------------------------------------
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  services.gnome.gnome-keyring.enable = true;
  programs.fish.enable = true;
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [thunar-archive-plugin thunar-volman];
  };
  programs.xfconf.enable = true;
  services.tumbler.enable = true;
  services.gvfs.enable = true;
  services.journald.extraConfig = ''
    SystemMaxUse=250M
    MaxFileSec=1month
  '';
  environment.pathsToLink = ["/share/xdg-desktop-portal" "/share/applications"];
  environment.systemPackages = with pkgs; [
    vim
    wget
    ethtool
    git
    iw
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
    hyprpolkitagent
    ffmpegthumbnailer
    sshfs
    fastfetch
    (pkgs.callPackage ./pear.nix {})
  ];
}
