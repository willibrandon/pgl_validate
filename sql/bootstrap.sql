CREATE SCHEMA IF NOT EXISTS pgl_validate;

CREATE TABLE pgl_validate.peer (
    name                    text PRIMARY KEY,
    dsn                     text NOT NULL,
    backend                 text NOT NULL DEFAULT 'pglogical'
                            CHECK (backend IN ('pglogical','native','standby')),
    subscription_name       name,
    replication_sets        text[],
    connect_timeout_seconds int NOT NULL DEFAULT 10
                            CHECK (connect_timeout_seconds > 0),
    statement_timeout_ms    int NOT NULL DEFAULT 600000
                            CHECK (statement_timeout_ms > 0),
    lock_timeout_ms         int NOT NULL DEFAULT 30000
                            CHECK (lock_timeout_ms > 0),
    added_at                timestamptz NOT NULL DEFAULT now()
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

-- Resolve the pglogical replication contract for one relation. The effective
-- column list is taken from pglogical.show_repset_table_info(), because that is
-- pglogical's own resolved bitmap after combining all covering repsets.
CREATE FUNCTION pgl_validate.pglogical_table_contract(
    relation regclass,
    input_repsets text[] DEFAULT NULL,
    subscription_name name DEFAULT NULL
)
RETURNS TABLE (
    schema_name text,
    table_name text,
    key_cols text[],
    att_list text[],
    repsets text[],
    repl_insert boolean,
    repl_update boolean,
    repl_delete boolean,
    repl_truncate boolean,
    has_row_filter boolean,
    sync_status "char",
    validated_property text,
    exact_comparable boolean,
    reason text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    info record;
    action_rec record;
    status_text text;
BEGIN
    IF to_regprocedure('pglogical.show_repset_table_info(regclass,text[])') IS NULL THEN
        RAISE EXCEPTION 'pglogical extension is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    SELECT n.nspname, c.relname
    INTO schema_name, table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = relation;

    SELECT array_agg(a.attname ORDER BY ord.ordinality)
    INTO key_cols
    FROM pg_index i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS ord(attnum, ordinality)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ord.attnum
    WHERE i.indrelid = relation
      AND i.indisprimary;

    IF input_repsets IS NULL OR cardinality(input_repsets) = 0 THEN
        SELECT array_agg(DISTINCT rs.set_name::text ORDER BY rs.set_name::text)
        INTO repsets
        FROM pglogical.replication_set_table rst
        JOIN pglogical.replication_set rs ON rs.set_id = rst.set_id
        WHERE rst.set_reloid = relation;
    ELSE
        SELECT array_agg(DISTINCT requested.repset ORDER BY requested.repset)
        INTO repsets
        FROM unnest(input_repsets) AS requested(repset);
    END IF;

    IF repsets IS NULL OR cardinality(repsets) = 0 THEN
        att_list := NULL;
        repl_insert := false;
        repl_update := false;
        repl_delete := false;
        repl_truncate := false;
        has_row_filter := false;
        sync_status := NULL;
        validated_property := 'skipped';
        exact_comparable := false;
        reason := 'table is not a member of any selected pglogical replication set';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT *
    INTO info
    FROM pglogical.show_repset_table_info(relation, repsets);

    att_list := info.att_list;
    IF att_list IS NULL OR cardinality(att_list) = 0 THEN
        SELECT array_agg(a.attname ORDER BY a.attname)
        INTO att_list
        FROM pg_attribute a
        WHERE a.attrelid = relation
          AND a.attnum > 0
          AND NOT a.attisdropped;
    END IF;
    has_row_filter := COALESCE(info.has_row_filter, false);

    SELECT bool_or(rs.replicate_insert) AS repl_insert,
           bool_or(rs.replicate_update) AS repl_update,
           bool_or(rs.replicate_delete) AS repl_delete,
           bool_or(rs.replicate_truncate) AS repl_truncate
    INTO action_rec
    FROM pglogical.replication_set rs
    WHERE rs.set_name::text = ANY (repsets);

    repl_insert := COALESCE(action_rec.repl_insert, false);
    repl_update := COALESCE(action_rec.repl_update, false);
    repl_delete := COALESCE(action_rec.repl_delete, false);
    repl_truncate := COALESCE(action_rec.repl_truncate, false);

    sync_status := 'r';
    IF subscription_name IS NOT NULL THEN
        SELECT s.status
        INTO status_text
        FROM pglogical.show_subscription_table(subscription_name, relation) AS s;

        IF status_text IS NOT NULL THEN
            sync_status := left(status_text, 1)::"char";
        END IF;
    ELSE
        SELECT lss.sync_status
        INTO sync_status
        FROM pglogical.local_sync_status lss
        WHERE lss.sync_nspname = schema_name::name
          AND lss.sync_relname = table_name::name
        ORDER BY lss.sync_statuslsn DESC
        LIMIT 1;

        sync_status := COALESCE(sync_status, 'r');
    END IF;

    IF sync_status <> 'r' THEN
        validated_property := 'skipped';
        exact_comparable := false;
        reason := format('pglogical sync status is %s, not ready', sync_status);
    ELSIF NOT repl_insert THEN
        validated_property := 'unsupported_mask';
        exact_comparable := false;
        reason := 'replicate_insert=false means the provider row set does not bound the subscriber';
    ELSIF has_row_filter AND repl_update THEN
        validated_property := 'filtered_intersection';
        exact_comparable := false;
        reason := 'pglogical row filters allow legitimate presence differences; localization is required';
    ELSIF has_row_filter THEN
        validated_property := 'filtered_advisory';
        exact_comparable := false;
        reason := 'pglogical filtered table without update replication is advisory only';
    ELSIF repl_update AND repl_delete AND repl_truncate THEN
        validated_property := 'full';
        exact_comparable := true;
        reason := 'full pglogical action mask with no row filter';
    ELSIF repl_update THEN
        validated_property := 'superset';
        exact_comparable := false;
        reason := 'delete or truncate is not replicated, so subscriber extras are legitimate';
    ELSE
        validated_property := 'keys_only';
        exact_comparable := false;
        reason := 'updates are not replicated, so content drift is contract-permitted';
    END IF;

    RETURN NEXT;
END
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
    contract_repsets text[];
    contract_subscription name;
    contract_rec record;
    plan_repsets text[];
    repl_insert boolean := true;
    repl_update boolean := true;
    repl_delete boolean := true;
    repl_truncate boolean := true;
    has_row_filter boolean := false;
    sync_status "char" := 'r';
    validated_property text := 'full';
    exact_comparable boolean := true;
    contract_reason text := 'direct full-table comparison';
    pglogical_available boolean;
    table_in_pglogical boolean := false;
    requested_backend text;
    peer_names text[];
    missing_peers text[];
    peer_rec record;
    remote_rec record;
    checksum_sql text;
    n_rows bigint;
    lthash bytea;
    differ_count int := 0;
    participant_count int := 1;
    verdict text;
    result_reason text;
    result_row pgl_validate.table_result;
BEGIN
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

    requested_backend := COALESCE(NULLIF(options->>'backend', ''), 'pglogical');
    contract_subscription := NULLIF(options->>'subscription', '')::name;
    pglogical_available := to_regprocedure('pglogical.show_repset_table_info(regclass,text[])') IS NOT NULL;

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

    IF options ? 'repsets' THEN
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
            WHERE rst.set_reloid = table_name
        )
        INTO table_in_pglogical;
    ELSIF options ? 'backend' AND requested_backend = 'pglogical' THEN
        RAISE EXCEPTION 'backend=pglogical requested but pglogical is not installed in this database'
            USING ERRCODE = '0A000';
    END IF;

    IF requested_backend = 'pglogical'
       AND pglogical_available
       AND (table_in_pglogical
            OR contract_repsets IS NOT NULL
            OR contract_subscription IS NOT NULL) THEN
        SELECT *
        INTO contract_rec
        FROM pgl_validate.pglogical_table_contract(
            table_name,
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
        sync_status := contract_rec.sync_status;
        validated_property := contract_rec.validated_property;
        exact_comparable := contract_rec.exact_comparable;
        contract_reason := contract_rec.reason;
    END IF;

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
        v_run_id, schema_name, rel_name, key_cols, cols, plan_repsets,
        repl_insert, repl_update, repl_delete, repl_truncate,
        has_row_filter, sync_status, validated_property
    );

    IF NOT exact_comparable THEN
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
            v_run_id, schema_name, rel_name, verdict, result_reason, now()
        )
        RETURNING * INTO result_row;

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

        RETURN result_row;
    END IF;

    checksum_sql := pgl_validate.plan_chunk_sql(table_name, key_cols, NULL, NULL, cols, NULL);
    EXECUTE checksum_sql INTO n_rows, lthash;

    INSERT INTO pgl_validate.table_node_result(
        run_id, schema_name, table_name, node, n_rows, lthash, set_hash
    )
    VALUES (v_run_id, schema_name, rel_name, 'local', n_rows, lthash, NULL);

    FOR peer_rec IN
        SELECT p.name, p.dsn, p.backend,
               p.connect_timeout_seconds,
               p.statement_timeout_ms,
               p.lock_timeout_ms
        FROM pgl_validate.peer p
        WHERE p.name = ANY (peer_names)
        ORDER BY p.name
    LOOP
        SELECT rc.pg_version, rc.n_rows, rc.lthash
        INTO remote_rec
        FROM pgl_validate.remote_checksum(
            peer_rec.dsn,
            checksum_sql,
            peer_rec.connect_timeout_seconds,
            peer_rec.statement_timeout_ms,
            peer_rec.lock_timeout_ms
        ) AS rc;

        participant_count := participant_count + 1;

        INSERT INTO pgl_validate.run_participant(
            run_id, node, role, backend, pg_version, dsn_ref, status
        )
        VALUES (
            v_run_id, peer_rec.name, 'participant', peer_rec.backend,
            remote_rec.pg_version, peer_rec.name, 'done'
        );

        INSERT INTO pgl_validate.table_node_result(
            run_id, schema_name, table_name, node, n_rows, lthash, set_hash
        )
        VALUES (
            v_run_id, schema_name, rel_name, peer_rec.name,
            remote_rec.n_rows, remote_rec.lthash, NULL
        );

        IF remote_rec.n_rows IS DISTINCT FROM n_rows
           OR remote_rec.lthash IS DISTINCT FROM lthash THEN
            differ_count := differ_count + 1;
        END IF;
    END LOOP;

    IF differ_count = 0 THEN
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
    ELSE
        verdict := 'differ';
        result_reason := format('%s of %s remote peer(s) differ from local', differ_count, participant_count - 1);
    END IF;

    INSERT INTO pgl_validate.table_result(
        run_id, schema_name, table_name, verdict, reason, finished_at
    )
    VALUES (
        v_run_id, schema_name, rel_name, verdict, result_reason, now()
    )
    RETURNING * INTO result_row;

    UPDATE pgl_validate.run
    SET status = 'completed',
        finished_at = now(),
        tables_matched = CASE WHEN differ_count = 0 THEN 1 ELSE 0 END,
        tables_differ = CASE WHEN differ_count = 0 THEN 0 ELSE 1 END
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
