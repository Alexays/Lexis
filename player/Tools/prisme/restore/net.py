# The network that would restore a starved 4K stream's luma on the Neural Engine, at its own size: the picture folded
# by four into sixteen channels on a quarter of its pixels each way (960x540 for 4K), the stream's deband strength less
# 1 as a seventeenth, the scaler network's four 3x3 convolutions of 32 channels, and sixteen outputs a position
# unfolded back over the picture. Its data, the player's strength rule, and loading one back.
import glob, os, math, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
D = os.path.expanduser(os.environ.get('RESTORE_DATA', '~/prisme/restore'))

class Net(nn.Module):
    def __init__(self, ch=32, layers=4):
        super().__init__()
        self.body = nn.Sequential(*[m for i in range(layers) for m in (nn.Conv2d(17 if i == 0 else ch, ch, 3, padding=1), nn.ReLU())])
        self.tail = nn.Conv2d(ch, 16, 3, padding=1)
    def forward(self, x, s):
        h = F.pixel_unshuffle(x, 4)
        h = torch.cat([h, s.reshape(-1, 1, 1, 1).expand(-1, 1, h.shape[2], h.shape[3])], 1)
        return x + F.pixel_shuffle(self.tail(self.body(h)), 4)

def load(path):
    n = Net(); n.load_state_dict(torch.load(path, map_location='cpu')); return n.eval()

def size(d): return tuple(map(int, open(f'{d}/size').read().strip().split(',')[:2]))

def strength(d, tag):
    # the player's Deband.strength for this extract's encode: H.264 counted at half
    if tag == 'clean': return 1.0
    W, H = size(d); b = dict(l.split() for l in open(f'{d}/bytes'))[tag]
    bpp = int(b) * 8 / (24 * W * H) * (0.5 if tag.startswith('h264') else 1)
    return 1 + min(max(math.log2(0.2 / bpp) / 2, 0), 1)

def mbps(d, tag):
    return int(dict(l.split() for l in open(f'{d}/bytes'))[tag]) * 8 / 1e6

def pairs(split, root=None):
    # every encode of every kept frame, and the clean frame as its own source
    out = []
    for d in sorted(glob.glob(f'{root or D}/{split}/*')):
        if not os.path.exists(f'{d}/done'): continue
        W, H = size(d)
        for hr in sorted(glob.glob(f'{d}/hr*.y')):
            n = int(os.path.basename(hr)[2:-2])
            out.append(dict(d=d, film=os.path.basename(d), W=W, H=H, tag='clean', n=n, lr=hr, hr=hr))
            for f in sorted(glob.glob(f'{d}/*.{n}.y')):
                out.append(dict(d=d, film=os.path.basename(d), W=W, H=H, tag=os.path.basename(f).split('.')[0], n=n, lr=f, hr=hr))
    return out

def read(path, W, H):
    return np.fromfile(path, '<u2').astype(np.float32).reshape(H, W)
