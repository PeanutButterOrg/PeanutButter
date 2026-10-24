//! Turn Jackett `.torrent` download links into magnets before results reach
//! the apps.
//!
//! Some indexers give Jackett no magnet, only a link like
//! `http://jackett:9117/dl/<indexer>/?jackett_apikey=…`. The apps' torrent
//! engines only take magnets, so those results failed with "unsupported URL
//! protocol" (and the link handed every app the Jackett API key). Jackett
//! answers such a link with either a redirect to a magnet or the .torrent
//! file itself; both become a plain `magnet:?xt=urn:btih:…` here.

use std::time::Duration;

use futures::stream::{self, StreamExt};
use tracing::warn;

use crate::graphql::types::StreamSource;

const PER_LINK_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_TORRENT_BYTES: usize = 8 * 1024 * 1024;
const PARALLEL: usize = 6;

fn is_link(s: &str) -> bool {
    let l = s.trim().to_ascii_lowercase();
    l.starts_with("http://") || l.starts_with("https://")
}

/// Replace every http(s) link with a magnet; links that can't be resolved
/// are dropped (they would only fail on the device).
pub async fn resolve_all(sources: Vec<StreamSource>) -> Vec<StreamSource> {
    if !sources.iter().any(|s| is_link(&s.magnet)) {
        return sources;
    }
    let http = match reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(PER_LINK_TIMEOUT)
        .build()
    {
        Ok(c) => c,
        Err(_) => return sources.into_iter().filter(|s| !is_link(&s.magnet)).collect(),
    };
    let resolved: Vec<(usize, Option<StreamSource>)> = stream::iter(sources.into_iter().enumerate())
        .map(|(i, mut src)| {
            let http = http.clone();
            async move {
                if !is_link(&src.magnet) {
                    return (i, Some(src));
                }
                match resolve(&http, &src.magnet, &src.title).await {
                    Some(magnet) => {
                        src.magnet = magnet;
                        (i, Some(src))
                    }
                    None => {
                        warn!(title = %src.title, "dropped a torrent link that didn't resolve to a magnet");
                        (i, None)
                    }
                }
            }
        })
        .buffer_unordered(PARALLEL)
        .collect()
        .await;
    let mut ordered = resolved;
    ordered.sort_by_key(|(i, _)| *i);
    ordered.into_iter().filter_map(|(_, s)| s).collect()
}

async fn resolve(http: &reqwest::Client, url: &str, title: &str) -> Option<String> {
    let mut next = url.to_string();
    for _ in 0..4 {
        let res = http.get(&next).send().await.ok()?;
        if res.status().is_redirection() {
            let loc = res.headers().get(reqwest::header::LOCATION)?.to_str().ok()?.trim().to_string();
            if loc.to_ascii_lowercase().starts_with("magnet:") {
                return Some(loc);
            }
            next = reqwest::Url::parse(&next).ok()?.join(&loc).ok()?.to_string();
            continue;
        }
        if !res.status().is_success() {
            return None;
        }
        if res.content_length().is_some_and(|n| n as usize > MAX_TORRENT_BYTES) {
            return None;
        }
        let body = res.bytes().await.ok()?;
        if body.len() > MAX_TORRENT_BYTES {
            return None;
        }
        // Some indexers answer with the magnet as text.
        let head = String::from_utf8_lossy(&body[..body.len().min(512)]);
        if head.trim_start().to_ascii_lowercase().starts_with("magnet:") {
            return Some(head.trim().to_string());
        }
        return magnet_from_torrent(&body, title);
    }
    None
}

/// `magnet:?xt=urn:btih:<sha1 of info>&dn=…&tr=…` from a .torrent file.
pub fn magnet_from_torrent(data: &[u8], fallback_name: &str) -> Option<String> {
    let top = parse(data, 0)?;
    let Value::Dict(entries, _, _) = top.0 else {
        return None;
    };
    let mut info_span = None;
    let mut name = None;
    let mut trackers: Vec<String> = Vec::new();
    for (key, value) in &entries {
        match key.as_slice() {
            b"info" => {
                if let Value::Dict(info, start, end) = value {
                    info_span = Some((*start, *end));
                    for (k, v) in info {
                        if k.as_slice() == b"name" {
                            if let Value::Bytes(n) = v {
                                name = String::from_utf8(n.clone()).ok();
                            }
                        }
                    }
                }
            }
            b"announce" => {
                if let Value::Bytes(b) = value {
                    if let Ok(s) = String::from_utf8(b.clone()) {
                        trackers.push(s);
                    }
                }
            }
            b"announce-list" => {
                if let Value::List(tiers) = value {
                    for tier in tiers {
                        if let Value::List(urls) = tier {
                            for u in urls {
                                if let Value::Bytes(b) = u {
                                    if let Ok(s) = String::from_utf8(b.clone()) {
                                        trackers.push(s);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    let (start, end) = info_span?;
    let digest = ring::digest::digest(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, &data[start..end]);
    let hash = hex::encode(digest.as_ref());
    let dn = name.unwrap_or_else(|| fallback_name.to_string());
    let mut magnet = format!("magnet:?xt=urn:btih:{hash}&dn={}", encode(&dn));
    let mut seen = std::collections::HashSet::new();
    for tr in trackers.into_iter().filter(|t| seen.insert(t.clone())).take(20) {
        magnet.push_str("&tr=");
        magnet.push_str(&encode(&tr));
    }
    Some(magnet)
}

fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Just enough bencode to find the `info` dictionary's exact byte span.
enum Value {
    Int,
    Bytes(Vec<u8>),
    List(Vec<Value>),
    /// Entries plus the dict's start and end offsets in the input.
    Dict(Vec<(Vec<u8>, Value)>, usize, usize),
}

fn parse(d: &[u8], i: usize) -> Option<(Value, usize)> {
    match *d.get(i)? {
        b'i' => {
            let end = i + d[i..].iter().position(|&c| c == b'e')?;
            Some((Value::Int, end + 1))
        }
        b'l' => {
            let mut items = Vec::new();
            let mut j = i + 1;
            while *d.get(j)? != b'e' {
                let (v, n) = parse(d, j)?;
                items.push(v);
                j = n;
            }
            Some((Value::List(items), j + 1))
        }
        b'd' => {
            let mut entries = Vec::new();
            let mut j = i + 1;
            while *d.get(j)? != b'e' {
                let (k, n) = parse(d, j)?;
                let Value::Bytes(key) = k else { return None };
                let (v, m) = parse(d, n)?;
                entries.push((key, v));
                j = m;
            }
            Some((Value::Dict(entries, i, j + 1), j + 1))
        }
        b'0'..=b'9' => {
            let colon = i + d[i..].iter().position(|&c| c == b':')?;
            let len: usize = std::str::from_utf8(&d[i..colon]).ok()?.parse().ok()?;
            let start = colon + 1;
            let end = start.checked_add(len)?;
            Some((Value::Bytes(d.get(start..end)?.to_vec()), end))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::magnet_from_torrent;

    #[test]
    fn builds_magnet_from_torrent_file() {
        // d8:announce19:udp://t.example:1/a4:infod6:lengthi10e4:name4:file12:piece lengthi16384e6:pieces0:ee
        let info = b"d6:lengthi10e4:name4:file12:piece lengthi16384e6:pieces0:e";
        let mut torrent = b"d8:announce19:udp://t.example:1/a4:info".to_vec();
        torrent.extend_from_slice(info);
        torrent.push(b'e');
        let m = magnet_from_torrent(&torrent, "fallback").expect("magnet");
        let want = hex::encode(
            ring::digest::digest(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, info).as_ref(),
        );
        assert!(m.starts_with(&format!("magnet:?xt=urn:btih:{want}&dn=file")));
        assert!(m.contains("&tr=udp%3A%2F%2Ft.example%3A1%2Fa"));
    }

    #[test]
    fn rejects_garbage() {
        assert!(magnet_from_torrent(b"<html>not a torrent</html>", "x").is_none());
        assert!(magnet_from_torrent(b"d4:infoi1ee", "x").is_none());
    }
}
