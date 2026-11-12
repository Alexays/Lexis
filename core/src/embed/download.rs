//! The encoder's two files, fetched the way artwork is: into the cache
//! directory, once, and never committed or bundled. What comes back is checked
//! against a pinned length and digest before anything reads it as a model.

use super::{EmbedError, Encoder};
use parking_lot::Mutex;
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// One pinned file: what it is called in the cache, where it lives, how long
/// it is, and the digest that says it is the right one. The digest is what
/// decides; the length only bounds the read, so a URL now answering with
/// something else is refused as it arrives rather than after a body of any
/// size is on disk.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pin {
    pub name: &'static str,
    pub url: String,
    pub sha256: String,
    pub len: u64,
}

/// Where the encoder comes from. Built from the constants below, except in the
/// tests, which must reach a server of their own rather than Hugging Face.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelSource {
    /// Which encoder these files are, and so what the vectors they write are
    /// stamped with.
    pub encoder: Encoder,
    pub weights: Pin,
    pub tokenizer: Pin,
    /// The model's `config.json`: the head count, the LayerNorm epsilon and
    /// where the position rows start, none of which the weights say.
    pub config: Pin,
}

pub const WEIGHTS_FILE: &str = "multilingual-e5-small.safetensors";
pub const TOKENIZER_FILE: &str = "multilingual-e5-small.tokenizer.json";
pub const CONFIG_FILE: &str = "multilingual-e5-small.config.json";

/// `intfloat/multilingual-e5-small`, Apache-2.0, unmodified, served from
/// Hugging Face's own CDN at a pinned commit. Nothing is repacked and nothing
/// has to be published: these URLs are public and answer an unauthenticated
/// GET, which is the whole reason they are these ones.
pub const WEIGHTS_URL: &str = "https://huggingface.co/intfloat/multilingual-e5-small/resolve/614241f622f53c4eeff9890bdc4f31cfecc418b3/model.safetensors";
pub const WEIGHTS_SHA256: &str = "1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477";
pub const WEIGHTS_LEN: u64 = 470_641_600;

/// The tokenizer, from the same commit as the weights. A tokenizer from one
/// model against the weights of another names pieces the row table does not
/// have, which is why the two are pinned together and installed together.
pub const TOKENIZER_URL: &str = "https://huggingface.co/intfloat/multilingual-e5-small/resolve/614241f622f53c4eeff9890bdc4f31cfecc418b3/tokenizer.json";
pub const TOKENIZER_SHA256: &str =
    "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39";
pub const TOKENIZER_LEN: u64 = 17_082_730;

pub const CONFIG_URL: &str = "https://huggingface.co/intfloat/multilingual-e5-small/resolve/614241f622f53c4eeff9890bdc4f31cfecc418b3/config.json";
pub const CONFIG_SHA256: &str = "69137736cab8b8903a07fe8afaafdda25aac55415a12a55d1bffa9f581abf959";
pub const CONFIG_LEN: u64 = 655;

/// The small encoder's config as pinned, byte for byte. A device that
/// installed the weights and the tokenizer before the config was pinned has
/// the model already, and is not made to wait for the network to use it.
pub const SMALL_CONFIG: &[u8] = include_bytes!("multilingual-e5-small.config.json");

/// `intfloat/multilingual-e5-base`, Apache-2.0, at a pinned commit: an
/// XLM-RoBERTa of twelve heads of 64, 768 wide. Its tokenizer is not the small
/// one's byte for byte (250 002 pieces against 250 037), so it is pinned too.
const BASE_COMMIT_URL: &str =
    "https://huggingface.co/intfloat/multilingual-e5-base/resolve/d128750597153bb5987e10b1c3493a34e5a4502a";
pub const BASE_WEIGHTS_SHA256: &str =
    "a18a44fad1d0b46ded15928144138cff1135d5cc8233bdd90be5f18822de09a7";
pub const BASE_WEIGHTS_LEN: u64 = 1_112_201_288;
pub const BASE_TOKENIZER_SHA256: &str =
    "62c24cdc13d4c9952d63718d6c9fa4c287974249e16b7ade6d5a85e7bbb75626";
pub const BASE_TOKENIZER_LEN: u64 = 17_082_660;
pub const BASE_CONFIG_SHA256: &str =
    "9dab198f24c8c0879e481cf7822005d5ecbceedbacb390ffafa594e28d31bac4";
pub const BASE_CONFIG_LEN: u64 = 694;

impl Encoder {
    /// Where this encoder's files are fetched from, and the pins that say
    /// they are the right ones.
    pub fn source(self) -> ModelSource {
        let pin = |name, url: String, sha256: &str, len| Pin {
            name,
            url,
            sha256: sha256.to_string(),
            len,
        };
        match self {
            Encoder::Small => ModelSource {
                encoder: self,
                weights: pin(
                    WEIGHTS_FILE,
                    WEIGHTS_URL.into(),
                    WEIGHTS_SHA256,
                    WEIGHTS_LEN,
                ),
                tokenizer: pin(
                    TOKENIZER_FILE,
                    TOKENIZER_URL.into(),
                    TOKENIZER_SHA256,
                    TOKENIZER_LEN,
                ),
                config: pin(CONFIG_FILE, CONFIG_URL.into(), CONFIG_SHA256, CONFIG_LEN),
            },
            Encoder::Base => ModelSource {
                encoder: self,
                weights: pin(
                    "multilingual-e5-base.safetensors",
                    format!("{BASE_COMMIT_URL}/model.safetensors"),
                    BASE_WEIGHTS_SHA256,
                    BASE_WEIGHTS_LEN,
                ),
                tokenizer: pin(
                    "multilingual-e5-base.tokenizer.json",
                    format!("{BASE_COMMIT_URL}/tokenizer.json"),
                    BASE_TOKENIZER_SHA256,
                    BASE_TOKENIZER_LEN,
                ),
                config: pin(
                    "multilingual-e5-base.config.json",
                    format!("{BASE_COMMIT_URL}/config.json"),
                    BASE_CONFIG_SHA256,
                    BASE_CONFIG_LEN,
                ),
            },
        }
    }
}

impl Default for ModelSource {
    fn default() -> ModelSource {
        Encoder::Small.source()
    }
}

impl ModelSource {
    /// Nothing pinned is the feature withdrawn on every device: the digests
    /// are filled together or not at all.
    pub fn is_pinned(&self) -> bool {
        !self.weights.sha256.is_empty()
            && !self.tokenizer.sha256.is_empty()
            && !self.config.sha256.is_empty()
    }

    /// Where the pinned files would be, whether or not any is installed.
    pub fn artifact(&self, cache_dir: &Path) -> Artifact {
        Artifact {
            encoder: self.encoder,
            weights: file_path(cache_dir, &self.weights),
            tokenizer: file_path(cache_dir, &self.tokenizer),
            config: file_path(cache_dir, &self.config),
        }
    }
}

impl ModelSource {
    /// The same pins at an address nothing listens on: what a test core runs
    /// against, so a pass thread it leaves behind never reaches Hugging Face.
    #[cfg(test)]
    pub fn offline(self) -> ModelSource {
        let off = |pin: Pin| Pin {
            url: "http://127.0.0.1:9/offline".into(),
            ..pin
        };
        ModelSource {
            weights: off(self.weights),
            tokenizer: off(self.tokenizer),
            config: off(self.config),
            ..self
        }
    }
}

/// Removes the cached files of `source` whose bytes no longer hash to their
/// pin, so the next launch fetches them again. A file that still matches
/// stays: a pinned file that will not load is this build's fault, and a
/// download per launch would not change it.
pub fn discard_damaged(cache_dir: &Path, source: &ModelSource) {
    let mut buf = vec![0u8; 1 << 20];
    for pin in [&source.weights, &source.tokenizer, &source.config] {
        if pin.sha256.is_empty() {
            continue;
        }
        let path = file_path(cache_dir, pin);
        let Ok(mut file) = std::fs::File::open(&path) else {
            continue;
        };
        let mut digest = Sha256::new();
        let read = loop {
            match file.read(&mut buf) {
                Ok(0) => break true,
                Ok(n) => digest.update(&buf[..n]),
                Err(_) => break false,
            }
        };
        let hex: String = digest
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        if read && !hex.eq_ignore_ascii_case(&pin.sha256) {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// Where the three files are on this device, and which encoder they are.
#[derive(Debug)]
pub struct Artifact {
    pub encoder: Encoder,
    pub weights: PathBuf,
    pub tokenizer: PathBuf,
    pub config: PathBuf,
}

/// Held across a download: the temporary has a fixed name, so that one which
/// stood aside can be picked up where it stopped, and one writer at a time is
/// what keeps it whole.
static FETCHING: Mutex<()> = Mutex::new(());

/// Where a pinned file is cached. The digest names the file because a cached
/// one is never verified again: a changed pin has to miss the cache rather than
/// trust what the old one left there.
pub fn file_path(cache_dir: &Path, pin: &Pin) -> PathBuf {
    let key = pin.sha256.get(..16).unwrap_or(&pin.sha256);
    cache_dir.join("model").join(format!("{key}-{}", pin.name))
}

/// The three files on disk, downloading whichever is not there yet. `Ok(None)`
/// when any checksum is unpinned: there is nothing to verify against, so there is
/// nothing to fetch.
///
/// Pass an agent of its own, built with a bounded redirects(5) rather than the
/// redirects(0) every other client here needs: these requests carry no header
/// and their answers are pinned by digest, so the host that ends up serving the
/// bytes decides nothing.
///
/// `paused` set mid-download stops it with `EmbedError::Paused`, keeping what
/// arrived for the next call to resume from.
pub fn model_files(
    agent: &ureq::Agent,
    cache_dir: &Path,
    source: &ModelSource,
    paused: &AtomicBool,
) -> Result<Option<Artifact>, EmbedError> {
    if !source.is_pinned() {
        return Ok(None);
    }
    let weights = fetch(agent, cache_dir, &source.weights, paused)?;
    let tokenizer = fetch(agent, cache_dir, &source.tokenizer, paused)?;
    let config = fetch(agent, cache_dir, &source.config, paused)?;
    // only once all are in place: a sweep between them would delete the one
    // that had just been installed, since the others' names are not there yet.
    // The default encoder's files outlive a switch to another one, so that
    // switching back costs neither a download nor a re-embedding.
    let small = Encoder::Small.source().artifact(cache_dir);
    sweep(
        cache_dir,
        &[&weights, &tokenizer, &config],
        &[&small.weights, &small.tokenizer, &small.config],
    );
    Ok(Some(Artifact {
        encoder: source.encoder,
        weights,
        tokenizer,
        config,
    }))
}

/// One pinned file, downloaded if the cache does not hold it.
///
/// The body is hashed and written as it arrives rather than collected first:
/// the weights are 449 MiB, and a device holding them twice over in memory is a
/// device the system kills halfway through the only download it ever makes.
fn fetch(
    agent: &ureq::Agent,
    cache_dir: &Path,
    pin: &Pin,
    paused: &AtomicBool,
) -> Result<PathBuf, EmbedError> {
    let path = file_path(cache_dir, pin);
    if path.exists() {
        return Ok(path);
    }
    let dir = path.parent().expect("file_path always has a directory");
    std::fs::create_dir_all(dir).map_err(|e| EmbedError::Io(e.to_string()))?;
    let _fetching = FETCHING.lock();
    // installed by another caller while this one waited for the lock
    if path.exists() {
        return Ok(path);
    }
    if pin.sha256.eq_ignore_ascii_case(CONFIG_SHA256) {
        let mut part = path.clone().into_os_string();
        part.push(".part");
        std::fs::write(&part, SMALL_CONFIG).map_err(|e| EmbedError::Io(e.to_string()))?;
        std::fs::rename(&part, &path).map_err(|e| EmbedError::Io(e.to_string()))?;
        return Ok(path);
    }

    // written aside and renamed: a download cut in half would otherwise be read
    // as a model on the next launch, and only this path checks the digest
    let mut part = path.clone().into_os_string();
    part.push(".part");
    let part = PathBuf::from(part);
    // a part as long as the pin or longer is not something a range can finish
    let have = std::fs::metadata(&part)
        .map(|m| m.len())
        .ok()
        .filter(|&len| len < pin.len)
        .unwrap_or(0);
    if let Err(e) = stream(agent, pin, &part, have, paused) {
        // what the server or the bytes decided goes; what the network, the
        // disk or a film interrupted stays for the next call to resume
        let resumable = match &e {
            EmbedError::Paused | EmbedError::Transport(_) | EmbedError::Io(_) => true,
            EmbedError::Status(code) => *code >= 500,
            _ => false,
        };
        if !resumable {
            let _ = std::fs::remove_file(&part);
        }
        return Err(e);
    }
    std::fs::rename(&part, &path).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        EmbedError::Io(e.to_string())
    })?;
    Ok(path)
}

/// The body into `part`, hashed on the way past, after the `have` bytes an
/// earlier call left there. One read past the pinned length is enough to know
/// the body is not the file, and it stops there rather than reading the rest of
/// whatever is being served.
fn stream(
    agent: &ureq::Agent,
    pin: &Pin,
    part: &Path,
    have: u64,
    paused: &AtomicBool,
) -> Result<(), EmbedError> {
    let mut req = agent.get(&pin.url);
    if have > 0 {
        req = req.set("Range", &format!("bytes={have}-"));
    }
    let resp = req.call().map_err(|e| match e {
        ureq::Error::Status(code, _) => EmbedError::Status(code),
        ureq::Error::Transport(t) => EmbedError::Transport(t.kind().to_string()),
    })?;
    let mut digest = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    // a redirect past the agent's limit comes back as the 3xx itself, body and
    // all; only a 200 carries the file, and a 206 from `have` the rest of it
    let resumed = have > 0
        && resp.status() == 206
        && resp
            .header("Content-Range")
            .is_some_and(|v| v.trim().starts_with(&format!("bytes {have}-")));
    let (mut file, mut written) = if resumed {
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .append(true)
            .open(part)
            .map_err(|e| EmbedError::Io(e.to_string()))?;
        // the digest covers the whole file, so the part on disk goes through it first
        loop {
            let n = file
                .read(&mut buf)
                .map_err(|e| EmbedError::Io(e.to_string()))?;
            if n == 0 {
                break;
            }
            digest.update(&buf[..n]);
        }
        (file, have)
    } else if resp.status() == 200 {
        let file = std::fs::File::create(part).map_err(|e| EmbedError::Io(e.to_string()))?;
        (file, 0)
    } else {
        return Err(EmbedError::Status(resp.status()));
    };
    let mut reader = resp.into_reader().take(pin.len + 1 - written);
    loop {
        // playback owns the network: what arrived stays in the part
        if paused.load(Ordering::Relaxed) {
            return Err(EmbedError::Paused);
        }
        let n = reader
            .read(&mut buf)
            .map_err(|e| EmbedError::Io(e.to_string()))?;
        if n == 0 {
            break;
        }
        written += n as u64;
        if written > pin.len {
            return Err(EmbedError::TooLarge);
        }
        digest.update(&buf[..n]);
        file.write_all(&buf[..n])
            .map_err(|e| EmbedError::Io(e.to_string()))?;
    }
    // nothing checks that `written` reached `pin.len`: a body that stopped
    // early is a truncation the digest below refuses on its own, and rejecting
    // it on the length as well would turn a mispasted `len` into a correct file
    // refused for the wrong reason
    let hex: String = digest
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    // both sides lowercase: the pin is pasted by hand, and hex out of a
    // checksum tool comes in either case
    if !hex.eq_ignore_ascii_case(&pin.sha256) {
        return Err(EmbedError::Checksum);
    }
    file.sync_all().map_err(|e| EmbedError::Io(e.to_string()))
}

/// What an earlier pin installed answers nothing now, and the weights are
/// 449 MiB of a cache the device may purge for us otherwise; the base
/// encoder's are 1.1 GB. `keep` is what this source installed, and only its
/// temporaries are left, since one of them is a download to resume: a
/// temporary of any other file is a download nobody will finish. `spare`
/// survives too, but not its temporaries.
fn sweep(cache_dir: &Path, keep: &[&Path], spare: &[&Path]) {
    let Ok(entries) = std::fs::read_dir(cache_dir.join("model")) else {
        return;
    };
    for entry in entries.flatten() {
        let stale = entry.path();
        let kept = if stale.extension() == Some("part".as_ref()) {
            keep.iter().any(|k| {
                let mut part = k.as_os_str().to_owned();
                part.push(".part");
                stale.as_os_str() == part
            })
        } else {
            keep.contains(&stale.as_path()) || spare.contains(&stale.as_path())
        };
        if !kept {
            let _ = std::fs::remove_file(&stale);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::embed::fixture;
    use crate::plex::fake::{FakeServer, Reply};

    /// The agent this download asks for: bounded redirects, no header.
    fn agent() -> ureq::Agent {
        ureq::AgentBuilder::new().redirects(5).build()
    }

    fn hex(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// A server answering the three files, and the source that reaches it.
    struct Hosted {
        server: FakeServer,
        weights: Vec<u8>,
        tokenizer: Vec<u8>,
        config: Vec<u8>,
    }

    impl Hosted {
        /// Serves the bytes it is given, so a test can host a body that is not
        /// what the source pins.
        fn serving(weights: Vec<u8>, tokenizer: Vec<u8>) -> Hosted {
            let config = fixture::config_bytes();
            let (w, t, c) = (weights.clone(), tokenizer.clone(), config.clone());
            let server = FakeServer::start(move |req| Reply {
                status: 200,
                headers: Vec::new(),
                body: if req.url.contains("tokenizer") {
                    t.clone()
                } else if req.url.contains("config") {
                    c.clone()
                } else {
                    w.clone()
                },
            });
            Hosted {
                server,
                weights,
                tokenizer,
                config,
            }
        }

        fn start() -> Hosted {
            Hosted::serving(fixture::weights_bytes(), fixture::tokenizer_bytes())
        }

        /// The source pinning the fixture, at this server.
        fn source(&self) -> ModelSource {
            ModelSource {
                encoder: Encoder::Small,
                weights: Pin {
                    name: WEIGHTS_FILE,
                    url: format!("{}/weights.safetensors", self.server.base_url),
                    sha256: hex(&self.weights),
                    len: self.weights.len() as u64,
                },
                tokenizer: Pin {
                    name: TOKENIZER_FILE,
                    url: format!("{}/tokenizer.json", self.server.base_url),
                    sha256: hex(&self.tokenizer),
                    len: self.tokenizer.len() as u64,
                },
                config: Pin {
                    name: CONFIG_FILE,
                    url: format!("{}/config.json", self.server.base_url),
                    sha256: hex(&self.config),
                    len: self.config.len() as u64,
                },
            }
        }
    }

    /// Whatever is in the cache directory, which the failing paths must leave
    /// empty: no artifact, and no temporary either.
    fn cached(cache_dir: &Path) -> Vec<String> {
        let dir = cache_dir.join("model");
        if !dir.exists() {
            return Vec::new();
        }
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn both_files_are_downloaded_once_and_then_read_from_the_cache() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        let source = hosted.source();

        let artifact = model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert_eq!(std::fs::read(&artifact.weights).unwrap(), hosted.weights);
        assert_eq!(
            std::fs::read(&artifact.tokenizer).unwrap(),
            hosted.tokenizer
        );
        assert_eq!(hosted.server.requests().len(), 3);
        // no credential goes to wherever the weights are hosted
        assert_eq!(hosted.server.requests()[0].header("X-Plex-Token"), None);

        let again = model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert_eq!(again.weights, artifact.weights);
        assert_eq!(hosted.server.requests().len(), 3);
        // nothing half-written is left behind
        assert_eq!(cached(cache.path()).len(), 3);
    }

    #[test]
    fn what_an_earlier_pin_installed_is_reclaimed_rather_than_kept() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        let stale = cache.path().join("model").join("deadbeefdeadbeef-old.bin");
        std::fs::create_dir_all(stale.parent().unwrap()).unwrap();
        std::fs::write(&stale, b"an artifact an earlier release pinned").unwrap();

        model_files(
            &agent(),
            cache.path(),
            &hosted.source(),
            &AtomicBool::new(false),
        )
        .unwrap()
        .unwrap();
        assert!(!stale.exists());
        assert_eq!(cached(cache.path()).len(), 3);
    }

    #[test]
    fn the_redirect_a_cdn_answers_with_is_followed() {
        let hosted = Hosted::start();
        let signed = hosted.server.base_url.clone();
        // what a resolve URL really answers: a 302 to a signed URL elsewhere
        let front = FakeServer::start(move |req| Reply {
            status: 302,
            headers: vec![("Location".into(), format!("{signed}{}", req.url))],
            body: Vec::new(),
        });
        let cache = tempfile::tempdir().unwrap();
        let mut source = hosted.source();
        source.weights.url = format!("{}/weights.safetensors", front.base_url);
        source.tokenizer.url = format!("{}/tokenizer.json", front.base_url);
        source.config.url = format!("{}/config.json", front.base_url);

        let artifact = model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        // the bytes came from the second host, and the digest is what kept them
        assert_eq!(std::fs::read(&artifact.weights).unwrap(), hosted.weights);
        assert_eq!(hosted.server.requests().len(), 3);
    }

    #[test]
    fn the_small_config_kept_in_the_binary_is_the_pinned_one() {
        assert_eq!(SMALL_CONFIG.len() as u64, CONFIG_LEN);
        assert_eq!(hex(SMALL_CONFIG), CONFIG_SHA256);
    }

    #[test]
    fn a_cache_holding_the_small_pair_from_before_the_config_needs_no_fetch() {
        // a device that installed the small encoder before its config was
        // pinned: the two large files are there and nothing else
        let cache = tempfile::tempdir().unwrap();
        let installed = fixture::write_model(cache.path());
        std::fs::remove_file(&installed.config).unwrap();
        let offline = FakeServer::start(|_req| Reply::status(404));
        let mut source = ModelSource::default();
        for pin in [
            &mut source.weights,
            &mut source.tokenizer,
            &mut source.config,
        ] {
            pin.url = format!("{}/{}", offline.base_url, pin.name);
        }
        let artifact = model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert!(offline.requests().is_empty());
        assert_eq!(std::fs::read(&artifact.config).unwrap(), SMALL_CONFIG);
    }

    #[test]
    fn the_small_encoder_outlives_a_switch_and_an_abandoned_download_does_not() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        // the default encoder, installed, and half of the other one
        let small = Encoder::Small.source().artifact(cache.path());
        let base = Encoder::Base.source().artifact(cache.path());
        std::fs::create_dir_all(small.weights.parent().unwrap()).unwrap();
        for path in [&small.weights, &small.tokenizer, &small.config] {
            std::fs::write(path, b"small").unwrap();
        }
        let mut part = base.weights.clone().into_os_string();
        part.push(".part");
        std::fs::write(&part, b"half of 1.1 GB").unwrap();

        model_files(
            &agent(),
            cache.path(),
            &hosted.source(),
            &AtomicBool::new(false),
        )
        .unwrap()
        .unwrap();
        for path in [&small.weights, &small.tokenizer, &small.config] {
            assert!(path.exists(), "{path:?} was reclaimed");
        }
        assert!(!std::path::Path::new(&part).exists());
    }

    #[test]
    fn each_encoder_is_pinned_apart_and_cached_under_its_own_names() {
        let (small, base) = (Encoder::Small.source(), Encoder::Base.source());
        assert!(small.is_pinned() && base.is_pinned());
        let cache = Path::new("/cache");
        let (a, b) = (small.artifact(cache), base.artifact(cache));
        for (x, y) in [
            (&a.weights, &b.weights),
            (&a.tokenizer, &b.tokenizer),
            (&a.config, &b.config),
        ] {
            assert_ne!(x, y);
        }
        assert_eq!((a.encoder, b.encoder), (Encoder::Small, Encoder::Base));
    }

    #[test]
    fn a_pin_pasted_in_upper_case_is_the_same_pin() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        let mut source = hosted.source();
        source.weights.sha256 = source.weights.sha256.to_uppercase();
        source.tokenizer.sha256 = source.tokenizer.sha256.to_uppercase();

        let artifact = model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert_eq!(std::fs::read(&artifact.weights).unwrap(), hosted.weights);
    }

    #[test]
    fn bytes_that_are_not_the_pinned_ones_are_not_cached() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        let mut source = hosted.source();
        // the pinned length, so only the digest can tell them apart
        source.weights.sha256 = hex(&vec![7u8; hosted.weights.len()]);

        let err =
            model_files(&agent(), cache.path(), &source, &AtomicBool::new(false)).unwrap_err();
        assert!(matches!(err, EmbedError::Checksum), "{err:?}");
        // no artifact, and nothing half-written next to where it would go
        assert!(cached(cache.path()).is_empty());
    }

    #[test]
    fn a_body_that_is_not_the_pinned_length_is_refused_as_it_arrives() {
        let cache = tempfile::tempdir().unwrap();
        let weights = fixture::weights_bytes();
        let tokenizer = fixture::tokenizer_bytes();

        // longer than the pin: refused without reading the rest of it
        let mut longer = weights.clone();
        longer.push(0);
        let hosted = Hosted::serving(longer, tokenizer.clone());
        let mut source = hosted.source();
        source.weights.sha256 = hex(&weights);
        source.weights.len = weights.len() as u64;
        let err =
            model_files(&agent(), cache.path(), &source, &AtomicBool::new(false)).unwrap_err();
        assert!(matches!(err, EmbedError::TooLarge), "{err:?}");
        assert!(cached(cache.path()).is_empty());

        // shorter than the pin: the length is not what refuses this one, the
        // digest is, and a body that stopped early has a different one
        let hosted = Hosted::serving(weights[..weights.len() - 1].to_vec(), tokenizer);
        let mut source = hosted.source();
        source.weights.sha256 = hex(&weights);
        source.weights.len = weights.len() as u64;
        let err =
            model_files(&agent(), cache.path(), &source, &AtomicBool::new(false)).unwrap_err();
        assert!(matches!(err, EmbedError::Checksum), "{err:?}");
        assert!(cached(cache.path()).is_empty());
    }

    #[test]
    fn a_server_that_will_not_serve_it_leaves_the_feature_off() {
        let cache = tempfile::tempdir().unwrap();
        let gone = FakeServer::start(|_req| Reply::status(404));
        let mut source = ModelSource::default();
        source.weights.url = format!("{}/weights", gone.base_url);
        source.tokenizer.url = format!("{}/tokenizer", gone.base_url);
        source.config.url = format!("{}/config", gone.base_url);
        assert!(matches!(
            model_files(&agent(), cache.path(), &source, &AtomicBool::new(false)),
            Err(EmbedError::Status(404))
        ));

        // nothing listens on port 1
        let mut dead = ModelSource::default();
        dead.weights.url = "http://127.0.0.1:1/w".to_string();
        dead.tokenizer.url = "http://127.0.0.1:1/t".to_string();
        dead.config.url = "http://127.0.0.1:1/c".to_string();
        assert!(matches!(
            model_files(&agent(), cache.path(), &dead, &AtomicBool::new(false)),
            Err(EmbedError::Transport(_))
        ));
        assert!(cached(cache.path()).is_empty());
    }

    #[test]
    fn a_download_stands_aside_for_playback_and_resumes_where_it_stopped() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        let source = hosted.source();
        let err = model_files(&agent(), cache.path(), &source, &AtomicBool::new(true)).unwrap_err();
        assert!(matches!(err, EmbedError::Paused), "{err:?}");
        assert!(!file_path(cache.path(), &source.weights).exists());

        // half the weights already in the part, and a host that honours ranges
        let half = hosted.weights.len() / 2;
        let mut part = file_path(cache.path(), &source.weights).into_os_string();
        part.push(".part");
        std::fs::write(&part, &hosted.weights[..half]).unwrap();
        let ranged = crate::plex::fake::range_server(hosted.weights.clone());
        let mut resumed = source.clone();
        resumed.weights.url = format!("{}/weights.safetensors", ranged.base_url);

        let artifact = model_files(&agent(), cache.path(), &resumed, &AtomicBool::new(false))
            .unwrap()
            .unwrap();
        assert_eq!(std::fs::read(&artifact.weights).unwrap(), hosted.weights);
        let asked = format!("bytes={half}-");
        assert_eq!(ranged.requests()[0].header("Range"), Some(asked.as_str()));
        assert_eq!(cached(cache.path()).len(), 3);
    }

    #[test]
    fn no_pinned_checksum_is_no_download_at_all() {
        let hosted = Hosted::start();
        let cache = tempfile::tempdir().unwrap();
        // the artifact is withdrawn: the feature is off, quietly, and nothing
        // is fetched to find that out
        for blank in 0..3 {
            let mut source = hosted.source();
            match blank {
                0 => source.weights.sha256 = String::new(),
                1 => source.tokenizer.sha256 = String::new(),
                _ => source.config.sha256 = String::new(),
            }
            assert!(!source.is_pinned());
            assert!(
                model_files(&agent(), cache.path(), &source, &AtomicBool::new(false))
                    .unwrap()
                    .is_none()
            );
        }
        assert!(hosted.server.requests().is_empty());
    }
}
