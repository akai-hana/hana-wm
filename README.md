<div align="center">

# hana【花】
###### A comfy X11 Window Manager written in Zig.


![](dev/demonstration.gif)

</div>

> [!NOTE]
> hana-wm is on an early development phase.
> 
> Once I finish polishing everything, I'll release the stable source code on a new `main` branch, and maintain the latest bleeding-edge development on `dev`.

---

### Quick anchors

- [Introduction](#introduction)
    - [About 花](#about-花)
    - [Motivations](#motivations)
- [Installation](#installation)
    - [Showcase](#showcase)
    - [Dependencies](#dependencies)
        - [Ubuntu/Debian-based](#ubuntu-debian-based)
        - [Arch Linux](#arch-linux)
        - [Fedora](#fedora)
- [Body](#body)
    - [Architecture](#architecture)
    - [Configuration](#configuration)
- [Roadmap](#roadmap)
- [Development](#development)

---

# Introduction

## About 花

**hana** is a dynamic X window manager (+ status bar) written in Zig, focused on modularity, flexibility and comfort.

It includes both tiling and floating window management paradigms, as well as its own native bar, integrated to the WM. \
However, no feature is required for hana to work, and the user can add/remove them at will. 

---

The highest priority of this window manager is to be as **modular** as possible, and it achieves this by making all features that aren't strictly necessary to hana working **optional**, by isolating their specific logic on their own codefile(s) (following the open-closed principle), and making hana's core **adapt** automatically to the presence/absence of new sub-systems/modules.  

Basically, sub-systems (e.g. tiling), as well as their modules (e.g. tiling layouts), act as addons to hana. They can be removed, hana re-compiled, and a new binary is produced, fruit of a different codebase. 

This way, the user can achieve two things:
1. Features are removed by deleting their source code and re-compiling. \
   This produces a new binary that stems from a codebase that simply doesn't include the logic for certain features
3. Features _within_ each sub-system can be added/removed in order to extend _that_ particular sub-system _(e.g. `src/tiling/modules/master.zig`; the master-slave layout)_.

> For a more thorough explanation, see [hana's architecture section](#architecture).

Beyond modularity and its extendability benefits, hana focuses on **comfort** of configurability and usage, as well as the **flexibility** to alter its source code in the most clean and seamless possible way.

For example, a user could remove either the tiling or floating paradigm, can remove the one they don't want to use, 

## Motivations

**hana** was initially born by my love of [dwm](https://dwm.suckless.org/), and discontent of its patch **extendability** system.

I wanted a window manager with three places: one for the core logic, another for the optional sub-systems, and then a place for modules to exist that extend each sub-system; the latter would act as the "patches" that extend hana's behavior. \
This way, extensions can be managed as codefile plugins, with no addon being permanent, and no patching utilities being required: no patch conflicts, no "tainted" source code, no "patching orders"... Drag'n'drop _(n're-compile)_, baby. 

I also wanted a more... **comfortable** usage experience.

For example, having to re-compile the entire WM on each change, even if it was a minor config adjustment, didn't sit right with me. \
I understand dwm's reasoning, but I wanted my own WM's config to suck more. That's why hana uses a **TOML config** _(custom-parsed btw)_, and then allows the user for **config hot-reloading**. \
On that note, **hana's entire BINARY can be hot-reloaded**; if one decides on adding/removing any sub-system or module _on the fly_, they can re-compile hana and hot-reload the binary, preserving their existing X session's windows. _Pretty neat, huh?_  

Finally, I wanted foundational source code **cleanness** and **flexibility**, both of which are tied to hana's modular architecture. \
- **On cleanness**, sub-systems and modules should not only be handled properly as detachables, but hana's source code should also NOT reference any of the removed module's code. \
  This means no dummy stubs, but rather closed cores that allow open modules through general interfaces. \
  Concretely: hana's core never imports an optional sub-system by name: it only knows the open contracts declared in `src/core/plugin.zig` (`Surfaces`, `WindowModule`, `Segment`, `Layout`), and iterates the modules that are actually compiled in through build-GENERATED registries (`window_modules`, `tiling_modules`, `bar_modules`) populated from the files found on disk. Deleting a module therefore just shortens an array — no `if` chains, no dead stubs, and nothing in the core that ever needs patching back in.
  
- **On flexibility**, the ability for users to extend hana by their own modules should be the bestest possible. \
  The general interfaces that keep cores closed to modules _also_ allow new modules to be created under those same interfaces. \
  This means that community extendability is first-class (also including drop-in module templates over at [`dev/plugin-template/`](dev/plugin-template/): [`layout.zig`](dev/plugin-template/layout.zig) for a new tiling layout, [`provider.zig`](dev/plugin-template/provider.zig) for a new window sub-system, and [`segment.zig`](dev/plugin-template/segment.zig) for a new bar segment. These are also enforced by `zig build check` compiling them against the contracts (`check-plugin-template`). 

---

# Installation
```sh
zig build
# yeah... that's pretty much it
```

## Showcase

(video showcase)

<details>
<summary><b>For a textual showcase, click here for the full set of features/characteristics hana offers (optionally :-) ).</b></summary>
**On window management:**

- Dynamic tiling **and** floating paradigms — optional and removable; at least one of them must stay for hana to compile
- Various tiling layouts: master-stack, monocle, grid, fibonacci, scroll, and leaf \
> (Some layouts include variants!; alternatives that are slightly differing in behavior, but otherwise the same layout.)
- Per-window tiling/floating _(toggleable AND configurable via float window rules)_
- Fullscreening / Minimizing
- Workspaces _(window tags, multi-workspace tagging, pinning)_
- Per-program window rules _(class → workspace, and class → float admission)_
- Per-workspace configurations & window rules _(numbered `[workspace.rules.N]` sub-tables and per-workspace master counts)_
- Drag-and-drop window placement with snapping

**On customizability:**

- TOML Config file & file joining _(split config across multiple files)_
- Config hot-reloading _(in-place, no restart)_
- Swap-able themes _(palette files under `config/themes/`)_
- Advanced binding: `{...}` glob expansion, ranged-keys, multi-action arrays, mouse bindings, placeholder substitution
- WM scaling across any display resolution _(DPI-aware)_
- Drop-in module templates for community extensions _(see [`dev/plugin-template/`](dev/plugin-template/))_

**On hana's bar:**

- Modular bar _(inspired by dwm)_ — an optional sub-system, removable from the build
- Various bar widgets _(workspaces, title, layout/variants indicators, clock, volume manager, system status)_
- Title carousel _(marquee for overflowing titles, timed by monitor refresh rate)_
- Inline bar command prompt with vim-modal motions

**On session & system integration:**

- EWMH/ICCCM cooperation _(window class, `_NET_WM_PID`, fullscreen hints, …)_
- Window persistence across restarts, and a clean re-exec (`reload_hana`)
- Crash diagnostics: alternate-signal-stack backtrace dump on SIGUSR2
- Monitor refresh-rate detection via RandR _(carousel timing)_
</details>

## Dependencies
- Zig 0.16.0 (`build.zig.zon` pins `minimum_zig_version = "0.16.0"`)
- An X server (e.g. Xorg)
- libxcb, with its randr/XKB extensions _(for, well, everything)_
- xcb-util-cursor (custom cursor support)
- xcb-util-keysyms (keycode ↔ keysym conversion)
- xkbcommon + xkbcommon-x11 (keyboard input handling)
- cairo + pango/pangocairo (bar rendering)

All of these are linked unconditionally — they make up `build.zig.zon`'s `.links` table — so their development headers are required even when a consuming sub-system (e.g. the bar) is removed from the build.

### Ubuntu/Debian-based
```sh
apt install libxcb1-dev libxcb-cursor-dev libxcb-keysyms1-dev libxcb-randr0-dev libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev libcairo2-dev libpango1.0-dev
```

### Arch Linux
```sh
pacman -S libxcb xcb-util-cursor xcb-util-keysyms libxkbcommon libxkbcommon-x11 cairo pango
```

### Fedora
```sh
dnf install libxcb-devel xcb-util-cursor-devel xcb-util-keysyms-devel libxkbcommon-devel libxkbcommon-x11-devel cairo-devel pango-devel
```

*more distros later :)*

---

# Body
> Going deeper into detail in hana's internals

## Architecture 

<img alt="hana's architecture; onion layers diagram" src="https://github.com/user-attachments/assets/54937208-8dd1-4525-b8f1-1cc00996fde0" />

hana counts with a modular codebase architecture, split into single-responsibility code files, written with the goal of making the codebase tidy and easily modifiable by any user. Any file or directory that isn't essential to this WM working/booting up can be just removed, and hana will recompile just fine. 

Don't want hana's bar? Simply remove the bar subsystem and recompile. Don't want tiling/floating? Remove the tiling subsystem or the floating module. Want the bar's inline command prompt, but without vim motions? Keep the prompt module and remove the vim-motions engine.

By default, hana's codebase is categorized into directories and sub-directories, although these are purely decorative; the user is free to re-organize the files in any way and hierarchy they prefer.

The main subsystems are `core`, `window`, `config`, `model`, `tiling`, `input` and `bar`, with unit tests organized under `src/test/` by area. `core`, `window` and `config` are hana's mandatory heart. `bar` contains the code for hana's bar, which is optional to compilation, so it can be removed if the user wants to use another bar, or none at all. `tiling` and `input` hold the tiling engine and key input handling respectively, and `model` is the single source of truth for window state, kept deliberately free of X11 code.

By default, hana's codebase is organized so that any optional code which extends a particular sub-system lives beside its peers (e.g. bar modules beside the bar, window modules beside the window layer), modularly coded so that each individual addition has its own file, or set of files if needed (e.g. a title segment with its carousel helper). This is to make a clear hierarchy, as to which files are mandatory and which ones are optional, and what does every module add onto.

`tiling` and `floating` are both included by default, making hana a dynamic window manager. At minimum, either one of them must be included in order to compile hana. 

hana's wiring is a hub-and-spoke rather than a strict import stack: a single core `model`, the event pipeline, and one synchronization boundary sit at the center, with `core` and `window` talking to each other around it. Pluggable behavior hangs off that hub through build-GENERATED registries (`window_modules`, `tiling_modules`, `bar_modules`) consumed against the open contracts in `core/plugin.zig`, so the core never names an optional module directly. What `dev/scripts/check-layers.sh` — invoked by `zig build check` — actually enforces is: wire-mutating XCB requests and server grabs belong behind the `sync` boundary, `model` and `tiling` stay xcb-free, and the whole tree is `zig fmt` clean. Optional modules extend one subsystem and live beside their peers (bar modules under `bar/modules/`, window modules under `window/modules/`, layouts under `tiling/modules/`), each as a self-contained file that can be deleted to drop the feature from the build.

## Configuration

hana has dedicated, hot-reloadable config files, written in TOML.

> See [`config/README.md`](config/README.md) for the section reference and value
> format details (percent vs pixel sizes, color spellings, file joining).

Configuration can be self-contained on any arrangement of one or more `config/<any-name>.toml` file(s), but by default, hana provides a configuration split into two categories: **functional** and **visual**.

**Functional** configuration can be done through `config/config.toml`, while different **visual** configurations (both color palette and other visual details) can be written (also on TOML) and placed on `config/themes/`, then selected from the config. This means general behavior is separated from visual appearance, allowing different themes to be written and swapped around from the config, while retaining functional preferences, like window rules, tiling behavior, keybindings, workspace layouts, etc.

Selecting a file from the config simply merges the contents from that TOML file with `config/config.toml`. This means the user is free to divide their configuration into any layout of files they want: from one with an individual keybinds vocab file, color palette, visual aspects, tiling config, etc, to just placing everything inside this single `config.toml`.

By default, hana ships a red theme, `config/themes/akai.toml`. When hana is ran, both TOML files' contents are joined, then read through with a custom config parser. This means it's very easy for a user to further divide the config into different files, or just place everything inside a single .toml file.

hana automatically reads all `.toml` files inside `config/.`, meaning the name of the `.toml` file doesn't really matter. Likewise, multiple `.toml` files can be placed inside `config/.`, and they'll be joined automatically. Any sub-directories within `config/` are ignored, and instead must be manually joined through a `.toml` file in the `config/` level, in the case the user wants to store multiple TOML files but doesn't necessarily want to use all of them at the same time; think the previous example, of different themes that can be swapped around in the config.

Since this is all an arbitrary design choice, it is optional and re-categorizable by the user, so one could do `config/config.toml` and `config/others/<binds.toml/rules.toml/tiling.toml>`, or whatever the heck else.

> BTW, pull requests with custom themes are very much welcome. :-)

---

# Roadmap

Planned, not-yet-shipped items:

- **External bar support** — hana currently ships its own integrated bar;
  driving an external bar (dwm-style `setstatus`) is not implemented yet.
- **Ratio `%N` spelling** — the config parser accepts `N%` but not the
  reversed `%N` form yet.
- **Finer window rules** — rules today cover class → workspace and class →
  float; rule-driven properties (border color, gaps, …) are future work.
- **Scaling polish** — cross-display scaling works, but per-monitor fine-tuning
  is still being refined.

---

# Development

```sh
# format check, build with layer checks, then the full test suite
zig fmt --check .
zig build check
dev/scripts/xtest.sh zig build test   # runs under Xvfb; headless `zig build test` skips X-gated tests
```

- `dev/scripts/check-layers.sh` (invoked by `zig build check`) enforces the
  subsystem layering described under [Architecture](#architecture).
- `zig build check-all` additionally runs the modularity matrix
  (`dev/scripts/check-modularity.sh`: builds each module in isolation) — kept
  separate from `check` because it cold-builds ~25 configurations.
- Latency benchmarks are opt-in: `zig build test -Dbench` runs the
  `focus_latency_test`/`tiling_latency_test` full loops and prints timings
  (off by default, so the normal suite stays fast and silent). `zig build
  -Dprofile-key` instruments the key-dispatch path (receive → action latency).
- End-to-end X scenarios live in `dev/harness/`. `dev/harness/run-scenario.sh
  --golden S01-spawn-tiled …` records a baseline, and `--compare` diffs a run
  against `dev/harness/golden/` (normalized tree/property/state-log snapshots);
  `--compare-raw` is a byte-exact variant and `--keep` leaves the isolated
  Xvfb + hana up for inspection.
- Unit tests live in `src/test/` alongside the code they cover. X-gated window
  tests self-pass when no display is available, printing `SKIP:`/`WARN:` to a
  TTY only (interactive runs); set `HANA_REQUIRE_X=1` to turn any skip into a
  hard failure. `dev/scripts/xtest.sh` already sets it, so that path can never
  go green by skipping.
- The tree carries no `TODO`/`FIXME` markers: `rg -n "TODO|FIXME" src/` is
  empty by design (open work lives in the issue tracker, not the source).

---

<div align="center">

</> with <3 by [akai_hana](https://github.com/akai-hana)

</div>
