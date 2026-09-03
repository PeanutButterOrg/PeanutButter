use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

pub type Result<T> = std::result::Result<T, AppError>;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Server configuration problem. Check Settings.")]
    Config(String),

    #[error("Couldn’t read or save data. Try again.")]
    Database(#[from] sqlx::Error),

    #[error("Search is unavailable right now. Try again in a moment.")]
    Search(String),

    #[error("{}", provider_user_message(.0))]
    Provider(String),

    #[error("Couldn’t reach a remote service. Try again.")]
    Http(#[from] reqwest::Error),

    #[error("A file on the server couldn’t be read.")]
    Io(#[from] std::io::Error),

    #[error("That item wasn’t found.")]
    NotFound(String),

    #[error("This device isn’t paired. Open the pairing screen and type a code from the server console.")]
    Unauthorized(String),

    #[error("Access denied. Check the server token in Settings.")]
    Forbidden(String),

    #[error("{0}")]
    BadRequest(String),

    #[error("Something went wrong on the server. Try again.")]
    Internal(String),

    #[error("{0}")]
    Message(String),
}

fn provider_user_message(inner: &str) -> String {
    let t = inner.to_ascii_lowercase();
    if t.contains("subtitle") {
        if t.contains("too large") {
            return "That subtitle file is too large to load.".into();
        }
        if t.contains("zip") {
            return "Zipped subtitles aren’t supported.".into();
        }
        if t.contains("srt") {
            return "That subtitle file isn’t a valid SRT.".into();
        }
        return "Couldn’t load subtitles. Try again.".into();
    }
    "Couldn’t fetch metadata. Check TMDB and OMDb keys in Settings.".into()
}

impl AppError {
    pub fn status(&self) -> StatusCode {
        match self {
            AppError::NotFound(_) => StatusCode::NOT_FOUND,
            AppError::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            AppError::Forbidden(_) => StatusCode::FORBIDDEN,
            AppError::BadRequest(_) | AppError::Config(_) | AppError::Message(_) => StatusCode::BAD_REQUEST,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        tracing::error!(error = ?self, "request failed");
        let body = serde_json::json!({
            "error": self.to_string(),
        });
        (self.status(), axum::Json(body)).into_response()
    }
}

impl From<meilisearch_sdk::errors::Error> for AppError {
    fn from(value: meilisearch_sdk::errors::Error) -> Self {
        AppError::Search(value.to_string())
    }
}
