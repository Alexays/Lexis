//! The video transcode session: a second, lighter rendition of a file the
//! connection cannot carry as it is, produced live by the server.
//!
//! Probed against a real server (2026-08-27) rather than written from
//! memory, and three of its findings shape everything here:
//!
//! - Conversion is only granted to a client that declares a profile. Without
//!   `X-Plex-Client-Profile-Extra` the decision answers "no conversion
//!   profile found", whatever the token.
//! - The output is a LIVE stream: chunked, `Accept-Ranges: none`, the
//!   `Range` header ignored, no length. `TranscodeStream` is therefore
//!   sequential, and its `Seek` answers `Unsupported` for anything but a
//!   position query - a player opens it in stream mode or not at all.
//! - A session started at `offset` seconds restarts its own clock near
//!   zero: the caller carries the offset and a seek is a NEW session.

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use super::client::{PlexClient, PlexError};

/// The one profile the probe validated: h264 and AAC in live matroska over
/// plain http, which is also the shape the player's own hardware path takes
/// without a transcode. `context=streaming` is what the server expects for a
/// session it produces on demand.
const PROFILE_EXTRA: &str = "add-transcode-target(type=videoProfile&\
context=streaming&protocol=http&container=mkv&videoCodec=h264&audioCodec=aac)";

/// How often a session is told its client still exists. The server reaps
/// silent sessions after about two minutes, and a full byte-cache window
/// parks the reader for longer than that on a slow film.
const PING_SECONDS: u64 = 60;

/// What the server answered when asked whether it would convert.
#[derive(Debug, Clone, PartialEq)]
pub struct TranscodeDecision {
    pub ok: bool,
    /// The server's own sentence, kept for the diagnostics line.
    pub reason: String,
    /// What the converted stream will cost, in kbps, when the server said.
    pub kbps: Option<i64>,
}

impl PlexClient {
    fn transcode_query(
        &self,
        rating_key: &str,
        max_kbps: u32,
        session: &str,
        offset_seconds: f64,
    ) -> Vec<(&'static str, String)> {
        vec![
            ("path", format!("/library/metadata/{rating_key}")),
            ("mediaIndex", "0".to_string()),
            ("partIndex", "0".to_string()),
            ("protocol", "http".to_string()),
            ("fastSeek", "1".to_string()),
            ("directPlay", "0".to_string()),
            ("directStream", "0".to_string()),
            ("maxVideoBitrate", max_kbps.to_string()),
            ("session", session.to_string()),
            ("offset", format!("{offset_seconds:.3}")),
            ("X-Plex-Client-Identifier", "lexis".to_string()),
            ("X-Plex-Product", "Lexis".to_string()),
            ("X-Plex-Platform", "Generic".to_string()),
            ("X-Plex-Client-Profile-Extra", PROFILE_EXTRA.to_string()),
        ]
    }

    /// Asks without starting anything: the decision endpoint costs the server
    /// a lookup, where `start` costs it a transcoder.
    pub fn transcode_decision(
        &self,
        rating_key: &str,
        max_kbps: u32,
        session: &str,
    ) -> Result<TranscodeDecision, PlexError> {
        let value = self.get_json_value(
            "/video/:/transcode/universal/decision",
            &self.transcode_query(rating_key, max_kbps, session, 0.0),
        )?;
        let container = &value["MediaContainer"];
        // 1001 is "conversion OK"; everything else carries its own sentence.
        let code = container["transcodeDecisionCode"].as_i64().unwrap_or(0);
        let reason = container["transcodeDecisionText"]
            .as_str()
            .unwrap_or("no decision")
            .to_string();
        let kbps = container["Metadata"][0]["Media"][0]["bitrate"].as_i64();
        Ok(TranscodeDecision {
            ok: code == 1001,
            reason,
            kbps,
        })
    }

    /// Starts a session and hands back its live stream. The caller owns the
    /// offset: the stream's own timestamps restart near zero.
    pub fn open_transcode(
        &self,
        rating_key: &str,
        max_kbps: u32,
        session: &str,
        offset_seconds: f64,
    ) -> Result<TranscodeStream, PlexError> {
        let mut req = self
            .agent()
            .get(&format!(
                "{}/video/:/transcode/universal/start.mkv",
                self.base_url()
            ))
            .set("X-Plex-Token", self.token());
        for (k, v) in self.transcode_query(rating_key, max_kbps, session, offset_seconds) {
            req = req.query(k, &v);
        }
        let resp = req.call().map_err(|e| match e {
            ureq::Error::Status(401, _) => PlexError::Unauthorized,
            ureq::Error::Status(code, _) => PlexError::Status(code),
            ureq::Error::Transport(t) => PlexError::Transport(t.kind().to_string()),
        })?;
        let reader = resp.into_reader();
        let closed = Arc::new(AtomicBool::new(false));
        let pinger = spawn_pinger(self.clone(), session.to_string(), closed.clone());
        Ok(TranscodeStream {
            reader: Box::new(reader),
            client: self.clone(),
            session: session.to_string(),
            consumed: 0,
            closed,
            pinger: Some(pinger),
        })
    }

    pub fn transcode_ping(&self, session: &str) -> Result<(), PlexError> {
        self.get_ok(
            "/video/:/transcode/universal/ping",
            &[("session", session.to_string())],
        )
    }

    /// Tells the server to put its transcoder down. Idempotent on the server
    /// side: a session already reaped answers 404, which is still "stopped".
    pub fn transcode_stop(&self, session: &str) -> Result<(), PlexError> {
        match self.get_ok(
            "/video/:/transcode/universal/stop",
            &[("session", session.to_string())],
        ) {
            Err(PlexError::Status(404)) => Ok(()),
            other => other,
        }
    }
}

fn spawn_pinger(
    client: PlexClient,
    session: String,
    closed: Arc<AtomicBool>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        // Wakes every second to notice a close, pings once a minute: a
        // thread parked a whole minute would hold a dropped stream's stop
        // back for the rest of it.
        let mut ticks = 0u64;
        loop {
            std::thread::sleep(std::time::Duration::from_secs(1));
            if closed.load(Ordering::Relaxed) {
                return;
            }
            ticks += 1;
            if ticks.is_multiple_of(PING_SECONDS) {
                let _ = client.transcode_ping(&session);
            }
        }
    })
}

/// The live session, as a stream the FFI can carry. Sequential: `Seek` only
/// answers a position query, because the server serves nothing else.
pub struct TranscodeStream {
    reader: Box<dyn Read + Send>,
    client: PlexClient,
    session: String,
    consumed: u64,
    closed: Arc<AtomicBool>,
    pinger: Option<std::thread::JoinHandle<()>>,
}

impl Read for TranscodeStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.reader.read(buf)?;
        self.consumed += n as u64;
        Ok(n)
    }
}

impl Seek for TranscodeStream {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match pos {
            // FFmpeg asks where it stands; that much a live stream can say.
            SeekFrom::Current(0) => Ok(self.consumed),
            _ => Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "a live transcode session serves no seeks: open a new one at an offset",
            )),
        }
    }
}

impl Drop for TranscodeStream {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Relaxed);
        if let Some(pinger) = self.pinger.take() {
            let _ = pinger.join();
        }
        // The transcoder is real CPU on the server for as long as the session
        // lives: a dropped stream gives it back rather than letting the reap
        // timer find it two minutes later.
        let _ = self.client.transcode_stop(&self.session);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plex::fake;
    use std::io::Read;

    fn client(server: &fake::FakeServer) -> PlexClient {
        PlexClient::new(&server.base_url, "sekrit", "install")
    }

    #[test]
    fn the_decision_reads_the_servers_own_answer() {
        let server = fake::library();
        let decision = client(&server)
            .transcode_decision("44434", 2000, "s1")
            .unwrap();
        assert!(decision.ok, "{}", decision.reason);
        assert_eq!(decision.kbps, Some(1720));
    }

    /// The fake refuses a profileless request the way the real server was
    /// measured to; the query built here has to carry the profile, or every
    /// decision in the field answers "no conversion profile found".
    #[test]
    fn the_query_carries_the_client_profile() {
        let server = fake::library();
        let _ = client(&server).transcode_decision("44434", 2000, "s1");
        let sent = server.requests();
        let decision = sent
            .iter()
            .find(|r| r.url.starts_with("/video/:/transcode/universal/decision"))
            .expect("no decision request");
        assert!(decision.url.contains("X-Plex-Client-Profile-Extra="));
        assert!(decision.url.contains("maxVideoBitrate=2000"));
        assert!(decision.url.contains("session=s1"));
    }

    #[test]
    fn the_stream_reads_the_live_body_and_stops_its_session_on_drop() {
        let server = fake::library();
        let mut stream = client(&server)
            .open_transcode("44434", 2000, "s2", 300.0)
            .unwrap();
        let mut body = Vec::new();
        stream.read_to_end(&mut body).unwrap();
        assert_eq!(body, b"live-matroska-body");
        // the offset rides the start URL: the session is the seek
        let started = server
            .requests()
            .into_iter()
            .find(|r| r.url.starts_with("/video/:/transcode/universal/start"))
            .expect("no start request");
        assert!(started.url.contains("offset=300.000"));
        drop(stream);
        assert!(
            server
                .requests()
                .iter()
                .any(|r| r.url.starts_with("/video/:/transcode/universal/stop")
                    && r.url.contains("session=s2")),
            "a dropped stream must give the transcoder back"
        );
    }

    /// A live session serves no seeks: the position query answers, anything
    /// else refuses, and the refusal is what the player's stream mode reads.
    #[test]
    fn the_stream_answers_position_and_refuses_travel() {
        let server = fake::library();
        let mut stream = client(&server)
            .open_transcode("44434", 2000, "s3", 0.0)
            .unwrap();
        let mut four = [0u8; 4];
        stream.read_exact(&mut four).unwrap();
        assert_eq!(stream.stream_position().unwrap(), 4);
        assert!(stream.seek(SeekFrom::Start(0)).is_err());
        assert!(stream.seek(SeekFrom::End(-1)).is_err());
    }
}
