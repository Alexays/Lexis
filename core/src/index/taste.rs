//! The viewer's taste, as a handful of directions in the embedding space, and
//! the row those directions pick out of the library.
//!
//! One average of a whole history describes nobody: someone who watches horror
//! and children's films does not want the midpoint of the two, and the nearest
//! titles to that midpoint belong to neither taste. So the fingerprint is a
//! few directions, not one, each with the share of the history that stands
//! behind it, and the row is dealt out between them in proportion.
//!
//! Nothing here reads a tmdb_id. TMDB strengthens the ranking where it has
//! something to say (see `fuse`) and is absent otherwise, so the row exists on
//! a device that has never had a key.

use super::db::{
    Db, DiscoveryPick, IndexError, TasteFacetMeta, TastePassOutput, TastePick, TitleTasteRow,
    TitleVector, WatchedFile,
};
use super::{MediaKind, Verdict};
use crate::embed::pass::MAX_VECTORS;
use crate::embed::space::Space;
use crate::embed::Encoder;
use std::collections::HashMap;

/// How many tastes the fingerprint may hold. Four fits a shelf: the first
/// screenful of a twenty-title row shows five or six, so every facet is on
/// screen at once and the mix is visible rather than inferred. Past that the
/// facets stop being tastes and start being slices of one, which the owner's
/// own library shows plainly: at six, two of them are the same action films
/// twice and the row reaches down to titles the fingerprint barely matches.
pub const FACETS: usize = 4;

/// How long it takes a play to weigh half of what it did the evening it
/// happened. Three months: what was watched last week decides tonight, what
/// was watched last spring still counts for something.
const HALF_LIFE_SECS: f32 = 90.0 * 86_400.0;

/// What a play never decays below, however old. Without a floor a history
/// whose last month is thin collapses onto whatever was watched most recently,
/// and one evening's viewing becomes the whole fingerprint. Seven years of
/// this library's watch state is a taste; the floor is what keeps it in.
const RECENCY_FLOOR: f32 = 0.15;

/// What a stated "I liked this" is worth, against a play.
///
/// One: exactly what a film finished this evening weighs, and no more. A
/// verdict is better evidence than a play - it is deliberate, and it is about
/// the film rather than about an evening - but it is evidence about one title,
/// not a claim that the title outranks a history. The strongest thing the
/// model already knows is the ceiling it is allowed to reach.
///
/// It is a flat number and there is no age term beside it, which is the whole
/// difference from `play_weight`. The half-life there exists because a play is
/// an event and the model has to guess whether it still speaks for the viewer;
/// a verdict is that statement made out loud, so there is nothing left to
/// guess. What bounds it instead is that the next press on the same title
/// replaces it, and clearing it removes it.
const LIKED_WEIGHT: f32 = 1.0;

/// What "adoré" is worth: two films finished this evening. A loved title seeds
/// a facet, steers its centre and claims a share of the row like two of them.
/// Higher was tried against the owner's history and is not a level, it is a
/// takeover: at four, one press is an eighth of a 750-title fingerprint and
/// the whole home screen becomes one film's neighbours.
const LOVED_WEIGHT: f32 = 2.0;

/// How much of its place a candidate loses for what it shares with something
/// the viewer rejected. A half: a title as close to the rejection as it is to
/// the taste keeps half its score, one that shares nothing with the rejection
/// loses nothing at all, and a near-twin of a rejected film falls through the
/// floor in `nearest` and leaves the row.
///
/// It cannot empty a facet, and that is structural rather than clamped: what
/// is measured is only the part of the rejected title the taste does not
/// already explain (see `Distaste`), so the candidates sitting closest to a
/// facet's centre - the ones that lead its list - are the ones it can reach
/// least. A viewer who likes horror and rejects one horror film loses that
/// film and whatever else is distinctively like it, never horror.
pub(crate) const DISLIKE_PULL: f32 = 0.5;

/// How many rejections steer the row. Each one costs a pass over the library's
/// vectors here, and thirty-two distinct directions is already far more shape
/// than a four-facet fingerprint holds; past that the newest press would be
/// buying an ever-smaller correction with the same work. Beyond the cut the
/// titles themselves still stay out of the row - that costs nothing, it is the
/// `seen` flag - they simply stop pulling their neighbours down with them.
const MAX_DISTASTE: usize = 32;

/// How much of the way from "anything in this library" to "the films that
/// built this taste" a title has to stand before the fingerprint claims a
/// kinship out loud.
///
/// Without a floor the detail screen says "in the vein of Divergent, at 0%",
/// which is three claims that contradict each other: the affinity is clamped
/// at zero precisely when the title is no closer to the taste than anything
/// else on the shelf, and naming the leader anyway asserts a resemblance the
/// number beside it denies. A fifth of the way is a judgement and not a
/// measurement - it is the point below which nothing a viewer would recognise
/// as kinship is left.
const MIN_AFFINITY: f32 = 0.2;

/// How much of a rejected title this one has to carry, once the taste has
/// taken its own part out, before that rejection is worth naming.
///
/// The clause only ever qualifies a kinship: "closer to your taste were it not
/// for what it shares with this". A residue of five hundredths of a cosine is
/// noise, and naming it reads as an accusation the ranking never made.
const MIN_SHARED: f32 = 0.15;

/// Under what share of its runtime a title left unfinished reads as given up
/// on rather than as the start of something. A quarter: past that the viewer
/// sat through a whole act, which is a verdict on nothing.
const ABANDON_SHARE: f32 = 0.25;

/// How long a title has to have run before stopping it says anything. Under
/// five minutes it is a check of the picture or the sound, not an opinion.
const ABANDON_MIN_SECS: f64 = 300.0;

/// How long a title has to lie untouched before it is given up on. A fortnight:
/// a film stopped on a Tuesday and finished on the Sunday was an evening cut
/// short, not a no.
const ABANDON_AFTER_SECS: i64 = 14 * 86_400;

/// What an abandoned title pulls its neighbours back by, against a thumb
/// down's `DISLIKE_PULL`: a no said by walking away is quieter than one said
/// out loud, and its reasons are less certain (a phone call, a late hour).
const ABANDON_PULL: f32 = 0.2;

/// What each doubling of the viewings adds to a title, as a share of one:
/// seen four times is 1 + ln 4 / 2, about 1.7. Logarithmic, so the film a
/// child has seen forty times does not become the whole fingerprint.
const REWATCH_BONUS: f32 = 0.5;

/// How many episodes finished within `BINGE_WINDOW_SECS` make a binge: past a
/// few in a week, a series is what the evenings were for.
const BINGE_EPISODES: usize = 4;

const BINGE_WINDOW_SECS: i64 = 7 * 86_400;

/// What a binged series weighs at least, before the age of its last episode is
/// taken into account: one and a half films, since one title took a week.
const BINGE_WEIGHT: f32 = 1.5;

/// How many refusals of one title, within `DEFER_WINDOW_SECS`, make a pattern
/// rather than a series of evenings that were not right for it.
const DEFER_REPEAT: u32 = 3;

const DEFER_WINDOW_SECS: i64 = 60 * 86_400;

/// What a title refused again and again pulls its neighbours back by: the
/// faintest of the three, since "not tonight" is still not "never".
const DEFER_PULL: f32 = 0.1;

/// What a gesture of interest in an unseen title weighs: a page read, a trailer
/// watched, a title put on the list. Under a third of a film finished tonight:
/// the title pulls the centre of the taste nearest it, and never seeds or
/// names a facet of its own.
const INTEREST_WEIGHT: f32 = 0.3;

/// What choosing a title over another weighs: a gesture, and a decided one.
const CHOSEN_WEIGHT: f32 = 0.5;

/// How long a gesture of interest counts for. A page read last month and not
/// followed up was a passing curiosity.
const INTEREST_WINDOW_SECS: i64 = 30 * 86_400;

/// How old a facet's history has to be, at its weighted median, to be a taste
/// the viewer has kept rather than one they have moved on from. Such a facet
/// decays on `STABLE_HALF_LIFE_SECS` instead: a genre watched for years and
/// not this season is resting, not gone.
const STABLE_AGE_SECS: i64 = 365 * 86_400;

const STABLE_HALF_LIFE_SECS: f32 = HALF_LIFE_SECS * 3.0;

/// Refinement rounds after the facets are seeded. Spherical k-means on a few
/// hundred points settles in two or three; the count is fixed rather than
/// convergence-tested so the row is the same on every pass.
const ROUNDS: usize = 3;

/// How deep the stored row goes. The home screen shows twenty, and the rest is
/// the margin that keeps it twenty when the read filters out what has been
/// watched or unshelved since the pass ran.
pub const PICKS: usize = 60;

/// How long "not because of this" holds, and what it leaves of the contested
/// taste: its members keep a third of their weight, so the facet shrinks in
/// the row without the history that made it being denied.
pub const MUTE_SECS: i64 = 30 * 86_400;
const MUTE_FACTOR: f32 = 0.3;

/// One taste: the direction it points, the share of the history behind it, the
/// title that names it (the watched member sitting nearest that direction, and
/// the seed TMDB is asked about), and how close to the direction the films
/// that made it actually sit.
struct Facet {
    centre: Vec<f32>,
    weight: f32,
    leader: i64,
    /// The weighted mean cosine of the facet's own members to `centre`: how
    /// coherent this taste is, and half of what `nearest` cuts on.
    inner: f32,
}

/// Recomputes the taste row from the watch history and the vectors on disk,
/// and replaces what the last pass stored. Returns how many picks it wrote:
/// zero when nothing has been watched, when nothing has been vectorised yet,
/// or when no title has a direction of its own once the direction the whole
/// library shares is taken out. All three leave the home screen without the
/// row rather than with an empty one, and the last is what a taste needs
/// before it can be named after anything: the row promises its contents
/// resemble one title, and there is no resemblance to be had in a library
/// whose vectors all say the same thing.
pub fn refresh(db: &Db, now: i64) -> Result<usize, IndexError> {
    let mean = db.mean_rating()?.map(|m| m.to_string()).unwrap_or_default();
    db.set_setting(super::tonight::RATING_MEAN_SETTING, &mean)?;
    let version = Encoder::chosen(db)?.version();
    let history = db.watch_history(version)?;
    let verdicts = db.verdicts(version)?;
    let deferred = db.repeat_deferrals(now - DEFER_WINDOW_SECS, DEFER_REPEAT)?;
    let interests = db.interests(now - INTEREST_WINDOW_SECS)?;
    let muted = db.muted_tastes(now)?;
    let mut vectors = db.vectors(version, MAX_VECTORS)?;
    // a filmed stage show says nothing of which films the viewer likes, and
    // has a shelf of its own rather than a place among them
    let stage = db.stage_shows()?;
    vectors.retain(|v| !stage.contains(&v.title_id));
    let space = Space::of(&vectors);
    let moods = anchor_cosines(db, version, &vectors, &space, &MOODS)?;
    let tones = tones(&vectors, &moods);
    let (facets, seen, rejected, weight) = fingerprint(
        &history, &verdicts, &deferred, &interests, &muted, &vectors, &space, now,
    );
    if facets.is_empty() {
        db.replace_taste(&TastePassOutput {
            now,
            tones,
            ..Default::default()
        })?;
        db.replace_club(&[])?;
        return Ok(0);
    }
    let distaste = distaste(db, &vectors, &space, &rejected)?;

    let mut lists = Vec::with_capacity(facets.len());
    for facet in &facets {
        let near = nearest(&vectors, &space, facet, &seen, &distaste);
        lists.push(fuse(near, &db.tmdb_ranks(facet.leader)?));
    }
    let picks = {
        let mut ids: HashMap<String, usize> = HashMap::new();
        let mut genres: HashMap<i64, Vec<usize>> = HashMap::new();
        for (title_id, genre) in db.genre_tags()? {
            let next = ids.len();
            genres
                .entry(title_id)
                .or_default()
                .push(*ids.entry(genre).or_insert(next));
        }
        // the history's genre mix, each title spread over its own genres at
        // the weight the fingerprint gave it
        let mut target = vec![0.0f64; ids.len()];
        for (i, v) in vectors.iter().enumerate() {
            let Some(own) = genres
                .get(&v.title_id)
                .filter(|_| seen[i] && weight[i] > 0.0)
            else {
                continue;
            };
            for &g in own {
                target[g] += f64::from(weight[i]) / own.len() as f64;
            }
        }
        calibrate(deal(&facets, &lists), &genres, &target)
    };
    let meta: Vec<TasteFacetMeta> = facets
        .iter()
        .enumerate()
        .map(|(i, f)| TasteFacetMeta {
            facet: i as u32,
            weight: f.weight,
            leader: f.leader,
            cos_to_top: dot(&f.centre, &facets[0].centre),
        })
        .collect();
    let (discovery, best) = discovery(&vectors, &space, &facets, &seen);
    let title_taste = explain(&vectors, &space, &facets, &seen, &distaste, &best);
    // The other half of the same claims: `explain` keeps what is still on
    // offer, this keeps what has been spent. The evening block weighs these by
    // the hour they were watched at, which is the only way to tell a taste
    // that comes out on a Friday from one that comes out on a Tuesday.
    let watched_facet: Vec<(i64, u32)> = (0..vectors.len())
        .filter(|&i| seen[i] && space.placed(i) && best[i].cos > f32::MIN)
        .map(|i| (vectors[i].title_id, best[i].facet))
        .collect();
    let mut seasonal = anchored(
        &anchor_cosines(db, version, &vectors, &space, &SEASONS)?,
        &vectors,
        &seen,
        None,
    );
    seasonal.extend(anchored(&moods, &vectors, &seen, Some(&best)));
    let written = picks.len();
    db.replace_taste(&TastePassOutput {
        picks,
        facets: meta,
        discovery,
        title_taste,
        watched_facet,
        seasonal,
        tones,
        now,
    })?;
    // after the affinities it is measured on are written
    db.replace_club(&club_themes(db)?)?;
    lay_thread(db, &facets, &lists, now)?;
    Ok(written)
}

/// The facets the history, the verdicts and the gestures point at, strongest
/// first, which titles are already spent, and which titles pull their
/// neighbours back and by how much. `vectors` is the library; a title outside
/// it has no direction and cannot be part of a taste or an answer. `muted`
/// holds the leaders of the tastes the viewer contested.
#[allow(clippy::too_many_arguments)]
fn fingerprint(
    history: &[WatchedFile],
    verdicts: &[(i64, Verdict)],
    deferred: &[i64],
    interests: &[(i64, bool)],
    muted: &[i64],
    vectors: &[TitleVector],
    space: &Space,
    now: i64,
) -> (Vec<Facet>, Vec<bool>, Vec<(usize, f32)>, Vec<f32>) {
    let index: HashMap<i64, usize> = vectors
        .iter()
        .enumerate()
        .map(|(i, v)| (v.title_id, i))
        .collect();
    let Played {
        mut weight,
        last,
        abandoned,
    } = weigh_history(history, &index, vectors.len(), now, HALF_LIFE_SECS);
    let mut seen = vec![false; vectors.len()];
    for row in history {
        if let Some(&i) = index.get(&row.title_id) {
            seen[i] = true;
        }
    }
    // what a verdict or a gesture guarantees a title whatever its plays, kept
    // apart so a facet reweighed below keeps it
    let mut floor = vec![0.0f32; vectors.len()];

    // after the plays, and this is the whole of what a verdict overrides: a
    // film stopped after eight minutes, until it has lain a fortnight, weighs
    // a small positive here, which is the model reading "I tried this" as a
    // faint yes, and the thumb down is the viewer saying it was a no. A
    // positive verdict is a floor and never a discount - a film finished
    // tonight and loved is worth the loved weight, not the smaller of the two
    // - and every verdict spends its title, so the row never offers back
    // something already argued about, however it was argued about and whether
    // or not it was ever played.
    let mut rejected = Vec::new();
    let mut stated = vec![false; vectors.len()];
    for (title_id, verdict) in verdicts {
        let Some(&i) = index.get(title_id) else {
            continue;
        };
        seen[i] = true;
        stated[i] = true;
        match verdict {
            Verdict::Down => {
                weight[i] = 0.0;
                if space.placed(i) && rejected.len() < MAX_DISTASTE {
                    rejected.push((i, DISLIKE_PULL));
                }
            }
            Verdict::Up => floor[i] = LIKED_WEIGHT,
            Verdict::Loved => floor[i] = LOVED_WEIGHT,
        }
        weight[i] = weight[i].max(floor[i]);
    }
    // a title the viewer gave up on, unless they have since said otherwise
    for &i in &abandoned {
        if !stated[i] && space.placed(i) && rejected.len() < MAX_DISTASTE {
            rejected.push((i, ABANDON_PULL));
        }
    }
    // a gesture leans towards a title without spending it: it stays on offer
    for &(title_id, chosen) in interests {
        let Some(&i) = index.get(&title_id) else {
            continue;
        };
        if !seen[i] {
            floor[i] = if chosen {
                CHOSEN_WEIGHT
            } else {
                INTEREST_WEIGHT
            };
            weight[i] = floor[i];
        }
    }
    for title_id in deferred {
        let Some(&i) = index.get(title_id) else {
            continue;
        };
        if !seen[i] && weight[i] == 0.0 && space.placed(i) && rejected.len() < MAX_DISTASTE {
            rejected.push((i, DEFER_PULL));
        }
    }

    let mut seeds: Vec<usize> = (0..vectors.len())
        .filter(|&i| weight[i] > 0.0 && space.placed(i))
        .collect();
    if seeds.is_empty() {
        return (Vec::new(), seen, rejected, weight);
    }
    // heaviest first, and title ids break every tie: the seeding below reads
    // this order, so the facets are the same on every pass over the same
    // history
    seeds.sort_by(|&a, &b| weight[b].partial_cmp(&weight[a]).unwrap().then(a.cmp(&b)));

    let unit: Vec<Vec<f32>> = seeds.iter().map(|&i| space.unit(i, &vectors[i])).collect();
    let mut centres = seed_centres(&unit, &seeds, &weight, &seen);
    if centres.is_empty() {
        return (Vec::new(), seen, rejected, weight);
    }
    let mut member = vec![0usize; seeds.len()];
    for _ in 0..ROUNDS {
        for (s, v) in unit.iter().enumerate() {
            member[s] = centres
                .iter()
                .enumerate()
                .max_by(|(_, a), (_, b)| dot(v, a).partial_cmp(&dot(v, b)).unwrap())
                .map(|(c, _)| c)
                .unwrap();
        }
        for (c, centre) in centres.iter_mut().enumerate() {
            let mut sum = vec![0.0f32; centre.len()];
            for (s, v) in unit.iter().enumerate() {
                if member[s] != c {
                    continue;
                }
                let w = weight[seeds[s]];
                for (a, b) in sum.iter_mut().zip(v) {
                    *a += w * b;
                }
            }
            // a facet nothing chose keeps the direction it was seeded with
            // rather than becoming a zero vector every title is orthogonal to
            if normalize(&mut sum) {
                *centre = sum;
            }
        }
    }

    // A taste whose history is mostly more than a year old and still makes a
    // facet is one the viewer keeps: its members are reweighed on the slower
    // half-life, once, around the centres already found.
    let mut slow: Option<Vec<f32>> = None;
    for c in 0..centres.len() {
        let mut aged: Vec<(i64, f32)> = (0..seeds.len())
            .filter(|&s| member[s] == c && last[seeds[s]] > 0)
            .map(|s| (now - last[seeds[s]], weight[seeds[s]]))
            .collect();
        aged.sort_by_key(|(age, _)| *age);
        let half = aged.iter().map(|(_, w)| w).sum::<f32>() / 2.0;
        let mut below = 0.0;
        let median = aged.iter().find(|(_, w)| {
            below += w;
            below >= half
        });
        if median.is_none_or(|(age, _)| *age <= STABLE_AGE_SECS) {
            continue;
        }
        let slow = slow.get_or_insert_with(|| {
            weigh_history(history, &index, vectors.len(), now, STABLE_HALF_LIFE_SECS).weight
        });
        for s in (0..seeds.len()).filter(|&s| member[s] == c) {
            weight[seeds[s]] = slow[seeds[s]].max(floor[seeds[s]]);
        }
    }

    // The name a row carries is a claim about what the row holds, so it comes
    // from the middle of the taste rather than from the top of the history.
    // The heaviest member is whatever was finished most recently, which on
    // this library is how a row of Avengers films came to be called "because
    // you like 22 Jump Street": one buddy comedy watched last night, sitting
    // at the edge of a cluster whose centre of mass is superhero action. The
    // middle is unweighted for the same reason: a series binged last month
    // outweighs everything else and drags the weighted centre onto itself.
    let mut facets = Vec::with_capacity(centres.len());
    for (c, centre) in centres.into_iter().enumerate() {
        let mut middle = vec![0.0f32; centre.len()];
        for s in (0..seeds.len()).filter(|&s| member[s] == c) {
            for (a, b) in middle.iter_mut().zip(&unit[s]) {
                *a += b;
            }
        }
        if !normalize(&mut middle) {
            middle.clone_from(&centre);
        }
        let mut best: Option<(i64, f32)> = None;
        let mut members = Vec::new();
        for s in (0..seeds.len()).filter(|&s| member[s] == c) {
            members.push((seeds[s], dot(&unit[s], &centre)));
            // seeds are in weight order, so ties go to the heavier title and
            // the same history always names the same row. Only a title the
            // viewer watched or judged names one: a row is never "because you
            // liked" something they only looked at.
            let near = dot(&unit[s], &middle);
            if seen[seeds[s]] && best.is_none_or(|(_, b)| near > b) {
                best = Some((vectors[seeds[s]].title_id, near));
            }
        }
        let Some((leader, _)) = best else {
            continue;
        };
        // A contested taste keeps its members and its direction and loses
        // weight: the last word on each member's weight, after its floor and
        // the stable reweigh, so the genre mix the row is calibrated on
        // shrinks with it.
        let mute = if muted.contains(&leader) {
            MUTE_FACTOR
        } else {
            1.0
        };
        let mut weight_sum = 0.0;
        let mut cos_sum = 0.0;
        for (i, cos) in members {
            weight[i] *= mute;
            weight_sum += weight[i];
            cos_sum += weight[i] * cos;
        }
        facets.push(Facet {
            centre,
            weight: weight_sum,
            leader,
            inner: cos_sum / weight_sum,
        });
    }

    facets.sort_by(|a, b| {
        b.weight
            .partial_cmp(&a.weight)
            .unwrap()
            .then(a.leader.cmp(&b.leader))
    });
    (facets, seen, rejected, weight)
}

/// What the plays say, title by title: its weight, when it was last touched
/// (0 for never), and which titles were given up on, most recently first.
struct Played {
    weight: Vec<f32>,
    last: Vec<i64>,
    abandoned: Vec<usize>,
}

/// Weighs the history title by title, on a given half-life. One title, one
/// vote: a show watched to its fortieth episode says as much as a film watched
/// once, and the weight is the best any of its files earned, raised for a
/// title seen again and for a series binged, and zero for one given up on.
fn weigh_history(
    history: &[WatchedFile],
    index: &HashMap<i64, usize>,
    len: usize,
    now: i64,
    half_life: f32,
) -> Played {
    #[derive(Default)]
    struct Title {
        weight: f32,
        finished: bool,
        share: f32,
        position: f64,
        plays: u32,
        episodes: Vec<i64>,
    }
    let mut titles: HashMap<usize, Title> = HashMap::new();
    let mut last = vec![0i64; len];
    for row in history {
        let Some(&i) = index.get(&row.title_id) else {
            continue;
        };
        let t = titles.entry(i).or_default();
        t.weight = t.weight.max(play_weight(row, now, half_life));
        t.finished |= row.watched;
        // a row with no runtime says nothing about how far in it stopped
        if row.duration_secs > 0.0 {
            t.share = t.share.max((row.position_secs / row.duration_secs) as f32);
            t.position = t.position.max(row.position_secs);
        }
        t.plays = t.plays.max(row.plays);
        if row.watched && row.kind == MediaKind::Show {
            t.episodes.push(row.updated_at);
        }
        last[i] = last[i].max(row.updated_at);
    }
    let mut weight = vec![0.0f32; len];
    let mut abandoned = Vec::new();
    for (i, mut t) in titles {
        if !t.finished
            && t.share < ABANDON_SHARE
            && t.position >= ABANDON_MIN_SECS
            && now - last[i] >= ABANDON_AFTER_SECS
        {
            abandoned.push(i);
            continue;
        }
        let mut w = t.weight;
        if t.plays >= 2 {
            w *= 1.0 + REWATCH_BONUS * (t.plays as f32).ln();
        }
        // the latest episode that closes a run of BINGE_EPISODES in a week
        t.episodes.sort_unstable();
        let binge = (BINGE_EPISODES - 1..t.episodes.len())
            .rev()
            .find(|&e| t.episodes[e] - t.episodes[e + 1 - BINGE_EPISODES] <= BINGE_WINDOW_SECS);
        if let Some(e) = binge {
            let age = (now - t.episodes[e]).max(0) as f32;
            w = w.max(BINGE_WEIGHT * recency(age, half_life));
        }
        weight[i] = w;
    }
    abandoned.sort_by(|&a, &b| last[b].cmp(&last[a]).then(a.cmp(&b)));
    Played {
        weight,
        last,
        abandoned,
    }
}

/// One title the viewer set aside, measured against the whole library.
///
/// `unit` is its own centred direction; `cos` is its centred cosine to every
/// title in `vectors`, in that order. Both are here rather than in `nearest`
/// because neither depends on which facet is being filled, and the row asks
/// the same questions of the same rejections once per facet: measured here,
/// a rejection costs one pass over the library, not four.
struct Distaste {
    unit: Vec<f32>,
    cos: Vec<f32>,
    /// How hard it pulls its neighbours back: a thumb down, an abandonment
    /// and a run of refusals are three strengths of the same no.
    pull: f32,
    /// What to call it when a row explains itself (see `explain`).
    name: String,
}

/// What the viewer has set aside, in the form the row is built against.
fn distaste(
    db: &Db,
    vectors: &[TitleVector],
    space: &Space,
    rejected: &[(usize, f32)],
) -> Result<Vec<Distaste>, IndexError> {
    rejected
        .iter()
        .map(|&(d, pull)| {
            Ok(Distaste {
                pull,
                unit: space.unit(d, &vectors[d]),
                cos: vectors
                    .iter()
                    .enumerate()
                    .map(|(i, v)| {
                        if v.vector.len() != vectors[d].vector.len() {
                            return 0.0;
                        }
                        let dot: f32 = v
                            .vector
                            .iter()
                            .zip(&vectors[d].vector)
                            .map(|(a, b)| f32::from(*a) * f32::from(*b))
                            .sum();
                        space.cos(i, d, dot)
                    })
                    .collect(),
                name: db
                    .title_key(vectors[d].title_id)?
                    .map(|(_, name, _)| name)
                    .unwrap_or_default(),
            })
        })
        .collect()
}

/// How many titles one thread holds. Five is a fortnight of evenings at the
/// pace a viewer actually watches, and short enough that the end of it is
/// visible from the start.
const THREAD_LEN: usize = 5;

/// Lays a new thread when the running one has been watched through, and never
/// otherwise: the point of a cycle is that it outlives the pass that made it.
///
/// The next thread comes from the facet after the last one's, round robin, so
/// a viewer who finishes one thread is taken through another taste rather than
/// deeper into the same one. Its members are the head of that facet's own
/// list, which is already ordered from the most obvious member of the taste to
/// the most particular: that ordering is the cycle's progression.
fn lay_thread(db: &Db, facets: &[Facet], lists: &[Vec<i64>], now: i64) -> Result<(), IndexError> {
    // A thread is about one taste, and it says so by name - which is the same
    // name that taste's own row carries, so the shelf shows one or the other.
    // On a fingerprint with a single facet that trade would leave no row about
    // the taste at all, so a thread waits until there is a second taste to
    // fall back on.
    if facets.len() < 2 {
        return Ok(());
    }
    let previous = db.active_thread()?;
    if let Some((_, facet)) = previous {
        if db.thread_unwatched()? > 0 {
            return Ok(());
        }
        let start = facet as usize + 1;
        for step in 0..facets.len() {
            let f = (start + step) % facets.len();
            if lists[f].len() >= THREAD_LEN {
                db.create_thread(facets[f].leader, f as u32, &lists[f][..THREAD_LEN], now)?;
                return Ok(());
            }
        }
        return Ok(());
    }
    // nothing has ever run: the strongest taste opens
    for (f, list) in lists.iter().enumerate() {
        if list.len() >= THREAD_LEN {
            db.create_thread(facets[f].leader, f as u32, &list[..THREAD_LEN], now)?;
            return Ok(());
        }
    }
    Ok(())
}

/// The seasonal windows: a key, and the sentence the encoder is asked to
/// place. French, accents and all, like the library and like every
/// description the model was given - an anchor in another language would be
/// a different point in the space. The encoder adds its own role prefix.
pub const SEASONS: [(&str, &str); 3] = [
    (
        "oct",
        "film d'horreur, épouvante, frissons, monstres et maisons hantées",
    ),
    (
        "dec",
        "film de Noël, conte des fêtes de fin d'année, neige et famille réunie",
    ),
    (
        "summer",
        "comédie d'été ensoleillée, road movie, vacances au bord de la mer",
    ),
];

/// The moods a viewer can ask for in one press, each a sentence the encoder
/// places like a seasonal anchor. French for the same reason, and none of
/// them is a length: "short" is a runtime, which the evening already knows.
pub const MOODS: [(&str, &str); 7] = [
    (
        "light",
        "comédie légère et drôle, bonne humeur, on rit sans se prendre la tête",
    ),
    (
        "gripping",
        "thriller haletant, suspense, action intense, tension jusqu'à la fin",
    ),
    (
        "moving",
        "drame émouvant, histoire touchante qui fait pleurer, sentiments forts",
    ),
    (
        "chills",
        "film d'horreur, peur, angoisse, frissons dans le noir",
    ),
    (
        "escape",
        "grande aventure, voyage, fantastique, épopée spectaculaire",
    ),
    (
        "mind",
        "film cérébral et intrigant, énigme, science-fiction qui fait réfléchir",
    ),
    (
        "cosy",
        "film doux et réconfortant, feel-good, chaleureux, à voir en famille",
    ),
];

/// How much the taste weighs beside a mood. A half: the mood decides what
/// kind of evening it is, and among what fits it the viewer's own taste
/// comes first, rather than the library's most generic example of the mood.
const MOOD_TASTE: f32 = 0.5;

/// Every title's centred cosine to each anchor the embedding pass has
/// vectorised, in the order `vectors` came in: NaN for a title with no
/// direction. One sweep per anchor, shared by the rankings and the tones.
fn anchor_cosines(
    db: &Db,
    version: i64,
    vectors: &[TitleVector],
    space: &Space,
    anchors: &[(&'static str, &str)],
) -> Result<Vec<(&'static str, Vec<f32>)>, IndexError> {
    let mut out = Vec::with_capacity(anchors.len());
    for (key, _) in anchors {
        let Some(anchor) = db.anchor_vector(key, version)? else {
            continue;
        };
        // the anchor is not a title of the library, so it is centred on its
        // own before anything is compared against it
        let Some(direction) = space.direction_of(&anchor) else {
            continue;
        };
        let along = space.along_mean(&direction);
        let cosines = vectors
            .iter()
            .enumerate()
            .map(|(i, v)| {
                if !space.placed(i) || v.vector.len() != direction.len() {
                    return f32::NAN;
                }
                let dot: f32 = v
                    .vector
                    .iter()
                    .zip(&direction)
                    .map(|(a, b)| f32::from(*a) * b)
                    .sum();
                space.cos_to(i, dot, along)
            })
            .collect();
        out.push((*key, cosines));
    }
    Ok(out)
}

/// The most tones a title is said to have. Two reads as a character ("light,
/// gripping"); a third is a list.
const TONES: usize = 2;

/// Where an anchor's floor sits: halfway between the library's mean cosine
/// to it and this percentile of them, the way `nearest` puts its floor halfway
/// between the background and a taste's own members. A tone is a title nearer
/// the mood than an arbitrary title is by half the reach of its top twentieth.
const TONE_PERCENTILE: f32 = 0.95;

/// Up to `TONES` moods per title, those it stands furthest past each mood's
/// floor, and by how much. The floors come from the library's own
/// distribution against each anchor, so an anchor the encoder places near
/// everything does not tone everything.
fn tones(
    vectors: &[TitleVector],
    moods: &[(&'static str, Vec<f32>)],
) -> Vec<(i64, &'static str, f32)> {
    let floors: Vec<f32> = moods
        .iter()
        .map(|(_, cos)| {
            let mut placed: Vec<f32> = cos.iter().copied().filter(|c| !c.is_nan()).collect();
            if placed.is_empty() {
                return f32::INFINITY;
            }
            let mean = placed.iter().sum::<f32>() / placed.len() as f32;
            let at = ((placed.len() - 1) as f32 * TONE_PERCENTILE).round() as usize;
            let (_, high, _) = placed.select_nth_unstable_by(at, |a, b| a.total_cmp(b));
            (mean + *high) / 2.0
        })
        .collect();
    let mut out = Vec::new();
    let mut best: Vec<(&'static str, f32)> = Vec::with_capacity(moods.len());
    for (i, v) in vectors.iter().enumerate() {
        best.clear();
        for ((key, cos), floor) in moods.iter().zip(&floors) {
            // NaN compares false: a title with no direction has no tone
            if cos[i] > *floor {
                best.push((key, cos[i] - floor));
            }
        }
        best.sort_by(|a, b| b.1.total_cmp(&a.1));
        out.extend(
            best.iter()
                .take(TONES)
                .map(|(key, past)| (v.title_id, *key, *past)),
        );
    }
    out
}

/// The library ranked against each anchor `anchor_cosines` measured.
/// Nothing here is dated: which window is open is the reader's question, and
/// a pass that ran in June still leaves October ready.
///
/// A season is the calendar's and ranks on the anchor alone. A mood is the
/// viewer's, so `claims` (each title's nearest taste) adds `MOOD_TASTE` of
/// the title's cosine to that taste, and the titles already watched are
/// ranked the same way under `seen:<key>`: the evening's rewatch in a mood.
fn anchored(
    cosines: &[(&str, Vec<f32>)],
    vectors: &[TitleVector],
    seen: &[bool],
    claims: Option<&[Claim]>,
) -> Vec<(String, Vec<i64>)> {
    let mut out = Vec::new();
    for (key, cos) in cosines {
        let mut unseen: Vec<(i64, f32)> = Vec::new();
        let mut watched: Vec<(i64, f32)> = Vec::new();
        for (i, v) in vectors.iter().enumerate() {
            if (seen[i] && claims.is_none()) || cos[i].is_nan() {
                continue;
            }
            let taste = claims.map_or(0.0, |c| if c[i].cos > f32::MIN { c[i].cos } else { 0.0 });
            let score = cos[i] + MOOD_TASTE * taste;
            if seen[i] { &mut watched } else { &mut unseen }.push((v.title_id, score));
        }
        // a season never collects a watched title, so its list stays unwritten
        let lists = [(key.to_string(), unseen), (format!("seen:{key}"), watched)];
        for (key, mut scored) in lists.into_iter().take(if claims.is_some() { 2 } else { 1 }) {
            scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
            scored.truncate(PICKS);
            out.push((key, scored.into_iter().map(|(id, _)| id).collect()));
        }
    }
    out
}

/// What one play is worth to the fingerprint: how much of it was actually
/// watched, times how recently. A film finished last night weighs one; the
/// same film left after four minutes weighs a twentieth of that, which is the
/// difference between "this is what I like" and "I tried this".
fn play_weight(row: &WatchedFile, now: i64, half_life: f32) -> f32 {
    let done = if row.watched {
        1.0
    } else if row.duration_secs > 0.0 {
        (row.position_secs / row.duration_secs).clamp(0.0, 1.0) as f32
    } else {
        0.0
    };
    done * recency((now - row.updated_at).max(0) as f32, half_life)
}

/// What something `age` seconds old still weighs, on a given half-life.
fn recency(age: f32, half_life: f32) -> f32 {
    RECENCY_FLOOR + (1.0 - RECENCY_FLOOR) * (-age / half_life * LN2).exp()
}

const LN2: f32 = std::f32::consts::LN_2;

/// Where the facets start: the heaviest title watched, then the title that is
/// both heavy and least like anything chosen so far. Seeding by spread rather
/// than by weight alone is what stops all four landing in the same taste, and
/// picking greedily off a fixed order is what makes them reproducible. Only a
/// `seen` title seeds: a gesture of interest joins a taste, it never starts
/// one. Empty when no seed was seen.
fn seed_centres(
    unit: &[Vec<f32>],
    seeds: &[usize],
    weight: &[f32],
    seen: &[bool],
) -> Vec<Vec<f32>> {
    let Some(first) = seeds.iter().position(|&i| seen[i]) else {
        return Vec::new();
    };
    let mut centres = vec![unit[first].clone()];
    let mut nearest: Vec<f32> = unit.iter().map(|v| dot(v, &unit[first])).collect();
    let seeded = seeds.iter().filter(|&&i| seen[i]).count();
    while centres.len() < FACETS.min(seeded) {
        let mut best = (first, f32::MIN);
        for (s, &i) in seeds.iter().enumerate().filter(|(_, &i)| seen[i]) {
            let gain = weight[i] * (1.0 - nearest[s]);
            if gain > best.1 {
                best = (s, gain);
            }
        }
        centres.push(unit[best.0].clone());
        for (s, v) in unit.iter().enumerate() {
            nearest[s] = nearest[s].max(dot(v, &unit[best.0]));
        }
    }
    centres
}

/// The library's titles nearest one taste, best first, never one the history
/// has already spent, and never one that is only nearer than average.
///
/// The cut is a count of neighbours nowhere: filling a fixed number of slots
/// is what pads a row with titles that merely share a language, and this
/// library is dense enough that the twentieth is always *some* title. So the
/// floor is halfway between the two similarities the library itself supplies:
/// what an arbitrary title scores against this taste, and what the films that
/// made the taste score. Below that midpoint a candidate is closer to random
/// than to the viewer, whatever its rank. Both ends are measured per facet, so
/// a small library, a tight taste (everything already seen, and nothing left
/// that belongs) and a broad one each get their own answer rather than a
/// number tuned on someone else's shelf.
///
/// The midpoint is only a midpoint of something in the centred space (see
/// `Space`). Measured raw, this library's background sat at 0.913 and its
/// tastes at 0.916, so "halfway between" was three thousandths wide and every
/// candidate cleared it: the row filled all sixty slots with whatever the
/// quantiser rounded upward. Centred, the two ends are 0.00 and 0.23.
///
/// What the viewer rejected is taken off a candidate's score here rather than
/// out of the fingerprint above, because a rejection is not a taste turned
/// around: there is no direction a viewer wants less of, only titles they do
/// not want offered. Subtracting it from the score means it competes with the
/// floor, so a near-twin of a rejected film falls out of the row altogether
/// while a title that merely shares the facet loses a place or two.
///
/// The part of a rejection that a taste already explains is thrown away first:
/// what is subtracted is `unit(candidate) . residue`, where the residue is the
/// rejected title with its projection on this centre removed. That is what
/// keeps one thumb down from emptying a facet - a film that *is* the taste
/// leaves no residue and takes nothing with it, and the candidates nearest a
/// centre are by construction the ones a residue can reach least.
fn nearest(
    vectors: &[TitleVector],
    space: &Space,
    facet: &Facet,
    seen: &[bool],
    distaste: &[Distaste],
) -> Vec<i64> {
    let centre = &facet.centre;
    let along = space.along_mean(centre);
    // how much of each rejection this taste already accounts for. The residue
    // itself is never materialised: a candidate's dot with it is its cosine to
    // the rejected title less this much of its cosine to the centre, and both
    // of those are already in hand.
    let explained: Vec<f32> = distaste.iter().map(|d| dot(&d.unit, centre)).collect();
    let mut scored: Vec<(i64, f32)> = Vec::with_capacity(PICKS + 1);
    let mut background = 0.0f32;
    let mut counted = 0u32;
    for (i, v) in vectors.iter().enumerate() {
        if v.vector.len() != centre.len() || !space.placed(i) {
            continue;
        }
        let dot: f32 = v
            .vector
            .iter()
            .zip(centre)
            .map(|(a, b)| f32::from(*a) * b)
            .sum();
        let cos = space.cos_to(i, dot, along);
        // the background is what the library looks like to this taste, so it
        // is measured before the rejections: they are the viewer's, not the
        // library's, and a floor that moved with them would let the row reach
        // further down every time one was pressed
        background += cos;
        counted += 1;
        // the largest single rejection, never their sum: three rejections in
        // one corner of the library must not penalise three times as deeply as
        // one does. What more of them buys is width, not depth.
        let mut shared = 0.0f32;
        for (d, explained) in distaste.iter().zip(&explained) {
            shared = shared.max(d.pull * (d.cos[i] - explained * cos));
        }
        let score = cos - shared;
        if seen[i] || scored.len() == PICKS && score <= scored[PICKS - 1].1 {
            continue;
        }
        // ids are walked in order, so equal scores keep the order they arrived
        let at = scored.partition_point(|(_, s)| *s >= score);
        scored.insert(at, (v.title_id, score));
        scored.truncate(PICKS);
    }
    if counted == 0 {
        return Vec::new();
    }
    let floor = (background / counted as f32 + facet.inner) / 2.0;
    scored
        .into_iter()
        .take_while(|(_, cos)| *cos >= floor)
        .map(|(id, _)| id)
        .collect()
}

/// The titles deliberately a step aside from every taste: close enough to
/// catch, far enough to be new. The band is measured off the same two anchors
/// `nearest` cuts on, per title against its best facet: the library's
/// background on one end, the facets' own floor on the other. Inside it, the
/// middle of the band ranks first - the point furthest from both "more of the
/// same" and "a stranger".
///
/// Rejections are not subtracted here: a rejected title is spent by its
/// verdict and never a candidate, and the band already keeps its near-twins
/// at arm's length from every facet centre.
/// Returns the band, and the per-title best cosine to any facet beside it:
/// the same pass answers "how far aside is this" and "which taste claims
/// this", and `explain` needs the second.
fn discovery(
    vectors: &[TitleVector],
    space: &Space,
    facets: &[Facet],
    seen: &[bool],
) -> (Vec<DiscoveryPick>, Vec<Claim>) {
    let alongs: Vec<f32> = facets.iter().map(|f| space.along_mean(&f.centre)).collect();
    let mut claims = vec![Claim::default(); vectors.len()];
    let mut background = 0.0f32;
    let mut counted = 0u32;
    for (i, v) in vectors.iter().enumerate() {
        if !space.placed(i) {
            continue;
        }
        for (f, (facet, along)) in facets.iter().zip(&alongs).enumerate() {
            if v.vector.len() != facet.centre.len() {
                continue;
            }
            let dot: f32 = v
                .vector
                .iter()
                .zip(&facet.centre)
                .map(|(a, b)| f32::from(*a) * b)
                .sum();
            let cos = space.cos_to(i, dot, *along);
            if cos > claims[i].cos {
                claims[i] = Claim {
                    facet: f as u32,
                    cos,
                };
            }
        }
        if claims[i].cos > f32::MIN {
            background += claims[i].cos;
            counted += 1;
        }
    }
    if counted == 0 {
        return (Vec::new(), claims);
    }
    let background = background / counted as f32;
    let inner = facets.iter().map(|f| f.inner).fold(f32::MAX, f32::min);
    let floor = (background + inner) / 2.0;
    // the band: the middle half of the background-to-floor span
    let lo = background + 0.25 * (floor - background);
    let hi = background + 0.75 * (floor - background);
    let mid = (lo + hi) / 2.0;
    let span = (hi - lo).max(f32::EPSILON);
    let mut band: Vec<(DiscoveryPick, f32)> = vectors
        .iter()
        .enumerate()
        .filter(|(i, _)| {
            !seen[*i] && space.placed(*i) && claims[*i].cos >= lo && claims[*i].cos <= hi
        })
        .map(|(i, v)| {
            (
                DiscoveryPick {
                    title_id: v.title_id,
                    // 0 at the library's own background, 1 at the taste's edge
                    closeness: ((claims[i].cos - lo) / span).clamp(0.0, 1.0),
                },
                (claims[i].cos - mid).abs(),
            )
        })
        .collect();
    band.sort_by(|a, b| {
        a.1.partial_cmp(&b.1)
            .unwrap()
            .then(a.0.title_id.cmp(&b.0.title_id))
    });
    (
        band.into_iter().take(PICKS).map(|(pick, _)| pick).collect(),
        claims,
    )
}

/// Which facet is nearest one title, and how near. `cos` starts at f32::MIN:
/// a title no facet could be compared against is claimed by none.
#[derive(Clone, Copy)]
struct Claim {
    facet: u32,
    cos: f32,
}

impl Default for Claim {
    fn default() -> Self {
        Claim {
            facet: 0,
            cos: f32::MIN,
        }
    }
}

/// What the fingerprint has to say about every title it could recommend: the
/// taste that claims it, how strongly, and the rejection that holds it back.
///
/// The affinity is the claim's cosine placed between the two anchors the row
/// itself is cut on - the library's background and the facet's own coherence -
/// so 0 is "no more like your taste than anything else here" and 1 is "as
/// close as the films that built the taste". Titles already spent are left
/// out: a viewer is only ever shown this about something being offered.
fn explain(
    vectors: &[TitleVector],
    space: &Space,
    facets: &[Facet],
    seen: &[bool],
    distaste: &[Distaste],
    claims: &[Claim],
) -> Vec<TitleTasteRow> {
    let placed: Vec<usize> = (0..vectors.len())
        .filter(|&i| space.placed(i) && claims[i].cos > f32::MIN)
        .collect();
    if placed.is_empty() {
        return Vec::new();
    }
    let background = placed.iter().map(|&i| claims[i].cos).sum::<f32>() / placed.len() as f32;
    let explained: Vec<Vec<f32>> = facets
        .iter()
        .map(|f| distaste.iter().map(|d| dot(&d.unit, &f.centre)).collect())
        .collect();
    placed
        .iter()
        .filter(|&&i| !seen[i])
        .filter_map(|&i| {
            let claim = claims[i];
            let inner = facets[claim.facet as usize].inner;
            let span = (inner - background).max(f32::EPSILON);
            // the rejection this title shares the most with, once the taste
            // has taken its own part out: the same residue `nearest` scores on
            let mut worst = (0.0f32, "");
            for (d, explained) in distaste
                .iter()
                .zip(&explained[claim.facet as usize])
                .map(|(d, e)| (d, *e))
            {
                let shared = d.cos[i] - explained * claim.cos;
                if shared > worst.0 {
                    worst = (shared, d.name.as_str());
                }
            }
            let affinity = ((claim.cos - background) / span).clamp(0.0, 1.0);
            if affinity < MIN_AFFINITY {
                return None;
            }
            Some(TitleTasteRow {
                title_id: vectors[i].title_id,
                facet: claim.facet,
                affinity,
                rejected: if worst.0 > MIN_SHARED {
                    worst.1.to_string()
                } else {
                    String::new()
                },
            })
        })
        .collect()
}

/// One facet's list, re-ordered by what TMDB also has to say about the title
/// leading it. A candidate's score is the sum over the lists naming it of
/// 1 / (10 + rank), the same fusion the detail screen's similar row uses: on
/// a device with no TMDB key the sum has one term and the order is the one the
/// vectors gave, and a key arriving strengthens the ranking without the row
/// having ever depended on it.
fn fuse(near: Vec<i64>, tmdb: &HashMap<i64, i64>) -> Vec<i64> {
    if tmdb.is_empty() {
        return near;
    }
    let mut scored: Vec<(i64, f64)> = near
        .into_iter()
        .enumerate()
        .map(|(rank, id)| {
            let mut score = 1.0 / (10.0 + rank as f64);
            if let Some(t) = tmdb.get(&id) {
                score += 1.0 / (10.0 + *t as f64);
            }
            (id, score)
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
    scored.into_iter().map(|(id, _)| id).collect()
}

/// The row, dealt between the facets in proportion to the history behind each.
/// A facet's next pick falls due after every 1 / share of the row, so the mix
/// holds at any length the screen cuts the row off at, not only at the end:
/// the strongest taste leads, and a taste that is a tenth of the history is
/// still on screen rather than buried past the twentieth tile.
fn deal(facets: &[Facet], lists: &[Vec<i64>]) -> Vec<TastePick> {
    let total: f32 = facets.iter().map(|f| f.weight).sum();
    let mut cursor = vec![0usize; facets.len()];
    let mut taken = vec![0.0f32; facets.len()];
    let mut out: Vec<TastePick> = Vec::with_capacity(PICKS);
    while out.len() < PICKS {
        let mut due: Option<(usize, f32)> = None;
        for f in 0..facets.len() {
            while cursor[f] < lists[f].len()
                && out.iter().any(|p| p.title_id == lists[f][cursor[f]])
            {
                cursor[f] += 1;
            }
            if cursor[f] >= lists[f].len() {
                continue;
            }
            let at = (taken[f] + 0.5) * total / facets[f].weight;
            if due.is_none_or(|(_, best)| at < best) {
                due = Some((f, at));
            }
        }
        let Some((f, _)) = due else { break };
        out.push(TastePick {
            title_id: lists[f][cursor[f]],
            facet: f as u32,
            leader: facets[f].leader,
        });
        cursor[f] += 1;
        taken[f] += 1.0;
    }
    out
}

/// How many unseen titles a film club theme needs, and how near the taste
/// they must sit on average (`title_taste.affinity`, 0 where none is placed).
const CLUB_MIN_TITLES: usize = 5;
const CLUB_AFFINITY: f32 = 0.4;

/// Unseen titles with TMDB keywords, and how near the taste each sits.
const CLUB_KEYWORDS: &str = "SELECT t.id, m.keywords, COALESCE(tt.affinity, 0)
  FROM metadata m
  CROSS JOIN titles t ON t.id = m.title_id
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  WHERE m.keywords <> ''
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)";

/// The same for the composers and writers credited on unseen titles.
const CLUB_CREDITS: &str = "SELECT t.id, g.kind, g.value, COALESCE(tt.affinity, 0)
  FROM title_tags g
  CROSS JOIN titles t ON t.id = g.title_id
  LEFT JOIN title_taste tt ON tt.title_id = t.id
  WHERE g.kind IN ('composer', 'writer')
    AND NOT EXISTS (SELECT 1 FROM watch_state w JOIN files f ON f.id = w.file_id
                    WHERE f.title_id = t.id)
    AND NOT EXISTS (SELECT 1 FROM title_verdict v WHERE v.title_id = t.id)
    AND EXISTS (SELECT 1 FROM files c WHERE c.title_id = t.id)";

/// The film club's themes: every keyword, composer and writer with at least
/// `CLUB_MIN_TITLES` unseen titles whose mean affinity reaches
/// `CLUB_AFFINITY`, as `(kind, value, [(title_id, affinity)])`. Measured here
/// rather than on the home, whose rows are lookups: this reads the library.
fn club_themes(db: &Db) -> Result<Vec<(&'static str, String, Vec<(i64, f32)>)>, IndexError> {
    let mut themes: HashMap<(&'static str, String), Vec<(i64, f32)>> = HashMap::new();
    {
        let mut stmt = db.conn().prepare_cached(CLUB_KEYWORDS)?;
        let mut rows = stmt.query([])?;
        while let Some(r) = rows.next()? {
            let (id, words, affinity): (i64, String, f32) = (r.get(0)?, r.get(1)?, r.get(2)?);
            for word in words.split(',').map(str::trim).filter(|w| !w.is_empty()) {
                themes
                    .entry(("keyword", word.to_string()))
                    .or_default()
                    .push((id, affinity));
            }
        }
    }
    {
        let mut stmt = db.conn().prepare_cached(CLUB_CREDITS)?;
        let mut rows = stmt.query([])?;
        while let Some(r) = rows.next()? {
            let (id, kind, name, affinity): (i64, String, String, f32) =
                (r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?);
            let kind = if kind == "composer" {
                "composer"
            } else {
                "writer"
            };
            themes.entry((kind, name)).or_default().push((id, affinity));
        }
    }
    Ok(themes
        .into_iter()
        .filter(|(_, titles)| {
            titles.len() >= CLUB_MIN_TITLES
                && titles.iter().map(|(_, a)| a).sum::<f32>() / titles.len() as f32 >= CLUB_AFFINITY
        })
        .map(|((kind, value), titles)| (kind, value, titles))
        .collect())
}

/// How much the calibration weighs the genre mix against the dealt order,
/// and how much of the history's own mix is blended into the list's, so a
/// genre the list has not reached yet is far rather than infinitely far.
const CALIBRATION: f64 = 0.3;
const CALIBRATION_BLEND: f64 = 0.01;

/// Reorders the dealt row so its genres follow the history's (`target`,
/// unnormalised) the way Steck's calibration does: greedily, each place goes
/// to the pick that best trades its dealt rank against the divergence of the
/// list so far from the history. A history that is seven parts comedy gets a
/// row that is about seven parts comedy, not ten. Only the order moves: every
/// pick stays. A history with no genres leaves the row as dealt.
fn calibrate(
    picks: Vec<TastePick>,
    genres: &HashMap<i64, Vec<usize>>,
    target: &[f64],
) -> Vec<TastePick> {
    let sum: f64 = target.iter().sum();
    if sum <= 0.0 {
        return picks;
    }
    let p: Vec<f64> = target.iter().map(|t| t / sum).collect();
    let mut left: Vec<(usize, TastePick)> = picks.into_iter().enumerate().collect();
    let mut mass = vec![0.0f64; p.len()];
    let mut listed = 0.0f64;
    let mut out = Vec::with_capacity(left.len());
    while !left.is_empty() {
        let mut best: Option<(usize, f64)> = None;
        for (at, (rank, pick)) in left.iter().enumerate() {
            let own = genres.get(&pick.title_id).map_or(&[][..], Vec::as_slice);
            let total = listed + f64::from(u8::from(!own.is_empty()));
            let kl: f64 = p
                .iter()
                .enumerate()
                .filter(|(_, pg)| **pg > 0.0)
                .map(|(g, pg)| {
                    let m = mass[g]
                        + if own.contains(&g) {
                            1.0 / own.len() as f64
                        } else {
                            0.0
                        };
                    let q = if total > 0.0 { m / total } else { 0.0 };
                    let q = (1.0 - CALIBRATION_BLEND) * q + CALIBRATION_BLEND * pg;
                    pg * (pg / q).ln()
                })
                .sum();
            let score = (1.0 - CALIBRATION) / (10.0 + *rank as f64) - CALIBRATION * kl;
            if best.is_none_or(|(_, b)| score > b) {
                best = Some((at, score));
            }
        }
        let (_, pick) = left.remove(best.unwrap().0);
        if let Some(own) = genres.get(&pick.title_id).filter(|o| !o.is_empty()) {
            for &g in own {
                mass[g] += 1.0 / own.len() as f64;
            }
            listed += 1.0;
        }
        out.push(pick);
    }
    out
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// Scales a vector to length one, and says whether there was a direction to
/// scale: the zero vector has none and is left alone.
fn normalize(v: &mut [f32]) -> bool {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm <= 0.0 {
        return false;
    }
    for x in v.iter_mut() {
        *x /= norm;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::db::{
        Db, EmbeddingRecord, FileMedia, FileRecord, MetadataRecord, MetadataSource, WatchAuthority,
        WatchRecord,
    };
    use crate::index::MediaKind;

    const DAY: i64 = 86_400;
    const NOW: i64 = 20_000 * DAY;
    /// The encoder an index is set to until somebody chooses another.
    const SMALL: i64 = 2;

    /// What every title in a library has in common, in the one dimension none
    /// of them tell apart: that it is a film, described in one language, in
    /// the register a synopsis is written in. A sentence encoder spends most
    /// of every vector saying it - on the owner's shelf it is 91% of each one,
    /// which puts every raw cosine in the library between +0.78 and +0.89 -
    /// and the fingerprint has to work in what is left. A fixture without it
    /// is a library no encoder produces.
    const SHARED: i8 = 80;

    /// A title with a file and a vector: everything the fingerprint needs to
    /// place it, and nothing TMDB has ever been asked about. `vector` is the
    /// part that distinguishes this title; what it shares with the rest is
    /// prepended here, so a test says only what it means to say.
    fn vectorised(db: &Db, name: &str, vector: &[i8]) -> i64 {
        let vector: Vec<i8> = std::iter::once(SHARED)
            .chain(vector.iter().copied())
            .collect();
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
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: SMALL,
            source_hash: 0,
            vector,
            computed_at: 1,
        })
        .unwrap();
        id
    }

    fn play(db: &Db, title_id: i64, at: i64, watched: bool, position: f64) {
        let file_id = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1",
                params_id(title_id),
                |r| r.get(0),
            )
            .unwrap();
        db.upsert_watch_state(
            &WatchRecord {
                file_id,
                position_secs: position,
                duration_secs: 6000.0,
                watched,
                plays: 0,
                updated_at: at,
            },
            WatchAuthority::Report,
        )
        .unwrap();
    }

    fn params_id(id: i64) -> [i64; 1] {
        [id]
    }

    fn said(db: &Db, title_id: i64, verdict: Verdict, at: i64) {
        db.set_verdict(title_id, Some(verdict), at).unwrap();
    }

    /// The row as the home screen would read it, in the order it was dealt.
    fn row(db: &Db) -> Vec<String> {
        db.conn()
            .prepare(
                "SELECT t.name FROM taste_pick p
                 JOIN titles t ON t.id = p.title_id ORDER BY p.rank",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    /// Someone who watches horror and children's films. The two tastes point
    /// in two directions, and "Both At Once" sits exactly between them, which
    /// is where a single average of the history would land.
    fn two_tastes() -> Db {
        let db = Db::open_in_memory().unwrap();
        for (name, v) in [
            ("Horror One", [100, 6, 0, 0]),
            ("Horror Two", [98, 0, 9, 0]),
            ("Horror Three", [99, 0, 0, 7]),
            ("Small Bear", [6, 100, 0, 0]),
            ("Small Fox", [0, 98, 9, 0]),
        ] {
            let id = vectorised(&db, name, &v);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[97, 0, 0, 0]);
        vectorised(&db, "Small Unseen", &[0, 97, 0, 0]);
        vectorised(&db, "Both At Once", &[70, 70, 0, 0]);
        db
    }

    /// Three mood anchors, one axis each past what every title shares, and a
    /// shelf spread over those axes and a fourth none of them names.
    fn toned_shelf() -> Db {
        let db = Db::open_in_memory().unwrap();
        for (key, v) in [
            ("light", [SHARED, 100, 0, 0, 0]),
            ("gripping", [SHARED, 0, 100, 0, 0]),
            ("moving", [SHARED, 0, 0, 100, 0]),
        ] {
            db.put_anchor_vector(key, SMALL, &v).unwrap();
        }
        for (name, v) in [
            ("Comedy Two", [90, 0, 10, 0]),
            ("Thriller", [0, 100, 0, 0]),
            ("Thriller Two", [10, 90, 0, 0]),
            ("Drama", [0, 0, 100, 0]),
            ("Drama Two", [0, 10, 90, 0]),
            ("Other", [0, 0, 0, 100]),
            ("Other Two", [0, 0, 10, 90]),
        ] {
            vectorised(&db, name, &v);
        }
        db
    }

    /// The trio reads the library's mean score every minute, so the pass
    /// measures it, with or without a model to place anything.
    #[test]
    fn the_pass_stores_the_library_s_mean_score_even_with_no_vectors() {
        let db = Db::open_in_memory().unwrap();
        for (name, score) in [("Heat", 7.0), ("Ronin", 8.0)] {
            let id = db.upsert_title(MediaKind::Movie, name, None).unwrap();
            db.conn()
                .execute(
                    "INSERT INTO metadata (title_id, source, fetched_at, audience_rating,
                                           audience_source)
                     VALUES (?1, 'tmdb', 0, ?2, 'themoviedb')",
                    rusqlite::params![id, score],
                )
                .unwrap();
        }
        refresh(&db, NOW).unwrap();
        let stored = db
            .setting(crate::index::tonight::RATING_MEAN_SETTING)
            .unwrap();
        assert_eq!(stored.as_deref(), Some("7.5"));
    }

    /// A tone is what the library says about a title, not what the viewer
    /// does: it is there before anything is watched.
    #[test]
    fn a_title_aligned_with_the_light_anchor_has_light_for_its_first_tone() {
        let db = toned_shelf();
        let comedy = vectorised(&db, "Comedy", &[100, 20, 0, 0]);
        refresh(&db, NOW).unwrap();
        let tones = db.title_tones(comedy).unwrap();
        assert_eq!(
            tones.first().map(String::as_str),
            Some("light"),
            "{tones:?}"
        );
        assert!(tones.len() <= 2, "{tones:?}");
    }

    #[test]
    fn a_title_in_the_middle_of_everything_has_no_tone() {
        let db = toned_shelf();
        vectorised(&db, "Comedy", &[100, 20, 0, 0]);
        // near the shelf's own mean against every anchor: over a floor set at
        // that mean, under the one halfway to the top of the shelf
        let middle = vectorised(&db, "Middle", &[55, 55, 50, 45]);
        refresh(&db, NOW).unwrap();
        assert_eq!(db.title_tones(middle).unwrap(), Vec::<String>::new());
    }

    #[test]
    fn a_title_in_three_moods_keeps_the_two_it_is_most_in() {
        let db = toned_shelf();
        // a shelf mostly about none of the moods, so that each mood's floor
        // sits well under its purest titles
        for k in 0..20 {
            vectorised(&db, &format!("Filler {k}"), &[0, 0, k as i8, 100]);
        }
        let both = vectorised(&db, "Action Comedy", &[80, 80, 30, 0]);
        refresh(&db, NOW).unwrap();
        let mut tones = db.title_tones(both).unwrap();
        tones.sort();
        assert_eq!(tones, ["gripping", "light"]);
    }

    /// A mood is ranked on its anchor and then leans to the viewer: of two
    /// titles as much in the mood, the one nearer a taste of theirs leads,
    /// even over a stranger slightly more in the mood.
    #[test]
    fn a_mood_leans_towards_the_viewers_own_taste() {
        let db = two_tastes();
        let near = vectorised(&db, "Mood Near Taste", &[40, 0, 0, 80]);
        let stranger = vectorised(&db, "Mood Stranger", &[0, 0, 30, 100]);
        db.put_anchor_vector("gripping", SMALL, &[SHARED, 0, 0, 0, 100])
            .unwrap();
        refresh(&db, NOW).unwrap();
        let ranked = db.seasonal_titles("gripping").unwrap();
        assert_eq!(ranked[..2], [near, stranger], "{ranked:?}");
        // a season is the calendar's, and ranks on the anchor alone
        db.put_anchor_vector("oct", SMALL, &[SHARED, 0, 0, 0, 100])
            .unwrap();
        refresh(&db, NOW).unwrap();
        assert_eq!(db.seasonal_titles("oct").unwrap()[0], stranger);
    }

    /// A mood also ranks what was already watched, under `seen:` and its key,
    /// for the evening's rewatch: nearest the mood first, and nothing unseen.
    /// A season keeps to the unseen alone.
    #[test]
    fn a_mood_ranks_the_titles_already_watched_in_it_apart() {
        let db = two_tastes();
        db.put_anchor_vector("light", SMALL, &[SHARED, 6, 100, 0, 0])
            .unwrap();
        db.put_anchor_vector("oct", SMALL, &[SHARED, 6, 100, 0, 0])
            .unwrap();
        refresh(&db, NOW).unwrap();
        let seen = db.seasonal_titles("seen:light").unwrap();
        let name = |id: &i64| -> String {
            db.conn()
                .query_row("SELECT name FROM titles WHERE id = ?1", [id], |r| r.get(0))
                .unwrap()
        };
        let names: Vec<String> = seen.iter().map(name).collect();
        assert_eq!(names[0], "Small Bear", "{names:?}");
        assert_eq!(names.len(), 5, "{names:?}");
        assert!(!db
            .seasonal_titles("light")
            .unwrap()
            .iter()
            .any(|id| seen.contains(id)));
        assert!(db.seasonal_titles("seen:oct").unwrap().is_empty());
    }

    /// Picked over another title in a duel: the fingerprint weighs the
    /// winner as a choice at the next refresh, and the title stays on offer.
    #[test]
    fn a_title_chosen_in_a_duel_weighs_as_a_choice_at_the_next_refresh() {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        let bear = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        play(&db, bear, NOW - DAY, true, 0.0);
        let chosen = vectorised(&db, "Small Fox", &[0, 100, 40, 0]);
        let lost = vectorised(&db, "Horror Unseen", &[100, 4, 0, 0]);
        vectorised(&db, "Small Kin", &[0, 100, 30, 0]);
        vectorised(&db, "Elsewhere", &[0, 0, 0, 100]);
        refresh(&db, NOW).unwrap();
        let facet = |db: &Db| {
            db.taste_facets()
                .unwrap()
                .into_iter()
                .find(|f| f.leader == bear)
        };
        let before = facet(&db).expect("a facet led by the bear");

        crate::index::tonight::choose(&db, chosen, lost, NOW - DAY, 0).unwrap();
        refresh(&db, NOW).unwrap();
        let after = facet(&db).expect("still led by the bear");
        assert!(
            (after.weight - before.weight - CHOSEN_WEIGHT).abs() < 1e-4,
            "{after:?}"
        );
        assert!(
            row(&db).contains(&"Small Fox".to_string()),
            "{:?}",
            row(&db)
        );
    }

    /// The pass writes one taste_facet row per facet, weight order, the
    /// dominant one carrying cos_to_top = 1 - and the facet least like it,
    /// which is what "the other mood" will be chosen by, sits in the other
    /// taste.
    #[test]
    fn refresh_persists_the_facets_beside_the_picks() {
        let db = two_tastes();
        refresh(&db, NOW).unwrap();
        let facets = db.taste_facets().unwrap();
        assert!(facets.len() >= 2, "{facets:?}");
        assert!(
            facets.windows(2).all(|w| w[0].weight >= w[1].weight),
            "{facets:?}"
        );
        assert!(facets[0].cos_to_top > 0.999, "{facets:?}");
        let facing = facets[1..]
            .iter()
            .min_by(|a, b| a.cos_to_top.partial_cmp(&b.cos_to_top).unwrap())
            .unwrap();
        assert!(facing.cos_to_top < facets[0].cos_to_top, "{facets:?}");
        let name = |id: i64| -> String {
            db.conn()
                .query_row("SELECT name FROM titles WHERE id = ?1", [id], |r| r.get(0))
                .unwrap()
        };
        let top = name(facets[0].leader);
        let other = name(facing.leader);
        assert_ne!(
            top.starts_with("Small"),
            other.starts_with("Small"),
            "top {top} vs facing {other}"
        );
    }

    /// Discovery picks sit in the cosine band: never a facet's own nearest
    /// (those are taste_pick's), never a stranger below the background.
    #[test]
    fn refresh_fills_the_discovery_band_between_taste_and_background() {
        let db = Db::open_in_memory().unwrap();
        for n in 0..4 {
            let id = vectorised(&db, &format!("Watched {n}"), &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Twin", &[100, 0, 0, 0]);
        vectorised(&db, "Step Aside One", &[70, 55, 0, 0]);
        vectorised(&db, "Step Aside Two", &[65, 0, 60, 0]);
        for n in 0..3 {
            vectorised(&db, &format!("Stranger {n}"), &[0, 100, 0, 0]);
        }
        refresh(&db, NOW).unwrap();
        let discovery: Vec<String> = db
            .conn()
            .prepare(
                "SELECT t.name FROM discovery_pick p
                 JOIN titles t ON t.id = p.title_id ORDER BY p.rank",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(!discovery.is_empty());
        assert!(
            discovery.iter().all(|n| n.starts_with("Step Aside")),
            "{discovery:?}"
        );
    }

    /// A thread runs until it has been watched through, then the next taste
    /// takes its turn: a cycle the viewer finished is not the cycle to offer.
    #[test]
    fn the_thread_holds_until_it_is_watched_through_then_moves_on() {
        let db = two_tastes();
        // enough unseen titles either side for a thread of five
        for n in 0..6 {
            vectorised(&db, &format!("Horror Spare {n}"), &[96, n as i8, 0, 0]);
            vectorised(&db, &format!("Small Spare {n}"), &[0, 96, n as i8, 0]);
        }
        refresh(&db, NOW).unwrap();
        let first = db.active_thread().unwrap().expect("a thread is laid");

        // a pass that changes nothing leaves the running thread alone
        refresh(&db, NOW).unwrap();
        assert_eq!(db.active_thread().unwrap(), Some(first));

        // watched through, and the next pass lays another, on another taste
        let members: Vec<i64> = db
            .conn()
            .prepare("SELECT title_id FROM thread_item ORDER BY rank")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for member in members {
            play(&db, member, NOW, true, 0.0);
        }
        refresh(&db, NOW).unwrap();
        let second = db.active_thread().unwrap().expect("a second thread");
        assert_ne!(second.1, first.1, "the next taste takes its turn");
    }

    /// A history seven parts comedy and three drama, all one taste: the row
    /// the taste ranks is every comedy before any drama, and the calibration
    /// brings drama forward into the first screenful without dropping a pick.
    #[test]
    fn a_history_mostly_comedy_does_not_make_a_row_all_comedy() {
        let db = Db::open_in_memory().unwrap();
        let genre = |id: i64, g: &str| {
            db.conn()
                .execute(
                    "INSERT INTO title_tags (title_id, kind, value) VALUES (?1, 'genre', ?2)",
                    rusqlite::params![id, g],
                )
                .unwrap();
        };
        for n in 0..10 {
            let id = vectorised(&db, &format!("Watched {n}"), &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
            genre(id, if n < 7 { "Comedie" } else { "Drame" });
        }
        for n in 0..12 {
            let id = vectorised(&db, &format!("Comedy {n:02}"), &[100, n, 0, 0]);
            genre(id, "Comedie");
        }
        for n in 0..4 {
            let id = vectorised(&db, &format!("Drama {n}"), &[100, 0, 20 + n, 0]);
            genre(id, "Drame");
        }
        // the rest of the shelf, which is what near is measured against
        for n in 0..10 {
            vectorised(&db, &format!("Stranger {n}"), &[0, 0, 0, 100]);
        }
        refresh(&db, NOW).unwrap();
        assert_eq!(db.taste_facets().unwrap().len(), 1);
        let row = row(&db);
        assert_eq!(row.len(), 16, "{row:?}");
        let first: Vec<&String> = row.iter().take(10).collect();
        assert!(first.iter().any(|n| n.starts_with("Drama")), "{row:?}");
        assert!(!first.iter().all(|n| n.starts_with("Comedy")), "{row:?}");
        // reordered, not refilled: a drama now leads comedies dealt above it
        let at = |name: &str| row.iter().position(|n| n == name).unwrap();
        assert!(at("Drama 0") < at("Comedy 11"), "{row:?}");
    }

    /// A club theme is five unseen titles near the taste on average: four is
    /// not one, five far from the taste is not one, and a watched fifth does
    /// not count. The pass stores the themes that qualify, with every member.
    #[test]
    fn a_keyword_with_four_unseen_titles_is_not_a_club_theme() {
        let db = Db::open_in_memory().unwrap();
        let keyworded = |name: &str, keywords: &str, affinity: f32| -> i64 {
            let id = vectorised(&db, name, &[0, 0, 0, 100]);
            db.conn()
                .execute(
                    "INSERT INTO metadata (title_id, source, fetched_at, keywords)
                     VALUES (?1, 'tmdb', 1, ?2)",
                    rusqlite::params![id, keywords],
                )
                .unwrap();
            db.conn()
                .execute(
                    "INSERT INTO title_taste (title_id, facet, affinity, rejected)
                     VALUES (?1, 0, ?2, '')",
                    rusqlite::params![id, affinity],
                )
                .unwrap();
            id
        };
        for n in 0..4 {
            keyworded(&format!("Heist {n}"), "heist, noir", 0.9);
        }
        for n in 0..5 {
            keyworded(&format!("Far Robbery {n}"), "robbery", 0.1);
        }
        let seen = keyworded("Seen Heist", "heist", 0.9);
        play(&db, seen, NOW - DAY, true, 0.0);
        let stored = |db: &Db| -> Vec<(String, String, usize)> {
            db.conn()
                .prepare("SELECT kind, value, COUNT(*) FROM club_pick GROUP BY kind, value ORDER BY value")
                .unwrap()
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        db.replace_club(&club_themes(&db).unwrap()).unwrap();
        assert!(stored(&db).is_empty(), "{:?}", stored(&db));

        keyworded("Heist 4", "heist", 0.8);
        keyworded("Heist 5", "heist", 0.0);
        db.replace_club(&club_themes(&db).unwrap()).unwrap();
        assert_eq!(
            stored(&db),
            [("keyword".to_string(), "heist".to_string(), 6)]
        );
    }

    #[test]
    fn two_tastes_are_two_rows_of_one_and_never_their_midpoint() {
        let db = two_tastes();
        refresh(&db, NOW).unwrap();
        // one horror film and one children's film, dealt between the tastes in
        // the order their share of the history puts them in. The title halfway
        // between the two is what the average of this history points at, and
        // it is nobody's evening: it is not in the row at all.
        assert_eq!(row(&db), ["Small Unseen", "Horror Unseen"]);
    }

    #[test]
    fn a_contested_taste_weighs_less_at_the_next_refresh_and_is_back_on_the_31st_day() {
        let db = two_tastes();
        // the share of the history behind the taste `leader` names
        let share = |db: &Db, now: i64, leader: i64| -> f32 {
            refresh(db, now).unwrap();
            let facets = db.taste_facets().unwrap();
            let total: f32 = facets.iter().map(|f| f.weight).sum();
            facets.iter().find(|f| f.leader == leader).unwrap().weight / total
        };
        refresh(&db, NOW).unwrap();
        let leader = db.taste_facets().unwrap()[0].leader;
        let plain = share(&db, NOW, leader);
        let plain_later = share(&db, NOW + 31 * DAY, leader);

        db.mute_taste(leader, NOW + MUTE_SECS).unwrap();
        let muted = share(&db, NOW, leader);
        assert!(muted < plain * 0.8, "muted {muted} against {plain}");
        let later = share(&db, NOW + 31 * DAY, leader);
        assert!(
            (later - plain_later).abs() < 1e-6,
            "{later} against {plain_later}"
        );
    }

    #[test]
    fn a_taste_gets_the_share_of_the_row_its_history_earned() {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two", "Horror Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        let bear = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        play(&db, bear, NOW - DAY, true, 0.0);
        for n in 0..4 {
            vectorised(&db, &format!("Horror Unseen {n}"), &[100, 0, 0, 0]);
            vectorised(&db, &format!("Small Unseen {n}"), &[0, 100, 0, 0]);
        }
        refresh(&db, NOW).unwrap();

        // three quarters of the history is horror, so three of every four
        // tiles are - and the quarter that is not is on the first screenful
        // rather than buried past the end of the shelf. The row holds every
        // title either taste can offer, in the proportion that earned it.
        let names = row(&db);
        assert_eq!(names.len(), 8, "{names:?}");
        let small = |from: &[String]| from.iter().filter(|n| n.starts_with("Small")).count();
        assert_eq!(small(&names), 4, "{names:?}");
        assert_eq!(small(&names[..4]), 1, "{names:?}");
    }

    #[test]
    fn what_was_watched_last_night_outweighs_what_was_watched_in_march() {
        let db = Db::open_in_memory().unwrap();
        // the older taste is the bigger one by title count, and still loses:
        // three films from a year ago are not what tonight is about
        for name in ["Horror One", "Horror Two", "Horror Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - 365 * DAY, true, 0.0);
        }
        for name in ["Small Bear", "Small Fox"] {
            let id = vectorised(&db, name, &[0, 100, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[100, 0, 0, 0]);
        vectorised(&db, "Small Unseen", &[0, 100, 0, 0]);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Small Unseen", "Horror Unseen"]);
    }

    #[test]
    fn a_film_watched_to_the_end_outweighs_one_abandoned_after_four_minutes() {
        let db = Db::open_in_memory().unwrap();
        // same evening, same count in the bigger taste's favour: what
        // separates them is that nobody sat through the horror
        for name in ["Horror One", "Horror Two", "Horror Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, false, 240.0);
        }
        for name in ["Small Bear", "Small Fox"] {
            let id = vectorised(&db, name, &[0, 100, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[100, 0, 0, 0]);
        vectorised(&db, "Small Unseen", &[0, 100, 0, 0]);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Small Unseen", "Horror Unseen"]);
    }

    #[test]
    fn a_title_no_nearer_than_average_is_left_out_rather_than_filling_a_slot() {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two", "Horror Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[99, 8, 0, 0]);
        // shares a little with the taste and belongs to none of it: the row
        // ends rather than reaching down for it
        vectorised(&db, "Faint Echo", &[40, 90, 0, 0]);
        vectorised(&db, "Nothing In Common", &[0, 0, 100, 0]);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Horror Unseen"]);
    }

    /// The bug this row was shipped with, in the shape it had on the owner's
    /// library: a row of Avengers films called "because you like 22 Jump
    /// Street", because one buddy comedy at the edge of the cluster was the
    /// last thing finished.
    #[test]
    fn a_row_is_named_after_what_it_holds_not_after_the_last_thing_watched() {
        let db = Db::open_in_memory().unwrap();
        // a taste with a middle: three films pointing the same way
        for name in ["Cape One", "Cape Two", "Cape Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0, 0]);
            play(&db, id, NOW - 120 * DAY, true, 0.0);
        }
        // and one watched last night that belongs to it and does not speak for
        // it: it leans off the taste in a direction none of the others share
        let edge = vectorised(&db, "Buddy Comedy", &[70, 0, 0, 0, 68]);
        play(&db, edge, NOW - DAY, true, 0.0);
        // three other tastes, so the four facets have somewhere to go
        for (name, v) in [
            ("Romance One", [0, 100, 0, 0, 0]),
            ("Horror One", [0, 0, 100, 0, 0]),
            ("Docs One", [0, 0, 0, 100, 0]),
        ] {
            let id = vectorised(&db, name, &v);
            play(&db, id, NOW - 120 * DAY, true, 0.0);
        }
        vectorised(&db, "Cape Unseen", &[99, 6, 0, 0, 0]);
        refresh(&db, NOW).unwrap();

        // the heaviest member of the taste is the buddy comedy, and the row it
        // anchored is capes: the name comes from the middle of the row
        let named: Vec<String> = db
            .conn()
            .prepare(
                "SELECT DISTINCT l.name FROM taste_pick p
                 JOIN titles t ON t.id = p.title_id
                 JOIN titles l ON l.id = p.leader WHERE t.name = 'Cape Unseen'",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(named, ["Cape One"], "{named:?}");
    }

    /// A library whose vectors are the direction every title shares and
    /// nothing else, which is what an encoder writes when it has no words for
    /// any of them. Once that direction is taken out there is no title left to
    /// point anywhere, so there is no taste to find and nothing a row could
    /// honestly be named after: the home screen gets no row rather than four
    /// that lie. Read raw, every one of these is every other one's neighbour
    /// at a cosine of exactly one.
    #[test]
    fn a_library_that_is_all_one_direction_holds_no_taste_and_writes_no_row() {
        let db = Db::open_in_memory().unwrap();
        for n in 0..12 {
            let id = vectorised(&db, &format!("Alike {n}"), &[0, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        for n in 0..8 {
            vectorised(&db, &format!("Alike Unseen {n}"), &[0, 0, 0, 0]);
        }
        assert_eq!(refresh(&db, NOW).unwrap(), 0);
        assert!(row(&db).is_empty(), "{:?}", row(&db));
    }

    #[test]
    fn the_row_stands_with_no_tmdb_id_anywhere_and_tmdb_strengthens_it() {
        let db = Db::open_in_memory().unwrap();
        let lead = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        play(&db, lead, NOW - DAY, true, 0.0);
        let near = vectorised(&db, "Nearest", &[100, 2, 0, 0]);
        let second = vectorised(&db, "Second", &[100, 5, 0, 0]);
        vectorised(&db, "Third", &[100, 8, 0, 0]);
        // a library that is not all one thing, so "nearer than average" means
        // something: without it every title here is everything's neighbour
        vectorised(&db, "Elsewhere One", &[0, 100, 0, 0]);
        vectorised(&db, "Elsewhere Two", &[0, 0, 100, 0]);
        vectorised(&db, "Elsewhere Three", &[0, 0, 0, 100]);

        // nothing here has ever been matched to TMDB, which is every device
        // with no key on it: the row is the model's order, and it exists
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Nearest", "Second", "Third"]);

        // a key arrives, the seed of the taste is matched, and TMDB puts the
        // second title first: agreeing with the model outranks leading it
        describe(&db, lead, 42);
        describe(&db, near, 78);
        describe(&db, second, 79);
        db.upsert_similar(42, MediaKind::Movie, &[79]).unwrap();
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Second", "Nearest", "Third"]);
    }

    fn describe(db: &Db, title_id: i64, tmdb_id: i64) {
        db.upsert_metadata(&MetadataRecord {
            title_id,
            tmdb_id: Some(tmdb_id),
            overview_fr: None,
            overview_en: None,
            poster_path: None,
            backdrop_path: None,
            genres: String::new(),
            cast_names: String::new(),
            collections: String::new(),
            director_names: String::new(),
            writer_names: String::new(),
            composer_names: String::new(),
            source: MetadataSource::Tmdb,
            fetched_at: 1,
            critics: None,
            audience: None,
            release_date: None,
        })
        .unwrap();
    }

    #[test]
    fn a_history_or_a_library_with_no_vectors_yields_no_row_at_all() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(refresh(&db, NOW).unwrap(), 0);

        // vectors, and nothing watched: there is no taste to name yet
        vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        assert_eq!(refresh(&db, NOW).unwrap(), 0);
        assert!(row(&db).is_empty());
    }

    /// The hole this signal was asked for. Eight minutes of a hundred-minute
    /// film is `done = 0.08`, which the fingerprint reads as a faint yes: the
    /// taste is weaker than the one behind a finished film, and it is still a
    /// taste, and it still puts its neighbours on the home screen. Nothing in
    /// the model could say otherwise, because nothing in the model can say no.
    #[test]
    fn a_film_abandoned_after_eight_minutes_counts_for_the_viewer_until_they_say_it_does_not() {
        let db = Db::open_in_memory().unwrap();
        let tried: Vec<i64> = ["Horror One", "Horror Two", "Horror Three"]
            .iter()
            .map(|name| {
                let id = vectorised(&db, name, &[100, 0, 0, 0]);
                play(&db, id, NOW - DAY, false, 480.0);
                id
            })
            .collect();
        for name in ["Small Bear", "Small Fox"] {
            let id = vectorised(&db, name, &[0, 100, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[100, 0, 0, 0]);
        vectorised(&db, "Small Unseen", &[0, 100, 0, 0]);

        // three films nobody sat through are a taste, and the row offers more
        // of them
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Small Unseen", "Horror Unseen"]);

        // and this is the sentence the model had no way to hear
        for id in tried {
            said(&db, id, Verdict::Down, NOW);
        }
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Small Unseen"]);
    }

    /// The verdict that stands on nothing: no play, no position, no history
    /// row at all. A viewer can say they like a film they have never started
    /// here, and it is the only signal in this app that works that way.
    #[test]
    fn a_title_never_played_makes_a_taste_when_the_viewer_says_they_like_it() {
        let db = Db::open_in_memory().unwrap();
        let loved = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        vectorised(&db, "Horror Unseen", &[100, 4, 0, 0]);
        vectorised(&db, "Elsewhere One", &[0, 100, 0, 0]);
        vectorised(&db, "Elsewhere Two", &[0, 0, 100, 0]);

        // nothing has been played, so there is nothing to build a taste out of
        assert_eq!(refresh(&db, NOW).unwrap(), 0);

        said(&db, loved, Verdict::Up, NOW);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Horror Unseen"]);
    }

    /// "Adoré" is a level and not an exclamation mark: it is worth two films
    /// finished this evening, so it seeds, steers and claims twice what a
    /// thumb up does, and the row is dealt in that proportion.
    #[test]
    fn a_film_they_adored_is_worth_two_they_merely_liked() {
        let db = Db::open_in_memory().unwrap();
        let liked = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        said(&db, liked, Verdict::Up, NOW);
        let adored = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        said(&db, adored, Verdict::Loved, NOW);
        for n in 0..4 {
            vectorised(&db, &format!("Horror Unseen {n}"), &[100, 0, 0, 0]);
            vectorised(&db, &format!("Small Unseen {n}"), &[0, 100, 0, 0]);
        }
        refresh(&db, NOW).unwrap();

        // two thirds of the row, and the first tile, to the film they adored
        let names = row(&db);
        assert_eq!(names.len(), 8, "{names:?}");
        let small = |from: &[String]| from.iter().filter(|n| n.starts_with("Small")).count();
        assert_eq!(small(&names[..6]), 4, "{names:?}");
        assert!(names[0].starts_with("Small"), "{names:?}");
    }

    /// Both halves of what a thumb down is for, on one library.
    ///
    /// The useful half: the rejected film's own kind of horror goes with it,
    /// which is the whole reason a verdict is worth more than a hidden title.
    /// The dangerous half: the taste it sat in is untouched. What is
    /// subtracted is only the part of the rejected film this taste does not
    /// already explain, so a viewer who rejects one horror film loses that
    /// film and its near-twins, never horror.
    #[test]
    fn a_thumb_down_takes_what_is_distinctively_like_it_and_leaves_the_taste_standing() {
        let db = Db::open_in_memory().unwrap();
        // a taste with a middle rather than a point: three films that agree on
        // what they are and differ in what else they are
        for (name, v) in [
            ("Horror One", [100, 12, 0, 0, 0]),
            ("Horror Two", [100, 0, 12, 0, 0]),
            ("Horror Three", [100, 0, 0, 12, 0]),
        ] {
            let id = vectorised(&db, name, &v);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        // horror, and one thing more that none of the watched three share
        let rejected = vectorised(&db, "Found Footage One", &[100, 0, 0, 0, 18]);
        vectorised(&db, "Found Footage Two", &[100, 0, 0, 0, 18]);
        vectorised(&db, "Plain Horror", &[100, 4, 4, 4, 0]);
        vectorised(&db, "Elsewhere One", &[0, 100, 0, 0, 0]);
        vectorised(&db, "Elsewhere Two", &[0, 0, 0, 100, 0]);

        // the row offers both, the plainer one first
        refresh(&db, NOW).unwrap();
        assert_eq!(
            row(&db),
            ["Plain Horror", "Found Footage One", "Found Footage Two"]
        );

        said(&db, rejected, Verdict::Down, NOW);
        refresh(&db, NOW).unwrap();
        // the rejected film is gone and so is its twin; horror is still here
        assert_eq!(row(&db), ["Plain Horror"]);
    }

    /// Why a verdict carries no half-life. Both signals here are two years
    /// old, and only one of them was a guess about what the viewer meant: a
    /// play is an event the model has to date, a verdict is the viewer saying
    /// it, and saying it does not become less true.
    #[test]
    fn a_verdict_two_years_old_outweighs_a_film_finished_two_years_ago() {
        let db = Db::open_in_memory().unwrap();
        let old = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        play(&db, old, NOW - 730 * DAY, true, 0.0);
        let stated = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        said(&db, stated, Verdict::Up, NOW - 730 * DAY);
        for n in 0..4 {
            vectorised(&db, &format!("Horror Unseen {n}"), &[100, 0, 0, 0]);
            vectorised(&db, &format!("Small Unseen {n}"), &[0, 100, 0, 0]);
        }
        refresh(&db, NOW).unwrap();

        // the play has decayed to the floor and the verdict has not moved, so
        // the first three tiles are what they said and the fourth is what they
        // watched
        let names = row(&db);
        assert_eq!(names.len(), 8, "{names:?}");
        let small = |from: &[String]| from.iter().filter(|n| n.starts_with("Small")).count();
        assert_eq!(small(&names[..4]), 3, "{names:?}");
        assert!(names[0].starts_with("Small"), "{names:?}");
    }

    /// A row promises its contents resemble the title it is named after, so a
    /// title the viewer has rejected must never be the one it names - and a
    /// finished film that was then rejected is exactly the title that would
    /// have led it.
    #[test]
    fn a_row_is_never_named_after_a_film_the_viewer_rejected() {
        let db = Db::open_in_memory().unwrap();
        let regretted = vectorised(&db, "Regretted", &[100, 0, 0, 0]);
        play(&db, regretted, NOW - DAY, true, 0.0);
        let kept = vectorised(&db, "Kept", &[99, 5, 0, 0]);
        play(&db, kept, NOW - 60 * DAY, true, 0.0);
        vectorised(&db, "Horror Unseen", &[98, 3, 0, 0]);
        vectorised(&db, "Elsewhere One", &[0, 100, 0, 0]);
        vectorised(&db, "Elsewhere Two", &[0, 0, 100, 0]);

        refresh(&db, NOW).unwrap();
        assert_eq!(named_after(&db, "Horror Unseen"), ["Regretted"]);

        said(&db, regretted, Verdict::Down, NOW);
        refresh(&db, NOW).unwrap();
        assert_eq!(named_after(&db, "Horror Unseen"), ["Kept"]);
    }

    /// Played to the end `plays` times, the last of them at `at`, as the
    /// server that owns the item reports it.
    fn played_times(db: &Db, title_id: i64, at: i64, plays: u32) {
        let file_id = db
            .conn()
            .query_row(
                "SELECT id FROM files WHERE title_id = ?1",
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
                plays,
                updated_at: at,
            },
            WatchAuthority::Owner,
        )
        .unwrap();
    }

    /// A series with one vector and an episode finished at each of `finished`.
    fn series(db: &Db, name: &str, vector: &[i8], finished: &[i64]) -> i64 {
        let vector: Vec<i8> = std::iter::once(SHARED)
            .chain(vector.iter().copied())
            .collect();
        let id = db.upsert_title(MediaKind::Show, name, None).unwrap();
        db.upsert_embedding(&EmbeddingRecord {
            title_id: id,
            model_version: SMALL,
            source_hash: 0,
            vector,
            computed_at: 1,
        })
        .unwrap();
        for (n, at) in finished.iter().enumerate() {
            let path = format!("Shows/{name}.E{n}.mkv");
            db.upsert_file(&FileRecord {
                source_id: "s1".into(),
                dir: "Shows".into(),
                path: path.clone(),
                size: 1,
                mtime: 0,
                seen_gen: 1,
                title_id: id,
                season: Some(1),
                episode: Some(n as u16 + 1),
                rating_key: None,
                media: FileMedia::default(),
            })
            .unwrap();
            let file_id = db
                .conn()
                .query_row("SELECT id FROM files WHERE path = ?1", [&path], |r| {
                    r.get(0)
                })
                .unwrap();
            db.upsert_watch_state(
                &WatchRecord {
                    file_id,
                    position_secs: 2400.0,
                    duration_secs: 2400.0,
                    watched: true,
                    plays: 1,
                    updated_at: *at,
                },
                WatchAuthority::Report,
            )
            .unwrap();
        }
        id
    }

    fn facet_weight(db: &Db, leader: i64) -> f32 {
        db.taste_facets()
            .unwrap()
            .into_iter()
            .find(|f| f.leader == leader)
            .map(|f| f.weight)
            .unwrap_or_else(|| panic!("no facet led by {leader}: {:?}", db.taste_facets()))
    }

    /// Seeing a film again is saying it twice: four viewings on the same
    /// evening weigh 1 + ln 4 / 2 of one.
    #[test]
    fn a_title_seen_four_times_outweighs_one_seen_once_on_the_same_date() {
        let db = Db::open_in_memory().unwrap();
        let once = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        played_times(&db, once, NOW - 10 * DAY, 1);
        let often = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        played_times(&db, often, NOW - 10 * DAY, 4);
        vectorised(&db, "Horror Unseen", &[100, 4, 0, 0]);
        vectorised(&db, "Small Unseen", &[4, 100, 0, 0]);
        vectorised(&db, "Elsewhere", &[0, 0, 100, 0]);
        refresh(&db, NOW).unwrap();
        let ratio = facet_weight(&db, often) / facet_weight(&db, once);
        assert!((ratio - (1.0 + 0.5 * 4f32.ln())).abs() < 1e-3, "{ratio}");
        assert_eq!(db.taste_facets().unwrap()[0].leader, often);
    }

    /// Five episodes in three days is an appetite, not five small yeses: the
    /// series weighs at least one and a half films finished that week.
    #[test]
    fn five_episodes_in_three_days_weigh_at_least_a_binge() {
        let db = Db::open_in_memory().unwrap();
        let film = vectorised(&db, "Horror One", &[100, 0, 0, 0]);
        play(&db, film, NOW - 8 * DAY, true, 0.0);
        let binged = series(
            &db,
            "Serial",
            &[0, 100, 0, 0],
            &[
                NOW - 11 * DAY,
                NOW - 10 * DAY,
                NOW - 10 * DAY + 3600,
                NOW - 9 * DAY,
                NOW - 8 * DAY,
            ],
        );
        let sipped = series(
            &db,
            "Slow Serial",
            &[0, 0, 100, 0],
            &[
                NOW - 60 * DAY,
                NOW - 45 * DAY,
                NOW - 30 * DAY,
                NOW - 15 * DAY,
                NOW - 8 * DAY,
            ],
        );
        vectorised(&db, "Elsewhere", &[0, 0, 0, 100]);
        refresh(&db, NOW).unwrap();
        let week = recency((8 * DAY) as f32, HALF_LIFE_SECS);
        assert!(facet_weight(&db, binged) >= 1.5 * week - 1e-4);
        // the same five episodes over two months are five evenings, not one
        assert!(
            facet_weight(&db, sipped) < 1.01 * week,
            "{}",
            facet_weight(&db, sipped)
        );
        assert!((facet_weight(&db, film) - week).abs() < 1e-4);
    }

    /// One taste, and three unseen titles in it: one plainly of it, and two
    /// that share one thing more, the nearer of which leads the row. Returns
    /// the one further out, which the tests set aside.
    fn set_aside() -> (Db, i64) {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two", "Horror Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        let aside = vectorised(&db, "Set Aside", &[100, 0, 0, 0, 18]);
        vectorised(&db, "Twin", &[100, 0, 0, 0, 10]);
        vectorised(&db, "Plain Horror", &[100, 11, 0, 0, 0]);
        vectorised(&db, "Elsewhere One", &[0, 100, 0, 0, 0]);
        vectorised(&db, "Elsewhere Two", &[0, 0, 100, 0, 0]);
        vectorised(&db, "Elsewhere Three", &[0, 0, 0, 100, 0]);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Twin", "Plain Horror", "Set Aside"]);
        (db, aside)
    }

    /// Stopped at a tenth and never taken up again is a quiet no: its twin
    /// gives up its place and stays on offer, and the taste is untouched.
    /// Three days on it is not a no yet, only an evening cut short.
    #[test]
    fn a_film_abandoned_weeks_ago_pulls_its_twin_back_and_leaves_the_taste_standing() {
        let (db, dropped) = set_aside();
        play(&db, dropped, NOW - 3 * DAY, false, 600.0);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Twin", "Plain Horror"]);

        play(&db, dropped, NOW - 20 * DAY, false, 600.0);
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Plain Horror", "Twin"]);
    }

    /// Put off three times in two months is a pattern; twice is two evenings.
    /// Either way the title itself stays on offer: a refusal never spends it.
    #[test]
    fn three_refusals_pull_a_neighbour_back_and_two_do_not() {
        let (db, refused) = set_aside();
        for n in 0..2 {
            db.defer_tonight(refused, NOW - (n + 1) * 7 * DAY).unwrap();
        }
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Twin", "Plain Horror", "Set Aside"]);

        db.defer_tonight(refused, NOW - 21 * DAY).unwrap();
        refresh(&db, NOW).unwrap();
        assert_eq!(row(&db), ["Plain Horror", "Twin", "Set Aside"]);
    }

    /// A page read is a lean, not a taste: ten seconds on a title unlike
    /// anything watched takes none of the four facet slots, and the rows keep
    /// being named after what was watched.
    #[test]
    fn a_page_read_on_an_outlier_makes_no_facet_of_its_own() {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Horror Unseen", &[100, 4, 0, 0]);
        let read = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        vectorised(&db, "Small Fox", &[4, 100, 0, 0]);
        vectorised(&db, "Elsewhere", &[0, 0, 100, 0]);
        refresh(&db, NOW).unwrap();
        let before: Vec<i64> = db
            .taste_facets()
            .unwrap()
            .iter()
            .map(|f| f.leader)
            .collect();

        db.record_interest(read, crate::index::db::TASTE_DWELL, NOW - DAY)
            .unwrap();
        refresh(&db, NOW).unwrap();
        let after: Vec<i64> = db
            .taste_facets()
            .unwrap()
            .iter()
            .map(|f| f.leader)
            .collect();
        assert_eq!(after, before);
        assert!(
            !row(&db).contains(&"Small Fox".to_string()),
            "{:?}",
            row(&db)
        );
    }

    /// Ten seconds on a title near a taste leans that taste towards it: the
    /// facet gains the gesture's weight and turns, the title stays on offer,
    /// and the row is still named after something the viewer watched.
    #[test]
    fn a_page_read_near_a_taste_moves_it_without_leading_it() {
        let db = Db::open_in_memory().unwrap();
        for name in ["Horror One", "Horror Two"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        let bear = vectorised(&db, "Small Bear", &[0, 100, 0, 0]);
        play(&db, bear, NOW - DAY, true, 0.0);
        let read = vectorised(&db, "Small Fox", &[0, 100, 40, 0]);
        vectorised(&db, "Small Kin", &[0, 100, 30, 0]);
        vectorised(&db, "Horror Unseen", &[100, 4, 0, 0]);
        vectorised(&db, "Elsewhere", &[0, 0, 0, 100]);
        refresh(&db, NOW).unwrap();
        let facet = |db: &Db| {
            db.taste_facets()
                .unwrap()
                .into_iter()
                .find(|f| f.leader == bear)
        };
        let before = facet(&db).expect("a facet led by the bear");

        db.record_interest(read, crate::index::db::TASTE_DWELL, NOW - DAY)
            .unwrap();
        refresh(&db, NOW).unwrap();
        let after = facet(&db).expect("still led by the bear");
        assert!(db.taste_facets().unwrap().iter().all(|f| f.leader != read));
        assert!(
            (after.weight - before.weight - INTEREST_WEIGHT).abs() < 1e-4,
            "{after:?}"
        );
        assert!(
            (after.cos_to_top - before.cos_to_top).abs() > 1e-4,
            "{before:?} {after:?}"
        );
        assert!(
            row(&db).contains(&"Small Fox".to_string()),
            "{:?}",
            row(&db)
        );
    }

    /// A taste the viewer has held for years and not revisited lately is a
    /// taste, not a memory: it decays three times slower than a passing one.
    #[test]
    fn a_taste_watched_three_years_ago_keeps_more_share_than_one_half_life_allows() {
        let db = Db::open_in_memory().unwrap();
        let old: Vec<i64> = (0..3)
            .map(|n| {
                let id = vectorised(&db, &format!("Horror {n}"), &[100, n as i8 * 3, 0, 0]);
                play(&db, id, NOW - 3 * 365 * DAY, true, 0.0);
                id
            })
            .collect();
        for name in ["Small Bear", "Small Fox"] {
            let id = vectorised(&db, name, &[0, 100, 0, 0]);
            play(&db, id, NOW - DAY, true, 0.0);
        }
        vectorised(&db, "Elsewhere", &[0, 0, 100, 0]);
        refresh(&db, NOW).unwrap();
        let facets = db.taste_facets().unwrap();
        let total: f32 = facets.iter().map(|f| f.weight).sum();
        let horror: f32 = facets
            .iter()
            .filter(|f| old.contains(&f.leader))
            .map(|f| f.weight)
            .sum();
        let age = (3 * 365 * DAY) as f32;
        let one = 3.0 * recency(age, HALF_LIFE_SECS);
        let recent = 2.0 * recency(DAY as f32, HALF_LIFE_SECS);
        assert!(horror / total > one / (one + recent) + 0.02, "{facets:?}");
        assert!(
            (horror - 3.0 * recency(age, HALF_LIFE_SECS * 3.0)).abs() < 1e-3,
            "{facets:?}"
        );
    }

    #[test]
    fn a_series_binged_at_the_edge_of_a_taste_does_not_name_it() {
        let db = Db::open_in_memory().unwrap();
        // a taste kept for years, each film of it down to the recency floor
        for name in ["Cape One", "Cape Two", "Cape Three"] {
            let id = vectorised(&db, name, &[100, 0, 0, 0, 0]);
            play(&db, id, NOW - 700 * DAY, true, 0.0);
        }
        // eight episodes in a week: the heaviest title of the history by far
        let episodes: Vec<i64> = (0..8).map(|n| NOW - 20 * DAY + n * 18 * 3_600).collect();
        series(&db, "Under The Pier", &[70, 0, 0, 0, 68], &episodes);
        for (name, v) in [
            ("Romance One", [0, 100, 0, 0, 0]),
            ("Horror One", [0, 0, 100, 0, 0]),
            ("Docs One", [0, 0, 0, 100, 0]),
        ] {
            let id = vectorised(&db, name, &v);
            play(&db, id, NOW - 700 * DAY, true, 0.0);
        }
        refresh(&db, NOW).unwrap();
        let leaders: Vec<String> = db
            .taste_facets()
            .unwrap()
            .iter()
            .map(|f| {
                db.conn()
                    .query_row("SELECT name FROM titles WHERE id = ?1", [f.leader], |r| {
                        r.get(0)
                    })
                    .unwrap()
            })
            .collect();
        assert_eq!(leaders[0], "Cape One", "{leaders:?}");
    }

    fn named_after(db: &Db, title: &str) -> Vec<String> {
        db.conn()
            .prepare(
                "SELECT DISTINCT l.name FROM taste_pick p
                 JOIN titles t ON t.id = p.title_id
                 JOIN titles l ON l.id = p.leader WHERE t.name = ?1",
            )
            .unwrap()
            .query_map([title], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }
}
