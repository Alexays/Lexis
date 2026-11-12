//! The slice of the Plex JSON API the core reads. Unknown fields are ignored.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// The fields below describe the copy rather than the work, and no two Plex
/// versions have spelled them alike: a resolution has come back as `"1080"`
/// and as `1080`, a flag as `true` and as `1`, a score as a number and as the
/// string next to it. A page that fails to deserialize costs the whole
/// section, not one badge, so anything that is not the shape expected here
/// reads as "the server did not say" and the sync carries on.
///
/// Only the fields nothing has confirmed on a real server go through these.
/// The ones the app has always read stay strict, where a surprise is a bug
/// worth hearing about.
fn lenient<'de, D: Deserializer<'de>, T>(
    d: D,
    from: fn(&Value) -> Option<T>,
) -> Result<Option<T>, D::Error> {
    Ok(Option::<Value>::deserialize(d)?.as_ref().and_then(from))
}

fn lenient_string<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    lenient(d, |v| match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    })
}

fn lenient_u32<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    lenient(d, |v| match v {
        Value::Number(n) => n.as_u64().map(|n| n as u32),
        Value::String(s) => s.parse().ok(),
        _ => None,
    })
}

fn lenient_f32<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f32>, D::Error> {
    lenient(d, |v| match v {
        Value::Number(n) => n.as_f64().map(|n| n as f32),
        Value::String(s) => s.parse().ok(),
        _ => None,
    })
}

/// 0 and 1 are how Plex has written its flags for as long as its API has had
/// an XML half, and `false`/`true` are how the JSON half writes them now.
fn lenient_bool<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    lenient(d, |v| match v {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_i64().map(|n| n != 0),
        Value::String(s) => Some(s == "1" || s.eq_ignore_ascii_case("true")),
        _ => None,
    })
}

#[derive(Debug, Deserialize)]
pub struct SectionsResponse {
    #[serde(rename = "MediaContainer")]
    pub container: SectionsContainer,
}

#[derive(Debug, Default, Deserialize)]
pub struct SectionsContainer {
    #[serde(rename = "Directory", default)]
    pub directory: Vec<Section>,
}

#[derive(Debug, Deserialize)]
pub struct Section {
    pub key: String,
    /// "movie", "show", "artist", "photo".
    #[serde(rename = "type")]
    pub kind: String,
    pub title: String,
    /// When the section's own record last changed, in unix seconds; 0 when
    /// the server sends none. Metadata edited on an item moves this.
    #[serde(rename = "updatedAt", default)]
    pub updated_at: i64,
    /// When the server last scanned this section, in unix seconds; 0 when the
    /// server sends none. **This**, and not `updatedAt`, is what a section
    /// gaining files moves: a Plex that has just taken in a film has scanned
    /// its section, and may well not have touched the section's own record at
    /// all.
    #[serde(rename = "scannedAt", default)]
    pub scanned_at: i64,
}

impl Section {
    /// What a sync gates on, stored against the section's key the way a
    /// filesystem scan stores a directory's own mtime. 0 when the server
    /// sends neither stamp, and a section answering 0 is never trusted: it is
    /// pulled in full every time, the same way an unsettled directory mtime is
    /// never trusted by the file scanner.
    ///
    /// The newest of the two, because either moving is a reason to look again
    /// and each answers for something the other does not: the scan for files
    /// arriving and leaving, the record for a title renamed or re-matched in
    /// place. Both only ever count forward, and a change happening now stamps
    /// now, so nothing that moves can move under this maximum.
    pub fn stamp(&self) -> i64 {
        self.updated_at.max(self.scanned_at)
    }
}

#[derive(Debug, Deserialize)]
pub struct ItemsResponse {
    #[serde(rename = "MediaContainer")]
    pub container: ItemsContainer,
}

#[derive(Debug, Default, Deserialize)]
pub struct ItemsContainer {
    /// Only sent on paged responses; 0 means "not sent".
    #[serde(rename = "totalSize", default)]
    pub total_size: u32,
    #[serde(default)]
    pub size: u32,
    #[serde(rename = "Metadata", default)]
    pub metadata: Vec<Metadata>,
}

#[derive(Debug, Deserialize)]
pub struct Metadata {
    #[serde(rename = "ratingKey")]
    pub rating_key: String,
    #[serde(default)]
    pub title: String,
    /// The show name, on episodes only.
    #[serde(rename = "grandparentTitle", default)]
    pub grandparent_title: Option<String>,
    /// The season number, on episodes only.
    #[serde(rename = "parentIndex", default)]
    pub parent_index: Option<u16>,
    /// The episode number, on episodes only.
    #[serde(default)]
    pub index: Option<u16>,
    #[serde(default)]
    pub year: Option<u16>,
    /// The day an item first came out, "2019-04-14". Read for an episode whose
    /// server sent no `year`, which is the one date a season is placed by.
    #[serde(
        rename = "originallyAvailableAt",
        default,
        deserialize_with = "lenient_string"
    )]
    pub originally_available_at: Option<String>,
    /// The server's own description, in the server's language.
    #[serde(default)]
    pub summary: String,
    /// Poster, as a path on the Plex server ("/library/metadata/1/thumb/2").
    #[serde(default)]
    pub thumb: Option<String>,
    /// Backdrop, same shape as `thumb`.
    #[serde(default)]
    pub art: Option<String>,
    /// Resume position in milliseconds; absent on an item never played.
    #[serde(rename = "viewOffset", default)]
    pub view_offset: Option<i64>,
    /// How many times the item was played to the end; absent means never.
    #[serde(rename = "viewCount", default)]
    pub view_count: Option<u32>,
    /// The item's runtime in milliseconds.
    #[serde(default)]
    pub duration: Option<i64>,
    /// The cut a Plex edition names ("Extended Edition"); each edition of a
    /// film is its own item.
    #[serde(rename = "editionTitle", default)]
    pub edition_title: Option<String>,
    /// The critics' score the item's agent carries, out of 10. Plex also sends
    /// `audienceRating` alongside it, and either may be the only one present.
    #[serde(default, deserialize_with = "lenient_f32")]
    pub rating: Option<f32>,
    #[serde(rename = "audienceRating", default, deserialize_with = "lenient_f32")]
    pub audience_rating: Option<f32>,
    /// Who measured the score above, as the URI of the mark Plex would draw:
    /// "imdb://image.rating", "themoviedb://image.rating",
    /// "rottentomatoes://image.rating.ripe". It is the only thing on the wire
    /// that says which scale and which population the number is on, and an
    /// agent that carries no provenance sends none of it.
    #[serde(rename = "ratingImage", default, deserialize_with = "lenient_string")]
    pub rating_image: Option<String>,
    /// The same, for `audienceRating`. Rotten Tomatoes spells the two apart
    /// past the scheme ("image.rating.ripe" against "image.rating.upright")
    /// and every other agent repeats one word.
    #[serde(
        rename = "audienceRatingImage",
        default,
        deserialize_with = "lenient_string"
    )]
    pub audience_rating_image: Option<String>,
    /// When the server last played the item, in unix seconds, the unit
    /// `watch_state.updated_at` holds; absent on an item never played.
    #[serde(rename = "lastViewedAt", default)]
    pub last_viewed_at: Option<i64>,
    /// When the server took the item into its library, in unix seconds. It is
    /// the only date a Plex item has that says when it arrived: the server
    /// exposes no file mtime, and the library's "recently added" order is
    /// built from the file's.
    #[serde(rename = "addedAt", default)]
    pub added_at: Option<i64>,
    /// When the server last rewrote the item's own record, in unix seconds:
    /// a match, an edit, a refresh, and the item's arrival too.
    #[serde(rename = "updatedAt", default)]
    pub updated_at: Option<i64>,
    #[serde(rename = "Genre", default)]
    pub genre: Vec<Tag>,
    /// The billing, as the server tags it.
    #[serde(rename = "Role", default)]
    pub role: Vec<Tag>,
    /// Same shape as Role, and listed alongside it. A show carries the
    /// directors of its episodes here, which is why the column they land in is
    /// cut short.
    #[serde(rename = "Director", default)]
    pub director: Vec<Tag>,
    #[serde(rename = "Writer", default)]
    pub writer: Vec<Tag>,
    /// The franchise or box set this item belongs to, same shape as Genre:
    /// Plex tags membership on the item itself, not on a separate endpoint.
    #[serde(rename = "Collection", default)]
    pub collection: Vec<Tag>,
    #[serde(rename = "Media", default)]
    pub media: Vec<Media>,
    /// The item's pictures by role ("coverPoster", "background",
    /// "clearLogo"), each a path on the server like `thumb`.
    #[serde(rename = "Image", default)]
    pub image: Vec<Image>,
}

impl Metadata {
    /// The title's own lettering, which only this array carries.
    pub fn clear_logo(&self) -> Option<&str> {
        self.image
            .iter()
            .find(|i| i.kind == "clearLogo" && !i.url.is_empty())
            .map(|i| i.url.as_str())
    }
}

#[derive(Debug, Deserialize)]
pub struct Image {
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub url: String,
}

/// A Plex tag object: Genre, Country, Role all share this shape.
#[derive(Debug, Deserialize)]
pub struct Tag {
    #[serde(default)]
    pub tag: String,
    /// The part played, on a Role tag only.
    #[serde(default, deserialize_with = "lenient_string")]
    pub role: Option<String>,
}

/// One copy of an item, with the shape of the picture and the sound in it.
/// Plex spells the resolution as a bare token: "4k", "1080", "720", "sd".
#[derive(Debug, Deserialize)]
pub struct Media {
    #[serde(
        rename = "videoResolution",
        default,
        deserialize_with = "lenient_string"
    )]
    pub video_resolution: Option<String>,
    #[serde(rename = "videoCodec", default, deserialize_with = "lenient_string")]
    pub video_codec: Option<String>,
    #[serde(rename = "audioCodec", default, deserialize_with = "lenient_string")]
    pub audio_codec: Option<String>,
    #[serde(rename = "audioChannels", default, deserialize_with = "lenient_u32")]
    pub audio_channels: Option<u32>,
    /// "atmos" on the object codecs, "ma" on DTS-HD Master Audio, absent on
    /// the plain ones. The only place a listing names Atmos without streams.
    #[serde(rename = "audioProfile", default, deserialize_with = "lenient_string")]
    pub audio_profile: Option<String>,
    #[serde(rename = "Part", default)]
    pub part: Vec<Part>,
}

#[derive(Debug, Deserialize)]
pub struct Part {
    #[serde(default)]
    pub id: i64,
    /// "/library/parts/123/1/file.mkv": the path the stream is opened with.
    pub key: String,
    #[serde(default)]
    pub size: u64,
    /// Only on servers that put the tracks in a section listing; the ones that
    /// do not answer the same listing without this, and never an error.
    #[serde(rename = "Stream", default)]
    pub stream: Vec<Stream>,
}

/// One track. `stream_type` is 1 for video, 2 for audio and 3 for subtitles.
#[derive(Debug, Deserialize)]
pub struct Stream {
    #[serde(rename = "streamType", default, deserialize_with = "lenient_u32")]
    pub stream_type: Option<u32>,
    /// BCP 47, "fr" or "en-US"; absent on a track the file left untagged.
    #[serde(rename = "languageTag", default, deserialize_with = "lenient_string")]
    pub language_tag: Option<String>,
    /// The transfer function: "smpte2084" is HDR10 or HDR10+, "arib-std-b67"
    /// is HLG. Absent on SDR.
    #[serde(rename = "colorTrc", default, deserialize_with = "lenient_string")]
    pub color_trc: Option<String>,
    #[serde(rename = "DOVIPresent", default, deserialize_with = "lenient_bool")]
    pub dovi_present: Option<bool>,
    /// "TrueHD 7.1 (Atmos)", "HEVC 4K HDR10": the one field carrying what the
    /// attributes above leave out on servers that spell it here instead.
    #[serde(
        rename = "extendedDisplayTitle",
        default,
        deserialize_with = "lenient_string"
    )]
    pub extended_display_title: Option<String>,
}
