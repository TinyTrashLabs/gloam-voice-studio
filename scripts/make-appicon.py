#!/usr/bin/env python3
"""Render the Gloam app icon for macOS 26 and for everything older.

macOS 26 (Tahoe) composes the app icon itself from `App/AppIcon.icon`: it masks
the layers to its own squircle, adds the glass rim and shadow, and expects the
art to run edge to edge. Handing it the old inset icon (a squircle with margin,
bevel and shadow already baked in) makes Tahoe draw a second, smaller squircle
inside its own -- which is the "border" that shipped in build 10.

So the `.icon` gets two full-bleed layers with nothing baked in:
  App/AppIcon.icon/Assets/ground.png  opaque ink gradient, the whole canvas
  App/AppIcon.icon/Assets/bars.png    the four bars on transparency

Everything that is NOT Tahoe's compositor still wants the classic look -- a
squircle with a transparent margin and a soft drop shadow: macOS 14/15 Docks,
Finder on older systems, and App Store Connect, which reads the listing icon
from the bundle's AppIcon.icns (see scripts/embed-full-appicon.sh). Those come
from the same render, drawn inside Apple's 824pt tile on a 1024 canvas:
  App/StoreIcon/icon-{16,32,64,128,256,512,1024}.png

Geometry is shared with gloam-voice-studio-ios/scripts/make-appicon.py so the
mark is identical on every platform: the bar layout was measured off the
original 800pt master and rescaled to whatever tile it is drawn in.

Usage: scripts/make-appicon.py
"""
import pathlib

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersample

GROUND_TOP = (7, 35, 47)      # #07232f
GROUND_BOT = (2, 18, 26)      # #02121a
PINK = (254, 58, 139)         # #fe3a8b
VIOLET = (174, 105, 252)      # #ae69fc
CYAN = (76, 239, 253)         # #4ceffd

# Bar layout in master pixels: (dx, dy, h) from the bar-group origin, drawn in
# an 800pt tile. BAR_W and GROUP_* are in the same units.
MASTER_TILE = 800.0
BAR_W = 88.5
BARS = [(0, 137, 224), (130, 0, 479), (256, 74, 340), (383, 177, 162)]
GROUP_W, GROUP_H = 471, 479

# Apple's macOS icon template: an 824pt tile centred on the 1024 canvas.
LEGACY_TILE = 824
LEGACY_RADIUS = 184          # 22.37% of the tile, Apple's continuous-corner look
LEGACY_SHADOW = (0, 10, 24, 0.30)  # dx, dy, blur, opacity at 1024
LEGACY_SIZES = (16, 32, 64, 128, 256, 512, 1024)

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICON_ASSETS = ROOT / "App/AppIcon.icon/Assets"
STORE_ICON = ROOT / "App/StoreIcon"


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def bar_color(t):
    """Pink at the cap, violet mid, cyan at the foot."""
    return lerp(PINK, VIOLET, t / 0.5) if t < 0.5 else lerp(VIOLET, CYAN, (t - 0.5) / 0.5)


def ground(px):
    """Opaque vertical ink gradient, px square."""
    img = Image.new("RGB", (px, px))
    d = ImageDraw.Draw(img)
    for y in range(px):
        c = lerp(GROUND_TOP, GROUND_BOT, y / (px - 1))
        d.line([(0, y), (px, y)], fill=c)
    return img


def bars(px, tile):
    """The four bars on transparency, laid out for a `tile`-wide squircle
    centred in a px-square canvas (both in supersampled pixels)."""
    k = tile / MASTER_TILE
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    x0 = (px - GROUP_W * k) / 2
    y0 = (px - GROUP_H * k) / 2
    w = BAR_W * k
    for dx, dy, h in BARS:
        x, y, hh = x0 + dx * k, y0 + dy * k, h * k
        strip = Image.new("RGBA", (round(w), round(hh)))
        sd = ImageDraw.Draw(strip)
        for i in range(round(hh)):
            sd.line([(0, i), (round(w), i)], fill=bar_color(i / max(1, hh - 1)) + (255,))
        mask = Image.new("L", (round(w), round(hh)), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, round(w) - 1, round(hh) - 1], radius=round(w / 2), fill=255)
        img.paste(strip, (round(x), round(y)), mask)
    return img


def down(img):
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def render_tahoe_layers():
    n = SIZE * SS
    return down(ground(n)), down(bars(n, n))


def render_legacy_master():
    """Classic macOS icon: squircle tile with margin and drop shadow, RGBA."""
    n = SIZE * SS
    tile = LEGACY_TILE * SS
    inset = (n - tile) // 2

    # The tile: ground gradient masked to the squircle, bars on top.
    tile_mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle(
        [inset, inset, inset + tile - 1, inset + tile - 1],
        radius=LEGACY_RADIUS * SS, fill=255)
    face = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    g = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    g.paste(ground(tile), (inset, inset))
    face.paste(g, (0, 0), tile_mask)
    face.alpha_composite(bars(n, tile))

    # Shadow under the tile.
    dx, dy, blur, opacity = LEGACY_SHADOW
    shadow_alpha = tile_mask.filter(ImageFilter.GaussianBlur(blur * SS))
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha.point(lambda a: round(a * opacity)))
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.alpha_composite(shadow, (dx * SS, dy * SS))
    out.alpha_composite(face)
    return down(out)


def main():
    ICON_ASSETS.mkdir(parents=True, exist_ok=True)
    STORE_ICON.mkdir(parents=True, exist_ok=True)

    ground_img, bars_img = render_tahoe_layers()
    ground_img.save(ICON_ASSETS / "ground.png")
    bars_img.save(ICON_ASSETS / "bars.png")
    print("wrote", ICON_ASSETS.relative_to(ROOT) / "{ground,bars}.png")

    master = render_legacy_master()
    for s in LEGACY_SIZES:
        (master if s == SIZE else master.resize((s, s), Image.LANCZOS)).save(
            STORE_ICON / f"icon-{s}.png")
    print("wrote", STORE_ICON.relative_to(ROOT) / "icon-{16..1024}.png")


if __name__ == "__main__":
    main()
