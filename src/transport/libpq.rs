use core::ffi::{c_char, c_int};
use pgrx::pg_sys;
use serde::Deserialize;
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
    fn PQsetnonblocking(conn: *mut PGconn, arg: c_int) -> c_int;
    fn PQsendQuery(conn: *mut PGconn, query: *const c_char) -> c_int;
    fn PQsocket(conn: *const PGconn) -> c_int;
    fn PQconsumeInput(conn: *mut PGconn) -> c_int;
    fn PQisBusy(conn: *mut PGconn) -> c_int;
    fn PQgetResult(conn: *mut PGconn) -> *mut PGresult;
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
    /// Optional cryptographic set hash for paranoid confirmation.
    pub(crate) set_hash: Option<Vec<u8>>,
}

/// One generated checksum request scheduled by the chunk fan-out executor.
#[derive(Debug, Clone, Deserialize, Eq, PartialEq)]
pub(crate) struct RemoteChecksumTask {
    /// Stable task identifier assigned by SQL for joining results back to chunks.
    pub(crate) task_id: i32,
    /// Remote libpq connection string.
    pub(crate) dsn: String,
    /// Generated checksum SQL to execute on the remote node.
    pub(crate) checksum_sql: String,
    /// libpq connection timeout in seconds.
    pub(crate) connect_timeout_seconds: i32,
    /// PostgreSQL statement timeout in milliseconds.
    pub(crate) statement_timeout_ms: i32,
    /// PostgreSQL lock timeout in milliseconds.
    pub(crate) lock_timeout_ms: i32,
}

/// Result for one generated checksum request in a fan-out batch.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct RemoteChecksumBatchResult {
    /// Stable task identifier from `RemoteChecksumTask`.
    pub(crate) task_id: i32,
    /// Remote server checksum result.
    pub(crate) checksum: RemoteChecksum,
}

/// Schema-contract signature fetched from a remote participant.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct RemoteSchemaSignature {
    /// Remote server_version_num.
    pub(crate) pg_version: i32,
    /// Deterministic JSON signature for the compared relation contract.
    pub(crate) signature: String,
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
    /// JSON text representation of the localized row.
    pub(crate) row_json: String,
}

/// Last value fetched from a remote sequence.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) struct RemoteSequenceValue {
    /// Remote server_version_num.
    pub(crate) pg_version: i32,
    /// Remote sequence `last_value`.
    pub(crate) last_value: i64,
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

/// Provider-side lag observation for one logical replication slot.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct LogicalSlotLag {
    /// Whether the provider slot currently has an active replication backend.
    pub(crate) active: bool,
    /// Maximum write/flush/replay lag reported by `pg_stat_replication`, in milliseconds.
    pub(crate) lag_ms: i64,
    /// WAL bytes between the provider's current WAL LSN and slot confirmed flush.
    pub(crate) lag_bytes: i64,
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

/// Physical-standby replay status fetched from a remote participant.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct StandbyReplayStatus {
    /// Remote server_version_num.
    pub(crate) pg_version: i32,
    /// Whether the remote participant is currently in recovery.
    pub(crate) in_recovery: bool,
    /// Remote `pg_last_wal_replay_lsn()`, or zero when no replay LSN exists.
    pub(crate) replay_lsn: u64,
    /// Whether WAL replay is paused on the remote participant.
    pub(crate) replay_paused: bool,
}

/// Physical-standby lag observation against a target primary LSN.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct StandbyReplayLag {
    /// Whether the remote participant is currently in recovery.
    pub(crate) in_recovery: bool,
    /// Remote `pg_last_wal_replay_lsn()`, or zero when no replay LSN exists.
    pub(crate) replay_lsn: u64,
    /// Replay lag in milliseconds, or `None` when the standby is behind but has no replay timestamp.
    pub(crate) lag_ms: Option<i64>,
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

/// Native logical subscription status fetched from a remote target node.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct NativeSubscriptionStatus {
    /// Whether the subscription is enabled on the target.
    pub(crate) enabled: bool,
    /// Subscription OID on the target.
    pub(crate) subid: i64,
    /// Provider-side logical replication slot name, when the subscription uses one.
    pub(crate) slot_name: Option<String>,
    /// JSON text for the subscription publication array.
    pub(crate) publications_json: String,
    /// Replication-origin name used by core logical replication for this subscription.
    pub(crate) origin_name: String,
}

/// Per-table synchronization state fetched from a remote subscriber.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct TableSyncStatus {
    /// Subscriber-side table state, such as `r` for ready.
    pub(crate) sync_status: Option<String>,
    /// Subscriber-side status LSN when the replication backend records one.
    pub(crate) sync_status_lsn: Option<u64>,
}

/// pglogical subscription that would forward an origin-tagged repair.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct ForwardingSubscription {
    /// Subscription name on the downstream subscriber.
    pub(crate) subscription_name: String,
}

/// pglogical conflict-history row fetched from a subscriber.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct ConflictHistoryRow {
    /// Conflict row identifier within the subscriber partition.
    pub(crate) conflict_id: i64,
    /// Subscriber-side conflict recording timestamp as PostgreSQL text.
    pub(crate) recorded_at: String,
    /// Subscription name that observed the conflict.
    pub(crate) subscription_name: Option<String>,
    /// pglogical conflict type, such as `update_update`.
    pub(crate) conflict_type: String,
    /// pglogical conflict resolution, such as `keep_local`.
    pub(crate) resolution: String,
    /// Index name used for conflict detection.
    pub(crate) index_name: Option<String>,
    /// Local tuple JSON text, when pglogical captured it.
    pub(crate) local_tuple_json: Option<String>,
    /// Local transaction id text, when available.
    pub(crate) local_xid: Option<String>,
    /// Local tuple replication origin, when available.
    pub(crate) local_origin: Option<i32>,
    /// Local tuple commit timestamp text, when available.
    pub(crate) local_commit_ts: Option<String>,
    /// Remote tuple JSON text, when pglogical captured it.
    pub(crate) remote_tuple_json: Option<String>,
    /// Remote tuple replication origin.
    pub(crate) remote_origin: i32,
    /// Remote commit timestamp text.
    pub(crate) remote_commit_ts: String,
    /// Remote commit LSN.
    pub(crate) remote_commit_lsn: u64,
    /// Whether subscriber BEFORE triggers participated in the conflict.
    pub(crate) has_before_triggers: bool,
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

    fn set_nonblocking(&self, enabled: bool) -> Result<(), String> {
        let value = if enabled { 1 } else { 0 };
        if unsafe { PQsetnonblocking(self.raw, value) } == 0 {
            Ok(())
        } else {
            Err(format!(
                "could not set libpq nonblocking mode: {}",
                self.error_message()
            ))
        }
    }

    fn send_query(&self, sql: &str) -> Result<(), String> {
        let sql = CString::new(sql).map_err(|_| "query contains an embedded NUL".to_string())?;
        if unsafe { PQsendQuery(self.raw, sql.as_ptr()) } == 1 {
            Ok(())
        } else {
            Err(format!("libpq send query failed: {}", self.error_message()))
        }
    }

    fn socket(&self) -> Result<pg_sys::pgsocket, String> {
        let socket = unsafe { PQsocket(self.raw) };
        if socket < 0 {
            Err(format!(
                "libpq connection has no waitable socket: {}",
                self.error_message()
            ))
        } else {
            Ok(socket as pg_sys::pgsocket)
        }
    }

    fn consume_input(&self) -> Result<(), String> {
        if unsafe { PQconsumeInput(self.raw) } == 1 {
            Ok(())
        } else {
            Err(format!(
                "libpq consume input failed: {}",
                self.error_message()
            ))
        }
    }

    fn is_busy(&self) -> bool {
        unsafe { PQisBusy(self.raw) == 1 }
    }

    fn next_result(&self) -> Option<QueryResult> {
        let raw = unsafe { PQgetResult(self.raw) };
        if raw.is_null() {
            None
        } else {
            Some(QueryResult { raw })
        }
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

struct WaitEventSetGuard {
    raw: *mut pg_sys::WaitEventSet,
}

impl WaitEventSetGuard {
    fn new(event_count: usize) -> Result<Self, String> {
        let raw = unsafe { crate::compat::create_wait_event_set(event_count as c_int) };
        if raw.is_null() {
            Err("CreateWaitEventSet returned NULL".to_string())
        } else {
            Ok(Self { raw })
        }
    }
}

impl Drop for WaitEventSetGuard {
    fn drop(&mut self) {
        unsafe { pg_sys::FreeWaitEventSet(self.raw) };
    }
}

fn wait_for_remote_input(active: &[ActiveChecksumTask]) -> Result<(), String> {
    let sockets = active
        .iter()
        .map(|task| task.conn.socket())
        .collect::<Result<Vec<_>, _>>()?;
    let wait_set = WaitEventSetGuard::new(sockets.len() + 1)?;

    unsafe {
        let invalid_socket = !0 as pg_sys::pgsocket;
        let latch_pos = pg_sys::AddWaitEventToSet(
            wait_set.raw,
            pg_sys::WL_LATCH_SET,
            invalid_socket,
            pg_sys::MyLatch,
            std::ptr::null_mut(),
        );
        if latch_pos < 0 {
            return Err("AddWaitEventToSet failed for backend latch".to_string());
        }

        let socket_events = if pg_sys::WaitEventSetCanReportClosed() {
            pg_sys::WL_SOCKET_READABLE | pg_sys::WL_SOCKET_CLOSED
        } else {
            pg_sys::WL_SOCKET_READABLE
        };

        for socket in sockets {
            let socket_pos = pg_sys::AddWaitEventToSet(
                wait_set.raw,
                socket_events,
                socket,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
            if socket_pos < 0 {
                return Err(format!(
                    "AddWaitEventToSet failed for libpq socket {socket}"
                ));
            }
        }

        let mut occurred_events = vec![pg_sys::WaitEvent::default(); active.len() + 1];
        let ready_count = pg_sys::WaitEventSetWait(
            wait_set.raw,
            -1,
            occurred_events.as_mut_ptr(),
            occurred_events.len() as c_int,
            pg_sys::PG_WAIT_EXTENSION,
        );
        pg_sys::ResetLatch(pg_sys::MyLatch);
        pg_sys::check_for_interrupts!();

        if ready_count < 0 {
            return Err("WaitEventSetWait failed while waiting for libpq input".to_string());
        }
    }

    Ok(())
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
    fn status(&self) -> c_int {
        unsafe { PQresultStatus(self.raw) }
    }

    fn require_status(&self, expected: c_int) -> Result<(), String> {
        let status = self.status();
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

    fn value_opt(&self, row: c_int, column: c_int) -> Result<Option<String>, String> {
        if unsafe { PQgetisnull(self.raw, row, column) } != 0 {
            return Ok(None);
        }

        self.value(row, column).map(Some)
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

/// Fetch the provider's current WAL insert LSN for degraded fencing.
pub(crate) fn fetch_current_wal_lsn(
    dsn: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<u64, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let result = conn.exec("SELECT pg_current_wal_lsn()::text")?;
    parse_lsn(&result.single_value()?)
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

/// Fetch a provider logical slot's current `confirmed_flush_lsn`.
pub(crate) fn fetch_slot_confirmed_flush_lsn(
    dsn: &str,
    slot_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<u64, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let slot = sql_literal(slot_name);
    let result = conn.exec(&format!(
        "SELECT COALESCE(confirmed_flush_lsn, '0/0'::pg_lsn)::text \
         FROM pg_replication_slots \
         WHERE slot_name = {slot}"
    ))?;
    parse_lsn(&result.single_value()?)
}

/// Fetch provider-side time and byte lag for one logical replication slot.
pub(crate) fn fetch_logical_slot_lag(
    dsn: &str,
    slot_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<LogicalSlotLag, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let slot = sql_literal(slot_name);
    let result = conn.exec(&format!(
        "WITH slot AS ( \
             SELECT s.active_pid, \
                    COALESCE(s.confirmed_flush_lsn, '0/0'::pg_lsn) AS confirmed_flush_lsn, \
                    pg_current_wal_lsn() AS current_lsn \
             FROM pg_replication_slots s \
             WHERE s.slot_name = {slot} \
         ), observed AS ( \
             SELECT (slot.active_pid IS NOT NULL) AS active, \
                    GREATEST( \
                        COALESCE(sr.write_lag, '0'::interval), \
                        COALESCE(sr.flush_lag, '0'::interval), \
                        COALESCE(sr.replay_lag, '0'::interval) \
                    ) AS lag_interval, \
                    GREATEST( \
                        pg_wal_lsn_diff(slot.current_lsn, slot.confirmed_flush_lsn), \
                        0::numeric \
                    ) AS lag_bytes \
             FROM slot \
             LEFT JOIN pg_stat_replication sr ON sr.pid = slot.active_pid \
         ) \
         SELECT active::text, \
                ceil(extract(epoch FROM lag_interval) * 1000)::bigint::text, \
                lag_bytes::bigint::text \
         FROM observed"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 3 {
        return Err(format!(
            "logical slot lag query for {slot_name:?} returned {} row(s) and {} column(s), expected 1 row and 3 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(LogicalSlotLag {
        active: parse_bool(&result.value(0, 0)?)?,
        lag_ms: result
            .value(0, 1)?
            .parse::<i64>()
            .map_err(|err| format!("invalid logical slot lag_ms: {err}"))?,
        lag_bytes: result
            .value(0, 2)?
            .parse::<i64>()
            .map_err(|err| format!("invalid logical slot lag_bytes: {err}"))?,
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

/// Fetch physical-standby replay status from a remote participant.
pub(crate) fn fetch_standby_replay_status(
    dsn: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<StandbyReplayStatus, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let result = conn.exec(
        "SELECT current_setting('server_version_num')::int::text, \
                pg_is_in_recovery()::text, \
                COALESCE(pg_last_wal_replay_lsn(), '0/0'::pg_lsn)::text, \
                CASE WHEN pg_is_in_recovery() \
                     THEN pg_is_wal_replay_paused() \
                     ELSE false \
                END::text",
    )?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 4 {
        return Err(format!(
            "remote standby replay status returned {} row(s) and {} column(s), expected 1 row and 4 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(StandbyReplayStatus {
        pg_version: result
            .value(0, 0)?
            .parse::<i32>()
            .map_err(|err| format!("invalid remote server_version_num: {err}"))?,
        in_recovery: parse_bool(&result.value(0, 1)?)?,
        replay_lsn: parse_lsn(&result.value(0, 2)?)?,
        replay_paused: parse_bool(&result.value(0, 3)?)?,
    })
}

/// Fetch physical-standby replay lag against a primary WAL LSN.
pub(crate) fn fetch_standby_replay_lag(
    dsn: &str,
    target_lsn: u64,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<StandbyReplayLag, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let target_lsn = format_lsn(target_lsn);
    let result = conn.exec(&format!(
        "WITH observed AS ( \
             SELECT pg_is_in_recovery() AS in_recovery, \
                    COALESCE(pg_last_wal_replay_lsn(), '0/0'::pg_lsn) AS replay_lsn, \
                    pg_last_xact_replay_timestamp() AS replay_timestamp \
         ) \
         SELECT in_recovery::text, \
                replay_lsn::text, \
                CASE \
                    WHEN NOT in_recovery THEN '0'::text \
                    WHEN replay_lsn >= '{target_lsn}'::pg_lsn THEN '0'::text \
                    WHEN replay_timestamp IS NULL THEN NULL \
                    ELSE ceil(extract(epoch FROM (clock_timestamp() - replay_timestamp)) * 1000)::bigint::text \
                END AS lag_ms \
         FROM observed"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 3 {
        return Err(format!(
            "remote standby replay lag returned {} row(s) and {} column(s), expected 1 row and 3 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(StandbyReplayLag {
        in_recovery: parse_bool(&result.value(0, 0)?)?,
        replay_lsn: parse_lsn(&result.value(0, 1)?)?,
        lag_ms: result
            .value_opt(0, 2)?
            .map(|value| {
                value
                    .parse::<i64>()
                    .map_err(|err| format!("invalid standby replay lag_ms: {err}"))
            })
            .transpose()?,
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

/// Fetch native logical subscription status from a remote target node.
pub(crate) fn fetch_native_subscription_status(
    dsn: &str,
    subscription_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<NativeSubscriptionStatus, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let subscription_name = sql_literal(subscription_name);
    let result = conn.exec(&format!(
        "SELECT s.subenabled::text, \
                s.oid::bigint::text, \
                s.subslotname::text, \
                COALESCE(to_json(s.subpublications)::text, '[]') AS publications_json, \
                ('pg_' || s.oid::text) AS origin_name \
         FROM pg_subscription s \
         JOIN pg_database d ON d.oid = s.subdbid \
         WHERE s.subname = {subscription_name}::name \
           AND d.datname = current_database()"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 5 {
        return Err(format!(
            "expected one native subscription status row with 5 columns, got {} row(s) and {} column(s)",
            result.ntuples(),
            result.nfields()
        ));
    }

    Ok(NativeSubscriptionStatus {
        enabled: parse_bool(&result.value(0, 0)?)?,
        subid: result
            .value(0, 1)?
            .parse::<i64>()
            .map_err(|err| format!("invalid native subscription oid: {err}"))?,
        slot_name: result.value_opt(0, 2)?,
        publications_json: result.value(0, 3)?,
        origin_name: result.value(0, 4)?,
    })
}

/// Fetch pglogical per-table synchronization state from a remote subscriber.
pub(crate) fn fetch_pglogical_table_sync_status(
    dsn: &str,
    subscription_name: &str,
    schema_name: &str,
    table_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<TableSyncStatus, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let subscription_name = sql_literal(subscription_name);
    let schema_name = sql_literal(schema_name);
    let table_name = sql_literal(table_name);
    let result = conn.exec(&format!(
        "SELECT sync_status::text, sync_statuslsn::text \
         FROM pglogical.local_sync_status lss \
         JOIN pglogical.subscription s ON s.sub_id = lss.sync_subid \
         WHERE s.sub_name = {subscription_name}::name \
           AND lss.sync_nspname = {schema_name}::name \
           AND lss.sync_relname = {table_name}::name \
         ORDER BY lss.sync_statuslsn DESC NULLS LAST \
         LIMIT 1"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 2 {
        return Err(format!(
            "expected two pglogical table sync status columns, got {}",
            result.nfields()
        ));
    }
    if result.ntuples() == 0 {
        return Ok(TableSyncStatus {
            sync_status: Some("r".to_string()),
            sync_status_lsn: None,
        });
    }
    if result.ntuples() != 1 {
        return Err(format!(
            "expected at most one pglogical table sync status row, got {}",
            result.ntuples()
        ));
    }

    Ok(TableSyncStatus {
        sync_status: result.value_opt(0, 0)?,
        sync_status_lsn: result
            .value_opt(0, 1)?
            .map(|value| parse_lsn(&value))
            .transpose()?,
    })
}

/// Fetch native logical per-table synchronization state from a remote subscriber.
pub(crate) fn fetch_native_table_sync_status(
    dsn: &str,
    subscription_name: &str,
    schema_name: &str,
    table_name: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<TableSyncStatus, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let subscription_name = sql_literal(subscription_name);
    let schema_name = sql_literal(schema_name);
    let table_name = sql_literal(table_name);
    let result = conn.exec(&format!(
        "WITH rel AS ( \
             SELECT to_regclass(format('%I.%I', {schema_name}, {table_name})) AS oid \
         ) \
         SELECT sr.srsubstate::text \
         FROM pg_subscription s \
         JOIN pg_subscription_rel sr ON sr.srsubid = s.oid \
         JOIN rel ON rel.oid = sr.srrelid \
         JOIN pg_database d ON d.oid = s.subdbid \
         WHERE s.subname = {subscription_name}::name \
           AND d.datname = current_database()"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 1 {
        return Err(format!(
            "expected one native table sync status column, got {}",
            result.nfields()
        ));
    }
    if result.ntuples() == 0 {
        return Ok(TableSyncStatus {
            sync_status: None,
            sync_status_lsn: None,
        });
    }
    if result.ntuples() != 1 {
        return Err(format!(
            "expected at most one native table sync status row, got {}",
            result.ntuples()
        ));
    }

    Ok(TableSyncStatus {
        sync_status: result.value_opt(0, 0)?,
        sync_status_lsn: None,
    })
}

/// Fetch enabled pglogical subscriptions that forward all origins for a provider.
pub(crate) fn fetch_forwarding_subscriptions(
    dsn: &str,
    provider_node: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<Vec<ForwardingSubscription>, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let provider_node = sql_literal(provider_node);
    let result = conn.exec(&format!(
        "SELECT s.sub_name::text \
         FROM pglogical.subscription AS s \
         JOIN pglogical.node AS provider \
           ON provider.node_id = s.sub_origin \
         WHERE s.sub_enabled \
           AND provider.node_name::text = {provider_node} \
           AND 'all' = ANY (s.sub_forward_origins) \
         ORDER BY s.sub_name::text"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 1 {
        return Err(format!(
            "expected one pglogical forwarding-subscription column, got {}",
            result.nfields()
        ));
    }

    let mut subscriptions = Vec::with_capacity(result.ntuples() as usize);
    for row in 0..result.ntuples() {
        subscriptions.push(ForwardingSubscription {
            subscription_name: result.value(row, 0)?,
        });
    }
    Ok(subscriptions)
}

/// Fetch pglogical conflict-history rows for one subscription and relation.
pub(crate) fn fetch_conflict_history(
    dsn: &str,
    subscription_name: &str,
    schema_name: &str,
    table_name: &str,
    since: &str,
    max_rows: i32,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<Vec<ConflictHistoryRow>, String> {
    if max_rows <= 0 {
        return Err("max_rows must be greater than zero".to_string());
    }

    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;

    let available = conn.exec("SELECT to_regclass('pglogical.conflict_history') IS NOT NULL")?;
    if !parse_bool(&available.single_value()?)? {
        return Ok(Vec::new());
    }

    let subscription_name = sql_literal(subscription_name);
    let schema_name = sql_literal(schema_name);
    let table_name = sql_literal(table_name);
    let since = sql_literal(since);
    let result = conn.exec(&format!(
        "SELECT id::bigint::text, \
                recorded_at::text, \
                sub_name::text, \
                conflict_type::text, \
                resolution::text, \
                index_name::text, \
                local_tuple::text, \
                local_xid::text, \
                local_origin::int::text, \
                local_commit_ts::text, \
                remote_tuple::text, \
                remote_origin::int::text, \
                remote_commit_ts::text, \
                remote_commit_lsn::text, \
                has_before_triggers::text \
         FROM pglogical.conflict_history \
         WHERE sub_name = {subscription_name}::name \
           AND schema_name = {schema_name}::name \
           AND table_name = {table_name}::name \
           AND recorded_at >= {since}::timestamptz \
         ORDER BY recorded_at DESC, id DESC \
         LIMIT {max_rows}"
    ))?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 15 {
        return Err(format!(
            "expected 15 pglogical conflict-history columns, got {}",
            result.nfields()
        ));
    }

    let mut rows = Vec::with_capacity(result.ntuples() as usize);
    for row in 0..result.ntuples() {
        let conflict_id = result
            .value(row, 0)?
            .parse::<i64>()
            .map_err(|err| format!("invalid pglogical conflict id: {err}"))?;
        let local_origin = result
            .value_opt(row, 8)?
            .map(|value| {
                value
                    .parse::<i32>()
                    .map_err(|err| format!("invalid pglogical local_origin: {err}"))
            })
            .transpose()?;
        let remote_origin = result
            .value(row, 11)?
            .parse::<i32>()
            .map_err(|err| format!("invalid pglogical remote_origin: {err}"))?;

        rows.push(ConflictHistoryRow {
            conflict_id,
            recorded_at: result.value(row, 1)?,
            subscription_name: result.value_opt(row, 2)?,
            conflict_type: result.value(row, 3)?,
            resolution: result.value(row, 4)?,
            index_name: result.value_opt(row, 5)?,
            local_tuple_json: result.value_opt(row, 6)?,
            local_xid: result.value_opt(row, 7)?,
            local_origin,
            local_commit_ts: result.value_opt(row, 9)?,
            remote_tuple_json: result.value_opt(row, 10)?,
            remote_origin,
            remote_commit_ts: result.value(row, 12)?,
            remote_commit_lsn: parse_lsn(&result.value(row, 13)?)?,
            has_before_triggers: parse_bool(&result.value(row, 14)?)?,
        });
    }

    Ok(rows)
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
    conn.exec_command("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY")?;
    let checksum = match conn
        .exec(&checksum_wrapper_sql(checksum_sql))
        .and_then(|result| parse_checksum_result(&result))
    {
        Ok(checksum) => checksum,
        Err(err) => {
            let _ = conn.exec_command("ROLLBACK");
            return Err(err);
        }
    };
    if let Err(err) = conn.exec_command("COMMIT") {
        let _ = conn.exec_command("ROLLBACK");
        return Err(err);
    }

    Ok(checksum)
}

/// Run generated checksum SQL requests concurrently over bounded libpq fan-out.
pub(crate) fn fetch_checksums_batch(
    tasks: Vec<RemoteChecksumTask>,
    max_parallel: i32,
) -> Result<Vec<RemoteChecksumBatchResult>, String> {
    if max_parallel <= 0 {
        return Err("max_parallel must be greater than zero".to_string());
    }

    let mut pending = tasks.into_iter();
    let mut active = Vec::<ActiveChecksumTask>::new();
    let mut results = Vec::<RemoteChecksumBatchResult>::new();
    let max_parallel = max_parallel as usize;

    loop {
        while active.len() < max_parallel {
            let Some(task) = pending.next() else {
                break;
            };
            active.push(ActiveChecksumTask::start(task)?);
        }

        if active.is_empty() {
            break;
        }

        let mut index = 0;
        let mut made_progress = false;
        while index < active.len() {
            match active[index].try_finish()? {
                Some(result) => {
                    results.push(result);
                    active.swap_remove(index);
                    made_progress = true;
                }
                None => {
                    index += 1;
                }
            }
        }

        if !made_progress {
            wait_for_remote_input(&active)?;
        }
    }

    results.sort_by_key(|result| result.task_id);
    Ok(results)
}

struct ActiveChecksumTask {
    task: RemoteChecksumTask,
    conn: Connection,
    checksum: Option<RemoteChecksum>,
}

impl ActiveChecksumTask {
    fn start(task: RemoteChecksumTask) -> Result<Self, String> {
        if task.task_id <= 0 {
            return Err("remote checksum batch task_id must be greater than zero".to_string());
        }

        let conn = Connection::connect_with_timeout(&task.dsn, task.connect_timeout_seconds)?;
        conn.set_query_timeouts(task.statement_timeout_ms, task.lock_timeout_ms)?;
        conn.set_nonblocking(true)?;
        conn.send_query(&checksum_transaction_sql(&task.checksum_sql))?;

        Ok(Self {
            task,
            conn,
            checksum: None,
        })
    }

    fn try_finish(&mut self) -> Result<Option<RemoteChecksumBatchResult>, String> {
        loop {
            self.conn.consume_input()?;
            if self.conn.is_busy() {
                return Ok(None);
            }

            let Some(result) = self.conn.next_result() else {
                let Some(checksum) = self.checksum.take() else {
                    return Err(format!(
                        "remote checksum batch task {} completed without a result",
                        self.task.task_id
                    ));
                };

                return Ok(Some(RemoteChecksumBatchResult {
                    task_id: self.task.task_id,
                    checksum,
                }));
            };

            match result.status() {
                PGRES_COMMAND_OK => {}
                PGRES_TUPLES_OK => {
                    if self.checksum.is_some() {
                        return Err(format!(
                            "remote checksum batch task {} returned more than one tuple result",
                            self.task.task_id
                        ));
                    }

                    self.checksum = Some(parse_checksum_result(&result)?);
                }
                status => {
                    return Err(format!(
                        "remote checksum batch task {} returned libpq status {status}: {}",
                        self.task.task_id,
                        result.error_message()
                    ));
                }
            }
        }
    }
}

fn checksum_transaction_sql(checksum_sql: &str) -> String {
    format!(
        "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY; {}; COMMIT",
        checksum_wrapper_sql(checksum_sql)
    )
}

fn checksum_wrapper_sql(checksum_sql: &str) -> String {
    format!(
        "SELECT current_setting('server_version_num')::int::text, \
                q.n_rows::bigint::text, \
                encode(q.lthash, 'hex'), \
                encode(q.set_hash, 'hex') \
         FROM ({checksum_sql}) AS q"
    )
}

fn parse_checksum_result(result: &QueryResult) -> Result<RemoteChecksum, String> {
    result.require_status(PGRES_TUPLES_OK)?;

    if result.ntuples() != 1 || result.nfields() != 4 {
        return Err(format!(
            "remote checksum returned {} row(s) and {} column(s), expected 1 row and 4 columns",
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
    let set_hash = result
        .value_opt(0, 3)?
        .map(|value| parse_hex(&value))
        .transpose()?;

    Ok(RemoteChecksum {
        pg_version,
        n_rows,
        lthash,
        set_hash,
    })
}

/// Run generated schema-signature SQL on a remote participant.
pub(crate) fn fetch_schema_signature(
    dsn: &str,
    signature_sql: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<RemoteSchemaSignature, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;
    let wrapped_sql = format!(
        "SELECT current_setting('server_version_num')::int::text, \
                q.signature::text \
         FROM ({signature_sql}) AS q"
    );

    let result = conn.exec(&wrapped_sql)?;
    result.require_status(PGRES_TUPLES_OK)?;

    if result.ntuples() != 1 || result.nfields() != 2 {
        return Err(format!(
            "remote schema signature returned {} row(s) and {} column(s), expected 1 row and 2 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    let pg_version = result
        .value(0, 0)?
        .parse::<i32>()
        .map_err(|err| format!("invalid remote server_version_num: {err}"))?;
    let signature = result.value(0, 1)?;

    Ok(RemoteSchemaSignature {
        pg_version,
        signature,
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
                encode(q.row_digest, 'hex'), \
                q.row_json \
         FROM ({localization_sql}) AS q"
    );

    let result = conn.exec(&wrapped_sql)?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.nfields() != 4 {
        return Err(format!(
            "remote localization returned {} column(s), expected 4",
            result.nfields()
        ));
    }

    let mut rows = Vec::with_capacity(result.ntuples() as usize);
    for row in 0..result.ntuples() {
        rows.push(LocalizedRowDigest {
            key_text: result.value(row, 0)?,
            key_bytes: parse_hex(&result.value(row, 1)?)?,
            row_digest: parse_hex(&result.value(row, 2)?)?,
            row_json: result.value(row, 3)?,
        });
    }

    Ok(rows)
}

/// Run generated sequence SQL on a remote participant.
pub(crate) fn fetch_sequence_value(
    dsn: &str,
    sequence_sql: &str,
    connect_timeout_seconds: i32,
    statement_timeout_ms: i32,
    lock_timeout_ms: i32,
) -> Result<RemoteSequenceValue, String> {
    let conn = Connection::connect_with_timeout(dsn, connect_timeout_seconds)?;
    conn.set_query_timeouts(statement_timeout_ms, lock_timeout_ms)?;
    let wrapped_sql = format!(
        "SELECT current_setting('server_version_num')::int::text, \
                q.last_value::bigint::text \
         FROM ({sequence_sql}) AS q"
    );

    let result = conn.exec(&wrapped_sql)?;
    result.require_status(PGRES_TUPLES_OK)?;
    if result.ntuples() != 1 || result.nfields() != 2 {
        return Err(format!(
            "remote sequence query returned {} row(s) and {} column(s), expected 1 row and 2 columns",
            result.ntuples(),
            result.nfields()
        ));
    }

    let pg_version = result
        .value(0, 0)?
        .parse::<i32>()
        .map_err(|err| format!("invalid remote server_version_num: {err}"))?;
    let last_value = result
        .value(0, 1)?
        .parse::<i64>()
        .map_err(|err| format!("invalid remote sequence last_value: {err}"))?;

    Ok(RemoteSequenceValue {
        pg_version,
        last_value,
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

/// Format a PostgreSQL LSN value using canonical hexadecimal text.
pub(crate) fn format_lsn(lsn: u64) -> String {
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
