CREATE SCHEMA IF NOT EXISTS pgl_validate;

CREATE TABLE pgl_validate.peer (
    name      text PRIMARY KEY,
    dsn       text NOT NULL,
    backend   text NOT NULL DEFAULT 'pglogical'
              CHECK (backend IN ('pglogical','native','standby')),
    added_at  timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON pgl_validate.peer FROM PUBLIC;

CREATE TABLE pgl_validate.run (
    run_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status         text NOT NULL CHECK (status IN
                   ('planning','fencing','running','paused','rechecking',
                    'completed','failed','canceled')),
    options        jsonb NOT NULL DEFAULT '{}',
    reference_node text,
    launched_by    name NOT NULL DEFAULT current_user,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    tables_total   int,
    tables_matched int,
    tables_differ  int,
    error          text
);

CREATE TABLE pgl_validate.run_participant (
    run_id     bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    node       text NOT NULL,
    role       text NOT NULL CHECK (role IN ('coordinator','reference','participant')),
    backend    text NOT NULL CHECK (backend IN ('pglogical','native','standby')),
    pg_version int  NOT NULL,
    dsn_ref    text,
    status     text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','connected','converged','unreachable','done','error')),
    PRIMARY KEY (run_id, node)
);

CREATE TABLE pgl_validate.fence_epoch (
    run_id     bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    epoch_seq  int NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, epoch_seq)
);

CREATE TABLE pgl_validate.run_edge (
    run_id        bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    edge_id       int NOT NULL,
    provider_node text NOT NULL,
    target_node   text NOT NULL,
    backend       text NOT NULL CHECK (backend IN ('pglogical','native','standby')),
    subscription  text,
    slot_name     text,
    origin_name   text,
    repsets       text[],
    PRIMARY KEY (run_id, edge_id)
);

CREATE TABLE pgl_validate.fence_edge (
    run_id          bigint NOT NULL,
    epoch_seq       int NOT NULL,
    edge_id         int NOT NULL,
    fence_kind      text NOT NULL CHECK (fence_kind IN ('barrier','standby_replay','degraded')),
    barrier_token   uuid,
    barrier_end_lsn pg_lsn,
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    CONSTRAINT fence_edge_required CHECK (
        (fence_kind = 'barrier'        AND barrier_token IS NOT NULL AND barrier_end_lsn IS NOT NULL) OR
        (fence_kind = 'standby_replay' AND barrier_token IS NULL     AND barrier_end_lsn IS NOT NULL) OR
        (fence_kind = 'degraded')
    ),
    FOREIGN KEY (run_id, epoch_seq) REFERENCES pgl_validate.fence_epoch(run_id, epoch_seq) ON DELETE CASCADE,
    FOREIGN KEY (run_id, edge_id) REFERENCES pgl_validate.run_edge(run_id, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.fence_attempt (
    run_id              bigint NOT NULL,
    epoch_seq           int NOT NULL,
    edge_id             int NOT NULL,
    barrier_end_lsn     pg_lsn,
    origin_progress_lsn pg_lsn,
    token_visible       boolean NOT NULL DEFAULT false,
    confirmed_flush_lsn pg_lsn,
    converged_at        timestamptz,
    status              text NOT NULL DEFAULT 'waiting'
                        CHECK (status IN ('waiting','converged','timeout','degraded')),
    CONSTRAINT fence_attempt_converged_truth CHECK (
        status <> 'converged'
        OR (barrier_end_lsn IS NOT NULL
            AND origin_progress_lsn IS NOT NULL
            AND origin_progress_lsn >= barrier_end_lsn
            AND token_visible)
    ),
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    FOREIGN KEY (run_id, epoch_seq, edge_id)
        REFERENCES pgl_validate.fence_edge(run_id, epoch_seq, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.fence_barrier (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    token       uuid NOT NULL,
    injected_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fence_barrier_token_idx ON pgl_validate.fence_barrier (token);

CREATE TABLE pgl_validate.fence_barrier_run (
    token           uuid NOT NULL,
    run_id          bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    epoch_seq       int NOT NULL,
    edge_id         int NOT NULL,
    origin_node     text NOT NULL,
    barrier_end_lsn pg_lsn,
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    FOREIGN KEY (run_id, edge_id) REFERENCES pgl_validate.run_edge(run_id, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.table_plan (
    run_id             bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    schema_name        text NOT NULL,
    table_name         text NOT NULL,
    key_cols           text[],
    att_list           text[],
    repsets            text[],
    repl_insert        boolean,
    repl_update        boolean,
    repl_delete        boolean,
    repl_truncate      boolean,
    has_row_filter     boolean NOT NULL DEFAULT false,
    sync_status        "char",
    validated_property text NOT NULL
                       CHECK (validated_property IN ('full','superset','keys_only',
                              'filtered_intersection','filtered_advisory','keyless',
                              'unsupported_mask','skipped')),
    PRIMARY KEY (run_id, schema_name, table_name)
);

CREATE TABLE pgl_validate.table_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    verdict     text NOT NULL CHECK (verdict IN
                ('match','differ','indeterminate','partial','approximate',
                 'degraded','skipped','error','fence_timeout')),
    reason      text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (run_id, schema_name, table_name),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.table_node_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    node        text NOT NULL,
    n_rows      bigint,
    lthash      bytea,
    set_hash    bytea,
    PRIMARY KEY (run_id, schema_name, table_name, node),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.chunk_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    chunk_id    bigint NOT NULL,
    parent_id   bigint,
    lo          bytea,
    hi          bytea,
    state       text NOT NULL CHECK (state IN
                ('pending','running','clean','split','divergent','candidate')),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, chunk_id),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.chunk_node_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    chunk_id    bigint NOT NULL,
    node        text NOT NULL,
    n_rows      bigint,
    lthash      bytea,
    PRIMARY KEY (run_id, schema_name, table_name, chunk_id, node),
    FOREIGN KEY (run_id, schema_name, table_name, chunk_id)
        REFERENCES pgl_validate.chunk_result(run_id, schema_name, table_name, chunk_id)
        ON DELETE CASCADE
);

CREATE TABLE pgl_validate.divergence (
    run_id         bigint NOT NULL,
    schema_name    text NOT NULL,
    table_name     text NOT NULL,
    key_text       text NOT NULL,
    key_bytes      bytea NOT NULL,
    classification text NOT NULL CHECK (classification IN ('missing_on','extra_on','differs')),
    node           text NOT NULL,
    status         text NOT NULL DEFAULT 'candidate'
                   CHECK (status IN ('candidate','confirmed','cleared','indeterminate','advisory')),
    detected_epoch int NOT NULL,
    tuple          jsonb,
    detected_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, key_bytes, node),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE,
    FOREIGN KEY (run_id, detected_epoch)
        REFERENCES pgl_validate.fence_epoch(run_id, epoch_seq)
);

CREATE TABLE pgl_validate.divergence_recheck (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    key_bytes   bytea NOT NULL,
    node        text NOT NULL,
    epoch_seq   int NOT NULL,
    outcome     text NOT NULL CHECK (outcome IN ('still_differs','cleared','still_hot')),
    at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, key_bytes, node, epoch_seq),
    FOREIGN KEY (run_id, schema_name, table_name, key_bytes, node)
        REFERENCES pgl_validate.divergence(run_id, schema_name, table_name, key_bytes, node)
        ON DELETE CASCADE
);

CREATE TABLE pgl_validate.sequence_result (
    run_id                bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    schema_name           text NOT NULL,
    seq_name              text NOT NULL,
    provider_node         text NOT NULL,
    provider_last_value   bigint,
    subscriber_node       text NOT NULL,
    subscriber_last_value bigint,
    cache_size            int,
    within_contract       boolean,
    verdict               text NOT NULL CHECK (verdict IN ('match','behind','ahead_of_window','error')),
    PRIMARY KEY (run_id, schema_name, seq_name, subscriber_node)
);

CREATE TABLE pgl_validate.schema_issue (
    run_id      bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    node        text NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    issue_code  text NOT NULL,
    detail      text,
    PRIMARY KEY (run_id, node, schema_name, table_name, issue_code)
);

CREATE TABLE pgl_validate.schedule (
    name        text PRIMARY KEY,
    cron        text NOT NULL,
    tables      text[],
    repset      text,
    peers       text[],
    options     jsonb NOT NULL DEFAULT '{}',
    enabled     boolean NOT NULL DEFAULT true,
    last_run_id bigint REFERENCES pgl_validate.run(run_id) ON DELETE SET NULL
);

CREATE TABLE pgl_validate.repair_run (
    repair_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id         bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    authoritative  text NOT NULL,
    target         text NOT NULL,
    propagation    text NOT NULL CHECK (propagation IN ('local_only','replicate')),
    paused_subs    text[],
    origin_name    text,
    status         text NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running','applied','revalidated','failed','rolled_back')),
    launched_by    name NOT NULL DEFAULT current_user,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    error          text
);

CREATE TABLE pgl_validate.repair_result (
    repair_id      bigint NOT NULL REFERENCES pgl_validate.repair_run(repair_id) ON DELETE CASCADE,
    schema_name    text NOT NULL,
    table_name     text NOT NULL,
    key_bytes      bytea NOT NULL,
    action         text NOT NULL CHECK (action IN ('insert','update','delete','setval')),
    statement      text NOT NULL,
    post_verdict   text CHECK (post_verdict IN ('match','still_differs','indeterminate')),
    PRIMARY KEY (repair_id, schema_name, table_name, key_bytes, action)
);

CREATE OR REPLACE VIEW pgl_validate.runs AS
SELECT * FROM pgl_validate.run;

CREATE OR REPLACE VIEW pgl_validate.table_results AS
SELECT * FROM pgl_validate.table_result;

CREATE OR REPLACE VIEW pgl_validate.chunk_results AS
SELECT * FROM pgl_validate.chunk_result;

CREATE OR REPLACE VIEW pgl_validate.divergences AS
SELECT * FROM pgl_validate.divergence;

CREATE OR REPLACE VIEW pgl_validate.sequence_results AS
SELECT * FROM pgl_validate.sequence_result;

CREATE OR REPLACE VIEW pgl_validate.schema_issues AS
SELECT * FROM pgl_validate.schema_issue;

CREATE OR REPLACE VIEW pgl_validate.run_progress AS
SELECT
    r.run_id,
    r.status,
    count(cr.*) FILTER (WHERE cr.state IN ('clean','divergent')) AS chunks_done,
    count(cr.*) AS chunks_total,
    r.started_at,
    r.finished_at
FROM pgl_validate.run r
LEFT JOIN pgl_validate.chunk_result cr USING (run_id)
GROUP BY r.run_id, r.status, r.started_at, r.finished_at;

-- Pick the coordinator-pushed encoding mode for a column. This is intentionally
-- conservative for types whose binary send format is less suitable as a
-- cross-version contract; the coordinator emits the chosen mode positionally in
-- row_digest(enc[], VARIADIC "any").
CREATE FUNCTION pgl_validate.column_encoding_mode(type_oid oid)
RETURNS int
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN type_oid IN ('json'::regtype::oid, 'numeric'::regtype::oid) THEN 2
        WHEN t.typsend = 0 THEN 2
        ELSE 1
    END
    FROM pg_type t
    WHERE t.oid = type_oid
$$;

-- Generate the planner-visible SQL used to checksum a table chunk. Columns are
-- sorted by name before they are passed as heterogeneous VARIADIC row_digest
-- arguments; callers may EXPLAIN the returned SQL directly on a participant.
CREATE FUNCTION pgl_validate.plan_chunk_sql(
    rel regclass,
    key_cols text[],
    lo bytea,
    hi bytea,
    cols text[],
    repsets text[] DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel_sql text;
    enc_modes int[];
    digest_args text;
    selected_cols text[];
BEGIN
    IF lo IS NOT NULL OR hi IS NOT NULL THEN
        RAISE EXCEPTION 'bounded chunks are not available until Merkle planning is enabled'
            USING ERRCODE = '0A000';
    END IF;

    SELECT format('%I.%I', n.nspname, c.relname)
    INTO rel_sql
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = rel;

    IF rel_sql IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', rel;
    END IF;

    IF cols IS NULL OR cardinality(cols) = 0 THEN
        SELECT array_agg(a.attname ORDER BY a.attname)
        INTO selected_cols
        FROM pg_attribute a
        WHERE a.attrelid = rel
          AND a.attnum > 0
          AND NOT a.attisdropped;
    ELSE
        SELECT array_agg(a.attname ORDER BY a.attname)
        INTO selected_cols
        FROM unnest(cols) requested(col_name)
        JOIN pg_attribute a
          ON a.attrelid = rel
         AND a.attname = requested.col_name
         AND a.attnum > 0
         AND NOT a.attisdropped;

        IF cardinality(selected_cols) IS DISTINCT FROM cardinality(cols) THEN
            RAISE EXCEPTION 'one or more requested columns are not present on %', rel::text;
        END IF;
    END IF;

    IF selected_cols IS NULL OR cardinality(selected_cols) = 0 THEN
        RAISE EXCEPTION 'no comparable columns found on %', rel::text;
    END IF;

    SELECT
        array_agg(pgl_validate.column_encoding_mode(a.atttypid) ORDER BY a.attname),
        string_agg(format('t.%I', a.attname), ', ' ORDER BY a.attname)
    INTO enc_modes, digest_args
    FROM pg_attribute a
    WHERE a.attrelid = rel
      AND a.attname = ANY (selected_cols)
      AND a.attnum > 0
      AND NOT a.attisdropped;

    RETURN format(
        'SELECT count(*)::bigint AS n_rows, pgl_validate.lthash_bytes(pgl_validate.lthash(pgl_validate.row_digest(%L::int[], %s))) AS lthash FROM %s t WHERE true',
        enc_modes::text,
        digest_args,
        rel_sql
    );
END
$$;

-- First executable comparison path: compute and persist the local node's table
-- checksum using the same generated SQL that the coordinator will send to
-- remote peers. Multi-peer transport layers build on this catalog contract.
CREATE FUNCTION pgl_validate.compare_table(
    table_name regclass,
    peers text[] DEFAULT NULL,
    options jsonb DEFAULT '{}'
)
RETURNS pgl_validate.table_result
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_run_id bigint;
    schema_name text;
    rel_name text;
    cols text[];
    key_cols text[];
    checksum_sql text;
    n_rows bigint;
    lthash bytea;
    result_row pgl_validate.table_result;
BEGIN
    IF peers IS NOT NULL AND cardinality(peers) > 0 THEN
        RAISE EXCEPTION 'remote peer transport is not available in this build slice'
            USING ERRCODE = '0A000';
    END IF;

    SELECT n.nspname, c.relname
    INTO schema_name, rel_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = table_name;

    IF schema_name IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', table_name;
    END IF;

    SELECT array_agg(a.attname ORDER BY a.attname)
    INTO cols
    FROM pg_attribute a
    WHERE a.attrelid = table_name
      AND a.attnum > 0
      AND NOT a.attisdropped;

    SELECT array_agg(a.attname ORDER BY ord.ordinality)
    INTO key_cols
    FROM pg_index i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS ord(attnum, ordinality)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ord.attnum
    WHERE i.indrelid = table_name
      AND i.indisprimary;

    INSERT INTO pgl_validate.run(status, options, tables_total)
    VALUES ('running', options, 1)
    RETURNING pgl_validate.run.run_id INTO v_run_id;

    INSERT INTO pgl_validate.run_participant(run_id, node, role, backend, pg_version, status)
    VALUES (v_run_id, 'local', 'coordinator', 'pglogical', current_setting('server_version_num')::int, 'connected');

    INSERT INTO pgl_validate.table_plan(
        run_id, schema_name, table_name, key_cols, att_list, repsets,
        repl_insert, repl_update, repl_delete, repl_truncate,
        has_row_filter, sync_status, validated_property
    )
    VALUES (
        v_run_id, schema_name, rel_name, key_cols, cols, NULL,
        true, true, true, true,
        false, 'r', 'full'
    );

    checksum_sql := pgl_validate.plan_chunk_sql(table_name, key_cols, NULL, NULL, cols, NULL);
    EXECUTE checksum_sql INTO n_rows, lthash;

    INSERT INTO pgl_validate.table_node_result(
        run_id, schema_name, table_name, node, n_rows, lthash, set_hash
    )
    VALUES (v_run_id, schema_name, rel_name, 'local', n_rows, lthash, NULL);

    INSERT INTO pgl_validate.table_result(
        run_id, schema_name, table_name, verdict, reason, finished_at
    )
    VALUES (
        v_run_id, schema_name, rel_name, 'match',
        'single local participant; remote transport not yet involved',
        now()
    )
    RETURNING * INTO result_row;

    UPDATE pgl_validate.run
    SET status = 'completed',
        finished_at = now(),
        tables_matched = 1,
        tables_differ = 0
    WHERE pgl_validate.run.run_id = v_run_id;

    UPDATE pgl_validate.run_participant
    SET status = 'done'
    WHERE pgl_validate.run_participant.run_id = v_run_id
      AND node = 'local';

    RETURN result_row;
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

CREATE FUNCTION pgl_validate.sequences(run_id bigint)
RETURNS SETOF pgl_validate.sequence_result
LANGUAGE sql
STABLE
AS $$
    SELECT s.* FROM pgl_validate.sequence_result s WHERE s.run_id = sequences.run_id
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
