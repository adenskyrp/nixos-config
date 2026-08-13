{ pkgs, ... }:

let
  # ---------------------------------------------------------
  # 1. THE FHS SANDBOX (Your existing runtime)
  # ---------------------------------------------------------
  pear-runtime = pkgs.buildFHSEnv {
    name = "pear-runtime";
    targetPkgs = pkgs: with pkgs; [
      udev alsa-lib gtk3 nss dbus glibc gcc-unwrapped bash curl
    ];
    # Right now, this drops to a bash shell. 
    runScript = "bash";
  };

  # ---------------------------------------------------------
  # 2. THE DESKTOP ENTRY (GUI Integration)
  # ---------------------------------------------------------
  pear-desktop = pkgs.makeDesktopItem {
    name = "pear-desktop";
    desktopName = "Pear Environment";
    comment = "FHS Sandbox for Pear P2P";
    # We point the exec command directly to the binary created by our sandbox.
    exec = "${pear-runtime}/bin/pear-runtime";
    # Because our runScript is "bash", we MUST tell the drun to open this 
    # inside a terminal window, otherwise it executes invisibly in the background.
    terminal = true;
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
