Concerns related to src/window/. TO-DO item tasks:

- all codefiles under protocol/ seem unoptimal. look into this dir in particular, analyzing it thoroughly and extensively, and producing a final evaluation, along with suggestions for improvement, no matter how drastic these are; effort, risk, or backwards compatibility don't matter, only the best final codebase resulting does.

- query.zig seems really archaic. it also seems like it only is a facade, which doesn't stir much into me of its real practical usefulness standalone. look further into this, and into model as a whole, in order to reach a conclusion.

- wincache.zig holds window title information. should it live somewhere in bar, inside or next to title.zig/carousel.zig? doesn't feel like it belongs here.
