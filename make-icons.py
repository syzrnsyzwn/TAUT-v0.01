#!/usr/bin/env python3
"""Regenerate ALL app icons from ONE logo file.

Put your logo at assets/logo.svg (or assets/logo.png, square, 1024x1024), then run:
    pip install pillow cairosvg
    python make-icons.py
Transparent logos are placed on BG below. Edit BG to change the background colour.
"""
import io, os, sys
from PIL import Image

BG = "#8a8a45"                      # background behind the logo (also used for the maskable icon)
ROOT = os.path.dirname(os.path.abspath(__file__))

def load():
    svg, png = (os.path.join(ROOT, "assets", n) for n in ("logo.svg", "logo.png"))
    if os.path.exists(svg):
        import cairosvg
        data = cairosvg.svg2png(url=svg, output_width=1024, output_height=1024)
        return Image.open(io.BytesIO(data)).convert("RGBA")
    if os.path.exists(png):
        return Image.open(png).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    sys.exit("Put your logo at assets/logo.svg or assets/logo.png")

logo = Image.alpha_composite(Image.new("RGBA", (1024, 1024), BG), load())   # flatten onto BG
out = os.path.join(ROOT, "icons"); os.makedirs(out, exist_ok=True)

def save(img, name, size):
    img.resize((size, size), Image.LANCZOS).convert("RGB").save(os.path.join(out, name))

for name, size in (("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180), ("favicon-32.png", 32)):
    save(logo, name, size)

# maskable: logo shrunk into the safe zone so phones can crop it to a circle/squircle
canvas = Image.new("RGBA", (1024, 1024), BG)
small = logo.resize((680, 680), Image.LANCZOS)
canvas.paste(small, (172, 172))
save(canvas, "icon-maskable-512.png", 512)
print("Icons updated in", out)
