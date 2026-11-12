# train.py <out.lxsr>: a Prisme bank from the extracts under PRISME_DATA/train, as the player reads it.
# KERNELS=lanczos,... keeps only those downscales; ALPHA=a,b is each level's share of the perceptual
# curve over the least squares one, 1,1 in the shipped banks.
import sys, os, time, struct, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import prisme

def write(path, F, S):
    # little endian: the header, the bins, then [level][phase][class][pair][tap] and [level][class][knot]
    with open(path, 'wb') as f:
        f.write(b'LXSR')
        f.write(struct.pack('<9I', 1, prisme.T, prisme.ANG, len(prisme.STR), len(prisme.COH), len(prisme.LEVELS),
                            len(prisme.KNOTS), prisme.K, 0))
        f.write(struct.pack('<f', prisme.RHO))
        for a in (np.log2(prisme.STR), prisme.COH, prisme.LEVELS, prisme.KNOTS): f.write(np.asarray(a, '<f4').tobytes())
        f.write(np.ascontiguousarray(F.transpose(0, 2, 3, 1, 4)).astype('<f4').tobytes())
        f.write(np.asarray(S, '<f4').tobytes())

if __name__ == '__main__':
    out = sys.argv[1]
    kernels = os.environ['KERNELS'].split(',') if os.environ.get('KERNELS') else None
    alpha = [float(x) for x in os.environ.get('ALPHA', '1,1').split(',')]
    sms = prisme.samples('train', kernels=kernels, frames=(1,))
    print(len(sms), 'samples from', len({s['film'] for s in sms}), 'extracts', flush=True)
    t = time.time(); F, used = prisme.train(sms, soft=False, augment=True, step=2, workers=10)
    print('filters in %.0f s, classes trained by level %s' % (time.time() - t, used.sum((1, 2))), flush=True)
    # the detail kept: the least squares curve, then the map onto the true detail's magnitudes,
    # held to three times the estimate and rising
    S = prisme.fit_shrink(sms[::2], F, step=4, workers=10, soft=False)
    M = prisme.fit_match(sms[::2], F)
    M = np.maximum.accumulate(np.minimum(M, 3 * prisme.KNOTS[None, None, :]), axis=-1)
    curves = np.stack([(1 - a) * S[level] + a * M[level] for level, a in enumerate(alpha)]).astype(np.float32)
    write(out, F, curves)
    print(out, os.path.getsize(out), 'bytes, in %.0f s' % (time.time() - t))
