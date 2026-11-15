# PLACEHOLDER: written by hand, NOT generated on the machine. It exists so the
# flake evaluates. On the z890 box, replace it with the real one:
#   nixos-generate-config --show-hardware-config > hosts/z890/hardware-configuration.nix
#
# Until then it mounts by filesystem label, the way the NixOS manual formats a
# UEFI install (`mkfs.ext4 -L nixos`, `mkfs.fat -F 32 -n boot`). If the disks
# carry other labels, stage 1 stops waiting for /dev/disk/by-label/nixos.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # vmd: prebuilt Intel boards often ship with VMD on, which hides the NVMe
  # drive from the kernel unless this module is in the initrd.
  boot.initrd.availableKernelModules = ["nvme" "vmd" "xhci_pci" "thunderbolt" "ahci" "usbhid" "usb_storage" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = ["defaults" "noatime"];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = ["fmask=0077" "dmask=0077"];
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
