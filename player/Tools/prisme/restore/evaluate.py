# evaluate.py <net.pt>...: networks on the held out films, a clip a moment and encode, its eight frames: PSNR and VMAF
# (libvmaf's 4K models, NEG and plain) of the decoded picture and of each network's against the true 4K, the fine
# detail kept, and over time, on the blocks the true 4K holds still, the flashing and scintillation ../network/adele.py
# scores, with the error of the frame to frame change against the truth's over the whole picture. The clean frames as
# their own source say how near the identity a network stays.
import sys, os, re, json, glob, subprocess, tempfile, numpy as np, torch, torch.nn.functional as F
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
M = glob.glob('/opt/homebrew/Cellar/libvmaf/*/share/libvmaf/model')[0]
VMAF = f"libvmaf=model='path={M}/vmaf_4k_v0.6.1neg.json\\:name=neg|path={M}/vmaf_4k_v0.6.1.json\\:name=std':n_threads=3"
nets = {os.path.basename(s)[:-3]: load(s).to('mps') for s in sys.argv[1:]}

def box(a, r):
    t = torch.from_numpy(a)[None, None]; return F.avg_pool2d(F.pad(t, (r // 2,) * 4, mode='replicate'), r, 1)[0, 0].numpy()

def blocks(a, b): h, w = a.shape; return a[:h // b * b, :w // b * b].reshape(h // b, b, w // b, b).mean((1, 3))

def vmaf(frames, truth):
    H, W = truth[0].shape
    with tempfile.TemporaryDirectory() as d:
        for name, fs in (('o', frames), ('r', truth)):
            with open(f'{d}/{name}.y', 'wb') as f:
                for a in fs: f.write(np.clip(np.rint(a), 0, 1023).astype('<u2').tobytes())
        raw = ['-f', 'rawvideo', '-pix_fmt', 'gray10le', '-s', f'{W}x{H}', '-i']
        subprocess.run(['ffmpeg', '-v', 'error', *raw, f'{d}/o.y', *raw, f'{d}/r.y', '-lavfi', f'[0][1]{VMAF}:log_fmt=json:log_path={d}/v.json',
                        '-f', 'null', '-'], check=True)
        p = json.load(open(f'{d}/v.json'))['pooled_metrics']; return p['neg']['mean'], p['std']['mean']

def scores(O, R):
    # PSNR over the clip, fine detail kept, then over time on the true 4K's still blocks and over the whole picture
    psnr = 10 * np.log10(1023 ** 2 / np.mean([np.mean((o - r) ** 2) for o, r in zip(O, R)]))
    hr = [np.abs(r - box(r, 5)) for r in R]; detail = np.mean([np.abs(o - box(o, 5))[h > 2].mean() / h[h > 2].mean() for o, h in zip(O, hr)])
    flash = still = 0; fine = []; terr = []
    for n in range(1, len(O)):
        m = blocks(np.abs(R[n] - R[n - 1]), 32) < 1.0; m32 = m.repeat(32, 0).repeat(32, 1)
        d = O[n] - O[n - 1]; dd = d[:m32.shape[0], :m32.shape[1]]
        flash += ((blocks(np.abs(d), 32) > 4) & m).sum(); still += m.sum()
        if m.any(): fine.append(np.abs(dd - box(dd, 3))[m32].mean())
        terr.append(np.abs(d - (R[n] - R[n - 1])).mean())
    return dict(psnr=psnr, detail=detail, flash=100 * flash / max(still, 1), still=still, scint=np.mean(fine) if fine else 0, terr=np.mean(terr))

if __name__ == '__main__':
    clips = {}
    for p in pairs('test'): clips.setdefault((p['film'], p['tag']), []).append(p)
    rows = []; ex = ThreadPoolExecutor(4)
    for (film, tag), ps in sorted(clips.items()):
        ps.sort(key=lambda p: p['n']); W, H = ps[0]['W'], ps[0]['H'] // 4 * 4; d = ps[0]['d']
        R = [read(p['hr'], ps[0]['W'], ps[0]['H'])[:H] for p in ps]; L = [read(p['lr'], ps[0]['W'], ps[0]['H'])[:H] for p in ps]
        s = strength(d, tag); outs = {'decoded': L}; pending = []
        for name, net in nets.items():
            with torch.no_grad():
                outs[name] = [net(torch.from_numpy(l / 1023)[None, None].to('mps'), torch.tensor([s - 1.0], device='mps'))[0, 0].cpu().numpy() * 1023 for l in L]
        for name, O in outs.items():
            O = [np.clip(np.rint(o), 0, 1023) for o in O]
            row = dict(film=film, tag=tag, mbps=0 if tag == 'clean' else mbps(d, tag), s=s, method=name, **scores(O, R))
            if name != 'decoded': row['change'] = np.mean([np.abs(o - l).mean() for o, l in zip(O, L)])
            rows.append(row); pending.append((row, ex.submit(vmaf, O, R) if tag != 'clean' else None))
        for row, f in pending:
            row['neg'], row['std'] = f.result() if f else (100, 100)
            print('%-12s %-13s %5.1f Mb/s s %.2f %-10s PSNR %6.2f  NEG %6.2f  VMAF %6.2f  detail %.3f  flash %5.2f%% (%4d)  scint %.3f  terr %.3f%s' % (
                row['film'], row['tag'], row['mbps'], row['s'], row['method'], row['psnr'], row['neg'], row['std'], row['detail'], row['flash'],
                row['still'], row['scint'], row['terr'], '  change %.3f' % row['change'] if 'change' in row else ''), flush=True)
    json.dump(rows, open(os.environ.get('OUT', '/dev/null'), 'w'), default=float)
    # the stop criterion, a network at a time, on the starved clips and on the 40 Mb/s ones
    dec = {(r['film'], r['tag']): r for r in rows if r['method'] == 'decoded'}
    for name in nets:
        q = [(r, dec[r['film'], r['tag']]) for r in rows if r['method'] == name]
        print(f'--- {name}')
        for tag in sorted({r['tag'] for r, _ in q}):
            t = [(r, b) for r, b in q if r['tag'] == tag]
            print('%-13s %2d clips  %5.1f Mb/s  dPSNR %+.2f (min %+.2f)  dNEG %+.2f  dVMAF %+.2f  detail %.3f/%.3f  flash %.2f/%.2f%%  scint %.3f/%.3f  terr %.3f/%.3f' % (
                tag, len(t), np.mean([r['mbps'] for r, _ in t]), np.mean([r['psnr'] - b['psnr'] for r, b in t]), min(r['psnr'] - b['psnr'] for r, b in t),
                np.mean([r['neg'] - b['neg'] for r, b in t]), np.mean([r['std'] - b['std'] for r, b in t]),
                np.mean([r['detail'] for r, _ in t]), np.mean([b['detail'] for _, b in t]), np.mean([r['flash'] for r, _ in t]), np.mean([b['flash'] for _, b in t]),
                np.mean([r['scint'] for r, _ in t]), np.mean([b['scint'] for _, b in t]), np.mean([r['terr'] for r, _ in t]), np.mean([b['terr'] for _, b in t])))
        st = [(r, b) for r, b in q if r['tag'] not in ('clean', 'hevc10b40000')]; hi = [(r, b) for r, b in q if r['tag'] == 'hevc10b40000']
        dp = [r['psnr'] - b['psnr'] for r, b in st]; dn = [r['neg'] - b['neg'] for r, b in st]
        print(f'starved: dPSNR {np.mean(dp):+.2f} dB (worst clip {min(dp):+.2f}), dVMAF NEG {np.mean(dn):+.2f}, '
              f'dVMAF {np.mean([r["std"] - b["std"] for r, b in st]):+.2f}; 40 Mb/s: largest |dPSNR| {max(abs(r["psnr"] - b["psnr"]) for r, b in hi):.2f} dB; '
              f'flashing {np.mean([r["flash"] for r, _ in st]):.2f}% against {np.mean([b["flash"] for _, b in st]):.2f}%, '
              f'temporal error {np.mean([r["terr"] for r, _ in st]):.3f} against {np.mean([b["terr"] for _, b in st]):.3f}')
        ok = np.mean(dp) >= 1.0 and np.mean(dn) >= 2.0 and min(dp) >= -0.2 and max(abs(r['psnr'] - b['psnr']) for r, b in hi) < 0.3 and \
             np.mean([r['flash'] for r, _ in st]) <= np.mean([b['flash'] for _, b in st]) and np.mean([r['terr'] for r, _ in st]) <= np.mean([b['terr'] for _, b in st])
        print(f'stop criterion: {"PASS" if ok else "FAIL"}')
