Welcome to my Quickshell dotfiles for both Hyprland and MangoWC

## Dependencies

### hypr-bar.qml (Hyprland)

- `quickshell` + `quickshell-wayland` + `quickshell-hyprland`
- `iwd`
- `playerctl`
- `glib2` — for `gsettings`
- `cava` *(optional — audio visualiser)*
- Symbols Nerd Font
- SF Pro Display *(or a substitute)*
- iwd and iwctl

### mango-bar.qml (MangoWC)

- `quickshell` + `quickshell-wayland`
- `networkmanager` — with iwd backend enabled
- `iwd`
- `playerctl`
- `glib2` — for `gsettings`
- `cava` *(optional — audio visualiser)*
- Symbols Nerd Font
- SF Pro Display *(or a substitute)*

1.0: Installation

Copy the directory, cd into quickshell-btw, and copy your desired dotfiles to the location where you keep your bar files. For both of these programmes, all you need to do is to to make it launch on boot is to set an exec-once = quickshell -p ~/path/to/the/quickshell/config/quickshell-bar-you-chose.qml in hyprland.conf or mango.conf.

1.1: customation

I dunno, do what you like -- it's technically your bar now.
