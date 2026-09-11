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
pub fn is_blocked_content_rating(rating: &str) -> bool {
    let r = rating.trim().to_ascii_uppercase();
    matches!(r.as_str(), "XXX" | "AO") || r.contains("XXX")
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
