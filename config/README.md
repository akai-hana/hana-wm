# hana configuration

hana's configuration is one or more **TOML** files living inside `config/`.
There is no schema duty: every file is parsed with hana's own TOML parser, so
malformed values are either warned-and-ignored or rejected while keeping the
previous config in memory.

The stock split (arbitrary, and entirely up to you):

| file                 | role                                        |
| -------------------- | ------------------------------------------- |
| `config.toml`        | functional behavior, binds, bar, rules      |
| `themes/akai.toml`   | visual palette & appearance                 |
| `programs.toml`      | personal program binds                      |
| `fallback.toml`      | built-in config used when no file is found  |

> `fallback.toml` is a compile-time default, not a file you edit; edit
> `config.toml` (or add your own `.toml`) instead.

## File joining

- Every `.toml` file placed directly in `config/` is loaded automatically,
  sorted by name. Later files win on scalar conflicts.
- Files placed in **subdirectories** of `config/` (e.g. `config/themes/`) are
  ignored by the auto-loader. Pull them in explicitly from a top-level file:

  ```toml
  include = ["themes/akai.toml"]
  ```

- Sub-directories never auto-load; `include` is the only way to use them. This
  is what makes swap-able themes and separate keybind files convenient.

## Value formats

Most sizing knobs accept a `ScalableValue`: a percentage, or exact pixels.

| example    | meaning          |
| ---------- | ---------------- |
| `50%`      | percent of the relevant base (screen, bar, …) |
| `12px` / `12` | exact pixels       |

- Ratio knobs (e.g. `transparency`) additionally accept a plain `0.0–1.0`
  float. Mind the bare-`1` ambiguity rule: for these knobs `1` means **1%**,
  not 1.0 — write `1.0` or `100%` for fully opaque.
- Colors accept `"#RRGGBB"`, bare `RRGGBB`, or `0xRRGGBB`, quoted or not.
- Colors can also be built by **mixing** other colors with `+`, where the
  first operand carries the remaining weight:
  `primary_color +(weight:25%) secondary_color` = 75%/25%; a bare `+` is an
  50/50 split. Operands are hex values or palette variables
  (`primary_color`, `secondary_color`, `alternative_color`, `text_color`),
  and a palette variable may itself be declared as a mix or an alias of
  another one. Weights sit in 0-100 and their sum must not exceed 100. Since a
  bare `#` after the first token starts a comment, use quoted `"#RRGGBB"` or
  `0xRRGGBB` for a hex operand past the head.
- Strings (fonts, icons, formats) are normal TOML strings. `icons` accepts
  either a single string (split into characters) or an array of labels.
- Binds support **glob expansion**: `Mod+{1-4,Q,W,E,R}` expands into the full
  set of binds. Workspace-indexed actions get a `_N` suffix automatically.
- Bound commands may reference placeholders: `{kill}` is replaced by the
  `[binds] kill` value, and `{state}` in volume formats by `mute`/`unmute`.

## Sections

Run `config.toml` for the working example; this is the quick reference.

### `[tiling]`

Master-stack behavior (`global_layout`, `min_window_dim`, `layouts` list) plus
per-layout overrides in `[tiling.layouts.<name>]` (`count`, `side`, `width`,
`variants`, optional `indicator`). Window chrome lives in
`[tiling.aesthetics]` (`gap_width`, `border_width`, `border_focused`,
`border_unfocused`) — usually themed by the theme file.

### `[drag]`

`enabled` and `snap_distance` for the drag-and-drop placement behavior.

### `[workspaces]`

`count` — number of workspaces, 1–64.

### `[bar]`

Bar layout selects segments into left/center/right anchors:

```toml
[bar.layout.left]
segments = ["workspaces", "layout", "variants"]

[bar.layout.center]
segments = ["title"]

[bar.layout.right]
segments = ["clock"]
```

Available segments: `workspaces`, `title`, `clock`, `layout`, `variants`,
`batt`, `cpu`, `mem`, `volume`, `brightness`. A segment is compiled in only
when its `src/bar/modules/*` file (or, for a readout/control sub, its file in
`src/bar/modules/systatus/` or `src/bar/modules/slider/`) is present; the
above list is the full stock set.

Every systatus readout and slider control is its OWN segment — there is no
aggregate `systatus`/`slider` belt anymore. Each is selected, ordered, and
spaced independently through `segments`:
- readouts `batt`, `cpu`, `mem` (systatus; a readout absent on this machine —
  e.g. `batt` with no battery — renders nothing and takes no space);
- controls `volume`, `brightness` (slider; a control present only when its
  source file was dropped into the package directory).

Segment behavior knobs:

- `volume_format` / `volume_muted_format` — the volume slider's text.
  `{pct}` is the sink level (0–100); `{state}` is `mute`/`unmute`. Defaults:
  `"VOL {pct}%"` and `"MUTE"`.
- `brightness_format` — the brightness slider's text; `{pct}` is the level
  (0–100). Default: `"BRT {pct}%"`.
- `brightness_device` — optional sysfs device pin: a `backlight`-class name
  (`amdgpu_bl0`, …), or an `led:`-prefixed LED-class device (`led:kbd`).
  Default: the lexicographically smallest `backlight` device with a positive
  `max_brightness`.

  Brightness writes go straight to the sysfs node; when the node is root-only
  (no write policy), hana falls back to a throttled `brightnessctl` spawn.
  To make every commit a native, un-throttled write, install
  `contrib/udev/90-hana-backlight.rules` and add your user to the `video`
  group.
- `clock_format` (strftime), `drun_prompt`, `carousel_enabled`,
  `carousel_speed_px_s`, `indicator_*` and the appearance/color knobs
  (usually themed).

Per-segment accents live in `[bar.colors]` (`title`, `title_unfocused`,
`title_minimized`, `drun_bg`, `drun_fg`, `drun_prompt_color`). Any other key
`<segment>` is that segment's text color (e.g. `cpu = primary_color`), and
`<segment>_value` separately colors its numeric readout (the `42%` in
`Cpu 42%`), falling back to the segment text color when absent.

### `[binds]`

Key-to-action map. Actions include `toggle_layout`, `workspace`,
`move_to_workspace`, `toggle_tag`, `pin_window`, `all_workspaces`,
`toggle_floating_window`, `minimize_window`, `close_window`,
`toggle_bar_visibility`, `toggle_bar_position`, `reload` (hot config reload)
and `reload_hana` (re-exec). See the `[binds]` section of `config.toml`.

### Window rules

Class-to-workspace routing and floating admission, in three interchangeable
spellings:

```toml
[workspace.rules]
# numbered -> class list (1-based workspace)
1 = ["firefox", "Navigator"]
# class -> workspace
emacs = 6
# class -> float (admit floating on the current workspace)
calendar = "float"

[rules]
# top-level class rules, no workspace scope on the key's side
browser = 2

[workspace.rules.1]   # per-workspace sub-tables (workspace number in the key)
firefox = true
```

- Workspace numbers are 1-based in the file; a window matching a rule is
  admitted to that workspace.
- The string value `"float"` turns any of these into a **floating rule**: the
  window is admitted floating on the current workspace instead of being tiled.
- On float adoption, a window that already has a persisted restore record
  keeps its recorded geometry over the class rule.