# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal NixOS flake configuration for adenskyrp's machines, tuned aggressively for low-latency
desktop/gaming use (Hyprland on Wayland with native Lua config, CachyOS BORE kernel, Mesa-git RADV
or NVIDIA, PipeWire realtime audio, static IRQ/CPU isolation, per-game Hyprland/DXVK rules). There is no
application code or test suite — this repo *is* the system and home-manager configuration.

## Hosts

- **`omnibook`** — HP OmniBook Ultra 14 laptop (Ryzen AI 9 365: 4x Zen 5 `0-7` + 6x Zen 5c `8-19`,
  Radeon 880M `gfx1150` iGPU with 24 GiB GTT ceiling, 32 GB LPDDR5X, Qualcomm WCN785x Wi-Fi 7).
- **`desktop`** — AM4 desktop (Ryzen 5 5600X: 6x Zen 3, SMT siblings are `N`/`N+6`; Radeon
  RX 5700 XT `gfx1010` Navi 10 8 GB (a 7800 XT swap was trialled and reverted); ASRock B550M-HDV;
  32 GB DDR4; Qualcomm WCN785x Wi-Fi 7 via `ath12k_wifi7_pci`; no wired NIC enabled; FiiO K7
  USB DAC/amp on the chipset xHCI is the audio output).
  CPU layout (from measured per-core boost bins, see the host file): physical cores 1,2,4,5
  (`1-2,4-5,7-8,10-11`) games; core 0 (`0,6`) Wi-Fi (ath12k hard-pins its single MSI to cpu0),
  mouse xHCI, default IRQs, kthreads; core 3 (`3,9`, worst bin) GPU IRQ/CRTC, K7 xHCI, PipeWire.
  CPPC and Global C-state Control are **deliberately Disabled** in BIOS (2026-11-11). Setting
  them to Enabled made no difference: the BIOS published no `_CPC`/`_CST` and no `cppc` CPUID
  flag either way. So there is no cpufreq or cpuidle driver; the SMU handles boost on its own
  (4.84 GHz single-core) and cores only HLT into C1. `cpufreq-performance` and `cpu-idle-limit`
  log their expected warning every boot and do nothing. They take effect automatically if the
  firmware ever exposes those objects.
- **`z890`** — iBUYPOWER Z890 desktop on an ASUS board (Core Ultra 7 270K Plus: 8 P-cores `0-7` +
  16 E-cores `8-23`, no SMT; NVIDIA RTX 5070 on the open kernel modules, the only DRM device;
  MediaTek MT7925 Wi-Fi 7, no wired NIC; FiiO K7). Checked on the machine (2026-11-15): CPU
  numbering (`z890-topology-check` re-checks it every boot), IRQ table (all USB on the chipset
  xHCI `80:14.0`; GPU audio on a legacy IO-APIC line, so unpinnable), panel on `DP-1`, IOMMU
  passthrough, and the idle-state cap. C-states are capped on the E-cores only
  (`capCstatesCpus`), which keeps the P-cores' 2-core turbo bin. Imports `gpu/nvidia.nix`, which
  also names the NVIDIA kernel threads for `irq-affinity.nix` (there are no `cardN-crtcM`
  workers) and points `VK_DRIVER_FILES` at `nvidia_icd.json` (no arch suffix, unlike Mesa's).
  Lines still marked `VERIFY` (state version, sensor module, VA-API, Sober) are unchecked.
- **Kernel**: all hosts use `linuxPackages_cachyos-bore`. Plain `linuxPackages_cachyos` is now the
  clang-LTO build with BORE compiled out; check with `sysctl kernel.sched_bore`.

## Commands

```fish
sysdeploy "message"                        # git add, rebuild+switch, commit, push the current branch
sudo nixos-rebuild switch --no-write-lock-file --flake .#(hostname)
nh os build                                # build current host, show nvd package diff, no switch
nix flake check                            # evaluates ALL hosts; must stay warning-free
nix build --no-link .#nixosConfigurations.desktop.config.system.build.toplevel  # build, no ./result
nix flake update                           # bump flake.lock
alejandra <file>                           # format; avoid `alejandra .` (reflows untouched home.nix)
```

`sysdeploy` is a fish function in `home/cli.nix`. It commits and pushes the current branch on
success, so only use it when that is wanted. A failed unit after the switch (exit 4) is reported
as such and not committed.

## Architecture

```
flake.nix                    mkHost: ./modules + hosts/<name>/configuration.nix + ./home
modules/                     shared by every host (modules/default.nix imports them)
  cpu.nix                    local.hardware options -> kernel params, affinity, masks, C-states, governor
  irq-affinity.nix           local.irqAffinity pin table, kthread and CRTC-worker pinning
  core.nix                   boot, kernel, memory, udev, user, base packages
  nix.nix network.nix audio.nix session.nix
  gaming.nix minecraft.nix sober.nix webcam.nix diagnostics.nix
  lib.nix                    cpuListToMask
modules/gpu/{amd,nvidia}.nix opt-in: a host imports exactly one
modules/stationary.nix       opt-in: desktop + z890 (panel, FiiO K7, wired NIC, swap file)
modules/llm.nix              opt-in: omnibook
hosts/<name>/                configuration.nix (hardware facts only), hardware-configuration.nix,
                             optional home.nix (omnibook: kanshi)
home/                        the user profile: hyprland.nix, desktop.nix, apps.nix, osu.nix,
                             cli.nix, theme.nix (palette + font)
```

- **`flake.nix`** — inputs: `chaotic` (Chaotic-Nyx: cached `linuxPackages_cachyos-bore`, `mesa-git`;
  its module also configures the `nyx-cache.chaotic.cx` substituter), `nixpkgs` follows
  `chaotic/nixpkgs` so the kernel/Mesa always hit that cache, `grimoire`, `home-manager`,
  `nix-flatpak` (pinned tag, zero inputs). `mkHost` sets `networking.hostName` and imports
  `hosts/<name>/home.nix` only if it exists.
- **`modules/cpu.nix`** — the single source of truth for CPU numbers. A host sets
  `local.hardware.{gameCores,gameCoresNoSmt,backgroundCores,housekeepingCores,allCores}` and
  optionally `capCstates*`; the module derives `rcu_nocbs=`, `irqaffinity=`, systemd
  `CPUAffinity`/`AllowedCPUs`, the workqueue cpumasks (hex computed by `lib.nix`), the
  `cpu-idle-limit` and `cpufreq-performance` units. Never write a CPU list or mask anywhere else.
- **`modules/irq-affinity.nix`** — pins keyed by PCI address, `driver:<name>` (preferred — survives
  GPU swaps and bus renumbering) or `pci:<vendor>:<device>` (for two controllers on one driver,
  e.g. the desktop's xHCIs). `defaultCpus` (default `housekeepingCores`) sweeps unlisted IRQs,
  needed because the kernel always adds cpu0 to `irqaffinity=`. Also GPU worker kthreads
  (`gpuKthreadPattern` -> `crtcCpus`) and housekeeping kthread pinning, optional xHCI IRQ-thread FIFO priority, re-run on resume and on NetworkManager Wi-Fi
  `up` (ath12k resets its IRQ affinity hint to cpu0 on firmware start).
- **`modules/session.nix`** — greetd/tuigreet, console palette, portals, keyring, Thunar. Defines
  `local.hardware.monitors` (Hyprland monitor rules; set by `stationary.nix` or the host).
- **`modules/gaming.nix`** — `pkgs.proton-cachyos-slr` overlay from `proton-cachyos.json` (wrapped to
  `taskset -c gameCores`), Steam, OpenTabletDriver, Proton session vars, `/etc/dxvk.conf` (keys
  verified against the bundled DXVK; unknown keys are silently ignored), `zen5`/`zen5-nosmt`
  wrappers. Driver-specific variables live in `gpu/*.nix`.
- **`home/hyprland.nix`** — native Lua config. Game window rules are generated from one list.
  `hl.config` reports an unknown scalar key but silently skips an unknown key whose value is a
  list (that is how `exec_once` and `bindm` sat dead); check new keys with
  `hyprctl getoption <section>:<key>`. Programs start as systemd user units, not from the config.
- **`home/theme.nix`** — the One Dark palette and the font, consumed by waybar, fuzzel, kitty,
  tuigreet and the kernel console. Change a colour there, nowhere else.
- `diagnostics.nix` is opt-in frametime/PSI telemetry (amdgpu-specific);
  `home/cli.nix` carries `sysdeploy` and `update-proton-cachyos`.

## Conventions

- Prefer settings that fail loudly over silent no-ops; when a knob is verified dead (env var, dxvk
  key, sysfs path), remove it and leave a one-line note rather than keeping it "just in case".
- Verify hardware claims against the live machine (`lspci -nnk`, `/proc/interrupts`,
  `/sys/bus/pci/drivers/*`) before encoding PCI addresses or CPU numbers.
- A host file holds hardware facts only. Anything two hosts share goes in a module; anything
  derived from a CPU list is computed in `cpu.nix`.
- Files that are new to git must be `git add`ed before the flake can see them.
