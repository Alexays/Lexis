# Prisme

Prisme is the player's scaler: it doubles a picture with filters learned against true 4K. This folder is
what trains those filters and the network that takes their place on the Neural Engine. The kernel that runs
them is `Sources/LexisPlayer/Upscaler.swift`; it loads `Sources/LexisPlayer/Resources/Prisme.lxsr` and
`PrismeNet.mlmodelc`.

## How it works

For every other source pixel each way, the gradients around it are summed into a structure tensor. Its
orientation, strength and coherence pick one of 48 classes, which its three neighbours share. Each class
holds, for each of the four output pixels a source pixel becomes, a pair of 4x4 filters: one estimates
the true 4K pixel, the other the same pixel blurred. Their difference is the detail. A curve learned per
class then keeps, shrinks or raises that detail, and the result is held within the four source pixels
around it, so an edge never overshoots.

Two banks are learned, one on clean masters and one on starved encodes, and mixed by `Deband.strength`,
1 to 2, which the player already reads off a stream's bits per pixel.

The approach follows RAISR (Romano, Isidoro, Milanfar, 2016) and BLADE (Getreuer et al., 2017). Three
things are added here:

- the pair of filters, which gives the detail in the one pass, with no neighbouring output to wait for;
- the curve learned per class for that detail, by least squares;
- a second curve per class that maps the estimated detail's magnitudes onto the true detail's, by
  quantiles, after the perception-distortion tradeoff (Blau and Michaeli, 2018). `ALPHA` mixes the two.

## Files

- `prisme.py`: the scaler as numpy, the training, and the scalers it replaced, kept to compare against.
- `train.py`: a bank from a dataset.
- `evaluate.py`: a bank against the true 4K of the held out films.
- `bank.py`: a bank file read back.
- `dataset.sh`: the dataset, from 4K films on a Plex server, listed in a `films.txt` of your own (its
  format is at the top of the script; the list the banks were trained on is not published).
- `stability.py`: what a bank does over time to a starved film in motion: flashing, pattern instability.

`prisme.py` matches the Metal kernel to a tenth of a ten bit code on average. Check it again after
changing either.

## Training

Every dataset script reads a `films.txt` of your own, one film a line, its format at the top of the script:
`name|/library/parts/<id>/<stamp>/file.mkv|minutes|train or test|kernels`, the part path being the one your
Plex server gives the 4K file. The list the shipped banks were trained on is not published.

### The filters

Needs `ffmpeg` with libx264, libx265 and libvmaf, and `numpy`.

```sh
cd player/Tools/prisme
PLEX_BASE=https://<server>:32400 PLEX_TOKEN=<token> ./dataset.sh films.txt ~/prisme/data

# Prisme.lxsr: every downscale, clean and encoded
PRISME_DATA=~/prisme/data python3 train.py ../../Sources/LexisPlayer/Resources/Prisme.lxsr
PRISME_DATA=~/prisme/data python3 evaluate.py ../../Sources/LexisPlayer/Resources/Prisme.lxsr reference
```

The dataset is 14 films to train on and 3 held out to test, three moments of each, three frames a moment:
about 10 GB. Each extract is halved by several kernels, then left clean in ten bits or encoded by x264 at
CRF 20 and 28 and by x265 at 2 Mb/s. The spline kernel is kept out of the training to test on.

### What the filters measured

On the held out films, VMAF NEG against true 4K, the scaler before Prisme (Lanczos 3 or FSR 1's EASU,
then a cored sharpen) first:

| | before | Prisme |
|---|---|---|
| clean source | 96.99 | 97.81 |
| encoded source | 86.90 | 87.05 |
| clean source, fine detail kept | 0.96 | 0.94 |
| clean source, overshoot | 0.058 | 0.010 |


Tried and dropped, each measured: soft selection between neighbouring classes (no steadier, four times
the cost), 288 classes and 6x6 filters (no better than 48 and 4x4), a class for the codec's block grid,
a restoration pass ahead of the scaler, a shorter structure tensor window (no faster on an A15), a class
shared across 4x4 source pixels (a tenth of a point of VMAF lost), banks at four levels of starvation
trained on encodes at a library's own bitrates (no better on encoded sources at equal detail), the frame
before as a second source (0.02 dB on still pixels), a grain laid at 4K (every measure against true 4K
falls with it).

### The network

`network/` trains the network the player doubles the luma with on the Neural Engine, in the filters' place, where
it keeps up with the film (`Upscaler.Network`). Four 3x3 convolutions of 32 channels at a quarter of the source's
pixels, the stream's deband strength as a fifth input channel, sixteen output pixels a position over the nearest
neighbour, learned by L1 against true 4K. On the GPU after it, its finest detail is raised by a fifth, and half
again at the widest starvation.

```sh
cd player/Tools/prisme/network
# the filters' films at three moments, and a second, longer list at two, at a library's own bitrates
FRACS="25 50 75" PLEX_BASE=... PLEX_TOKEN=... ./dataset.sh ../films.txt ~/prisme/data
PLEX_BASE=... PLEX_TOKEN=... ./dataset.sh films.txt ~/prisme/data
python3 train.py ~/prisme/net.pt
python3 export.py ~/prisme/net.pt PrismeNet.mlpackage
xcrun coremlcompiler compile PrismeNet.mlpackage ../../../Sources/LexisPlayer/Resources/
python3 evaluate.py ~/prisme/net.pt
```

Needs PyTorch and coremltools (Python 3.12, PyTorch 2.7). Keep `~/prisme` out of `~/Library/Caches`, which macOS
empties when the disk runs short.

Against true 4K on the held out films, VMAF NEG, the filters first:

| | filters | network |
|---|---|---|
| clean source | 97.8 | 99.2 |
| encoded source | 89.1 | 89.0 |

On an Apple TV 4K (A15) it takes 13 to 14 ms a frame on the Neural Engine, and the GPU's share of the scale falls
from about 15 ms to 2.

Tried and dropped, each measured: a loss on the amount of fine detail (it scintillates), a frequency loss (no
better), a perceptual loss (LPIPS; texture that scintillates twice as much and flashes), the frame before carried as features (0.1 to 0.2 VMAF), 48 channels (0.1 for twice the work).

### Restoration

`restore/` trains a network that cleans a starved 4K stream at full size, exported for the Neural Engine on a
3840x2160 canvas and timed against the scaler. It is an experiment: the player does not ship it.
