"""Renders the Live Scan demo: a plain soda can on a wooden table seen by a
phone camera, plus the matching AR data (camera matrices, hologram points,
AI outline) that the app's Live Scan screen draws on top.

    python tools/make_demo_can.py app/test/assets

Writes demo_can.jpg and demo_can.json. World axes follow ARCore: y is up,
units are metres.
"""
import json
import warnings
warnings.filterwarnings('ignore')
import math
import os
import sys

import cv2
import numpy as np

W, H = 1080, 2340
F = 1836.0  # focal length in pixels (about 65 degrees vertical view)
R_CAN, H_CAN = 0.033, 0.122
TARGET = np.array([0.0, 0.055, 0.0])
AZ = math.radians(30)        # camera direction around the can
ELEV = math.radians(27)
DIST = 0.34


def camera():
    c = TARGET + DIST * np.array([math.sin(AZ) * math.cos(ELEV), math.sin(ELEV), math.cos(AZ) * math.cos(ELEV)])
    f = TARGET - c
    f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0])
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return c, r, u, f


def wood(p):
    x, z = p[..., 0], p[..., 2]
    plank = np.floor(z / 0.11)
    ring = np.sin(z * 260 + np.sin(x * 7 + plank * 1.7) * 2.2 + plank * 3.1)
    grain = 0.5 + 0.5 * ring
    fine = 0.5 + 0.5 * np.sin(z * 1400 + x * 25)
    seam = (np.abs(z / 0.11 - np.round(z / 0.11)) < 0.012).astype(float)
    base = np.stack([0.42, 0.27, 0.15]) * np.ones(p.shape)
    shade = 0.92 + 0.12 * np.sin(plank * 2.3)[..., None]
    col = base * shade * (0.8 + 0.25 * grain[..., None]) * (0.94 + 0.06 * fine[..., None])
    return col * (1 - 0.45 * seam[..., None])


def label(theta, y):
    # plain drink label: colour bands and a wave, no brand
    t = theta / (2 * math.pi)
    hue = (0.52 + 0.18 * np.sin(t * 2 * math.pi)) % 1.0
    wave = 0.5 + 0.5 * np.sin(theta * 3 + y * 60)
    band = (np.abs(y - 0.06 - 0.012 * np.sin(theta * 2)) < 0.012).astype(float)
    hsv = np.stack([hue * 180, np.full_like(t, 200), 150 + 80 * wave], -1).astype(np.uint8)
    rgb = cv2.cvtColor(hsv.reshape(-1, 1, 3), cv2.COLOR_HSV2RGB).reshape(hsv.shape).astype(float) / 255
    rgb = rgb * (1 - band[..., None]) + np.array([0.95, 0.95, 0.97]) * band[..., None]
    rim = ((y < 0.008) | (y > H_CAN - 0.01)).astype(float)
    return rgb * (1 - rim[..., None]) + np.array([0.78, 0.8, 0.83]) * rim[..., None]


def render():
    c, r, u, f = camera()
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    d = ((xs - W / 2) / F)[..., None] * r + (-(ys - H / 2) / F)[..., None] * u + f
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    best = np.full((H, W), np.inf)
    col = np.zeros((H, W, 3))
    nrm = np.zeros((H, W, 3))
    spec_k = np.zeros((H, W))

    # can side
    a = d[..., 0] ** 2 + d[..., 2] ** 2
    b = 2 * (c[0] * d[..., 0] + c[2] * d[..., 2])
    cc = c[0] ** 2 + c[2] ** 2 - R_CAN ** 2
    disc = b * b - 4 * a * cc
    t = np.where(disc > 0, (-b - np.sqrt(np.maximum(disc, 0))) / (2 * a + 1e-12), np.inf)
    p = c + d * t[..., None]
    hit = (t > 0) & (p[..., 1] >= 0) & (p[..., 1] <= H_CAN)
    t = np.where(hit, t, np.inf)
    m = t < best
    best[m] = t[m]
    theta = np.arctan2(p[..., 0], p[..., 2]) % (2 * np.pi)
    col[m] = label(theta, p[..., 1])[m]
    n = np.stack([p[..., 0], np.zeros_like(t), p[..., 2]], -1) / R_CAN
    nrm[m] = n[m]
    spec_k[m] = 0.9
    # can top
    tt = (H_CAN - c[1]) / d[..., 1]
    p = c + d * tt[..., None]
    rr = np.hypot(p[..., 0], p[..., 2])
    tt = np.where((tt > 0) & (rr <= R_CAN), tt, np.inf)
    m = tt < best
    best[m] = tt[m]
    top = np.array([0.72, 0.74, 0.77]) * (0.85 + 0.15 * (np.abs(rr - 0.026) < 0.0015)[..., None])
    col[m] = top[m] if top.ndim == 3 else top
    nrm[m] = np.array([0, 1.0, 0])
    spec_k[m] = 1.0
    # table
    tp = -c[1] / d[..., 1]
    p = c + d * tp[..., None]
    tp = np.where((tp > 0) & (np.abs(p[..., 0]) < 0.9) & (p[..., 2] > -0.55) & (p[..., 2] < 0.9), tp, np.inf)
    m = tp < best
    best[m] = tp[m]
    col[m] = wood(p)[m]
    nrm[m] = np.array([0, 1.0, 0])
    spec_k[m] = 0.15
    # room background
    m = ~np.isfinite(best)
    g = np.clip(0.5 + d[..., 1], 0, 1)
    col[m] = (np.array([0.20, 0.21, 0.24]) * (0.6 + 0.6 * g[..., None]))[m]
    nrm[m] = -d[m]

    L = np.array([-0.5, 0.8, 0.45])
    L /= np.linalg.norm(L)
    diff = np.clip((nrm * L).sum(-1), 0, 1)
    hv = L - d
    hv /= np.linalg.norm(hv, axis=-1, keepdims=True)
    spec = np.clip((nrm * hv).sum(-1), 0, 1) ** 60 * spec_k
    # soft contact shadow under the can
    p = c + d * np.where(np.isfinite(best), best, 0)[..., None]
    rr = np.hypot(p[..., 0] + 0.012, p[..., 2] + 0.006)
    shadow = np.where((np.abs(p[..., 1]) < 1e-4) & np.isfinite(best), np.clip((rr - R_CAN * 0.9) / 0.03, 0.45, 1), 1)
    img = col * (0.45 + 0.65 * diff[..., None]) * shadow[..., None] + spec[..., None] * 0.9
    img = np.clip(img, 0, 1) ** (1 / 1.1)
    # mild vignette like a phone camera
    vig = 1 - 0.25 * (((xs - W / 2) / W) ** 2 + ((ys - H / 2) / H) ** 2)
    img = img * vig[..., None]
    return (np.clip(img, 0, 1) * 255).astype(np.uint8)[..., ::-1]


def matrices():
    c, r, u, f = camera()
    Rv = np.stack([r, u, -f])
    tv = -Rv @ c
    V = np.eye(4)
    V[:3, :3] = Rv
    V[:3, 3] = tv
    near, far = 0.03, 100.0
    P = np.zeros((4, 4))
    P[0, 0] = 2 * F / W
    P[1, 1] = 2 * F / H
    P[2, 2] = -(far + near) / (far - near)
    P[2, 3] = -2 * far * near / (far - near)
    P[3, 2] = -1
    return V.T.flatten().tolist(), P.T.flatten().tolist()  # column major


def hologram(progress=True):
    pts = []
    cam_dir = AZ
    step = 0.0055
    for th in np.arange(0, 2 * math.pi, math.radians(4.5)):
        diff = abs((th - cam_dir + math.pi) % (2 * math.pi) - math.pi)
        for y in np.arange(0.004, H_CAN, step):
            if progress:
                if diff < math.radians(75):
                    st = 2
                elif diff < math.radians(100):
                    st = 1
                elif diff < math.radians(125):
                    st = 0
                else:
                    continue
            else:
                if diff < math.radians(35):
                    st = 0
                else:
                    continue
            pts += [R_CAN * math.sin(th), float(y), R_CAN * math.cos(th), st]
    for rr in np.arange(0.004, R_CAN, step):
        for th in np.arange(0, 2 * math.pi, step / rr):
            diff = abs((th - cam_dir + math.pi) % (2 * math.pi) - math.pi)
            if progress:
                st = 2 if diff < math.radians(60) else 0
            else:
                if diff > math.radians(40):
                    continue
                st = 0
            pts += [rr * math.sin(th), H_CAN, rr * math.cos(th), st]
    return pts


def outline():
    o = []
    for th in np.arange(0, 2 * math.pi, math.radians(3)):
        o += [R_CAN * math.sin(th), H_CAN, R_CAN * math.cos(th)]
        diff = abs((th - AZ + math.pi) % (2 * math.pi) - math.pi)
        if diff < math.pi / 2:
            o += [R_CAN * math.sin(th), 0.0, R_CAN * math.cos(th)]
    for side in (-1, 1):
        th = AZ + side * math.pi / 2
        for y in np.arange(0, H_CAN, 0.003):
            o += [R_CAN * math.sin(th), float(y), R_CAN * math.cos(th)]
    return o


def bins(progress=True):
    b = [0] * 72
    seg = int(((AZ / (2 * math.pi)) % 1.0) * 24)
    if progress:
        for k in range(-7, 5):
            b[(seg + k) % 24] = 2
        for k in range(-5, 7):
            b[24 + (seg + k) % 24] = 2
        for k in (0, 1):
            b[48 + (seg + k) % 24] = 1
    else:
        b[24 + seg] = 1
    return b


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    cv2.imwrite(os.path.join(out, 'demo_can.jpg'), render(), [cv2.IMWRITE_JPEG_QUALITY, 90])
    V, P = matrices()
    radius = R_CAN * 1.4 + 0.02
    data = {
        'view': V, 'proj': P,
        'center': [0.0, -0.01, 0.0], 'radius': radius, 'bottom': -0.01, 'top': H_CAN + 0.035,
        'outline': outline(),
        'progress': {'points': hologram(True), 'bins': bins(True), 'captured': 0.64, 'detail': 0.71,
                     'photos': 23, 'hint': 'Now raise the phone and look down at the top'},
        'selected': {'points': hologram(False), 'bins': bins(False), 'captured': 0.04, 'detail': 0.0,
                     'photos': 1, 'hint': 'Walk slowly around the object'},
    }
    with open(os.path.join(out, 'demo_can.json'), 'w') as fp:
        json.dump(data, fp)
    print('demo written')


if __name__ == '__main__':
    main()
