# 从 logo 源图生成 Windows 图标 (.ico)
#
# 源图是白底黑线的"无"字。生成两种取向:
#   * app.ico      白底圆角方块 + 黑色字形  -> 用于应用/快捷方式/安装包
#   * 小尺寸会适当加粗描边, 否则 16/24px 下细线糊成一团

from PIL import Image, ImageDraw, ImageFilter
import os

SRC = r"E:\dpg\docs\logo_src.png"
OUT_DIR = r"E:\dpg\assets"
os.makedirs(OUT_DIR, exist_ok=True)

SIZES = [256, 128, 64, 48, 40, 32, 24, 20, 16]


def load_glyph_mask(size: int) -> Image.Image:
    """把源图里的黑色字形提取成 L 通道蒙版 (255=字形)"""
    im = Image.open(SRC).convert("L")
    # 源图白底黑线 -> 取反得到"字形=亮"
    inv = im.point(lambda v: 255 - v)
    # 裁掉四周空白
    bbox = inv.point(lambda v: 255 if v > 40 else 0).getbbox()
    if bbox:
        inv = inv.crop(bbox)
    # 等比缩放到目标尺寸的 72%
    target = max(1, int(size * 0.72))
    w, h = inv.size
    scale = target / max(w, max(h, 1))
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    inv = inv.resize((nw, nh), Image.LANCZOS)

    # 小尺寸是难点: 原字形是细线, 直接缩小会糊成一团灰。
    # 两步处理 —— 先加粗, 再把灰色拉黑, 保证 16px 下也能看清。
    if size <= 64:
        inv = inv.filter(ImageFilter.MaxFilter(3))
    if size <= 32:
        inv = inv.filter(ImageFilter.MaxFilter(3))
        inv = inv.point(lambda v: 255 if v >= 60 else min(255, int(v * 3.2)))
    else:
        # 中大尺寸也做一点对比度提升, 避免边缘发灰
        inv = inv.point(lambda v: min(255, int(v * 1.35)))

    canvas = Image.new("L", (size, size), 0)
    canvas.paste(inv, ((size - nw) // 2, (size - nh) // 2))
    return canvas


def make_icon(size: int) -> Image.Image:
    """白底圆角方块 + 黑色字形"""
    # 4 倍超采样再缩, 边缘更干净
    ss = 4
    big = size * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(big * 0.22)
    # 纯白底 (和源图一致, 在深色任务栏上也醒目)
    d.rounded_rectangle([0, 0, big - 1, big - 1], radius=radius, fill=(255, 255, 255, 255))
    mask = load_glyph_mask(big)
    glyph = Image.new("RGBA", (big, big), (17, 17, 17, 255))
    img.paste(glyph, (0, 0), mask)
    return img.resize((size, size), Image.LANCZOS)


frames = [make_icon(s) for s in SIZES]
ico_path = os.path.join(OUT_DIR, "app.ico")
frames[0].save(ico_path, format="ICO",
               sizes=[(s, s) for s in SIZES], append_images=frames[1:])
print(f"生成 {ico_path}  尺寸: {SIZES}")

# 顺便出一张 512 的 PNG 给安装程序界面用
make_icon(512).save(os.path.join(OUT_DIR, "logo512.png"))
# 深色背景下用的反色版 (安装程序头部是深色)
dark = make_icon(512)
px = dark.load()
for y in range(512):
    for x in range(512):
        r, g, b, a = px[x, y]
        if a > 0:
            # 白底 -> 深色底; 黑字形 -> 亮色
            if r > 200 and g > 200 and b > 200:
                px[x, y] = (26, 29, 36, 255)
            else:
                px[x, y] = (235, 240, 248, 255)
dark.save(os.path.join(OUT_DIR, "logo512_dark.png"))
print("生成 logo512.png / logo512_dark.png")
