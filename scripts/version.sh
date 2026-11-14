#!/bin/sh
# The version of Silverside, kept in two files that the builds read: MARKETING_VERSION in the
# app's project (its Debug and Release lines; CFBundleVersion is $(MARKETING_VERSION) too), and
# SilversideVersion.string in the engine (the CLI and the User-Agent). Neither build can read the
# other's, so this script changes both, and make lint checks that they agree. The website and
# CHANGELOG.md name the released version, which scripts/release.sh writes.
#
#   scripts/version.sh             print the version (it fails if the two files disagree)
#   scripts/version.sh check       the same, printing nothing when they agree
#   scripts/version.sh set 0.9.8   change the version in both files
#   scripts/version.sh next [0.9.8]  start the next version after a release: set it (by default,
#                                  the last part raised by one), and add its heading,
#                                  "## 0.9.8 (not released yet)", to CHANGELOG.md
set -eu

cd "$(dirname "$0")/.."
PROJECT=App/Silverside.xcodeproj/project.pbxproj
ENGINE=SilversideKit/Sources/SilversideKit/WebClient.swift

die() {
    echo "version.sh: $*" >&2
    exit 1
}

# Each version that a file declares, one a line.
project_versions() { sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);$/\1/p' "$PROJECT" | sort -u; }
engine_versions() { sed -n 's/^[[:space:]]*public static let string = "\([^"]*\)"$/\1/p' "$ENGINE" | sort -u; }

current() {
    project=$(project_versions)
    engine=$(engine_versions)
    [ -n "$project" ] || die "no MARKETING_VERSION in $PROJECT"
    [ -n "$engine" ] || die "no SilversideVersion.string in $ENGINE"
    if [ "$(printf '%s\n' "$project" | wc -l)" -ne 1 ] || [ "$project" != "$engine" ]; then
        echo "The version differs between the files; scripts/version.sh set <version> makes them agree:" >&2
        printf '%s\n' "$project" | sed "s|^|  $PROJECT: |" >&2
        printf '%s\n' "$engine" | sed "s|^|  $ENGINE: |" >&2
        exit 1
    fi
    echo "$project"
}

valid() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a version of three numbers: $1"
}

set_version() {
    valid "$1"
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION = )[^;]*;$/\1$1;/" "$PROJECT"
    sed -i '' -E "s/^([[:space:]]*public static let string = \")[^\"]*(\")$/\1$1\2/" "$ENGINE"
    [ "$(current)" = "$1" ] || die "the version did not change in both files"
}

case "${1:-}" in
"")
    current
    ;;
check)
    current >/dev/null
    ;;
set)
    [ $# -eq 2 ] || die "usage: scripts/version.sh set <version>"
    set_version "$2"
    echo "$2"
    ;;
next)
    now=$(current)
    heading=$(grep -m 1 '^## ' CHANGELOG.md || true)
    case "$heading" in
    *"(not released yet)") die "CHANGELOG.md already starts a version: $heading" ;;
    esac
    new=${2:-$(echo "$now" | awk -F. '{ print $1 "." $2 "." $3 + 1 }')}
    valid "$new"
    set_version "$new"
    # The new heading goes before the first version's.
    awk -v heading="## $new (not released yet)" \
        '!done && /^## / { print heading; print ""; done = 1 } { print }' CHANGELOG.md >CHANGELOG.md.new
    mv CHANGELOG.md.new CHANGELOG.md
    echo "$new: in $PROJECT, $ENGINE, and CHANGELOG.md. Commit them (\"Start $new\")."
    ;;
*)
    die "usage: scripts/version.sh [check | set <version> | next [<version>]]"
    ;;
esac
