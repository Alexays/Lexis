//! The Tonight trio: three roles, three sources, one firm promise. The safe
//! bet comes off the dominant facet's picks, the other mood off the facet
//! least like it, the discovery off the band the taste pass swept beside
//! them - and nothing is offered that cannot finish before the bedtime this
//! module reads off the watch history's own evenings.

use super::db::{Db, IndexError};
use super::queries::{row_to_title, TitleRow};
use super::MediaKind;
use rusqlite::params;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// Minutes after 00:00 local; an evening spans [0, 720) from there.
pub const EVENING_START_MIN: u32 = 18 * 60;
pub const EVENING_LEN_MIN: u32 = 12 * 60;

/// A weekend afternoon runs 13:00-18:00 local, where the evening takes over.
pub const AFTERNOON_START_MIN: u32 = 13 * 60;
pub const AFTERNOON_LEN_MIN: u32 = EVENING_START_MIN - AFTERNOON_START_MIN;

/// 19:30, as minutes after 13:00: when a weekend afternoon's film has to be
/// over, dinner and the evening being the next thing the day holds.
pub const DEFAULT_AFTERNOON_END_MIN: u32 = 19 * 60 + 30 - AFTERNOON_START_MIN;

/// 23:15, what a weeknight is until the history says otherwise.
pub const DEFAULT_WEEKNIGHT_MIN: u32 = 315;
/// Midnight, the weekend's default.
pub const DEFAULT_WEEKEND_MIN: u32 = 360;
/// 22:00: below this the estimate is distrust, not evidence.
pub const CLAMP_MIN: u32 = 240;
/// 02:00: past this the estimate stops meaning "tonight".
pub const CLAMP_MAX: u32 = 480;
pub const QUANTILE: f32 = 0.75;
/// Fewer evenings than this and the default answers instead.
pub const MIN_EVENINGS: usize = 8;
/// 26 weeks: how far back an evening is still evidence.
pub const WINDOW_SECS: i64 = 26 * 7 * 86_400;
/// A film may run this many minutes past the estimate and still be honest.
pub const TOLERANCE_MIN: u32 = 15;

/// The same margin for an evening of two. Wider because two people talk,
/// pause, and go and fetch a drink: the same film runs longer in a room with
/// somebody else in it.
pub const TOLERANCE_TOGETHER_MIN: u32 = 30;

/// How near the taste the gamble must stay when the evening is not only the
/// viewer's own. Betting a stranger's evening on a stranger's film is a bet
/// they did not agree to.
pub const GAMBLE_TOGETHER_FLOOR: f32 = 0.5;
/// "Not tonight" keeps a title out of the trio this long.
pub const DEFER_SECS: i64 = 14 * 86_400;

/// How many times an evening may be refused before its trio is its trio,
/// unless a setting says otherwise. Refusal without a bound is browsing under
/// another name, and the whole point of a screen that does not scroll is that
/// browsing has to stop.
pub const PASSES: u32 = 3;

/// The setting that overrides it, read by the core rather than the screen so
/// the rule holds whatever a client draws.
pub const PASSES_SETTING: &str = "tonight.passes";

/// The library's mean score on the 0-10 scale, as the taste pass last measured
/// it: the prior every score is pulled towards, read every minute and so
/// stored rather than averaged over the whole of `metadata` each time.
pub const RATING_MEAN_SETTING: &str = "tonight.rating_mean";

/// How long an accepted "after this" proposal waits for its evening. Three
/// days: a proposal made on Friday is still tomorrow's on Saturday and
/// Sunday, and stops being an obligation by Tuesday.
pub const QUEUE_LIFE_SECS: i64 = 3 * 86_400;

/// How many places at the head of the discovery band the gamble turns
/// through, one order per session. The band is ranked once per taste pass,
/// so without the turn the same stranger would lead it every night until the
/// taste moved; twelve is deep enough to vary and shallow enough to stay in
/// the part of the band the pass meant.
pub const GAMBLE_WINDOW: usize = 12;

/// The least a stranger's score may be, pulled towards the library's mean by
/// how few voted for it, for the gamble to offer it: far from the taste is a
/// risk worth taking, a film most who saw it disliked is not.
pub const GAMBLE_QUALITY_FLOOR: f64 = 0.55;

/// How many voters a score needs before it speaks mostly for itself: below
/// this the library's mean outweighs it, and a score whose count nobody gave
/// is read as if it had exactly this many.
pub const BAYES_VOTES: f64 = 200.0;

/// Above this share of episodes among what a slot of the week finished, the
/// safe bet's series step up a band; below `FILM_SHARE`, its films do.
pub const SERIES_SHARE: f32 = 0.6;
pub const FILM_SHARE: f32 = 0.2;

/// How recent the pages opened must be to say what this sitting is about,
/// and how many of one taste make it a direction rather than a wander.
pub const BROWSE_SECS: i64 = 2 * 3_600;
pub const BROWSE_MIN: u32 = 2;

/// What the weather or an early dark adds to a candidate of the fitting
/// moods, on the fit's nought-to-two scale: a nudge between near equals, far
/// short of the band a place of the ranking is worth.
pub const AMBIENT_NUDGE: f64 = 0.15;

/// How long what the app said about the weather still holds.
pub const AMBIENT_LIFE_SECS: i64 = 3 * 3_600;

/// The sky as the app read it, in the words the nudge needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Weather {
    Clear,
    Rain,
    Snow,
    Cold,
    Hot,
    Other,
}

/// What the world outside says about the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ambient {
    pub weather: Weather,
    /// The sun set before 18:30.
    pub dark_early: bool,
}

/// The moods the ambient leans towards: somewhere warm when it is grey,
/// cold or dark outside, somewhere else when it is hot.
fn ambient_moods(ambient: Ambient) -> &'static [&'static str] {
    match ambient.weather {
        Weather::Rain | Weather::Snow | Weather::Cold => &["cosy", "light"],
        Weather::Hot => &["escape", "light"],
        Weather::Clear | Weather::Other if ambient.dark_early => &["cosy", "light"],
        Weather::Clear | Weather::Other => &[],
    }
}

/// The local evening `now` belongs to, as a local day number: the day the
/// evening started. None outside 18:00-06:00.
pub fn evening_of(now: i64, tz_offset_secs: i32) -> Option<i64> {
    let local = now + i64::from(tz_offset_secs);
    let day = local.div_euclid(86_400);
    let min = (local.rem_euclid(86_400) / 60) as u32;
    if min >= EVENING_START_MIN {
        Some(day)
    } else if min < EVENING_START_MIN + EVENING_LEN_MIN - 1_440 {
        Some(day - 1)
    } else {
        None
    }
}

/// The session of the trio `now` belongs to: the evening's day number, or on
/// a Saturday or Sunday between 13:00 and 18:00 `-(day) - 1`, which no evening
/// can be. None when the block hides.
pub fn session_of(now: i64, tz_offset_secs: i32) -> Option<i64> {
    if let Some(evening) = evening_of(now, tz_offset_secs) {
        return Some(evening);
    }
    let local = now + i64::from(tz_offset_secs);
    let day = local.div_euclid(86_400);
    let min = (local.rem_euclid(86_400) / 60) as u32;
    // 1970-01-01 was a Thursday: 2 is a Saturday, 3 a Sunday
    (matches!(day.rem_euclid(7), 2 | 3) && min >= AFTERNOON_START_MIN).then_some(-day - 1)
}

/// The local day a session falls on, which is what its distance to another
/// is counted in.
pub fn session_day(session: i64) -> i64 {
    if session >= 0 {
        session
    } else {
        -session - 1
    }
}

/// How far into its evening `now` is, in minutes after 18:00 local.
pub fn minutes_into_evening(now: i64, tz_offset_secs: i32) -> Option<u32> {
    let evening = evening_of(now, tz_offset_secs)?;
    let local = now + i64::from(tz_offset_secs);
    Some(((local - (evening * 86_400 + i64::from(EVENING_START_MIN) * 60)) / 60) as u32)
}

/// 1970-01-01 was a Thursday: day 1 is a Friday.
pub fn weekend(evening: i64) -> bool {
    matches!((evening.rem_euclid(7) + 4) % 7, 5 | 6)
}

/// The estimated end of an evening of this class, in minutes after 18:00.
///
/// One sample per evening, the max of its stamps: a bulk import that lands a
/// hundred stamps in one sitting is one evening's evidence, not a hundred.
pub fn bedtime(ends: &[i64], tz_offset_secs: i32, now: i64, weekend_class: bool) -> u32 {
    let mut per_evening: std::collections::HashMap<i64, u32> = std::collections::HashMap::new();
    for &end in ends {
        if now - end > WINDOW_SECS || end > now {
            continue;
        }
        let Some(evening) = evening_of(end, tz_offset_secs) else {
            continue;
        };
        if weekend(evening) != weekend_class {
            continue;
        }
        let m = minutes_into_evening(end, tz_offset_secs).unwrap();
        let slot = per_evening.entry(evening).or_insert(0);
        *slot = (*slot).max(m);
    }
    let default = if weekend_class {
        DEFAULT_WEEKEND_MIN
    } else {
        DEFAULT_WEEKNIGHT_MIN
    };
    if per_evening.len() < MIN_EVENINGS {
        return default;
    }
    let mut samples: Vec<u32> = per_evening.into_values().collect();
    samples.sort_unstable();
    let at = ((QUANTILE * samples.len() as f32).ceil() as usize).saturating_sub(1);
    samples[at].clamp(CLAMP_MIN, CLAMP_MAX)
}

/// How many runners-up the rail under the trio carries. Ten is about a screen
/// of posters at the size that rail draws them, and past a screenful a list of
/// things to watch stops being a suggestion.
pub const MORE: usize = 10;

/// The three registers of the evening. They say a level of commitment rather
/// than a mood: what is already known and loved, what the taste says next, and
/// what it deliberately does not. The numbers are what `tonight_pick` stores;
/// the cards come out safe bet first, gamble, then the familiar.
pub const ROLE_FAMILIAR: u32 = 0;
pub const ROLE_SAFE: u32 = 1;
pub const ROLE_GAMBLE: u32 = 2;

/// How many places of the taste ranking count as one band, within which the
/// evening is free to prefer the title that fills it best.
///
/// Eight: deep enough that there is a real choice of runtimes inside a band,
/// shallow enough that relevance still decides. Ranking on fit alone would
/// hand every evening to whatever film happens to be the length of the gap,
/// which is not a recommendation.
const FIT_BAND: usize = 8;

/// How many plays of one evening class the history needs before that class
/// gets to choose the tastes on its own. Below it the whole history decides,
/// which is what happened before there was a class at all. A slot of the day
/// needs the same before it is heard over its class.
const MIN_CLASS_PLAYS: u32 = 12;

/// Where in the day a moment falls, as the taste reads it: a class of day and
/// a band of hours. The class is the one `weekend` gives an evening, and for
/// the daytime Saturday and Sunday. The bands are the daytime, the start of
/// the evening (18:00-21:00), its heart (21:00-23:00) and late (23:00-06:00):
/// what someone watches at seven with dinner is rarely what they watch at
/// eleven.
pub fn slot(at: i64, tz_offset_secs: i32) -> (bool, u8) {
    match evening_of(at, tz_offset_secs) {
        Some(evening) => {
            let band = match minutes_into_evening(at, tz_offset_secs).unwrap() {
                0..180 => 1,
                180..300 => 2,
                _ => 3,
            };
            (weekend(evening), band)
        }
        None => {
            let day = (at + i64::from(tz_offset_secs)).div_euclid(86_400);
            // 1970-01-01 was a Thursday: 2 is a Saturday, 3 a Sunday
            (matches!(day.rem_euclid(7), 2 | 3), 0)
        }
    }
}

/// How many evenings a card's showings are remembered. Every evening a title
/// was a card and was not launched sinks it one band (see `fit`), and every
/// two it sat in the lane under the trio, so a title ignored night after night
/// gives way; a month away and it starts afresh.
pub const FATIGUE_EVENINGS: i64 = 30;

/// What a title with no score is worth beside the scored ones, on the same
/// nought-to-one scale: about the middle of what the sources give a library.
const UNRATED: f64 = 0.65;

/// Why a role has no card tonight. The block says which, rather than hiding:
/// "no time left for a discovery" is an answer a viewer can act on, and an
/// empty screen is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gap {
    /// The role had candidates and every one of them runs past bedtime.
    NoTime,
    /// The role had nothing to offer at all: the facet is spent, or the
    /// fingerprint is too thin to have one.
    Exhausted,
}

/// One card of the trio. `seed` names the watched title the role argues
/// from, and is empty on a discovery. `runtime_secs` is one episode's for a
/// show (`episode` says so), a film's otherwise.
#[derive(Debug)]
pub struct TonightRow {
    pub title: TitleRow,
    pub role: u32,
    pub seed: String,
    /// How many times this was played through, and when it last was. Both
    /// nought on every role but the familiar, which is what they describe.
    pub plays: u32,
    pub last_watched_at: i64,
    /// What this card costs of the evening: a film's length, one episode's for
    /// a show, and what is LEFT of either when the card is a continuation.
    pub runtime_secs: f64,
    pub episode: bool,
    /// How close to the taste this sits, 0 to 1, for the discovery alone: the
    /// card that argues from nothing otherwise. 0 on every other role.
    pub closeness: f32,
    /// The file to carry on with and where it stopped, for a continuation.
    /// None starts at the beginning, which is every other role.
    pub resume: Option<Resume>,
}

/// Where a continuation picks up. `season` and `episode` are the numbers the
/// index gave the file, absent on a film and on an episode nothing numbered.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Resume {
    pub file_id: i64,
    pub position_secs: f64,
    pub season: Option<u16>,
    pub episode: Option<u16>,
}

/// The session's trio, and the bedtime it was cut against, in minutes after
/// the session's start: 18:00 local, or 13:00 on an afternoon.
#[derive(Debug)]
pub struct Trio {
    pub cards: Vec<TonightRow>,
    /// The candidates the safe bet and the gamble did not take, best first
    /// and mixed across the two rather than served a facet at a time.
    ///
    /// Not a second query: these are the very rows the trio was chosen from,
    /// so they carry the same ranking and the same refusals - nothing
    /// deferred, nothing already seen, nothing that would run past bedtime -
    /// without a line of SQL of their own. What they drop is the staging: a
    /// role, a reason and a finishing time are worth three cards of the
    /// screen, and are noise on the tenth.
    pub more: Vec<TitleRow>,
    /// The roles with no card tonight, and why. Empty on a full trio.
    pub gaps: Vec<(u32, Gap)>,
    pub bedtime_min: u32,
    /// How many refusals the evening has left.
    pub passes_left: u32,
    /// A weekend afternoon's trio rather than an evening's.
    pub afternoon: bool,
}

/// The durations a card's runtime is judged on, one correlated subquery deep
/// (SQLite refuses `t.id` any deeper): `runtime_of` turns the list into a
/// film's longest file or a show's median episode - the commitment of one
/// evening, not of a season.
pub(crate) const RUNTIME: &str = "(SELECT GROUP_CONCAT(c.duration_secs) FROM files c
       WHERE c.title_id = t.id AND c.duration_secs > 0)";

/// The score a card is judged on beside its fit, off `metadata m` joined on
/// the title: the audience's where a source gave one, the critics' otherwise,
/// both on the 0-10 scale `metadata` keeps, and the voters behind that same
/// score.
const RATING: &str = "CASE WHEN m.audience_source <> '' THEN m.audience_rating
                     WHEN m.critic_source <> '' THEN m.critic_rating END AS rating,
    CASE WHEN m.audience_source <> '' THEN m.audience_votes
         WHEN m.critic_source <> '' THEN m.critic_votes END AS votes";

/// A score pulled towards the library's mean by how few voted for it, on a
/// nought-to-one scale. An unknown count weighs as `BAYES_VOTES`, so the
/// score counts for half.
fn quality_of(rating: Option<f64>, votes: Option<u32>, mean: f64) -> f64 {
    rating.map_or(UNRATED, |r| {
        let v = votes.map_or(BAYES_VOTES, f64::from);
        ((v * r + BAYES_VOTES * mean) / (v + BAYES_VOTES) / 10.0).clamp(0.0, 1.0)
    })
}

pub(crate) fn runtime_of(durations: Option<String>, episode: bool) -> f64 {
    let mut list: Vec<f64> = durations
        .map(|s| s.split(',').filter_map(|d| d.parse().ok()).collect())
        .unwrap_or_default();
    if list.is_empty() {
        return 0.0;
    }
    list.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if episode {
        list[(list.len() - 1) / 2]
    } else {
        *list.last().unwrap()
    }
}

/// A title's place in the gamble's turn for one session: the avalanche
/// `rows::SHUFFLE` deals the rows with, in Rust, seeded by the session.
pub(crate) fn turn(title_id: i64, session: i64) -> i64 {
    const MASK: i64 = 1_073_741_823;
    let d = session.wrapping_mul(2_654_435_761);
    let s = (title_id ^ d) & MASK;
    let u = ((s + (s >> 15)) * 2_246_822_519) & MASK;
    ((u + (u >> 13)) * 3_266_489_917) & MASK
}

// The same never-launched shape as rows.rs's PICKED: any watch_state row on a
// title's files spends it, a verdict spends it, and a live deferral keeps it
// out for DEFER_SECS.
static TASTE_CANDIDATES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    l.name, 0.0, {RUNTIME} AS durations, tt.facet, {RATING}
  FROM taste_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  LEFT JOIN titles l ON l.id = p.leader
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE p.facet = ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank"
    )
});

/// One title by id, whichever pool dealt it or none, under the same refusals:
/// what keeps a frozen safe bet when the hour or the variety moves the
/// leading taste, and what brings in a title the viewer queued. The seed is
/// its taste pick's leader, else the leader of the taste it sits nearest.
static SAFE_BY_ID: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    COALESCE(pl.name, l.name), 0.0, {RUNTIME} AS durations, tt.facet, {RATING}
  FROM titles t
  LEFT JOIN taste_pick p ON p.title_id = t.id
  LEFT JOIN titles pl ON pl.id = p.leader
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  LEFT JOIN taste_facet tf ON tf.facet = tt.facet
  LEFT JOIN titles l ON l.id = tf.leader
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE t.id = ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)"
    )
});

/// The safe bet under a mood: the library against the mood's anchor, which
/// already leans to the taste, under the same refusals. The seed is the
/// leader of the taste the title sits nearest, empty when it sits near none.
static MOOD_CANDIDATES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    l.name, 0.0, {RUNTIME} AS durations, tt.facet, {RATING}
  FROM seasonal_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  LEFT JOIN taste_facet tf ON tf.facet = tt.facet
  LEFT JOIN titles l ON l.id = tf.leader
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE p.window = ?2
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND NOT EXISTS (SELECT 1 FROM stage_show s WHERE s.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank"
    )
});

/// The safe bet with a guest: what both would watch, the lesser of the two
/// tastes first (see `duo`), under the same refusals. The seed is the leader
/// of the owner's taste the title sits in.
static GUEST_CANDIDATES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    l.name, 0.0, {RUNTIME} AS durations, tt.facet, {RATING}
  FROM guest_taste g
  CROSS JOIN titles t ON t.id = g.title_id
  CROSS JOIN title_taste tt ON tt.title_id = t.id
  LEFT JOIN taste_facet tf ON tf.facet = tt.facet
  LEFT JOIN titles l ON l.id = tf.leader
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE g.guest_id = ?2 AND tt.affinity >= {veto}
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM guest_verdict gv
                    WHERE gv.guest_id = g.guest_id AND gv.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY MIN(g.cos, tt.affinity) DESC, t.id
  LIMIT {limit}",
        veto = super::duo::VETO,
        limit = super::taste::PICKS,
    )
});

static DISCOVERY_CANDIDATES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    NULL, p.closeness, {RUNTIME} AS durations, tt.facet, {RATING}
  FROM discovery_pick p
  CROSS JOIN titles t ON t.id = p.title_id
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)
  ORDER BY p.rank"
    )
});

/// What the viewer has already watched through and may want again.
///
/// The exclusions are the mirror of the taste pools beside it: there a
/// watch_state row spends a candidate, here it is what makes one. A stated
/// refusal ends it for good, and a live deferral keeps it out like anywhere
/// else. Ordering is left to the score, which SQL cannot express.
static FAMILIAR_CANDIDATES: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT t.id, t.kind, t.name, t.year,
    (SELECT COUNT(*) FROM files c WHERE c.title_id = t.id) AS file_count,
    (SELECT c.id FROM files c WHERE c.title_id = t.id ORDER BY c.quality DESC, c.id LIMIT 1) AS first_file_id,
    w.plays, w.touched, COALESCE(v.verdict, 0), {RUNTIME} AS durations, {RATING}
  FROM titles t
  CROSS JOIN (SELECT f.title_id AS title_id,
                     MAX(s.plays) AS plays,
                     MAX(s.updated_at) AS touched
                FROM watch_state s CROSS JOIN files f ON f.id = s.file_id
               WHERE s.watched = 1
               GROUP BY f.title_id) w ON w.title_id = t.id
  LEFT JOIN title_verdict v ON v.title_id = t.id
  LEFT JOIN metadata m ON m.title_id = t.id
  WHERE COALESCE(v.verdict, 0) >= 0
    AND w.touched <= ?2
    AND NOT EXISTS (SELECT 1 FROM watchlist wl WHERE wl.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM tonight_deferred td
                    WHERE td.title_id = t.id AND td.deferred_at > ?1)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)"
    )
});

/// How long a title must have been away before it can be offered back at
/// all. The score alone would not do it: a film finished an hour ago scores
/// near nought, and near nought still leads a pool that holds nothing else.
/// A quarter is the shortest gap over which "I have not seen this in a
/// while" is a true sentence.
pub const FAMILIAR_REST_SECS: i64 = 90 * 86_400;

/// How long a title has to stay away before it is worth an evening again.
/// A year: the shape saturates, so two years out is near its ceiling and a
/// month out is worth almost nothing.
pub const FAMILIAR_HALF_LIFE_DAYS: f64 = 365.0;

/// What a stated verdict is worth next to a play, on the same scale. A thumb
/// up is a sentence about the whole title; a play is a sentence about one
/// evening, and two evenings is about what the thumb is worth.
pub const FAMILIAR_LOVED: f64 = 2.0;

/// Two quantities multiplied: how attached the viewer is, and how long it has
/// been away.
///
/// Recency is a penalty here, which is the opposite of every other ranking in
/// this crate. A film watched last month is not a rewatch, whatever it is
/// worth otherwise, and one loved four years ago is the whole point.
fn familiar_score(plays: u32, verdict: i64, since_secs: i64) -> f64 {
    let attachment = f64::from(plays) + verdict.max(0) as f64 * FAMILIAR_LOVED;
    let days = since_secs.max(0) as f64 / 86_400.0;
    attachment * (1.0 - (-days / FAMILIAR_HALF_LIFE_DAYS).exp())
}

struct Candidate {
    title: TitleRow,
    seed: String,
    runtime_secs: f64,
    episode: bool,
    closeness: f32,
    /// The title's score on a nought-to-one scale, `UNRATED` when none.
    quality: f64,
    /// The taste the title sits nearest, None when it sits near none.
    facet: Option<u32>,
    resume: Option<Resume>,
    plays: u32,
    last_watched_at: i64,
}

impl Candidate {
    fn card(self, role: u32) -> TonightRow {
        TonightRow {
            title: self.title,
            role,
            seed: self.seed,
            plays: self.plays,
            last_watched_at: self.last_watched_at,
            runtime_secs: self.runtime_secs,
            episode: self.episode,
            closeness: self.closeness,
            resume: self.resume,
        }
    }
}

/// Reads one of the new-title pools. Their queries lay their columns out the
/// same way from the seventh on: the seed's name (or none), the closeness to
/// the taste, the durations, the facet, the score and its voters.
fn pool(
    db: &Db,
    sql: &str,
    params: impl rusqlite::Params,
    mean: f64,
) -> Result<Vec<Candidate>, IndexError> {
    let mut stmt = db.conn().prepare_cached(sql)?;
    let rows = stmt.query_map(params, |r| {
        let title = row_to_title(r)?;
        let episode = title.kind == MediaKind::Show;
        Ok(Candidate {
            title,
            seed: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
            closeness: r.get(7)?,
            runtime_secs: runtime_of(r.get(8)?, episode),
            episode,
            facet: r.get(9)?,
            quality: quality_of(r.get(10)?, r.get(11)?, mean),
            resume: None,
            plays: 0,
            last_watched_at: 0,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// One session's composition before anything is written: the cards in role
/// order and what each role's pool had left, in the order it ranked them.
struct Composition {
    session: i64,
    cards: Vec<TonightRow>,
    /// Safe bet's, gamble's and familiar's, in that order; the familiar's is
    /// always empty, the lane being about tonight's new titles.
    leftovers: [Vec<Candidate>; 3],
    gaps: Vec<(u32, Gap)>,
    bedtime_min: u32,
    stored: HashMap<u32, i64>,
    exposure: HashMap<i64, super::db::Exposure>,
    /// What the queue holds, as (title, when it was queued), oldest first.
    queued: Vec<(i64, i64)>,
}

/// This session's trio, or None: outside evening hours and weekend
/// afternoons, or when not one of the three roles can be filled.
///
/// A role that cannot be filled no longer takes the block down with it. It
/// comes back as a gap saying why, because "there is no time left for a
/// discovery" is something a viewer can act on - by going to bed later, which
/// this block now lets them say - and a screen that silently reverts to the
/// daytime hero is not.
///
/// The trio freezes per session: a stored pick keeps its slot for as long as
/// it still qualifies, and only the duration gate or a death (launched,
/// deferred, unshelved) replaces it - with the next candidate of its own
/// role, the others untouched. Everything that only reorders (the turn of the
/// gamble, the week's variety, the ambient, the sitting's browsing) therefore
/// never moves a card already shown; a mood or a company set by the viewer
/// clears the freeze on purpose.
pub fn tonight(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    ambient: Option<Ambient>,
) -> Result<Option<Trio>, IndexError> {
    let Some((trio, record)) = compose_tonight(db, now, tz_offset_secs, ambient)? else {
        return Ok(None);
    };
    record_tonight(db, &record)?;
    Ok(Some(trio))
}

/// What showing a composed trio changes: the freeze when its picks moved, the
/// exposure of what the session had not shown yet, and the queue it spends.
pub struct TonightRecord {
    session: i64,
    now: i64,
    picks: Option<Vec<(u32, i64)>>,
    new_cards: Vec<(u32, i64)>,
    new_lane: Vec<i64>,
    consumed: Vec<i64>,
}

/// `tonight` without a write: the trio, and what showing it would record. A
/// reader that only looks, like the Top Shelf, drops the record.
pub fn compose_tonight(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    ambient: Option<Ambient>,
) -> Result<Option<(Trio, TonightRecord)>, IndexError> {
    let Some(c) = compose(db, now, tz_offset_secs, ambient)? else {
        return Ok(None);
    };
    // Three empty roles is not a thin evening, it is no evening: the block has
    // nothing at all to say and the daytime hero is the honest screen.
    if c.cards.is_empty() {
        return Ok(None);
    }
    let session = c.session;
    // Round robin across the roles, so the rail opens on a spread of the
    // evening's reasons rather than on the safe facet's own tail.
    let mut used: HashSet<i64> = c.cards.iter().map(|c| c.title.id).collect();
    let mut lane: Vec<&Candidate> = Vec::new();
    let deepest = c.leftovers.iter().map(Vec::len).max().unwrap_or(0);
    for depth in 0..deepest {
        for pool in &c.leftovers {
            if let Some(candidate) = pool.get(depth) {
                if used.insert(candidate.title.id) {
                    lane.push(candidate);
                }
            }
        }
    }
    // A sitting spent opening the pages of one taste is a sitting about that
    // taste: the lane leads with it. The cards stay where they are.
    if let Some(facet) = db.browsed_facet(now - BROWSE_SECS, BROWSE_MIN)? {
        lane.sort_by_key(|c| c.facet != Some(facet));
    }
    let more: Vec<TitleRow> = lane
        .into_iter()
        .take(MORE)
        .map(|c| c.title.clone())
        .collect();
    // The home asks again every minute, so each write happens only when the
    // session actually changed: a new card, or a title the lane had not shown.
    let mut picks: Vec<(u32, i64)> = c.cards.iter().map(|c| (c.role, c.title.id)).collect();
    picks.sort_unstable();
    let mut frozen: Vec<(u32, i64)> = c.stored.into_iter().collect();
    frozen.sort_unstable();
    // by what the session has recorded as shown, not by the exposure date: a
    // duel's loser carries this session's date without having been a card
    let shown = db.tonight_shown(session)?;
    let new_cards: Vec<(u32, i64)> = c
        .cards
        .iter()
        .map(|c| (c.role, c.title.id))
        .filter(|(_, id)| !shown.contains(id))
        .collect();
    let new_lane: Vec<i64> = more
        .iter()
        .map(|t| t.id)
        .filter(|id| c.exposure.get(id).is_none_or(|e| e.last_lane != session))
        .collect();
    let consumed: Vec<i64> = picks
        .iter()
        .map(|&(_, id)| id)
        .filter(|id| c.queued.iter().any(|(queued, _)| queued == id))
        .collect();
    let trio = Trio {
        cards: c.cards,
        more,
        gaps: c.gaps,
        bedtime_min: c.bedtime_min,
        passes_left: passes_left(db, now, tz_offset_secs)?,
        afternoon: session < 0,
    };
    let record = TonightRecord {
        session,
        now,
        picks: (picks != frozen).then_some(picks),
        new_cards,
        new_lane,
        consumed,
    };
    Ok(Some((trio, record)))
}

/// Writes what `compose_tonight` found. Every part is idempotent within a
/// session, so a record composed on a reader a moment ago is still safe.
pub fn record_tonight(db: &Db, r: &TonightRecord) -> Result<(), IndexError> {
    if let Some(picks) = &r.picks {
        db.replace_tonight_picks(r.session, picks, r.now)?;
    }
    if !r.new_cards.is_empty() || !r.new_lane.is_empty() {
        db.record_tonight_exposure(r.session, &r.new_cards, &r.new_lane, FATIGUE_EVENINGS)?;
    }
    for title_id in &r.consumed {
        db.consume_queued(*title_id)?;
    }
    Ok(())
}

/// Two titles to choose between, off the safe bet's and the gamble's pools:
/// both fit what is left of the session, neither is one of its cards nor in
/// `exclude`, and they come from two tastes when the pools hold two. None
/// when the session is over or the pools hold fewer than two. Reads only: the
/// trio it steps around is the one `tonight` shows or would.
pub fn this_or_that(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    ambient: Option<Ambient>,
    exclude: &[i64],
) -> Result<Option<(TonightRow, TonightRow)>, IndexError> {
    let Some(c) = compose(db, now, tz_offset_secs, ambient)? else {
        return Ok(None);
    };
    let mut taken: HashSet<i64> = c.cards.iter().map(|c| c.title.id).collect();
    taken.extend(exclude);
    let [safe, gamble, _] = c.leftovers;
    let mut safe = safe.into_iter().map(|c| (ROLE_SAFE, c));
    let mut gamble = gamble.into_iter().map(|c| (ROLE_GAMBLE, c));
    // alternated like the lane, so the first duel sets the taste against
    // the stranger when both have something
    let mut offer: Vec<(u32, Candidate)> = Vec::new();
    loop {
        let (a, b) = (safe.next(), gamble.next());
        if a.is_none() && b.is_none() {
            break;
        }
        for (role, candidate) in a.into_iter().chain(b) {
            if taken.insert(candidate.title.id) {
                offer.push((role, candidate));
            }
        }
    }
    if offer.len() < 2 {
        return Ok(None);
    }
    let facet = offer[0].1.facet;
    let other = offer[1..]
        .iter()
        .position(|(_, c)| c.facet != facet)
        .map_or(1, |at| at + 1);
    let (right_role, right) = offer.swap_remove(other);
    let (left_role, left) = offer.swap_remove(0);
    Ok(Some((left.card(left_role), right.card(right_role))))
}

/// The answer to one duel: the winner is a title the viewer leaned towards,
/// which the fingerprint weighs at the next refresh, and the loser tires like
/// a card passed over.
pub fn choose(
    db: &Db,
    winner: i64,
    loser: i64,
    now: i64,
    tz_offset_secs: i32,
) -> Result<(), IndexError> {
    db.record_interest(winner, super::db::TASTE_CHOSEN, now)?;
    if let Some(session) = session_of(now, tz_offset_secs) {
        db.tire_tonight(loser, session, FATIGUE_EVENINGS)?;
    }
    Ok(())
}

fn compose(
    db: &Db,
    now: i64,
    tz_offset_secs: i32,
    ambient: Option<Ambient>,
) -> Result<Option<Composition>, IndexError> {
    let Some(window) = Window::of(db, now, tz_offset_secs, None)? else {
        return Ok(None);
    };
    let Window {
        session,
        now_min,
        bedtime_min,
        ..
    } = window;
    let day = session_day(session);
    let facets = db.taste_facets()?;
    let together = window.answers.together;
    let deferred_after = now - DEFER_SECS;
    // the pass's measure, or a live one until a pass has stored it; empty
    // when the library scores nothing
    let mean = match db.setting(RATING_MEAN_SETTING)? {
        Some(stored) => stored.parse().ok(),
        None => db.mean_rating()?,
    }
    .unwrap_or(UNRATED * 10.0);
    let mood = window.answers.mood.as_deref();

    // No facet is not a reason to have no evening: the familiar role argues
    // from the history alone, and a library with no model downloaded still
    // has one card it can defend.
    let safe_facet = if facets.is_empty() {
        None
    } else {
        let ends = db.watched_facet_ends()?;
        let order = facet_order(&ends, &facets, tz_offset_secs, now);
        // Variety: two evenings running spent on the leading taste, and
        // tonight's safe bet comes from the next one. Only the evenings count:
        // an afternoon is the same day's warm-up, not a night of its own.
        let mut evenings = [false; 2];
        let mut strayed = false;
        for &(facet, end) in &ends {
            let Some(back) = evening_of(end, tz_offset_secs).map(|e| day - e) else {
                continue;
            };
            if (1..=2).contains(&back) && end <= now {
                evenings[back as usize - 1] = true;
                strayed |= facet != order[0];
            }
        }
        match order.get(1) {
            Some(&next) if evenings == [true, true] && !strayed => Some(next),
            _ => Some(order[0]),
        }
    };

    // With a guest the safe bet is what both would watch; under a mood it is
    // the mood's own list, which already leans to the taste; either with
    // nothing left falls back to the next, and the taste answers last.
    let guest = window.answers.guest_id;
    let mut safe: Vec<Candidate> = match guest {
        Some(guest) => pool(db, &GUEST_CANDIDATES, params![deferred_after, guest], mean)?,
        None => Vec::new(),
    };
    if let (true, Some(key)) = (safe.is_empty(), mood) {
        safe = pool(db, &MOOD_CANDIDATES, params![deferred_after, key], mean)?;
    }
    if safe.is_empty() {
        if let Some(safe_facet) = safe_facet {
            safe = pool(
                db,
                &TASTE_CANDIDATES,
                params![deferred_after, safe_facet],
                mean,
            )?;
            // a taste pick names its facet's leader, and one without a
            // leader has nothing to argue from
            safe.retain(|c| !c.seed.is_empty());
        }
    }
    // The freeze outranks every reordering of the tastes: a safe bet already
    // shown this session stays while it still qualifies, whatever taste the
    // hour or the variety leads with now.
    let picks = db.tonight_picks(session)?;
    let frozen_at = picks.first().map(|&(_, _, at)| at);
    let stored: HashMap<u32, i64> = picks.into_iter().map(|(role, id, _)| (role, id)).collect();
    // What last night's credits proposed and a duel's keep are each a yes
    // said about tonight, whatever pool they came from: they join the safe
    // bet's.
    let queued = db.queued_tonight(now - QUEUE_LIFE_SECS)?;
    for id in stored
        .get(&ROLE_SAFE)
        .into_iter()
        .chain(queued.iter().map(|(id, _)| id))
    {
        if !safe.iter().any(|c| c.title.id == *id) {
            safe.extend(pool(db, &SAFE_BY_ID, params![deferred_after, id], mean)?);
        }
    }
    let mut discovery = pool(db, &DISCOVERY_CANDIDATES, params![deferred_after], mean)?;
    if together {
        discovery.retain(|c| c.closeness >= GAMBLE_TOGETHER_FLOOR);
    }
    // a stranger both could take a chance on: the guest's veto holds here too
    if let Some(accepted) = guest
        .map(|g| db.guest_discoveries(g))
        .transpose()?
        .flatten()
    {
        discovery.retain(|c| accepted.contains(&c.title.id));
    }
    discovery.retain(|c| c.quality >= GAMBLE_QUALITY_FLOOR);
    // The gamble turns: the head of the band in a new order each session,
    // the same one all session long.
    let head = discovery.len().min(GAMBLE_WINDOW);
    discovery[..head].sort_by_key(|c| turn(c.title.id, session));

    // What the viewer is already in the middle of is the queue's work, drawn
    // under the trio with its own progress bar. Offering it as a card too
    // would say the same thing twice on a screen that says very little.
    //
    // A queued title leads the safe bet. It stays a candidate like the others
    // - the duration gate can still refuse it - and the evening that shows it
    // spends it.
    if !queued.is_empty() {
        safe.sort_by_key(|c| !queued.iter().any(|(id, _)| *id == c.title.id));
    }
    // Queueing is an explicit act, which the freeze gives way to: the latest
    // title queued since the trio froze (or at all, before it has) takes the
    // safe bet over both the stored pick and the fit. One queued before the
    // freeze had its chance and waits.
    let newer: Vec<i64> = queued
        .iter()
        .rev()
        .filter(|(_, at)| !stored.contains_key(&ROLE_SAFE) || frozen_at.is_none_or(|f| *at > f))
        .map(|(id, _)| *id)
        .collect();

    let mut familiar: Vec<Candidate> = {
        let mut stmt = db.conn().prepare_cached(&FAMILIAR_CANDIDATES)?;
        let rows = stmt.query_map(params![deferred_after, now - FAMILIAR_REST_SECS], |r| {
            let title = row_to_title(r)?;
            let episode = title.kind == MediaKind::Show;
            let plays: u32 = r.get(6)?;
            let last_watched_at: i64 = r.get(7)?;
            let verdict: i64 = r.get(8)?;
            Ok((
                familiar_score(plays, verdict, now - last_watched_at),
                Candidate {
                    title,
                    seed: String::new(),
                    runtime_secs: runtime_of(r.get(9)?, episode),
                    episode,
                    closeness: 0.0,
                    quality: quality_of(r.get(10)?, r.get(11)?, mean),
                    facet: None,
                    resume: None,
                    plays,
                    last_watched_at,
                },
            ))
        })?;
        let mut scored: Vec<(f64, Candidate)> = rows.collect::<Result<_, _>>()?;
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        scored.into_iter().map(|(_, c)| c).collect()
    };

    // A mood also leads the gamble with the strangers in its mood, and the
    // familiar with what was already loved in it, each in the mood's order.
    if let Some(key) = mood {
        let listed: HashMap<i64, usize> = db
            .seasonal_titles(key)?
            .into_iter()
            .enumerate()
            .map(|(at, id)| (id, at))
            .collect();
        discovery.sort_by_key(|c| listed.get(&c.title.id).copied().unwrap_or(usize::MAX));
        let seen: HashMap<i64, usize> = db
            .seasonal_titles(&format!("seen:{key}"))?
            .into_iter()
            .enumerate()
            .map(|(at, id)| (id, at))
            .collect();
        familiar.sort_by_key(|c| seen.get(&c.title.id).copied().unwrap_or(usize::MAX));
    }

    // Film or series: what this slot of the week has finished says which
    // kind of safe bet it wants, once it has finished enough to say.
    let lift = {
        let here = slot(now, tz_offset_secs);
        let (mut episodes, mut total) = (0u32, 0u32);
        for (episode, end) in db.finished_kinds(now - WINDOW_SECS)? {
            if end <= now && slot(end, tz_offset_secs) == here {
                total += 1;
                episodes += u32::from(episode);
            }
        }
        let share = episodes as f32 / total.max(1) as f32;
        match total >= MIN_CLASS_PLAYS {
            true if share > SERIES_SHARE => Some(true),
            true if share < FILM_SHARE => Some(false),
            _ => None,
        }
    };

    let nudged: HashSet<i64> = match ambient {
        Some(ambient) => {
            let mut ids = HashSet::new();
            for key in ambient_moods(ambient) {
                ids.extend(db.seasonal_titles(key)?);
            }
            ids
        }
        None => HashSet::new(),
    };

    let exposure = db.tonight_exposure()?;
    // the sessions each title has been shown and not been launched, this one
    // aside: the freeze already keeps its own cards where they are, and the
    // lane must not reshuffle under the viewer within the session
    let tired: HashMap<i64, u32> = exposure
        .iter()
        .map(|(id, e)| {
            let cards = if day - session_day(e.last_card) <= FATIGUE_EVENINGS {
                e.cards - u32::from(e.last_card == session)
            } else {
                0
            };
            let lanes = if day - session_day(e.last_lane) <= FATIGUE_EVENINGS {
                // saturating: a lane date set by a card showing can stand
                // with no lane counted
                let tonight = e.last_lane == session && e.last_card != session;
                e.lanes.saturating_sub(u32::from(tonight))
            } else {
                0
            };
            (*id, cards + lanes / 2)
        })
        .filter(|(_, tired)| *tired > 0)
        .collect();
    let mut used: HashSet<i64> = HashSet::new();
    let mut cards = Vec::with_capacity(3);
    let mut gaps: Vec<(u32, Gap)> = Vec::new();
    let mut leftovers: [Vec<Candidate>; 3] = Default::default();
    // The safe bet leads: it is the first title the home lights, and the
    // answer to "what tonight" is something new before it is a rewatch.
    for (at, (role, pool)) in [
        (ROLE_SAFE, safe),
        (ROLE_GAMBLE, discovery),
        (ROLE_FAMILIAR, familiar),
    ]
    .into_iter()
    .enumerate()
    {
        let offered = pool.len();
        let qualifying: Vec<Candidate> = pool
            .into_iter()
            .filter(|c| window.fits(c.runtime_secs) && !used.contains(&c.title.id))
            .collect();
        if qualifying.is_empty() {
            // a role with candidates and no room is a different sentence from
            // a role with nothing left, and the block says which
            gaps.push((
                role,
                if offered == 0 {
                    Gap::Exhausted
                } else {
                    Gap::NoTime
                },
            ));
            continue;
        }
        let lift = if role == ROLE_SAFE { lift } else { None };
        let mut qualifying = fit(qualifying, now_min, bedtime_min, &tired, lift, &nudged);
        // the freeze: rank order decides only when the stored pick is gone
        let queued_pick = match role {
            ROLE_SAFE => newer
                .iter()
                .find_map(|k| qualifying.iter().position(|c| c.title.id == *k)),
            _ => None,
        };
        let pick = queued_pick
            .or_else(|| {
                stored
                    .get(&role)
                    .and_then(|k| qualifying.iter().position(|c| c.title.id == *k))
            })
            .unwrap_or(0);
        // `remove` and not `swap_remove`: the pool arrived in rank order and
        // the rest of it is offered below as the runners-up, so the order has
        // to survive the pick. The pools are a screenful, not a library.
        let picked = qualifying.remove(pick);
        used.insert(picked.title.id);
        // what was already seen stays out of the runners-up: the lane is
        // about tonight's new titles, and the rewatches have a row of their own
        if role != ROLE_FAMILIAR {
            leftovers[at] = qualifying;
        }
        cards.push(picked.card(role));
    }
    Ok(Some(Composition {
        session,
        cards,
        leftovers,
        gaps,
        bedtime_min,
        stored,
        exposure,
        queued,
    }))
}

/// What is left of one session: where the clock stands in it, when it ends
/// and how far past that a title may run. The trio's cards are held to
/// that gate.
pub(crate) struct Window {
    pub session: i64,
    /// Minutes since the session started, and when it ends, on the same scale.
    pub now_min: u32,
    pub bedtime_min: u32,
    pub tolerance: u32,
    pub answers: super::db::EveningAnswers,
}

impl Window {
    /// None outside evening hours and weekend afternoons. `known_bedtime` is
    /// a bedtime already worked out this minute, which is taken as it is.
    pub(crate) fn of(
        db: &Db,
        now: i64,
        tz_offset_secs: i32,
        known_bedtime: Option<u32>,
    ) -> Result<Option<Window>, IndexError> {
        let Some(session) = session_of(now, tz_offset_secs) else {
            return Ok(None);
        };
        let now_min = ((now - session_span(session, tz_offset_secs).0) / 60) as u32;
        let answers = db.evening_state(session)?;
        // a corrected window beats the estimator, in both directions: the
        // viewer knows what is left of their own evening
        let bedtime_min = match (known_bedtime, answers.window_min) {
            (Some(known), _) => known,
            (None, Some(window)) => now_min + window,
            (None, None) if session < 0 => DEFAULT_AFTERNOON_END_MIN,
            (None, None) => bedtime(&db.watch_ends()?, tz_offset_secs, now, weekend(session)),
        };
        let tolerance = if answers.together {
            TOLERANCE_TOGETHER_MIN
        } else {
            TOLERANCE_MIN
        };
        Ok(Some(Window {
            session,
            now_min,
            bedtime_min,
            tolerance,
            answers,
        }))
    }

    /// Whether something of this length, started now, ends in time. A length
    /// nobody measured never fits: the promise is that it ends before bed.
    pub(crate) fn fits(&self, runtime_secs: f64) -> bool {
        runtime_secs > 0.0
            && self.now_min + minutes_of(runtime_secs) <= self.bedtime_min + self.tolerance
    }
}

/// A runtime as the whole minutes an evening has to hold.
fn minutes_of(runtime_secs: f64) -> u32 {
    (runtime_secs / 60.0).ceil() as u32
}

/// Reorders a role's qualifying candidates so that, within one band of the
/// taste ranking, the one that best fills what is left of the evening, and is
/// best thought of, leads. Each evening a title was a card without being
/// launched, and each two it sat in the lane, (`tired`) sinks it one band;
/// when the slot of the week has a kind (`lift`: series or not), the other
/// kind sinks one. A title of a mood the ambient leans to (`nudged`) gains a
/// little inside its band.
///
/// The gate above only ever answered "does this fit". Two titles that both fit
/// are not equally good at nine o'clock with two and a half hours left: a
/// forty-minute film leaves the evening open and a two-hour one is the
/// evening. Relevance still decides between bands, so this can never reach
/// past the band for a title the taste ranked far below.
fn fit(
    pool: Vec<Candidate>,
    now_min: u32,
    bedtime_min: u32,
    tired: &HashMap<i64, u32>,
    lift: Option<bool>,
    nudged: &HashSet<i64>,
) -> Vec<Candidate> {
    let room = f64::from(bedtime_min.saturating_sub(now_min)).max(1.0);
    let mut ranked: Vec<((usize, i64, usize), Candidate)> = pool
        .into_iter()
        .enumerate()
        .map(|(rank, c)| {
            // how much of the room it fills, as a share; a card allowed by the
            // tolerance overshoots and lands just under a perfect fill, which
            // is where it belongs
            let share = f64::from(minutes_of(c.runtime_secs)) / room;
            let fill = share.min(2.0 - share);
            // A continuation is never stepped over for a better fit. What it
            // is worth is that the viewer already started it, and no length
            // outranks that; fit only orders the ones nothing is known about.
            let band = if c.resume.is_some() {
                0
            } else {
                1 + rank / FIT_BAND
                    + tired.get(&c.title.id).copied().unwrap_or(0) as usize
                    + usize::from(lift.is_some_and(|series| series != c.episode))
            };
            let nudge = if nudged.contains(&c.title.id) {
                AMBIENT_NUDGE
            } else {
                0.0
            };
            // fit and score weigh alike, both nought to one; rank last, so a
            // band with nothing to choose between keeps the taste's order
            (
                (band, -((fill + c.quality + nudge) * 10_000.0) as i64, rank),
                c,
            )
        })
        .collect();
    ranked.sort_by_key(|(rank, _)| *rank);
    ranked.into_iter().map(|(_, c)| c).collect()
}

/// The facets strongest first for this moment of the week, falling back to
/// its class of day and then to the order the whole history gives. `ends` is
/// `Db::watched_facet_ends`.
///
/// A viewer whose Saturdays are long films and whose Tuesdays are half-hour
/// comedies has two tastes, and the fingerprint alone cannot tell which of
/// them tonight is. The hour each spent title was watched at can, once there
/// is enough of it: the slot of the day speaks first when it holds
/// `MIN_CLASS_PLAYS`, then the class, then the whole history as before.
pub(crate) fn facet_order(
    ends: &[(u32, i64)],
    facets: &[super::db::TasteFacetMeta],
    tz_offset_secs: i32,
    now: i64,
) -> Vec<u32> {
    let (class, band) = slot(now, tz_offset_secs);
    let mut in_slot: HashMap<u32, u32> = HashMap::new();
    let mut in_class: HashMap<u32, u32> = HashMap::new();
    let (mut slot_total, mut class_total) = (0u32, 0u32);
    for &(facet, end) in ends {
        if now - end > WINDOW_SECS || end > now {
            continue;
        }
        let (their_class, their_band) = slot(end, tz_offset_secs);
        if their_class != class {
            continue;
        }
        *in_class.entry(facet).or_insert(0) += 1;
        class_total += 1;
        if their_band == band {
            *in_slot.entry(facet).or_insert(0) += 1;
            slot_total += 1;
        }
    }
    let counts = if slot_total >= MIN_CLASS_PLAYS {
        in_slot
    } else if class_total >= MIN_CLASS_PLAYS {
        in_class
    } else {
        return facets.iter().map(|f| f.facet).collect();
    };
    let mut order: Vec<u32> = facets.iter().map(|f| f.facet).collect();
    // the whole-history order breaks the ties, which is what keeps a slot
    // with two equal facets answering the same thing every night
    order.sort_by_key(|f| std::cmp::Reverse(counts.get(f).copied().unwrap_or(0)));
    order
}

/// "Not tonight": out of the trio for DEFER_SECS, and out of the frozen
/// evening at once. Never a verdict: the fingerprint hears only a run of them.
/// Refuses one card, unless the evening has spent its budget.
///
/// The core holds the rule rather than trusting the screen to stop offering
/// the gesture: a client that kept drawing the pill would otherwise have an
/// unbounded evening, which is the thing this budget exists to prevent.
pub fn defer(db: &Db, title_id: i64, now: i64, tz_offset_secs: i32) -> Result<(), IndexError> {
    if passes_left(db, now, tz_offset_secs)? == 0 {
        return Ok(());
    }
    db.defer_tonight(title_id, now)
}

/// The span of wall clock one session covers, as unix seconds: 18:00 to
/// 06:00 for an evening, 13:00 to 18:00 for an afternoon.
pub(crate) fn session_span(session: i64, tz_offset_secs: i32) -> (i64, i64) {
    let (start_min, len_min) = if session >= 0 {
        (EVENING_START_MIN, EVENING_LEN_MIN)
    } else {
        (AFTERNOON_START_MIN, AFTERNOON_LEN_MIN)
    };
    let start =
        session_day(session) * 86_400 + i64::from(start_min) * 60 - i64::from(tz_offset_secs);
    (start, start + i64::from(len_min) * 60)
}

/// How many refusals this session has left.
pub fn passes_left(db: &Db, now: i64, tz_offset_secs: i32) -> Result<u32, IndexError> {
    let Some(session) = session_of(now, tz_offset_secs) else {
        return Ok(PASSES);
    };
    let budget = db
        .setting(PASSES_SETTING)?
        .and_then(|v| v.parse().ok())
        .unwrap_or(PASSES);
    let (from, to) = session_span(session, tz_offset_secs);
    Ok(budget.saturating_sub(db.deferrals_between(from, to)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{EveningAnswers, FileMedia, FileRecord, WatchAuthority, WatchRecord};
    use crate::index::{MediaKind, Verdict};

    const DAY: i64 = 86_400;
    /// A Thursday: a weeknight evening, whose default bedtime is 23:15.
    const EVENING: i64 = 20_685;
    /// 21:00 that Thursday, read at tz 0.
    const NOW: i64 = EVENING * DAY + 21 * 3_600;

    fn film(db: &Db, name: &str, secs: f64) -> i64 {
        let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
        file(db, id, &format!("{name}.mkv"), None, secs);
        id
    }

    fn show(db: &Db, name: &str, episodes: &[f64]) -> i64 {
        let id = db.upsert_title(MediaKind::Show, name, None).unwrap();
        for (n, secs) in episodes.iter().enumerate() {
            file(
                db,
                id,
                &format!("{name}.E{n}.mkv"),
                Some((1, n as u16 + 1)),
                *secs,
            );
        }
        id
    }

    fn file(db: &Db, title_id: i64, path: &str, episode: Option<(u16, u16)>, secs: f64) {
        db.upsert_file(&FileRecord {
            source_id: "s1".into(),
            dir: "Media".into(),
            path: format!("Media/{path}"),
            size: 1,
            mtime: 0,
            seen_gen: 1,
            title_id,
            season: episode.map(|(s, _)| s),
            episode: episode.map(|(_, e)| e),
            rating_key: None,
            media: FileMedia::default(),
        })
        .unwrap();
        db.conn()
            .execute(
                "UPDATE files SET duration_secs = ?1 WHERE path = ?2",
                rusqlite::params![secs, format!("Media/{path}")],
            )
            .unwrap();
    }

    fn launched(db: &Db, title_id: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1 LIMIT 1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 600.0,
                duration_secs: 6000.0,
                watched: false,
                plays: 0,
                updated_at: NOW - DAY,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    /// Watched to the end, which is the one death a continuation cannot undo:
    /// there is nothing left of it to carry on with.
    fn finished(db: &Db, title_id: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1 LIMIT 1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 6000.0,
                duration_secs: 6000.0,
                watched: true,
                plays: 0,
                updated_at: NOW - DAY,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    /// Three facets, five taste picks, two discovery picks: enough library
    /// for every role, all films of 100 minutes, which fit a 21:00 start.
    fn library(db: &Db) -> (i64, i64) {
        let leader_a = film(db, "Leader A", 6000.0);
        let leader_b = film(db, "Leader B", 6000.0);
        let leader_c = film(db, "Leader C", 6000.0);
        let safe_one = film(db, "Safe One", 6000.0);
        let safe_two = film(db, "Safe Two", 6000.0);
        let mood = film(db, "Mood", 6000.0);
        let other_one = film(db, "Other One", 6000.0);
        let other_two = film(db, "Other Two", 6000.0);
        let disco_one = film(db, "Disco One", 6000.0);
        let disco_two = film(db, "Disco Two", 6000.0);
        db.replace_taste(&pass(
            [
                pick(safe_one, 0, leader_a),
                pick(mood, 1, leader_b),
                pick(other_one, 2, leader_c),
                pick(safe_two, 0, leader_a),
                pick(other_two, 2, leader_c),
            ],
            meta(leader_a, leader_b, leader_c),
            &[disco_one, disco_two],
        ))
        .unwrap();
        (safe_one, safe_two)
    }

    fn pick(title_id: i64, facet: u32, leader: i64) -> crate::index::db::TastePick {
        crate::index::db::TastePick {
            title_id,
            facet,
            leader,
        }
    }

    /// One pass's worth of output, as these tests state it: the row, the
    /// facets behind it, and the discovery band by title id alone - what the
    /// trio reads. The band's closeness is the middle of the band, which is
    /// where a pick with nothing to say about its own distance belongs.
    fn pass(
        picks: impl Into<Vec<crate::index::db::TastePick>>,
        facets: impl Into<Vec<crate::index::db::TasteFacetMeta>>,
        discovery: &[i64],
    ) -> crate::index::db::TastePassOutput {
        crate::index::db::TastePassOutput {
            picks: picks.into(),
            facets: facets.into(),
            discovery: discovery
                .iter()
                .map(|title_id| crate::index::db::DiscoveryPick {
                    title_id: *title_id,
                    closeness: 0.5,
                })
                .collect(),
            ..Default::default()
        }
    }

    /// Facet 1 is second by weight, facet 2 is the least like the top: the
    /// other mood is 2, never 1.
    fn meta(a: i64, b: i64, c: i64) -> Vec<crate::index::db::TasteFacetMeta> {
        vec![
            crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader: a,
                cos_to_top: 1.0,
            },
            crate::index::db::TasteFacetMeta {
                facet: 1,
                weight: 2.0,
                leader: b,
                cos_to_top: 0.5,
            },
            crate::index::db::TasteFacetMeta {
                facet: 2,
                weight: 1.0,
                leader: c,
                cos_to_top: -0.2,
            },
        ]
    }

    fn names(trio: &Trio) -> Vec<(u32, String, String)> {
        trio.cards
            .iter()
            .map(|c| (c.role, c.title.name.clone(), c.seed.clone()))
            .collect()
    }

    /// A title watched `n` times, the last of them at `at`.
    fn played(db: &Db, title_id: i64, n: u32, at: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1 LIMIT 1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        let dur: f64 = db
            .conn()
            .query_row(
                "SELECT duration_secs FROM files WHERE id = ?1",
                [file_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 0.0,
                duration_secs: dur,
                watched: true,
                plays: n,
                updated_at: at,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
    }

    #[test]
    fn a_film_loved_years_ago_leads_the_familiar_and_last_months_does_not() {
        let db = Db::open_in_memory().unwrap();
        let old = film(&db, "Heat", 6000.0);
        let recent = film(&db, "Sicario", 6000.0);
        // more plays, but four months ago against nearly four years: both
        // clear the rest floor, so the score alone decides between them
        played(&db, recent, 4, NOW - 120 * DAY);
        played(&db, old, 3, NOW - 1_400 * DAY);

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = trio.cards.iter().find(|c| c.role == ROLE_FAMILIAR).unwrap();
        assert_eq!(card.title.name, "Heat");
        assert_eq!(card.plays, 3);
        assert_eq!(card.last_watched_at, NOW - 1_400 * DAY);
    }

    #[test]
    fn a_stated_verdict_weighs_beside_the_plays_and_a_refusal_ends_it() {
        let db = Db::open_in_memory().unwrap();
        let plain = film(&db, "Plain", 6000.0);
        let loved = film(&db, "Loved", 6000.0);
        let hated = film(&db, "Hated", 6000.0);
        for t in [plain, loved, hated] {
            played(&db, t, 2, NOW - 1_400 * DAY);
        }
        db.set_verdict(loved, Some(Verdict::Loved), NOW - DAY)
            .unwrap();
        db.set_verdict(hated, Some(Verdict::Down), NOW - DAY)
            .unwrap();

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = trio.cards.iter().find(|c| c.role == ROLE_FAMILIAR).unwrap();
        assert_eq!(card.title.name, "Loved");

        // and a refusal is final, however often it was played
        played(&db, hated, 9, NOW - 1_400 * DAY);
        db.replace_tonight_picks(evening_of(NOW, 0).unwrap(), &[], 0)
            .unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = trio.cards.iter().find(|c| c.role == ROLE_FAMILIAR).unwrap();
        assert_ne!(card.title.name, "Hated");
    }

    #[test]
    fn a_film_too_long_for_what_is_left_of_the_evening_is_not_the_familiar() {
        let db = Db::open_in_memory().unwrap();
        // 21:00, weeknight bedtime 23:15: 135 minutes plus 15 of tolerance
        let long = film(&db, "Lawrence of Arabia", 227.0 * 60.0);
        let short = film(&db, "Reservoir Dogs", 99.0 * 60.0);
        played(&db, long, 5, NOW - 1_400 * DAY);
        played(&db, short, 2, NOW - 1_400 * DAY);

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = trio.cards.iter().find(|c| c.role == ROLE_FAMILIAR).unwrap();
        assert_eq!(card.title.name, "Reservoir Dogs");
    }

    #[test]
    fn a_library_with_no_fingerprint_still_offers_what_was_loved_before() {
        let db = Db::open_in_memory().unwrap();
        let old = film(&db, "Heat", 6000.0);
        played(&db, old, 3, NOW - 1_400 * DAY);
        assert!(db.taste_facets().unwrap().is_empty());

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards.len(), 1);
        assert_eq!(trio.cards[0].role, ROLE_FAMILIAR);
        assert_eq!(trio.gaps.len(), 2);
    }

    #[test]
    fn nothing_the_queue_already_shows_is_offered_again_by_the_trio() {
        let db = Db::open_in_memory().unwrap();
        let wanted = film(&db, "Heat", 6000.0);
        let other = film(&db, "Collateral", 6000.0);
        played(&db, wanted, 5, NOW - 1_400 * DAY);
        played(&db, other, 2, NOW - 1_400 * DAY);
        // on the watchlist, so the queue below the trio already carries it
        db.set_watchlisted(wanted, true, NOW).unwrap();

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = trio.cards.iter().find(|c| c.role == ROLE_FAMILIAR).unwrap();
        assert_eq!(card.title.name, "Collateral");
    }

    /// The Top Shelf composes the trio on a readonly connection: it must get
    /// the same cards and record nothing, however stale the session is.
    #[test]
    fn a_trio_is_composed_on_a_reader_without_a_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        let db = Db::open(&path).unwrap();
        library(&db);
        let reader = Db::open_read_only(&path).unwrap();

        let (trio, _) = compose_tonight(&reader, NOW, 0, None).unwrap().unwrap();
        assert!(!trio.cards.is_empty());
        let shown: i64 = db
            .conn()
            .query_row("SELECT COUNT(*) FROM tonight_shown", [], |r| r.get(0))
            .unwrap();
        assert_eq!(shown, 0);

        // what the writer then records is what the reader composed
        let written = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(names(&written), names(&trio));
    }

    #[test]
    fn carrying_on_belongs_to_the_queue_and_no_card_is_ever_a_resume() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let started = title_by_name(&db, "Other Two");
        in_progress(&db, started, 3_600.0, NOW - DAY);

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(
            trio.cards.iter().all(|c| c.resume.is_none()),
            "{:?}",
            names(&trio)
        );
        assert!(
            !trio.cards.iter().any(|c| c.title.name == "Other Two"),
            "{:?}",
            names(&trio)
        );
    }

    fn window(minutes: u32) -> EveningAnswers {
        EveningAnswers {
            window_min: Some(minutes),
            ..Default::default()
        }
    }

    fn set_together(db: &Db, together: bool) {
        db.set_evening_state(
            evening_of(NOW, 0).unwrap(),
            &EveningAnswers {
                together,
                ..Default::default()
            },
        )
        .unwrap();
    }

    #[test]
    fn two_people_get_a_wider_margin_before_bedtime_than_one() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        // 21:00 is 180 minutes into the evening and bedtime 23:15 is 315, so
        // one margin leaves 150 minutes and the other 165: 160 needs the wider
        let snug = film(&db, "Snug", 160.0 * 60.0);
        db.replace_taste(&pass(
            [pick(snug, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();

        assert!(tonight(&db, NOW, 0, None).unwrap().is_none());

        set_together(&db, true);
        db.replace_tonight_picks(evening_of(NOW, 0).unwrap(), &[], 0)
            .unwrap();
        let together = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(together.cards.iter().any(|c| c.title.name == "Snug"));
    }

    #[test]
    fn the_gamble_stays_near_the_taste_when_the_evening_is_not_only_yours() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let safe = film(&db, "Safe One", 6000.0);
        let far = film(&db, "Far", 6000.0);
        db.replace_taste(&pass(
            [pick(safe, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[far],
        ))
        .unwrap();
        // the fixture places a discovery at closeness 0.5; push this one out
        db.conn()
            .execute("UPDATE discovery_pick SET closeness = 0.1", [])
            .unwrap();

        let alone = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(alone.cards.iter().any(|c| c.role == ROLE_GAMBLE));

        set_together(&db, true);
        db.replace_tonight_picks(evening_of(NOW, 0).unwrap(), &[], 0)
            .unwrap();
        let together = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(!together.cards.iter().any(|c| c.role == ROLE_GAMBLE));
        assert!(together.gaps.iter().any(|(r, _)| *r == ROLE_GAMBLE));
    }

    #[test]
    fn a_corrected_window_beats_the_estimator_in_both_directions() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let epic = film(&db, "Epic", 200.0 * 60.0);
        db.replace_taste(&pass(
            [pick(epic, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();
        // 200 minutes runs well past the estimated 23:15, and it is the only
        // candidate there is, so the evening has nothing to say at all
        assert!(tonight(&db, NOW, 0, None).unwrap().is_none());

        let evening = evening_of(NOW, 0).unwrap();
        db.set_evening_state(evening, &window(240)).unwrap();
        db.replace_tonight_picks(evening, &[], 0).unwrap();
        let long = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(long.cards[0].title.name, "Epic");

        // and a shorter window takes it away again
        db.set_evening_state(evening, &window(60)).unwrap();
        db.replace_tonight_picks(evening, &[], 0).unwrap();
        assert!(tonight(&db, NOW, 0, None).unwrap().is_none());
    }

    #[test]
    fn what_the_viewer_said_about_tonight_outlives_a_restart_but_not_the_evening() {
        let db = Db::open_in_memory().unwrap();
        let evening = evening_of(NOW, 0).unwrap();
        let said = EveningAnswers {
            together: true,
            window_min: Some(90),
            mood: Some("light".into()),
            guest_id: None,
        };
        db.set_evening_state(evening, &said).unwrap();
        assert_eq!(db.evening_state(evening).unwrap(), said);
        // tomorrow starts over
        assert_eq!(
            db.evening_state(evening + 1).unwrap(),
            EveningAnswers::default()
        );
    }

    #[test]
    fn three_refusals_an_evening_and_then_the_trio_stands() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let picks: Vec<i64> = (0..8)
            .map(|i| film(&db, &format!("Film {i}"), 6000.0))
            .collect();
        db.replace_taste(&pass(
            picks
                .iter()
                .map(|&t| pick(t, 0, leader))
                .collect::<Vec<_>>(),
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();

        for spent in 0..PASSES {
            let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
            assert_eq!(trio.passes_left, PASSES - spent);
            defer(&db, trio.cards[0].title.id, NOW, 0).unwrap();
        }

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.passes_left, 0);
        let standing = trio.cards[0].title.id;
        // the core holds the rule, whatever the screen still offers
        defer(&db, standing, NOW, 0).unwrap();
        let after = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(after.cards[0].title.id, standing);
    }

    #[test]
    fn a_setting_moves_the_budget_and_the_core_reads_it_not_the_screen() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let one = film(&db, "One", 6000.0);
        let two = film(&db, "Two", 6000.0);
        db.replace_taste(&pass(
            [pick(one, 0, leader), pick(two, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();

        db.set_setting(PASSES_SETTING, "1").unwrap();
        assert_eq!(passes_left(&db, NOW, 0).unwrap(), 1);
        defer(&db, one, NOW, 0).unwrap();
        assert_eq!(passes_left(&db, NOW, 0).unwrap(), 0);
        // the second refusal is refused, however the screen asked
        defer(&db, two, NOW, 0).unwrap();
        assert_eq!(passes_left(&db, NOW, 0).unwrap(), 0);
        assert_eq!(
            db.deferrals_between(EVENING * DAY, (EVENING + 1) * DAY)
                .unwrap(),
            1
        );
    }

    #[test]
    fn the_budget_is_counted_by_evening_and_not_by_calendar_day() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let one = film(&db, "One", 6000.0);
        db.replace_taste(&pass(
            [pick(one, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();

        defer(&db, one, NOW, 0).unwrap();
        assert_eq!(passes_left(&db, NOW, 0).unwrap(), PASSES - 1);

        // 01:00, which belongs to the evening that began the day before
        let after_midnight = EVENING * DAY + 25 * 3_600;
        assert_eq!(evening_of(after_midnight, 0), Some(EVENING));
        assert_eq!(passes_left(&db, after_midnight, 0).unwrap(), PASSES - 1);

        // and the next evening starts over
        assert_eq!(passes_left(&db, NOW + DAY, 0).unwrap(), PASSES);
    }

    #[test]
    fn the_trio_no_longer_argues_a_second_mood() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.bedtime_min, DEFAULT_WEEKNIGHT_MIN);
        // nothing here was ever watched, so the familiar role is a gap and
        // the two taste roles are what is left
        assert_eq!(
            names(&trio),
            [
                (ROLE_SAFE, "Safe One".into(), "Leader A".into()),
                (ROLE_GAMBLE, "Disco One".into(), String::new()),
            ]
        );
        assert!(trio.gaps.iter().any(|(r, _)| *r == ROLE_FAMILIAR));
    }

    #[test]
    fn nothing_launched_is_offered_afresh_and_nothing_deferred_at_all() {
        let db = Db::open_in_memory().unwrap();
        let leader_a = film(&db, "Leader A", 6000.0);
        let leader_b = film(&db, "Leader B", 6000.0);
        let started = film(&db, "Launched", 6000.0);
        let fresh = film(&db, "Deferred Recent", 6000.0);
        let stale = film(&db, "Deferred Old", 6000.0);
        let mood = film(&db, "Mood", 6000.0);
        let disco = film(&db, "Disco", 6000.0);
        db.replace_taste(&pass(
            [
                pick(started, 0, leader_a),
                pick(fresh, 0, leader_a),
                pick(stale, 0, leader_a),
                pick(mood, 1, leader_b),
            ],
            meta(leader_a, leader_b, leader_b)[..2].to_vec(),
            &[disco],
        ))
        .unwrap();
        launched(&db, started);
        db.defer_tonight(fresh, NOW - 3 * DAY).unwrap();
        db.defer_tonight(stale, NOW - 15 * DAY).unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        // a launched title is spent for the taste pools and belongs to the
        // queue, so no role reaches for it
        assert!(
            !trio.cards.iter().any(|c| c.title.name == "Launched"),
            "{:?}",
            names(&trio)
        );
        // the deferral that has run out comes back, the live one does not
        let seen: Vec<&str> = trio
            .cards
            .iter()
            .map(|c| c.title.name.as_str())
            .chain(trio.more.iter().map(|t| t.name.as_str()))
            .collect();
        assert!(seen.contains(&"Deferred Old"), "{seen:?}");
        assert!(!seen.contains(&"Deferred Recent"), "{seen:?}");

        // finished rather than started, and it is spent for good: nothing is
        // left of it to carry on with
        let db2 = Db::open_in_memory().unwrap();
        let leader_a = film(&db2, "Leader A", 6000.0);
        let leader_b = film(&db2, "Leader B", 6000.0);
        let seen = film(&db2, "Seen", 6000.0);
        let left = film(&db2, "Left", 6000.0);
        let mood = film(&db2, "Mood", 6000.0);
        let disco = film(&db2, "Disco", 6000.0);
        db2.replace_taste(&pass(
            [
                pick(seen, 0, leader_a),
                pick(left, 0, leader_a),
                pick(mood, 1, leader_b),
            ],
            meta(leader_a, leader_b, leader_b)[..2].to_vec(),
            &[disco],
        ))
        .unwrap();
        finished(&db2, seen);
        let after = tonight(&db2, NOW, 0, None).unwrap().unwrap();
        assert_eq!(after.cards[0].title.name, "Left", "{:?}", names(&after));
    }

    #[test]
    fn the_runtime_gate_is_firm_and_slides_to_short_formats() {
        let db = Db::open_in_memory().unwrap();
        let leader_a = film(&db, "Leader A", 6000.0);
        let leader_b = film(&db, "Leader B", 6000.0);
        // 160 minutes from 21:00 ends past 23:30; 110 minutes fits
        let long = film(&db, "Long", 9_600.0);
        let short = film(&db, "Short", 6_600.0);
        let serial = show(&db, "Serial", &[2_520.0, 2_700.0, 2_520.0]);
        let bare = film(&db, "No Runtime", 0.0);
        let disco = film(&db, "Disco", 6_000.0);
        db.replace_taste(&pass(
            [
                pick(long, 0, leader_a),
                pick(short, 0, leader_a),
                pick(disco, 1, leader_b),
            ],
            meta(leader_a, leader_b, leader_b)[..2].to_vec(),
            &[bare, serial],
        ))
        .unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Short", "{:?}", names(&trio));
        // a title whose runtime nobody knows cannot promise an end time, so
        // the gamble reaches past it to the show, which is measured on its
        // median episode and says so
        assert_eq!(trio.cards[1].title.name, "Serial");
        assert!(trio.cards[1].episode);
        assert_eq!(trio.cards[1].runtime_secs, 2_520.0);
    }

    #[test]
    fn the_trio_freezes_for_the_evening_and_a_dead_card_is_replaced() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        let first = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(first.cards[0].title.name, "Safe One");
        // the pool reorders under the frozen trio, and the stored pick holds
        let leaders: (i64, i64, i64) = (
            db.taste_facets().unwrap()[0].leader,
            db.taste_facets().unwrap()[1].leader,
            db.taste_facets().unwrap()[2].leader,
        );
        let mood: i64 = title_by_name(&db, "Mood");
        let other_one = title_by_name(&db, "Other One");
        let disco_one = title_by_name(&db, "Disco One");
        let disco_two = title_by_name(&db, "Disco Two");
        db.replace_taste(&pass(
            [
                pick(safe_two, 0, leaders.0),
                pick(safe_one, 0, leaders.0),
                pick(mood, 1, leaders.1),
                pick(other_one, 2, leaders.2),
            ],
            meta(leaders.0, leaders.1, leaders.2),
            &[disco_one, disco_two],
        ))
        .unwrap();
        let second = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(
            second.cards[0].title.name,
            "Safe One",
            "{:?}",
            names(&second)
        );
        // a card gone dead is replaced, alone. Watched to the end and not
        // merely started: a film left in progress is what the safe bet now
        // leads with rather than a death (see the continuation test below).
        finished(&db, safe_one);
        let third = tonight(&db, NOW + 1_200, 0, None).unwrap().unwrap();
        assert_eq!(third.cards[0].title.name, "Safe Two", "{:?}", names(&third));
        assert_eq!(third.cards[1].title.name, "Disco One");
    }

    #[test]
    fn a_gamble_kept_after_the_trio_froze_becomes_the_safe_bet_and_stays() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let first = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(first.cards[0].title.name, "Safe One");
        // a duel's "keep for tonight" on a stranger the gamble did not deal
        let disco_two = title_by_name(&db, "Disco Two");
        db.queue_tonight(disco_two, NOW + 300).unwrap();
        let second = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(second.cards[0].title.id, disco_two, "{:?}", names(&second));
        assert_eq!(second.cards[0].role, ROLE_SAFE);
        assert_eq!(
            second.cards[1].title.name, "Disco One",
            "the gamble is untouched"
        );
        // shown, the queue is spent, and the freeze keeps what it replaced it with
        assert!(db.queued_tonight(0).unwrap().is_empty());
        let third = tonight(&db, NOW + 1_200, 0, None).unwrap().unwrap();
        assert_eq!(third.cards[0].title.id, disco_two, "{:?}", names(&third));
    }

    #[test]
    fn a_title_queued_from_outside_every_pool_becomes_the_safe_bet() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        tonight(&db, NOW, 0, None).unwrap().unwrap();
        let sequel = film(&db, "Sequel", 5_400.0);
        db.queue_tonight(sequel, NOW + 300).unwrap();
        let trio = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, sequel, "{:?}", names(&trio));
    }

    #[test]
    fn of_two_titles_queued_after_the_freeze_the_later_leads_and_the_earlier_waits() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        tonight(&db, NOW, 0, None).unwrap().unwrap();
        let earlier = film(&db, "Earlier", 5_400.0);
        let later = film(&db, "Later", 5_400.0);
        db.queue_tonight(earlier, NOW + 100).unwrap();
        db.queue_tonight(later, NOW + 200).unwrap();
        let trio = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, later, "{:?}", names(&trio));
        // queued before this freeze, the earlier one leaves the card alone
        let again = tonight(&db, NOW + 1_200, 0, None).unwrap().unwrap();
        assert_eq!(again.cards[0].title.id, later, "{:?}", names(&again));
        assert_eq!(db.queued_tonight(0).unwrap(), vec![(earlier, NOW + 100)]);
    }

    fn rated(db: &Db, title_id: i64, audience: f64) {
        db.conn()
            .execute(
                "INSERT INTO metadata (title_id, source, fetched_at, audience_rating, audience_source)
                 VALUES (?1, 'tmdb', 0, ?2, 'themoviedb')",
                rusqlite::params![title_id, audience],
            )
            .unwrap();
    }

    #[test]
    fn a_card_ignored_evening_after_evening_gives_way() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, _) = library(&db);
        let first = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(first.cards[0].title.id, safe_one);
        // the same evening holds it: tonight's own showing is not fatigue
        let later = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(later.cards[0].title.id, safe_one);
        // the next evening it has been passed over once, and sinks a band
        let next = tonight(&db, NOW + DAY, 0, None).unwrap().unwrap();
        assert_eq!(next.cards[0].title.name, "Safe Two", "{:?}", names(&next));
        // and a month away wipes the slate
        let fresh = tonight(&db, NOW + (FATIGUE_EVENINGS + 3) * DAY, 0, None)
            .unwrap()
            .unwrap();
        assert_eq!(fresh.cards[0].title.id, safe_one, "{:?}", names(&fresh));
    }

    /// The lane under the trio tires a title too, at half a card's rate: one
    /// evening there costs nothing, four cost it the card.
    #[test]
    fn a_title_the_lane_showed_evening_after_evening_gives_way() {
        for (evenings, card) in [(1, "Safe One"), (4, "Safe Two")] {
            let db = Db::open_in_memory().unwrap();
            let (safe_one, _) = library(&db);
            for n in 1..=evenings {
                db.record_tonight_exposure(EVENING - n, &[], &[safe_one], FATIGUE_EVENINGS)
                    .unwrap();
            }
            let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
            assert_eq!(
                trio.cards[0].title.name,
                card,
                "{evenings}: {:?}",
                names(&trio)
            );
        }

        // a month away and the lane's count is forgotten
        let db = Db::open_in_memory().unwrap();
        let (safe_one, _) = library(&db);
        for n in 41..=44 {
            db.record_tonight_exposure(EVENING - n, &[], &[safe_one], FATIGUE_EVENINGS)
                .unwrap();
        }
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One", "{:?}", names(&trio));

        // the evening counts its own lane once, however often it is asked
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        let exposure = db.tonight_exposure().unwrap();
        assert!(!trio.more.is_empty());
        for title in &trio.more {
            assert_eq!(exposure[&title.id].lanes, 1, "{}", title.name);
        }
    }

    #[test]
    fn within_one_band_the_better_thought_of_leads() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        rated(&db, safe_one, 5.1);
        rated(&db, safe_two, 8.4);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, safe_two, "{:?}", names(&trio));
    }

    #[test]
    fn the_safe_bet_leads_and_the_runners_up_are_all_new() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let old = film(&db, "Heat", 6000.0);
        let older = film(&db, "Ronin", 6000.0);
        played(&db, old, 3, NOW - 4 * 365 * DAY);
        played(&db, older, 2, NOW - 3 * 365 * DAY);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let roles: Vec<u32> = trio.cards.iter().map(|c| c.role).collect();
        assert_eq!(roles, [ROLE_SAFE, ROLE_GAMBLE, ROLE_FAMILIAR]);
        assert!(
            !trio.more.iter().any(|t| t.id == old || t.id == older),
            "{:?}",
            trio.more
        );
    }

    #[test]
    fn asking_again_the_same_evening_writes_nothing() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        tonight(&db, NOW, 0, None).unwrap().unwrap();
        let written = db.conn().total_changes();
        tonight(&db, NOW + 60, 0, None).unwrap().unwrap();
        assert_eq!(db.conn().total_changes(), written);
    }

    #[test]
    fn the_home_knows_what_the_evening_lane_already_shows() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let shown = db.on_home(Some(EVENING)).unwrap();
        for id in trio
            .cards
            .iter()
            .map(|c| c.title.id)
            .chain(trio.more.iter().map(|t| t.id))
        {
            assert!(shown.contains(&id));
        }
        assert!(db.on_home(Some(EVENING + 1)).unwrap().is_empty());
    }

    #[test]
    fn the_evening_keeps_each_card_it_showed_in_its_role() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let mut expected: Vec<(i64, u32)> =
            trio.cards.iter().map(|c| (c.title.id, c.role)).collect();
        expected.sort_unstable();
        let shown: Vec<(i64, u32)> = db
            .conn()
            .prepare(
                "SELECT title_id, role FROM tonight_shown WHERE evening = ?1 ORDER BY title_id",
            )
            .unwrap()
            .query_map([EVENING], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(shown, expected);
    }

    fn title_by_name(db: &Db, name: &str) -> i64 {
        db.conn()
            .query_row("SELECT id FROM titles WHERE name = ?1", [name], |r| {
                r.get(0)
            })
            .unwrap()
    }

    #[test]
    fn one_taste_is_enough_now_that_no_role_argues_a_second() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let safe = film(&db, "Safe One", 6000.0);
        let disco = film(&db, "Disco", 6000.0);
        db.replace_taste(&pass(
            [pick(safe, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[disco],
        ))
        .unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One");
        assert_eq!(trio.cards[1].title.name, "Disco");
    }

    #[test]
    fn no_trio_when_no_role_can_be_filled_or_outside_the_evening() {
        // an empty discovery no longer takes the block down with it: the two
        // roles that can be filled are, and the third says why it is not
        let db = Db::open_in_memory().unwrap();
        let leader_a = film(&db, "Leader A", 6000.0);
        let leader_b = film(&db, "Leader B", 6000.0);
        let safe = film(&db, "Safe One", 6000.0);
        let mood = film(&db, "Mood", 6000.0);
        db.replace_taste(&pass(
            [pick(safe, 0, leader_a), pick(mood, 1, leader_b)],
            meta(leader_a, leader_b, leader_b)[..2].to_vec(),
            &[],
        ))
        .unwrap();
        let thin = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(thin.cards.iter().any(|c| c.role == ROLE_SAFE));
        assert!(thin.gaps.contains(&(ROLE_GAMBLE, Gap::Exhausted)));

        // three in the afternoon is nobody's evening
        let db = Db::open_in_memory().unwrap();
        library(&db);
        assert!(tonight(&db, EVENING * DAY + 15 * 3_600, 0, None)
            .unwrap()
            .is_none());
    }

    #[test]
    fn defer_removes_the_card_and_the_next_candidate_steps_in() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, _) = library(&db);
        let first = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(first.cards[0].title.name, "Safe One");
        defer(&db, safe_one, NOW, 0).unwrap();
        let second = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(
            names(&second)
                .iter()
                .map(|(_, n, _)| n.clone())
                .collect::<Vec<_>>(),
            ["Safe Two", "Disco One"]
        );
    }

    /// Left in progress at `when`, which is what makes carrying on with it a
    /// plan for tonight rather than a title walked away from.
    fn in_progress(db: &Db, title_id: i64, position: f64, when: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1 LIMIT 1",
                [title_id],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: position,
                duration_secs: 6000.0,
                watched: false,
                plays: 0,
                updated_at: when,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    #[test]
    fn a_film_finished_is_never_offered_back_as_something_to_carry_on_with() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let seen = title_by_name(&db, "Other Two");
        // a second file of the same title - another cut, another quality -
        // which the watch row does not cover: without a guard the evening
        // offers "carry on at 0 min" on a film that has been finished
        file(&db, seen, "Other Two.remux.mkv", None, 6000.0);
        finished(&db, seen);

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(
            !trio.cards.iter().any(|c| c.title.name == "Other Two"),
            "{:?}",
            names(&trio)
        );
        assert!(trio.cards[0].resume.is_none());
    }

    #[test]
    fn a_role_with_candidates_and_no_room_says_which() {
        let db = Db::open_in_memory().unwrap();
        let leader_a = film(&db, "Leader A", 6000.0);
        let leader_b = film(&db, "Leader B", 6000.0);
        let leader_c = film(&db, "Leader C", 6000.0);
        // the two tastes hold something short; the discovery holds one film
        // three hours long, which is a different sentence from holding nothing
        let safe = film(&db, "Safe One", 1_800.0);
        let mood = film(&db, "Mood", 1_800.0);
        let epic = film(&db, "Epic", 10_800.0);
        db.replace_taste(&pass(
            [pick(safe, 0, leader_a), pick(mood, 2, leader_c)],
            meta(leader_a, leader_b, leader_c),
            &[epic],
        ))
        .unwrap();

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert!(trio.cards.iter().any(|c| c.role == ROLE_SAFE));
        assert!(trio.gaps.contains(&(ROLE_GAMBLE, Gap::NoTime)));
    }

    #[test]
    fn within_one_band_the_evening_prefers_what_fills_it() {
        let db = Db::open_in_memory().unwrap();
        let leader_a = film(&db, "Leader A", 6000.0);
        let leader_b = film(&db, "Leader B", 6000.0);
        let leader_c = film(&db, "Leader C", 6000.0);
        // 21:00 against a 23:15 bedtime leaves 135 minutes. The taste ranks
        // the half-hour first, and the evening reaches past it for the one
        // that actually fills the night - without ever leaving the band.
        let short = film(&db, "Short", 1_800.0);
        let full = film(&db, "Full", 7_800.0);
        let mood = film(&db, "Mood", 1_800.0);
        let disco = film(&db, "Disco", 1_800.0);
        db.replace_taste(&pass(
            [
                pick(short, 0, leader_a),
                pick(full, 0, leader_a),
                pick(mood, 2, leader_c),
            ],
            meta(leader_a, leader_b, leader_c),
            &[disco],
        ))
        .unwrap();

        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Full", "{:?}", names(&trio));
        // and the one it stepped over is still the first thing offered under
        // the block rather than dropped
        assert_eq!(trio.more[0].name, "Short");
    }

    #[test]
    fn the_hour_chooses_the_taste_once_it_has_enough_evenings_of_its_own() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        db.conn().execute("DELETE FROM watched_facet", []).unwrap();
        // weeknight dinners are facet 1, weeknight late films facet 2
        for week in 1..=MIN_CLASS_PLAYS as i64 {
            for (facet, hour) in [(1u32, 19), (2u32, 22)] {
                let id = film(&db, &format!("Spent {facet} {week}"), 6000.0);
                played(&db, id, 1, (EVENING - 7 * week) * DAY + hour * 3_600);
                db.conn()
                    .execute(
                        "INSERT INTO watched_facet (title_id, facet) VALUES (?1, ?2)",
                        rusqlite::params![id, facet],
                    )
                    .unwrap();
            }
        }
        let facets = db.taste_facets().unwrap();
        let ends = db.watched_facet_ends().unwrap();
        assert_eq!(facet_order(&ends, &facets, 0, NOW - 2 * 3_600)[0], 1);
        assert_eq!(facet_order(&ends, &facets, 0, NOW + 3_600)[0], 2);
        // a Saturday afternoon has no history of its own, nor does its class
        let saturday = (EVENING + 2) * DAY + 15 * 3_600;
        assert_eq!(slot(saturday, 0), (true, 0));
        assert_eq!(facet_order(&ends, &facets, 0, saturday)[0], 0);
    }

    #[test]
    fn the_class_of_evening_chooses_the_taste_once_there_is_enough_of_it() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        // the whole history puts facet 0 first, and it does tonight too
        let first = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(first.cards[0].title.name, "Safe One");

        // twelve weeknight plays of facet 2, which is what this class of
        // evening actually reaches for
        let spent: Vec<(i64, u32)> = (0..MIN_CLASS_PLAYS as i64)
            .map(|i| (film(&db, &format!("Spent {i}"), 6000.0), 2))
            .collect();
        // finished, not left in progress: what this test needs is the stamp
        // saying when the taste was watched, not a plan for tonight
        for (title_id, _) in &spent {
            finished(&db, *title_id);
        }
        db.conn().execute("DELETE FROM watched_facet", []).unwrap();
        for (title_id, facet) in &spent {
            db.conn()
                .execute(
                    "INSERT INTO watched_facet (title_id, facet) VALUES (?1, ?2)",
                    rusqlite::params![title_id, facet],
                )
                .unwrap();
        }
        // the deferral window keeps those out of the offer; what they change
        // is which taste leads, from a fresh evening: the one already shown
        // keeps its frozen card
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One", "{:?}", names(&trio));
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Other One", "{:?}", names(&trio));
    }

    #[test]
    fn the_evening_runs_from_six_pm_to_six_am() {
        // 2026-08-25 is a Tuesday; 19:00 UTC at tz 0 belongs to that day
        let day = 20_690;
        assert_eq!(evening_of(day * 86_400 + 19 * 3_600, 0), Some(day));
        // 01:00 the next morning still belongs to the 25th
        assert_eq!(evening_of((day + 1) * 86_400 + 3_600, 0), Some(day));
        // 15:00 is nobody's evening
        assert_eq!(evening_of(day * 86_400 + 15 * 3_600, 0), None);
        // the timezone moves the boundary: 17:30 UTC at +01:00 is 18:30 local
        assert_eq!(
            evening_of(day * 86_400 + 17 * 3_600 + 1_800, 3_600),
            Some(day)
        );
    }

    #[test]
    fn friday_and_saturday_evenings_are_the_weekend_class() {
        // 1970-01-01 was a Thursday; day 1 a Friday
        assert!(weekend(1));
        assert!(weekend(2));
        assert!(!weekend(0));
        assert!(!weekend(3));
    }

    #[test]
    fn bedtime_is_the_upper_quartile_of_real_evenings() {
        // 20 weeknight evenings ending 22:30 local (m = 270) and 4 ending
        // 23:50 (m = 350): the 75th percentile stays at 270
        let day = 20_685;
        let mut ends = Vec::new();
        for e in 0..20 {
            ends.push((day - e * 7) * 86_400 + 22 * 3_600 + 30 * 60);
        }
        for e in 0..4 {
            ends.push((day - 1 - e * 7) * 86_400 + 23 * 3_600 + 50 * 60);
        }
        let now = day * 86_400 + 20 * 3_600;
        assert_eq!(bedtime(&ends, 0, now, false), 270);
    }

    #[test]
    fn a_bulk_import_counts_as_one_evening_and_the_default_holds() {
        let day = 20_685;
        let ends: Vec<i64> = (0..100)
            .map(|i| day * 86_400 + 20 * 3_600 + i * 30)
            .collect();
        let now = day * 86_400 + 20 * 3_600 + 3_600;
        assert_eq!(bedtime(&ends, 0, now, false), DEFAULT_WEEKNIGHT_MIN);
    }

    #[test]
    fn bedtime_is_clamped_and_windowed() {
        // 10 evenings ending 21:00 (m = 180): clamped up to 22:00 (240).
        let day = 20_685;
        let ends: Vec<i64> = (0..10)
            .map(|e| (day - e * 7) * 86_400 + 21 * 3_600)
            .collect();
        let now = day * 86_400 + 20 * 3_600;
        assert_eq!(bedtime(&ends, 0, now, false), CLAMP_MIN);
        // evenings older than 26 weeks are not evidence
        let stale: Vec<i64> = ends.iter().map(|e| e - 30 * 7 * 86_400).collect();
        assert_eq!(bedtime(&stale, 0, now, false), DEFAULT_WEEKNIGHT_MIN);
    }

    /// The library of `library`, with the mood lists a taste pass would
    /// write beside it, keyed as `taste::anchored` keys them.
    fn with_lists(db: &Db, lists: &[(&str, &[i64])]) {
        let facets = db.taste_facets().unwrap();
        let picks: Vec<crate::index::db::TastePick> = db
            .conn()
            .prepare("SELECT title_id, facet, leader FROM taste_pick ORDER BY rank")
            .unwrap()
            .query_map([], |r| Ok(pick(r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let discovery: Vec<i64> = db
            .conn()
            .prepare("SELECT title_id FROM discovery_pick ORDER BY rank")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let mut out = pass(picks, facets, &discovery);
        out.seasonal = lists
            .iter()
            .map(|(key, ids)| (key.to_string(), ids.to_vec()))
            .collect();
        db.replace_taste(&out).unwrap();
    }

    fn mood(db: &Db, key: Option<&str>) {
        db.set_evening_state(
            EVENING,
            &EveningAnswers {
                mood: key.map(String::from),
                ..Default::default()
            },
        )
        .unwrap();
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
    }

    #[test]
    fn a_mood_hands_the_safe_bet_to_its_first_unseen_title_that_fits() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let epic = film(&db, "Epic", 300.0 * 60.0);
        let seen = film(&db, "Seen", 6000.0);
        finished(&db, seen);
        let other_two = title_by_name(&db, "Other Two");
        let safe_two = title_by_name(&db, "Safe Two");
        with_lists(&db, &[("light", &[epic, seen, other_two, safe_two])]);

        mood(&db, Some("light"));
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].role, ROLE_SAFE);
        assert_eq!(trio.cards[0].title.name, "Other Two", "{:?}", names(&trio));
        // argued from the taste the title sits in, when the pass placed it
        assert_eq!(trio.cards[0].seed, "");

        // and without the mood the taste's own order is back
        mood(&db, None);
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One", "{:?}", names(&trio));
    }

    #[test]
    fn a_mood_leads_the_gamble_and_the_familiar_with_its_own() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let heat = film(&db, "Heat", 6000.0);
        let paddington = film(&db, "Paddington", 6000.0);
        played(&db, heat, 5, NOW - 1_400 * DAY);
        played(&db, paddington, 1, NOW - 1_400 * DAY);
        let disco_two = title_by_name(&db, "Disco Two");
        let other_two = title_by_name(&db, "Other Two");
        with_lists(
            &db,
            &[
                ("light", &[other_two, disco_two]),
                ("seen:light", &[paddington]),
            ],
        );

        let plain = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let familiar = |t: &Trio| {
            t.cards
                .iter()
                .find(|c| c.role == ROLE_FAMILIAR)
                .unwrap()
                .title
                .name
                .clone()
        };
        assert_eq!(familiar(&plain), "Heat");

        mood(&db, Some("light"));
        let light = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(light.cards[0].title.id, other_two);
        let gamble = light.cards.iter().find(|c| c.role == ROLE_GAMBLE).unwrap();
        assert_eq!(gamble.title.id, disco_two, "{:?}", names(&light));
        assert_eq!(familiar(&light), "Paddington");
    }

    /// A finished title's facet, as the taste pass records it.
    fn spent_in(db: &Db, title_id: i64, facet: u32) {
        db.conn()
            .execute(
                "INSERT INTO watched_facet (title_id, facet) VALUES (?1, ?2)",
                rusqlite::params![title_id, facet],
            )
            .unwrap();
    }

    #[test]
    fn two_evenings_running_on_the_leading_taste_hand_the_safe_bet_to_the_next() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let monday = film(&db, "Spent Monday", 6000.0);
        played(&db, monday, 1, (EVENING - 2) * DAY + 21 * 3_600);
        spent_in(&db, monday, 0);
        // one evening is not a run
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One", "{:?}", names(&trio));

        let tuesday = film(&db, "Spent Tuesday", 6000.0);
        played(&db, tuesday, 1, (EVENING - 1) * DAY + 22 * 3_600);
        spent_in(&db, tuesday, 0);
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Mood", "{:?}", names(&trio));
        assert_eq!(trio.cards[0].seed, "Leader B");

        // and a run broken by another taste is no run
        let other = film(&db, "Spent Elsewhere", 6000.0);
        played(&db, other, 1, (EVENING - 1) * DAY + 20 * 3_600);
        spent_in(&db, other, 2);
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.name, "Safe One", "{:?}", names(&trio));
    }

    /// Enough discovery for the turn to have somewhere to go.
    fn wide_band(db: &Db) {
        let leader = film(db, "Leader A", 6000.0);
        let safe = film(db, "Safe One", 6000.0);
        let band: Vec<i64> = (0..GAMBLE_WINDOW + 3)
            .map(|i| film(db, &format!("Disco {i}"), 6000.0))
            .collect();
        db.replace_taste(&pass(
            [pick(safe, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &band,
        ))
        .unwrap();
    }

    fn gamble_of(trio: &Trio) -> String {
        trio.cards
            .iter()
            .find(|c| c.role == ROLE_GAMBLE)
            .unwrap()
            .title
            .name
            .clone()
    }

    #[test]
    fn the_gamble_turns_with_the_session_and_holds_within_it() {
        let db = Db::open_in_memory().unwrap();
        wide_band(&db);
        let first = gamble_of(&tonight(&db, NOW, 0, None).unwrap().unwrap());
        // the same session deals the same turn, frozen or not
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        assert_eq!(
            gamble_of(&tonight(&db, NOW + 600, 0, None).unwrap().unwrap()),
            first
        );

        // another evening, on a library that never showed anything
        let other = Db::open_in_memory().unwrap();
        wide_band(&other);
        let next = gamble_of(&tonight(&other, NOW + DAY, 0, None).unwrap().unwrap());
        assert_ne!(next, first);
        // and the turn stays within the head of the band
        let head: Vec<String> = (0..GAMBLE_WINDOW).map(|i| format!("Disco {i}")).collect();
        assert!(
            head.contains(&first) && head.contains(&next),
            "{first} {next}"
        );
    }

    fn rated_by(db: &Db, title_id: i64, audience: f64, votes: Option<u32>) {
        db.conn()
            .execute(
                "INSERT INTO metadata (title_id, source, fetched_at, audience_rating,
                                       audience_source, audience_votes)
                 VALUES (?1, 'tmdb', 0, ?2, 'themoviedb', ?3)",
                rusqlite::params![title_id, audience, votes],
            )
            .unwrap();
    }

    #[test]
    fn a_high_score_off_a_handful_of_voters_trails_a_good_one_off_thousands() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        rated_by(&db, safe_one, 8.5, Some(12));
        rated_by(&db, safe_two, 7.9, Some(40_000));
        // the rest of the library, which is what the handful is pulled towards
        for name in ["Other One", "Other Two", "Mood", "Disco One"] {
            rated_by(&db, title_by_name(&db, name), 5.5, Some(1_000));
        }
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, safe_two, "{:?}", names(&trio));
        // with no count to go on, the score counts for half and still leads
        assert!(quality_of(Some(8.5), None, 6.0) > quality_of(Some(7.9), None, 6.0));
    }

    #[test]
    fn the_mean_a_score_is_pulled_towards_is_the_one_the_taste_pass_stored() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        rated_by(&db, safe_one, 8.5, Some(12));
        rated_by(&db, safe_two, 7.9, Some(40_000));
        for name in ["Other One", "Other Two", "Mood", "Disco One"] {
            rated_by(&db, title_by_name(&db, name), 5.5, Some(1_000));
        }
        // a stored mean of ten pulls the handful up, past the thousands
        db.set_setting(RATING_MEAN_SETTING, "10").unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, safe_one, "{:?}", names(&trio));
    }

    /// One file of `title_id`'s watched to the end at `at`, by its index.
    fn finished_file_at(db: &Db, title_id: i64, n: usize, at: i64) {
        let file_id: i64 = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1 ORDER BY id LIMIT 1 OFFSET ?2",
                rusqlite::params![title_id, n as i64],
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: 0.0,
                duration_secs: 1.0,
                watched: true,
                plays: 1,
                updated_at: at,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
    }

    /// A safe pool of one film and one series, each ranked where `first`
    /// says, and twelve weeks of this slot spent on `binge` series episodes or
    /// films.
    fn kind_evening(film_mins: f64, show_mins: f64, series_history: bool) -> Trio {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        let one = film(&db, "Film", film_mins * 60.0);
        let serial = show(&db, "Serial", &[show_mins * 60.0; 3]);
        db.replace_taste(&pass(
            [pick(one, 0, leader), pick(serial, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();
        let weeks = MIN_CLASS_PLAYS as usize;
        let spent = if series_history {
            show(&db, "Binge", &vec![2_700.0; weeks])
        } else {
            let id = db.upsert_title(MediaKind::Movie, "Films", None).unwrap();
            for n in 0..weeks {
                file(&db, id, &format!("Films.{n}.mkv"), None, 6000.0);
            }
            id
        };
        for n in 0..weeks {
            finished_file_at(
                &db,
                spent,
                n,
                (EVENING - 7 * (n as i64 + 1)) * DAY + 21 * 3_600,
            );
        }
        // those evenings would otherwise teach an early bedtime
        db.set_evening_state(EVENING, &window(135)).unwrap();
        tonight(&db, NOW, 0, None).unwrap().unwrap()
    }

    #[test]
    fn a_slot_of_series_prefers_the_series_and_a_slot_of_films_the_film() {
        // left to the fit, the film fills the evening better than one episode
        let series = kind_evening(120.0, 45.0, true);
        assert_eq!(series.cards[0].title.name, "Serial", "{:?}", names(&series));
        // left to the fit, a long episode fills it better than a short film
        let films = kind_evening(50.0, 125.0, false);
        assert_eq!(films.cards[0].title.name, "Film", "{:?}", names(&films));
    }

    /// A Saturday, at 15:00 local.
    const SATURDAY_3PM: i64 = (EVENING + 2) * DAY + 15 * 3_600;

    #[test]
    fn a_weekend_afternoon_has_a_trio_that_ends_before_dinner() {
        let db = Db::open_in_memory().unwrap();
        let leader = film(&db, "Leader A", 6000.0);
        // 15:00 plus five hours is 20:00, past 19:30 and its margin
        let long = film(&db, "Long", 300.0 * 60.0);
        let short = film(&db, "Short", 100.0 * 60.0);
        db.replace_taste(&pass(
            [pick(long, 0, leader), pick(short, 0, leader)],
            [crate::index::db::TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }],
            &[],
        ))
        .unwrap();

        let trio = tonight(&db, SATURDAY_3PM, 0, None).unwrap().unwrap();
        assert!(trio.afternoon);
        assert_eq!(trio.bedtime_min, DEFAULT_AFTERNOON_END_MIN);
        assert_eq!(trio.cards[0].title.name, "Short", "{:?}", names(&trio));
        let three_pm = 15 * 60;
        for card in &trio.cards {
            assert!(three_pm + minutes_of(card.runtime_secs) <= 19 * 60 + 45);
        }

        // a weekday afternoon is nobody's session
        assert!(tonight(&db, NOW - 6 * 3_600, 0, None).unwrap().is_none());
        assert_eq!(session_of(NOW - 6 * 3_600, 0), None);
    }

    #[test]
    fn six_pm_starts_a_new_session_and_leaves_the_afternoon_s_choices_behind() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, _) = library(&db);
        let saturday = EVENING + 2;
        let before = saturday * DAY + 17 * 3_600 + 59 * 60;
        let afternoon = tonight(&db, before, 0, None).unwrap().unwrap();
        assert!(afternoon.afternoon);
        assert_eq!(afternoon.cards[0].title.id, safe_one);
        // a refusal spent in the afternoon is the afternoon's
        defer(&db, afternoon.cards[1].title.id, before, 0).unwrap();
        assert_eq!(passes_left(&db, before, 0).unwrap(), PASSES - 1);

        let evening = tonight(&db, saturday * DAY + 18 * 3_600, 0, None)
            .unwrap()
            .unwrap();
        assert!(!evening.afternoon);
        assert_eq!(
            passes_left(&db, saturday * DAY + 18 * 3_600, 0).unwrap(),
            PASSES
        );
        // the afternoon's picks are not the evening's: its card was shown and
        // passed over, and the evening moves on to the next
        assert_ne!(evening.cards[0].title.id, safe_one, "{:?}", names(&evening));
        assert_eq!(db.tonight_picks(-saturday - 1).unwrap(), []);
    }

    #[test]
    fn a_duel_never_offers_a_card_an_excluded_title_or_one_title_twice() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let extra: Vec<i64> = (0..3)
            .map(|i| film(&db, &format!("Disco Extra {i}"), 6000.0))
            .collect();
        let disco_one = title_by_name(&db, "Disco One");
        let disco_two = title_by_name(&db, "Disco Two");
        let mut out = pass(
            db.conn()
                .prepare("SELECT title_id, facet, leader FROM taste_pick ORDER BY rank")
                .unwrap()
                .query_map([], |r| Ok(pick(r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap(),
            db.taste_facets().unwrap(),
            &[&[disco_one, disco_two][..], &extra].concat(),
        );
        // every stranger sits in the leading taste beside Safe Two, but one
        let safe_two = title_by_name(&db, "Safe Two");
        out.title_taste = [safe_two, disco_one, disco_two, extra[0], extra[1], extra[2]]
            .into_iter()
            .map(|title_id| crate::index::db::TitleTasteRow {
                title_id,
                facet: if title_id == extra[2] { 1 } else { 0 },
                affinity: 0.5,
                rejected: String::new(),
            })
            .collect();
        db.replace_taste(&out).unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let cards: Vec<i64> = trio.cards.iter().map(|c| c.title.id).collect();

        let mut exclude = Vec::new();
        let mut rounds = 0;
        while let Some((left, right)) = this_or_that(&db, NOW, 0, None, &exclude).unwrap() {
            assert_ne!(left.title.id, right.title.id);
            for card in [&left, &right] {
                assert!(!cards.contains(&card.title.id), "{}", card.title.name);
                assert!(!exclude.contains(&card.title.id), "{}", card.title.name);
            }
            if rounds == 0 {
                // the taste's runner-up against the one stranger of
                // another taste
                assert_eq!(left.title.name, "Safe Two");
                assert_eq!(left.role, ROLE_SAFE);
                assert_eq!(right.title.id, extra[2], "{}", right.title.name);
                assert_eq!(right.role, ROLE_GAMBLE);
            }
            exclude.extend([left.title.id, right.title.id]);
            rounds += 1;
        }
        assert!(rounds >= 2, "{rounds}");
        // asking changed nothing of the trio
        let again = tonight(&db, NOW + 60, 0, None).unwrap().unwrap();
        assert_eq!(
            again.cards.iter().map(|c| c.title.id).collect::<Vec<_>>(),
            cards
        );
    }

    #[test]
    fn the_loser_of_a_duel_tires_from_the_next_session() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        // the taste's first title loses, twice in one session: one showing
        choose(&db, safe_two, safe_one, NOW - DAY, 0).unwrap();
        choose(&db, safe_two, safe_one, NOW - DAY + 60, 0).unwrap();
        assert_eq!(db.interests(0).unwrap(), [(safe_two, true)]);
        assert_eq!(db.tonight_exposure().unwrap()[&safe_one].cards, 1);
        // the next session it has sunk a band, and the winner leads
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, safe_two, "{:?}", names(&trio));
        assert!(trio.more.iter().any(|t| t.id == safe_one));
    }

    #[test]
    fn a_duel_loser_that_becomes_a_card_the_same_session_is_counted_as_shown() {
        let db = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&db);
        tonight(&db, NOW, 0, None).unwrap().unwrap();
        choose(&db, safe_one, safe_two, NOW + 60, 0).unwrap();
        // the loss is not tonight's to weigh: the card in front goes, and
        // the loser steps in as the next of its role
        defer(&db, safe_one, NOW + 120, 0).unwrap();
        let trio = tonight(&db, NOW + 180, 0, None).unwrap().unwrap();
        assert_eq!(trio.cards[0].title.id, safe_two, "{:?}", names(&trio));
        let shown: Vec<i64> = db
            .conn()
            .prepare("SELECT title_id FROM tonight_shown WHERE evening = ?1")
            .unwrap()
            .query_map([EVENING], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(shown.contains(&safe_two), "{shown:?}");
    }

    /// A card frozen by the variety stays when the hour moves the order of
    /// the tastes under it: the freeze outranks every reordering.
    #[test]
    fn a_safe_bet_chosen_by_variety_holds_when_the_hour_reorders_the_tastes() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let spend = |name: String, facet: u32, at: i64| {
            let id = film(&db, &name, 6000.0);
            played(&db, id, 1, at);
            spent_in(&db, id, facet);
        };
        // weeknights at 22:00 are facet 0, then 2; the class adds facet 1 late
        for week in 1..=8 {
            spend(
                format!("Late 0 {week}"),
                0,
                (EVENING - 7 * week) * DAY + 22 * 3_600,
            );
        }
        for week in 1..=5 {
            spend(
                format!("Late 2 {week}"),
                2,
                (EVENING - 7 * week) * DAY + 22 * 3_600,
            );
        }
        for week in 1..=6 {
            spend(
                format!("Night 1 {week}"),
                1,
                (EVENING - 7 * week) * DAY + 23 * 3_600 + 1_800,
            );
        }
        // and the two evenings before were both facet 0: the variety fires
        spend("Monday".into(), 0, (EVENING - 2) * DAY + 19 * 3_600);
        spend("Tuesday".into(), 0, (EVENING - 1) * DAY + 19 * 3_600);
        db.set_evening_state(EVENING, &window(300)).unwrap();

        let facets = db.taste_facets().unwrap();
        let ends = db.watched_facet_ends().unwrap();
        assert_eq!(facet_order(&ends, &facets, 0, NOW - 600), [0, 1, 2]);
        assert_eq!(facet_order(&ends, &facets, 0, NOW + 600), [0, 2, 1]);

        let before = tonight(&db, NOW - 600, 0, None).unwrap().unwrap();
        assert_eq!(before.cards[0].title.name, "Mood", "{:?}", names(&before));
        let after = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert_eq!(after.cards[0].title.name, "Mood", "{:?}", names(&after));
    }

    #[test]
    fn two_pages_of_one_taste_lead_the_lane_and_leave_the_cards_alone() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        // two strangers of the third taste, so that one is in the lane
        // whichever of the band the gamble turns up
        let third = [
            film(&db, "Disco Three", 6000.0),
            film(&db, "Disco Four", 6000.0),
        ];
        let disco_one = title_by_name(&db, "Disco One");
        let disco_two = title_by_name(&db, "Disco Two");
        let other_one = title_by_name(&db, "Other One");
        let other_two = title_by_name(&db, "Other Two");
        let mut out = pass(
            db.conn()
                .prepare("SELECT title_id, facet, leader FROM taste_pick ORDER BY rank")
                .unwrap()
                .query_map([], |r| Ok(pick(r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap(),
            db.taste_facets().unwrap(),
            &[disco_one, disco_two, third[0], third[1]],
        );
        out.title_taste = [third[0], third[1], other_one, other_two]
            .into_iter()
            .map(|title_id| crate::index::db::TitleTasteRow {
                title_id,
                facet: 2,
                affinity: 0.5,
                rejected: String::new(),
            })
            .collect();
        db.replace_taste(&out).unwrap();
        let before = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(before.more[0].name, "Safe Two", "{:?}", before.more);

        db.record_interest(other_one, crate::index::db::TASTE_DWELL, NOW - 3_000)
            .unwrap();
        db.record_interest(other_two, crate::index::db::TASTE_DWELL, NOW + 300)
            .unwrap();
        let after = tonight(&db, NOW + 600, 0, None).unwrap().unwrap();
        assert!(third.contains(&after.more[0].id), "{:?}", after.more);
        assert_eq!(names(&after), names(&before));

        // pages opened three hours ago are another sitting, at midnight past
        // an estimated bedtime the viewer has since pushed back
        db.set_evening_state(EVENING, &window(240)).unwrap();
        let later = tonight(&db, NOW + 3 * 3_600 + 400, 0, None)
            .unwrap()
            .unwrap();
        assert_eq!(later.more[0].name, "Safe Two", "{:?}", later.more);
    }

    #[test]
    fn rain_leans_the_evening_to_its_comforting_titles_and_nothing_else_does() {
        let db = Db::open_in_memory().unwrap();
        let (_, safe_two) = library(&db);
        with_lists(&db, &[("cosy", &[safe_two])]);
        let rain = Ambient {
            weather: Weather::Rain,
            dark_early: false,
        };

        let dry = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(dry.cards[0].title.name, "Safe One");
        let hot = Ambient {
            weather: Weather::Hot,
            dark_early: false,
        };
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        let warm = tonight(&db, NOW, 0, Some(hot)).unwrap().unwrap();
        assert_eq!(warm.cards[0].title.name, "Safe One");

        db.replace_tonight_picks(EVENING, &[], 0).unwrap();
        let wet = tonight(&db, NOW, 0, Some(rain)).unwrap().unwrap();
        assert_eq!(wet.cards[0].title.id, safe_two, "{:?}", names(&wet));
        // and a card already shown stays where it is when the rain starts
        let fresh = Db::open_in_memory().unwrap();
        let (safe_one, safe_two) = library(&fresh);
        with_lists(&fresh, &[("cosy", &[safe_two])]);
        tonight(&fresh, NOW, 0, None).unwrap().unwrap();
        let later = tonight(&fresh, NOW + 600, 0, Some(rain)).unwrap().unwrap();
        assert_eq!(later.cards[0].title.id, safe_one);
    }

    #[test]
    fn a_chosen_guest_hands_the_safe_bet_to_what_both_would_watch_and_narrows_the_gamble() {
        let db = Db::open_in_memory().unwrap();
        library(&db);
        let safe_two = title_by_name(&db, "Safe Two");
        let other_two = title_by_name(&db, "Other Two");
        let disco_two = title_by_name(&db, "Disco Two");
        let guest = db.add_guest("Sam", NOW).unwrap();
        db.set_evening_state(
            EVENING,
            &EveningAnswers {
                together: true,
                guest_id: Some(guest),
                ..Default::default()
            },
        )
        .unwrap();
        // a guest nothing measured yet leaves the evening as it was
        let unmeasured = tonight(&db, NOW, 0, None).unwrap().unwrap();
        assert_eq!(
            unmeasured.cards[0].title.name,
            "Safe One",
            "{:?}",
            names(&unmeasured)
        );
        db.replace_tonight_picks(EVENING, &[], 0).unwrap();

        for (id, affinity) in [(safe_two, 0.3), (other_two, 0.8)] {
            db.conn()
                .execute(
                    "INSERT INTO title_taste (title_id, facet, affinity, rejected) VALUES (?1, 0, ?2, '')",
                    rusqlite::params![id, affinity],
                )
                .unwrap();
        }
        // the lesser of the two decides: Other Two is the owner's favourite
        // and only half the guest's, Safe Two is well liked by both
        db.replace_guest_taste(
            guest,
            &[(other_two, 0.2), (safe_two, 0.9), (disco_two, 0.6)],
        )
        .unwrap();
        let trio = tonight(&db, NOW, 0, None).unwrap().unwrap();
        let card = |role| {
            trio.cards
                .iter()
                .find(|c| c.role == role)
                .map(|c| c.title.name.clone())
        };
        assert_eq!(
            card(ROLE_SAFE).as_deref(),
            Some("Safe Two"),
            "{:?}",
            names(&trio)
        );
        assert_eq!(
            card(ROLE_GAMBLE).as_deref(),
            Some("Disco Two"),
            "{:?}",
            names(&trio)
        );
        // the lane holds only what the guest's taste let through
        assert!(
            trio.more.iter().all(|t| t.name != "Disco One"),
            "{:?}",
            trio.more
        );
    }
}
