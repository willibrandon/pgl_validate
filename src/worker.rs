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

    let result = BackgroundWorker::transaction(|| {
        Spi::run(&format!("SELECT pgl_validate._run_worker_task({task_id})"))
    });

    if let Err(err) = result {
        mark_task_failed(task_id, &format!("worker task execution failed: {err}"));
    }
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
            Ok(_) => return false,
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
