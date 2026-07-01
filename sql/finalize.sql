COMMENT ON TABLE pgl_validate.peer IS
    'Named connection targets, replication-set metadata, and remote-query timeouts used by the coordinator when resolving peers.';
COMMENT ON COLUMN pgl_validate.peer.reverse_subscription_name IS
    'Explicit local pglogical subscription from this peer back to the coordinator, used to include bidirectional reverse edges in the fence vector.';
COMMENT ON TABLE pgl_validate.run IS
    'One validation run, including lifecycle state and summary counts.';
COMMENT ON SEQUENCE pgl_validate.run_run_id_seq IS
    'Generates run_id values for pgl_validate.run.';
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
COMMENT ON SEQUENCE pgl_validate.fence_barrier_id_seq IS
    'Generates local surrogate id values for duplicate-safe fence barrier rows.';
COMMENT ON TABLE pgl_validate.fence_barrier_run IS
    'Coordinator-local linkage between a barrier token and the run edge that injected it.';
COMMENT ON TABLE pgl_validate.table_plan IS
    'Per-table validation plan and replication contract selected for a run.';
COMMENT ON TABLE pgl_validate.table_column_plan IS
    'Per-column digest encoding plan selected for a table in a validation run.';
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
COMMENT ON SEQUENCE pgl_validate.worker_task_task_id_seq IS
    'Generates task_id values for pgl_validate.worker_task.';
COMMENT ON TABLE pgl_validate.repair_run IS
    'Audited repair execution state.';
COMMENT ON SEQUENCE pgl_validate.repair_run_repair_id_seq IS
    'Generates repair_id values for pgl_validate.repair_run.';
COMMENT ON TABLE pgl_validate.repair_result IS
    'Per-key outcome from a repair run.';

DO $$
DECLARE
    column_comment record;
    copied_comment record;
BEGIN
    FOR column_comment IN
        SELECT *
        FROM (VALUES
            ('peer', 'name', 'Stable peer name used in validation requests and run catalogs.'),
            ('peer', 'dsn', 'libpq connection string used to reach the peer.'),
            ('peer', 'provider_dsn', 'libpq connection string used to reach the local pglogical provider when validating this peer.'),
            ('peer', 'backend', 'Replication backend type for the peer: pglogical, native, or standby.'),
            ('peer', 'is_local', 'True when this peer row names the database currently executing pgl_validate.'),
            ('peer', 'subscription_name', 'Target-side subscription name used to identify the incoming edge.'),
            ('peer', 'reverse_subscription_name', 'Explicit local pglogical subscription from this peer back to the coordinator, used to include bidirectional reverse edges in the fence vector.'),
            ('peer', 'replication_sets', 'Replication sets expected on this peer when a request does not supply an override.'),
            ('peer', 'connect_timeout_seconds', 'libpq connection timeout for remote calls to this peer.'),
            ('peer', 'statement_timeout_ms', 'Remote statement timeout applied while querying this peer.'),
            ('peer', 'lock_timeout_ms', 'Remote lock timeout applied while querying this peer.'),
            ('peer', 'added_at', 'Time this peer definition was inserted.'),

            ('run', 'run_id', 'Validation run identifier.'),
            ('run', 'status', 'Current lifecycle state of the validation run.'),
            ('run', 'options', 'Normalized run options recorded for audit and resume.'),
            ('run', 'reference_node', 'Optional named authoritative or provider node for the run.'),
            ('run', 'launched_by', 'Database role that launched the run.'),
            ('run', 'started_at', 'Time the run row was created.'),
            ('run', 'finished_at', 'Time the run reached a terminal state.'),
            ('run', 'tables_total', 'Number of tables planned for the run.'),
            ('run', 'tables_matched', 'Number of tables with exact match verdicts.'),
            ('run', 'tables_differ', 'Number of tables with confirmed differ verdicts.'),
            ('run', 'error', 'Terminal error message when the run fails.'),

            ('run_participant', 'run_id', 'Validation run that owns this participant row.'),
            ('run_participant', 'node', 'Participant node name within the run.'),
            ('run_participant', 'role', 'Participant role in the run.'),
            ('run_participant', 'backend', 'Replication backend used for this participant.'),
            ('run_participant', 'pg_version', 'Remote PostgreSQL server_version_num observed for this participant.'),
            ('run_participant', 'dsn_ref', 'Peer name or DSN reference used to reach the participant.'),
            ('run_participant', 'status', 'Participant connection or completion state.'),

            ('fence_epoch', 'run_id', 'Validation run that owns this convergence epoch.'),
            ('fence_epoch', 'epoch_seq', 'Monotonic epoch number within the run.'),
            ('fence_epoch', 'created_at', 'Time the epoch was recorded.'),

            ('run_edge', 'run_id', 'Validation run that owns this directed replication edge.'),
            ('run_edge', 'edge_id', 'Directed edge number within the run.'),
            ('run_edge', 'provider_node', 'Node that produces changes for this edge.'),
            ('run_edge', 'target_node', 'Node that receives changes for this edge.'),
            ('run_edge', 'backend', 'Replication backend used by this edge.'),
            ('run_edge', 'subscription', 'Subscription name for the receiving side of this edge.'),
            ('run_edge', 'slot_name', 'Provider-side logical replication slot for this edge.'),
            ('run_edge', 'origin_name', 'Target-side replication origin name for this edge.'),
            ('run_edge', 'repsets', 'Replication sets validated on this edge.'),

            ('fence_edge', 'run_id', 'Validation run that owns this fence target.'),
            ('fence_edge', 'epoch_seq', 'Fence epoch for this edge.'),
            ('fence_edge', 'edge_id', 'Directed edge being fenced.'),
            ('fence_edge', 'fence_kind', 'Fence method: barrier, standby_replay, or degraded.'),
            ('fence_edge', 'barrier_token', 'Barrier token expected to become visible on the target for exact logical fences.'),
            ('fence_edge', 'barrier_end_lsn', 'Exact WAL LSN the target must reach for this fence.'),

            ('fence_attempt', 'run_id', 'Validation run that owns this fence observation.'),
            ('fence_attempt', 'epoch_seq', 'Fence epoch being observed.'),
            ('fence_attempt', 'edge_id', 'Directed edge being observed.'),
            ('fence_attempt', 'barrier_end_lsn', 'Fence LSN copied from the edge target.'),
            ('fence_attempt', 'origin_progress_lsn', 'Target-side replay or origin progress observed for the edge.'),
            ('fence_attempt', 'token_visible', 'Whether the barrier token is visible on the target.'),
            ('fence_attempt', 'confirmed_flush_lsn', 'Provider-side slot flush confirmation, when available.'),
            ('fence_attempt', 'converged_at', 'Time the edge first satisfied its convergence predicate.'),
            ('fence_attempt', 'status', 'Observed fence state.'),

            ('fence_barrier', 'id', 'Local surrogate key for duplicate-safe barrier rows.'),
            ('fence_barrier', 'token', 'Replicated non-unique barrier token.'),
            ('fence_barrier', 'injected_at', 'Local time the barrier token row was inserted.'),

            ('fence_barrier_run', 'token', 'Barrier token associated with a run edge.'),
            ('fence_barrier_run', 'run_id', 'Validation run that injected the token.'),
            ('fence_barrier_run', 'epoch_seq', 'Fence epoch that injected the token.'),
            ('fence_barrier_run', 'edge_id', 'Directed edge that injected the token.'),
            ('fence_barrier_run', 'origin_node', 'Origin node where the barrier transaction was committed.'),
            ('fence_barrier_run', 'barrier_end_lsn', 'Exact commit-end LSN returned after barrier insertion.'),

            ('table_plan', 'run_id', 'Validation run that owns this table plan.'),
            ('table_plan', 'schema_name', 'Schema name of the planned table.'),
            ('table_plan', 'table_name', 'Relation name of the planned table.'),
            ('table_plan', 'key_cols', 'Comparison key columns used for localization.'),
            ('table_plan', 'att_list', 'Columns included in row digests for the table.'),
            ('table_plan', 'repsets', 'Replication sets used to resolve the table contract.'),
            ('table_plan', 'repl_insert', 'Whether the contract replicates inserts.'),
            ('table_plan', 'repl_update', 'Whether the contract replicates updates.'),
            ('table_plan', 'repl_delete', 'Whether the contract replicates deletes.'),
            ('table_plan', 'repl_truncate', 'Whether the contract replicates truncates.'),
            ('table_plan', 'has_row_filter', 'Whether the table contract includes a row filter.'),
            ('table_plan', 'sync_status', 'Subscriber-side table synchronization state, when known.'),
            ('table_plan', 'validated_property', 'Strongest property that can be soundly validated for the table.'),

            ('table_column_plan', 'run_id', 'Validation run that owns this column plan.'),
            ('table_column_plan', 'schema_name', 'Schema name of the planned table.'),
            ('table_column_plan', 'table_name', 'Relation name of the planned table.'),
            ('table_column_plan', 'attnum', 'Local attribute number used for catalog traceability.'),
            ('table_column_plan', 'attname', 'Column name included in row digests.'),
            ('table_column_plan', 'type_oid', 'Local type OID used when the encoding mode was selected.'),
            ('table_column_plan', 'type_schema', 'Schema name of the column type.'),
            ('table_column_plan', 'type_name', 'Column type name.'),
            ('table_column_plan', 'typmod', 'Column typmod used by the planned comparison.'),
            ('table_column_plan', 'encoding_mode', 'Numeric row_digest encoding mode passed positionally in generated SQL.'),
            ('table_column_plan', 'encoding_name', 'Human-readable encoding mode: send, text, or jsonb_normalize.'),

            ('table_result', 'run_id', 'Validation run that owns this table verdict.'),
            ('table_result', 'schema_name', 'Schema name of the validated table.'),
            ('table_result', 'table_name', 'Relation name of the validated table.'),
            ('table_result', 'verdict', 'Final table-level validation verdict.'),
            ('table_result', 'reason', 'Human-readable explanation of the verdict.'),
            ('table_result', 'started_at', 'Time table validation began.'),
            ('table_result', 'finished_at', 'Time table validation finished.'),

            ('table_node_result', 'run_id', 'Validation run that owns this node checksum.'),
            ('table_node_result', 'schema_name', 'Schema name of the validated table.'),
            ('table_node_result', 'table_name', 'Relation name of the validated table.'),
            ('table_node_result', 'node', 'Participant node that produced this checksum.'),
            ('table_node_result', 'n_rows', 'Rows included in the table checksum.'),
            ('table_node_result', 'lthash', 'LtHash multiset checksum for the table.'),
            ('table_node_result', 'set_hash', 'Optional cryptographic sorted-digest confirmation for the table.'),

            ('chunk_result', 'run_id', 'Validation run that owns this chunk.'),
            ('chunk_result', 'schema_name', 'Schema name of the chunked table.'),
            ('chunk_result', 'table_name', 'Relation name of the chunked table.'),
            ('chunk_result', 'chunk_id', 'Chunk identifier within the table plan.'),
            ('chunk_result', 'parent_id', 'Parent chunk identifier for split chunks.'),
            ('chunk_result', 'lo', 'Inclusive lower key boundary encoded as canonical bytes.'),
            ('chunk_result', 'hi', 'Exclusive upper key boundary encoded as canonical bytes.'),
            ('chunk_result', 'state', 'Chunk validation or localization state.'),
            ('chunk_result', 'updated_at', 'Last time the chunk row changed.'),

            ('chunk_node_result', 'run_id', 'Validation run that owns this chunk checksum.'),
            ('chunk_node_result', 'schema_name', 'Schema name of the chunked table.'),
            ('chunk_node_result', 'table_name', 'Relation name of the chunked table.'),
            ('chunk_node_result', 'chunk_id', 'Chunk identifier within the table plan.'),
            ('chunk_node_result', 'node', 'Participant node that produced this chunk checksum.'),
            ('chunk_node_result', 'n_rows', 'Rows included in the chunk checksum.'),
            ('chunk_node_result', 'lthash', 'LtHash multiset checksum for the chunk.'),

            ('divergence', 'run_id', 'Validation run that owns this divergence.'),
            ('divergence', 'schema_name', 'Schema name of the divergent table.'),
            ('divergence', 'table_name', 'Relation name of the divergent table.'),
            ('divergence', 'key_text', 'Text form of the divergent key for display.'),
            ('divergence', 'key_bytes', 'Canonical key bytes used for stable identity.'),
            ('divergence', 'classification', 'Whether the key is missing, extra, or content-different on the node.'),
            ('divergence', 'node', 'Participant node where the divergence was observed.'),
            ('divergence', 'status', 'Candidate, confirmed, cleared, indeterminate, or advisory state.'),
            ('divergence', 'detected_epoch', 'Fence epoch in which the candidate was first detected.'),
            ('divergence', 'tuple', 'Bounded tuple payload captured for repair or reporting.'),
            ('divergence', 'detected_at', 'Time the divergence was recorded.'),

            ('divergence_recheck', 'run_id', 'Validation run that owns this recheck.'),
            ('divergence_recheck', 'schema_name', 'Schema name of the rechecked table.'),
            ('divergence_recheck', 'table_name', 'Relation name of the rechecked table.'),
            ('divergence_recheck', 'key_bytes', 'Canonical key bytes rechecked for stability.'),
            ('divergence_recheck', 'node', 'Participant node rechecked for the key.'),
            ('divergence_recheck', 'epoch_seq', 'Later fence epoch used for the recheck.'),
            ('divergence_recheck', 'outcome', 'Digest-stability outcome for the recheck.'),
            ('divergence_recheck', 'at', 'Time the recheck was recorded.'),

            ('conflict_evidence', 'run_id', 'Validation run that owns this conflict evidence.'),
            ('conflict_evidence', 'schema_name', 'Schema name of the divergent table.'),
            ('conflict_evidence', 'table_name', 'Relation name of the divergent table.'),
            ('conflict_evidence', 'key_bytes', 'Canonical divergent key matched to the conflict.'),
            ('conflict_evidence', 'node', 'Participant node whose conflict history was queried.'),
            ('conflict_evidence', 'source', 'Evidence source identifier.'),
            ('conflict_evidence', 'conflict_id', 'Conflict-history identifier from the source node.'),
            ('conflict_evidence', 'recorded_at', 'Time the conflict was recorded on the source node.'),
            ('conflict_evidence', 'subscription_name', 'Subscription associated with the conflict.'),
            ('conflict_evidence', 'conflict_type', 'pglogical conflict type.'),
            ('conflict_evidence', 'resolution', 'pglogical conflict resolution that was applied.'),
            ('conflict_evidence', 'index_name', 'Index used by pglogical conflict detection, when available.'),
            ('conflict_evidence', 'local_tuple', 'Local tuple image from conflict history, when available.'),
            ('conflict_evidence', 'local_xid', 'Local transaction id from conflict history, when available.'),
            ('conflict_evidence', 'local_origin', 'Local replication origin identifier, when available.'),
            ('conflict_evidence', 'local_commit_ts', 'Local commit timestamp from conflict history, when available.'),
            ('conflict_evidence', 'remote_tuple', 'Remote tuple image from conflict history, when available.'),
            ('conflict_evidence', 'remote_origin', 'Remote replication origin identifier from conflict history.'),
            ('conflict_evidence', 'remote_commit_ts', 'Remote commit timestamp from conflict history.'),
            ('conflict_evidence', 'remote_commit_lsn', 'Remote commit LSN from conflict history.'),
            ('conflict_evidence', 'has_before_triggers', 'Whether pglogical reported before triggers on the target table.'),
            ('conflict_evidence', 'matched_on', 'Tuple fields that matched the divergent key.'),
            ('conflict_evidence', 'observed_at', 'Time pgl_validate recorded this evidence.'),

            ('sequence_result', 'run_id', 'Validation run that owns this sequence result.'),
            ('sequence_result', 'schema_name', 'Schema name of the sequence.'),
            ('sequence_result', 'seq_name', 'Sequence name.'),
            ('sequence_result', 'provider_node', 'Provider node used as the sequence reference.'),
            ('sequence_result', 'provider_last_value', 'Provider last_value observed for the sequence.'),
            ('sequence_result', 'subscriber_node', 'Subscriber node compared against the provider.'),
            ('sequence_result', 'subscriber_last_value', 'Subscriber last_value observed for the sequence.'),
            ('sequence_result', 'cache_size', 'Sequence cache size used to compute the acceptable window.'),
            ('sequence_result', 'within_contract', 'Whether the subscriber value is inside the pglogical sequence window.'),
            ('sequence_result', 'verdict', 'Sequence validation verdict.'),

            ('schema_issue', 'run_id', 'Validation run that owns this issue.'),
            ('schema_issue', 'node', 'Node where the issue was discovered.'),
            ('schema_issue', 'schema_name', 'Schema name related to the issue.'),
            ('schema_issue', 'table_name', 'Relation name related to the issue.'),
            ('schema_issue', 'issue_code', 'Machine-readable issue code.'),
            ('schema_issue', 'detail', 'Human-readable issue detail.'),

            ('schedule', 'name', 'Stable schedule name.'),
            ('schedule', 'cron', 'Five-field cron expression evaluated in the database session time zone.'),
            ('schedule', 'tables', 'Optional relation names validated by the schedule.'),
            ('schedule', 'repset', 'Optional pglogical replication set expanded by the schedule.'),
            ('schedule', 'peers', 'Optional peer names used by the schedule.'),
            ('schedule', 'options', 'Validation options merged into scheduled runs.'),
            ('schedule', 'enabled', 'Whether automatic dispatch may launch the schedule.'),
            ('schedule', 'last_run_id', 'Most recent run launched by the schedule.'),

            ('worker_task', 'task_id', 'Background worker task identifier.'),
            ('worker_task', 'run_id', 'Validation run owned by this worker task.'),
            ('worker_task', 'task_kind', 'Task kind executed by the worker.'),
            ('worker_task', 'request', 'Serialized request used by the worker.'),
            ('worker_task', 'status', 'Durable worker task state.'),
            ('worker_task', 'launched_by', 'Database role that queued the task.'),
            ('worker_task', 'database_name', 'Database where the worker connects to run the task.'),
            ('worker_task', 'worker_pid', 'Backend PID of the worker handling the task.'),
            ('worker_task', 'enqueued_at', 'Time the task was queued.'),
            ('worker_task', 'started_at', 'Time the task started running.'),
            ('worker_task', 'finished_at', 'Time the task reached a terminal state.'),
            ('worker_task', 'error', 'Terminal worker error message, if any.'),

            ('repair_run', 'repair_id', 'Repair run identifier.'),
            ('repair_run', 'run_id', 'Validation run being repaired.'),
            ('repair_run', 'authoritative', 'Node chosen as the repair authority.'),
            ('repair_run', 'target', 'Node receiving repair statements.'),
            ('repair_run', 'propagation', 'Repair propagation mode.'),
            ('repair_run', 'paused_subs', 'Subscriptions paused while repair was applied.'),
            ('repair_run', 'origin_name', 'Replication origin used for the repair session.'),
            ('repair_run', 'status', 'Repair lifecycle state.'),
            ('repair_run', 'launched_by', 'Database role that launched the repair.'),
            ('repair_run', 'started_at', 'Time the repair run began.'),
            ('repair_run', 'finished_at', 'Time the repair run reached a terminal state.'),
            ('repair_run', 'error', 'Terminal repair error message, if any.'),

            ('repair_result', 'repair_id', 'Repair run that owns this per-key result.'),
            ('repair_result', 'schema_name', 'Schema name of the repaired object.'),
            ('repair_result', 'table_name', 'Table or sequence name repaired.'),
            ('repair_result', 'key_bytes', 'Canonical key bytes repaired.'),
            ('repair_result', 'action', 'Repair action performed.'),
            ('repair_result', 'statement', 'Generated SQL statement applied or proposed for the key.'),
            ('repair_result', 'post_verdict', 'Focused post-repair verdict for the key.')
        ) AS v(relation_name, column_name, description)
    LOOP
        EXECUTE format(
            'COMMENT ON COLUMN pgl_validate.%I.%I IS %L',
            column_comment.relation_name,
            column_comment.column_name,
            column_comment.description
        );
    END LOOP;

    FOR copied_comment IN
        SELECT *
        FROM (VALUES
            ('runs', 'run'),
            ('table_results', 'table_result'),
            ('chunk_results', 'chunk_result'),
            ('divergences', 'divergence'),
            ('sequence_results', 'sequence_result'),
            ('schema_issues', 'schema_issue'),
            ('worker_tasks', 'worker_task')
        ) AS v(view_name, table_name)
    LOOP
        FOR column_comment IN
            SELECT a.attname AS column_name,
                   col_description(source_rel.oid, a.attnum) AS description
            FROM pg_attribute a
            JOIN pg_class source_rel
              ON source_rel.oid = a.attrelid
            JOIN pg_namespace source_ns
              ON source_ns.oid = source_rel.relnamespace
            WHERE source_ns.nspname = 'pgl_validate'
              AND source_rel.relname = copied_comment.table_name
              AND a.attnum > 0
              AND NOT a.attisdropped
        LOOP
            EXECUTE format(
                'COMMENT ON COLUMN pgl_validate.%I.%I IS %L',
                copied_comment.view_name,
                column_comment.column_name,
                column_comment.description
            );
        END LOOP;
    END LOOP;
END
$$;

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

DO $$
DECLARE
    column_comment record;
BEGIN
    FOR column_comment IN
        SELECT *
        FROM (VALUES
            ('run_progress', 'run_id', 'Validation run identifier.'),
            ('run_progress', 'status', 'Current lifecycle state of the validation run.'),
            ('run_progress', 'phase', 'Derived execution phase for progress displays.'),
            ('run_progress', 'current_epoch', 'Most recent fence epoch recorded for the run.'),
            ('run_progress', 'chunks_done', 'Completed or divergent leaf chunks.'),
            ('run_progress', 'chunks_total', 'Total leaf chunks currently known.'),
            ('run_progress', 'rows_scanned', 'Rows included in table or chunk checksum work.'),
            ('run_progress', 'bytes_scanned', 'Approximate digest payload bytes scanned.'),
            ('run_progress', 'eta', 'Estimated remaining interval when enough progress exists.'),
            ('run_progress', 'started_at', 'Time the run row was created.'),
            ('run_progress', 'finished_at', 'Time the run reached a terminal state.')
        ) AS v(relation_name, column_name, description)
    LOOP
        EXECUTE format(
            'COMMENT ON COLUMN pgl_validate.%I.%I IS %L',
            column_comment.relation_name,
            column_comment.column_name,
            column_comment.description
        );
    END LOOP;
END
$$;

COMMENT ON FUNCTION pgl_validate.digest_type_oid(oid) IS
    'Resolve the SQL type a root-domain column is cast to before value encoding, preserving domain identity in schema signatures while hashing the base value.';
COMMENT ON FUNCTION pgl_validate.digest_value_sql(text, name, oid) IS
    'Generate the table-column SQL expression passed to row_digest, including base-type casts for root-domain columns.';
COMMENT ON FUNCTION pgl_validate.column_encoding_mode(oid) IS
    'Select the coordinator-pushed row_digest encoding mode for a column type, using binary send only for stable built-ins and enums while recursively falling back to pinned text for unknown or unstable nested type families; root domains are resolved through their base value type.';
COMMENT ON FUNCTION pgl_validate.plan_settings_cte(text) IS
    'Build the generated-SQL CTE that pins digest-affecting GUCs on a participant session.';
COMMENT ON FUNCTION pgl_validate.comparison_key_cols(regclass) IS
    'Select the replica-identity, primary-key, or safe unique-index columns used for row-level divergence localization.';
COMMENT ON FUNCTION pgl_validate.pglogical_table_contract(regclass, text[], name) IS
    'Resolve pglogical action masks, effective column list, exact filter predicate, sync state, and validated property for a relation.';
COMMENT ON FUNCTION pgl_validate.native_table_contract(regclass, text[], name) IS
    'Resolve native logical publication actions, effective column list, exact row filter, sync state, and validated property for a relation.';
COMMENT ON FUNCTION pgl_validate.ensure_pglogical_barrier_repset() IS
    'Create or verify the dedicated insert-only pglogical replication set that carries fence barrier tokens.';
COMMENT ON FUNCTION pgl_validate.pglogical_local_node() IS
    'Return the current database''s pglogical node name and local interface DSN.';
COMMENT ON FUNCTION pgl_validate.pglogical_subscription_table_sync_status(name, regclass) IS
    'Return raw pglogical per-table synchronization state for a local subscription, treating missing table-sync rows as ready.';
COMMENT ON FUNCTION pgl_validate.ensure_pglogical_subscription_barrier(name) IS
    'Ensure a local pglogical subscription includes the pgl_validate barrier replication set.';
COMMENT ON FUNCTION pgl_validate.register_pglogical_peer(text, text, name, name, text[], integer, integer, integer) IS
    'Register or update a pglogical peer, discover forward and reverse subscriptions when unambiguous, and install the barrier replication set on those subscriptions.';
COMMENT ON FUNCTION pgl_validate.unregister_pglogical_peer(text) IS
    'Remove a pglogical peer registration without changing the replication topology.';
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
COMMENT ON FUNCTION pgl_validate.plan_keyless_bucket_sql(regclass, integer, integer, text[], text, boolean, text) IS
    'Generate planner-visible checksum SQL for one keyless row-digest bucket.';
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
COMMENT ON FUNCTION pgl_validate._cron_field_matches(text, integer, integer, integer, boolean) IS
    'Evaluate one numeric cron field with list, range, and step support.';
COMMENT ON FUNCTION pgl_validate._cron_matches(text, timestamptz) IS
    'Return whether a five-field cron expression matches a timestamp in the current session time zone.';
COMMENT ON FUNCTION pgl_validate.put_schedule(text, text, text[], text, text[], jsonb, boolean) IS
    'Create or replace a durable validation schedule definition without launching it.';
COMMENT ON FUNCTION pgl_validate.set_schedule_enabled(text, boolean) IS
    'Enable or disable a durable validation schedule definition.';
COMMENT ON FUNCTION pgl_validate.delete_schedule(text) IS
    'Delete a durable validation schedule definition and leave any historical runs intact.';
COMMENT ON FUNCTION pgl_validate.run_schedule(text, boolean) IS
    'Dispatch a durable validation schedule through compare_async, record the launched run id, and return it.';
COMMENT ON FUNCTION pgl_validate.dispatch_due_schedules(timestamptz) IS
    'Dispatch enabled schedules whose cron expression is due at the given timestamp, at most once per matching minute.';
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
    'Apply target-labeled generated repair statements after explicit target confirmation, using a loopback peer for origin-aware local repairs, then run focused revalidation and record repair_run and repair_result audit rows.';
COMMENT ON FUNCTION pgl_validate._conflict_tuple_matches_key(jsonb, jsonb) IS
    'Return whether a pglogical conflict-history tuple image contains a divergent key, accepting both typed JSON values and pglogical stringified scalar output.';
COMMENT ON FUNCTION pgl_validate.correlate_conflict_history(bigint, interval, integer) IS
    'Attach pglogical conflict-history rows to confirmed divergences when tuple JSON contains the divergent key.';
COMMENT ON FUNCTION pgl_validate.run_status(bigint) IS
    'Return the persisted state for a validation run.';
COMMENT ON FUNCTION pgl_validate.divergences(bigint) IS
    'Return persisted divergences for a validation run.';
COMMENT ON FUNCTION pgl_validate.conflict_evidence(bigint) IS
    'Return pglogical conflict-history evidence attached to a validation run.';
COMMENT ON FUNCTION pgl_validate.conflict_summary(bigint) IS
    'Return compact conflict-history cause counts by table, node, conflict type, and resolution for one validation run.';
COMMENT ON FUNCTION pgl_validate.purge_conflict_evidence(timestamptz, bigint) IS
    'Delete raw conflict-history evidence older than the recorded-at cutoff, optionally scoped to one run, while retaining validation results.';
COMMENT ON FUNCTION pgl_validate.sequences(bigint) IS
    'Return persisted sequence results for a validation run.';
COMMENT ON FUNCTION pgl_validate.report(bigint) IS
    'Return a structured JSON validation report for one run, including plans, verdicts, divergences, conflict summaries, sequences, fences, and issues.';
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
COMMENT ON FUNCTION pgl_validate.remote_pglogical_local_node(text, integer, integer, integer) IS
    'Fetch a remote node''s pglogical node name and local interface DSN over libpq with bounded timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_pglogical_subscriptions(text, integer, integer, integer) IS
    'Fetch pglogical subscription summaries from a remote node over libpq with bounded timeouts.';
COMMENT ON FUNCTION pgl_validate.remote_ensure_pglogical_barrier_subscription(text, text, integer, integer, integer) IS
    'Ensure a remote pglogical subscription includes the pgl_validate barrier replication set.';
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

GRANT EXECUTE ON FUNCTION pgl_validate.digest_type_oid(oid)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.digest_value_sql(text, name, oid)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.column_encoding_mode(oid)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.comparison_key_cols(regclass)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.pglogical_table_contract(regclass, text[], name)
    TO pgl_validate_discover;
GRANT EXECUTE ON FUNCTION pgl_validate.pglogical_subscription_table_sync_status(name, regclass)
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
