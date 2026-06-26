CREATE FUNCTION pgl_validate.throttle_replication_lag(
    p_run_id bigint,
    p_schema_name text,
    p_table_name text,
    p_provider_node text,
    p_provider_dsn text,
    p_edge_ids int[],
    p_max_lag interval,
    p_timeout_ms int DEFAULT 300000,
    p_poll_interval_ms int DEFAULT 100
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    threshold_ms bigint;
    deadline timestamptz;
    edge_rec record;
    provider_dsn text;
    lag_rec record;
    lagging boolean;
    lag_detail text;
    slept boolean := false;
BEGIN
    IF p_max_lag IS NULL THEN
        RETURN;
    END IF;
    IF p_run_id IS NULL THEN
        RAISE EXCEPTION 'run_id is required';
    END IF;
    IF p_max_lag <= interval '0' THEN
        RAISE EXCEPTION 'max lag must be greater than zero';
    END IF;
    IF p_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'timeout_ms must be greater than zero';
    END IF;
    IF p_poll_interval_ms <= 0 THEN
        RAISE EXCEPTION 'poll_interval_ms must be greater than zero';
    END IF;
    IF p_edge_ids IS NULL OR cardinality(p_edge_ids) = 0 THEN
        RETURN;
    END IF;

    threshold_ms := ceil(extract(epoch FROM p_max_lag) * 1000)::bigint;
    IF threshold_ms <= 0 THEN
        RAISE EXCEPTION 'max lag must be at least one millisecond';
    END IF;

    deadline := clock_timestamp() + make_interval(secs => p_timeout_ms / 1000.0);
    LOOP
        lagging := false;
        lag_detail := NULL;

        FOR edge_rec IN
            SELECT re.*,
                   provider_peer.dsn AS provider_peer_dsn,
                   provider_peer.connect_timeout_seconds AS provider_connect_timeout_seconds,
                   provider_peer.statement_timeout_ms AS provider_statement_timeout_ms,
                   provider_peer.lock_timeout_ms AS provider_lock_timeout_ms,
                   target_peer.dsn AS target_peer_dsn,
                   target_peer.connect_timeout_seconds AS target_connect_timeout_seconds,
                   target_peer.statement_timeout_ms AS target_statement_timeout_ms,
                   target_peer.lock_timeout_ms AS target_lock_timeout_ms,
                   standby_fence.barrier_end_lsn AS standby_target_lsn
            FROM pgl_validate.run_edge re
            LEFT JOIN pgl_validate.peer provider_peer ON provider_peer.name = re.provider_node
            LEFT JOIN pgl_validate.peer target_peer ON target_peer.name = re.target_node
            LEFT JOIN LATERAL (
                SELECT fe.barrier_end_lsn
                FROM pgl_validate.fence_edge fe
                WHERE fe.run_id = re.run_id
                  AND fe.edge_id = re.edge_id
                  AND fe.fence_kind = 'standby_replay'
                ORDER BY fe.epoch_seq DESC
                LIMIT 1
            ) standby_fence ON true
            WHERE re.run_id = p_run_id
              AND re.edge_id = ANY (p_edge_ids)
              AND (
                    (re.backend IN ('pglogical','native') AND re.slot_name IS NOT NULL)
                    OR re.backend = 'standby'
                  )
            ORDER BY re.edge_id
        LOOP
            IF edge_rec.backend IN ('pglogical','native') THEN
                provider_dsn := CASE
                    WHEN edge_rec.provider_node = p_provider_node THEN p_provider_dsn
                    ELSE edge_rec.provider_peer_dsn
                END;

                IF provider_dsn IS NULL THEN
                    RAISE EXCEPTION
                        'cannot throttle edge % (% -> %): provider DSN is unknown',
                        edge_rec.edge_id,
                        edge_rec.provider_node,
                        edge_rec.target_node
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO lag_rec
                FROM pgl_validate.remote_logical_slot_lag(
                    provider_dsn,
                    edge_rec.slot_name,
                    COALESCE(edge_rec.provider_connect_timeout_seconds, 10),
                    COALESCE(edge_rec.provider_statement_timeout_ms, 600000),
                    COALESCE(edge_rec.provider_lock_timeout_ms, 30000)
                );

                IF NOT lag_rec.active OR lag_rec.lag_ms > threshold_ms THEN
                    lagging := true;
                    lag_detail := format(
                        'edge %s %s->%s backend=%s slot=%s active=%s lag_ms=%s lag_bytes=%s threshold_ms=%s',
                        edge_rec.edge_id,
                        edge_rec.provider_node,
                        edge_rec.target_node,
                        edge_rec.backend,
                        edge_rec.slot_name,
                        lag_rec.active,
                        lag_rec.lag_ms,
                        lag_rec.lag_bytes,
                        threshold_ms
                    );
                END IF;
            ELSIF edge_rec.backend = 'standby' THEN
                IF edge_rec.target_peer_dsn IS NULL THEN
                    RAISE EXCEPTION
                        'cannot throttle standby edge % (% -> %): target DSN is unknown',
                        edge_rec.edge_id,
                        edge_rec.provider_node,
                        edge_rec.target_node
                        USING ERRCODE = '0A000';
                END IF;
                IF edge_rec.standby_target_lsn IS NULL THEN
                    RAISE EXCEPTION
                        'cannot throttle standby edge % (% -> %): no standby replay fence is recorded',
                        edge_rec.edge_id,
                        edge_rec.provider_node,
                        edge_rec.target_node
                        USING ERRCODE = '0A000';
                END IF;

                SELECT *
                INTO lag_rec
                FROM pgl_validate.remote_standby_replay_lag(
                    edge_rec.target_peer_dsn,
                    edge_rec.standby_target_lsn,
                    COALESCE(edge_rec.target_connect_timeout_seconds, 10),
                    COALESCE(edge_rec.target_statement_timeout_ms, 600000),
                    COALESCE(edge_rec.target_lock_timeout_ms, 30000)
                );

                IF NOT lag_rec.in_recovery THEN
                    RAISE EXCEPTION 'standby peer % is not in recovery', edge_rec.target_node
                        USING ERRCODE = '0A000';
                END IF;

                IF lag_rec.lag_ms IS NULL OR lag_rec.lag_ms > threshold_ms THEN
                    lagging := true;
                    lag_detail := format(
                        'edge %s %s->%s backend=standby target_lsn=%s replay_lsn=%s lag_ms=%s threshold_ms=%s',
                        edge_rec.edge_id,
                        edge_rec.provider_node,
                        edge_rec.target_node,
                        edge_rec.standby_target_lsn,
                        lag_rec.replay_lsn,
                        lag_rec.lag_ms,
                        threshold_ms
                    );
                END IF;
            END IF;

            IF lagging THEN
                INSERT INTO pgl_validate.schema_issue(
                    run_id, node, schema_name, table_name, issue_code, detail
                )
                VALUES (
                    p_run_id,
                    edge_rec.target_node,
                    COALESCE(p_schema_name, '<unknown>'),
                    COALESCE(p_table_name, '<unknown>'),
                    'THROTTLED_REPLICATION_LAG',
                    lag_detail
                )
                ON CONFLICT (run_id, node, schema_name, table_name, issue_code) DO UPDATE
                SET detail = EXCLUDED.detail;

                EXIT;
            END IF;
        END LOOP;

        EXIT WHEN NOT lagging;

        UPDATE pgl_validate.run
        SET status = 'paused'
        WHERE run_id = p_run_id
          AND status IN ('planning','fencing','running','rechecking','paused');
        slept := true;

        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION
                'replication lag remained above throttle_max_lag after % ms: %',
                p_timeout_ms,
                lag_detail
                USING ERRCODE = '57014';
        END IF;

        PERFORM pg_sleep(p_poll_interval_ms / 1000.0);
    END LOOP;

    IF slept THEN
        UPDATE pgl_validate.run
        SET status = 'running'
        WHERE run_id = p_run_id
          AND status = 'paused';
    END IF;
END
$$;
