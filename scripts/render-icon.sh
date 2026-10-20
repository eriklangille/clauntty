#!/bin/sh
# Renders design/AppIcon.svg into the iOS icon (1024pt, opaque: iOS masks the corners
# itself), then the Mac sizes from it with make-mac-icon.swift.
#
#   scripts/render-icon.sh
#
# Needs uv (https://docs.astral.sh/uv/): the SVG is drawn with resvg, from PyPI.
set -e
cd "$(dirname "$0")/.."

uv run -q --with resvg_py --with pillow python -I - design/AppIcon.svg \
    Clauntty/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png <<'PY'
import io, sys
import resvg_py
from PIL import Image
svg, out = sys.argv[1:3]
png = bytes(resvg_py.svg_to_bytes(svg_path=svg))
Image.open(io.BytesIO(png)).convert("RGB").save(out)
PY

swift scripts/make-mac-icon.swift
