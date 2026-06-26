use super::encode::{EncodingMode, encode_datum, frame_value};
use pgrx::prelude::*;

/// Compute row_digest from PostgreSQL's raw function-call information.
///
/// # Safety
///
/// `fcinfo` must be a valid PostgreSQL `FunctionCallInfo` for
/// `row_digest(enc int[], VARIADIC "any")`.
pub unsafe fn row_digest_fcinfo(fcinfo: pg_sys::FunctionCallInfo) -> Vec<u8> {
    let nargs = unsafe { (*fcinfo).nargs as usize };
    if nargs == 0 {
        pgrx::error!("row_digest requires enc int[] followed by variadic column values");
    }

    let modes = unsafe { pgrx::pg_getarg::<Vec<Option<i32>>>(fcinfo, 0) }
        .expect("row_digest enc int[] must not be NULL")
        .into_iter()
        .map(|mode| {
            mode.expect("row_digest enc int[] must not contain NULLs")
                .try_into()
                .unwrap_or_else(|err: String| pgrx::error!("{err}"))
        })
        .collect::<Vec<EncodingMode>>();

    let value_count = nargs - 1;
    if modes.len() != value_count {
        pgrx::error!(
            "row_digest enc length ({}) must match variadic column count ({value_count})",
            modes.len()
        );
    }

    let algorithm = crate::current_hash_algorithm();
    let mut hasher = blake3::Hasher::new();
    for idx in 0..value_count {
        let argno = idx + 1;
        if unsafe { pgrx::pg_arg_is_null(fcinfo, argno) } {
            frame_value(&mut hasher, None);
            continue;
        }

        let datum = unsafe { pgrx::pg_getarg_datum_raw(fcinfo, argno) };
        let type_oid = unsafe { pgrx::pg_getarg_type(fcinfo, argno) };
        if type_oid == pg_sys::InvalidOid {
            pgrx::error!("could not resolve row_digest argument {argno} type");
        }
        let encoded = unsafe { encode_datum(type_oid, datum, modes[idx]) };
        frame_value(&mut hasher, Some(&encoded));
    }

    algorithm.finalize_blake3(hasher)
}
