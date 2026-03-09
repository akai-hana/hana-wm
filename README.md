<div align="center">

# hana【花】
A simple, light, and performant X11 window manager. 🪷

![](https://raw.githubusercontent.com/akai-hana/assets/main/flower-banner.png)

<sub>*TODO: replace this with a tiling demonstration gif*</sub>

</div>

---

# Installation
```sh
zig build
```

## Dependencies
- Zig (master branch)
- X server (xorg/xlibre)
- libxcb (for, well, everything)
- xcb-util-cursor (for custom cursor support)
- xkbcommon (keyboard input handling library)

`#TODO: maybe i missed some dependency. will revise later`

---

# Status

it'll be three months since i started developing hana. it is still very much on an alpha. Completely functional, minus some minor visual bugs, and a serious lack of polish on its config file and codebase.

i'll keep working on this for the time being. expect a first stable release in, say, two more months? or three? hopefully so.

---

# About 花

hana is a window manager for X11, written in Zig. It includes its own bar with an integrated inline command prompt.

<!-- TODO: do widgets, like volume -->

Functionality-wise, hana offers:

- Tiling/floating window management
- Various tiling layouts: master-stack, monocle, grid, fibonacci
- Floating layout
- Per-window floating/dragging
- Fullscreening
- Minimizing
- Workspaces; window tags, multi-tagging
- Per-program window rules
- Per-workspace configurations & window rules
- Modular bar
- Various bar widgets (workspace/layout indicators, window status, clock) `# TODO: System status, volume display & manager`
- Inline bar command prompt, vim-modal motions
- TOML Config file & file joining
- Visual ratios to root window
- Ranged-key & array bindings, multi-action keybindings, keybind nesting

---

## Configuration

`# TODO: most of the information on this section isn't true (yet), and are instead planned features.`

Functional configuration can be done through `config.toml`, while different visual configurations (both color palette and other visual details) can be written (also on TOML) and placed on `themes/`, then selected from the config. This means general behavior is separated from visual appearance, allowing different themes to be written and swapped around from the config, while retaining functional preferences, like tiling behavior, keybindings, workspace rules, etc.

Selecting a file from the config simply merges the contents from that TOML file with `config/config.toml`. This means the user is free to divide their configuration into any layout of files they want: from one with an individual keybinds vocab file, color palette, visual aspects, tiling config, etc, to just placing everything inside this single `config.toml`.

By default, hana ships a red theme, `config/themes/akai.toml`. When hana is ran, both TOML files' contents are joined, then read through with a custom config parser. This means it's very easy for a user to further divide the config into different files, or just place everything inside a single .toml file.

hana automatically reads all `.toml` files inside `config/.`, meaning the name of the `.toml` file doesn't really matter. Likewise, multiple `.toml` files can be placed inside `config/.`, and they'll be joined automatically. Any sub-directories within `config/` are ignored, and instead must be manually joined through a `.toml` file in the `config/` level. This is in the case the user wants to store multiple TOML files but doesn't necessarily want to use all of them at the same time; think the previous example, of different themes that can be swapped around in the config.

> BTW, pull requests with custom themes are very much welcome. :-)

---

## Codebase

hana's codebase is distributed modularly, in individual files with a single responsibility each, sorted purely decoratively in (sub)directories; these serve no other purpose than organization, and hana will work in any set dir configuration: one could forgo dirs entirely and place all files directly in `src/` if they wanted to.

Modules which are essential to hana working are placed inside `core/`. Any dirs outside it are non-essential, and can be entirely removed if wanted (one of tiling/floating, or just individual layouts; bar, or any of its widgets; inline command prompt, or just its vim mode; debugging).

Don't like something in specific? Just remove it! As long as it's a non-essential module, hana is made to work with missing files. Alternatively, you can just disable them through the config.

---

<div align="center">

made with <3 by akai_hana

</div>
