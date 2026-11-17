# Nix itself: evaluation policy, the daemon's CPU and I/O share, store upkeep.
{config, ...}: {
  # ---------------------------------------------------------------------------
  # REPOSITORY EVALUATION POLICIES & FLAKE STATE
  # ---------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;
  # No permittedInsecurePackages: the electron-40.10.5 exception that used to
  # be here matched nothing in any host's closure (checked 2026-11-15).

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
    # 256 MiB: avoids "download buffer is full" stalls when substituting
    # large paths (kernel, mesa-git, proton) on a fast link.
    download-buffer-size = 268435456;
  };

  # ---------------------------------------------------------------------------
  # NIX BUILDS: ALL CORES, HIGH PRIORITY
  # ---------------------------------------------------------------------------
  # Every system service inherits Manager.CPUAffinity = backgroundCores, and
  # system.slice is cpuset-confined to it, so builds ran on 4 threads (desktop).
  # Builds are run when nothing latency-sensitive is, so nix-daemon gets its
  # own top-level slice with every CPU and 10x the CPU/IO weight of
  # user.slice / system.slice (weight is what arbitrates between cgroups;
  # nice only orders tasks inside one).
  systemd.slices.nixbuild = {
    description = "Nix builds (all CPUs, high weight)";
    sliceConfig = {
      AllowedCPUs = config.local.hardware.allCores;
      CPUWeight = 1000;
      IOWeight = 1000;
    };
  };
  systemd.services.nix-daemon.serviceConfig = {
    Slice = "nixbuild.slice";
    CPUAffinity = config.local.hardware.allCores;
  };
  nix.daemonIOSchedClass = "best-effort";
  nix.daemonIOSchedPriority = 0;

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

  # `nh os switch` / `nh os build`: nixos-rebuild with an nvd package diff and
  # build tree. nh.clean stays off (nix.gc above already owns GC).
  programs.nh = {
    enable = true;
    flake = "/home/crazycat/nixos-config";
  };
}
