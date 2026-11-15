#!/usr/bin/env python3
"""Draws the app icon: writes Resources/AppIcon.svg and builds Resources/AppIcon.icns.

Run from the repository root: python3 scripts/make-icon.py
Needs rsvg-convert (brew install librsvg) and iconutil. Only for redrawing the
icon; the .icns is checked in, so building the app needs neither.
"""
import math, pathlib, subprocess, tempfile

def pts(p): return " ".join(f"{x:.1f},{y:.1f}" for x, y in p)

# A lightning bolt centred on the canvas, tall enough to break out of the frame.
BOLT = [(718.5, 133.5), (475.5, 538.5), (649.5, 538.5), (535.5, 898.5), (943.5, 397.5), (745.5, 397.5), (865.5, 133.5)]
BOLT = [(x - 196, y) for x, y in BOLT]

def rays(n=20, r0=120, r1=720, w=.05):
    out = ""
    for i in range(n):
        a = i * math.tau / n - math.pi / 2
        p = [(512 + r0 * math.cos(a - w * .25), 512 + r0 * math.sin(a - w * .25)),
             (512 + r1 * math.cos(a - w), 512 + r1 * math.sin(a - w)),
             (512 + r1 * math.cos(a + w), 512 + r1 * math.sin(a + w)),
             (512 + r0 * math.cos(a + w * .25), 512 + r0 * math.sin(a + w * .25))]
        out += f'<polygon points="{pts(p)}" fill="url(#gold2)" opacity="{1 if i % 2 == 0 else .7}"/>'
    return out

# Apple's icon grid: an 824 rounded square centred in 1024.
SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
<clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFF6C4"/><stop offset=".3" stop-color="#FFD24A"/><stop offset=".55" stop-color="#C98A0A"/><stop offset=".75" stop-color="#FFE27A"/><stop offset="1" stop-color="#9A5F00"/></linearGradient>
<linearGradient id="gold2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFE98A"/><stop offset="1" stop-color="#A86A00"/></linearGradient>
<radialGradient id="shine"><stop offset="0" stop-color="#FFD24A" stop-opacity=".45"/><stop offset="1" stop-color="#FFD24A" stop-opacity="0"/></radialGradient>
<radialGradient id="bg" cx=".5" cy=".5" r=".75"><stop offset="0" stop-color="#4A3414"/><stop offset=".6" stop-color="#170F05"/><stop offset="1" stop-color="#050302"/></radialGradient>
</defs>
<g clip-path="url(#sq)">
<rect width="1024" height="1024" fill="url(#bg)"/>
{rays()}
<circle cx="512" cy="512" r="330" fill="url(#shine)"/>
<rect x="124" y="124" width="776" height="776" rx="164" fill="none" stroke="url(#gold)" stroke-width="26"/>
<polygon points="{pts(BOLT)}" fill="#0A0703" stroke="#0A0703" stroke-width="44" stroke-linejoin="round"/>
<polygon points="{pts(BOLT)}" fill="url(#gold)" stroke="#FFF6C4" stroke-width="6" stroke-linejoin="round"/>
</g>
</svg>
'''

root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
svg = root / "AppIcon.svg"
svg.write_text(SVG)
with tempfile.TemporaryDirectory() as tmp:
    iconset = pathlib.Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["rsvg-convert", "-w", str(size * scale), str(svg), "-o", str(iconset / name)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "AppIcon.icns")], check=True)
print("wrote", svg, "and AppIcon.icns")
