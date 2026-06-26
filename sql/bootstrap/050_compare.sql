CREATE FUNCTION pgl_validate.reported_tuple_json(row_json jsonb, max_bytes integer)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    tuple_bytes integer;
BEGIN
    IF row_json IS NULL THEN
        RETURN NULL;
    END IF;
    IF max_bytes IS NULL OR max_bytes <= 0 THEN
        RAISE EXCEPTION 'max_reported_tuple_bytes must be greater than zero'
            USING ERRCODE = '22023';
    END IF;

    tuple_bytes := octet_length(row_json::text);
    IF tuple_bytes <= max_bytes THEN
        RETURN row_json;
    END IF;

    RETURN jsonb_build_object(
        '_pgl_validate_tuple_truncated', true,
        'original_bytes', tuple_bytes,
        'max_reported_tuple_bytes', max_bytes
    );
END
$$;

CREATE FUNCTION pgl_validate.compare(
    tables regclass[] DEFAULT NULL,
    repset text DEFAULT NULL,
    peers text[] DEFAULT NULL,
    reference text DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_run_id bigint;
    table_list regclass[];
    sequence_list regclass[];
    table_oid regclass;
    sequence_oid regclass;
    effective_options jsonb := COALESCE(options, '{}'::jsonb);
    internal_options jsonb;
    result_row pgl_validate.table_result;
    table_count int := 0;
    sequence_count int := 0;
    error_schema_name text;
    error_table_name text;
    error_detail text;
    error_cols text[];
    error_key_cols text[];
    parent_run_id bigint := NULLIF(effective_options->>'_pgl_validate_parent_run_id', '')::bigint;
    stored_options jsonb;
BEGIN
    IF jsonb_typeof(effective_options) <> 'object' THEN
        RAISE EXCEPTION 'options must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    IF tables IS NOT NULL AND cardinality(tables) > 0 THEN
        SELECT array_agg(dedup.table_oid ORDER BY dedup.first_ordinal)
        INTO table_list
        FROM (
            SELECT input.table_oid, min(input.ordinality) AS first_ordinal
            FROM unnest(tables) WITH ORDINALITY AS input(table_oid, ordinality)
            GROUP BY input.table_oid
        ) dedup;
    ELSIF repset IS NOT NULL THEN
        IF to_regclass('pglogical.replication_set_table') IS NULL
           OR to_regclass('pglogical.replication_set') IS NULL THEN
            RAISE EXCEPTION 'repset expansion requires pglogical to be installed in this database'
                USING ERRCODE = '0A000';
        END IF;

        EXECUTE
            'SELECT array_agg(rst.set_reloid ORDER BY rst.set_reloid::text)
             FROM pglogical.replication_set rs
             JOIN pglogical.replication_set_table rst ON rst.set_id = rs.set_id
             WHERE rs.set_name = $1::name'
        INTO table_list
        USING repset;

        EXECUTE
            'SELECT array_agg(rss.set_seqoid ORDER BY rss.set_seqoid::text)
             FROM pglogical.replication_set rs
             JOIN pglogical.replication_set_seq rss ON rss.set_id = rs.set_id
             WHERE rs.set_name = $1::name'
        INTO sequence_list
        USING repset;
    ELSE
        SELECT array_agg(c.oid::regclass ORDER BY n.nspname, c.relname)
        INTO table_list
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','p')
          AND n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
          AND n.nspname <> 'information_schema'
          AND n.nspname <> 'pgl_validate';

        SELECT array_agg(c.oid::regclass ORDER BY n.nspname, c.relname)
        INTO sequence_list
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S'
          AND n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
          AND n.nspname <> 'information_schema'
          AND n.nspname <> 'pgl_validate';
    END IF;

    table_count := COALESCE(cardinality(table_list), 0);
    sequence_count := COALESCE(cardinality(sequence_list), 0);

    IF table_count = 0 AND sequence_count = 0 THEN
        RAISE EXCEPTION 'no tables or sequences resolved for validation run'
            USING ERRCODE = '02000';
    END IF;

    IF repset IS NOT NULL THEN
        effective_options := effective_options || jsonb_build_object('repsets', jsonb_build_array(repset));
    END IF;
    IF reference IS NOT NULL THEN
        effective_options := effective_options || jsonb_build_object('provider_node', reference);
    END IF;
    stored_options := effective_options - '_pgl_validate_parent_run_id';

    IF parent_run_id IS NULL THEN
        INSERT INTO pgl_validate.run(status, options, reference_node, tables_total)
        VALUES ('planning', stored_options, reference, table_count)
        RETURNING pgl_validate.run.run_id INTO v_run_id;
    ELSE
        SELECT r.run_id
        INTO v_run_id
        FROM pgl_validate.run r
        WHERE r.run_id = parent_run_id
          AND r.status IN ('planning','fencing','running','rechecking','paused')
        FOR UPDATE;

        IF v_run_id IS NULL THEN
            RAISE EXCEPTION 'parent validation run % does not exist or is not appendable', parent_run_id
                USING ERRCODE = '55000';
        END IF;

        UPDATE pgl_validate.run
        SET status = 'planning',
            options = stored_options,
            reference_node = reference,
            tables_total = table_count,
            tables_matched = NULL,
            tables_differ = NULL,
            finished_at = NULL,
            error = NULL
        WHERE pgl_validate.run.run_id = v_run_id;
    END IF;

    BEGIN
        IF table_count > 0 THEN
            FOREACH table_oid IN ARRAY table_list LOOP
                internal_options := effective_options || jsonb_build_object('_pgl_validate_parent_run_id', v_run_id);
                BEGIN
                    SELECT *
                    INTO result_row
                    FROM pgl_validate.compare_table(table_oid, peers, internal_options);
                EXCEPTION WHEN others THEN
                    error_detail := SQLERRM;

                    IF COALESCE(NULLIF(effective_options->>'on_precondition_fail', ''), 'skip_table') = 'abort_run' THEN
                        RAISE;
                    END IF;

                    SELECT n.nspname, c.relname
                    INTO error_schema_name, error_table_name
                    FROM pg_class c
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.oid = table_oid;

                    error_schema_name := COALESCE(error_schema_name, '<unknown>');
                    error_table_name := COALESCE(error_table_name, table_oid::text);

                    SELECT array_agg(a.attname ORDER BY a.attname)
                    INTO error_cols
                    FROM pg_attribute a
                    WHERE a.attrelid = table_oid
                      AND a.attnum > 0
                      AND NOT a.attisdropped;

                    BEGIN
                        error_key_cols := pgl_validate.comparison_key_cols(table_oid);
                    EXCEPTION WHEN others THEN
                        error_key_cols := NULL;
                    END;

                    INSERT INTO pgl_validate.table_plan(
                        run_id, schema_name, table_name, key_cols, att_list, repsets,
                        repl_insert, repl_update, repl_delete, repl_truncate,
                        has_row_filter, sync_status, validated_property
                    )
                    VALUES (
                        v_run_id, error_schema_name, error_table_name,
                        error_key_cols, error_cols, NULL,
                        NULL, NULL, NULL, NULL,
                        false, NULL, 'skipped'
                    )
                    ON CONFLICT (run_id, schema_name, table_name) DO UPDATE
                    SET key_cols = EXCLUDED.key_cols,
                        att_list = EXCLUDED.att_list,
                        validated_property = EXCLUDED.validated_property;

                    INSERT INTO pgl_validate.schema_issue(
                        run_id, node, schema_name, table_name, issue_code, detail
                    )
                    VALUES (
                        v_run_id,
                        COALESCE(reference, 'local'),
                        error_schema_name,
                        error_table_name,
                        'TABLE_COMPARE_FAILED',
                        error_detail
                    )
                    ON CONFLICT DO NOTHING;

                    INSERT INTO pgl_validate.table_result(
                        run_id, schema_name, table_name, verdict, reason, finished_at
                    )
                    VALUES (
                        v_run_id,
                        error_schema_name,
                        error_table_name,
                        'error',
                        format('table comparison failed: %s', error_detail),
                        now()
                    )
                    ON CONFLICT (run_id, schema_name, table_name) DO UPDATE
                    SET verdict = EXCLUDED.verdict,
                        reason = EXCLUDED.reason,
                        finished_at = EXCLUDED.finished_at;
                END;
            END LOOP;
        END IF;

        IF sequence_count > 0 THEN
            FOREACH sequence_oid IN ARRAY sequence_list LOOP
                internal_options := effective_options || jsonb_build_object('_pgl_validate_parent_run_id', v_run_id);
                PERFORM pgl_validate.compare_sequence(sequence_oid, peers, internal_options);
            END LOOP;
        END IF;

        UPDATE pgl_validate.run
        SET status = 'completed',
            finished_at = now(),
            tables_total = table_count,
            tables_matched = (
                SELECT count(*)::int
                FROM pgl_validate.table_result tr
                WHERE tr.run_id = v_run_id
                  AND tr.verdict = 'match'
            ),
            tables_differ = (
                SELECT count(*)::int
                FROM pgl_validate.table_result tr
                WHERE tr.run_id = v_run_id
                  AND tr.verdict = 'differ'
            )
        WHERE pgl_validate.run.run_id = v_run_id;

        UPDATE pgl_validate.run_participant
        SET status = 'done'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND status NOT IN ('unreachable','error');
    EXCEPTION WHEN others THEN
        UPDATE pgl_validate.run
        SET status = 'failed',
            finished_at = now(),
            error = SQLERRM
        WHERE pgl_validate.run.run_id = v_run_id;

        UPDATE pgl_validate.run_participant
        SET status = 'error'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';

        RAISE;
    END;

    RETURN v_run_id;
END
$$;

-- First executable comparison path: compute and persist the local node's table
-- checksum using the same generated SQL that the coordinator will send to
-- remote peers. Multi-peer transport layers build on this catalog contract.
CREATE FUNCTION pgl_validate.compare_table(
    p_table_name regclass,
    peers text[] DEFAULT NULL,
    options jsonb DEFAULT '{}'
)
RETURNS pgl_validate.table_result
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_run_id bigint;
    parent_run_id bigint := NULLIF(options->>'_pgl_validate_parent_run_id', '')::bigint;
    append_to_parent boolean := false;
    initial_epoch int := 1;
    recheck_epoch int := 2;
    recheck_pass int;
    previous_sample text := 'A';
    current_sample text;
    v_schema_name text;
    v_rel_name text;
    cols text[];
    key_cols text[];
    contract_repsets text[];
    contract_subscription name;
    contract_rec record;
    plan_repsets text[];
    repl_insert boolean := true;
    repl_update boolean := true;
    repl_delete boolean := true;
    repl_truncate boolean := true;
    has_row_filter boolean := false;
    row_filter_sql text;
    row_filter_exact boolean := true;
    allow_approximate_filters boolean := COALESCE(
        (NULLIF(options->>'allow_approximate_filters', ''))::boolean,
        NULLIF(current_setting('pgl_validate.allow_approximate_filters', true), '')::boolean,
        false
    );
    allow_degraded_fence boolean := COALESCE(
        (NULLIF(options->>'allow_degraded_fence', ''))::boolean,
        NULLIF(current_setting('pgl_validate.allow_degraded_fence', true), '')::boolean,
        false
    );
    approximate_filter_mode boolean := false;
    sync_status "char" := 'r';
    validated_property text := 'full';
    exact_comparable boolean := true;
    contract_reason text := 'direct full-table comparison';
    issue_code text;
    pglogical_available boolean;
    table_in_pglogical boolean := false;
    table_in_native_publication boolean := false;
    requested_backend text;
    provider_dsn text;
    provider_node text;
    provider_node_filter text;
    fence_timeout_ms int;
    fence_poll_interval_ms int;
    on_fence_timeout text;
    on_precondition_fail text;
    partial_mode boolean := false;
    degraded_mode boolean := false;
    skipped_peers text[] := ARRAY[]::text[];
    skipped_peer_details text[] := ARRAY[]::text[];
    edge_seq int := 0;
    current_edge_ids int[] := ARRAY[]::int[];
    subscription_rec record;
    reverse_subscription_rec record;
    reverse_subscription_count int;
    reverse_status_text text;
    reverse_sync_status "char";
    table_sync_rec record;
    fence_rec pgl_validate.fence_attempt;
    peer_names text[];
    missing_peers text[];
    selected_peer_count int := 0;
    standby_peer_count int := 0;
    pglogical_peer_count int := 0;
    native_subscription_peer_count int := 0;
    peer_rec record;
    remote_rec record;
    range_rec record;
    child_chunk_id bigint;
    planned_chunk_count int := 0;
    chunk_differ_count int := 0;
    classified_divergence_count int := 0;
    reported_divergence_count int := 0;
    range_target_rows int;
    checksum_sql text;
    remote_checksum_sql text;
    remote_set_hash_sql text;
    local_schema_signature text;
    remote_schema_sql text;
    remote_schema_rec record;
    schema_mismatch_count int := 0;
    schema_error_details text[] := ARRAY[]::text[];
    localize_sql text;
    remote_localize_sql text;
    n_rows bigint;
    lthash bytea;
    set_hash bytea;
    chunk_n_rows bigint;
    chunk_lthash bytea;
    chunk_set_hash bytea;
    differ_count int := 0;
    confirmed_count int := 0;
    advisory_count int := 0;
    indeterminate_count int := 0;
    participant_count int := 1;
    verdict text;
    result_reason text;
    result_row pgl_validate.table_result;
    paranoid_unbounded boolean := false;
    paranoid_confirm boolean := COALESCE(
        (NULLIF(options->>'paranoid_confirm', ''))::boolean,
        NULLIF(current_setting('pgl_validate.paranoid_confirm', true), '')::boolean,
        false
    );
    paranoid_confirm_max_rows int := COALESCE(
        (NULLIF(options->>'paranoid_confirm_max_rows', ''))::int,
        NULLIF(current_setting('pgl_validate.paranoid_confirm_max_rows', true), '')::int,
        1000
    );
    max_reported_tuple_bytes int := COALESCE(
        (NULLIF(options->>'max_reported_tuple_bytes', ''))::int,
        NULLIF(current_setting('pgl_validate.max_reported_tuple_bytes', true), '')::int,
        8192
    );
    max_reported_divergences int := COALESCE(
        (NULLIF(options->>'max_reported_divergences', ''))::int,
        NULLIF(current_setting('pgl_validate.max_reported_divergences', true), '')::int,
        1000
    );
    hash_algorithm text := COALESCE(
        NULLIF(options->>'hash_algorithm', ''),
        NULLIF(current_setting('pgl_validate.hash_algorithm', true), ''),
        'blake3_256'
    );
    chunk_target_rows int := COALESCE(
        (NULLIF(options->>'chunk_target_rows', ''))::int,
        NULLIF(current_setting('pgl_validate.chunk_target_rows', true), '')::int,
        50000
    );
    chunk_max_duration interval := COALESCE(
        (NULLIF(options->>'chunk_max_duration', ''))::interval,
        (NULLIF(current_setting('pgl_validate.chunk_max_duration', true), ''))::interval,
        interval '2 seconds'
    );
    localize_threshold int := COALESCE(
        (NULLIF(options->>'localize_threshold', ''))::int,
        NULLIF(current_setting('pgl_validate.localize_threshold', true), '')::int,
        1000
    );
    max_parallel_chunks int := COALESCE(
        (NULLIF(options->>'max_parallel_chunks', ''))::int,
        NULLIF(current_setting('pgl_validate.max_parallel_chunks', true), '')::int,
        4
    );
    recheck_passes int := COALESCE(
        (NULLIF(options->>'recheck_passes', ''))::int,
        NULLIF(current_setting('pgl_validate.recheck_passes', true), '')::int,
        3
    );
    max_snapshot_age interval := COALESCE(
        (NULLIF(options->>'max_snapshot_age', ''))::interval,
        (NULLIF(current_setting('pgl_validate.max_snapshot_age', true), ''))::interval,
        interval '5 minutes'
    );
    statement_timeout_per_chunk interval := COALESCE(
        (NULLIF(options->>'statement_timeout_per_chunk', ''))::interval,
        (NULLIF(current_setting('pgl_validate.statement_timeout_per_chunk', true), ''))::interval,
        interval '30 seconds'
    );
    statement_timeout_per_chunk_ms int;
    previous_statement_timeout text;
    throttle_max_lag_setting text := COALESCE(
        NULLIF(options->>'throttle_max_lag', ''),
        NULLIF(current_setting('pgl_validate.throttle_max_lag', true), ''),
        'off'
    );
    throttle_max_lag interval;
    correlate_conflict_history boolean := COALESCE(
        (NULLIF(options->>'correlate_conflict_history', ''))::boolean,
        NULLIF(current_setting('pgl_validate.correlate_conflict_history', true), '')::boolean,
        true
    );
    conflict_history_lookback interval := COALESCE((NULLIF(options->>'conflict_history_lookback', ''))::interval, interval '24 hours');
    conflict_history_max_rows int := COALESCE(
        (NULLIF(options->>'conflict_history_max_rows', ''))::int,
        NULLIF(current_setting('pgl_validate.conflict_history_max_rows', true), '')::int,
        1000
    );
    stored_options jsonb;
BEGIN
    SELECT n.nspname, c.relname
    INTO v_schema_name, v_rel_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_table_name;

    IF v_schema_name IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', p_table_name;
    END IF;

    SELECT array_agg(a.attname ORDER BY a.attname)
    INTO cols
    FROM pg_attribute a
    WHERE a.attrelid = p_table_name
      AND a.attnum > 0
      AND NOT a.attisdropped;

    key_cols := pgl_validate.comparison_key_cols(p_table_name);

    requested_backend := NULLIF(options->>'backend', '');
    IF requested_backend IS NOT NULL
       AND requested_backend NOT IN ('pglogical','native','standby') THEN
        RAISE EXCEPTION 'unsupported backend %', requested_backend
            USING ERRCODE = '0A000';
    END IF;
    provider_dsn := NULLIF(options->>'provider_dsn', '');
    provider_node := COALESCE(NULLIF(options->>'provider_node', ''), 'local');
    provider_node_filter := provider_node;
    fence_timeout_ms := COALESCE(
        (NULLIF(options->>'fence_timeout_ms', ''))::int,
        NULLIF(current_setting('pgl_validate.fence_timeout_ms', true), '')::int,
        300000
    );
    fence_poll_interval_ms := COALESCE(
        (NULLIF(options->>'fence_poll_interval_ms', ''))::int,
        NULLIF(current_setting('pgl_validate.fence_poll_interval_ms', true), '')::int,
        100
    );
    on_fence_timeout := COALESCE(NULLIF(options->>'on_fence_timeout', ''), 'abort_run');
    on_precondition_fail := COALESCE(NULLIF(options->>'on_precondition_fail', ''), 'skip_table');
    contract_subscription := NULLIF(options->>'subscription', '')::name;
    pglogical_available := to_regprocedure('pglogical.show_repset_table_info(regclass,text[])') IS NOT NULL;

    IF on_fence_timeout NOT IN ('abort_run','skip_peer') THEN
        RAISE EXCEPTION 'on_fence_timeout must be abort_run or skip_peer';
    END IF;
    IF on_precondition_fail NOT IN ('skip_table','abort_run') THEN
        RAISE EXCEPTION 'on_precondition_fail must be skip_table or abort_run';
    END IF;
    IF fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF fence_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'fence_poll_interval_ms must be greater than zero';
    END IF;
    IF paranoid_confirm_max_rows <= 0 THEN
        RAISE EXCEPTION 'paranoid_confirm_max_rows must be greater than zero';
    END IF;
    IF max_reported_tuple_bytes <= 0 THEN
        RAISE EXCEPTION 'max_reported_tuple_bytes must be greater than zero';
    END IF;
    IF max_reported_divergences <= 0 THEN
        RAISE EXCEPTION 'max_reported_divergences must be greater than zero';
    END IF;
    IF hash_algorithm NOT IN ('blake3_256','blake3_512') THEN
        RAISE EXCEPTION 'hash_algorithm % is not implemented; supported values are blake3_256, blake3_512', hash_algorithm
            USING ERRCODE = '0A000';
    END IF;
    PERFORM set_config('pgl_validate.hash_algorithm', hash_algorithm, true);
    stored_options := (COALESCE(options, '{}'::jsonb) - '_pgl_validate_parent_run_id')
        || jsonb_build_object('hash_algorithm', hash_algorithm);
    IF chunk_target_rows <= 0 THEN
        RAISE EXCEPTION 'chunk_target_rows must be greater than zero';
    END IF;
    IF chunk_max_duration <= interval '0' THEN
        RAISE EXCEPTION 'chunk_max_duration must be greater than zero';
    END IF;
    IF localize_threshold <= 0 THEN
        RAISE EXCEPTION 'localize_threshold must be greater than zero';
    END IF;
    IF max_parallel_chunks <= 0 THEN
        RAISE EXCEPTION 'max_parallel_chunks must be greater than zero';
    END IF;
    IF recheck_passes <= 0 THEN
        RAISE EXCEPTION 'recheck_passes must be greater than zero';
    END IF;
    IF max_snapshot_age <= interval '0' THEN
        RAISE EXCEPTION 'max_snapshot_age must be greater than zero';
    END IF;
    IF statement_timeout_per_chunk <= interval '0' THEN
        RAISE EXCEPTION 'statement_timeout_per_chunk must be greater than zero';
    END IF;
    statement_timeout_per_chunk_ms := ceil(extract(epoch FROM statement_timeout_per_chunk) * 1000)::int;
    IF statement_timeout_per_chunk_ms <= 0 THEN
        RAISE EXCEPTION 'statement_timeout_per_chunk must be at least one millisecond';
    END IF;
    IF lower(throttle_max_lag_setting) = 'off' THEN
        throttle_max_lag := NULL;
    ELSE
        throttle_max_lag := throttle_max_lag_setting::interval;
        IF throttle_max_lag <= interval '0' THEN
            RAISE EXCEPTION 'throttle_max_lag must be greater than zero or off';
        END IF;
    END IF;

    IF peers IS NULL OR cardinality(peers) = 0 THEN
        SELECT COALESCE(array_agg(p.name ORDER BY p.name), ARRAY[]::text[])
        INTO peer_names
        FROM pgl_validate.peer p;
    ELSE
        SELECT array_agg(DISTINCT requested.peer_name ORDER BY requested.peer_name)
        INTO peer_names
        FROM unnest(peers) AS requested(peer_name);

        SELECT array_agg(requested.peer_name ORDER BY requested.peer_name)
        INTO missing_peers
        FROM unnest(peer_names) AS requested(peer_name)
        LEFT JOIN pgl_validate.peer p ON p.name = requested.peer_name
        WHERE p.name IS NULL;

        IF missing_peers IS NOT NULL THEN
            RAISE EXCEPTION 'unknown pgl_validate peer(s): %', array_to_string(missing_peers, ', ');
        END IF;
    END IF;

    SELECT count(*),
           count(*) FILTER (WHERE p.backend = 'standby'),
           count(*) FILTER (WHERE p.backend = 'pglogical'),
           count(*) FILTER (WHERE p.backend = 'native' AND p.subscription_name IS NOT NULL)
    INTO selected_peer_count, standby_peer_count, pglogical_peer_count, native_subscription_peer_count
    FROM pgl_validate.peer p
    WHERE p.name = ANY (peer_names);

    requested_backend := COALESCE(
        requested_backend,
        CASE
            WHEN options ? 'publications' THEN 'native'
            WHEN selected_peer_count > 0 AND standby_peer_count = selected_peer_count THEN 'standby'
            ELSE 'pglogical'
        END
    );

    IF standby_peer_count > 0
       AND (requested_backend <> 'standby'
            OR standby_peer_count <> selected_peer_count) THEN
        RAISE EXCEPTION
            'standby peers require a standby-only comparison backend'
            USING ERRCODE = '0A000';
    END IF;

    IF requested_backend = 'standby' THEN
        IF selected_peer_count = 0 THEN
            RAISE EXCEPTION 'backend=standby requires at least one registered standby peer'
                USING ERRCODE = '0A000';
        END IF;
        IF pg_is_in_recovery() THEN
            RAISE EXCEPTION 'backend=standby requires the coordinator to be a primary'
                USING ERRCODE = '0A000';
        END IF;
    END IF;

    IF options ? 'publications' THEN
        SELECT array_agg(DISTINCT elem.value ORDER BY elem.value)
        INTO contract_repsets
        FROM jsonb_array_elements_text(options->'publications') AS elem(value);
    ELSIF options ? 'repsets' THEN
        SELECT array_agg(DISTINCT elem.value ORDER BY elem.value)
        INTO contract_repsets
        FROM jsonb_array_elements_text(options->'repsets') AS elem(value);
    END IF;

    IF contract_repsets IS NULL OR cardinality(contract_repsets) = 0 THEN
        SELECT array_agg(DISTINCT peer_repset.repset ORDER BY peer_repset.repset)
        INTO contract_repsets
        FROM pgl_validate.peer p
        CROSS JOIN LATERAL unnest(p.replication_sets) AS peer_repset(repset)
        WHERE p.name = ANY (peer_names);
    END IF;

    IF pglogical_available THEN
        SELECT EXISTS (
            SELECT 1
            FROM pglogical.replication_set_table rst
            WHERE rst.set_reloid = p_table_name
        )
        INTO table_in_pglogical;
    ELSIF options ? 'backend' AND requested_backend = 'pglogical' THEN
        RAISE EXCEPTION 'backend=pglogical requested but pglogical is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    IF requested_backend = 'native' THEN
        SELECT EXISTS (
            SELECT 1
            FROM pg_publication_tables pt
            WHERE pt.schemaname = v_schema_name
              AND pt.tablename = v_rel_name
              AND (
                  contract_repsets IS NULL
                  OR cardinality(contract_repsets) = 0
                  OR pt.pubname::text = ANY (contract_repsets)
              )
        )
        INTO table_in_native_publication;
    END IF;

    IF requested_backend = 'pglogical'
       AND pglogical_available
       AND (table_in_pglogical
            OR contract_repsets IS NOT NULL
            OR contract_subscription IS NOT NULL) THEN
        SELECT *
        INTO contract_rec
        FROM pgl_validate.pglogical_table_contract(
            p_table_name,
            contract_repsets,
            contract_subscription
        );

        cols := contract_rec.att_list;
        key_cols := contract_rec.key_cols;
        plan_repsets := contract_rec.repsets;
        repl_insert := contract_rec.repl_insert;
        repl_update := contract_rec.repl_update;
        repl_delete := contract_rec.repl_delete;
        repl_truncate := contract_rec.repl_truncate;
        has_row_filter := contract_rec.has_row_filter;
        row_filter_sql := contract_rec.row_filter_sql;
        row_filter_exact := contract_rec.row_filter_exact;
        sync_status := contract_rec.sync_status;
        validated_property := contract_rec.validated_property;
        exact_comparable := contract_rec.exact_comparable;
        contract_reason := contract_rec.reason;
    ELSIF requested_backend = 'native'
          AND (table_in_native_publication
               OR contract_repsets IS NOT NULL
               OR contract_subscription IS NOT NULL
               OR options ? 'backend') THEN
        SELECT *
        INTO contract_rec
        FROM pgl_validate.native_table_contract(
            p_table_name,
            contract_repsets,
            contract_subscription
        );

        cols := contract_rec.att_list;
        key_cols := contract_rec.key_cols;
        plan_repsets := contract_rec.repsets;
        repl_insert := contract_rec.repl_insert;
        repl_update := contract_rec.repl_update;
        repl_delete := contract_rec.repl_delete;
        repl_truncate := contract_rec.repl_truncate;
        has_row_filter := contract_rec.has_row_filter;
        row_filter_sql := contract_rec.row_filter_sql;
        row_filter_exact := contract_rec.row_filter_exact;
        sync_status := contract_rec.sync_status;
        validated_property := contract_rec.validated_property;
        exact_comparable := contract_rec.exact_comparable;
        contract_reason := contract_rec.reason;
    END IF;

    IF exact_comparable
       AND validated_property = 'full'
       AND (key_cols IS NULL OR cardinality(key_cols) = 0) THEN
        validated_property := 'keyless';
        contract_reason :=
            contract_reason || '; no comparison key found, using whole-relation keyless checksum contract';
    END IF;

    IF parent_run_id IS NULL THEN
        INSERT INTO pgl_validate.run(status, options, tables_total)
        VALUES ('running', stored_options, 1)
        RETURNING pgl_validate.run.run_id INTO v_run_id;
    ELSE
        SELECT r.run_id
        INTO v_run_id
        FROM pgl_validate.run r
        WHERE r.run_id = parent_run_id
          AND r.status IN ('planning','fencing','running','rechecking','paused');

        IF v_run_id IS NULL THEN
            RAISE EXCEPTION 'parent validation run % does not exist or is not appendable', parent_run_id
                USING ERRCODE = '55000';
        END IF;

        append_to_parent := true;
        SELECT COALESCE(max(fe.epoch_seq), 0) + 1
        INTO initial_epoch
        FROM pgl_validate.fence_epoch fe
        WHERE fe.run_id = v_run_id;
        recheck_epoch := initial_epoch + 1;

        SELECT COALESCE(max(re.edge_id), 0)
        INTO edge_seq
        FROM pgl_validate.run_edge re
        WHERE re.run_id = v_run_id;

        UPDATE pgl_validate.run
        SET options = pgl_validate.run.options
            || jsonb_build_object('hash_algorithm', hash_algorithm)
        WHERE pgl_validate.run.run_id = v_run_id;
    END IF;

    INSERT INTO pgl_validate.run_participant(run_id, node, role, backend, pg_version, status)
    VALUES (v_run_id, 'local', 'coordinator', requested_backend, current_setting('server_version_num')::int, 'connected')
    ON CONFLICT (run_id, node) DO UPDATE
    SET status = 'connected',
        pg_version = EXCLUDED.pg_version;

    INSERT INTO pgl_validate.table_plan(
        run_id, schema_name, table_name, key_cols, att_list, repsets,
        repl_insert, repl_update, repl_delete, repl_truncate,
        has_row_filter, sync_status, validated_property
    )
    VALUES (
        v_run_id, v_schema_name, v_rel_name, key_cols, cols, plan_repsets,
        repl_insert, repl_update, repl_delete, repl_truncate,
        has_row_filter, sync_status, validated_property
    );

    IF current_setting('track_commit_timestamp', true) = 'off' THEN
        INSERT INTO pgl_validate.schema_issue(
            run_id, node, schema_name, table_name, issue_code, detail
        )
        VALUES (
            v_run_id,
            provider_node,
            v_schema_name,
            v_rel_name,
            'NO_COMMIT_TS',
            'track_commit_timestamp is off; validation remains sound, but origin-attribution diagnostics and last-update-wins repair are unavailable'
        )
        ON CONFLICT DO NOTHING;
    END IF;

    approximate_filter_mode :=
        NOT exact_comparable
        AND has_row_filter
        AND NOT row_filter_exact
        AND allow_approximate_filters;

    IF approximate_filter_mode THEN
        INSERT INTO pgl_validate.schema_issue(
            run_id, node, schema_name, table_name, issue_code, detail
        )
        VALUES (
            v_run_id,
            provider_node,
            v_schema_name,
            v_rel_name,
            'NONDETERMINISTIC_ROW_FILTER',
            contract_reason
        )
        ON CONFLICT DO NOTHING;

        IF requested_backend = 'pglogical' THEN
            checksum_sql := pgl_validate.plan_pglogical_filtered_sql(
                p_table_name,
                cols,
                plan_repsets,
                false
            );
        ELSE
            checksum_sql := pgl_validate.plan_chunk_sql(
                p_table_name,
                key_cols,
                NULL,
                NULL,
                cols,
                NULL,
                row_filter_sql,
                false
            );
        END IF;

        previous_statement_timeout := current_setting('statement_timeout');
        PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
        BEGIN
            EXECUTE checksum_sql INTO n_rows, lthash, set_hash;
        EXCEPTION WHEN others THEN
            PERFORM set_config('statement_timeout', previous_statement_timeout, true);
            RAISE;
        END;
        PERFORM set_config('statement_timeout', previous_statement_timeout, true);

        INSERT INTO pgl_validate.table_node_result(
            run_id, schema_name, table_name, node, n_rows, lthash, set_hash
        )
        VALUES (v_run_id, v_schema_name, v_rel_name, 'local', n_rows, lthash, set_hash);

        remote_checksum_sql := pgl_validate.plan_chunk_sql(
            p_table_name,
            key_cols,
            NULL,
            NULL,
            cols,
            NULL,
            NULL,
            false
        );

        differ_count := 0;
        participant_count := 1;
        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
            ORDER BY p.name
        LOOP
            SELECT rc.pg_version, rc.n_rows, rc.lthash, rc.set_hash
            INTO remote_rec
            FROM pgl_validate.remote_checksum(
                peer_rec.dsn,
                remote_checksum_sql,
                peer_rec.connect_timeout_seconds,
                LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
                peer_rec.lock_timeout_ms
            ) AS rc;

            participant_count := participant_count + 1;

            INSERT INTO pgl_validate.run_participant(
                run_id, node, role, backend, pg_version, dsn_ref, status
            )
            VALUES (
                v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                remote_rec.pg_version, peer_rec.name, 'done'
            )
            ON CONFLICT (run_id, node) DO UPDATE
            SET backend = EXCLUDED.backend,
                pg_version = EXCLUDED.pg_version,
                dsn_ref = EXCLUDED.dsn_ref,
                status = EXCLUDED.status;

            INSERT INTO pgl_validate.table_node_result(
                run_id, schema_name, table_name, node, n_rows, lthash, set_hash
            )
            VALUES (
                v_run_id, v_schema_name, v_rel_name, peer_rec.name,
                remote_rec.n_rows, remote_rec.lthash, remote_rec.set_hash
            );

            IF remote_rec.n_rows IS DISTINCT FROM n_rows
               OR remote_rec.lthash IS DISTINCT FROM lthash THEN
                differ_count := differ_count + 1;
            END IF;
        END LOOP;

        verdict := 'approximate';
        result_reason := format(
            'approximate row-filter diagnostic %s across %s participant(s); exact validation refused: %s',
            CASE WHEN differ_count = 0 THEN 'matched' ELSE 'found checksum differences' END,
            participant_count,
            contract_reason
        );

        INSERT INTO pgl_validate.table_result(
            run_id, schema_name, table_name, verdict, reason, finished_at
        )
        VALUES (
            v_run_id, v_schema_name, v_rel_name, verdict, result_reason, now()
        )
        RETURNING * INTO result_row;

        INSERT INTO pgl_validate.chunk_result(
            run_id, schema_name, table_name, chunk_id, parent_id, lo, hi, state, updated_at
        )
        VALUES (
            v_run_id,
            v_schema_name,
            v_rel_name,
            1,
            NULL,
            NULL,
            NULL,
            'candidate',
            now()
        )
        ON CONFLICT (run_id, schema_name, table_name, chunk_id) DO UPDATE
        SET state = EXCLUDED.state,
            updated_at = EXCLUDED.updated_at;

        INSERT INTO pgl_validate.chunk_node_result(
            run_id, schema_name, table_name, chunk_id, node, n_rows, lthash
        )
        SELECT
            tnr.run_id,
            tnr.schema_name,
            tnr.table_name,
            1,
            tnr.node,
            tnr.n_rows,
            tnr.lthash
        FROM pgl_validate.table_node_result tnr
        WHERE tnr.run_id = v_run_id
          AND tnr.schema_name = v_schema_name
          AND tnr.table_name = v_rel_name
        ON CONFLICT (run_id, schema_name, table_name, chunk_id, node) DO UPDATE
        SET n_rows = EXCLUDED.n_rows,
            lthash = EXCLUDED.lthash;

        IF NOT append_to_parent THEN
            UPDATE pgl_validate.run
            SET status = 'completed',
                finished_at = now(),
                tables_matched = 0,
                tables_differ = 0
            WHERE pgl_validate.run.run_id = v_run_id;

            UPDATE pgl_validate.run_participant
            SET status = 'done'
            WHERE pgl_validate.run_participant.run_id = v_run_id
              AND node = 'local';
        END IF;

        RETURN result_row;
    END IF;

    IF NOT exact_comparable THEN
        issue_code := CASE
            WHEN has_row_filter AND NOT row_filter_exact THEN 'NONDETERMINISTIC_ROW_FILTER'
            WHEN sync_status IS NOT NULL AND sync_status <> 'r' THEN 'SYNC_NOT_READY'
            WHEN validated_property = 'unsupported_mask' THEN 'UNSUPPORTED_ACTION_MASK'
            WHEN validated_property = 'filtered_advisory' THEN 'FILTERED_ADVISORY_ONLY'
            WHEN contract_reason ILIKE '%incompatible column list%' THEN 'INCOMPATIBLE_COLUMN_LIST'
            WHEN contract_reason ILIKE '%not a member%' THEN 'TABLE_NOT_IN_REPLICATION_CONTRACT'
            ELSE 'NOT_EXACT_COMPARABLE'
        END;

        INSERT INTO pgl_validate.schema_issue(
            run_id, node, schema_name, table_name, issue_code, detail
        )
        VALUES (
            v_run_id,
            provider_node,
            v_schema_name,
            v_rel_name,
            issue_code,
            contract_reason
        )
        ON CONFLICT DO NOTHING;

        verdict := CASE
            WHEN validated_property IN ('skipped','unsupported_mask') THEN 'skipped'
            ELSE 'partial'
        END;
        result_reason := format(
            'pglogical contract %s is not yet exact-comparable by the checksum-only path: %s',
            validated_property,
            contract_reason
        );

        INSERT INTO pgl_validate.table_result(
            run_id, schema_name, table_name, verdict, reason, finished_at
        )
        VALUES (
            v_run_id, v_schema_name, v_rel_name, verdict, result_reason, now()
        )
        RETURNING * INTO result_row;

        IF NOT append_to_parent THEN
            UPDATE pgl_validate.run
            SET status = 'completed',
                finished_at = now(),
                tables_matched = 0,
                tables_differ = 0
            WHERE pgl_validate.run.run_id = v_run_id;

            UPDATE pgl_validate.run_participant
            SET status = 'done'
            WHERE pgl_validate.run_participant.run_id = v_run_id
              AND node = 'local';
        END IF;

        RETURN result_row;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pgl_validate.peer p
        WHERE p.name = ANY (peer_names)
          AND p.backend = 'pglogical'
    ) THEN
        IF provider_dsn IS NULL THEN
            RAISE EXCEPTION
                'options.provider_dsn is required when comparing pglogical peers'
                USING ERRCODE = '0A000';
        END IF;

        INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
        VALUES (v_run_id, initial_epoch);

        UPDATE pgl_validate.run
        SET status = 'fencing'
        WHERE pgl_validate.run.run_id = v_run_id;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend, p.subscription_name, p.replication_sets,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
              AND p.backend = 'pglogical'
            ORDER BY p.name
        LOOP
            IF peer_rec.subscription_name IS NULL THEN
                RAISE EXCEPTION
                    'pglogical peer % requires subscription_name for exact barrier fencing',
                    peer_rec.name
                    USING ERRCODE = '0A000';
            END IF;

            BEGIN
                SELECT *
                INTO subscription_rec
                FROM pgl_validate.remote_pglogical_subscription_status(
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms
                );

                IF subscription_rec.status <> 'replicating' THEN
                    RAISE EXCEPTION
                        'pglogical peer % subscription % is %, not replicating',
                        peer_rec.name,
                        peer_rec.subscription_name,
                        subscription_rec.status
                        USING ERRCODE = '57014';
                END IF;

                SELECT *
                INTO table_sync_rec
                FROM pgl_validate.remote_pglogical_table_sync_status(
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    v_schema_name,
                    v_rel_name,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms
                );

                IF COALESCE(table_sync_rec.sync_status, '<missing>') <> 'r' THEN
                    partial_mode := true;
                    skipped_peers := skipped_peers || peer_rec.name;
                    skipped_peer_details := skipped_peer_details || format(
                        '%s sync_status=%s sync_status_lsn=%s',
                        peer_rec.name,
                        COALESCE(table_sync_rec.sync_status, '<missing>'),
                        COALESCE(table_sync_rec.sync_status_lsn::text, '<none>')
                    );
                    peer_names := array_remove(peer_names, peer_rec.name);

                    INSERT INTO pgl_validate.run_participant(
                        run_id, node, role, backend, pg_version, dsn_ref, status
                    )
                    VALUES (
                        v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                        0, peer_rec.name, 'skipped'
                    )
                    ON CONFLICT (run_id, node) DO UPDATE
                    SET backend = EXCLUDED.backend,
                        pg_version = EXCLUDED.pg_version,
                        dsn_ref = EXCLUDED.dsn_ref,
                        status = 'skipped';

                    INSERT INTO pgl_validate.schema_issue(
                        run_id, node, schema_name, table_name, issue_code, detail
                    )
                    VALUES (
                        v_run_id,
                        peer_rec.name,
                        v_schema_name,
                        v_rel_name,
                        'SYNC_NOT_READY',
                        format(
                            'pglogical subscription %s table sync_status=%s sync_status_lsn=%s; peer skipped for this table',
                            peer_rec.subscription_name,
                            COALESCE(table_sync_rec.sync_status, '<missing>'),
                            COALESCE(table_sync_rec.sync_status_lsn::text, '<none>')
                        )
                    )
                    ON CONFLICT DO NOTHING;

                    CONTINUE;
                END IF;

                IF NOT (subscription_rec.replication_sets_json::jsonb ? 'pgl_validate_barrier') THEN
                    IF NOT allow_degraded_fence THEN
                        RAISE EXCEPTION
                            'pglogical peer % subscription % does not include pgl_validate_barrier',
                            peer_rec.name,
                            peer_rec.subscription_name
                            USING ERRCODE = '0A000';
                    END IF;

                    edge_seq := edge_seq + 1;
                    current_edge_ids := current_edge_ids || edge_seq;
                    degraded_mode := true;

                    SELECT *
                    INTO fence_rec
                    FROM pgl_validate.fence_pglogical_degraded_edge(
                        v_run_id,
                        initial_epoch,
                        edge_seq,
                        provider_node,
                        peer_rec.name,
                        provider_dsn,
                        peer_rec.subscription_name::text,
                        subscription_rec.slot_name,
                        subscription_rec.slot_name,
                        peer_rec.replication_sets,
                        peer_rec.connect_timeout_seconds,
                        peer_rec.statement_timeout_ms,
                        peer_rec.lock_timeout_ms
                    );

                    IF fence_rec.status <> 'degraded' THEN
                        RAISE EXCEPTION
                            'pglogical peer % failed to record degraded fence: %',
                            peer_rec.name,
                            fence_rec.status
                            USING ERRCODE = '57014';
                    END IF;

                    CONTINUE;
                END IF;

                edge_seq := edge_seq + 1;
                current_edge_ids := current_edge_ids || edge_seq;
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_edge(
                    v_run_id,
                    initial_epoch,
                    edge_seq,
                    provider_node,
                    peer_rec.name,
                    provider_dsn,
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    subscription_rec.slot_name,
                    subscription_rec.slot_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'pglogical peer % failed to converge barrier fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            EXCEPTION WHEN others THEN
                IF on_fence_timeout <> 'skip_peer' THEN
                    RAISE;
                END IF;

                partial_mode := true;
                skipped_peers := skipped_peers || peer_rec.name;
                skipped_peer_details := skipped_peer_details || format(
                    '%s under on_fence_timeout=skip_peer: %s',
                    peer_rec.name,
                    SQLERRM
                );
                peer_names := array_remove(peer_names, peer_rec.name);

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    0, peer_rec.name, 'unreachable'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = 'unreachable';

                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'PEER_SKIPPED',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;

                CONTINUE;
            END;
        END LOOP;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend, p.reverse_subscription_name,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
              AND p.backend = 'pglogical'
              AND p.reverse_subscription_name IS NOT NULL
            ORDER BY p.name
        LOOP
            BEGIN
                SELECT count(*)
                INTO reverse_subscription_count
                FROM pglogical.show_subscription_status(peer_rec.reverse_subscription_name) AS s;

                IF reverse_subscription_count = 0 THEN
                    RAISE EXCEPTION
                        'pglogical peer % reverse subscription % was not found on coordinator',
                        peer_rec.name,
                        peer_rec.reverse_subscription_name
                        USING ERRCODE = '02000';
                END IF;

                IF reverse_subscription_count > 1 THEN
                    RAISE EXCEPTION
                        'pglogical peer % has multiple local reverse subscriptions; set pgl_validate.peer.reverse_subscription_name',
                        peer_rec.name
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO reverse_subscription_rec
                FROM pglogical.show_subscription_status(peer_rec.reverse_subscription_name) AS s
                LIMIT 1;

                IF reverse_subscription_rec.status <> 'replicating' THEN
                    RAISE EXCEPTION
                        'pglogical reverse edge % -> % subscription % is %, not replicating',
                        peer_rec.name,
                        provider_node,
                        reverse_subscription_rec.subscription_name,
                        reverse_subscription_rec.status
                        USING ERRCODE = '57014';
                END IF;

                SELECT s.status
                INTO reverse_status_text
                FROM pglogical.show_subscription_table(
                    reverse_subscription_rec.subscription_name::name,
                    p_table_name
                ) AS s;

                IF reverse_status_text IS NULL THEN
                    CONTINUE;
                END IF;

                reverse_sync_status := left(reverse_status_text, 1)::"char";
                IF reverse_sync_status <> 'r' THEN
                    partial_mode := true;
                    skipped_peers := skipped_peers || peer_rec.name;
                    skipped_peer_details := skipped_peer_details || format(
                        '%s reverse sync_status=%s',
                        peer_rec.name,
                        COALESCE(reverse_sync_status::text, '<missing>')
                    );
                    peer_names := array_remove(peer_names, peer_rec.name);

                    INSERT INTO pgl_validate.run_participant(
                        run_id, node, role, backend, pg_version, dsn_ref, status
                    )
                    VALUES (
                        v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                        0, peer_rec.name, 'skipped'
                    )
                    ON CONFLICT (run_id, node) DO UPDATE
                    SET backend = EXCLUDED.backend,
                        pg_version = EXCLUDED.pg_version,
                        dsn_ref = EXCLUDED.dsn_ref,
                        status = 'skipped';

                    INSERT INTO pgl_validate.schema_issue(
                        run_id, node, schema_name, table_name, issue_code, detail
                    )
                    VALUES (
                        v_run_id,
                        provider_node,
                        v_schema_name,
                        v_rel_name,
                        'SYNC_NOT_READY',
                        format(
                            'pglogical reverse subscription %s table sync_status=%s; peer skipped for this table',
                            reverse_subscription_rec.subscription_name,
                            COALESCE(reverse_sync_status::text, '<missing>')
                        )
                    )
                    ON CONFLICT DO NOTHING;

                    CONTINUE;
                END IF;

                IF NOT ('pgl_validate_barrier' = ANY (COALESCE(reverse_subscription_rec.replication_sets, ARRAY[]::text[]))) THEN
                    IF NOT allow_degraded_fence THEN
                        RAISE EXCEPTION
                            'pglogical reverse edge % -> % subscription % does not include pgl_validate_barrier',
                            peer_rec.name,
                            provider_node,
                            reverse_subscription_rec.subscription_name
                            USING ERRCODE = '0A000';
                    END IF;

                    edge_seq := edge_seq + 1;
                    current_edge_ids := current_edge_ids || edge_seq;
                    degraded_mode := true;

                    SELECT *
                    INTO fence_rec
                    FROM pgl_validate.fence_pglogical_degraded_edge(
                        v_run_id,
                        initial_epoch,
                        edge_seq,
                        peer_rec.name,
                        provider_node,
                        peer_rec.dsn,
                        reverse_subscription_rec.subscription_name::text,
                        reverse_subscription_rec.slot_name,
                        reverse_subscription_rec.slot_name,
                        reverse_subscription_rec.replication_sets,
                        peer_rec.connect_timeout_seconds,
                        peer_rec.statement_timeout_ms,
                        peer_rec.lock_timeout_ms
                    );

                    IF fence_rec.status <> 'degraded' THEN
                        RAISE EXCEPTION
                            'pglogical reverse edge % -> % failed to record degraded fence: %',
                            peer_rec.name,
                            provider_node,
                            fence_rec.status
                            USING ERRCODE = '57014';
                    END IF;

                    CONTINUE;
                END IF;

                edge_seq := edge_seq + 1;
                current_edge_ids := current_edge_ids || edge_seq;
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_edge(
                    v_run_id,
                    initial_epoch,
                    edge_seq,
                    peer_rec.name,
                    provider_node,
                    peer_rec.dsn,
                    provider_dsn,
                    reverse_subscription_rec.subscription_name::text,
                    reverse_subscription_rec.slot_name,
                    reverse_subscription_rec.slot_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'pglogical reverse edge % -> % failed to converge barrier fence: %',
                        peer_rec.name,
                        provider_node,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            EXCEPTION WHEN others THEN
                IF on_fence_timeout <> 'skip_peer' THEN
                    RAISE;
                END IF;

                partial_mode := true;
                skipped_peers := skipped_peers || peer_rec.name;
                skipped_peer_details := skipped_peer_details || format(
                    '%s reverse edge under on_fence_timeout=skip_peer: %s',
                    peer_rec.name,
                    SQLERRM
                );
                peer_names := array_remove(peer_names, peer_rec.name);

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    0, peer_rec.name, 'unreachable'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = 'unreachable';

                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'PEER_SKIPPED',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;

                CONTINUE;
            END;
        END LOOP;

        UPDATE pgl_validate.run_participant
        SET status = 'converged'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';
    END IF;

    IF native_subscription_peer_count > 0 THEN
        IF provider_dsn IS NULL THEN
            RAISE EXCEPTION
                'options.provider_dsn is required when comparing native logical subscription peers'
                USING ERRCODE = '0A000';
        END IF;

        INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
        VALUES (v_run_id, initial_epoch)
        ON CONFLICT DO NOTHING;

        UPDATE pgl_validate.run
        SET status = 'fencing'
        WHERE pgl_validate.run.run_id = v_run_id;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend, p.subscription_name, p.replication_sets,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
              AND p.backend = 'native'
              AND p.subscription_name IS NOT NULL
            ORDER BY p.name
        LOOP
            BEGIN
                SELECT *
                INTO subscription_rec
                FROM pgl_validate.remote_native_subscription_status(
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms
                );

                IF NOT subscription_rec.enabled THEN
                    RAISE EXCEPTION
                        'native peer % subscription % is disabled',
                        peer_rec.name,
                        peer_rec.subscription_name
                        USING ERRCODE = '57014';
                END IF;

                IF subscription_rec.slot_name IS NULL THEN
                    RAISE EXCEPTION
                        'native peer % subscription % has no provider slot',
                        peer_rec.name,
                        peer_rec.subscription_name
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO table_sync_rec
                FROM pgl_validate.remote_native_table_sync_status(
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    v_schema_name,
                    v_rel_name,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms
                );

                IF COALESCE(table_sync_rec.sync_status, '<missing>') <> 'r' THEN
                    partial_mode := true;
                    skipped_peers := skipped_peers || peer_rec.name;
                    skipped_peer_details := skipped_peer_details || format(
                        '%s sync_status=%s',
                        peer_rec.name,
                        COALESCE(table_sync_rec.sync_status, '<missing>')
                    );
                    peer_names := array_remove(peer_names, peer_rec.name);

                    INSERT INTO pgl_validate.run_participant(
                        run_id, node, role, backend, pg_version, dsn_ref, status
                    )
                    VALUES (
                        v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                        0, peer_rec.name, 'skipped'
                    )
                    ON CONFLICT (run_id, node) DO UPDATE
                    SET backend = EXCLUDED.backend,
                        pg_version = EXCLUDED.pg_version,
                        dsn_ref = EXCLUDED.dsn_ref,
                        status = 'skipped';

                    INSERT INTO pgl_validate.schema_issue(
                        run_id, node, schema_name, table_name, issue_code, detail
                    )
                    VALUES (
                        v_run_id,
                        peer_rec.name,
                        v_schema_name,
                        v_rel_name,
                        'SYNC_NOT_READY',
                        format(
                            'native subscription %s table sync_status=%s; peer skipped for this table',
                            peer_rec.subscription_name,
                            COALESCE(table_sync_rec.sync_status, '<missing>')
                        )
                    )
                    ON CONFLICT DO NOTHING;

                    CONTINUE;
                END IF;

                IF NOT (subscription_rec.publications_json::jsonb ? 'pgl_validate_barrier') THEN
                    IF NOT allow_degraded_fence THEN
                        RAISE EXCEPTION
                            'native peer % subscription % does not include pgl_validate_barrier',
                            peer_rec.name,
                            peer_rec.subscription_name
                            USING ERRCODE = '0A000';
                    END IF;

                    edge_seq := edge_seq + 1;
                    current_edge_ids := current_edge_ids || edge_seq;
                    degraded_mode := true;

                    SELECT *
                    INTO fence_rec
                    FROM pgl_validate.fence_native_degraded_edge(
                        v_run_id,
                        initial_epoch,
                        edge_seq,
                        provider_node,
                        peer_rec.name,
                        provider_dsn,
                        peer_rec.subscription_name::text,
                        subscription_rec.slot_name,
                        subscription_rec.origin_name,
                        peer_rec.replication_sets,
                        peer_rec.connect_timeout_seconds,
                        peer_rec.statement_timeout_ms,
                        peer_rec.lock_timeout_ms,
                        fence_timeout_ms,
                        fence_poll_interval_ms
                    );

                    IF fence_rec.status <> 'degraded' THEN
                        RAISE EXCEPTION
                            'native peer % failed to record degraded fence: %',
                            peer_rec.name,
                            fence_rec.status
                            USING ERRCODE = '57014';
                    END IF;

                    CONTINUE;
                END IF;

                edge_seq := edge_seq + 1;
                current_edge_ids := current_edge_ids || edge_seq;
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_native_edge(
                    v_run_id,
                    initial_epoch,
                    edge_seq,
                    provider_node,
                    peer_rec.name,
                    provider_dsn,
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    subscription_rec.slot_name,
                    subscription_rec.origin_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'native peer % failed to converge barrier fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            EXCEPTION WHEN others THEN
                IF on_fence_timeout <> 'skip_peer' THEN
                    RAISE;
                END IF;

                partial_mode := true;
                skipped_peers := skipped_peers || peer_rec.name;
                skipped_peer_details := skipped_peer_details || format(
                    '%s under on_fence_timeout=skip_peer: %s',
                    peer_rec.name,
                    SQLERRM
                );
                peer_names := array_remove(peer_names, peer_rec.name);

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    0, peer_rec.name, 'unreachable'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = 'unreachable';

                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'PEER_SKIPPED',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;

                CONTINUE;
            END;
        END LOOP;

        UPDATE pgl_validate.run_participant
        SET status = 'converged'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';
    END IF;

    IF standby_peer_count > 0 THEN
        INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
        VALUES (v_run_id, initial_epoch)
        ON CONFLICT DO NOTHING;

        UPDATE pgl_validate.run
        SET status = 'fencing'
        WHERE pgl_validate.run.run_id = v_run_id;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
              AND p.backend = 'standby'
            ORDER BY p.name
        LOOP
            edge_seq := edge_seq + 1;
            current_edge_ids := current_edge_ids || edge_seq;

            BEGIN
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_standby_edge(
                    v_run_id,
                    initial_epoch,
                    edge_seq,
                    provider_node,
                    peer_rec.name,
                    peer_rec.dsn,
                    NULL,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'standby peer % failed to converge replay fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            EXCEPTION WHEN others THEN
                IF on_fence_timeout <> 'skip_peer' THEN
                    RAISE;
                END IF;

                partial_mode := true;
                skipped_peers := skipped_peers || peer_rec.name;
                skipped_peer_details := skipped_peer_details || format(
                    '%s under on_fence_timeout=skip_peer: %s',
                    peer_rec.name,
                    SQLERRM
                );
                peer_names := array_remove(peer_names, peer_rec.name);

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    0, peer_rec.name, 'unreachable'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = 'unreachable';

                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'PEER_SKIPPED',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;

                CONTINUE;
            END;
        END LOOP;

        UPDATE pgl_validate.run_participant
        SET status = 'converged'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';
    END IF;

    IF peer_names IS NOT NULL AND cardinality(peer_names) > 0 THEN
        local_schema_signature :=
            pgl_validate.schema_signature(v_schema_name, v_rel_name, cols, key_cols)::text;
        remote_schema_sql :=
            pgl_validate.plan_schema_signature_sql(v_schema_name, v_rel_name, cols, key_cols);

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
            ORDER BY p.name
        LOOP
            BEGIN
                SELECT rss.pg_version, rss.signature
                INTO remote_schema_rec
                FROM pgl_validate.remote_schema_signature(
                    peer_rec.dsn,
                    remote_schema_sql,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms
                ) AS rss;

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    remote_schema_rec.pg_version, peer_rec.name, 'connected'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = CASE
                        WHEN pgl_validate.run_participant.status IN ('converged','done') THEN
                            pgl_validate.run_participant.status
                        ELSE EXCLUDED.status
                    END;

                IF remote_schema_rec.signature IS DISTINCT FROM local_schema_signature THEN
                    schema_mismatch_count := schema_mismatch_count + 1;
                    schema_error_details := schema_error_details || format(
                        '%s:SCHEMA_SIGNATURE_MISMATCH',
                        peer_rec.name
                    );

                    UPDATE pgl_validate.run_participant
                    SET status = 'error'
                    WHERE pgl_validate.run_participant.run_id = v_run_id
                      AND node = peer_rec.name;

                    INSERT INTO pgl_validate.schema_issue(
                        run_id, node, schema_name, table_name, issue_code, detail
                    )
                    VALUES (
                        v_run_id,
                        peer_rec.name,
                        v_schema_name,
                        v_rel_name,
                        'SCHEMA_SIGNATURE_MISMATCH',
                        format(
                            'schema precondition failed for compared columns=%s keys=%s; local=%s; remote=%s',
                            COALESCE(cols::text, '<all>'),
                            COALESCE(key_cols::text, '<none>'),
                            local_schema_signature,
                            remote_schema_rec.signature
                        )
                    )
                    ON CONFLICT DO NOTHING;
                END IF;
            EXCEPTION WHEN others THEN
                schema_mismatch_count := schema_mismatch_count + 1;
                schema_error_details := schema_error_details || format(
                    '%s:SCHEMA_CHECK_FAILED',
                    peer_rec.name
                );

                INSERT INTO pgl_validate.run_participant(
                    run_id, node, role, backend, pg_version, dsn_ref, status
                )
                VALUES (
                    v_run_id, peer_rec.name, 'participant', peer_rec.backend,
                    0, peer_rec.name, 'error'
                )
                ON CONFLICT (run_id, node) DO UPDATE
                SET backend = EXCLUDED.backend,
                    pg_version = EXCLUDED.pg_version,
                    dsn_ref = EXCLUDED.dsn_ref,
                    status = 'error';

                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'SCHEMA_CHECK_FAILED',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;
            END;
        END LOOP;

        IF schema_mismatch_count > 0 THEN
            result_reason := format(
                'schema precondition failed for %s peer(s): %s',
                schema_mismatch_count,
                array_to_string(schema_error_details, '; ')
            );

            IF on_precondition_fail = 'abort_run' THEN
                RAISE EXCEPTION '%', result_reason
                    USING ERRCODE = '0A000';
            END IF;

            INSERT INTO pgl_validate.table_result(
                run_id, schema_name, table_name, verdict, reason, finished_at
            )
            VALUES (
                v_run_id, v_schema_name, v_rel_name, 'skipped', result_reason, now()
            )
            RETURNING * INTO result_row;

            IF NOT append_to_parent THEN
                UPDATE pgl_validate.run
                SET status = 'completed',
                    finished_at = now(),
                    tables_matched = 0,
                    tables_differ = 0
                WHERE pgl_validate.run.run_id = v_run_id;

                UPDATE pgl_validate.run_participant
                SET status = 'done'
                WHERE pgl_validate.run_participant.run_id = v_run_id
                  AND node = 'local';
            END IF;

            RETURN result_row;
        END IF;
    END IF;

    UPDATE pgl_validate.run
    SET status = 'running'
    WHERE pgl_validate.run.run_id = v_run_id;

    checksum_sql := pgl_validate.plan_chunk_sql(
        p_table_name,
        key_cols,
        NULL,
        NULL,
        cols,
        NULL,
        row_filter_sql,
        false
    );
    remote_checksum_sql := pgl_validate.plan_chunk_sql(
        p_table_name,
        key_cols,
        NULL,
        NULL,
        cols,
        NULL,
        NULL,
        false
    );
    previous_statement_timeout := current_setting('statement_timeout');
    PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
    BEGIN
        EXECUTE checksum_sql INTO n_rows, lthash, set_hash;
    EXCEPTION WHEN others THEN
        PERFORM set_config('statement_timeout', previous_statement_timeout, true);
        RAISE;
    END;
    PERFORM set_config('statement_timeout', previous_statement_timeout, true);

    IF paranoid_confirm AND n_rows <= paranoid_confirm_max_rows THEN
        checksum_sql := pgl_validate.plan_chunk_sql(
            p_table_name,
            key_cols,
            NULL,
            NULL,
            cols,
            NULL,
            row_filter_sql,
            true
        );
        previous_statement_timeout := current_setting('statement_timeout');
        PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
        BEGIN
            EXECUTE checksum_sql INTO n_rows, lthash, set_hash;
        EXCEPTION WHEN others THEN
            PERFORM set_config('statement_timeout', previous_statement_timeout, true);
            RAISE;
        END;
        PERFORM set_config('statement_timeout', previous_statement_timeout, true);
    END IF;

    INSERT INTO pgl_validate.table_node_result(
        run_id, schema_name, table_name, node, n_rows, lthash, set_hash
    )
    VALUES (v_run_id, v_schema_name, v_rel_name, 'local', n_rows, lthash, set_hash);

    FOR peer_rec IN
        SELECT p.name, p.dsn, p.backend,
               p.connect_timeout_seconds,
               p.statement_timeout_ms,
               p.lock_timeout_ms
        FROM pgl_validate.peer p
        WHERE p.name = ANY (peer_names)
        ORDER BY p.name
    LOOP
        SELECT rc.pg_version, rc.n_rows, rc.lthash, rc.set_hash
        INTO remote_rec
        FROM pgl_validate.remote_checksum(
            peer_rec.dsn,
            remote_checksum_sql,
            peer_rec.connect_timeout_seconds,
            LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
            peer_rec.lock_timeout_ms
        ) AS rc;

        IF paranoid_confirm
           AND n_rows <= paranoid_confirm_max_rows
           AND remote_rec.n_rows <= paranoid_confirm_max_rows THEN
            remote_set_hash_sql := pgl_validate.plan_chunk_sql(
                p_table_name,
                key_cols,
                NULL,
                NULL,
                cols,
                NULL,
                NULL,
                true
            );

            SELECT rc.pg_version, rc.n_rows, rc.lthash, rc.set_hash
            INTO remote_rec
            FROM pgl_validate.remote_checksum(
                peer_rec.dsn,
                remote_set_hash_sql,
                peer_rec.connect_timeout_seconds,
                LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
                peer_rec.lock_timeout_ms
            ) AS rc;
        END IF;

        participant_count := participant_count + 1;

        INSERT INTO pgl_validate.run_participant(
            run_id, node, role, backend, pg_version, dsn_ref, status
        )
        VALUES (
            v_run_id, peer_rec.name, 'participant', peer_rec.backend,
            remote_rec.pg_version, peer_rec.name, 'done'
        )
        ON CONFLICT (run_id, node) DO UPDATE
        SET backend = EXCLUDED.backend,
            pg_version = EXCLUDED.pg_version,
            dsn_ref = EXCLUDED.dsn_ref,
            status = EXCLUDED.status;

        INSERT INTO pgl_validate.table_node_result(
            run_id, schema_name, table_name, node, n_rows, lthash, set_hash
        )
        VALUES (
            v_run_id, v_schema_name, v_rel_name, peer_rec.name,
            remote_rec.n_rows, remote_rec.lthash, remote_rec.set_hash
        );

        IF remote_rec.n_rows IS DISTINCT FROM n_rows
           OR remote_rec.lthash IS DISTINCT FROM lthash
           OR (paranoid_confirm AND remote_rec.set_hash IS DISTINCT FROM set_hash) THEN
            differ_count := differ_count + 1;
        END IF;
    END LOOP;

    range_target_rows := chunk_target_rows;
    IF differ_count > 0 THEN
        range_target_rows := LEAST(range_target_rows, localize_threshold);
    END IF;
    IF paranoid_confirm
       AND key_cols IS NOT NULL
       AND cardinality(key_cols) > 0 THEN
        range_target_rows := LEAST(range_target_rows, paranoid_confirm_max_rows);
    END IF;

    paranoid_unbounded :=
        paranoid_confirm
        AND (key_cols IS NULL OR cardinality(key_cols) = 0)
        AND n_rows > paranoid_confirm_max_rows;

    IF paranoid_unbounded THEN
        INSERT INTO pgl_validate.schema_issue(
            run_id, node, schema_name, table_name, issue_code, detail
        )
        VALUES (
            v_run_id,
            provider_node,
            v_schema_name,
            v_rel_name,
            'PARANOID_CONFIRM_REQUIRES_KEY',
            format(
                'paranoid_confirm requested for %s row keyless relation; cap is %s rows and no comparison key exists for bounded subdivision',
                n_rows,
                paranoid_confirm_max_rows
            )
        )
        ON CONFLICT DO NOTHING;
    END IF;

    IF key_cols IS NOT NULL
       AND cardinality(key_cols) > 0
       AND n_rows > range_target_rows THEN
        FOR range_rec IN
            SELECT *
            FROM pgl_validate.plan_key_ranges(
                p_table_name,
                key_cols,
                NULL,
                NULL,
                range_target_rows,
                row_filter_sql
            )
            ORDER BY chunk_id
        LOOP
            planned_chunk_count := planned_chunk_count + 1;
            child_chunk_id := range_rec.chunk_id + 1;
            chunk_differ_count := 0;

            INSERT INTO pgl_validate.chunk_result(
                run_id, schema_name, table_name, chunk_id, parent_id, lo, hi, state, updated_at
            )
            VALUES (
                v_run_id,
                v_schema_name,
                v_rel_name,
                child_chunk_id,
                1,
                range_rec.lo,
                range_rec.hi,
                'running',
                now()
            )
            ON CONFLICT (run_id, schema_name, table_name, chunk_id) DO UPDATE
            SET parent_id = EXCLUDED.parent_id,
                lo = EXCLUDED.lo,
                hi = EXCLUDED.hi,
                state = EXCLUDED.state,
                updated_at = EXCLUDED.updated_at;

            checksum_sql := pgl_validate.plan_chunk_sql(
                p_table_name,
                key_cols,
                range_rec.lo,
                range_rec.hi,
                cols,
                NULL,
                row_filter_sql,
                paranoid_confirm
            );
            previous_statement_timeout := current_setting('statement_timeout');
            PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
            BEGIN
                EXECUTE checksum_sql INTO chunk_n_rows, chunk_lthash, chunk_set_hash;
            EXCEPTION WHEN others THEN
                PERFORM set_config('statement_timeout', previous_statement_timeout, true);
                RAISE;
            END;
            PERFORM set_config('statement_timeout', previous_statement_timeout, true);

            INSERT INTO pgl_validate.chunk_node_result(
                run_id, schema_name, table_name, chunk_id, node, n_rows, lthash
            )
            VALUES (
                v_run_id,
                v_schema_name,
                v_rel_name,
                child_chunk_id,
                'local',
                chunk_n_rows,
                chunk_lthash
            )
            ON CONFLICT (run_id, schema_name, table_name, chunk_id, node) DO UPDATE
            SET n_rows = EXCLUDED.n_rows,
                lthash = EXCLUDED.lthash;

            remote_checksum_sql := pgl_validate.plan_chunk_sql(
                p_table_name,
                key_cols,
                range_rec.lo,
                range_rec.hi,
                cols,
                NULL,
                NULL,
                paranoid_confirm
            );

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms
                FROM pgl_validate.peer p
                WHERE p.name = ANY (peer_names)
                ORDER BY p.name
            LOOP
                SELECT rc.pg_version, rc.n_rows, rc.lthash, rc.set_hash
                INTO remote_rec
                FROM pgl_validate.remote_checksum(
                    peer_rec.dsn,
                    remote_checksum_sql,
                    peer_rec.connect_timeout_seconds,
                    LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
                    peer_rec.lock_timeout_ms
                ) AS rc;

                INSERT INTO pgl_validate.chunk_node_result(
                    run_id, schema_name, table_name, chunk_id, node, n_rows, lthash
                )
                VALUES (
                    v_run_id,
                    v_schema_name,
                    v_rel_name,
                    child_chunk_id,
                    peer_rec.name,
                    remote_rec.n_rows,
                    remote_rec.lthash
                )
                ON CONFLICT (run_id, schema_name, table_name, chunk_id, node) DO UPDATE
                SET n_rows = EXCLUDED.n_rows,
                    lthash = EXCLUDED.lthash;

                IF remote_rec.n_rows IS DISTINCT FROM chunk_n_rows
                   OR remote_rec.lthash IS DISTINCT FROM chunk_lthash
                   OR (paranoid_confirm AND remote_rec.set_hash IS DISTINCT FROM chunk_set_hash) THEN
                    chunk_differ_count := chunk_differ_count + 1;
                END IF;
            END LOOP;

            UPDATE pgl_validate.chunk_result cr
            SET state = CASE WHEN chunk_differ_count = 0 THEN 'clean' ELSE 'divergent' END,
                updated_at = now()
            WHERE cr.run_id = v_run_id
              AND cr.schema_name = v_schema_name
              AND cr.table_name = v_rel_name
              AND cr.chunk_id = child_chunk_id;
        END LOOP;
    END IF;

    IF differ_count > 0
       AND NOT degraded_mode
       AND key_cols IS NOT NULL
       AND cardinality(key_cols) > 0 THEN
        INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
        VALUES (v_run_id, initial_epoch)
        ON CONFLICT DO NOTHING;

        IF to_regclass('pg_temp.pgl_validate_localized_sample') IS NOT NULL THEN
            DROP TABLE pg_temp.pgl_validate_localized_sample;
        END IF;
        CREATE TEMP TABLE pgl_validate_localized_sample (
            sample     text NOT NULL,
            node       text NOT NULL,
            key_text   text NOT NULL,
            key_bytes  bytea NOT NULL,
            row_digest bytea NOT NULL,
            row_json   jsonb NOT NULL
        ) ON COMMIT DROP;

        FOR range_rec IN
            SELECT *
            FROM (
                SELECT 1::bigint AS chunk_id, NULL::bytea AS lo, NULL::bytea AS hi
                WHERE planned_chunk_count = 0
                   OR NOT EXISTS (
                       SELECT 1
                       FROM pgl_validate.chunk_result fallback_cr
                       WHERE fallback_cr.run_id = v_run_id
                         AND fallback_cr.schema_name = v_schema_name
                         AND fallback_cr.table_name = v_rel_name
                         AND fallback_cr.state = 'divergent'
                   )
                UNION ALL
                SELECT cr.chunk_id, cr.lo, cr.hi
                FROM pgl_validate.chunk_result cr
                WHERE cr.run_id = v_run_id
                  AND cr.schema_name = v_schema_name
                  AND cr.table_name = v_rel_name
                  AND cr.state = 'divergent'
            ) localized_ranges
            ORDER BY chunk_id
        LOOP
            localize_sql := pgl_validate.plan_localize_sql(
                p_table_name,
                key_cols,
                range_rec.lo,
                range_rec.hi,
                cols,
                row_filter_sql
            );

            previous_statement_timeout := current_setting('statement_timeout');
            PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
            BEGIN
                EXECUTE format(
                    'INSERT INTO pg_temp.pgl_validate_localized_sample(sample, node, key_text, key_bytes, row_digest, row_json)
                     SELECT %L, %L, q.key_text, q.key_bytes, q.row_digest, q.row_json::jsonb FROM (%s) AS q',
                    'A',
                    'local',
                    localize_sql
                );
            EXCEPTION WHEN others THEN
                PERFORM set_config('statement_timeout', previous_statement_timeout, true);
                RAISE;
            END;
            PERFORM set_config('statement_timeout', previous_statement_timeout, true);
        END LOOP;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
            ORDER BY p.name
        LOOP
            FOR range_rec IN
                SELECT *
                FROM (
                    SELECT 1::bigint AS chunk_id, NULL::bytea AS lo, NULL::bytea AS hi
                    WHERE planned_chunk_count = 0
                       OR NOT EXISTS (
                           SELECT 1
                           FROM pgl_validate.chunk_result fallback_cr
                           WHERE fallback_cr.run_id = v_run_id
                             AND fallback_cr.schema_name = v_schema_name
                             AND fallback_cr.table_name = v_rel_name
                             AND fallback_cr.state = 'divergent'
                       )
                    UNION ALL
                    SELECT cr.chunk_id, cr.lo, cr.hi
                    FROM pgl_validate.chunk_result cr
                    WHERE cr.run_id = v_run_id
                      AND cr.schema_name = v_schema_name
                      AND cr.table_name = v_rel_name
                      AND cr.state = 'divergent'
                ) localized_ranges
                ORDER BY chunk_id
            LOOP
                remote_localize_sql := pgl_validate.plan_localize_sql(
                    p_table_name,
                    key_cols,
                    range_rec.lo,
                    range_rec.hi,
                    cols,
                    NULL
                );

                INSERT INTO pg_temp.pgl_validate_localized_sample(
                    sample, node, key_text, key_bytes, row_digest, row_json
                )
                SELECT 'A', peer_rec.name, r.key_text, r.key_bytes, r.row_digest, r.row_json::jsonb
                FROM pgl_validate.remote_localize_rows(
                    peer_rec.dsn,
                    remote_localize_sql,
                    peer_rec.connect_timeout_seconds,
                    LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
                    peer_rec.lock_timeout_ms
                ) AS r;
            END LOOP;

            WITH classified AS (
                SELECT
                    COALESCE(l.key_text, r.key_text) AS key_text,
                    COALESCE(l.key_bytes, r.key_bytes) AS key_bytes,
                    l.row_json AS local_row_json,
                    r.row_json AS peer_row_json,
                    CASE
                        WHEN r.key_bytes IS NULL THEN 'missing_on'
                        WHEN l.key_bytes IS NULL THEN 'extra_on'
                        WHEN l.row_digest IS DISTINCT FROM r.row_digest
                         AND validated_property <> 'keys_only'
                        THEN 'differs'
                        ELSE NULL
                    END AS classification
                FROM (
                    SELECT key_text, key_bytes, row_digest, row_json
                    FROM pg_temp.pgl_validate_localized_sample
                    WHERE sample = 'A' AND node = 'local'
                ) l
                FULL OUTER JOIN (
                    SELECT key_text, key_bytes, row_digest, row_json
                    FROM pg_temp.pgl_validate_localized_sample
                    WHERE sample = 'A' AND node = peer_rec.name
                ) r USING (key_bytes)
            ),
            numbered AS (
                SELECT
                    c.*,
                    count(*) OVER () AS total_divergences,
                    row_number() OVER (ORDER BY c.key_text, c.classification, c.key_bytes) AS divergence_ordinal
                FROM classified c
                WHERE c.classification IS NOT NULL
            ),
            upserted AS (
                INSERT INTO pgl_validate.divergence(
                    run_id, schema_name, table_name, key_text, key_bytes,
                    classification, node, status, detected_epoch, tuple
                )
                SELECT
                    v_run_id,
                    v_schema_name,
                    v_rel_name,
                    n.key_text,
                    n.key_bytes,
                    n.classification,
                    peer_rec.name,
                    CASE
                        WHEN n.classification IN ('missing_on','extra_on')
                         AND validated_property IN ('filtered_intersection','filtered_advisory')
                        THEN 'advisory'
                        WHEN n.classification = 'extra_on'
                         AND validated_property = 'superset'
                        THEN 'advisory'
                        ELSE 'candidate'
                    END,
                    initial_epoch,
                    jsonb_build_object(
                        'local', pgl_validate.reported_tuple_json(
                            n.local_row_json,
                            max_reported_tuple_bytes
                        ),
                        'peer', pgl_validate.reported_tuple_json(
                            n.peer_row_json,
                            max_reported_tuple_bytes
                        )
                    )
                FROM numbered n
                WHERE n.divergence_ordinal <= max_reported_divergences
                ON CONFLICT (run_id, schema_name, table_name, key_bytes, node) DO UPDATE
                SET classification = EXCLUDED.classification,
                    status = EXCLUDED.status,
                    tuple = EXCLUDED.tuple,
                    detected_epoch = EXCLUDED.detected_epoch,
                    detected_at = now()
                RETURNING 1
            )
            SELECT
                COALESCE(max(n.total_divergences), 0)::int,
                (SELECT count(*)::int FROM upserted)
            INTO classified_divergence_count, reported_divergence_count
            FROM numbered n;

            IF classified_divergence_count > reported_divergence_count THEN
                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    peer_rec.name,
                    v_schema_name,
                    v_rel_name,
                    'DIVERGENCE_LIMIT_REACHED',
                    format(
                        'reported %s of %s key-level divergence(s); increase max_reported_divergences above %s to persist every key',
                        reported_divergence_count,
                        classified_divergence_count,
                        max_reported_divergences
                    )
                )
                ON CONFLICT DO NOTHING;
            END IF;
        END LOOP;

        FOR recheck_pass IN 1..recheck_passes LOOP
            EXIT WHEN NOT EXISTS (
                SELECT 1
                FROM pgl_validate.divergence d
                JOIN pgl_validate.peer p ON p.name = d.node
                WHERE d.run_id = v_run_id
                  AND d.schema_name = v_schema_name
                  AND d.table_name = v_rel_name
                  AND d.status = 'candidate'
                  AND (
                      p.backend IN ('pglogical','standby')
                      OR EXISTS (
                          SELECT 1
                          FROM pgl_validate.run_edge re
                          WHERE re.run_id = v_run_id
                            AND re.target_node = d.node
                            AND re.backend = 'native'
                            AND re.edge_id = ANY (current_edge_ids)
                      )
                  )
            );

            recheck_epoch := initial_epoch + recheck_pass;
            current_sample := format('R%s', recheck_pass);

            INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
            VALUES (v_run_id, recheck_epoch)
            ON CONFLICT DO NOTHING;

            UPDATE pgl_validate.run
            SET status = 'rechecking'
            WHERE pgl_validate.run.run_id = v_run_id;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend, p.subscription_name,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms,
                       re.edge_id,
                       re.slot_name,
                       re.origin_name
                FROM pgl_validate.peer p
                JOIN pgl_validate.run_edge re
                  ON re.run_id = v_run_id
                 AND re.target_node = p.name
                 AND re.edge_id = ANY (current_edge_ids)
                WHERE p.name = ANY (peer_names)
                  AND p.backend = 'pglogical'
                ORDER BY p.name
            LOOP
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_edge(
                    v_run_id,
                    recheck_epoch,
                    peer_rec.edge_id,
                    provider_node,
                    peer_rec.name,
                    provider_dsn,
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    peer_rec.slot_name,
                    peer_rec.origin_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'pglogical peer % failed to converge recheck fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END LOOP;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms,
                       re.edge_id,
                       re.subscription AS edge_subscription,
                       re.slot_name,
                       re.origin_name
                FROM pgl_validate.peer p
                JOIN pgl_validate.run_edge re
                  ON re.run_id = v_run_id
                 AND re.provider_node = p.name
                 AND re.target_node = provider_node_filter
                 AND re.edge_id = ANY (current_edge_ids)
                 AND re.backend = 'pglogical'
                WHERE p.name = ANY (peer_names)
                  AND p.backend = 'pglogical'
                ORDER BY p.name, re.edge_id
            LOOP
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_edge(
                    v_run_id,
                    recheck_epoch,
                    peer_rec.edge_id,
                    peer_rec.name,
                    provider_node,
                    peer_rec.dsn,
                    provider_dsn,
                    peer_rec.edge_subscription,
                    peer_rec.slot_name,
                    peer_rec.origin_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'pglogical reverse edge % -> % failed to converge recheck fence: %',
                        peer_rec.name,
                        provider_node,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END LOOP;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend, p.subscription_name,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms,
                       re.edge_id,
                       re.slot_name,
                       re.origin_name
                FROM pgl_validate.peer p
                JOIN pgl_validate.run_edge re
                  ON re.run_id = v_run_id
                 AND re.target_node = p.name
                 AND re.edge_id = ANY (current_edge_ids)
                 AND re.backend = 'native'
                WHERE p.name = ANY (peer_names)
                  AND p.backend = 'native'
                ORDER BY p.name
            LOOP
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_native_edge(
                    v_run_id,
                    recheck_epoch,
                    peer_rec.edge_id,
                    provider_node,
                    peer_rec.name,
                    provider_dsn,
                    peer_rec.dsn,
                    peer_rec.subscription_name::text,
                    peer_rec.slot_name,
                    peer_rec.origin_name,
                    ARRAY['pgl_validate_barrier'],
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'native peer % failed to converge recheck fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END LOOP;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms,
                       re.edge_id
                FROM pgl_validate.peer p
                JOIN pgl_validate.run_edge re
                  ON re.run_id = v_run_id
                 AND re.target_node = p.name
                 AND re.edge_id = ANY (current_edge_ids)
                WHERE p.name = ANY (peer_names)
                  AND p.backend = 'standby'
                ORDER BY p.name
            LOOP
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_standby_edge(
                    v_run_id,
                    recheck_epoch,
                    peer_rec.edge_id,
                    provider_node,
                    peer_rec.name,
                    peer_rec.dsn,
                    NULL,
                    peer_rec.connect_timeout_seconds,
                    peer_rec.statement_timeout_ms,
                    peer_rec.lock_timeout_ms,
                    fence_timeout_ms,
                    fence_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'standby peer % failed to converge recheck fence: %',
                        peer_rec.name,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END LOOP;

            DELETE FROM pg_temp.pgl_validate_localized_sample
            WHERE sample = current_sample;

            FOR range_rec IN
                SELECT *
                FROM (
                    SELECT 1::bigint AS chunk_id, NULL::bytea AS lo, NULL::bytea AS hi
                    WHERE planned_chunk_count = 0
                       OR NOT EXISTS (
                           SELECT 1
                           FROM pgl_validate.chunk_result fallback_cr
                           WHERE fallback_cr.run_id = v_run_id
                             AND fallback_cr.schema_name = v_schema_name
                             AND fallback_cr.table_name = v_rel_name
                             AND fallback_cr.state = 'divergent'
                       )
                    UNION ALL
                    SELECT cr.chunk_id, cr.lo, cr.hi
                    FROM pgl_validate.chunk_result cr
                    WHERE cr.run_id = v_run_id
                      AND cr.schema_name = v_schema_name
                      AND cr.table_name = v_rel_name
                      AND cr.state = 'divergent'
                ) localized_ranges
                ORDER BY chunk_id
            LOOP
                localize_sql := pgl_validate.plan_localize_sql(
                    p_table_name,
                    key_cols,
                    range_rec.lo,
                    range_rec.hi,
                    cols,
                    row_filter_sql
                );

                previous_statement_timeout := current_setting('statement_timeout');
                PERFORM set_config('statement_timeout', statement_timeout_per_chunk_ms::text, true);
                BEGIN
                    EXECUTE format(
                        'INSERT INTO pg_temp.pgl_validate_localized_sample(sample, node, key_text, key_bytes, row_digest, row_json)
                         SELECT %L, %L, q.key_text, q.key_bytes, q.row_digest, q.row_json::jsonb FROM (%s) AS q',
                        current_sample,
                        'local',
                        localize_sql
                    );
                EXCEPTION WHEN others THEN
                    PERFORM set_config('statement_timeout', previous_statement_timeout, true);
                    RAISE;
                END;
                PERFORM set_config('statement_timeout', previous_statement_timeout, true);
            END LOOP;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.backend,
                       p.connect_timeout_seconds,
                       p.statement_timeout_ms,
                       p.lock_timeout_ms
                FROM pgl_validate.peer p
                WHERE p.name = ANY (peer_names)
                  AND (
                      p.backend IN ('pglogical','standby')
                      OR EXISTS (
                          SELECT 1
                          FROM pgl_validate.run_edge re
                          WHERE re.run_id = v_run_id
                            AND re.target_node = p.name
                            AND re.backend = 'native'
                            AND re.edge_id = ANY (current_edge_ids)
                      )
                  )
                ORDER BY p.name
            LOOP
                FOR range_rec IN
                    SELECT *
                    FROM (
                        SELECT 1::bigint AS chunk_id, NULL::bytea AS lo, NULL::bytea AS hi
                        WHERE planned_chunk_count = 0
                           OR NOT EXISTS (
                               SELECT 1
                               FROM pgl_validate.chunk_result fallback_cr
                               WHERE fallback_cr.run_id = v_run_id
                                 AND fallback_cr.schema_name = v_schema_name
                                 AND fallback_cr.table_name = v_rel_name
                                 AND fallback_cr.state = 'divergent'
                           )
                        UNION ALL
                        SELECT cr.chunk_id, cr.lo, cr.hi
                        FROM pgl_validate.chunk_result cr
                        WHERE cr.run_id = v_run_id
                          AND cr.schema_name = v_schema_name
                          AND cr.table_name = v_rel_name
                          AND cr.state = 'divergent'
                    ) localized_ranges
                    ORDER BY chunk_id
                LOOP
                    remote_localize_sql := pgl_validate.plan_localize_sql(
                        p_table_name,
                        key_cols,
                        range_rec.lo,
                        range_rec.hi,
                        cols,
                        NULL
                    );

                    INSERT INTO pg_temp.pgl_validate_localized_sample(
                        sample, node, key_text, key_bytes, row_digest, row_json
                    )
                    SELECT current_sample, peer_rec.name, r.key_text, r.key_bytes, r.row_digest, r.row_json::jsonb
                    FROM pgl_validate.remote_localize_rows(
                        peer_rec.dsn,
                        remote_localize_sql,
                        peer_rec.connect_timeout_seconds,
                        LEAST(peer_rec.statement_timeout_ms, statement_timeout_per_chunk_ms),
                        peer_rec.lock_timeout_ms
                    ) AS r;
                END LOOP;

                INSERT INTO pgl_validate.divergence_recheck(
                    run_id, schema_name, table_name, key_bytes, node, epoch_seq, outcome
                )
                SELECT
                    d.run_id,
                    d.schema_name,
                    d.table_name,
                    d.key_bytes,
                    d.node,
                    recheck_epoch,
                    CASE
                        WHEN (lb.key_bytes IS NOT NULL AND pb.key_bytes IS NOT NULL
                              AND lb.row_digest IS NOT DISTINCT FROM pb.row_digest)
                          OR (lb.key_bytes IS NULL AND pb.key_bytes IS NULL)
                        THEN 'cleared'
                        WHEN la.row_digest IS NOT DISTINCT FROM lb.row_digest
                         AND pa.row_digest IS NOT DISTINCT FROM pb.row_digest
                        THEN 'still_differs'
                        ELSE 'still_hot'
                    END
                FROM pgl_validate.divergence d
                LEFT JOIN pg_temp.pgl_validate_localized_sample la
                  ON la.sample = previous_sample AND la.node = 'local' AND la.key_bytes = d.key_bytes
                LEFT JOIN pg_temp.pgl_validate_localized_sample pa
                  ON pa.sample = previous_sample AND pa.node = d.node AND pa.key_bytes = d.key_bytes
                LEFT JOIN pg_temp.pgl_validate_localized_sample lb
                  ON lb.sample = current_sample AND lb.node = 'local' AND lb.key_bytes = d.key_bytes
                LEFT JOIN pg_temp.pgl_validate_localized_sample pb
                  ON pb.sample = current_sample AND pb.node = d.node AND pb.key_bytes = d.key_bytes
                WHERE d.run_id = v_run_id
                  AND d.schema_name = v_schema_name
                  AND d.table_name = v_rel_name
                  AND d.node = peer_rec.name
                  AND d.status = 'candidate'
                ON CONFLICT (run_id, schema_name, table_name, key_bytes, node, epoch_seq)
                DO UPDATE SET outcome = EXCLUDED.outcome, at = now();

                UPDATE pgl_validate.divergence d
                SET status = CASE
                    WHEN r.outcome = 'cleared' THEN 'cleared'
                    WHEN r.outcome = 'still_differs' THEN 'confirmed'
                    WHEN recheck_pass >= recheck_passes THEN 'indeterminate'
                    ELSE 'candidate'
                END
                FROM pgl_validate.divergence_recheck r
                WHERE r.run_id = d.run_id
                  AND r.schema_name = d.schema_name
                  AND r.table_name = d.table_name
                  AND r.key_bytes = d.key_bytes
                  AND r.node = d.node
                  AND r.epoch_seq = recheck_epoch
                  AND d.run_id = v_run_id
                  AND d.schema_name = v_schema_name
                  AND d.table_name = v_rel_name
                  AND d.node = peer_rec.name
                  AND d.status = 'candidate';
            END LOOP;

            previous_sample := current_sample;
        END LOOP;

        UPDATE pgl_validate.divergence d
        SET status = 'confirmed'
        FROM pgl_validate.peer p
        WHERE p.name = d.node
          AND p.backend NOT IN ('pglogical','standby')
          AND NOT EXISTS (
              SELECT 1
              FROM pgl_validate.run_edge re
              WHERE re.run_id = v_run_id
                AND re.target_node = d.node
                AND re.backend = 'native'
                AND re.edge_id = ANY (current_edge_ids)
          )
          AND d.run_id = v_run_id
          AND d.schema_name = v_schema_name
          AND d.table_name = v_rel_name
          AND d.status = 'candidate';

        SELECT
            count(*) FILTER (WHERE status = 'confirmed'),
            count(*) FILTER (WHERE status = 'advisory'),
            count(*) FILTER (WHERE status = 'indeterminate')
        INTO confirmed_count, advisory_count, indeterminate_count
        FROM pgl_validate.divergence d
        WHERE d.run_id = v_run_id
          AND d.schema_name = v_schema_name
          AND d.table_name = v_rel_name;

        IF correlate_conflict_history AND confirmed_count > 0 THEN
            BEGIN
                PERFORM pgl_validate.correlate_conflict_history(
                    v_run_id,
                    conflict_history_lookback,
                    conflict_history_max_rows
                );
            EXCEPTION WHEN others THEN
                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    v_run_id,
                    provider_node,
                    v_schema_name,
                    v_rel_name,
                    'CONFLICT_HISTORY_UNAVAILABLE',
                    SQLERRM
                )
                ON CONFLICT DO NOTHING;
            END;
        END IF;
    END IF;

    IF differ_count = 0 AND paranoid_unbounded THEN
        verdict := 'indeterminate';
        result_reason := format(
            'paranoid_confirm requested but %s row keyless relation cannot be subdivided under paranoid_confirm_max_rows=%s; validated_property=%s',
            n_rows,
            paranoid_confirm_max_rows,
            validated_property
        );
    ELSIF differ_count = 0 THEN
        verdict := 'match';
        IF participant_count = 1 THEN
            result_reason := format(
                'single local participant; no peers registered or requested; validated_property=%s',
                validated_property
            );
        ELSE
            result_reason := format(
                'all %s participants have matching row count and LtHash; validated_property=%s',
                participant_count,
                validated_property
            );
        END IF;
    ELSIF key_cols IS NULL OR cardinality(key_cols) = 0 THEN
        verdict := 'differ';
        result_reason := format(
            '%s of %s remote peer(s) differ from local; whole-relation checksum/count differ; row-level localization unavailable without a key; validated_property=%s',
            differ_count,
            participant_count - 1,
            validated_property
        );
    ELSIF confirmed_count > 0 THEN
        verdict := 'differ';
        result_reason := format(
            '%s confirmed divergence(s), %s advisory difference(s), %s indeterminate key(s); validated_property=%s',
            confirmed_count,
            advisory_count,
            indeterminate_count,
            validated_property
        );
    ELSIF indeterminate_count > 0 THEN
        verdict := 'indeterminate';
        result_reason := format(
            'checksum mismatch localized, but %s key(s) remained hot after recheck; %s advisory difference(s); validated_property=%s',
            indeterminate_count,
            advisory_count,
            validated_property
        );
    ELSE
        verdict := 'match';
        result_reason := format(
            'initial checksum mismatch produced no confirmed divergence after localization/recheck; advisory differences=%s; validated_property=%s',
            advisory_count,
            validated_property
        );
    END IF;

    IF degraded_mode THEN
        result_reason := format(
            '%s; one or more pglogical edges used allow_degraded_fence and are not exact',
            result_reason
        );
        verdict := 'degraded';
    END IF;

    IF partial_mode THEN
        result_reason := format(
            '%s; skipped peer(s): %s',
            result_reason,
            CASE
                WHEN cardinality(skipped_peer_details) > 0 THEN
                    array_to_string(skipped_peer_details, ', ')
                ELSE
                    array_to_string(skipped_peers, ', ')
            END
        );
        verdict := 'partial';
    END IF;

    INSERT INTO pgl_validate.chunk_result(
        run_id, schema_name, table_name, chunk_id, parent_id, lo, hi, state, updated_at
    )
    VALUES (
        v_run_id,
        v_schema_name,
        v_rel_name,
        1,
        NULL,
        NULL,
        NULL,
        CASE
            WHEN planned_chunk_count > 0 THEN 'split'
            WHEN verdict = 'match' THEN 'clean'
            WHEN verdict = 'differ' THEN 'divergent'
            ELSE 'candidate'
        END,
        now()
    )
    ON CONFLICT (run_id, schema_name, table_name, chunk_id) DO UPDATE
    SET parent_id = EXCLUDED.parent_id,
        lo = EXCLUDED.lo,
        hi = EXCLUDED.hi,
        state = EXCLUDED.state,
        updated_at = EXCLUDED.updated_at;

    INSERT INTO pgl_validate.chunk_node_result(
        run_id, schema_name, table_name, chunk_id, node, n_rows, lthash
    )
    SELECT
        tnr.run_id,
        tnr.schema_name,
        tnr.table_name,
        1,
        tnr.node,
        tnr.n_rows,
        tnr.lthash
    FROM pgl_validate.table_node_result tnr
    WHERE tnr.run_id = v_run_id
      AND tnr.schema_name = v_schema_name
      AND tnr.table_name = v_rel_name
    ON CONFLICT (run_id, schema_name, table_name, chunk_id, node) DO UPDATE
    SET n_rows = EXCLUDED.n_rows,
        lthash = EXCLUDED.lthash;

    INSERT INTO pgl_validate.table_result(
        run_id, schema_name, table_name, verdict, reason, finished_at
    )
    VALUES (
        v_run_id, v_schema_name, v_rel_name, verdict, result_reason, now()
    )
    RETURNING * INTO result_row;

    IF NOT append_to_parent THEN
        UPDATE pgl_validate.run
        SET status = 'completed',
            finished_at = now(),
            tables_matched = CASE WHEN verdict = 'match' THEN 1 ELSE 0 END,
            tables_differ = CASE WHEN verdict = 'differ' THEN 1 ELSE 0 END
        WHERE pgl_validate.run.run_id = v_run_id;

        UPDATE pgl_validate.run_participant
        SET status = 'done'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';
    END IF;

    RETURN result_row;
END
$$;

CREATE FUNCTION pgl_validate.compare_sequence(
    sequence_name regclass,
    peers text[] DEFAULT NULL,
    options jsonb DEFAULT '{}'
)
RETURNS SETOF pgl_validate.sequence_result
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_run_id bigint;
    parent_run_id bigint := NULLIF(options->>'_pgl_validate_parent_run_id', '')::bigint;
    append_to_parent boolean := false;
    initial_epoch int := 1;
    v_schema_name text;
    v_seq_name text;
    peer_names text[];
    missing_peers text[];
    peer_rec record;
    remote_seq_rec record;
    subscription_rec record;
    fence_rec pgl_validate.fence_attempt;
    provider_dsn text := NULLIF(options->>'provider_dsn', '');
    provider_node text := COALESCE(NULLIF(options->>'provider_node', ''), 'local');
    fence_timeout_ms int := COALESCE(
        (NULLIF(options->>'fence_timeout_ms', ''))::int,
        NULLIF(current_setting('pgl_validate.fence_timeout_ms', true), '')::int,
        300000
    );
    fence_poll_interval_ms int := COALESCE(
        (NULLIF(options->>'fence_poll_interval_ms', ''))::int,
        NULLIF(current_setting('pgl_validate.fence_poll_interval_ms', true), '')::int,
        100
    );
    buffer_multiplier int := COALESCE(
        (NULLIF(options->>'sequence_buffer_multiplier', ''))::int,
        NULLIF(current_setting('pgl_validate.sequence_buffer_multiplier', true), '')::int,
        2
    );
    edge_seq int := 0;
    sequence_sql text;
    provider_last_value bigint;
    subscriber_last_value bigint;
    cache_size int;
    window_max numeric;
    verdict text;
    within_contract boolean;
BEGIN
    SELECT n.nspname, c.relname
    INTO v_schema_name, v_seq_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = sequence_name
      AND c.relkind = 'S';

    IF v_schema_name IS NULL THEN
        RAISE EXCEPTION 'relation % is not a sequence', sequence_name;
    END IF;
    IF fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF fence_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'fence_poll_interval_ms must be greater than zero';
    END IF;
    IF buffer_multiplier <= 0 THEN
        RAISE EXCEPTION 'sequence_buffer_multiplier must be greater than zero';
    END IF;

    IF peers IS NULL OR cardinality(peers) = 0 THEN
        SELECT COALESCE(array_agg(p.name ORDER BY p.name), ARRAY[]::text[])
        INTO peer_names
        FROM pgl_validate.peer p;
    ELSE
        SELECT array_agg(DISTINCT requested.peer_name ORDER BY requested.peer_name)
        INTO peer_names
        FROM unnest(peers) AS requested(peer_name);

        SELECT array_agg(requested.peer_name ORDER BY requested.peer_name)
        INTO missing_peers
        FROM unnest(peer_names) AS requested(peer_name)
        LEFT JOIN pgl_validate.peer p ON p.name = requested.peer_name
        WHERE p.name IS NULL;

        IF missing_peers IS NOT NULL THEN
            RAISE EXCEPTION 'unknown pgl_validate peer(s): %', array_to_string(missing_peers, ', ');
        END IF;
    END IF;

    IF parent_run_id IS NULL THEN
        INSERT INTO pgl_validate.run(status, options, tables_total)
        VALUES ('running', options, 0)
        RETURNING pgl_validate.run.run_id INTO v_run_id;
    ELSE
        SELECT r.run_id
        INTO v_run_id
        FROM pgl_validate.run r
        WHERE r.run_id = parent_run_id
          AND r.status IN ('planning','fencing','running','rechecking','paused');

        IF v_run_id IS NULL THEN
            RAISE EXCEPTION 'parent validation run % does not exist or is not appendable', parent_run_id
                USING ERRCODE = '55000';
        END IF;

        append_to_parent := true;
        SELECT COALESCE(max(fe.epoch_seq), 0) + 1
        INTO initial_epoch
        FROM pgl_validate.fence_epoch fe
        WHERE fe.run_id = v_run_id;

        SELECT COALESCE(max(re.edge_id), 0)
        INTO edge_seq
        FROM pgl_validate.run_edge re
        WHERE re.run_id = v_run_id;
    END IF;

    INSERT INTO pgl_validate.run_participant(run_id, node, role, backend, pg_version, status)
    VALUES (v_run_id, 'local', 'coordinator', 'pglogical', current_setting('server_version_num')::int, 'connected')
    ON CONFLICT (run_id, node) DO UPDATE
    SET status = 'connected',
        pg_version = EXCLUDED.pg_version;

    IF EXISTS (
        SELECT 1
        FROM pgl_validate.peer p
        WHERE p.name = ANY (peer_names)
          AND p.backend = 'pglogical'
    ) THEN
        IF provider_dsn IS NULL THEN
            RAISE EXCEPTION
                'options.provider_dsn is required when comparing pglogical peers'
                USING ERRCODE = '0A000';
        END IF;

        INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
        VALUES (v_run_id, initial_epoch);

        UPDATE pgl_validate.run
        SET status = 'fencing'
        WHERE pgl_validate.run.run_id = v_run_id;

        FOR peer_rec IN
            SELECT p.name, p.dsn, p.backend, p.subscription_name,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.peer p
            WHERE p.name = ANY (peer_names)
              AND p.backend = 'pglogical'
            ORDER BY p.name
        LOOP
            IF peer_rec.subscription_name IS NULL THEN
                RAISE EXCEPTION
                    'pglogical peer % requires subscription_name for exact barrier fencing',
                    peer_rec.name
                    USING ERRCODE = '0A000';
            END IF;

            SELECT *
            INTO subscription_rec
            FROM pgl_validate.remote_pglogical_subscription_status(
                peer_rec.dsn,
                peer_rec.subscription_name::text,
                peer_rec.connect_timeout_seconds,
                peer_rec.statement_timeout_ms,
                peer_rec.lock_timeout_ms
            );

            IF subscription_rec.status <> 'replicating' THEN
                RAISE EXCEPTION
                    'pglogical peer % subscription % is %, not replicating',
                    peer_rec.name,
                    peer_rec.subscription_name,
                    subscription_rec.status
                    USING ERRCODE = '57014';
            END IF;

            IF NOT (subscription_rec.replication_sets_json::jsonb ? 'pgl_validate_barrier') THEN
                RAISE EXCEPTION
                    'pglogical peer % subscription % does not include pgl_validate_barrier',
                    peer_rec.name,
                    peer_rec.subscription_name
                    USING ERRCODE = '0A000';
            END IF;

            edge_seq := edge_seq + 1;
            SELECT *
            INTO fence_rec
            FROM pgl_validate.fence_pglogical_edge(
                v_run_id,
                initial_epoch,
                edge_seq,
                provider_node,
                peer_rec.name,
                provider_dsn,
                peer_rec.dsn,
                peer_rec.subscription_name::text,
                subscription_rec.slot_name,
                subscription_rec.slot_name,
                ARRAY['pgl_validate_barrier'],
                peer_rec.connect_timeout_seconds,
                peer_rec.statement_timeout_ms,
                peer_rec.lock_timeout_ms,
                fence_timeout_ms,
                fence_poll_interval_ms
            );

            IF fence_rec.status <> 'converged' THEN
                RAISE EXCEPTION
                    'pglogical peer % failed to converge barrier fence: %',
                    peer_rec.name,
                    fence_rec.status
                    USING ERRCODE = '57014';
            END IF;
        END LOOP;
    END IF;

    UPDATE pgl_validate.run
    SET status = 'running'
    WHERE pgl_validate.run.run_id = v_run_id;

    sequence_sql := pgl_validate.plan_sequence_sql(sequence_name);
    EXECUTE sequence_sql INTO provider_last_value;

    IF to_regclass('pglogical.sequence_state') IS NOT NULL THEN
        SELECT COALESCE(ss.cache_size, ps.cache_size, 1)::int
        INTO cache_size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pglogical.sequence_state ss ON ss.seqoid = c.oid
        LEFT JOIN pg_sequences ps
          ON ps.schemaname = n.nspname
         AND ps.sequencename = c.relname
        WHERE c.oid = sequence_name;
    ELSE
        SELECT COALESCE(ps.cache_size, 1)::int
        INTO cache_size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_sequences ps
          ON ps.schemaname = n.nspname
         AND ps.sequencename = c.relname
        WHERE c.oid = sequence_name;
    END IF;

    cache_size := GREATEST(COALESCE(cache_size, 1), 1);
    window_max := provider_last_value::numeric + (buffer_multiplier::numeric * cache_size::numeric);

    FOR peer_rec IN
        SELECT p.name, p.dsn, p.backend,
               p.connect_timeout_seconds,
               p.statement_timeout_ms,
               p.lock_timeout_ms
        FROM pgl_validate.peer p
        WHERE p.name = ANY (peer_names)
        ORDER BY p.name
    LOOP
        remote_seq_rec := NULL;
        subscriber_last_value := NULL;

        BEGIN
            SELECT r.pg_version, r.last_value
            INTO remote_seq_rec
            FROM pgl_validate.remote_sequence_value(
                peer_rec.dsn,
                sequence_sql,
                peer_rec.connect_timeout_seconds,
                peer_rec.statement_timeout_ms,
                peer_rec.lock_timeout_ms
            ) AS r;

            subscriber_last_value := remote_seq_rec.last_value;

            IF subscriber_last_value < provider_last_value THEN
                verdict := 'behind';
                within_contract := false;
            ELSIF subscriber_last_value::numeric > window_max THEN
                verdict := 'ahead_of_window';
                within_contract := false;
            ELSE
                verdict := 'match';
                within_contract := true;
            END IF;
        EXCEPTION WHEN others THEN
            subscriber_last_value := NULL;
            verdict := 'error';
            within_contract := false;
        END;

        INSERT INTO pgl_validate.run_participant(
            run_id, node, role, backend, pg_version, dsn_ref, status
        )
        VALUES (
            v_run_id, peer_rec.name, 'participant', peer_rec.backend,
            COALESCE(remote_seq_rec.pg_version, current_setting('server_version_num')::int),
            peer_rec.name, 'done'
        )
        ON CONFLICT (run_id, node) DO UPDATE
        SET backend = EXCLUDED.backend,
            pg_version = EXCLUDED.pg_version,
            dsn_ref = EXCLUDED.dsn_ref,
            status = EXCLUDED.status;

        INSERT INTO pgl_validate.sequence_result(
            run_id, schema_name, seq_name, provider_node, provider_last_value,
            subscriber_node, subscriber_last_value, cache_size, within_contract, verdict
        )
        VALUES (
            v_run_id, v_schema_name, v_seq_name, provider_node, provider_last_value,
            peer_rec.name, subscriber_last_value, cache_size, within_contract, verdict
        );
    END LOOP;

    IF NOT append_to_parent THEN
        UPDATE pgl_validate.run
        SET status = 'completed',
            finished_at = now()
        WHERE pgl_validate.run.run_id = v_run_id;

        UPDATE pgl_validate.run_participant
        SET status = 'done'
        WHERE pgl_validate.run_participant.run_id = v_run_id
          AND node = 'local';
    END IF;

    RETURN QUERY
    SELECT sr.*
    FROM pgl_validate.sequence_result sr
    WHERE sr.run_id = v_run_id
    ORDER BY sr.schema_name, sr.seq_name, sr.subscriber_node;
END
$$;

