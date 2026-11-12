# evaluate.py <net.pt>...: networks against Prisme on the held out films, by film, downscale and encode, as
# Tools/prisme/evaluate.py scores: VMAF NEG by libvmaf, SSIM, fine detail and overshoot against the truth.
# PRISME=0 leaves Prisme out.
import sys, os, re, glob, subprocess, tempfile, numpy as np, torch
from concurrent.futures import ProcessPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
sys.path.insert(0, TOOLS); import prisme, bank
GAIN = float(os.environ.get('GAIN', '0.5'))   # the network's finest detail raised by this much at the widest strength, as the player does
from numpy.lib.stride_tricks import sliding_window_view as sw
MODEL = glob.glob('/opt/homebrew/Cellar/libvmaf/*/share/libvmaf/model/vmaf_4k_v0.6.1neg.json')[0]
BANK = bank.read(RESOURCES + 'Prisme.lxsr')
SPECS = sys.argv[1:]

def ssim(a, b):
    C1, C2 = (0.01 * 1023) ** 2, (0.03 * 1023) ** 2
    ma, mb = prisme.box(a, 7), prisme.box(b, 7); va = prisme.box(a * a, 7) - ma * ma; vb = prisme.box(b * b, 7) - mb * mb
    cov = prisme.box(a * b, 7) - ma * mb
    return np.mean(((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2)))

def group(ps):
    torch.set_num_threads(2); nets = {os.path.basename(s): load(s) for s in SPECS}
    names = (['prisme'] if os.environ.get('PRISME', '1') == '1' else []) + list(nets)
    lines = []
    for name in names:
        ss = []; dr = []; ha = []; W, H = ps[0]['W'], ps[0]['H']; chroma = np.full(W * H // 2, 512, '<u2').tobytes()
        with tempfile.TemporaryDirectory() as d:
            with open(d + '/d.yuv', 'wb') as fd, open(d + '/r.yuv', 'wb') as fr:
                for p in ps:
                    L, R = read(p); s = strength(p['d'], p['kernel'], p['tag'])
                    O = prisme.apply_shrunk(L, *BANK, s, 1.0, True, False) if name == 'prisme' else run(nets[name], L, s)
                    if name != 'prisme' and GAIN: O = O + GAIN * (s - 1) * (O - prisme.box(O, 3))
                    O = np.clip(np.rint(O), 4, 1019)
                    fd.write(O.astype('<u2').tobytes() + chroma); fr.write(np.clip(np.rint(R), 0, 1023).astype('<u2').tobytes() + chroma)
                    ss.append(ssim(O, R)); hr = np.abs(R - prisme.box(R, 5)); hd = np.abs(O - prisme.box(O, 5)); msk = hr > 2
                    dr.append(hd[msk].mean() / hr[msk].mean())
                    win = sw(np.pad(R, 2, mode='edge'), (5, 5))
                    ha.append(np.mean(np.maximum(O - win.max((-1, -2)), 0) + np.maximum(win.min((-1, -2)) - O, 0)))
            err = subprocess.run(['ffmpeg', '-hide_banner', '-f', 'rawvideo', '-pix_fmt', 'yuv420p10le', '-s', f'{W}x{H}', '-i', d + '/d.yuv',
                                  '-f', 'rawvideo', '-pix_fmt', 'yuv420p10le', '-s', f'{W}x{H}', '-i', d + '/r.yuv',
                                  '-lavfi', f'libvmaf=model=path={MODEL}:n_threads=2', '-f', 'null', '-'], capture_output=True, text=True).stderr
        vm = float(re.search(r'VMAF score: ([\d.]+)', err).group(1))
        lines.append((ps[0]['film'].split('-')[0], ps[0]['kernel'], ps[0]['tag'], name, vm, np.mean(ss), np.mean(dr), np.mean(ha)))
    return lines

if __name__ == '__main__':
    groups = {}
    for p in pairs('test'):
        if p['n'] != 2: groups.setdefault((p['film'].split('-')[0], p['kernel'], p['tag']), []).append(p)
    rows = []
    with ProcessPoolExecutor(6) as ex:
        for lines in ex.map(group, [v for _, v in sorted(groups.items())]):
            for l in lines: print('%-8s %-8s %-10s %-14s VMAF %.2f  SSIM %.4f  detail %.2f  halo %.3f' % l, flush=True); rows.append(l)
    print('--- means over every group')
    for m in sorted({l[3] for l in rows}):
        for sel, name in ((lambda l: l[2] == 'c10', 'clean'), (lambda l: l[2] != 'c10', 'encoded')):
            q = [l for l in rows if l[3] == m and sel(l)]
            if q: print('%-14s %-8s VMAF %.2f  SSIM %.4f  detail %.2f  halo %.3f' % (m, name, *(np.mean([l[i] for l in q]) for i in (4, 5, 6, 7))))
