# prisme.py: Prisme, the player's scaler, as it is trained and as the Metal kernel runs it.
# A 2x luma upscaler: each source pixel's structure tensor picks a class, the class a pair of
# filters, one estimating the true pixel and one the same pixel blurred, and a curve that keeps,
# shrinks or raises their difference. Two banks, clean and starved, mixed by Deband.strength.
# The defaults are the shipped banks'; every one can be set from the environment to experiment.
import numpy as np, os, glob, math, sys
from concurrent.futures import ProcessPoolExecutor
D = os.environ.get('PRISME_DATA', 'data')    # what dataset.sh wrote
T = int(os.environ.get('T', '4'))            # taps each way
ANG = int(os.environ.get('ANG', '8'))        # orientations
STR = np.array([float(x) for x in os.environ.get('STR', '8,32,128').split(',')])   # strength bin centres, in ten bit codes a pixel
COH = np.array([float(x) for x in os.environ.get('COH', '0.35').split(',')])       # coherence bin edges
RHO = float(os.environ.get('RHO', '1.2'))    # the structure tensor's smoothing
LEVELS = np.array([1.0, 2.0])                # the deband strengths the banks are trained at
SHARE = 2                                    # source pixels a class is shared across each way, as in the kernel
K = ANG * len(STR) * (len(COH) + 1)
N = T * T

def gauss(a, rho):
    r = int(math.ceil(2 * rho)); x = np.arange(-r, r + 1); k = np.exp(-x * x / (2 * rho * rho)); k /= k.sum()
    p = np.pad(a, ((r, r), (0, 0)), mode='edge'); a = sum(k[i] * p[i:i + a.shape[0]] for i in range(len(k)))
    p = np.pad(a, ((0, 0), (r, r)), mode='edge'); return sum(k[i] * p[:, i:i + a.shape[1]] for i in range(len(k)))

def features(L, rho=RHO):
    p = np.pad(L, 1, mode='edge'); gx = (p[1:-1, 2:] - p[1:-1, :-2]) / 2; gy = (p[2:, 1:-1] - p[:-2, 1:-1]) / 2
    a = gauss(gx * gx, rho); b = gauss(gx * gy, rho); c = gauss(gy * gy, rho)
    d = np.sqrt((a - c) ** 2 + 4 * b * b); l1 = (a + c + d) / 2; l2 = np.maximum((a + c - d) / 2, 0)
    ang = (0.5 * np.arctan2(2 * b, a - c) / np.pi) % 1.0 * ANG          # continuous, bin centres at integers
    st = np.sqrt(l1)
    sp = np.interp(np.log2(np.maximum(st, 1e-3)), np.log2(STR), np.arange(len(STR)))  # continuous strength position
    co = (np.sqrt(l1) - np.sqrt(l2)) / (np.sqrt(l1) + np.sqrt(l2) + 1e-6)
    return ang, sp, np.searchsorted(COH, co)

def soft_buckets(L, soft=True):
    # the (bucket, weight) pairs of each pixel: two orientations by two strengths
    ang, sp, ci = features(L)
    a0 = np.floor(ang).astype(np.int32); ta = ang - a0; a0 %= ANG; a1 = (a0 + 1) % ANG
    s0 = np.floor(sp).astype(np.int32); ts = sp - s0; s1 = np.minimum(s0 + 1, len(STR) - 1)
    if not soft:
        a = np.where(ta < 0.5, a0, a1); s = np.where(ts < 0.5, s0, s1)
        kinds = ((a * len(STR) + s) * (len(COH) + 1) + ci)[::SHARE, ::SHARE].repeat(SHARE, 0).repeat(SHARE, 1)
        return [(kinds[:ang.shape[0], :ang.shape[1]], np.ones_like(ang, np.float32))]
    out = []
    for a, wa in ((a0, 1 - ta), (a1, ta)):
        for s, ws in ((s0, 1 - ts), (s1, ts)):
            out.append(((a * len(STR) + s) * (len(COH) + 1) + ci, (wa * ws).astype(np.float32)))
    return out

def offsets(phase):
    return list(range(-T // 2, T // 2)) if phase == 0 else list(range(-T // 2 + 1, T // 2 + 1))

def patches(L, py, px, step=1):
    P = T // 2 + 1; h, w = L.shape; p = np.pad(L, P, mode='edge')
    return np.stack([p[P + dy:P + dy + h:step, P + dx:P + dx + w:step] for dy in offsets(py) for dx in offsets(px)])

def box(a, k):
    a = a.astype(np.float64); h, w = a.shape; r = k // 2; p = np.pad(a, r, mode='edge'); c = p.cumsum(0).cumsum(1); c = np.pad(c, ((1, 0), (1, 0)))
    return (c[k:k + h, k:k + w] - c[:h, k:k + w] - c[k:k + h, :w] + c[:h, :w]) / (k * k)

def strength_of(bytes_, frames, w, h, codec):
    bpp = bytes_ * 8 / (frames * w * h) * (1 if codec == 'x265' else 0.5)
    return 1 + min(max(math.log2(0.2 / bpp) / 2, 0), 1)

def samples(split, kernels=None, tags=None, frames=(1,)):
    out = []
    for d in sorted(glob.glob(f'{D}/{split}/*')):
        if not os.path.exists(f'{d}/done'): continue
        W, H = map(int, open(f'{d}/size').read().strip().split(',')[:2])
        sizes = dict(l.split() for l in open(f'{d}/bytes')) if os.path.exists(f'{d}/bytes') else {}
        for f in glob.glob(f'{d}/*.*.1.y'):
            kernel, tag = os.path.basename(f).split('.')[:2]
            if kernels and kernel not in kernels: continue
            if tags and tag not in tags: continue
            s = 1.0 if tag == 'c10' else strength_of(int(sizes[f'{kernel}.{tag}']), 24, W // 2, H // 2, tag[:4])
            for n in frames:
                out.append(dict(film=os.path.basename(d), W=W, H=H, lr=f'{d}/{kernel}.{tag}.{n}.y', hr=f'{d}/hr{n}.y', s=s, kernel=kernel, tag=tag))
    return out

def load(sm):
    L = np.fromfile(sm['lr'], '<u2').astype(np.float32).reshape(sm['H'] // 2, sm['W'] // 2)
    R = np.fromfile(sm['hr'], '<u2').astype(np.float32).reshape(sm['H'], sm['W'])
    return L, R

def level_weights(s):
    return np.maximum(0, 1 - np.abs(s - LEVELS) / (LEVELS[1] - LEVELS[0]))

def accumulate(args):
    sms, soft, augment, step = args
    AtA = np.zeros((len(LEVELS), 4, K, N, N)); Atb = np.zeros((len(LEVELS), 2, 4, K, N)); cnt = np.zeros((len(LEVELS), 4, K))
    for sm in sms:
        L0, R0 = load(sm); lw = level_weights(sm['s'])
        views = [(L0, R0)]
        if augment:
            views = [(L0, R0), (L0[:, ::-1], R0[:, ::-1]), (L0[::-1], R0[::-1]), (L0.T, R0.T)]
        for L, R in views:
            L = np.ascontiguousarray(L); R = np.ascontiguousarray(R)
            Rb = box(box(R, 3), 3).astype(np.float32)
            bw = [(b[::step, ::step].ravel(), w[::step, ::step].ravel()) for b, w in soft_buckets(L, soft)]
            for py in (0, 1):
                for px in (0, 1):
                    ph = py * 2 + px
                    X = patches(L, py, px, step).reshape(N, -1).T.astype(np.float64)
                    t = [R[py::2, px::2][::step, ::step].ravel().astype(np.float64), Rb[py::2, px::2][::step, ::step].ravel().astype(np.float64)]
                    for b, w in bw:
                        keep = w > 1e-3; b = b[keep]; w = w[keep]; Xk = X[keep]; tk = [x[keep] for x in t]
                        order = np.argsort(b, kind='stable'); b = b[order]; bounds = np.searchsorted(b, np.arange(K + 1))
                        Xk = Xk[order]; w = w[order]; tk = [x[order] for x in tk]
                        for k in np.nonzero(np.diff(bounds))[0]:
                            lo, hi = bounds[k], bounds[k + 1]; Xs = Xk[lo:hi]; Xw = Xs * w[lo:hi, None]
                            A = Xw.T @ Xs; bb = [Xw.T @ x[lo:hi] for x in tk]
                            for li, lv in enumerate(lw):
                                if lv > 0:
                                    AtA[li, ph, k] += lv * A; cnt[li, ph, k] += lv * w[lo:hi].sum()
                                    for q in range(2): Atb[li, q, ph, k] += lv * bb[q]
    return AtA, Atb, cnt

def train(sms, soft=True, augment=True, step=2, workers=10, ridge=1e-5):
    chunks = [(sms[i::workers], soft, augment, step) for i in range(workers)]
    AtA = 0; Atb = 0; cnt = 0
    with ProcessPoolExecutor(workers) as ex:
        for A, B, C in ex.map(accumulate, chunks):
            AtA = AtA + A; Atb = Atb + B; cnt = cnt + C
    F = np.zeros((len(LEVELS), 2, 4, K, N), np.float32); used = np.zeros((len(LEVELS), 4, K), bool)
    for li in range(len(LEVELS)):
        for ph in range(4):
            pooled = AtA[li, ph].sum(0)
            for q in range(2):
                fb = np.linalg.solve(pooled + 1e-6 * pooled.trace() / N * np.eye(N), Atb[li, q, ph].sum(0))
                for k in range(K):
                    A = AtA[li, ph, k]; tr = A.trace() / N
                    if cnt[li, ph, k] < 20 * N:   # too little data: the level's pooled filter
                        F[li, q, ph, k] = fb; continue
                    used[li, ph, k] = True
                    F[li, q, ph, k] = np.linalg.solve(A + ridge * tr * np.eye(N), Atb[li, q, ph, k])
    return F, used

def apply(L, F, s, floor=None, amount=3.0, clamp=True, soft=True):
    h, w = L.shape; lw = level_weights(s); Fs = np.tensordot(lw, F, 1)   # 2,4,K,N
    if floor is None: floor = 3 + 5 * min(max(s - 1, 0), 1)
    bw = soft_buckets(L, soft); out = np.zeros((2 * h, 2 * w), np.float32); p1 = np.pad(L, 1, mode='edge')
    for py in (0, 1):
        for px in (0, 1):
            ph = py * 2 + px; P = patches(L, py, px)
            y = np.zeros((h, w), np.float32); bl = np.zeros((h, w), np.float32)
            for b, wt in bw:
                y += wt * np.einsum('nhw,hwn->hw', P, Fs[0, ph][b]); bl += wt * np.einsum('nhw,hwn->hw', P, Fs[1, ph][b])
            d = y - bl; d = np.sign(d) * np.maximum(np.abs(d) - floor, 0); v = y + amount * d
            if clamp:
                ys = (-1, 0) if py == 0 else (0, 1); xs = (-1, 0) if px == 0 else (0, 1)
                nb = [p1[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] for dy in ys for dx in xs]
                v = np.clip(v, np.minimum.reduce(nb), np.maximum.reduce(nb))
            out[py::2, px::2] = v
    return out

def lanczos_up(L):
    h, w = L.shape
    def taps(n):
        at = (np.arange(2 * n) + 0.5) / 2 - 0.5; first = np.floor(at).astype(int) - 2
        x = first[:, None] + np.arange(6)[None] - at[:, None]; ax = np.abs(x)
        wt = np.where(ax < 1e-9, 1.0, np.where(ax >= 3, 0.0, 3 * np.sin(np.pi * ax) * np.sin(np.pi * ax / 3) / (np.pi ** 2 * ax ** 2 + 1e-30)))
        return first, wt / wt.sum(1, keepdims=True)
    f, wt = taps(w); idx = np.clip(f[:, None] + np.arange(6), 0, w - 1); A = (L[:, idx] * wt[None]).sum(2)
    f, wt = taps(h); idx = np.clip(f[:, None] + np.arange(6), 0, h - 1); return (A[idx] * wt[:, :, None]).sum(1)

def easu_up(L):
    # FSR 1 EASU on one channel, as the production kernel runs it
    h, w = L.shape; Ln = L / 1023.0
    oy, ox = np.mgrid[0:2 * h, 0:2 * w].astype(np.float32)
    py = (oy + 0.5) / 2 - 0.5; px = (ox + 0.5) / 2 - 0.5; fy = np.floor(py); fx = np.floor(px); ppy = py - fy; ppx = px - fx
    fy = fy.astype(int); fx = fx.astype(int)
    def at(dy, dx): return Ln[np.clip(fy + dy, 0, h - 1), np.clip(fx + dx, 0, w - 1)]
    b, c = at(-1, 0), at(-1, 1); e, f, g, hh = at(0, -1), at(0, 0), at(0, 1), at(0, 2)
    i, j, k, l = at(1, -1), at(1, 0), at(1, 1), at(1, 2); n, o = at(2, 0), at(2, 1)
    dirx = np.zeros_like(ppx); diry = np.zeros_like(ppx); ln = np.zeros_like(ppx)
    def analyse(wt, A, B, C, Dd, E):
        nonlocal dirx, diry, ln
        dX = Dd - B; lX = np.clip(np.abs(dX) / np.maximum(np.maximum(np.abs(Dd - C), np.abs(C - B)), 1e-8), 0, 1)
        dirx = dirx + dX * wt; ln = ln + lX * lX * wt
        dY = E - A; lY = np.clip(np.abs(dY) / np.maximum(np.maximum(np.abs(E - C), np.abs(C - A)), 1e-8), 0, 1)
        diry = diry + dY * wt; ln = ln + lY * lY * wt
    analyse((1 - ppx) * (1 - ppy), b, e, f, g, j); analyse(ppx * (1 - ppy), c, f, g, hh, k)
    analyse((1 - ppx) * ppy, f, i, j, k, n); analyse(ppx * ppy, g, j, k, l, o)
    r2 = dirx * dirx + diry * diry; flat = r2 < 1 / 32768; inv = 1 / np.sqrt(np.maximum(r2, 1e-12))
    dx = np.where(flat, 1.0, dirx * inv); dy = np.where(flat, 0.0, diry * inv)
    ln = (ln * 0.5) ** 2; stretch = (dx * dx + dy * dy) / np.maximum(np.abs(dx), np.abs(dy))
    l2x = 1 + (stretch - 1) * ln; l2y = 1 - 0.5 * ln; lob = 0.5 + (0.21 - 0.5) * ln; clp = 1 / lob
    num = np.zeros_like(ppx); den = np.zeros_like(ppx)
    for (ox_, oy_), val in (((0, -1), b), ((1, -1), c), ((-1, 1), i), ((0, 1), j), ((0, 0), f), ((-1, 0), e), ((1, 1), k), ((2, 1), l), ((2, 0), hh), ((1, 0), g), ((1, 2), o), ((0, 2), n)):
        offx = ox_ - ppx; offy = oy_ - ppy
        vx = (offx * dx + offy * dy) * l2x; vy = (-offx * dy + offy * dx) * l2y
        d2 = np.minimum(vx * vx + vy * vy, clp); wB = 0.4 * d2 - 1; wA = lob * d2 - 1
        wt = (25 / 16 * wB * wB - 9 / 16) * wA * wA; num += val * wt; den += wt
    v = np.clip(num / den, np.minimum(np.minimum(f, g), np.minimum(j, k)), np.maximum(np.maximum(f, g), np.maximum(j, k)))
    return v * 1023.0

def sharpen(y, core, amount=3):
    from numpy.lib.stride_tricks import sliding_window_view as sw
    d = y - box(box(y, 3), 3); d = np.sign(d) * np.maximum(np.abs(d) - core, 0)
    p = np.pad(y, 1, mode='edge'); win = sw(p, (3, 3)); return np.clip(y + amount * d, win.min((-1, -2)), win.max((-1, -2)))

def production(L, s):
    floor = 3 + 5 * min(max(s - 1, 0), 1)
    return sharpen(easu_up(L) if s > 1 else lanczos_up(L), floor)

KNOTS = np.array([0.0, 2, 4, 8, 16, 32, 64, 128])   # |detail| in ten bit codes

def hats(x):
    # piecewise linear basis over KNOTS, flat past the last
    x = np.minimum(x, KNOTS[-1]); i = np.clip(np.searchsorted(KNOTS, x, side='right') - 1, 0, len(KNOTS) - 2)
    t = (x - KNOTS[i]) / (KNOTS[i + 1] - KNOTS[i]); B = np.zeros(x.shape + (len(KNOTS),), np.float32)
    np.put_along_axis(B, i[..., None], (1 - t)[..., None], -1)
    B2 = np.zeros_like(B); np.put_along_axis(B2, (i + 1)[..., None], t[..., None], -1)
    return B + B2

def estimates(L, F, s, soft=True):
    # per phase: the HR estimate, the blurred HR estimate, and the pixel's (bucket, weight) pairs
    h, w = L.shape; Fs = np.tensordot(level_weights(s), F, 1); bw = soft_buckets(L, soft); out = []
    for py in (0, 1):
        for px in (0, 1):
            ph = py * 2 + px; P = patches(L, py, px); y = np.zeros((h, w), np.float32); bl = np.zeros((h, w), np.float32)
            for b, wt in bw:
                y += wt * np.einsum('nhw,hwn->hw', P, Fs[0, ph][b])
                bl += wt * np.einsum('nhw,hwn->hw', P, Fs[1, ph][b])
            out.append((py, px, y, bl))
    return out, bw

def shrink_accumulate(args):
    sms, F, step, soft = args
    Q = len(KNOTS); A = np.zeros((len(LEVELS), K, Q, Q)); c = np.zeros((len(LEVELS), K, Q))
    for sm in sms:
        L, R = load(sm); lw = level_weights(sm['s']); est, bw = estimates(L, F, sm['s'], soft)
        for py, px, y, bl in est:
            d = (y - bl)[::step, ::step].ravel(); t = (R[py::2, px::2] - bl)[::step, ::step].ravel()
            M = hats(np.abs(d)) * np.sign(d)[:, None]
            for b, wt in bw:
                b = b[::step, ::step].ravel(); wt = wt[::step, ::step].ravel()
                order = np.argsort(b, kind='stable'); bs = b[order]; bounds = np.searchsorted(bs, np.arange(K + 1))
                Mo = M[order]; to = t[order]; wo = wt[order]
                for k in np.nonzero(np.diff(bounds))[0]:
                    lo, hi = bounds[k], bounds[k + 1]; Mw = Mo[lo:hi] * wo[lo:hi, None]
                    AA = Mw.T @ Mo[lo:hi]; cc = Mw.T @ to[lo:hi]
                    for li, lv in enumerate(lw):
                        if lv > 0: A[li, k] += lv * AA; c[li, k] += lv * cc
    return A, c

def fit_shrink(sms, F, step=2, workers=10, ridge=1e-3, soft=True):
    # per level and bucket, the detail kept as a function of the detail estimated: least squares over the hats
    A = 0; c = 0
    with ProcessPoolExecutor(workers) as ex:
        for a, b in ex.map(shrink_accumulate, [(sms[i::workers], F, step, soft) for i in range(workers)]):
            A = A + a; c = c + b
    Q = len(KNOTS); S = np.zeros((len(LEVELS), K, Q), np.float32)
    identity = KNOTS.astype(np.float32)   # phi(x) = x keeps the linear estimate
    for li in range(len(LEVELS)):
        for k in range(K):
            M = A[li, k]; tr = max(M.trace() / Q, 1e-9)
            # pulled toward keeping the linear estimate where data is thin
            S[li, k] = np.linalg.solve(M + ridge * tr * np.eye(Q), c[li, k] + ridge * tr * identity)
    return S

def apply_shrunk(L, F, S, s, gain=1.0, clamp=True, soft=True):
    h, w = L.shape; est, bw = estimates(L, F, s, soft); Ss = np.tensordot(level_weights(s), S, 1)   # K,Q
    out = np.zeros((2 * h, 2 * w), np.float32); p1 = np.pad(L, 1, mode='edge')
    for py, px, y, bl in est:
        d = y - bl; Hm = hats(np.abs(d)); phi = np.zeros((h, w), np.float32)
        for b, wt in bw: phi += wt * np.einsum('hwq,hwq->hw', Hm, Ss[b])
        v = bl + np.sign(d) * (gain * phi)
        if clamp:
            ys = (-1, 0) if py == 0 else (0, 1); xs = (-1, 0) if px == 0 else (0, 1)
            nb = [p1[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] for dy in ys for dx in xs]
            v = np.clip(v, np.minimum.reduce(nb), np.maximum.reduce(nb))
        out[py::2, px::2] = v
    return out

HBINS = np.concatenate([[0], np.geomspace(0.25, 512, 95)])   # |detail| histogram edges, in codes

def match_accumulate(args):
    sms, F, step = args
    hd = np.zeros((len(LEVELS), K, len(HBINS))); ht = np.zeros((len(LEVELS), K, len(HBINS)))
    for sm in sms:
        L, R = load(sm); lw = level_weights(sm['s']); est, bw = estimates(L, F, sm['s'], soft=False)
        b = bw[0][0]
        for py, px, y, bl in est:
            d = np.abs(y - bl)[::step, ::step].ravel(); t = np.abs(R[py::2, px::2] - bl)[::step, ::step].ravel(); bb = b[::step, ::step].ravel()
            di = np.clip(np.searchsorted(HBINS, d), 0, len(HBINS) - 1); ti = np.clip(np.searchsorted(HBINS, t), 0, len(HBINS) - 1)
            for li, lv in enumerate(lw):
                if lv > 0:
                    np.add.at(hd[li], (bb, di), lv); np.add.at(ht[li], (bb, ti), lv)
    return hd, ht

def fit_match(sms, F, step=4, workers=10):
    # per level and bucket, the monotone map taking the estimated detail's magnitudes onto the true detail's
    hd = 0; ht = 0
    with ProcessPoolExecutor(workers) as ex:
        for a, b in ex.map(match_accumulate, [(sms[i::workers], F, step) for i in range(workers)]):
            hd = hd + a; ht = ht + b
    M = np.zeros((len(LEVELS), K, len(KNOTS)), np.float32)
    for li in range(len(LEVELS)):
        for k in range(K):
            if hd[li, k].sum() < 1000: M[li, k] = KNOTS; continue
            cd = np.cumsum(hd[li, k]) / hd[li, k].sum(); ct = np.cumsum(ht[li, k]) / ht[li, k].sum()
            q = np.interp(KNOTS, HBINS, cd)            # rank of each knot among the estimated details
            M[li, k] = np.interp(q, ct, HBINS)         # the true detail of that rank
            M[li, k, 0] = 0
    return M
