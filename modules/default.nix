# Everything every host shares. flake.nix imports this directory for each
# host; a host file then adds what is specific to it: a GPU module
# (gpu/amd.nix or gpu/nvidia.nix), stationary.nix, llm.nix.
{
  imports = [
    ./core.nix
    ./cpu.nix
    ./irq-affinity.nix
    ./nix.nix
    ./network.nix
    ./audio.nix
    ./session.nix
    ./gaming.nix
    ./minecraft.nix
    ./sober.nix
    ./webcam.nix
    ./diagnostics.nix
  ];
}
