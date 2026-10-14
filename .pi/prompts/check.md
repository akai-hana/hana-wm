---
description: "Fast local gate: format check + type-check + layer guards"
---
Run the fast local gate and fix anything it reports:

```sh
zig fmt --check .
zig build check
```

`zig build check` enforces the layer guards (model/tiling/config stay xcb-free,
XCB mutation behind the reconcile boundary), type-checks, and compiles
`dev/plugin-template/` against the current contracts. Keep changes to `src/`
`zig fmt` clean. Never "fix" a layer-guard violation by weakening the guard —
move the code to the correct side of the boundary instead.
