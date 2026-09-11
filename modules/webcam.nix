# modules/webcam.nix
#
# PHONE-AS-WEBCAM: a Pixel's camera presented to the host as an ordinary V4L2
# capture device.
#
# THE PIPELINE:
#   Pixel camera --(adb, USB or TCP/IP)--> scrcpy --> /dev/video10
#                                                     (v4l2loopback sink)
#
# The point of terminating in a loopback node rather than a per-app plugin is
# that nothing downstream has to know any of this happened: Chromium/Electron
# apps, Firefox and OBS all enumerate "VirtualCam" next to the real UVC camera
# and need no configuration of their own. The phone's sensor is several classes
# better than the 1080p module in the lid, which is the whole motivation.
#
# WHY A SEPARATE MODULE: this is host-independent behaviour -- it names no PCI
# address, no wattage and no panel -- so per the convention in CLAUDE.md it
# lives here and is imported from hosts/*/configuration.nix. Deleting that one
# import line is the full revert; nothing below leaves state behind in the
# running kernel the way a /proc write would.
{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # V4L2 LOOPBACK KERNEL MODULE
  # ---------------------------------------------------------------------------
  # config.boot.kernelPackages, NOT pkgs.linuxPackages. v4l2loopback is an
  # out-of-tree module, so it is compiled against a specific kernel's headers
  # and refuses to load into any other one (vermagic mismatch -- modprobe fails
  # with "Invalid module format" and dmesg names the version it wanted).
  # pkgs.linuxPackages is nixpkgs' default kernel, which is NOT what this host
  # runs: hosts/omnibook/configuration.nix sets boot.kernelPackages to
  # pkgs.linuxPackages_cachyos. Referring to the option instead of a concrete
  # package set means this file follows whatever kernel the host picked, and
  # keeps following it across a CachyOS bump.
  #
  # REDUNDANT ON THIS HOST TODAY, KEPT DELIBERATELY. The CachyOS kernel already
  # carries v4l2loopback in-tree -- its own module tree ships
  #     lib/modules/7.2.3-cachyos/kernel/drivers/media/v4l2-core/v4l2loopback.ko.zst
  # and both builds are the same upstream release (verified with modinfo:
  # version 0.15.4, vermagic "7.2.3-cachyos SMP preempt mod_unload", identical
  # on both). This line adds a second copy under updates/, which depmod ranks
  # ahead of kernel/, so the standalone build is the one that actually loads.
  #
  # Kept anyway, for two reasons: it pins the module to a derivation nixpkgs
  # tracks rather than to a patch CachyOS may drop without notice, and it keeps
  # this file correct on a host running a stock kernel (the desktop stub), where
  # nothing would provide the module otherwise. The cost is one extra
  # out-of-tree compile per kernel bump. If that ever stops being worth it, drop
  # this line and the in-tree module takes over with no other change -- confirm
  # with `modinfo v4l2loopback | head -2` after, which prints the loaded file's
  # path.
  boot.extraModulePackages = [config.boot.kernelPackages.v4l2loopback];

  # Load at boot rather than leaving it to on-demand autoloading. There is no
  # hardware event that would ever trigger a loopback module -- the device it
  # creates is the reason to load it, not a consequence of something appearing
  # on a bus -- so without this line /dev/video10 simply does not exist and the
  # first scrcpy run dies on a missing sink.
  boot.kernelModules = ["v4l2loopback"];

  # --- MODULE PARAMETERS ---
  # devices=1     One node. Each additional one is another entry every app's
  #               camera picker has to be told to ignore.
  # video_nr=10   Pins the node at /dev/video10 so the scrcpy invocation is a
  #               constant. The real UVC camera and its metadata node take the
  #               low numbers (video0, video1) and renumber on re-enumeration;
  #               10 sits clear of anything the hardware will claim.
  # card_label    The string every app shows in its device list.
  # exclusive_caps=1
  #               LOAD-BEARING, not cosmetic. By default a v4l2loopback node
  #               advertises CAPTURE and OUTPUT capabilities simultaneously.
  #               Chromium's device enumeration treats a node claiming OUTPUT as
  #               not-a-camera and filters it out, so on every Electron app
  #               (Discord, Slack, Teams) the camera silently fails to appear
  #               with no error anywhere -- the single most common way this
  #               setup "doesn't work". exclusive_caps makes the node advertise
  #               only CAPTURE once a producer has it open.
  #
  # types.lines, so this concatenates with the cfg80211 stanza in
  # modules/core.nix and the mt7925 stanza in hosts/omnibook/configuration.nix
  # rather than clashing with either.
  boot.extraModprobeConfig = ''
    options v4l2loopback devices=1 video_nr=10 card_label="VirtualCam" exclusive_caps=1
  '';

  # ---------------------------------------------------------------------------
  # USERSPACE PIPELINE
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # The producer. --v4l2-sink writes decoded frames into the loopback node;
    # --video-source=camera asks the phone for its camera stream instead of its
    # screen, which is the part that makes this a webcam rather than a mirror.
    scrcpy

    # adb/fastboot -- the transport scrcpy speaks over. This is now the ONLY
    # thing that puts adb on PATH: programs.adb.enable no longer exists (see
    # the ADB DEVICE ACCESS section below), and its removal note points here.
    android-tools

    # scrcpy links its own libav; this is the CLI, for re-encoding or probing a
    # stream by hand when the loopback path is misbehaving.
    ffmpeg

    # How you diagnose this whole module. `v4l2-ctl --list-devices` is the
    # authority on whether the node exists and what it advertises:
    #   v4l2-ctl --list-devices          # expect "VirtualCam (platform:v4l2loopback-000)"
    #   v4l2-ctl -d /dev/video10 --all   # confirm Video Capture caps, no Video Output
    v4l-utils
  ];

  # ---------------------------------------------------------------------------
  # ADB DEVICE ACCESS -- NEITHER programs.adb NOR THE adbusers GROUP EXISTS ANY MORE
  # ---------------------------------------------------------------------------
  # This section is deliberately empty of declarations, and that is the whole
  # point of it being written down. The conventional recipe for this feature is
  #
  #     programs.adb.enable = true;
  #     users.users.<name>.extraGroups = [ "adbusers" ];
  #
  # and on this nixpkgs BOTH halves are gone. Not deprecated -- removed, and the
  # first one fails evaluation outright rather than warning:
  #
  #     The option definition `programs.adb' ... no longer has any effect;
  #     please remove it. This option is no longer needed as systemd 258
  #     handles uaccess rules automatically. Please add `pkgs.android-tools`
  #     to your system packages to get the adb command.
  #
  # android-udev-rules is removed too ("superseded by built-in systemd uaccess
  # rules"), and with it the `adbusers` group, which nothing in nixpkgs now
  # defines. Adding a user to it would still evaluate -- there is no assertion
  # against unknown groups in extraGroups -- which is exactly the trap: it would
  # look like the access grant was configured while granting nothing at all.
  #
  # WHAT GRANTS ACCESS INSTEAD (systemd 261 here, lib/udev/rules.d/70-uaccess.rules):
  #
  #     SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:dc0201:*|*:ff4201:*|*:ff4203:*", \
  #         ENV{ID_DEBUG_APPLIANCE}="android"
  #     ...
  #     ENV{ID_DEBUG_APPLIANCE}=="?*", TAG+="uaccess"
  #
  # ff4201 is ADB's vendor-specific interface class, ff4203 fastboot, dc0201 ADB
  # over USB debug capability. The phone is matched by interface class, so no
  # per-vendor id list has to be maintained the way android-udev-rules did.
  #
  # This is strictly better than the group grant it replaces, for the same
  # reason spelled out at length in modules/core.nix's hidraw section: uaccess
  # hands an ACL to whoever holds the ACTIVE SEAT and revokes it on logout,
  # whereas group membership is a permanent, seat-independent grant over a
  # debug transport that can read and write the phone's storage. There is
  # nothing to add here -- the rule ships in systemd, which is already running.
  #
  # VERIFY (the phone must be unlocked with USB debugging on, and the
  # "Allow USB debugging?" prompt accepted -- otherwise adb reports the device
  # as `unauthorized`, which is a phone-side state no host config can fix):
  #
  #   adb devices              # expect "<serial>  device"
  #   getfacl /dev/bus/usb/<bus>/<dev>   # expect user:crazycat:rw-
}
