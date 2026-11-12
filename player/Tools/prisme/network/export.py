# export.py <net.pt> <out.mlpackage>: the network as the Core ML program the player bundles, compiled by
# `xcrun coremlcompiler compile` into Sources/LexisPlayer/Resources/PrismeNet.mlmodelc, for the Neural Engine on a
# 1920x1088 canvas. The strength channel, constant over the picture, folds into a bias scaled by the `strength` input.
import sys, os, numpy as np, torch, torch.nn as nn, torch.nn.functional as F, coremltools as ct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from net import *
n = load(sys.argv[1]); W, H = 1920, 1088
class Deploy(nn.Module):
    def __init__(self, n):
        super().__init__(); self.n = n; first = n.body[0]
        self.first = nn.Conv2d(4, first.out_channels, 3, padding=1)
        self.first.weight.data = first.weight.data[:, :4].clone(); self.first.bias.data = first.bias.data.clone()
        self.fold = nn.Parameter(first.weight.data[:, 4].sum((1, 2)).view(1, -1, 1, 1).clone())
    def forward(self, x, s):
        h = F.relu(self.first(F.pixel_unshuffle(x, 2)) + s * self.fold)
        for m in list(self.n.body)[2:]: h = m(h)
        return F.interpolate(x, scale_factor=2, mode='nearest') + F.pixel_shuffle(self.n.tail(h), 4)
d = Deploy(n).eval(); x = torch.rand(1, 1, H, W); s = torch.full((1, 1, 1, 1), 0.5)
with torch.no_grad(): ref = n(x, torch.tensor([0.5])); got = d(x, s)
print(f'folded against concatenated, inside the border: {(ref - got)[..., 64:-64, 64:-64].abs().max().item() * 1023:.4f} codes')
m = ct.convert(torch.jit.trace(d, (x, s)),
               inputs=[ct.TensorType('luma', x.shape, np.float16), ct.TensorType('strength', s.shape, np.float16)],
               outputs=[ct.TensorType('scaled', dtype=np.float16)], convert_to='mlprogram', compute_precision=ct.precision.FLOAT16,
               compute_units=ct.ComputeUnit.CPU_AND_NE, minimum_deployment_target=ct.target.tvOS17)
m.save(sys.argv[2])
feed = {'luma': x.numpy().astype(np.float16), 'strength': s.numpy().astype(np.float16)}
print(f'Core ML against torch: {np.abs(m.predict(feed)["scaled"] - ref.numpy())[..., 64:-64, 64:-64].mean() * 1023:.3f} codes mean inside')
