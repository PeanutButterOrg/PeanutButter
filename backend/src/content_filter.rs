//! Hard block for adult / pornographic catalog content.

/// Genre names that must never appear in the UI or stay attached to titles.
pub fn is_blocked_genre(name: &str) -> bool {
    let n = name.trim().to_ascii_lowercase();
    matches!(
        n.as_str(),
        "sex"
            | "adult"
            | "erotica"
            | "erotic"
            | "hentai"
            | "porn"
            | "pornographic"
            | "pornography"
            | "xxx"
            | "softcore"
            | "hardcore"
            | "adult animation"
            | "adults only"
    ) || n.contains("hentai")
        || n.contains("porn")
        || n == "x"
}

/// Content ratings that indicate explicit adult material (not general R / R18+).
/// NC-17 is the US rating sexually explicit films get; R and TV-MA stay.
pub fn is_blocked_content_rating(rating: &str) -> bool {
    let r = rating.trim().to_ascii_uppercase();
    matches!(r.as_str(), "XXX" | "AO" | "NC-17" | "NC17") || r.contains("XXX")
}

/// TMDB keywords that mark porn, softcore and erotic films. TMDB has no
/// erotic genre and only flags outright porn as `adult`, so Korean erotic
/// films and the like reach trending with `adult: false`; their keywords
/// give them away. "erotic thriller" is deliberately absent: it tags
/// mainstream films (Basic Instinct, Gone Girl).
pub fn is_blocked_keyword(name: &str) -> bool {
    let n = name.trim().to_ascii_lowercase();
    matches!(
        n.as_str(),
        "erotic movie"
            | "erotic film"
            | "erotica"
            | "erotic"
            | "softcore"
            | "soft core"
            | "sexploitation"
            | "pink film"
            | "pinku eiga"
            | "sex film"
            | "adult film"
            | "adult movie"
            | "adult video"
            | "xxx"
            | "hardcore"
            | "hardcore sex"
            | "unsimulated sex"
            | "explicit sex"
    ) || n.contains("porn")
        || n.contains("hentai")
        || n.contains("softcore")
}

/// True when a YYYY-MM-DD (or YYYY-MM) date is strictly after today (UTC).
pub fn is_unreleased_date(raw: &str) -> bool {
    let raw = raw.trim();
    if raw.len() < 10 {
        return false;
    }
    let Ok(date) = chrono::NaiveDate::parse_from_str(&raw[..10], "%Y-%m-%d") else {
        return false;
    };
    date > chrono::Utc::now().date_naive()
}

/// SQL `lower(g.name)` values for blocked genres (for EXISTS filters).
pub const BLOCKED_GENRE_SQL_LIST: &str = "'sex','adult','erotica','erotic','hentai','porn','pornographic','pornography','xxx','softcore','hardcore','adult animation','adults only','x'";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_erotic_keywords() {
        for k in ["erotic movie", "Softcore", " sexploitation ", "pink film", "softcore porn", "pornography", "hentai"] {
            assert!(is_blocked_keyword(k), "{k}");
        }
    }

    #[test]
    fn keeps_mainstream_keywords() {
        for k in ["erotic thriller", "sex scene", "nudity", "drug addiction", "sex comedy", "romance", "seduction"] {
            assert!(!is_blocked_keyword(k), "{k}");
        }
    }

    #[test]
    fn blocks_explicit_ratings_only() {
        for r in ["NC-17", "nc-17", "XXX", "AO"] {
            assert!(is_blocked_content_rating(r), "{r}");
        }
        for r in ["R", "TV-MA", "18", "R18+", "PG-13", ""] {
            assert!(!is_blocked_content_rating(r), "{r}");
        }
    }
}
