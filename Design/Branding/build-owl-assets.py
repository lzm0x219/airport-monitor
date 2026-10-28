"""Run swift Design/Branding/render-owl.swift, then this script with Pillow."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops, ImageDraw

root = Path(__file__).resolve().parents[2]
brand = root / 'Design/Branding'
source = Image.open(brand / 'owl-render.png').convert('RGB')
mask = source.convert('L').point(lambda value: 255 if value < 200 else 0)
bounds = mask.getbbox()
owl = source.crop(bounds)
alpha = mask.crop(bounds)
# App tile remains flat: white rounded square, black owl and vermilion beak.
size = 2048
tile = Image.new('RGBA', (size, size))
ImageDraw.Draw(tile).rounded_rectangle((104, 104, 1944, 1944), radius=410, fill='white')
owl.thumbnail((1460, 1460), Image.Resampling.LANCZOS)
alpha = alpha.resize(owl.size, Image.Resampling.LANCZOS)
tile.paste(owl, ((size-owl.width)//2, (size-owl.height)//2), alpha)
assets = root / 'Sources/App/Assets.xcassets'
for item in json.loads((assets / 'AppIcon.appiconset/Contents.json').read_text())['images']:
    pixels = int(item['size'].split('x')[0]) * int(item['scale'][0])
    tile.resize((pixels, pixels), Image.Resampling.LANCZOS).save(assets / 'AppIcon.appiconset' / item['filename'])
# Template icon: white eyes and colored beak become transparent cutouts.
menu_alpha = source.convert('L').point(lambda value: 255 if value < 80 else 0).crop(bounds)
for scale in (1, 2):
    canvas = Image.new('RGBA', (18*scale, 18*scale))
    shape = menu_alpha.copy()
    shape.thumbnail((18*scale, 16*scale), Image.Resampling.LANCZOS)
    ink = Image.new('RGBA', shape.size, 'black')
    ink.putalpha(shape)
    canvas.alpha_composite(ink, ((18*scale-shape.width)//2, (18*scale-shape.height)//2))
    canvas.save(assets / 'MenuBarIcon.imageset' / ('MenuBarIcon' + ('@2x' if scale == 2 else '') + '.png'))
    if scale == 2:
        preview = Image.new('RGBA', (440, 180), 'white')
        preview.alpha_composite(canvas.resize((144, 144), Image.Resampling.NEAREST), (38, 18))
        ImageDraw.Draw(preview).rectangle((220, 0, 440, 180), fill='#202020')
        light = Image.new('RGBA', canvas.size, 'white')
        light.putalpha(canvas.getchannel('A'))
        preview.alpha_composite(light.resize((144, 144), Image.Resampling.NEAREST), (258, 18))
        preview.save(brand / 'MenuBar-Preview.png')
# Editable monochrome source, preserving the selected vector paths through a mask.
tree = ET.parse(brand / 'owl-06-flat-v2.svg')
paths = list(tree.getroot())
parts = []
for index, path in enumerate(paths):
    path.set('fill', 'white' if index == 0 else 'black')
    parts.append(ET.tostring(path, encoding='unicode'))
x0,y0,x1,y1 = [v / 6 for v in bounds]
svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0} {y0} {x1-x0} {y1-y0}"><defs><mask id="owl" maskUnits="userSpaceOnUse" x="0" y="0" width="380" height="340">' + ''.join(parts) + '</mask></defs><rect width="380" height="340" fill="black" mask="url(#owl)"/></svg>'
(brand / 'MenuBarSymbol.svg').write_text(svg)
print('Generated 10 app icon sizes, 2 template menu icons, and vector menu source.')
