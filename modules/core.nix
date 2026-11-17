# Base system shared by every host: boot, kernel, memory, devices, the user.
# CPU isolation is in cpu.nix; audio, network, session and Nix have their own
# files.
{pkgs, ...}: {
  # ---------------------------------------------------------------------------
  # BOOT & KERNEL
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot = {
    enable = true;
    # Every generation keeps a kernel and an initrd on /boot.
    configurationLimit = 15;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # The prebuilt Chaotic-Nyx kernel, straight from its binary cache. Must be the
  # -bore attribute: plain linuxPackages_cachyos is the clang-LTO build with
  # BORE compiled out (no kernel.sched_bore sysctl; found 2026-11-08).
  # No sched-ext scheduler is loaded: BORE measured better than scx_lavd on the
  # omnibook (2026-08-20, possibly against a non-BORE kernel, see above).
  boot.kernelPackages = pkgs.linuxPackages_cachyos-bore;

  boot.kernelModules = ["ntsync"];

  boot.kernelParams = [
    "8250.nr_uarts=0"
    "pcie_aspm=off"
    # zram is the swap device, and THP only on madvise() so khugepaged scans
    # never stall a game.
    "zswap.enabled=0"
    "transparent_hugepage=madvise"
    "split_lock_detect=off"
    "threadirqs"
    "nowatchdog"
    "nmi_watchdog=0"
    "tsc=reliable"
    "clocksource=tsc"
    "usbcore.autosuspend=-1"
    "iomem=relaxed"
    # Speculative-execution mitigations off: a known security trade-off.
    "mitigations=off"
  ];

  # ---------------------------------------------------------------------------
  # MEMORY
  # ---------------------------------------------------------------------------
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  boot.kernel.sysctl = {
    "vm.compaction_proactiveness" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.swappiness" = 10;
  };

  # Never stall on synchronous THP compaction.
  systemd.tmpfiles.rules = [
    "w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  ];

  # ---------------------------------------------------------------------------
  # DEVICES & SEAT ACCESS
  # ---------------------------------------------------------------------------
  hardware.enableRedistributableFirmware = true;
  services.power-profiles-daemon.enable = false;

  # The one place the graphics stack is switched on; the GPU modules add the
  # vendor driver.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.udev.extraRules = ''
    # Enforce radio power_save=off whenever any wireless netdev initializes
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*|wlp*", RUN+="${pkgs.iw}/bin/iw dev %k set power_save off"

    # Low-latency NVMe queue scheduler
    ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"

    # Auto-authorize Thunderbolt 4 endpoints
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"

    # USB: Force continuous active power state (eliminates first-input wake delay)
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/control}="on"

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

  programs.fish.enable = true;

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
}
