# The embedding model

The encoder is [`intfloat/multilingual-e5-small`][upstream], Apache-2.0: a
twelve-layer BERT, 384 dimensions, over the 250 037-piece XLM-RoBERTa
SentencePiece vocabulary. It is multilingual because the library is French and
so are the synopses.

Three files are fetched, all unmodified, all from Hugging Face's own CDN at a
pinned commit:

| file | bytes | MiB |
| --- | --- | --- |
| `model.safetensors` | 470 641 600 | 448.84 |
| `tokenizer.json` | 17 082 730 | 16.29 |
| `config.json` | 655 | 0.00 |
| total | 487 724 985 | 465.13 |

`config.json` is what the weights do not say: the head count (the forward pass
splits the width into that many heads), the LayerNorm epsilon, and whether
positions are numbered from zero (BERT) or from past the padding id
(XLM-RoBERTa).

Nothing is committed and nothing is bundled. The app downloads them into its
cache directory once, verifies each against the length and SHA-256 pinned in
`core/src/embed/download.rs`, and works without them: with no model the home
rows are the ones TMDB's links and the genre counts give on their own.

## Why the upstream files rather than a repack

The URLs above are public and answer an unauthenticated GET, so a device
installs the encoder with no credential and nothing published by anybody. The
release this replaced pointed at an asset that did not exist, which is why the
personalised rows had never run anywhere.

A repacked artifact would be smaller. `core/scripts/build-embed-model.py`
builds one, to put a number on it rather than to ship it: the word table
quantized to int8 with a scale per row, the encoder body in float16, the
pooler and the position ids dropped. That comes to **134.02 MiB**, 3.35 times
smaller, 150.31 MiB with the tokenizer beside it. Taking it would mean
somebody hosting that file, which is a decision for whoever owns the
repository, not for the code.

## What it costs to run

Measured over the owner's 3798-title library on an M4 Pro, release build:
**74 ms per title**, so a full pass over a library that size is about five
minutes of background work, resumable batch by batch. Loading the model is
270 ms. The neighbour sweep that follows it is 130 ms for the whole library.

Memory is the part to watch, and it is not the weights. The word table is
366 MiB of the 449 MiB and one title reads a few hundred of its rows, so it
stays on the memory mapping and is gathered a row at a time; only the encoder
body, the position table and the LayerNorms are copied into tensors, about
81 MiB. But `tokenizers` turns the 16 MiB `tokenizer.json` into **388 MiB** of
resident Unigram trie, which dwarfs everything else here and is steady state
rather than a spike during parsing. Version 0.23 does the same as 0.21.

That is the ceiling on this design. The two ways down from it are a Unigram
implementation whose trie is not a hash map per node, or an encoder whose
tokenizer is a WordPiece vocabulary rather than SentencePiece: WordPiece needs
one hash map and no trie. Until then `embed_pending` dropping the model the
moment its queue empties is what keeps the cost to the length of a pass rather
than the life of the process. A question asked in words (`ask`) borrows the
same model, read off the cache and never fetched, and lets it go 60 s after
the last question unless the pass is embedding and will drop it itself.

`MAX_TOKENS` is 256 of the model's 512. Attention is quadratic in that, and
the library's texts have a median of 141 tokens and a mean of 149: 256 leaves
6% of titles truncated, where 128 would truncate 59% and only save a fifth of
the work.

Both sides of a similarity are prefixed `query: `, which is what e5 was
trained with. The library is compared against itself, so there is no
asymmetric side for `passage: ` to name.

## The larger encoder

[`intfloat/multilingual-e5-base`][base] is pinned beside it, at commit
`d128750597153bb5987e10b1c3493a34e5a4502a`, and chosen only by hand: the
`embed.model` setting, `small` by default, which the diagnostic screen switches.
It is an XLM-RoBERTa, twelve layers of twelve heads 64 wide, 768 dimensions,
over a 250 002-piece vocabulary. Its tokenizer is not the small one's byte for
byte (17 082 660 bytes against 17 082 730, 250 002 pieces against 250 037), so
it is pinned with its own digest; the small tokenizer against these weights
names pieces past the row table and is refused at load.

| file | bytes | MiB |
| --- | --- | --- |
| `model.safetensors` | 1 112 201 288 | 1060.68 |
| `tokenizer.json` | 17 082 660 | 16.29 |
| `config.json` | 694 | 0.00 |

The lengths and digests come from the Git LFS pointers at that commit, which
Hugging Face serves without the body, and the small files were hashed as
downloaded. The weights were not downloaded, so nothing below is measured.
From the header: the word table is 732.43 MiB and stays on the mapping as the
small one's does; the encoder body copied into tensors is 325.97 MiB, four
times the small one's 81 MiB. A forward pass is twice as wide at the same
depth, so about four times the arithmetic: roughly 300 ms a title where the
small one takes 74, twenty minutes for the owner's library. The tokenizer's
388 MiB of trie is the same with either.

Each encoder stamps its vectors with its own version, 2 for small and 3 for
base: switching leaves every stored vector owed a recompute, and a vector of
one is never compared with a vector of the other. The replay measures a switch
before it is made the default: `replay <index.sqlite> --model base --model-dir
<the app's cache directory>` re-embeds the in-memory copy with the base files
found under `model/` there, and refuses with the path it looked in when they
are missing.

## Checking a change to the forward pass

`core/src/embed/model.rs` implements the encoder directly on candle rather
than through `candle-transformers`, so it is worth checking against something
that shares no code with it. The test
`bench_what_the_pinned_encoder_says_about_french` prints the quantized bytes
and the pairwise cosines for a handful of French sentences; an independent
implementation reading the same three files must reproduce them.

[upstream]: https://huggingface.co/intfloat/multilingual-e5-small
[base]: https://huggingface.co/intfloat/multilingual-e5-base
