COMMENT ON SCHEMA pgl_validate IS
    'Cross-node data validation objects for pglogical-first replication topologies.';

COMMENT ON TABLE pgl_validate.peer IS
    'Named connection targets, replication-set metadata, and remote-query timeouts used by the coordinator when resolving peers.';
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
COMMENT ON TABLE pgl_validate.sequence_result IS
    'Sequence validation result using pglogical sequence-window semantics.';
COMMENT ON TABLE pgl_validate.schema_issue IS
    'Schema, privilege, or contract issues discovered during planning.';
COMMENT ON TABLE pgl_validate.schedule IS
    'Persisted validation schedule definitions.';
COMMENT ON TABLE pgl_validate.repair_run IS
    'Audited repair execution state.';
COMMENT ON TABLE pgl_validate.repair_result IS
    'Per-key outcome from a repair run.';

COMMENT ON VIEW pgl_validate.runs IS
    'Reporting view over validation runs.';
COMMENT ON VIEW pgl_validate.run_progress IS
    'Reporting view with chunk completion counts per run.';
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

COMMENT ON FUNCTION pgl_validate.column_encoding_mode(oid) IS
    'Select the coordinator-pushed row_digest encoding mode for a column type.';
COMMENT ON FUNCTION pgl_validate.pglogical_table_contract(regclass, text[], name) IS
    'Resolve pglogical action masks, effective column list, exact filter predicate, sync state, and validated property for a relation.';
COMMENT ON FUNCTION pgl_validate.ensure_pglogical_barrier_repset() IS
    'Create or verify the dedicated insert-only pglogical replication set that carries fence barrier tokens.';
COMMENT ON FUNCTION pgl_validate.fence_pglogical_edge(bigint, integer, integer, text, text, text, text, text, text, text, text[], integer, integer, integer, integer, integer) IS
    'Inject and converge an exact pglogical barrier for one provider-to-target run edge.';
COMMENT ON FUNCTION pgl_validate.plan_chunk_sql(regclass, text[], bytea, bytea, text[], text[], text) IS
    'Generate planner-visible SQL for a table chunk checksum.';
COMMENT ON FUNCTION pgl_validate.plan_localize_sql(regclass, text[], text[], text) IS
    'Generate planner-visible SQL for key and row-digest enumeration during divergence localization.';
COMMENT ON FUNCTION pgl_validate.plan_sequence_sql(regclass) IS
    'Generate planner-visible SQL for reading a sequence last_value on a participant.';
COMMENT ON FUNCTION pgl_validate.compare(regclass[], text, text[], text, jsonb) IS
    'Run a validation over explicit tables, a pglogical replication set including its sequences, or auto-discovered local relations and return the parent run id.';
COMMENT ON FUNCTION pgl_validate.compare_table(regclass, text[], jsonb) IS
    'Run the current table comparison path and return the persisted table verdict.';
COMMENT ON FUNCTION pgl_validate.compare_sequence(regclass, text[], jsonb) IS
    'Validate one sequence against peers using the pglogical sequence buffer-window contract.';
COMMENT ON FUNCTION pgl_validate._repair_statements(bigint, text) IS
    'Build structured repair statements with target, key, lock, verification, and relation metadata for generate_repair and apply_repair.';
COMMENT ON FUNCTION pgl_validate.generate_repair(bigint, text) IS
    'Generate reviewable node-labeled DML and sequence setval statements for confirmed divergences using the selected authoritative node.';
COMMENT ON FUNCTION pgl_validate.apply_repair(bigint, text, text, text, text, boolean) IS
    'Apply target-labeled generated repair statements after explicit target confirmation and record repair_run and repair_result audit rows.';
COMMENT ON FUNCTION pgl_validate.run_status(bigint) IS
    'Return the persisted state for a validation run.';
COMMENT ON FUNCTION pgl_validate.divergences(bigint) IS
    'Return persisted divergences for a validation run.';
COMMENT ON FUNCTION pgl_validate.sequences(bigint) IS
    'Return persisted sequence results for a validation run.';
COMMENT ON FUNCTION pgl_validate.report(bigint) IS
    'Return a structured JSON validation report for one run, including plans, verdicts, divergences, sequences, fences, and issues.';
COMMENT ON FUNCTION pgl_validate.metrics() IS
    'Return aggregate validation counters and gauges as structured JSON.';
COMMENT ON FUNCTION pgl_validate.record_barrier_fence(bigint, integer, integer, uuid, text, pg_lsn) IS
    'Persist an exact barrier token and end LSN for one run edge and epoch.';
COMMENT ON FUNCTION pgl_validate.record_fence_attempt(bigint, integer, integer, pg_lsn, pg_lsn, boolean, pg_lsn, text) IS
    'Persist a fence convergence observation with status derived from origin progress and token visibility.';
COMMENT ON FUNCTION pgl_validate.protected_barrier_tokens() IS
    'Return barrier tokens referenced by unfinished validation runs.';
COMMENT ON FUNCTION pgl_validate.cleanup_fence_barriers(interval, uuid[]) IS
    'Delete unprotected expired barrier tokens from the local node.';

COMMENT ON FUNCTION pgl_validate.row_digest(integer[], "any") IS
    'Compute a canonical row digest from coordinator-selected encodings and VARIADIC values.';
COMMENT ON FUNCTION pgl_validate.last_commit_lsn() IS
    'Return the backend exact last commit end LSN for barrier fencing.';
COMMENT ON FUNCTION pgl_validate.hash_digest_array(bytea[]) IS
    'Hash a caller-sorted array of row digests for cryptographic set confirmation.';
COMMENT ON FUNCTION pgl_validate.row_filter_tree_is_immutable(text) IS
    'Return whether a serialized PostgreSQL row-filter expression tree contains only immutable functions.';
COMMENT ON FUNCTION pgl_validate.remote_checksum(text, text, integer, integer, integer) IS
    'Execute generated checksum SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_localize_rows(text, text, integer, integer, integer) IS
    'Execute generated row-localization SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts, returning key, digest, and row JSON.';
COMMENT ON FUNCTION pgl_validate.remote_sequence_value(text, text, integer, integer, integer) IS
    'Execute generated sequence SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_execute(text, text, integer, integer, integer) IS
    'Execute a generated SQL command batch on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_inject_barrier(text, integer, integer, integer) IS
    'Insert a barrier token on a remote origin over libpq and return the exact barrier commit end LSN.';
COMMENT ON FUNCTION pgl_validate.remote_wait_slot_confirm_lsn(text, text, pg_lsn, integer, integer, integer) IS
    'Call pglogical.wait_slot_confirm_lsn on a provider and return the slot confirmed_flush_lsn.';
COMMENT ON FUNCTION pgl_validate.remote_observe_barrier(text, text, uuid, pg_lsn, integer, integer, integer) IS
    'Observe target-side replication origin progress, barrier-token visibility, and convergence.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_subscription_status(text, text, integer, integer, integer) IS
    'Fetch pglogical subscription status from a remote target over libpq with bounded timeouts.';
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
