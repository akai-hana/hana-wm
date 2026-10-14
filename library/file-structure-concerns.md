Hello reader.

In this markdown note I'll write all my concerns about the current file/dir structure of hana's src/ codebase.

Be critical when reading these; don't just take them at face value, since they are just my thoughts and they might be wrong. Question the statements objectively, and agree when they're right and disagree when they're wrong, always formulating justifications either way.

Before starting anything, if you want to ask any follow-ups on any points, ask any questions and I shall respond with my thoughts.

---

src/core/

- This directory seems good at first glance. It is sorted into sub-directories, with the eponymous (core.zig) right in src/core/. No issues.

src/core/architecture/

- Having both a contract.zig and contract_x11.zig is confusing. Whatever this split meants to resolve, it still manages to leave confusion, so I'm thinking of changing something about these. model.zig looks good.

src/core/display/

- All good. usable_area.zig seems slightly suspicious as to whether it's the most correct split or naming, but I might be wrong.

src/core/loop/

- diag.zig's purpose is to do read-only logs? and that's it? why is this not part of log.zig? and why is this on loop? I have the same concerns with xtrace.zig: pure log/tracing concern, why isn't it just a part of log.zig?
- Why is reload.zig, a file that reloads the config, in src/core/loop and not on the same dir as config.zig? This doesn't make a lot of sense to me.
- Shouldn't grabs.zig be part of input.zig? Or is the current split right? What about the current location of grabs.zig?
- I don't fully understand the split between events.zig and timers.zig. Is the split really necessary? timer.zig is really short, so couldn't it just be merged onto events.zig?

src/core/proc/

- Is "persist.zig" really the most adequate filename? How about lifecycle.zig? And restart.zig?
- Does restart.zig genuinely belong here and not near config.zig? Just asking to be sure.
- I have no particular issuee with signals.zig, but just by reading the doc comment header, I wonder if this is the best possible implementation? "routes POSIX signals through a self-pipe so the event loop can dispatch them safely without signal-handler reentrancy" sounds kind of questionable: is there no simpler solution/implementation for this, to achieve the same ultimate purpose? Or am I just wrong?
- Should spawn.zig remaind a standalone codefile, ot would it be better to merge it with events.zig? Or something else?

src/core/pure/

- Is the dpi_math.zig-dpi.zig file separation really worth it, instead of merging them both together?
- Is there no way to simplify idmap.zig, or does it truly offer a valid solution implementation to what it achieves to do?
- The file header doc comment of ids.zig is really long and confusing for me, a reader who is skimming through the many codefiles of the codebase. The doc comment should not be confusing; i don't even know this file's purpose, so I can't provide my thoughts on this point. Please fix this.
- I believe paths.zig is a mixed bag of very small utilities that could just be in-lined on the respective codefiles that import it. Specially the common_dirs/common_paths part. I might be wrong, so I want to hear your thoughts. 
- There's a small naming inconsistency between log.zig and scaling.zig; for naming consistency's sake, I'd expect them both to be either log.zig/scale.zig or logging.zig/scaling.zig. Please decide on which one of the two is more adequate, or whether it should be kept this way (which i'm not really sure about keeping it this way, but if you have genuine good justification for it i can hear you out).
- If time.zig is only used for the clock.zig, shouldn't it be just merged to clock.zig? Or am I missing something?

src/core/x11/

- No issue with cursor.zig, but is there no way to simplify the codebase such that it isn't needed anymore? I've never seen any other window manager have a dedicated section to handle cursor theming, so I was just curious whether any simplifications for this sub-system were available.
- Shouldn't ledger.zig be part of model.zig?
- I get that masks.zig is a x11 concern, but having constants.zig and masks.zig in separate sub-directories feels kind of wrong. Maybe that's just my impression, but could you figure out any way to re-structure the src/core/ sub-directories so that they could be together, in a way that makes sense?
- reconcile.zig has a hilariously long doc comment. The first screenful of text is just purely the header doc comment. I'm not denying that the doc comment might be completely useless, but this definitely can't be the best way to approach this. Also, I can see reconcile.zig acts in cooperation with ledger.zig and grab.zig, but I still wonder if this is the best way to approach this specific part of the window manager. It just rubs me the wrong way to have 3 different codefiles to handle a single chain of actions. Model.zig itself I have no problem with since it represents a larger part of hana's architecture in its entirety, similar to contract.zig, but I think that the split chain of actions between reconcile-ledger-grab adds indirection at best. Having said that, is there no better way to handle these three codefiles and their interactions, or to improve them by doing any re-thinking, re-write or re-structuring of how this sub-system part of hana inherently works?
- Minor concerns with request.zig: it doesn't initially strike me as a codefile with a really strong motive in its reason of being separated. The doc comment header does seem logical, but it just strikes me as code logic that is its own codefile out of no other logical choice because of external elements, rather than a codefile that has a strong purpose and goal and justification for itself. Am I onto something here, or am I just plain wrong?
