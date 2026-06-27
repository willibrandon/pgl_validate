use super::algorithm::HashAlgorithm;

/// Number of 16-bit lanes in the LtHash accumulator.
pub(crate) const LANES: usize = 1024;
const LANE_BYTES: usize = 2;
const STATE_BYTES: usize = LANES * LANE_BYTES;

/// Core LtHash accumulator used before conversion to the PostgreSQL varlena type.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct LtHashCore {
    /// Accumulator lanes, each updated with wrapping addition.
    pub(crate) lanes: [u16; LANES],
}

impl Default for LtHashCore {
    fn default() -> Self {
        Self { lanes: [0; LANES] }
    }
}

/// Add one row digest to an LtHash accumulator.
pub(crate) fn add_row_digest(state: &mut LtHashCore, row_digest: &[u8]) {
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
pub(crate) fn combine(left: LtHashCore, right: LtHashCore) -> LtHashCore {
    let mut out = LtHashCore::default();
    for ((dst, l), r) in out.lanes.iter_mut().zip(left.lanes).zip(right.lanes) {
        *dst = l.wrapping_add(r);
    }
    out
}

/// Hash caller-sorted row digests into a cryptographic confirmation digest.
pub(crate) fn hash_digest_array(sorted_row_digests: &[&[u8]], algorithm: HashAlgorithm) -> Vec<u8> {
    let mut hasher = blake3::Hasher::new();
    for digest in sorted_row_digests {
        hasher.update(digest);
    }
    algorithm.finalize_blake3(hasher)
}

impl LtHashCore {
    /// Serialize the accumulator lanes in little-endian order.
    pub(crate) fn to_bytes(self) -> Vec<u8> {
        let mut out = Vec::with_capacity(STATE_BYTES);
        for lane in self.lanes {
            out.extend_from_slice(&lane.to_le_bytes());
        }
        out
    }

    /// Parse the canonical byte representation of an LtHash accumulator.
    pub(crate) fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
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
    pub(crate) fn to_hex(self) -> String {
        let bytes = self.to_bytes();
        let mut out = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            use core::fmt::Write;
            write!(&mut out, "{byte:02x}").expect("writing to String cannot fail");
        }
        out
    }

    /// Parse either the aggregate initial condition `0` or hexadecimal state text.
    pub(crate) fn parse_text(input: &str) -> Result<Self, String> {
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
    use proptest::prelude::*;

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
        let first = hash_digest_array(&[a.as_bytes(), b.as_bytes()], HashAlgorithm::Blake3_256);
        let second = hash_digest_array(&[b.as_bytes(), a.as_bytes()], HashAlgorithm::Blake3_256);
        assert_ne!(first, second);
    }

    fn digest_strategy() -> impl Strategy<Value = Vec<u8>> {
        prop::collection::vec(any::<u8>(), 0..128)
    }

    fn digest_vec_strategy() -> impl Strategy<Value = Vec<Vec<u8>>> {
        prop::collection::vec(digest_strategy(), 0..32)
    }

    fn lthash_reference(digests: &[Vec<u8>]) -> LtHashCore {
        let mut state = LtHashCore::default();
        for digest in digests {
            add_row_digest(&mut state, digest);
        }
        state
    }

    fn sorted_digest_reference(digests: &[Vec<u8>], algorithm: HashAlgorithm) -> Vec<u8> {
        let mut sorted = digests.to_vec();
        sorted.sort();

        let mut hasher = blake3::Hasher::new();
        for digest in &sorted {
            hasher.update(digest);
        }
        algorithm.finalize_blake3(hasher)
    }

    proptest! {
        #[test]
        fn lthash_is_commutative_for_any_generated_multiset(mut digests in digest_vec_strategy()) {
            let forward = lthash_reference(&digests);
            digests.reverse();
            let reverse = lthash_reference(&digests);

            prop_assert_eq!(forward, reverse);
        }

        #[test]
        fn lthash_combine_matches_partitioned_reference(
            left in digest_vec_strategy(),
            right in digest_vec_strategy()
        ) {
            let mut all = left.clone();
            all.extend(right.clone());

            prop_assert_eq!(
                combine(lthash_reference(&left), lthash_reference(&right)),
                lthash_reference(&all)
            );
        }

        #[test]
        fn lthash_changes_for_single_added_non_empty_digest(
            mut digests in digest_vec_strategy(),
            extra in prop::collection::vec(any::<u8>(), 1..128)
        ) {
            let before = lthash_reference(&digests);
            digests.push(extra);
            let after = lthash_reference(&digests);

            prop_assert_ne!(before, after);
        }

        #[test]
        fn sorted_confirmation_matches_independent_sorted_reference(
            digests in digest_vec_strategy(),
            wide in any::<bool>()
        ) {
            let algorithm = if wide {
                HashAlgorithm::Blake3_512
            } else {
                HashAlgorithm::Blake3_256
            };

            let mut sorted = digests.clone();
            sorted.sort();
            let refs = sorted.iter().map(Vec::as_slice).collect::<Vec<_>>();

            prop_assert_eq!(
                hash_digest_array(&refs, algorithm),
                sorted_digest_reference(&digests, algorithm)
            );
        }
    }
}
