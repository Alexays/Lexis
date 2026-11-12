# train.py <out.pt> [steps]: the network on every encode of the training films and on their clean frames, by mean squared
# error against the true 4K. Crops are read from the files, not mapped, as ../network/train.py reads them, and sit on the
# codec's 16 pixel grid, as a whole picture's do in the player.
import sys, os, time, numpy as np, torch, torch.nn.functional as F
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
out = sys.argv[1]; steps = int(sys.argv[2]) if len(sys.argv) > 2 else 60000
# L1, as the scaler is trained, keeps the identity: the encode's error is mostly the grain it dropped, which no
# input predicts, and its median is nought. LOSS=l1 trains that way; the default is the mean squared error.
L1 = os.environ.get('LOSS') == 'l1'
torch.manual_seed(0); rng = np.random.default_rng(0)
ps = pairs('train')
for p in ps: p['s'] = strength(p['d'], p['tag']) - 1
print(f'{len(ps)} pairs, {sum(p["tag"] == "clean" for p in ps)} clean', flush=True)
def rows(path, w, y0, n):
    with open(path, 'rb') as f:
        f.seek(y0 * w * 2); return np.frombuffer(f.read(n * w * 2), '<u2').reshape(n, w)
P = 192; B = 32
def batch():
    xs = np.empty((B, 1, P, P), np.float32); ys = np.empty((B, 1, P, P), np.float32); ss = np.empty(B, np.float32)
    for i in range(B):
        p = ps[rng.integers(len(ps))]; h, w = p['H'], p['W']
        y0 = 16 * rng.integers(0, (h - P) // 16); x0 = 16 * rng.integers(0, (w - P) // 16); k = rng.integers(8)
        x = rows(p['lr'], w, y0, P)[:, x0:x0 + P]; y = x if p['tag'] == 'clean' else rows(p['hr'], w, y0, P)[:, x0:x0 + P]
        if k & 1: x, y = x[:, ::-1], y[:, ::-1]
        if k & 2: x, y = x[::-1], y[::-1]
        if k & 4: x, y = x.T, y.T
        xs[i, 0] = x; ys[i, 0] = y; ss[i] = p['s']
    return xs / 1023, ys / 1023, ss
# a quarter of the scaler network's rate: the residual is a few codes, and at its rate the last layer's units all die
net = Net().to('mps'); opt = torch.optim.Adam(net.parameters(), 2.5e-4)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, 5e-4, total_steps=steps, pct_start=0.05)
t = time.time(); run_loss = 0; reader = ThreadPoolExecutor(1); nxt = reader.submit(batch)
for s in range(steps):
    # the next batch is read while this one trains
    x, y, sv = (torch.from_numpy(a).to('mps') for a in nxt.result()); nxt = reader.submit(batch); loss = F.l1_loss(net(x, sv), y) if L1 else F.mse_loss(net(x, sv), y)
    opt.zero_grad(); loss.backward(); opt.step(); sched.step(); run_loss = 0.99 * run_loss + 0.01 * loss.item()
    if s % 2000 == 0 or s == steps - 1: print(f'step {s} loss {(run_loss if L1 else run_loss ** 0.5) * 1023:.3f} codes {time.time() - t:.0f} s', flush=True)
torch.save(net.state_dict(), out)
