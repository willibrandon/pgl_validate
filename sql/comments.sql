COMMENT ON SCHEMA pgl_validate IS
    'Cross-node data validation objects for pglogical-first replication topologies.';

COMMENT ON TABLE pgl_validate.peer IS
    'Named connection targets and remote-query timeouts used by the coordinator when resolving peers.';
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
COMMENT ON FUNCTION pgl_validate.plan_chunk_sql(regclass, text[], bytea, bytea, text[], text[]) IS
    'Generate planner-visible SQL for a table chunk checksum.';
COMMENT ON FUNCTION pgl_validate.compare_table(regclass, text[], jsonb) IS
    'Run the current table comparison path and return the persisted table verdict.';
COMMENT ON FUNCTION pgl_validate.run_status(bigint) IS
    'Return the persisted state for a validation run.';
COMMENT ON FUNCTION pgl_validate.divergences(bigint) IS
    'Return persisted divergences for a validation run.';
COMMENT ON FUNCTION pgl_validate.sequences(bigint) IS
    'Return persisted sequence results for a validation run.';
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
COMMENT ON FUNCTION pgl_validate.remote_checksum(text, text, integer, integer, integer) IS
    'Execute generated checksum SQL on a named peer DSN via libpq with bounded connect, statement, and lock timeouts.';
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
