#!/usr/bin/env python3
"""从 desktop/build/appicon.png 生成安卓各密度启动图标。

背景：Windows / macOS 用的是 build/appicon.png（wails3 会把它转成
build/windows/icon.ico、darwin 的 icns），而安卓侧一直是 Wails 模板自带的
默认图标（字母 W），两端图标长期不一致。

改了 appicon.png 之后跑一次这个脚本即可对齐：

    cd desktop && python build/android/scripts/gen-icons.py

生成物（相对 build/android/app/src/main/res）：
    mipmap-<密度>/ic_launcher.png            传统图标，保留圆角方块底
    mipmap-<密度>/ic_launcher_round.png      圆形图标（供 android:roundIcon）
    mipmap-<密度>/ic_launcher_foreground.png 自适应图标前景（108dp 满幅）
    mipmap-anydpi-v26/ic_launcher.xml        自适应图标（API 26+）
    mipmap-anydpi-v26/ic_launcher_round.xml
    values/ic_launcher_background.xml        自适应图标背景色

自适应图标为什么用「满幅 + 裁掉一点边」：appicon.png 自带圆角方块和一圈浅色
描边，若原样塞进 66% 安全区，桌面上会变成「形状里套一个形状」。这里先裁掉
6% 的外边（去掉透明角与描边），再铺满 108dp，让启动器的遮罩成为唯一的外轮廓，
视觉上与 Windows 的圆角方块一致；书本图案在中心约 50%，任何遮罩都不会切到它。
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# 脚本在 desktop/build/android/scripts/ 下：parents[1] = desktop/build/
HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "appicon.png"
RES = HERE.parent / "app" / "src" / "main" / "res"

# 传统图标边长（dp 48）
LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# 自适应图标前景边长（108dp）
FOREGROUND_SIZES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

# 自适应背景色：取自 appicon.png 的渐变中段。前景满幅时只在遮罩边缘露出一点。
BACKGROUND_COLOR = "#6A5AE0"

# 前景裁边比例（相对边长）：去掉透明圆角与最外层描边。
# appicon 的圆角半径约 22%，要让裁掉后的四角落在圆角方块内部，
# 至少需要 r*(1-1/√2) ≈ 6.4%，取 8% 留一点余量。
FOREGROUND_INSET = 0.08

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{color}</color>
</resources>
"""


def circle_mask(size: int) -> Image.Image:
    """画一个抗锯齿的圆形遮罩。

    直接在目标尺寸画圆，边缘会有锯齿；先按 4 倍画再缩小，边缘就平滑了。
    """
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(big)
    draw.ellipse((0, 0, size * scale - 1, size * scale - 1), fill=255)
    return big.resize((size, size), Image.LANCZOS)


def inset_crop(im: Image.Image, ratio: float) -> Image.Image:
    w, h = im.size
    dx, dy = int(w * ratio), int(h * ratio)
    return im.crop((dx, dy, w - dx, h - dy))


def flatten(im: Image.Image) -> Image.Image:
    """把透明像素压到底色上。

    自适应图标的前景层若留透明，启动器会用 background 色填进来，而 background
    是纯色、原图是渐变，两者在角落会形成一道可见的接缝。这里直接合成掉。
    """
    canvas = Image.new("RGBA", im.size, BACKGROUND_COLOR)
    canvas.alpha_composite(im)
    return canvas


def main() -> int:
    if not SOURCE.exists():
        print(f"找不到源图标: {SOURCE}", file=sys.stderr)
        return 1

    src = Image.open(SOURCE).convert("RGBA")
    if src.width != src.height:
        print(f"源图标必须是正方形，当前 {src.size}", file=sys.stderr)
        return 1

    written = 0
    for density, size in LEGACY_SIZES.items():
        out_dir = RES / f"mipmap-{density}"
        out_dir.mkdir(parents=True, exist_ok=True)

        legacy = src.resize((size, size), Image.LANCZOS)
        legacy.save(out_dir / "ic_launcher.png")

        # 圆形图标先裁掉外边再遮罩：appicon 自带一圈浅色描边，若直接按原尺寸
        # 切圆，描边会正好落在圆的最外沿，看起来像一圈白边。
        rounded = inset_crop(src, FOREGROUND_INSET).resize((size, size), Image.LANCZOS)
        rounded.putalpha(circle_mask(size))
        rounded.save(out_dir / "ic_launcher_round.png")

        fg = inset_crop(src, FOREGROUND_INSET).resize(
            (FOREGROUND_SIZES[density], FOREGROUND_SIZES[density]), Image.LANCZOS
        )
        flatten(fg).save(out_dir / "ic_launcher_foreground.png")

        written += 3
        print(f"  mipmap-{density}: {size}px 图标 + {FOREGROUND_SIZES[density]}px 前景")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (anydpi / name).write_text(ADAPTIVE_XML, encoding="utf-8")
        written += 1

    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        BACKGROUND_XML.format(color=BACKGROUND_COLOR), encoding="utf-8"
    )
    written += 1

    print(f"完成：{written} 个文件写到 {RES}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
