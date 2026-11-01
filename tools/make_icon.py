"""Draws the ScanForge Pro launcher icon (orange wireframe cube with scan arcs)."""
import math, os, sys
import cv2
import numpy as np

S = 1024
img = np.zeros((S, S, 4), np.uint8)
# rounded dark square
mask = np.zeros((S, S), np.uint8)
r = 220
cv2.rectangle(mask, (r, 0), (S - r, S), 255, -1)
cv2.rectangle(mask, (0, r), (S, S - r), 255, -1)
for cx, cy in [(r, r), (S - r, r), (r, S - r), (S - r, S - r)]:
    cv2.circle(mask, (cx, cy), r, 255, -1, cv2.LINE_AA)
yy, xx = np.mgrid[0:S, 0:S]
grad = (np.clip(1 - np.hypot(xx - S * 0.5, yy - S * 0.42) / (S * 0.8), 0, 1) * 30).astype(np.uint8)
img[..., 0] = 22 + grad
img[..., 1] = 18 + grad
img[..., 2] = 15 + grad
img[..., 3] = mask
orange = (31, 138, 255, 255)  # BGRA
c = np.array([S / 2, S / 2 + 30])
a = 250
# isometric cube
top = c + [0, -a]
pts = {
    't': c + [0, -a], 'tl': c + [-a * 0.87, -a * 0.5], 'tr': c + [a * 0.87, -a * 0.5],
    'm': c, 'bl': c + [-a * 0.87, a * 0.5], 'br': c + [a * 0.87, a * 0.5], 'b': c + [0, a],
}
def P(k): return tuple(int(v * 16) for v in pts[k])
# filled faces
faces = [(['t', 'tr', 'm', 'tl'], (60, 160, 255, 255)), (['tl', 'm', 'b', 'bl'], (20, 110, 230, 255)),
         (['m', 'tr', 'br', 'b'], (10, 80, 190, 255))]
for f, col in faces:
    poly = np.array([pts[k] for k in f], np.int32)
    cv2.fillConvexPoly(img, poly, col, cv2.LINE_AA)
for e in [('t', 'tr'), ('tr', 'm'), ('m', 'tl'), ('tl', 't'), ('tl', 'bl'), ('bl', 'b'), ('b', 'br'), ('br', 'tr'), ('m', 'b')]:
    cv2.line(img, P(e[0]), P(e[1]), (230, 240, 255, 255), 14, cv2.LINE_AA, 4)
# scan arcs
for rad, th in [(400, 22), (455, 14)]:
    cv2.ellipse(img, (int(c[0]), int(c[1])), (rad, int(rad * 0.42)), 0, 15, 165, orange, th, cv2.LINE_AA)
img[..., 3] = np.minimum(img[..., 3], mask)
out = sys.argv[1]
for name, px in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    d = os.path.join(out, f'mipmap-{name}')
    os.makedirs(d, exist_ok=True)
    cv2.imwrite(os.path.join(d, 'ic_launcher.png'), cv2.resize(img, (px, px), interpolation=cv2.INTER_AREA))
cv2.imwrite(os.path.join(out, 'icon_1024.png'), img)
