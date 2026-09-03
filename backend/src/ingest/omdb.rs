use serde::Deserialize;
use tracing::{debug, info, warn};

use super::{throttle, IngestContext};
use crate::error::Result;
use crate::ingest::tmdb::{apply_content_rating, reindex, replace_genre_names, upsert_ratings, upsert_title};

/// Popular IMDb IDs used to fill Movies/Series from OMDb without TMDB.
/// OMDb is fetched one title at a time and skipped if already in the catalog.
const OMDB_SEED: &[&str] = &[
    // Movies
    "tt0111161", "tt0068646", "tt0468569", "tt0071562", "tt0050083", "tt0108052", "tt0167260",
    "tt0110912", "tt0120737", "tt0060196", "tt0109830", "tt0137523", "tt0167261", "tt0080684",
    "tt0133093", "tt0099685", "tt0073486", "tt0114369", "tt0110413", "tt0102926", "tt0120815",
    "tt0816692", "tt1375666", "tt0172495", "tt0120586", "tt0482571", "tt0407887", "tt0209144",
    "tt0120689", "tt0076759", "tt0088763", "tt0107290", "tt0110357", "tt0120338", "tt0499549",
    "tt0848228", "tt4154796", "tt4154756", "tt1853728", "tt0993846", "tt1345836", "tt0372784",
    "tt1130884", "tt2015381", "tt2582802", "tt6751668", "tt7286456", "tt1745960", "tt15398776",
    "tt1517268", "tt9362722", "tt6710474", "tt1160419", "tt15239678", "tt10872600", "tt1877830",
    "tt0081505", "tt0078748", "tt0086190", "tt0114814", "tt0095016", "tt0103064", "tt0114709",
    "tt0266697", "tt0112573", "tt0119217", "tt0266543", "tt0435761", "tt1049413", "tt0910970",
    "tt2380307", "tt2096673", "tt1979376", "tt0892769", "tt2278388", "tt0118715", "tt0054215",
    "tt0034583", "tt0047478", "tt0057012", "tt0062622", "tt0082971", "tt0088247", "tt0090605",
    "tt0107048", "tt0119488", "tt0264464", "tt0338013", "tt0361748", "tt0469494", "tt0470752",
    "tt0780504", "tt1201607", "tt1392190", "tt1663202", "tt1856101", "tt2543164", "tt3315342",
    // Series
    "tt0903747", "tt0944947", "tt1475582", "tt4574334", "tt0386676", "tt0108778", "tt0141842",
    "tt0773262", "tt2442560", "tt2861424", "tt2085059", "tt3032476", "tt0306414", "tt0185906",
    "tt7660850", "tt1190634", "tt8111088", "tt2356777", "tt5753856", "tt4786824", "tt5180504",
    "tt6468322", "tt2306299", "tt2802850", "tt4158110", "tt3322312", "tt0475784", "tt3581920",
    "tt2705436", "tt0417299", "tt0898266", "tt0460681", "tt1632701", "tt1520211", "tt0460649",
];

#[derive(Debug, Deserialize)]
struct OmdbResponse {
    #[serde(rename = "Title")]
    title: Option<String>,
    #[serde(rename = "Year")]
    year: Option<String>,
    #[serde(rename = "Runtime")]
    runtime: Option<String>,
    #[serde(rename = "Genre")]
    genre: Option<String>,
    #[serde(rename = "Plot")]
    plot: Option<String>,
    #[serde(rename = "Rated")]
    rated: Option<String>,
    #[serde(rename = "Poster")]
    poster: Option<String>,
    #[serde(rename = "imdbID")]
    imdb_id: Option<String>,
    #[serde(rename = "Type")]
    kind: Option<String>,
    #[serde(rename = "imdbRating")]
    imdb_rating: Option<String>,
    #[serde(rename = "imdbVotes")]
    imdb_votes: Option<String>,
    #[serde(rename = "Ratings")]
    ratings: Option<Vec<OmdbSourceRating>>,
    #[serde(rename = "Response")]
    response: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OmdbSourceRating {
    #[serde(rename = "Source")]
    source: Option<String>,
    #[serde(rename = "Value")]
    value: Option<String>,
}

/// Fill the movie/series catalog from OMDb, then backfill missing IMDb / RT scores.
pub async fn sync_catalog(ctx: &IngestContext) -> Result<()> {
    if ctx.config.omdb_key().is_empty() {
        warn!("OMDB_API_KEY is empty; skipping OMDb ingest");
        return Ok(());
    }

    let existing: Vec<(String,)> = sqlx::query_as(
        "SELECT imdb_id FROM titles WHERE imdb_id IS NOT NULL AND imdb_id <> ''",
    )
    .fetch_all(&ctx.pool)
    .await?;
    let have: std::collections::HashSet<String> = existing.into_iter().map(|r| r.0).collect();

    let missing: Vec<&str> = OMDB_SEED
        .iter()
        .copied()
        .filter(|id| !have.contains(*id))
        .collect();
    info!(count = missing.len(), "ingesting titles from OMDb");

    for imdb_id in missing {
        match fetch_title(ctx, imdb_id).await {
            Ok(Some(parsed)) => {
                if let Err(e) = upsert_omdb_title(ctx, parsed).await {
                    warn!(%imdb_id, error = %e, "OMDb upsert failed");
                }
            }
            Ok(None) => debug!(%imdb_id, "OMDb had no record"),
            Err(e) => warn!(%imdb_id, error = %e, "OMDb lookup failed"),
        }
        throttle().await;
    }

    enrich_missing_imdb(ctx).await
}

pub async fn enrich_missing_imdb(ctx: &IngestContext) -> Result<()> {
    if ctx.config.omdb_key().is_empty() {
        return Ok(());
    }
    let rows: Vec<(uuid::Uuid, String)> = sqlx::query_as(
        r#"
        SELECT t.id, t.imdb_id
        FROM titles t
        LEFT JOIN ratings r ON r.title_id = t.id
        WHERE t.imdb_id IS NOT NULL
          AND t.imdb_id <> ''
          AND (r.imdb_rating IS NULL OR r.rt_score IS NULL)
        LIMIT 80
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    info!(count = rows.len(), "enriching IMDb / Rotten Tomatoes via OMDb");
    for (title_id, imdb_id) in rows {
        match fetch_title(ctx, &imdb_id).await {
            Ok(Some(parsed)) => {
                upsert_ratings(
                    ctx,
                    title_id,
                    None,
                    None,
                    parsed.imdb_rating,
                    parsed.imdb_votes,
                    None,
                    None,
                    parsed.rt_score,
                )
                .await?;
                let _ = reindex(ctx, title_id).await;
            }
            Ok(None) => debug!(%imdb_id, "omdb had no rating"),
            Err(e) => warn!(%imdb_id, error = %e, "omdb lookup failed"),
        }
        throttle().await;
    }
    Ok(())
}

struct ParsedOmdb {
    title: String,
    kind: String,
    year: Option<i32>,
    runtime: Option<i32>,
    plot: Option<String>,
    poster: Option<String>,
    imdb_id: String,
    genres: Vec<String>,
    imdb_rating: Option<f64>,
    imdb_votes: Option<i32>,
    rt_score: Option<i32>,
    rated: Option<String>,
}

async fn fetch_title(ctx: &IngestContext, imdb_id: &str) -> Result<Option<ParsedOmdb>> {
    let url = format!(
        "https://www.omdbapi.com/?i={imdb_id}&plot=full&apikey={}",
        ctx.config.omdb_key()
    );
    let parsed: OmdbResponse = ctx.http.get(url).send().await?.json().await?;
    if parsed.response.as_deref() == Some("False") {
        return Ok(None);
    }
    let Some(title) = parsed.title.filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    let imdb = parsed
        .imdb_id
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| imdb_id.to_string());
    let kind = match parsed.kind.as_deref().unwrap_or("movie") {
        "series" => "series",
        "episode" => return Ok(None),
        _ => "movie",
    };
    let poster = parsed
        .poster
        .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("N/A"));
    let plot = parsed.plot.filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("N/A"));
    Ok(Some(ParsedOmdb {
        title,
        kind: kind.into(),
        year: parse_year(parsed.year.as_deref()),
        runtime: parse_runtime(parsed.runtime.as_deref()),
        plot,
        poster,
        imdb_id: imdb,
        genres: parse_genres(parsed.genre.as_deref()),
        imdb_rating: parsed
            .imdb_rating
            .as_deref()
            .filter(|s| *s != "N/A")
            .and_then(|s| s.parse().ok()),
        imdb_votes: parsed.imdb_votes.as_deref().and_then(parse_votes),
        rt_score: parsed.ratings.as_deref().and_then(parse_rt),
        rated: parsed
            .rated
            .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("N/A")),
    }))
}

async fn upsert_omdb_title(ctx: &IngestContext, parsed: ParsedOmdb) -> Result<()> {
    let existing_kind: Option<(String,)> =
        sqlx::query_as("SELECT kind FROM titles WHERE imdb_id = $1")
            .bind(&parsed.imdb_id)
            .fetch_optional(&ctx.pool)
            .await?;
    if existing_kind.as_ref().map(|r| r.0.as_str()) == Some("anime") {
        return Ok(());
    }
    let id = upsert_title(
        ctx,
        &parsed.kind,
        &parsed.title,
        None,
        parsed.plot.as_deref(),
        parsed.plot.as_deref(),
        parsed.year,
        parsed.runtime,
        parsed.poster.as_deref(),
        None,
        None,
        Some(&parsed.imdb_id),
        None,
        None,
    )
    .await?;
    replace_genre_names(ctx, id, &parsed.genres).await?;
    apply_content_rating(ctx, id, parsed.rated).await?;
    upsert_ratings(
        ctx,
        id,
        None,
        None,
        parsed.imdb_rating,
        parsed.imdb_votes,
        None,
        None,
        parsed.rt_score,
    )
    .await?;
    reindex(ctx, id).await?;
    Ok(())
}

fn parse_year(raw: Option<&str>) -> Option<i32> {
    let raw = raw?;
    let digits: String = raw.chars().take(4).filter(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn parse_runtime(raw: Option<&str>) -> Option<i32> {
    let raw = raw?;
    let digits: String = raw.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn parse_genres(raw: Option<&str>) -> Vec<String> {
    raw.unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("N/A"))
        .collect()
}

fn parse_rt(ratings: &[OmdbSourceRating]) -> Option<i32> {
    ratings.iter().find_map(|r| {
        let source = r.source.as_deref().unwrap_or("");
        if !source.eq_ignore_ascii_case("Rotten Tomatoes") {
            return None;
        }
        r.value
            .as_deref()?
            .trim()
            .trim_end_matches('%')
            .parse()
            .ok()
    })
}

fn parse_votes(raw: &str) -> Option<i32> {
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_comma_votes() {
        assert_eq!(parse_votes("1,234,567"), Some(1_234_567));
        assert_eq!(parse_votes("N/A"), None);
    }

    #[test]
    fn parses_year_ranges() {
        assert_eq!(parse_year(Some("2011–2019")), Some(2011));
        assert_eq!(parse_year(Some("1999")), Some(1999));
    }
}
