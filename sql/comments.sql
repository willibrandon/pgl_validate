COMMENT ON SCHEMA pgl_validate IS
    'Cross-node data validation objects for pglogical-first replication topologies.';

COMMENT ON TABLE pgl_validate.peer IS
    'Named connection targets, replication-set metadata, and remote-query timeouts used by the coordinator when resolving peers.';
COMMENT ON COLUMN pgl_validate.peer.reverse_subscription_name IS
    'Explicit local pglogical subscription from this peer back to the coordinator, used to include bidirectional reverse edges in the fence vector.';
COMMENT ON TABLE pgl_validate.run IS
    'One validation run, including lifecycle state and summary counts.';
COMMENT ON TABLE pgl_validate.run_participant IS
    'Per-run participant metadata and connection status.';
COMMENT ON TABLE pgl_validate.fence_epoch IS
    'Barrier-converged epoch identifier for a validation run.';
COMMENT ON TABLE pgl_validate.run_edge IS
    'Directed replication edge identity for provider-to-target validation.';
COMMENT ON TABLE pgl_validate.fence_edge IS
    'Per-edge fence target recorded for an epoch.';
COMMENT ON TABLE pgl_validate.fence_attempt IS
    'Observed convergence state for a fenced edge.';
COMMENT ON TABLE pgl_validate.fence_barrier IS
    'Replicated, non-unique barrier-token table carried by the dedicated barrier repset.';
COMMENT ON TABLE pgl_validate.fence_barrier_run IS
    'Coordinator-local linkage between a barrier token and the run edge that injected it.';
COMMENT ON TABLE pgl_validate.table_plan IS
    'Per-table validation plan and replication contract selected for a run.';
COMMENT ON TABLE pgl_validate.table_result IS
    'Per-table validation verdict for a run.';
COMMENT ON TABLE pgl_validate.table_node_result IS
    'Per-node checksum result for a validated table.';
COMMENT ON TABLE pgl_validate.chunk_result IS
    'Merkle chunk state used while localizing table divergences.';
COMMENT ON TABLE pgl_validate.chunk_node_result IS
    'Per-node checksum result for a Merkle chunk.';
COMMENT ON TABLE pgl_validate.divergence IS
    'Candidate and confirmed key-level divergences found during validation.';
COMMENT ON TABLE pgl_validate.divergence_recheck IS
    'Digest-stability recheck history for a divergent key.';
COMMENT ON TABLE pgl_validate.conflict_evidence IS
    'Optional pglogical conflict-history evidence correlated to confirmed divergences.';
COMMENT ON TABLE pgl_validate.sequence_result IS
    'Sequence validation result using pglogical sequence-window semantics.';
COMMENT ON TABLE pgl_validate.schema_issue IS
    'Schema, privilege, or contract issues discovered during planning.';
COMMENT ON TABLE pgl_validate.schedule IS
    'Persisted validation schedule definitions.';
COMMENT ON TABLE pgl_validate.worker_task IS
    'Durable background-worker task queue for asynchronous validation orchestration.';
COMMENT ON TABLE pgl_validate.repair_run IS
    'Audited repair execution state.';
COMMENT ON TABLE pgl_validate.repair_result IS
    'Per-key outcome from a repair run.';

COMMENT ON VIEW pgl_validate.runs IS
    'Reporting view over validation runs.';
COMMENT ON VIEW pgl_validate.run_progress IS
    'Reporting view with phase, current epoch, chunk completion, scan counters, and ETA per run.';
COMMENT ON VIEW pgl_validate.table_results IS
    'Reporting view over table verdicts.';
COMMENT ON VIEW pgl_validate.chunk_results IS
    'Reporting view over Merkle chunk states.';
COMMENT ON VIEW pgl_validate.divergences IS
    'Reporting view over key-level divergences.';
COMMENT ON VIEW pgl_validate.sequence_results IS
    'Reporting view over sequence validation results.';
COMMENT ON VIEW pgl_validate.schema_issues IS
    'Reporting view over planning and schema issues.';
COMMENT ON VIEW pgl_validate.worker_tasks IS
    'Reporting view over asynchronous validation worker tasks.';

COMMENT ON FUNCTION pgl_validate.column_encoding_mode(oid) IS
    'Select the coordinator-pushed row_digest encoding mode for a column type.';
COMMENT ON FUNCTION pgl_validate.comparison_key_cols(regclass) IS
    'Select the replica-identity, primary-key, or safe unique-index columns used for row-level divergence localization.';
COMMENT ON FUNCTION pgl_validate.pglogical_table_contract(regclass, text[], name) IS
    'Resolve pglogical action masks, effective column list, exact filter predicate, sync state, and validated property for a relation.';
COMMENT ON FUNCTION pgl_validate.native_table_contract(regclass, text[], name) IS
    'Resolve native logical publication actions, effective column list, exact row filter, sync state, and validated property for a relation.';
COMMENT ON FUNCTION pgl_validate.ensure_pglogical_barrier_repset() IS
    'Create or verify the dedicated insert-only pglogical replication set that carries fence barrier tokens.';
COMMENT ON FUNCTION pgl_validate.ensure_native_barrier_publication(text) IS
    'Create or verify the dedicated insert-only native logical publication that carries fence barrier tokens.';
COMMENT ON FUNCTION pgl_validate.fence_pglogical_edge(bigint, integer, integer, text, text, text, text, text, text, text, text[], integer, integer, integer, integer, integer) IS
    'Inject and converge an exact pglogical barrier for one provider-to-target run edge.';
COMMENT ON FUNCTION pgl_validate.fence_native_edge(bigint, integer, integer, text, text, text, text, text, text, text, text[], integer, integer, integer, integer, integer) IS
    'Inject and converge an exact native logical barrier for one provider-to-target run edge.';
COMMENT ON FUNCTION pgl_validate.fence_pglogical_degraded_edge(bigint, integer, integer, text, text, text, text, text, text, text[], integer, integer, integer) IS
    'Persist an explicitly degraded pglogical fence when a barrier cannot be carried on the edge.';
COMMENT ON FUNCTION pgl_validate.fence_native_degraded_edge(bigint, integer, integer, text, text, text, text, text, text, text[], integer, integer, integer, integer, integer) IS
    'Persist an explicitly degraded native logical fence when a barrier cannot be carried on the edge.';
COMMENT ON FUNCTION pgl_validate.fence_standby_edge(bigint, integer, integer, text, text, text, pg_lsn, integer, integer, integer, integer, integer) IS
    'Converge one physical standby edge by waiting for replay to reach a primary WAL LSN.';
COMMENT ON FUNCTION pgl_validate.plan_key_range_predicate(regclass, text[], bytea, bytea) IS
    'Generate an indexable key-column range predicate from UTF-8 JSON boundary bytes.';
COMMENT ON FUNCTION pgl_validate.plan_key_ranges(regclass, text[], bytea, bytea, integer, text) IS
    'Plan ordered key ranges as bytea JSON boundaries for Merkle chunk validation.';
COMMENT ON FUNCTION pgl_validate.schema_signature(text, text, text[], text[]) IS
    'Build a deterministic JSON signature for the compared relation columns, key columns, type identity, and collation metadata.';
COMMENT ON FUNCTION pgl_validate.plan_schema_signature_sql(text, text, text[], text[]) IS
    'Generate remote SQL that returns a relation contract schema_signature without failing on a missing remote relation.';
COMMENT ON FUNCTION pgl_validate.plan_chunk_sql(regclass, text[], bytea, bytea, text[], text[], text, boolean, text) IS
    'Generate planner-visible SQL for a table chunk checksum and optional cryptographic set confirmation.';
COMMENT ON FUNCTION pgl_validate.plan_pglogical_filtered_sql(regclass, text[], text[], boolean, text) IS
    'Generate diagnostic-only checksum SQL using pglogical.table_data_filtered for session-sensitive row filters.';
COMMENT ON FUNCTION pgl_validate.plan_localize_sql(regclass, text[], bytea, bytea, text[], text, text) IS
    'Generate planner-visible SQL for key and row-digest enumeration within a bounded divergent range.';
COMMENT ON FUNCTION pgl_validate.plan_localize_sql(regclass, text[], text[], text, text) IS
    'Generate planner-visible SQL for unbounded key and row-digest enumeration during divergence localization.';
COMMENT ON FUNCTION pgl_validate.plan_sequence_sql(regclass) IS
    'Generate planner-visible SQL for reading a sequence last_value on a participant.';
COMMENT ON FUNCTION pgl_validate.compare(regclass[], text, text[], text, jsonb) IS
    'Run a validation over explicit tables, a pglogical replication set including its sequences, or auto-discovered local relations and return the parent run id.';
COMMENT ON FUNCTION pgl_validate.reported_tuple_json(jsonb, integer) IS
    'Return a divergent tuple payload, or a bounded truncation marker when it exceeds max_reported_tuple_bytes.';
COMMENT ON FUNCTION pgl_validate.classify_recheck_outcome(bytea, bytea, bytea, bytea) IS
    'Classify one digest-stability recheck as cleared, still_differs, or still_hot from previous and current row digests.';
COMMENT ON FUNCTION pgl_validate.compare_table(regclass, text[], jsonb) IS
    'Run the current table comparison path and return the persisted table verdict.';
COMMENT ON FUNCTION pgl_validate.compare_sequence(regclass, text[], jsonb) IS
    'Validate one sequence against peers using the pglogical sequence buffer-window contract.';
COMMENT ON FUNCTION pgl_validate.cancel(bigint) IS
    'Mark an active validation run canceled and finish it without deleting its audit rows.';
COMMENT ON FUNCTION pgl_validate.pause(bigint) IS
    'Move an active validation run into paused state for later resume.';
COMMENT ON FUNCTION pgl_validate.resume(bigint) IS
    'Resume a paused run; when a durable async worker task is paused, failed, or stale, requeue it and launch a replacement dynamic worker.';
COMMENT ON FUNCTION pgl_validate.put_schedule(text, text, text[], text, text[], jsonb, boolean) IS
    'Create or replace a durable validation schedule definition without launching it.';
COMMENT ON FUNCTION pgl_validate.set_schedule_enabled(text, boolean) IS
    'Enable or disable a durable validation schedule definition.';
COMMENT ON FUNCTION pgl_validate.delete_schedule(text) IS
    'Delete a durable validation schedule definition and leave any historical runs intact.';
COMMENT ON FUNCTION pgl_validate.run_schedule(text, boolean) IS
    'Dispatch a durable validation schedule through compare_async, record the launched run id, and return it.';
COMMENT ON FUNCTION pgl_validate.compare_async(regclass[], text, text[], text, jsonb) IS
    'Create a durable validation run, enqueue a compare task, launch a dynamic background worker, and return the run id immediately.';
COMMENT ON FUNCTION pgl_validate._claim_worker_task(integer) IS
    'Atomically mark a queued worker task running before the background worker executes it; returns NULL when a just-launched worker has not yet observed the enqueuing transaction.';
COMMENT ON FUNCTION pgl_validate._run_worker_task(integer) IS
    'Execute one claimed worker task and persist completed or failed state without hiding the run id from callers.';
COMMENT ON FUNCTION pgl_validate.purge(timestamptz) IS
    'Delete terminal validation runs older than the cutoff and clean unprotected local barrier tokens.';
COMMENT ON FUNCTION pgl_validate._repair_statements(bigint, text) IS
    'Build structured repair statements with target, key, lock, verification, and relation metadata for generate_repair and apply_repair.';
COMMENT ON FUNCTION pgl_validate.generate_repair(bigint, text) IS
    'Generate reviewable node-labeled DML and sequence setval statements for confirmed divergences using the selected authoritative node.';
COMMENT ON FUNCTION pgl_validate.apply_repair(bigint, text, text, text, text, boolean) IS
    'Apply target-labeled generated repair statements after explicit target confirmation, then run focused revalidation and record repair_run and repair_result audit rows.';
COMMENT ON FUNCTION pgl_validate.correlate_conflict_history(bigint, interval, integer) IS
    'Attach pglogical conflict-history rows to confirmed divergences when tuple JSON contains the divergent key.';
COMMENT ON FUNCTION pgl_validate.run_status(bigint) IS
    'Return the persisted state for a validation run.';
COMMENT ON FUNCTION pgl_validate.divergences(bigint) IS
    'Return persisted divergences for a validation run.';
COMMENT ON FUNCTION pgl_validate.conflict_evidence(bigint) IS
    'Return pglogical conflict-history evidence attached to a validation run.';
COMMENT ON FUNCTION pgl_validate.sequences(bigint) IS
    'Return persisted sequence results for a validation run.';
COMMENT ON FUNCTION pgl_validate.report(bigint) IS
    'Return a structured JSON validation report for one run, including plans, verdicts, divergences, sequences, fences, and issues.';
COMMENT ON FUNCTION pgl_validate.metrics() IS
    'Return aggregate validation counters, per-table last success, rows scanned, and recorded remote payload bytes as structured JSON.';
COMMENT ON FUNCTION pgl_validate.record_barrier_fence(bigint, integer, integer, uuid, text, pg_lsn) IS
    'Persist an exact barrier token and end LSN for one run edge and epoch.';
COMMENT ON FUNCTION pgl_validate.record_fence_attempt(bigint, integer, integer, pg_lsn, pg_lsn, boolean, pg_lsn, text) IS
    'Persist a fence convergence observation with status derived from origin progress and token visibility.';
COMMENT ON FUNCTION pgl_validate.protected_barrier_tokens() IS
    'Return barrier tokens referenced by unfinished validation runs.';
COMMENT ON FUNCTION pgl_validate.cleanup_fence_barriers(interval, uuid[]) IS
    'Delete unprotected expired barrier tokens from the local node.';

COMMENT ON FUNCTION pgl_validate.row_digest(integer[], "any") IS
    'Compute a canonical row digest from coordinator-selected encodings, VARIADIC values, and the active pgl_validate.hash_algorithm.';
COMMENT ON FUNCTION pgl_validate.last_commit_lsn() IS
    'Return the backend exact last commit end LSN for barrier fencing.';
COMMENT ON FUNCTION pgl_validate.hash_digest_array(bytea[]) IS
    'Hash a caller-sorted array of row digests for cryptographic set confirmation using the active pgl_validate.hash_algorithm.';
COMMENT ON FUNCTION pgl_validate.row_filter_tree_is_immutable(text) IS
    'Return whether a serialized PostgreSQL row-filter expression tree contains only immutable functions.';
COMMENT ON FUNCTION pgl_validate.remote_checksum(text, text, integer, integer, integer) IS
    'Execute generated checksum SQL on a named peer DSN via libpq, returning row count, LtHash, and optional set hash.';
COMMENT ON FUNCTION pgl_validate.remote_checksum_batch(jsonb, integer) IS
    'Execute generated checksum SQL tasks through bounded libpq fan-out for parallel chunk validation.';
COMMENT ON FUNCTION pgl_validate.remote_schema_signature(text, text, integer, integer, integer) IS
    'Execute generated schema-signature SQL on a named peer DSN via libpq, returning remote server version and signature text.';
COMMENT ON FUNCTION pgl_validate.remote_localize_rows(text, text, integer, integer, integer) IS
    'Execute generated row-localization SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts, returning key, digest, and row JSON.';
COMMENT ON FUNCTION pgl_validate.remote_sequence_value(text, text, integer, integer, integer) IS
    'Execute generated sequence SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_execute(text, text, integer, integer, integer) IS
    'Execute a generated SQL command batch on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
COMMENT ON FUNCTION pgl_validate.launch_worker_task(integer) IS
    'Launch a queued validation task in a PostgreSQL dynamic background worker and return its backend pid.';
COMMENT ON FUNCTION pgl_validate.remote_inject_barrier(text, integer, integer, integer) IS
    'Insert a barrier token on a remote origin over libpq and return the exact barrier commit end LSN.';
COMMENT ON FUNCTION pgl_validate.remote_wait_slot_confirm_lsn(text, text, pg_lsn, integer, integer, integer) IS
    'Call pglogical.wait_slot_confirm_lsn on a provider and return the slot confirmed_flush_lsn.';
COMMENT ON FUNCTION pgl_validate.remote_slot_confirmed_flush_lsn(text, text, integer, integer, integer) IS
    'Fetch a provider logical slot confirmed_flush_lsn without using pglogical-specific helpers.';
COMMENT ON FUNCTION pgl_validate.remote_logical_slot_lag(text, text, integer, integer, integer) IS
    'Fetch provider-side active state, time lag, and WAL-byte lag for a logical replication slot.';
COMMENT ON FUNCTION pgl_validate.remote_current_wal_lsn(text, integer, integer, integer) IS
    'Fetch a provider current WAL LSN for an explicitly degraded fence.';
COMMENT ON FUNCTION pgl_validate.remote_observe_barrier(text, text, uuid, pg_lsn, integer, integer, integer) IS
    'Observe target-side replication origin progress, barrier-token visibility, and convergence.';
COMMENT ON FUNCTION pgl_validate.remote_standby_replay_status(text, integer, integer, integer) IS
    'Fetch a remote participant''s recovery state, replay LSN, and replay-pause status.';
COMMENT ON FUNCTION pgl_validate.remote_standby_replay_lag(text, pg_lsn, integer, integer, integer) IS
    'Fetch physical-standby recovery state, replay LSN, and time lag relative to a primary WAL LSN.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_subscription_status(text, text, integer, integer, integer) IS
    'Fetch pglogical subscription status from a remote target over libpq with bounded timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_native_subscription_status(text, text, integer, integer, integer) IS
    'Fetch native logical subscription status from a remote target over libpq with bounded timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_table_sync_status(text, text, text, text, integer, integer, integer) IS
    'Fetch pglogical subscriber-side per-table synchronization state for a remote subscription.';
COMMENT ON FUNCTION pgl_validate.remote_native_table_sync_status(text, text, text, text, integer, integer, integer) IS
    'Fetch native logical subscriber-side per-table synchronization state for a remote subscription.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_forwarding_subscriptions(text, text, integer, integer, integer) IS
    'Fetch enabled pglogical subscriptions on a remote subscriber that would forward all origins for the named provider node.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_conflict_history(text, text, text, text, text, integer, integer, integer, integer) IS
    'Fetch pglogical conflict-history rows for one remote subscription and relation, returning typed text fields for catalog-side casting.';
COMMENT ON FUNCTION pgl_validate.throttle_replication_lag(bigint, text, text, text, text, int[], interval, integer, integer) IS
    'Pause a run while any exact logical or standby edge in the current edge vector exceeds the configured replication-lag threshold.';
COMMENT ON FUNCTION pgl_validate.re_fence_run_edges(bigint, integer, text, text, int[], integer, integer) IS
    'Re-fence the selected edge vector for an existing run and epoch without rediscovering topology.';
COMMENT ON TYPE pgl_validate.lthash_state IS
    'Internal varlena state for the LtHash multiset accumulator.';
COMMENT ON FUNCTION pgl_validate.lthash_state_in(cstring) IS
    'Input function for pgl_validate.lthash_state.';
COMMENT ON FUNCTION pgl_validate.lthash_state_out(pgl_validate.lthash_state) IS
    'Output function for pgl_validate.lthash_state.';
COMMENT ON FUNCTION pgl_validate.lthash_combine(pgl_validate.lthash_state, pgl_validate.lthash_state) IS
    'Combine two LtHash states.';
COMMENT ON FUNCTION pgl_validate.lthash_bytes(pgl_validate.lthash_state) IS
    'Serialize an LtHash state for catalog persistence.';
COMMENT ON FUNCTION pgl_validate.lthash_state_lthash_state_state(pgl_validate.lthash_state, bytea) IS
    'Transition function for the pgl_validate.lthash aggregate.';
COMMENT ON FUNCTION pgl_validate.lthash_state_lthash_state_finalize(pgl_validate.lthash_state) IS
    'Finalize function for the pgl_validate.lthash aggregate.';
COMMENT ON FUNCTION pgl_validate.lthash_state_lthash_state_combine(pgl_validate.lthash_state, pgl_validate.lthash_state) IS
    'Parallel combine function for the pgl_validate.lthash aggregate.';
COMMENT ON AGGREGATE pgl_validate.lthash(bytea) IS
    'Order-independent, duplicate-sensitive LtHash aggregate over row digests.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgl_validate_validate') THEN
        CREATE ROLE pgl_validate_validate NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgl_validate_discover') THEN
        CREATE ROLE pgl_validate_discover NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgl_validate_orchestrate') THEN
        CREATE ROLE pgl_validate_orchestrate NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgl_validate_repair') THEN
        CREATE ROLE pgl_validate_repair NOLOGIN;
    END IF;
END
$$;

COMMENT ON ROLE pgl_validate_validate IS
    'pgl_validate T1 role: run node-local digest and set-hash primitives against tables the caller can already read.';
COMMENT ON ROLE pgl_validate_discover IS
    'pgl_validate T2 role: inspect replication contracts and topology metadata; pglogical deployments still require pglogical-appropriate elevated privileges.';
COMMENT ON ROLE pgl_validate_orchestrate IS
    'pgl_validate T3 role: write validation catalogs, fence peers, launch workers, and read stored peer DSNs.';
COMMENT ON ROLE pgl_validate_repair IS
    'pgl_validate T4 role: generate and apply audited repairs using replication-origin and target-table privileges.';

GRANT pgl_validate_validate TO pgl_validate_discover;
GRANT pgl_validate_discover TO pgl_validate_orchestrate;
GRANT pgl_validate_orchestrate TO pgl_validate_repair;

REVOKE ALL ON SCHEMA pgl_validate FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA pgl_validate FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pgl_validate FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pgl_validate FROM PUBLIC;
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA pgl_validate FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgl_validate
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA pgl_validate
    TO pgl_validate_validate,
       pgl_validate_discover,
       pgl_validate_orchestrate,
       pgl_validate_repair;

GRANT USAGE ON TYPE pgl_validate.lthash_state
    TO pgl_validate_validate,
       pgl_validate_discover,
       pgl_validate_orchestrate,
       pgl_validate_repair;

GRANT EXECUTE ON FUNCTION pgl_validate.row_digest(integer[], "any")
    TO pgl_validate_validate;
GRANT EXECUTE ON FUNCTION pgl_validate.hash_digest_array(bytea[])
    TO pgl_validate_validate;
GRANT EXECUTE ON FUNCTION pgl_validate.lthash(bytea)
    TO pgl_validate_validate;
GRANT EXECUTE ON FUNCTION pgl_validate.lthash_combine(
    pgl_validate.lthash_state,
    pgl_validate.lthash_state
) TO pgl_validate_validate;
GRANT EXECUTE ON FUNCTION pgl_validate.lthash_bytes(pgl_validate.lthash_state)
    TO pgl_validate_validate;

GRANT EXECUTE ON FUNCTION pgl_validate.column_encoding_mode(oid)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.comparison_key_cols(regclass)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.pglogical_table_contract(regclass, text[], name)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.native_table_contract(regclass, text[], name)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.row_filter_tree_is_immutable(text)
    TO pgl_validate_discover;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgl_validate
    TO pgl_validate_orchestrate;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA pgl_validate
    TO pgl_validate_orchestrate;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgl_validate
    TO pgl_validate_orchestrate;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA pgl_validate
    TO pgl_validate_orchestrate;

REVOKE EXECUTE ON FUNCTION pgl_validate._repair_statements(bigint, text)
    FROM pgl_validate_orchestrate;
REVOKE EXECUTE ON FUNCTION pgl_validate.generate_repair(bigint, text)
    FROM pgl_validate_orchestrate;
REVOKE EXECUTE ON FUNCTION pgl_validate.apply_repair(
    bigint,
    text,
    text,
    text,
    text,
    boolean
) FROM pgl_validate_orchestrate;
REVOKE EXECUTE ON FUNCTION pgl_validate.remote_execute(
    text,
    text,
    integer,
    integer,
    integer
) FROM pgl_validate_orchestrate;

GRANT EXECUTE ON FUNCTION pgl_validate._repair_statements(bigint, text)
    TO pgl_validate_repair;
GRANT EXECUTE ON FUNCTION pgl_validate.generate_repair(bigint, text)
    TO pgl_validate_repair;
GRANT EXECUTE ON FUNCTION pgl_validate.apply_repair(
    bigint,
    text,
    text,
    text,
    text,
    boolean
) TO pgl_validate_repair;
GRANT EXECUTE ON FUNCTION pgl_validate.remote_execute(
    text,
    text,
    integer,
    integer,
    integer
) TO pgl_validate_repair;
