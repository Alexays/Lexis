//! The sentence encoder: a twelve-layer BERT or XLM-RoBERTa read out of the upstream
//! safetensors and run through candle. A title's vector is the mean of the
//! last hidden states over its tokens, L2 normalized and quantized into bytes.
//!
//! Attention is the point. The model this replaced was a table of one row per
//! token, averaged, so "un flic qui n'est pas corrompu" and "un flic corrompu"
//! embedded identically. Word order and negation reach the vector now.

use super::download::Artifact;
use super::EmbedError;
use candle_core::{Device, Tensor, D};
use candle_nn::ops::softmax_last_dim;
use candle_nn::{LayerNorm, Linear, Module};
use memmap2::Mmap;
use std::collections::HashMap;
use std::ops::Range;
use std::path::Path;
use tokenizers::{Tokenizer, TruncationParams};

/// Where a title's text stops being read. The model reaches 512, and attention
/// costs the square of this: a name, a year, the genres, the sagas, the billing
/// and the opening of a synopsis fit inside 256 with room to spare, and the
/// tail of a long synopsis is plot rather than subject.
pub const MAX_TOKENS: usize = 256;

/// e5 was trained with every text prefixed by its role. Both sides of a
/// similarity are "query" here: the library is compared against itself, so
/// there is no asymmetry for "passage" to name.
const PREFIX: &str = "query: ";

/// BERT's own LayerNorm epsilon, for a config that does not state one.
const LAYER_NORM_EPS: f64 = 1e-12;

pub struct EmbedModel {
    tokenizer: Tokenizer,
    /// The word table is 366 MiB of the 449 MiB artifact and one title reads a
    /// few hundred of its rows, so it stays on the mapping and is gathered row
    /// by row. Copying it into a tensor would be the whole file resident for
    /// the sake of the fraction of a percent a batch touches.
    weights: Mmap,
    words: Range<usize>,
    vocab: usize,
    dims: usize,
    heads: usize,
    head_dim: usize,
    /// The position row of the first token. RoBERTa numbers positions from
    /// past its padding id, so its first rows are never read.
    first_position: usize,
    /// The encoder the files are, which every vector this writes is stamped
    /// with.
    version: i64,
    positions: Vec<f32>,
    token_type: Vec<f32>,
    embed_norm: LayerNorm,
    layers: Vec<Layer>,
}

struct Layer {
    query: Linear,
    key: Linear,
    value: Linear,
    attn_out: Linear,
    attn_norm: LayerNorm,
    intermediate: Linear,
    out: Linear,
    out_norm: LayerNorm,
}

impl EmbedModel {
    /// The model the three files hold. `Ok(None)` when any is missing: no
    /// model is the feature switched off, and every row falls back to what it
    /// did before this plan.
    ///
    /// Nothing here trusts any file: they arrive over the network, and a
    /// header that lies must fail rather than index past the end of itself.
    pub fn load(artifact: &Artifact) -> Result<Option<EmbedModel>, EmbedError> {
        let Some(weights) = map(&artifact.weights)? else {
            return Ok(None);
        };
        let read = |path: &Path| match std::fs::read(path) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(EmbedError::Io(e.to_string())),
        };
        let (Some(tokenizer), Some(config)) = (read(&artifact.tokenizer)?, read(&artifact.config)?)
        else {
            return Ok(None);
        };
        let config: serde_json::Value = serde_json::from_slice(&config)
            .map_err(|e| EmbedError::Format(format!("the config is not readable: {e}")))?;
        let heads = config
            .get("num_attention_heads")
            .and_then(|h| h.as_u64())
            .ok_or_else(|| EmbedError::Format("the config names no head count".into()))?
            as usize;
        let eps = config
            .get("layer_norm_eps")
            .and_then(|e| e.as_f64())
            .unwrap_or(LAYER_NORM_EPS);
        let first_position = match config.get("model_type").and_then(|t| t.as_str()) {
            Some("xlm-roberta") => (config
                .get("pad_token_id")
                .and_then(|p| p.as_u64())
                .unwrap_or(1) as usize)
                .saturating_add(1),
            _ => 0,
        };
        let mut tokenizer = Tokenizer::from_bytes(&tokenizer)
            .map_err(|e| EmbedError::Format(format!("the tokenizer is not readable: {e}")))?;
        // the tokenizer's own truncation keeps the closing special token a
        // slice of its output would cut off
        tokenizer
            .with_truncation(Some(TruncationParams {
                max_length: MAX_TOKENS,
                ..TruncationParams::default()
            }))
            .map_err(|e| EmbedError::Format(format!("the tokenizer is not readable: {e}")))?;
        let header = header(&weights)?;
        let device = Device::Cpu;

        let (words, word_shape) = locate(&header, "embeddings.word_embeddings.weight")?;
        if heads == 0
            || word_shape.len() != 2
            || word_shape[1] == 0
            || !word_shape[1].is_multiple_of(heads)
        {
            return Err(EmbedError::Format(format!(
                "word embeddings are {word_shape:?}, not [vocab, a multiple of {heads} heads]"
            )));
        }
        let (vocab, dims) = (word_shape[0], word_shape[1]);
        // the ids the tokenizer hands out index those rows directly, so this is
        // what makes every gather below safe
        if tokenizer.get_vocab_size(true) > vocab {
            return Err(EmbedError::Format(format!(
                "{} pieces against {vocab} rows",
                tokenizer.get_vocab_size(true)
            )));
        }

        let positions = floats(&weights, &header, "embeddings.position_embeddings.weight")?;
        // divided rather than multiplied: the offset is the config's word, and
        // a lying one must not overflow into a check that passes
        if positions.len() / dims < first_position.saturating_add(MAX_TOKENS) {
            return Err(EmbedError::Format(format!(
                "{} position rows, fewer than the {MAX_TOKENS} a text may reach past {first_position}",
                positions.len() / dims.max(1)
            )));
        }
        // one segment: a title is a single text, so every token is type 0 and
        // the second row of that table is never read
        let mut token_type = floats(&weights, &header, "embeddings.token_type_embeddings.weight")?;
        if token_type.len() < dims {
            return Err(EmbedError::Format("the token type table is short".into()));
        }
        token_type.truncate(dims);

        let embed_norm = norm(&weights, &header, "embeddings.LayerNorm", eps, &device)?;
        let mut layers = Vec::new();
        // as many as the file describes: the reader is not owed the pinned
        // model's depth, and a file that stops early stops the stack early
        while header.contains_key(&format!(
            "encoder.layer.{}.attention.self.query.weight",
            layers.len()
        )) {
            let p = format!("encoder.layer.{}", layers.len());
            layers.push(Layer {
                query: linear(
                    &weights,
                    &header,
                    &format!("{p}.attention.self.query"),
                    &device,
                )?,
                key: linear(
                    &weights,
                    &header,
                    &format!("{p}.attention.self.key"),
                    &device,
                )?,
                value: linear(
                    &weights,
                    &header,
                    &format!("{p}.attention.self.value"),
                    &device,
                )?,
                attn_out: linear(
                    &weights,
                    &header,
                    &format!("{p}.attention.output.dense"),
                    &device,
                )?,
                attn_norm: norm(
                    &weights,
                    &header,
                    &format!("{p}.attention.output.LayerNorm"),
                    eps,
                    &device,
                )?,
                intermediate: linear(
                    &weights,
                    &header,
                    &format!("{p}.intermediate.dense"),
                    &device,
                )?,
                out: linear(&weights, &header, &format!("{p}.output.dense"), &device)?,
                out_norm: norm(
                    &weights,
                    &header,
                    &format!("{p}.output.LayerNorm"),
                    eps,
                    &device,
                )?,
            });
        }
        if layers.is_empty() {
            return Err(EmbedError::Format(
                "the file describes no encoder layer".into(),
            ));
        }

        Ok(Some(EmbedModel {
            tokenizer,
            weights,
            words,
            vocab,
            dims,
            heads,
            head_dim: dims / heads,
            first_position,
            version: artifact.encoder.version(),
            positions,
            token_type,
            embed_norm,
            layers,
        }))
    }

    pub fn dims(&self) -> usize {
        self.dims
    }

    pub fn layers(&self) -> usize {
        self.layers.len()
    }

    pub fn version(&self) -> i64 {
        self.version
    }

    /// This text's pooled hidden state, unit length, quantized back into bytes
    /// so a dot product of two vectors is their cosine. None when the text says
    /// nothing: a title with no name and no synopsis has no subject, and the
    /// vector of an empty string is the same constant for every one of them.
    pub fn embed(&self, text: &str) -> Result<Option<Vec<i8>>, EmbedError> {
        if text.trim().is_empty() {
            return Ok(None);
        }
        let encoded = self
            .tokenizer
            .encode_fast(format!("{PREFIX}{text}"), true)
            .map_err(|e| EmbedError::Format(e.to_string()))?;
        let ids = encoded.get_ids();
        // a no-op behind the truncation set at load, and what bounds the
        // position rows read below whatever the tokenizer does
        let ids = &ids[..ids.len().min(MAX_TOKENS)];
        if ids.is_empty() {
            return Ok(None);
        }

        // the word row, the position row and the one segment row, summed into
        // the [tokens, dims] the first LayerNorm reads
        let mut buf = vec![0f32; ids.len() * self.dims];
        for (i, id) in ids.iter().enumerate() {
            let id = *id as usize;
            // the vocabulary check at load makes this unreachable; a tokenizer
            // that names a piece past the table would index another tensor
            if id >= self.vocab {
                return Err(EmbedError::Format(format!(
                    "the tokenizer named piece {id}, past the {} rows",
                    self.vocab
                )));
            }
            let start = self.words.start + id * self.dims * 4;
            let row = &self.weights[start..start + self.dims * 4];
            let slot = &mut buf[i * self.dims..(i + 1) * self.dims];
            let position = &self.positions[(self.first_position + i) * self.dims..];
            for (d, out) in slot.iter_mut().enumerate() {
                let word = f32::from_le_bytes(row[d * 4..d * 4 + 4].try_into().unwrap());
                *out = word + position[d] + self.token_type[d];
            }
        }

        // summed rather than averaged: the division by the token count is left
        // out, since normalizing removes it anyway
        let pooled = self
            .forward(buf, ids.len())
            .and_then(|h| h.sum(0)?.to_vec1::<f32>())
            .map_err(candle)?;
        let norm = pooled
            .iter()
            .map(|v| f64::from(*v) * f64::from(*v))
            .sum::<f64>()
            .sqrt();
        // every hidden state would have to cancel every other one exactly
        if norm == 0.0 {
            return Ok(None);
        }
        Ok(Some(
            pooled
                .iter()
                .map(|v| (f64::from(*v) * 127.0 / norm).round().clamp(-127.0, 127.0) as i8)
                .collect(),
        ))
    }

    /// The encoder stack over one text. A batch of one, so there is no padding
    /// and no attention mask: every token attends to every other one, and the
    /// pooling at the end is over exactly the tokens the text has.
    fn forward(&self, embedded: Vec<f32>, tokens: usize) -> candle_core::Result<Tensor> {
        let scale = 1.0 / (self.head_dim as f64).sqrt();
        let shape = (tokens, self.heads, self.head_dim);
        let mut hidden = Tensor::from_vec(embedded, (tokens, self.dims), &Device::Cpu)?;
        hidden = self.embed_norm.forward(&hidden)?;

        for layer in &self.layers {
            let heads = |t: Tensor| t.reshape(shape)?.transpose(0, 1)?.contiguous();
            let query = heads(layer.query.forward(&hidden)?)?;
            let key = heads(layer.key.forward(&hidden)?)?;
            let value = heads(layer.value.forward(&hidden)?)?;

            let scores = query
                .matmul(&key.transpose(D::Minus2, D::Minus1)?)?
                .affine(scale, 0.0)?;
            let context = softmax_last_dim(&scores)?
                .matmul(&value)?
                .transpose(0, 1)?
                .contiguous()?
                .reshape((tokens, self.dims))?;

            let attended = hidden.add(&layer.attn_out.forward(&context)?)?;
            hidden = layer.attn_norm.forward(&attended)?;
            let inner = layer.intermediate.forward(&hidden)?;
            let shape = inner.dims2()?;
            let mut inner = inner.flatten_all()?.to_vec1::<f32>()?;
            for x in inner.iter_mut() {
                *x = gelu(*x);
            }
            let inner = Tensor::from_vec(inner, shape, &Device::Cpu)?;
            let projected = hidden.add(&layer.out.forward(&inner)?)?;
            hidden = layer.out_norm.forward(&projected)?;
        }
        Ok(hidden)
    }
}

/// The exact (erf) GELU the config names, with erf by Abramowitz and Stegun
/// 7.1.26 (error under 1.5e-7): candle's own calls a scalar libm erf per
/// element, which is most of a forward pass.
fn gelu(x: f32) -> f32 {
    let z = x * std::f32::consts::FRAC_1_SQRT_2;
    let a = z.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * a);
    let poly = ((((1.061_405_4 * t - 1.453_152) * t + 1.421_413_8) * t - 0.284_496_74) * t
        + 0.254_829_6)
        * t;
    let erf = (1.0 - poly * (-a * a).exp()).copysign(z);
    0.5 * x * (1.0 + erf)
}

/// The file at `path`, mapped. `Ok(None)` when there is nothing there.
fn map(path: &Path) -> Result<Option<Mmap>, EmbedError> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(EmbedError::Io(e.to_string())),
    };
    // SAFETY: the artifact is written into a cache directory by this process
    // and renamed into place, and nothing rewrites it afterwards. A file
    // truncated under the mapping would fault, which is the exposure every
    // mapped read in the process already carries.
    let map = unsafe { Mmap::map(&file) }.map_err(|e| EmbedError::Io(e.to_string()))?;
    Ok(Some(map))
}

type Header = HashMap<String, (Vec<usize>, Range<usize>)>;

/// Every F32 tensor's shape and byte range, checked against the file that
/// carries them. Tensors of any other width are skipped rather than refused:
/// the upstream artifact carries an I64 `position_ids` nothing here reads.
fn header(bytes: &[u8]) -> Result<Header, EmbedError> {
    if bytes.len() < 8 {
        return Err(EmbedError::Format("the file is too short".into()));
    }
    let header_len = u64::from_le_bytes(bytes[..8].try_into().unwrap()) as usize;
    let data_start = header_len
        .checked_add(8)
        .filter(|end| *end <= bytes.len())
        .ok_or_else(|| EmbedError::Format("the header runs past the file".into()))?;
    let parsed: serde_json::Value = serde_json::from_slice(&bytes[8..data_start])
        .map_err(|e| EmbedError::Format(e.to_string()))?;
    let parsed = parsed
        .as_object()
        .ok_or_else(|| EmbedError::Format("the header is not an object".into()))?;

    let mut out = Header::with_capacity(parsed.len());
    for (name, entry) in parsed {
        if name == "__metadata__" || entry.get("dtype").and_then(|d| d.as_str()) != Some("F32") {
            continue;
        }
        // one entry that is not a count fails the whole shape: dropping it
        // would rebuild a rank the header never stated, and the rank guards
        // would then pass on a tensor nobody described
        let shape: Vec<usize> = entry
            .get("shape")
            .and_then(|s| s.as_array())
            .and_then(|s| s.iter().map(|v| Some(v.as_u64()? as usize)).collect())
            .ok_or_else(|| EmbedError::Format(format!("{name} has no shape")))?;
        let offsets = entry
            .get("data_offsets")
            .and_then(|o| o.as_array())
            .ok_or_else(|| EmbedError::Format(format!("{name} has no offsets")))?;
        let (Some(from), Some(to)) = (
            offsets.first().and_then(|v| v.as_u64()),
            offsets.get(1).and_then(|v| v.as_u64()),
        ) else {
            return Err(EmbedError::Format(format!("{name} has no offsets")));
        };
        let from = data_start
            .checked_add(from as usize)
            .ok_or_else(|| EmbedError::Format(format!("{name} starts past the file")))?;
        let to = data_start
            .checked_add(to as usize)
            .ok_or_else(|| EmbedError::Format(format!("{name} ends past the file")))?;
        if from > to || to > bytes.len() {
            return Err(EmbedError::Format(format!("{name} runs past the file")));
        }
        // unchecked, a shape whose product wraps to the real byte length is
        // believed, and every dimension read out of it is then unbounded
        let count = shape
            .iter()
            .try_fold(4usize, |a, d| a.checked_mul(*d))
            .ok_or_else(|| EmbedError::Format(format!("{name} shape overflows")))?;
        if count != to - from {
            return Err(EmbedError::Format(format!("{name} is not its own shape")));
        }
        out.insert(name.clone(), (shape, from..to));
    }
    Ok(out)
}

fn locate(header: &Header, name: &str) -> Result<(Range<usize>, Vec<usize>), EmbedError> {
    let (shape, range) = header
        .get(name)
        .ok_or_else(|| EmbedError::Format(format!("no {name} tensor")))?;
    Ok((range.clone(), shape.clone()))
}

fn floats(bytes: &[u8], header: &Header, name: &str) -> Result<Vec<f32>, EmbedError> {
    let (range, _) = locate(header, name)?;
    Ok(bytes[range]
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect())
}

fn tensor(
    bytes: &[u8],
    header: &Header,
    name: &str,
    device: &Device,
) -> Result<Tensor, EmbedError> {
    let (range, shape) = locate(header, name)?;
    let values: Vec<f32> = bytes[range]
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    Tensor::from_vec(values, shape, device).map_err(candle)
}

/// An `[out, in]` weight and its bias. candle multiplies by the transpose, so
/// the tensor goes in exactly as the upstream file stores it.
fn linear(
    bytes: &[u8],
    header: &Header,
    prefix: &str,
    device: &Device,
) -> Result<Linear, EmbedError> {
    let weight = tensor(bytes, header, &format!("{prefix}.weight"), device)?;
    let bias = tensor(bytes, header, &format!("{prefix}.bias"), device)?;
    Ok(Linear::new(weight, Some(bias)))
}

fn norm(
    bytes: &[u8],
    header: &Header,
    prefix: &str,
    eps: f64,
    device: &Device,
) -> Result<LayerNorm, EmbedError> {
    let weight = tensor(bytes, header, &format!("{prefix}.weight"), device)?;
    let bias = tensor(bytes, header, &format!("{prefix}.bias"), device)?;
    Ok(LayerNorm::new(weight, bias, eps))
}

fn candle(e: candle_core::Error) -> EmbedError {
    EmbedError::Format(e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::embed::fixture;

    fn model(dir: &Path) -> EmbedModel {
        EmbedModel::load(&fixture::write_model(dir))
            .unwrap()
            .unwrap()
    }

    fn dot(a: &[i8], b: &[i8]) -> i32 {
        a.iter()
            .zip(b)
            .map(|(x, y)| i32::from(*x) * i32::from(*y))
            .sum()
    }

    #[test]
    fn the_gelu_matches_the_exact_erf_one() {
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let values: Vec<f32> = (0..100_000)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                // the hidden states of the intermediate layer, and well past them
                (seed >> 40) as f32 / (1u64 << 24) as f32 * 24.0 - 12.0
            })
            .collect();
        let exact = Tensor::from_vec(values.clone(), values.len(), &Device::Cpu)
            .unwrap()
            .gelu_erf()
            .unwrap()
            .to_vec1::<f32>()
            .unwrap();
        let worst = values
            .iter()
            .zip(&exact)
            .map(|(x, e)| (gelu(*x) - e).abs())
            .fold(0.0f32, f32::max);
        assert!(worst < 2e-6, "{worst}");
    }

    #[test]
    fn a_text_past_the_token_cap_still_ends_on_its_closing_token() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        // the fixture with a closing "." appended to every text, the way the
        // upstream tokenizer appends its end-of-sequence piece
        let closing = r#"{"type":"TemplateProcessing",
"single":[{"Sequence":{"id":"A","type_id":0}},{"SpecialToken":{"id":".","type_id":0}}],
"pair":[{"Sequence":{"id":"A","type_id":0}},{"Sequence":{"id":"B","type_id":0}}],
"special_tokens":{".":{"id":".","ids":[14],"tokens":["."]}}}"#;
        let tokenizer = String::from_utf8(fixture::tokenizer_bytes())
            .unwrap()
            .replace(
                r#""post_processor":null"#,
                &format!(r#""post_processor":{closing}"#),
            );
        std::fs::write(&artifact.tokenizer, tokenizer).unwrap();
        let model = EmbedModel::load(&artifact).unwrap().unwrap();

        let long = "science fiction ".repeat(MAX_TOKENS);
        let encoded = model
            .tokenizer
            .encode_fast(format!("{PREFIX}{long}"), true)
            .unwrap();
        let ids = encoded.get_ids();
        assert_eq!(ids.len(), MAX_TOKENS);
        assert_eq!(ids.last(), Some(&14));
        assert!(model.embed(&long).unwrap().is_some());
    }

    #[test]
    fn a_hand_written_encoder_loads_and_embeds() {
        let tmp = tempfile::tempdir().unwrap();
        let model = model(tmp.path());
        assert_eq!(model.dims(), fixture::DIMS);
        assert_eq!(model.layers(), fixture::LAYERS);

        let vector = model.embed("science fiction").unwrap().unwrap();
        assert_eq!(vector.len(), fixture::DIMS);
        // unit length, so a dot product of two of them is their cosine
        assert!((dot(&vector, &vector) - 127 * 127).abs() < 400);
    }

    #[test]
    fn embedding_the_same_text_twice_gives_the_same_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let model = model(tmp.path());
        let text = "Dune. Science-Fiction. Un desert, une epice.";
        assert_eq!(model.embed(text).unwrap(), model.embed(text).unwrap());
    }

    #[test]
    fn word_order_reaches_the_vector() {
        let tmp = tempfile::tempdir().unwrap();
        let model = model(tmp.path());
        // the whole point of replacing the averaged table: the same words in
        // another order were the same vector to it, and are not to this
        let forward = model.embed("science fiction alien").unwrap().unwrap();
        let backward = model.embed("alien fiction science").unwrap().unwrap();
        assert_ne!(forward, backward);
    }

    #[test]
    fn a_text_that_says_nothing_has_no_vector_at_all() {
        let tmp = tempfile::tempdir().unwrap();
        let model = model(tmp.path());
        // a zero vector would be equally similar to everything, which is worse
        // than no row at all
        assert_eq!(model.embed("").unwrap(), None);
        assert_eq!(model.embed("   \n ").unwrap(), None);
    }

    #[test]
    fn a_config_of_heads_sixty_four_wide_loads_and_attends_otherwise() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        let narrow = model(tmp.path())
            .embed("science fiction alien")
            .unwrap()
            .unwrap();

        // one head across the whole width: the head count is the config's,
        // and the same weights split another way attend another way
        std::fs::write(&artifact.config, fixture::config_with(1, "bert")).unwrap();
        let wide = EmbedModel::load(&artifact).unwrap().unwrap();
        let vector = wide.embed("science fiction alien").unwrap().unwrap();
        assert_eq!(vector.len(), fixture::DIMS);
        assert_ne!(vector, narrow);
    }

    #[test]
    fn a_head_count_that_does_not_divide_the_width_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        for heads in [0, 12] {
            std::fs::write(&artifact.config, fixture::config_with(heads, "bert")).unwrap();
            assert!(
                matches!(EmbedModel::load(&artifact), Err(EmbedError::Format(_))),
                "{heads} heads were accepted"
            );
        }
        std::fs::write(&artifact.config, b"{}").unwrap();
        assert!(matches!(
            EmbedModel::load(&artifact),
            Err(EmbedError::Format(_))
        ));
    }

    #[test]
    fn a_roberta_config_reads_its_positions_past_the_padding_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        let bert = model(tmp.path()).embed("science fiction").unwrap().unwrap();
        std::fs::write(&artifact.config, fixture::config_with(2, "xlm-roberta")).unwrap();
        let roberta = EmbedModel::load(&artifact).unwrap().unwrap();
        assert_ne!(roberta.embed("science fiction").unwrap().unwrap(), bert);

        // a padding id past the position table is refused, not overflowed
        std::fs::write(
            &artifact.config,
            br#"{"model_type":"xlm-roberta","num_attention_heads":2,"pad_token_id":18446744073709551615}"#,
        )
        .unwrap();
        assert!(matches!(
            EmbedModel::load(&artifact),
            Err(EmbedError::Format(_))
        ));
    }

    #[test]
    fn a_model_is_stamped_with_the_encoder_its_files_are() {
        let tmp = tempfile::tempdir().unwrap();
        let mut artifact = fixture::write_model(tmp.path());
        assert_eq!(EmbedModel::load(&artifact).unwrap().unwrap().version(), 2);
        artifact.encoder = crate::embed::Encoder::Base;
        assert_eq!(EmbedModel::load(&artifact).unwrap().unwrap().version(), 3);
    }

    #[test]
    fn nothing_where_the_model_goes_is_no_model_and_no_error() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        assert!(EmbedModel::load(&artifact).unwrap().is_some());

        // any file missing on its own is the feature off, not a failure
        std::fs::remove_file(&artifact.config).unwrap();
        assert!(EmbedModel::load(&artifact).unwrap().is_none());
        std::fs::write(&artifact.config, fixture::config_bytes()).unwrap();
        std::fs::remove_file(&artifact.tokenizer).unwrap();
        assert!(EmbedModel::load(&artifact).unwrap().is_none());
        std::fs::remove_file(&artifact.weights).unwrap();
        assert!(EmbedModel::load(&artifact).unwrap().is_none());
    }

    /// The fixture with one substring of its JSON header rewritten, re-padded
    /// and re-prefixed, so only the header's claim changes and the tensor bytes
    /// behind it stay exactly what they were.
    fn claiming(from: &str, to: &str) -> Vec<u8> {
        let bytes = fixture::weights_bytes();
        let header_len = u64::from_le_bytes(bytes[..8].try_into().unwrap()) as usize;
        let header = std::str::from_utf8(&bytes[8..8 + header_len]).unwrap();
        assert!(header.contains(from), "{from} is not in the header");
        let mut header = header.replace(from, to).into_bytes();
        while !(8 + header.len()).is_multiple_of(8) {
            header.push(b' ');
        }
        let mut out = (header.len() as u64).to_le_bytes().to_vec();
        out.extend_from_slice(&header);
        out.extend_from_slice(&bytes[8 + header_len..]);
        out
    }

    /// Loads `weights` beside a real tokenizer, so only the weights decide.
    fn load_weights(dir: &Path, weights: &[u8]) -> Result<Option<EmbedModel>, EmbedError> {
        let artifact = fixture::write_model(dir);
        std::fs::write(&artifact.weights, weights).unwrap();
        EmbedModel::load(&artifact)
    }

    #[test]
    fn a_file_that_is_not_the_artifact_is_refused_rather_than_read() {
        let tmp = tempfile::tempdir().unwrap();
        for bytes in [b"not a model".to_vec(), Vec::new()] {
            assert!(matches!(
                load_weights(tmp.path(), &bytes),
                Err(EmbedError::Format(_))
            ));
        }
        // a header that claims more bytes than the file holds
        let mut truncated = fixture::weights_bytes();
        truncated.truncate(truncated.len() - 4);
        assert!(matches!(
            load_weights(tmp.path(), &truncated),
            Err(EmbedError::Format(_))
        ));
        // a header naming a length past the end of the file
        let mut lying = fixture::weights_bytes();
        lying[0..8].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(matches!(
            load_weights(tmp.path(), &lying),
            Err(EmbedError::Format(_))
        ));
    }

    #[test]
    fn a_shape_whose_product_wraps_is_refused_rather_than_believed() {
        let tmp = tempfile::tempdir().unwrap();
        // 4 * 16 * (2^58 + 4) wraps to the 4096 bytes the rows really are:
        // unchecked, the file loads and the first embed asks the allocator for
        // four exabytes
        let vocab = fixture::PIECES.len();
        let lying = claiming(
            &format!(r#""shape":[{vocab},{}]"#, fixture::DIMS),
            &format!(r#""shape":[{vocab},288230376151711748]"#),
        );
        assert!(matches!(
            load_weights(tmp.path(), &lying),
            Err(EmbedError::Format(_))
        ));
    }

    #[test]
    fn a_shape_that_is_not_a_list_of_counts_is_refused_rather_than_repaired() {
        let tmp = tempfile::tempdir().unwrap();
        // dropping the entry that is not a count would rebuild a rank-2 shape
        // the header never stated, and the rank guard would never see it
        let vocab = fixture::PIECES.len();
        let real = format!(r#""shape":[{vocab},{}]"#, fixture::DIMS);
        for shape in [
            format!(r#""shape":[{vocab},{},"x"]"#, fixture::DIMS),
            format!(r#""shape":[{vocab},-1,{}]"#, fixture::DIMS),
        ] {
            let lying = claiming(&real, &shape);
            assert!(
                matches!(load_weights(tmp.path(), &lying), Err(EmbedError::Format(_))),
                "{shape} was accepted"
            );
        }
    }

    /// What the pinned encoder says about sentences a human can judge. Point
    /// `LEXIS_BENCH_WEIGHTS`, `LEXIS_BENCH_TOKENIZER` and `LEXIS_BENCH_CONFIG`
    /// at the real files and
    /// run with `--ignored --nocapture`. Prints rather than asserts: this is
    /// here to be read against a reference implementation, not to gate a build.
    #[test]
    #[ignore]
    fn bench_what_the_pinned_encoder_says_about_french() {
        use crate::embed::download::Artifact;
        use crate::embed::Encoder;
        use std::path::PathBuf;

        let artifact = Artifact {
            encoder: Encoder::Small,
            weights: PathBuf::from(std::env::var("LEXIS_BENCH_WEIGHTS").unwrap()),
            tokenizer: PathBuf::from(std::env::var("LEXIS_BENCH_TOKENIZER").unwrap()),
            config: PathBuf::from(std::env::var("LEXIS_BENCH_CONFIG").unwrap()),
        };
        let model = EmbedModel::load(&artifact).unwrap().unwrap();
        let texts = [
            "un flic qui n'est pas corrompu",
            "un flic corrompu",
            "un policier honnete",
            "une comedie romantique legere",
            "un film d'horreur terrifiant",
        ];
        let vectors: Vec<Vec<i8>> = texts
            .iter()
            .map(|t| model.embed(t).unwrap().unwrap())
            .collect();
        // the first few bytes of the first vector, for a reference to match
        eprintln!("dims={} first16={:?}", model.dims(), &vectors[0][..16]);
        for (i, a) in texts.iter().enumerate() {
            for (j, b) in texts.iter().enumerate().skip(i + 1) {
                let cos = f64::from(dot(&vectors[i], &vectors[j])) / f64::from(127 * 127);
                eprintln!("  {cos:+.4}  {a}  ||  {b}");
            }
        }
    }

    #[test]
    fn a_tokenizer_naming_more_pieces_than_the_table_has_rows_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let artifact = fixture::write_model(tmp.path());
        // the weights of one model against the tokenizer of another: every
        // piece past the row table would gather somebody else's tensor
        let many: Vec<String> = (0..fixture::PIECES.len() + 1)
            .map(|i| {
                if i == 0 {
                    "[UNK]".to_string()
                } else {
                    format!("p{i}")
                }
            })
            .collect();
        let many: Vec<&str> = many.iter().map(|s| s.as_str()).collect();
        std::fs::write(&artifact.tokenizer, fixture::tokenizer_with(&many)).unwrap();
        assert!(matches!(
            EmbedModel::load(&artifact),
            Err(EmbedError::Format(_))
        ));
    }
}
