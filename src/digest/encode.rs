use core::ffi::CStr;
use pgrx::prelude::*;
use std::ffi::CString;

/// Encoding selected by the coordinator for one row_digest column position.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum EncodingMode {
    /// Use the type's binary send function.
    Send = 1,
    /// Use the type's text output function.
    Text = 2,
    /// Convert `json` through `jsonb` before using jsonb binary send.
    JsonbNormalize = 3,
}

impl TryFrom<i32> for EncodingMode {
    type Error = String;

    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Send),
            2 => Ok(Self::Text),
            3 => Ok(Self::JsonbNormalize),
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
    let datum = unsafe { normalize_float_datum(type_oid, datum) };
    match mode {
        EncodingMode::Send => unsafe { encode_send(type_oid, datum) },
        EncodingMode::Text => unsafe { encode_text(type_oid, datum) },
        EncodingMode::JsonbNormalize => unsafe { encode_json_as_jsonb(type_oid, datum) },
    }
}

unsafe fn encode_json_as_jsonb(type_oid: pg_sys::Oid, datum: pg_sys::Datum) -> Vec<u8> {
    if type_oid != pg_sys::JSONOID {
        pgrx::error!("jsonb-normalize encoding mode requires json input, got type oid {type_oid}");
    }

    let json_text = unsafe { encode_text(pg_sys::JSONOID, datum) };
    let json_cstring = CString::new(json_text)
        .unwrap_or_else(|_| pgrx::error!("json output unexpectedly contained NUL"));
    let mut input_oid = pg_sys::InvalidOid;
    let mut type_io_param = pg_sys::InvalidOid;
    unsafe {
        pg_sys::getTypeInputInfo(pg_sys::JSONBOID, &mut input_oid, &mut type_io_param);
    }
    if input_oid == pg_sys::InvalidOid {
        pgrx::error!("jsonb input function was not found");
    }

    let jsonb_datum = unsafe {
        pg_sys::OidInputFunctionCall(
            input_oid,
            json_cstring.as_ptr().cast_mut(),
            type_io_param,
            -1,
        )
    };
    unsafe { encode_send(pg_sys::JSONBOID, jsonb_datum) }
}

unsafe fn normalize_float_datum(type_oid: pg_sys::Oid, datum: pg_sys::Datum) -> pg_sys::Datum {
    if type_oid == pg_sys::FLOAT4OID {
        let value =
            unsafe { f32::from_datum(datum, false) }.expect("non-null float4 datum must decode");
        return normalize_f32(value)
            .into_datum()
            .expect("float4 value must encode as datum");
    }

    if type_oid == pg_sys::FLOAT8OID {
        let value =
            unsafe { f64::from_datum(datum, false) }.expect("non-null float8 datum must decode");
        return normalize_f64(value)
            .into_datum()
            .expect("float8 value must encode as datum");
    }

    datum
}

fn normalize_f32(value: f32) -> f32 {
    normalize_f32_with_policy(
        value,
        crate::float_signed_zero_distinct(),
        crate::float_nan_distinct(),
    )
}

fn normalize_f64(value: f64) -> f64 {
    normalize_f64_with_policy(
        value,
        crate::float_signed_zero_distinct(),
        crate::float_nan_distinct(),
    )
}

fn normalize_f32_with_policy(value: f32, signed_zero_distinct: bool, nan_distinct: bool) -> f32 {
    if value.is_nan() && !nan_distinct {
        return f32::from_bits(0x7fc0_0000);
    }

    if value == 0.0 && !signed_zero_distinct {
        return 0.0;
    }

    value
}

fn normalize_f64_with_policy(value: f64, signed_zero_distinct: bool, nan_distinct: bool) -> f64 {
    if value.is_nan() && !nan_distinct {
        return f64::from_bits(0x7ff8_0000_0000_0000);
    }

    if value == 0.0 && !signed_zero_distinct {
        return 0.0;
    }

    value
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
    use proptest::prelude::*;

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
        assert_eq!(
            EncodingMode::try_from(3).unwrap(),
            EncodingMode::JsonbNormalize
        );
        assert!(EncodingMode::try_from(0).is_err());
    }

    #[test]
    fn float_normalization_canonicalizes_signed_zero_and_nan_payloads() {
        assert_eq!(
            normalize_f32_with_policy(-0.0, false, false).to_bits(),
            0.0f32.to_bits()
        );
        assert_eq!(
            normalize_f64_with_policy(-0.0, false, false).to_bits(),
            0.0f64.to_bits()
        );
        assert_eq!(
            normalize_f32_with_policy(f32::from_bits(0x7fc0_0001), false, false).to_bits(),
            0x7fc0_0000
        );
        assert_eq!(
            normalize_f64_with_policy(f64::from_bits(0x7ff8_0000_0000_0001), false, false)
                .to_bits(),
            0x7ff8_0000_0000_0000
        );
    }

    #[test]
    fn float_normalization_policy_can_preserve_bits() {
        assert_eq!(
            normalize_f32_with_policy(-0.0, true, false).to_bits(),
            (-0.0f32).to_bits()
        );
        assert_eq!(
            normalize_f64_with_policy(-0.0, true, false).to_bits(),
            (-0.0f64).to_bits()
        );
        assert_eq!(
            normalize_f32_with_policy(f32::from_bits(0x7fc0_0001), false, true).to_bits(),
            0x7fc0_0001
        );
        assert_eq!(
            normalize_f64_with_policy(f64::from_bits(0x7ff8_0000_0000_0001), false, true).to_bits(),
            0x7ff8_0000_0000_0001
        );
    }

    fn frame_reference(values: &[Option<Vec<u8>>]) -> Vec<u8> {
        let mut out = Vec::new();
        for value in values {
            match value {
                None => out.push(0x00),
                Some(bytes) => {
                    out.push(0x01);
                    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
                    out.extend_from_slice(bytes);
                }
            }
        }
        out
    }

    fn framed_digest(values: &[Option<Vec<u8>>]) -> blake3::Hash {
        let mut hasher = blake3::Hasher::new();
        for value in values {
            frame_value(&mut hasher, value.as_deref());
        }
        hasher.finalize()
    }

    proptest! {
        #[test]
        fn frame_value_matches_independent_reference(
            values in prop::collection::vec(
                prop::option::of(prop::collection::vec(any::<u8>(), 0..256)),
                0..32
            )
        ) {
            let actual = framed_digest(&values);
            let expected = blake3::hash(&frame_reference(&values));

            prop_assert_eq!(actual, expected);
        }
    }
}
