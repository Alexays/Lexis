//! An encoder small enough to run in a test: two heads of 32, two layers and a
//! sixteen-piece vocabulary, laid out exactly as the upstream artifact is.
//! Nothing binary is committed and nothing is downloaded.
//!
//! The weights are not random. A generator that changed run to run would make
//! every assertion about what the vectors say a coin toss, so they come from a
//! fixed sequence: deterministic, spread over the range a trained tensor
//! occupies, and different for every row and column.

use super::download::{Artifact, ModelSource};
use std::path::Path;

/// Two heads of the small model's width, so the fixture exercises the same
/// multi-head reshaping the pinned model does.
pub const DIMS: usize = 64;
const HEADS: usize = 2;
pub const LAYERS: usize = 2;
const INNER: usize = 128;
/// Enough that `MAX_TOKENS` of text has a position row to read.
const POSITIONS: usize = 512;

/// Sixteen pieces, in id order. `[UNK]` is id zero.
pub const PIECES: [&str; 16] = [
    "[UNK]", "science", "fiction", "dune", "desert", "alien", "horreur", "epice", "space", "cafe",
    "elegie", "naivete", "query", ":", ".", ",",
];

/// One value of the fixed sequence. Odd multipliers over a power of two never
/// repeat inside a tensor, and the fold keeps the result in the range a
/// trained weight lives in rather than growing with the index.
fn weight(seed: usize, i: usize) -> f32 {
    let x = (seed
        .wrapping_mul(2_654_435_761)
        .wrapping_add(i.wrapping_mul(40_503)))
        & 0xffff;
    (x as f32 / 32_768.0) - 1.0
}

fn tensor(seed: usize, count: usize) -> Vec<u8> {
    (0..count)
        .flat_map(|i| weight(seed, i).to_le_bytes())
        .collect()
}

/// A LayerNorm's gain is around one and its bias around zero: a gain drawn
/// from the same range as a weight would put half the layers at a negative
/// scale, which no trained model does.
fn gain(seed: usize, count: usize) -> Vec<u8> {
    (0..count)
        .flat_map(|i| (1.0 + weight(seed, i) * 0.1).to_le_bytes())
        .collect()
}

/// The artifact, exactly as the upstream one is laid out: an 8-byte
/// little-endian header length, a JSON header padded to an 8-byte boundary,
/// then the tensors end to end in the order the header gives their offsets.
pub fn weights_bytes() -> Vec<u8> {
    let mut named: Vec<(String, Vec<usize>, Vec<u8>)> = vec![
        (
            "embeddings.word_embeddings.weight".into(),
            vec![PIECES.len(), DIMS],
            tensor(1, PIECES.len() * DIMS),
        ),
        (
            "embeddings.position_embeddings.weight".into(),
            vec![POSITIONS, DIMS],
            tensor(2, POSITIONS * DIMS),
        ),
        (
            "embeddings.token_type_embeddings.weight".into(),
            vec![2, DIMS],
            tensor(3, 2 * DIMS),
        ),
        (
            "embeddings.LayerNorm.weight".into(),
            vec![DIMS],
            gain(4, DIMS),
        ),
        (
            "embeddings.LayerNorm.bias".into(),
            vec![DIMS],
            tensor(5, DIMS),
        ),
    ];
    for layer in 0..LAYERS {
        let p = format!("encoder.layer.{layer}");
        let seed = 100 + layer * 20;
        for (i, part) in [
            "attention.self.query",
            "attention.self.key",
            "attention.self.value",
            "attention.output.dense",
        ]
        .into_iter()
        .enumerate()
        {
            named.push((
                format!("{p}.{part}.weight"),
                vec![DIMS, DIMS],
                tensor(seed + i, DIMS * DIMS),
            ));
            named.push((
                format!("{p}.{part}.bias"),
                vec![DIMS],
                tensor(seed + i + 8, DIMS),
            ));
        }
        named.push((
            format!("{p}.attention.output.LayerNorm.weight"),
            vec![DIMS],
            gain(seed + 12, DIMS),
        ));
        named.push((
            format!("{p}.attention.output.LayerNorm.bias"),
            vec![DIMS],
            tensor(seed + 13, DIMS),
        ));
        named.push((
            format!("{p}.intermediate.dense.weight"),
            vec![INNER, DIMS],
            tensor(seed + 14, INNER * DIMS),
        ));
        named.push((
            format!("{p}.intermediate.dense.bias"),
            vec![INNER],
            tensor(seed + 15, INNER),
        ));
        named.push((
            format!("{p}.output.dense.weight"),
            vec![DIMS, INNER],
            tensor(seed + 16, DIMS * INNER),
        ));
        named.push((
            format!("{p}.output.dense.bias"),
            vec![DIMS],
            tensor(seed + 17, DIMS),
        ));
        named.push((
            format!("{p}.output.LayerNorm.weight"),
            vec![DIMS],
            gain(seed + 18, DIMS),
        ));
        named.push((
            format!("{p}.output.LayerNorm.bias"),
            vec![DIMS],
            tensor(seed + 19, DIMS),
        ));
    }

    let mut entries = Vec::with_capacity(named.len());
    let mut body = Vec::new();
    for (name, shape, bytes) in &named {
        let shape = shape
            .iter()
            .map(|d| d.to_string())
            .collect::<Vec<_>>()
            .join(",");
        entries.push(format!(
            r#""{name}":{{"dtype":"F32","shape":[{shape}],"data_offsets":[{},{}]}}"#,
            body.len(),
            body.len() + bytes.len()
        ));
        body.extend_from_slice(bytes);
    }
    let mut header = format!("{{{}}}", entries.join(",")).into_bytes();
    while !(8 + header.len()).is_multiple_of(8) {
        header.push(b' ');
    }
    let mut out = Vec::with_capacity(8 + header.len() + body.len());
    out.extend_from_slice(&(header.len() as u64).to_le_bytes());
    out.extend_from_slice(&header);
    out.extend_from_slice(&body);
    out
}

/// A tokenizer the `tokenizers` crate reads: one id per whitespace-separated
/// word, lower cased, with everything it does not know as `[UNK]`.
pub fn tokenizer_with(pieces: &[&str]) -> Vec<u8> {
    let vocab = pieces
        .iter()
        .enumerate()
        .map(|(id, piece)| format!(r#""{piece}":{id}"#))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],
"normalizer":{{"type":"Lowercase"}},"pre_tokenizer":{{"type":"Whitespace"}},
"post_processor":null,"decoder":null,
"model":{{"type":"WordLevel","vocab":{{{vocab}}},"unk_token":"[UNK]"}}}}"#
    )
    .into_bytes()
}

pub fn tokenizer_bytes() -> Vec<u8> {
    tokenizer_with(&PIECES)
}

/// A `config.json` with the three fields the loader reads, as the upstream
/// ones state them.
pub fn config_with(heads: usize, model_type: &str) -> Vec<u8> {
    format!(
        r#"{{"model_type":"{model_type}","num_attention_heads":{heads},"layer_norm_eps":1e-12,"pad_token_id":1}}"#
    )
    .into_bytes()
}

pub fn config_bytes() -> Vec<u8> {
    config_with(HEADS, "bert")
}

/// The fixture in a cache directory, at the paths the *shipped* pins are looked
/// for: a caller that plants it there is the model being on the device already,
/// and `model_files` returns both from the cache without a request. Nothing in
/// the tests may reach Hugging Face, and this is what makes that structural
/// rather than a rule to remember.
pub fn write_model(dir: &Path) -> Artifact {
    let artifact = ModelSource::default().artifact(dir);
    std::fs::create_dir_all(artifact.weights.parent().unwrap()).unwrap();
    std::fs::write(&artifact.weights, weights_bytes()).unwrap();
    std::fs::write(&artifact.tokenizer, tokenizer_bytes()).unwrap();
    std::fs::write(&artifact.config, config_bytes()).unwrap();
    artifact
}
