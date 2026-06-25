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
    let conn = Connection::connect_with_timeout(dsn, 10)?;
    conn.set_query_timeouts(10_000, 10_000)?;
    let result = conn.exec(sql)?;
    result.require_status(PGRES_COMMAND_OK)
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

#[cfg(test)]
mod tests {
    use super::{dsn_with_connect_timeout, parse_hex};

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
}
