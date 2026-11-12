use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedName {
    pub title: String,
    pub year: Option<u16>,
    /// (season, episode)
    pub episode: Option<(u16, u16)>,
    /// What the release tags say it speaks, in the shape `FileMedia` stores.
    pub audio_languages: String,
    pub subtitle_languages: String,
}

const RELEASE_TAGS: &[&str] = &[
    "2160p",
    "1080p",
    "720p",
    "480p",
    "4k",
    "uhd",
    "remux",
    "bluray",
    "blu-ray",
    "bdrip",
    "web-dl",
    "webdl",
    "webrip",
    "hdtv",
    "dvdrip",
    "x264",
    "x265",
    "h264",
    "h265",
    "hevc",
    "avc",
    "av1",
    "vc-1",
    "xvid",
    "divx",
    "dv",
    "dovi",
    "hdr",
    "hdr10",
    "hdr10+",
    "hlg",
    "sdr",
    "atmos",
    "truehd",
    "dts",
    "dts-hd",
    "dtshd",
    "ac3",
    "eac3",
    "ddp",
    "aac",
    "flac",
    "10bit",
    "8bit",
    "hybrid",
    "imax",
    "proper",
    "repack",
    "extended",
    "unrated",
    "uncut",
    "remastered",
    "multi",
    "vff",
    "vfq",
    "vfi",
    "vf2",
    "vostfr",
    "truefrench",
    "french",
    "english",
];

fn episode_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\bs(\d{1,2})\s*e(\d{1,3})\b|\b(\d{1,2})x(\d{2,3})\b").unwrap()
    })
}

fn year_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\(?\b(19\d{2}|20\d{2})\b\)?").unwrap())
}

pub fn parse_filename(name: &str) -> ParsedName {
    let stem = match name.rsplit_once('.') {
        Some((s, ext)) if ext.len() <= 4 && !s.is_empty() => s,
        _ => name,
    };
    let cleaned = stem.replace(['.', '_'], " ");

    let (mut title_part, episode) = match episode_re().captures(&cleaned) {
        Some(c) => {
            let m = c.get(0).unwrap();
            let (s, e) = match (c.get(1), c.get(2)) {
                (Some(s), Some(e)) => (s.as_str(), e.as_str()),
                _ => (c.get(3).unwrap().as_str(), c.get(4).unwrap().as_str()),
            };
            let ep = Some((s.parse().unwrap(), e.parse().unwrap()));
            (cleaned[..m.start()].to_string(), ep)
        }
        None => (cleaned.clone(), None),
    };

    let mut year = None;
    // the year leaves the title either way, so "Show.2015.S01E01" and
    // "Show.S01E02" land on one title row; only movies keep it as a field
    if let Some(c) = year_re().captures_iter(&title_part).last() {
        let m = c.get(0).unwrap();
        // never let the year swallow the whole name ("2012.mkv")
        if m.start() > 0 {
            if episode.is_none() {
                year = c[1].parse().ok();
            }
            title_part.truncate(m.start());
        }
    }

    let mut words: Vec<&str> = Vec::new();
    for w in title_part.split_whitespace() {
        if RELEASE_TAGS.contains(&w.to_ascii_lowercase().as_str()) {
            break;
        }
        words.push(w);
    }
    // read only past the year or the episode when there is one, so the word
    // in "The French Connection 1971" is not a French dub
    let named = if title_part.len() < cleaned.trim_end().len() {
        title_part.split_whitespace().count()
    } else {
        words.len()
    };
    let mut audio: Vec<&str> = Vec::new();
    let mut subtitles: Vec<&str> = Vec::new();
    for w in cleaned.split_whitespace().skip(named) {
        let (a, s): (&[&str], &[&str]) = match w.to_ascii_lowercase().as_str() {
            "vf" | "vff" | "vfq" | "vfi" | "vf2" | "truefrench" | "french" => (&["fr"], &[]),
            // the scene's word for the French dub beside the original track
            "multi" => (&["fr", "mul"], &[]),
            "vostfr" => (&[], &["fr"]),
            "english" => (&["en"], &[]),
            _ => continue,
        };
        for code in a {
            if !audio.contains(code) {
                audio.push(code);
            }
        }
        for code in s {
            if !subtitles.contains(code) {
                subtitles.push(code);
            }
        }
    }
    let title = words.join(" ").trim_matches([' ', '-']).to_string();
    let title = if title.is_empty() {
        title_part.trim().to_string()
    } else {
        title
    };
    ParsedName {
        title,
        year,
        episode,
        audio_languages: audio.join(","),
        subtitle_languages: subtitles.join(","),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn movie(title: &str, year: Option<u16>) -> ParsedName {
        ParsedName {
            title: title.into(),
            year,
            episode: None,
            ..Default::default()
        }
    }

    #[test]
    fn movie_dotted_with_tags() {
        assert_eq!(
            parse_filename("Blade.Runner.2049.2017.2160p.REMUX.HEVC.TrueHD.mkv"),
            movie("Blade Runner 2049", Some(2017))
        );
    }

    #[test]
    fn movie_parenthesized_year() {
        assert_eq!(
            parse_filename("Dune (2021) [2160p].mkv"),
            movie("Dune", Some(2021))
        );
    }

    #[test]
    fn year_only_name_is_kept_as_title() {
        assert_eq!(parse_filename("2012.mkv"), movie("2012", None));
        assert_eq!(parse_filename("2012 (2009).mkv"), movie("2012", Some(2009)));
    }

    #[test]
    fn episode_sxxeyy() {
        assert_eq!(
            parse_filename("The.Expanse.S03E05.1080p.WEB-DL.x265-GROUP.mkv"),
            ParsedName {
                title: "The Expanse".into(),
                year: None,
                episode: Some((3, 5)),
                ..Default::default()
            }
        );
    }

    #[test]
    fn episode_with_year_in_the_name_keeps_the_bare_title() {
        // same show as episode_sxxeyy: a year must not split it into two titles
        assert_eq!(
            parse_filename("The.Expanse.2015.S03E05.mkv"),
            ParsedName {
                title: "The Expanse".into(),
                year: None,
                episode: Some((3, 5)),
                ..Default::default()
            }
        );
    }

    #[test]
    fn episode_nxnn() {
        assert_eq!(
            parse_filename("Firefly.1x02.HDTV.mkv"),
            ParsedName {
                title: "Firefly".into(),
                year: None,
                episode: Some((1, 2)),
                ..Default::default()
            }
        );
    }

    #[test]
    fn unmatched_keeps_filename_as_title() {
        assert_eq!(
            parse_filename("concert-rome.mkv"),
            movie("concert-rome", None)
        );
    }

    #[test]
    fn release_tags_name_the_languages_but_a_title_before_the_year_does_not() {
        let multi = parse_filename("Amelie.2001.MULTI.VOSTFR.1080p.mkv");
        assert_eq!(multi.title, "Amelie");
        assert_eq!(multi.audio_languages, "fr,mul");
        assert_eq!(multi.subtitle_languages, "fr");

        let dub = parse_filename("Heat.1995.TRUEFRENCH.720p.mkv");
        assert_eq!(
            (
                dub.audio_languages.as_str(),
                dub.subtitle_languages.as_str()
            ),
            ("fr", "")
        );

        let connection = parse_filename("The.French.Connection.1971.1080p.mkv");
        assert_eq!(connection.audio_languages, "");

        let bare = parse_filename("Amelie.FRENCH.mkv");
        assert_eq!(bare.audio_languages, "fr");
    }

    #[test]
    fn no_extension() {
        assert_eq!(parse_filename("Alien 1979"), movie("Alien", Some(1979)));
    }
}
