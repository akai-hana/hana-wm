<div align="center">

# hana【花】
###### A comfy X11 Window Manager written in Zig.

![](https://raw.githubusercontent.com/akai-hana/assets/main/flower-banner.png)

<sub>*TODO: replace this with a tiling demonstration gif*</sub>

</div>

> [!NOTE]
> hana is on a very early development phase. it is already fully functioning, but some of the details mentioned in this `README.md` may only be planned features for now; a "`TODO`" comment will be visible on such cases.

---

### Quick anchors

- [Installation](#Installation)

`TODO: documentation section`

---

# About 花

**hana** is an _(optionally)_ dynamic window manager for X11, written in Zig.

It supports tiling/floating window management, and includes its own bar, integrated to the WM.

It is designed with the objective to be comfortable to use, highly configurable and easily modifiable.

---

hana's biggest strength is its ability to be molded like Play-Doh™ (not sponsored).

In particular, hana's main offerings are the following:

## Architecture 

hana counts with a modular codebase architecture, split into single-responsibility code files, written with the goal of making the codebase tidy and easily modifiable by any user. Any file or directory that isn't essential to this WM working/booting up can be just removed, and hana will recompile just fine. 

Don't want hana's bar? Simply remove `src/bar/` and recompile. Don't want tiling/floating? Remove `src/window/modules/tiling/` or `src/window/modules/floating`. Want the bar's inline command prompt, but without vim motions? Keep `src/bar/modules/prompt/prompt.zig` and remove `src/bar/modules/prompt/vim.zig`.

By default, hana's codebase is categorized into directories and sub-directories, although these are purely decorative; the user is free to re-organize the files in any way and hierarchy they prefer.

The main directories are: 

```bash
$ tree src -L 1
src
├ bar
├ config
├ core
└ window
```

`core/`, `window/`, `config/` are hana's main directories. `bar/` contains the code for hana's bar, which is optional to compilation, so it can be removed if the user wants to use another bar, or none at all. `TODO: improve support with external bars`

By default, hana's codebase is organized so that any optional code which extends a particular sub-system is located inside a `modules/` directory, modularly coded so that each individual addition has its own file, or set of files if needed (e.g. `src/bar/title/<title.zig/carousel.zig>`). This is to make a clear hierarchy, as to which files are mandatory and which ones are optional, and what does every module add onto.

`tiling/` and `floating/` can be found inside `window/modules`. Both are included by default, making hana a dynamic window manager. At minimum, either one of them must be included in order to compile hana. 

`TODO: mention codebase encapsulation`

## Configuration

hana has dedicated, hot-reloadable config files, written in TOML.

Configuration can be self-contained on any arrangement of one or more `config/<any-name>.toml` file(s), but by default, hana provides a configuration split into two categories: **functional** and **visual**.

**Functional** configuration can be done through `config/config.toml`, while different **visual** configurations (both color palette and other visual details) can be written (also on TOML) and placed on `config/themes/`, then selected from the config. This means general behavior is separated from visual appearance, allowing different themes to be written and swapped around from the config, while retaining functional preferences, like window rules, tiling behavior, keybindings, workspace layouts, etc.

Selecting a file from the config simply merges the contents from that TOML file with `config/config.toml`. This means the user is free to divide their configuration into any layout of files they want: from one with an individual keybinds vocab file, color palette, visual aspects, tiling config, etc, to just placing everything inside this single `config.toml`.

By default, hana ships a red theme, `config/themes/akai.toml`. When hana is ran, both TOML files' contents are joined, then read through with a custom config parser. This means it's very easy for a user to further divide the config into different files, or just place everything inside a single .toml file.

hana automatically reads all `.toml` files inside `config/.`, meaning the name of the `.toml` file doesn't really matter. Likewise, multiple `.toml` files can be placed inside `config/.`, and they'll be joined automatically. Any sub-directories within `config/` are ignored, and instead must be manually joined through a `.toml` file in the `config/` level, in the case the user wants to store multiple TOML files but doesn't necessarily want to use all of them at the same time; think the previous example, of different themes that can be swapped around in the config.

Since this is all an arbitrary design choice, it is optional and re-categorizable by the user, so one could do `config/config.toml` and `config/others/<binds.toml/rules.toml/tiling.toml>`, or whatever the heck else.

> BTW, pull requests with custom themes are very much welcome. :-)

## Features

Here's the full set of features/characteristics hana offers by default.

- Various window layouts by default: master-stack, monocle, grid, fibonacci, floating
- Per-window tiling/floating _(togglable AND configurable)_ `TODO: configurable pending; togglable ready`
- Fullscreening/Minimizing
- Workspaces _(window tags, multi-workspace tagging)_
- Per-program window rules `TODO: not entirely done yet`
- Per-workspace configurations & window rules `TODO: no workspace-specific window rules yet`
- Modular bar _(inspired by dwm)_
- Various bar widgets _(workspace/layout indicators, window status, clock)_ `TODO: Add system status, volume display & manager widgets`
- Carousel 
- Inline bar command prompt, vim-modal motions
- TOML Config file & file joining _(split config across multiple files)_
- Advanced binding: Ranged-key & array bindings, multi-action keybindings, keybind nesting
- WM scaling across any display resolution `TODO: working, but pending to finish/polish`

---

# Installation
```sh
zig build
# yeah... that's pretty much it
```

## Dependencies
- Zig (master branch)
- X server (xorg/xlibre)
- libxcb (for, well, everything)
- xcb-util-cursor (for custom cursor support)
- xkbcommon (keyboard input handling library)

`TODO: maybe i missed some dependency. will revise later`

### Ubuntu/Debian-based
```sh
apt install libgtk-3-dev xorg-dev libxcb-cursor-dev libxcb-keysyms1-dev libxkbcommon-x11-dev
```

`#`

---

<div align="center">

made with <3 by akai_hana

</div>
