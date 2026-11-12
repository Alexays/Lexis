# bank.py: a bank file read back into the arrays prisme.py applies
import struct, numpy as np

def read(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'LXSR'
    _, taps, _, strengths, coherences, levels, knots, classes, _ = struct.unpack('<9I', d[4:40])
    at = 44 + 4 * (strengths + coherences + levels + knots); n = levels * 4 * classes * 2 * taps * taps
    F = np.frombuffer(d, '<f4', n, at).reshape(levels, 4, classes, 2, taps * taps).transpose(0, 3, 1, 2, 4)
    S = np.frombuffer(d, '<f4', levels * classes * knots, at + 4 * n).reshape(levels, classes, knots)
    return F, S
