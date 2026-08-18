#!/usr/bin/env python3
"""Build the DMG window background: light plate, arrow, and a one-line instruction.

    python3 Assets/DMG/make-background.py

Emits `background.tiff` with 1x and 2x representations. A plain PNG would be soft on a
Retina display, and the DMG window is the first thing anyone sees of this app.

Geometry is tied to `scripts/release.sh`: the window is 600x420 points, the app icon sits
centred at (150, 200) and the Applications alias at (450, 200), so the arrow belongs in
the gap between them. Change one without the other and the arrow points at nothing.
"""

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
W, H = 600, 420
APP_X, APPS_X, ICON_Y = 150, 450, 200

# Light, deliberately, despite the app icon being dark.
#
# Finder draws icon labels in a colour chosen by the system appearance, not by what is
# behind them: black in Light mode, white in Dark. A background cannot satisfy both, and
# the first version of this was dark -- which rendered the "Teams Music Status" and
# "Applications" labels in black on near-black for every user in Light mode. Reported
# from a second machine as "the text under each icon is black instead of white".
#
# Light loses less: Light is the more common default, and a white label on a light plate
# in Dark mode is still legible, where black on near-black was not legible at all. The
# indigo is carried by the arrow and the wordmark instead of the field.
TOP = (247, 246, 251)
BOTTOM = (232, 230, 243)
ARROW = (99, 91, 195)
TEXT = (74, 71, 102)


def render(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), BOTTOM)
    draw = ImageDraw.Draw(img)

    # Vertical gradient, drawn a row at a time — cheap at this size and smoother than
    # any of the alternatives that do not pull in numpy.
    for y in range(h):
        t = y / max(h - 1, 1)
        draw.line([(0, y), (w, y)],
                  fill=tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))

    # Arrow, centred in the gap between the two icons.
    cy = ICON_Y * scale
    x0 = (APP_X + 105) * scale
    x1 = (APPS_X - 105) * scale
    shaft = 7 * scale
    head = 26 * scale

    draw.rounded_rectangle([x0, cy - shaft // 2, x1 - head, cy + shaft // 2],
                           radius=shaft // 2, fill=ARROW)
    draw.polygon([(x1, cy), (x1 - head, cy - head // 2), (x1 - head, cy + head // 2)],
                 fill=ARROW)

    label = "Drag Teams Music Status into Applications"
    size = 15 * scale
    for candidate in ("/System/Library/Fonts/SFNS.ttf",
                      "/System/Library/Fonts/Helvetica.ttc"):
        try:
            font = ImageFont.truetype(candidate, size)
            break
        except OSError:
            continue
    else:
        font = ImageFont.load_default()

    box = draw.textbbox((0, 0), label, font=font)
    draw.text(((w - (box[2] - box[0])) / 2, (ICON_Y + 118) * scale), label,
              font=font, fill=TEXT)
    return img


def main() -> None:
    one = HERE / "background.png"
    two = HERE / "background@2x.png"
    render(1).save(one)
    render(2).save(two)
    out = HERE / "background.tiff"
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(out)],
                   check=True, capture_output=True)
    one.unlink()
    two.unlink()
    print(f"wrote {out.relative_to(HERE.parent.parent)} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
