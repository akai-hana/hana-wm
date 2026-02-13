#!/bin/sh
# Prints an entire repo's commit history into a file.
# Shows commit tag, message, and diff file within brackets.

git log -p --pretty=format:"%h%nCOMMIT MESSAGE: %B%n----" | sed '/^diff --git/d; /^---/d; /^+++/d; /^new file mode/d; /^Binary files/d; /^index/d' | awk '/^[0-9a-f]+$/ {print "COMMIT TAG: " $0; print "{"; next} /^----/ {print "}"; print; next} 1' > full_history.txt
