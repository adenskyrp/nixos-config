# Mains-powered towers (desktop, z890): one fixed 600 Hz panel on DisplayPort,
# the FiiO K7 as audio output, an optional wired NIC, a swap file. Everything
# here trades idle power for latency, which is why the omnibook does not
# import it.
{pkgs, ...}: {
  local.hardware.monitors = [
    ''hl.monitor({ output = "DP-1", mode = "1920x1080@599.94", position = "0x0", scale = 1, bitdepth = 8, vrr = 0 })''
    # Catch-all: if a GPU swap renumbers connectors (DP-1 -> DP-2/3), come up
    # at the highest refresh rate instead of falling back to 60 Hz.
    ''hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })''
  ];

  boot.kernelParams = [
    "systemd.gpt_auto=0"
    # CachyOS defaults HDA codec power-save to 10 s: the codec powers down when
    # idle, so the first sound afterwards is late and pops.
    "snd_hda_intel.power_save=0"
    "snd_hda_intel.power_save_controller=N"
  ];

  # ---------------------------------------------------------------------------
  # AUDIO
  # ---------------------------------------------------------------------------
  # Keep ALSA outputs open. WirePlumber otherwise closes the device after 5 s
  # of silence, and reopening it on the next sound adds startup delay.
  services.pipewire.wireplumber.extraConfig."13-alsa-no-suspend" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "~alsa_output.*";}];
        actions.update-props."session.suspend-timeout-seconds" = 0;
      }
    ];
  };

  # FiiO K7 (UAC2, async, 125 us packets): small ALSA buffer. snd-usb-audio
  # sizes its URB queue from the buffer (nurbs = min(MAX_URBS, urbs/period x
  # periods/buffer)), so with PipeWire's default 32768-frame buffer it keeps
  # ~10 ms of audio on the wire regardless of period size. Measured ALSA delay
  # on the desktop (silence, pw-cat, median, 2026-11-11):
  #   256 x (32768 buf), headroom 256 (old generic rule)  22.5 ms
  #   128 x (32768 buf), headroom 0                       12.6 ms
  #   128 x 2 (256 buf)                                    9.0 ms
  #    64 x 3 (192 buf)                                    5.9 ms
  # The 192-frame buffer caps the graph quantum at 64 (1.33 ms cycles) while the
  # K7 drives it. 30 s under 12-thread busy load + fsync writes: 0 device xruns.
  # If anything crackles, step back to period-num = 2 with period-size = 128.
  # The K7 has no USB volume control (only a boolean unit), so PipeWire volume
  # is software: leave it at 100% (bit-exact) and use the K7's knob.
  services.pipewire.wireplumber.extraConfig."14-fiio-k7" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "~alsa_output.usb-GuangZhou_FiiO_Electronics_Co._Ltd_FiiO_K7.*";}];
        actions.update-props = {
          "api.alsa.period-size" = 128;
          "api.alsa.period-num" = 3;
          "api.alsa.headroom" = 0;
          # USB inputs default to 2109 vs 1109 for this sink, so in a call the
          # Yeti/C922 would drive the graph at their own (large) quantum and
          # this 192-frame buffer would underrun. The K7 must be the driver.
          "priority.driver" = 3000;
        };
      }
    ];
  };

  # ---------------------------------------------------------------------------
  # WIRED NETWORK
  # ---------------------------------------------------------------------------
  # Applies to whatever wired NIC exists; a no-op on a host with none enabled.
  systemd.services.optimize-nic = {
    description = "Disable EEE and GRO/LRO on wired NICs";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "optimize-nic" ''
        for dev in /sys/class/net/en*; do
          [ -e "$dev" ] || continue
          IFACE=$(basename "$dev")
          ${pkgs.ethtool}/bin/ethtool --set-eee "$IFACE" eee off 2>/dev/null || true
          ${pkgs.ethtool}/bin/ethtool -K "$IFACE" gro off lro off 2>/dev/null || true
        done
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # SWAP
  # ---------------------------------------------------------------------------
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024; # 8 GiB overflow on disk
      priority = 0; # Low priority: only used when zram fills
    }
  ];
}
