//! PostgreSQL-version compatibility helpers.

use pgrx::pg_sys;
use std::ffi::c_int;

/// Create a wait-event set using the owner argument expected by the active PG major.
///
/// PostgreSQL 15 and 16 allocate wait-event sets under a memory context; newer
/// majors attach them to the current resource owner.
pub(crate) unsafe fn create_wait_event_set(event_count: c_int) -> *mut pg_sys::WaitEventSet {
    #[cfg(any(feature = "pg15", feature = "pg16"))]
    {
        unsafe { pg_sys::CreateWaitEventSet(pg_sys::CurrentMemoryContext, event_count) }
    }

    #[cfg(not(any(feature = "pg15", feature = "pg16")))]
    {
        unsafe { pg_sys::CreateWaitEventSet(pg_sys::CurrentResourceOwner, event_count) }
    }
}
