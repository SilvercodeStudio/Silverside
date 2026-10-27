#!/bin/sh
# Prints the Git commit that the working tree is at, abbreviated, with "-dirty" when the tree
# has changes that are not committed (new files too). Prints nothing outside a Git checkout.
# The app's build (a script phase) and the Makefile's CLI builds record it; see SilversideVersion.
cd "$(dirname "$0")/.." || exit 0
commit=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
[ -z "$(git status --porcelain 2>/dev/null)" ] || commit="$commit-dirty"
printf '%s\n' "$commit"
