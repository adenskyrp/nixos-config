# We define a function that takes 'pkgs' as an argument.
{ pkgs, ... }:

# We return the FHS environment directly. 
# No 'let ... in' needed here because we are just returning the derivation.
pkgs.buildFHSEnv {
  name = "pear-runtime";

  targetPkgs = pkgs: with pkgs; [
    udev           
    alsa-lib       
    gtk3           
    nss            
    dbus           
    glibc          
    gcc-unwrapped  
    bash
    curl
  ];

  runScript = "bash";
}
