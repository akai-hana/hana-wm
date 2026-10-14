---
description: Run hana's test suite through the isolated Xvfb wrapper
argument-hint: "[test-filter]"
---
Run hana's unit test suite:

```sh
dev/scripts/xtest.sh zig build test${1:+ -Dtest-filter=$1}
```

Never run a bare `zig build test` — it would hit the live X session and
silently skip the X-gated tests. If tests fail, diagnose with file:line,
fix, and re-run until green.
