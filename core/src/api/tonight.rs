use super::library::{to_item, TitleItem};
use super::{unix_now, CoreError, LexisCore};
use crate::index::tonight::PASSES_SETTING as TONIGHT_PASSES;

impl LexisCore {
    /// What the app said about the weather, while it still holds.
    pub(crate) fn ambient_at(&self, now: i64) -> Option<crate::index::tonight::Ambient> {
        self.ambient
            .lock()
            .filter(|(_, at)| now - at < crate::index::tonight::AMBIENT_LIFE_SECS)
            .map(|(ambient, _)| ambient)
    }

    pub(crate) fn set_ambient_at(&self, ambient: Option<Ambient>, now: i64) {
        use crate::index::tonight::Weather;
        *self.ambient.lock() = ambient.map(|a| {
            let weather = match a.weather {
                WeatherKind::Clear => Weather::Clear,
                WeatherKind::Rain => Weather::Rain,
                WeatherKind::Snow => Weather::Snow,
                WeatherKind::Cold => Weather::Cold,
                WeatherKind::Hot => Weather::Hot,
                WeatherKind::Other => Weather::Other,
            };
            let ambient = crate::index::tonight::Ambient {
                weather,
                dark_early: a.dark_early,
            };
            (ambient, now)
        });
    }

    /// `tonight` at a chosen clock, which is what a test needs an evening to
    /// be. Composed on the heavy reader and only recorded on the write
    /// connection, which a scan or a playback report may be holding.
    pub(crate) fn tonight_at(
        &self,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<Option<TonightTrio>, CoreError> {
        let ambient = self.ambient_at(now);
        let composed = crate::index::tonight::compose_tonight(
            &self.heavy_db.lock(),
            now,
            tz_offset_secs,
            ambient,
        )?;
        let trio = match composed {
            Some((trio, record)) => {
                crate::index::tonight::record_tonight(&self.db.lock(), &record)?;
                Some(trio)
            }
            None => None,
        };
        Ok(trio.map(|t| TonightTrio {
            bedtime_minutes: (t.bedtime_min
                + if t.afternoon {
                    crate::index::tonight::AFTERNOON_START_MIN
                } else {
                    crate::index::tonight::EVENING_START_MIN
                })
                % 1_440,
            passes_left: t.passes_left,
            afternoon: t.afternoon,
            more: t.more.into_iter().map(to_item).collect(),
            cards: t.cards.into_iter().map(to_card).collect(),
            gaps: t
                .gaps
                .into_iter()
                .map(|(role, reason)| TonightGap {
                    role: to_role(role),
                    reason: match reason {
                        crate::index::tonight::Gap::NoTime => TonightGapReason::NoTime,
                        crate::index::tonight::Gap::Exhausted => TonightGapReason::Exhausted,
                    },
                })
                .collect(),
        }))
    }

    pub(crate) fn tonight_defer_at(
        &self,
        title_id: i64,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<Option<TonightTrio>, CoreError> {
        {
            let db = self.db.lock();
            crate::index::tonight::defer(&db, title_id, now, tz_offset_secs)?;
        }
        self.tonight_at(now, tz_offset_secs)
    }

    pub(crate) fn this_or_that_at(
        &self,
        exclude: &[i64],
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<Option<Duel>, CoreError> {
        let ambient = self.ambient_at(now);
        let db = self.read_db.lock();
        let duel = crate::index::tonight::this_or_that(&db, now, tz_offset_secs, ambient, exclude)?;
        Ok(duel.map(|(left, right)| Duel {
            left: to_card(left),
            right: to_card(right),
        }))
    }

    pub(crate) fn set_evening_at(
        &self,
        together: bool,
        window_minutes: Option<u32>,
        mood: Option<String>,
        guest_id: Option<i64>,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<Option<TonightTrio>, CoreError> {
        if let Some(key) = &mood {
            if !crate::index::taste::MOODS.iter().any(|(k, _)| k == key) {
                return Err(CoreError::Storage {
                    msg: format!("unknown mood {key}"),
                });
            }
        }
        if let Some(session) = crate::index::tonight::session_of(now, tz_offset_secs) {
            let answers = crate::index::db::EveningAnswers {
                together: together || guest_id.is_some(),
                window_min: window_minutes,
                mood,
                guest_id,
            };
            let chosen = {
                let db = self.db.lock();
                let before = db.evening_state(session)?.guest_id;
                db.set_evening_state(session, &answers)?;
                // the frozen picks answered the old question
                db.replace_tonight_picks(session, &[], 0)?;
                guest_id.filter(|g| before != Some(*g))
            };
            // a guest newly chosen is measured now, on the press, so the trio
            // asked every minute reads their taste rather than sweeping for it
            if let Some(guest) = chosen {
                let ranked = {
                    let db = self.heavy_db.lock();
                    crate::index::duo::rank(&db, now, tz_offset_secs, Some(guest), &[], &[])?
                };
                self.db.lock().replace_guest_taste(guest, &ranked.taste)?;
            }
        }
        self.tonight_at(now, tz_offset_secs)
    }
}

/// The three slots of the Tonight block, in the order they are drawn. Each
/// says a level of commitment rather than a mood.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TonightRole {
    /// Watched, liked, and away long enough to have been missed.
    Familiar,
    /// Never watched, and squarely inside the taste.
    SafeBet,
    /// Never watched, and deliberately outside it.
    Gamble,
}

/// One Tonight card. `seed` names the watched title the role argues from,
/// and is empty on a discovery. `runtime_secs` is one episode's for a show
/// (`episode` says so), a film's otherwise.
#[derive(Debug, uniffi::Record)]
pub struct TonightCard {
    pub item: TitleItem,
    pub role: TonightRole,
    pub seed: String,
    /// What this card costs of the evening, which for a card the viewer is
    /// already in the middle of is what is LEFT of it and not its whole length.
    pub runtime_secs: u32,
    pub episode: bool,
    /// How close to the taste it sits, 0 to 1, on the gamble alone: the one
    /// card with no watched title to argue from. 0 on the other two.
    pub closeness: f32,
    /// The file to carry on with, when this card is something already started.
    /// None plays from the beginning, which is every other card.
    pub resume_file_id: Option<i64>,
    pub resume_position_secs: f64,
    /// Which episode carrying on would play. Both absent on a film, and on an
    /// episode nothing numbered.
    pub resume_season: Option<u16>,
    pub resume_episode: Option<u16>,
    /// How many times this was played through, and when it last was. Both
    /// nought on every role but the familiar, which is what they describe.
    pub plays: u32,
    pub last_watched_at: i64,
}

fn to_card(c: crate::index::tonight::TonightRow) -> TonightCard {
    TonightCard {
        role: to_role(c.role),
        item: to_item(c.title),
        seed: c.seed,
        runtime_secs: c.runtime_secs as u32,
        episode: c.episode,
        closeness: c.closeness,
        resume_file_id: c.resume.map(|r| r.file_id),
        resume_position_secs: c.resume.map_or(0.0, |r| r.position_secs),
        resume_season: c.resume.and_then(|r| r.season),
        resume_episode: c.resume.and_then(|r| r.episode),
        plays: c.plays,
        last_watched_at: c.last_watched_at,
    }
}

fn to_role(role: u32) -> TonightRole {
    match role {
        crate::index::tonight::ROLE_FAMILIAR => TonightRole::Familiar,
        crate::index::tonight::ROLE_SAFE => TonightRole::SafeBet,
        _ => TonightRole::Gamble,
    }
}

/// A role with no card tonight, and why. The block draws these rather than
/// hiding: a viewer told there is no time left for a discovery can go to bed
/// later, and a viewer shown the daytime hero instead learns nothing.
#[derive(Debug, uniffi::Record)]
pub struct TonightGap {
    pub role: TonightRole,
    pub reason: TonightGapReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TonightGapReason {
    /// Every candidate of the role runs past the end of the evening.
    NoTime,
    /// The role has nothing left to offer at all.
    Exhausted,
}

/// The evening's trio. `bedtime_minutes` is the inferred end of the evening,
/// in minutes after local midnight (23:15 is 1395), for the app to render.
#[derive(Debug, uniffi::Record)]
pub struct TonightTrio {
    pub cards: Vec<TonightCard>,
    /// The runners-up, best first: the same evening's ranking without the
    /// roles, the reasons or the finishing times, which are worth three cards
    /// of the screen and are noise on the tenth. Empty is ordinary - a thin
    /// library has three candidates and no more.
    pub more: Vec<TitleItem>,
    pub bedtime_minutes: u32,
    /// How many refusals the evening has left. At nought the screen stops
    /// drawing the gesture, and the core stops honouring it either way.
    pub passes_left: u32,
    /// The roles with nothing to show tonight. Empty on a full trio.
    pub gaps: Vec<TonightGap>,
    /// A weekend afternoon's trio, which the screen names as the afternoon;
    /// `bedtime_minutes` is then when the afternoon's film has to be over.
    pub afternoon: bool,
}

/// Two titles to choose between. Both fit what is left of the session, and
/// neither is one of its cards.
#[derive(Debug, uniffi::Record)]
pub struct Duel {
    pub left: TonightCard,
    pub right: TonightCard,
}

/// The sky, as the app read it off the weather service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WeatherKind {
    Clear,
    Rain,
    Snow,
    Cold,
    Hot,
    Other,
}

/// What the world outside says about the session. `dark_early` is a sunset
/// before 18:30.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Ambient {
    pub weather: WeatherKind,
    pub dark_early: bool,
}

/// What the screen assumed about tonight, and what is left of its budget.
#[derive(Debug, uniffi::Record)]
pub struct EveningState {
    pub together: bool,
    /// Minutes from now, when the viewer corrected the window. None leaves
    /// the bedtime estimator to answer.
    pub window_minutes: Option<u32>,
    pub passes_left: u32,
    /// The mood asked of the session, a key of the moods `moods` lists.
    pub mood: Option<String>,
    /// Who the viewer watches with, one of `guests`.
    pub guest_id: Option<i64>,
}

#[uniffi::export]
impl LexisCore {
    /// How many times an evening may be refused before its trio stands.
    pub fn tonight_passes(&self) -> Result<u32, CoreError> {
        let db = self.read_db.lock();
        Ok(db
            .setting(TONIGHT_PASSES)?
            .and_then(|v| v.parse().ok())
            .unwrap_or(crate::index::tonight::PASSES))
    }

    pub fn set_tonight_passes(&self, passes: u32) -> Result<(), CoreError> {
        if !matches!(passes, 1 | 3 | 5) {
            return Err(CoreError::Storage {
                msg: format!("unknown pass budget {passes}"),
            });
        }
        let db = self.db.lock();
        db.set_setting(TONIGHT_PASSES, &passes.to_string())?;
        Ok(())
    }

    /// Accepts that proposal: the title leads the next evening's trio.
    pub fn queue_tonight(&self, title_id: i64) -> Result<(), CoreError> {
        let db = self.db.lock();
        db.queue_tonight(title_id, unix_now())?;
        Ok(())
    }

    /// What the app assumed about tonight, and what the viewer corrected.
    /// `window_minutes` absent leaves the bedtime estimator to answer.
    pub fn evening(&self, tz_offset_secs: i32) -> Result<EveningState, CoreError> {
        self.evening_at(unix_now(), tz_offset_secs)
    }

    pub(crate) fn evening_at(
        &self,
        now: i64,
        tz_offset_secs: i32,
    ) -> Result<EveningState, CoreError> {
        let db = self.read_db.lock();
        let answers = match crate::index::tonight::session_of(now, tz_offset_secs) {
            Some(session) => db.evening_state(session)?,
            None => Default::default(),
        };
        Ok(EveningState {
            together: answers.together,
            window_minutes: answers.window_min,
            passes_left: crate::index::tonight::passes_left(&db, now, tz_offset_secs)?,
            mood: answers.mood,
            guest_id: answers.guest_id,
        })
    }

    /// Corrects one of the assumptions: company, time, or the mood asked of
    /// the session. The trio is recomposed against the new answer, which is
    /// why this hands it back.
    pub fn set_evening(
        &self,
        together: bool,
        window_minutes: Option<u32>,
        mood: Option<String>,
        guest_id: Option<i64>,
        tz_offset_secs: i32,
    ) -> Result<Option<TonightTrio>, CoreError> {
        self.set_evening_at(
            together,
            window_minutes,
            mood,
            guest_id,
            unix_now(),
            tz_offset_secs,
        )
    }

    /// The Tonight trio, or nothing: outside evening hours, on a fingerprint
    /// too thin for a second taste, or when not one of the three roles has a
    /// card that finishes before bedtime. A role that alone cannot be filled
    /// comes back in `gaps` instead, so the block says what is missing rather
    /// than vanishing.
    pub fn tonight(&self, tz_offset_secs: i32) -> Result<Option<TonightTrio>, CoreError> {
        self.tonight_at(unix_now(), tz_offset_secs)
    }

    /// "Not tonight": the card leaves the trio for a fortnight without a
    /// verdict, and the refreshed trio answers in its place.
    pub fn tonight_defer(
        &self,
        title_id: i64,
        tz_offset_secs: i32,
    ) -> Result<Option<TonightTrio>, CoreError> {
        self.tonight_defer_at(title_id, unix_now(), tz_offset_secs)
    }

    /// Two titles to choose between tonight, neither a card of the trio nor
    /// one of `exclude`: what the duel screen asks round after round.
    pub fn this_or_that(
        &self,
        tz_offset_secs: i32,
        exclude: Vec<i64>,
    ) -> Result<Option<Duel>, CoreError> {
        self.this_or_that_at(&exclude, unix_now(), tz_offset_secs)
    }

    /// One duel's answer: the winner leans the taste its way at the next
    /// refresh, and the loser tires like a card passed over.
    pub fn choose(&self, winner: i64, loser: i64, tz_offset_secs: i32) -> Result<(), CoreError> {
        let db = self.db.lock();
        crate::index::tonight::choose(&db, winner, loser, unix_now(), tz_offset_secs)?;
        Ok(())
    }

    /// What the sky says, or None when the app could not read it. Held for
    /// three hours, in memory only.
    pub fn set_ambient(&self, ambient: Option<Ambient>) {
        self.set_ambient_at(ambient, unix_now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::testing::*;
    use std::sync::Arc;

    #[test]
    fn tonight_answers_over_the_ffi_and_defers() {
        use crate::index::db::{
            Db, DiscoveryPick, FileMedia, FileRecord, TasteFacetMeta, TastePassOutput, TastePick,
        };
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let film = |name: &str| -> i64 {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{name}.mkv"),
                size: 1,
                mtime: 0,
                seen_gen: 1,
                title_id: id,
                season: None,
                episode: None,
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            db.conn()
                .execute(
                    "UPDATE files SET duration_secs = 6000 WHERE title_id = ?1",
                    [id],
                )
                .unwrap();
            id
        };
        let leader_a = film("Leader A");
        let leader_b = film("Leader B");
        let safe_one = film("Safe One");
        let safe_two = film("Safe Two");
        let mood = film("Mood");
        let disco = film("Disco");
        db.replace_taste(&TastePassOutput {
            picks: [
                TastePick {
                    title_id: safe_one,
                    facet: 0,
                    leader: leader_a,
                },
                TastePick {
                    title_id: safe_two,
                    facet: 0,
                    leader: leader_a,
                },
                TastePick {
                    title_id: mood,
                    facet: 1,
                    leader: leader_b,
                },
            ]
            .into(),
            facets: [
                TasteFacetMeta {
                    facet: 0,
                    weight: 3.0,
                    leader: leader_a,
                    cos_to_top: 1.0,
                },
                TasteFacetMeta {
                    facet: 1,
                    weight: 1.0,
                    leader: leader_b,
                    cos_to_top: 0.2,
                },
            ]
            .into(),
            discovery: vec![DiscoveryPick {
                title_id: disco,
                closeness: 0.5,
            }],
            ..Default::default()
        })
        .unwrap();

        // a weeknight, 21:00, read at tz 0
        const NOW: i64 = 20_685 * 86_400 + 21 * 3_600;
        let trio = core.tonight_at(NOW, 0).unwrap().unwrap();
        // nothing here was ever watched, so the familiar role has no card
        assert_eq!(trio.cards.len(), 2);
        assert!(matches!(trio.cards[0].role, TonightRole::SafeBet));
        assert!(matches!(trio.cards[1].role, TonightRole::Gamble));
        assert_eq!(trio.cards[0].item.name, "Safe One");
        assert_eq!(trio.cards[0].seed, "Leader A");
        assert_eq!(trio.cards[0].runtime_secs, 6_000);
        assert!(!trio.cards[0].episode);
        assert_eq!(trio.cards[1].seed, "");
        // 23:15 as minutes after local midnight
        assert_eq!(trio.bedtime_minutes, 1_395);

        let deferred = core
            .tonight_defer_at(trio.cards[0].item.id, NOW, 0)
            .unwrap()
            .unwrap();
        assert_eq!(deferred.cards[0].item.name, "Safe Two");

        // a duel only reads, so a writer holding the write connection does not
        // hold it up
        let held = core.db.lock();
        let (tx, rx) = std::sync::mpsc::channel();
        let asker = Arc::clone(&core);
        std::thread::spawn(move || tx.send(asker.this_or_that_at(&[], NOW, 0).is_ok()).unwrap());
        let answered = rx.recv_timeout(std::time::Duration::from_secs(2));
        drop(held);
        assert_eq!(answered, Ok(true));
    }

    /// A mood said over the FFI recomposes the frozen trio at once, an
    /// unknown one is refused, and the weather the app reports leans the
    /// evening for three hours and then no more.
    #[test]
    fn the_evening_takes_a_mood_and_the_weather_over_the_ffi() {
        use crate::index::db::{
            Db, DiscoveryPick, FileMedia, FileRecord, TasteFacetMeta, TastePassOutput, TastePick,
        };
        use crate::index::MediaKind;

        let cache = tempfile::tempdir().unwrap();
        let store = Arc::new(MemStore::default());
        let core = LexisCore::new(cache.path().to_string_lossy().into_owned(), store).unwrap();
        let db = Db::open(&cache.path().join("index.sqlite")).unwrap();
        let film = |name: &str| -> i64 {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Movies".into(),
                path: format!("Movies/{name}.mkv"),
                size: 1,
                mtime: 0,
                seen_gen: 1,
                title_id: id,
                season: None,
                episode: None,
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            db.conn()
                .execute(
                    "UPDATE files SET duration_secs = 6000 WHERE title_id = ?1",
                    [id],
                )
                .unwrap();
            id
        };
        let leader = film("Leader A");
        let safe_one = film("Safe One");
        let safe_two = film("Safe Two");
        let funny = film("Funny");
        let disco = film("Disco");
        db.replace_taste(&TastePassOutput {
            picks: [
                TastePick {
                    title_id: safe_one,
                    facet: 0,
                    leader,
                },
                TastePick {
                    title_id: safe_two,
                    facet: 0,
                    leader,
                },
            ]
            .into(),
            facets: [TasteFacetMeta {
                facet: 0,
                weight: 3.0,
                leader,
                cos_to_top: 1.0,
            }]
            .into(),
            discovery: vec![DiscoveryPick {
                title_id: disco,
                closeness: 0.5,
            }],
            seasonal: vec![
                ("light".into(), vec![funny]),
                ("cosy".into(), vec![safe_two]),
            ],
            ..Default::default()
        })
        .unwrap();

        // a weeknight, 21:00, read at tz 0
        const NOW: i64 = 20_685 * 86_400 + 21 * 3_600;
        assert_eq!(
            core.tonight_at(NOW, 0).unwrap().unwrap().cards[0].item.id,
            safe_one
        );
        let light = core
            .set_evening_at(false, None, Some("light".into()), None, NOW, 0)
            .unwrap()
            .unwrap();
        assert_eq!(light.cards[0].item.id, funny);
        assert_eq!(
            core.evening_at(NOW, 0).unwrap().mood.as_deref(),
            Some("light")
        );
        assert!(core
            .set_evening_at(false, None, Some("glum".into()), None, NOW, 0)
            .is_err());
        core.set_evening_at(false, None, None, None, NOW, 0)
            .unwrap();

        // rain, reported at 21:00, leans the recomposed evening to the cosy
        core.set_ambient_at(
            Some(Ambient {
                weather: WeatherKind::Rain,
                dark_early: false,
            }),
            NOW,
        );
        let evening = crate::index::tonight::evening_of(NOW, 0).unwrap();
        db.replace_tonight_picks(evening, &[], 0).unwrap();
        assert_eq!(
            core.tonight_at(NOW + 60, 0).unwrap().unwrap().cards[0]
                .item
                .id,
            safe_two
        );
        // three hours on it says nothing more
        db.replace_tonight_picks(evening, &[], 0).unwrap();
        db.set_evening_state(
            evening,
            &crate::index::db::EveningAnswers {
                window_min: Some(200),
                ..Default::default()
            },
        )
        .unwrap();
        let later = NOW + crate::index::tonight::AMBIENT_LIFE_SECS;
        assert_eq!(
            core.tonight_at(later, 0).unwrap().unwrap().cards[0].item.id,
            safe_one
        );

        // and a duel steps around the trio
        let duel = core.this_or_that_at(&[], NOW, 0).unwrap();
        assert!(duel.is_none(), "{duel:?}");
    }
}
