#!/bin/bash

max=250

while true; do
    yes y | git-rewrite-commits --provider ollama --model hf.co/noctrex/Qwopus3.5-9B-Coder-MTP \
        --template "feat\(scope\): message" \
        --max-commits "$max"

    git push --force-with-lease
    max=$((max + 1))
done
