/// Number of 16-bit lanes in the LtHash accumulator.
pub const LANES: usize = 1024;
const LANE_BYTES: usize = 2;
const STATE_BYTES: usize = LANES * LANE_BYTES;

/// Core LtHash accumulator used before conversion to the PostgreSQL varlena type.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LtHashCore {
    /// Accumulator lanes, each updated with wrapping addition.
    pub lanes: [u16; LANES],
}

impl Default for LtHashCore {
    fn default() -> Self {
        Self { lanes: [0; LANES] }
    }
}

/// Add one row digest to an LtHash accumulator.
pub fn add_row_digest(state: &mut LtHashCore, row_digest: &[u8]) {
    if row_digest.is_empty() {
        return;
    }

    let mut reader = blake3::Hasher::new().update(row_digest).finalize_xof();
    let mut expanded = [0u8; STATE_BYTES];
    reader.fill(&mut expanded);

    for (lane, bytes) in state
        .lanes
        .iter_mut()
        .zip(expanded.chunks_exact(LANE_BYTES))
    {
        let addend = u16::from_le_bytes([bytes[0], bytes[1]]);
        *lane = lane.wrapping_add(addend);
    }
}

/// Combine two LtHash states with lane-wise wrapping addition.
pub fn combine(left: LtHashCore, right: LtHashCore) -> LtHashCore {
    let mut out = LtHashCore::default();
    for ((dst, l), r) in out.lanes.iter_mut().zip(left.lanes).zip(right.lanes) {
        *dst = l.wrapping_add(r);
    }
    out
}

/// Hash caller-sorted row digests into a cryptographic confirmation digest.
pub fn hash_digest_array(sorted_row_digests: &[&[u8]]) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new();
    for digest in sorted_row_digests {
        hasher.update(digest);
    }
    *hasher.finalize().as_bytes()
}

impl LtHashCore {
    /// Serialize the accumulator lanes in little-endian order.
    pub fn to_bytes(self) -> Vec<u8> {
        let mut out = Vec::with_capacity(STATE_BYTES);
        for lane in self.lanes {
            out.extend_from_slice(&lane.to_le_bytes());
        }
        out
    }

    /// Parse the canonical byte representation of an LtHash accumulator.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() != STATE_BYTES {
            return Err(format!(
                "lthash_state must be {STATE_BYTES} bytes, got {}",
                bytes.len()
            ));
        }

        let mut lanes = [0u16; LANES];
        for (lane, bytes) in lanes.iter_mut().zip(bytes.chunks_exact(LANE_BYTES)) {
            *lane = u16::from_le_bytes([bytes[0], bytes[1]]);
        }
        Ok(Self { lanes })
    }

    /// Render the canonical byte representation as lowercase hexadecimal.
    pub fn to_hex(self) -> String {
        let bytes = self.to_bytes();
        let mut out = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            use core::fmt::Write;
            write!(&mut out, "{byte:02x}").expect("writing to String cannot fail");
        }
        out
    }

    /// Parse either the aggregate initial condition `0` or hexadecimal state text.
    pub fn parse_text(input: &str) -> Result<Self, String> {
        if input == "0" {
            return Ok(Self::default());
        }

        let input = input.strip_prefix("\\x").unwrap_or(input);
        if input.len() != STATE_BYTES * 2 {
            return Err(format!(
                "lthash_state hex must have {} characters, got {}",
                STATE_BYTES * 2,
                input.len()
            ));
        }

        let mut bytes = vec![0u8; STATE_BYTES];
        for (idx, byte) in bytes.iter_mut().enumerate() {
            let start = idx * 2;
            *byte = u8::from_str_radix(&input[start..start + 2], 16)
                .map_err(|err| format!("invalid lthash_state hex at byte {idx}: {err}"))?;
        }
        Self::from_bytes(&bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lthash_is_order_independent() {
        let a = blake3::hash(b"a");
        let b = blake3::hash(b"b");

        let mut left = LtHashCore::default();
        add_row_digest(&mut left, a.as_bytes());
        add_row_digest(&mut left, b.as_bytes());

        let mut right = LtHashCore::default();
        add_row_digest(&mut right, b.as_bytes());
        add_row_digest(&mut right, a.as_bytes());

        assert_eq!(left, right);
    }

    #[test]
    fn lthash_is_duplicate_sensitive() {
        let a = blake3::hash(b"a");

        let mut once = LtHashCore::default();
        add_row_digest(&mut once, a.as_bytes());

        let mut twice = LtHashCore::default();
        add_row_digest(&mut twice, a.as_bytes());
        add_row_digest(&mut twice, a.as_bytes());

        assert_ne!(once, twice);
    }

    #[test]
    fn combine_matches_incremental_add() {
        let a = blake3::hash(b"a");
        let b = blake3::hash(b"b");

        let mut left = LtHashCore::default();
        add_row_digest(&mut left, a.as_bytes());

        let mut right = LtHashCore::default();
        add_row_digest(&mut right, b.as_bytes());

        let mut direct = LtHashCore::default();
        add_row_digest(&mut direct, a.as_bytes());
        add_row_digest(&mut direct, b.as_bytes());

        assert_eq!(combine(left, right), direct);
    }

    #[test]
    fn state_bytes_round_trip() {
        let mut state = LtHashCore::default();
        add_row_digest(&mut state, blake3::hash(b"row").as_bytes());
        assert_eq!(LtHashCore::from_bytes(&state.to_bytes()).unwrap(), state);
        assert_eq!(LtHashCore::parse_text(&state.to_hex()).unwrap(), state);
        assert_eq!(LtHashCore::parse_text("0").unwrap(), LtHashCore::default());
    }

    #[test]
    fn hash_digest_array_uses_caller_order() {
        let a = blake3::hash(b"a");
        let b = blake3::hash(b"b");
        let first = hash_digest_array(&[a.as_bytes(), b.as_bytes()]);
        let second = hash_digest_array(&[b.as_bytes(), a.as_bytes()]);
        assert_ne!(first, second);
    }
}
