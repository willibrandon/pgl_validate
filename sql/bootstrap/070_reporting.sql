CREATE FUNCTION pgl_validate.cancel(run_id bigint)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    changed boolean;
BEGIN
    UPDATE pgl_validate.run r
    SET status = 'canceled',
        finished_at = COALESCE(r.finished_at, clock_timestamp())
    WHERE r.run_id = cancel.run_id
      AND r.status IN ('planning','fencing','running','paused','rechecking')
    RETURNING true INTO changed;

    RETURN COALESCE(changed, false);
END
$$;

CREATE FUNCTION pgl_validate.pause(run_id bigint)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    changed boolean;
BEGIN
    UPDATE pgl_validate.run r
    SET status = 'paused'
    WHERE r.run_id = pause.run_id
      AND r.status IN ('planning','fencing','running','rechecking')
    RETURNING true INTO changed;

    IF COALESCE(changed, false) THEN
        UPDATE pgl_validate.worker_task wt
        SET status = 'paused',
            worker_pid = NULL
        WHERE wt.run_id = pause.run_id
          AND wt.status IN ('queued','starting');
    END IF;

    RETURN COALESCE(changed, false);
END
$$;

CREATE FUNCTION pgl_validate.resume(run_id bigint)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    changed boolean;
    task pgl_validate.worker_task;
    v_worker_pid integer;
BEGIN
    SELECT wt.*
    INTO task
    FROM pgl_validate.worker_task wt
    JOIN pgl_validate.run r USING (run_id)
    WHERE wt.run_id = resume.run_id
      AND (
          wt.status IN ('paused','failed')
          OR (
              wt.status IN ('starting','running')
              AND wt.worker_pid IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM pg_stat_activity a
                  WHERE a.pid = wt.worker_pid
              )
          )
      )
      AND r.status IN ('paused','failed','planning','fencing','running','rechecking')
    ORDER BY wt.task_id DESC
    LIMIT 1
    FOR UPDATE OF wt;

    IF FOUND THEN
        UPDATE pgl_validate.run r
        SET status = 'planning',
            finished_at = NULL,
            error = NULL
        WHERE r.run_id = resume.run_id
          AND r.status IN ('paused','failed','planning','fencing','running','rechecking')
        RETURNING true INTO changed;

        IF NOT COALESCE(changed, false) THEN
            RETURN false;
        END IF;

        UPDATE pgl_validate.worker_task wt
        SET status = 'queued',
            worker_pid = NULL,
            started_at = NULL,
            finished_at = NULL,
            error = NULL
        WHERE wt.task_id = task.task_id;

        BEGIN
            v_worker_pid := pgl_validate.launch_worker_task(task.task_id);
            UPDATE pgl_validate.worker_task wt
            SET worker_pid = v_worker_pid
            WHERE wt.task_id = task.task_id;
        EXCEPTION WHEN others THEN
            UPDATE pgl_validate.worker_task wt
            SET status = 'failed',
                finished_at = clock_timestamp(),
                error = SQLERRM
            WHERE wt.task_id = task.task_id;

            UPDATE pgl_validate.run r
            SET status = 'failed',
                finished_at = clock_timestamp(),
                error = SQLERRM
            WHERE r.run_id = resume.run_id;

            RAISE;
        END;

        RETURN true;
    END IF;

    UPDATE pgl_validate.run r
    SET status = 'running',
        finished_at = NULL,
        error = NULL
    WHERE r.run_id = resume.run_id
      AND r.status = 'paused'
    RETURNING true INTO changed;

    RETURN COALESCE(changed, false);
END
$$;

CREATE FUNCTION pgl_validate.put_schedule(
    p_name text,
    p_cron text,
    p_tables text[] DEFAULT NULL,
    p_repset text DEFAULT NULL,
    p_peers text[] DEFAULT NULL,
    p_options jsonb DEFAULT '{}'::jsonb,
    p_enabled boolean DEFAULT true
)
RETURNS pgl_validate.schedule
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    schedule_row pgl_validate.schedule;
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'schedule name is required'
            USING ERRCODE = '22023';
    END IF;
    IF p_cron IS NULL OR btrim(p_cron) = '' THEN
        RAISE EXCEPTION 'schedule cron expression is required'
            USING ERRCODE = '22023';
    END IF;
    IF p_options IS NULL OR jsonb_typeof(p_options) <> 'object' THEN
        RAISE EXCEPTION 'schedule options must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO pgl_validate.schedule(
        name, cron, tables, repset, peers, options, enabled
    )
    VALUES (
        p_name,
        p_cron,
        p_tables,
        NULLIF(p_repset, ''),
        p_peers,
        p_options,
        COALESCE(p_enabled, true)
    )
    ON CONFLICT (name) DO UPDATE
    SET cron = EXCLUDED.cron,
        tables = EXCLUDED.tables,
        repset = EXCLUDED.repset,
        peers = EXCLUDED.peers,
        options = EXCLUDED.options,
        enabled = EXCLUDED.enabled
    RETURNING * INTO schedule_row;

    RETURN schedule_row;
END
$$;

CREATE FUNCTION pgl_validate.set_schedule_enabled(p_name text, p_enabled boolean DEFAULT true)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    changed boolean;
BEGIN
    UPDATE pgl_validate.schedule s
    SET enabled = COALESCE(p_enabled, true)
    WHERE s.name = p_name
    RETURNING true INTO changed;

    RETURN COALESCE(changed, false);
END
$$;

CREATE FUNCTION pgl_validate.delete_schedule(p_name text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    changed boolean;
BEGIN
    DELETE FROM pgl_validate.schedule s
    WHERE s.name = p_name
    RETURNING true INTO changed;

    RETURN COALESCE(changed, false);
END
$$;

CREATE FUNCTION pgl_validate.run_schedule(p_name text, p_force boolean DEFAULT false)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    schedule_row pgl_validate.schedule;
    table_oids regclass[];
    missing_table text;
    v_run_id bigint;
BEGIN
    SELECT *
    INTO schedule_row
    FROM pgl_validate.schedule s
    WHERE s.name = p_name
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'schedule % does not exist', p_name
            USING ERRCODE = '02000';
    END IF;

    IF NOT schedule_row.enabled AND NOT COALESCE(p_force, false) THEN
        RETURN NULL;
    END IF;

    IF schedule_row.tables IS NOT NULL THEN
        SELECT min(table_name)
        INTO missing_table
        FROM unnest(schedule_row.tables) AS t(table_name)
        WHERE to_regclass(t.table_name) IS NULL;

        IF missing_table IS NOT NULL THEN
            RAISE EXCEPTION 'scheduled table % does not exist', missing_table
                USING ERRCODE = '42P01';
        END IF;

        SELECT array_agg(to_regclass(t.table_name)::regclass ORDER BY t.ordinality)
        INTO table_oids
        FROM unnest(schedule_row.tables) WITH ORDINALITY AS t(table_name, ordinality);
    END IF;

    v_run_id := pgl_validate.compare_async(
        table_oids,
        schedule_row.repset,
        schedule_row.peers,
        NULL,
        schedule_row.options || jsonb_build_object('schedule', schedule_row.name)
    );

    UPDATE pgl_validate.schedule s
    SET last_run_id = v_run_id
    WHERE s.name = schedule_row.name;

    RETURN v_run_id;
END
$$;

CREATE FUNCTION pgl_validate.compare_async(
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
    effective_options jsonb := COALESCE(options, '{}'::jsonb);
    v_run_id bigint;
    v_task_id integer;
    v_worker_pid integer;
BEGIN
    IF jsonb_typeof(effective_options) <> 'object' THEN
        RAISE EXCEPTION 'options must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO pgl_validate.run(status, options, reference_node, tables_total)
    VALUES (
        'planning',
        effective_options || jsonb_build_object('async', true),
        reference,
        CASE WHEN tables IS NULL THEN NULL ELSE cardinality(tables) END
    )
    RETURNING pgl_validate.run.run_id INTO v_run_id;

    INSERT INTO pgl_validate.worker_task(
        run_id, task_kind, request, status, database_name
    )
    VALUES (
        v_run_id,
        'compare',
        jsonb_build_object(
            'tables',
                CASE
                    WHEN tables IS NULL THEN NULL::jsonb
                    ELSE (
                        SELECT jsonb_agg(t.table_oid::text ORDER BY t.ordinality)
                        FROM unnest(tables) WITH ORDINALITY AS t(table_oid, ordinality)
                    )
                END,
            'repset', repset,
            'peers', to_jsonb(peers),
            'reference', reference,
            'options', effective_options
        ),
        'queued',
        current_database()
    )
    RETURNING task_id INTO v_task_id;

    BEGIN
        v_worker_pid := pgl_validate.launch_worker_task(v_task_id);
        UPDATE pgl_validate.worker_task
        SET worker_pid = v_worker_pid
        WHERE task_id = v_task_id;
    EXCEPTION WHEN others THEN
        UPDATE pgl_validate.worker_task
        SET status = 'failed',
            finished_at = clock_timestamp(),
            error = SQLERRM
        WHERE task_id = v_task_id;

        UPDATE pgl_validate.run
        SET status = 'failed',
            finished_at = clock_timestamp(),
            error = SQLERRM
        WHERE run_id = v_run_id;

        RAISE;
    END;

    RETURN v_run_id;
END
$$;

CREATE FUNCTION pgl_validate._claim_worker_task(task_id integer)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    task pgl_validate.worker_task;
BEGIN
    SELECT *
    INTO task
    FROM pgl_validate.worker_task wt
    WHERE wt.task_id = _claim_worker_task.task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'worker task % does not exist', task_id
            USING ERRCODE = '02000';
    END IF;

    IF task.status = 'canceled' THEN
        UPDATE pgl_validate.run
        SET status = 'canceled',
            finished_at = COALESCE(finished_at, clock_timestamp())
        WHERE run_id = task.run_id
          AND status IN ('planning','fencing','running','paused','rechecking');
        RETURN false;
    END IF;

    IF task.status NOT IN ('queued','starting','running') THEN
        RETURN false;
    END IF;

    UPDATE pgl_validate.worker_task
    SET status = 'running',
        started_at = COALESCE(started_at, clock_timestamp()),
        worker_pid = pg_backend_pid()
    WHERE pgl_validate.worker_task.task_id = task.task_id;

    RETURN true;
END
$$;

CREATE FUNCTION pgl_validate._run_worker_task(task_id integer)
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    task pgl_validate.worker_task;
    table_list regclass[];
    peer_list text[];
    request_options jsonb;
    request_repset text;
    request_reference text;
BEGIN
    SELECT *
    INTO task
    FROM pgl_validate.worker_task wt
    WHERE wt.task_id = _run_worker_task.task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'worker task % does not exist', task_id
            USING ERRCODE = '02000';
    END IF;

    IF task.status = 'canceled' THEN
        UPDATE pgl_validate.run
        SET status = 'canceled',
            finished_at = COALESCE(finished_at, clock_timestamp())
        WHERE run_id = task.run_id
          AND status IN ('planning','fencing','running','paused','rechecking');
        RETURN;
    END IF;

    IF task.status <> 'running' THEN
        RAISE EXCEPTION 'worker task % is %, expected running', task.task_id, task.status
            USING ERRCODE = '55000';
    END IF;

    IF task.task_kind <> 'compare' THEN
        RAISE EXCEPTION 'unsupported worker task kind %', task.task_kind
            USING ERRCODE = '0A000';
    END IF;

    SELECT array_agg(t.table_name::regclass ORDER BY t.ordinality)
    INTO table_list
    FROM jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(task.request->'tables') = 'array' THEN task.request->'tables'
            ELSE '[]'::jsonb
        END
    ) WITH ORDINALITY AS t(table_name, ordinality);

    SELECT array_agg(p.peer_name ORDER BY p.ordinality)
    INTO peer_list
    FROM jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(task.request->'peers') = 'array' THEN task.request->'peers'
            ELSE '[]'::jsonb
        END
    ) WITH ORDINALITY AS p(peer_name, ordinality);

    request_options := COALESCE(task.request->'options', '{}'::jsonb);
    request_repset := NULLIF(task.request->>'repset', '');
    request_reference := NULLIF(task.request->>'reference', '');

    BEGIN
        PERFORM pgl_validate.compare(
            table_list,
            request_repset,
            peer_list,
            request_reference,
            request_options || jsonb_build_object('_pgl_validate_parent_run_id', task.run_id)
        );

        UPDATE pgl_validate.worker_task
        SET status = 'completed',
            finished_at = clock_timestamp(),
            error = NULL
        WHERE pgl_validate.worker_task.task_id = task.task_id;
    EXCEPTION WHEN others THEN
        UPDATE pgl_validate.worker_task
        SET status = 'failed',
            finished_at = clock_timestamp(),
            error = SQLERRM
        WHERE pgl_validate.worker_task.task_id = task.task_id;

        UPDATE pgl_validate.run
        SET status = 'failed',
            finished_at = clock_timestamp(),
            error = SQLERRM
        WHERE run_id = task.run_id
          AND status <> 'canceled';
    END;
END
$$;

CREATE FUNCTION pgl_validate.purge(before timestamptz)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    deleted_runs bigint;
BEGIN
    IF before IS NULL THEN
        RAISE EXCEPTION 'purge cutoff timestamp is required'
            USING ERRCODE = '22004';
    END IF;

    WITH deleted AS (
        DELETE FROM pgl_validate.run r
        WHERE r.status IN ('completed','failed','canceled')
          AND COALESCE(r.finished_at, r.started_at) < purge.before
        RETURNING 1
    )
    SELECT count(*) INTO deleted_runs FROM deleted;

    PERFORM pgl_validate.cleanup_fence_barriers();

    RETURN deleted_runs;
END
$$;

CREATE FUNCTION pgl_validate.run_status(run_id bigint)
RETURNS pgl_validate.run
LANGUAGE sql
STABLE
AS $$
    SELECT r FROM pgl_validate.run r WHERE r.run_id = run_status.run_id
$$;

CREATE FUNCTION pgl_validate.divergences(run_id bigint)
RETURNS SETOF pgl_validate.divergence
LANGUAGE sql
STABLE
AS $$
    SELECT d.* FROM pgl_validate.divergence d WHERE d.run_id = divergences.run_id
$$;

CREATE FUNCTION pgl_validate.conflict_evidence(run_id bigint)
RETURNS SETOF pgl_validate.conflict_evidence
LANGUAGE sql
STABLE
AS $$
    SELECT ce.*
    FROM pgl_validate.conflict_evidence ce
    WHERE ce.run_id = conflict_evidence.run_id
    ORDER BY ce.recorded_at DESC, ce.conflict_id DESC
$$;

CREATE FUNCTION pgl_validate.sequences(run_id bigint)
RETURNS SETOF pgl_validate.sequence_result
LANGUAGE sql
STABLE
AS $$
    SELECT s.* FROM pgl_validate.sequence_result s WHERE s.run_id = sequences.run_id
$$;

CREATE FUNCTION pgl_validate.report(p_run_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
WITH selected_run AS (
    SELECT r.*
    FROM pgl_validate.run r
    WHERE r.run_id = p_run_id
)
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM selected_run) THEN
        jsonb_build_object('run_id', p_run_id, 'error', 'run not found')
    ELSE
        jsonb_build_object(
            'run', (SELECT to_jsonb(r) FROM selected_run r),
            'participants',
                COALESCE((
                    SELECT jsonb_agg(to_jsonb(rp) ORDER BY rp.node)
                    FROM pgl_validate.run_participant rp
                    WHERE rp.run_id = p_run_id
                ), '[]'::jsonb),
            'tables',
                COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'plan', to_jsonb(tp),
                            'result', to_jsonb(tr),
                            'nodes',
                                COALESCE((
                                    SELECT jsonb_agg(to_jsonb(tnr) ORDER BY tnr.node)
                                    FROM pgl_validate.table_node_result tnr
                                    WHERE tnr.run_id = tp.run_id
                                      AND tnr.schema_name = tp.schema_name
                                      AND tnr.table_name = tp.table_name
                                ), '[]'::jsonb),
                            'chunks',
                                COALESCE((
                                    SELECT jsonb_agg(
                                        jsonb_build_object(
                                            'chunk', to_jsonb(cr),
                                            'nodes',
                                                COALESCE((
                                                    SELECT jsonb_agg(to_jsonb(cnr) ORDER BY cnr.node)
                                                    FROM pgl_validate.chunk_node_result cnr
                                                    WHERE cnr.run_id = cr.run_id
                                                      AND cnr.schema_name = cr.schema_name
                                                      AND cnr.table_name = cr.table_name
                                                      AND cnr.chunk_id = cr.chunk_id
                                                ), '[]'::jsonb)
                                        )
                                        ORDER BY cr.chunk_id
                                    )
                                    FROM pgl_validate.chunk_result cr
                                    WHERE cr.run_id = tp.run_id
                                      AND cr.schema_name = tp.schema_name
                                      AND cr.table_name = tp.table_name
                                ), '[]'::jsonb),
                            'divergences',
                                COALESCE((
                                    SELECT jsonb_agg(
                                        jsonb_build_object(
                                            'divergence', to_jsonb(d),
                                            'rechecks',
                                                COALESCE((
                                                    SELECT jsonb_agg(to_jsonb(dr) ORDER BY dr.epoch_seq)
                                                    FROM pgl_validate.divergence_recheck dr
                                                    WHERE dr.run_id = d.run_id
                                                      AND dr.schema_name = d.schema_name
                                                      AND dr.table_name = d.table_name
                                                      AND dr.key_bytes = d.key_bytes
                                                      AND dr.node = d.node
                                                ), '[]'::jsonb),
                                            'conflict_evidence',
                                                COALESCE((
                                                    SELECT jsonb_agg(
                                                        to_jsonb(ce)
                                                        ORDER BY ce.recorded_at DESC, ce.conflict_id DESC
                                                    )
                                                    FROM pgl_validate.conflict_evidence ce
                                                    WHERE ce.run_id = d.run_id
                                                      AND ce.schema_name = d.schema_name
                                                      AND ce.table_name = d.table_name
                                                      AND ce.key_bytes = d.key_bytes
                                                      AND ce.node = d.node
                                                ), '[]'::jsonb)
                                        )
                                        ORDER BY d.detected_at, d.node, d.key_text
                                    )
                                    FROM pgl_validate.divergence d
                                    WHERE d.run_id = tp.run_id
                                      AND d.schema_name = tp.schema_name
                                      AND d.table_name = tp.table_name
                                ), '[]'::jsonb)
                        )
                        ORDER BY tp.schema_name, tp.table_name
                    )
                    FROM pgl_validate.table_plan tp
                    LEFT JOIN pgl_validate.table_result tr
                      ON tr.run_id = tp.run_id
                     AND tr.schema_name = tp.schema_name
                     AND tr.table_name = tp.table_name
                    WHERE tp.run_id = p_run_id
                ), '[]'::jsonb),
            'sequences',
                COALESCE((
                    SELECT jsonb_agg(to_jsonb(sr) ORDER BY sr.schema_name, sr.seq_name, sr.subscriber_node)
                    FROM pgl_validate.sequence_result sr
                    WHERE sr.run_id = p_run_id
                ), '[]'::jsonb),
            'schema_issues',
                COALESCE((
                    SELECT jsonb_agg(to_jsonb(si) ORDER BY si.node, si.schema_name, si.table_name, si.issue_code)
                    FROM pgl_validate.schema_issue si
                    WHERE si.run_id = p_run_id
                ), '[]'::jsonb),
            'fence',
                jsonb_build_object(
                    'epochs',
                        COALESCE((
                            SELECT jsonb_agg(to_jsonb(fe) ORDER BY fe.epoch_seq)
                            FROM pgl_validate.fence_epoch fe
                            WHERE fe.run_id = p_run_id
                        ), '[]'::jsonb),
                    'edges',
                        COALESCE((
                            SELECT jsonb_agg(to_jsonb(re) ORDER BY re.edge_id)
                            FROM pgl_validate.run_edge re
                            WHERE re.run_id = p_run_id
                        ), '[]'::jsonb),
                    'targets',
                        COALESCE((
                            SELECT jsonb_agg(to_jsonb(fedge) ORDER BY fedge.epoch_seq, fedge.edge_id)
                            FROM pgl_validate.fence_edge fedge
                            WHERE fedge.run_id = p_run_id
                        ), '[]'::jsonb),
                    'attempts',
                        COALESCE((
                            SELECT jsonb_agg(to_jsonb(fa) ORDER BY fa.epoch_seq, fa.edge_id)
                            FROM pgl_validate.fence_attempt fa
                            WHERE fa.run_id = p_run_id
                        ), '[]'::jsonb),
                    'barriers',
                        COALESCE((
                            SELECT jsonb_agg(to_jsonb(fbr) ORDER BY fbr.epoch_seq, fbr.edge_id)
                            FROM pgl_validate.fence_barrier_run fbr
                            WHERE fbr.run_id = p_run_id
                        ), '[]'::jsonb)
                )
        )
END
$$;

CREATE FUNCTION pgl_validate.metrics()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
SELECT jsonb_build_object(
    'runs',
        jsonb_build_object(
            'total', (SELECT count(*) FROM pgl_validate.run),
            'by_status',
                COALESCE((
                    SELECT jsonb_object_agg(status, n)
                    FROM (
                        SELECT r.status, count(*) AS n
                        FROM pgl_validate.run r
                        GROUP BY r.status
                        ORDER BY r.status
                    ) s
                ), '{}'::jsonb),
            'last_completed_at',
                (SELECT max(r.finished_at) FROM pgl_validate.run r WHERE r.status = 'completed')
        ),
    'tables',
        jsonb_build_object(
            'by_verdict',
                COALESCE((
                    SELECT jsonb_object_agg(verdict, n)
                    FROM (
                        SELECT tr.verdict, count(*) AS n
                        FROM pgl_validate.table_result tr
                        GROUP BY tr.verdict
                        ORDER BY tr.verdict
                    ) s
                ), '{}'::jsonb),
            'last_successful_validation',
                (SELECT max(tr.finished_at) FROM pgl_validate.table_result tr WHERE tr.verdict = 'match'),
            'last_successful_by_table',
                COALESCE((
                    SELECT jsonb_object_agg(table_key, last_finished_at)
                    FROM (
                        SELECT
                            tr.schema_name || '.' || tr.table_name AS table_key,
                            max(tr.finished_at) AS last_finished_at
                        FROM pgl_validate.table_result tr
                        WHERE tr.verdict = 'match'
                          AND tr.finished_at IS NOT NULL
                        GROUP BY tr.schema_name, tr.table_name
                        ORDER BY tr.schema_name, tr.table_name
                    ) s
                ), '{}'::jsonb)
        ),
    'sequences',
        jsonb_build_object(
            'by_verdict',
                COALESCE((
                    SELECT jsonb_object_agg(verdict, n)
                    FROM (
                        SELECT sr.verdict, count(*) AS n
                        FROM pgl_validate.sequence_result sr
                        GROUP BY sr.verdict
                        ORDER BY sr.verdict
                    ) s
                ), '{}'::jsonb),
            'out_of_contract',
                (SELECT count(*) FROM pgl_validate.sequence_result sr WHERE NOT sr.within_contract)
        ),
    'divergences',
        jsonb_build_object(
            'by_status',
                COALESCE((
                    SELECT jsonb_object_agg(status, n)
                    FROM (
                        SELECT d.status, count(*) AS n
                        FROM pgl_validate.divergence d
                        GROUP BY d.status
                        ORDER BY d.status
                    ) s
                ), '{}'::jsonb),
            'confirmed',
                (SELECT count(*) FROM pgl_validate.divergence d WHERE d.status = 'confirmed')
        ),
    'fences',
        jsonb_build_object(
            'attempts_by_status',
                COALESCE((
                    SELECT jsonb_object_agg(status, n)
                    FROM (
                        SELECT fa.status, count(*) AS n
                        FROM pgl_validate.fence_attempt fa
                        GROUP BY fa.status
                        ORDER BY fa.status
                    ) s
                ), '{}'::jsonb)
        ),
    'io',
        jsonb_build_object(
            'rows_scanned',
                COALESCE((SELECT sum(tnr.n_rows) FROM pgl_validate.table_node_result tnr), 0)
              + COALESCE((SELECT sum(cnr.n_rows) FROM pgl_validate.chunk_node_result cnr), 0),
            'bytes_transferred',
                COALESCE((
                    SELECT sum(
                        COALESCE(octet_length(tnr.lthash), 0)
                      + COALESCE(octet_length(tnr.set_hash), 0)
                    )
                    FROM pgl_validate.table_node_result tnr
                    WHERE tnr.node <> 'local'
                ), 0)
              + COALESCE((
                    SELECT sum(COALESCE(octet_length(cnr.lthash), 0))
                    FROM pgl_validate.chunk_node_result cnr
                    WHERE cnr.node <> 'local'
                ), 0)
              + COALESCE((
                    SELECT sum(COALESCE(octet_length(d.key_bytes), 0))
                    FROM pgl_validate.divergence d
                    WHERE d.node <> 'local'
                ), 0)
        )
)
$$;

