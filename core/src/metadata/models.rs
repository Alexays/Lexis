//! The slice of the TMDB JSON API the core reads. Unknown fields are ignored.

use serde::{Deserialize, Deserializer};

/// TMDB writes an unset field as `null` about as often as it omits it, and a
/// null in one field must not cost the whole payload.
fn null_as_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Default, Deserialize)]
pub struct SearchResponse {
    #[serde(default, deserialize_with = "null_as_default")]
    pub results: Vec<SearchResult>,
}

/// One search hit, with everything the match rule weighs: a movie's titles
/// arrive as `title`/`original_title` and a show's as `name`/`original_name`,
/// and the date is "YYYY-MM-DD" or "" when TMDB holds none.
#[derive(Debug, Default, Deserialize)]
pub struct SearchResult {
    pub id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pub title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub original_title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub original_name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub release_date: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub first_air_date: String,
}

/// Movie and TV details share every field we read.
#[derive(Debug, Default, Deserialize)]
pub struct Details {
    #[serde(default, deserialize_with = "null_as_default")]
    pub overview: String,
    #[serde(default)]
    pub poster_path: Option<String>,
    #[serde(default)]
    pub backdrop_path: Option<String>,
    #[serde(default, deserialize_with = "null_as_default")]
    pub genres: Vec<Genre>,
    /// Present only because the details request asks for it with
    /// append_to_response; TMDB does not send it otherwise.
    #[serde(default, deserialize_with = "null_as_default")]
    pub credits: Credits,
    /// A series' billing across every season, where `credits` holds the latest
    /// season's alone. Asked for on shows only; its crew spells jobs another
    /// way and is never read.
    #[serde(default, deserialize_with = "null_as_default")]
    pub aggregate_credits: Credits,
    /// The saga this title is filed under, which only TMDB knows: null for a
    /// standalone film, and absent from every show payload.
    #[serde(default)]
    pub belongs_to_collection: Option<Collection>,
    /// What TMDB's own voters gave it, out of ten. An audience score and never
    /// a critics' one, whatever the column it ends up filling would suggest:
    /// these are site users, the same population Plex files under
    /// `audienceRating`.
    #[serde(default, deserialize_with = "null_as_default")]
    pub vote_average: f32,
    /// How many of them voted. A ten out of four votes is not a ten, and this
    /// is the only thing on the wire that says so.
    #[serde(default, deserialize_with = "null_as_default")]
    pub vote_count: u32,
    /// "YYYY-MM-DD" or "": a film's date arrives as `release_date`, a
    /// series' as `first_air_date`.
    #[serde(default, deserialize_with = "null_as_default")]
    pub release_date: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub first_air_date: String,
}

/// A title's keywords. A film's answer lists them under `keywords` and a
/// series' under `results`, so both are read and one of them is empty.
#[derive(Debug, Default, Deserialize)]
pub struct Keywords {
    #[serde(default, deserialize_with = "null_as_default")]
    pub keywords: Vec<Keyword>,
    #[serde(default, deserialize_with = "null_as_default")]
    pub results: Vec<Keyword>,
}

#[derive(Debug, Deserialize)]
pub struct Keyword {
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct Collection {
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct Genre {
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct Credits {
    #[serde(default, deserialize_with = "null_as_default")]
    pub cast: Vec<CastMember>,
    #[serde(default, deserialize_with = "null_as_default")]
    pub crew: Vec<CrewMember>,
}

/// One credit behind the camera. `job` is what is read and `department` is not:
/// TMDB files the composer under "Sound" next to the boom operator, and the
/// screenwriter under "Writing" next to whoever wrote the novel, so the
/// department is too coarse to pick a taste signal out of.
#[derive(Debug, Deserialize)]
pub struct CrewMember {
    #[serde(default, deserialize_with = "null_as_default")]
    pub id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub job: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub profile_path: String,
}

/// One credit in front of the camera. The id and the photograph ride along on
/// the details call the enrichment already makes, so a face costs no request
/// of its own: `profile_path` is empty for a performer TMDB holds no
/// photograph of, which is a final answer rather than a miss.
#[derive(Debug, Deserialize)]
pub struct CastMember {
    #[serde(default, deserialize_with = "null_as_default")]
    pub id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub profile_path: String,
    /// The part played; empty on a series' aggregate billing, which names its
    /// parts in `roles` instead.
    #[serde(default, deserialize_with = "null_as_default")]
    pub character: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub roles: Vec<CastRole>,
}

/// One part a performer played across a series, and in how many episodes.
#[derive(Debug, Deserialize)]
pub struct CastRole {
    #[serde(default, deserialize_with = "null_as_default")]
    pub character: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub episode_count: u32,
}

/// The images payload. Only the logos are read: posters and backdrops come
/// off the details call, which the enrichment already makes.
#[derive(Debug, Default, Deserialize)]
pub struct Images {
    #[serde(default, deserialize_with = "null_as_default")]
    pub logos: Vec<LogoImage>,
}

/// A details call with the images appended to it, asked in English. Both
/// halves are needed together to choose a logo: the lettering to pick from,
/// and the English name that says whether English lettering would read as the
/// title this app writes. A movie answers in `title` and a show in `name`.
#[derive(Debug, Default, Deserialize)]
pub struct DetailedImages {
    #[serde(default, deserialize_with = "null_as_default")]
    pub title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub images: Images,
}

/// The videos payload. Only YouTube entries are read: TMDB also lists Vimeo,
/// and the app has nowhere to send a Vimeo key.
#[derive(Debug, Default, Deserialize)]
pub struct Videos {
    #[serde(default, deserialize_with = "null_as_default")]
    pub results: Vec<Video>,
}

/// A details call with the videos appended to it. Nothing else on that payload
/// is read here: the description, the artwork and the billing are the
/// enrichment's, and this call is made long after it.
#[derive(Debug, Default, Deserialize)]
pub struct DetailedVideos {
    #[serde(default, deserialize_with = "null_as_default")]
    pub videos: Videos,
}

/// One video TMDB lists for a title. `key` is the id on `site`, `kind` is
/// TMDB's own `type` - "Trailer", "Teaser", "Clip", "Featurette" and a dozen
/// more - and `official` marks what the studio published rather than what a
/// viewer uploaded.
#[derive(Debug, Deserialize)]
pub struct Video {
    #[serde(default, deserialize_with = "null_as_default")]
    pub key: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub site: String,
    #[serde(rename = "type", default, deserialize_with = "null_as_default")]
    pub kind: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub official: bool,
    /// "" for a video TMDB files under no language, which it writes as an
    /// empty string rather than as a null.
    #[serde(default, deserialize_with = "null_as_default")]
    pub iso_639_1: String,
    /// ISO 8601, "" when TMDB holds no date. Compared as text: that format
    /// orders the same way the instant it names does.
    #[serde(default, deserialize_with = "null_as_default")]
    pub published_at: String,
}

/// One title treatment. `iso_639_1` is absent as often as it is null, and both
/// mean the same thing: lettering that belongs to no one language.
#[derive(Debug, Deserialize)]
pub struct LogoImage {
    #[serde(default, deserialize_with = "null_as_default")]
    pub file_path: String,
    #[serde(default)]
    pub iso_639_1: Option<String>,
    /// Width over height, TMDB's own measurement of the file. The app draws a
    /// logo by height and needs the width before the PNG is decoded.
    #[serde(default, deserialize_with = "null_as_default")]
    pub aspect_ratio: f32,
    #[serde(default, deserialize_with = "null_as_default")]
    pub vote_average: f32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_explicit_null_reads_like_an_absent_field() {
        let nulled: Details = serde_json::from_str(
            r#"{"id":1,"overview":null,"poster_path":null,"backdrop_path":null,"genres":null}"#,
        )
        .unwrap();
        assert!(nulled.overview.is_empty());
        assert!(nulled.poster_path.is_none());
        assert!(nulled.backdrop_path.is_none());
        assert!(nulled.genres.is_empty());

        let named: Details = serde_json::from_str(r#"{"genres":[{"id":1,"name":null}]}"#).unwrap();
        assert!(named.genres[0].name.is_empty());

        let nulled: Details = serde_json::from_str(r#"{"credits":null}"#).unwrap();
        assert!(nulled.credits.cast.is_empty());
        let nameless: Details =
            serde_json::from_str(r#"{"credits":{"cast":[{"name":null}]}}"#).unwrap();
        assert!(nameless.credits.cast[0].name.is_empty());

        let results: SearchResponse = serde_json::from_str(r#"{"results":null}"#).unwrap();
        assert!(results.results.is_empty());

        let nulled: Details = serde_json::from_str(r#"{"belongs_to_collection":null}"#).unwrap();
        assert!(nulled.belongs_to_collection.is_none());
        let saga: Details =
            serde_json::from_str(r#"{"belongs_to_collection":{"id":1,"name":"Dune"}}"#).unwrap();
        assert_eq!(saga.belongs_to_collection.unwrap().name, "Dune");
        let bare: SearchResult =
            serde_json::from_str(r#"{"id":7,"title":null,"release_date":null}"#).unwrap();
        assert!(bare.title.is_empty());
        assert!(bare.release_date.is_empty());

        let absent: Details = serde_json::from_str("{}").unwrap();
        assert!(absent.overview.is_empty());
        assert!(absent.genres.is_empty());
        let absent: SearchResponse = serde_json::from_str("{}").unwrap();
        assert!(absent.results.is_empty());
    }
}
