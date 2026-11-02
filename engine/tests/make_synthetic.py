"""Renders a synthetic photo set of a textured object on a textured table.

    python make_synthetic.py <out_dir> [views] [--poses] [--masks] [--plain]

  --poses  also write poses.txt (camera positions, slightly noisy, like Live Scan)
  --masks  also write masks/ (object outlines, like AI object selection)
  --plain  give the object a plain colour (no texture), which photos alone cannot scan
  --far    shoot from further away so the object is small in the photos

Used to test the reconstruction engine without real photos. The object is a
sphere resting on a box (known size), cameras orbit at two heights.
"""
import math
import os
import sys

import cv2
import numpy as np

rng = np.random.default_rng(3)
DIRS = rng.normal(size=(18, 3))
DIRS /= np.linalg.norm(DIRS, axis=1, keepdims=True)
FREQ = rng.uniform(6, 45, size=18)
PHASE = rng.uniform(0, 6.28, size=18)
MIX = rng.uniform(0, 1, size=(18, 3))


def texture(p, tint):
    acc = np.zeros(p.shape[:-1] + (3,))
    for i in range(len(FREQ)):
        s = 0.5 + 0.5 * np.sin(p @ DIRS[i] * FREQ[i] + PHASE[i])
        acc += s[..., None] * MIX[i]
    acc /= MIX.sum(axis=0)
    acc = np.clip((acc - 0.5) * 2.2 + 0.5, 0, 1)
    return acc * tint


def look_at(c, target, up=(0, 0, 1)):
    f = target - c
    f /= np.linalg.norm(f)
    r = np.cross(f, up)
    r /= np.linalg.norm(r)
    d = np.cross(f, r)  # image y points down
    return np.stack([r, d, f])  # rows: camera axes in world


PLAIN = False


def render(c, R, W, H, f):
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    d_cam = np.stack([(xs - W / 2) / f, (ys - H / 2) / f, np.ones_like(xs)], -1)
    d = d_cam @ R  # world directions
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    best = np.full((H, W), np.inf)
    nrm = np.zeros((H, W, 3))
    tint = np.zeros((H, W, 3))
    obj = np.zeros((H, W), bool)

    def take(t, n, col, is_obj=False):
        m = (t > 1e-6) & (t < best)
        best[m] = t[m]
        nrm[m] = n[m] if n.ndim == 3 else n
        tint[m] = col
        obj[m] = is_obj

    # sphere
    sc, sr = np.array([0.0, 0.0, 0.62]), 0.32
    oc = c - sc
    b = d @ oc
    disc = b * b - (oc @ oc - sr * sr)
    t = np.where(disc > 0, -b - np.sqrt(np.maximum(disc, 0)), np.inf)
    p = c + d * t[..., None]
    take(t, (p - sc) / sr, (1.0, 0.85, 0.7), True)
    # box [-0.3,0.3]x[-0.2,0.2]x[0,0.3]
    lo, hi = np.array([-0.3, -0.2, 0.0]), np.array([0.3, 0.2, 0.3])
    with np.errstate(divide="ignore", invalid="ignore"):
        t1 = (lo - c) / d
        t2 = (hi - c) / d
    tmin = np.minimum(t1, t2).max(-1)
    tmax = np.maximum(t1, t2).min(-1)
    hit = (tmax >= tmin) & (tmax > 0)
    tb = np.where(hit, tmin, np.inf)
    pb = c + d * tb[..., None]
    nb = np.zeros_like(pb)
    for k in range(3):
        nb[..., k] = np.where(np.abs(pb[..., k] - lo[k]) < 1e-6, -1, nb[..., k])
        nb[..., k] = np.where(np.abs(pb[..., k] - hi[k]) < 1e-6, 1, nb[..., k])
    take(tb, nb, (0.6, 0.8, 1.0), True)
    # table plane z = 0 (disc radius 3)
    with np.errstate(divide="ignore", invalid="ignore"):
        tp = -c[2] / d[..., 2]
    pp = c + d * tp[..., None]
    tp = np.where((tp > 0) & (np.hypot(pp[..., 0], pp[..., 1]) < 3), tp, np.inf)
    take(tp, np.array([0, 0, 1.0]), (0.9, 0.9, 0.85))
    # room (large sphere)
    oc = c
    b = d @ oc
    disc = b * b - (oc @ oc - 64)
    tr = -b + np.sqrt(np.maximum(disc, 0))
    pr = c + d * tr[..., None]
    take(tr, -pr / 8, (0.7, 0.7, 0.7))

    p = c + d * best[..., None]
    col = texture(p, tint)
    if PLAIN:
        col[obj] = np.array([0.18, 0.18, 0.2])
    L = np.array([0.4, -0.3, 0.85])
    L /= np.linalg.norm(L)
    shade = 0.55 + 0.45 * np.clip(nrm @ L, 0, 1)
    img = np.clip(col * shade[..., None], 0, 1)
    return (img[..., ::-1] * 255).astype(np.uint8), (obj * 255).astype(np.uint8)


def main():
    global PLAIN
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    out = args[0]
    n = int(args[1]) if len(args) > 1 else 40
    PLAIN = '--plain' in flags
    os.makedirs(out, exist_ok=True)
    poses = []
    noise = np.random.default_rng(5)
    W, H, f = 1200, 900, 950.0
    target = np.array([0, 0, 0.4])
    k = 0
    rings = [(22, int(n * 0.55)), (48, n - int(n * 0.55))]
    for elev, cnt in rings:
        for i in range(cnt):
            az = 2 * math.pi * i / cnt + elev * 0.01
            r = 6.0 if '--far' in flags else 2.4
            c = target + r * np.array([math.cos(az) * math.cos(math.radians(elev)),
                                       math.sin(az) * math.cos(math.radians(elev)),
                                       math.sin(math.radians(elev))])
            R = look_at(c, target)
            img, mask = render(c, R, W, H, f)
            name = f"img_{k:03d}.jpg"
            cv2.imwrite(os.path.join(out, name), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
            if '--masks' in flags:
                os.makedirs(os.path.join(out, 'masks'), exist_ok=True)
                cv2.imwrite(os.path.join(out, 'masks', f"img_{k:03d}.png"), mask)
            # noisy pose like AR tracking: ~0.5 deg, ~1 cm
            w = noise.normal(0, 0.5 * math.pi / 180, 3)
            Rn, _ = cv2.Rodrigues(w)
            Rp = Rn @ R
            cp = c + noise.normal(0, 0.01, 3)
            tp = -Rp @ cp
            poses.append(name + " " + " ".join(f"{v:.6f}" for v in [f, f, W / 2, H / 2, *Rp.flatten(), *tp]))
            k += 1
    if '--poses' in flags:
        with open(os.path.join(out, 'poses.txt'), 'w') as fp:
            fp.write("up 0 0 1\nsize %d %d\n" % (W, H))
            fp.write("\n".join(poses) + "\n")
    print("rendered", k)


if __name__ == "__main__":
    main()
