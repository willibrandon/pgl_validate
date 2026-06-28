-- Ensure the dedicated insert-only barrier replication set exists on the
-- current pglogical node and carries only the standalone barrier table.
CREATE FUNCTION pgl_validate.ensure_pglogical_barrier_repset()
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    set_rec record;
    table_member boolean;
BEGIN
    IF to_regprocedure('pglogical.create_replication_set(name,boolean,boolean,boolean,boolean)') IS NULL THEN
        RAISE EXCEPTION 'pglogical extension is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    SELECT rs.*
    INTO set_rec
    FROM pglogical.replication_set rs
    JOIN pglogical.local_node ln ON ln.node_id = rs.set_nodeid
    WHERE rs.set_name = 'pgl_validate_barrier'::name;

    IF NOT FOUND THEN
        PERFORM pglogical.create_replication_set(
            'pgl_validate_barrier'::name,
            true,
            false,
            false,
            false
        );
    ELSIF NOT (
        set_rec.replicate_insert
        AND NOT set_rec.replicate_update
        AND NOT set_rec.replicate_delete
        AND NOT set_rec.replicate_truncate
    ) THEN
        RAISE EXCEPTION
            'pglogical replication set pgl_validate_barrier exists but is not insert-only';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pglogical.replication_set rs
        JOIN pglogical.local_node ln ON ln.node_id = rs.set_nodeid
        JOIN pglogical.replication_set_table rst ON rst.set_id = rs.set_id
        WHERE rs.set_name = 'pgl_validate_barrier'::name
          AND rst.set_reloid <> 'pgl_validate.fence_barrier'::regclass
    ) THEN
        RAISE EXCEPTION
            'pglogical replication set pgl_validate_barrier must contain only pgl_validate.fence_barrier';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM pglogical.replication_set rs
        JOIN pglogical.local_node ln ON ln.node_id = rs.set_nodeid
        JOIN pglogical.replication_set_table rst ON rst.set_id = rs.set_id
        WHERE rs.set_name = 'pgl_validate_barrier'::name
          AND rst.set_reloid = 'pgl_validate.fence_barrier'::regclass
    )
    INTO table_member;

    IF NOT table_member THEN
        PERFORM pglogical.replication_set_add_table(
            'pgl_validate_barrier'::name,
            'pgl_validate.fence_barrier'::regclass,
            false
        );
    END IF;
END
$$;

-- Return the current database's pglogical node identity and local interface DSN.
CREATE FUNCTION pgl_validate.pglogical_local_node()
RETURNS TABLE (node_name text, dsn text)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF to_regclass('pglogical.local_node') IS NULL THEN
        RAISE EXCEPTION 'pglogical extension is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    RETURN QUERY
    SELECT n.node_name::text, ni.if_dsn::text
    FROM pglogical.local_node ln
    JOIN pglogical.node n ON n.node_id = ln.node_id
    JOIN pglogical.node_interface ni ON ni.if_id = ln.node_local_interface;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pglogical local node is not configured'
            USING ERRCODE = '0A000';
    END IF;
END
$$;

-- Return subscriber-side pglogical table sync state using the raw sync catalog.
CREATE FUNCTION pgl_validate.pglogical_subscription_table_sync_status(
    p_subscription_name name,
    p_relation regclass
)
RETURNS TABLE (sync_status text, sync_status_lsn pg_lsn)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    schema_name name;
    table_name name;
BEGIN
    IF to_regclass('pglogical.local_sync_status') IS NULL THEN
        RAISE EXCEPTION 'pglogical extension is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    PERFORM 1
    FROM pglogical.subscription s
    WHERE s.sub_name = p_subscription_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pglogical subscription % not found', p_subscription_name
            USING ERRCODE = '02000';
    END IF;

    SELECT n.nspname::name, c.relname::name
    INTO schema_name, table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_relation;

    IF schema_name IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', p_relation;
    END IF;

    RETURN QUERY
    SELECT lss.sync_status::text, lss.sync_statuslsn
    FROM pglogical.local_sync_status lss
    JOIN pglogical.subscription s ON s.sub_id = lss.sync_subid
    WHERE s.sub_name = p_subscription_name
      AND lss.sync_nspname = schema_name
      AND lss.sync_relname = table_name
    ORDER BY lss.sync_statuslsn DESC NULLS LAST
    LIMIT 1;

    IF NOT FOUND THEN
        sync_status := 'r';
        sync_status_lsn := NULL;
        RETURN NEXT;
    END IF;
END
$$;

-- Ensure a local pglogical subscription carries the barrier replication set.
CREATE FUNCTION pgl_validate.ensure_pglogical_subscription_barrier(
    p_subscription_name name
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    subscription_rec record;
BEGIN
    PERFORM pgl_validate.ensure_pglogical_barrier_repset();

    SELECT *
    INTO subscription_rec
    FROM pglogical.show_subscription_status(p_subscription_name) AS s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pglogical subscription % not found', p_subscription_name
            USING ERRCODE = '02000';
    END IF;

    IF 'pgl_validate_barrier' = ANY (
        COALESCE(subscription_rec.replication_sets, ARRAY[]::text[])
    ) THEN
        RETURN false;
    END IF;

    PERFORM pglogical.alter_subscription_add_replication_set(
        p_subscription_name,
        'pgl_validate_barrier'::name
    );
    RETURN true;
END
$$;

-- Register a pglogical peer and install the pgl_validate barrier set on both
-- directed subscriptions when they can be discovered.
CREATE FUNCTION pgl_validate.register_pglogical_peer(
    p_peer_name text,
    p_peer_dsn text,
    p_subscription_name name DEFAULT NULL,
    p_reverse_subscription_name name DEFAULT NULL,
    p_replication_sets text[] DEFAULT NULL,
    p_connect_timeout_seconds integer DEFAULT 10,
    p_statement_timeout_ms integer DEFAULT 600000,
    p_lock_timeout_ms integer DEFAULT 30000
)
RETURNS pgl_validate.peer
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    local_node_rec record;
    remote_node_rec record;
    forward_subscription_count int;
    reverse_subscription_count int;
    forward_subscription_rec record;
    reverse_subscription_rec record;
    resolved_subscription name;
    resolved_reverse_subscription name;
    resolved_replication_sets text[];
    result_row pgl_validate.peer;
BEGIN
    IF p_peer_name IS NULL OR btrim(p_peer_name) = '' THEN
        RAISE EXCEPTION 'peer name is required';
    END IF;
    IF p_peer_dsn IS NULL OR btrim(p_peer_dsn) = '' THEN
        RAISE EXCEPTION 'peer dsn is required';
    END IF;
    IF p_connect_timeout_seconds <= 0 THEN
        RAISE EXCEPTION 'connect_timeout_seconds must be greater than zero';
    END IF;
    IF p_statement_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'statement_timeout_ms must be greater than zero';
    END IF;
    IF p_lock_timeout_ms <= 0 THEN
        RAISE EXCEPTION 'lock_timeout_ms must be greater than zero';
    END IF;

    PERFORM pgl_validate.ensure_pglogical_barrier_repset();

    SELECT *
    INTO local_node_rec
    FROM pgl_validate.pglogical_local_node();

    SELECT *
    INTO remote_node_rec
    FROM pgl_validate.remote_pglogical_local_node(
        p_peer_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    );

    SELECT count(*)
    INTO forward_subscription_count
    FROM pgl_validate.remote_pglogical_subscriptions(
        p_peer_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    ) AS s
    WHERE CASE
              WHEN p_subscription_name IS NULL THEN s.provider_node = local_node_rec.node_name
              ELSE s.subscription_name = p_subscription_name::text
          END;

    IF forward_subscription_count = 0 THEN
        IF p_subscription_name IS NULL THEN
            RAISE EXCEPTION
                'no pglogical subscription on peer % receives from local node %; pass subscription_name explicitly if discovery is ambiguous',
                p_peer_name,
                local_node_rec.node_name
                USING ERRCODE = '02000';
        END IF;
        RAISE EXCEPTION
            'pglogical subscription % not found on peer %',
            p_subscription_name,
            p_peer_name
            USING ERRCODE = '02000';
    END IF;

    IF forward_subscription_count > 1 THEN
        RAISE EXCEPTION
            'multiple pglogical subscriptions on peer % receive from local node %; pass subscription_name explicitly',
            p_peer_name,
            local_node_rec.node_name
            USING ERRCODE = '0A000';
    END IF;

    SELECT *
    INTO forward_subscription_rec
    FROM pgl_validate.remote_pglogical_subscriptions(
        p_peer_dsn,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    ) AS s
    WHERE CASE
              WHEN p_subscription_name IS NULL THEN s.provider_node = local_node_rec.node_name
              ELSE s.subscription_name = p_subscription_name::text
          END
    LIMIT 1;

    resolved_subscription := forward_subscription_rec.subscription_name::name;

    SELECT array_agg(repset ORDER BY repset)
    INTO resolved_replication_sets
    FROM jsonb_array_elements_text(
        forward_subscription_rec.replication_sets_json::jsonb
    ) AS repsets(repset)
    WHERE repset <> 'pgl_validate_barrier';

    resolved_replication_sets := COALESCE(
        p_replication_sets,
        resolved_replication_sets,
        ARRAY['default']::text[]
    );

    IF p_reverse_subscription_name IS NULL THEN
        SELECT count(*)
        INTO reverse_subscription_count
        FROM pglogical.show_subscription_status() AS s
        WHERE s.provider_node = remote_node_rec.node_name;

        IF reverse_subscription_count = 1 THEN
            SELECT *
            INTO reverse_subscription_rec
            FROM pglogical.show_subscription_status() AS s
            WHERE s.provider_node = remote_node_rec.node_name
            LIMIT 1;

            resolved_reverse_subscription := reverse_subscription_rec.subscription_name::name;
        ELSIF reverse_subscription_count > 1 THEN
            RAISE EXCEPTION
                'multiple local pglogical subscriptions receive from peer node %; pass reverse_subscription_name explicitly',
                remote_node_rec.node_name
                USING ERRCODE = '0A000';
        END IF;
    ELSE
        SELECT count(*)
        INTO reverse_subscription_count
        FROM pglogical.show_subscription_status(p_reverse_subscription_name) AS s;

        IF reverse_subscription_count = 0 THEN
            RAISE EXCEPTION
                'local pglogical reverse subscription % not found',
                p_reverse_subscription_name
                USING ERRCODE = '02000';
        END IF;

        resolved_reverse_subscription := p_reverse_subscription_name;
    END IF;

    PERFORM pgl_validate.remote_ensure_pglogical_barrier_subscription(
        p_peer_dsn,
        resolved_subscription::text,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    );

    IF resolved_reverse_subscription IS NOT NULL THEN
        PERFORM pgl_validate.ensure_pglogical_subscription_barrier(
            resolved_reverse_subscription
        );
    END IF;

    INSERT INTO pgl_validate.peer(
        name,
        dsn,
        backend,
        subscription_name,
        reverse_subscription_name,
        replication_sets,
        connect_timeout_seconds,
        statement_timeout_ms,
        lock_timeout_ms
    )
    VALUES (
        p_peer_name,
        p_peer_dsn,
        'pglogical',
        resolved_subscription,
        resolved_reverse_subscription,
        resolved_replication_sets,
        p_connect_timeout_seconds,
        p_statement_timeout_ms,
        p_lock_timeout_ms
    )
    ON CONFLICT (name) DO UPDATE
    SET dsn = EXCLUDED.dsn,
        backend = EXCLUDED.backend,
        subscription_name = EXCLUDED.subscription_name,
        reverse_subscription_name = EXCLUDED.reverse_subscription_name,
        replication_sets = EXCLUDED.replication_sets,
        connect_timeout_seconds = EXCLUDED.connect_timeout_seconds,
        statement_timeout_ms = EXCLUDED.statement_timeout_ms,
        lock_timeout_ms = EXCLUDED.lock_timeout_ms
    RETURNING * INTO result_row;

    RETURN result_row;
END
$$;

-- Remove a pgl_validate peer registration without modifying the replication
-- topology or shared barrier replication set.
CREATE FUNCTION pgl_validate.unregister_pglogical_peer(
    p_peer_name text
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    removed_count int;
BEGIN
    DELETE FROM pgl_validate.peer p
    WHERE p.name = p_peer_name
      AND p.backend = 'pglogical';

    GET DIAGNOSTICS removed_count = ROW_COUNT;
    RETURN removed_count > 0;
END
$$;

-- Ensure the native logical barrier publication exists on the current provider
-- and publishes only INSERTs for the standalone barrier table.
CREATE FUNCTION pgl_validate.ensure_native_barrier_publication(
    p_publication text DEFAULT 'pgl_validate_barrier'
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    publication_rec record;
    table_member boolean;
BEGIN
    IF p_publication IS NULL OR btrim(p_publication) = '' THEN
        RAISE EXCEPTION 'publication name is required';
    END IF;

    SELECT p.*
    INTO publication_rec
    FROM pg_publication p
    WHERE p.pubname = p_publication::name;

    IF NOT FOUND THEN
        EXECUTE format(
            'CREATE PUBLICATION %I FOR TABLE pgl_validate.fence_barrier WITH (publish = %L)',
            p_publication,
            'insert'
        );
        RETURN;
    END IF;

    IF NOT (
        publication_rec.pubinsert
        AND NOT publication_rec.pubupdate
        AND NOT publication_rec.pubdelete
        AND NOT publication_rec.pubtruncate
    ) THEN
        RAISE EXCEPTION
            'native publication % exists but is not insert-only',
            p_publication;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM pg_publication_tables pt
        WHERE pt.pubname = p_publication
          AND pt.schemaname = 'pgl_validate'
          AND pt.tablename = 'fence_barrier'
    )
    INTO table_member;

    IF NOT table_member THEN
        EXECUTE format(
            'ALTER PUBLICATION %I ADD TABLE pgl_validate.fence_barrier',
            p_publication
        );
    END IF;
END
$$;

