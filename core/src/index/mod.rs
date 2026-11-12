/// A stage show filmed, stand-up or a one-man show, on the metadata row
/// aliased `$m`: a recording of a stage, not a film a mood or a season deals.
/// Told by a stage's TMDB keyword on a title with a stage's billing, by its
/// one performer having written or directed it, or by a name that opens on
/// its headliner's or its writer's, "Dieudonné - En paix", "Sellig : Épisode
/// 1", which is how a recorded show is titled. Never a documentary, which is
/// titled after its subject the same way.
macro_rules! stage_show {
    ($m:literal) => {
        concat!(
            "((((",
            $m,
            ".keywords LIKE '%stand-up%' OR ",
            $m,
            ".keywords LIKE '%stand up%' OR ",
            $m,
            ".keywords LIKE '%one-man show%' OR ",
            $m,
            ".keywords LIKE '%one-woman show%' OR ",
            $m,
            ".keywords LIKE '%comedy special%')",
            " AND (SELECT COUNT(*) FROM title_tags c WHERE c.title_id = ",
            $m,
            ".title_id AND c.kind = 'cast') <= 10)",
            " OR ((SELECT COUNT(*) FROM title_tags c WHERE c.title_id = ",
            $m,
            ".title_id AND c.kind = 'cast') = 1",
            " AND EXISTS (SELECT 1 FROM title_tags c JOIN title_tags w ON w.title_id = c.title_id",
            " AND w.kind IN ('writer', 'director') AND w.value = c.value",
            " WHERE c.title_id = ",
            $m,
            ".title_id AND c.kind = 'cast'))",
            " OR EXISTS (SELECT 1 FROM titles x, (SELECT substr(",
            $m,
            ".cast_names, 1,",
            " instr(",
            $m,
            ".cast_names || ',', ',') - 1) AS head UNION ALL SELECT substr(",
            $m,
            ".writer_names, 1,",
            " instr(",
            $m,
            ".writer_names || ',', ',') - 1)) h",
            " WHERE x.id = ",
            $m,
            ".title_id AND h.head <> '' AND (x.name LIKE h.head || ' - %'",
            " OR x.name LIKE h.head || ' : %' OR x.name LIKE h.head || ': %')))",
            " AND ",
            $m,
            ".genres NOT LIKE '%Documentaire%' AND ",
            $m,
            ".genres NOT LIKE '%Documentary%')"
        )
    };
}

pub mod ask;
pub mod db;
pub mod duo;
pub mod evidence;
pub mod profile;
pub mod queries;
pub mod replay;
pub mod rows;
pub mod scan;
pub mod stats;
pub mod taste;
pub mod tonight;

/// What the viewer said about one title, in the only three levels the remote
/// offers. Three and not a scale: a star rating asks someone holding a remote
/// to calibrate, and the answers it gets back are not worth the arithmetic
/// they invite. What each is worth to the fingerprint is in `index::taste`.
///
/// The stored numbers are the column's, so a row read back means the same
/// thing as the row written: -1 rejected, 1 liked, 2 loved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Down,
    Up,
    Loved,
}

impl Verdict {
    pub fn as_i64(self) -> i64 {
        match self {
            Verdict::Down => -1,
            Verdict::Up => 1,
            Verdict::Loved => 2,
        }
    }

    pub fn from_i64(v: i64) -> Option<Self> {
        match v {
            -1 => Some(Verdict::Down),
            1 => Some(Verdict::Up),
            2 => Some(Verdict::Loved),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Movie,
    Show,
}

impl MediaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MediaKind::Movie => "movie",
            MediaKind::Show => "show",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "movie" => Some(MediaKind::Movie),
            "show" => Some(MediaKind::Show),
            _ => None,
        }
    }
}
