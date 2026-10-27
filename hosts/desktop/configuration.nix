{
config,
pkgs,
lib,
inputs,
...
}: let
gpuDpmLevel = "high";

# ---------------------------------------------------------------------------
# DESKTOP PCI IRQ PIN TABLE (Ryzen 5 5600X SMT ON: 12 Threads / 6 Physical Cores)
# ---------------------------------------------------------------------------
# - Cores 0-3 Primary (CPUs 0,1,2,3): Game main & worker threads (Isolated)
# - Physical Core 4   (CPUs 4,10):     Radeon RX 5700 XT (08:00.0), Audio (08:00.1) + CRTC
# - Physical Core 5   (CPUs 5,11):     8KHz xHCI, NIC, Wi-Fi 7, Audio, Background Tasks
desktopIrqPinScript = pkgs.writeShellScript "desktop-hardware-irq-pin" ''
set -u
grep_bin=${pkgs.gnugrep}/bin/grep
awk_bin=${pkgs.gawk}/bin/awk

pin_pci() {
local pci=$1
local cpu=$2
local irq
for irq in $("$grep_bin" -F -- "$pci" /proc/interrupts | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'); do
if [ -e "/proc/irq/$irq/smp_affinity_list" ]; then
echo "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
echo "desktop-irq-pin: $pci (irq $irq) -> cpu$cpu"
fi
done
}

# 1. 8KHz Peripherals & Networking -> Physical Core 5 (CPUs 5,11)
pin_pci "0000:0a:00.3" "5,11"
for pid in $(${pkgs.procps}/bin/pgrep -f "irq/.*-xhci_hcd" || true); do
${pkgs.util-linux}/bin/chrt -f -p 90 "$pid" 2>/dev/null || true
done
pin_pci "0000:02:00.0" "5,11"
pin_pci "0000:04:00.0" "5,11"
pin_pci "0000:05:00.0" "5,11"
pin_pci "0000:0a:00.4" "5,11"

for irq in $("$grep_bin" -E "ath12k|wlp|enp" /proc/interrupts | "$awk_bin" -F: '{gsub(/ /, "", $1); print $1}'); do
echo "5,11" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
done

# 2. Radeon RX 5700 XT (08:00.0) & Audio (08:00.1) -> Physical Core 4 (CPUs 4,10)
pin_pci "0000:08:00.0" "4,10"
pin_pci "0000:08:00.1" "4,10"
for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^card[0-9]+-crtc/ {print $1}'); do
${pkgs.util-linux}/bin/taskset -pc 4,10 "$pid" >/dev/null 2>&1 || true
done

# 3. Background Housekeeping -> Physical Core 5 (CPUs 5,11)
for pid in $(${pkgs.procps}/bin/ps -eo pid,comm --no-headers | "$awk_bin" '$2 ~ /^(jbd2\/|kswapd|kcompactd|khugepaged|ksmd|kauditd|khungtaskd|psimon|hwrng|watchdogd|usb-storage|scsi_eh_|kdevtmpfs)/ {print $1}'); do
${pkgs.util-linux}/bin/taskset -pc 5,11 "$pid" >/dev/null 2>&1 || true
done
'';
in {
nixpkgs.config.permittedInsecurePackages = [
"electron-40.10.5"
];

imports = [
./hardware-configuration.nix
../../modules/core.nix
../../modules/gaming.nix
../../modules/minecraft.nix
../../modules/sober.nix
../../modules/diagnostics.nix
../../modules/webcam.nix
];

# ---------------------------------------------------------------------------
# HOST CPU TOPOLOGY (Ryzen 5 5600X SMT ON: Cores 0-3 Games, Core 4 GPU, Core 5 I/O)
# ---------------------------------------------------------------------------
local.hardware = {
gameCores = "0-3,6-9";
gameCoresNoSmt = "0-3,6-9";
backgroundCores = "4,5,10,11";
monitors = [
''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
];
};
networking.hostName = "desktop";

boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;
systemd.packages = [ pkgs.lact ];
systemd.services.lactd.wantedBy = [ "multi-user.target" ];
boot.kernelPackages = pkgs.linuxPackages_cachyos;

boot.kernelModules = [
"nct6775"
"ath12k"
];

boot.kernelParams = [
"amd_pstate=active"
"amdgpu.ppfeaturemask=0xffffffff"
"amdgpu.gpu_recovery=1"
"pcie_aspm=off"
"irqaffinity=5,11"
"zswap.enabled=0"
"systemd.gpt_auto=0"
"transparent_hugepage=madvise"
"split_lock_detect=off"
"threadirqs"
"nowatchdog"
"nmi_watchdog=0"
"tsc=reliable"
"clocksource=tsc"
"usbcore.autosuspend=-1"
"iomem=relaxed"
"reboot=pci"
"mitigations=off"
];

boot.blacklistedKernelModules = ["sp5100_tco"];

services.udev.extraRules = ''
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x731f", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x17cb", ATTR{device}=="0x1107", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1278", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="373b", ATTR{idProduct}=="1209", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
'';

systemd.services.optimize-nic = {
description = "Tune Realtek Ethernet for competitive gaming latency";
after = ["network.target"];
wantedBy = ["multi-user.target"];
serviceConfig = {
Type = "oneshot";
RemainAfterExit = true;
ExecStart = pkgs.writeShellScript "tune-desktop-nic" ''
for IFACE in enp5s0 enp4s0; do
if [ -d "/sys/class/net/$IFACE" ]; then
${pkgs.ethtool}/bin/ethtool --set-eee "$IFACE" eee off 2>/dev/null || true
${pkgs.ethtool}/bin/ethtool -K "$IFACE" gro off lro off 2>/dev/null || true
fi
done
'';
};
};

services.irqbalance.enable = false;
systemd.services.xhci-irq-unpin.enable = false;

systemd.services.hardware-irq-pin = {
description = "Pin 8KHz xHCI, Navi 10 amdgpu, and Realtek NIC IRQs to dedicated Zen 3 threads";
wantedBy = ["multi-user.target"];
after = ["systemd-modules-load.service"];
serviceConfig = {
Type = "oneshot";
RemainAfterExit = true;
ExecStart = desktopIrqPinScript;
};
};

powerManagement = {
enable = true;
resumeCommands = ''
${pkgs.systemd}/bin/systemctl restart hardware-irq-pin.service || true
'';
};

systemd.tmpfiles.rules = [
"w /sys/devices/system/cpu/cpu[0-11]/cpufreq/scaling_governor - - - - performance"
"w /sys/devices/system/cpu/cpu[0-11]/cpufreq/energy_performance_preference - - - - performance"
"w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - ${gpuDpmLevel}"
# Bitmask 0x820 targets CPUs 5 and 11 (Physical Core 5)
"w /sys/devices/virtual/workqueue/cpumask - - - - 820"
"w /sys/bus/workqueue/devices/writeback/cpumask - - - - 820"
"w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
];

systemd.settings.Manager.CPUAffinity = "4,5,10,11";
systemd.user.settings.Manager.CPUAffinity = "4,5,10,11";
systemd.slices."system".sliceConfig.AllowedCPUs = "4,5,10,11";

chaotic.mesa-git.enable = true;
hardware.graphics = {
enable = true;
enable32Bit = true;
};

environment.sessionVariables = {
AQ_NO_MODIFIERS = lib.mkForce "0";
};

services.udev.packages = [pkgs.swayosd];

services.greetd = {
enable = true;
settings = {
default_session = {
command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'start-hyprland'";
        user = "crazycat";
      };
    };
  };
  systemd.services.greetd = {
    wants = lib.mkForce [];
    after = lib.mkForce ["systemd-user-sessions.service"];
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
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  security.pam.services.greetd.enableGnomeKeyring = true;

  local.diagnostics = {
    enable = false;
    unsafeTracing = false;
  };

  system.stateVersion = "25.11";
}
