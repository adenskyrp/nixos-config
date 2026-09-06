# modules/sober.nix
#
# Declarative Sober (Roblox runtime) deployment via Flatpak.
#
# WHY A SEPARATE MODULE:
# Sober is closed-source and Flathub-only by upstream design -- the vinegarhq
# maintainers closed the source specifically to reduce the abuse vectors that
# got earlier Roblox-on-Linux projects banned. There is no source tree for us to
# build or audit here. Isolating this in its own file keeps a hard line between
# "things Nix builds from source" and "things Nix merely orchestrates the state
# of." Everything below declares *state*, not a derivation: which remote is
# trusted, which ref is installed, what sandbox permissions it holds. The bits
# themselves come down through Flatpak's own OSTree backend.
#
# NOT COVERED BY `nixos-rebuild --rollback`: rolling back a generation retracts
# these declarations but does NOT roll the installed Flatpak commit back. That
# is separate state, moved with
#   flatpak update --commit=<hash> org.vinegarhq.Sober
{
  config,
  lib,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------------------------
  # GPU: AMD / MESA RADV
  # ---------------------------------------------------------------------------
  # Sober's Android compat layer renders via Vulkan by default. RADV (Mesa's
  # open Vulkan driver) ships in nixpkgs out of the box for AMD -- no
  # proprietary blob, no kernel module juggling like NVIDIA would need.
  #
  # Redundant with hosts/omnibook/configuration.nix and modules/minecraft.nix,
  # which already assert the same two booleans. That is deliberate and safe:
  # types.bool merges via mergeEqualOption, so identical definitions collapse
  # rather than conflict, and the module stays self-describing about what it
  # needs instead of depending on a sibling module having been imported.
  hardware.graphics = {
    enable = true;

    # Not required by Sober itself (it is 64-bit only), but Flathub's
    # freedesktop runtime assumes 32-bit ICDs are resolvable on the host for
    # the general case. Cheap insurance for the next flatpak app that does
    # need it.
    enable32Bit = true;
  };

  # ---------------------------------------------------------------------------
  # XDG PORTALS: THE PIECE HYPRLAND DOES NOT GIVE YOU FOR FREE
  # ---------------------------------------------------------------------------
  # Flatpak sandboxes talk to the outside world *only* through
  # xdg-desktop-portal (a D-Bus broker for screen capture, file dialogs,
  # notifications). GNOME/KDE bundle a portal implementation; wlroots-based
  # compositors like Hyprland deliberately do not. Skip this block and Sober's
  # screen-share ("captures") feature and notifications silently hang.
  #
  # This is also load-bearing for the flatpak module itself: nixpkgs'
  # services.flatpak carries an assertion that xdg.portal.enable is true, so
  # without this the evaluation fails outright rather than degrading.
  #
  # Nothing else in this tree enables portals. Hyprland here is configured
  # purely from home-manager (wayland.windowManager.hyprland in
  # hosts/omnibook/home.nix); programs.hyprland is NOT set at the system level,
  # so the portal wiring that option would have pulled in never happened.
  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-hyprland # native: screencopy / screenshot
      pkgs.xdg-desktop-portal-gtk # fallback: file chooser, notifications
    ];
    # Try the hyprland backend for every interface, fall back to gtk for the
    # ones it does not implement (FileChooser, Notification).
    config.common.default = ["hyprland" "gtk"];
  };

  # ---------------------------------------------------------------------------
  # FLATPAK STATE, DECLARED
  # ---------------------------------------------------------------------------
  services.flatpak = {
    enable = true;

    remotes = [
      {
        name = "flathub";
        location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      }
    ];

    packages = [
      # NOT `"flathub:app/org.vinegarhq.Sober//stable"`. nix-flatpak renders a
      # package as `flatpak install <origin> <appId>` (modules/flatpak/install.nix,
      # installCmdBuilder), so a remote-qualified appId puts the remote in the
      # command twice, and flatpak's own ref parser rejects the colon outright:
      #     $ flatpak info 'flathub:app/org.vinegarhq.Sober//stable'
      #     error: Invalid id flathub:app: Name can't contain :
      # That would fail flatpak-managed-install.service on activation, not at
      # eval, so it would have surfaced as a broken switch rather than a build
      # error. Verified against flatpak 1.18.1 on 2026-09-06.
      #
      # The branch is left implicit rather than pinned as `app/…//stable`:
      # Flathub's xa.default-branch is `stable`, so it resolves identically,
      # and a bare appId is what nix-flatpak's uninstall path expects -- it
      # matches recorded state against `flatpak list --columns=application`,
      # which prints bare ids. A ref-qualified appId would never match, so
      # removing this module later would log a warning and leave Sober
      # installed instead of cleaning it up.
      {
        appId = "org.vinegarhq.Sober";
        origin = "flathub";
      }
    ];

    # Per-app sandbox permissions, declared instead of clicked through Flatseal.
    # This is the part that is actually hardware-conditional.
    overrides = {
      "org.vinegarhq.Sober" = {
        Context = {
          # Pure-Wayland: no XWayland fallback socket.
          # THIS IS A HYPOTHESIS, NOT A GUARANTEE. Some sandboxed apps lean on
          # XWayland for input-grab quirks (cursor lock, certain key-repeat
          # handling). If Sober's mouse/keyboard capture misbehaves under
          # Hyprland, this line is the first thing to revert before touching
          # anything else.
          sockets = ["wayland" "!x11" "!fallback-x11" "pulseaudio"];

          # dri = render node + device access, what RADV needs to see the GPU
          # from inside the sandbox.
          devices = ["dri"];
        };
      };
    };
  };
}
