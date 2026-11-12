# train.py <out.pt> [steps]: the network on every downscale but the spline, clean and encoded, by L1 against the
# true 4K. Crops are read from the files, not mapped: thousands of mapped pictures hold their pages as the process's
# own and push the machine into swap.
import sys, os, time, numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
out = sys.argv[1]; steps = int(sys.argv[2]) if len(sys.argv) > 2 else 150000
torch.manual_seed(0); rng = np.random.default_rng(0)
ps = [p for p in pairs('train') if p['kernel'] != 'spline']
for p in ps: p['s'] = strength(p['d'], p['kernel'], p['tag']) - 1
def rows(path, w, y0, n):
    with open(path, 'rb') as f:
        f.seek(y0 * w * 2); return np.frombuffer(f.read(n * w * 2), '<u2').reshape(n, w)
P = 48; B = 64
def batch():
    xs = np.empty((B, 1, P, P), np.float32); ys = np.empty((B, 1, 2 * P, 2 * P), np.float32); ss = np.empty(B, np.float32)
    for i in range(B):
        p = ps[rng.integers(len(ps))]; h, w = p['H'] // 2, p['W'] // 2
        y0 = rng.integers(0, h - P); x0 = rng.integers(0, w - P); k = rng.integers(8)
        x = rows(p['lr'], w, y0, P)[:, x0:x0 + P]; y = rows(p['hr'], 2 * w, 2 * y0, 2 * P)[:, 2 * x0:2 * x0 + 2 * P]
        if k & 1: x, y = x[:, ::-1], y[:, ::-1]
        if k & 2: x, y = x[::-1], y[::-1]
        if k & 4: x, y = x.T, y.T
        xs[i, 0] = x; ys[i, 0] = y; ss[i] = p['s']
    return torch.from_numpy(xs / 1023).to('mps'), torch.from_numpy(ys / 1023).to('mps'), torch.from_numpy(ss).to('mps')
net = Net().to('mps'); opt = torch.optim.Adam(net.parameters(), 1e-3)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, 2e-3, total_steps=steps, pct_start=0.05)
t = time.time(); run_loss = 0
for s in range(steps):
    x, y, sv = batch(); loss = F.l1_loss(net(x, sv), y)
    opt.zero_grad(); loss.backward(); opt.step(); sched.step(); run_loss = 0.99 * run_loss + 0.01 * loss.item()
    if s % 5000 == 0 or s == steps - 1: print(f'step {s} loss {run_loss * 1023:.3f} codes {time.time() - t:.0f} s', flush=True)
torch.save(net.state_dict(), out)
