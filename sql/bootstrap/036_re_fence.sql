-- Re-fence the exact edge vector already selected for a validation run.
-- This is used by long table validations to bound the age of a convergence
-- epoch without rediscovering topology or weakening the original edge set.
CREATE FUNCTION pgl_validate.re_fence_run_edges(
    p_run_id bigint,
    p_epoch_seq int,
    p_provider_node text,
    p_provider_dsn text,
    p_edge_ids int[] DEFAULT NULL,
    p_fence_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    edge_rec record;
    provider_peer pgl_validate.peer%ROWTYPE;
    target_peer pgl_validate.peer%ROWTYPE;
    timeout_peer pgl_validate.peer%ROWTYPE;
    edge_provider_dsn text;
    edge_target_dsn text;
    edge_fence_kind text;
    connect_timeout_seconds int;
    statement_timeout_ms int;
    lock_timeout_ms int;
    fence_rec pgl_validate.fence_attempt;
    re_fenced_count int := 0;
BEGIN
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_epoch_seq IS NULL THEN
        RAISE EXCEPTION 'epoch_seq is required';
    END IF;
    IF p_provider_node IS NULL THEN
        RAISE EXCEPTION 'provider_node is required';
    END IF;
    IF p_fence_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'fence_timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;

    INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
    VALUES (p_run_id, p_epoch_seq)
    ON CONFLICT DO NOTHING;

    FOR edge_rec IN
        SELECT re.*
        FROM pgl_validate.run_edge re
        WHERE re.run_id = p_run_id
          AND (p_edge_ids IS NULL OR re.edge_id = ANY (p_edge_ids))
        ORDER BY re.edge_id
    LOOP
        provider_peer := NULL;
        target_peer := NULL;
        timeout_peer := NULL;
        edge_provider_dsn := NULL;
        edge_target_dsn := NULL;
        edge_fence_kind := NULL;

        IF edge_rec.provider_node = p_provider_node THEN
            edge_provider_dsn := p_provider_dsn;
        ELSE
            SELECT *
            INTO provider_peer
            FROM pgl_validate.peer p
            WHERE p.name = edge_rec.provider_node;

            IF provider_peer.name IS NULL THEN
                RAISE EXCEPTION
                    'cannot re-fence edge %, provider peer % was not found',
                    edge_rec.edge_id,
                    edge_rec.provider_node
                    USING ERRCODE = '02000';
            END IF;

            edge_provider_dsn := provider_peer.dsn;
            timeout_peer := provider_peer;
        END IF;

        IF edge_rec.target_node = p_provider_node THEN
            edge_target_dsn := p_provider_dsn;
        ELSE
            SELECT *
            INTO target_peer
            FROM pgl_validate.peer p
            WHERE p.name = edge_rec.target_node;

            IF target_peer.name IS NULL THEN
                RAISE EXCEPTION
                    'cannot re-fence edge %, target peer % was not found',
                    edge_rec.edge_id,
                    edge_rec.target_node
                    USING ERRCODE = '02000';
            END IF;

            edge_target_dsn := target_peer.dsn;
            timeout_peer := target_peer;
        END IF;

        IF timeout_peer.name IS NULL THEN
            SELECT *
            INTO timeout_peer
            FROM pgl_validate.peer p
            WHERE p.name = edge_rec.target_node
               OR p.name = edge_rec.provider_node
            ORDER BY CASE WHEN p.name = edge_rec.target_node THEN 0 ELSE 1 END
            LIMIT 1;
        END IF;

        connect_timeout_seconds := COALESCE(timeout_peer.connect_timeout_seconds, 10);
        statement_timeout_ms := COALESCE(timeout_peer.statement_timeout_ms, 600000);
        lock_timeout_ms := COALESCE(timeout_peer.lock_timeout_ms, 30000);

        SELECT fe.fence_kind
        INTO edge_fence_kind
        FROM pgl_validate.fence_edge fe
        WHERE fe.run_id = p_run_id
          AND fe.edge_id = edge_rec.edge_id
        ORDER BY fe.epoch_seq DESC
        LIMIT 1;

        edge_fence_kind := COALESCE(
            edge_fence_kind,
            CASE WHEN edge_rec.backend = 'standby' THEN 'standby_replay' ELSE 'barrier' END
        );

        IF edge_rec.backend = 'pglogical' THEN
            IF edge_rec.slot_name IS NULL OR edge_rec.origin_name IS NULL THEN
                RAISE EXCEPTION
                    'cannot re-fence pglogical edge %, slot_name and origin_name are required',
                    edge_rec.edge_id
                    USING ERRCODE = '0A000';
            END IF;

            IF edge_fence_kind = 'degraded' THEN
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_degraded_edge(
                    p_run_id,
                    p_epoch_seq,
                    edge_rec.edge_id,
                    edge_rec.provider_node,
                    edge_rec.target_node,
                    edge_provider_dsn,
                    edge_rec.subscription,
                    edge_rec.slot_name,
                    edge_rec.origin_name,
                    edge_rec.repsets,
                    connect_timeout_seconds,
                    statement_timeout_ms,
                    lock_timeout_ms
                );

                IF fence_rec.status <> 'degraded' THEN
                    RAISE EXCEPTION
                        'pglogical edge % failed to record degraded re-fence: %',
                        edge_rec.edge_id,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            ELSE
                IF edge_provider_dsn IS NULL OR edge_target_dsn IS NULL THEN
                    RAISE EXCEPTION
                        'cannot re-fence pglogical edge %, provider and target DSNs are required',
                        edge_rec.edge_id
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_pglogical_edge(
                    p_run_id,
                    p_epoch_seq,
                    edge_rec.edge_id,
                    edge_rec.provider_node,
                    edge_rec.target_node,
                    edge_provider_dsn,
                    edge_target_dsn,
                    edge_rec.subscription,
                    edge_rec.slot_name,
                    edge_rec.origin_name,
                    COALESCE(edge_rec.repsets, ARRAY['pgl_validate_barrier']::text[]),
                    connect_timeout_seconds,
                    statement_timeout_ms,
                    lock_timeout_ms,
                    p_fence_timeout_ms,
                    p_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'pglogical edge % failed to converge re-fence: %',
                        edge_rec.edge_id,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END IF;
        ELSIF edge_rec.backend = 'native' THEN
            IF edge_rec.slot_name IS NULL OR edge_rec.origin_name IS NULL THEN
                RAISE EXCEPTION
                    'cannot re-fence native edge %, slot_name and origin_name are required',
                    edge_rec.edge_id
                    USING ERRCODE = '0A000';
            END IF;

            IF edge_fence_kind = 'degraded' THEN
                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_native_degraded_edge(
                    p_run_id,
                    p_epoch_seq,
                    edge_rec.edge_id,
                    edge_rec.provider_node,
                    edge_rec.target_node,
                    edge_provider_dsn,
                    edge_rec.subscription,
                    edge_rec.slot_name,
                    edge_rec.origin_name,
                    edge_rec.repsets,
                    connect_timeout_seconds,
                    statement_timeout_ms,
                    lock_timeout_ms,
                    p_fence_timeout_ms,
                    p_poll_interval_ms
                );

                IF fence_rec.status <> 'degraded' THEN
                    RAISE EXCEPTION
                        'native edge % failed to record degraded re-fence: %',
                        edge_rec.edge_id,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            ELSE
                IF edge_provider_dsn IS NULL OR edge_target_dsn IS NULL THEN
                    RAISE EXCEPTION
                        'cannot re-fence native edge %, provider and target DSNs are required',
                        edge_rec.edge_id
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO fence_rec
                FROM pgl_validate.fence_native_edge(
                    p_run_id,
                    p_epoch_seq,
                    edge_rec.edge_id,
                    edge_rec.provider_node,
                    edge_rec.target_node,
                    edge_provider_dsn,
                    edge_target_dsn,
                    edge_rec.subscription,
                    edge_rec.slot_name,
                    edge_rec.origin_name,
                    COALESCE(edge_rec.repsets, ARRAY['pgl_validate_barrier']::text[]),
                    connect_timeout_seconds,
                    statement_timeout_ms,
                    lock_timeout_ms,
                    p_fence_timeout_ms,
                    p_poll_interval_ms
                );

                IF fence_rec.status <> 'converged' THEN
                    RAISE EXCEPTION
                        'native edge % failed to converge re-fence: %',
                        edge_rec.edge_id,
                        fence_rec.status
                        USING ERRCODE = '57014';
                END IF;
            END IF;
        ELSIF edge_rec.backend = 'standby' THEN
            IF edge_target_dsn IS NULL THEN
                RAISE EXCEPTION
                    'cannot re-fence standby edge %, target DSN is required',
                    edge_rec.edge_id
                    USING ERRCODE = '0A000';
            END IF;

            SELECT *
            INTO fence_rec
            FROM pgl_validate.fence_standby_edge(
                p_run_id,
                p_epoch_seq,
                edge_rec.edge_id,
                edge_rec.provider_node,
                edge_rec.target_node,
                edge_target_dsn,
                NULL,
                connect_timeout_seconds,
                statement_timeout_ms,
                lock_timeout_ms,
                p_fence_timeout_ms,
                p_poll_interval_ms
            );

            IF fence_rec.status <> 'converged' THEN
                RAISE EXCEPTION
                    'standby edge % failed to converge re-fence: %',
                    edge_rec.edge_id,
                    fence_rec.status
                    USING ERRCODE = '57014';
            END IF;
        ELSE
            RAISE EXCEPTION 'unsupported edge backend %', edge_rec.backend
                USING ERRCODE = '0A000';
        END IF;

        re_fenced_count := re_fenced_count + 1;
    END LOOP;

    RETURN re_fenced_count;
END
$$;
