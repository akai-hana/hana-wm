# Hana Architecture - Component Reference (Post Phase 5)

# CORE LAYER

## Architecture Contracts
- contract.zig - Unified plugin contracts: WindowModule, Layout, Segment, Surfaces, KeyPressEvent (opaque). Pure - no XCB imports. Single vocabulary file.
- model.zig - Single source of truth for WM state. Contains: Window, Workspace, LayoutParams, Entry (mask, anchor, presence, covering_ws), Rect, Margins. Pure, allocator-free, XCB-free.

## Core Pure Utilities (core/pure/*)
- ids.zig - WindowId (u32), WorkspaceId (struct{index:u8}), bit operations
- bounded.zig - BoundedList, Store (sorted-key map, fixed capacity)
- log.zig - Logging + WindowedProfiler (latency tests)
- masks.zig - Modifier/event masks, X protocol literals (no XCB)
- time.zig - Monotonic timing
- paths.zig - XDG path resolution
- scaling.zig, constants.zig, time.zig

## Display Policy
- dpi.zig - DPI detection (RandR + RESOURCE_MANAGER), scaling helpers
- hz.zig - RandR refresh-rate detection, drives carousel frame pacing
- usable_area.zig - Work-area ledger (bar struts, window edge claims)

## Process Management (Phase 5 consolidated)
- core/proc/session.zig - Session persistence (serialize model -> JSON, deserialize on restore)
- core/proc/process.zig - Process lifecycle (signals, reload flag, re-exec coordinator)

## X11 Layer (IMPURE - only place XCB allowed)
- core/x11/plan.zig - Reconciliation planner: unconditional compute, delta send against sent ledger
- core/x11/dispatch.zig - Dispatch sink (vtable: map, geom, border, park, stack, flush, grab/ungrab)
- core/x11/requests.zig - Raw XCB primitives (configure, map, raise, border, grab, properties)
- core/x11/atoms.zig - Atom cache (batched intern, cached lookups)
- core/x11/xcb.zig - Single @cImport site (xcb.h, randr.h, xkb.h)

### Event Loop
- core/loop/pipeline.zig - Model owner + reconcile choke point. Owns Model, builds Plan.Ctx, grabScoped()/reconcileGraveFocus().
- core/loop/events.zig - Event loop + dispatch + config reload + timer wheel.
- core/loop/seed.zig - Config -> model seeding (template + overrides).

---

## INPUT LAYER
- input/input.zig - Keyboard/mouse handling, keybind dispatch map, chrome overlay first-refusal
- input/keybind.zig - Keysym->keycode resolution + (mods<<32|keysym)->Action dispatch map
- input/mouse.zig - Mouse intake (button/motion, drag routing to floating)
- input/keysyms.zig - Pure keysym<->name parsing (used by config)
- input/keymap.zig - X-free keymap utilities (xkb_keymap -> flat keycode->keysym table)
- input/xkbcommon.zig - XKB state machine (keymap, retries, auto-repeat, mapping-change rebuild)

---

## ACTIONS HUB
- actions/actions.zig - Action hub (6 groups): minimize/restore*, cycleLayoutKind/stepVariantDir/primary/*, moveWindowTo/tagToggle/pinToggle/allViewToggle/switchTo, mapRequest/focusAfterGeometry/unmanage, fullscreenToggleWindow/fullscreenSetWindow, toggleFloating + drag family, viewportStep, dumpState
- actions/layout_params.zig - Layout cycling, variant stepping, primary adjust, swap, config->model seeding
- actions/geometry.zig - Floating drag, move, viewport, toggle floating
- actions/ws.zig - Workspace actions (move, tag, pin, all-view, switch)
- actions/manage.zig - Map/unmap, focus after geometry, unmanage
- actions/parked.zig - Minimize/restore (LIFO/FIFO)
- actions/covering.zig - Fullscreen toggle/set/move

---

## WINDOW LAYER
- window/window.zig - Client lifecycle facade (admission, geometry, events, WM_PROTOCOLS)
- window/admission.zig - Placement + session adoption (rules map, spawn queue, 5-cookie pipeline)
- window/query.zig - Read facade (registry mapping XID->model entry, WS predicates)
- window/protocol/icccm.zig - ICCCM/EWMH properties, focus delivery modes, WM_DELETE_WINDOW
- window/protocol/borders.zig - Border reload + color resolution
- window/protocol/focus.zig - Two-phase focus (prepare/apply), suppress during tiling
- window/protocol/wincache.zig - Metadata cache (name/class/icon), populated at admission
- window/modules/floating.zig - Floating mode (drag, work-area anchoring)
- window/modules/fullscreen.zig - Fullscreen covering (hide bar, cross-WS ownership)
- window/modules/minimize.zig - Self-contained parked store (LIFO/FIFO)
- window/modules/workspaces.zig - Tag transitions (send/add/remove/pin/all-view)

---

## BAR LAYER (Phase 3 Flattened)
- bar/bar.zig - Orchestrator (layout pass, click dispatch, damage model)
- bar/render.zig - Unified render (when + where + text)
- bar/frame.zig - Live state collection (model/query/title cache -> DrawCtx)
- bar/surface.zig - X surface (pixmap + cairo, visual/depth resolution)
- bar/drawing.zig - Render logic (Cairo/Pango, text, blit)
- bar/fonts.zig - Pango font book (layout, metrics, Xft->Pango)
- bar/segment.zig - Segment vocab + builder (vocab, DrawCtx, Frame, builder)
- bar/visibility.zig - Visibility policy + wire (fullscreen, workspace, prompt)
- bar/win.zig - Bar window lifecycle (create, props, struts, atoms)

Bar Modules:
- clock.zig - Self-ticking clock, display modes
- tags.zig - Workspace tags (icons, click->switch)
- layout.zig - Active tiling layout icon
- variants.zig - Active layout variant string
- systatus/systatus.zig - Orchestrates readouts registry
- systatus/batt.zig - Battery (sysfs)
- systatus/cpu.zig - CPU usage (/proc/stat)
- ram.zig - RAM usage (MemTotal/Available)
- title/title.zig - Title segment + inline prompt overlay
- title/carousel.zig - Marquee scroller (Hz-locked)
- prompt/prompt.zig - Inline prompt (editor, completion, spawn)
- prompt/vim.zig - Vi-style editing addon
- slider/slider.zig - Slider orchestrator (throttle, preview/commit/apply)
- slider/brightness.zig - Backlight (sysfs/brightnessctl)
- slider/volume.zig - Volume (Pulse/ALSA/spawn)
- slider/native_alsa.zig - ALSA mixer ioctls
- slider/native_pulse.zig - libpulse dlopen
- slider/level.zig - Slot<->level mapping
- slider/shell.zig - Slider interaction shell (throttle, drag)

---

## CONFIG LAYER
- config/config.zig - Facade (load, validate, reload, snapshot)
- config/types.zig - Config types + defaults (Action, Keybind, TilingConfig, BarConfig)
- config/action.zig - Action union + Dir/SwapMode/RestoreOrder vocab
- config/parse/parser.zig - Tokenizer + interpreter (TOML-ish)
- config/parse/document.zig - Document/Section/Value model + merge
- config/parse/schema.zig - Comptime knob table + reflection engine
- config/parse/color.zig - Color parsing + palette + mix
- config/parse/bar_properties.zig - [bar.properties] decoder
- config/sections/binds.zig - [binds] section parser
- config/sections/rules.zig - [rules] section parser
- config/sections/bar_sections.zig - [bar] section parser
- config/sections/tiling_sections.zig - [tiling] section parser
- config/vocab/action_names.zig - Action name<->enum mapping
- config/vocab/layout_names.zig - Layout name<->canonical mapping
- config/parse/bar_properties.zig - [bar.properties] decoder
- config/source/discover.zig - Config file discovery (XDG + fallback)
- config/source/fallback.zig - Embedded fallback TOML
- config/persist/snapshot.zig - Snapshot (freeze config for re-exec)

---

## TILING ENGINE
- tiling/tiling.zig - Dispatch engine + geometry helpers + registry dispatch
- tiling/modules/master.zig - Master-stack + overflow grid
- tiling/modules/monocle.zig - Monocle (fullscreen stack)
- tiling/modules/grid.zig - Equal cells (rigid/relaxed)
- tiling/modules/fibonacci.zig - Spiral layout
- tiling/modules/leaf.zig - BSP bisection
- tiling/modules/scroll.zig - Horizontal scrollable strip

---

## KEY DATA FLOWS

Input -> Actions -> (Window, Bar, Tiling)
Window -> Actions, Admission, Query, Focus, Borders, Wincache, Floating, Fullscreen, Minimize, Workspaces
Bar -> Render, Frame, Segment, Visibility, Win
Render -> Surface, Fonts, Drawing
Drawing -> Bindings, Fonts
Segment -> Contract
Visibility -> Bar, Fullscreen
Tiling -> Contract, Model
Config -> Model, Tiling, Actions, Bar
Input -> Actions, Keybind, Mouse
Actions -> Model, Pipeline, Focus, Query, Admission, Window, Tiling, Bar
Window -> Actions, Admission, Query, ICCCM, Borders, Focus, Wincache, Floating, Fullscreen, Minimize, Workspaces
Fullscreen -> Actions, Bar
Config -> Model, Tiling, Actions, Bar
Input -> Actions, Keybind, Mouse
Actions -> Model, Pipeline, Focus, Query, Admission, Window, Tiling, Bar
Window -> Actions, Admission, Query, ICCCM, Borders, Focus, Wincache, Floating, Fullscreen, Minimize, Workspaces
Fullscreen -> Actions, Bar
Config -> Model, Tiling, Actions, Bar
Input -> Actions, Keybind, Mouse
Actions -> Model, Pipeline, Focus, Query, Admission, Window, Tiling, Bar

---

## KEY ARCHITECTURAL RULES

1. **contract.zig is PURE** - No XCB imports. X-typed vocabulary (KeyPressEvent, Surfaces) lives here.
2. **X11 only in core/x11/** - Enforced by check-layers.sh Rule 1-3
3. **Model is single writer** - All state mutations through model.zig
4. **Reconcile = recompute + delta** - Plan computes desired state, dispatch sends delta
5. **contract.zig is the plugin seam** - WindowModule, Layout, Segment, Surfaces all defined here
6. **Build-generated registries** - window_modules, tiling_modules, bar_modules, *_subs auto-generated from modules/ directories
5. **Deletion modularity** - Delete a modules/ file -> feature gone, still compiles
6. **Bar flattened (Phase 3)** - 8 render files -> 3 (render.zig, frame.zig, surface.zig)

---

## FILES BY LAYER (for manual diagram)

| Layer | Files |
|-------|-------|
| **Core** | contract.zig, model.zig, pure/*, display/*, proc/session.zig, proc/process.zig, x11/plan.zig, x11/dispatch.zig, x11/requests.zig, x11/atoms.zig, x11/xcb.zig, loop/pipeline.zig, loop/events.zig, loop/seed.zig |
| **Input** | input/input.zig, keybind.zig, mouse.zig, keysyms.zig, keymap.zig, xkbcommon.zig |
| **Actions** | actions.zig, layout_params.zig, geometry.zig, ws.zig, manage.zig, parked.zig, covering.zig |
| **Window** | window.zig, admission.zig, query.zig, protocol/icccm.zig, protocol/borders.zig, protocol/focus.zig, protocol/wincache.zig, modules/floating.zig, modules/fullscreen.zig, modules/minimize.zig, modules/workspaces.zig |
| **Bar** | bar.zig, render.zig, frame.zig, surface.zig, drawing.zig, fonts.zig, segment.zig, visibility.zig, win.zig, modules/clock.zig, modules/tags.zig, modules/layout.zig, modules/variants.zig, modules/systatus/*.zig, modules/title/*.zig, modules/prompt/*.zig, modules/slider/*.zig |
| **Config** | config.zig, types.zig, action.zig, parse/parser.zig, parse/document.zig, parse/schema.zig, parse/color.zig, parse/bar_properties.zig, sections/binds.zig, sections/rules.zig, sections/bar_sections.zig, sections/tiling_sections.zig, vocab/action_names.zig, vocab/layout_names.zig, parse/bar_properties.zig, source/discover.zig, source/fallback.zig, persist/snapshot.zig |
| **Tiling** | tiling.zig, modules/master.zig, modules/monocle.zig, modules/grid.zig, modules/fibonacci.zig, modules/leaf.zig, modules/scroll.zig |
