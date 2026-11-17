# One palette and one font for everything drawn on screen: bar, launcher,
# terminal, greeter and the kernel console. It is One Dark, which the bar
# already used. Hex without the leading '#', so each consumer adds its own
# prefix or alpha suffix.
rec {
  font = "FiraCode Nerd Font";

  bg = "282c34";
  bgDark = "1e222a";
  border = "383c46";
  selection = "3e4451";
  muted = "5c6370";
  fg = "abb2bf";
  fgBright = "ffffff";

  red = "e06c75";
  green = "98c379";
  yellow = "e5c07b";
  blue = "61afef";
  magenta = "c678dd";
  cyan = "56b6c2";

  # ANSI colours 0-15, for the terminal and the virtual console.
  ansi = [
    bg
    red
    green
    yellow
    blue
    magenta
    cyan
    fg
    muted
    red
    green
    yellow
    blue
    magenta
    cyan
    fgBright
  ];
}
