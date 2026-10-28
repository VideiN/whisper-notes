"""임시 앱 아이콘 (2026-10-28, TestFlight에 올리려면 아이콘이 있어야 해서): 남색 바탕, 흰 강의자료 한 장(글 줄, 주황 필기 밑줄),
오른쪽에 청록 소리 막대 (녹음·전사). App Store Connect가 받는 1024x1024 불투명 PNG를 만든다.
모서리는 iPadOS가 둥글게 자른다.

사용법: python scripts/make-app-icon.py WhisperNotes/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (Pillow 필요)
"""

import math
import sys

from PIL import Image, ImageDraw

out = sys.argv[1]
N = 4096  # 크게 그린 뒤 줄여 가장자리를 매끈하게
img = Image.new("RGB", (N, N))
draw = ImageDraw.Draw(img)
# 남색 세로 그라데이션 (위가 조금 밝게)
top, bottom = (40, 58, 120), (14, 20, 52)
for y in range(N):
    t = y / (N - 1)
    draw.line([(0, y), (N, y)], fill=tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))

white = (246, 247, 251)
gray = (196, 202, 216)
orange = (255, 159, 67)
teal = (64, 214, 200)

# 강의자료: 왼쪽으로 비킨 세로로 긴 종이
px0, py0, px1, py1 = N * 0.13, N * 0.18, N * 0.52, N * 0.82
draw.rounded_rectangle([px0, py0, px1, py1], radius=N * 0.035, fill=white)

# 글 줄
bar = N * 0.026
base = py0 + N * 0.10
spacing = N * 0.10
for i, length in enumerate((0.85, 0.65, 0.75, 0.55, 0.70)):
    y = base + i * spacing
    x0 = px0 + N * 0.05
    draw.rounded_rectangle([x0, y, x0 + (px1 - px0 - N * 0.10) * length, y + bar], radius=bar / 2, fill=gray)

# 필기: 둘째 줄 아래를 지나는 주황 물결 밑줄 (셋째 줄에 닿지 않게)
stroke = round(N * 0.024)
wave = []
for k in range(121):
    t = k / 120
    x = px0 + N * 0.045 + t * (px1 - px0 - N * 0.09)
    y = base + spacing + bar + N * 0.034 + math.sin(t * math.tau * 2.2) * N * 0.010
    wave.append((x, y))
draw.line(wave, fill=orange, width=stroke, joint="curve")
for x, y in (wave[0], wave[-1]):  # 끝을 둥글게
    draw.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=orange)

# 소리 막대: 종이 오른쪽, 가운데를 기준으로 위아래 대칭
cy = N * 0.5
width = N * 0.04
gap = N * 0.025
x = px1 + N * 0.06
for height in (0.10, 0.22, 0.34, 0.20, 0.12):
    h = N * height
    draw.rounded_rectangle([x, cy - h / 2, x + width, cy + h / 2], radius=width / 2, fill=teal)
    x += width + gap

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save(out, "PNG", optimize=True)
print("saved", out, icon.size, icon.mode)
