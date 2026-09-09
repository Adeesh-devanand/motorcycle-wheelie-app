"""Turn the top-down motorcycle artwork into a TEMPLATE image asset.

    python3 .kiro/tools/make_bike_glyph.py <source.png> <Assets.xcassets>

iOS template rendering uses ONLY the alpha channel and discards colour, so the asset's
alpha has to be the shape we want tinted. Two things have to end up transparent: the
page around the bike, and the white highlight strokes drawn INSIDE it -- those are what
give the silhouette its linework, and if they go opaque the whole thing flattens into a
featureless blob.

The source is dark navy ink with a TRANSPARENT background (RGBA, alpha 0 outside the
bike). Note the trap: `Image.convert("L")` composites RGBA against BLACK, so the
transparent page reads as luminance 0 -- i.e. as maximally dark ink. Deriving alpha from
that inverts the image and makes the background fully opaque, which is exactly what the
first attempt at this did (it reported "cropped to 1254x1254, aspect 1.000" because it
found ink in every corner).

So alpha comes from two factors multiplied:

    alpha = source_alpha x (255 - luminance(RGB))

The first term drops the page, the second drops the white highlights, and both keep
their partial values at edges so anti-aliasing survives. The result is normalised so the
darkest ink reaches full opacity -- navy is only ~L30, not L0, and without this the
silhouette would tint at ~88%.

RGB is set to white throughout; template rendering ignores it, and white keeps the asset
sane if it is ever drawn untinted.

Finally it crops to the ink's bounding box. The glyph is positioned and rotated about
its centre, and the gap in the drawn line is measured from its length, so the frame has
to BE the bike rather than the artwork's white margin.
"""
import json
import pathlib
import sys

from PIL import Image, ImageChops

src = pathlib.Path(sys.argv[1])
catalog = pathlib.Path(sys.argv[2])
name = "BikeTopDown"

img = Image.open(src).convert("RGBA")
source_alpha = img.getchannel("A")
# Luminance of the COLOUR channels only — no compositing, so a transparent pixel's
# arbitrary RGB cannot masquerade as ink. The source_alpha factor discards it anyway.
luminance = img.convert("RGB").convert("L")
inkiness = luminance.point(lambda v: 255 - v)

alpha = ImageChops.multiply(source_alpha, inkiness)

peak = alpha.getextrema()[1]
if peak == 0:
    raise SystemExit("source image has no ink")
alpha = alpha.point(lambda v: min(255, round(v * 255 / peak)))

# Clear the last of the near-transparent noise so the crop is tight.
FLOOR = 6
alpha = alpha.point(lambda v: 0 if v <= FLOOR else v)

bbox = alpha.getbbox()
if bbox is None:
    raise SystemExit("source image is blank after keying")
alpha = alpha.crop(bbox)

out = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
out.putalpha(alpha)

dst_dir = catalog / f"{name}.imageset"
dst_dir.mkdir(parents=True, exist_ok=True)
out.save(dst_dir / f"{name}.png")

# Single-scale universal image, rendered as a template so `.foregroundStyle` tints it.
contents = {
    "images": [
        {"filename": f"{name}.png", "idiom": "universal", "scale": "1x"},
        {"idiom": "universal", "scale": "2x"},
        {"idiom": "universal", "scale": "3x"},
    ],
    "info": {"author": "xcode", "version": 1},
    "properties": {"template-rendering-intent": "template"},
}
(dst_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

w, h = out.size
print(f"wrote {dst_dir}")
print(f"cropped {img.size} -> {w}x{h}, width/height = {w / h:.4f}")
