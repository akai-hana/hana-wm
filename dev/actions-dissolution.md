# Dissolving `src/actions/` — plan of record and execution status

**Status: EXECUTED** (2026-10-12). `src/actions/` no longer exists; `src/DONE`
marks completion.

> Provenance note. The working copy of the plan lived at `src/actions/PLAN.md`
> and was **untracked** — it was never committed. Deleting `src/actions/` with
> the action sources therefore removed it too. This file is the reconstructed
> plan of record plus the deviations taken during execution and the
> verification results. Nothing here is aspirational: every destination below
> is what the tree actually contains now.

## Goal

No central action layer. Every user-facing command (`types.Action`'s dispatch
targets) moves into the module that owns the state it writes. The core reaches
each command the same way it already reached every other optional-module
capability: through a `contract.WindowModule` hook resolved by the generated
registry. Deleting an optional module drops its commands along with its state,
and the tree still compiles.

## Destinations (as executed)

| Deleted file | Went to |
|---|---|
| `ws.zig` (switch / move / tag / pin / all-view) | `src/window/modules/workspaces.zig` |
| `covering.zig` (enter/exit/switch covering transition) | `src/window/modules/fullscreen.zig` |
| `parked.zig` (hide / restore family) | `src/window/modules/minimize.zig` |
| `geometry.zig` `toggleFloating` + `repairStrandedHome` | `src/window/modules/floating.zig` |
| `geometry.zig` drag wrappers (`startDrag`/`stopDrag`/`updateDrag`/`isDragging`/`isResizingWindow`/`getDragLastRect`/`cancelDragForWindow`) | **deleted** — call sites dispatch through `window.dispatchAll` / `window.dispatchFirstTrue` / `registry.providerOf` directly; the floating module already bound every one of these hooks |
| `geometry.zig` `moveFocused`, the viewport family and every layout-parameter transition | `src/window/sync/reconcile_tails.zig` (see deviation 1) |
| `layout_params.zig` (cycle/variant/primary/swap/balance) | `src/window/sync/reconcile_tails.zig` (see deviation 1) |
| `manage.zig` `mapRequest`, `focusAfterGeometry` | `src/window/admission.zig` |
| `manage.zig` `unmanage` | `src/window/window.zig` |
| `actions.zig` `retile` / `retileWithFallback` | `src/window/sync/reconcile_tails.zig` |
| `actions.zig` `focusFallback` / `prepareAndSetFocus` | `src/window/protocol/focus.zig` |
| `actions.zig` `isMinimizedOnAnyWs`, `currentCoveringOccupant` | `src/window/registry.zig` (named reads over `callHookBool` / `providerOf`) |
| `actions.zig` `dumpState` | `src/window/window.zig` |

`reconcile_tails.zig` lives under `src/window/sync/` beside `reconcile.zig`,
because it is one model transition plus one reconcile entry — the same shape
the reconcile layer already owns.

## How the core reaches a command

Twelve new hooks on `contract.WindowModule`, all listed in
`single_binder_hooks`:

| Hook | Bound by |
|---|---|
| `switchWorkspace`, `moveToWorkspace`, `toggleTag`, `pinWindow`, `allWorkspaces` | `workspaces` |
| `toggleFullscreenWindow`, `setFullscreenWindow` | `fullscreen` |
| `minimizeWindow`, `unminimize`, `unminimizeOrdered`, `unminimizeAll` | `minimize` |
| `toggleFloatingWindow` | `floating` |

Command hooks take no `*model.Model`: the command resolves the live model
through the pipeline itself, which is what makes it a command rather than a
model transition.

Always-present transitions (`reconcile_tails.*`, `admission.mapRequest`,
`window.unmanage` / `window.dumpState`, `focus.focusFallback`) are reached
directly — they name no optional module, so there is nothing to unbind.

`window.zig` stays the stable external facade: it re-exports the registry
wrappers, the two named reads, and the always-present command surface, so
`core/input`, `bar/*` and the tests never import an owning module by name.
Inside `src/window/**`, callers import `registry` directly.

## Deviations from the original plan, and why

1. **Layout-parameter commands and `moveFocused` are NOT under `src/tiling/`.**
   `build.zig`'s `assertPureLayerImports` forbids `src/tiling/**` from
   importing anything but the pure shelf, `model`, `domain` and `tiling_contract`;
   `check-layers.sh` Rule 3 sweeps `src/tiling` for any `xcb` token. Each of
   these commands reaches `pipeline.reconcileGrab` (a server grab), so none of
   them can sit in the pure layer. They live in
   `src/window/sync/reconcile_tails.zig` and still reach the tiling ENGINE
   through the build-generated `tiling_seam`, never by naming `src/tiling/`.
   A tree without the tiling subsystem keeps compiling behind the existing
   `has_tiling` gates.

2. **The viewport family did not move to `floating.zig`.** It is a tiling-layout
   concern (slot width and max offset come from the layout metadata), and
   putting it in the optional floating module would drop `scroll_view` in a
   tiling-without-floating tree. It rides with the other layout-parameter
   transitions in `reconcile_tails.zig`.

3. **`toggle_floating_window` now dies with `floating.zig`.** The old
   `geometry.toggleFloating` was a model edit that worked without the floating
   module; after the move it is a hook, so a tree with no floating module has
   no binder and the command no-ops. That is the rule the plan itself sets for
   optional modules ("deleting a module's file drops the feature"), and the
   modularity matrix only requires the tree to compile.

4. **`src/test/window/actions_test.zig` keeps its stem, and its build gate
   widened** to `tiling, floating, minimize, workspaces`. The file tests the
   `types.Action` command surface, which still exists; the `actions` PRODUCTION
   module stem is gone (`zig build modules` lists `action`, `action_names` and
   `actions_test`, and no `actions`). The gate now names exactly the features
   the file's direct module imports make necessary, so a feature-stripped build
   skips the file instead of failing assertions against a module that is not
   compiled in.

## Invariants preserved

- Model focus and protocol focus stay paired: every command that moves focus
  commits a `focus.FocusTransition` prepared *before* the model write, so a
  `no_input` window can never take model focus.
- `prepareAndSetFocus` / `focusFallback` are the only places that pair a model
  focus write with its prepare; both now live in `focus.zig`, next to the
  transition type they return.
- Covering commands still classify before mutating, arm the deferred bar
  show/hide inside the grab, and bump the fullscreen fact on exit.
- `mapRequest` keeps geometry-before-focus (`.after` order) so a freshly
  spawned window is mapped before `xcb_set_input_focus` targets it.
- No production file `@import()`s `workspaces`, `fullscreen`, `minimize` or
  `floating`; only tests do, and only behind a `build-gate` that guarantees the
  module is compiled in.

## Verification

| Gate | Result |
|---|---|
| `zig fmt --check .` | clean |
| `zig build` | builds |
| `zig build check` (type-check + `check-layers.sh` + plugin-template) | pass |
| `zig build modules` | no `actions` / `ws` / `covering` / `parked` / `geometry` / `manage` / `layout_params` production stems |
| `dev/scripts/xtest.sh zig build test` | 600 pass, 0 fail, 9 skip |
| `dev/scripts/check-modularity.sh -j 4` | 31 passed, 0 failed (every tier, including `fullscreen`, `minimize`, `workspaces`, `floating` and `tiling` single-module deletion) |

Targeted re-runs after the move (all through `xtest.sh`):
`actions_test` 13 pass, `pipeline_test` 8 pass, `ewmh_test` 9 pass,
`workspaces_test` 9 pass, `minimize_test` 11 pass, `fullscreen_test` 9 pass,
`floating_test` 2 pass.
