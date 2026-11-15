# Helpers shared by the modules.
{lib}: {
  # CPU list -> lowercase hex bitmask, the form sysfs cpumask files take:
  # "0,6" -> "41", "14-17" -> "3c000", "20-23" -> "f00000".
  cpuListToMask = list: let
    cpusOf = part: let
      bounds = map lib.toInt (lib.splitString "-" part);
    in
      lib.range (lib.head bounds) (lib.last bounds);
    bit = cpu: builtins.foldl' (acc: _: acc * 2) 1 (lib.range 1 cpu);
    cpus = lib.unique (lib.concatMap cpusOf (lib.splitString "," list));
  in
    lib.toLower (lib.toHexString (builtins.foldl' (acc: cpu: acc + bit cpu) 0 cpus));
}
