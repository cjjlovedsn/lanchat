#!/usr/bin/env python3
"""Render the editable LanChat SVG into platform icons (requires Pillow).

The deliberately small SVG vocabulary keeps the brand build portable: the
master uses rounded rectangles, diagonal gradient and M/L/H/V/Q/Z paths.
Usage: python3 tool/generate_brand_assets.py [--preview-only]
"""
from pathlib import Path
import argparse
import re
import shutil
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / 'assets/brand/lanchat.svg'
BRAND = SVG.parent
OUTPUT = ROOT.parent / 'outputs'
SCALE = 2
SIZE = 1024


def rgb(value):
    value = value.lstrip('#')
    return tuple(int(value[i:i+2], 16) for i in (0, 2, 4))


def points(path):
    tokens = re.findall(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+)', path)
    result = []
    current = (0., 0.)
    first = None
    index = 0
    command = None
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command == 'Z':
            result.append(first)
            current = first
            command = None
            continue
        count = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'Q': 4}.get(command)
        if count is None:
            raise ValueError(f'Unsupported SVG path command: {command}')
        values = list(map(float, tokens[index:index+count]))
        index += count
        if command in ('M', 'L'):
            current = tuple(values)
            result.append(current)
            if first is None:
                first = current
            if command == 'M':
                command = 'L'
        elif command == 'H':
            current = (values[0], current[1]); result.append(current)
        elif command == 'V':
            current = (current[0], values[0]); result.append(current)
        elif command == 'Q':
            start = current
            control = values[:2]
            end = values[2:]
            for step in range(1, 49):
                t = step / 48
                result.append(tuple((1-t)**2*start[n] + 2*(1-t)*t*control[n] + t*t*end[n] for n in (0, 1)))
            current = tuple(end)
    return result


def render():
    tree = ET.parse(SVG)
    ns = {'s': 'http://www.w3.org/2000/svg'}
    side = SIZE * SCALE
    gradient = Image.new('RGBA', (side, side))
    draw = ImageDraw.Draw(gradient)
    stops = [(float(stop.attrib['offset']), rgb(stop.attrib['stop-color']))
             for stop in tree.findall('.//s:linearGradient/s:stop', ns)]
    for diagonal in range(side * 2 - 1):
        t = diagonal / (2 * side - 2)
        left, right = next(((a, b) for a, b in zip(stops, stops[1:]) if a[0] <= t <= b[0]), stops[-2:])
        fraction = (t-left[0]) / (right[0]-left[0])
        color = tuple(round(a+(b-a)*fraction) for a, b in zip(left[1], right[1])) + (255,)
        draw.line([(0, diagonal), (diagonal, 0)], fill=color)
    mask = Image.new('L', (side, side))
    ImageDraw.Draw(mask).rounded_rectangle((96*SCALE,96*SCALE,928*SCALE,928*SCALE), radius=190*SCALE, fill=255)
    tile = gradient.copy(); tile.putalpha(mask)
    shadow_mask = Image.new('L', (side, side))
    ImageDraw.Draw(shadow_mask).rounded_rectangle((96*SCALE,108*SCALE,928*SCALE,940*SCALE), radius=190*SCALE, fill=41)
    shadow = Image.new('RGBA', (side, side), (22,59,114,0))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(12*SCALE)))
    tile = Image.alpha_composite(shadow, tile)
    ImageDraw.Draw(tile).rounded_rectangle((97*SCALE,97*SCALE,927*SCALE,927*SCALE), radius=189*SCALE,
        outline=(255,255,255,41), width=2*SCALE)
    glyph = Image.new('RGBA', (side, side))
    draw = ImageDraw.Draw(glyph)
    for path in tree.findall('.//s:g/s:path', ns):
        vertices = [(round(x*SCALE),round(y*SCALE)) for x,y in points(path.attrib['d'])]
        draw.line(vertices, fill=rgb(path.attrib['stroke'])+(255,), width=64*SCALE, joint='curve')
    icon = Image.alpha_composite(tile, glyph)
    return icon.resize((SIZE,SIZE), Image.Resampling.LANCZOS), glyph.resize((SIZE,SIZE), Image.Resampling.LANCZOS)


def save_png(image, path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size,size), Image.Resampling.LANCZOS).save(path)


def font(size, bold=False):
    names = ['Arial Bold.ttf' if bold else 'Arial.ttf', 'Verdana Bold.ttf' if bold else 'Verdana.ttf']
    for name in names:
        path = Path('/System/Library/Fonts/Supplemental') / name
        if path.exists(): return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def preview(icon):
    sheet = Image.new('RGB', (1400,800), '#EEF3F9')
    draw = ImageDraw.Draw(sheet)
    draw.rounded_rectangle((28,28,696,772), radius=32, fill='white')
    sheet.paste(icon.resize((480,480),Image.Resampling.LANCZOS),(122,60),icon.resize((480,480),Image.Resampling.LANCZOS))
    draw.text((362,580),'LanChat',fill='#1D2D48',font=font(62,True),anchor='mm')
    draw.text((362,644),'APP ICON  /  EDITABLE VECTOR',fill='#7C899D',font=font(15),anchor='mm')
    draw.rounded_rectangle((724,28,1372,430),radius=32,fill='#101823')
    small=icon.resize((240,240),Image.Resampling.LANCZOS)
    sheet.paste(small,(762,82),small)
    draw.text((1010,182),'LanChat',fill='#F0F5FF',font=font(48,True),anchor='lm')
    draw.text((1012,232),'DARK SURFACE',fill='#8295AF',font=font(14),anchor='lm')
    draw.rounded_rectangle((724,454,1372,772),radius=32,fill='white')
    draw.text((760,486),'SMALL-SIZE LEGIBILITY',fill='#7C899D',font=font(14))
    for x,size in [(794,16),(910,32),(1030,64),(1180,96)]:
        image=icon.resize((size,size),Image.Resampling.LANCZOS)
        sheet.paste(image,(x-size//2,596-size//2),image)
        draw.text((x,676),str(size)+' px',fill='#67758B',font=font(15),anchor='mm')
    sheet.save(OUTPUT/'lanchat-logo-preview.png')


def generate_platforms(icon,glyph):
    for size in [16,32,64,128,256,512,1024]:
        save_png(icon,ROOT/f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png',size)
    ico_sizes=[(n,n) for n in [16,24,32,48,64,128,256]]
    for path in [ROOT/'windows/runner/resources/app_icon.ico',ROOT/'assets/tray_icon.ico']:
        icon.save(path,format='ICO',sizes=ico_sizes)
    save_png(icon,ROOT/'assets/tray_icon.png',64)
    # A template image follows the macOS menu bar's light/dark appearance.
    crop=glyph.crop(glyph.getbbox())
    monochrome=Image.new('RGBA',crop.size,(0,0,0,255));monochrome.putalpha(crop.getchannel('A'))
    monochrome.thumbnail((28,28),Image.Resampling.LANCZOS)
    tray=Image.new('RGBA',(32,32));tray.alpha_composite(monochrome,((32-monochrome.width)//2,(32-monochrome.height)//2))
    tray.save(ROOT/'assets/tray_icon_template.png')
    for density,size,foreground in [('mdpi',48,108),('hdpi',72,162),('xhdpi',96,216),('xxhdpi',144,324),('xxxhdpi',192,432)]:
        target=ROOT/f'android/app/src/main/res/mipmap-{density}'
        save_png(icon,target/'ic_launcher.png',size)
        # Modern Android supplies the mask and background separately.
        save_png(glyph,target/'ic_launcher_foreground.png',foreground)
    adaptive=ROOT/'android/app/src/main/res/mipmap-anydpi-v26';adaptive.mkdir(exist_ok=True)
    (adaptive/'ic_launcher.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/lanchat_icon_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
''')
    (ROOT/'android/app/src/main/res/drawable/lanchat_icon_background.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:angle="315" android:startColor="#3974F8" android:centerColor="#2858D6" android:endColor="#118F8C" />
</shape>
''')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--preview-only',action='store_true');args=parser.parse_args()
    OUTPUT.mkdir(exist_ok=True)
    icon,glyph=render()
    icon.save(BRAND/'lanchat_icon.png');glyph.save(BRAND/'lanchat_mark.png')
    icon.crop((96,96,928,928)).save(BRAND/'lanchat_badge.png')
    icon.save(OUTPUT/'lanchat-logo.png');shutil.copy2(SVG,OUTPUT/'lanchat-logo.svg')
    preview(icon)
    if not args.preview_only:generate_platforms(icon,glyph)
    print('LanChat brand assets generated from assets/brand/lanchat.svg')

if __name__=='__main__':main()
