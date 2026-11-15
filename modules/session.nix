# The graphical session around Hyprland: greeter, console palette, portals,
# keyring, file manager. Hyprland itself is configured in home/hyprland.nix;
# programs.hyprland is deliberately not set at the system level.
{
  pkgs,
  lib,
  ...
}: let
  theme = import ../home/theme.nix;
in {
  options.local.hardware.monitors = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    example = [''hl.monitor({ output = "DP-1", mode = "highrr", position = "0x0", scale = 1 })''];
    description = "Hyprland monitor rules, one Lua statement each, injected into hyprland.lua.";
  };

  config = {
    # ---------------------------------------------------------------------------
    # GREETER (greetd + tuigreet)
    # ---------------------------------------------------------------------------
    # The session inherits backgroundCores from the service manager (cpu.nix),
    # so start-hyprland needs no taskset of its own.
    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --theme 'border=darkgray;text=gray;prompt=blue;time=blue;action=darkgray;button=blue;container=black;input=white' --cmd start-hyprland";
        user = "crazycat";
      };
    };
    systemd.services.greetd = {
      wants = lib.mkForce [];
      after = lib.mkForce ["systemd-user-sessions.service"];
    };

    # The 16 console colours tuigreet's theme names resolve to. Same palette as
    # the desktop, so boot, greeter and session do not change colour scheme.
    console.colors = theme.ansi;

    # ---------------------------------------------------------------------------
    # KEYRING & DESKTOP SERVICES
    # ---------------------------------------------------------------------------
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.login.enableGnomeKeyring = true;
    security.pam.services.greetd.enableGnomeKeyring = true;

    programs.dconf.enable = true;

    # Backlight and LED access for the swayosd on-screen display.
    services.udev.packages = [pkgs.swayosd];

    programs.thunar = {
      enable = true;
      plugins = [pkgs.thunar-archive-plugin];
    };
    programs.xfconf.enable = true;
    services.tumbler.enable = true;
    services.gvfs.enable = true;

    # ---------------------------------------------------------------------------
    # XDG PORTALS: THE PIECE HYPRLAND DOES NOT GIVE YOU FOR FREE
    # ---------------------------------------------------------------------------
    # Sandboxed apps reach screen capture, file dialogs and notifications only
    # through xdg-desktop-portal. GNOME and KDE bundle an implementation;
    # Hyprland does not, and because Hyprland is configured purely from
    # home-manager here, nothing else pulls one in. services.flatpak
    # (sober.nix) also asserts xdg.portal.enable, so without this block
    # evaluation fails outright.
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
    environment.pathsToLink = ["/share/xdg-desktop-portal" "/share/applications"];
  };
}
