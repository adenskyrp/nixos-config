# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal NixOS flake configuration for adenskyrp's machines, tuned aggressively for low-latency
desktop/gaming use (Hyprland on Wayland, CachyOS BORE kernel, RDNA 3.5 Mesa-git, PipeWire realtime
audio, per-game Hyprland/DXVK rules). There is no application code, build system, or test suite —
this repo *is* the system and home-manager configuration, evaluated by `nix`.

## Commands

Rebuild and switch the running system (host is `omnibook`, the only host with a real config today):

```fish
sudo nixos-rebuild switch --flake .#omnibook
```

There is a fish shell function `sysdeploy` (defined in `hosts/omnibook/home.nix`, installed for the
`crazycat` user) that wraps the full loop: `cd ~/nixos-config`, `git add .`, rebuild, and on success
commit + `git push origin main` (on rebuild failure it aborts before committing). It takes an
optional commit message argument, e.g. `sysdeploy "tune pipewire quantum"`.

Other useful commands:

```fish
nix flake check                      # evaluate the flake / catch eval errors without switching
nix flake update                     # bump flake.lock (nixpkgs, chaotic, home-manager)
nixos-rebuild build --flake .#omnibook   # build without activating, e.g. to sanity-check a change
alejandra <file>.nix                 # format a .nix file (also runs automatically on save in the
                                      # configured Neovim via nixd, see hosts/omnibook/home.nix)
```

There are no unit/integration tests. "Testing" a change means `nix flake check` / `nixos-rebuild
build` succeeding, and ultimately `nixos-rebuild switch` + reboot/relogin to confirm behavior.

## Architecture

- **`flake.nix`** — entry point. Inputs: `nixpkgs` (nixos-unstable), `chaotic` (Chaotic-Nyx overlay,
  provides `linuxPackages_cachyos` and `mesa-git`), `home-manager` (following nixpkgs). Defines
  `nixosConfigurations.omnibook` and `nixosConfigurations.desktop`. **Note:** `desktop` points at
  `./hosts/desktop/configuration.nix`, which does not exist in this tree yet — it's a stub for a
  second machine, not a bug to "fix" by removing.
- **`hosts/<host>/configuration.nix`** — per-host root. Imports that host's
  `hardware-configuration.nix` (machine-generated, never hand-edit) plus the shared modules under
  `modules/`, then layers host-specific stuff: hostname, bootloader/kernel params, power/thermal
  tuning (e.g. `ryzenadj` SMU limits via a oneshot systemd service), GPU driver flags, greetd/login,
  bluetooth, `system.stateVersion`.
- **`hosts/<host>/home.nix`** — that host's home-manager profile for user `crazycat`, wired in from
  `flake.nix` via `home-manager.users.crazycat`. Owns anything user-session-scoped: Hyprland config
  (written in Lua via `configType = "lua"`, not the usual keybinds.conf/hyprland.conf string style —
  check this file before assuming Hyprland options live elsewhere), fish functions, fuzzel/ironbar,
  Neovim (LSP via `nixd`, format-on-save via `alejandra`), Firefox policies/prefs, kanshi output
  profiles, per-app packages, XDG mime associations. `home.stateVersion` lives here, independent of
  the system's `stateVersion`.
- **`modules/*.nix`** — shared NixOS modules imported by host configs, not home-manager modules:
  - `core.nix` — base system: sched-ext (`scx_lavd`) scheduler, nix settings/GC/optimise, DNS
    (DoT via systemd-resolved, Quad9/Cloudflare), network queueing (`cake` + `bbr`), udev rules
    (NVMe scheduler, Thunderbolt auto-auth, HID access), PipeWire/WirePlumber low-latency tuning
    (64-sample quantum, realtime priorities), PAM rtprio/memlock/nice limits, user account
    definition, base system packages.
  - `gaming.nix` — Steam + Proton-GE, VM/sysctl tuning for Esync/Fsync, global env vars
    (`RADV_PERFTEST`, `WINE_FSYNC`, etc.), and a declarative `/etc/dxvk.conf` applied to all
    DX9/DX11 titles.
  - `minecraft.nix` — Prism Launcher wrapped with multiple JDKs + `gamemode`/`taskset`, patched
    GLFW for Wayland.
  - New host-independent system behavior should generally become a new file here and get imported
    from the relevant `hosts/*/configuration.nix`, following the existing style (a commented
    section-header banner per logical group, values pulled into named `let` bindings when they
    carry hardware-specific meaning like the SMU wattage constants in `configuration.nix`).

## Conventions specific to this repo

- Every `.nix` file uses banner-style comments (`# --- SECTION ---`) to delineate logical groups,
  and inline comments explain *why* a low-level tunable is set (thermal envelope, latency rationale,
  hardware quirk), not just what it does. Match this density in new code — it's what makes the
  aggressive kernel/sysctl/PipeWire tuning maintainable.
- Formatting is `alejandra` (invoked on save from Neovim, and available as a plain CLI command).
- Per-game/app tuning (Hyprland window rules, launcher wrapper scripts) lives in `home.nix` next to
  the thing it configures rather than in a separate directory per app.
