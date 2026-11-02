"""Renders the small-object Live Scan demo: a 16 mm dice on a wooden table,
seen from about 12 cm, plus matching AR data for the screenshot test.

    python tools/make_demo_dice.py app/test/assets
"""
import json
import math
import os
import sys
import warnings

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import make_demo_can as base  # noqa: E402

warnings.filterwarnings('ignore')
S = 0.016  # dice size (m)
base.TARGET = np.array([0.0, S / 2, 0.0])
base.AZ = math.radians(35)
base.ELEV = math.radians(32)
base.DIST = 0.12
W, H, F = base.W, base.H, base.F


def pips(u, v, n):
    pos = {1: [(0, 0)], 2: [(-1, -1), (1, 1)], 3: [(-1, -1), (0, 0), (1, 1)],
           4: [(-1, -1), (1, -1), (-1, 1), (1, 1)], 5: [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)],
           6: [(-1, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (1, 1)]}[n]
    m = np.zeros(u.shape, bool)
    for a, b in pos:
        m |= (u - a * 0.28) ** 2 + (v - b * 0.28) ** 2 < 0.11 ** 2
    return m


def render():
    c, r, u, f = base.camera()
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    d = ((xs - W / 2) / F)[..., None] * r + (-(ys - H / 2) / F)[..., None] * u + f
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    lo, hi = np.array([-S / 2, 0, -S / 2]), np.array([S / 2, S, S / 2])
    with np.errstate(divide='ignore', invalid='ignore'):
        t1 = (lo - c) / d
        t2 = (hi - c) / d
    tmin = np.minimum(t1, t2).max(-1)
    tmax = np.maximum(t1, t2).min(-1)
    tb = np.where((tmax >= tmin) & (tmax > 0), tmin, np.inf)
    p = c + d * tb[..., None]
    col = np.zeros((H, W, 3))
    nrm = np.zeros((H, W, 3))
    best = tb.copy()
    hit = np.isfinite(tb)
    q = (p - (lo + hi) / 2) / (S / 2)  # -1..1
    for axis, (nv, faces) in enumerate([((1, 0, 0), (3, 4)), ((0, 1, 0), (1, 6)), ((0, 0, 1), (2, 5))]):
        for sign, n in zip((1, -1), faces):
            m = hit & (np.abs(q[..., axis] - sign) < 1e-3)
            oth = [k for k in range(3) if k != axis]
            pp = pips(q[..., oth[0]], q[..., oth[1]], n)
            face = np.where(pp[..., None], np.array([0.08, 0.08, 0.1]), np.array([0.94, 0.93, 0.9]))
            # rounded edges darker
            edge = np.maximum(np.abs(q[..., oth[0]]), np.abs(q[..., oth[1]])) > 0.9
            face = np.where(edge[..., None], face * 0.85, face)
            col[m] = face[m]
            nrm[m] = np.array(nv, float) * sign
    tp = -c[1] / d[..., 1]
    pt = c + d * tp[..., None]
    tp = np.where((tp > 0) & (tp < best), tp, np.inf)
    m = np.isfinite(tp)
    best = np.where(m, tp, best)
    col[m] = base.wood(pt * 0.5 + 0.05)[m]
    nrm[m] = np.array([0, 1.0, 0])
    m = ~np.isfinite(best)
    col[m] = np.array([0.18, 0.19, 0.22])
    nrm[m] = -d[m]
    L = np.array([-0.5, 0.8, 0.45])
    L /= np.linalg.norm(L)
    diff = np.clip((nrm * L).sum(-1), 0, 1)
    pa = c + d * np.where(np.isfinite(best), best, 0)[..., None]
    rr = np.maximum(np.abs(pa[..., 0] + 0.004), np.abs(pa[..., 2] + 0.002))
    shadow = np.where((np.abs(pa[..., 1]) < 1e-5) & np.isfinite(best), np.clip((rr - S * 0.45) / 0.012, 0.45, 1), 1)
    img = col * (0.5 + 0.6 * diff[..., None]) * shadow[..., None]
    # shallow depth of field like a close-up photo: blur the background
    img8 = (np.clip(img, 0, 1) * 255).astype(np.uint8)[..., ::-1]
    blur = cv2.GaussianBlur(img8, (0, 0), 9)
    dist = np.where(np.isfinite(best), best, 5.0)
    k = np.clip(np.abs(dist - base.DIST) / 0.08, 0, 1)[..., None]
    return (img8 * (1 - k) + blur * k).astype(np.uint8)


def hologram():
    pts = []
    step = 0.0011
    cam_az = base.AZ
    for axis, sign in [(0, 1), (0, -1), (2, 1), (2, -1), (1, 1)]:
        g = np.arange(-S / 2 + step / 2, S / 2, step)
        for a in g:
            for b in g:
                p = [0.0, 0.0, 0.0]
                p[axis] = sign * S / 2
                oth = [k for k in range(3) if k != axis]
                p[oth[0]] = a
                p[oth[1]] = b
                p[1] += S / 2 if axis != 1 else S / 2
                if axis == 1:
                    p[1] = S
                    st = 2 if (a + b) > -0.004 else 0
                else:
                    n_az = math.atan2(sign if axis == 0 else 0, sign if axis == 2 else 0)
                    diff = abs((n_az - cam_az + math.pi) % (2 * math.pi) - math.pi)
                    if diff < math.radians(60):
                        st = 2
                    elif diff < math.radians(100):
                        st = 1 if b > 0 else 2
                    else:
                        st = 0
                pts += [p[0], p[1], p[2], st]
    return pts


def main():
    out = sys.argv[1]
    cv2.imwrite(os.path.join(out, 'demo_dice.jpg'), render(), [cv2.IMWRITE_JPEG_QUALITY, 90])
    V, P = base.matrices()
    radius = S * 0.72 * 1.4 + 0.015
    bins = [0] * 72
    seg = int(((base.AZ / (2 * math.pi)) % 1.0) * 24)
    for k in range(-6, 6):
        bins[(seg + k) % 24] = 2
    for k in range(-4, 8):
        bins[24 + (seg + k) % 24] = 2
    for k in range(0, 5):
        bins[48 + (seg + k) % 24] = 1
    data = {'view': V, 'proj': P, 'center': [0.0, -0.01, 0.0], 'radius': radius, 'bottom': -0.01,
            'top': S + 0.03, 'outline': [],
            'progress': {'points': hologram(), 'bins': bins, 'captured': 0.58, 'detail': 0.83, 'photos': 19,
                         'hint': 'Fill in the red spots'}}
    with open(os.path.join(out, 'demo_dice.json'), 'w') as fp:
        json.dump(data, fp)
    print('dice demo written')


if __name__ == '__main__':
    main()
