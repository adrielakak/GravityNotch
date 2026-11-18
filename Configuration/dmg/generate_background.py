#!/usr/bin/env python3
"""
Generate the 1x and 2x DMG background images for GravityNotch and combine them
into a multi-resolution HiDPI TIFF using macOS tiffutil.
"""

from pathlib import Path
import math
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Brand palette (matches docs/styles.css)
LILAC_BG = (241, 240, 254, 255)       # #f1f0fe
ULTRA = (18, 25, 237, 255)            # #1219ed
DEEP_ULTRA = (11, 16, 184, 255)       # #0b10b8
INK_NAVY = (19, 21, 105, 255)         # #131569

BASE_W = 660
BASE_H = 400
LEFT_X = 175
RIGHT_X = 485
ICON_Y = 185


def load_font(size: int, weight: str = "medium") -> ImageFont.FreeTypeFont:
    candidates = [
        ("/System/Library/Fonts/SFNS.ttf", 0),
        ("/System/Library/Fonts/SFNSDisplay.ttf", 0),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if weight == "bold" else 0),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if weight == "bold" else "/System/Library/Fonts/Supplemental/Arial.ttf", 0),
    ]
    for path, index in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size=size, index=index)
            except Exception:
                continue
    return ImageFont.load_default()


def render_canvas(scale: int, repo_root: Path) -> Image.Image:
    # Render at 2x supersampling for crisp anti-aliased vector edges
    ss = 2
    s = scale * ss
    w = BASE_W * s
    h = BASE_H * s

    canvas = Image.new("RGBA", (w, h), LILAC_BG)

    # Subtle ambient radial glow in ultramarine near top center and icon zones
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    for cx, cy, rx, ry, alpha in [
        (BASE_W // 2, 0, 320, 170, 18),
        (LEFT_X, ICON_Y, 120, 120, 14),
        (RIGHT_X, ICON_Y, 120, 120, 14),
    ]:
        bbox = [
            (cx - rx) * s,
            (cy - ry) * s,
            (cx + rx) * s,
            (cy + ry) * s,
        ]
        gdraw.ellipse(bbox, fill=(ULTRA[0], ULTRA[1], ULTRA[2], alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=42 * s))
    canvas = Image.alpha_composite(canvas, glow)

    # Subtle stipple dot grid near the corners (website signature texture)
    stipple = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(stipple)
    step = 14 * s
    dot_r = max(1, int(1.1 * s))
    for y in range(step // 2, h, step):
        for x in range(step // 2, w, step):
            nx = (x / w) - 0.5
            ny = (y / h) - 0.5
            dist = math.hypot(nx * 1.15, ny * 1.35)
            if dist > 0.36:
                fade = min(1.0, (dist - 0.36) / 0.38)
                a = int(18 * fade)
                if a > 1:
                    sdraw.ellipse(
                        [x - dot_r, y - dot_r, x + dot_r, y + dot_r],
                        fill=(ULTRA[0], ULTRA[1], ULTRA[2], a),
                    )
    canvas = Image.alpha_composite(canvas, stipple)

    # Icon drop pads (left: app, right: Applications)
    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)
    pad_half = 76 * s
    pad_radius = 34 * s
    for cx in (LEFT_X, RIGHT_X):
        px = cx * s
        py = ICON_Y * s
        rect = [px - pad_half, py - pad_half, px + pad_half, py + pad_half]
        odraw.rounded_rectangle(
            rect,
            radius=pad_radius,
            fill=(255, 255, 255, 165),
            outline=(ULTRA[0], ULTRA[1], ULTRA[2], 34),
            width=max(1, int(1.25 * s)),
        )

    # Top Dynamic Island brand pill
    pill_font = load_font(int(12.5 * s), weight="bold")
    pill_label = "GravityNotch"
    tb = odraw.textbbox((0, 0), pill_label, font=pill_font)
    tw = tb[2] - tb[0]
    th = tb[3] - tb[1]

    icon_path = repo_root / "docs" / "assets" / "icon.png"
    has_icon = icon_path.exists()
    icon_px = 18 * s if has_icon else 0
    gap_px = 7 * s if has_icon else 0
    content_w = icon_px + gap_px + tw

    pill_w = content_w + 26 * s
    pill_h = 30 * s
    pill_x0 = (w - pill_w) // 2
    pill_y0 = 28 * s
    pill_rect = [pill_x0, pill_y0, pill_x0 + pill_w, pill_y0 + pill_h]
    odraw.rounded_rectangle(
        pill_rect,
        radius=pill_h // 2,
        fill=DEEP_ULTRA,
        outline=(ULTRA[0], ULTRA[1], ULTRA[2], 90),
        width=max(1, s),
    )

    start_x = pill_x0 + (pill_w - content_w) // 2
    if has_icon:
        app_icon = Image.open(icon_path).convert("RGBA")
        app_icon = app_icon.resize((icon_px, icon_px), Image.Resampling.LANCZOS)
        iy = pill_y0 + (pill_h - icon_px) // 2
        overlay.alpha_composite(app_icon, (start_x, iy))
        text_x = start_x + icon_px + gap_px - tb[0]
    else:
        text_x = start_x - tb[0]

    ty = pill_y0 + (pill_h - th) // 2 - tb[1]
    odraw.text((text_x, ty), pill_label, font=pill_font, fill=(255, 255, 255, 245))

    # Center arrow between left and right pads
    mid_x = (BASE_W // 2) * s
    mid_y = ICON_Y * s

    # Soft pill backdrop behind arrow
    arrow_pill_w = 76 * s
    arrow_pill_h = 36 * s
    odraw.rounded_rectangle(
        [
            mid_x - arrow_pill_w // 2,
            mid_y - arrow_pill_h // 2,
            mid_x + arrow_pill_w // 2,
            mid_y + arrow_pill_h // 2,
        ],
        radius=arrow_pill_h // 2,
        fill=(ULTRA[0], ULTRA[1], ULTRA[2], 20),
        outline=(ULTRA[0], ULTRA[1], ULTRA[2], 42),
        width=max(1, s),
    )

    shaft_x0 = mid_x - 16 * s
    shaft_x1 = mid_x + 14 * s
    stroke_w = max(2, int(2.6 * s))
    odraw.line([(shaft_x0, mid_y), (shaft_x1, mid_y)], fill=ULTRA, width=stroke_w)
    r = stroke_w // 2
    odraw.ellipse([shaft_x0 - r, mid_y - r, shaft_x0 + r, mid_y + r], fill=ULTRA)

    head = 8 * s
    tip_x = mid_x + 16 * s
    odraw.line([(tip_x - head, mid_y - head), (tip_x, mid_y)], fill=ULTRA, width=stroke_w)
    odraw.line([(tip_x - head, mid_y + head), (tip_x, mid_y)], fill=ULTRA, width=stroke_w)
    odraw.ellipse([tip_x - r, mid_y - r, tip_x + r, mid_y + r], fill=ULTRA)
    odraw.ellipse([tip_x - head - r, mid_y - head - r, tip_x - head + r, mid_y - head + r], fill=ULTRA)
    odraw.ellipse([tip_x - head - r, mid_y + head - r, tip_x - head + r, mid_y + head + r], fill=ULTRA)

    # Discrete bottom caption
    caption = "Glissez GravityNotch dans Applications"
    caption_font = load_font(int(13.5 * s), weight="medium")
    cb = odraw.textbbox((0, 0), caption, font=caption_font)
    cw = cb[2] - cb[0]
    ch = cb[3] - cb[1]
    cx = (w - cw) // 2 - cb[0]
    cy = 336 * s - ch // 2 - cb[1]
    odraw.text((cx, cy), caption, font=caption_font, fill=(INK_NAVY[0], INK_NAVY[1], INK_NAVY[2], 215))

    canvas = Image.alpha_composite(canvas, overlay)
    final_w = BASE_W * scale
    final_h = BASE_H * scale
    return canvas.convert("RGB").resize((final_w, final_h), Image.Resampling.LANCZOS)


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    bg_dir = script_dir / ".background"
    bg_dir.mkdir(parents=True, exist_ok=True)
    out_tiff = bg_dir / "background.tiff"

    img_1x = render_canvas(1, repo_root)
    img_2x = render_canvas(2, repo_root)

    with tempfile.TemporaryDirectory() as tmp:
        p1 = Path(tmp) / "background.png"
        p2 = Path(tmp) / "background@2x.png"
        img_1x.save(p1, format="PNG", dpi=(72, 72))
        img_2x.save(p2, format="PNG", dpi=(144, 144))
        subprocess.run(
            ["tiffutil", "-cathidpicheck", str(p1), str(p2), "-out", str(out_tiff)],
            check=True,
        )
    print(f"Generated multi-resolution HiDPI TIFF: {out_tiff}")


if __name__ == "__main__":
    main()
