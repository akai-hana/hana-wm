# hana configuration

hana's configuration is a `config.toml` living inside `config/`, plus every
file that file pulls in with `include`. There is no schema duty: every file
is parsed with hana's own TOML parser, so malformed values are either
warned-and-ignored or rejected while keeping the previous config in memory.

Sections follow the build: each optional subsystem ships a `*_config.zig`
fragment next to its code, and the binary only parses the sections owned by
the fragments it was compiled with. A `[tiling]` key in a bar-only build (or
any section whose owning subsystem was deleted from the tree) is simply
unrecognized — warned about like any unknown section and ignored. The
embedded fallback config is pre-filtered the same way, so a minimal build
boots silently with no inert-section noise.

The stock split (arbitrary, and entirely up to you):

| file                 | role                                        |
| -------------------- | ------------------------------------------- |
| `config.toml`        | the entry file: functional behavior, bar, rules |
| `binds.toml`         | keybindings, incl. personal program binds (via `include`) |
| `themes/akai.toml`   | visual palette & appearance (via `include`) |
| `fallback.toml`      | built-in config used when no file is found  |

> `fallback.toml` is a compile-time default, not a file you edit; edit
> `config.toml` (or add your own `.toml`) instead.

## File joining

- `config.toml` is the **only** file a config directory loads on its own.
  Every other top-level `.toml` is inert — and reported as a warning —
  until `config.toml` names it:

  ```toml
  include = ["binds.toml", "themes/akai.toml"]
  ```

- `include` is a root-level key, so it has to sit above the first table
  header. Files merge in list order, after `config.toml` itself: later files
  win on scalar conflicts, arrays accumulate.
- Sub-directories are never read on their own; `include` is the only way to
  reach them (`themes/akai.toml`), resolved one level deep — an included
  file's own `include` is ignored.
- This is what makes swap-able themes and separate keybind files convenient:
  change what loads in one place, without moving any file around.
- A directory with `.toml` files but no `config.toml` is skipped as a config
  source entirely (the search moves on) and says so, rather than booting
  whatever location answers next without a word.

## Value formats

Most sizing knobs accept a `ScalableValue`: a percentage, or a bare number of
exact pixels.

| example    | meaning          |
| ---------- | ---------------- |
| `50%`      | percent of the relevant base (screen, bar, …) |
| `12`       | exact pixels (a bare number IS the pixel value; no `px` suffix is parsed) |

- Ratio knobs additionally accept a plain `0.0–1.0` float.
  `indicator_padding` also reads bare integers as percentages
  (0-100) — mind the bare-`1` rule: `1` means **1%**, not 1.0.
  `transparency` is stricter: bare integers are rejected (warned
  and ignored), so write `0.5` or `50%`; `1.0` or `100%` is
  fully opaque.
- Colors accept `"#RRGGBB"`, `#RRGGBB`, or `0xRRGGBB`, quoted or not. A bare
  all-digit spelling is hex too when it has exactly 6 (`RRGGBB`) or 8
  (`RRGGBBAA`) digits — e.g. `112233` reads as `0x112233`; any other bare
  number in a color slot is invalid (never silently coerced to a decimal
  color).
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
- A bind value may be an **array of actions**: commas run actions sequentially
  (`[a, b]` = a then b), and `+` groups actions into a parallel batch
  (`b + c` = b and c together). Mixed lists compose: `[a, b + c, d]` runs a,
  then b and c as one batch, then d. A `+` only splits when whitespace
  touches it, so literal plus signs in commands (`xdotool key ctrl+plus`)
  survive intact. The WM is single-threaded: a "parallel" batch is dispatched
  before the next step runs, sync actions completing back-to-back and `exec`
  children running as concurrent processes. One caveat: an `exec` step inside
  a **comma sequence** is run synchronously — the WM blocks until the command
  exits, so avoid long-running commands there. That wait is deadline-capped
  (`spawn.sync_exec_timeout_ms`, default 5 s): a wedged command is killed and
  logged rather than freezing hana, and the parser warns at load time for any
  bind that routes a command through this blocking path.

## Sections

Run `config.toml` for the working example; this is the quick reference.

### `[tiling]`

Master-stack behavior (`global_layout`, `min_window_dim`, `layouts` list) plus
per-layout overrides. A `[tiling.layouts.<name>]` table carries that layout's
`variants` string; the master family additionally accepts `count`, `side`, and
`width` under `[tiling.layouts.master-stack]`, and per-workspace count
overrides under `[tiling.layouts.master-stack.counts]` (1-based workspace =
count; only meaningful with `global_layout = false`). Window chrome
(`gap_width`, `border_width`, `border_focused`, `border_unfocused`)
lives in `[tiling]` itself — usually themed by the theme file.

### `[drag]`

`snap_distance` for the drag-and-drop placement behavior.

### `[fullscreen]`

No keys: the fullscreen feature's presence is decided at build time
(module `fullscreen`), not by config.

### `[workspaces]`

`count` — number of workspaces, 1–64. Also accepted under the alias
section `[bar.modules.workspaces]`.

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
`batt`, `cpu`, `ram`, `volume`, `brightness`. A segment is compiled in only
when its `src/bar/modules/*` file (or, for a readout/control sub, its file in
`src/bar/modules/systatus/` or `src/bar/modules/slider/`) is present; the
above list is the full stock set.

Every systatus readout and slider control is its OWN segment — there is no
aggregate `systatus`/`slider` belt anymore. Each is selected, ordered, and
spaced independently through `segments`:
- readouts `batt`, `cpu`, `ram` (systatus; a readout absent on this machine —
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
- `clock_format` (strftime), `run_prompt`, `carousel_enabled`,
  `carousel_speed_px_s`, `indicator_*` and the appearance/color knobs
  (usually themed).
- `carousel_gap_px` — pixels of blank space between repeats of a scrolling
  title. Default: `48`.
- `systatus_interval_ms` — how often the systatus readouts (`batt`, `cpu`,
  `ram`) poll their source while present. Default: `2000`; a readout that
  goes absent still backs off to its own slower re-probe. Minimum `250`.
- `volume_read_interval_ms` — how often the volume control polls the sink
  (this is also the cadence that corrects an optimistic drag commit if the
  daemon disagreed with it). Default: `5000`. Minimum `250`.
- `max_batched_redraws` — an internal safety cap: how many redraw passes one
  batch of events may run while modules settle their layouts. Raising it
  lets unusually deep layout cascades finish inside one batch; lowering it
  to `1` trades that for earlier batching. Default: `4` (range `1`–`64`).
- Selected workspace tag: `selected_fg` colors the current tag's **icon text**
  and `selected_indicator_color` colors its **indicator glyph** independently
  (unset follows `indicator_color`, then the tag's text color). The selected
  tag's text styling uses the same composite format as any segment -- see the
  `workspaces`/`workspaces_selected` entries below.

Per-segment accents live in `[bar.properties]` (`title`, `title_unfocused`,
`title_minimized`, `run_bg`, `run_fg`, `run_prompt_color`). The older
`drun_prompt`, `drun_bg`, `drun_fg` and `drun_prompt_color` spellings are
still accepted as aliases for the same settings. Any other key
`<segment>` is that segment's text color and/or style: the first color-carrying
item (`cpu = primary_color`) sets the text color and trailing
`underline`/`bold`/`italic` flags set its style, e.g.
`volume = #ff0000 underline bold` or a style-only `clock = underline`.
A bare flag means `true`; `name=bool` and `name=0|1` spellings work too.
A `size=N` token pins the segment's text to an absolute pixel size (1–255),
overriding the configured font size for that segment alone, e.g.
`cpu = #ff0000 size=14`. A `<segment>_value` key is color-only and separately
colors its numeric
readout (the `42%` in `CPU 42%`), falling back to the segment text color when
absent.

Workspace tags take two of these composite keys: `workspaces` styles **every**
tag (the first color-carrying item colors all the unselected icons), and
`workspaces_selected` is a per-state overlay applied on top for the **current**
tag in the same format -- e.g. `workspaces_selected = bold` bolds only the
selected icon, or `workspaces_selected = #ff0000 bold` recolors and bolds it.
The selected tag's text falls back to `selected_fg`; the rest to the bar-wide
`fg`.

### `[binds]`

Key-to-action map. Actions include `toggle_layout`, `workspace`,
`move_to_workspace`, `toggle_tag`, `pin_window`, `all_workspaces`,
`toggle_floating_window`, `minimize_window`, `close_window`,
`toggle_bar_visibility`, `toggle_bar_position`, `reload_config` (hot config reload)
and `reload_hana` (re-exec). See the `[binds]` section of `binds.toml`.

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
