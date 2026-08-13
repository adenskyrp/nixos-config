{ pkgs, ... }:

let
  # ---------------------------------------------------------
  # 1. THE FHS SANDBOX (Wayland / GLFW Graphics Stack)
  # ---------------------------------------------------------
  pear-runtime = pkgs.buildFHSEnv {
    name = "pear-runtime";
    
    targetPkgs = pkgs: with pkgs; [
      # Base System & Networking
      udev alsa-lib gtk3 nss dbus glibc gcc-unwrapped bash curl
      
      # --- THE WAYLAND/GLFW PIPELINE FIX ---
      # Pear's UI requires hardware acceleration and Wayland protocols
      # to render natively on your AMD APU without falling back to XWayland.
      libGL
      libglvnd
      vulkan-loader
      wayland
      libxkbcommon # Required for keyboard input in Wayland windows
      
      # DBus and Portals (Fixes the org.freedesktop error)
      xdg-desktop-portal
      xdg-desktop-portal-gtk
    ];

    # We ensure the sandbox inherits the host's DBus session and Wayland display.
    # This bridges the gap between the isolated FHS environment and Hyprland.
    profile = ''
      export WAYLAND_DISPLAY=$WAYLAND_DISPLAY
      export DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS
    '';

    # We keep this as bash so you can launch Pear manually with arguments.
    runScript = "bash";
  };

  # ---------------------------------------------------------
  # 2. THE DESKTOP ENTRY (Explicit TTY Routing)
  # ---------------------------------------------------------
  pear-desktop = pkgs.makeDesktopItem {
    name = "pear-desktop";
    desktopName = "Pear Environment";
    comment = "FHS Sandbox for Pear P2P";
    
    # THE FIX: We use escaped double quotes (\") instead of single quotes.
    # This satisfies the strict FreeDesktop XDG parser while still passing 
    # the correct argument to the sandbox.
    exec = "${pkgs.kitty}/bin/kitty --hold -- ${pear-runtime}/bin/pear-runtime -c \"bash -i\"";
    
    terminal = false; 
    categories = [ "Network" "Utility" ];
  };
in
# ---------------------------------------------------------
# 3. THE ARCHITECTURAL FUSION
# ---------------------------------------------------------
# Your system configuration expects a single package from this file.
# symlinkJoin merges the /bin/ directory of the sandbox and the 
# /share/applications/ directory of the desktop item into one clean Nix package.
pkgs.symlinkJoin {
  name = "pear-integrated";
  paths = [ pear-runtime pear-desktop ];
}
