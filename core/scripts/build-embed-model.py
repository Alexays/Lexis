#!/usr/bin/env python3
"""Repacks the pinned encoder into a smaller artifact, and measures it.

The app does not need this. `core/src/embed/download.rs` pins the upstream
files on Hugging Face's own CDN, unmodified, and installs them with no
credential and nothing published anywhere. This script exists to put a number
on the alternative: what the same encoder costs if somebody hosts a repacked
copy of it, and how much of a device's memory that would save.

The word table is 366 MiB of the 449 MiB and is only ever read one row at a
time, so int8 with a scale per row costs almost nothing in accuracy. The
encoder body is what every matmul runs through, so it stays float16.

Usage: build-embed-model.py <model.safetensors> <out.safetensors>
"""
import json
import struct
import sys

import numpy as np

WORDS = "embeddings.word_embeddings.weight"
# nothing reads either: the pooling is a mean over the hidden states, and the
# position ids are a range this reader builds for itself
DROP = ("pooler.", "embeddings.position_ids")


def main() -> int:
    src, out_path = sys.argv[1:3]

    with open(src, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        blob = np.memmap(src, dtype=np.uint8, mode="r", offset=8 + n)

    tensors = {}
    for name, info in header.items():
        if name == "__metadata__" or name.startswith(DROP):
            continue
        if info["dtype"] != "F32":
            continue
        a, b = info["data_offsets"]
        tensors[name] = blob[a:b].view(np.float32).reshape(info["shape"])
    if WORDS not in tensors:
        raise SystemExit(f"{src} has no {WORDS}")

    entries, body = {}, bytearray()

    def put(name, array, dtype):
        payload = array.astype(dtype).tobytes()
        entries[name] = {
            "dtype": {"int8": "I8", "float16": "F16", "float32": "F32"}[dtype],
            "shape": list(array.shape),
            "data_offsets": [len(body), len(body) + len(payload)],
        }
        body.extend(payload)

    words = np.asarray(tensors.pop(WORDS), dtype=np.float32)
    # one scale per row rather than one for the table: a row is dequantized
    # whole at lookup, so a per-row scale costs one multiply and keeps the
    # rows a global scale would flatten
    scale = np.abs(words).max(axis=1) / 127.0
    scale[scale == 0] = 1.0
    put(WORDS, np.clip(np.rint(words / scale[:, None]), -127, 127), "int8")
    put(WORDS + ".scale", scale, "float32")

    for name, array in tensors.items():
        # LayerNorm gains and every bias stay float32: they are a rounding
        # error's worth of bytes and the thing float16 loses most on
        keep = name.endswith(".bias") or "LayerNorm" in name or "position_embeddings" in name
        put(name, np.asarray(array), "float32" if keep else "float16")

    encoded = json.dumps(entries, separators=(",", ":")).encode("utf-8")
    encoded += b" " * ((8 - (8 + len(encoded)) % 8) % 8)
    with open(out_path, "wb") as f:
        f.write(struct.pack("<Q", len(encoded)))
        f.write(encoded)
        f.write(body)

    total = 8 + len(encoded) + len(body)
    source = 8 + n + len(blob)
    print(f"{src}: {source / 1048576:.2f} MiB")
    print(f"{out_path}: {total / 1048576:.2f} MiB ({source / total:.2f}x smaller)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
