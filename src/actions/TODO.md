Concerns related to src/actions/. TO-DO item tasks:

- ws.zig is a split from what should be workspaces.zig logic. fold logic into workspaces.zig.

- parked.zig is also a split from what should be inside minimize.zig. fold.

- I feel like geometry.zig is a mixed bag that does actions related to many different systems and sub-systems, and i believe instead that all these different segments of logic should belong to their respective codefiles/systems. look into a viable merge and plan it out.

- difference between manage.zig and lifecycle.zig? Why are these separated?

- covering.zig seems to split from fullscreen.zig. please fold.

- actions.zig also seems to mix various different concerns and ends up being really structurally messy. look into architectural alternatives and resolve.
