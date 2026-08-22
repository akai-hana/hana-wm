# S05 — restore-all: three minimized, then unminimize_all partition/LIFO focus.
spawn_client A
spawn_client B
spawn_client C
key super+t; settle 250   # minimize newest
key super+t; settle 250   # minimize next focus fallback
key super+t; settle 250   # minimize last visible
dump all-minimized
state_dump
key super+shift+alt+t     # unminimize_all
settle 600
dump all-restored
state_dump
