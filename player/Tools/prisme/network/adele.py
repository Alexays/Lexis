# adele.py <net.pt>...: Adele's still shot with its moving coat, doubled by Prisme and by each network, decoded and
# through the Enhanced rendering (~/prisme/adele.E, from bench.sh): on what the source holds still, the 32x32 blocks
# the output moves by over four codes (flashing) and a pixel's change against its 3x3's (scintillation); on the coat,
# its change once its motion is taken out, over its own contrast (pattern instability).
import sys, os, numpy as np, torch
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
sys.path.insert(0, TOOLS); import prisme, bank
GAIN = float(os.environ.get('GAIN', '0.5'))   # the network's finest detail raised by this much at the widest strength
R = RESOURCES
BANKS = {False: bank.read(R + 'Prisme.lxsr'), True: bank.read(R + 'PrismeEnhanced.lxsr')}
A = f'{ROOT}/adele'; W, H = 1920, 1040
SHIFTS = {3: (-4, -2), 4: (-3, -1), 5: (-3, 1), 6: (-2, 2), 7: (-2, 3), 8: (-3, 3), 9: (-3, 2), 10: (-2, 2)}
def frame(n, enhanced):
    path = f'{A}.E/f{n:03d}-{W}x{H}.E.yuv' if enhanced else f'{A}/f{n:03d}-{W}x{H}.yuv'
    return np.fromfile(path, '<u2', count=W * H).astype(np.float32).reshape(H, W)
def blocks(a, b): h, w = a.shape; return a[:h // b * b, :w // b * b].reshape(h // b, b, w // b, b).mean((1, 3))
torch.set_num_threads(8)
methods = [('prisme', None)] + [(os.path.basename(s), load(s)) for s in sys.argv[1:]]
for enhanced in (False, True):
    for name, net in methods:
        up = lambda L: prisme.apply_shrunk(L, *BANKS[enhanced], 1.78, 1.0, True, False) if net is None else (lambda O: O + GAIN * 0.78 * (O - prisme.box(O, 3)))(run(net, L, 1.78))
        out = {n: np.clip(np.rint(up(frame(n, enhanced))), 4, 1019) for n in range(2, 31)}
        flash = still = 0; fine = []
        for n in range(4, 31):
            m = blocks(np.abs(frame(n, False) - frame(n - 1, False)), 16) < 1.0; m4 = m.repeat(32, 0).repeat(32, 1)[:2 * H, :2 * W]
            d = out[n] - out[n - 1]; fine.append(np.abs(d - prisme.box(d, 3))[m4].mean())
            flash += ((blocks(np.abs(d), 32) > 4) & m).sum(); still += m.sum()
        x0, y0, w, h = 1400, 1640, 1400, 400; coat = []
        for n in range(3, 11):
            dy, dx = SHIFTS[n]; t = out[n][y0:y0 + h, x0:x0 + w]; d = t - out[n - 1][y0 + 2 * dy:y0 + 2 * dy + h, x0 + 2 * dx:x0 + 2 * dx + w]
            coat.append(np.sqrt(np.mean(d ** 2)) / np.std(t))
        print(f'{"enhanced" if enhanced else "decoded":8s} {name:16s} flashing {100 * flash / still:.2f}%  scintillation {np.mean(fine):.3f}  '
              f'pattern instability {np.mean(coat):.3f}', flush=True)
