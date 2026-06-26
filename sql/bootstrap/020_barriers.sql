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

