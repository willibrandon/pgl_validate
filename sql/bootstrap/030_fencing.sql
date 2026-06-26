-- Fence one pglogical provider->target edge by injecting a real replicated
-- barrier, waiting for provider-side slot flush, then polling target-side
-- origin progress and token visibility until convergence or timeout.
CREATE FUNCTION pgl_validate.fence_pglogical_edge(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_provider_node text,
    p_target_node text,
    p_provider_dsn text,
    p_target_dsn text,
    p_subscription_name text,
    p_slot_name text,
    p_origin_name text,
    p_repsets text[] DEFAULT ARRAY['pgl_validate_barrier']::text[],
    p_connect_timeout_seconds int DEFAULT 10,
    p_statement_timeout_ms int DEFAULT 600000,
    p_lock_timeout_ms int DEFAULT 30000,
    p_fence_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    injection record;
    confirmed_flush_lsn pg_lsn;
    observation record;
    deadline timestamptz;
    attempt_status text;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge_id is required';
    END IF;
    IF p_provider_node IS NULL OR p_target_node IS NULL THEN
        RAISE EXCEPTION 'provider_node and target_node are required';
    END IF;
    IF p_provider_dsn IS NULL OR p_target_dsn IS NULL THEN
        RAISE EXCEPTION 'provider_dsn and target_dsn are required';
    END IF;
    IF p_slot_name IS NULL THEN
        RAISE EXCEPTION 'slot_name is required';
    END IF;
    IF p_origin_name IS NULL THEN
        RAISE EXCEPTION 'origin_name is required';
    END IF;
    IF p_fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;

    INSERT INTO pgl_validate.run_edge(
        run_id, edge_id, provider_node, target_node, backend,
        subscription, slot_name, origin_name, repsets
    )
    VALUES (
        p_run_id, p_edge_id, p_provider_node, p_target_node, 'pglogical',
        p_subscription_name, p_slot_name, p_origin_name, p_repsets
    )
    ON CONFLICT (run_id, edge_id) DO UPDATE
    SET provider_node = EXCLUDED.provider_node,
        target_node = EXCLUDED.target_node,
        backend = 'pglogical',
        subscription = EXCLUDED.subscription,
        slot_name = EXCLUDED.slot_name,
        origin_name = EXCLUDED.origin_name,
        repsets = EXCLUDED.repsets;

    SELECT *
    INTO injection
    FROM pgl_validate.remote_inject_barrier(
        p_provider_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    );

    PERFORM pgl_validate.record_barrier_fence(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        injection.token,
        p_provider_node,
        injection.barrier_end_lsn
    );

    SELECT pgl_validate.remote_wait_slot_confirm_lsn(
        p_provider_dsn,
        p_slot_name,
        injection.barrier_end_lsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    )
    INTO confirmed_flush_lsn;

    IF confirmed_flush_lsn < injection.barrier_end_lsn THEN
        RAISE EXCEPTION
            'slot % confirmed_flush_lsn % is behind barrier_end_lsn %',
            p_slot_name,
            confirmed_flush_lsn,
            injection.barrier_end_lsn;
    END IF;

    deadline := clock_timestamp() + make_interval(secs => p_fence_timeout_ms / 1000.0);
    LOOP
        SELECT *
        INTO observation
        FROM pgl_validate.remote_observe_barrier(
            p_target_dsn,
            p_origin_name,
            injection.token,
            injection.barrier_end_lsn,
            p_connect_timeout_seconds,
            p_statement_timeout_ms,
            p_lock_timeout_ms
        );

        EXIT WHEN observation.converged;

        IF clock_timestamp() >= deadline THEN
            attempt_status := 'timeout';
            EXIT;
        END IF;

        PERFORM pg_sleep(p_poll_interval_ms / 1000.0);
    END LOOP;

    SELECT *
    INTO result_row
    FROM pgl_validate.record_fence_attempt(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        injection.barrier_end_lsn,
        observation.origin_progress_lsn,
        observation.token_visible,
        confirmed_flush_lsn,
        attempt_status
    );

    RETURN result_row;
END
$$;

-- Fence one native logical provider->target edge by injecting a replicated
-- barrier, waiting for provider slot flush, then polling target-side core
-- replication-origin progress and token visibility until convergence.
CREATE FUNCTION pgl_validate.fence_native_edge(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_provider_node text,
    p_target_node text,
    p_provider_dsn text,
    p_target_dsn text,
    p_subscription_name text,
    p_slot_name text,
    p_origin_name text,
    p_publications text[] DEFAULT ARRAY['pgl_validate_barrier']::text[],
    p_connect_timeout_seconds int DEFAULT 10,
    p_statement_timeout_ms int DEFAULT 600000,
    p_lock_timeout_ms int DEFAULT 30000,
    p_fence_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    injection record;
    confirmed_flush_lsn pg_lsn := '0/0'::pg_lsn;
    observation record;
    deadline timestamptz;
    attempt_status text;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge_id is required';
    END IF;
    IF p_provider_node IS NULL OR p_target_node IS NULL THEN
        RAISE EXCEPTION 'provider_node and target_node are required';
    END IF;
    IF p_provider_dsn IS NULL OR p_target_dsn IS NULL THEN
        RAISE EXCEPTION 'provider_dsn and target_dsn are required';
    END IF;
    IF p_slot_name IS NULL THEN
        RAISE EXCEPTION 'slot_name is required';
    END IF;
    IF p_origin_name IS NULL THEN
        RAISE EXCEPTION 'origin_name is required';
    END IF;
    IF p_fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;

    INSERT INTO pgl_validate.run_edge(
        run_id, edge_id, provider_node, target_node, backend,
        subscription, slot_name, origin_name, repsets
    )
    VALUES (
        p_run_id, p_edge_id, p_provider_node, p_target_node, 'native',
        p_subscription_name, p_slot_name, p_origin_name, p_publications
    )
    ON CONFLICT (run_id, edge_id) DO UPDATE
    SET provider_node = EXCLUDED.provider_node,
        target_node = EXCLUDED.target_node,
        backend = 'native',
        subscription = EXCLUDED.subscription,
        slot_name = EXCLUDED.slot_name,
        origin_name = EXCLUDED.origin_name,
        repsets = EXCLUDED.repsets;

    SELECT *
    INTO injection
    FROM pgl_validate.remote_inject_barrier(
        p_provider_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    );

    PERFORM pgl_validate.record_barrier_fence(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        injection.token,
        p_provider_node,
        injection.barrier_end_lsn
    );

    deadline := clock_timestamp() + make_interval(secs => p_fence_timeout_ms / 1000.0);
    LOOP
        SELECT pgl_validate.remote_slot_confirmed_flush_lsn(
            p_provider_dsn,
            p_slot_name,
            p_connect_timeout_seconds,
            p_statement_timeout_ms,
            p_lock_timeout_ms
        )
        INTO confirmed_flush_lsn;

        EXIT WHEN confirmed_flush_lsn >= injection.barrier_end_lsn;

        IF clock_timestamp() >= deadline THEN
            attempt_status := 'timeout';
            EXIT;
        END IF;

        PERFORM pg_sleep(p_poll_interval_ms / 1000.0);
    END LOOP;

    SELECT *
    INTO observation
    FROM pgl_validate.remote_observe_barrier(
        p_target_dsn,
        p_origin_name,
        injection.token,
        injection.barrier_end_lsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    );

    IF attempt_status IS DISTINCT FROM 'timeout' THEN
        LOOP
            EXIT WHEN observation.converged;

            IF clock_timestamp() >= deadline THEN
                attempt_status := 'timeout';
                EXIT;
            END IF;

            PERFORM pg_sleep(p_poll_interval_ms / 1000.0);

            SELECT *
            INTO observation
            FROM pgl_validate.remote_observe_barrier(
                p_target_dsn,
                p_origin_name,
                injection.token,
                injection.barrier_end_lsn,
                p_connect_timeout_seconds,
                p_statement_timeout_ms,
                p_lock_timeout_ms
            );
        END LOOP;
    END IF;

    SELECT *
    INTO result_row
    FROM pgl_validate.record_fence_attempt(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        injection.barrier_end_lsn,
        observation.origin_progress_lsn,
        observation.token_visible,
        confirmed_flush_lsn,
        attempt_status
    );

    RETURN result_row;
END
$$;

-- Record an explicit degraded pglogical fence for an edge that cannot carry the
-- barrier table. This is never exact: it waits only for provider-side slot
-- flush through a captured WAL LSN and persists status=degraded.
CREATE FUNCTION pgl_validate.fence_pglogical_degraded_edge(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_provider_node text,
    p_target_node text,
    p_provider_dsn text,
    p_subscription_name text,
    p_slot_name text,
    p_origin_name text,
    p_repsets text[] DEFAULT NULL,
    p_connect_timeout_seconds int DEFAULT 10,
    p_statement_timeout_ms int DEFAULT 600000,
    p_lock_timeout_ms int DEFAULT 30000
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    target_lsn pg_lsn;
    confirmed_flush_lsn pg_lsn;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge_id is required';
    END IF;
    IF p_provider_node IS NULL OR p_target_node IS NULL THEN
        RAISE EXCEPTION 'provider_node and target_node are required';
    END IF;
    IF p_provider_dsn IS NULL THEN
        RAISE EXCEPTION 'provider_dsn is required';
    END IF;
    IF p_slot_name IS NULL THEN
        RAISE EXCEPTION 'slot_name is required';
    END IF;
    IF p_origin_name IS NULL THEN
        RAISE EXCEPTION 'origin_name is required';
    END IF;

    INSERT INTO pgl_validate.run_edge(
        run_id, edge_id, provider_node, target_node, backend,
        subscription, slot_name, origin_name, repsets
    )
    VALUES (
        p_run_id, p_edge_id, p_provider_node, p_target_node, 'pglogical',
        p_subscription_name, p_slot_name, p_origin_name, p_repsets
    )
    ON CONFLICT (run_id, edge_id) DO UPDATE
    SET provider_node = EXCLUDED.provider_node,
        target_node = EXCLUDED.target_node,
        backend = 'pglogical',
        subscription = EXCLUDED.subscription,
        slot_name = EXCLUDED.slot_name,
        origin_name = EXCLUDED.origin_name,
        repsets = EXCLUDED.repsets;

    SELECT pgl_validate.remote_current_wal_lsn(
        p_provider_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    )
    INTO target_lsn;

    SELECT pgl_validate.remote_wait_slot_confirm_lsn(
        p_provider_dsn,
        p_slot_name,
        target_lsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    )
    INTO confirmed_flush_lsn;

    IF confirmed_flush_lsn < target_lsn THEN
        RAISE EXCEPTION
            'slot % confirmed_flush_lsn % is behind degraded target_lsn %',
            p_slot_name,
            confirmed_flush_lsn,
            target_lsn;
    END IF;

    INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
    VALUES (p_run_id, p_epoch_seq)
    ON CONFLICT DO NOTHING;

    INSERT INTO pgl_validate.fence_edge(
        run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
    )
    VALUES (
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        'degraded',
        NULL,
        target_lsn
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET fence_kind = 'degraded',
        barrier_token = NULL,
        barrier_end_lsn = EXCLUDED.barrier_end_lsn;

    SELECT *
    INTO result_row
    FROM pgl_validate.record_fence_attempt(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        target_lsn,
        NULL,
        false,
        confirmed_flush_lsn,
        'degraded'
    );

    RETURN result_row;
END
$$;

-- Record an explicit degraded native logical fence for an edge whose
-- subscription cannot carry barrier tokens. This is never exact: only provider
-- slot flush is known, so the persisted attempt is status=degraded.
CREATE FUNCTION pgl_validate.fence_native_degraded_edge(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_provider_node text,
    p_target_node text,
    p_provider_dsn text,
    p_subscription_name text,
    p_slot_name text,
    p_origin_name text,
    p_publications text[] DEFAULT NULL,
    p_connect_timeout_seconds int DEFAULT 10,
    p_statement_timeout_ms int DEFAULT 600000,
    p_lock_timeout_ms int DEFAULT 30000,
    p_fence_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    target_lsn pg_lsn;
    confirmed_flush_lsn pg_lsn := '0/0'::pg_lsn;
    deadline timestamptz;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge_id is required';
    END IF;
    IF p_provider_node IS NULL OR p_target_node IS NULL THEN
        RAISE EXCEPTION 'provider_node and target_node are required';
    END IF;
    IF p_provider_dsn IS NULL THEN
        RAISE EXCEPTION 'provider_dsn is required';
    END IF;
    IF p_slot_name IS NULL THEN
        RAISE EXCEPTION 'slot_name is required';
    END IF;
    IF p_origin_name IS NULL THEN
        RAISE EXCEPTION 'origin_name is required';
    END IF;
    IF p_fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;

    INSERT INTO pgl_validate.run_edge(
        run_id, edge_id, provider_node, target_node, backend,
        subscription, slot_name, origin_name, repsets
    )
    VALUES (
        p_run_id, p_edge_id, p_provider_node, p_target_node, 'native',
        p_subscription_name, p_slot_name, p_origin_name, p_publications
    )
    ON CONFLICT (run_id, edge_id) DO UPDATE
    SET provider_node = EXCLUDED.provider_node,
        target_node = EXCLUDED.target_node,
        backend = 'native',
        subscription = EXCLUDED.subscription,
        slot_name = EXCLUDED.slot_name,
        origin_name = EXCLUDED.origin_name,
        repsets = EXCLUDED.repsets;

    SELECT pgl_validate.remote_current_wal_lsn(
        p_provider_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    )
    INTO target_lsn;

    deadline := clock_timestamp() + make_interval(secs => p_fence_timeout_ms / 1000.0);
    LOOP
        SELECT pgl_validate.remote_slot_confirmed_flush_lsn(
            p_provider_dsn,
            p_slot_name,
            p_connect_timeout_seconds,
            p_statement_timeout_ms,
            p_lock_timeout_ms
        )
        INTO confirmed_flush_lsn;

        EXIT WHEN confirmed_flush_lsn >= target_lsn;

        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION
                'slot % confirmed_flush_lsn % is behind degraded native target_lsn %',
                p_slot_name,
                confirmed_flush_lsn,
                target_lsn
                USING ERRCODE = '57014';
        END IF;

        PERFORM pg_sleep(p_poll_interval_ms / 1000.0);
    END LOOP;

    INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
    VALUES (p_run_id, p_epoch_seq)
    ON CONFLICT DO NOTHING;

    INSERT INTO pgl_validate.fence_edge(
        run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
    )
    VALUES (
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        'degraded',
        NULL,
        target_lsn
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET fence_kind = 'degraded',
        barrier_token = NULL,
        barrier_end_lsn = EXCLUDED.barrier_end_lsn;

    SELECT *
    INTO result_row
    FROM pgl_validate.record_fence_attempt(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        target_lsn,
        NULL,
        false,
        confirmed_flush_lsn,
        'degraded'
    );

    RETURN result_row;
END
$$;

-- Fence one primary->physical-standby edge by capturing a primary WAL LSN and
-- polling the target until physical replay has reached that cut.
CREATE FUNCTION pgl_validate.fence_standby_edge(
    p_run_id bigint,
    p_epoch_seq int,
    p_edge_id int,
    p_provider_node text,
    p_target_node text,
    p_target_dsn text,
    p_target_lsn pg_lsn DEFAULT NULL,
    p_connect_timeout_seconds int DEFAULT 10,
    p_statement_timeout_ms int DEFAULT 600000,
    p_lock_timeout_ms int DEFAULT 30000,
    p_fence_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS pgl_validate.fence_attempt
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    target_lsn pg_lsn := COALESCE(p_target_lsn, pg_current_wal_lsn());
    observation record;
    deadline timestamptz;
    attempt_status text;
    result_row pgl_validate.fence_attempt;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_edge_id IS NULL THEN
        RAISE EXCEPTION 'edge_id is required';
    END IF;
    IF p_provider_node IS NULL OR p_target_node IS NULL THEN
        RAISE EXCEPTION 'provider_node and target_node are required';
    END IF;
    IF p_target_dsn IS NULL THEN
        RAISE EXCEPTION 'target_dsn is required';
    END IF;
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'standby fences must be coordinated from a primary'
            USING ERRCODE = '0A000';
    END IF;
    IF p_fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;

    INSERT INTO pgl_validate.run_edge(
        run_id, edge_id, provider_node, target_node, backend,
        subscription, slot_name, origin_name, repsets
    )
    VALUES (
        p_run_id, p_edge_id, p_provider_node, p_target_node, 'standby',
        NULL, NULL, NULL, NULL
    )
    ON CONFLICT (run_id, edge_id) DO UPDATE
    SET provider_node = EXCLUDED.provider_node,
        target_node = EXCLUDED.target_node,
        backend = 'standby',
        subscription = NULL,
        slot_name = NULL,
        origin_name = NULL,
        repsets = NULL;

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
        'standby_replay',
        NULL,
        target_lsn
    )
    ON CONFLICT (run_id, epoch_seq, edge_id) DO UPDATE
    SET fence_kind = 'standby_replay',
        barrier_token = NULL,
        barrier_end_lsn = EXCLUDED.barrier_end_lsn;

    deadline := clock_timestamp() + make_interval(secs => p_fence_timeout_ms / 1000.0);
    LOOP
        SELECT *
        INTO observation
        FROM pgl_validate.remote_standby_replay_status(
            p_target_dsn,
            p_connect_timeout_seconds,
            p_statement_timeout_ms,
            p_lock_timeout_ms
        );

        IF NOT observation.in_recovery THEN
            RAISE EXCEPTION 'standby peer % is not in recovery', p_target_node
                USING ERRCODE = '0A000';
        END IF;

        EXIT WHEN observation.replay_lsn >= target_lsn;

        IF clock_timestamp() >= deadline THEN
            attempt_status := 'timeout';
            EXIT;
        END IF;

        PERFORM pg_sleep(p_poll_interval_ms / 1000.0);
    END LOOP;

    SELECT *
    INTO result_row
    FROM pgl_validate.record_fence_attempt(
        p_run_id,
        p_epoch_seq,
        p_edge_id,
        target_lsn,
        observation.replay_lsn,
        true,
        NULL,
        attempt_status
    );

    RETURN result_row;
END
$$;

