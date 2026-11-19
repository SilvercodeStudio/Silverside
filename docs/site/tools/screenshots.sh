#!/bin/zsh
# Takes the site's screenshots again, after the app's look changes:
#
#   make site-shots                          every scene, light then dark
#   make site-shots SCENES='ready done'      some of them
#   make site-shots APPEARANCES=dark         one appearance
#
# For each scene in docs/site/tools/scenes, in each appearance, the script starts the Debug app
# with -scene (ScreenshotScene in the app): the drives, discs, and rips of the screenshot, from
# your rip history, with the sidebar as it was then. Take a region screenshot (Shift-Command-4) a
# little larger than the window, with desktop all around it, then quit the app (Command-Q). For
# another window or a sheet, the scene makes the main window invisible ("mainWindow": false); with
# "capture": "window", the script asks for a screenshot of that window alone (Shift-Command-4,
# Space, then Option-click it). The script finds the new screenshot in your screenshot folder,
# makes the site's images from it with shot.swift, and starts the next one. The app runs with a
# scratch copy of the settings and SILVERSIDE_CACHE_ONLY=1, so it changes nothing and asks
# MusicBrainz nothing.
#
# The captures are kept in build/site-shots, so a crop can be made again by hand. The <img>
# heights in the pages follow the new images, and the link preview follows the dark hero.
set -euo pipefail

repo=${0:A:h:h:h:h}
app=${APP:?set APP to the Debug Silverside.app (make site-shots does)}
scene_dir=$repo/docs/site/tools/scenes
images=$repo/docs/site/images
keep=$repo/build/site-shots
mkdir -p $keep

# The scenes in the order of the pages, then any others.
order=(ripping ready compilation done repaired data-track damaged hdcd dts set report history
    welcome cover-art settings about)
all=($order ${${${(f)"$(ls $scene_dir/*.json)"}:t:r}:|order})
scenes=(${@:-${=SCENES:-$all}})
appearances=(${=APPEARANCES:-light dark})
for scene in $scenes; do
    [[ -f $scene_dir/$scene.json ]] || { echo "No scene $scene_dir/$scene.json" >&2; exit 1; }
done

# Where Shift-Command-4 saves: the setting in Screenshot's Options, else the Desktop. SHOTS names
# another folder.
shots=${SHOTS:-$(defaults read com.apple.screencapture location 2>/dev/null || echo ~/Desktop)}
shots=${~shots}

scratch=$(mktemp -d -t silverside-shots)
trap '[[ $scratch == */silverside-shots.* ]] && rm -r -- $scratch' EXIT
cp ~/Library/Application\ Support/Silverside/settings.json $scratch/settings.json

# A key of a scene file, or the default.
function scene_value {
    plutil -extract $2 raw -o - $scene_dir/$1.json 2>/dev/null || echo ${3:-}
}

# The newest PNG in the screenshot folder made since the marker, waiting for it a while:
# with the floating thumbnail on, macOS writes the file a few seconds after the capture.
function new_capture {
    local marker=$1
    local -a newest
    for _ in {1..30}; do
        newest=($shots/*.png(N.om[1]))
        if (( $#newest )) && [[ $newest[1] -nt $marker ]]; then
            echo $newest[1]
            return
        fi
        sleep 0.5
    done
}

# Sets each page's <img> height for the image to the new image's, at its largest width.
function update_heights {
    local name=$1 width=$2 height
    [[ -f $images/$name-dark-$width.webp ]] || return 0
    height=$(sips -g pixelHeight $images/$name-dark-$width.webp | awk '/pixelHeight/ {print $2}')
    for page in $repo/docs/site/index.html $repo/docs/site/screenshots.html; do
        NAME=$name WIDTH=$width HEIGHT=$height perl -i -pe \
            's/height="\d+"/height="$ENV{HEIGHT}"/ if /src="images\/\Q$ENV{NAME}\E-dark-\Q$ENV{WIDTH}\E\.webp"/' $page
    done
}

echo "Scenes: $scenes"
for scene in $scenes; do
    file=$scene_dir/$scene.json
    capture=$(scene_value $scene capture region)
    widths=$(scene_value $scene widths 2400,1200)
    arguments=(${=$(scene_value $scene arguments)})
    # The report beside an earlier rip is kept in the app's defaults: hidden unless the scene shows it.
    (( ${arguments[(I)-reportShown]} )) || arguments=(-reportShown 0 $arguments)
    if [[ $capture == window ]]; then
        how="a screenshot of that window alone (⇧⌘4, Space, then ⌥-click it)"
        crop=(--widths $widths)
    else
        # With "mainWindow": false, the main window is invisible, and the window or sheet on show
        # has the desktop around it.
        how="a region screenshot (⇧⌘4) a little larger than the window, with desktop all around it"
        crop=(--widths $widths --radius $(scene_value $scene radius 36))
    fi
    for appearance in $appearances; do
        while true; do
            marker=$scratch/marker
            touch $marker
            sleep 1
            echo "\n$scene ($appearance): take $how, then quit Silverside (⌘Q)."
            # Through Launch Services, which brings the app to the front (started as a plain
            # process, it stays behind the Terminal); -n for a new copy beside any Silverside
            # running, -W to wait until it quits.
            open -n -W -a $app --env SILVERSIDE_SETTINGS=$scratch/settings.json --env SILVERSIDE_CACHE_ONLY=1 \
                --stdout $scratch/app.log --stderr $scratch/app.log \
                --args -scene $file -appearance $appearance -welcomeDone 1 $arguments || true
            # The scene's settings changes go into the scratch file: the next scene starts afresh.
            cp ~/Library/Application\ Support/Silverside/settings.json $scratch/settings.json
            shot=$(new_capture $marker)
            if [[ -n $shot ]]; then
                mv $shot $keep/$scene-$appearance.png
                swift $repo/docs/site/tools/shot.swift $keep/$scene-$appearance.png $images/$scene-$appearance $crop
                if [[ $scene-$appearance == ripping-dark ]]; then
                    swift $repo/docs/site/tools/og-image.swift $images/ripping-dark-2400.webp $images/og-image.jpg
                fi
                break
            fi
            read "answer?No new screenshot in $shots. Again, skip, or quit? [a/s/q] "
            case $answer in
            s*) break ;;
            q*) exit 1 ;;
            esac
        done
    done
    update_heights $scene ${widths%%,*}
done
echo "\nDone. The captures are in $keep; check the pages with make site."
