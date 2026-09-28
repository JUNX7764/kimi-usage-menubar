#!/usr/bin/env python3
"""KimiUsage 图标候选设计：A=双环仪表，B=堆叠电量条。4x 超采样渲染。"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4096          # 渲染尺寸（4x）
OUT = 1024        # 主尺寸
BOX = (S - 3296) // 2   # macOS 图标安全区 824/1024 -> 3296
RAD = int(3296 * 0.2237)  # squircle 圆角

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def squircle_mask():
    m = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([BOX, BOX, S - BOX, S - BOX], radius=RAD, fill=255)
    return m

def vgrad(top, bottom):
    t = np.linspace(0, 1, S)[:, None, None]
    top = np.array(top, float)[None, None, :]
    bot = np.array(bottom, float)[None, None, :]
    arr = (top * (1 - t) + bot * t).astype(np.uint8)
    return Image.fromarray(np.repeat(arr, S, axis=1), 'RGB')

def radial_glow(cx, cy, r, color, peak):
    y, x = np.mgrid[0:S, 0:S].astype(float)
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / r
    a = np.clip(1 - d, 0, 1) ** 2 * peak
    g = np.zeros((S, S, 4), np.uint8)
    g[..., 0], g[..., 1], g[..., 2] = color
    g[..., 3] = a.astype(np.uint8)
    return Image.fromarray(g, 'RGBA')

def base_bg():
    bg = vgrad((30, 41, 92), (8, 12, 34)).convert('RGBA')          # 深空蓝渐变
    bg.alpha_composite(radial_glow(S*0.32, S*0.26, S*0.75, (88, 120, 255), 64))
    bg.alpha_composite(radial_glow(S*0.78, S*0.85, S*0.6, (40, 210, 255), 30))
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(bg, (0, 0), squircle_mask())
    return out

def ring_layer(center, radius, width, frac, c0, c1, start=-90):
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    steps = max(2, int(360 * frac))
    bb = [center - radius, center - radius, center + radius, center + radius]
    for i in range(steps):
        t = i / (steps - 1)
        d.arc(bb, start + i, start + i + 1.6, fill=lerp(c0, c1, t) + (255,), width=width)
    for t, ang in [(0, start), (1, start + 360 * frac)]:
        rr = math.radians(ang)
        x = center + radius * math.cos(rr)
        y = center + radius * math.sin(rr)
        d.ellipse([x - width/2, y - width/2, x + width/2, y + width/2],
                  fill=lerp(c0, c1, t) + (255,))
    return layer

def design_rings():
    icon = base_bg()
    c = S / 2
    # 轨道底圈（半透明）
    track = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(track)
    for r_, w_ in [(S*0.295, S*0.062), (S*0.185, S*0.054)]:
        bb = [c - r_, c - r_, c + r_, c + r_]
        td.arc(bb, 0, 360, fill=(255, 255, 255, 26), width=int(w_))
    icon.alpha_composite(track)
    # 外环 5H ~92%：青→蓝
    outer = ring_layer(c, S*0.295, int(S*0.062), 0.92, (94, 227, 255), (59, 130, 246))
    # 内环 7D ~76%：紫→蓝紫
    inner = ring_layer(c, S*0.185, int(S*0.054), 0.76, (167, 139, 250), (99, 102, 241))
    for lay in (outer, inner):
        glow = lay.filter(ImageFilter.GaussianBlur(S*0.012))
        icon.alpha_composite(glow)
        icon.alpha_composite(lay)
    return icon

def design_bars():
    icon = base_bg()
    d = ImageDraw.Draw(icon)
    bw, bh = S*0.56, S*0.115
    x0 = (S - bw) / 2
    bars = [(S*0.415, 0.90, (94, 227, 255), (59, 130, 246)),
            (S*0.600, 0.74, (167, 139, 250), (99, 102, 241))]
    for cy, frac, c0, c1 in bars:
        y0 = cy - bh / 2
        # 容器：磨砂玻璃
        d.rounded_rectangle([x0, y0, x0 + bw, y0 + bh], radius=bh/2,
                            fill=(255, 255, 255, 24), outline=(255, 255, 255, 60),
                            width=int(S*0.002))
        # 填充：横向渐变
        fw = bw * frac
        grad = Image.new('RGBA', (int(fw), int(bh)), (0, 0, 0, 0))
        gx = np.linspace(0, 1, int(fw))[None, :, None]
        arr = (np.array(c0, float)[None, None, :] * (1 - gx) +
               np.array(c1, float)[None, None, :] * gx).astype(np.uint8)
        arr = np.repeat(arr, int(bh), axis=0)
        fill = Image.fromarray(np.dstack([arr, np.full(arr.shape[:2] + (1,), 255, np.uint8)]), 'RGBA')
        fmask = Image.new('L', (int(fw), int(bh)), 0)
        ImageDraw.Draw(fmask).rounded_rectangle([0, 0, fw, bh], radius=bh/2, fill=255)
        glow = fill.filter(ImageFilter.GaussianBlur(S*0.010))
        icon.paste(glow, (int(x0), int(y0)), fmask)
        icon.paste(fill, (int(x0), int(y0)), fmask)
    return icon

def finish(icon, name):
    small = icon.resize((OUT, OUT), Image.LANCZOS)
    small.save(f'/Users/Chester/Documents/kimi/workspace/kimi-usage-menubar/{name}.png')
    return small

ra = design_rings()
ra.save('/Users/Chester/Documents/kimi/workspace/kimi-usage-menubar/icon_master.png')
a = finish(ra, 'icon_candidate_a')
b = finish(design_bars(), 'icon_candidate_b')

# 从 4096 母版导出全套 iconset 尺寸
import os
iset = '/Users/Chester/Documents/kimi/workspace/kimi-usage-menubar/AppIcon.iconset'
os.makedirs(iset, exist_ok=True)
for name, px in [('icon_16x16.png', 16), ('icon_16x16@2x.png', 32),
                 ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
                 ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256),
                 ('icon_256x256.png', 256), ('icon_256x256@2x.png', 512),
                 ('icon_512x512.png', 512), ('icon_512x512@2x.png', 1024)]:
    ra.resize((px, px), Image.LANCZOS).save(f'{iset}/{name}')
print('iconset done')

# 并排对比图（白底 + 深灰底各一半，模拟不同 Finder 背景）
sheet = Image.new('RGBA', (OUT*2 + 120, OUT + 160), (244, 244, 246, 255))
sheet.alpha_composite(a, (40, 60))
sheet.alpha_composite(b, (OUT + 80, 60))
sheet.convert('RGB').save('/Users/Chester/Documents/kimi/workspace/kimi-usage-menubar/icon_compare.png')
print('done')
