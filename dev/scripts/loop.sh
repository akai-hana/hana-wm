#!/bin/bash
# Destructive rewrite loop: each pass rewrites commit history with an LLM and
# force-pushes it. Deliberately demands an explicit opt-in flag so a stray run
# cannot clobber shared history.

[ "$1" = "--yes-i-know" ] || { echo "Refusing: pass --yes-i-know to run this destructive force-push loop." >&2; exit 1; }

max=250

while true; do
    yes y | git-rewrite-commits --provider ollama --model hf.co/noctrex/Qwopus3.5-9B-Coder-MTP \
        --template "feat\(scope\): message" \
        --max-commits "$max"

    git push --force-with-lease
    max=$((max + 1))
done
