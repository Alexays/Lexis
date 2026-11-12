//! Replays past evenings of an index to score the recommendation engine:
//! `replay <index.sqlite> [--evenings 60] [--tz 7200] [--at 180]
//! [--model small|base --model-dir <cache dir>]`.

use lexis_core::embed::Encoder;
use lexis_core::index::replay::{self, ReplayOptions};
use lexis_core::index::tonight;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: replay <index.sqlite> [--evenings 60] [--tz 7200] \
[--at 180, minutes after 18:00, under 720] \
[--model small|base --model-dir <the app's cache directory, holding model/>]";

fn main() -> ExitCode {
    let mut source: Option<PathBuf> = None;
    let mut opts = ReplayOptions {
        evenings: 60,
        tz_offset_secs: 7_200,
        at_minutes: 180,
        reembed: None,
    };
    let (mut model, mut model_dir): (Option<Encoder>, Option<PathBuf>) = (None, None);
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let parsed = match arg.as_str() {
            "--evenings" => args
                .next()
                .and_then(|v| v.parse().ok())
                .map(|v| opts.evenings = v),
            "--tz" => args
                .next()
                .and_then(|v| v.parse().ok())
                .map(|v| opts.tz_offset_secs = v),
            "--at" => args
                .next()
                .and_then(|v| v.parse().ok())
                .filter(|v| *v < tonight::EVENING_LEN_MIN)
                .map(|v| opts.at_minutes = v),
            "--model" => args
                .next()
                .and_then(|v| Encoder::from_key(&v))
                .map(|v| model = Some(v)),
            "--model-dir" => args.next().map(|v| model_dir = Some(PathBuf::from(v))),
            _ if source.is_none() && !arg.starts_with("--") => {
                source = Some(PathBuf::from(arg));
                Some(())
            }
            _ => None,
        };
        if parsed.is_none() {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    }
    let Some(source) = source else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    opts.reembed = match (model, model_dir) {
        (Some(model), Some(dir)) => Some((model, dir)),
        (None, None) => None,
        _ => {
            eprintln!("--model and --model-dir go together\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match replay::run(&source, &opts) {
        Ok(r) => {
            println!("evenings {}", r.evenings);
            println!("trio_hits {}", r.trio_hits);
            println!("more_hits {}", r.more_hits);
            println!("taste_hits_20 {}", r.taste_hits_20);
            println!("taste_hits_60 {}", r.taste_hits_60);
            println!("mrr_taste {:.4}", r.mrr_taste);
            println!("row_hits_head {}", r.row_hits_head);
            println!("row_hits {}", r.row_hits);
            println!("mrr_rows {:.4}", r.mrr_rows);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("replay: {e}");
            ExitCode::FAILURE
        }
    }
}
