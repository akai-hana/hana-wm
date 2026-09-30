<div align="center">

# hana【花】
###### A comfy X11 Window Manager written in Zig.

![](dev/demonstration.gif)

</div>

> [!WARNING]
> hana is still in development.
>
> At this moment you're reading this, I'm almost done with hana's first stable release, but I'm still working on polishing everything. \
> You may see statements on this README that are still a WiP. Once I do finish though, you'll see this message disappear.

> [!TIP]  
> hana contains three layers of documentation:
> 1. [#introduction](#introduction) for a users' surface overview
> 2. [#body](#body) for a curious users' more in-depth view of any particular topic
> 3. Individual markdown files for developers, highlighting technical/implementation details, one for each sub-system's directory.
> 
> The code itself is also extensibly commented. And there's also templates to create new modules/plugins for every particular sub-system, also for the sake of the QoL of developers' who want to extend hana.

---

### Quick anchors

- [Installation](#installation)
    - [Showcase](#showcase)
- [Introduction](#introduction)
    - [About 花](#about-花)
    - [Motivations](#motivations)
- [Body](#body)
    - [Architecture](#architecture)
    - [Configuration](#configuration)
- [Roadmap](#roadmap)
- [Development](#development)

---

# Installation
```sh
zig build
# yeah... that's pretty much it
```

---

<details>
<summary><i>Dependencies</i></summary>

- Zig 0.16.0 (`build.zig.zon` pins `minimum_zig_version = "0.16.0"`)
- An X server (e.g. Xorg)
- libxcb, with its randr/XKB extensions _(for, well, everything)_
- xcb-util-cursor (custom cursor support)
- xcb-util-keysyms (keycode ↔ keysym conversion)
- xkbcommon + xkbcommon-x11 (keyboard input handling)
- cairo + pango/pangocairo (bar rendering)
- _i think this is everything, but LMK if i'm missing something ^\_^'_

All of these are linked unconditionally; they make up `build.zig.zon`'s `.links` table, so their development headers are required even when a consuming sub-system (e.g. the bar) is removed from the build. (TO-DO: handle conditional dependency linkage)
</details>

## Showcase

(video showcase)

<details>
<summary><i>For a textual showcase, click here for the full set of features/characteristics hana offers (optionally o-o).</i></summary>
**On window management:**

- Tiling/floating paradigms are optional and removable _(at least one of them must stay for hana to compile)_
- Various tiling layouts: master-stack, monocle, grid, fibonacci, scroll, and leaf \
> (Some layouts include variants!; alternatives that are slightly differing in behavior, but otherwise the same layout.)
- Per-window tiling/floating _(toggleable AND configurable via float window rules)_
- Fullscreening / Minimizing
- Workspaces _(window tags, multi-workspace tagging, pinning)_
- Per-program window handling rules _(class-workspace, and class-float admission)_
- Per-workspace configurations & window rules _(numbered `[workspace.rules.N]` sub-tables on the config)_
- Drag-and-drop floating window placement with V-sync smooth dragging and screen edge snapping

**On customizability:**

- TOML Config file splitting & auto-joining _(config can be categorically split across different files if preferred over a mono-file)_
- Config + binary hot-reloading _(in-place, no restart)_
- Swap-able themes _(by default, split-config pallete files under `config/themes/`)_
- Advanced binding: `{...}` glob expansion, ranged-keys, multi-action arrays, mouse bindings, placeholder substitution...
- WM scaling across any display resolution _(DPI & resolution detection)_
- Drop-in module templates for community extensions _(see [`dev/plugin-template/`](dev/plugin-template/))_

**On hana's bar:**

- Modular bar (optional and replaceable if preferred) 
- Various bar widgets by default _(workspaces, title, layout/variants indicators, clock, system-status readouts, volume/brightness drag-sliders...)_
- Title carousel _(text effect for overflowing titles, aware and adaptable of monitor refresh rate)_
- Inline bar command prompt with optional vim-modal motions

**On session & system integration:**

- EWMH/ICCCM cooperation _(window class, `_NET_WM_PID`, fullscreen hints...)_
- Window persistence across restarts, and a clean re-exec (`reload_hana` hot-reloading)
- Crash diagnostics: alternate-signal-backtrace dump on SIGUSR2
- Monitor refresh-rate detection via RandR _(for carousel timing; can be used to extend hana with any new modules)_
</details>

---

# Introduction

## About 花

**hana** is a dynamic X window manager (+ status bar) written in Zig, focused on **modularity**, **flexibility**, and **user-friendliness**.

It includes both tiling and floating window management sub-systems, as well as a status bar that's native/integrated to hana. \
However, all of hana's systems and extensions are modular; as long as one isn't absolutely mandatory for hana to boot, the user can add/remove them at will, deleting their source code and re-compiling & hot-reloading hana's binary.

---

The highest priority of this WM is to be as **modular** as possible, and it achieves this by isolating the source code of all of hana's different systems, as well as developing hana's core systems to make any logic that isn't mandatory **optional** instead. Then, it becomes a matter of eliminating its associated codefile/directory, making hana's core automatically **adapt** to the presence/absence of sub-systems/modules on the next re-compile and hot-reload.

Basically, sub-systems (e.g. tiling, floating, the status bar...), as well as their extensions (e.g. tiling layouts, status bar segments...), act as modules to hana. They can be moved out of hana's `src/` directory, and on re-compiling, a new hana binary is produced, stemming from the new codebase.

Thanks to this, the user achieves two things:

1. Sub-systems are added/removed by moving their source code in/out and re-compiling.
   > The new binary won't include logic that isn't used, and the logic of optional sub-systems is self-contained: no module will mangle the rest of the codebase, not creeping back into hana's core, and instead sitting on top of it.
   > 
   > Any community "patches" become self-contained, auto-organized, and easily manageable.
   
2. Features _within_ each sub-system can be added/removed in order to extend _that_ particular sub-system _(e.g. `src/tiling/modules/master.zig`; the master-stack tiling layout)_.
   > This makes the codebase self-organized by definition: it is clear what belongs to what, and which sits on top/below of which.
   > 
   > Removing a parent sub-system's directory (e.g. `src/tiling/`) also removes all of the child modules contained within it.

> [!TIP]  
> For a more thorough explanation on hana's design, and how it achieves its modularity, see [#architecture](#architecture).

---

Beyond modularity and the extendability/organization benefits that it introduces, hana focuses on the user's **comfort** of usage and configurability, as well as comfort in the **flexibility** to extend its source code in the cleanest and most seamless possible way.

This point leads to my motivations for creating hana to begin with.

## Motivations

**hana** was initially born by my love of [dwm](https://dwm.suckless.org/), and discontent of its patch **extendability** system, and its lack of **flexibility**.

I wanted a window manager that wasn't a single-ish codefile, and instead one that was sub-divided on different sections: one for the core logic, another for the optional sub-systems, and then a place for extension-modules to exist; the latter would act as the "patch"-modules that extend each of hana's particular sub-systems. \
This way, these module-extensions can be managed as codefiles, with no module requiring itself to meld on hana's core code, no patching utilities being required, and all modules always readily available to be moved in/out of hana, them being self-contained.

That aside, I also wanted a more... **Comfortable** usage experience.

For example, having to re-compile the entire WM on each change, even if it was a config change, felt tedious. \
I understand the design philosophy behind dwm, but I just wanted my WM's config to suck more. \
That's why hana uses a user-comfy **TOML config\*** _\*(not true TOML, but a custom parser similar to TOML, adapted to hana's needs)_, and then allows the user to **config hot-reload**.

On that note, **hana's entire BINARY can be hot-reloaded** too btw; if one decides on adding/removing any sub-system or module _on-the-fly_, they won't have to restart their X session and lose all of their running processes; instead, hana can be re-compiled and its binary hot-reloaded. `(o_O)` 

Finally, I wanted foundational source code **cleanness** and **flexibility**, both of which are tied to hana's modular architecture. \
- **On cleanness**, sub-systems and modules should not only be handled properly as detachables, but hana's source code should also NOT reference the removed module in any way. \

  This means that modules interact with closed cores that introduce their own contract-based interfaces. \
  Concretely: hana's core never imports an optional sub-system by name: it only knows the open contracts declared in `src/core/contract.zig` (`Surfaces`, `WindowModule`, `Segment`, `Layout`), and iterates the modules that are actually compiled in through build-GENERATED registries (`window_modules`, `tiling_modules`, `bar_modules`), populated from the files found on the codebase.
  
- **On flexibility**, the ability for users to extend hana by their own modules should be the bestest possible. \
  The general interfaces that keep cores closed to modules _also_ allow new modules to be created under those same interfaces.
  
  This means that community extendability is first-class (also including drop-in module templates over at [`dev/plugin-template/`](dev/plugin-template/): [`layout.zig`](dev/plugin-template/layout.zig) for a new tiling layout, [`provider.zig`](dev/plugin-template/provider.zig) for a new window sub-system, and [`segment.zig`](dev/plugin-template/segment.zig) for a new bar segment. These are also enforced by `zig build check`, compiling them against the contracts (`check-plugin-template`). 

---

# Body
> Venturing deeper into the nitty-gritty

## Architecture 

<img alt="hana's architecture; onion 3-layer diagram" src="https://github.com/user-attachments/assets/54937208-8dd1-4525-b8f1-1cc00996fde0" />

hana counts with a modular codebase architecture, split into single-responsibility code files, written with the goal of making the codebase tidy and easily modifiable by any user. Any file or directory that isn't essential to this WM working/booting up can be just removed, and hana will recompile just fine. 

Don't want hana's bar? Simply remove the bar subsystem and recompile. Don't want tiling/floating? Remove the tiling subsystem or the floating module. Want the bar's inline command prompt, but without vim motions? Keep the prompt module and remove the vim-motions engine.

By default, hana's codebase is categorized into directories and sub-directories, although these are purely decorative; the user is free to re-organize the files in any way and hierarchy they prefer.

The main subsystems are `core`, `window`, `config`, `model`, `tiling`, `input` and `bar`, with unit tests organized under `src/test/` by area. `core`, `window` and `config` are hana's mandatory heart. `bar` contains the code for hana's bar, which is optional to compilation, so it can be removed if the user wants to use another bar, or none at all. `tiling` and `input` hold the tiling engine and key input handling respectively, and `model` is the single source of truth for window state, kept deliberately free of X11 code.

By default, hana's codebase is organized so that any optional code which extends a particular sub-system lives beside its peers (e.g. bar modules beside the bar, window modules beside the window layer), modularly coded so that each individual addition has its own file, or set of files if needed (e.g. a title segment with its carousel helper). This is to make a clear hierarchy, as to which files are mandatory and which ones are optional, and what does every module add onto.

`tiling` and `floating` are both included by default, making hana a dynamic window manager. At minimum, either one of them must be included in order to compile hana. 

hana's wiring is a hub-and-spoke rather than a strict import : a single core `model`, the event pipeline, and one synchronization boundary sit at the center, with `core` and `window` talking to each other around it. Pluggable behavior hangs off that hub through build-GENERATED registries (`window_modules`, `tiling_modules`, `bar_modules`) consumed against the open contracts in `core/contract.zig`, so the core never names an optional module directly. What `dev/scripts/check-layers.sh` — invoked by `zig build check` — actually enforces is: wire-mutating XCB requests and server grabs belong behind the `sync` boundary, `model`, `tiling` and `config` stay xcb-free, and `src/` is `zig fmt` clean. Optional modules extend one subsystem and live beside their peers (bar modules under `bar/modules/`, window modules under `window/modules/`, layouts under `tiling/modules/`), each as a self-contained file that can be deleted to drop the feature from the build.

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

## Backlight write policy

The slider's brightness sub talks to the panel through the kernel's own sysfs
interface (`/sys/class/backlight/<dev>/brightness`), so a commit is one tiny
file write — no subprocess, applied immediately, un-throttled. That native
path needs write permission on the node; by default the nodes are root-only,
and hana silently falls back to a rate-limited `brightnessctl` spawn.

To opt into the native, un-throttled path, install the shipped udev rules and
add your user to the `video` group:

```sh
sudo install -m 0644 contrib/udev/90-hana-backlight.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
sudo usermod -aG video $USER   # then log out and back in
```

With no rule installed, hana still works: the brightnessctl fallback does the
write for you (clamped, coalesced, throttled), just with a subprocess boundary
per commit. See `config/README.md` for the `brightness_device` config knob.

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
