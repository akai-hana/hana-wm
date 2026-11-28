# <|>$>#{ bar/ ~~*** #
# Independent engine #

The status bar is hana's optional, replaceable bar engine. `bar.zig` owns the
lifecycle and the uniform loops over the generated `bar_modules` registry; it
carries no segment logic of its own.

## Layout

- `bar.zig` creates and destroys the bar window, folds dirty state, and drives
  the per-batch update (`updateIfDirty`).
- `core/contract.zig` (module `bar_contract`) is the segment hook set
  (`Segment`, `Frame`, `Painted`, `ClickCtx`, `BarOverlay`, `DirtySources`,
  opaque `KeyPressEvent`). It is X-free and feature-free.
- `core/config.zig` parses the `[bar]` subtree, and `core/sections.zig` parses
  its non-scalar pieces (fonts, icons, layout columns).
- `engine/state.zig` holds the live `State`/`Bar` handle and the shared `gBar`
  pointer. It is a leaf, so `engine/render/` and `engine/wire/` can read it
  without importing `bar.zig`.
- `engine/segment.zig` provides the registry helpers: capability sets, hook
  runners, and the shared segment bounds.
- `engine/render/` turns model facts and dirty bits into a painted bar
  (`render.zig`, `drawing.zig`, `metrics.zig`, `fonts.zig`, `surface.zig`,
  `center_row.zig`, `bindings.zig`).
- `engine/wire/` is the X11 edge: `win.zig` for window setup and EWMH
  properties, `input_events.zig` for input.
- `engine/visibility.zig` is the pure show/hide policy; the wire calls stay in
  `bar.zig`.

`core/` and `engine/` are naming tiers. `src/bar/core/<name>.zig` registers as
`bar_<name>` in the flat module namespace, so files there carry role-only
names; `engine/` holds implementation detail and `modules/` holds the drop-in
segments.

## Segments

Every segment under `src/bar/modules/` (or under `modules/systatus/` and
`modules/slider/` for readouts and controls) declares a `pub const module`
bound to `bar_contract.Segment`. `build.zig` scans those directories and emits
`bar_modules.modules`, so adding or removing a segment is a file move plus a
recompile.

A readout with nothing to show (no battery, unreadable file) returns
`Painted.nothing`: zero width, still a success. A failed draw is a separate
outcome, and the bar substitutes its fallback for that segment.

The bar is optional: delete `src/bar/` and the rest of hana still builds.
