Look at those receipts:

- **`nix flake check`:** Zero errors, zero evaluation warnings (across **both** `omnibook` and `desktop`).
- **Build Speed:** `nixos-rebuild build --flake .#omnibook` completed straight from the Chaotic-Nyx binary cache—zero local kernel compilation.
- **Closure Size:** Dropped from **30.0 GiB → 27.5 GiB** (**-2.5 GiB** off the active closure immediately, plus **-24.6 GiB** unlocked by removing the stale September `./result` symlink).
- **Codebase Footprint:** `898 insertions(+), 1217 deletions(-)`—net reduction of over 300 lines while adding an entire second host (`hosts/desktop/`).

*(Curious what makes up the remaining 27.5 GiB? Run `nix path-info -rSh /nix/store/fiynny8mcfjl892zal0nwpk70bks5m9l-nixos-system-omnibook-26.11.20261015.fe13242 | sort -h | tail -n 20` anytime—most of it will be `blender`, `bitwig-studio`, `google-cloud-sdk`, `wineWow64Packages.staging`, `proton-cachyos`, and the two JDK 21 distributions in `minecraft.nix`.)*

---

### Final Polish Before Switching: Update `CLAUDE.md`
To keep your repository's documentation 100% truthful to the new architecture, update `CLAUDE.md` so any future session (human or AI) knows:
1. `hosts/desktop/` is now a real, evaluated host configuration (Ryzen 5 5600X + RX 6650 XT + ASRock B550M-HDV + Intel BE200).
2. `local.hardware` (`gameCores`, `gameCoresNoSmt`, `backgroundCores`) in `modules/core.nix` is the single source of truth for per-host CPU topology, consumed by `modules/gaming.nix`, `hosts/*/configuration.nix`, and `hosts/*/home.nix`.
3. `pkgs.proton-cachyos-slr` is exposed via an overlay in `modules/gaming.nix` from `modules/proton-cachyos.json`.

Here is the updated `CLAUDE.md` you can drop in:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal NixOS flake configuration for adenskyrp's machines, tuned aggressively for low-latency
desktop/gaming use (Hyprland on Wayland, CachyOS BORE kernel, Mesa-git RADV, PipeWire realtime
audio, per-game Hyprland/DXVK rules). There is no application code, build system, or test suite —
this repo *is* the system and home-manager configuration, evaluated by `nix`.

## Hosts

- **`omnibook`** — HP OmniBook Ultra 14 laptop (AMD Ryzen AI 9 365: 4x Zen 5 `0-7` + 6x Zen 5c
  `8-19`, Radeon 880M `gfx1150` RDNA 3.5 iGPU with 24 GiB GTT ceiling, 32 GB LPDDR5X, MediaTek
  MT7925 Wi-Fi 7).
- **`desktop`** — Custom AM4 desktop rig (AMD Ryzen 5 5600X: 6x Zen 3 `0-11` in a unified 32 MB L3
  CCX, Radeon RX 6650 XT `gfx1032` RDNA 2 8 GB dGPU, ASRock B550M-HDV, 16 GB Samsung B-Die DDR4,
  Intel BE200NGW Wi-Fi 7). Note: `hosts/desktop/hardware-configuration.nix` uses label-based disk
  stubs (`/dev/disk/by-label/nixos` and `/dev/disk/by-label/BOOT`) until physical OS installation.

## Commands

Rebuild and switch the running system (auto-detects current hostname via `sysdeploy`, or run
manually):

```fish
sudo nixos-rebuild switch --no-write-lock-file --flake .#(hostname)
```

There is a fish shell function `sysdeploy` (defined in `hosts/omnibook/home.nix`, shared by both
hosts) that wraps the full loop: `cd ~/nixos-config`, `git add .`, updates/verifies `flake.lock` as
the normal user (so `sudo` never writes root-owned objects into `.git/objects`), rebuilds with
`--no-write-lock-file`, and on success commits + `git push origin main`. It takes an optional commit
message argument, e.g. `sysdeploy "tune pipewire quantum"`.

Other useful commands:

```fish
nix flake check                            # evaluate both omnibook and desktop / catch eval errors
nix flake update                           # bump flake.lock (nixpkgs, chaotic, grimoire, home-manager)
nixos-rebuild build --flake .#omnibook --no-link # build without leaving a ./result GC root
alejandra .                                # format all .nix files (also runs on save in Neovim)
```

## Architecture

- **`flake.nix`** — entry point. Inputs: `nixpkgs` (nixos-unstable), `chaotic` (Chaotic-Nyx overlay,
  provides cached `linuxPackages_cachyos` and `mesa-git`), `grimoire` (following `nixpkgs`),
  `home-manager` (following `nixpkgs`), and `nix-flatpak` (pinned release tag, zero inputs). Uses a
  unified `mkHost` builder to construct `nixosConfigurations.omnibook` and
  `nixosConfigurations.desktop`.
- **`hosts/<host>/configuration.nix`** — per-host root. Imports that host's
  `hardware-configuration.nix` plus shared modules under `modules/`, defines `local.hardware`
  (`gameCores`, `gameCoresNoSmt`, `backgroundCores`) for the machine's CPU topology, and layers
  host-specific kernel parameters, Wi-Fi module options, power/thermal tuning (`ryzenadj` oneshot on
  boot/resume for `omnibook`), `cpupower idle-set -D 350`, and `greetd`.
- **`hosts/<host>/home.nix`** — Home Manager profile for `crazycat`. `hosts/omnibook/home.nix` holds
  the primary user-session configuration (Hyprland native Lua config via `configType = "lua"`,
  `osuStableLauncher`, `ironbar`, `fuzzel`, Neovim with `nixd`/`alejandra`, Firefox policies, and
  `xdg.desktopEntries` parameterized via `osConfig.local.hardware`). `hosts/desktop/home.nix`
  imports `../omnibook/home.nix` and disables laptop-specific `kanshi` `eDP-1` dock profiles.
- **`modules/*.nix`** — shared NixOS modules imported by host configs:
  - `core.nix` — defines `options.local.hardware` (`gameCores`, `gameCoresNoSmt`,
    `backgroundCores`), Nix settings/GC/optimise (`persistent = false` to avoid boot I/O storms),
    `fq` + `bbr` network sysctls, udev rules (NVMe scheduler, USB power, priority-60 `hidraw`
    `uaccess`), PipeWire/WirePlumber low-latency config (256/48000 = 5.33 ms), PAM realtime limits,
    and base system packages.
  - `gaming.nix` — exposes `pkgs.proton-cachyos-slr` (from `modules/proton-cachyos.json`) via an
    overlay shared by Steam `extraCompatPackages` and `osuStableLauncher`, configures OpenTabletDriver,
    sets low-latency Proton/Mesa session variables, writes `/etc/dxvk.conf`, and builds the `zen5` /
    `zen5-nosmt` launch wrappers bound to `config.local.hardware.gameCores`.
  - `minecraft.nix` — Prism Launcher with Temurin 21, Zulu 21, and `util-linux` (`taskset`), plus
    Wayland-patched GLFW.
  - `sober.nix` — declarative Flatpak setup for Sober (`org.vinegarhq.Sober`) and `xdg-desktop-portal`
    (`hyprland` + `gtk`).
  - `webcam.nix` — Pixel-as-webcam pipeline via `v4l2loopback` (`/dev/video10`, `exclusive_caps=1`)
    and `scrcpy`/`adb`.
  - `diagnostics.nix` — opt-in (`local.diagnostics.enable`) frametime/PSI telemetry (`stutter-trace`,
    `psi-calibrate`, `psi-watch`, `perf`).
  - `llm.nix` (`omnibook` only) — local Vulkan/RADV `llama-cpp` server using `/var/lib/llama/models`.
  - `irq-affinity.nix` (`omnibook` only) — pins `omnibook` PCI peripheral IRQs to Zen 5c cores (`8-19`).
```
