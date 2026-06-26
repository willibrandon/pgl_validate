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
        WHEN type_oid = 'json'::regtype::oid
         AND COALESCE(NULLIF(current_setting('pgl_validate.json_normalize', true), '')::boolean, false) THEN 3
        WHEN type_oid IN ('json'::regtype::oid, 'numeric'::regtype::oid) THEN 2
        WHEN t.typsend = 0 THEN 2
        ELSE 1
    END
    FROM pg_type t
    WHERE t.oid = type_oid
$$;

-- Resolve the comparison key used for row-level localization. Prefer the
-- relation's replica identity index, then its primary key, then a simple
-- non-partial unique key whose NULL semantics make duplicate keys impossible.
CREATE FUNCTION pgl_validate.comparison_key_cols(relation regclass)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    WITH candidates AS (
        SELECT i.*,
               CASE
                   WHEN i.indisreplident THEN 1
                   WHEN i.indisprimary THEN 2
                   ELSE 3
               END AS priority
        FROM pg_index i
        WHERE i.indrelid = $1
          AND i.indisvalid
          AND i.indisready
          AND i.indpred IS NULL
          AND i.indexprs IS NULL
          AND (
              i.indisreplident
              OR i.indisprimary
              OR (
                  i.indisunique
                  AND i.indimmediate
                  AND (
                      i.indnullsnotdistinct
                      OR NOT EXISTS (
                          SELECT 1
                          FROM unnest(i.indkey) WITH ORDINALITY AS key(attnum, ordinality)
                          JOIN pg_attribute a
                            ON a.attrelid = i.indrelid
                           AND a.attnum = key.attnum
                          WHERE key.ordinality <= i.indnkeyatts
                            AND NOT a.attnotnull
                      )
                  )
              )
          )
          AND NOT EXISTS (
              SELECT 1
              FROM unnest(i.indkey) WITH ORDINALITY AS key(attnum, ordinality)
              LEFT JOIN pg_attribute a
                ON a.attrelid = i.indrelid
               AND a.attnum = key.attnum
              WHERE key.ordinality <= i.indnkeyatts
                AND (key.attnum <= 0 OR a.attnum IS NULL OR a.attisdropped)
          )
    ),
    chosen AS (
        SELECT *
        FROM candidates
        ORDER BY priority, indexrelid
        LIMIT 1
    )
    SELECT array_agg(a.attname ORDER BY key.ordinality)
    FROM chosen i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS key(attnum, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = i.indrelid
     AND a.attnum = key.attnum
    WHERE key.ordinality <= i.indnkeyatts
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
    row_filter_sql text,
    row_filter_exact boolean,
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
    filter_rec record;
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

    key_cols := pgl_validate.comparison_key_cols(relation);

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
        row_filter_sql := NULL;
        row_filter_exact := true;
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

    SELECT
        COALESCE(bool_or(rst.set_row_filter IS NULL), false) AS has_unfiltered_membership,
        count(*) FILTER (WHERE rst.set_row_filter IS NOT NULL) AS filtered_memberships,
        string_agg(
            format('(%s)', pg_get_expr(rst.set_row_filter, rst.set_reloid)),
            ' OR '
            ORDER BY rs.set_name::text
        ) FILTER (WHERE rst.set_row_filter IS NOT NULL) AS predicate,
        bool_and(
            pgl_validate.row_filter_tree_is_immutable(rst.set_row_filter::text)
            AND pg_get_expr(rst.set_row_filter, rst.set_reloid) !~*
                '(^|[^[:alnum:]_])(current_user|session_user|current_role|current_setting|set_config|current_schema|current_schemas)([^[:alnum:]_]|$)'
        ) FILTER (WHERE rst.set_row_filter IS NOT NULL) AS exact
    INTO filter_rec
    FROM pglogical.replication_set_table rst
    JOIN pglogical.replication_set rs ON rs.set_id = rst.set_id
    WHERE rst.set_reloid = relation
      AND rs.set_name::text = ANY (repsets);

    IF COALESCE(filter_rec.has_unfiltered_membership, false)
       OR COALESCE(filter_rec.filtered_memberships, 0) = 0 THEN
        has_row_filter := false;
        row_filter_sql := NULL;
        row_filter_exact := true;
    ELSE
        has_row_filter := true;
        row_filter_sql := filter_rec.predicate;
        row_filter_exact := COALESCE(filter_rec.exact, false);
    END IF;

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
    ELSIF has_row_filter AND repl_update AND row_filter_exact THEN
        validated_property := 'filtered_intersection';
        exact_comparable := true;
        reason := 'pglogical row filter is immutable/context-free; validating content intersection with advisory presence differences';
    ELSIF has_row_filter AND repl_update THEN
        validated_property := 'skipped';
        exact_comparable := false;
        reason := 'pglogical row filter is not immutable/context-free; exact validation would be session-sensitive';
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
        exact_comparable := true;
        reason := 'delete or truncate is not replicated, so subscriber extras are legitimate';
    ELSE
        validated_property := 'keys_only';
        exact_comparable := true;
        reason := 'updates are not replicated, so content drift is contract-permitted';
    END IF;

    RETURN NEXT;
END
$$;

-- Resolve the native logical replication contract for one relation. The
-- effective table membership, column list, and row filter come from the core
-- pg_publication_tables view so FOR ALL TABLES and FOR TABLES IN SCHEMA are
-- expanded exactly as PostgreSQL does.
CREATE FUNCTION pgl_validate.native_table_contract(
    relation regclass,
    input_publications text[] DEFAULT NULL,
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
    row_filter_sql text,
    row_filter_exact boolean,
    sync_status "char",
    validated_property text,
    exact_comparable boolean,
    reason text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    action_rec record;
    filter_rec record;
    distinct_att_lists int;
BEGIN
    SELECT n.nspname, c.relname
    INTO schema_name, table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = relation;

    key_cols := pgl_validate.comparison_key_cols(relation);

    SELECT array_agg(DISTINCT pt.pubname::text ORDER BY pt.pubname::text),
           count(DISTINCT pt.attnames::text)
    INTO repsets, distinct_att_lists
    FROM pg_publication_tables pt
    WHERE pt.schemaname = schema_name
      AND pt.tablename = table_name
      AND (
          input_publications IS NULL
          OR cardinality(input_publications) = 0
          OR pt.pubname::text = ANY (input_publications)
      );

    IF repsets IS NULL OR cardinality(repsets) = 0 THEN
        att_list := NULL;
        repl_insert := false;
        repl_update := false;
        repl_delete := false;
        repl_truncate := false;
        has_row_filter := false;
        row_filter_sql := NULL;
        row_filter_exact := true;
        sync_status := NULL;
        validated_property := 'skipped';
        exact_comparable := false;
        reason := 'table is not a member of any selected native publication';
        RETURN NEXT;
        RETURN;
    END IF;

    IF distinct_att_lists > 1 THEN
        att_list := NULL;
        repl_insert := false;
        repl_update := false;
        repl_delete := false;
        repl_truncate := false;
        has_row_filter := false;
        row_filter_sql := NULL;
        row_filter_exact := false;
        sync_status := NULL;
        validated_property := 'skipped';
        exact_comparable := false;
        reason := 'native publications have incompatible column lists for this table';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT array_agg(DISTINCT att.attname::text ORDER BY att.attname::text)
    INTO att_list
    FROM pg_publication_tables pt
    CROSS JOIN LATERAL unnest(pt.attnames) AS att(attname)
    WHERE pt.schemaname = schema_name
      AND pt.tablename = table_name
      AND pt.pubname::text = ANY (repsets);

    SELECT bool_or(p.pubinsert) AS repl_insert,
           bool_or(p.pubupdate) AS repl_update,
           bool_or(p.pubdelete) AS repl_delete,
           bool_or(p.pubtruncate) AS repl_truncate
    INTO action_rec
    FROM pg_publication p
    WHERE p.pubname::text = ANY (repsets);

    repl_insert := COALESCE(action_rec.repl_insert, false);
    repl_update := COALESCE(action_rec.repl_update, false);
    repl_delete := COALESCE(action_rec.repl_delete, false);
    repl_truncate := COALESCE(action_rec.repl_truncate, false);

    SELECT
        COALESCE(bool_or(pt.rowfilter IS NULL), false) AS has_unfiltered_membership,
        count(*) FILTER (WHERE pt.rowfilter IS NOT NULL) AS filtered_memberships,
        string_agg(
            format('(%s)', pt.rowfilter),
            ' OR '
            ORDER BY pt.pubname::text
        ) FILTER (WHERE pt.rowfilter IS NOT NULL) AS predicate,
        bool_and(
            pt.rowfilter !~*
                '(^|[^[:alnum:]_])(current_user|session_user|current_role|current_setting|set_config|current_schema|current_schemas)([^[:alnum:]_]|$)'
        ) FILTER (WHERE pt.rowfilter IS NOT NULL) AS exact
    INTO filter_rec
    FROM pg_publication_tables pt
    WHERE pt.schemaname = schema_name
      AND pt.tablename = table_name
      AND pt.pubname::text = ANY (repsets);

    IF COALESCE(filter_rec.has_unfiltered_membership, false)
       OR COALESCE(filter_rec.filtered_memberships, 0) = 0 THEN
        has_row_filter := false;
        row_filter_sql := NULL;
        row_filter_exact := true;
    ELSE
        has_row_filter := true;
        row_filter_sql := filter_rec.predicate;
        row_filter_exact := COALESCE(filter_rec.exact, false);
    END IF;

    sync_status := 'r';
    IF subscription_name IS NOT NULL THEN
        SELECT sr.srsubstate
        INTO sync_status
        FROM pg_subscription s
        JOIN pg_subscription_rel sr ON sr.srsubid = s.oid
        JOIN pg_database d ON d.oid = s.subdbid
        WHERE s.subname = subscription_name
          AND d.datname = current_database()
          AND sr.srrelid = relation;
    END IF;

    IF sync_status IS NULL THEN
        validated_property := 'skipped';
        exact_comparable := false;
        reason := format('native subscription %s has no sync state for this table', subscription_name);
    ELSIF sync_status <> 'r' THEN
        validated_property := 'skipped';
        exact_comparable := false;
        reason := format('native subscription sync status is %s, not ready', sync_status);
    ELSIF NOT repl_insert THEN
        validated_property := 'unsupported_mask';
        exact_comparable := false;
        reason := 'publish=insert is disabled, so the provider row set does not bound the subscriber';
    ELSIF has_row_filter AND NOT row_filter_exact THEN
        validated_property := 'skipped';
        exact_comparable := false;
        reason := 'native row filter is session-sensitive; exact validation would be context-dependent';
    ELSIF has_row_filter AND repl_update AND repl_delete AND repl_truncate THEN
        validated_property := 'full';
        exact_comparable := true;
        reason := 'native row filter with full action mask maintains S = P_F';
    ELSIF has_row_filter AND repl_update THEN
        validated_property := 'superset';
        exact_comparable := true;
        reason := 'native row filter is exact, but delete or truncate is not replicated, so subscriber extras are legitimate';
    ELSIF has_row_filter THEN
        validated_property := 'filtered_advisory';
        exact_comparable := false;
        reason := 'native filtered table without update replication is advisory only';
    ELSIF repl_update AND repl_delete AND repl_truncate THEN
        validated_property := 'full';
        exact_comparable := true;
        reason := 'full native publication action mask with no row filter';
    ELSIF repl_update THEN
        validated_property := 'superset';
        exact_comparable := true;
        reason := 'delete or truncate is not replicated, so subscriber extras are legitimate';
    ELSE
        validated_property := 'keys_only';
        exact_comparable := true;
        reason := 'updates are not replicated, so content drift is contract-permitted';
    END IF;

    RETURN NEXT;
END
$$;

