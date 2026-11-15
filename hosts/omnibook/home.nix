# Laptop-only user configuration: output profiles for docked and undocked use.
{...}: {
  # kanshi is the authority for mode setting here: it matches the panel by its
  # EDID string, which survives connector renumbering across MST
  # re-enumeration in a way DP-N does not. It starts with the session
  # (systemdTarget). Never restart it from a Hyprland `exec` hook: that fires on
  # every config reload, re-applies the profile, and a modeset at 599.94 Hz
  # across the dock's MST link is a multi-second black-and-recover.
  services.kanshi = {
    enable = true;
    systemdTarget = "hyprland-session.target";
    settings = [
      {
        profile = {
          name = "docked";
          outputs = [
            {
              criteria = "eDP-1";
              status = "disable";
            }
            {
              criteria = "BNQ XL2586X+ EB3CR02979SL0";
              mode = "1920x1080@599.94Hz";
              position = "0,0";
              scale = 1.0;
              status = "enable";
            }
          ];
        };
      }
      {
        profile = {
          name = "undocked";
          outputs = [
            {
              criteria = "eDP-1";
              mode = "2240x1400@60.00Hz";
              position = "0,0";
              scale = 1.0;
              status = "enable";
            }
          ];
        };
      }
    ];
  };
}
