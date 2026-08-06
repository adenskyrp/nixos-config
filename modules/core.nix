# ~/nixos-config/modules/core.nix
{ config, pkgs, lib, ... }:

{
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
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50; 
  };
  programs.dconf.enable = true;

  # ---------------------------------------------------------------------------
  # COMPETITIVE NETWORKING & EDGE DNS
  # ---------------------------------------------------------------------------
  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
    wifi.macAddress = "permanent";
    
    # THE SEVERANCE: Strip NetworkManager of all DNS authority. 
    # It will no longer pass Spectrum's DHCP/SLAAC servers to systemd-resolved.
    dns = lib.mkForce "none"; 
  };
  
  networking.nameservers = [ "127.0.0.53" ];
  networking.firewall.checkReversePath = "loose";
  services.resolved = {
    enable = true;
    
    # The modern, strictly-typed systemd-resolved configuration
    settings = {
      Resolve = {
	DNS = "9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com";
        FallbackDNS = "149.112.112.112#dns.quad9.net 1.0.0.1#cloudflare-dns.com";
        DNSSEC = "true";
        Domains = "~.";

        
        # STRICT mode DoT configuration
        DNSOverTLS = "yes";
        Cache = "yes";
        CacheFromLocalhost = "no";
      };
    };
  };
  # --- KERNEL NETWORK TUNING ---
  # TCP BBR requires the 'tcp_bbr' kernel module to be loaded BEFORE sysctl applies.
  # Without this, systemd-sysctl silently fails and defaults back to CUBIC.
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    # Forces Fair Queueing to prioritize UDP game packets over bulk TCP traffic
    "net.core.default_qdisc" = "fq_codel";
    # Uses Google's BBR algorithm for TCP, reducing generic network latency
    "net.ipv4.tcp_congestion_control" = "bbr";
    
    # Expands UDP buffer sizes to 16MB for high-tick-rate games (Rocket League/CS2)
    # Prevents dropped packets during violent network spikes on shared infrastructure
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
  };

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
          "default.clock.allowed-rates" = [ 48000 96000 ];
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
          "server.address" = [ "unix:native" ];
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
            matches = [ { "node.name" = "~alsa_output.*"; } ];
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
          "bluez5.codecs" = [ "sbc_xq" "sbc" ];
          "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
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
    extraGroups = [ "networkmanager" "wheel" "video" "input" "audio" ];
    
    # Bind the Fish shell to your user profile natively.
    shell = pkgs.fish;
  };

  security.polkit.enable = true;
  security.pam.loginLimits = [
    { domain = "*"; item = "nofile"; type = "soft"; value = "1048576"; }
    { domain = "*"; item = "nofile"; type = "hard"; value = "1048576"; }
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "95"; }
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }
  ];

  # ---------------------------------------------------------------------------
  # LOCALIZATION & BASE UTILITIES
  # ---------------------------------------------------------------------------
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb = { layout = "us"; variant = ""; };
  services.gnome.gnome-keyring.enable = true;
  programs.fish.enable = true;
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [ thunar-archive-plugin thunar-volman ];
  };
  services.gvfs.enable = true;    
  services.tumbler.enable = true; 

  environment.pathsToLink = [ "/share/xdg-desktop-portal" "/share/applications" ];
  environment.systemPackages = with pkgs; [
    vim wget ethtool git bluetui wireplumber pulsemixer pciutils lm_sensors htop kitty pavucontrol shared-mime-info
  ];
}
