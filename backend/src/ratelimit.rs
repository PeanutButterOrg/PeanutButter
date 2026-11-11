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
    /// The console login.
    Credential,
    /// POST /pair: six-digit codes. Also capped server-wide (see
    /// [PAIRING_GLOBAL_LIMIT]), since an attacker can spread guesses over
    /// many addresses.
    Pairing,
}

/// Wrong pairing codes per window from all addresses together. With 900,000
/// codes this keeps a 15-minute code's odds of being guessed under 0.03%.
/// Too many attempts pause pairing for everyone until the window passes.
const PAIRING_GLOBAL_LIMIT: u32 = 200;

impl Bucket {
    fn limit(self) -> u32 {
        match self {
            Bucket::Auth => 30,
            Bucket::Credential | Bucket::Pairing => 10,
        }
    }
}

fn counters(bucket: Bucket) -> &'static Cache<IpAddr, Arc<AtomicU32>> {
    static AUTH: OnceLock<Cache<IpAddr, Arc<AtomicU32>>> = OnceLock::new();
    static CRED: OnceLock<Cache<IpAddr, Arc<AtomicU32>>> = OnceLock::new();
    static PAIR: OnceLock<Cache<IpAddr, Arc<AtomicU32>>> = OnceLock::new();
    let cell = match bucket {
        Bucket::Auth => &AUTH,
        Bucket::Credential => &CRED,
        Bucket::Pairing => &PAIR,
    };
    cell.get_or_init(|| {
        Cache::builder()
            .max_capacity(50_000)
            .time_to_live(WINDOW)
            .build()
    })
}

/// One counter per client: an IPv6 host usually owns a whole /64, so each
/// address in it must not get its own allowance. IPv4-mapped IPv6 counts as
/// the IPv4 address.
fn client_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => ip,
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => {
                let s = v6.segments();
                IpAddr::V6(std::net::Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0))
            }
        },
    }
}

/// Server-wide pairing failures, under one fixed key.
fn pairing_total() -> Arc<AtomicU32> {
    static TOTAL: OnceLock<Cache<u8, Arc<AtomicU32>>> = OnceLock::new();
    TOTAL
        .get_or_init(|| Cache::builder().max_capacity(1).time_to_live(WINDOW).build())
        .get_with(0, || Arc::new(AtomicU32::new(0)))
}

pub fn is_blocked(bucket: Bucket, ip: IpAddr) -> bool {
    if matches!(bucket, Bucket::Pairing)
        && pairing_total().load(Ordering::Relaxed) >= PAIRING_GLOBAL_LIMIT
    {
        return true;
    }
    counters(bucket)
        .get(&client_key(ip))
        .is_some_and(|n| n.load(Ordering::Relaxed) >= bucket.limit())
}

pub fn record_failure(bucket: Bucket, ip: IpAddr) {
    if matches!(bucket, Bucket::Pairing) {
        pairing_total().fetch_add(1, Ordering::Relaxed);
    }
    counters(bucket)
        .get_with(client_key(ip), || Arc::new(AtomicU32::new(0)))
        .fetch_add(1, Ordering::Relaxed);
}

/// A credential check in progress: it already counts as a failure, so
/// concurrent requests can't all pass a limit check before any of them is
/// recorded. Call [Attempt::succeeded] when the credential was right;
/// dropping it otherwise keeps the failure.
#[must_use]
pub struct Attempt {
    counted: Vec<Arc<AtomicU32>>,
}

impl Attempt {
    /// The credential was right: give the reserved slots back.
    pub fn succeeded(self) {
        for c in &self.counted {
            c.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

/// Take one counted attempt before checking a credential, or None when the
/// limit is reached. The add and the limit check are one atomic step, so
/// parallel requests can't exceed the limit.
pub fn reserve(bucket: Bucket, ip: IpAddr) -> Option<Attempt> {
    fn take(counter: Arc<AtomicU32>, limit: u32, counted: &mut Vec<Arc<AtomicU32>>) -> bool {
        if counter.fetch_add(1, Ordering::Relaxed) >= limit {
            counter.fetch_sub(1, Ordering::Relaxed);
            return false;
        }
        counted.push(counter);
        true
    }
    let mut counted = Vec::with_capacity(2);
    let ok = (!matches!(bucket, Bucket::Pairing)
        || take(pairing_total(), PAIRING_GLOBAL_LIMIT, &mut counted))
        && take(
            counters(bucket).get_with(client_key(ip), || Arc::new(AtomicU32::new(0))),
            bucket.limit(),
            &mut counted,
        );
    if ok {
        Some(Attempt { counted })
    } else {
        // Undo whatever was taken before the limit was hit.
        Attempt { counted }.succeeded();
        None
    }
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

    #[test]
    fn ipv6_neighbours_share_one_allowance() {
        let a: IpAddr = "2001:db8:1:2::1".parse().unwrap();
        let b: IpAddr = "2001:db8:1:2:ffff::9".parse().unwrap();
        let other: IpAddr = "2001:db8:1:3::1".parse().unwrap();
        for _ in 0..Bucket::Credential.limit() {
            record_failure(Bucket::Credential, a);
        }
        assert!(is_blocked(Bucket::Credential, b));
        assert!(!is_blocked(Bucket::Credential, other));
    }

    #[test]
    fn mapped_ipv4_counts_as_ipv4() {
        let v4: IpAddr = "10.1.2.3".parse().unwrap();
        let mapped: IpAddr = "::ffff:10.1.2.3".parse().unwrap();
        assert_eq!(client_key(mapped), v4);
    }

    #[test]
    fn pairing_is_capped_across_all_addresses() {
        for i in 0..PAIRING_GLOBAL_LIMIT {
            let ip = IpAddr::V4(std::net::Ipv4Addr::from(0x0b00_0000 + i));
            record_failure(Bucket::Pairing, ip);
        }
        let fresh: IpAddr = "192.0.2.77".parse().unwrap();
        assert!(is_blocked(Bucket::Pairing, fresh));
        // The console login has its own, per-address limit.
        assert!(!is_blocked(Bucket::Credential, fresh));
    }

    #[test]
    fn parallel_attempts_cannot_exceed_the_limit() {
        let ip: IpAddr = "198.51.100.20".parse().unwrap();
        // Many requests in flight at once, none finished yet.
        let held: Vec<_> = (0..50).filter_map(|_| reserve(Bucket::Credential, ip)).collect();
        assert_eq!(held.len() as u32, Bucket::Credential.limit());
        assert!(is_blocked(Bucket::Credential, ip));
        drop(held); // all wrong: they stay counted
        assert!(reserve(Bucket::Credential, ip).is_none());
    }

    #[test]
    fn a_right_credential_gives_its_slot_back() {
        let ip: IpAddr = "198.51.100.21".parse().unwrap();
        for _ in 0..100 {
            reserve(Bucket::Credential, ip).expect("slot").succeeded();
        }
        assert!(!is_blocked(Bucket::Credential, ip));
    }
}
