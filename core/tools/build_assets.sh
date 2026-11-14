#!/bin/sh
# Builds assets/ (the data every Portolan app reads) from YOUR OWN copy of the original game.
#
#   1. put the original game's GAME folder at original/GAME
#   2. install the Python packages once:   python3 -m venv .venv && .venv/bin/pip install capstone numpy scipy
#   3. run:                                PYTHON=.venv/bin/python tools/build_assets.sh
#
# SKIP_MUSIC=1 leaves out the music (tools/mml.py needs macOS's afconvert to write .m4a).
# assets/ is derived from the original game and must never be committed or redistributed.
set -eu
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
[ -f original/GAME/MAIN.EXE ] || [ -d original/GAME ] || { echo "original/GAME not found: see README" >&2; exit 1; }
"$PY" -I tools/extract.py
for t in portmaps townchars sprites endings seamap; do "$PY" -I tools/$t.py; done   # seamap needs extract.py first
"$PY" -I tools/faces.py --export assets/faces
"$PY" -I tools/frame.py
if [ "${SKIP_MUSIC:-0}" != 1 ]; then "$PY" -I tools/mml.py render; fi
"$PY" -I tools/sfx.py render
echo "assets/ is ready: $(find assets -type f | wc -l | tr -d ' ') files"
