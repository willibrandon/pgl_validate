CREATE FUNCTION pgl_validate.record_barrier_fence(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_token uuid,
    p_origin_node text,
    p_barrier_end_lsn pg_lsn
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF p_token IS NULL THEN
        RAISE EXCEPTION 'barrier token is required';
    END IF;
    IF p_barrier_end_lsn IS NULL THEN
        RAISE EXCEPTION 'barrier_end_lsn is required';
    END IF;

    INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
    VALUES (p_run_id, p_epoch_seq)
    ON CONFLICT (run_id, epoch_seq) DO NOTHING;

    INSERT INTO pgl_validate.fence_edge(
        run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
    )
    VALUES (
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        'barrier',
        p_token,
        p_barrier_end_lsn
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET fence_kind = 'barrier',
        barrier_token = EXCLUDED.barrier_token,
        barrier_end_lsn = EXCLUDED.barrier_end_lsn;

    INSERT INTO pgl_validate.fence_barrier_run(
        token, run_id, epoch_seq, edge_id, origin_node, barrier_end_lsn
    )
    VALUES (
        p_token,
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        p_origin_node,
        p_barrier_end_lsn
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET token = EXCLUDED.token,
        origin_node = EXCLUDED.origin_node,
        barrier_end_lsn = EXCLUDED.barrier_end_lsn;
END
$$;

CREATE FUNCTION pgl_validate.record_fence_attempt(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_barrier_end_lsn pg_lsn,
    p_origin_progress_lsn pg_lsn,
    p_token_visible boolean,
    p_confirmed_flush_lsn pg_lsn DEFAULT NULL,
    p_status text DEFAULT NULL
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    derived_status text;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_barrier_end_lsn IS NULL THEN
        RAISE EXCEPTION 'barrier_end_lsn is required';
    END IF;
    IF p_token_visible IS NULL THEN
        RAISE EXCEPTION 'token_visible is required';
    END IF;

    derived_status := COALESCE(
        p_status,
        CASE
            WHEN p_origin_progress_lsn IS NOT NULL
             AND p_origin_progress_lsn >= p_barrier_end_lsn
             AND p_token_visible
            THEN 'converged'
            ELSE 'waiting'
        END
    );

    IF derived_status NOT IN ('waiting','converged','timeout','degraded') THEN
        RAISE EXCEPTION 'invalid fence attempt status: %', derived_status;
    END IF;

    INSERT INTO pgl_validate.fence_attempt(
        run_id, epoch_seq, edge_id, barrier_end_lsn, origin_progress_lsn,
        token_visible, confirmed_flush_lsn, converged_at, status
    )
    VALUES (
        p_run_id, p_epoch_seq, p_edge_id, p_barrier_end_lsn, p_origin_progress_lsn,
        p_token_visible, p_confirmed_flush_lsn,
        CASE WHEN derived_status = 'converged' THEN now() ELSE NULL END,
        derived_status
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET barrier_end_lsn = EXCLUDED.barrier_end_lsn,
        origin_progress_lsn = EXCLUDED.origin_progress_lsn,
        token_visible = EXCLUDED.token_visible,
        confirmed_flush_lsn = EXCLUDED.confirmed_flush_lsn,
        converged_at = EXCLUDED.converged_at,
        status = EXCLUDED.status
    RETURNING * INTO result_row;

    RETURN result_row;
END
$$;

CREATE FUNCTION pgl_validate.protected_barrier_tokens()
RETURNS uuid[]
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(array_agg(br.token), ARRAY[]::uuid[])
    FROM pgl_validate.fence_barrier_run br
    JOIN pgl_validate.run r USING (run_id)
    WHERE r.status NOT IN ('completed','failed','canceled')
$$;

CREATE FUNCTION pgl_validate.cleanup_fence_barriers(
    barrier_retention interval DEFAULT interval '1 hour',
    protected uuid[] DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    protected_tokens uuid[] := COALESCE(protected, pgl_validate.protected_barrier_tokens());
    deleted_count bigint;
BEGIN
    WITH deleted AS (
        DELETE FROM pgl_validate.fence_barrier
        WHERE injected_at < now() - barrier_retention
          AND NOT (token = ANY (protected_tokens))
        RETURNING 1
    )
    SELECT count(*) INTO deleted_count FROM deleted;

    RETURN deleted_count;
END
$$;
