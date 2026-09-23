#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Draw the zeppelin map icon (media/zeppelin.tga).

The game has no zeppelin map icon, only top-down vehicle sprites, so this draws one to sit beside the stock
ferry (atlas flightmasterferry): a side view in its palette, with its soft black outline and tan rim. Drawn
at 512 and downsampled so the edges stay clean at the 20 px the map shows it.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 512
OUTPUT = Path(__file__).resolve().parent.parent / "media" / "zeppelin.tga"

TAN = (255, 214, 128)
GOLD = (196, 140, 50)
BROWN = (92, 58, 12)
DARK = (40, 24, 2)
BALLOON = (60, 90, 470, 300)
GONDOLA = (175, 315, 355, 390)


def fins(draw):
    draw.polygon([(95, 195), (22, 120), (40, 110), (130, 170)], fill=255)
    draw.polygon([(95, 195), (22, 270), (40, 280), (130, 220)], fill=255)


def struts(draw):
    for top, bottom in ((215, 205), (315, 325)):
        draw.line((top, 290, bottom, 330), fill=255, width=24)


def gondola(draw):
    draw.rounded_rectangle(GONDOLA, radius=24, fill=255)


def propeller(draw):
    draw.ellipse((150, 330, 172, 370), fill=255)
    draw.rectangle((160, 345, 190, 355), fill=255)


def balloon(draw):
    draw.ellipse(BALLOON, fill=255)


def mask(*shapes):
    image = Image.new("L", (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(image)
    for shape in shapes:
        shape(draw)
    return image


def gradient(top, bottom, start, end):
    image = Image.new("RGBA", (SIZE, SIZE))
    for y in range(SIZE):
        t = min(max((y - start) / (end - start), 0), 1)
        color = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom, strict=True)) + (255,)
        image.paste(color, (0, y, SIZE, y + 1))
    return image


def layer(draw_fn):
    image = Image.new("RGBA", (SIZE, SIZE))
    draw_fn(ImageDraw.Draw(image))
    return image


def main():
    empty = Image.new("RGBA", (SIZE, SIZE))
    silhouette = mask(fins, struts, gondola, propeller, balloon)
    icon = Image.new("RGBA", (SIZE, SIZE))
    icon.paste((0, 0, 0, 235), (0, 0), silhouette.filter(ImageFilter.MaxFilter(33)).filter(ImageFilter.GaussianBlur(4)))
    icon.paste(DARK + (255,), (0, 0), silhouette.filter(ImageFilter.MaxFilter(17)))

    for shape, top, bottom, span in (
        (fins, GOLD, BROWN, (110, 280)),
        (struts, BROWN, DARK, (290, 330)),
        (gondola, GOLD, BROWN, (318, 380)),
        (propeller, TAN, BROWN, (330, 370)),
        (balloon, (245, 200, 110), (70, 42, 4), (100, 300)),
    ):
        icon.alpha_composite(Image.composite(gradient(top, bottom, *span), empty, mask(shape)))

    def ribs(draw):
        draw.ellipse((60, 150, 470, 240), outline=DARK + (230,), width=12)
        for x in (200, 330):
            draw.line((x, 92, x, 298), fill=DARK + (220,), width=12)

    inside = mask(balloon).filter(ImageFilter.MinFilter(9))
    icon.alpha_composite(Image.composite(layer(ribs), empty, inside))
    icon.alpha_composite(layer(lambda d: d.ellipse(BALLOON, outline=TAN + (255,), width=14)))
    icon.alpha_composite(layer(lambda d: d.arc((120, 110, 420, 230), 200, 320, fill=(255, 240, 190, 230), width=12)))
    icon.alpha_composite(layer(lambda d: d.rounded_rectangle(GONDOLA, radius=24, outline=TAN + (255,), width=10)))
    icon.alpha_composite(
        layer(
            lambda d: [
                d.rounded_rectangle((x, 336, x + 26, 366), radius=5, fill=DARK + (255,)) for x in (200, 244, 288)
            ]
        )
    )

    icon = icon.crop(icon.getbbox())
    side = max(icon.size)
    square = Image.new("RGBA", (side, side))
    square.alpha_composite(icon, ((side - icon.width) // 2, (side - icon.height) // 2))
    OUTPUT.parent.mkdir(exist_ok=True)
    square.resize((64, 64), Image.LANCZOS).save(OUTPUT)
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
