//! Semantic similarity: one vector per title, from a multilingual sentence
//! encoder kept in the cache directory. No model on disk is the feature
//! switched off, not a failure (spec: Errors and degraded modes).

pub mod download;
pub mod model;
pub mod pass;
pub mod space;

#[cfg(test)]
pub mod fixture;

use crate::index::db::{Db, IndexError};

/// The setting that names the encoder, read by every pass that stores or
/// compares vectors.
pub const ENCODER_SETTING: &str = "embed.model";

/// The encoders a device can run. The small one is the default; the base one
/// is twice as wide and three times as heavy, and is only ever chosen by hand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoder {
    Small,
    Base,
}

impl Encoder {
    /// What every stored vector and anchor is stamped with. A vector of one
    /// encoder is meaningless against the other's, so each has its own
    /// version and a change of encoder leaves every stored vector owed.
    pub fn version(self) -> i64 {
        match self {
            Encoder::Small => 2,
            Encoder::Base => 3,
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Encoder::Small => "small",
            Encoder::Base => "base",
        }
    }

    pub fn from_key(key: &str) -> Option<Encoder> {
        match key {
            "small" => Some(Encoder::Small),
            "base" => Some(Encoder::Base),
            _ => None,
        }
    }

    /// The encoder this index is set to; the small one when nothing was chosen.
    pub fn chosen(db: &Db) -> Result<Encoder, IndexError> {
        Ok(db
            .setting(ENCODER_SETTING)?
            .as_deref()
            .and_then(Encoder::from_key)
            .unwrap_or(Encoder::Small))
    }
}

#[derive(Debug, thiserror::Error)]
pub enum EmbedError {
    #[error("the embedding model is not readable: {0}")]
    Format(String),
    #[error("model cache error: {0}")]
    Io(String),
    #[error("model http status {0}")]
    Status(u16),
    #[error("model transport error: {0}")]
    Transport(String),
    #[error("the model file is not the one that was pinned")]
    Checksum,
    /// A title the queue named and the write that would have banked its vector:
    /// retryable, unlike everything else here, and the one failure that is
    /// about this device's index rather than about the model.
    #[error("index error: {0}")]
    Index(String),
    /// Its own variant rather than an `Io`: a body past the pinned length is
    /// the wrong file at the pinned URL, where the rest of `Io` is a cache
    /// another launch may write.
    #[error("the file at the pinned URL is longer than the artifact")]
    TooLarge,
    /// Playback asked for the network back mid-download. What arrived is kept
    /// and the next call resumes from it.
    #[error("the model download stood aside for playback")]
    Paused,
}
