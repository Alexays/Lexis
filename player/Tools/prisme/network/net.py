# The network the player can double the luma with on the Neural Engine: convolutions at a quarter of the source's
# pixels, four to a position, the stream's deband strength less 1 as a fifth channel, then the sixteen output pixels
# of each position over the nearest neighbour. Its data, the player's strength rule, and loading one back.
import glob, os, math, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
ROOT = os.path.expanduser(os.environ.get('NET_ROOT', '~/prisme'))
D = os.path.expanduser(os.environ.get('NET_DATA', f'{ROOT}/data'))
TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(TOOLS, '../../Sources/LexisPlayer/Resources/')

class Net(nn.Module):
    def __init__(self, ch=32, layers=4):
        super().__init__()
        self.body = nn.Sequential(*[m for i in range(layers) for m in (nn.Conv2d(5 if i == 0 else ch, ch, 3, padding=1), nn.ReLU())])
        self.tail = nn.Conv2d(ch, 16, 3, padding=1)
    def forward(self, x, s):
        h = F.pixel_unshuffle(x, 2)
        h = torch.cat([h, s.reshape(-1, 1, 1, 1).expand(-1, 1, h.shape[2], h.shape[3])], 1)
        return F.interpolate(x, scale_factor=2, mode='nearest') + F.pixel_shuffle(self.tail(self.body(h)), 4)

def load(path):
    n = Net(); n.load_state_dict(torch.load(path, map_location='cpu')); return n.eval()

def run(net, L, strength):
    # a whole picture's luma, in ten bit codes, doubled
    with torch.no_grad(): return net(torch.from_numpy(L / 1023)[None, None].float(), torch.tensor([strength - 1.0]))[0, 0].numpy() * 1023

def size(d): return tuple(map(int, open(f'{d}/size').read().strip().split(',')[:2]))

def strength(d, kernel, tag):
    # the player's Deband.strength for this extract's encode: H.264 counted at half
    if tag == 'c10': return 1.0
    W, H = size(d); b = dict(l.split() for l in open(f'{d}/bytes'))[f'{kernel}.{tag}']
    bpp = int(b) * 8 / (24 * W // 2 * H // 2) * (1 if tag.startswith('hevc') else 0.5)
    return 1 + min(max(math.log2(0.2 / bpp) / 2, 0), 1)

def pairs(split, root=None):
    out = []
    for d in sorted(glob.glob(f'{root or D}/{split}/*')):
        if not os.path.exists(f'{d}/done'): continue
        W, H = size(d)
        for f in sorted(glob.glob(f'{d}/*.*.[1-8].y')):
            kernel, tag, n = os.path.basename(f).split('.')[:3]
            if os.path.exists(f'{d}/hr{n}.y'):
                out.append(dict(d=d, film=os.path.basename(d), W=W, H=H, kernel=kernel, tag=tag, n=int(n), lr=f, hr=f'{d}/hr{n}.y'))
    return out

def read(p):
    L = np.fromfile(p['lr'], '<u2').astype(np.float32).reshape(p['H'] // 2, p['W'] // 2)
    R = np.fromfile(p['hr'], '<u2').astype(np.float32).reshape(p['H'], p['W'])
    return L, R
