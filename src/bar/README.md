# <|>$>#{ bar/ ~~*** #
# Independent engine #

The status bar is hana's optional, replaceable bar engine. `bar.zig` owns the
lifecycle and the uniform loops over the generated `bar_modules` registry; it
carries no segment logic of its own.

## Layout

- `bar.zig` creates and destroys the bar window, folds dirty state, and drives
  the per-batch update (`updateIfDirty`).
- `state.zig` holds the live `State`/`Bar` handle and the shared `gBar`
  pointer. It is a leaf, so `render/` and `wire/` can read it without
  importing `bar.zig`.
- `bar_contract.zig` is the segment hook set (`Segment`, `Frame`, `Painted`,
  `ClickCtx`, `BarOverlay`, `DirtySources`, opaque `KeyPressEvent`). It is
  X-free and feature-free.
- `segment.zig` provides the registry helpers: capability sets, hook runners,
  and the shared segment bounds.
- `render/` turns model facts and dirty bits into a painted bar (`render.zig`,
  `drawing.zig`, `metrics.zig`, `fonts.zig`, `surface.zig`, `center_row.zig`,
  `bindings.zig`).
- `wire/` is the X11 edge: `win.zig` for window setup and EWMH properties,
  `input_events.zig` for input.
- `visibility.zig` is the pure show/hide policy; the wire calls stay in
  `bar.zig`.
- `bar_config.zig` parses the `[bar]` subtree, and `bar_sections.zig` parses
  its non-scalar pieces (fonts, icons, layout columns).

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
