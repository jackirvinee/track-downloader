from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Track Downloader.app" / "Contents" / "Resources"
SOURCE_PNG = RESOURCES / "AppIcon-1024.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"

def draw_icon(size: int = 1024) -> Image.Image:
    scale = size / 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Two green low bars, two amber middle bars, and one taller red peak.
    # The arrow is deliberately separate: this reads as download, not a funnel.
    baseline = 660 * scale
    bar_width = 96 * scale
    gap = 36 * scale
    heights = [285, 325, 425, 470, 590]
    colors = ["#4DCB78", "#4DCB78", "#E7A43B", "#E7A43B", "#E05C58"]
    total_width = len(heights) * bar_width + (len(heights) - 1) * gap
    start_x = (size - total_width) / 2
    for index, (height, color) in enumerate(zip(heights, colors, strict=True)):
        x0 = start_x + index * (bar_width + gap)
        x1 = x0 + bar_width
        y0 = baseline - height * scale
        y1 = baseline
        draw.rounded_rectangle(
            (x0, y0, x1, y1),
            radius=int(36 * scale),
            fill=color,
        )

    arrow_x = 512 * scale
    arrow_top = 756 * scale
    arrow_bottom = 948 * scale
    shaft_half = 44 * scale
    head_half = 146 * scale
    head_top = 840 * scale
    arrow = [
        (arrow_x - shaft_half, arrow_top),
        (arrow_x + shaft_half, arrow_top),
        (arrow_x + shaft_half, head_top),
        (arrow_x + head_half, head_top),
        (arrow_x, arrow_bottom),
        (arrow_x - head_half, head_top),
        (arrow_x - shaft_half, head_top),
    ]
    draw.polygon(arrow, fill="#E8E7E1")
    return canvas


def save_iconset(source: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    # Remove legacy 1x 16/32 assets before compiling so an older generated
    # iconset cannot make the package invalid.
    for obsolete_filename in ("icon_16x16.png", "icon_32x32.png"):
        (ICONSET / obsolete_filename).unlink(missing_ok=True)
    sizes = {
        "icon_16x16@2x.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for filename, pixel_size in sizes.items():
        source.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS).save(ICONSET / filename)


def load_iconset_images() -> list[Image.Image]:
    # ICNS stores one representation per pixel width. These source files are
    # the exact images that ship in the iconset, not new resizes of the 1024 px
    # drawing, so both output formats stay pixel-identical at every size.
    filenames = (
        "icon_16x16@2x.png",
        "icon_32x32@2x.png",
        "icon_128x128.png",
        "icon_128x128@2x.png",
        "icon_256x256@2x.png",
        "icon_512x512@2x.png",
    )
    images: list[Image.Image] = []
    for filename in filenames:
        with Image.open(ICONSET / filename) as image:
            image.load()
            images.append(image.convert("RGBA"))
    return images


def main() -> int:
    RESOURCES.mkdir(parents=True, exist_ok=True)
    source = draw_icon()
    source.save(SOURCE_PNG)
    save_iconset(source)
    icon_images = load_iconset_images()
    icon_images[-1].save(ICNS, format="ICNS", append_images=icon_images[:-1])
    print(ICNS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
