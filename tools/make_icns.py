#!/usr/bin/env python3
"""1024px PNG -> Resources/AppIcon.icns (16~512 at 1x and @2x, PNG entries). Pillow 필요.
SVG 렌더 예: google-chrome --headless --default-background-color=00000000 --window-size=1024,1024 \\
  --screenshot=icon-1024.png Resources/AppIcon.svg  (macOS면 qlmanage/Safari 등 아무 SVG 렌더러나 OK)
사용법: tools/make_icns.py icon-1024.png [Resources/AppIcon.icns]"""
import io, struct, sys
from PIL import Image

src = Image.open(sys.argv[1]).convert("RGBA")
assert src.size == (1024, 1024), "1024x1024 PNG가 필요해요"
out = sys.argv[2] if len(sys.argv) > 2 else "Resources/AppIcon.icns"
# OSType -> 픽셀 크기 (ic11/12/13/14/10 = 16/32/128/256/512 @2x)
TYPES = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
         ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
pngs = {}
body = b""
for t, sz in TYPES:
    if sz not in pngs:
        im = src if sz == 1024 else src.resize((sz, sz), Image.LANCZOS)
        b = io.BytesIO(); im.save(b, "PNG", optimize=True); pngs[sz] = b.getvalue()
    body += t.encode() + struct.pack(">I", 8 + len(pngs[sz])) + pngs[sz]
open(out, "wb").write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
print(out, 8 + len(body), "bytes")
