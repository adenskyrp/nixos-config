# Connectivity: NetworkManager and Wi-Fi policy, firewall backend, TCP tuning,
# Bluetooth, mDNS.
{...}: {
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
  boot.kernelModules = ["tcp_bbr"];

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
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;
    settings.General = {
      Experimental = true;
      FastConnectable = true;
    };
  };

  services.avahi.enable = true;
}
