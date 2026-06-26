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
BEGIN
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
                (SELECT max(tr.finished_at) FROM pgl_validate.table_result tr WHERE tr.verdict = 'match')
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
        )
)
$$;

