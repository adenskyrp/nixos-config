-- /etc/nixos/hyprland.lua

-- 1. Hardware & Monitor Setup
hl.config({
  input = {
    kb_layout = "us"
  }
})

hl.monitor({
  output = "eDP-1", -- Verify this matches your laptop screen via 'hyprctl monitors'
  mode = "highres",
  position = "0x0",
  scale = 1
})

-- 2. SwayOSD Media & Brightness Controls (with repeating flag for holding down)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume raise 5"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume lower 5"), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"))

hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("swayosd-client --brightness raise 5"), { repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness lower 5"), { repeating = true })

-- 3. The Power of Lua: Dynamic Workspace Generation
-- Instead of writing 10 lines of config, we generate workspace keybinds programmatically
local mainMod = "SUPER"
for i = 1, 9 do
  -- Bind SUPER + [1-9] to switch workspaces
  hl.bind(mainMod .. " + " .. tostring(i), hl.dsp.exec_cmd("hyprctl dispatch workspace " .. tostring(i)))
  -- Bind SUPER + SHIFT + [1-9] to move active window to workspace
  hl.bind(mainMod .. " + SHIFT + " .. tostring(i), hl.dsp.exec_cmd("hyprctl dispatch movetoworkspace " .. tostring(i)))
end
