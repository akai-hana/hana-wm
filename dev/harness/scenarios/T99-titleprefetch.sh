# T99 - title prefetch timing: spawn many windows sequentially so each
# window-count change forces a batched title/geometry refetch.
spawn_client A
spawn_client B
spawn_client C
spawn_client D
spawn_client E
spawn_client F
spawn_client G
spawn_client H
spawn_client I
spawn_client J
spawn_client K
spawn_client L
spawn_client M
spawn_client N
spawn_client O
settle 1000
# Now rapidly create+destroy to hammer the prefetch.
spawn_client P
spawn_client Q
spawn_client R
settle 1000
