# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal NixOS flake configuration for adenskyrp's machines, tuned aggressively for low-latency
desktop/gaming use (Hyprland on Wayland with native Lua config, CachyOS BORE kernel, Mesa-git RADV,
PipeWire realtime audio, static IRQ/CPU isolation, per-game Hyprland/DXVK rules). There is no
application code or test suite — this repo *is* the system and home-manager configuration.

## Hosts

- **`omnibook`** — HP OmniBook Ultra 14 laptop (Ryzen AI 9 365: 4x Zen 5 `0-7` + 6x Zen 5c `8-19`,
  Radeon 880M `gfx1150` iGPU with 24 GiB GTT ceiling, 32 GB LPDDR5X, Qualcomm WCN785x Wi-Fi 7).
- **`desktop`** — AM4 desktop (Ryzen 5 5600X: 6x Zen 3, SMT siblings are `N`/`N+6`; Radeon
  RX 5700 XT `gfx1010` Navi 10 8 GB (a 7800 XT swap was trialled and reverted); ASRock B550M-HDV;
  32 GB DDR4; Qualcomm WCN785x Wi-Fi 7 via `ath12k_wifi7_pci`; no wired NIC enabled).
  CPU layout: physical cores 0-3 (`0-3,6-9`) games, core 4 (`4,10`) GPU IRQ/CRTC/audio, core 5
  (`5,11`) xHCI/Wi-Fi/kthreads. BIOS currently has CPPC / Global C-state Control off, so there is
  **no cpufreq or cpuidle driver** (`amd_pstate: _CPC object is not present`), so the desktop sets
  `capCstates = false` and has no cpufreq tmpfiles rules; restore both if that BIOS setting changes.
- **Kernel**: both hosts use `linuxPackages_cachyos-bore`. Plain `linuxPackages_cachyos` is now the
  clang-LTO build with BORE compiled out; check with `sysctl kernel.sched_bore`.

## Commands

```fish
sysdeploy "message"                        # git add, verify lock as user, rebuild+switch, commit, push
sudo nixos-rebuild switch --no-write-lock-file --flake .#(hostname)
nh os build                                # build current host, show nvd package diff, no switch
nix flake check                            # evaluates BOTH hosts; must stay warning-free
nix build --no-link .#nixosConfigurations.desktop.config.system.build.toplevel  # build, no ./result
nix flake update                           # bump flake.lock
alejandra <file>                           # format; avoid `alejandra .` (reflows untouched home.nix)
```

`sysdeploy` is a fish function in `hosts/omnibook/home.nix` (shared by both hosts). It commits and
pushes on success, so only use it when that is wanted.

## Architecture

- **`flake.nix`** — inputs: `chaotic` (Chaotic-Nyx: cached `linuxPackages_cachyos`, `mesa-git`; its
  module also configures the `nyx-cache.chaotic.cx` substituter), `nixpkgs` follows `chaotic/nixpkgs`
  so the kernel/Mesa always hit that cache, `grimoire`, `home-manager`, `nix-flatpak` (pinned tag,
  zero inputs). A `mkHost` builder produces `nixosConfigurations.{omnibook,desktop}`.
- **`hosts/<host>/configuration.nix`** — per-host root: imports, `local.hardware` (CPU topology +
  Hyprland monitor rules), `local.irqAffinity` (IRQ pin table), kernel params, tmpfiles sysfs writes,
  systemd `CPUAffinity`/`AllowedCPUs` = `backgroundCores`, greetd. `omnibook` adds the `ryzenadj`
  oneshot; `desktop` adds `hardware.amdgpu` (initrd KMS, overdrive `0xfffd7fff`) and `services.lact`
  (mutable `/etc/lact/config.yaml`, keyed per GPU PCI ID+slot).
- **`hosts/<host>/home.nix`** — `hosts/omnibook/home.nix` is the full user profile (Hyprland Lua,
  `osuStableLauncher`, ironbar, fuzzel, Neovim, Firefox policies, `xdg.desktopEntries` built from
  `osConfig.local.hardware`). `hosts/desktop/home.nix` imports it and disables `kanshi`.
- **`modules/`**:
  - `core.nix` — defines `options.local.hardware` (`gameCores`, `gameCoresNoSmt`, `backgroundCores`,
    `monitors`, `capCstates`) — the single source of truth for per-host CPU topology, consumed by
    `gaming.nix`, `irq-affinity.nix`, host configs and `home.nix`. Also Nix settings/GC/optimise
    (timers `persistent = false`), `fq`+`bbr` sysctls, udev rules, PipeWire/WirePlumber low-latency
    config, PAM realtime limits, base packages.
  - `irq-affinity.nix` — shared `local.irqAffinity` module (both hosts): pins keyed by PCI address or
    `driver:<name>` (preferred — survives GPU swaps and bus renumbering), `defaultCpus` sweep (needed
    because the kernel always adds cpu0 to `irqaffinity=`), CRTC worker / kthread pinning, optional
    xHCI IRQ-thread FIFO priority, re-run on resume and on NetworkManager Wi-Fi `up` (ath12k resets
    its IRQ affinity hint to cpu0 on firmware start).
  - `gaming.nix` — `pkgs.proton-cachyos-slr` overlay from `proton-cachyos.json` (wrapped to
    `taskset -c gameCores`), Steam, OpenTabletDriver, Proton/Mesa session vars, `/etc/dxvk.conf`
    (keys verified against the bundled DXVK; unknown keys are silently ignored), `zen5`/`zen5-nosmt`
    wrappers.
  - `minecraft.nix` (Prism + Temurin/Zulu 21), `sober.nix` (Flatpak Sober + portals), `webcam.nix`
    (Pixel via `v4l2loopback`/scrcpy), `diagnostics.nix` (opt-in frametime/PSI telemetry),
    `llm.nix` (`omnibook` only; Vulkan llama.cpp).

## Conventions

- Prefer settings that fail loudly over silent no-ops; when a knob is verified dead (env var, dxvk
  key, sysfs path), remove it and leave a one-line note rather than keeping it "just in case".
- Verify hardware claims against the live machine (`lspci -nnk`, `/proc/interrupts`,
  `/sys/bus/pci/drivers/*`) before encoding PCI addresses or CPU numbers.
