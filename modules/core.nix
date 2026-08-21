{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # CPU SCHEDULER
  # ---------------------------------------------------------------------------
  # No sched-ext scheduler is loaded: the CachyOS kernel's own BORE
  # (Burst-Oriented Response Enhancer) EEVDF variant is used as-is, which
  # measured better on this machine than scx_lavd (tested 2026-08-20). A BPF
  # scheduler replaces BORE outright rather than layering on it, and its failure
  # mode is silent -- if the scx unit dies the kernel drops back to the in-tree
  # scheduler mid-session with nothing surfacing the swap. Leaving it out removes
  # both the regression and that class of surprise.

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
  # These three jobs are heavy enough to be felt: measured on this machine,
  # nix-optimise hard-links ~157k files reading 4-6.5 GB over ~90-115 s, nix-gc
  # reads ~900 MB over ~24 s, and fstrim discards the full 638 GiB root in ~60 s.
  #
  # All three default to Persistent = true, and that is the actual hazard. A
  # laptop is asleep or off at 00:00 and 04:00, so the timers almost never fire
  # at their scheduled hour -- systemd instead runs the missed job on the next
  # boot. The effect is that the machine ambushes itself with a minute of
  # saturated NVMe I/O shortly after login, which is precisely when someone sits
  # down to play. Dropping catch-up means a missed window is simply skipped
  # until the next real occurrence; nothing here needs to run on a strict
  # cadence, and a rebuild rewrites the store anyway.
  #
  # Note this cannot be solved with ionice: the udev rule further down sets
  # NVMe queue/scheduler=none, and with no I/O scheduler attached there is
  # nothing to honor an idle scheduling class -- requests go straight to the
  # hardware queue in submission order. Not competing for the disk in the first
  # place is the only lever that actually works.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    persistent = false;
    options = "--delete-older-than 7d";
  };

  nix.optimise = {
    automatic = true;
    dates = ["04:00"];
    persistent = false;
  };

  services.fstrim.enable = true;

  # services.fstrim exposes no persistent option, so reach the timer directly.
  systemd.timers.fstrim.timerConfig.Persistent = false;

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

    # Keep the receiver out of PS-Poll/U-APSD. Powersave parks the radio between
    # beacons (this AP advertises DTIM 2 / 100 ms beacons, so ~200 ms of sleep),
    # which leaves an inbound server tick sitting in the AP's buffer until the
    # next wake-up instead of landing on arrival.
    wifi.powersave = false;
    wifi.macAddress = "permanent";
    dns = "systemd-resolved";

    settings = {
      device = {
        # A fresh MAC per scan cycle makes the AP treat us as an unknown station,
        # costing a full association + 4-way handshake on every reconnect.
        "wifi.scan-rand-mac-address" = "no";
      };

      # --- GLOBAL DNS OVERRIDE ---
      # Overrides the resolver list each connection learns over DHCP. Without it
      # NetworkManager registers the router's leased servers on the default-route
      # link, and systemd-resolved prefers those link-scoped servers over the
      # global DoT servers configured below — so the encrypted path is bypassed,
      # and a dead entry in the lease (this network hands out one) stalls the
      # first lookup for the full resolver timeout before it rotates off.
      #
      # Declared with the DoT URI form so resolved still receives the TLS
      # servername it needs to validate the certificate. A [global-dns-domain-*]
      # section implies an empty [global-dns] section, and that is what makes the
      # override authoritative over per-connection settings.
      "global-dns-domain-*" = {
        servers = "dns+tls://9.9.9.9#dns.quad9.net,dns+tls://1.1.1.1#cloudflare-dns.com";
      };
    };
  };

  # --- 802.11v BSS TRANSITION MANAGEMENT (ROAM STEERING) ---
  # The AP repeatedly issues WNM "BSS Transition Management / Disassociation
  # Imminent" frames to steer clients onto its 2.4 GHz BSS for load balancing.
  # Obeying one costs a deauth + reassoc + 4-way handshake — seconds of dead air
  # mid-match — and on a single-AP network there is nowhere better to roam to.
  # Dropping BTM from our advertised capabilities stops the AP from asking.
  networking.wireless.extraConfig = ''
    disable_btm=1

    # wpa_supplicant will not enable 6 GHz channels at all without an explicit
    # country. Declaring it here also makes the domain SET_BY_USER — the
    # highest-trust regulatory source — instead of leaving it inherited from
    # whatever country IE the AP happens to beacon after we already associated.
    country=US
  '';

  # --- REGULATORY DOMAIN (6 GHz UNLOCK) ---
  # cfg80211 defaults to the "00" world domain, which permits no 6 GHz at all.
  # The domain does get corrected to US later from the AP's country IE, but that
  # lands *after* mt7925 has already registered its wiphy and locked band 4, and
  # the driver never re-enables the band. Pin the domain at module load so 6 GHz
  # is permitted before the radio driver ever evaluates it.
  #
  # This narrows what the card may do rather than widening it: the wireless-regdb
  # US rules still cap 6 GHz at 12 dBm, indoor-only, passive-scan.
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=US
  '';

  # Default is bgscan="simple:30:-70:3600" — once the link dips below -70 dBm
  # wpa_supplicant sweeps every 30 s. Each sweep takes the radio off-channel
  # across all bands for >100 ms, dropping every tick in that window, and on a
  # single-AP network there is no better BSS for it to find. Off-channel scans
  # are exactly the kind of periodic hitch that reads as "the Wi-Fi stuttered".
  networking.wireless.scanOnLowSignal = false;

  # ---------------------------------------------------------------------------
  # PACKET FILTER BACKEND & PROTOCOL ATTACK SURFACE
  # ---------------------------------------------------------------------------
  # Everything in this section lives in the kernel's netfilter/protocol path,
  # which runs on the RX/TX softirq long before a packet's payload reaches the
  # compositor or the GPU. None of it sits on a frame-pacing path, so none of it
  # is measurable in mangohud -- these are per-packet boolean checks and module
  # autoload refusals, not work that touches the render loop.

  # Move the firewall off the legacy iptables backend. Two concrete wins beyond
  # hygiene: a ruleset reload becomes a single atomic transaction instead of an
  # iptables-restore flush-then-refill, so there is no brief window mid-reload
  # where the box sits unfiltered; and one merged ruleset is evaluated per
  # packet rather than walking iptables' separate tables in sequence.
  #
  # Safe here specifically because nothing in this repo emits raw iptables:
  # there are no networking.firewall.extraCommands (which the nftables backend
  # rejects outright rather than silently ignoring), and no docker/podman/libvirt
  # daemon installing chains of its own -- only the docker-client binary in
  # home.nix, which has no local daemon. NetworkManager touches the filter
  # tables only for connection sharing, which is unused here.
  #
  # checkReversePath survives the swap: the nftables backend builds its own
  # strict-RPF prerouting chain carrying the same DHCPv4 sport/dport carve-out
  # the iptables path had, so the strict behavior restored in 771e49f is kept
  # rather than quietly dropped on the backend change.
  networking.nftables.enable = true;

  # Protocol families nothing on this machine opens a socket for. The kernel
  # autoloads any of them on demand -- a stray socket() call is enough -- so
  # blacklisting closes the autoload path rather than unloading anything in use
  # (none of the four are currently resident, confirmed with lsmod). DCCP and
  # SCTP carry the bulk of the historical remote-triggerable CVEs in this set;
  # RDS and TIPC are cluster/datacenter transports with no desktop role at all.
  boot.blacklistedKernelModules = [
    "dccp" # Datagram Congestion Control Protocol
    "sctp" # Stream Control Transmission Protocol
    "rds" # Reliable Datagram Sockets
    "tipc" # Transparent Inter-Process Communication
  ];

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
    # Prioritize interactive UDP game packets over bulk TCP traffic. Note this
    # only reaches wired links (Thunderbolt dock / USB ethernet): mac80211
    # installs "noqueue" on the Wi-Fi netdev and runs its own per-station
    # fq_codel with airtime fairness, so no qdisc can attach there.
    "net.core.default_qdisc" = "cake";
    "net.ipv4.tcp_congestion_control" = "bbr";

    # Expand buffer ceilings for high-tick-rate UDP streams
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;

    # --- ANTI-SPOOFING / ANTI-AMPLIFICATION ---
    # Strict reverse-path filtering, set on BOTH `all` and `default` deliberately:
    # the kernel's effective value per interface is max(all.rp_filter,
    # <iface>.rp_filter), so setting `all` alone would still resolve to 2 (loose)
    # against systemd's shipped default.rp_filter = 2 -- max(1, 2) = 2. The
    # `default` entry is what a newly created netdev inherits, and NixOS writes
    # both to /etc/sysctl.d/60-nixos.conf, which outranks systemd's
    # 50-default.conf on numeric precedence.
    #
    # This duplicates the firewall's own strict-RPF chain one layer down, and is
    # safe for DHCP despite carrying no DHCP carve-out of its own: the
    # NetworkManager internal DHCPv4 client runs discovery over an AF_PACKET raw
    # socket, tapped at the netdev layer before the IP stack's RPF check is ever
    # reached. Lease renewal in BOUND state is plain unicast UDP from an
    # already-routable source, which passes strict RPF normally.
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;

    # Refuse ICMP echo aimed at a broadcast address, which is what makes a host
    # usable as a smurf amplifier by anyone spoofing a victim's source address.
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

    # An accepted ICMP redirect rewrites our routing table mid-session, making it
    # a route-injection primitive for anything on-link. On a single-AP home
    # network there is no second gateway to legitimately be steered toward.
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;

    # Only routers emit redirects and this box does not forward, so sending them
    # is dead weight that also leaks local topology.
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;

    # Source routing lets the sender dictate the return path, a direct spoofing
    # aid. The option predates NAT and has no remaining legitimate use.
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;

    # Already on in this kernel; pinned so a future default flip cannot silently
    # remove SYN-flood resilience.
    "net.ipv4.tcp_syncookies" = 1;

    # Memory compaction & swapping heuristics
    "vm.compaction_proactiveness" = 20;
    "vm.watermark_boost_factor" = 1;
    "vm.swappiness" = 10;
  };

  # ---------------------------------------------------------------------------
  # THUNDERBOLT 4 / USB4 & UDEV HARDWARE ISOLATION
  # ---------------------------------------------------------------------------
  services.hardware.bolt.enable = true;

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
  # xHCI INTERRUPT AFFINITY (INPUT CONTROLLERS ONTO THE Zen5 BIG CORES)
  # ---------------------------------------------------------------------------
  # This Ryzen AI 9 365 is heterogeneous: cpu0-7 are the four Zen5 cores boosting
  # to 5.09 GHz, cpu8-19 the six Zen5c dense cores capped at 3.32 GHz. Nothing
  # constrains where a USB interrupt lands -- smp_affinity_list defaults to the
  # full 0-19 -- and measured on this machine the kernel had placed both
  # input-carrying controllers on dense cores:
  #
  #   irq 43  c5:00.0  bus3          GameSir G7 Pro       6.73M irqs  -> cpu16
  #   irq 45  c5:00.3  bus5 + bus6   8 kHz dongle, ATK    8.82M irqs  -> cpu17
  #                                  keyboard, Yeti, RTL8153
  #
  # The dongle's interrupt endpoint runs bInterval=01 at high speed, i.e. one
  # transfer every 125 us microframe = 8000 Hz. Because `threadirqs` is set, each
  # of those wakeups is a scheduled RT-prio-50 kernel thread (irq/45-xhci_hcd)
  # rather than a hardirq -- so 8000 times a second the mouse's input path was
  # being serviced by a core running ~35% slower than the ones available. Cheap
  # in CPU terms either way; the cost is jitter on the wakeup, which is exactly
  # what an 8 kHz mouse is bought to avoid.
  #
  # Restricting the mask to the big cores lets the kernel keep choosing which one
  # while guaranteeing it never picks a Zen5c. The write is rejected for
  # kernel-managed vectors (NVMe-style), so each result is logged rather than
  # discarded -- an affinity change that silently no-ops is the same failure mode
  # the CPU SCHEDULER note above rejects sched-ext for.
  systemd.services.xhci-irq-affinity = {
    description = "Pin xHCI interrupt handling to the Zen5 big cores";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "xhci-irq-affinity" ''
        for irq in $(${pkgs.gawk}/bin/awk -F: '/xhci_hcd/ {gsub(/ /, "", $1); print $1}' /proc/interrupts); do
          if echo 0-7 > /proc/irq/"$irq"/smp_affinity_list 2>/dev/null; then
            echo "irq $irq pinned to 0-7, now effective on cpu$(cat /proc/irq/"$irq"/effective_affinity_list)"
          else
            echo "irq $irq: affinity write rejected, left on cpu$(cat /proc/irq/"$irq"/effective_affinity_list)" >&2
          fi
        done
      '';
    };
  };

  # An s2idle cycle can re-enumerate the xHCI controllers and hand their vectors
  # back out with a fresh default mask, so the boot-time pin does not survive
  # closing the lid. Re-run the same unit on resume; it re-reads /proc/interrupts
  # and therefore also copes with the irq numbers themselves having changed.
  # (resumeCommands is types.lines, so this concatenates with the SMU/EPP
  # re-injection block in hosts/omnibook/configuration.nix rather than clashing.)
  powerManagement.resumeCommands = ''
    ${pkgs.systemd}/bin/systemctl restart xhci-irq-affinity.service || true
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
    extraGroups = ["networkmanager" "wheel" "video" "input" "audio"];
    shell = pkgs.fish;
  };

  security.polkit.enable = true;
  security.pam.loginLimits = [
    # General User File Descriptors & Memory Locks
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

    # Audio Realtime Scheduling (PipeWire / WirePlumber)
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

    # Realtime Game Engines & Compositor Priority
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
