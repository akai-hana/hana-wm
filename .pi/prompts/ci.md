---
description: Replicate hana's CI locally (fmt, tests, layer guards, build)
---
Replicate hana's CI on this machine, in order, and fix failures as you go:

1. `zig fmt --check src`
2. `dev/scripts/xtest.sh zig build test` (isolated Xvfb — never bare)
3. `zig build check` (type-check + layer guards)
4. `zig build` (Debug build must succeed)

Report each step's result. Only mention the modularity matrix
(`dev/scripts/check-modularity.sh`) if the change touched build wiring or
deleted/moved source files; it is heavy (~31 cold builds) and not part of the
default gate.
