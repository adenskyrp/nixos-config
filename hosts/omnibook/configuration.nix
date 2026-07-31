# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  hardware.system76.kernel-modules.enable = true;

  boot.kernelParams = [
    # Prevents runtime power management from suspending the USB host controller.
    # Essential for 8kHz dongles to prevent the first 2-3ms wake-up packet delay.
    "usbcore.autosuspend=-1"
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  services.greetd = {
        enable = true;
        settings = {
          initial_session = {
	  command = "start-hyprland";
            user = "crazycat";
          };
          default_session = {
            # Corrected package reference from pkgs.greetd.tuigreet to standalone pkgs.tuigreet
            command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd start-hyprland";
            user = "crazycat";
          };
        };
      };
  # ---------------------------------------------------------------------------
  # HOME MANAGER INTEGRATION & ATOMIC SAFETY
  # ---------------------------------------------------------------------------
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # Prevents activation crashes when Home Manager encounters unmanaged local files 
    # (e.g., ~/.mozilla/firefox/profiles.ini). Automatically appends '.backup'.
    backupFileExtension = "backup";
  };
  # ---------------------------------------------------------------------------
  # GLOBAL NETWORKING & PRIMARY DNS
  # ---------------------------------------------------------------------------
  # Primary DNS server: Points directly to AdGuard Home on the Debian server
  networking.nameservers = [ "100.96.67.107" ];

  # ---------------------------------------------------------------------------
  # SPLIT-DNS & CACHING (systemd-resolved)
  # ---------------------------------------------------------------------------
  services.resolved = {
    enable = true;

    # Modernized NixOS 26.05+ structured INI settings mapping directly to resolved.conf
    settings = {
      Resolve = {
        Cache = "yes";                   # RAM-level DNS caching for zero-latency game lookups
        DNSOverTLS = "opportunistic";     # Encrypts queries when upstream server supports it
        FallbackDNS = [                  # Replaces deprecated services.resolved.fallbackDns
          "1.1.1.1#one.one.one.one" 
          "9.9.9.9#dns.quad9.net"
        ];
      };
    };
  };
  # ---------------------------------------------------------------------------
  # TAILSCALE MESH NETWORK
  # ---------------------------------------------------------------------------
  services.tailscale = {
    enable = true;
    
    # Integrate cleanly with systemd-resolved for per-interface split-DNS
    extraUpFlags = [
      "--accept-dns=true"
    ];
  };

  # Preserve your sterile boot pipeline: manual daemon activation only
  systemd.services.tailscaled.wantedBy = pkgs.lib.mkForce [ ];
  networking.firewall.checkReversePath = "loose";

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.crazycat = {
    isNormalUser = true;
    description = "Aden Sky";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    ethtool
    git
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

    environment.pathsToLink = [
    "/share/xdg-desktop-portal"
    "/share/applications"
  ];
  security.pam.loginLimits = [
    { domain = "*"; item = "nofile"; type = "soft"; value = "1048576"; }
    { domain = "*"; item = "nofile"; type = "hard"; value = "1048576"; }
  ];
  services.gnome.gnome-keyring.enable = true;
  # ---------------------------------------------------------------------------
  # SECURITY & POLKIT
  # ---------------------------------------------------------------------------
  security.polkit.enable = true;

  # ---------------------------------------------------------------------------
  # HIGH-POLLING USB INTERRUPT & POWER MANAGEMENT TUNING
  # ---------------------------------------------------------------------------
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="258a", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{product}=="*8k*", ATTR{power/control}="on"
  '';

  systemd.services.pin-xhci-irq = {
    description = "Pin Compx 8K xHCI USB Host Controller IRQ to CPU P-Core 2";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      TARGET_BUS="c5:00.4"
      TARGET_IRQ=$(${pkgs.gawk}/bin/awk -v bus="$TARGET_BUS" '$0 ~ bus {sub(":", "", $1); print $1}' /proc/interrupts)

      if [ -n "$TARGET_IRQ" ] && [ -f "/proc/irq/$TARGET_IRQ/smp_affinity_list" ]; then
        echo "2" > "/proc/irq/$TARGET_IRQ/smp_affinity_list"
      else
        ALL_IRQS=$(${pkgs.gawk}/bin/awk -F':' '/xhci_hcd/ {print $1}' /proc/interrupts | ${pkgs.findutils}/bin/xargs)
        for IRQ in $ALL_IRQS; do
          if [ -f "/proc/irq/$IRQ/smp_affinity_list" ]; then
            echo "2" > "/proc/irq/$IRQ/smp_affinity_list"
          fi
        done
      fi
    '';
  };

  # ---------------------------------------------------------------------------
  # BLEEDING-EDGE AMD RDNA 3.5 GRAPHICS PIPELINE
  # ---------------------------------------------------------------------------
  # Replaces standard Mesa with Chaotic-Nyx's daily git builds for maximum
  # Vulkan performance on the Radeon 880M.
  chaotic.mesa-git.enable = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # ---------------------------------------------------------------------------
  # GAMESCOPE MICRO-COMPOSITOR (System-Level Wrapper)
  # ---------------------------------------------------------------------------
  programs.gamescope = {
    enable = true;
    # Wraps the binary with cap_sys_nice, unlocking the --rt flag in Steam
    capSysNice = false;
    # Targets the git master branch provided by the Chaotic-Nyx overlay
    package = pkgs.gamescope_git;
  };
  # ---------------------------------------------------------------------------
  # LIGHTWEIGHT GUI FILE MANAGEMENT
  # ---------------------------------------------------------------------------
  # Thunar requires system-level declaration to mount drives and manage trash.
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [
      thunar-archive-plugin
      thunar-volman
    ];
  };

  # Daemons required for Thunar to function properly outside a Desktop Environment
  services.gvfs.enable = true;    # Mount, trash, and other virtual filesystems
  services.tumbler.enable = true; # Video/Image thumbnail generation
  services.irqbalance.enable = false;
}
