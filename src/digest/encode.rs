use core::ffi::CStr;
use pgrx::prelude::*;

/// Encoding selected by the coordinator for one row_digest column position.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum EncodingMode {
    /// Use the type's binary send function.
    Send = 1,
    /// Use the type's text output function.
    Text = 2,
}

impl TryFrom<i32> for EncodingMode {
    type Error = String;

    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Send),
            2 => Ok(Self::Text),
            _ => Err(format!("unknown pgl_validate encoding mode {value}")),
        }
    }
}

/// Add a NULL-aware length-delimited value frame to a row digest hasher.
pub fn frame_value(hasher: &mut blake3::Hasher, value: Option<&[u8]>) {
    match value {
        None => {
            hasher.update(&[0x00]);
        }
        Some(bytes) => {
            hasher.update(&[0x01]);
            hasher.update(&(bytes.len() as u32).to_le_bytes());
            hasher.update(bytes);
        }
    }
}

/// Encode a PostgreSQL datum according to the selected digest mode.
///
/// # Safety
///
/// `datum` must be a valid non-null datum for `type_oid` in the current
/// PostgreSQL memory context.
pub unsafe fn encode_datum(
    type_oid: pg_sys::Oid,
    datum: pg_sys::Datum,
    mode: EncodingMode,
) -> Vec<u8> {
    match mode {
        EncodingMode::Send => unsafe { encode_send(type_oid, datum) },
        EncodingMode::Text => unsafe { encode_text(type_oid, datum) },
    }
}

unsafe fn encode_send(type_oid: pg_sys::Oid, datum: pg_sys::Datum) -> Vec<u8> {
    let mut send_oid = pg_sys::InvalidOid;
    let mut is_varlena = false;
    unsafe {
        pg_sys::getTypeBinaryOutputInfo(type_oid, &mut send_oid, &mut is_varlena);
    }
    if send_oid == pg_sys::InvalidOid {
        pgrx::error!("type oid {type_oid} has no binary send function");
    }

    let bytea = unsafe { pg_sys::OidSendFunctionCall(send_oid, datum) };
    if bytea.is_null() {
        pgrx::error!("binary send function for type oid {type_oid} returned NULL");
    }
    unsafe { pgrx::varlena_to_byte_slice(bytea.cast()).to_vec() }
}

unsafe fn encode_text(type_oid: pg_sys::Oid, datum: pg_sys::Datum) -> Vec<u8> {
    let mut output_oid = pg_sys::InvalidOid;
    let mut is_varlena = false;
    unsafe {
        pg_sys::getTypeOutputInfo(type_oid, &mut output_oid, &mut is_varlena);
    }
    if output_oid == pg_sys::InvalidOid {
        pgrx::error!("type oid {type_oid} has no text output function");
    }

    let cstr = unsafe { pg_sys::OidOutputFunctionCall(output_oid, datum) };
    if cstr.is_null() {
        pgrx::error!("text output function for type oid {type_oid} returned NULL");
    }
    unsafe { CStr::from_ptr(cstr) }.to_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_distinguishes_null_empty_and_bytes() {
        let mut null_hasher = blake3::Hasher::new();
        frame_value(&mut null_hasher, None);

        let mut empty_hasher = blake3::Hasher::new();
        frame_value(&mut empty_hasher, Some(&[]));

        let mut bytes_hasher = blake3::Hasher::new();
        frame_value(&mut bytes_hasher, Some(b"x"));

        assert_ne!(null_hasher.finalize(), empty_hasher.finalize());
        assert_ne!(empty_hasher.finalize(), bytes_hasher.finalize());
    }

    #[test]
    fn encoding_modes_are_explicit() {
        assert_eq!(EncodingMode::try_from(1).unwrap(), EncodingMode::Send);
        assert_eq!(EncodingMode::try_from(2).unwrap(), EncodingMode::Text);
        assert!(EncodingMode::try_from(0).is_err());
    }
}
