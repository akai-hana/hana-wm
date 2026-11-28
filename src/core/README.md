# )#{<> core >/=!= #
# "The Foundation" #

`core/` represents the foundation of hana.

Systems here feed into the rest of hana's engines.

---

# Overview

Core is the smallest mandatory layer. It owns the process-wide X connection,
the window/workspace model, input dispatch, the event loop, and the reconcile
boundary. Optional subsystems reach it through generated registries and the
contracts in `architecture/`; core never imports an optional subsystem by
name.

## Layout

- `core.zig` is the process-wide `State` (connection, screen, root, allocator,
  config pointer, fact revisions) plus the `init`/`getState` entry points.
- `model.zig` is the pure window/workspace model: windows, workspaces, tags,
  focus, and tiled order. It is deliberately X11-free.
- `architecture/` holds the cross-engine contracts. `contract_dispatch.zig`
  provides `providerOf`/`callAll`; `layout_port.zig` is the generic layout
  port core, window, bar, and config speak, with the tiling adapter supplied
  by the subsystem when present.
- `input/` is keyboard and mouse handling (`dispatch`, `keybinds`, `keymap`,
  `keys`, `masks`, `mouse`, `xkb`, `cursor`).
- `loop/` is the event loop and pipeline (`events.zig`, `pipeline.zig`).
- `x11/` is the wire edge (`xcb`, `atoms`, `requests`, `sink`, `reconcile`).
  Mutations go through `reconcile`; the pure layers stay xcb-free.
- `display/` derives DPI, refresh rate, scaling, and usable area.
- `process/` covers spawning and session handling.
- `pure/` is dependency-free helpers (`bounded`, `idmap`).
- `diagnostic.zig` and `debug/` hold diagnostics, tracing, and profiling.

## Layer policy

`dev/scripts/check-layers.sh` enforces the wire/pure split: `model`, `tiling`,
and `config` must not import xcb, and wire traffic outside the reconcile
boundary is allowlisted. `dev/scripts/check-modularity.sh`
builds the feature-deletion matrix. Keep new pure logic pure, and put X11
traffic behind the sink/reconcile boundary.
