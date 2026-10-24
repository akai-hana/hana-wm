<div align="center">

# hana【花】
###### A comfy X11 Window Manager written in Zig.

![](https://github.com/akai-hana/hana-wm/releases/download/demo-gif/demonstration.gif)

</div>

> [!WARNING]
> hana is still in development.
>
> At this moment you're reading this, I'm almost done with hana's first stable release, but I'm still working on polishing everything. \
> You may see statements on this README that are still a WiP. Once I do finish though, you'll see this message disappear.

> [!TIP]  
> hana contains two layers of documentation:
> 1. [#introduction](#introduction) for a users' surface overview
> 2. [#body](#body) for a curious users' more in-depth view of any particular topic
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
<br>

- Zig 0.16.0 (`build.zig.zon` pins `minimum_zig_version = "0.16.0"`)
- An X server (e.g. Xorg)
- libxcb, with its randr/XKB extensions _(for, well, everything)_
- xcb-util-cursor (custom cursor support)
- xcb-util-keysyms (keycode ↔ keysym conversion)
- xkbcommon + xkbcommon-x11 (keyboard input handling)
- cairo + pango/pangocairo (bar rendering)
> _i think this is everything, but LMK if i'm missing something ^\_^'_

All of these are linked unconditionally; they make up `build.zig.zon`'s `.links` table, so their development headers are required even when a consuming sub-system (e.g. the bar) is removed from the build. (TO-DO: handle conditional dependency linkage)
</details>

## Showcase

(video showcase)

<details>
<summary><i>For a textual showcase, click here for the full set of features/characteristics hana offers (optionally o_o).</i></summary>
<br>

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
- Drop-in module templates for community extensions _(see [`contrib/plugin-template/`](contrib/plugin-template/))_

**On hana's bar:**

- Modular bar (optional and replaceable if preferred) 
- Various bar widgets by default _(workspaces, title, layout/variants indicators, clock, system-status readouts, volume/brightness drag-sliders...)_
- Title carousel _(text effect for overflowing titles, aware and adaptable of monitor refresh rate)_
- Inline bar command prompt with optional vim-modal motions

**On session & system integration:**

- EWMH/ICCCM standards _(window class, `_NET_WM_PID`, fullscreen hints...)_
- Window persistence across restarts, and a clean re-exec (`reload_hana` hot-reloading)
- Crash diagnostics: alternate-signal-backtrace dump on SIGUSR2
- Monitor refresh-rate detection via RandR _(for carousel timing; can be used to extend hana with any new modules)_
</details>

---

# Introduction

## About 花

**hana** is a dynamic X window manager (+ status bar) written in Zig, focused on **modularity**, **flexibility**, and **user-friendliness**. \
It includes both tiling and floating window management sub-systems, as well as a status bar that's native/integrated to hana.

However, all of hana's systems and extensions are modular; as long as one isn't absolutely mandatory for hana to boot, the user can add/remove them at will, deleting their source code and re-compiling & hot-reloading hana's binary.

---

The highest priority of this WM is to be as **modular** as possible, and it achieves this by isolating the source code of all of hana's different systems, as well as developing hana's core systems to make any logic that isn't mandatory **optional** instead. Then, it becomes a matter of eliminating its associated codefile/directory, making hana's core automatically **adapt** to the presence/absence of sub-systems/modules on the next recompile and reload/hot reload.

Basically, sub-systems (e.g. tiling, floating, the status bar...), as well as their extensions (e.g. tiling layouts, status bar segments...), act as modules to hana. They can be removed, or moved out of hana's `src/` directory, and a new hana binary is produced on recompilation, stemming from the new codebase.

Thanks to this, the user achieves two things:

**1.** Sub-systems are added/removed by moving their source code in/out and re-compiling.
   > The new binary won't include logic that isn't used, and the logic of optional sub-systems is self-contained: no module will mangle the rest of the codebase, not creeping back into hana's core, and instead sitting on top of it.
   > 
   > Any community "patches" become self-contained, auto-organized (organized by design), and easily manageable.
   
**2.** Features _within_ each sub-system can be added/removed in order to extend _that_ particular sub-system _(e.g. `src/tiling/modules/master.zig` extends the tiling system with a master-stack tiling layout)_.
   > This is what makes hana organized by design: thanks to the dir/file structure it is clear what does what, which belongs to where, and who sits on top/below of whoever else.
   > 
   > Removing a parent sub-system's directory (e.g. `src/tiling/`) also removes all of the child modules contained within it.

> [!TIP]  
> For a more thorough explanation on hana's design, and how it achieves its modularity, see [#architecture](#architecture).

---

Beyond modularity, extendability and organization benefits introduced, hana also focuses on the user's **comfort** in usage and configurability, as well as comfort of the developer/advanced user in the **flexibility** to extend its source code in the cleanest and most seamless possible way.

This point leads to my motivations for creating hana to begin with.

## Motivations

**hana** was initially born by my love of [dwm](https://dwm.suckless.org/), and discontent of its patch **extendability** system, particularly due to its lack of **flexibility**.

I wanted a window manager that wasn't mostly a single codefile, and instead one that was sub-divided on different sections: one for the core logic, another for the optional sub-systems, and then a place for extension-modules to exist; the latter would act as the "patch"-modules that extend each of hana's particular sub-systems.

This way, these module-extensions can be managed as codefiles, with no module requiring itself to meld on hana's core code, no patching utilities being required, and all modules always readily available to be moved in/out of hana, them being self-contained.

That aside, I also wanted a more... **Comfortable** usage experience.

For example, having to recompile the entire WM on each change, even if it was a config change, felt tedious. \
I understand the design philosophy behind dwm, but I just wanted my WM's config to suck more. \
That's why hana uses a user-comfy **TOML config\*** _\*(not true TOML, but a custom parser similar to TOML, adapted to hana's needs)_, and introduces **config hot-reload**.

On that note, **hana's entire BINARY can be hot-reloaded** btw; if one decides on adding/removing any sub-system or module _on-the-fly_, they won't have to restart their X session and lose all of their running processes; instead, hana can be recompiled and its binary, config, or both, hot-reloaded (crazy, right...).

Finally, I wanted foundational source code **cleanness** and **flexibility**, both of which are tied to hana's modular architecture. \
- **On cleanness**, sub-systems and modules should not only be treated as detachables, but hana's source code should also NOT reference the detached modules in any way. \

  This means that modules interact with closed cores that introduce their own contract-based interfaces. \
  Concretely: hana's core never imports an optional sub-system by name: it only knows the contract interfaces declared beside each sub-system (the window, bar and tiling contract files under `src/window/`, `src/bar/` and `src/core/architecture/`), and it iterates only the modules that are actually compiled in, through registries generated at build time from the files found in the tree.
  
- **On flexibility**, the ability for users to extend hana by their own modules should be the bestest possible. \
  The general interfaces that keep cores closed to modules _also_ allow new modules to be created under them.
  
  This means that community extendability is first-class: drop-in module templates live in [`contrib/plugin-template/`](contrib/plugin-template/) — [`layout.zig`](contrib/plugin-template/layout.zig) for a new tiling layout, [`provider.zig`](contrib/plugin-template/provider.zig) for a new window sub-system, and [`segment.zig`](contrib/plugin-template/segment.zig) for a new bar segment — and `zig build check` compiles them against the current contracts, so the templates can't drift from the tree silently. 

---

# Body
> Venturing deeper into the nitty-gritty

## Architecture 

<img alt="hana's architecture; onion 3-layer diagram" src="https://github.com/user-attachments/assets/54937208-8dd1-4525-b8f1-1cc00996fde0" />

hana's codebase is an onion. At the very center sits a small, pure description of the world — what windows exist, where they are, which workspace they're on, how each workspace is arranged — with no knowledge of X11 at all. Around that center sit the logic layers that decide things: window admission, focus policy, workspaces, tiling, rendering. At the outer edge sits a deliberately thin boundary where decisions turn into actual X11 traffic; everything that has to talk to the server, or grab it, does so there, so the rest of the tree stays free of wire code.

How to think about it: anything essential to booting a window manager must be present — `src/core/`, `src/window/` and `src/config/` — and everything else is a layer you can delete outright.

Don't want hana's bar? Remove the bar subsystem and recompile. Don't want tiling? Remove the tiling subsystem (or, if tiling is the point and floating isn't, delete the floating module instead — at least one of the two paradigms has to stay for hana to compile). Want the bar's inline command prompt but not its vim motions? Keep the prompt, delete the motions engine. The next compile — and, for runtime features, the next config reload or binary hot-reload — simply yields a hana without those features.

The directory tree is organizational, not load-bearing: discovery works off file names rather than directories, so you can regroup files without breaking anything, and optional extensions live beside their peers — layouts beside the tiling engine, widgets beside the bar, window addons beside the window layer — usually one file, or a small pair when a feature genuinely needs a helper. That gives a clear reading order (what is mandatory, what is optional, what each addition hangs onto), and it means deleting a subsystem's directory takes its whole family of extensions with it.

Two habits keep this honest:

1. **The core never names the optional.** It speaks only through small contract interfaces — one family for window extensions, one for the bar, one shared by every tiling layout — and at build time a registry is generated from whatever files are actually in the tree. Deleting a file removes the only reference to it: no feature flag, no dead branch, no commented-out wiring left to clean up.
2. **State has exactly one writer.** All window state flows through a single model layer (`src/core/model.zig`, deliberately free of X11): every other subsystem asks it to change things, which is what keeps the state consistent no matter how many plugins are plugged in. Keyboard and mouse handling lives under `src/core/input/`, and the unit tests are grouped by area under `src/test/`.

Workspaces are tags in the EWMH sense — a window can live on several, be pinned to all of them, and move around without geometry drama — and per-program plus per-workspace rules shape how new windows arrive. All of it is configurable and hot-reloadable; see [#configuration](#configuration).

## Configuration

hana has dedicated, hot-reloadable config files, written in TOML.

> See [`config/README.md`](config/README.md) for the section reference and value
> format details (percent vs pixel sizes, color spellings, file joining).

How to think about it: `config/config.toml` is the entry file — the only one hana reads on its own. Every other `.toml` under `config/`, including everything in sub-directories, stays unloaded (and is reported as such) until the entry file names it in its `include` list; that naming is where the joining happens. Selecting a file simply merges its contents with the entry file.

The default organization splits **functional** from **visual**: behavior lives in `config/config.toml`, while palettes and look-and-feel live under `config/themes/` and are selected by name from the config (hana ships a red one, `config/themes/akai.toml`). Selecting a theme layers it over the base, so functional preferences — window rules, tiling behavior, keybinds, workspace layouts — stay put while the appearance changes.

None of that split is enforced; it's a convention. Keep one mono-config, or divide things however you like — a keybinds vocab file here, a palette there, tiling knobs somewhere else — as long as `config.toml` includes what you want loaded. Think of `include` as the config's own module system.

Everything in it hot-reloads while hana runs: a keybind, a color, a window rule — no restart, no recompile.

---

# Development

```sh
# format check, then the type-check + layer-guard gate, then the test suite
zig fmt --check .
zig build check -Doptimize=Debug      # no-emit: full Sema, no codegen
dev/scripts/xtest.sh zig build test -Doptimize=Debug   # THE test command: Xvfb-backed
zig build                             # bare = ReleaseFast binary (codegen/link proof)
zig build -Dconfig-warn               # release that keeps config warn diagnostics (~+145 KB)

# everything above + tests + the feature-deletion matrix
dev/scripts/check-before-commit.sh --all
dev/scripts/check-doc-paths.sh        # every path-like token in the docs still exists (also a CI step)
```

## Harness (end-to-end scenarios)

```sh
cd dev/harness
BUILD_DEBUG=1 ./run-scenario.sh --compare S01-spawn-tiled   # run a scenario against its recorded golden
BUILD_DEBUG=1 ./run-scenario.sh --golden  S01-spawn-tiled    # re-record after an intended change
```

Scenarios drive a real window manager on its own throwaway X server, so your session is never touched. `--compare` is a semantic diff (geometry, EWMH properties, state-dump assertions), `--compare-raw` diffs the normalized artifacts byte-for-byte, `--keep` leaves the server up for interactive debugging, and naming several scenarios runs them in sequence. The log-based assertions read info/debug log lines that release composites elide — hence `BUILD_DEBUG=1`, which builds a Debug binary first.

## Checking config

`hana --check-config` validates a config through the real load path (entry file, includes, merge) and exits non-zero on any diagnostic; it needs no display. It does need a Debug build — or a release built with `-Dconfig-warn`: a plain `zig build` composites the warn diagnostics out, and in that binary the mode refuses with exit 2 rather than claiming a clean config.

---

<div align="center">

</> with <3 by [akai_hana](https://github.com/akai-hana)

</div>
