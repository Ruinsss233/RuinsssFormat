"""Generate app icons for Ruinsss格式快转 from the supplied artwork.

The attachment lives outside the workspace and is read-only; output is written
into AppScope/resources/base/media (app icon) and entry/.../media (start icon).
"""
from pathlib import Path
from PIL import Image

SRC = Path(r"C:\Users\Administartor\.dsh\attachments\v1\objects\41"
           r"\41d3abc9274657e128d88bdbd33d9f5d8afbf372e59d7987ba4a95eef7b34b0f")
ROOT = Path(r"D:\DSH\RuinsssFormat")
APP_MEDIA = ROOT / "AppScope" / "resources" / "base" / "media"
ENTRY_MEDIA = ROOT / "entry" / "src" / "main" / "resources" / "base" / "media"

img = Image.open(SRC).convert("RGB")
print("source", img.size)

# Trim only the thin outer keyline. The artwork itself already has generous
# safe-area padding, which is exactly what a masked HarmonyOS icon wants.
trim = 8
img = img.crop((trim, trim, img.width - trim, img.height - trim))

APP_MEDIA.mkdir(parents=True, exist_ok=True)
ENTRY_MEDIA.mkdir(parents=True, exist_ok=True)

# Full-bleed app icon, downscaled with Lanczos for clean pixel-art edges.
icon = img.resize((1024, 1024), Image.Resampling.LANCZOS)
icon.save(APP_MEDIA / "app_icon.png", optimize=True)
# The start window icon is shown smaller; a 512 copy keeps the HAP lean.
start = img.resize((512, 512), Image.Resampling.LANCZOS)
start.save(ENTRY_MEDIA / "startIcon.png", optimize=True)

# A small in-app brand mark with rounded corners, drawn on transparent canvas.
mark = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
small = img.resize((256, 256), Image.Resampling.LANCZOS).convert("RGBA")
mask = Image.new("L", (256, 256), 0)
from PIL import ImageDraw
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 255, 255), radius=58, fill=255)
mark.paste(small, (0, 0), mask)
mark.save(ENTRY_MEDIA / "brand_mark.png", optimize=True)

print("wrote", APP_MEDIA / "app_icon.png", icon.size)
print("wrote", ENTRY_MEDIA / "startIcon.png", start.size)
print("wrote", ENTRY_MEDIA / "brand_mark.png", mark.size)
