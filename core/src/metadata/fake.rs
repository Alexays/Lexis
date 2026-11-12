//! A scripted TMDB server, on the HTTP harness the Plex tests already use.

use crate::plex::fake::{FakeServer, Reply};

pub const DUNE_FR: &str = r#"{"id":438631,"overview":"Dans un futur lointain.",
  "poster_path":"/dune.jpg","backdrop_path":"/dune-bd.jpg",
  "vote_average":7.8,"vote_count":1240,"release_date":"2021-09-15",
  "belongs_to_collection":{"id":726871,"name":"Dune - Saga"},
  "genres":[{"id":878,"name":"Science-Fiction"},{"id":12,"name":"Aventure"}],
  "credits":{"cast":[{"id":1190668,"name":"Timothee Chalamet","profile_path":"/tc.jpg",
    "character":"Paul Atreides"},
    {"id":933238,"name":"Rebecca Ferguson","profile_path":"/rf.jpg"},
    {"id":25072,"name":"Oscar Isaac","profile_path":null},
    {"name":"Josh Brolin"},{"name":"Stellan Skarsgard"},
    {"name":"Zendaya"},{"name":"Chang Chen"},{"name":"Dave Bautista"},
    {"name":"Sharon Duncan-Brewster"},{"name":"Jason Momoa"}],
  "crew":[{"name":"Joe Walker","job":"Editor","department":"Editing"},
    {"id":137427,"name":"Denis Villeneuve","job":"Director","department":"Directing",
     "profile_path":"/dv.jpg"},
    {"name":"Greig Fraser","job":"Director of Photography","department":"Camera"},
    {"name":"Frank Herbert","job":"Novel","department":"Writing"},
    {"name":"Denis Villeneuve","job":"Screenplay","department":"Writing"},
    {"name":"Jon Spaihts","job":"Screenplay","department":"Writing"},
    {"name":"Eric Roth","job":"Screenplay","department":"Writing"},
    {"name":"Theresa Repola Mohammed","job":"Boom Operator","department":"Sound"},
    {"name":"Hans Zimmer","job":"Original Music Composer","department":"Sound"}]}}"#;

pub const DUNE_EN: &str = r#"{"id":438631,"overview":"A far future.",
  "poster_path":"/dune-en.jpg","backdrop_path":"/dune-bd.jpg",
  "belongs_to_collection":{"id":726871,"name":"Dune - Saga"},
  "genres":[{"id":878,"name":"Science Fiction"},{"id":12,"name":"Adventure"}],
  "credits":{"cast":[{"name":"Timothee Chalamet"},{"name":"Rebecca Ferguson"},
    {"name":"Oscar Isaac"},{"name":"Josh Brolin"},{"name":"Stellan Skarsgard"},
    {"name":"Zendaya"},{"name":"Chang Chen"},{"name":"Dave Bautista"},
    {"name":"Sharon Duncan-Brewster"},{"name":"Jason Momoa"}]}}"#;

/// A title TMDB knows only in English: the fr-FR overview comes back empty.
pub const SOLARIS_FR: &str = r#"{"id":762,"overview":"","poster_path":"/solaris.jpg",
  "backdrop_path":null,"genres":[],"vote_average":9.5,"vote_count":12,"release_date":""}"#;

pub const SOLARIS_EN: &str = r#"{"id":762,"overview":"A psychologist is sent.",
  "poster_path":"/solaris.jpg","backdrop_path":null,
  "genres":[{"id":878,"name":"Science Fiction"}]}"#;

pub const EXPANSE_FR: &str = r#"{"id":63639,"overview":"Au 23e siecle.","first_air_date":"2015-12-14",
  "poster_path":"/expanse.jpg","backdrop_path":"/expanse-bd.jpg",
  "credits":{"cast":[{"id":1,"name":"Steven Strait","character":""}]},
  "aggregate_credits":{"cast":[
    {"id":1,"name":"Steven Strait","roles":[
      {"character":"Holden (voice)","episode_count":1},
      {"character":"James Holden","episode_count":62}]},
    {"id":2,"name":"Dominique Tipper","roles":[
      {"character":"Naomi Nagata","episode_count":62}]}]},
  "genres":[{"id":10765,"name":"Science-Fiction et fantastique"}]}"#;

pub const EXPANSE_EN: &str = r#"{"id":63639,"overview":"In the 23rd century.",
  "poster_path":"/expanse.jpg","backdrop_path":"/expanse-bd.jpg",
  "genres":[{"id":10765,"name":"Sci-Fi & Fantasy"}]}"#;

/// The shape a real answer has, the images appended to the English details:
/// French and English lettering side by side, a language this app does not
/// draw, one with no language at all, and a vector among them. Sampled against
/// this library, French and English logos are about equally common and every
/// file was a PNG; the SVG here is the case TMDB documents rather than one
/// seen, and it costs one comparison to refuse. The English name is the French
/// one, as it is for every title a French library keeps unchanged.
pub const DUNE_LOGOS: &str = r#"{"id":438631,"title":"Dune","images":{"logos":[
  {"file_path":"/dune-en-hi.png","iso_639_1":"en","aspect_ratio":5.6,
   "vote_average":5.3,"width":1400,"height":250},
  {"file_path":"/dune-fr.svg","iso_639_1":"fr","aspect_ratio":4.1,
   "vote_average":9.0,"width":800,"height":195},
  {"file_path":"/dune-fr-logo.png","iso_639_1":"fr","aspect_ratio":3.5,
   "vote_average":2.0,"width":700,"height":200},
  {"file_path":"/dune-ru.png","iso_639_1":"ru","aspect_ratio":4.0,
   "vote_average":9.9,"width":800,"height":200},
  {"file_path":"/dune-none.png","iso_639_1":null,"aspect_ratio":1.2,
   "vote_average":8.0,"width":600,"height":500}]}}"#;

/// Only English, which is the ordinary case, on a show the library names in
/// English too.
pub const EXPANSE_LOGOS: &str = r#"{"id":63639,"name":"The Expanse","images":{"logos":[
  {"file_path":"/expanse-en-logo.png","iso_639_1":"en","aspect_ratio":6.2,
   "vote_average":5.3,"width":1550,"height":250}]}}"#;

/// The case a language ranking alone gets wrong (tv 288671): TMDB knows this
/// series by a French name the library uses, spells it something else in
/// English, and holds English lettering only.
pub const ANHELOS_LOGOS: &str = r#"{"id":288671,"name":"The Map of Longing","images":{"logos":[
  {"file_path":"/anhelos-en-wide.png","iso_639_1":"en","aspect_ratio":5.519,
   "vote_average":0.0,"width":1546,"height":280},
  {"file_path":"/anhelos-en.png","iso_639_1":"en","aspect_ratio":1.455,
   "vote_average":0.0,"width":800,"height":550}]}}"#;

const NO_RESULTS: &str = r#"{"page":1,"results":[],"total_results":0}"#;

/// Knows Dune (2021, and the 1984 film of the same name), Solaris (English
/// only, and only without a year) and The Expanse. Everything else is unknown
/// to it.
pub fn tmdb() -> FakeServer {
    FakeServer::start(|req| {
        let url = req.url.as_str();
        let english = url.contains("language=en-US");
        if url.starts_with("/search/movie") {
            if url.contains("query=Dune") {
                // TMDB answers a name with everything that ever carried it,
                // its own best guess first: the 1984 film is the same title
                // and another film
                return Reply::json(
                    r#"{"page":1,"results":[
                        {"id":9,"title":"Dune","release_date":"1984-12-14"},
                        {"id":438631,"title":"Dune","release_date":"2021-09-15"}]}"#,
                );
            }
            // TMDB has this one under another release year, so only the
            // year-less retry finds it
            if url.contains("query=Solaris") && !url.contains("year=") {
                return Reply::json(
                    r#"{"page":1,"results":[{"id":762,"title":"Solaris",
                        "original_title":"Solyaris","release_date":"1972-05-13"}]}"#,
                );
            }
            return Reply::json(NO_RESULTS);
        }
        if url.starts_with("/search/tv") {
            if url.contains("Expanse") {
                return Reply::json(
                    r#"{"page":1,"results":[{"id":63639,"name":"The Expanse",
                        "first_air_date":"2015-12-14"}]}"#,
                );
            }
            return Reply::json(NO_RESULTS);
        }
        // the logo call is a details call with the images hung off it, so it
        // is told apart from a plain details call by what it appends, and
        // answered before the details arms below: those match on the id alone
        if url.contains("append_to_response=images") {
            if url.starts_with("/movie/438631") {
                return Reply::json(DUNE_LOGOS);
            }
            if url.starts_with("/tv/63639") {
                return Reply::json(EXPANSE_LOGOS);
            }
            if url.starts_with("/tv/288671") {
                return Reply::json(ANHELOS_LOGOS);
            }
            return Reply::status(404);
        }
        // /movie/{id}/keywords and /tv/{id}/keywords
        if let Some((id, _)) = url.split_once("/keywords") {
            return match id {
                "/movie/438631" => Reply::json(
                    r#"{"id":438631,"keywords":[{"id":1,"name":"desert"},{"id":2,"name":"messiah"}]}"#,
                ),
                "/tv/63639" => {
                    Reply::json(r#"{"id":63639,"results":[{"id":3,"name":"space colony"}]}"#)
                }
                _ if id.starts_with("/movie/") => Reply::json(r#"{"keywords":[]}"#),
                _ => Reply::json(r#"{"results":[]}"#),
            };
        }
        // /movie/{id}/credits and /tv/{id}/credits: the same sub-request the
        // details call appends, asked on its own by the faces queue. Answered
        // out of the same payload, so the two cannot drift apart here.
        if let Some((id, _)) = url.split_once("/credits") {
            let details = match id {
                "/movie/438631" => DUNE_FR,
                "/movie/762" => SOLARIS_FR,
                "/tv/63639" => EXPANSE_FR,
                _ => return Reply::status(404),
            };
            let credits = serde_json::from_str::<serde_json::Value>(details)
                .ok()
                .and_then(|d| d.get("credits").cloned())
                .unwrap_or_else(|| serde_json::json!({"cast": [], "crew": []}));
            return Reply::json(&credits.to_string());
        }
        // /movie/{id}/recommendations and /tv/{id}/recommendations, the links the rows join on
        if url.starts_with("/movie/438631/recommendations") {
            return Reply::json(
                r#"{"page":1,"results":[{"id":78},{"id":762},{"id":11111}],"total_pages":1}"#,
            );
        }
        if url.starts_with("/tv/63639/recommendations") {
            return Reply::json(r#"{"page":1,"results":[{"id":1668}],"total_pages":1}"#);
        }
        // TMDB knows this one and finds nothing like it
        if url.starts_with("/movie/762/recommendations") {
            return Reply::json(NO_RESULTS);
        }
        if url.starts_with("/movie/438631") {
            return Reply::json(if english { DUNE_EN } else { DUNE_FR });
        }
        if url.starts_with("/movie/762") {
            return Reply::json(if english { SOLARIS_EN } else { SOLARIS_FR });
        }
        if url.starts_with("/tv/63639") {
            return Reply::json(if english { EXPANSE_EN } else { EXPANSE_FR });
        }
        // a details payload with nothing in it but an id
        if url.starts_with("/movie/999") {
            return Reply::json(r#"{"id":999}"#);
        }
        Reply::status(404)
    })
}
