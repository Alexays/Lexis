# evaluate.py <bank.lxsr> [reference]: the bank against the true 4K of the extracts under PRISME_DATA/test,
# by film, downscale and encode; with `reference`, the Lanczos or edge directed scaler and sharpen it replaced too.
# VMAF NEG by ffmpeg's libvmaf (VMAF_MODEL names the 4K NEG model), SSIM, fine detail and overshoot by numpy.
import sys, os, re, subprocess, tempfile, numpy as np
from concurrent.futures import ProcessPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import prisme, bank
from numpy.lib.stride_tricks import sliding_window_view as sw
MODEL = os.environ.get('VMAF_MODEL', '/opt/homebrew/share/libvmaf/model/vmaf_4k_v0.6.1neg.json')
methods = ['prisme'] + sys.argv[2:]
F, S = bank.read(sys.argv[1])

def ssim(a, b):
    C1, C2 = (0.01 * 1023) ** 2, (0.03 * 1023) ** 2
    ma, mb = prisme.box(a, 7), prisme.box(b, 7); va = prisme.box(a * a, 7) - ma * ma; vb = prisme.box(b * b, 7) - mb * mb
    cov = prisme.box(a * b, 7) - ma * mb
    return np.mean(((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2)))

def group(args):
    film, kernel, tag, sms = args
    lines = []
    for m in methods:
        ss = []; dr = []; ha = []
        W, H = sms[0]['W'], sms[0]['H']; chroma = np.full(W * H // 2, 512, '<u2').tobytes()
        with tempfile.TemporaryDirectory() as d:
            with open(d + '/d.yuv', 'wb') as fd, open(d + '/r.yuv', 'wb') as fr:
                for sm in sms:
                    L, R = prisme.load(sm)
                    O = prisme.production(L, sm['s']) if m == 'reference' else prisme.apply_shrunk(L, F, S, sm['s'], 1.0, True, False)
                    O = np.clip(np.rint(O), 4, 1019)
                    fd.write(O.astype('<u2').tobytes() + chroma); fr.write(R.astype('<u2').tobytes() + chroma)
                    # detail: the picture's relief over its 5x5 against the truth's; halo: what goes past the truth's 5x5 range
                    ss.append(ssim(O, R)); hr = np.abs(R - prisme.box(R, 5)); hd = np.abs(O - prisme.box(O, 5)); msk = hr > 2
                    dr.append(hd[msk].mean() / hr[msk].mean())
                    p = np.pad(R, 2, mode='edge'); win = sw(p, (5, 5))
                    ha.append(np.mean(np.maximum(O - win.max((-1, -2)), 0) + np.maximum(win.min((-1, -2)) - O, 0)))
            out = subprocess.run(['ffmpeg', '-hide_banner', '-f', 'rawvideo', '-pix_fmt', 'yuv420p10le', '-s', f'{W}x{H}', '-i', d + '/d.yuv',
                                  '-f', 'rawvideo', '-pix_fmt', 'yuv420p10le', '-s', f'{W}x{H}', '-i', d + '/r.yuv',
                                  '-lavfi', f'libvmaf=model=path={MODEL}:n_threads=2', '-f', 'null', '-'], capture_output=True, text=True).stderr
        vm = float(re.search(r'VMAF score: ([\d.]+)', out).group(1))
        lines.append((film, kernel, tag, m, vm, np.mean(ss), np.mean(dr), np.mean(ha), np.mean([sm['s'] for sm in sms])))
    return lines

if __name__ == '__main__':
    sms = prisme.samples('test', frames=(1, 3))
    groups = {}
    for sm in sms: groups.setdefault((sm['film'].split('-')[0], sm['kernel'], sm['tag']), []).append(sm)
    rows = []
    with ProcessPoolExecutor(6) as ex:
        for lines in ex.map(group, [(f, k, t, v) for (f, k, t), v in sorted(groups.items())]):
            for l in lines: print('%-8s %-8s %-10s %-10s VMAF %.2f  SSIM %.4f  detail %.2f  halo %.3f  s %.2f' % l, flush=True); rows.append(l)
    print('--- means over every group')
    for m in methods:
        r = [l for l in rows if l[3] == m]
        for sel, name in ((lambda l: True, 'all'), (lambda l: l[2] == 'c10', 'clean'), (lambda l: l[2] != 'c10', 'encoded')):
            q = [l for l in r if sel(l)]
            if q: print('%-10s %-8s VMAF %.2f  SSIM %.4f  detail %.2f  halo %.3f' % (m, name, *(np.mean([l[i] for l in q]) for i in (4, 5, 6, 7))))
