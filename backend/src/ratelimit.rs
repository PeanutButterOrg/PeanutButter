//! Per-IP failure counters for credential checks (device keys, pairing codes,
//! console password). Successful requests are never counted.

use moka::sync::Cache;
use std::net::IpAddr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// Window over which failures are counted (from the first failure).
const WINDOW: Duration = Duration::from_secs(15 * 60);

#[derive(Clone, Copy)]
pub enum Bucket {
    /// API key / legacy code on normal requests.
    Auth,
    /// POST /pair and the console login: guessable secrets, tighter limit.
    Credential,
}

impl Bucket {
    fn limit(self) -> u32 {
        match self {
            Bucket::Auth => 30,
            Bucket::Credential => 10,
        }
    }
}

fn counters(bucket: Bucket) -> &'static Cache<IpAddr, Arc<AtomicU32>> {
    static AUTH: OnceLock<Cache<IpAddr, Arc<AtomicU32>>> = OnceLock::new();
    static CRED: OnceLock<Cache<IpAddr, Arc<AtomicU32>>> = OnceLock::new();
    let cell = match bucket {
        Bucket::Auth => &AUTH,
        Bucket::Credential => &CRED,
    };
    cell.get_or_init(|| {
        Cache::builder()
            .max_capacity(50_000)
            .time_to_live(WINDOW)
            .build()
    })
}

pub fn is_blocked(bucket: Bucket, ip: IpAddr) -> bool {
    counters(bucket)
        .get(&ip)
        .is_some_and(|n| n.load(Ordering::Relaxed) >= bucket.limit())
}

pub fn record_failure(bucket: Bucket, ip: IpAddr) {
    counters(bucket)
        .get_with(ip, || Arc::new(AtomicU32::new(0)))
        .fetch_add(1, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_after_limit() {
        let ip: IpAddr = "10.9.8.7".parse().unwrap();
        for _ in 0..Bucket::Credential.limit() {
            assert!(!is_blocked(Bucket::Credential, ip));
            record_failure(Bucket::Credential, ip);
        }
        assert!(is_blocked(Bucket::Credential, ip));
        assert!(!is_blocked(Bucket::Auth, ip));
    }
}
