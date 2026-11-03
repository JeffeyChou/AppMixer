#!/usr/bin/env bash
# Regenerates docs/demo.gif (and docs/screenshot.png) from the real UI with demo data.
# Needs ffmpeg (brew install ffmpeg). Nothing is played and no settings are changed.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT

build/AppMixer.app/Contents/MacOS/AppMixer --record-demo "$frames"
mkdir -p docs

# Two-pass palette GIF: crisp UI, small file. Shown at 360 pt wide in the README (sharp on retina).
ffmpeg -v error -y -framerate 12 -i "$frames/frame_%03d.png" \
    -vf "scale=iw:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    docs/demo.gif

# Still image: the last frame (EQ + spectrum, an app routed to AirPods, a lowered app).
cp "$frames/frame_100.png" docs/screenshot.png
ls -lh docs/demo.gif docs/screenshot.png
