//! One ranking for every result, whatever source it came from. The server is
//! the only place that ranks: each result carries its `score`, lists come back
//! sorted by it, and apps that merge several lists (one search per language)
//! sort by `score` again instead of applying rules of their own. That keeps
//! the TV app, desktop and phone in agreement.
//!
//! The score adds up, roughly in this order of weight:
//! - resolution against the preferred quality (exact match best, one step
//!   down next, bigger-than-asked a little lower, unknown in between);
//! - swarm health: seeders on a log scale (5 → 50 matters far more than
//!   500 → 545), peers as a small bonus; direct HTTP links count as healthy;
//! - preferred languages: an explicit match beats multi-audio, which beats an
//!   untagged release, and a release in another language sinks;
//! - release quality (remux > Blu-ray > WEB > HDTV);
//! - size sanity: a "1080p" movie of 300 MB is a fake or a re-encode, a 70 GB
//!   remux is too heavy to stream when 1080p was asked;
//! - for episodes, the exact episode before a season pack.

use crate::graphql::types::StreamSource;
use crate::jackett::{episode_specificity, has_token, padded, source_quality_score};

/// Most results a picker shows.
pub const MAX_RESULTS: usize = 24;

pub struct RankPrefs<'a> {
    /// "2160p" | "1080p" | "720p" | "480p" (empty = 1080p).
    pub resolution: &'a str,
    /// Comma-separated language codes ("en,hi"); empty = no preference.
    pub languages: &'a str,
    /// TitleKind::as_db(): "movie" | "series" | "anime" (empty = unknown).
    pub kind: &'a str,
}

/// Filter out what nobody should be offered, score the rest, best first.
pub fn rank(mut out: Vec<StreamSource>, prefs: &RankPrefs) -> Vec<StreamSource> {
    // `.torrent` links the server couldn't turn into magnets can't be opened
    // by the apps; drop them as long as something else is left.
    let openable = |s: &StreamSource| s.is_http() || s.magnet.to_ascii_lowercase().starts_with("magnet:");
    if out.iter().any(openable) {
        out.retain(openable);
    }
    // CAM / telesync never.
    out.retain(|s| source_quality_score(&s.title) >= 2);
    // Confirmed-dead torrents only when there is nothing else.
    if out.iter().any(|s| s.health != "dead") {
        out.retain(|s| s.health != "dead");
    }
    for s in &mut out {
        s.score = score(s, prefs);
    }
    out.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(b.seeders.cmp(&a.seeders))
            .then(b.peers.cmp(&a.peers))
            .then_with(|| a.title.cmp(&b.title))
    });
    out.truncate(MAX_RESULTS);
    out
}

pub fn score(s: &StreamSource, prefs: &RankPrefs) -> i32 {
    let res = detect_resolution(&s.title);
    resolution_score(res, prefs.resolution)
        + swarm_score(s)
        + language_score(&s.language, prefs.languages)
        + source_quality_score(&s.title) * 25
        + size_score(s, res, prefs)
        + episode_score(&s.title, prefs.kind)
}

const LADDER: [u32; 4] = [480, 720, 1080, 2160];

/// 2160 / 1080 / 720 / 480 from a release name.
pub fn detect_resolution(title: &str) -> Option<u32> {
    let h = padded(title);
    // An explicit "1080p" wins over "UHD" / "4K" words ("1080p UHD BluRay"
    // is a 1080p encode of the UHD disc).
    for (tokens, res) in [
        (&["2160p", "2160"][..], 2160),
        (&["1080p", "1080i", "1080"][..], 1080),
        (&["720p", "720"][..], 720),
        (&["480p", "576p"][..], 480),
        (&["4k", "uhd"][..], 2160),
        (&["sd", "dvdrip", "xvid"][..], 480),
    ] {
        if tokens.iter().any(|t| has_token(&h, t)) {
            return Some(res);
        }
    }
    None
}

fn preferred_resolution(raw: &str) -> u32 {
    let q = raw.trim().to_ascii_lowercase();
    if q.contains("2160") || q == "4k" {
        2160
    } else if q.contains("720") {
        720
    } else if q.contains("480") {
        480
    } else {
        1080
    }
}

fn resolution_score(found: Option<u32>, preferred: &str) -> i32 {
    let Some(found) = found else { return 250 };
    let want = preferred_resolution(preferred);
    let pos = |r: u32| LADDER.iter().position(|x| *x == r).unwrap_or(2) as i32;
    match pos(found) - pos(want) {
        0 => 500,
        -1 => 320,
        -2 => 150,
        1 => 300,
        2 => 200,
        _ => 50,
    }
}

fn swarm_score(s: &StreamSource) -> i32 {
    if s.is_http() {
        // A direct link starts at once and needs no swarm: as good as a
        // torrent with ~40 seeders, below a really busy one.
        return 380;
    }
    if s.health == "unknown" {
        // The index didn't say; about what 3 seeders would get.
        return 120;
    }
    let log = |n: i32| ((n.max(0) as f64) + 1.0).log2();
    let seeders = (log(s.seeders) * 70.0).min(560.0) as i32;
    let peers = (log(s.peers) * 8.0).min(60.0) as i32;
    seeders + peers
}

fn language_score(found: &str, preferred: &str) -> i32 {
    let wanted: Vec<String> = preferred
        .split([',', '/', '|', '+'])
        .map(|p| p.trim().to_ascii_lowercase())
        .filter(|p| !p.is_empty() && p != "all")
        .collect();
    if wanted.is_empty() {
        return 0;
    }
    let codes: Vec<String> = found
        .split([',', '/', '|', '+'])
        .map(|p| p.trim().to_ascii_lowercase())
        .filter(|p| !p.is_empty() && p != "unknown")
        .collect();
    // Earlier in the list = more preferred.
    if let Some(i) = wanted.iter().position(|w| codes.iter().any(|c| c == w)) {
        return 120 - (i as i32 * 10).min(40);
    }
    if codes.iter().any(|c| c == "multi") {
        return 80;
    }
    if codes.is_empty() {
        // Untagged Western releases are nearly always English.
        return if wanted.iter().any(|w| w == "en") { 40 } else { 0 };
    }
    -200
}

fn size_score(s: &StreamSource, res: Option<u32>, prefs: &RankPrefs) -> i32 {
    if s.size_bytes == 0 {
        return 0;
    }
    let is_movie = prefs.kind == "movie" || (prefs.kind.is_empty() && episode_specificity(&s.title) < 2);
    // Season packs hold many episodes; their size says nothing per hour.
    if !is_movie && episode_specificity(&s.title) < 2 {
        return 0;
    }
    let hours = if is_movie { 2.0 } else { 0.75 };
    let gb_per_hour = s.size_bytes as f64 / 1024f64.powi(3) / hours;
    let mut score = 0;
    let floor = match res {
        Some(2160) => 2.0,
        Some(1080) => 0.45,
        Some(720) => 0.2,
        _ => 0.0,
    };
    if gb_per_hour < floor {
        score -= 150;
    }
    let remux = has_token(&padded(&s.title), "remux");
    if gb_per_hour > 25.0 {
        score -= 80;
    } else if preferred_resolution(prefs.resolution) <= 1080 && gb_per_hour > 12.0 && !remux {
        score -= 40;
    }
    if remux && preferred_resolution(prefs.resolution) <= 1080 {
        // Lossless 30–80 GB files stall on most connections.
        score -= 60;
    }
    score
}

fn episode_score(title: &str, kind: &str) -> i32 {
    if kind == "movie" {
        return 0;
    }
    (episode_specificity(title) - 1) * 40
}

#[cfg(test)]
mod tests {
    use super::*;

    fn torrent(title: &str, seeders: i32, gb: f64) -> StreamSource {
        StreamSource {
            id: title.into(),
            title: title.into(),
            magnet: format!("magnet:?xt=urn:btih:{}", title.len()),
            seeders,
            health: crate::jackett::health_for(seeders).into(),
            language: "unknown".into(),
            kind: "torrent".into(),
            size_bytes: (gb * 1024f64.powi(3)) as u64,
            ..Default::default()
        }
    }

    fn prefs<'a>(res: &'a str, langs: &'a str) -> RankPrefs<'a> {
        RankPrefs { resolution: res, languages: langs, kind: "movie" }
    }

    fn titles(v: &[StreamSource]) -> Vec<&str> {
        v.iter().map(|s| s.title.as_str()).collect()
    }

    #[test]
    fn preferred_resolution_beats_a_few_more_seeders() {
        let out = rank(
            vec![
                torrent("Dune.2021.720p.BluRay.x264", 60, 4.0),
                torrent("Dune.2021.1080p.BluRay.x264", 40, 9.0),
                torrent("Dune.2021.2160p.BluRay.x265", 45, 30.0),
            ],
            &prefs("1080p", ""),
        );
        assert_eq!(out[0].title, "Dune.2021.1080p.BluRay.x264", "{:?}", titles(&out));
        assert!(out.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn a_dead_swarm_loses_to_a_healthy_lower_resolution() {
        let out = rank(
            vec![
                torrent("Dune.2021.1080p.WEB-DL", 1, 6.0),
                torrent("Dune.2021.720p.WEB-DL", 400, 3.0),
            ],
            &prefs("1080p", ""),
        );
        assert_eq!(out[0].title, "Dune.2021.720p.WEB-DL");
    }

    #[test]
    fn seeders_order_equal_releases() {
        let out = rank(
            vec![
                torrent("Dune.2021.1080p.WEB-DL.A", 12, 6.0),
                torrent("Dune.2021.1080p.WEB-DL.B", 300, 6.0),
                torrent("Dune.2021.1080p.WEB-DL.C", 50, 6.0),
            ],
            &prefs("1080p", ""),
        );
        assert_eq!(titles(&out), vec!["Dune.2021.1080p.WEB-DL.B", "Dune.2021.1080p.WEB-DL.C", "Dune.2021.1080p.WEB-DL.A"]);
    }

    #[test]
    fn implausibly_small_files_sink() {
        let out = rank(
            vec![
                torrent("Dune.2021.1080p.WEB-DL.tiny", 80, 0.3),
                torrent("Dune.2021.1080p.WEB-DL.real", 60, 7.0),
            ],
            &prefs("1080p", ""),
        );
        assert_eq!(out[0].title, "Dune.2021.1080p.WEB-DL.real");
    }

    #[test]
    fn preferred_language_wins_and_others_sink() {
        let mut hindi = torrent("Dune.2021.1080p.WEB-DL.Hindi", 30, 6.0);
        hindi.language = "hi".into();
        let mut spanish = torrent("Dune.2021.1080p.WEB-DL.Spanish", 300, 6.0);
        spanish.language = "es".into();
        let english = torrent("Dune.2021.1080p.WEB-DL", 30, 6.0);
        let out = rank(vec![spanish, english, hindi], &prefs("1080p", "hi,en"));
        assert_eq!(
            titles(&out),
            vec!["Dune.2021.1080p.WEB-DL.Hindi", "Dune.2021.1080p.WEB-DL", "Dune.2021.1080p.WEB-DL.Spanish"]
        );
    }

    #[test]
    fn http_streams_rank_with_torrents_and_drops_cams_and_dead() {
        let http = StreamSource {
            id: "http:1".into(),
            title: "Dune.2021.1080p.WEB-DL".into(),
            kind: "http".into(),
            url: "https://cdn.example/dune.mkv".into(),
            health: "unknown".into(),
            language: "unknown".into(),
            ..Default::default()
        };
        let out = rank(
            vec![
                torrent("Dune.2021.1080p.WEB-DL.weak", 3, 6.0),
                http,
                torrent("Dune.2021.HDCAM", 900, 1.4),
                torrent("Dune.2021.1080p.BluRay.dead", 0, 8.0),
            ],
            &prefs("1080p", ""),
        );
        assert_eq!(titles(&out), vec!["Dune.2021.1080p.WEB-DL", "Dune.2021.1080p.WEB-DL.weak"]);
        assert!(out[0].is_http());
    }

    #[test]
    fn explicit_resolution_wins_over_uhd_words() {
        assert_eq!(detect_resolution("Troy 2004 1080p UHD BluRay DV HDR"), Some(1080));
        assert_eq!(detect_resolution("Troy 2004 UHD BluRay HDR"), Some(2160));
        assert_eq!(detect_resolution("Troy.2004.4K.WEB"), Some(2160));
        assert_eq!(detect_resolution("Troy.2004.BluRay"), None);
    }

    #[test]
    fn single_episode_before_season_pack() {
        let p = RankPrefs { resolution: "1080p", languages: "", kind: "series" };
        let out = rank(
            vec![
                torrent("Show.S01.1080p.WEB-DL", 50, 20.0),
                torrent("Show.S01E02.1080p.WEB-DL", 50, 1.5),
            ],
            &p,
        );
        assert_eq!(out[0].title, "Show.S01E02.1080p.WEB-DL");
    }
}
