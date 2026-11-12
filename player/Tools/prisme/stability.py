# stability.py <frames> <bank.lxsr> [strength]: what a bank does over time to a starved film in motion.
# <frames> holds thirty consecutive 1920x1040 frames, f001-1920x1040.yuv on, ten bit planar, of a shot whose
# still background and one moving patterned coat are what is measured:
#   ffmpeg -ss 600 -i <Mon amie Adele, s01e01> -frames:v 30 -pix_fmt yuv420p10le -f image2 -c:v rawvideo f%03d-1920x1040.yuv
# Flashing: blocks the source holds still that the output moves by over four codes. Pattern instability: the
# coat's change from frame to frame once its motion is taken out, over its own contrast. SUFFIX names frames
# that went through a rendering first, f001-1920x1040<SUFFIX>.
import sys, os, numpy as np
from concurrent.futures import ProcessPoolExecutor
from numpy.lib.stride_tricks import sliding_window_view
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import prisme, bank
D = sys.argv[1]; F, S = bank.read(sys.argv[2]); s = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
SUFFIX = os.environ.get('SUFFIX', '.yuv'); W, H = 1920, 1040
# the coat's motion from each frame to the one before, in source pixels
SHIFTS = {3: (-4, -2), 4: (-3, -1), 5: (-3, 1), 6: (-2, 2), 7: (-2, 3), 8: (-3, 3), 9: (-3, 2), 10: (-2, 2)}

def luma(n, suffix='.yuv'):
    return np.fromfile(f'{D}/f{n:03d}-{W}x{H}{suffix}', '<u2', count=W * H).astype(np.float32).reshape(H, W)

def scaled(n):
    return np.clip(np.rint(prisme.apply_shrunk(luma(n, SUFFIX), F, S, s, 1.0, True, False)), 4, 1019).astype(np.float64)

def blocks(a, b):
    h, w = a.shape; return a[:h // b * b, :w // b * b].reshape(h // b, b, w // b, b).mean((1, 3))

if __name__ == '__main__':
    with ProcessPoolExecutor(8) as ex: out = dict(zip(range(2, 31), ex.map(scaled, range(2, 31))))
    still = flash = 0; detail = []
    for n in range(4, 31):
        m = blocks(np.abs(luma(n) - luma(n - 1)), 16) < 1.0; moved = blocks(np.abs(out[n] - out[n - 1]), 32)
        still += m.sum(); flash += ((moved > 4) & m).sum()
        if n % 5 == 0: detail.append(np.abs(out[n] - sliding_window_view(np.pad(out[n], 2, mode='edge'), (5, 5)).mean((-1, -2))).mean())
    x0, y0, w, h = 1400, 1640, 1400, 400; coat = []
    for n in range(3, 11):
        dy, dx = SHIFTS[n]; t = out[n][y0:y0 + h, x0:x0 + w]; d = t - out[n - 1][y0 + 2 * dy:y0 + 2 * dy + h, x0 + 2 * dx:x0 + 2 * dx + w]
        coat.append(np.sqrt(np.mean(d ** 2)) / np.std(t))
    print('flashing %.2f%%  pattern instability %.3f  fine detail %.2f' % (100 * flash / still, np.mean(coat), np.mean(detail)))
