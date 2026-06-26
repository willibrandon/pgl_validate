/// Supported row and set digest algorithms.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HashAlgorithm {
    /// BLAKE3 with a 256-bit output.
    Blake3_256,
    /// BLAKE3 XOF with a 512-bit output.
    Blake3_512,
}

impl HashAlgorithm {
    /// Parse a `pgl_validate.hash_algorithm` value.
    pub(crate) fn parse(name: &str) -> Result<Self, String> {
        match name {
            "blake3_256" => Ok(Self::Blake3_256),
            "blake3_512" => Ok(Self::Blake3_512),
            _ => Err(format!(
                "hash_algorithm {name} is not implemented; supported values are blake3_256, blake3_512"
            )),
        }
    }

    /// Return the digest output width in bytes.
    pub(crate) fn output_bytes(self) -> usize {
        match self {
            Self::Blake3_256 => 32,
            Self::Blake3_512 => 64,
        }
    }

    /// Finalize a BLAKE3 hasher at this algorithm's output width.
    pub(crate) fn finalize_blake3(self, hasher: blake3::Hasher) -> Vec<u8> {
        match self {
            Self::Blake3_256 => hasher.finalize().as_bytes().to_vec(),
            Self::Blake3_512 => {
                let mut out = vec![0; self.output_bytes()];
                hasher.finalize_xof().fill(&mut out);
                out
            }
        }
    }
}
