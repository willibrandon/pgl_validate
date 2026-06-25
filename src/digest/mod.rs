//! Digest primitives used by SQL-facing pgrx functions.

/// Datum encoding helpers for row digest input values.
pub mod encode;
/// LtHash multiset accumulator and confirmation hash helpers.
pub mod lthash;
/// Raw `fcinfo` implementation for the heterogeneous SQL `row_digest`.
pub mod row_digest;
