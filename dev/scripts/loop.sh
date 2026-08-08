#!/bin/bash

max=250

while true; do
    yes y | git-rewrite-commits --provider ollama --model hf.co/KevinJK51/Qwen3.6-12B-IQ-Ultra-Heretic-Uncensored-Thinking-V2-Hightop-GGUF:IQ4_NL \
        --template "feat\(scope\): message" \
        --max-commits $max

    git push --force-with-lease
    max=$((max + 1))
done
