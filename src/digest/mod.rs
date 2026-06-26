//! Digest primitives used by SQL-facing pgrx functions.

/// Row and set digest algorithm selection.
pub(crate) mod algorithm;
/// Datum encoding helpers for row digest input values.
pub mod encode;
/// LtHash multiset accumulator and confirmation hash helpers.
pub mod lthash;
/// Raw `fcinfo` implementation for the heterogeneous SQL `row_digest`.
pub mod row_digest;
