# PipeWire, tuned for a 48 kHz low-latency graph. Device-specific rules (the
# FiiO K7) live in stationary.nix.
{...}: {
  # ---------------------------------------------------------------------------
  # LOW-LATENCY AUDIO SUBSYSTEM (PipeWire: 256 realized = 5.33 ms @ 48 kHz)
  # ---------------------------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;

    extraConfig.pipewire = {
      "10-clock-quantum" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          # 48 kHz only: every alsa_output is pinned to audio.rate = 48000 below,
          # so allowing 44.1 kHz just let osu! drag the graph to 44100 while the
          # device stayed at 48000 (pw-top: driver 256/44100 vs S32LE 48000, xruns).
          # 44.1 kHz streams are now resampled once, in their own adapter.
          "default.clock.allowed-rates" = [48000];
          "default.clock.quantum" = 512;
          "default.clock.min-quantum" = 128;
          "default.clock.max-quantum" = 4096;
        };
      };
      "99-realtime" = {
        "context.modules" = [
          {
            name = "libpipewire-module-rt";
            args = {
              "nice.level" = -15;
              "rt.prio" = 88;
              "rt.time.soft" = -1;
              "rt.time.hard" = -1;
            };
            flags = ["ifexists" "nofail"];
          }
        ];
      };
    };

    extraConfig.pipewire-pulse = {
      "10-pulse-latency" = {
        "pulse.properties" = {
          "server.address" = ["unix:native"];
        };
        "stream.properties" = {
          "node.latency" = "256/48000";
        };
      };
    };

    wireplumber.extraConfig = {
      "11-alsa-gpu-tuning" = {
        "monitor.alsa.rules" = [
          {
            matches = [{"node.name" = "~alsa_output.*";}];
            actions = {
              update-props = {
                "node.pause-on-idle" = false;
                "audio.format" = "S32LE";
                "audio.rate" = 48000;
                "api.alsa.period-size" = 256;
                "api.alsa.headroom" = 256;
                "api.alsa.disable-batch" = true;
              };
            };
          }
          {
            # HD-Audio is not a batch device and reports an exact hw pointer, so
            # it needs no headroom; the 256 frames above added a flat 5.33 ms to
            # every sound on HDA outputs (desktop ALC897, GPU HDMI/DP).
            matches = [
              {
                "node.name" = "~alsa_output.*";
                "alsa.driver_name" = "snd_hda_intel";
              }
            ];
            actions = {
              update-props = {
                "api.alsa.headroom" = 0;
              };
            };
          }
        ];
      };

      "12-blue-yeti-gain-lock" = {
        "monitor.alsa.rules" = [
          {
            matches = [{"node.name" = "~alsa_input.*Blue_Microphones.*";}];
            actions = {
              update-props = {
                "node.pause-on-idle" = false;
                "api.alsa.soft-mixer" = false;
              };
            };
          }
        ];
      };

      "10-bluetooth-policy" = {
        "wireplumber.settings" = {
          "bluetooth.autoswitch-to-headset-profile" = false;
        };
        "monitor.bluez.properties" = {
          "bluez5.enable-sbc-xq" = true;
          "bluez5.enable-msbc" = true;
          "bluez5.enable-hw-volume" = true;
          "bluez5.codecs" = ["sbc_xq" "sbc"];
          "bluez5.roles" = ["a2dp_sink" "a2dp_source"];
        };
      };
    };
  };
}
