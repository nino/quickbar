#!/usr/bin/env python3
"""Draws the app icon as an Icon Composer document and compiles it.

Run from the repository root: python3 scripts/make-icon.py

Writes Resources/AppIcon.icon (layers as SVG plus icon.json; opens in Icon
Composer), then compiles it with Xcode's actool into Resources/Assets.car (the
Liquid Glass icon, macOS 26 and later) and Resources/AppIcon.icns (the flat
fallback for older systems). Both outputs are checked in, so building the app
does not need Xcode.
"""
import json, math, pathlib, shutil, subprocess, tempfile

def pts(p): return " ".join(f"{x:.1f},{y:.1f}" for x, y in p)

GOLD = '''<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFF6C4"/><stop offset=".3" stop-color="#FFD24A"/><stop offset=".55" stop-color="#C98A0A"/><stop offset=".75" stop-color="#FFE27A"/><stop offset="1" stop-color="#9A5F00"/></linearGradient>
<linearGradient id="gold2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFE98A"/><stop offset="1" stop-color="#A86A00"/></linearGradient>
<radialGradient id="shine"><stop offset="0" stop-color="#FFD24A" stop-opacity=".5"/><stop offset="1" stop-color="#FFD24A" stop-opacity="0"/></radialGradient>'''

def layer(body):
    # Drawn on Apple's 1024 grid with its 824 square; Icon Composer wants the
    # artwork full-bleed and applies the shape itself, hence the viewBox.
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824" width="1024" height="1024">\n<defs>{GOLD}</defs>\n{body}\n</svg>\n'

# The outline macOS gives icons, traced with potrace from an Icon Composer render
# (ictool, 2048 px; units are tenths of a pixel, y up). It is rounder than a
# rounded rectangle, so the frame is drawn from it to stay parallel to the edge.
SHAPE = ("M6430 20474 c-36 -2 -195 -8 -355 -14 -1518 -57 -2270 -179 -2993 -489 -1123 -481 -2092 -1450 -2573 -2573 "
         "-310 -725 -419 -1389 -491 -2993 -19 -422 -19 -7908 0 -8330 64 -1435 138 -1974 362 -2645 468 -1406 1644 -2582 "
         "3050 -3050 671 -224 1210 -298 2645 -362 422 -19 7908 -19 8330 0 1435 64 1974 138 2645 362 1406 468 2582 1644 "
         "3050 3050 224 671 298 1210 362 2645 19 422 19 7908 0 8330 -90 2015 -279 2809 -887 3730 -691 1046 -1739 1790 "
         "-2935 2084 -549 135 -943 180 -2090 238 -291 15 -7817 30 -8120 17z")
INSET = 0.937                     # the frame's centre line, as a fraction of the icon
UNIT = 824 / 2048 * 0.1 * INSET   # one path unit in drawing units

def shape(attrs):
    # The transform sits on the path itself: a clipPath may not contain groups.
    return (f'<path transform="translate(512,512) scale({INSET}) translate(-512,-512) translate(100,100) scale({824 / 2048}) '
            f'translate(0,2048) scale(0.1,-0.1)" d="{SHAPE}" {attrs}/>')

# A lightning bolt centred on the canvas, tall enough to cross the frame.
BOLT = [(522.5, 133.5), (279.5, 538.5), (453.5, 538.5), (339.5, 898.5), (747.5, 397.5), (549.5, 397.5), (669.5, 133.5)]

def rays(n=20, r0=120, r1=720, w=.05):
    out = ""
    for i in range(n):
        a = i * math.tau / n - math.pi / 2
        p = [(512 + r0 * math.cos(a - w * .25), 512 + r0 * math.sin(a - w * .25)),
             (512 + r1 * math.cos(a - w), 512 + r1 * math.sin(a - w)),
             (512 + r1 * math.cos(a + w), 512 + r1 * math.sin(a + w)),
             (512 + r0 * math.cos(a + w * .25), 512 + r0 * math.sin(a + w * .25))]
        out += f'<polygon points="{pts(p)}" fill="url(#gold2)" opacity="{1 if i % 2 == 0 else .7}"/>\n'
    return out

LAYERS = {
    # Clipped to the frame, so no ray ends poke out between it and the glass edge.
    "1-rays.svg": f'<clipPath id="in">{shape("")}</clipPath>\n<g clip-path="url(#in)">\n'
                  + rays() + '<circle cx="512" cy="512" r="340" fill="url(#shine)"/>\n</g>',
    "2-frame.svg": shape(f'fill="none" stroke="url(#gold)" stroke-width="{24 / UNIT:.1f}"'),
    "3-bolt.svg": f'<polygon points="{pts(BOLT)}" fill="url(#gold)" stroke="#FFF6C4" stroke-width="6" stroke-linejoin="round"/>',
}

def group(image, **settings):
    return {"layers": [{"image-name": image, "name": image[:-4]}], **settings}

# Groups are listed front to back.
ICON = {
    "fill": {"linear-gradient": ["display-p3:0.33000,0.23000,0.09000,1.00000", "display-p3:0.03000,0.02000,0.01000,1.00000"]},
    "groups": [
        group("3-bolt.svg", specular=True, shadow={"kind": "neutral", "opacity": 0.8},
              translucency={"enabled": True, "value": 0.15}),
        group("2-frame.svg", specular=True, shadow={"kind": "neutral", "opacity": 0.5},
              translucency={"enabled": True, "value": 0.2}),
        group("1-rays.svg", specular=False, shadow={"kind": "none", "opacity": 0.5},
              translucency={"enabled": True, "value": 0.35}),
    ],
    "supported-platforms": {"squares": ["macOS"]},
}

root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
doc = root / "AppIcon.icon"
shutil.rmtree(doc, ignore_errors=True)
(doc / "Assets").mkdir(parents=True)
for name, body in LAYERS.items():
    (doc / "Assets" / name).write_text(layer(body))
(doc / "icon.json").write_text(json.dumps(ICON, indent=2) + "\n")

with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["xcrun", "actool", str(doc), "--compile", tmp, "--app-icon", "AppIcon",
                    "--include-all-app-icons", "--output-partial-info-plist", f"{tmp}/partial.plist",
                    "--target-device", "mac", "--minimum-deployment-target", "14.0", "--platform", "macosx",
                    "--errors", "--warnings"], check=True)
    for name in ("Assets.car", "AppIcon.icns"):
        shutil.copy(f"{tmp}/{name}", root / name)
print("wrote", doc, "and compiled Assets.car, AppIcon.icns")
