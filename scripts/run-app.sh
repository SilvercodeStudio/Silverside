#!/bin/zsh
# Starts a built Silverside.app for make run, through Launch Services (open), never by running
# the executable inside it. An app started from a shell joins the shell's process coalition, and
# macOS takes the app for the owner of that coalition: after the app quits, the Dock can show it
# as running in the background, and its "Stop running in background" or Force Quit then ends
# every process in the coalition, tmux and the shells with it. Started by open, the app gets a
# coalition of its own.
#
#   scripts/run-app.sh path/to/Silverside.app [launch arguments]
#
# open does not pass this shell's environment on, so the SILVERSIDE_* variables (SILVERSIDE_SETTINGS,
# SILVERSIDE_LAME, and the others) go to the app with --env. Its output comes to this terminal,
# or, when there is none, to build/run.log. The script waits until the app quits; Control-C quits
# it too.
set -eu

app=${1:-}
[[ $app == *.app && -d $app ]] || { echo "run-app: no app at '$app'" >&2; exit 1; }
shift

flags=(-n -W)
for name in ${(k)parameters[(I)SILVERSIDE_*]}; do
    flags+=(--env "$name=${(P)name}")
done
if [[ -t 0 && -t 1 ]]; then
    out=$(tty)
else
    out=${0:A:h:h}/build/run.log
    mkdir -p ${out:h}
    : >$out
    echo "Output: $out"
fi
flags+=(--stdout $out --stderr $out)

# Control-C stops open's wait only, so it also ends this copy of the app (SIGTERM, as a plain
# process got it before): the copies of this build, and no other Silverside.
trap 'pkill -TERM -f "^${app}/Contents/MacOS/" || true' INT TERM

echo "Starting $app $*"
open $flags "$app" --args "$@"
