//! Background-worker orchestration for asynchronous validation runs.

use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, SignalWakeFlags};
use pgrx::prelude::*;
use std::time::{Duration, Instant};

fn sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// Launch a dynamic PostgreSQL background worker for one queued task.
pub(crate) fn launch_worker_task(task_id: i32) -> i32 {
    if task_id <= 0 {
        pgrx::error!("worker task id must be positive");
    }

    let database_name = Spi::get_one::<String>("SELECT current_database()::text")
        .unwrap_or_else(|err| pgrx::error!("could not read current database: {err}"))
        .unwrap_or_else(|| pgrx::error!("current_database() returned NULL"));

    let worker = BackgroundWorkerBuilder::new("pgl_validate run worker")
        .set_library("pgl_validate")
        .set_function("pgl_validate_worker_main")
        .set_argument(task_id.into_datum())
        .set_extra(&database_name)
        .enable_spi_access()
        .set_notify_pid(unsafe { pg_sys::MyProcPid })
        .load_dynamic()
        .unwrap_or_else(|_| pgrx::error!("could not start pgl_validate background worker"));

    worker.wait_for_startup().unwrap_or_else(|status| {
        pgrx::error!("pgl_validate background worker did not start: {status:?}")
    })
}

/// Entry point for a dynamic validation worker launched by `launch_worker_task`.
#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pgl_validate_worker_main(arg: pg_sys::Datum) {
    let task_id = unsafe { i32::from_datum(arg, false) };
    let Some(task_id) = task_id else {
        log!("pgl_validate worker received a NULL task id");
        return;
    };

    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some(BackgroundWorker::get_extra()), None);

    if !wait_for_task_claim(task_id) {
        return;
    }

    if !BackgroundWorker::wait_latch(Some(Duration::from_millis(1))) {
        mark_task_failed(task_id, "worker terminated before task execution");
        return;
    }

    let result = run_worker_task(task_id);

    if let Err(err) = result {
        mark_task_failed(task_id, &err);
    }
}

fn run_worker_task(task_id: i32) -> Result<(), String> {
    let Some(tables_json) = explicit_table_list_json(task_id)? else {
        return BackgroundWorker::transaction(|| {
            Spi::run(&format!("SELECT pgl_validate._run_worker_task({task_id})"))
        })
        .map_err(|err| format!("worker task execution failed: {err}"));
    };

    let table_names: Vec<String> = serde_json::from_str(&tables_json)
        .map_err(|err| format!("could not decode worker task table list: {err}"))?;
    if table_names.is_empty() {
        return BackgroundWorker::transaction(|| {
            Spi::run(&format!("SELECT pgl_validate._run_worker_task({task_id})"))
        })
        .map_err(|err| format!("worker task execution failed: {err}"));
    }

    for (index, table_name) in table_names.iter().enumerate() {
        run_one_table(task_id, table_name)?;
        maybe_fail_once_after_table(task_id, index + 1)?;
    }

    finish_explicit_table_task(task_id)
}

fn explicit_table_list_json(task_id: i32) -> Result<Option<String>, String> {
    BackgroundWorker::transaction(|| {
        Spi::get_one::<String>(&format!(
            "
            SELECT CASE
                WHEN NULLIF(wt.request->>'repset', '') IS NULL
                 AND jsonb_typeof(wt.request->'tables') = 'array'
                 AND jsonb_array_length(wt.request->'tables') > 0
                THEN (
                    SELECT jsonb_agg(t.table_name ORDER BY t.ordinality)::text
                    FROM jsonb_array_elements_text(wt.request->'tables')
                         WITH ORDINALITY AS t(table_name, ordinality)
                )
                ELSE NULL::text
            END
            FROM pgl_validate.worker_task wt
            WHERE wt.task_id = {task_id}
            "
        ))
    })
    .map_err(|err| format!("could not read worker task request: {err}"))
}

fn run_one_table(task_id: i32, table_name: &str) -> Result<(), String> {
    let table_name = sql_literal(table_name);

    BackgroundWorker::transaction(|| {
        Spi::run(&format!(
            "
            WITH task AS (
                SELECT wt.run_id, wt.request
                FROM pgl_validate.worker_task wt
                WHERE wt.task_id = {task_id}
            )
            SELECT pgl_validate.compare(
                ARRAY[{table_name}::regclass],
                NULL::text,
                (
                    SELECT array_agg(peer.name ORDER BY peer.ordinality)
                    FROM task,
                         jsonb_array_elements_text(
                             CASE
                                 WHEN jsonb_typeof(task.request->'peers') = 'array'
                                 THEN task.request->'peers'
                                 ELSE '[]'::jsonb
                             END
                         ) WITH ORDINALITY AS peer(name, ordinality)
                ),
                NULLIF(task.request->>'reference', ''),
                (
                    COALESCE(task.request->'options', '{{}}'::jsonb)
                    - '_pgl_validate_worker_fail_once_after_tables'
                ) || jsonb_build_object(
                    'async', true,
                    '_pgl_validate_parent_run_id', task.run_id,
                    '_pgl_validate_keep_parent_open', true
                )
            )
            FROM task
            "
        ))
    })
    .map_err(|err| format!("worker task table {table_name} failed: {err}"))
}

fn maybe_fail_once_after_table(task_id: i32, completed_tables: usize) -> Result<(), String> {
    let fail_after = BackgroundWorker::transaction(|| {
        Spi::get_one::<i32>(&format!(
            "
            SELECT NULLIF(
                       wt.request->'options'->>'_pgl_validate_worker_fail_once_after_tables',
                       ''
                   )::int
            FROM pgl_validate.worker_task wt
            WHERE wt.task_id = {task_id}
            "
        ))
    })
    .map_err(|err| format!("could not read worker failure-injection option: {err}"))?;

    if fail_after != Some(completed_tables as i32) {
        return Ok(());
    }

    BackgroundWorker::transaction(|| {
        Spi::run(&format!(
            "
            UPDATE pgl_validate.worker_task wt
            SET request = jsonb_set(
                wt.request,
                '{{options}}',
                COALESCE(wt.request->'options', '{{}}'::jsonb)
                    - '_pgl_validate_worker_fail_once_after_tables',
                true
            )
            WHERE wt.task_id = {task_id}
            "
        ))
    })
    .map_err(|err| format!("could not clear worker failure-injection option: {err}"))?;

    Err(format!(
        "worker task execution failed after committing {completed_tables} table(s)"
    ))
}

fn finish_explicit_table_task(task_id: i32) -> Result<(), String> {
    BackgroundWorker::transaction(|| {
        Spi::run(&format!(
            "
            WITH task AS (
                SELECT wt.run_id, wt.request
                FROM pgl_validate.worker_task wt
                WHERE wt.task_id = {task_id}
            ),
            table_count AS (
                SELECT count(*)::int AS n_tables
                FROM task,
                     jsonb_array_elements_text(task.request->'tables') AS t(table_name)
            ),
            finished_run AS (
                UPDATE pgl_validate.run r
                SET status = 'completed',
                    finished_at = clock_timestamp(),
                    tables_total = table_count.n_tables,
                    tables_matched = (
                        SELECT count(*)::int
                        FROM pgl_validate.table_result tr
                        WHERE tr.run_id = r.run_id
                          AND tr.verdict = 'match'
                    ),
                    tables_differ = (
                        SELECT count(*)::int
                        FROM pgl_validate.table_result tr
                        WHERE tr.run_id = r.run_id
                          AND tr.verdict = 'differ'
                    ),
                    error = NULL
                FROM task, table_count
                WHERE r.run_id = task.run_id
                  AND r.status <> 'canceled'
                RETURNING r.run_id
            ),
            participants AS (
                UPDATE pgl_validate.run_participant rp
                SET status = 'done'
                FROM finished_run fr
                WHERE rp.run_id = fr.run_id
                  AND rp.status NOT IN ('unreachable','error')
                RETURNING 1
            )
            UPDATE pgl_validate.worker_task wt
            SET status = 'completed',
                finished_at = clock_timestamp(),
                error = NULL
            FROM finished_run fr
            WHERE wt.task_id = {task_id}
              AND wt.run_id = fr.run_id
            "
        ))
    })
    .map_err(|err| format!("could not finish explicit-table worker task: {err}"))
}

fn wait_for_task_claim(task_id: i32) -> bool {
    let deadline = Instant::now() + Duration::from_secs(30);

    loop {
        let claim = BackgroundWorker::transaction(|| {
            Spi::get_one::<bool>(&format!(
                "SELECT pgl_validate._claim_worker_task({task_id})"
            ))
        });

        match claim {
            Ok(Some(true)) => return true,
            Ok(Some(false)) => return false,
            Ok(None) => {
                if Instant::now() >= deadline {
                    log!("pgl_validate worker could not see task {task_id} before startup timeout");
                    return false;
                }
                if !BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
                    return false;
                }
            }
            Err(err) => {
                if Instant::now() >= deadline {
                    log!("pgl_validate worker could not claim task {task_id}: {err}");
                    return false;
                }
                if !BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
                    return false;
                }
            }
        }
    }
}

fn mark_task_failed(task_id: i32, message: &str) {
    let message = sql_literal(message);
    let _ = BackgroundWorker::transaction(|| {
        Spi::run(&format!(
            "
            WITH task AS (
                UPDATE pgl_validate.worker_task
                SET status = 'failed',
                    finished_at = clock_timestamp(),
                    error = {message}
                WHERE task_id = {task_id}
                RETURNING run_id
            )
            UPDATE pgl_validate.run r
            SET status = 'failed',
                finished_at = clock_timestamp(),
                error = {message}
            FROM task
            WHERE r.run_id = task.run_id
              AND r.status <> 'canceled'
            "
        ))
    });
}
