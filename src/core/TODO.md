Concerns related to src/core/. TO-DO item tasks:

- fold time.zig and paths.zig into its importers. sizes are way too low to justify keeping them as individual codefiles.

- make log.zig a module, and detach the latency profiling logic to a new codefile called "profile.zig"

- rename xtrace.zig to trace.zig, make trace.zig a module, and create a new directory under core modules where log.zig, profile.zig and trace.zig should live, called "debug/".

- fold masks.zig into input.zig.

- fold ids.zig into workspaces.zig

- fold every constant on constants.zig into its respective importers.

- fold dpi_math.zig into dpi.zig

- contract_x11.zig is a workaround to contract keeping check-layers.sh in check. find a real solution that doesn't involve this workaround, which causes a contract split in half as a consequence.

- move reload.zig somewhere into src/config/.

- seed.zig should be either next to model.zig or inside src/config/. Find the better place and move it there. Right now it is isolated and its placement doesn't really make sense.

- reload.zig, seed.zig, and handoff.zig all have really similar purposes. figure if their split is really justified, or if there's a way to merge them, or fundamentally modify how hana's architecture works, in order to refactor-dissolve these files, or to reach a more manageable architecture, structurally speaking, instead of the current 3-way file split.

- fold spawn.zig into prompt.zig

- plan.zig and reconcile.zig seem duplicated. Make sure that this is the case, and if it is, de-duplicate this.
