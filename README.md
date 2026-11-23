<div align="center">

# hana【花】
###### A comfy X11 Window Manager written in Zig.

![](https://github.com/akai-hana/assets/blob/d1593f11eafa6a76944396aae454130d3071923b/demos/hana.gif)

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
> The code itself is also extensively commented. There are also templates to create new modules/plugins for hana's main extension points, for the sake of the QoL of developers who want to extend hana.

---

### Quick anchors

- [Introduction](#introduction)
    - [About 花](#about-花)
    - [Motivations](#motivations)
- [Installation](#installation)
- [Showcase](#showcase)
- [Body](#body)
    - [Architecture](#architecture)
    - [Configuration](#configuration)
        - [Config discovery](#config-discovery)
        - [Checking config](#checking-config)
    - [Current limitations](#current-limitations)
- [Development](#development)
    - [Dev loop](#dev-loop)
    - [Harness](#harness-end-to-end-scenarios)
    - [Testing](#testing)
    - [Extending hana](#extending-hana)

---

# Introduction

## About 花

**hana** is a dynamic X window manager (+ status bar) written in Zig, focused on **modularity**, **flexibility**, and **user-friendliness**. \
It includes both tiling and floating window management subsystems, as well as a status bar that's native/integrated to hana.

However, all of hana's systems and extensions are modular: anything not required to boot can be added or removed by moving its source in or out, then recompiling and hot-reloading the binary.

---

hana's highest priority is **modularity**. Its systems are isolated in their own source trees, and core logic that isn't mandatory is optional, so the core adapts to the presence or absence of each subsystem on the next build.

Subsystems (tiling, floating, the status bar) and their extensions (tiling layouts, status bar segments) are modules. They can be removed, or moved out of hana's `src/` directory, and a new hana binary is produced on recompilation.

This gives two things:

**1.** Subsystems are added or removed by moving their source in or out and recompiling.
   > The new binary leaves out unused logic, and optional subsystems are self-contained: no module creeps back into core; each sits on top of it.
   >
   > Community patches become self-contained, organized by design, and easy to manage.

**2.** Features within a subsystem can be added or removed to extend it (for example, `src/tiling/modules/master.zig` adds a master-stack layout).
   > The directory structure makes the hierarchy explicit: what does what, what belongs where, and what sits on top of what.
   >
   > Removing a parent subsystem's directory (for example, `src/tiling/`) also removes its child modules.

> [!TIP]
> For a more thorough explanation on hana's design, and how it achieves its modularity, see [#architecture](#architecture).

---

Beyond modularity, hana focuses on user comfort in usage and configuration, and on giving developers the flexibility to extend its source code cleanly and seamlessly.

This point leads to my motivations for creating hana to begin with.

## Motivations

**hana** was initially born by my love of [dwm](https://dwm.suckless.org/), and discontent with its patch-based **extendability**, particularly its lack of **flexibility**.

I wanted a window manager that wasn't mostly a single file, but subdivided into sections: core logic, optional subsystems, and a home for extension modules that act as patches for each subsystem.

This way, extensions are managed as ordinary code files: no module has to meld into core, no patching utility is needed, and every module is self-contained and easy to move in or out.

I also wanted a more **comfortable** experience.

Recompiling the whole WM for every change, including config changes, felt tedious. \
I understand dwm's philosophy, but I wanted the config to suck less. \
That's why hana uses a user-friendly **TOML-like config** _\*(not true TOML, but a custom parser adapted to hana's needs)_ and supports **config hot-reload**.

**hana's entire binary can be hot-reloaded** as well. Adding or removing a subsystem or module on the fly doesn't require restarting the X session or losing running processes: recompile hana, then hot-reload the binary, the config, or both.

Finally, I wanted the source to be **clean** and **flexible**, both tied to hana's modular architecture. \
- **On cleanness**, optional subsystems and modules must be detachable, and the source must never reference a detached module. \

  Modules interact with closed cores through contract-based interfaces. \
  Concretely, core never imports an optional subsystem by name. It knows only the contract interfaces declared beside each subsystem (the window, bar, and tiling contracts under `src/window/`, `src/bar/`, and `src/core/architecture/`) and iterates the modules actually compiled in through registries generated at build time.

- **On flexibility**, users should be able to extend hana with their own modules as easily as possible. \
  The same interfaces that keep cores closed also let new modules plug in beneath them.

  Community extendability is first-class: drop-in templates live in [`contrib/plugin-template/`](contrib/plugin-template/) ([`layout.zig`](contrib/plugin-template/layout.zig) for a new tiling layout, [`provider.zig`](contrib/plugin-template/provider.zig) for a new window subsystem, and [`segment.zig`](contrib/plugin-template/segment.zig) for a new bar segment), and `zig build check` compiles them against the current contracts, so they cannot drift silently.

---

# Installation
```sh
zig build
zig build run   # or launch zig-out/bin/hana from your X startup file
# that's it
```

---

<details>
<summary><i>Dependencies</i></summary>
<br>

- Linux/*BSD
- Zig 0.16.0
- An X server (for example, Xorg or XLibre)
- libxcb (+ randr/XKB extensions)
- xcb-util-keysyms (if using hana's bar)
- xkbcommon + xkbcommon-x11 (keyboard input handling)
- xcb-util-cursor (root cursor theming; skip with `-Dcursor=false`)
- cairo + pango/pangocairo (if using hana's bar)

Linkage is conditional where it can be. The bar-only libraries (`pangocairo-1.0` and `xcb-keysyms`) are skipped when the bar is absent, and `-Dcursor=false` drops `xcb-cursor`; the rest are core. `build.zig.zon`'s `.links` table names the direct entries (`xcb`, `xcb-keysyms`, `xkbcommon-x11`, `xcb-xkb`, `xcb-cursor`, `xcb-randr`, `pangocairo-1.0`), while xkbcommon, cairo, and pango arrive transitively through them.

</details>

---

# Showcase

<details>
<summary><i><b>Click here</b> for a feature list.</i></summary>
<br>

**Window management:**

- Tiling/floating paradigms are optional and removable _(at least one of them must stay for hana to compile)_
- Various tiling layouts: master-stack, monocle, grid, fibonacci, scroll, and leaf \
> (Some layouts include variants: alternatives that tweak behavior while keeping the same layout.)
- Per-window tiling/floating _(toggleable AND configurable via float window rules)_
- Fullscreen and minimize, with LIFO/FIFO restore order
- Workspaces _(window tags, multi-workspace tagging, pinning, all-view mode)_
- Per-workspace layouts, or one global layout across every workspace
- Per-program window rules _(send a class to a workspace, or admit it as floating)_
- Per-workspace configurations & window rules _(numbered `[workspace.rules.N]` sub-tables on the config)_
- Master-stack controls: count, side, width, swap, and stack growth
- Hover focus _(focus follows the pointer)_
- Drag-and-drop floating window placement with refresh-paced smooth dragging and screen edge snapping

**Customization:**

- TOML-like config file splitting & auto-joining _(split config across different files instead of one mono-file)_
- Config + binary hot-reloading _(in-place; no X-session restart)_
- Swappable themes _(by default, split config palette files under `config/themes/`)_
- Advanced bindings: `{...}` glob expansion, ranged-keys, multi-action arrays, mouse bindings, placeholder substitution
- Optional key auto-repeat (`[core] key_repeat`) when you want held keys to re-fire
- WM scaling across different display resolutions _(DPI & resolution detection)_
- Drop-in module templates for community extensions _(see [`contrib/plugin-template/`](contrib/plugin-template/))_

**Status bar:**

- Modular bar _(optional, replaceable, or removable)_
- Top/bottom position and visibility toggles
- Useful bar widgets out of the box _(workspaces, title, layout/variants indicators, clock, system-status readouts, volume/brightness drag-sliders)_
- Title carousel _(scrolls overflowing titles, paced to your monitor's refresh rate)_
- Inline bar command prompt with completion, history, and optional vim-modal motions

**System integration:**

- EWMH/ICCCM standards _(window class, `_NET_WM_PID`, fullscreen hints)_
- EWMH struts/work area, so foreign docks and panels can reserve screen edges
- Window persistence across a clean re-exec (`reload_hana` hot-reloading); a normal restart starts fresh
- Signals: SIGUSR1 re-execs the binary; SIGUSR2 dumps an alternate-stack backtrace
- Monitor refresh-rate detection via RandR _(for carousel timing; available to new modules too)_
</details>

---

# Body

## Architecture

<img alt="hana's architecture; onion 3-layer diagram" src="https://github.com/user-attachments/assets/54937208-8dd1-4525-b8f1-1cc00996fde0" />

hana's code has three layers: core, systems, and modules. The core holds the state model (`src/core/model.zig`): which windows exist, where they are, which workspaces they belong to, and how each workspace is arranged. The model lives in core because every system reads it: window policy, tiling, the bar, and config all share it. It is deliberately X11-free. The systems decide policy: `src/window/` admits windows, owns focus and workspace membership, and turns state changes into X11 requests; tiling and the bar consume the same model. Modules extend the systems. There is no separate wire layer: the wire is that translation edge, mostly under `src/core/x11/`, not a build-time construct.

The tree is not a strict import stack: core and window import each other, and X11 calls are spread across several modules. The boundary is enforced by policy instead: X11 mutations go through the reconcile boundary, and `model`, `tiling`, and `config` stay X11-free. Exceptions are allowlisted in `dev/scripts/check-layers.sh`.

Other than `src/core/`, and the two mandatory systems `src/window/` and `src/config/`, everything else is a layer that can be deleted at will.

Don't want hana's bar? Remove the bar subsystem and recompile. Don't want tiling? Remove it (or, if tiling is the point and floating isn't, delete the floating module instead; at least one of the two paradigms has to stay). Want the bar's inline prompt but not its vim motions? Keep the prompt, delete the motions engine. The next compile (or, for runtime features, the next config reload or binary hot-reload) yields a binary without those features.

Optional extensions live on top of the system they're extending, and discovery is path-prefixed: layouts are only picked up under `src/tiling/modules/`, bar segments under `src/bar/modules/`, and window addons under `src/window/modules/`. Within those homes, file names become registry stems. A `foo.zig` in the right `modules/` directory that declares the owner's module binding joins that owner's registry; move it somewhere else and it stops being discovered. That's what gives the tree a clear reading order (what is mandatory, what is optional, what each addition hangs onto), and it means deleting a subsystem's directory cleanly takes its whole family of extensions along with it.

---

hana's structure strictly follows two rules:

1. **The core never names the optional.** It speaks only through small contract interfaces (one family for window extensions, one for the bar, one shared by every tiling layout), and at build time a registry is generated from whatever files are actually in the tree. Deleting a file removes the only reference to it: no feature flag, no dead branch, no commented-out wiring left to clean up.
2. **State has exactly one home.** All managed window state sits in a single model layer (`src/core/model.zig`, deliberately free of X11). Membership writes (the `tiled_order` lists that keep each tiled window on exactly one workspace) go through a small single-writer set: the model's write API plus the few callers that genuinely re-home a window. That's what keeps state consistent no matter how many plugins are plugged in. Keyboard and mouse handling lives under `src/core/input/`, and the unit tests are grouped by area under `src/test/`.

Workspaces are hana's own tags: a window can live on several, be pinned to all of them, and moved around without geometry drama. EWMH pagers can switch workspaces, move windows between them, and request all-desktops, which hana maps to its pinned state. Per-program plus per-workspace rules shape how new windows arrive, and all of it is configurable and hot-reloadable; you can learn more right below.

## Configuration

hana's config lives in dedicated, hot-reloadable files written in hana's own **TOML-like dialect**: close enough to TOML to feel familiar, custom enough to fit hana's needs.

> See [`config/README.md`](config/README.md) for the section reference and value format details (percent vs pixel sizes, color spellings, file joining).

### Config discovery

hana looks for its config in this order:

1. `$XDG_CONFIG_HOME/hana/` (defaults to `~/.config/hana/`)
2. `./config/`
3. `$XDG_CONFIG_HOME/hana/config.toml` (defaults to `~/.config/hana/config.toml`)
4. `./config.toml`
5. the embedded fallback config

A directory contributes its `config.toml` plus that file's includes; a single-file location loads that file plus its includes. The first source that loads wins.

`config/config.toml` is the entry file: the only one hana reads on its own. Every other top-level `.toml` under `config/` (except the embedded `fallback.toml`) sits inert (and gets a warning) until the entry file names it in its `include` list. Sub-directories are never read on their own, so a file in one loads only when `include` reaches it (and that's one level deep: an included file's own `include` is ignored). That's where the joining happens: selecting a file merges its contents with the entry file.

The default organization splits **functional** from **visual**: behavior lives in `config/config.toml`, while palettes and look-and-feel live under `config/themes/` and are selected by name from the config (hana ships a red one, `config/themes/akai.toml`). Selecting a theme layers it over the base, so functional preferences (window rules, tiling behavior, keybinds, workspace layouts) stay put while the appearance changes.

None of that split is enforced; it's a convention. Keep one mono-config, or divide things however you like (a keybinds vocab file here, a palette there, tiling knobs somewhere else) as long as `config.toml` includes what you want loaded. `include` is basically the config's own module system.

And yes: everything in it hot-reloads while hana runs. A keybind, a color, a window rule: no restart, no recompile.

### Checking config

`hana --check-config` validates a config through the real load path (entry file, includes, merge) and exits non-zero on any diagnostic. It needs no display.

It does need a Debug build, or a release built with `-Dconfig-warn`: a plain `zig build` compiles the warn diagnostics out, and in that binary the mode refuses with exit 2 rather than claiming a clean config.

`hana --dump-config-schema` prints the composed knob inventory as JSON. It reads no config, needs no display, and works in every build mode, which makes it useful for docs and editor tooling.

## Current limitations

- One screen for now. Multi-monitor is a struts-only interim: hana does not lay windows out across outputs yet.
- Drag pacing follows the detected refresh rate and a timer; there is no vsync/vblank integration.

---

# Development

## Dev loop

```sh
# format check, then type-check + layer guards, then the test suite
zig fmt --check .
zig build check -Doptimize=Debug      # no-emit: full Sema, no codegen
dev/scripts/xtest.sh zig build test -Doptimize=Debug   # THE test command: Xvfb-backed
zig build                             # bare = ReleaseFast binary (codegen/link proof)
zig build -Dconfig-warn               # release that keeps config warn diagnostics (~+145 KB)

# fmt + doc paths + check + tests + feature-deletion matrix; bare `zig build` stays separate
dev/scripts/check-before-commit.sh --all
dev/scripts/check-doc-paths.sh        # every path-like token in the docs still exists (also a CI step)
```

Common build options:

- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` (bare `zig build` is `ReleaseFast`)
- `-Dconfig-warn` keeps config warn diagnostics in a release build
- `-Dcursor=false` drops root-cursor theming and the `xcb-util-cursor` dependency
- `-Dbench` runs the benchmark loops at full count
- `-Dprofile-key` logs key-dispatch latency
- `-Dstrict-grabs=false` elides grab-depth invariant checks
- `-Dtest-filter=<stem>` runs a single `*_test` file

## Harness (end-to-end scenarios)

```sh
cd dev/harness
BUILD_DEBUG=1 ./run-scenario.sh --compare S01-spawn-tiled   # run a scenario against its recorded golden
BUILD_DEBUG=1 ./run-scenario.sh --golden  S01-spawn-tiled    # re-record after an intended change
```

Scenarios drive a real window manager on its own throwaway X server, so your session is never touched. `--compare` is a semantic diff (geometry, EWMH properties, state-dump assertions), `--compare-raw` diffs the normalized artifacts byte-for-byte, `--keep` leaves the server up for interactive debugging, and naming several scenarios runs them in sequence. The scenario scripts live under `dev/harness/scenarios/`.

The log-based assertions read info/debug log lines that release builds elide, hence `BUILD_DEBUG=1`, which builds a Debug binary first.

## Testing

The unit suite is grouped by area under `src/test/`. Run it through `dev/scripts/xtest.sh`, which starts an isolated Xvfb and sets `HANA_REQUIRE_X=1` so display-gated tests actually run:

```sh
dev/scripts/xtest.sh zig build test -Doptimize=Debug
```

Benchmarks run their full loops with `-Dbench=true`:

```sh
zig build bench -Dbench=true
```

The fuzz target lives in `src/test/fuzz/`. End-to-end scenarios live under `dev/harness/`; see [Harness](#harness-end-to-end-scenarios).

## Extending hana

Drop-in templates live in [`contrib/plugin-template/`](contrib/plugin-template/): `layout.zig` for a tiling layout, `provider.zig` for a window subsystem, `segment.zig` for a bar segment, `readout.zig` and `control.zig` for systatus/slider segments, `config-fragment.zig` for a module config, and `title-addon.zig` / `prompt-addon.zig` for bar extensions. Copy one into the matching `src/**/modules/` directory and edit the TODOs.

`zig build check-plugin-template` type-checks every template against the current contracts, so they cannot drift silently. `zig build check-modularity` builds the feature-deletion matrix, and `dev/scripts/check-layers.sh` enforces the wire/pure-layer policy. For subsystem analysis notes, see [`src/system-wide-analysis/`](src/system-wide-analysis/).

---

<div align="center">

</> with <3 @ [akai_hana](https://github.com/akai-hana)

</div>
