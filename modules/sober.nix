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
{...}: {
  # Needs two things this file does not declare: xdg.portal (session.nix; the
  # flatpak module asserts it) and a Vulkan driver (the host's GPU module).
  # On NVIDIA, Flatpak also needs the org.freedesktop.Platform.GL.nvidia-<version>
  # runtime extension matching the driver exactly: it is pulled in when Sober is
  # installed, but a driver bump needs `flatpak update` before Sober starts again.

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

          # dri = render node + device access, what the Vulkan driver needs to
          # see the GPU from inside the sandbox.
          devices = ["dri"];
        };
      };
    };
  };
}
