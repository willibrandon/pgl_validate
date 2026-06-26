-- Build the planner-visible key-range predicate shared by chunk checksums and
-- row localization. Boundary bytes are UTF-8 JSON objects whose keys are the
-- comparison-key column names; SQL generation casts each value to the actual
-- column type so the final predicate is over table columns and typed constants.
CREATE FUNCTION pgl_validate.plan_key_range_predicate(
    rel regclass,
    key_cols text[],
    lo bytea,
    hi bytea
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    lower_doc jsonb;
    upper_doc jsonb;
    key_exprs text[] := ARRAY[]::text[];
    lower_values text[] := ARRAY[]::text[];
    upper_values text[] := ARRAY[]::text[];
    predicates text[] := ARRAY[]::text[];
    attr_rec record;
    seen_keys int := 0;
    value_text text;
BEGIN
    IF lo IS NULL AND hi IS NULL THEN
        RETURN 'true';
    END IF;

    IF key_cols IS NULL OR cardinality(key_cols) = 0 THEN
        RAISE EXCEPTION 'bounded chunks require a comparison key';
    END IF;

    IF lo IS NOT NULL THEN
        lower_doc := convert_from(lo, 'UTF8')::jsonb;
        IF jsonb_typeof(lower_doc) <> 'object' THEN
            RAISE EXCEPTION 'lower chunk boundary must be a JSON object';
        END IF;
    END IF;

    IF hi IS NOT NULL THEN
        upper_doc := convert_from(hi, 'UTF8')::jsonb;
        IF jsonb_typeof(upper_doc) <> 'object' THEN
            RAISE EXCEPTION 'upper chunk boundary must be a JSON object';
        END IF;
    END IF;

    FOR attr_rec IN
        SELECT ord.ordinality,
               a.attname,
               format_type(a.atttypid, a.atttypmod) AS type_sql
        FROM unnest(key_cols) WITH ORDINALITY AS ord(col_name, ordinality)
        JOIN pg_attribute a
          ON a.attrelid = rel
         AND a.attname = ord.col_name
         AND a.attnum > 0
         AND NOT a.attisdropped
        ORDER BY ord.ordinality
    LOOP
        seen_keys := seen_keys + 1;
        key_exprs := key_exprs || format('t.%I', attr_rec.attname);

        IF lower_doc IS NOT NULL THEN
            value_text := lower_doc ->> attr_rec.attname;
            IF value_text IS NULL THEN
                RAISE EXCEPTION 'lower chunk boundary is missing non-null key column %', attr_rec.attname;
            END IF;
            lower_values := lower_values || format('%L::%s', value_text, attr_rec.type_sql);
        END IF;

        IF upper_doc IS NOT NULL THEN
            value_text := upper_doc ->> attr_rec.attname;
            IF value_text IS NULL THEN
                RAISE EXCEPTION 'upper chunk boundary is missing non-null key column %', attr_rec.attname;
            END IF;
            upper_values := upper_values || format('%L::%s', value_text, attr_rec.type_sql);
        END IF;
    END LOOP;

    IF seen_keys <> cardinality(key_cols) THEN
        RAISE EXCEPTION 'one or more key columns are not present on %', rel::text;
    END IF;

    IF lower_doc IS NOT NULL THEN
        predicates := predicates || CASE
            WHEN seen_keys = 1 THEN format('%s >= %s', key_exprs[1], lower_values[1])
            ELSE format('(%s) >= (%s)', array_to_string(key_exprs, ', '), array_to_string(lower_values, ', '))
        END;
    END IF;

    IF upper_doc IS NOT NULL THEN
        predicates := predicates || CASE
            WHEN seen_keys = 1 THEN format('%s < %s', key_exprs[1], upper_values[1])
            ELSE format('(%s) < (%s)', array_to_string(key_exprs, ', '), array_to_string(upper_values, ', '))
        END;
    END IF;

    RETURN array_to_string(predicates, ' AND ');
END
$$;

-- Plan exact key ranges from a local participant scan. The returned boundaries
-- use the same bytea JSON-object representation consumed by
-- plan_key_range_predicate(), so each range can be fed directly into
-- plan_chunk_sql() or plan_localize_sql().
CREATE FUNCTION pgl_validate.plan_key_ranges(
    rel regclass,
    key_cols text[],
    p_lo bytea DEFAULT NULL,
    p_hi bytea DEFAULT NULL,
    chunk_target_rows integer DEFAULT 50000,
    row_filter_sql text DEFAULT NULL
)
RETURNS TABLE (
    chunk_id bigint,
    lo bytea,
    hi bytea,
    n_rows bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel_sql text;
    selected_key_cols text[];
    key_json_args text;
    order_args text;
    filter_sql text;
    range_sql text;
    where_sql text;
BEGIN
    IF chunk_target_rows IS NULL OR chunk_target_rows <= 0 THEN
        RAISE EXCEPTION 'chunk_target_rows must be greater than zero';
    END IF;

    IF key_cols IS NULL OR cardinality(key_cols) = 0 THEN
        RAISE EXCEPTION 'range planning requires a comparison key';
    END IF;

    SELECT format('%I.%I', n.nspname, c.relname)
    INTO rel_sql
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = rel;

    IF rel_sql IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', rel;
    END IF;

    SELECT array_agg(a.attname ORDER BY ord.ordinality)
    INTO selected_key_cols
    FROM unnest(key_cols) WITH ORDINALITY AS ord(col_name, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = ord.col_name
     AND a.attnum > 0
     AND NOT a.attisdropped;

    IF selected_key_cols IS NULL OR cardinality(selected_key_cols) <> cardinality(key_cols) THEN
        RAISE EXCEPTION 'one or more key columns are not present on %', rel::text;
    END IF;

    SELECT
        string_agg(format('%L, t.%I', a.attname, a.attname), ', ' ORDER BY ord.ordinality),
        string_agg(format('t.%I', a.attname), ', ' ORDER BY ord.ordinality)
    INTO key_json_args, order_args
    FROM unnest(selected_key_cols) WITH ORDINALITY AS ord(col_name, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = ord.col_name
     AND a.attnum > 0
     AND NOT a.attisdropped;

    filter_sql := CASE
        WHEN row_filter_sql IS NULL OR btrim(row_filter_sql) = '' THEN 'true'
        ELSE format('(%s)', row_filter_sql)
    END;
    range_sql := pgl_validate.plan_key_range_predicate(rel, key_cols, p_lo, p_hi);
    where_sql := COALESCE(
        NULLIF(
            concat_ws(
                ' AND ',
                NULLIF(filter_sql, 'true'),
                NULLIF(range_sql, 'true')
            ),
            ''
        ),
        'true'
    );

    RETURN QUERY EXECUTE format(
        $range_sql$
        WITH ordered AS MATERIALIZED (
            SELECT
                row_number() OVER (ORDER BY %1$s) AS rn,
                convert_to(jsonb_build_object(%2$s)::text, 'UTF8') AS boundary
            FROM %3$s t
            WHERE %4$s
        ),
        starts AS (
            SELECT
                (((rn - 1) / %5$s) + 1)::bigint AS planned_chunk_id,
                min(rn) AS start_rn,
                count(*)::bigint AS planned_rows
            FROM ordered
            GROUP BY 1
        ),
        ranges AS (
            SELECT
                s.planned_chunk_id,
                s.start_rn,
                s.planned_rows,
                lead(s.start_rn) OVER (ORDER BY s.planned_chunk_id) AS next_start_rn
            FROM starts s
        )
        SELECT
            r.planned_chunk_id,
            CASE
                WHEN r.planned_chunk_id = 1 THEN $1::bytea
                ELSE (
                    SELECT o.boundary
                    FROM ordered o
                    WHERE o.rn = r.start_rn
                )
            END AS lo,
            COALESCE(
                (
                    SELECT o.boundary
                    FROM ordered o
                    WHERE o.rn = r.next_start_rn
                ),
                $2::bytea
            ) AS hi,
            r.planned_rows
        FROM ranges r
        ORDER BY r.planned_chunk_id
        $range_sql$,
        order_args,
        key_json_args,
        rel_sql,
        where_sql,
        chunk_target_rows
    )
    USING p_lo, p_hi;
END
$$;

-- Build a deterministic signature for the compared relation contract. The
-- signature intentionally covers only the selected comparison columns and key
-- columns, because pglogical and native logical replication can validly project
-- a narrower column contract than the physical table definition.
CREATE FUNCTION pgl_validate.schema_signature(
    schema_name text,
    table_name text,
    cols text[] DEFAULT NULL,
    key_cols text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    relid oid := to_regclass(format('%I.%I', $1, $2));
    columns_json jsonb := '[]'::jsonb;
    missing_columns_json jsonb := '[]'::jsonb;
    key_columns_json jsonb := '[]'::jsonb;
    missing_key_columns_json jsonb := '[]'::jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(col_doc ORDER BY attname), '[]'::jsonb)
    INTO columns_json
    FROM (
        SELECT
            a.attname,
            jsonb_build_object(
                'name', a.attname,
                'type_schema', tn.nspname,
                'type_name', t.typname,
                'type_kind', t.typtype::text,
                'type_category', t.typcategory::text,
                'typmod', a.atttypmod,
                'not_null', a.attnotnull,
                'encoding_mode', pgl_validate.column_encoding_mode(a.atttypid),
                'collation', CASE
                    WHEN a.attcollation = 0::oid THEN NULL::jsonb
                    ELSE jsonb_build_object(
                        'schema', cn.nspname,
                        'name', co.collname,
                        'provider', co.collprovider::text,
                        'collate', co.collcollate,
                        'ctype', co.collctype,
                        'deterministic', co.collisdeterministic,
                        'version', co.collversion
                    )
                END,
                'enum_labels', (
                    SELECT COALESCE(jsonb_agg(to_jsonb(enum_label) ORDER BY enum_ordinal), '[]'::jsonb)
                    FROM (
                        SELECT e.enumlabel::text AS enum_label,
                               e.enumsortorder AS enum_ordinal
                        FROM pg_enum e
                        WHERE e.enumtypid = t.oid
                    ) ordered_enum
                ),
                'domain', CASE
                    WHEN t.typtype = 'd' THEN jsonb_build_object(
                        'base_schema', btn.nspname,
                        'base_name', bt.typname,
                        'base_typmod', t.typtypmod,
                        'not_null', t.typnotnull,
                        'constraints', (
                            SELECT COALESCE(jsonb_agg(to_jsonb(definition) ORDER BY constraint_name), '[]'::jsonb)
                            FROM (
                                SELECT c.conname AS constraint_name,
                                       pg_get_constraintdef(c.oid, true) AS definition
                                FROM pg_constraint c
                                WHERE c.contypid = t.oid
                            ) ordered_constraints
                        )
                    )
                    ELSE NULL::jsonb
                END
            ) AS col_doc
        FROM pg_attribute a
        JOIN pg_type t ON t.oid = a.atttypid
        JOIN pg_namespace tn ON tn.oid = t.typnamespace
        LEFT JOIN pg_type bt ON bt.oid = t.typbasetype
        LEFT JOIN pg_namespace btn ON btn.oid = bt.typnamespace
        LEFT JOIN pg_collation co ON co.oid = a.attcollation
        LEFT JOIN pg_namespace cn ON cn.oid = co.collnamespace
        WHERE a.attrelid = relid
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND (
              cols IS NULL
              OR cardinality(cols) = 0
              OR a.attname = ANY (cols)
          )
    ) ordered_columns;

    IF cols IS NOT NULL AND cardinality(cols) > 0 THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(col_name) ORDER BY ordinality), '[]'::jsonb)
        INTO missing_columns_json
        FROM (
            SELECT requested.col_name, requested.ordinality
            FROM unnest(cols) WITH ORDINALITY AS requested(col_name, ordinality)
            LEFT JOIN pg_attribute a
              ON a.attrelid = relid
             AND a.attname = requested.col_name
             AND a.attnum > 0
             AND NOT a.attisdropped
            WHERE a.attname IS NULL
        ) missing;
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(col_name) ORDER BY ordinality), '[]'::jsonb)
    INTO key_columns_json
    FROM unnest(COALESCE(key_cols, ARRAY[]::text[]))
         WITH ORDINALITY AS requested(col_name, ordinality);

    IF key_cols IS NOT NULL AND cardinality(key_cols) > 0 THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(col_name) ORDER BY ordinality), '[]'::jsonb)
        INTO missing_key_columns_json
        FROM (
            SELECT requested.col_name, requested.ordinality
            FROM unnest(key_cols) WITH ORDINALITY AS requested(col_name, ordinality)
            LEFT JOIN pg_attribute a
              ON a.attrelid = relid
             AND a.attname = requested.col_name
             AND a.attnum > 0
             AND NOT a.attisdropped
            WHERE a.attname IS NULL
        ) missing;
    END IF;

    RETURN jsonb_build_object(
        'schema', $1,
        'table', $2,
        'exists', relid IS NOT NULL,
        'columns', columns_json,
        'missing_columns', missing_columns_json,
        'key_columns', key_columns_json,
        'missing_key_columns', missing_key_columns_json
    );
END
$$;

-- Generate the CTE used by coordinator-built SQL to pin digest-affecting GUCs
-- on the participant session before row_digest or schema_signature runs.
CREATE FUNCTION pgl_validate.plan_settings_cte(hash_algorithm text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    effective_hash_algorithm text := COALESCE(
        NULLIF(hash_algorithm, ''),
        NULLIF(current_setting('pgl_validate.hash_algorithm', true), ''),
        'blake3_256'
    );
    json_normalize boolean := COALESCE(
        NULLIF(current_setting('pgl_validate.json_normalize', true), '')::boolean,
        false
    );
    float_signed_zero_distinct boolean := COALESCE(
        NULLIF(current_setting('pgl_validate.float_signed_zero_distinct', true), '')::boolean,
        false
    );
    float_nan_distinct boolean := COALESCE(
        NULLIF(current_setting('pgl_validate.float_nan_distinct', true), '')::boolean,
        false
    );
BEGIN
    IF effective_hash_algorithm NOT IN ('blake3_256','blake3_512') THEN
        RAISE EXCEPTION 'hash_algorithm % is not implemented; supported values are blake3_256, blake3_512',
            effective_hash_algorithm
            USING ERRCODE = '0A000';
    END IF;

    RETURN format(
        'pgl_validate_settings AS MATERIALIZED (SELECT set_config(''pgl_validate.hash_algorithm'', %L, true) AS hash_algorithm, set_config(''pgl_validate.json_normalize'', %L, true) AS json_normalize, set_config(''pgl_validate.float_signed_zero_distinct'', %L, true) AS float_signed_zero_distinct, set_config(''pgl_validate.float_nan_distinct'', %L, true) AS float_nan_distinct, set_config(''extra_float_digits'', ''3'', true) AS extra_float_digits, set_config(''DateStyle'', ''ISO, YMD'', true) AS date_style, set_config(''IntervalStyle'', ''iso_8601'', true) AS interval_style, set_config(''bytea_output'', ''hex'', true) AS bytea_output, set_config(''TimeZone'', ''UTC'', true) AS time_zone)',
        effective_hash_algorithm,
        json_normalize::text,
        float_signed_zero_distinct::text,
        float_nan_distinct::text
    );
END
$$;

-- Generate remote SQL that returns one schema_signature text column. It uses
-- schema/table names instead of a regclass literal so a missing remote relation
-- is reported as a signature mismatch rather than aborting SQL generation.
CREATE FUNCTION pgl_validate.plan_schema_signature_sql(
    schema_name text,
    table_name text,
    cols text[] DEFAULT NULL,
    key_cols text[] DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    cols_sql text;
    key_cols_sql text;
    settings_cte text;
BEGIN
    cols_sql := CASE
        WHEN cols IS NULL THEN 'NULL::text[]'
        ELSE format('%L::text[]', cols::text)
    END;
    key_cols_sql := CASE
        WHEN key_cols IS NULL THEN 'NULL::text[]'
        ELSE format('%L::text[]', key_cols::text)
    END;
    settings_cte := pgl_validate.plan_settings_cte(NULL);

    RETURN format(
        'WITH %s SELECT pgl_validate.schema_signature(%L, %L, %s, %s)::text AS signature FROM pgl_validate_settings',
        settings_cte,
        schema_name,
        table_name,
        cols_sql,
        key_cols_sql
    );
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
    repsets text[] DEFAULT NULL,
    row_filter_sql text DEFAULT NULL,
    include_set_hash boolean DEFAULT false,
    hash_algorithm text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel_sql text;
    enc_modes int[];
    digest_args text;
    row_digest_expr text;
    selected_cols text[];
    filter_sql text;
    range_sql text;
    where_sql text;
    effective_hash_algorithm text;
    settings_cte text;
BEGIN
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

    row_digest_expr := format(
        'pgl_validate.row_digest(%L::int[], %s)',
        enc_modes::text,
        digest_args
    );
    effective_hash_algorithm := COALESCE(
        NULLIF(hash_algorithm, ''),
        NULLIF(current_setting('pgl_validate.hash_algorithm', true), ''),
        'blake3_256'
    );
    IF effective_hash_algorithm NOT IN ('blake3_256','blake3_512') THEN
        RAISE EXCEPTION 'hash_algorithm % is not implemented; supported values are blake3_256, blake3_512',
            effective_hash_algorithm
            USING ERRCODE = '0A000';
    END IF;
    settings_cte := pgl_validate.plan_settings_cte(effective_hash_algorithm);
    filter_sql := CASE
        WHEN row_filter_sql IS NULL OR btrim(row_filter_sql) = '' THEN 'true'
        ELSE format('(%s)', row_filter_sql)
    END;
    range_sql := pgl_validate.plan_key_range_predicate(rel, key_cols, lo, hi);
    where_sql := COALESCE(
        NULLIF(
            concat_ws(
                ' AND ',
                NULLIF(filter_sql, 'true'),
                NULLIF(range_sql, 'true')
            ),
            ''
        ),
        'true'
    );

    IF include_set_hash THEN
        RETURN format(
            'WITH %s, digests AS MATERIALIZED (SELECT %s AS rd FROM pgl_validate_settings, %s t WHERE %s), aggregate AS (SELECT count(*)::bigint AS n_rows, pgl_validate.lthash_bytes(pgl_validate.lthash(rd)) AS lthash FROM digests) SELECT aggregate.n_rows, aggregate.lthash, (SELECT pgl_validate.hash_digest_array(COALESCE(array_agg(rd ORDER BY rd), ARRAY[]::bytea[])) FROM digests) AS set_hash FROM aggregate',
            settings_cte,
            row_digest_expr,
            rel_sql,
            where_sql
        );
    END IF;

    RETURN format(
        'WITH %s SELECT count(*)::bigint AS n_rows, pgl_validate.lthash_bytes(pgl_validate.lthash(%s)) AS lthash, NULL::bytea AS set_hash FROM pgl_validate_settings, %s t WHERE %s',
        settings_cte,
        row_digest_expr,
        rel_sql,
        where_sql
    );
END
$$;

-- Generate the diagnostic-only pglogical row-filter SQL used for
-- session-sensitive filters. This intentionally calls pglogical's own
-- table_data_filtered() function instead of the exact path's deparsed
-- predicate, and callers must stamp the resulting verdict as approximate.
CREATE FUNCTION pgl_validate.plan_pglogical_filtered_sql(
    rel regclass,
    cols text[],
    repsets text[],
    include_set_hash boolean DEFAULT false,
    hash_algorithm text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel_sql text;
    enc_modes int[];
    digest_args text;
    row_digest_expr text;
    selected_cols text[];
    source_sql text;
    effective_hash_algorithm text;
    settings_cte text;
BEGIN
    IF to_regprocedure('pglogical.table_data_filtered(anyelement,regclass,text[])') IS NULL THEN
        RAISE EXCEPTION 'pglogical.table_data_filtered(anyelement,regclass,text[]) is not available'
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

    IF repsets IS NULL OR cardinality(repsets) = 0 THEN
        RAISE EXCEPTION 'repsets are required for pglogical.table_data_filtered()';
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

    row_digest_expr := format(
        'pgl_validate.row_digest(%L::int[], %s)',
        enc_modes::text,
        digest_args
    );
    effective_hash_algorithm := COALESCE(
        NULLIF(hash_algorithm, ''),
        NULLIF(current_setting('pgl_validate.hash_algorithm', true), ''),
        'blake3_256'
    );
    IF effective_hash_algorithm NOT IN ('blake3_256','blake3_512') THEN
        RAISE EXCEPTION 'hash_algorithm % is not implemented; supported values are blake3_256, blake3_512',
            effective_hash_algorithm
            USING ERRCODE = '0A000';
    END IF;
    settings_cte := pgl_validate.plan_settings_cte(effective_hash_algorithm);
    source_sql := format(
        'pglogical.table_data_filtered(NULL::%s, %L::regclass, %L::text[]) AS t',
        rel_sql,
        rel_sql,
        repsets::text
    );

    IF include_set_hash THEN
        RETURN format(
            'WITH %s, digests AS MATERIALIZED (SELECT %s AS rd FROM pgl_validate_settings, %s), aggregate AS (SELECT count(*)::bigint AS n_rows, pgl_validate.lthash_bytes(pgl_validate.lthash(rd)) AS lthash FROM digests) SELECT aggregate.n_rows, aggregate.lthash, (SELECT pgl_validate.hash_digest_array(COALESCE(array_agg(rd ORDER BY rd), ARRAY[]::bytea[])) FROM digests) AS set_hash FROM aggregate',
            settings_cte,
            row_digest_expr,
            source_sql
        );
    END IF;

    RETURN format(
        'WITH %s SELECT count(*)::bigint AS n_rows, pgl_validate.lthash_bytes(pgl_validate.lthash(%s)) AS lthash, NULL::bytea AS set_hash FROM pgl_validate_settings, %s',
        settings_cte,
        row_digest_expr,
        source_sql
    );
END
$$;

-- Generate the planner-visible SQL used to enumerate keys and row digests for
-- a localized divergent key range.
CREATE FUNCTION pgl_validate.plan_localize_sql(
    rel regclass,
    key_cols text[],
    lo bytea,
    hi bytea,
    cols text[],
    row_filter_sql text DEFAULT NULL,
    hash_algorithm text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel_sql text;
    selected_cols text[];
    selected_key_cols text[];
    enc_modes int[];
    key_enc_modes int[];
    digest_args text;
    key_digest_args text;
    key_text_args text;
    order_args text;
    filter_sql text;
    range_sql text;
    where_sql text;
    effective_hash_algorithm text;
    settings_cte text;
BEGIN
    IF key_cols IS NULL OR cardinality(key_cols) = 0 THEN
        RAISE EXCEPTION 'row-level localization requires a comparison key';
    END IF;

    SELECT format('%I.%I', n.nspname, c.relname)
    INTO rel_sql
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = rel;

    IF rel_sql IS NULL THEN
        RAISE EXCEPTION 'relation % does not exist', rel;
    END IF;

    SELECT array_agg(a.attname ORDER BY a.attname)
    INTO selected_cols
    FROM unnest(cols) requested(col_name)
    JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = requested.col_name
     AND a.attnum > 0
     AND NOT a.attisdropped;

    IF selected_cols IS NULL OR cardinality(selected_cols) <> cardinality(cols) THEN
        RAISE EXCEPTION 'one or more requested columns are not present on %', rel::text;
    END IF;

    SELECT array_agg(a.attname ORDER BY ord.ordinality)
    INTO selected_key_cols
    FROM unnest(key_cols) WITH ORDINALITY AS ord(col_name, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = ord.col_name
     AND a.attnum > 0
     AND NOT a.attisdropped;

    IF selected_key_cols IS NULL OR cardinality(selected_key_cols) <> cardinality(key_cols) THEN
        RAISE EXCEPTION 'one or more key columns are not present on %', rel::text;
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

    SELECT
        array_agg(pgl_validate.column_encoding_mode(a.atttypid) ORDER BY ord.ordinality),
        string_agg(format('t.%I', a.attname), ', ' ORDER BY ord.ordinality),
        string_agg(format('%L, t.%I', a.attname, a.attname), ', ' ORDER BY ord.ordinality),
        string_agg(format('t.%I', a.attname), ', ' ORDER BY ord.ordinality)
    INTO key_enc_modes, key_digest_args, key_text_args, order_args
    FROM unnest(selected_key_cols) WITH ORDINALITY AS ord(col_name, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = ord.col_name
     AND a.attnum > 0
     AND NOT a.attisdropped;

    filter_sql := CASE
        WHEN row_filter_sql IS NULL OR btrim(row_filter_sql) = '' THEN 'true'
        ELSE format('(%s)', row_filter_sql)
    END;
    effective_hash_algorithm := COALESCE(
        NULLIF(hash_algorithm, ''),
        NULLIF(current_setting('pgl_validate.hash_algorithm', true), ''),
        'blake3_256'
    );
    IF effective_hash_algorithm NOT IN ('blake3_256','blake3_512') THEN
        RAISE EXCEPTION 'hash_algorithm % is not implemented; supported values are blake3_256, blake3_512',
            effective_hash_algorithm
            USING ERRCODE = '0A000';
    END IF;
    settings_cte := pgl_validate.plan_settings_cte(effective_hash_algorithm);
    range_sql := pgl_validate.plan_key_range_predicate(rel, key_cols, lo, hi);
    where_sql := COALESCE(
        NULLIF(
            concat_ws(
                ' AND ',
                NULLIF(filter_sql, 'true'),
                NULLIF(range_sql, 'true')
            ),
            ''
        ),
        'true'
    );

    RETURN format(
        'WITH %s SELECT jsonb_build_object(%s)::text AS key_text, pgl_validate.row_digest(%L::int[], %s) AS key_bytes, pgl_validate.row_digest(%L::int[], %s) AS row_digest, to_jsonb(t)::text AS row_json FROM pgl_validate_settings, %s t WHERE %s ORDER BY %s',
        settings_cte,
        key_text_args,
        key_enc_modes::text,
        key_digest_args,
        enc_modes::text,
        digest_args,
        rel_sql,
        where_sql,
        order_args
    );
END
$$;

-- Backward-compatible unbounded localization SQL generator.
CREATE FUNCTION pgl_validate.plan_localize_sql(
    rel regclass,
    key_cols text[],
    cols text[],
    row_filter_sql text DEFAULT NULL,
    hash_algorithm text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT pgl_validate.plan_localize_sql($1, $2, NULL, NULL, $3, $4, $5)
$$;

-- Generate the planner-visible SQL used to read a sequence last_value on each
-- participant. The returned SQL is safe to send to a peer with the same schema.
CREATE FUNCTION pgl_validate.plan_sequence_sql(seq regclass)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    seq_sql text;
BEGIN
    SELECT format('%I.%I', n.nspname, c.relname)
    INTO seq_sql
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = seq
      AND c.relkind = 'S';

    IF seq_sql IS NULL THEN
        RAISE EXCEPTION 'relation % is not a sequence', seq;
    END IF;

    RETURN format('SELECT last_value::bigint AS last_value FROM %s', seq_sql);
END
$$;

