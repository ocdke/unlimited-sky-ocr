"""生成多语种 OCR 测试图 (日语 / 俄语 / 韩语 / 英语)"""
from PIL import Image, ImageDraw, ImageFont
import os

OUT = r"E:\dpg\docs"
os.makedirs(OUT, exist_ok=True)

# 用系统字体, 保证假名/谚文/西里尔都能画出来
CANDIDATES = [
    (r"C:\Windows\Fonts\meiryo.ttc", "ja"),
    (r"C:\Windows\Fonts\YuGothM.ttc", "ja"),
    (r"C:\Windows\Fonts\malgun.ttf", "ko"),
    (r"C:\Windows\Fonts\msyh.ttc", "zh"),
    (r"C:\Windows\Fonts\arial.ttf", "en"),
]


def font_for(tag: str, size: int):
    for path, t in CANDIDATES:
        if t == tag and os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    for path, _ in CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()


CASES = {
    "ja": [
        "全画面OCR認識と翻訳のテストです。",
        "このソフトは日本語を正しく読み取れますか。",
        "ひらがな、カタカナ、漢字が混在しています。",
        "リアルタイム翻訳はとても便利ですね。",
    ],
    "ko": [
        "전체 화면 OCR 인식 및 번역 테스트입니다.",
        "이 소프트웨어는 한국어를 정확하게 읽을 수 있습니까?",
        "한글 자모와 받침이 모두 포함되어 있습니다.",
        "실시간 번역은 매우 편리합니다.",
    ],
    "ru": [
        "Это тест распознавания и перевода текста.",
        "Может ли эта программа правильно читать по-русски?",
        "Проверка заглавных и строчных букв.",
        "Перевод в реальном времени очень удобен.",
    ],
    "en": [
        "This is an OCR recognition and translation test.",
        "Can this software read English correctly?",
        "Mixed case and punctuation: Hello, World!",
        "Real-time translation is very convenient.",
    ],
}

for tag, lines in CASES.items():
    f = font_for(tag, 34)
    img = Image.new("RGB", (1000, 60 + len(lines) * 62), (255, 255, 255))
    d = ImageDraw.Draw(img)
    y = 24
    for ln in lines:
        d.text((28, y), ln, font=f, fill=(15, 15, 15))
        y += 62
    p = os.path.join(OUT, f"ocr_test_{tag}.png")
    img.save(p)
    print("生成", p, img.size)
