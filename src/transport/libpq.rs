use core::ffi::{c_char, c_int};
use std::ffi::{CStr, CString};

const CONNECTION_OK: c_int = 0;
const PGRES_COMMAND_OK: c_int = 1;
const PGRES_TUPLES_OK: c_int = 2;

#[repr(C)]
struct PGconn {
    _private: [u8; 0],
}

#[repr(C)]
struct PGresult {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn PQconnectdb(conninfo: *const c_char) -> *mut PGconn;
    fn PQstatus(conn: *const PGconn) -> c_int;
    fn PQerrorMessage(conn: *const PGconn) -> *mut c_char;
    fn PQfinish(conn: *mut PGconn);
    fn PQexec(conn: *mut PGconn, query: *const c_char) -> *mut PGresult;
    fn PQresultStatus(res: *const PGresult) -> c_int;
    fn PQresultErrorMessage(res: *const PGresult) -> *mut c_char;
    fn PQntuples(res: *const PGresult) -> c_int;
    fn PQnfields(res: *const PGresult) -> c_int;
    fn PQgetisnull(res: *const PGresult, row: c_int, column: c_int) -> c_int;
    fn PQgetvalue(res: *const PGresult, row: c_int, column: c_int) -> *mut c_char;
    fn PQgetlength(res: *const PGresult, row: c_int, column: c_int) -> c_int;
    fn PQclear(res: *mut PGresult);
}

/// Row-count and set-hash result fetched from a remote participant.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct RemoteChecksum {
    /// Remote server_version_num.
    pub(crate) pg_version: i32,
    /// Remote row count.
    pub(crate) n_rows: i64,
    /// Remote LtHash bytes.
    pub(crate) lthash: Vec<u8>,
}

/// Key and row digest fetched while localizing a divergent chunk.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct LocalizedRowDigest {
    /// JSON text representation of the comparison key.
    pub(crate) key_text: String,
    /// Canonical digest bytes for the comparison key.
    pub(crate) key_bytes: Vec<u8>,
    /// Canonical row digest bytes for the replicated column set.
    pub(crate) row_digest: Vec<u8>,
}

/// Barrier token and exact commit-end LSN injected on an origin node.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct BarrierInjection {
    /// UUID bytes inserted into `pgl_validate.fence_barrier`.
    pub(crate) token: [u8; 16],
    /// Exact barrier commit end LSN from `pgl_validate.last_commit_lsn()`.
    pub(crate) barrier_end_lsn: u64,
}

/// Provider-side slot flush observation for a barrier.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct SlotConfirmation {
    /// Slot `confirmed_flush_lsn` after `pglogical.wait_slot_confirm_lsn`.
    pub(crate) confirmed_flush_lsn: u64,
}

/// Target-side apply observation for a barrier.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct BarrierObservation {
    /// Edge-specific replication origin progress observed on the target.
    pub(crate) origin_progress_lsn: u64,
    /// Whether the barrier token is visible on the target.
    pub(crate) token_visible: bool,
    /// Whether origin progress and token visibility satisfy exact convergence.
    pub(crate) converged: bool,
}

/// pglogical subscription status fetched from a remote target node.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct SubscriptionStatus {
    /// Subscription lifecycle status, such as `replicating`.
    pub(crate) status: String,
    /// Provider node name reported by pglogical.
    pub(crate) provider_node: String,
    /// Provider DSN stored by the subscription.
    pub(crate) provider_dsn: String,
    /// Logical replication slot name used by the subscription.
    pub(crate) slot_name: String,
    /// JSON text for the subscription replication-set array.
    pub(crate) replication_sets_json: String,
    /// JSON text for the subscription forward-origins array.
    pub(crate) forward_origins_json: String,
}

struct Connection {
    raw: *mut PGconn,
}

impl Connection {
    fn connect(dsn: &str) -> Result<Self, String> {
        let dsn = CString::new(dsn).map_err(|_| "dsn contains an embedded NUL".to_string())?;
        let raw = unsafe { PQconnectdb(dsn.as_ptr()) };
        if raw.is_null() {
            return Err("PQconnectdb returned NULL".to_string());
        }

        let conn = Self { raw };
        if unsafe { PQstatus(conn.raw) } != CONNECTION_OK {
            let message = conn.error_message();
            return Err(format!("libpq connection failed: {message}"));
        }

        Ok(conn)
    }

    fn connect_with_timeout(dsn: &str, connect_timeout_seconds: i32) -> Result<Self, String> {
        let connect_timeout_seconds =
            validate_timeout("connect_timeout_seconds", connect_timeout_seconds)?;
        Self::connect(&dsn_with_connect_timeout(dsn, connect_timeout_seconds))
    }

    fn exec(&self, sql: &str) -> Result<QueryResult, String> {
        let sql = CString::new(sql).map_err(|_| "query contains an embedded NUL".to_string())?;
        let raw = unsafe { PQexec(self.raw, sql.as_ptr()) };
        if raw.is_null() {
            return Err(format!("libpq query failed: {}", self.error_message()));
        }

        Ok(QueryResult { raw })
    }

    fn exec_command(&self, sql: &str) -> Result<(), String> {
        let result = self.exec(sql)?;
        result.require_status(PGRES_COMMAND_OK)
    }

    fn set_query_timeouts(
        &self,
        statement_timeout_ms: i32,
        lock_timeout_ms: i32,
    ) -> Result<(), String> {
        let statement_timeout_ms = validate_timeout("statement_timeout_ms", statement_timeout_ms)?;
        let lock_timeout_ms = validate_timeout("lock_timeout_ms", lock_timeout_ms)?;
        let result = self.exec(&format!(
            "SET statement_timeout = {statement_timeout_ms}; SET lock_timeout = {lock_timeout_ms}"
        ))?;
        result.require_status(PGRES_COMMAND_OK)
    }

    fn error_message(&self) -> String {
        unsafe { c_message(PQerrorMessage(self.raw)) }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        unsafe { PQfinish(self.raw) };
    }
}

struct QueryResult {
    raw: *mut PGresult,
}

impl QueryResult {
    fn require_status(&self, expected: c_int) -> Result<(), String> {
        let status = unsafe { PQresultStatus(self.raw) };
        if status == expected {
            Ok(())
        } else {
            Err(format!(
                "libpq query returned status {status}: {}",
                self.error_message()
            ))
        }
    }

    fn ntuples(&self) -> c_int {
        unsafe { PQntuples(self.raw) }
    }

    fn nfields(&self) -> c_int {
        unsafe { PQnfields(self.raw) }
    }

    fn value(&self, row: c_int, column: c_int) -> Result<String, String> {
        if unsafe { PQgetisnull(self.raw, row, column) } != 0 {
            return Err(format!("remote result column {column} is NULL"));
        }

        let ptr = unsafe { PQgetvalue(self.raw, row, column) };
        if ptr.is_null() {
            return Err(format!("remote result column {column} has NULL storage"));
        }

        let len = unsafe { PQgetlength(self.raw, row, column) };
        if len < 0 {
            return Err(format!("remote result column {column} has negative length"));
        }

        let bytes = unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len as usize) };
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|err| format!("remote result column {column} is not UTF-8: {err}"))
    }

    fn single_value(&self) -> Result<String, String> {
        self.require_status(PGRES_TUPLES_OK)?;
        if self.ntuples() != 1 || self.nfields() != 1 {
            return Err(format!(
                "remote query returned {} row(s) and {} column(s), expected 1 row and 1 column",
                self.ntuples(),
                self.nfields()
            ));
        }

        self.value(0, 0)
    }

    fn error_message(&self) -> String {
        unsafe { c_message(PQresultErrorMessage(self.raw)) }
    }
}

impl Drop for QueryResult {
    fn drop(&mut self) {
        unsafe { PQclear(self.raw) };
    }
}

/// Execute one SQL command on a remote libpq connection.
#[cfg(any(test, feature = "pg_test"))]
pub(crate) fn execute_command(dsn: &str, sql: &str) -> Result<(), String> {
    execute_command_with_timeouts(dsn, sql, 10, 10_000, 10_000)
}

/// Execute one SQL command on a remote libpq connection with explicit timeouts.
#[cfg(any(test, feature = "pg_test"))]
pub(crate) fn execute_command_with_timeouts(
    dsn: &str,
    sql: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<(), String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;
    conn.exec_command(sql)
}

/// Insert a barrier token on an origin and return the exact commit-end LSN.
pub(crate) fn inject_barrier(
    dsn: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<BarrierInjection, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let token = uuid::Uuid::new_v4();
    let token_sql = token.to_string();

    conn.exec_command("BEGIN")?;
    if let Err(err) = conn.exec_command(&format!(
        "INSERT INTO pgl_validate.fence_barrier(token) VALUES ('{token_sql}'::uuid)"
    )) {
        let _ = conn.exec_command("ROLLBACK");
        return Err(err);
    }
    if let Err(err) = conn.exec_command("COMMIT") {
        let _ = conn.exec_command("ROLLBACK");
        return Err(err);
    }

    let lsn_result = conn.exec("SELECT pgl_validate.last_commit_lsn()::text")?;
    let barrier_end_lsn = parse_lsn(&lsn_result.single_value()?)?;

    Ok(BarrierInjection {
        token: *token.as_bytes(),
        barrier_end_lsn,
    })
}

/// Wait for pglogical to confirm that a provider slot has flushed a barrier.
pub(crate) fn wait_slot_confirm_lsn(
    dsn: &str,
    slot_name: &str,
    barrier_end_lsn: u64,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<SlotConfirmation, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let slot = sql_literal(slot_name);
    let barrier_lsn = format_lsn(barrier_end_lsn);
    conn.exec(&format!(
        "SELECT pglogical.wait_slot_confirm_lsn({slot}::name, '{}'::pg_lsn)",
        barrier_lsn
    ))?
    .require_status(PGRES_TUPLES_OK)?;

    let result = conn.exec(&format!(
        "SELECT confirmed_flush_lsn::text \
         FROM pg_replication_slots \
         WHERE slot_name = {slot}"
    ))?;
    let confirmed_flush_lsn = parse_lsn(&result.single_value()?)?;

    Ok(SlotConfirmation {
        confirmed_flush_lsn,
    })
}

/// Observe target-side origin progress and token visibility for a barrier.
pub(crate) fn observe_barrier(
    dsn: &str,
    origin_name: &str,
    token: [u8; 16],
    barrier_end_lsn: u64,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<BarrierObservation, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let origin = sql_literal(origin_name);
    let token = sql_literal(&uuid::Uuid::from_bytes(token).to_string());
    let barrier_lsn = format_lsn(barrier_end_lsn);
    let result = conn.exec(&format!(
        "WITH observed AS ( \
             SELECT COALESCE( \
                    (SELECT pg_replication_origin_progress(roname, true) \
                     FROM pg_replication_origin \
                     WHERE roname = {origin}), \
                    '0/0'::pg_lsn \
                    ) AS origin_progress_lsn, \
                    EXISTS ( \
                        SELECT 1 \
                        FROM pgl_validate.fence_barrier \
                        WHERE token = {token}::uuid \
                    ) AS token_visible \
         ) \
         SELECT origin_progress_lsn::text, \
                token_visible::text, \
                (origin_progress_lsn >= '{barrier_lsn}'::pg_lsn AND token_visible)::text \
         FROM observed"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 3 {
        return Err(format!(
            "remote barrier observation returned {} row(s) and {} column(s), expected 1 row and 3 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(BarrierObservation {
        origin_progress_lsn: parse_lsn(&result.value(0, 0)?)?,
        token_visible: parse_bool(&result.value(0, 1)?)?,
        converged: parse_bool(&result.value(0, 2)?)?,
    })
}

/// Fetch pglogical subscription status from a remote target node.
pub(crate) fn fetch_subscription_status(
    dsn: &str,
    subscription_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<SubscriptionStatus, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let subscription_name = sql_literal(subscription_name);
    let result = conn.exec(&format!(
        "SELECT status, \
                provider_node, \
                provider_dsn, \
                slot_name, \
                COALESCE(to_json(replication_sets)::text, '[]') AS replication_sets_json, \
                COALESCE(to_json(forward_origins)::text, '[]') AS forward_origins_json \
         FROM pglogical.show_subscription_status({subscription_name}::name)"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 6 {
        return Err(format!(
            "expected one pglogical subscription status row with 6 columns, got {} row(s) and {} column(s)",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(SubscriptionStatus {
        status: result.value(0, 0)?,
        provider_node: result.value(0, 1)?,
        provider_dsn: result.value(0, 2)?,
        slot_name: result.value(0, 3)?,
        replication_sets_json: result.value(0, 4)?,
        forward_origins_json: result.value(0, 5)?,
    })
}

/// Run generated checksum SQL on a remote participant and return its digest.
pub(crate) fn fetch_checksum(
    dsn: &str,
    checksum_sql: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<RemoteChecksum, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;
    let wrapped_sql = format!(
        "SELECT current_setting('server_version_num')::int::text, \
                q.n_rows::bigint::text, \
                encode(q.lthash, 'hex') \
         FROM ({checksum_sql}) AS q"
    );

    let result = conn.exec(&wrapped_sql)?;
    result.require_status(PGRES_TUPLES_OK)?;

    if result.ntuples() != 1 || result.nfields() != 3 {
        return Err(format!(
            "remote checksum returned {} row(s) and {} column(s), expected 1 row and 3 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    let pg_version = result
        .value(0, 0)?
        .parse::<i32>()
        .map_err(|err| format!("invalid remote server_version_num: {err}"))?;
    let n_rows = result
        .value(0, 1)?
        .parse::<i64>()
        .map_err(|err| format!("invalid remote row count: {err}"))?;
    let lthash = parse_hex(&result.value(0, 2)?)?;

    Ok(RemoteChecksum {
        pg_version,
        n_rows,
        lthash,
    })
}

/// Run generated localization SQL on a remote participant.
pub(crate) fn fetch_localized_rows(
    dsn: &str,
    localization_sql: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<Vec<LocalizedRowDigest>, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;
    let wrapped_sql = format!(
        "SELECT q.key_text, \
                encode(q.key_bytes, 'hex'), \
                encode(q.row_digest, 'hex') \
         FROM ({localization_sql}) AS q"
    );

    let result = conn.exec(&wrapped_sql)?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 3 {
        return Err(format!(
            "remote localization returned {} column(s), expected 3",
            result.nfields()
        ));
    }

    let mut rows = Vec::with_capacity(result.ntuples() as usize);
    for row in 0..result.ntuples() {
        rows.push(LocalizedRowDigest {
            key_text: result.value(row, 0)?,
            key_bytes: parse_hex(&result.value(row, 1)?)?,
            row_digest: parse_hex(&result.value(row, 2)?)?,
        });
    }

    Ok(rows)
}

unsafe fn c_message(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }

    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .trim()
        .to_string()
}

fn validate_timeout(label: &str, value: i32) -> Result<i32, String> {
    if value <= 0 {
        return Err(format!("{label} must be greater than zero"));
    }

    Ok(value)
}

fn dsn_with_connect_timeout(dsn: &str, connect_timeout_seconds: i32) -> String {
    if dsn.to_ascii_lowercase().contains("connect_timeout") {
        return dsn.to_string();
    }

    if dsn.starts_with("postgresql://") || dsn.starts_with("postgres://") {
        let separator = if dsn.contains('?') { '&' } else { '?' };
        return format!("{dsn}{separator}connect_timeout={connect_timeout_seconds}");
    }

    format!("{dsn} connect_timeout={connect_timeout_seconds}")
}

fn sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn parse_hex(input: &str) -> Result<Vec<u8>, String> {
    let input = input.strip_prefix("\\x").unwrap_or(input);
    if input.len() % 2 != 0 {
        return Err(format!("hex string has odd length {}", input.len()));
    }

    let mut out = Vec::with_capacity(input.len() / 2);
    for idx in (0..input.len()).step_by(2) {
        let byte = u8::from_str_radix(&input[idx..idx + 2], 16)
            .map_err(|err| format!("invalid hex byte at offset {idx}: {err}"))?;
        out.push(byte);
    }

    Ok(out)
}

fn parse_lsn(input: &str) -> Result<u64, String> {
    let Some((high, low)) = input.split_once('/') else {
        return Err(format!("invalid pg_lsn without slash: {input}"));
    };
    let high = u64::from_str_radix(high, 16)
        .map_err(|err| format!("invalid pg_lsn high word {high:?}: {err}"))?;
    let low = u64::from_str_radix(low, 16)
        .map_err(|err| format!("invalid pg_lsn low word {low:?}: {err}"))?;
    if high > u32::MAX as u64 || low > u32::MAX as u64 {
        return Err(format!("pg_lsn word out of range: {input}"));
    }

    Ok((high << 32) | low)
}

fn format_lsn(lsn: u64) -> String {
    format!("{:X}/{:08X}", lsn >> 32, lsn & u32::MAX as u64)
}

fn parse_bool(input: &str) -> Result<bool, String> {
    match input {
        "t" | "true" => Ok(true),
        "f" | "false" => Ok(false),
        _ => Err(format!("invalid boolean text: {input}")),
    }
}

#[cfg(test)]
mod tests {
    use super::{dsn_with_connect_timeout, format_lsn, parse_bool, parse_hex, parse_lsn};

    #[test]
    fn parses_hex_with_or_without_bytea_prefix() {
        assert_eq!(parse_hex("0102ff").unwrap(), vec![0x01, 0x02, 0xff]);
        assert_eq!(parse_hex("\\x0102ff").unwrap(), vec![0x01, 0x02, 0xff]);
    }

    #[test]
    fn rejects_invalid_hex() {
        assert!(parse_hex("0").is_err());
        assert!(parse_hex("xx").is_err());
    }

    #[test]
    fn appends_connect_timeout_to_keyword_dsn() {
        assert_eq!(
            dsn_with_connect_timeout("host=localhost dbname=postgres", 7),
            "host=localhost dbname=postgres connect_timeout=7"
        );
        assert_eq!(
            dsn_with_connect_timeout("host=localhost connect_timeout=3", 7),
            "host=localhost connect_timeout=3"
        );
    }

    #[test]
    fn appends_connect_timeout_to_uri_dsn() {
        assert_eq!(
            dsn_with_connect_timeout("postgresql://localhost/postgres", 7),
            "postgresql://localhost/postgres?connect_timeout=7"
        );
        assert_eq!(
            dsn_with_connect_timeout("postgresql://localhost/postgres?sslmode=disable", 7),
            "postgresql://localhost/postgres?sslmode=disable&connect_timeout=7"
        );
    }

    #[test]
    fn parses_pg_lsn_text() {
        assert_eq!(parse_lsn("0/16B6C50").unwrap(), 0x016b6c50);
        assert_eq!(parse_lsn("1/00000000").unwrap(), 0x1_0000_0000);
        assert!(parse_lsn("not-an-lsn").is_err());
        assert!(parse_lsn("100000000/0").is_err());
    }

    #[test]
    fn formats_pg_lsn_text() {
        assert_eq!(format_lsn(0x016b6c50), "0/016B6C50");
        assert_eq!(format_lsn(0x1_0000_0000), "1/00000000");
    }

    #[test]
    fn parses_postgres_boolean_text() {
        assert!(parse_bool("t").unwrap());
        assert!(parse_bool("true").unwrap());
        assert!(!parse_bool("f").unwrap());
        assert!(!parse_bool("false").unwrap());
        assert!(parse_bool("yes").is_err());
    }
}
