CREATE FUNCTION pgl_validate.correlate_conflict_history(
    p_run_id bigint,
    lookback interval DEFAULT interval '24 hours',
    max_rows_per_peer int DEFAULT 1000
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    run_rec pgl_validate.run%ROWTYPE;
    peer_rec record;
    table_rec record;
    since_text text;
    affected int;
    total_affected int := 0;
BEGIN
    IF lookback IS NULL OR lookback < interval '0 seconds' THEN
        RAISE EXCEPTION 'lookback must be a non-negative interval'
            USING ERRCODE = '22023';
    END IF;

    IF max_rows_per_peer IS NULL OR max_rows_per_peer <= 0 THEN
        RAISE EXCEPTION 'max_rows_per_peer must be greater than zero'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO run_rec
    FROM pgl_validate.run r
    WHERE r.run_id = p_run_id;

    IF run_rec.run_id IS NULL THEN
        RAISE EXCEPTION 'validation run % does not exist', p_run_id
            USING ERRCODE = '22023';
    END IF;

    since_text := (run_rec.started_at - lookback)::text;

    FOR table_rec IN
        SELECT DISTINCT d.schema_name, d.table_name
        FROM pgl_validate.divergence d
        WHERE d.run_id = p_run_id
          AND d.status = 'confirmed'
        ORDER BY d.schema_name, d.table_name
    LOOP
        FOR peer_rec IN
            SELECT DISTINCT p.name, p.dsn, p.subscription_name,
                   p.connect_timeout_seconds,
                   p.statement_timeout_ms,
                   p.lock_timeout_ms
            FROM pgl_validate.divergence d
            JOIN pgl_validate.peer p ON p.name = d.node
            WHERE d.run_id = p_run_id
              AND d.schema_name = table_rec.schema_name
              AND d.table_name = table_rec.table_name
              AND d.status = 'confirmed'
              AND p.backend = 'pglogical'
              AND p.subscription_name IS NOT NULL
            ORDER BY p.name
        LOOP
            INSERT INTO pgl_validate.conflict_evidence(
                run_id, schema_name, table_name, key_bytes, node,
                conflict_id, recorded_at, subscription_name, conflict_type,
                resolution, index_name, local_tuple, local_xid, local_origin,
                local_commit_ts, remote_tuple, remote_origin, remote_commit_ts,
                remote_commit_lsn, has_before_triggers, matched_on
            )
            SELECT
                d.run_id,
                d.schema_name,
                d.table_name,
                d.key_bytes,
                d.node,
                c.conflict_id,
                c.recorded_at_text::timestamptz,
                c.subscription_name,
                c.conflict_type,
                c.resolution,
                c.index_name,
                c.local_tuple_json::jsonb,
                c.local_xid,
                c.local_origin,
                c.local_commit_ts_text::timestamptz,
                c.remote_tuple_json::jsonb,
                c.remote_origin,
                c.remote_commit_ts_text::timestamptz,
                c.remote_commit_lsn_text::pg_lsn,
                c.has_before_triggers,
                array_remove(ARRAY[
                    CASE
                        WHEN c.local_tuple_json IS NOT NULL
                         AND c.local_tuple_json::jsonb @> d.key_text::jsonb
                        THEN 'local_tuple_key'
                    END,
                    CASE
                        WHEN c.remote_tuple_json IS NOT NULL
                         AND c.remote_tuple_json::jsonb @> d.key_text::jsonb
                        THEN 'remote_tuple_key'
                    END
                ]::text[], NULL)
            FROM pgl_validate.divergence d
            JOIN pgl_validate.remote_pglogical_conflict_history(
                peer_rec.dsn,
                peer_rec.subscription_name::text,
                table_rec.schema_name,
                table_rec.table_name,
                since_text,
                max_rows_per_peer,
                peer_rec.connect_timeout_seconds,
                peer_rec.statement_timeout_ms,
                peer_rec.lock_timeout_ms
            ) AS c
              ON (c.local_tuple_json IS NOT NULL AND c.local_tuple_json::jsonb @> d.key_text::jsonb)
              OR (c.remote_tuple_json IS NOT NULL AND c.remote_tuple_json::jsonb @> d.key_text::jsonb)
            WHERE d.run_id = p_run_id
              AND d.schema_name = table_rec.schema_name
              AND d.table_name = table_rec.table_name
              AND d.node = peer_rec.name
              AND d.status = 'confirmed'
            ON CONFLICT (
                run_id, schema_name, table_name, key_bytes, node,
                source, recorded_at, conflict_id
            ) DO UPDATE
            SET subscription_name = EXCLUDED.subscription_name,
                conflict_type = EXCLUDED.conflict_type,
                resolution = EXCLUDED.resolution,
                index_name = EXCLUDED.index_name,
                local_tuple = EXCLUDED.local_tuple,
                local_xid = EXCLUDED.local_xid,
                local_origin = EXCLUDED.local_origin,
                local_commit_ts = EXCLUDED.local_commit_ts,
                remote_tuple = EXCLUDED.remote_tuple,
                remote_origin = EXCLUDED.remote_origin,
                remote_commit_ts = EXCLUDED.remote_commit_ts,
                remote_commit_lsn = EXCLUDED.remote_commit_lsn,
                has_before_triggers = EXCLUDED.has_before_triggers,
                matched_on = EXCLUDED.matched_on,
                observed_at = now();

            GET DIAGNOSTICS affected = ROW_COUNT;
            total_affected := total_affected + affected;
        END LOOP;
    END LOOP;

    RETURN total_affected;
END
$$;

CREATE FUNCTION pgl_validate._repair_statements(
    p_run_id bigint,
    p_authoritative text
)
RETURNS TABLE (
    repair_target text,
    repair_schema text,
    repair_table text,
    repair_key_bytes bytea,
    repair_action text,
    repair_statement text,
    lock_statement text,
    verify_statement text,
    repair_relid oid
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rec record;
    source_classification text;
    source_tuple_doc jsonb;
    source_row jsonb;
    key_row jsonb;
    target_node text;
    action text;
    rel_sql text;
    rel_oid regclass;
    repair_cols text[];
    update_cols text[];
    column_list text;
    select_list text;
    update_list text;
    key_predicate text;
    verification_predicate text;
    statement text;
    lock_sql text;
    verify_sql text;
BEGIN
    IF p_authoritative IS NULL OR btrim(p_authoritative) = '' THEN
        RAISE EXCEPTION 'authoritative node is required'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgl_validate.run r WHERE r.run_id = p_run_id) THEN
        RAISE EXCEPTION 'validation run % does not exist', p_run_id
            USING ERRCODE = '02000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pgl_validate.run_participant rp
        WHERE rp.run_id = p_run_id
          AND rp.node = p_authoritative
    ) THEN
        RAISE EXCEPTION 'authoritative node % is not a participant in run %', p_authoritative, p_run_id
            USING ERRCODE = '22023';
    END IF;

    FOR rec IN
        SELECT d.run_id, d.schema_name, d.table_name, d.key_text, d.key_bytes, d.classification,
               d.node, d.tuple, tp.key_cols, tp.att_list, tp.validated_property,
               tp.repl_insert, tp.repl_update, tp.repl_delete, tp.repl_truncate
        FROM pgl_validate.divergence d
        JOIN pgl_validate.table_plan tp
          ON tp.run_id = d.run_id
         AND tp.schema_name = d.schema_name
         AND tp.table_name = d.table_name
        WHERE d.run_id = p_run_id
          AND d.status = 'confirmed'
          AND tp.validated_property IN ('full','superset','keys_only')
        ORDER BY d.schema_name, d.table_name, d.key_text, d.node
    LOOP
        rel_sql := format('%I.%I', rec.schema_name, rec.table_name);
        rel_oid := rel_sql::regclass;

        SELECT array_agg(col_name ORDER BY first_ord)
        INTO repair_cols
        FROM (
            SELECT col_name, min(ord) AS first_ord
            FROM (
                SELECT col_name, ord
                FROM unnest(rec.key_cols) WITH ORDINALITY AS k(col_name, ord)
                UNION ALL
                SELECT col_name, ord + 10000
                FROM unnest(rec.att_list) WITH ORDINALITY AS a(col_name, ord)
            ) requested
            GROUP BY col_name
        ) dedup
        JOIN pg_attribute attr
          ON attr.attrelid = rel_oid
         AND attr.attname = dedup.col_name
         AND attr.attnum > 0
         AND NOT attr.attisdropped
         AND attr.attgenerated = '';

        SELECT array_agg(col_name ORDER BY ordinality)
        INTO update_cols
        FROM unnest(repair_cols) WITH ORDINALITY AS c(col_name, ordinality)
        WHERE NOT (col_name = ANY (rec.key_cols));

        SELECT string_agg(format('%I', col_name), ', ' ORDER BY ordinality),
               string_agg(format('r.%I', col_name), ', ' ORDER BY ordinality)
        INTO column_list, select_list
        FROM unnest(repair_cols) WITH ORDINALITY AS c(col_name, ordinality);

        SELECT string_agg(format('%I = r.%I', col_name, col_name), ', ' ORDER BY ordinality)
        INTO update_list
        FROM unnest(update_cols) WITH ORDINALITY AS c(col_name, ordinality);

        SELECT string_agg(format('t.%I IS NOT DISTINCT FROM r.%I', col_name, col_name), ' AND ' ORDER BY ordinality)
        INTO key_predicate
        FROM unnest(rec.key_cols) WITH ORDINALITY AS c(col_name, ordinality);

        SELECT string_agg(format('t.%I IS NOT DISTINCT FROM r.%I', col_name, col_name), ' AND ' ORDER BY ordinality)
        INTO verification_predicate
        FROM unnest(repair_cols) WITH ORDINALITY AS c(col_name, ordinality);

        IF repair_cols IS NULL
           OR rec.key_cols IS NULL
           OR cardinality(rec.key_cols) = 0
           OR key_predicate IS NULL
           OR verification_predicate IS NULL THEN
            RAISE EXCEPTION 'cannot generate repair for %.% without a usable key and repair column set',
                rec.schema_name, rec.table_name
                USING ERRCODE = '0A000';
        END IF;

        source_row := NULL;
        key_row := NULL;
        target_node := NULL;
        action := NULL;

        IF p_authoritative = 'local' THEN
            target_node := rec.node;
            IF rec.classification = 'missing_on' THEN
                action := 'insert';
                source_row := rec.tuple->'local';
                key_row := source_row;
            ELSIF rec.classification = 'differs' THEN
                action := 'update';
                source_row := rec.tuple->'local';
                key_row := source_row;
            ELSIF rec.classification = 'extra_on' THEN
                action := 'delete';
                key_row := rec.tuple->'peer';
            END IF;
        ELSIF rec.node = p_authoritative THEN
            target_node := 'local';
            IF rec.classification = 'missing_on' THEN
                action := 'delete';
                key_row := rec.tuple->'local';
            ELSIF rec.classification = 'extra_on' THEN
                action := 'insert';
                source_row := rec.tuple->'peer';
                key_row := source_row;
            ELSIF rec.classification = 'differs' THEN
                action := 'update';
                source_row := rec.tuple->'peer';
                key_row := source_row;
            END IF;
        ELSE
            SELECT d.classification, d.tuple
            INTO source_classification, source_tuple_doc
            FROM pgl_validate.divergence d
            WHERE d.run_id = rec.run_id
              AND d.schema_name = rec.schema_name
              AND d.table_name = rec.table_name
              AND d.key_bytes = rec.key_bytes
              AND d.node = p_authoritative
              AND d.status = 'confirmed';

            target_node := rec.node;
            IF source_tuple_doc IS NULL THEN
                source_row := rec.tuple->'local';
            ELSIF source_classification = 'missing_on' THEN
                source_row := NULL;
            ELSE
                source_row := source_tuple_doc->'peer';
            END IF;

            IF source_row IS NOT NULL AND jsonb_typeof(source_row) = 'object' THEN
                action := CASE WHEN rec.classification = 'missing_on' THEN 'insert' ELSE 'update' END;
                key_row := source_row;
            ELSE
                action := 'delete';
                key_row := rec.tuple->'peer';
            END IF;
        END IF;

        IF action IN ('insert','update')
           AND source_row IS NOT NULL
           AND jsonb_typeof(source_row) = 'object'
           AND source_row ? '_pgl_validate_tuple_truncated' THEN
            RAISE EXCEPTION 'confirmed divergence %.% key % has capped authoritative tuple data; rerun validation with larger max_reported_tuple_bytes before repair',
                rec.schema_name, rec.table_name, encode(rec.key_bytes, 'hex')
                USING ERRCODE = '22023';
        END IF;
        IF action = 'delete'
           AND key_row IS NOT NULL
           AND jsonb_typeof(key_row) = 'object'
           AND key_row ? '_pgl_validate_tuple_truncated' THEN
            key_row := rec.key_text::jsonb;
        END IF;

        IF action IN ('insert','update')
           AND (source_row IS NULL OR jsonb_typeof(source_row) <> 'object') THEN
            RAISE EXCEPTION 'confirmed divergence %.% key % lacks authoritative tuple data for node %',
                rec.schema_name, rec.table_name, encode(rec.key_bytes, 'hex'), p_authoritative
                USING ERRCODE = '22023';
        END IF;
        IF action = 'delete'
           AND (key_row IS NULL OR jsonb_typeof(key_row) <> 'object') THEN
            RAISE EXCEPTION 'confirmed divergence %.% key % lacks key tuple data for delete repair',
                rec.schema_name, rec.table_name, encode(rec.key_bytes, 'hex')
                USING ERRCODE = '22023';
        END IF;

        IF action = 'insert' AND NOT COALESCE(rec.repl_insert, false) THEN
            CONTINUE;
        END IF;
        IF action = 'update' AND NOT COALESCE(rec.repl_update, false) THEN
            CONTINUE;
        END IF;
        IF action = 'delete'
           AND NOT (COALESCE(rec.repl_delete, false) AND COALESCE(rec.repl_truncate, false)) THEN
            CONTINUE;
        END IF;

        IF action = 'insert' THEN
            statement := format(
                '/* target: %s */ INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, %L::jsonb) AS r;',
                quote_literal(target_node),
                rel_sql,
                column_list,
                select_list,
                rel_sql,
                source_row::text
            );
        ELSIF action = 'update' THEN
            IF update_cols IS NULL OR cardinality(update_cols) = 0 THEN
                CONTINUE;
            END IF;
            statement := format(
                '/* target: %s */ UPDATE %s AS t SET %s FROM jsonb_populate_record(NULL::%s, %L::jsonb) AS r WHERE %s;',
                quote_literal(target_node),
                rel_sql,
                update_list,
                rel_sql,
                source_row::text,
                key_predicate
            );
        ELSIF action = 'delete' THEN
            statement := format(
                '/* target: %s */ DELETE FROM %s AS t USING jsonb_populate_record(NULL::%s, %L::jsonb) AS r WHERE %s;',
                quote_literal(target_node),
                rel_sql,
                rel_sql,
                key_row::text,
                key_predicate
            );
        ELSE
            CONTINUE;
        END IF;

        lock_sql := format(
            '/* target: %s */ SELECT 1 FROM %s AS t, jsonb_populate_record(NULL::%s, %L::jsonb) AS r WHERE %s FOR UPDATE OF t;',
            quote_literal(target_node),
            rel_sql,
            rel_sql,
            key_row::text,
            key_predicate
        );

        IF action IN ('insert','update') THEN
            verify_sql := format(
                '/* target: %s */ DO $pgl_validate_verify$ BEGIN IF NOT EXISTS (SELECT 1 FROM %s AS t, jsonb_populate_record(NULL::%s, %L::jsonb) AS r WHERE %s) THEN RAISE EXCEPTION %L; END IF; END $pgl_validate_verify$;',
                quote_literal(target_node),
                rel_sql,
                rel_sql,
                source_row::text,
                verification_predicate,
                format('repair verification failed for %s key %s on %s', rel_sql, encode(rec.key_bytes, 'hex'), target_node)
            );
        ELSE
            verify_sql := format(
                '/* target: %s */ DO $pgl_validate_verify$ BEGIN IF EXISTS (SELECT 1 FROM %s AS t, jsonb_populate_record(NULL::%s, %L::jsonb) AS r WHERE %s) THEN RAISE EXCEPTION %L; END IF; END $pgl_validate_verify$;',
                quote_literal(target_node),
                rel_sql,
                rel_sql,
                key_row::text,
                key_predicate,
                format('repair verification failed for %s key %s on %s', rel_sql, encode(rec.key_bytes, 'hex'), target_node)
            );
        END IF;

        RETURN QUERY
        SELECT target_node,
               rec.schema_name,
               rec.table_name,
               rec.key_bytes,
               action,
               statement,
               lock_sql,
               verify_sql,
               rel_oid::oid;
    END LOOP;

    FOR rec IN
        SELECT sr.*
        FROM pgl_validate.sequence_result sr
        WHERE sr.run_id = p_run_id
          AND NOT sr.within_contract
          AND sr.provider_last_value IS NOT NULL
          AND p_authoritative IN ('local', sr.provider_node)
        ORDER BY sr.schema_name, sr.seq_name, sr.subscriber_node
    LOOP
        RETURN QUERY
        SELECT rec.subscriber_node,
               rec.schema_name,
               rec.seq_name,
               convert_to(format('%I.%I', rec.schema_name, rec.seq_name), 'UTF8'),
               'setval',
               format(
                   '/* target: %s */ DO $pgl_validate_repair$ BEGIN PERFORM setval(%L::regclass, %s, true); END $pgl_validate_repair$;',
                   quote_literal(rec.subscriber_node),
                   format('%I.%I', rec.schema_name, rec.seq_name),
                   rec.provider_last_value
               ),
               NULL::text,
               NULL::text,
               NULL::oid;
    END LOOP;

    RETURN;
END
$$;

CREATE FUNCTION pgl_validate.generate_repair(
    run_id bigint,
    authoritative text
)
RETURNS SETOF text
LANGUAGE sql
STABLE
AS $$
    SELECT rs.repair_statement
    FROM pgl_validate._repair_statements($1, $2) AS rs
    ORDER BY rs.repair_target,
             rs.repair_schema,
             rs.repair_table,
             rs.repair_key_bytes,
             rs.repair_action,
             rs.repair_statement
$$;

CREATE FUNCTION pgl_validate.apply_repair(
    run_id bigint,
    authoritative text,
    target text,
    confirm text,
    propagation text DEFAULT 'local_only',
    acknowledge_conflict_policy boolean DEFAULT false
)
RETURNS pgl_validate.repair_run
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    target_peer pgl_validate.peer%ROWTYPE;
    repair pgl_validate.repair_run%ROWTYPE;
    origin_name text;
    lock_batch text;
    row_batch text;
    verify_batch text;
    remote_batch text;
    session_role_check text := 'DO $pgl_validate_role$ BEGIN IF current_setting(''session_replication_role'') <> ''origin'' THEN RAISE EXCEPTION ''pgl_validate repair requires session_replication_role = origin'' USING ERRCODE = ''55000''; END IF; END $pgl_validate_role$;';
    sequence_stmt record;
    statement_count int;
    repair_error text;
    revalidation_options jsonb;
    revalidation_peers text[];
    revalidation_failed boolean := false;
    revalidation_note text;
    revalidation_table pgl_validate.table_result%ROWTYPE;
    revalidation_sequence_match boolean;
    repaired_object record;
    repair_target_provider_node text;
    forwarding_subscription_refs text[];
    local_forwarding_subscription record;
    peer_rec record;
    remote_forwarding_subscription record;
BEGIN
    IF authoritative IS NULL OR btrim(authoritative) = '' THEN
        RAISE EXCEPTION 'authoritative node is required'
            USING ERRCODE = '22023';
    END IF;

    IF target IS NULL OR btrim(target) = '' THEN
        RAISE EXCEPTION 'target node is required'
            USING ERRCODE = '22023';
    END IF;

    IF confirm IS DISTINCT FROM target THEN
        RAISE EXCEPTION 'repair target confirmation must exactly equal target node %', target
            USING ERRCODE = '22023';
    END IF;

    IF propagation NOT IN ('local_only','replicate') THEN
        RAISE EXCEPTION 'propagation must be local_only or replicate'
            USING ERRCODE = '22023';
    END IF;

    IF propagation = 'replicate' AND NOT acknowledge_conflict_policy THEN
        RAISE EXCEPTION 'replicate repair requires acknowledge_conflict_policy = true'
            USING ERRCODE = '22023';
    END IF;

    IF authoritative = target THEN
        RAISE EXCEPTION 'authoritative node and repair target must differ'
            USING ERRCODE = '22023';
    END IF;

    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION 'pgl_validate repair requires session_replication_role = origin'
            USING ERRCODE = '55000';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgl_validate.run r WHERE r.run_id = apply_repair.run_id) THEN
        RAISE EXCEPTION 'validation run % does not exist', apply_repair.run_id
            USING ERRCODE = '02000';
    END IF;

    SELECT COALESCE(r.options, '{}'::jsonb) - '_pgl_validate_parent_run_id'
    INTO revalidation_options
    FROM pgl_validate.run r
    WHERE r.run_id = apply_repair.run_id;

    repair_target_provider_node := CASE
        WHEN target = 'local' THEN COALESCE(NULLIF(revalidation_options->>'provider_node', ''), 'local')
        ELSE target
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM pgl_validate.run_participant rp
        WHERE rp.run_id = apply_repair.run_id
          AND rp.node = authoritative
    ) THEN
        RAISE EXCEPTION 'authoritative node % is not a participant in run %', authoritative, apply_repair.run_id
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pgl_validate.run_participant rp
        WHERE rp.run_id = apply_repair.run_id
          AND rp.node = target
    ) THEN
        RAISE EXCEPTION 'target node % is not a participant in run %', target, apply_repair.run_id
            USING ERRCODE = '22023';
    END IF;

    IF target <> 'local' THEN
        SELECT *
        INTO target_peer
        FROM pgl_validate.peer p
        WHERE p.name = target;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'target node % is not registered in pgl_validate.peer', target
                USING ERRCODE = '22023';
        END IF;
    END IF;

    origin_name := CASE WHEN propagation = 'local_only' THEN 'pgl_validate_repair' ELSE NULL END;
    INSERT INTO pgl_validate.repair_run(run_id, authoritative, target, propagation, origin_name)
    VALUES (apply_repair.run_id, authoritative, target, propagation, origin_name)
    RETURNING * INTO repair;

    BEGIN
        IF current_setting('session_replication_role') <> 'origin' THEN
            RAISE EXCEPTION 'pgl_validate repair requires session_replication_role = origin'
                USING ERRCODE = '55000';
        END IF;

        CREATE TEMP TABLE IF NOT EXISTS pgl_validate_apply_statement (
            ord int NOT NULL,
            target_node text NOT NULL,
            schema_name text NOT NULL,
            table_name text NOT NULL,
            key_bytes bytea NOT NULL,
            statement text NOT NULL,
            lock_statement text,
            verify_statement text,
            action text NOT NULL CHECK (action IN ('insert','update','delete','setval')),
            relid oid,
            fk_rank int NOT NULL DEFAULT 0
        ) ON COMMIT DROP;
        TRUNCATE pgl_validate_apply_statement;

        INSERT INTO pgl_validate_apply_statement(
            ord, target_node, schema_name, table_name, key_bytes, statement,
            lock_statement, verify_statement, action, relid
        )
        SELECT row_number() OVER (
                   ORDER BY rs.repair_schema,
                            rs.repair_table,
                            rs.repair_key_bytes,
                            rs.repair_action,
                            rs.repair_statement
               )::int,
               rs.repair_target,
               rs.repair_schema,
               rs.repair_table,
               rs.repair_key_bytes,
               rs.repair_statement,
               rs.lock_statement,
               rs.verify_statement,
               rs.repair_action,
               rs.repair_relid
        FROM pgl_validate._repair_statements(apply_repair.run_id, authoritative) AS rs
        WHERE rs.repair_target = target;

        WITH RECURSIVE involved AS (
            SELECT DISTINCT relid
            FROM pgl_validate_apply_statement
            WHERE relid IS NOT NULL
        ),
        fk_edges AS (
            SELECT c.conrelid AS child_relid,
                   c.confrelid AS parent_relid
            FROM pg_constraint c
            JOIN involved child ON child.relid = c.conrelid
            JOIN involved parent ON parent.relid = c.confrelid
            WHERE c.contype = 'f'
        ),
        ranked(relid, depth) AS (
            SELECT relid, 0
            FROM involved
            UNION ALL
            SELECT e.child_relid, ranked.depth + 1
            FROM ranked
            JOIN fk_edges e ON e.parent_relid = ranked.relid
            WHERE ranked.depth < 64
        )
        UPDATE pgl_validate_apply_statement s
        SET fk_rank = COALESCE((
            SELECT max(r.depth)
            FROM ranked r
            WHERE r.relid = s.relid
        ), 0);

        SELECT count(*) INTO statement_count FROM pgl_validate_apply_statement;
        IF statement_count = 0 THEN
            UPDATE pgl_validate.repair_run
            SET status = 'applied',
                finished_at = clock_timestamp()
            WHERE repair_id = repair.repair_id
            RETURNING * INTO repair;
            RETURN repair;
        END IF;

        IF target = 'local' AND propagation = 'local_only' THEN
            SELECT *
            INTO target_peer
            FROM pgl_validate.peer p
            WHERE p.name = target;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'local_only repair target local requires pgl_validate.peer row named local so the origin-aware repair transaction can run over libpq'
                    USING ERRCODE = '55000';
            END IF;
        END IF;

        IF propagation = 'local_only' THEN
            forwarding_subscription_refs := ARRAY[]::text[];

            IF to_regclass('pglogical.subscription') IS NOT NULL
               AND to_regclass('pglogical.node') IS NOT NULL THEN
                FOR local_forwarding_subscription IN
                    SELECT s.sub_name::text AS subscription_name
                    FROM pglogical.subscription AS s
                    JOIN pglogical.node AS provider
                      ON provider.node_id = s.sub_origin
                    WHERE s.sub_enabled
                      AND provider.node_name::text = repair_target_provider_node
                      AND 'all' = ANY (s.sub_forward_origins)
                    ORDER BY s.sub_name::text
                LOOP
                    forwarding_subscription_refs := array_append(
                        forwarding_subscription_refs,
                        format('local:%s', local_forwarding_subscription.subscription_name)
                    );
                END LOOP;
            END IF;

            FOR peer_rec IN
                SELECT p.name, p.dsn, p.connect_timeout_seconds,
                       p.statement_timeout_ms, p.lock_timeout_ms
                FROM pgl_validate.peer p
                WHERE p.backend = 'pglogical'
                ORDER BY p.name
            LOOP
                FOR remote_forwarding_subscription IN
                    SELECT r.subscription_name
                    FROM pgl_validate.remote_pglogical_forwarding_subscriptions(
                        peer_rec.dsn,
                        repair_target_provider_node,
                        peer_rec.connect_timeout_seconds,
                        peer_rec.statement_timeout_ms,
                        peer_rec.lock_timeout_ms
                    ) AS r
                    ORDER BY r.subscription_name
                LOOP
                    forwarding_subscription_refs := array_append(
                        forwarding_subscription_refs,
                        format('%s:%s', peer_rec.name, remote_forwarding_subscription.subscription_name)
                    );
                END LOOP;
            END LOOP;

            IF cardinality(forwarding_subscription_refs) > 0 THEN
                RAISE EXCEPTION 'local_only repair target % would be forwarded by pglogical subscription(s) with forward_origins={all}: %. Change topology outside the repair run or use propagation=replicate with acknowledge_conflict_policy=true',
                    target,
                    array_to_string(forwarding_subscription_refs, ', ')
                    USING ERRCODE = '55000';
            END IF;
        END IF;

        SELECT string_agg(
                   lock_statement,
                   E'\n'
                   ORDER BY CASE action
                                WHEN 'delete' THEN 0
                                WHEN 'update' THEN 1
                                WHEN 'insert' THEN 2
                                ELSE 3
                            END,
                            CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                            schema_name,
                            table_name,
                            key_bytes,
                            ord
               )
        INTO lock_batch
        FROM pgl_validate_apply_statement
        WHERE action IN ('insert','update','delete')
          AND lock_statement IS NOT NULL;

        SELECT string_agg(
                   statement,
                   E'\n'
                   ORDER BY CASE action
                                WHEN 'delete' THEN 0
                                WHEN 'update' THEN 1
                                WHEN 'insert' THEN 2
                                ELSE 3
                            END,
                            CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                            schema_name,
                            table_name,
                            key_bytes,
                            ord
               )
        INTO row_batch
        FROM pgl_validate_apply_statement
        WHERE action IN ('insert','update','delete');

        SELECT string_agg(
                   verify_statement,
                   E'\n'
                   ORDER BY CASE action
                                WHEN 'delete' THEN 0
                                WHEN 'update' THEN 1
                                WHEN 'insert' THEN 2
                                ELSE 3
                            END,
                            CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                            schema_name,
                            table_name,
                            key_bytes,
                            ord
               )
        INTO verify_batch
        FROM pgl_validate_apply_statement
        WHERE action IN ('insert','update','delete')
          AND verify_statement IS NOT NULL;

        IF row_batch IS NOT NULL THEN
            IF target = 'local' AND propagation <> 'local_only' THEN
                FOR sequence_stmt IN
                    SELECT lock_statement
                    FROM pgl_validate_apply_statement
                    WHERE action IN ('insert','update','delete')
                      AND lock_statement IS NOT NULL
                    ORDER BY CASE action
                                 WHEN 'delete' THEN 0
                                 WHEN 'update' THEN 1
                                 WHEN 'insert' THEN 2
                                 ELSE 3
                             END,
                             CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                             schema_name,
                             table_name,
                             key_bytes,
                             ord
                LOOP
                    EXECUTE sequence_stmt.lock_statement;
                END LOOP;

                FOR sequence_stmt IN
                    SELECT statement
                    FROM pgl_validate_apply_statement
                    WHERE action IN ('insert','update','delete')
                    ORDER BY CASE action
                                 WHEN 'delete' THEN 0
                                 WHEN 'update' THEN 1
                                 WHEN 'insert' THEN 2
                                 ELSE 3
                             END,
                             CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                             schema_name,
                             table_name,
                             key_bytes,
                             ord
                LOOP
                    EXECUTE sequence_stmt.statement;
                END LOOP;

                FOR sequence_stmt IN
                    SELECT verify_statement
                    FROM pgl_validate_apply_statement
                    WHERE action IN ('insert','update','delete')
                      AND verify_statement IS NOT NULL
                    ORDER BY CASE action
                                 WHEN 'delete' THEN 0
                                 WHEN 'update' THEN 1
                                 WHEN 'insert' THEN 2
                                 ELSE 3
                             END,
                             CASE WHEN action = 'delete' THEN -fk_rank ELSE fk_rank END,
                             schema_name,
                             table_name,
                             key_bytes,
                             ord
                LOOP
                    EXECUTE sequence_stmt.verify_statement;
                END LOOP;
            ELSE
                IF propagation = 'local_only' THEN
                    remote_batch := session_role_check ||
                        E'\n' || format(
                        'DO $pgl_validate_origin$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_replication_origin WHERE roname = %L) THEN PERFORM pg_replication_origin_create(%L); END IF; END $pgl_validate_origin$;' ||
                        E'\nDO $pgl_validate_origin$ BEGIN PERFORM pg_replication_origin_session_setup(%L); END $pgl_validate_origin$;' ||
                        E'\nBEGIN;' ||
                        E'\n%s' ||
                        E'\n%s' ||
                        E'\n%s' ||
                        E'\nCOMMIT;' ||
                        E'\nDO $pgl_validate_origin$ BEGIN PERFORM pg_replication_origin_session_reset(); END $pgl_validate_origin$;',
                        origin_name,
                        origin_name,
                        origin_name,
                        COALESCE(lock_batch, ''),
                        row_batch,
                        COALESCE(verify_batch, '')
                    );
                ELSE
                    remote_batch := session_role_check ||
                                    E'\nBEGIN;' ||
                                    E'\n' || COALESCE(lock_batch, '') ||
                                    E'\n' || row_batch ||
                                    E'\n' || COALESCE(verify_batch, '') ||
                                    E'\nCOMMIT;';
                END IF;

                PERFORM pgl_validate.remote_execute(
                    target_peer.dsn,
                    remote_batch,
                    target_peer.connect_timeout_seconds,
                    target_peer.statement_timeout_ms,
                    target_peer.lock_timeout_ms
                );
            END IF;
        END IF;

        FOR sequence_stmt IN
            SELECT statement
            FROM pgl_validate_apply_statement
            WHERE action = 'setval'
            ORDER BY ord
        LOOP
            IF target = 'local' AND propagation <> 'local_only' THEN
                EXECUTE sequence_stmt.statement;
            ELSE
                IF propagation = 'local_only' THEN
                    remote_batch := session_role_check ||
                        E'\n' || format(
                        'DO $pgl_validate_origin$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_replication_origin WHERE roname = %L) THEN PERFORM pg_replication_origin_create(%L); END IF; END $pgl_validate_origin$;' ||
                        E'\nDO $pgl_validate_origin$ BEGIN PERFORM pg_replication_origin_session_setup(%L); END $pgl_validate_origin$;' ||
                        E'\n%s' ||
                        E'\nDO $pgl_validate_origin$ BEGIN PERFORM pg_replication_origin_session_reset(); END $pgl_validate_origin$;',
                        origin_name,
                        origin_name,
                        origin_name,
                        sequence_stmt.statement
                    );
                ELSE
                    remote_batch := sequence_stmt.statement;
                END IF;

                PERFORM pgl_validate.remote_execute(
                    target_peer.dsn,
                    remote_batch,
                    target_peer.connect_timeout_seconds,
                    target_peer.statement_timeout_ms,
                    target_peer.lock_timeout_ms
                );
            END IF;
        END LOOP;

        INSERT INTO pgl_validate.repair_result(
            repair_id, schema_name, table_name, key_bytes, action, statement, post_verdict
        )
        SELECT repair.repair_id,
               s.schema_name,
               s.table_name,
               s.key_bytes,
               s.action,
               s.statement,
               CASE WHEN s.action = 'setval' THEN 'indeterminate' ELSE 'match' END
        FROM pgl_validate_apply_statement s
        ON CONFLICT DO NOTHING;

        IF target <> 'local' THEN
            revalidation_peers := ARRAY[target];
        ELSIF authoritative <> 'local' THEN
            revalidation_peers := ARRAY[authoritative];
        ELSE
            revalidation_peers := ARRAY[]::text[];
        END IF;

        IF cardinality(revalidation_peers) > 0 THEN
            FOR repaired_object IN
                SELECT DISTINCT schema_name, table_name
                FROM pgl_validate_apply_statement
                WHERE action IN ('insert','update','delete')
                ORDER BY schema_name, table_name
            LOOP
                BEGIN
                    SELECT *
                    INTO revalidation_table
                    FROM pgl_validate.compare_table(
                        format('%I.%I', repaired_object.schema_name, repaired_object.table_name)::regclass,
                        revalidation_peers,
                        revalidation_options
                    );

                    IF revalidation_table.verdict = 'match' THEN
                        UPDATE pgl_validate.repair_result rr
                        SET post_verdict = 'match'
                        WHERE rr.repair_id = repair.repair_id
                          AND rr.schema_name = repaired_object.schema_name
                          AND rr.table_name = repaired_object.table_name
                          AND rr.action IN ('insert','update','delete');
                    ELSE
                        revalidation_failed := true;
                        revalidation_note := concat_ws(
                            '; ',
                            revalidation_note,
                            format(
                                'post-repair table revalidation %.% returned %s',
                                repaired_object.schema_name,
                                repaired_object.table_name,
                                revalidation_table.verdict
                            )
                        );
                        UPDATE pgl_validate.repair_result rr
                        SET post_verdict = 'still_differs'
                        WHERE rr.repair_id = repair.repair_id
                          AND rr.schema_name = repaired_object.schema_name
                          AND rr.table_name = repaired_object.table_name
                          AND rr.action IN ('insert','update','delete');
                    END IF;
                EXCEPTION WHEN others THEN
                    revalidation_failed := true;
                    revalidation_note := concat_ws(
                        '; ',
                        revalidation_note,
                        format(
                            'post-repair table revalidation %.% failed: %s',
                            repaired_object.schema_name,
                            repaired_object.table_name,
                            SQLERRM
                        )
                    );
                    UPDATE pgl_validate.repair_result rr
                    SET post_verdict = 'still_differs'
                    WHERE rr.repair_id = repair.repair_id
                      AND rr.schema_name = repaired_object.schema_name
                      AND rr.table_name = repaired_object.table_name
                      AND rr.action IN ('insert','update','delete');
                END;
            END LOOP;

            FOR repaired_object IN
                SELECT DISTINCT schema_name, table_name
                FROM pgl_validate_apply_statement
                WHERE action = 'setval'
                ORDER BY schema_name, table_name
            LOOP
                BEGIN
                    SELECT bool_and(sr.verdict = 'match' AND sr.within_contract)
                    INTO revalidation_sequence_match
                    FROM pgl_validate.compare_sequence(
                        format('%I.%I', repaired_object.schema_name, repaired_object.table_name)::regclass,
                        revalidation_peers,
                        revalidation_options
                    ) AS sr;

                    IF COALESCE(revalidation_sequence_match, false) THEN
                        UPDATE pgl_validate.repair_result rr
                        SET post_verdict = 'match'
                        WHERE rr.repair_id = repair.repair_id
                          AND rr.schema_name = repaired_object.schema_name
                          AND rr.table_name = repaired_object.table_name
                          AND rr.action = 'setval';
                    ELSE
                        revalidation_failed := true;
                        revalidation_note := concat_ws(
                            '; ',
                            revalidation_note,
                            format(
                                'post-repair sequence revalidation %.% did not match',
                                repaired_object.schema_name,
                                repaired_object.table_name
                            )
                        );
                        UPDATE pgl_validate.repair_result rr
                        SET post_verdict = 'still_differs'
                        WHERE rr.repair_id = repair.repair_id
                          AND rr.schema_name = repaired_object.schema_name
                          AND rr.table_name = repaired_object.table_name
                          AND rr.action = 'setval';
                    END IF;
                EXCEPTION WHEN others THEN
                    revalidation_failed := true;
                    revalidation_note := concat_ws(
                        '; ',
                        revalidation_note,
                        format(
                            'post-repair sequence revalidation %.% failed: %s',
                            repaired_object.schema_name,
                            repaired_object.table_name,
                            SQLERRM
                        )
                    );
                    UPDATE pgl_validate.repair_result rr
                    SET post_verdict = 'still_differs'
                    WHERE rr.repair_id = repair.repair_id
                      AND rr.schema_name = repaired_object.schema_name
                      AND rr.table_name = repaired_object.table_name
                      AND rr.action = 'setval';
                END;
            END LOOP;
        END IF;

        UPDATE pgl_validate.repair_run
        SET status = CASE WHEN revalidation_failed THEN 'applied' ELSE 'revalidated' END,
            finished_at = clock_timestamp(),
            error = revalidation_note
        WHERE repair_id = repair.repair_id
        RETURNING * INTO repair;

        RETURN repair;
    EXCEPTION WHEN others THEN
        GET STACKED DIAGNOSTICS repair_error = MESSAGE_TEXT;
        UPDATE pgl_validate.repair_run
        SET status = 'failed',
            finished_at = clock_timestamp(),
            error = repair_error
        WHERE repair_id = repair.repair_id
        RETURNING * INTO repair;
        RETURN repair;
    END;
END
$$;

