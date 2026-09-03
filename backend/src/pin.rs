//! Short pairing codes for TVs: six digits, typed on a remote.

use uuid::Uuid;

pub fn is_pairing_code(value: &str) -> bool {
    let digits = digits_only(value);
    digits.len() == 6
}

pub fn digits_only(value: &str) -> String {
    value.chars().filter(|c| c.is_ascii_digit()).collect()
}

pub fn normalize_code(value: &str) -> String {
    let digits = digits_only(value);
    if digits.len() == 6 {
        digits
    } else {
        value.trim().to_string()
    }
}

pub fn format_code(value: &str) -> String {
    let digits = digits_only(value);
    if digits.len() == 6 {
        format!("{} {}", &digits[..3], &digits[3..])
    } else {
        value.trim().to_string()
    }
}

pub fn codes_equal(a: &str, b: &str) -> bool {
    let left = normalize_code(a);
    let right = normalize_code(b);
    if left.len() != right.len() || left.is_empty() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

pub fn random_code() -> String {
    let uuid = Uuid::new_v4();
    let b = uuid.as_bytes();
    let n = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) % 900_000 + 100_000;
    format!("{n:06}")
}
