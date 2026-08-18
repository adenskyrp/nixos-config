{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # REPOSITORY EVALUATION POLICIES & FLAKE STATE
  # ---------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
  };

  # Weekly garbage collection preserving a 7-day rollback safety net
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Periodic store deduplication scheduled off-peak
  nix.optimise = {
    automatic = true;
    dates = ["04:00"];
  };

  services.fstrim.enable = true;

  # High-speed memory compression
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  programs.dconf.enable = true;

  # ---------------------------------------------------------------------------
  # COMPETITIVE NETWORKING & STRICT DoT ROUTING
  # ---------------------------------------------------------------------------
  networking.nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ];

  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
    wifi.macAddress = "permanent";
    dns = "systemd-resolved";

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

  networking.firewall.allowedUDPPorts = [ 41641 ]; # Tailscale WireGuard port
  networking.firewall.checkReversePath = "loose";

  services.resolved = {
    enable = true;
    settings = {
      Resolve = {
        DNS = "9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com";
        FallbackDNS = "149.112.112.112#dns.quad9.net 1.0.0.1#cloudflare-dns.com";
        DNSSEC = "true";
        DNSOverTLS = "yes";
        Domains = "~.";
        Cache = "yes";
        CacheFromLocalhost = "no";
      };
    };
  };

  # --- KERNEL NETWORK TUNING (CAKE + BBR) ---
  boot.kernelModules = ["tcp_bbr" "sch_cake"];
  boot.kernel.sysctl = {
    # Prioritize interactive UDP game packets over bulk TCP traffic
    "net.core.default_qdisc" = "cake";
    "net.ipv4.tcp_congestion_control" = "bbr";

    # Expand buffer ceilings for high-tick-rate UDP streams
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    
    # Memory compaction & swapping heuristics
    "vm.compaction_proactiveness" = 20;
    "vm.watermark_boost_factor" = 1;
    "vm.swappiness" = 10;
    "kernel.sched_mitigation_cost_ns" = 500000;
  };

  # ---------------------------------------------------------------------------
  # THUNDERBOLT 4 / USB4 & UDEV HARDWARE ISOLATION
  # ---------------------------------------------------------------------------
  services.hardware.bolt.enable = true;
  services.tailscale.enable = true;

  services.udev.extraRules = ''
    # Low-latency NVMe queue scheduler
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

    # Auto-authorize Thunderbolt 4 endpoints
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"

    # High-polling HID and direct gamepad access permissions
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05a7", ATTRS{idProduct}=="40fe", TAG+="uaccess"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05a7", ATTRS{idProduct}=="400d", TAG+="uaccess"
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0660", GROUP="users", TAG+="uaccess"
    KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="users", TAG+="uaccess"
  '';

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

    extraConfig.pipewire = {
      "10-clock-quantum" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.allowed-rates" = [48000 96000];
          "default.clock.quantum" = 64;
          "default.clock.min-quantum" = 64;
          "default.clock.max-quantum" = 1024;
        };
      };
      # Explicitly bind the Real-Time module to claim the priority granted by PAM/RTKit
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
            flags = [ "ifexists" "nofail" ];
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
          "node.latency" = "64/48000";
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
                "api.alsa.period-size" = 64;
                # Provide a 1-period (1.33ms) safety net for the DMA pointer
                "api.alsa.headroom" = 64;
                # Force high-resolution IRQ timers instead of grouped batch wakeups
                "api.alsa.disable-batch" = true; 
              };
            };
          }
        ];
      };

      # Blue Yeti hardware gain lock (Disables WebRTC AGC volume manipulation)
      "12-blue-yeti-gain-lock" = {
        "monitor.alsa.rules" = [
          {
            matches = [ { "node.name" = "~alsa_input.*Blue_Microphones.*"; } ];
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
    extraGroups = ["networkmanager" "wheel" "video" "input" "audio"];
    shell = pkgs.fish;
  };

  security.polkit.enable = true;
  security.pam.loginLimits = [
    # General User File Descriptors & Memory Locks
    { domain = "@users"; item = "nofile"; type = "-"; value = "1048576"; }
    { domain = "@users"; item = "memlock"; type = "-"; value = "unlimited"; }

    # Audio Realtime Scheduling (PipeWire / WirePlumber)
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "95"; }
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }

    # Realtime Game Engines & Compositor Priority
    { domain = "@wheel"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@wheel"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@wheel"; item = "nice"; type = "-"; value = "-20"; }
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
  ];
}
