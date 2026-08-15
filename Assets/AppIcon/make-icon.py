#!/usr/bin/env python3
"""Build AppIcon.iconset and AppIcon.icns from the source artwork.

    python3 Assets/AppIcon/make-icon.py
    iconutil -c icns Assets/AppIcon/AppIcon.iconset -o Assets/AppIcon/AppIcon.icns

The source PNG is a square plate on an opaque black background with a drop shadow.
macOS needs the opposite: a transparent canvas with the plate inset, because the system
draws its own shadow and expects the icon to be smaller than its bounding box. Shipping
the raw artwork gives a black square with square corners in the Dock and Finder.

So this script does three things:

1. Crops away the black surround and the shadow, leaving just the plate.
2. Masks the plate to its own corner curve. The curve was *measured* from the artwork by
   least-squares fit rather than assumed: it came out as a plain circular arc of radius
   0.2318 x the plate, not the superellipse Apple uses (0.2250, continuous curvature).
   Imposing Apple's squircle instead left a black wedge in each corner -- a squircle is
   squarer than a circle near the diagonal, so the mask kept a sliver of the original
   black background. Matching the source is both artifact-free and faithful to the art.
3. Insets the plate to 824/1024 of the canvas, the proportion Apple uses, so the icon
   sits correctly among the system's own.

Everything is supersampled 4x and downsampled with Lanczos, because the mask edge is
the most visible part of an icon at 16pt and aliasing there looks cheap. Resizing is
done on *premultiplied* alpha: Pillow resamples RGB and alpha independently, so the
black behind transparent pixels bleeds into the edge and leaves a dark halo at 16pt.
"""

from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "icon-source.png"
ICONSET = HERE / "AppIcon.iconset"
PREVIEW = HERE / "AppIcon-preview.png"

# Apple's proportions for a 1024pt canvas: an 824pt plate, inset so the system has room
# to draw its own shadow and selection highlight.
CANVAS = 1024
PLATE = 824

# Corner geometry measured from icon-source.png, not assumed. See the module docstring.
# The 1.5% margin makes the mask marginally *rounder* than the fit, which trims a hair of
# navy rather than risking a black fringe: erring the other way is visible, this is not.
CORNER_N = 2.0
RADIUS_FRACTION = 0.2318 * 1.015

SUPERSAMPLE = 4

# The 10 entries macOS expects. Finder, the Dock, Spotlight and Get Info each pick a
# different one, so a missing size silently degrades to a blurry upscale somewhere.
SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def find_plate(image: Image.Image) -> tuple[int, int, int, int]:
    """Locate the plate, excluding the black background and the drop shadow.

    The shadow is dim but not black, so a luminance threshold alone finds a box that is
    taller than it is wide. The plate is square by construction, so the width is trusted
    and the height derived from it -- that discards the shadow without guessing where it
    ends.
    """
    lum = np.asarray(image.convert("RGB")).astype(int).max(axis=2)
    ys, xs = np.where(lum > 18)
    left, right, top = int(xs.min()), int(xs.max()), int(ys.min())
    side = right - left + 1
    return left, top, left + side, top + side


def corner_mask(size: int) -> Image.Image:
    """An 8-bit alpha mask: opaque inside the rounded plate, transparent outside."""
    n = size * SUPERSAMPLE
    radius = (size * RADIUS_FRACTION) * SUPERSAMPLE

    # Distance from each axis into the corner region. Inside the straight edges this is
    # 0, so only the four corners are curved.
    coords = np.arange(n) + 0.5
    dx = np.maximum(radius - coords, coords - (n - radius))
    dx = np.maximum(dx, 0.0)
    gx, gy = np.meshgrid(dx, dx, indexing="xy")

    value = (gx / radius) ** CORNER_N + (gy / radius) ** CORNER_N
    inside = (value <= 1.0).astype(np.uint8) * 255

    mask = Image.fromarray(inside, mode="L")
    return mask.resize((size, size), Image.LANCZOS)


def resize_premultiplied(image: Image.Image, size: int) -> Image.Image:
    """Downsample RGBA without the dark halo un-premultiplied resampling produces.

    Pillow resamples each channel independently, so fully transparent pixels -- whose RGB
    is black -- drag the edge colour toward black. Weighting colour by alpha first, then
    dividing it back out, keeps the edge the colour of the artwork.
    """
    rgba = np.asarray(image.convert("RGBA")).astype(np.float64) / 255.0
    alpha = rgba[..., 3:4]
    premultiplied = np.concatenate([rgba[..., :3] * alpha, alpha], axis=2)

    small = np.asarray(
        Image.fromarray((premultiplied * 255).round().astype(np.uint8), mode="RGBA")
        .resize((size, size), Image.LANCZOS)
    ).astype(np.float64) / 255.0

    out_alpha = small[..., 3:4]
    with np.errstate(divide="ignore", invalid="ignore"):
        colour = np.where(out_alpha > 0, small[..., :3] / out_alpha, 0.0)
    result = np.concatenate([np.clip(colour, 0, 1), out_alpha], axis=2)
    return Image.fromarray((result * 255).round().astype(np.uint8), mode="RGBA")


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"missing source artwork at {SOURCE}")

    source = Image.open(SOURCE).convert("RGB")
    plate = source.crop(find_plate(source))

    # Render the plate once at full canvas resolution, then downsample per size. Masking
    # at each target size instead would re-quantise the curve and wobble between sizes.
    plate = plate.resize((PLATE, PLATE), Image.LANCZOS)
    plate.putalpha(corner_mask(PLATE))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - PLATE) // 2
    canvas.paste(plate, (offset, offset), plate)

    ICONSET.mkdir(exist_ok=True)
    for existing in ICONSET.glob("*.png"):
        existing.unlink()

    for size, scale in SIZES:
        pixels = size * scale
        suffix = f"{size}x{size}" + ("@2x" if scale == 2 else "")
        resize_premultiplied(canvas, pixels).save(ICONSET / f"icon_{suffix}.png")

    canvas.save(PREVIEW)
    print(f"wrote {len(SIZES)} PNGs to {ICONSET.relative_to(HERE.parent.parent)}")
    print(f"wrote preview to {PREVIEW.relative_to(HERE.parent.parent)}")
    print("now run: iconutil -c icns Assets/AppIcon/AppIcon.iconset -o Assets/AppIcon/AppIcon.icns")


if __name__ == "__main__":
    main()
