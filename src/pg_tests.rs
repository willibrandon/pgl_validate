#[pgrx::pg_schema]
mod tests {
    use pgrx::prelude::*;

    fn sql_literal(value: &str) -> String {
        format!("'{}'", value.replace('\'', "''"))
    }

    fn identifier(value: &str) -> String {
        assert!(
            value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            "test identifier contains unsafe characters: {value}"
        );
        value.to_string()
    }

    fn local_dsn() -> String {
        let port = Spi::get_one::<i32>("SELECT inet_server_port()")
            .unwrap()
            .unwrap();
        let dbname = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        let user = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();

        format!(
            "host=localhost port={port} dbname={dbname} user={user} connect_timeout=5 application_name=pgl_validate_test options='-c statement_timeout=10000 -c lock_timeout=10000'"
        )
    }

    fn peer_dsn(dbname: &str) -> String {
        let port = Spi::get_one::<i32>("SELECT inet_server_port()")
            .unwrap()
            .unwrap();
        let user = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();

        format!(
            "host=localhost port={port} dbname={dbname} user={user} connect_timeout=5 application_name=pgl_validate_test options='-c statement_timeout=10000 -c lock_timeout=10000'"
        )
    }

    #[pg_test]
    fn hash_digest_array_is_order_sensitive_by_contract() {
        let first = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.hash_digest_array(ARRAY['\\x01'::bytea, '\\x02'::bytea])",
        )
        .unwrap()
        .unwrap();
        let second = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.hash_digest_array(ARRAY['\\x02'::bytea, '\\x01'::bytea])",
        )
        .unwrap()
        .unwrap();
        assert_ne!(first, second);
    }

    #[pg_test]
    fn row_and_set_digests_honor_blake3_512_setting() {
        Spi::run("SET LOCAL pgl_validate.hash_algorithm = 'blake3_256'").unwrap();
        let digest_lengths = Spi::get_one::<String>(
            r#"
            SELECT octet_length(pgl_validate.row_digest(ARRAY[1], 1::int4))::text || ';' ||
                   octet_length(pgl_validate.hash_digest_array(ARRAY[
                       pgl_validate.row_digest(ARRAY[1], 1::int4)
                   ]))::text
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(digest_lengths, "32;32");

        Spi::run("SET LOCAL pgl_validate.hash_algorithm = 'blake3_512'").unwrap();
        let wide_digest_lengths = Spi::get_one::<String>(
            r#"
            SELECT octet_length(pgl_validate.row_digest(ARRAY[1], 1::int4))::text || ';' ||
                   octet_length(pgl_validate.hash_digest_array(ARRAY[
                       pgl_validate.row_digest(ARRAY[1], 1::int4)
                   ]))::text
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(wide_digest_lengths, "64;64");
    }

    #[pg_test]
    fn row_digest_distinguishes_null_from_empty_text() {
        let null_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[2], NULL::text)")
                .unwrap()
                .unwrap();
        let empty_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[2], ''::text)")
                .unwrap()
                .unwrap();
        assert_ne!(null_digest, empty_digest);
    }

    #[pg_test]
    fn row_digest_supports_send_mode() {
        let one = Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 1::int4)")
            .unwrap()
            .unwrap();
        let another_one =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 1::int4)")
                .unwrap()
                .unwrap();
        let two = Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 2::int4)")
            .unwrap()
            .unwrap();

        assert_eq!(one, another_one);
        assert_ne!(one, two);
    }

    #[pg_test]
    fn row_digest_normalizes_float_signed_zero_by_default() {
        let float4_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '-0'::float4)")
                .unwrap()
                .unwrap();
        let float4_positive_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '0'::float4)")
                .unwrap()
                .unwrap();
        let float8_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '-0'::float8)")
                .unwrap()
                .unwrap();
        let float8_positive_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '0'::float8)")
                .unwrap()
                .unwrap();

        assert_eq!(float4_digest, float4_positive_digest);
        assert_eq!(float8_digest, float8_positive_digest);
    }

    #[pg_test]
    fn row_digest_can_distinguish_float_signed_zero() {
        Spi::run("SET LOCAL pgl_validate.float_signed_zero_distinct = on").unwrap();

        let negative_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '-0'::float8)")
                .unwrap()
                .unwrap();
        let positive_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], '0'::float8)")
                .unwrap()
                .unwrap();

        assert_ne!(negative_digest, positive_digest);
    }

    #[pg_test]
    fn row_digest_normalizes_float_array_elements_by_default() {
        let negative_digest = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.row_digest(ARRAY[1], ARRAY['-0'::float4, '-0'::float4])",
        )
        .unwrap()
        .unwrap();
        let positive_digest = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.row_digest(ARRAY[1], ARRAY['0'::float4, '0'::float4])",
        )
        .unwrap()
        .unwrap();
        let shifted_lower_bound_digest = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.row_digest(ARRAY[1], '[0:1]={0,0}'::float4[])",
        )
        .unwrap()
        .unwrap();

        assert_eq!(negative_digest, positive_digest);
        assert_ne!(positive_digest, shifted_lower_bound_digest);
    }

    #[pg_test]
    fn row_digest_can_distinguish_float_array_signed_zero() {
        Spi::run("SET LOCAL pgl_validate.float_signed_zero_distinct = on").unwrap();

        let negative_digest = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.row_digest(ARRAY[1], ARRAY['-0'::float8])",
        )
        .unwrap()
        .unwrap();
        let positive_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], ARRAY['0'::float8])")
                .unwrap()
                .unwrap();

        assert_ne!(negative_digest, positive_digest);
    }

    #[pg_test]
    fn row_digest_preserves_json_exact_text_by_default() {
        let compact_digest = Spi::get_one::<Vec<u8>>(
            r#"SELECT pgl_validate.row_digest(ARRAY[2], '{"a":1,"b":2}'::json)"#,
        )
        .unwrap()
        .unwrap();
        let reordered_digest = Spi::get_one::<Vec<u8>>(
            r#"SELECT pgl_validate.row_digest(ARRAY[2], '{"b":2,"a":1}'::json)"#,
        )
        .unwrap()
        .unwrap();

        assert_ne!(compact_digest, reordered_digest);
    }

    #[pg_test]
    fn row_digest_can_normalize_json_through_jsonb() {
        let compact_digest = Spi::get_one::<Vec<u8>>(
            r#"SELECT pgl_validate.row_digest(ARRAY[3], '{"a":1,"b":2}'::json)"#,
        )
        .unwrap()
        .unwrap();
        let reordered_digest = Spi::get_one::<Vec<u8>>(
            r#"SELECT pgl_validate.row_digest(ARRAY[3], '{"b":2,"a":1}'::json)"#,
        )
        .unwrap()
        .unwrap();

        assert_eq!(compact_digest, reordered_digest);
    }

    #[pg_test]
    fn column_encoding_mode_honors_json_normalize() {
        let default_mode =
            Spi::get_one::<i32>("SELECT pgl_validate.column_encoding_mode('json'::regtype::oid)")
                .unwrap()
                .unwrap();
        Spi::run("SET LOCAL pgl_validate.json_normalize = on").unwrap();
        let normalized_mode =
            Spi::get_one::<i32>("SELECT pgl_validate.column_encoding_mode('json'::regtype::oid)")
                .unwrap()
                .unwrap();
        let jsonb_mode =
            Spi::get_one::<i32>("SELECT pgl_validate.column_encoding_mode('jsonb'::regtype::oid)")
                .unwrap()
                .unwrap();

        assert_eq!(default_mode, 2);
        assert_eq!(normalized_mode, 3);
        assert_eq!(jsonb_mode, 1);
    }

    #[pg_test]
    fn column_encoding_mode_recurses_into_arrays_and_domains() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let domain_name = identifier(&format!("pgl_validate_numeric_domain_{backend_pid}"));
        let composite_name = identifier(&format!("pgl_validate_composite_{backend_pid}"));
        let enum_name = identifier(&format!("pgl_validate_enum_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE DOMAIN public.{domain_name} AS numeric;
            CREATE TYPE public.{composite_name} AS (amount numeric);
            CREATE TYPE public.{enum_name} AS ENUM ('a', 'b');
            SET LOCAL pgl_validate.json_normalize = on;
            "
        ))
        .unwrap();

        let modes = Spi::get_one::<String>(&format!(
            "
            SELECT pgl_validate.column_encoding_mode('int4[]'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('numeric[]'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('json[]'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('public.{domain_name}'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('public.{composite_name}'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('int4range'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('point'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('float8[]'::regtype::oid)::text || ';' ||
                   pgl_validate.column_encoding_mode('public.{enum_name}'::regtype::oid)::text
            "
        ))
        .unwrap()
        .unwrap();

        assert_eq!(modes, "1;2;2;2;2;2;2;1;1");
    }

    #[pg_test]
    fn lthash_aggregate_is_order_independent_and_duplicate_sensitive() {
        Spi::run(
            r#"
            CREATE TEMP TABLE digest_rows(ord int, rd bytea);
            INSERT INTO digest_rows
            VALUES
                (1, pgl_validate.row_digest(ARRAY[1], 1::int4)),
                (2, pgl_validate.row_digest(ARRAY[1], 2::int4));
            "#,
        )
        .unwrap();

        let forward = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (SELECT rd FROM digest_rows ORDER BY ord) s",
        )
        .unwrap()
        .unwrap();
        let reverse = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (SELECT rd FROM digest_rows ORDER BY ord DESC) s",
        )
        .unwrap()
        .unwrap();
        let duplicate = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (
                SELECT rd FROM digest_rows
                UNION ALL
                SELECT rd FROM digest_rows WHERE ord = 1
             ) s",
        )
        .unwrap()
        .unwrap();

        assert_eq!(forward, reverse);
        assert_ne!(forward, duplicate);
    }

    #[pg_test]
    fn plan_chunk_sql_sorts_columns_and_uses_variadic_row_digest() {
        Spi::run(
            r#"
            CREATE TEMP TABLE plan_target(
                status text,
                id int PRIMARY KEY,
                amount numeric
            );
            INSERT INTO plan_target VALUES
                ('before', 1, 9.50),
                ('inside-low', 2, 10.25),
                ('inside-high', 9, 11.50),
                ('after', 10, 12.00);
            "#,
        )
        .unwrap();

        let sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['status','id','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(sql.contains("count(*)::bigint AS n_rows"));
        assert!(sql.contains("pgl_validate.lthash_bytes(pgl_validate.lthash("));
        assert!(sql.contains("NULL::bytea AS set_hash"));
        assert!(
            sql.contains("pgl_validate.row_digest('{2,1,1}'::int[], t.amount, t.id, t.status)")
        );
        assert!(!sql.contains("ARRAY[t."));

        let confirm_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['status','id','amount'],
                NULL,
                NULL,
                true
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(confirm_sql.contains("pgl_validate.hash_digest_array"));
        assert!(confirm_sql.contains("array_agg(rd ORDER BY rd)"));

        Spi::run("SET LOCAL pgl_validate.hash_algorithm = 'blake3_512'").unwrap();
        let wide_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['status','id','amount'],
                NULL,
                NULL,
                true
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(wide_sql.contains("set_config('pgl_validate.hash_algorithm', 'blake3_512', true)"));
        let wide_set_hash_bytes = Spi::get_one::<i32>(&format!(
            "SELECT octet_length(set_hash) FROM ({wide_sql}) AS q"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(wide_set_hash_bytes, 64);
        Spi::run("SET LOCAL pgl_validate.hash_algorithm = 'blake3_256'").unwrap();

        let bounded_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                convert_to('{"id":2}', 'UTF8'),
                convert_to('{"id":10}', 'UTF8'),
                ARRAY['status','id','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(bounded_sql.contains("t.id >= '2'::integer"));
        assert!(bounded_sql.contains("t.id < '10'::integer"));

        let bounded_count =
            Spi::get_one::<i64>(&format!("SELECT n_rows FROM ({bounded_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(bounded_count, 2);

        let planned_ranges = Spi::get_one::<String>(
            r#"
            SELECT string_agg(
                       chunk_id::text || ':' ||
                       COALESCE(convert_from(lo, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       COALESCE(convert_from(hi, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       n_rows::text,
                       ',' ORDER BY chunk_id
                   )
            FROM pgl_validate.plan_key_ranges(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                2
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(planned_ranges, "1:<null>:9:2,2:9:<null>:2");

        Spi::run(
            r#"
            CREATE TEMP TABLE plan_composite(
                part int NOT NULL,
                code text NOT NULL,
                amount int,
                PRIMARY KEY (part, code)
            );
            INSERT INTO plan_composite VALUES
                (1, 'a', 10),
                (1, 'b', 20),
                (2, 'a', 30),
                (2, 'b', 40);
            "#,
        )
        .unwrap();

        let composite_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_composite'::regclass,
                ARRAY['part','code'],
                convert_to('{"part":1,"code":"b"}', 'UTF8'),
                convert_to('{"part":2,"code":"b"}', 'UTF8'),
                ARRAY['part','code','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(composite_sql.contains("(t.part, t.code) >= ('1'::integer, 'b'::text)"));
        assert!(composite_sql.contains("(t.part, t.code) < ('2'::integer, 'b'::text)"));

        let composite_count =
            Spi::get_one::<i64>(&format!("SELECT n_rows FROM ({composite_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(composite_count, 2);

        let localize_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_localize_sql(
                'plan_composite'::regclass,
                ARRAY['part','code'],
                convert_to('{"part":1,"code":"b"}', 'UTF8'),
                convert_to('{"part":2,"code":"b"}', 'UTF8'),
                ARRAY['part','code','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(localize_sql.contains("(t.part, t.code) >= ('1'::integer, 'b'::text)"));
        assert!(localize_sql.contains("(t.part, t.code) < ('2'::integer, 'b'::text)"));

        let localized_count =
            Spi::get_one::<i64>(&format!("SELECT count(*) FROM ({localize_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(localized_count, 2);

        let composite_ranges = Spi::get_one::<String>(
            r#"
            WITH ranges AS (
                SELECT
                    chunk_id,
                    convert_from(lo, 'UTF8')::jsonb AS lo_doc,
                    convert_from(hi, 'UTF8')::jsonb AS hi_doc,
                    n_rows
                FROM pgl_validate.plan_key_ranges(
                    'plan_composite'::regclass,
                    ARRAY['part','code'],
                    convert_to('{"part":1,"code":"b"}', 'UTF8'),
                    convert_to('{"part":2,"code":"b"}', 'UTF8'),
                    1
                )
            )
            SELECT string_agg(
                       chunk_id::text || ':' ||
                       (lo_doc->>'part') || '/' || (lo_doc->>'code') || ':' ||
                       (hi_doc->>'part') || '/' || (hi_doc->>'code') || ':' ||
                       n_rows::text,
                       ',' ORDER BY chunk_id
                   )
            FROM ranges
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(composite_ranges, "1:1/b:2/a:1,2:2/a:2/b:1");
    }

    #[pg_test]
    fn generated_digest_sql_pins_text_fallback_gucs() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let domain_name = identifier(&format!("pgl_validate_tstz_domain_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_text_fallback_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE DOMAIN public.{domain_name} AS timestamptz;
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                observed_at public.{domain_name}
            );
            INSERT INTO public.{table_name}
            VALUES (1, '2026-06-27 01:02:03+00'::timestamptz);
            "
        ))
        .unwrap();

        let checksum_sql = Spi::get_one::<String>(&format!(
            "
            SELECT pgl_validate.plan_chunk_sql(
                'public.{table_name}'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['observed_at'],
                NULL,
                NULL,
                true
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert!(checksum_sql.contains("set_config('TimeZone', 'UTC', true)"));
        assert!(checksum_sql.contains("pgl_validate.row_digest('{2}'::int[]"));

        Spi::run("SET LOCAL TimeZone = 'America/Los_Angeles'").unwrap();
        let los_angeles_digest = Spi::get_one::<String>(&format!(
            "SELECT encode(set_hash, 'hex') FROM ({checksum_sql}) AS checksum"
        ))
        .unwrap()
        .unwrap();

        Spi::run("SET LOCAL TimeZone = 'Asia/Tokyo'").unwrap();
        let tokyo_digest = Spi::get_one::<String>(&format!(
            "SELECT encode(set_hash, 'hex') FROM ({checksum_sql}) AS checksum"
        ))
        .unwrap()
        .unwrap();

        assert_eq!(los_angeles_digest, tokyo_digest);
    }

    #[pg_test]
    fn generated_checksum_sql_covers_common_scalar_container_and_composite_types() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let composite_name = identifier(&format!("pgl_validate_type_matrix_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_type_matrix_target_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TYPE public.{composite_name} AS (amount numeric, label text);
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                amount numeric(18,6) NOT NULL,
                bounds int4range NOT NULL,
                bytes bytea NOT NULL,
                duration interval NOT NULL,
                ip inet NOT NULL,
                observed_at timestamptz NOT NULL,
                payload json NOT NULL,
                payloadb jsonb NOT NULL,
                point_value point NOT NULL,
                shaped public.{composite_name} NOT NULL,
                tags text[] NOT NULL,
                uid uuid NOT NULL
            );

            INSERT INTO public.{table_name}
            VALUES (
                1,
                12.345600,
                int4range(1, 5, '[)'),
                decode('00ff10', 'hex'),
                interval '1 day 02:03:04.500',
                inet '2001:db8::1/64',
                TIMESTAMPTZ '2026-06-27 01:02:03.456+00',
                '{{\"kind\":\"exact\",\"items\":[1,2,3]}}'::json,
                '{{\"kind\":\"canonical\",\"items\":[1,2,3]}}'::jsonb,
                point '(1.5,2.5)',
                ROW(12.345600, 'same')::public.{composite_name},
                ARRAY['alpha','beta']::text[],
                '00000000-0000-0000-0000-000000000001'::uuid
            );
            "
        ))
        .unwrap();

        let checksum_sql = Spi::get_one::<String>(&format!(
            "
            SELECT pgl_validate.plan_chunk_sql(
                'public.{table_name}'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY[
                    'amount',
                    'bounds',
                    'bytes',
                    'duration',
                    'ip',
                    'observed_at',
                    'payload',
                    'payloadb',
                    'point_value',
                    'shaped',
                    'tags',
                    'uid'
                ],
                NULL,
                NULL,
                true
            )
            "
        ))
        .unwrap()
        .unwrap();

        assert!(checksum_sql.contains("set_config('DateStyle', 'ISO, YMD', true)"));
        assert!(checksum_sql.contains("set_config('IntervalStyle', 'iso_8601', true)"));
        assert!(checksum_sql.contains("set_config('TimeZone', 'UTC', true)"));
        assert!(checksum_sql.contains("set_config('bytea_output', 'hex', true)"));
        assert!(checksum_sql.contains("pgl_validate.row_digest("));
        assert!(checksum_sql.contains("t.shaped"));

        Spi::run(
            "
            SET LOCAL DateStyle = 'SQL, DMY';
            SET LOCAL IntervalStyle = 'postgres';
            SET LOCAL TimeZone = 'America/Los_Angeles';
            SET LOCAL bytea_output = 'escape';
            ",
        )
        .unwrap();
        let hostile_guc_digest = Spi::get_one::<String>(&format!(
            "SELECT encode(set_hash, 'hex') FROM ({checksum_sql}) AS checksum"
        ))
        .unwrap()
        .unwrap();

        Spi::run(
            "
            SET LOCAL DateStyle = 'German, DMY';
            SET LOCAL IntervalStyle = 'sql_standard';
            SET LOCAL TimeZone = 'Asia/Tokyo';
            SET LOCAL bytea_output = 'hex';
            ",
        )
        .unwrap();
        let alternate_guc_digest = Spi::get_one::<String>(&format!(
            "SELECT encode(set_hash, 'hex') FROM ({checksum_sql}) AS checksum"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(hostile_guc_digest, alternate_guc_digest);

        Spi::run(&format!(
            "
            UPDATE public.{table_name}
            SET shaped = ROW(12.345600, 'changed')::public.{composite_name}
            WHERE id = 1;
            "
        ))
        .unwrap();
        let changed_digest = Spi::get_one::<String>(&format!(
            "SELECT encode(set_hash, 'hex') FROM ({checksum_sql}) AS checksum"
        ))
        .unwrap()
        .unwrap();
        assert_ne!(alternate_guc_digest, changed_digest);
    }

    #[pg_test]
    fn compare_table_records_local_match_result() {
        Spi::run(
            r#"
            CREATE TEMP TABLE compare_target(
                id int PRIMARY KEY,
                amount numeric,
                status text
            );
            INSERT INTO compare_target VALUES
                (1, 10.25, 'open'),
                (2, 11.50, 'closed');
            "#,
        )
        .unwrap();

        let verdict = Spi::get_one::<String>(
            "SELECT (pgl_validate.compare_table('compare_target'::regclass)).verdict",
        )
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "match");

        let node_rows = Spi::get_one::<i64>(
            "SELECT n_rows FROM pgl_validate.table_node_result WHERE table_name = 'compare_target'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(node_rows, 2);

        let lthash_present = Spi::get_one::<bool>(
            "SELECT lthash IS NOT NULL FROM pgl_validate.table_node_result WHERE table_name = 'compare_target'",
        )
        .unwrap()
        .unwrap();
        assert!(lthash_present);

        let root_chunk = Spi::get_one::<String>(
            "
            SELECT cr.state || ';' || cnr.n_rows::text || ';' || (cnr.lthash IS NOT NULL)::text
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.table_name = 'compare_target'
              AND cr.chunk_id = 1
              AND cnr.node = 'local'
            ",
        )
        .unwrap()
        .unwrap();
        assert_eq!(root_chunk, "clean;2;true");
    }

    #[pg_test]
    fn security_tier_roles_gate_extension_surface() {
        Spi::run(
            r#"
            DROP ROLE IF EXISTS pgl_validate_security_unprivileged;
            DROP ROLE IF EXISTS pgl_validate_security_orchestrator;
            DROP ROLE IF EXISTS pgl_validate_security_repair;
            CREATE ROLE pgl_validate_security_unprivileged;
            CREATE ROLE pgl_validate_security_orchestrator;
            CREATE ROLE pgl_validate_security_repair;
            GRANT pgl_validate_orchestrate TO pgl_validate_security_orchestrator;
            GRANT pgl_validate_repair TO pgl_validate_security_repair;
            "#,
        )
        .unwrap();

        let privilege_shape = Spi::get_one::<String>(
            r#"
            SELECT
                has_schema_privilege('pgl_validate_security_unprivileged', 'pgl_validate', 'USAGE')::text || ';' ||
                has_function_privilege('pgl_validate_security_unprivileged', 'pgl_validate.compare_table(regclass,text[],jsonb)', 'EXECUTE')::text || ';' ||
                has_table_privilege('pgl_validate_security_unprivileged', 'pgl_validate.peer', 'SELECT')::text || ';' ||
                has_function_privilege('pgl_validate_validate', 'pgl_validate.row_digest(integer[], "any")', 'EXECUTE')::text || ';' ||
                has_function_privilege('pgl_validate_validate', 'pgl_validate.compare_table(regclass,text[],jsonb)', 'EXECUTE')::text || ';' ||
                has_function_privilege('pgl_validate_security_orchestrator', 'pgl_validate.compare_table(regclass,text[],jsonb)', 'EXECUTE')::text || ';' ||
                has_table_privilege('pgl_validate_security_orchestrator', 'pgl_validate.run', 'INSERT')::text || ';' ||
                has_function_privilege('pgl_validate_security_orchestrator', 'pgl_validate.apply_repair(bigint,text,text,text,text,boolean)', 'EXECUTE')::text || ';' ||
                has_function_privilege('pgl_validate_security_repair', 'pgl_validate.apply_repair(bigint,text,text,text,text,boolean)', 'EXECUTE')::text || ';' ||
                has_function_privilege('pgl_validate_security_repair', 'pgl_validate.remote_execute(text,text,integer,integer,integer)', 'EXECUTE')::text
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            privilege_shape,
            "false;false;false;true;false;true;true;false;true;true"
        );

        Spi::run(
            r#"
            CREATE TABLE public.security_tier_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO public.security_tier_target VALUES (1, 'same');
            GRANT SELECT ON public.security_tier_target TO pgl_validate_security_orchestrator;
            "#,
        )
        .unwrap();

        Spi::run("SET ROLE pgl_validate_security_orchestrator").unwrap();
        let verdict = Spi::get_one::<String>(
            "SELECT (pgl_validate.compare_table('public.security_tier_target'::regclass)).verdict",
        );
        Spi::run("RESET ROLE").unwrap();
        assert_eq!(verdict.unwrap().unwrap(), "match");

        Spi::run(
            r#"
            DROP TABLE public.security_tier_target;
            DROP ROLE pgl_validate_security_repair;
            DROP ROLE pgl_validate_security_orchestrator;
            DROP ROLE pgl_validate_security_unprivileged;
            "#,
        )
        .unwrap();
    }

    #[pg_test]
    fn compare_table_records_commit_timestamp_advisory_when_disabled() {
        Spi::run(
            "
            CREATE TEMP TABLE commit_ts_advisory_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO commit_ts_advisory_target VALUES (1, 'same');
            ",
        )
        .unwrap();

        let setting = Spi::get_one::<String>("SHOW track_commit_timestamp")
            .unwrap()
            .unwrap();
        let run_id = Spi::get_one::<i64>(
            "SELECT (pgl_validate.compare_table('commit_ts_advisory_target'::regclass)).run_id",
        )
        .unwrap()
        .unwrap();

        let advisory_count = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.schema_issue
            WHERE run_id = {run_id}
              AND issue_code = 'NO_COMMIT_TS'
            "
        ))
        .unwrap()
        .unwrap();
        if setting == "off" {
            assert_eq!(advisory_count, 1);
        } else {
            assert_eq!(advisory_count, 0);
        }

        let verdict = Spi::get_one::<String>(&format!(
            "SELECT verdict FROM pgl_validate.table_result WHERE run_id = {run_id}"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "match");
    }

    #[pg_test]
    fn compare_table_persists_planned_key_range_chunks() {
        Spi::run(
            r#"
            DELETE FROM pgl_validate.peer;
            CREATE TEMP TABLE range_compare_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO range_compare_target
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 5) AS g;
            "#,
        )
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            r#"
            SELECT (pgl_validate.compare_table(
                'range_compare_target'::regclass,
                ARRAY[]::text[],
                '{"chunk_target_rows":2}'::jsonb
            )).run_id
            "#,
        )
        .unwrap()
        .unwrap();

        let chunk_shape = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(
                       chunk_id::text || ':' || state || ':' ||
                       COALESCE(convert_from(lo, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       COALESCE(convert_from(hi, 'UTF8')::jsonb->>'id', '<null>'),
                       ',' ORDER BY chunk_id
                   )
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = 'range_compare_target'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            chunk_shape,
            "1:split:<null>:<null>,2:clean:<null>:3,3:clean:3:5,4:clean:5:<null>"
        );

        let node_rows = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(chunk_id::text || ':' || n_rows::text, ',' ORDER BY chunk_id)
            FROM pgl_validate.chunk_node_result
            WHERE run_id = {run_id}
              AND table_name = 'range_compare_target'
              AND node = 'local'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(node_rows, "1:5,2:2,3:2,4:1");

        let progress = Spi::get_one::<String>(&format!(
            "
            SELECT chunks_done::text || '/' || chunks_total::text
            FROM pgl_validate.run_progress
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(progress, "3/3");
    }

    #[pg_test]
    fn compare_table_splits_slow_chunks_until_single_row_ranges() {
        Spi::run(
            r#"
            DELETE FROM pgl_validate.peer;
            CREATE TEMP TABLE duration_split_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO duration_split_target
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 6) AS g;
            "#,
        )
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            r#"
            SELECT (pgl_validate.compare_table(
                'duration_split_target'::regclass,
                ARRAY[]::text[],
                '{"chunk_target_rows":4,"chunk_max_duration":"1 microsecond"}'::jsonb
            )).run_id
            "#,
        )
        .unwrap()
        .unwrap();

        let split_count = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = 'duration_split_target'
              AND chunk_id <> 1
              AND state = 'split'
            "
        ))
        .unwrap()
        .unwrap();
        assert!(
            split_count > 0,
            "chunk_max_duration should force at least one non-root split"
        );

        let max_leaf_rows = Spi::get_one::<i64>(&format!(
            "
            SELECT max(cnr.n_rows)
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = 'duration_split_target'
              AND cr.chunk_id <> 1
              AND cr.state <> 'split'
              AND cnr.node = 'local'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(max_leaf_rows, 1);

        let split_parent_rows = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = 'duration_split_target'
              AND cr.chunk_id <> 1
              AND cr.state = 'split'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(split_parent_rows, 0);
    }

    #[pg_test]
    fn compare_table_uses_split_fanout_for_slow_chunk_retries() {
        Spi::run(
            r#"
            DELETE FROM pgl_validate.peer;
            CREATE TEMP TABLE split_fanout_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO split_fanout_target
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 8) AS g;
            "#,
        )
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            r#"
            SELECT (pgl_validate.compare_table(
                'split_fanout_target'::regclass,
                ARRAY[]::text[],
                '{"chunk_target_rows":4,"chunk_max_duration":"1 microsecond","split_fanout":4}'::jsonb
            )).run_id
            "#,
        )
        .unwrap()
        .unwrap();

        let non_root_split_count = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = 'split_fanout_target'
              AND chunk_id <> 1
              AND state = 'split'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(non_root_split_count, 2);

        let leaf_shape = Spi::get_one::<String>(&format!(
            "
            SELECT count(*)::text || ';' || max(cnr.n_rows)::text
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = 'split_fanout_target'
              AND cr.state <> 'split'
              AND cnr.node = 'local'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(leaf_shape, "8;1");
    }

    #[pg_test]
    fn compare_uses_guc_defaults_with_option_overrides() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_guc_peer_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_guc_target_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_guc_seq_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, 'value-' || g::text
                 FROM generate_series(1, 5) AS g;
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 DO $pgl_validate_guc$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 17, true);
                 END
                 $pgl_validate_guc$;"
            ),
        )
        .unwrap();

        let require_barrier_default = Spi::get_one::<String>("SHOW pgl_validate.require_barrier")
            .unwrap()
            .unwrap();
        assert_eq!(require_barrier_default, "on");

        Spi::run(&format!(
            "
            SET LOCAL pgl_validate.chunk_target_rows = 2;
            SET LOCAL pgl_validate.recheck_passes = 2;
            SET LOCAL pgl_validate.require_barrier = off;
            SET LOCAL pgl_validate.max_reported_tuple_bytes = 8192;
            SET LOCAL pgl_validate.max_reported_divergences = 1000;
            SET LOCAL pgl_validate.hash_algorithm = 'blake3_256';
            SET LOCAL pgl_validate.chunk_max_duration = '2s';
            SET LOCAL pgl_validate.split_fanout = 3;
            SET LOCAL pgl_validate.max_parallel_chunks = 4;
            SET LOCAL pgl_validate.max_snapshot_age = '5min';
            SET LOCAL pgl_validate.statement_timeout_per_chunk = '30s';
            SET LOCAL pgl_validate.throttle_max_lag = 'off';
            SET LOCAL pgl_validate.sequence_buffer_multiplier = 1;
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name}
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 5) AS g;
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_guc', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let guc_run_id = Spi::get_one::<i64>(&format!(
            "SELECT (pgl_validate.compare_table('public.{table_name}'::regclass)).run_id"
        ))
        .unwrap()
        .unwrap();
        let guc_chunks = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {guc_run_id}
              AND table_name = {table_name}
              AND state <> 'split'
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(guc_chunks, 3);

        let guc_run_options = Spi::get_one::<String>(&format!(
            "
            SELECT (options->>'chunk_target_rows') || ';' ||
                   (options->>'recheck_passes') || ';' ||
                   (options->>'throttle_max_lag') || ';' ||
                   (options->>'hash_algorithm') || ';' ||
                   (options->>'split_fanout') || ';' ||
                   (options->>'json_normalize') || ';' ||
                   (options->>'float_signed_zero_distinct') || ';' ||
                   (options->>'float_nan_distinct') || ';' ||
                   (options->>'require_barrier') || ';' ||
                   (options->>'allow_degraded_fence')
            FROM pgl_validate.run
            WHERE run_id = {guc_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            guc_run_options,
            "2;2;off;blake3_256;3;false;false;false;false;true"
        );

        let override_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_guc'],
                '{{\"chunk_target_rows\":10}}'::jsonb
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();
        let override_chunks = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {override_run_id}
              AND table_name = {table_name}
              AND state <> 'split'
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(override_chunks, 1);

        let wide_hash_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_guc'],
                '{{\"hash_algorithm\":\"blake3_512\",\"paranoid_confirm\":true}}'::jsonb
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();
        let wide_hash_widths = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(node || ':' || octet_length(set_hash)::text, ',' ORDER BY node)
            FROM pgl_validate.table_node_result
            WHERE run_id = {wide_hash_run_id}
              AND table_name = {table_name}
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(wide_hash_widths, "local:64,remote_guc:64");

        let wide_hash_progress = Spi::get_one::<String>(&format!(
            "
            SELECT (rp.bytes_scanned = rp.rows_scanned * 64)::text || ';' ||
                   (r.options->>'hash_algorithm')
            FROM pgl_validate.run_progress rp
            JOIN pgl_validate.run r USING (run_id)
            WHERE rp.run_id = {wide_hash_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(wide_hash_progress, "true;blake3_512");

        let recheck_setting = Spi::get_one::<String>("SHOW pgl_validate.recheck_passes")
            .unwrap()
            .unwrap();
        assert_eq!(recheck_setting, "2");
        let tuple_bytes_setting =
            Spi::get_one::<String>("SHOW pgl_validate.max_reported_tuple_bytes")
                .unwrap()
                .unwrap();
        assert_eq!(tuple_bytes_setting, "8192");
        let reported_divergences_setting =
            Spi::get_one::<String>("SHOW pgl_validate.max_reported_divergences")
                .unwrap()
                .unwrap();
        assert_eq!(reported_divergences_setting, "1000");
        let statement_timeout_setting =
            Spi::get_one::<String>("SHOW pgl_validate.statement_timeout_per_chunk")
                .unwrap()
                .unwrap();
        assert_eq!(statement_timeout_setting, "30s");
        let throttle_lag_setting = Spi::get_one::<String>("SHOW pgl_validate.throttle_max_lag")
            .unwrap()
            .unwrap();
        assert_eq!(throttle_lag_setting, "off");

        Spi::run(&format!(
            r#"
            DO $pgl_validate_recheck$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"recheck_passes":0}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'recheck_passes must be greater than zero' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject recheck_passes=0';
                END IF;

                rejected := false;
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"max_reported_tuple_bytes":0}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'max_reported_tuple_bytes must be greater than zero' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject max_reported_tuple_bytes=0';
                END IF;

                rejected := false;
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"max_reported_divergences":0}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'max_reported_divergences must be greater than zero' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject max_reported_divergences=0';
                END IF;

                rejected := false;
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"hash_algorithm":"sha256_256"}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM =
                       'hash_algorithm sha256_256 is not implemented; supported values are blake3_256, blake3_512' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject unsupported hash_algorithm';
                END IF;

                rejected := false;
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"statement_timeout_per_chunk":"0s"}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'statement_timeout_per_chunk must be greater than zero' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject statement_timeout_per_chunk=0s';
                END IF;

                rejected := false;
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"throttle_max_lag":"0s"}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'throttle_max_lag must be greater than zero or off' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject throttle_max_lag=0s';
                END IF;
            END
            $pgl_validate_recheck$;
            "#
        ))
        .unwrap();

        let guc_sequence = Spi::get_one::<String>(&format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_guc']
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(guc_sequence, "ahead_of_window;false");

        let override_sequence = Spi::get_one::<String>(&format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_guc'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(override_sequence, "match;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn classify_recheck_outcome_covers_cleared_stable_and_hot_keys() {
        let outcomes = Spi::get_one::<String>(
            r#"
            WITH cases(label, previous_local, previous_peer, current_local, current_peer) AS (
                VALUES
                    ('cleared_update', '\x01'::bytea, '\x02'::bytea, '\x03'::bytea, '\x03'::bytea),
                    ('cleared_delete', '\x01'::bytea, NULL::bytea, NULL::bytea, NULL::bytea),
                    ('still_differs', '\x01'::bytea, '\x02'::bytea, '\x01'::bytea, '\x02'::bytea),
                    ('still_hot', '\x01'::bytea, '\x02'::bytea, '\x04'::bytea, '\x02'::bytea)
            )
            SELECT string_agg(
                label || ':' || pgl_validate.classify_recheck_outcome(
                    previous_local,
                    previous_peer,
                    current_local,
                    current_peer
                ),
                ',' ORDER BY label
            )
            FROM cases
            "#,
        )
        .unwrap()
        .unwrap();

        assert_eq!(
            outcomes,
            "cleared_delete:cleared,cleared_update:cleared,still_differs:still_differs,still_hot:still_hot"
        );
    }

    #[pg_test]
    fn compare_table_localizes_only_divergent_key_ranges() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_range_peer_{backend_pid}"));
        let table_name = identifier(&format!("range_diff_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, CASE WHEN g = 4 THEN 'remote-diff' ELSE 'same-' || g::text END
                 FROM generate_series(1, 5) AS g;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name}
            SELECT g, 'same-' || g::text
            FROM generate_series(1, 5) AS g;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_range_diff', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                {table_name}::regclass,
                ARRAY['remote_range_diff'],
                '{{\"chunk_target_rows\":2,\"localize_threshold\":2}}'::jsonb
            )).run_id
            ",
            table_name = sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();

        let chunk_states = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(chunk_id::text || ':' || state, ',' ORDER BY chunk_id)
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = {table_name}
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(chunk_states, "1:split,2:clean,3:divergent,4:clean");

        let divergence_keys = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(key_text || ':' || classification || ':' || status, ',' ORDER BY key_text)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
              AND node = 'remote_range_diff'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(divergence_keys, "{\"id\": 4}:differs:confirmed");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn comparison_key_cols_prefers_replica_identity_and_safe_unique_indexes() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let identity_table = identifier(&format!("pgl_validate_identity_key_{backend_pid}"));
        let identity_index = identifier(&format!("pgl_validate_identity_idx_{backend_pid}"));
        let unique_table = identifier(&format!("pgl_validate_unique_key_{backend_pid}"));
        let unique_index = identifier(&format!("pgl_validate_unique_idx_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{identity_table}(
                id int PRIMARY KEY,
                code text NOT NULL,
                value text
            );
            CREATE UNIQUE INDEX {identity_index} ON public.{identity_table}(code);
            ALTER TABLE public.{identity_table} REPLICA IDENTITY USING INDEX {identity_index};

            CREATE TABLE public.{unique_table}(
                code text NOT NULL,
                payload text
            );
            CREATE UNIQUE INDEX {unique_index} ON public.{unique_table}(code) INCLUDE (payload);
            "
        ))
        .unwrap();

        let key_summary = Spi::get_one::<String>(&format!(
            "
            SELECT array_to_string(pgl_validate.comparison_key_cols('public.{identity_table}'::regclass), ',') ||
                   ';' ||
                   array_to_string(pgl_validate.comparison_key_cols('public.{unique_table}'::regclass), ',')
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(key_summary, "code;code");
    }

    #[pg_test]
    fn compare_records_multiple_tables_under_one_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let first_table = identifier(&format!("pgl_validate_compare_a_{backend_pid}"));
        let second_table = identifier(&format!("pgl_validate_compare_b_{backend_pid}"));
        let peer_name = format!("self_parent_{backend_pid}");
        let dsn = local_dsn();

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{first_table}, public.{second_table}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{first_table} VALUES (1, 'same');
                 INSERT INTO public.{second_table} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ({peer_name}, {dsn}, 'native');
            ",
            peer_name = sql_literal(&peer_name),
            dsn = sql_literal(&dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{first_table}'::regclass,
                    'public.{second_table}'::regclass
                ],
                peers => ARRAY[{peer_name}]
            )
            ",
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();

        let run_shape = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   r.tables_total::text || ';' ||
                   r.tables_matched::text || ';' ||
                   count(tr.*)::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.run_participant rp
                    WHERE rp.run_id = r.run_id) || ';' ||
                   jsonb_array_length(pgl_validate.report(r.run_id)->'tables')::text || ';' ||
                   (SELECT chunks_done::text || '/' || chunks_total::text
                    FROM pgl_validate.run_progress rp
                    WHERE rp.run_id = r.run_id)
            FROM pgl_validate.run r
            JOIN pgl_validate.table_result tr ON tr.run_id = r.run_id
            WHERE r.run_id = {run_id}
            GROUP BY r.run_id, r.status, r.tables_total, r.tables_matched
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;2;2;2;2;2;2/2");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{first_table}, public.{second_table}"),
        );
    }

    #[pg_test]
    fn compare_expands_partitioned_root_to_leaf_results() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_partition_peer_{backend_pid}"));
        let root_table = identifier(&format!("partition_parent_{backend_pid}"));
        let first_leaf = identifier(&format!("partition_part_a_{backend_pid}"));
        let second_leaf = identifier(&format!("partition_part_b_{backend_pid}"));
        let peer_name = identifier(&format!("partition_peer_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP TABLE IF EXISTS public.{root_table} CASCADE"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();

        let table_ddl = format!(
            "
            CREATE TABLE public.{root_table}(
                id int NOT NULL,
                value text,
                PRIMARY KEY (id)
            ) PARTITION BY RANGE (id);
            CREATE TABLE public.{first_leaf}
                PARTITION OF public.{root_table} FOR VALUES FROM (0) TO (10);
            CREATE TABLE public.{second_leaf}
                PARTITION OF public.{root_table} FOR VALUES FROM (10) TO (20);
            "
        );

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 {table_ddl}
                 INSERT INTO public.{root_table} VALUES (1, 'same'), (11, 'remote-diff');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            {table_ddl}
            INSERT INTO public.{root_table} VALUES (1, 'same'), (11, 'local-diff');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ({peer_name}, {remote_dsn}, 'native');
            ",
            peer_name = sql_literal(&peer_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY['public.{root_table}'::regclass],
                peers => ARRAY[{peer_name}]
            )
            ",
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();

        let verdict_shape = Spi::get_one::<String>(&format!(
            "
            SELECT
                count(*) FILTER (WHERE table_name = {root_table} AND verdict = 'differ')::text || ';' ||
                count(*) FILTER (WHERE table_name = {first_leaf} AND verdict = 'match')::text || ';' ||
                count(*) FILTER (WHERE table_name = {second_leaf} AND verdict = 'differ')::text || ';' ||
                count(*)::text
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
            ",
            root_table = sql_literal(&root_table),
            first_leaf = sql_literal(&first_leaf),
            second_leaf = sql_literal(&second_leaf)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdict_shape, "1;1;1;3");

        let run_shape = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || tables_total::text || ';' ||
                   tables_matched::text || ';' || tables_differ::text
            FROM pgl_validate.run
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;3;1;2");

        let parent_reason = Spi::get_one::<String>(&format!(
            "
            SELECT
                (reason LIKE '%partitioned parent aggregate of 2 leaf table(s)%')::text || ';' ||
                (reason LIKE '%' || {first_leaf} || '=match%')::text || ';' ||
                (reason LIKE '%' || {second_leaf} || '=differ%')::text
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
              AND table_name = {root_table}
            ",
            root_table = sql_literal(&root_table),
            first_leaf = sql_literal(&first_leaf),
            second_leaf = sql_literal(&second_leaf)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(parent_reason, "true;true;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP TABLE IF EXISTS public.{root_table} CASCADE"),
        );
        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_records_table_error_and_continues_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let error_table = identifier(&format!("pgl_validate_error_table_{backend_pid}"));
        let good_table = identifier(&format!("pgl_validate_good_after_error_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{error_table}();
            CREATE TABLE public.{good_table}(id int PRIMARY KEY, value text);
            INSERT INTO public.{good_table} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{error_table}'::regclass,
                    'public.{good_table}'::regclass
                ],
                peers => ARRAY[]::text[]
            )
            "
        ))
        .unwrap()
        .unwrap();

        let verdicts = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(table_name || ':' || verdict, ',' ORDER BY table_name)
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdicts, format!("{error_table}:error,{good_table}:match"));

        let run_shape = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || tables_total::text || ';' ||
                   tables_matched::text || ';' || tables_differ::text
            FROM pgl_validate.run
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;2;1;0");

        let issue = Spi::get_one::<String>(&format!(
            "
            SELECT si.issue_code || ';' ||
                   (si.detail LIKE '%no comparable columns%')::text
            FROM pgl_validate.schema_issue si
            WHERE si.run_id = {run_id}
              AND si.table_name = {error_table}
            ",
            error_table = sql_literal(&error_table)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(issue, "TABLE_COMPARE_FAILED;true");
    }

    #[pg_test]
    fn compare_parent_resume_skips_completed_tables_and_retries_failed_tables() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let completed_table = identifier(&format!("pgl_validate_resume_done_{backend_pid}"));
        let retry_table = identifier(&format!("pgl_validate_resume_retry_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{completed_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{retry_table}(id int PRIMARY KEY, value text);
            INSERT INTO public.{completed_table} VALUES (1, 'same');
            INSERT INTO public.{retry_table} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            "
            INSERT INTO pgl_validate.run(status, options, tables_total)
            VALUES ('paused', '{}', 2)
            RETURNING run_id
            ",
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.table_plan(
                run_id, schema_name, table_name, key_cols, att_list, validated_property
            )
            VALUES
                (
                    {run_id}, 'public', {completed_table},
                    ARRAY['id'], ARRAY['id','value'], 'full'
                ),
                (
                    {run_id}, 'public', {retry_table},
                    ARRAY['id'], ARRAY['id','value'], 'skipped'
                );

            INSERT INTO pgl_validate.table_result(
                run_id, schema_name, table_name, verdict, reason, finished_at
            )
            VALUES
                ({run_id}, 'public', {completed_table}, 'match', 'already complete', now()),
                ({run_id}, 'public', {retry_table}, 'error', 'stale failure', now());

            INSERT INTO pgl_validate.schema_issue(
                run_id, node, schema_name, table_name, issue_code, detail
            )
            VALUES (
                {run_id}, 'local', 'public', {retry_table},
                'TABLE_COMPARE_FAILED', 'stale failure'
            );
            ",
            completed_table = sql_literal(&completed_table),
            retry_table = sql_literal(&retry_table)
        ))
        .unwrap();

        let resumed_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{completed_table}'::regclass,
                    'public.{retry_table}'::regclass
                ],
                NULL,
                ARRAY[]::text[],
                NULL::text,
                jsonb_build_object('_pgl_validate_parent_run_id', {run_id})
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(resumed_id, run_id);

        let verdicts = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(table_name || ':' || verdict, ',' ORDER BY table_name)
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            verdicts,
            format!("{completed_table}:match,{retry_table}:match")
        );

        let resume_shape = Spi::get_one::<String>(&format!(
            "
            SELECT
                r.status || ';' ||
                r.tables_total::text || ';' ||
                r.tables_matched::text || ';' ||
                r.tables_differ::text || ';' ||
                COALESCE(done.reason, '<null>') || ';' ||
                (SELECT count(*)::text
                 FROM pgl_validate.schema_issue si
                 WHERE si.run_id = r.run_id
                   AND si.table_name = {retry_table}
                   AND si.issue_code = 'TABLE_COMPARE_FAILED')
            FROM pgl_validate.run r
            JOIN pgl_validate.table_result done
              ON done.run_id = r.run_id
             AND done.schema_name = 'public'
             AND done.table_name = {completed_table}
            WHERE r.run_id = {run_id}
            ",
            completed_table = sql_literal(&completed_table),
            retry_table = sql_literal(&retry_table)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(resume_shape, "completed;2;2;0;already complete;0");
    }

    #[pg_test]
    fn compare_table_parent_resume_reuses_clean_chunk_ranges() {
        Spi::run(
            r#"
            DELETE FROM pgl_validate.peer;
            CREATE TEMP TABLE range_resume_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO range_resume_target
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 5) AS g;
            "#,
        )
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            r#"
            SELECT (pgl_validate.compare_table(
                'range_resume_target'::regclass,
                ARRAY[]::text[],
                '{"chunk_target_rows":2}'::jsonb
            )).run_id
            "#,
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.table_result
            WHERE run_id = {run_id}
              AND table_name = 'range_resume_target';

            UPDATE pgl_validate.run
            SET status = 'paused',
                finished_at = NULL,
                tables_matched = NULL,
                tables_differ = NULL
            WHERE run_id = {run_id};
            "
        ))
        .unwrap();

        let resumed_id = Spi::get_one::<i64>(&format!(
            r#"
            SELECT (pgl_validate.compare_table(
                'range_resume_target'::regclass,
                ARRAY[]::text[],
                jsonb_build_object(
                    '_pgl_validate_parent_run_id', {run_id},
                    'chunk_target_rows', 2
                )
            )).run_id
            "#
        ))
        .unwrap()
        .unwrap();
        assert_eq!(resumed_id, run_id);

        let chunk_shape = Spi::get_one::<String>(&format!(
            "
            SELECT count(*)::text || ';' ||
                   max(chunk_id)::text || ';' ||
                   count(*) FILTER (WHERE state = 'clean')::text || ';' ||
                   (
                       SELECT count(*)::text
                       FROM (
                           SELECT lo, hi, count(*)
                           FROM pgl_validate.chunk_result cr
                           WHERE cr.run_id = {run_id}
                             AND cr.table_name = 'range_resume_target'
                             AND cr.state = 'clean'
                           GROUP BY lo, hi
                           HAVING count(*) > 1
                       ) dup
                   )
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = 'range_resume_target'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(chunk_shape, "4;4;3;0");

        let verdict = Spi::get_one::<String>(&format!(
            "
            SELECT verdict
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
              AND table_name = 'range_resume_target'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "match");
    }

    #[pg_test]
    fn compare_skips_schema_drift_table_and_continues_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_schema_peer_{backend_pid}"));
        let bad_table = identifier(&format!("schema_drift_bad_{backend_pid}"));
        let good_table = identifier(&format!("schema_drift_good_{backend_pid}"));
        let peer_name = identifier(&format!("schema_drift_peer_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{bad_table}(id int PRIMARY KEY, value int);
                 CREATE TABLE public.{good_table}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{bad_table} VALUES (1, 10);
                 INSERT INTO public.{good_table} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{bad_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{good_table}(id int PRIMARY KEY, value text);
            INSERT INTO public.{bad_table} VALUES (1, '10');
            INSERT INTO public.{good_table} VALUES (1, 'same');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ({peer_name}, {remote_dsn}, 'native');
            ",
            peer_name = sql_literal(&peer_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{bad_table}'::regclass,
                    'public.{good_table}'::regclass
                ],
                peers => ARRAY[{peer_name}]
            )
            ",
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();

        let verdicts = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(table_name || ':' || verdict, ',' ORDER BY table_name)
            FROM pgl_validate.table_result
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdicts, format!("{bad_table}:skipped,{good_table}:match"));

        let run_shape = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || tables_total::text || ';' ||
                   tables_matched::text || ';' || tables_differ::text
            FROM pgl_validate.run
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;2;1;0");

        let issue = Spi::get_one::<String>(&format!(
            "
            SELECT si.issue_code || ';' ||
                   (si.detail LIKE '%type_name%')::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.table_node_result tnr
                    WHERE tnr.run_id = si.run_id
                      AND tnr.schema_name = si.schema_name
                      AND tnr.table_name = si.table_name)
            FROM pgl_validate.schema_issue si
            WHERE si.run_id = {run_id}
              AND si.table_name = {bad_table}
              AND si.node = {peer_name}
            ",
            bad_table = sql_literal(&bad_table),
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(issue, "SCHEMA_SIGNATURE_MISMATCH;true;0");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_skips_collation_drift_table_before_checksum() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_collation_peer_{backend_pid}"));
        let table_name = identifier(&format!("collation_drift_target_{backend_pid}"));
        let peer_name = identifier(&format!("collation_drift_peer_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     value text COLLATE \"POSIX\"
                 );
                 INSERT INTO public.{table_name} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                value text COLLATE \"C\"
            );
            INSERT INTO public.{table_name} VALUES (1, 'same');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ({peer_name}, {remote_dsn}, 'native');
            ",
            peer_name = sql_literal(&peer_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let result = Spi::get_one::<String>(&format!(
            "
            SELECT run_id::text || ';' || verdict || ';' ||
                   (reason LIKE '%schema precondition failed%')::text
            FROM pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[{peer_name}]
            )
            ",
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();
        let (run_id, result_tail) = result
            .split_once(';')
            .expect("compare_table result should include run id");
        assert_eq!(result_tail, "skipped;true");

        let issue = Spi::get_one::<String>(&format!(
            "
            SELECT si.issue_code || ';' ||
                   (si.detail LIKE '%collation%')::text || ';' ||
                   (si.detail LIKE '%POSIX%')::text || ';' ||
                   (si.detail LIKE '%\"C\"%')::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.table_node_result tnr
                    WHERE tnr.run_id = si.run_id
                      AND tnr.schema_name = si.schema_name
                      AND tnr.table_name = si.table_name)
            FROM pgl_validate.schema_issue si
            WHERE si.run_id = {run_id}
              AND si.table_name = {table_name_lit}
              AND si.node = {peer_name}
            ",
            table_name_lit = sql_literal(&table_name),
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(issue, "SCHEMA_SIGNATURE_MISMATCH;true;true;true;0");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_records_nondeterministic_collation_advisory() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let collation_name = identifier(&format!("pgl_validate_nondet_{backend_pid}"));
        let table_name = identifier(&format!("nondet_collation_target_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TEMP TABLE pgl_validate_nondet_probe(
                created boolean NOT NULL,
                message text
            ) ON COMMIT DROP;
            DO $pgl_validate_nondet$
            BEGIN
                EXECUTE 'DROP COLLATION IF EXISTS public.{collation_name}';
                EXECUTE 'CREATE COLLATION public.{collation_name} (provider = icu, locale = ''und-u-ks-level1'', deterministic = false)';
                INSERT INTO pgl_validate_nondet_probe VALUES (true, NULL);
            EXCEPTION WHEN others THEN
                INSERT INTO pgl_validate_nondet_probe VALUES (false, SQLERRM);
            END
            $pgl_validate_nondet$;
            "
        ))
        .unwrap();

        let created = Spi::get_one::<bool>(
            "SELECT created FROM pgl_validate_nondet_probe ORDER BY created DESC LIMIT 1",
        )
        .unwrap()
        .unwrap();
        if !created {
            return;
        }

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                value text COLLATE public.{collation_name}
            );
            INSERT INTO public.{table_name} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let compare_result = Spi::get_one::<String>(&format!(
            "
            SELECT run_id::text || ';' || verdict
            FROM pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[]::text[]
            )
            "
        ))
        .unwrap()
        .unwrap();
        let (run_id, verdict) = compare_result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "match");

        let has_advisory = Spi::get_one::<bool>(&format!(
            "
            SELECT EXISTS (
                SELECT 1
                FROM pgl_validate.schema_issue si
                WHERE si.run_id = {run_id}
                  AND si.table_name = {table_name_lit}
                  AND si.node = 'local'
                  AND si.issue_code = 'NONDETERMINISTIC_COLLATION'
                  AND si.detail LIKE {collation_like}
                  AND si.detail LIKE '%validation hashes canonical bytes%'
            )
            ",
            table_name_lit = sql_literal(&table_name),
            collation_like = sql_literal(&format!("%{collation_name}%"))
        ))
        .unwrap()
        .unwrap();
        assert!(has_advisory);
    }

    #[pg_test]
    fn remote_checksum_reads_over_libpq() {
        let dsn = local_dsn();
        let checksum_sql = "SELECT 7::bigint AS n_rows, decode('010203', 'hex') AS lthash, decode('040506', 'hex') AS set_hash";
        let sql = format!(
            "SELECT n_rows FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );

        let n_rows = Spi::get_one::<i64>(&sql).unwrap().unwrap();
        assert_eq!(n_rows, 7);

        let sql = format!(
            "SELECT lthash FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );
        let lthash = Spi::get_one::<Vec<u8>>(&sql).unwrap().unwrap();
        assert_eq!(lthash, vec![0x01, 0x02, 0x03]);

        let sql = format!(
            "SELECT set_hash FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );
        let set_hash = Spi::get_one::<Vec<u8>>(&sql).unwrap().unwrap();
        assert_eq!(set_hash, vec![0x04, 0x05, 0x06]);
    }

    #[pg_test]
    fn remote_checksum_batch_reads_over_bounded_libpq_fanout() {
        let dsn = local_dsn();
        let sql = format!(
            "
            SELECT string_agg(
                       task_id::text || ':' || n_rows::text || ':' || encode(lthash, 'hex'),
                       ',' ORDER BY task_id
                   )
            FROM pgl_validate.remote_checksum_batch(
                jsonb_build_array(
                    jsonb_build_object(
                        'task_id', 1,
                        'dsn', {dsn},
                        'checksum_sql', 'SELECT 11::bigint AS n_rows, decode(''0a'', ''hex'') AS lthash, NULL::bytea AS set_hash',
                        'connect_timeout_seconds', 10,
                        'statement_timeout_ms', 600000,
                        'lock_timeout_ms', 30000
                    ),
                    jsonb_build_object(
                        'task_id', 2,
                        'dsn', {dsn},
                        'checksum_sql', 'SELECT 12::bigint AS n_rows, decode(''0b'', ''hex'') AS lthash, NULL::bytea AS set_hash',
                        'connect_timeout_seconds', 10,
                        'statement_timeout_ms', 600000,
                        'lock_timeout_ms', 30000
                    )
                ),
                2
            )
            ",
            dsn = sql_literal(&dsn)
        );

        let summary = Spi::get_one::<String>(&sql).unwrap().unwrap();
        assert_eq!(summary, "1:11:0a,2:12:0b");
    }

    #[pg_test]
    fn remote_checksum_batch_runs_tasks_concurrently_when_parallelism_allows() {
        let dsn = local_dsn();
        let lock_key = 904_209_i64;

        let concurrent_sql = format!(
            "
            SELECT n_rows
            FROM pgl_validate.remote_checksum_batch(
                jsonb_build_array(
                    jsonb_build_object(
                        'task_id', 1,
                        'dsn', {dsn},
                        'checksum_sql', format(
                            'WITH held AS (SELECT pg_advisory_lock(%s) AS locked),
                                  waited AS (SELECT pg_sleep(0.5) FROM held)
                             SELECT 1::bigint AS n_rows, decode(''01'', ''hex'') AS lthash, NULL::bytea AS set_hash
                             FROM waited',
                            {lock_key}
                        ),
                        'connect_timeout_seconds', 10,
                        'statement_timeout_ms', 600000,
                        'lock_timeout_ms', 30000
                    ),
                    jsonb_build_object(
                        'task_id', 2,
                        'dsn', {dsn},
                        'checksum_sql', format(
                            'WITH waited AS (SELECT pg_sleep(0.1) AS slept),
                                  probe AS (SELECT pg_try_advisory_lock(%s) AS got_lock FROM waited)
                             SELECT CASE WHEN got_lock THEN 1 ELSE 2 END::bigint AS n_rows,
                                    decode(''02'', ''hex'') AS lthash,
                                    NULL::bytea AS set_hash
                             FROM probe',
                            {lock_key}
                        ),
                        'connect_timeout_seconds', 10,
                        'statement_timeout_ms', 600000,
                        'lock_timeout_ms', 30000
                    )
                ),
                2
            )
            WHERE task_id = 2
            ",
            dsn = sql_literal(&dsn),
            lock_key = lock_key
        );

        let concurrent_probe = Spi::get_one::<i64>(&concurrent_sql).unwrap().unwrap();
        assert_eq!(concurrent_probe, 2);

        let serial_sql = concurrent_sql.replace(
            "                2\n            )",
            "                1\n            )",
        );
        let serial_probe = Spi::get_one::<i64>(&serial_sql).unwrap().unwrap();
        assert_eq!(serial_probe, 1);
    }

    #[pg_test]
    fn remote_inject_barrier_returns_visible_token_and_lsn() {
        let dsn = local_dsn();
        let sql = format!(
            "
            SELECT token::text || ';' || barrier_end_lsn::text
            FROM pgl_validate.remote_inject_barrier({})
            ",
            sql_literal(&dsn)
        );
        let injected = Spi::get_one::<String>(&sql).unwrap().unwrap();
        let (token, barrier_end_lsn) = injected
            .split_once(';')
            .expect("barrier result should contain token and LSN");

        let visible_sql = format!(
            "
            SELECT EXISTS (
                       SELECT 1
                       FROM pgl_validate.fence_barrier
                       WHERE token = {}::uuid
                   )
                   AND {}::pg_lsn <= pg_current_wal_lsn()
            ",
            sql_literal(token),
            sql_literal(barrier_end_lsn)
        );
        let valid = Spi::get_one::<bool>(&visible_sql).unwrap().unwrap();
        assert!(valid);
    }

    #[pg_test]
    fn throttle_replication_lag_times_out_for_inactive_slot() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let slot_name = identifier(&format!("pgl_validate_lag_{backend_pid}"));
        let dsn = local_dsn();

        Spi::run(&format!(
            "
            SELECT pg_drop_replication_slot(slot_name)
            FROM pg_replication_slots
            WHERE slot_name = {slot_name};
            SELECT pg_create_physical_replication_slot({slot_name});
            ",
            slot_name = sql_literal(&slot_name)
        ))
        .unwrap();

        let lag_probe = Spi::get_one::<String>(&format!(
            "
            SELECT active::text || ';' || lag_ms::text || ';' || lag_bytes::text
            FROM pgl_validate.remote_logical_slot_lag({}, {})
            ",
            sql_literal(&dsn),
            sql_literal(&slot_name)
        ))
        .unwrap()
        .unwrap();
        let lag_parts: Vec<_> = lag_probe.split(';').collect();
        assert_eq!(lag_parts[0], "false");
        assert_eq!(lag_parts[1], "0");
        assert!(
            lag_parts[2].parse::<i64>().unwrap() >= 0,
            "lag_bytes should be nonnegative: {lag_probe}"
        );

        Spi::run(&format!(
            "
            DO $pgl_validate_throttle$
            DECLARE
                v_run_id bigint;
            BEGIN
                INSERT INTO pgl_validate.run(status)
                VALUES ('running')
                RETURNING run_id INTO v_run_id;

                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                VALUES (
                    v_run_id, 1, 'local', 'peer', 'pglogical',
                    'sub', {slot_name}, 'origin', ARRAY['default']
                );

                BEGIN
                    PERFORM pgl_validate.throttle_replication_lag(
                        v_run_id,
                        'public',
                        'lag_target',
                        'local',
                        {dsn},
                        ARRAY[1],
                        interval '1 millisecond',
                        1,
                        1
                    );
                EXCEPTION
                    WHEN query_canceled THEN
                        IF SQLERRM LIKE 'replication lag remained above throttle_max_lag%' THEN
                            RETURN;
                        END IF;
                        RAISE;
                    WHEN others THEN
                        IF SQLERRM LIKE 'replication lag remained above throttle_max_lag%' THEN
                            RETURN;
                        END IF;
                        RAISE;
                END;

                RAISE EXCEPTION 'expected throttle_replication_lag to time out';
            END
            $pgl_validate_throttle$;
            ",
            dsn = sql_literal(&dsn),
            slot_name = sql_literal(&slot_name)
        ))
        .unwrap();

        Spi::run(&format!(
            "SELECT pg_drop_replication_slot({})",
            sql_literal(&slot_name)
        ))
        .unwrap();
    }

    #[pg_test]
    fn record_barrier_fence_persists_epoch_edge_and_protected_token() {
        let dsn = local_dsn();
        let sql = format!(
            "
            WITH run AS (
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING run_id
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                SELECT run_id, 1, 'origin', 'target', 'pglogical',
                       'sub', 'slot', 'origin_name', ARRAY['default']
                FROM run
                RETURNING run_id, edge_id
            ), injected AS (
                SELECT * FROM pgl_validate.remote_inject_barrier({})
            ), recorded AS (
                SELECT pgl_validate.record_barrier_fence(
                    edge.run_id,
                    1,
                    edge.edge_id,
                    injected.token,
                    'origin',
                    injected.barrier_end_lsn
                )
                FROM edge, injected
            )
            SELECT edge.run_id::text || ';' ||
                   injected.token::text || ';' ||
                   injected.barrier_end_lsn::text
            FROM edge, injected, recorded
            ",
            sql_literal(&dsn)
        );
        let recorded_values = Spi::get_one::<String>(&sql).unwrap().unwrap();
        let mut parts = recorded_values.split(';');
        let run_id = parts.next().expect("run id should be present");
        let token = parts.next().expect("token should be present");
        let barrier_end_lsn = parts.next().expect("barrier LSN should be present");

        let verify_sql = format!(
            "
            SELECT EXISTS (
                       SELECT 1
                       FROM pgl_validate.fence_edge
                       WHERE run_id = {}
                         AND fence_kind = 'barrier'
                         AND barrier_token = {}::uuid
                         AND barrier_end_lsn = {}::pg_lsn
                   )
                   AND {}::uuid = ANY (pgl_validate.protected_barrier_tokens())
            ",
            run_id,
            sql_literal(token),
            sql_literal(barrier_end_lsn),
            sql_literal(token)
        );
        let recorded = Spi::get_one::<bool>(&verify_sql).unwrap().unwrap();
        assert!(recorded);
    }

    #[pg_test]
    fn re_fence_run_edges_noops_empty_vector_and_requires_known_peers() {
        Spi::run(
            "
            DO $pgl_validate_re_fence$
            DECLARE
                v_run_id bigint;
                v_re_fenced int;
            BEGIN
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING run_id INTO v_run_id;

                SELECT pgl_validate.re_fence_run_edges(
                    v_run_id,
                    1,
                    'local',
                    NULL,
                    ARRAY[]::int[],
                    1,
                    1
                )
                INTO v_re_fenced;

                IF v_re_fenced <> 0 THEN
                    RAISE EXCEPTION 'expected empty edge vector to re-fence zero edges, got %', v_re_fenced;
                END IF;

                IF NOT EXISTS (
                    SELECT 1
                    FROM pgl_validate.fence_epoch
                    WHERE run_id = v_run_id
                      AND epoch_seq = 1
                ) THEN
                    RAISE EXCEPTION 'empty re-fence did not persist its epoch';
                END IF;

                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                VALUES (
                    v_run_id, 1, 'local', 'missing_peer', 'native',
                    'sub', 'slot', 'origin', ARRAY['pgl_validate_barrier']
                );

                BEGIN
                    PERFORM pgl_validate.re_fence_run_edges(
                        v_run_id,
                        2,
                        'local',
                        'dbname=' || current_database(),
                        ARRAY[1],
                        1,
                        1
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'cannot re-fence edge 1, target peer missing_peer was not found' THEN
                        RETURN;
                    END IF;
                    RAISE;
                END;

                RAISE EXCEPTION 'expected re_fence_run_edges to reject an unknown target peer';
            END
            $pgl_validate_re_fence$;
            ",
        )
        .unwrap();
    }

    #[pg_test]
    fn remote_observe_barrier_reports_origin_progress_and_token_visibility() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let origin_name = identifier(&format!("pgl_validate_origin_{backend_pid}"));

        let injected_sql = format!(
            "
            SELECT token::text || ';' || barrier_end_lsn::text
            FROM pgl_validate.remote_inject_barrier({})
            ",
            sql_literal(&dsn)
        );
        let injected = Spi::get_one::<String>(&injected_sql).unwrap().unwrap();
        let (token, barrier_end_lsn) = injected
            .split_once(';')
            .expect("barrier result should contain token and LSN");

        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_create({}); END $$",
                sql_literal(&origin_name)
            ),
        )
        .unwrap();
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_advance({}, {}::pg_lsn); END $$",
                sql_literal(&origin_name),
                sql_literal(barrier_end_lsn)
            ),
        )
        .unwrap();

        let observe_sql = format!(
            "
            SELECT token_visible::text || ';' ||
                   converged::text || ';' ||
                   (origin_progress_lsn >= {}::pg_lsn)::text
            FROM pgl_validate.remote_observe_barrier(
                {},
                {},
                {}::uuid,
                {}::pg_lsn
            )
            ",
            sql_literal(barrier_end_lsn),
            sql_literal(&dsn),
            sql_literal(&origin_name),
            sql_literal(token),
            sql_literal(barrier_end_lsn)
        );
        let observed = Spi::get_one::<String>(&observe_sql).unwrap().unwrap();
        assert_eq!(observed, "true;true;true");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_drop({}); END $$",
                sql_literal(&origin_name)
            ),
        );
    }

    #[pg_test]
    fn remote_standby_replay_status_reports_primary_not_in_recovery() {
        let dsn = local_dsn();
        let status = Spi::get_one::<String>(&format!(
            "
            SELECT (pg_version > 0)::text || ';' ||
                   in_recovery::text || ';' ||
                   replay_lsn::text || ';' ||
                   replay_paused::text
            FROM pgl_validate.remote_standby_replay_status({})
            ",
            sql_literal(&dsn)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(status, "true;false;0/0;false");
    }

    #[pg_test]
    fn remote_standby_replay_lag_reports_primary_not_in_recovery() {
        let dsn = local_dsn();
        let status = Spi::get_one::<String>(&format!(
            "
            SELECT in_recovery::text || ';' ||
                   replay_lsn::text || ';' ||
                   lag_ms::text
            FROM pgl_validate.remote_standby_replay_lag({}, pg_current_wal_lsn())
            ",
            sql_literal(&dsn)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(status, "false;0/0;0");
    }

    #[pg_test]
    fn throttle_standby_lag_rejects_primary_peer() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_name = identifier(&format!("standby_lag_primary_{backend_pid}"));

        Spi::run(&format!(
            "
            DO $pgl_validate_standby_throttle$
            DECLARE
                v_run_id bigint;
            BEGIN
                INSERT INTO pgl_validate.peer(name, dsn, backend)
                VALUES ({peer_name}, {dsn}, 'standby');

                INSERT INTO pgl_validate.run(status)
                VALUES ('running')
                RETURNING run_id INTO v_run_id;

                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                VALUES (
                    v_run_id, 1, 'local', {peer_name}, 'standby',
                    NULL, NULL, NULL, NULL
                );

                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                VALUES (v_run_id, 1);

                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
                )
                VALUES (v_run_id, 1, 1, 'standby_replay', NULL, pg_current_wal_lsn());

                BEGIN
                    PERFORM pgl_validate.throttle_replication_lag(
                        v_run_id,
                        'public',
                        'standby_lag_target',
                        'local',
                        {dsn},
                        ARRAY[1],
                        interval '1 millisecond',
                        1,
                        1
                    );
                EXCEPTION
                    WHEN others THEN
                        IF SQLERRM = format('standby peer %s is not in recovery', {peer_name}) THEN
                            RETURN;
                        END IF;
                        RAISE;
                END;

                RAISE EXCEPTION 'expected standby throttle to reject a primary peer';
            END
            $pgl_validate_standby_throttle$;
            ",
            dsn = sql_literal(&dsn),
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap();

        Spi::run(&format!(
            "DELETE FROM pgl_validate.peer WHERE name = {}",
            sql_literal(&peer_name)
        ))
        .unwrap();
    }

    #[pg_test]
    fn fence_standby_edge_rejects_primary_peer() {
        let dsn = local_dsn();
        let sql = format!(
            "
            DO $$
            DECLARE
                run_id bigint;
            BEGIN
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING pgl_validate.run.run_id INTO run_id;

                BEGIN
                    PERFORM pgl_validate.fence_standby_edge(
                        run_id,
                        1,
                        1,
                        'local',
                        'primary_peer',
                        {},
                        pg_current_wal_lsn(),
                        10,
                        10000,
                        10000,
                        100,
                        10
                    );
                    RAISE EXCEPTION 'expected primary peer to be rejected';
                EXCEPTION WHEN SQLSTATE '0A000' THEN
                    IF SQLERRM <> 'standby peer primary_peer is not in recovery' THEN
                        RAISE;
                    END IF;
                END;
            END
            $$;
            ",
            sql_literal(&dsn)
        );

        Spi::run(&sql).unwrap();
    }

    #[pg_test]
    fn compare_table_autodetects_standby_backend_and_fails_closed_on_primary_peer() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_standby_detect_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('standby_primary', {}, 'standby');
            ",
            sql_literal(&dsn)
        ))
        .unwrap();

        let compare_sql = format!(
            "
            DO $$
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table('public.{table_name}'::regclass);
                    RAISE EXCEPTION 'expected standby peer to require replay fencing';
                EXCEPTION WHEN SQLSTATE '0A000' THEN
                    IF SQLERRM <> 'standby peer standby_primary is not in recovery' THEN
                        RAISE;
                    END IF;
                END;
            END
            $$;
            "
        );
        Spi::run(&compare_sql).unwrap();

        Spi::run("DELETE FROM pgl_validate.peer WHERE name = 'standby_primary'").unwrap();
    }

    #[pg_test]
    fn record_fence_attempt_derives_converged_and_waiting_statuses() {
        let converged = Spi::get_one::<bool>(
            r#"
            WITH run AS (
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING run_id
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                SELECT run_id, 1, 'origin', 'target', 'pglogical',
                       'sub', 'slot', 'origin_name', ARRAY['default']
                FROM run
                RETURNING run_id, edge_id
            ), fence AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM run
                RETURNING run_id, epoch_seq
            ), fence_edge AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
                )
                SELECT edge.run_id, 1, edge.edge_id, 'barrier',
                       '66666666-6666-6666-6666-666666666666'::uuid,
                       '0/20'::pg_lsn
                FROM edge
                RETURNING run_id, epoch_seq, edge_id
            ), attempt AS (
                SELECT pgl_validate.record_fence_attempt(
                    run_id, epoch_seq, edge_id,
                    '0/20'::pg_lsn,
                    '0/20'::pg_lsn,
                    true,
                    '0/20'::pg_lsn
                ) AS row
                FROM fence_edge
            )
            SELECT ((row).status = 'converged' AND (row).converged_at IS NOT NULL)
            FROM attempt
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(converged);

        let waiting = Spi::get_one::<bool>(
            r#"
            WITH latest AS (
                SELECT run_id, epoch_seq, edge_id
                FROM pgl_validate.fence_edge
                WHERE barrier_token = '66666666-6666-6666-6666-666666666666'::uuid
            ), attempt AS (
                SELECT pgl_validate.record_fence_attempt(
                    run_id, epoch_seq, edge_id,
                    '0/20'::pg_lsn,
                    '0/10'::pg_lsn,
                    true,
                    '0/20'::pg_lsn
                ) AS row
                FROM latest
            )
            SELECT ((row).status = 'waiting' AND (row).converged_at IS NULL)
            FROM attempt
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(waiting);
    }

    #[pg_test]
    fn native_barrier_publication_is_insert_only() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let publication_name = identifier(&format!("pgl_validate_native_barrier_{backend_pid}"));

        Spi::run(&format!("DROP PUBLICATION IF EXISTS {publication_name}")).unwrap();
        Spi::run(&format!(
            "SELECT pgl_validate.ensure_native_barrier_publication({})",
            sql_literal(&publication_name)
        ))
        .unwrap();

        let publication = Spi::get_one::<String>(&format!(
            "
            SELECT p.pubinsert::text || ';' ||
                   p.pubupdate::text || ';' ||
                   p.pubdelete::text || ';' ||
                   p.pubtruncate::text || ';' ||
                   EXISTS (
                       SELECT 1
                       FROM pg_publication_tables pt
                       WHERE pt.pubname = p.pubname
                         AND pt.schemaname = 'pgl_validate'
                         AND pt.tablename = 'fence_barrier'
                   )::text
            FROM pg_publication p
            WHERE p.pubname = {}::name
            ",
            sql_literal(&publication_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(publication, "true;false;false;false;true");

        Spi::run(&format!("DROP PUBLICATION IF EXISTS {publication_name}")).unwrap();
    }

    #[pg_test]
    fn native_barrier_publication_rejects_wrong_action_mask() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let publication_name =
            identifier(&format!("pgl_validate_native_bad_barrier_{backend_pid}"));

        Spi::run(&format!("DROP PUBLICATION IF EXISTS {publication_name}")).unwrap();
        Spi::run(&format!(
            "CREATE PUBLICATION {publication_name}
             FOR TABLE pgl_validate.fence_barrier
             WITH (publish = 'insert, update')"
        ))
        .unwrap();

        let rejected = Spi::get_one::<bool>(&format!(
            "
            DO $$
            BEGIN
                PERFORM pgl_validate.ensure_native_barrier_publication({});
                RAISE EXCEPTION 'expected native publication action-mask rejection';
            EXCEPTION WHEN others THEN
                IF SQLERRM = {} THEN
                    RETURN;
                END IF;
                RAISE;
            END
            $$;
            SELECT true
            ",
            sql_literal(&publication_name),
            sql_literal(&format!(
                "native publication {publication_name} exists but is not insert-only"
            ))
        ))
        .unwrap()
        .unwrap();
        assert!(rejected);

        Spi::run(&format!("DROP PUBLICATION IF EXISTS {publication_name}")).unwrap();
    }

    #[pg_test]
    fn compare_table_skip_peer_fence_timeout_handles_native_subscription_peer() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("native_skip_peer_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_skip_{backend_pid}"));
        let dsn = local_dsn();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            CREATE PUBLICATION {publication_name} FOR TABLE public.{table_name};
            INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
            VALUES (
                'unreachable_native',
                'host=127.0.0.1 port=1 dbname=missing',
                'native',
                'native_sub',
                ARRAY[{publication}]
            );
            ",
            publication = sql_literal(&publication_name)
        ))
        .unwrap();

        let result = Spi::get_one::<String>(&format!(
            "
            SELECT (r).run_id::text || ';' || (r).verdict
            FROM (
                SELECT pgl_validate.compare_table(
                    'public.{table_name}'::regclass,
                    ARRAY['unreachable_native'],
                    jsonb_build_object(
                        'backend', 'native',
                        'publications', jsonb_build_array({publication}),
                        'provider_dsn', {provider_dsn},
                        'provider_node', 'local',
                        'on_fence_timeout', 'skip_peer'
                    )
                ) AS r
            ) s
            ",
            publication = sql_literal(&publication_name),
            provider_dsn = sql_literal(&dsn)
        ))
        .unwrap()
        .unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "partial");

        let persisted = Spi::get_one::<String>(&format!(
            "
            SELECT rp.status || ';' || si.issue_code || ';' ||
                   (tr.reason LIKE '%on_fence_timeout=skip_peer%')::text
            FROM pgl_validate.run_participant rp
            JOIN pgl_validate.schema_issue si
              ON si.run_id = rp.run_id
             AND si.node = rp.node
            JOIN pgl_validate.table_result tr
              ON tr.run_id = rp.run_id
            WHERE rp.run_id = {run_id}
              AND rp.node = 'unreachable_native'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(persisted, "unreachable;PEER_SKIPPED;true");
    }

    #[pg_test]
    fn native_contract_uses_publication_columns_filters_and_actions() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("native_contract_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_pub_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name} (id, kept)
            WHERE (id > 0);
            "
        ))
        .unwrap();

        let contract = Spi::get_one::<String>(&format!(
            "
            SELECT array_to_string(att_list, ',') || ';' ||
                   validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   has_row_filter::text || ';' ||
                   repl_insert::text || ';' ||
                   repl_update::text || ';' ||
                   repl_delete::text || ';' ||
                   repl_truncate::text
            FROM pgl_validate.native_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{publication}]
            )
            ",
            publication = sql_literal(&publication_name)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(contract, "id,kept;full;true;true;true;true;true;true");
    }

    #[pg_test]
    fn native_contract_skips_incompatible_column_lists() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("native_column_conflict_{backend_pid}"));
        let first_publication = identifier(&format!("pgl_validate_native_cols_a_{backend_pid}"));
        let second_publication = identifier(&format!("pgl_validate_native_cols_b_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept_a text,
                kept_b text
            );
            CREATE PUBLICATION {first_publication}
            FOR TABLE public.{table_name} (id, kept_a);
            CREATE PUBLICATION {second_publication}
            FOR TABLE public.{table_name} (id, kept_b);
            "
        ))
        .unwrap();

        let contract = Spi::get_one::<String>(&format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   (reason LIKE '%incompatible column lists%')::text
            FROM pgl_validate.native_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{first_publication},{second_publication}]
            )
            ",
            first_publication = sql_literal(&first_publication),
            second_publication = sql_literal(&second_publication)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(contract, "skipped;false;true");
    }

    #[pg_test]
    fn compare_table_uses_registered_remote_peer_match() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("self_compare_target_{backend_pid}"));

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ('self_peer', {}, 'native')",
            sql_literal(&dsn)
        ))
        .unwrap();

        let result_sql = format!(
            "SELECT (r).run_id::text || ';' || (r).verdict FROM (
                SELECT pgl_validate.compare_table(
                    {}::regclass,
                    NULL,
                    '{{\"paranoid_confirm\":true}}'::jsonb
                ) AS r
             ) s",
            sql_literal(&format!("public.{table_name}"))
        );
        let result = Spi::get_one::<String>(&result_sql).unwrap().unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "match");

        let participants = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.run_participant WHERE node IN ('local', 'self_peer')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(participants, 2);

        let confirmed_nodes = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.table_node_result
            WHERE run_id = {run_id}
              AND node IN ('local', 'self_peer')
              AND set_hash IS NOT NULL
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(confirmed_nodes, 2);
    }

    #[pg_test]
    fn compare_table_bounds_clean_paranoid_confirmation_by_key_range() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("bounded_paranoid_target_{backend_pid}"));

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, 'same-' || g::text
                 FROM generate_series(1, 5) AS g;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('self_bounded_paranoid', {}, 'native');
            ",
            sql_literal(&dsn)
        ))
        .unwrap();

        let result = Spi::get_one::<String>(&format!(
            "
            SELECT (r).run_id::text || ';' || (r).verdict
            FROM (
                SELECT pgl_validate.compare_table(
                    {}::regclass,
                    ARRAY['self_bounded_paranoid'],
                    '{{\"paranoid_confirm\":true,\"paranoid_confirm_max_rows\":2,\"chunk_target_rows\":10}}'::jsonb
                ) AS r
            ) s
            ",
            sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "match");

        let chunk_shape = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(chunk_id::text || ':' || state, ',' ORDER BY chunk_id)
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = {table_name}
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(chunk_shape, "1:split,2:clean,3:clean,4:clean");

        let largest_confirmed_range = Spi::get_one::<i64>(&format!(
            "
            SELECT max(cnr.n_rows)
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = {table_name}
              AND cr.parent_id = 1
              AND cnr.node = 'local'
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(largest_confirmed_range, 2);

        let root_set_hashes = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.table_node_result
            WHERE run_id = {run_id}
              AND table_name = {table_name}
              AND set_hash IS NOT NULL
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(root_set_hashes, 0);

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
    }

    #[pg_test]
    fn compare_table_fails_closed_for_oversized_keyless_paranoid_confirmation() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("keyless_paranoid_target_{backend_pid}"));

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{table_name}(value text);
                 INSERT INTO public.{table_name}
                 SELECT 'same-' || g::text
                 FROM generate_series(1, 3) AS g;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('self_keyless_paranoid', {}, 'native');
            ",
            sql_literal(&dsn)
        ))
        .unwrap();

        let result = Spi::get_one::<String>(&format!(
            "
            SELECT (r).run_id::text || ';' || (r).verdict
            FROM (
                SELECT pgl_validate.compare_table(
                    {}::regclass,
                    ARRAY['self_keyless_paranoid'],
                    '{{\"paranoid_confirm\":true,\"paranoid_confirm_max_rows\":2}}'::jsonb
                ) AS r
            ) s
            ",
            sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "indeterminate");

        let issue = Spi::get_one::<bool>(&format!(
            "
            SELECT EXISTS (
                SELECT 1
                FROM pgl_validate.schema_issue
                WHERE run_id = {run_id}
                  AND table_name = {table_name}
                  AND issue_code = 'PARANOID_CONFIRM_REQUIRES_KEY'
            )
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert!(issue);

        let run_counts = Spi::get_one::<String>(&format!(
            "
            SELECT tables_matched::text || ';' || tables_differ::text
            FROM pgl_validate.run
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_counts, "0;0");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
    }

    #[pg_test]
    fn compare_table_refuses_unfenced_pglogical_peer() {
        Spi::run(
            "
            CREATE TABLE unfenced_pglogical_peer(id int PRIMARY KEY, value text);
            INSERT INTO unfenced_pglogical_peer VALUES (1, 'same');
            INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name)
            VALUES ('pglogical_without_provider', 'dbname=' || current_database(), 'pglogical', 'sub');
            ",
        )
        .unwrap();

        Spi::run(
            r#"
            DO $$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table('unfenced_pglogical_peer'::regclass);
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'options.provider_dsn is required when comparing pglogical peers' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject an unfenced pglogical peer';
                END IF;
            END
            $$;
            "#,
        )
        .unwrap();
    }

    #[pg_test]
    fn compare_table_skip_peer_fence_timeout_returns_partial() {
        let dsn = local_dsn();

        Spi::run(&format!(
            "
            CREATE TABLE skip_peer_timeout_target(id int PRIMARY KEY, value text);
            INSERT INTO skip_peer_timeout_target VALUES (1, 'same');
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(
                name,
                dsn,
                backend,
                subscription_name,
                connect_timeout_seconds,
                statement_timeout_ms,
                lock_timeout_ms
            )
            VALUES (
                'unreachable_pglogical',
                'host=127.0.0.1 port=1 dbname=postgres',
                'pglogical',
                'sub',
                1,
                1000,
                1000
            );
            ",
        ))
        .unwrap();

        let result = Spi::get_one::<String>(&format!(
            "
            SELECT (r).run_id::text || ';' || (r).verdict
            FROM (
                SELECT pgl_validate.compare_table(
                    'skip_peer_timeout_target'::regclass,
                    ARRAY['unreachable_pglogical'],
                    jsonb_build_object(
                        'provider_dsn', {provider_dsn},
                        'provider_node', 'local',
                        'on_fence_timeout', 'skip_peer'
                    )
                ) AS r
            ) s
            ",
            provider_dsn = sql_literal(&dsn)
        ))
        .unwrap()
        .unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "partial");

        let persisted = Spi::get_one::<String>(&format!(
            "
            SELECT rp.status || ';' || si.issue_code || ';' ||
                   (tr.reason LIKE '%on_fence_timeout=skip_peer%')::text
            FROM pgl_validate.run_participant rp
            JOIN pgl_validate.schema_issue si
              ON si.run_id = rp.run_id
             AND si.node = rp.node
            JOIN pgl_validate.table_result tr
              ON tr.run_id = rp.run_id
            WHERE rp.run_id = {run_id}
              AND rp.node = 'unreachable_pglogical'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(persisted, "unreachable;PEER_SKIPPED;true");
    }

    #[pg_test]
    fn compare_table_reports_registered_remote_peer_difference() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_peer_{backend_pid}"));
        let table_name = identifier(&format!("remote_compare_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'remote'),
                     (2, 'remote-only');"
            ),
        )
        .unwrap();

        crate::transport::libpq::execute_command(
            &local_dsn,
            &format!(
                "DROP TABLE IF EXISTS public.{table_name};
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'local'),
                     (3, 'local-only');"
            ),
        )
        .unwrap();
        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer WHERE name IN ('local', 'remote_diff');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_diff', {}, 'native');
            ",
            sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).run_id",
            sql_literal(&format!("public.{table_name}"))
        );
        let run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();

        let verdict = Spi::get_one::<String>(&format!(
            "SELECT verdict FROM pgl_validate.table_result WHERE run_id = {run_id}"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "differ");

        let remote_rows = Spi::get_one::<i64>(
            "SELECT n_rows FROM pgl_validate.table_node_result WHERE node = 'remote_diff'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(remote_rows, 2);

        let root_chunk = Spi::get_one::<String>(&format!(
            "
            SELECT cr.state || ';' || count(cnr.*)::text
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = {table_name}
              AND cr.chunk_id = 1
            GROUP BY cr.state
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(root_chunk, "divergent;2");

        let divergence_summary = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(classification || ':' || status, ',' ORDER BY classification)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
              AND node = 'remote_diff'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            divergence_summary,
            "differs:confirmed,extra_on:confirmed,missing_on:confirmed"
        );

        let tuple_values = Spi::get_one::<String>(&format!(
            "
            SELECT (d.tuple->'local'->>'value') || ';' || (d.tuple->'peer'->>'value')
            FROM pgl_validate.divergence d
            WHERE d.run_id = {run_id}
              AND d.classification = 'differs'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(tuple_values, "local;remote");

        let repair_batch = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(stmt, E'\\n' ORDER BY stmt)
            FROM pgl_validate.generate_repair({run_id}, 'local') AS stmt
            "
        ))
        .unwrap()
        .unwrap();
        assert!(repair_batch.contains("/* target: 'remote_diff' */ UPDATE"));
        assert!(repair_batch.contains("/* target: 'remote_diff' */ INSERT"));
        assert!(repair_batch.contains("/* target: 'remote_diff' */ DELETE"));

        let repair_count_before_replicate_ack =
            Spi::get_one::<i64>("SELECT count(*) FROM pgl_validate.repair_run")
                .unwrap()
                .unwrap();
        Spi::run(&format!(
            "
            DO $$
            BEGIN
                PERFORM pgl_validate.apply_repair(
                    {run_id},
                    'local',
                    'remote_diff',
                    'remote_diff',
                    'replicate',
                    false
                );
                RAISE EXCEPTION 'expected unacknowledged replicate repair to fail';
            EXCEPTION WHEN invalid_parameter_value THEN
                IF SQLERRM <> 'replicate repair requires acknowledge_conflict_policy = true' THEN
                    RAISE;
                END IF;
            END
            $$
            "
        ))
        .unwrap();
        let repair_count_after_replicate_ack =
            Spi::get_one::<i64>("SELECT count(*) FROM pgl_validate.repair_run")
                .unwrap()
                .unwrap();
        assert_eq!(
            repair_count_before_replicate_ack,
            repair_count_after_replicate_ack
        );

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status || ';' || propagation || ';' || (origin_name IS NULL)::text
            FROM pgl_validate.apply_repair(
                {run_id},
                'local',
                'remote_diff',
                'remote_diff',
                'replicate',
                true
            )
            "
        ))
        .unwrap()
        .unwrap();
        let mut repair_status_parts = repair_status.split(';');
        let repair_id = repair_status_parts
            .next()
            .expect("repair status should include id");
        let repair_status = repair_status_parts
            .next()
            .expect("repair status should include status");
        let propagation = repair_status_parts
            .next()
            .expect("repair status should include propagation");
        let origin_is_null = repair_status_parts
            .next()
            .expect("repair status should include origin null flag");
        assert_eq!(repair_status, "revalidated");
        assert_eq!(propagation, "replicate");
        assert_eq!(origin_is_null, "true");
        assert!(
            repair_status_parts.next().is_none(),
            "repair status should not include extra fields"
        );

        let repair_actions = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(action, ',' ORDER BY action)
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(repair_actions, "delete,insert,update");

        let repaired_verdict_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).verdict",
            sql_literal(&format!("public.{table_name}"))
        );
        let repaired_verdict = Spi::get_one::<String>(&repaired_verdict_sql)
            .unwrap()
            .unwrap();
        assert_eq!(repaired_verdict, "match");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!("INSERT INTO public.{table_name} VALUES (5, 'remote-added')"),
        )
        .unwrap();

        crate::transport::libpq::execute_command(
            &local_dsn,
            &format!(
                "
                UPDATE public.{table_name}
                SET value = 'local-stale'
                WHERE id = 1;
                INSERT INTO public.{table_name}
                VALUES (4, 'local-extra');
                "
            ),
        )
        .unwrap();

        let local_drift_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let local_drift_verdict = Spi::get_one::<String>(&format!(
            "SELECT verdict FROM pgl_validate.table_result WHERE run_id = {local_drift_run_id}"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(local_drift_verdict, "differ");

        let missing_loopback = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || COALESCE(error, '')
            FROM pgl_validate.apply_repair(
                {local_drift_run_id},
                'remote_diff',
                'local',
                'local'
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            missing_loopback,
            "failed;local_only repair target local requires pgl_validate.peer row named local so the origin-aware repair transaction can run over libpq"
        );

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('local', {local_dsn}, 'native')
            ON CONFLICT (name) DO UPDATE
            SET dsn = EXCLUDED.dsn,
                backend = EXCLUDED.backend;
            ",
            local_dsn = sql_literal(&local_dsn)
        ))
        .unwrap();

        let local_repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status || ';' || COALESCE(error, '')
            FROM pgl_validate.apply_repair(
                {local_drift_run_id},
                'remote_diff',
                'local',
                'local'
            )
            "
        ))
        .unwrap()
        .unwrap();
        let (local_repair_id, local_repair_status) = local_repair_status
            .split_once(';')
            .expect("local repair status should include id");
        let (local_repair_status, local_repair_error) = local_repair_status
            .split_once(';')
            .expect("local repair status should include error");
        assert_eq!(local_repair_status, "revalidated");
        assert_eq!(local_repair_error, "");

        let local_repair_actions = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(action || ':' || post_verdict, ',' ORDER BY action)
            FROM pgl_validate.repair_result
            WHERE repair_id = {local_repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            local_repair_actions,
            "delete:match,insert:match,update:match"
        );

        let origin_reset =
            Spi::get_one::<bool>("SELECT NOT pg_replication_origin_session_is_setup()")
                .unwrap()
                .unwrap();
        assert!(origin_reset);

        let local_repaired_verdict = Spi::get_one::<String>(&repaired_verdict_sql)
            .unwrap()
            .unwrap();
        assert_eq!(local_repaired_verdict, "match");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name};"),
        );
    }

    #[pg_test]
    fn compare_table_compares_multiple_remote_peers_in_one_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_a_db = identifier(&format!("pgl_validate_nway_a_{backend_pid}"));
        let peer_b_db = identifier(&format!("pgl_validate_nway_b_{backend_pid}"));
        let table_name = identifier(&format!("nway_compare_target_{backend_pid}"));
        let peer_a_name = identifier(&format!("remote_nway_a_{backend_pid}"));
        let peer_b_name = identifier(&format!("remote_nway_b_{backend_pid}"));
        let local_dsn = local_dsn();
        let peer_a_dsn = peer_dsn(&peer_a_db);
        let peer_b_dsn = peer_dsn(&peer_b_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_a_db} WITH (FORCE)"),
        );
        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_b_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("CREATE DATABASE {peer_a_db}"),
        )
        .unwrap();
        crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("CREATE DATABASE {peer_b_db}"),
        )
        .unwrap();

        crate::transport::libpq::execute_command(
            &peer_a_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'local'),
                     (2, 'shared');"
            ),
        )
        .unwrap();
        crate::transport::libpq::execute_command(
            &peer_b_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'remote'),
                     (3, 'peer-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer WHERE name IN ({peer_a_name}, {peer_b_name});
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES
                (1, 'local'),
                (2, 'shared');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES
                ({peer_a_name}, {peer_a_dsn}, 'native'),
                ({peer_b_name}, {peer_b_dsn}, 'native');
            ",
            peer_a_name = sql_literal(&peer_a_name),
            peer_b_name = sql_literal(&peer_b_name),
            peer_a_dsn = sql_literal(&peer_a_dsn),
            peer_b_dsn = sql_literal(&peer_b_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT run_id
            FROM pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[{peer_a_name}, {peer_b_name}],
                '{{\"chunk_target_rows\":10}}'::jsonb
            )
            ",
            peer_a_name = sql_literal(&peer_a_name),
            peer_b_name = sql_literal(&peer_b_name)
        ))
        .unwrap()
        .unwrap();

        let table_state = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   string_agg(tnr.node || ':' || tnr.n_rows::text, ',' ORDER BY tnr.node)
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_node_result tnr
              USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {run_id}
              AND tr.table_name = {table_name}
            GROUP BY tr.verdict
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            table_state,
            format!("differ;local:2,{peer_a_name}:2,{peer_b_name}:2")
        );

        let root_chunk_state = Spi::get_one::<String>(&format!(
            "
            SELECT cr.state || ';' ||
                   string_agg(cnr.node, ',' ORDER BY cnr.node)
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = {table_name}
              AND cr.chunk_id = 1
            GROUP BY cr.state
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            root_chunk_state,
            format!("divergent;local,{peer_a_name},{peer_b_name}")
        );

        let divergence_summary = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(node || ':' || classification || ':' || status, ',' ORDER BY classification)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            divergence_summary,
            format!(
                "{peer_b_name}:differs:confirmed,{peer_b_name}:extra_on:confirmed,{peer_b_name}:missing_on:confirmed"
            )
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_a_db} WITH (FORCE)"),
        );
        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_b_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_caps_reported_divergent_tuple_payloads() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_tuple_cap_peer_{backend_pid}"));
        let table_name = identifier(&format!("tuple_cap_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 VALUES (1, repeat('remote-value-', 200));"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
             INSERT INTO public.{table_name}
             VALUES (1, repeat('local-value-', 200));
             INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ('remote_tuple_cap', {}, 'native');",
            sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                {}::regclass,
                ARRAY['remote_tuple_cap'],
                '{{\"max_reported_tuple_bytes\":128}}'::jsonb
            )).run_id
            ",
            sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();

        let cap_summary = Spi::get_one::<String>(&format!(
            "
            SELECT
                verdict || ';' ||
                status || ';' ||
                (tuple->'local'->>'_pgl_validate_tuple_truncated') || ';' ||
                (tuple->'peer'->>'_pgl_validate_tuple_truncated') || ';' ||
                ((tuple->'local'->>'original_bytes')::int > 128)::text || ';' ||
                ((tuple->'peer'->>'original_bytes')::int > 128)::text || ';' ||
                (tuple->'local' ? 'value')::text || ';' ||
                (tuple->'peer' ? 'value')::text
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.divergence d USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {run_id}
              AND d.node = 'remote_tuple_cap'
              AND d.classification = 'differs'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            cap_summary,
            "differ;confirmed;true;true;true;true;false;false"
        );

        Spi::run(&format!(
            r#"
            DO $pgl_validate_tuple_cap$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.generate_repair({run_id}, 'local');
                EXCEPTION WHEN others THEN
                    IF SQLERRM LIKE 'confirmed divergence % has capped authoritative tuple data;%' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected capped tuple data to block repair generation';
                END IF;
            END
            $pgl_validate_tuple_cap$;
            "#
        ))
        .unwrap();

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_caps_reported_divergence_keys_with_summary() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_div_cap_peer_{backend_pid}"));
        let table_name = identifier(&format!("div_cap_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, 'remote-' || g::text
                 FROM generate_series(1, 5) AS g;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
             INSERT INTO public.{table_name}
             SELECT g, 'local-' || g::text
             FROM generate_series(1, 5) AS g;
             INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ('remote_div_cap', {}, 'native');",
            sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                {}::regclass,
                ARRAY['remote_div_cap'],
                '{{\"max_reported_divergences\":2}}'::jsonb
            )).run_id
            ",
            sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();

        let capped_summary = Spi::get_one::<String>(&format!(
            "
            SELECT
                tr.verdict || ';' ||
                count(d.*)::text || ';' ||
                string_agg(d.key_text, ',' ORDER BY d.key_text) || ';' ||
                max(si.detail)
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.divergence d USING (run_id, schema_name, table_name)
            JOIN pgl_validate.schema_issue si USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {run_id}
              AND d.node = 'remote_div_cap'
              AND si.node = 'remote_div_cap'
              AND si.issue_code = 'DIVERGENCE_LIMIT_REACHED'
            GROUP BY tr.verdict
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            capped_summary,
            "differ;2;{\"id\": 1},{\"id\": 2};reported 2 of 5 key-level divergence(s); increase max_reported_divergences above 2 to persist every key"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_records_duplicate_sensitive_keyless_contract_without_repair_rows() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_keyless_peer_{backend_pid}"));
        let table_name = identifier(&format!("remote_keyless_target_{backend_pid}"));
        let peer_name = identifier(&format!("remote_keyless_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'same'),
                     (1, 'same'),
                     (2, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int, value text);
             INSERT INTO public.{table_name} VALUES
                 (1, 'same'),
                 (1, 'same'),
                 (2, 'same');
             INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ({peer_name}, {remote_dsn}, 'native');",
            peer_name = sql_literal(&peer_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass, NULL, '{{\"split_fanout\":4}}'::jsonb)).run_id",
            sql_literal(&format!("public.{table_name}"))
        );
        let match_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let match_contract = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   (tr.reason LIKE '%validated_property=keyless%')::text
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {match_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(match_contract, "match;keyless;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DELETE FROM public.{table_name}
                 WHERE ctid = (
                     SELECT ctid
                     FROM public.{table_name}
                     WHERE id = 1 AND value = 'same'
                     LIMIT 1
                 );
                 INSERT INTO public.{table_name} VALUES (2, 'same');"
            ),
        )
        .unwrap();

        let differ_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let differ_contract = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   (tr.reason LIKE '%whole-relation checksum/count differ%')::text || ';' ||
                   (tr.reason LIKE '%keyless hash bucket(s) differ%')::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.divergence d
                    WHERE d.run_id = tr.run_id) || ';' ||
                   (SELECT (count(DISTINCT tnr.n_rows) = 1
                            AND min(tnr.n_rows) = 3)::text
                    FROM pgl_validate.table_node_result tnr
                    WHERE tnr.run_id = tr.run_id) || ';' ||
                   (SELECT (count(DISTINCT tnr.lthash) = 2)::text
                    FROM pgl_validate.table_node_result tnr
                    WHERE tnr.run_id = tr.run_id) || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.chunk_result cr
                    WHERE cr.run_id = tr.run_id
                      AND cr.parent_id = 1) || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.chunk_node_result cnr
                    JOIN pgl_validate.chunk_result cr USING (run_id, schema_name, table_name, chunk_id)
                    WHERE cr.run_id = tr.run_id
                      AND cr.parent_id = 1) || ';' ||
                   (SELECT EXISTS (
                        SELECT 1
                        FROM pgl_validate.chunk_result cr
                        WHERE cr.run_id = tr.run_id
                          AND cr.parent_id = 1
                          AND cr.state = 'divergent'
                    )::text) || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.generate_repair(tr.run_id, 'local'))
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {differ_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            differ_contract,
            "differ;keyless;true;true;0;true;true;4;8;true;0"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_uses_native_publication_column_projection() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!(
            "pgl_validate_native_projection_peer_{backend_pid}"
        ));
        let table_name = identifier(&format!("native_projection_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_projection_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);
        let options_json = format!(
            "'{{\"backend\":\"native\",\"publications\":[\"{publication_name}\"]}}'::jsonb"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     kept text,
                     ignored text
                 );
                 INSERT INTO public.{table_name}
                 VALUES (1, 'same', 'remote-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            INSERT INTO public.{table_name}
            VALUES (1, 'same', 'local-only');
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name} (id, kept);
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_native_projection', {remote_dsn}, 'native', ARRAY[{publication}]);
            ",
            remote_dsn = sql_literal(&remote_dsn),
            publication = sql_literal(&publication_name)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_native_projection'],
                {options_json}
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let plan = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   array_to_string(tp.att_list, ',')
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(plan, "match;full;id,kept");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_confirms_native_filtered_presence_differences() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_native_filter_peer_{backend_pid}"));
        let table_name = identifier(&format!("native_filtered_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_filter_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);
        let options_json = format!(
            "'{{\"backend\":\"native\",\"publications\":[\"{publication_name}\"]}}'::jsonb"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, kept text);
                 INSERT INTO public.{table_name} VALUES
                     (5, 'remote-extra-outside-filter'),
                     (11, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, kept text);
            INSERT INTO public.{table_name} VALUES
                (5, 'local-outside-filter'),
                (11, 'same'),
                (12, 'local-filtered-missing');
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name}
            WHERE (id > 10);
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_native_filtered', {remote_dsn}, 'native', ARRAY[{publication}]);
            ",
            remote_dsn = sql_literal(&remote_dsn),
            publication = sql_literal(&publication_name)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_native_filtered'],
                {options_json}
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let divergence = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(classification || ':' || status, ',' ORDER BY classification)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(divergence, "extra_on:confirmed,missing_on:confirmed");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn apply_repair_orders_inserts_by_foreign_key() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_fk_peer_{backend_pid}"));
        let parent_table = identifier(&format!("z_repair_parent_{backend_pid}"));
        let child_table = identifier(&format!("a_repair_child_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{parent_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{child_table}(
                     id int PRIMARY KEY,
                     parent_id int NOT NULL REFERENCES public.{parent_table}(id),
                     value text
                 );"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{parent_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{child_table}(
                id int PRIMARY KEY,
                parent_id int NOT NULL REFERENCES public.{parent_table}(id),
                value text
            );
            INSERT INTO public.{parent_table} VALUES (1, 'parent');
            INSERT INTO public.{child_table} VALUES (10, 1, 'child');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_fk', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{child_table}'::regclass,
                    'public.{parent_table}'::regclass
                ],
                peers => ARRAY['remote_fk']
            )
            "
        ))
        .unwrap()
        .unwrap();

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair({run_id}, 'local', 'remote_fk', 'remote_fk')
            "
        ))
        .unwrap()
        .unwrap();
        let (repair_id, repair_status) = repair_status
            .split_once(';')
            .expect("FK repair status should include id");
        assert_eq!(repair_status, "revalidated");

        let repair_audit = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(table_name || ':' || action || ':' || post_verdict, ',' ORDER BY table_name)
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            repair_audit,
            format!("{child_table}:insert:match,{parent_table}:insert:match")
        );

        let repaired_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{child_table}'::regclass,
                    'public.{parent_table}'::regclass
                ],
                peers => ARRAY['remote_fk']
            )
            "
        ))
        .unwrap()
        .unwrap();
        let repaired_verdicts = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(verdict, ',' ORDER BY table_name)
            FROM pgl_validate.table_result
            WHERE run_id = {repaired_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(repaired_verdicts, "match,match");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn fence_barrier_accepts_duplicate_tokens() {
        Spi::run(
            r#"
            INSERT INTO pgl_validate.fence_barrier(token)
            VALUES
                ('11111111-1111-1111-1111-111111111111'),
                ('11111111-1111-1111-1111-111111111111');
            "#,
        )
        .unwrap();

        let count = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.fence_barrier
             WHERE token = '11111111-1111-1111-1111-111111111111'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(count, 2);
    }

    #[pg_test]
    fn fence_attempt_accepts_truthful_converged_status() {
        let run_id = Spi::get_one::<i64>(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('fencing')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), fence AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn)
                SELECT run_id, 1, 1, 'barrier', '22222222-2222-2222-2222-222222222222', '0/20'
                FROM r
            )
            SELECT run_id FROM r;
            "#,
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            r#"
            INSERT INTO pgl_validate.fence_attempt(
                run_id, epoch_seq, edge_id, barrier_end_lsn, origin_progress_lsn, token_visible, status)
            VALUES ({run_id}, 1, 1, '0/20', '0/20', true, 'converged');
            "#,
        ))
        .unwrap();
    }

    #[pg_test(
        error = "new row for relation \"fence_attempt\" violates check constraint \"fence_attempt_converged_truth\""
    )]
    fn fence_attempt_rejects_untruthful_converged_status() {
        let run_id = Spi::get_one::<i64>(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('fencing')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), fence AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn)
                SELECT run_id, 1, 1, 'barrier', '55555555-5555-5555-5555-555555555555', '0/20'
                FROM r
            )
            SELECT run_id FROM r;
            "#,
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            r#"
            INSERT INTO pgl_validate.fence_attempt(
                run_id, epoch_seq, edge_id, barrier_end_lsn, origin_progress_lsn, token_visible, status)
            VALUES ({run_id}, 1, 1, '0/20', '0/10', true, 'converged');
            "#,
        ))
        .unwrap();
    }

    #[pg_test]
    fn barrier_cleanup_protects_unfinished_runs() {
        Spi::run(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('running')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), barrier_rows AS (
                INSERT INTO pgl_validate.fence_barrier(token, injected_at)
                VALUES
                    ('33333333-3333-3333-3333-333333333333', now() - interval '2 hours'),
                    ('44444444-4444-4444-4444-444444444444', now() - interval '2 hours')
            )
            INSERT INTO pgl_validate.fence_barrier_run(
                token, run_id, epoch_seq, edge_id, origin_node, barrier_end_lsn)
            SELECT '33333333-3333-3333-3333-333333333333', run_id, 1, 1, 'a', '0/20'
            FROM r;
            "#,
        )
        .unwrap();

        let deleted =
            Spi::get_one::<i64>("SELECT pgl_validate.cleanup_fence_barriers(interval '1 hour')")
                .unwrap()
                .unwrap();
        assert_eq!(deleted, 1);

        let protected_remaining = Spi::get_one::<bool>(
            "SELECT EXISTS (
                SELECT 1 FROM pgl_validate.fence_barrier
                WHERE token = '33333333-3333-3333-3333-333333333333'
             )",
        )
        .unwrap()
        .unwrap();
        let garbage_remaining = Spi::get_one::<bool>(
            "SELECT EXISTS (
                SELECT 1 FROM pgl_validate.fence_barrier
                WHERE token = '44444444-4444-4444-4444-444444444444'
             )",
        )
        .unwrap()
        .unwrap();

        assert!(protected_remaining);
        assert!(!garbage_remaining);
    }

    #[pg_test]
    fn run_control_transitions_only_active_runs() {
        let running_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status) VALUES ('running') RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let completed_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, finished_at)
             VALUES ('completed', now() - interval '1 hour')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();

        let paused = Spi::get_one::<bool>(&format!("SELECT pgl_validate.pause({running_run})"))
            .unwrap()
            .unwrap();
        let resumed = Spi::get_one::<bool>(&format!("SELECT pgl_validate.resume({running_run})"))
            .unwrap()
            .unwrap();
        let canceled = Spi::get_one::<bool>(&format!("SELECT pgl_validate.cancel({running_run})"))
            .unwrap()
            .unwrap();
        let completed_pause =
            Spi::get_one::<bool>(&format!("SELECT pgl_validate.pause({completed_run})"))
                .unwrap()
                .unwrap();
        let final_state = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || (finished_at IS NOT NULL)::text
            FROM pgl_validate.run
            WHERE run_id = {running_run}
            "
        ))
        .unwrap()
        .unwrap();

        assert!(paused);
        assert!(resumed);
        assert!(canceled);
        assert!(!completed_pause);
        assert_eq!(final_state, "canceled;true");
    }

    #[pg_test]
    fn pause_parks_queued_async_worker_tasks() {
        let run_id = Spi::get_one::<i64>(
            "
            INSERT INTO pgl_validate.run(status, options)
            VALUES ('running', '{\"async\": true}'::jsonb)
            RETURNING run_id
            ",
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.worker_task(
                run_id, task_kind, request, status, database_name
            )
            VALUES (
                {run_id},
                'compare',
                '{{\"tables\": [], \"options\": {{}}}}'::jsonb,
                'queued',
                current_database()
            )
            "
        ))
        .unwrap();

        let paused = Spi::get_one::<bool>(&format!("SELECT pgl_validate.pause({run_id})"))
            .unwrap()
            .unwrap();
        let parked = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   wt.status || ';' ||
                   (wt.worker_pid IS NULL)::text
            FROM pgl_validate.run r
            JOIN pgl_validate.worker_task wt USING (run_id)
            WHERE r.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();

        assert!(paused);
        assert_eq!(parked, "paused;paused;true");
    }

    #[pg_test]
    fn schedule_management_validates_and_dispatches_disabled_schedules_safely() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_schedule_target_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let schedule = Spi::get_one::<String>(&format!(
            "
            SELECT name || ';' ||
                   cron || ';' ||
                   tables[1] || ';' ||
                   COALESCE(repset, '<null>') || ';' ||
                   peers[1] || ';' ||
                   (options->>'chunk_target_rows') || ';' ||
                   enabled::text
            FROM pgl_validate.put_schedule(
                'nightly',
                '0 2 * * *',
                ARRAY['public.{table_name}'],
                NULL,
                ARRAY['local'],
                '{{\"chunk_target_rows\":5}}'::jsonb,
                true
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            schedule,
            format!("nightly;0 2 * * *;public.{table_name};<null>;local;5;true")
        );

        let run_count_before = Spi::get_one::<i64>("SELECT count(*) FROM pgl_validate.run")
            .unwrap()
            .unwrap();
        let changed = Spi::get_one::<String>(
            "
            SELECT pgl_validate.set_schedule_enabled('nightly', false)::text || ';' ||
                   (pgl_validate.run_schedule('nightly') IS NULL)::text
            ",
        )
        .unwrap()
        .unwrap();
        let run_count_after = Spi::get_one::<i64>("SELECT count(*) FROM pgl_validate.run")
            .unwrap()
            .unwrap();
        assert_eq!(changed, "true;true");
        assert_eq!(run_count_after, run_count_before);

        let removed = Spi::get_one::<bool>("SELECT pgl_validate.delete_schedule('nightly')")
            .unwrap()
            .unwrap();
        let exists = Spi::get_one::<bool>(
            "SELECT EXISTS (SELECT 1 FROM pgl_validate.schedule WHERE name = 'nightly')",
        )
        .unwrap()
        .unwrap();

        assert!(removed);
        assert!(!exists);
    }

    #[pg_test]
    fn schedule_cron_matching_supports_ranges_steps_and_sunday_7() {
        Spi::run("SET LOCAL TimeZone = 'UTC'").unwrap();

        let matches = Spi::get_one::<String>(
            "
            SELECT pgl_validate._cron_matches('*/15 1-3 * 1 1', '2026-01-05 02:30:00+00'::timestamptz)::text || ';' ||
                   pgl_validate._cron_matches('*/15 1-3 * 1 1', '2026-01-05 02:31:00+00'::timestamptz)::text || ';' ||
                   pgl_validate._cron_matches('0 0 15 * 1', '2026-01-05 00:00:00+00'::timestamptz)::text || ';' ||
                   pgl_validate._cron_matches('0 0 * * 7', '2026-01-04 00:00:00+00'::timestamptz)::text
            ",
        )
        .unwrap()
        .unwrap();
        assert_eq!(matches, "true;false;true;true");

        Spi::run(
            "
            DO $$
            BEGIN
                PERFORM pgl_validate.put_schedule('bad_cron', '* * *', NULL, NULL, NULL, '{}'::jsonb, true);
                RAISE EXCEPTION 'expected invalid cron to fail';
            EXCEPTION WHEN invalid_parameter_value THEN
                -- expected
            END
            $$
            ",
        )
        .unwrap();
        let rejected = Spi::get_one::<bool>(
            "SELECT NOT EXISTS (SELECT 1 FROM pgl_validate.schedule WHERE name = 'bad_cron')",
        )
        .unwrap()
        .unwrap();
        assert!(rejected);
    }

    #[pg_test]
    fn dispatch_due_schedules_skips_disabled_and_duplicate_minutes() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let schedule_name = format!("dispatch_guard_{backend_pid}");
        let table_name = identifier(&format!("pgl_validate_dispatch_target_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            SELECT pgl_validate.put_schedule(
                {schedule_name},
                '* * * * *',
                ARRAY['public.{table_name}'],
                NULL,
                ARRAY['local'],
                '{{\"chunk_target_rows\":5}}'::jsonb,
                false
            );
            ",
            schedule_name = sql_literal(&schedule_name)
        ))
        .unwrap();

        let disabled_count = Spi::get_one::<i32>(
            "SELECT pgl_validate.dispatch_due_schedules('2026-01-05 02:30:00+00'::timestamptz)",
        )
        .unwrap()
        .unwrap();
        assert_eq!(disabled_count, 0);

        Spi::run(&format!(
            "
            WITH inserted_run AS (
                INSERT INTO pgl_validate.run(status, started_at, options)
                VALUES ('completed', '2026-01-05 02:30:10+00'::timestamptz, '{{}}'::jsonb)
                RETURNING run_id
            )
            UPDATE pgl_validate.schedule
            SET enabled = true,
                last_run_id = inserted_run.run_id
            FROM inserted_run
            WHERE name = {schedule_name}
            ",
            schedule_name = sql_literal(&schedule_name)
        ))
        .unwrap();

        let duplicate_minute_count = Spi::get_one::<i32>(
            "SELECT pgl_validate.dispatch_due_schedules('2026-01-05 02:30:59+00'::timestamptz)",
        )
        .unwrap()
        .unwrap();
        assert_eq!(duplicate_minute_count, 0);
    }

    #[pg_test]
    fn worker_task_claim_and_run_executes_parent_compare() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_worker_target_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let task = Spi::get_one::<String>(&format!(
            "
            WITH run AS (
                INSERT INTO pgl_validate.run(status, options)
                VALUES ('planning', '{{\"async\": true}}'::jsonb)
                RETURNING run_id
            ),
            task AS (
                INSERT INTO pgl_validate.worker_task(
                    run_id, task_kind, request, status, database_name
                )
                SELECT
                    run_id,
                    'compare',
                    jsonb_build_object(
                        'tables', jsonb_build_array('public.{table_name}'),
                        'repset', NULL,
                        'peers', NULL,
                        'reference', NULL,
                        'options', '{{}}'::jsonb
                    ),
                    'queued',
                    current_database()
                FROM run
                RETURNING run_id, task_id
            )
            SELECT run_id::text || ';' || task_id::text
            FROM task
            "
        ))
        .unwrap()
        .unwrap();
        let (run_id, task_id) = task
            .split_once(';')
            .expect("worker task result should contain run and task ids");

        let claimed = Spi::get_one::<bool>(&format!(
            "SELECT pgl_validate._claim_worker_task({task_id}::integer)"
        ))
        .unwrap()
        .unwrap();
        assert!(claimed);

        Spi::run(&format!(
            "SELECT pgl_validate._run_worker_task({task_id}::integer)"
        ))
        .unwrap();

        let state = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   wt.status || ';' ||
                   tr.verdict || ';' ||
                   (wt.worker_pid = pg_backend_pid())::text || ';' ||
                   (wt.finished_at IS NOT NULL)::text
            FROM pgl_validate.run r
            JOIN pgl_validate.worker_tasks wt USING (run_id)
            JOIN pgl_validate.table_result tr USING (run_id)
            WHERE r.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();

        assert_eq!(state, "completed;completed;match;true;true");
    }

    #[pg_test]
    fn purge_removes_terminal_runs_and_unprotected_barriers() {
        let active_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at)
             VALUES ('running', now() - interval '2 days')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let old_done = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at, finished_at)
             VALUES ('completed', now() - interval '3 days', now() - interval '2 days')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let recent_done = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at, finished_at)
             VALUES ('completed', now() - interval '10 minutes', now() - interval '5 minutes')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
            VALUES ({active_run}, 1);
            INSERT INTO pgl_validate.run_edge(
                run_id, edge_id, provider_node, target_node, backend,
                subscription, slot_name, origin_name, repsets)
            VALUES ({active_run}, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']);
            INSERT INTO pgl_validate.fence_barrier(token, injected_at)
            VALUES
                ('55555555-5555-5555-5555-555555555555', now() - interval '2 hours'),
                ('66666666-6666-6666-6666-666666666666', now() - interval '2 hours');
            INSERT INTO pgl_validate.fence_barrier_run(
                token, run_id, epoch_seq, edge_id, origin_node, barrier_end_lsn)
            VALUES ('55555555-5555-5555-5555-555555555555', {active_run}, 1, 1, 'a', '0/30');
            "
        ))
        .unwrap();

        let purged = Spi::get_one::<i64>("SELECT pgl_validate.purge(now() - interval '1 hour')")
            .unwrap()
            .unwrap();

        let outcome = Spi::get_one::<String>(&format!(
            "
            SELECT EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {old_done})::text || ';' ||
                   EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {recent_done})::text || ';' ||
                   EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {active_run})::text || ';' ||
                   EXISTS (
                       SELECT 1 FROM pgl_validate.fence_barrier
                       WHERE token = '55555555-5555-5555-5555-555555555555'
                   )::text || ';' ||
                   EXISTS (
                       SELECT 1 FROM pgl_validate.fence_barrier
                       WHERE token = '66666666-6666-6666-6666-666666666666'
                   )::text
            "
        ))
        .unwrap()
        .unwrap();

        assert_eq!(purged, 1);
        assert_eq!(outcome, "false;true;true;true;false");
    }

    #[pg_test]
    fn pglogical_accepts_insert_only_barrier_repset() {
        Spi::run(
            r#"
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node(
                'pgl_validate_test',
                'dbname=' || current_database()
            );
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            "#,
        )
        .unwrap();

        let has_row_filter = Spi::get_one::<bool>(
            r#"
            SELECT has_row_filter
            FROM pglogical.show_repset_table_info(
                'pgl_validate.fence_barrier'::regclass,
                ARRAY['pgl_validate_barrier']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        let att_count = Spi::get_one::<i32>(
            r#"
            SELECT cardinality(att_list)
            FROM pglogical.show_repset_table_info(
                'pgl_validate.fence_barrier'::regclass,
                ARRAY['pgl_validate_barrier']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(!has_row_filter);
        assert_eq!(att_count, 3);
    }

    #[pg_test]
    fn pglogical_barrier_repset_rejects_extra_tables() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_barrier_extra_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_barrier_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(id int PRIMARY KEY);
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            SELECT pglogical.replication_set_add_table(
                'pgl_validate_barrier',
                'public.{table_name}'::regclass,
                false
            );
            ",
            node = sql_literal(&node_name),
        ))
        .unwrap();

        Spi::run(
            r#"
            DO $$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.ensure_pglogical_barrier_repset();
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'pglogical replication set pgl_validate_barrier must contain only pgl_validate.fence_barrier' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected pgl_validate_barrier to reject extra tables';
                END IF;
            END
            $$;
            "#,
        )
        .unwrap();
    }

    #[pg_test]
    fn pglogical_contract_uses_effective_column_list_and_action_mask() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_contract_cols_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_contract_cols_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_contract_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            SELECT pglogical.create_replication_set({repset}, true, false, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                ARRAY['id','kept']
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT array_to_string(att_list, ',') || ';' ||
                   validated_property || ';' ||
                   repl_update::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "id,kept;keys_only;false");
    }

    #[pg_test]
    fn compare_expands_pglogical_repset_into_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_repset_peer_{backend_pid}"));
        let first_table = identifier(&format!("pgl_validate_repset_a_{backend_pid}"));
        let second_table = identifier(&format!("pgl_validate_repset_b_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_repset_seq_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_compare_repset_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_compare_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 INSERT INTO public.{first_table} VALUES (1, 'same');
                 INSERT INTO public.{second_table} VALUES (1, 'same');
                 DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 12, true);
                 END
                 $$;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            INSERT INTO public.{first_table} VALUES (1, 'same');
            INSERT INTO public.{second_table} VALUES (1, 'same');
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{first_table}'::regclass,
                false
            );
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{second_table}'::regclass,
                false
            );
            SELECT pglogical.replication_set_add_sequence(
                {repset},
                'public.{sequence_name}'::regclass,
                false
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('repset_peer', {remote_dsn}, 'native');
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                NULL::regclass[],
                {repset},
                ARRAY['repset_peer'],
                NULL::text,
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            ",
            repset = sql_literal(&repset_name)
        ))
        .unwrap()
        .unwrap();

        let planned = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   count(tp.*)::text || ';' ||
                   bool_and(tp.repsets = ARRAY[{repset}]::text[])::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.sequence_result sr
                    WHERE sr.run_id = r.run_id
                      AND sr.seq_name = {sequence_name}) || ';' ||
                   (SELECT bool_and(sr.verdict = 'match' AND sr.within_contract)::text
                    FROM pgl_validate.sequence_result sr
                    WHERE sr.run_id = r.run_id
                      AND sr.seq_name = {sequence_name})
            FROM pgl_validate.run r
            JOIN pgl_validate.table_plan tp ON tp.run_id = r.run_id
            WHERE r.run_id = {run_id}
            GROUP BY r.run_id, r.status
            ",
            repset = sql_literal(&repset_name),
            sequence_name = sql_literal(&sequence_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(planned, "completed;2;true;1;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn pglogical_contract_deparses_exact_row_filter() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_filter_contract_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filter_contract_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filter_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text
            );
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'id > 0 AND lower(kept) = kept'
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   row_filter_exact::text || ';' ||
                   (row_filter_sql IS NOT NULL)::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "filtered_intersection;true;true;true");
    }

    #[pg_test]
    fn pglogical_contract_skips_session_sensitive_row_filter() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_filter_session_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filter_session_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filter_session_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(id int PRIMARY KEY);
            INSERT INTO public.{table_name} VALUES (0), (1);
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'id > 0 AND current_user = current_user'
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   row_filter_exact::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "skipped;false;false");

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[]::text[],
                jsonb_build_object('repsets', jsonb_build_array({repset}))
            )).run_id
            ",
            repset = sql_literal(&repset_name)
        ))
        .unwrap()
        .unwrap();
        let issue = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' || si.issue_code
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.schema_issue si
              ON si.run_id = tr.run_id
             AND si.schema_name = tr.schema_name
             AND si.table_name = tr.table_name
            WHERE tr.run_id = {run_id}
              AND si.issue_code = 'NONDETERMINISTIC_ROW_FILTER'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(issue, "skipped;NONDETERMINISTIC_ROW_FILTER");

        let approx_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[]::text[],
                jsonb_build_object(
                    'repsets', jsonb_build_array({repset}),
                    'allow_approximate_filters', true
                )
            )).run_id
            ",
            repset = sql_literal(&repset_name)
        ))
        .unwrap()
        .unwrap();
        let approximate = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' || si.issue_code || ';' || tnr.n_rows::text
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.schema_issue si
              ON si.run_id = tr.run_id
             AND si.schema_name = tr.schema_name
             AND si.table_name = tr.table_name
            JOIN pgl_validate.table_node_result tnr
              ON tnr.run_id = tr.run_id
             AND tnr.schema_name = tr.schema_name
             AND tnr.table_name = tr.table_name
             AND tnr.node = 'local'
            WHERE tr.run_id = {approx_run_id}
              AND si.issue_code = 'NONDETERMINISTIC_ROW_FILTER'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(approximate, "approximate;NONDETERMINISTIC_ROW_FILTER;1");
    }

    #[pg_test]
    fn compare_table_uses_pglogical_column_projection() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_contract_peer_{backend_pid}"));
        let table_name = identifier(&format!("pglogical_projection_target_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_projection_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_projection_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     kept text,
                     ignored text
                 );
                 INSERT INTO public.{table_name} VALUES (1, 'same', 'remote-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            INSERT INTO public.{table_name} VALUES (1, 'same', 'local-only');
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                ARRAY['id','kept']
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_projection', {remote_dsn}, 'native', ARRAY[{repset}]);
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let verdict_sql = format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_projection'],
                '{{\"repsets\":[{repset_json}]}}'::jsonb
            )).verdict
            ",
            repset_json = sql_literal(&repset_name).replace('\'', "\"")
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "match");

        let planned_cols_sql = format!(
            "SELECT array_to_string(att_list, ',')
             FROM pgl_validate.table_plan
             WHERE table_name = {}
             ORDER BY run_id DESC
             LIMIT 1",
            sql_literal(&table_name)
        );
        let planned_cols = Spi::get_one::<String>(&planned_cols_sql).unwrap().unwrap();
        assert_eq!(planned_cols, "id,kept");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_marks_filtered_presence_difference_advisory() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_filter_peer_{backend_pid}"));
        let table_name = identifier(&format!("pglogical_filtered_target_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filtered_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filtered_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     include_row boolean NOT NULL,
                     value text
                 );
                 INSERT INTO public.{table_name} VALUES
                     (1, true, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                include_row boolean NOT NULL,
                value text
            );
            INSERT INTO public.{table_name} VALUES
                (1, true, 'same'),
                (6, true, 'entered-filter-locally');
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'include_row'
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_filtered', {remote_dsn}, 'native', ARRAY[{repset}]);
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let verdict_sql = format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_filtered'],
                '{{\"repsets\":[{repset_json}]}}'::jsonb
            )).verdict
            ",
            repset_json = sql_literal(&repset_name).replace('\'', "\"")
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "match");

        let divergence_sql = format!(
            "
            SELECT classification || ';' || status || ';' || node
            FROM pgl_validate.divergence
            WHERE table_name = {table_name_lit}
            ORDER BY detected_at DESC
            LIMIT 1
            ",
            table_name_lit = sql_literal(&table_name)
        );
        let divergence = Spi::get_one::<String>(&divergence_sql).unwrap().unwrap();
        assert_eq!(divergence, "missing_on;advisory;remote_filtered");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_marks_non_replicated_truncate_extras_advisory() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_truncate_peer_{backend_pid}"));
        let table_name = identifier(&format!("pglogical_truncate_target_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_truncate_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_truncate_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES (1, 'left-behind-by-nonreplicated-truncate');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            SELECT pglogical.create_replication_set({repset}, true, true, true, false);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_truncate_extra', {remote_dsn}, 'native', ARRAY[{repset}]);
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let result_sql = format!(
            "
            SELECT (r).run_id::text || ';' || (r).verdict
            FROM (
                SELECT pgl_validate.compare_table(
                    'public.{table_name}'::regclass,
                    ARRAY['remote_truncate_extra'],
                    '{{\"repsets\":[{repset_json}]}}'::jsonb
                ) AS r
            ) s
            ",
            repset_json = sql_literal(&repset_name).replace('\'', "\"")
        );
        let result = Spi::get_one::<String>(&result_sql).unwrap().unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "match");

        let contract = Spi::get_one::<String>(&format!(
            "
            SELECT tp.validated_property || ';' ||
                   tp.repl_truncate::text || ';' ||
                   d.classification || ';' ||
                   d.status || ';' ||
                   (tr.reason LIKE '%advisory differences=1%validated_property=superset')::text
            FROM pgl_validate.table_plan tp
            JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
            JOIN pgl_validate.divergence d USING (run_id, schema_name, table_name)
            WHERE tp.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(contract, "superset;false;extra_on;advisory;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_sequence_applies_pglogical_buffer_window() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_sequence_peer_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_sequence_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 12, true);
                 END
                 $$;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_sequence', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let compare_sql = format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_sequence'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        );
        let matched = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(matched, "match;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 9, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let behind_sql = format!(
            "
            SELECT run_id::text || ';' || verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_sequence'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        );
        let behind = Spi::get_one::<String>(&behind_sql).unwrap().unwrap();
        let (behind_run_id, behind_result) = behind
            .split_once(';')
            .expect("sequence result should include run id");
        assert_eq!(behind_result, "behind;false");

        let sequence_repair = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(stmt, E'\\n' ORDER BY stmt)
            FROM pgl_validate.generate_repair({behind_run_id}::bigint, 'local') AS stmt
            "
        ))
        .unwrap()
        .unwrap();
        assert!(
            sequence_repair.contains("/* target: 'remote_sequence' */ DO $pgl_validate_repair$")
        );
        assert!(sequence_repair.contains(", 10, true)"));

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair(
                {behind_run_id}::bigint,
                'local',
                'remote_sequence',
                'remote_sequence'
            )
            "
        ))
        .unwrap()
        .unwrap();
        let (repair_id, repair_status) = repair_status
            .split_once(';')
            .expect("sequence repair status should include id");
        assert_eq!(repair_status, "revalidated");

        let sequence_repair_action = Spi::get_one::<String>(&format!(
            "
            SELECT action || ':' || post_verdict
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(sequence_repair_action, "setval:match");

        let repaired_sequence = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(repaired_sequence, "match;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 9, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let behind = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(behind, "behind;false");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 21, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let ahead = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(ahead, "ahead_of_window;false");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn conflict_history_correlation_attaches_key_evidence() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_conflict_peer_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_conflict_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "
                CREATE SCHEMA pglogical;
                CREATE TABLE pglogical.conflict_history (
                    id bigserial,
                    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
                    sub_id oid NOT NULL,
                    sub_name name,
                    conflict_type text NOT NULL,
                    resolution text NOT NULL,
                    schema_name name NOT NULL,
                    table_name name NOT NULL,
                    index_name name,
                    local_tuple jsonb,
                    local_xid xid,
                    local_origin integer,
                    local_commit_ts timestamptz,
                    remote_tuple jsonb,
                    remote_origin integer NOT NULL,
                    remote_commit_ts timestamptz NOT NULL,
                    remote_commit_lsn pg_lsn NOT NULL,
                    has_before_triggers boolean NOT NULL DEFAULT false
                );
                INSERT INTO pglogical.conflict_history(
                    recorded_at, sub_id, sub_name, conflict_type, resolution,
                    schema_name, table_name, index_name, local_tuple, remote_tuple,
                    remote_origin, remote_commit_ts, remote_commit_lsn
                )
                VALUES
                    (
                        now(), '1'::oid, 'sub', 'update_update', 'keep_local',
                        'public', {table_name}, {index_name},
                        '{{\"id\": 1, \"value\": \"local\"}}'::jsonb,
                        '{{\"id\": 1, \"value\": \"remote\"}}'::jsonb,
                        1, now(), '0/16B6C50'::pg_lsn
                    ),
                    (
                        now(), '1'::oid, 'sub', 'update_update', 'keep_local',
                        'public', {table_name}, {index_name},
                        '{{\"id\": 2, \"value\": \"local\"}}'::jsonb,
                        '{{\"id\": 2, \"value\": \"remote\"}}'::jsonb,
                        1, now(), '0/16B6C60'::pg_lsn
                    );
                ",
                table_name = sql_literal(&table_name),
                index_name = sql_literal(&format!("{table_name}_pkey"))
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name)
            VALUES ('target_history', {remote_dsn}, 'pglogical', 'sub');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let fetched_conflicts = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.remote_pglogical_conflict_history(
                {remote_dsn},
                'sub',
                'public',
                {table_name},
                (now() - interval '24 hours')::text,
                10
            )
            ",
            remote_dsn = sql_literal(&remote_dsn),
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(fetched_conflicts, 2);

        let run_id = Spi::get_one::<i64>(&format!(
            "
            WITH run AS (
                INSERT INTO pgl_validate.run(status, started_at)
                VALUES ('completed', now() - interval '1 hour')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM run
                RETURNING run_id
            ), plan AS (
                INSERT INTO pgl_validate.table_plan(
                    run_id, schema_name, table_name, key_cols, att_list,
                    validated_property
                )
                SELECT run_id, 'public', {table_name}, ARRAY['id'], ARRAY['id','value'], 'full'
                FROM run
                RETURNING run_id
            ), divergence AS (
                INSERT INTO pgl_validate.divergence(
                    run_id, schema_name, table_name, key_text, key_bytes,
                    classification, node, status, detected_epoch, tuple
                )
                SELECT run_id, 'public', {table_name},
                       '{{\"id\": 1}}',
                       decode('01', 'hex'),
                       'differs',
                       'target_history',
                       'confirmed',
                       1,
                       '{{\"local\": {{\"id\": 1, \"value\": \"local\"}},
                          \"peer\": {{\"id\": 1, \"value\": \"remote\"}}}}'::jsonb
                FROM run
            )
            SELECT run_id
            FROM run
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        let evidence_count = Spi::get_one::<i64>(&format!(
            "SELECT pgl_validate.correlate_conflict_history({run_id}, interval '24 hours', 10)::bigint"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(evidence_count, 1);

        let evidence = Spi::get_one::<String>(&format!(
            "
            SELECT count(*)::text || ';' ||
                   min(conflict_type) || ';' ||
                   min(resolution) || ';' ||
                   bool_or('local_tuple_key' = ANY(matched_on))::text || ';' ||
                   bool_or('remote_tuple_key' = ANY(matched_on))::text
            FROM pgl_validate.conflict_evidence({run_id})
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(evidence, "1;update_update;keep_local;true;true");

        let report_has_evidence = Spi::get_one::<bool>(&format!(
            "
            SELECT jsonb_array_length(
                pgl_validate.report({run_id})
                    -> 'tables' -> 0
                    -> 'divergences' -> 0
                    -> 'conflict_evidence'
            ) = 1
            "
        ))
        .unwrap()
        .unwrap();
        assert!(report_has_evidence);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn run_progress_reports_phase_epoch_scan_counters_and_eta() {
        let run_id = Spi::get_one::<i64>(
            "
            INSERT INTO pgl_validate.run(status, started_at)
            VALUES ('running', clock_timestamp() - interval '10 seconds')
            RETURNING run_id
            ",
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
            VALUES ({run_id}, 2);

            INSERT INTO pgl_validate.table_plan(
                run_id, schema_name, table_name, validated_property
            )
            VALUES ({run_id}, 'public', 'progress_target', 'full');

            INSERT INTO pgl_validate.table_node_result(
                run_id, schema_name, table_name, node, n_rows, lthash
            )
            VALUES ({run_id}, 'public', 'progress_target', 'local', 10, '\\x01'::bytea);

            INSERT INTO pgl_validate.chunk_result(
                run_id, schema_name, table_name, chunk_id, state
            )
            VALUES
                ({run_id}, 'public', 'progress_target', 1, 'clean'),
                ({run_id}, 'public', 'progress_target', 2, 'running'),
                ({run_id}, 'public', 'progress_target', 3, 'split');

            INSERT INTO pgl_validate.chunk_node_result(
                run_id, schema_name, table_name, chunk_id, node, n_rows, lthash
            )
            VALUES
                ({run_id}, 'public', 'progress_target', 1, 'local', 5, '\\x02'::bytea),
                ({run_id}, 'public', 'progress_target', 2, 'local', 5, '\\x03'::bytea);

            INSERT INTO pgl_validate.divergence(
                run_id, schema_name, table_name, key_text, key_bytes,
                classification, node, detected_epoch
            )
            VALUES (
                {run_id}, 'public', 'progress_target', '1', '\\x31'::bytea,
                'differs', 'peer', 2
            );
            "
        ))
        .unwrap();

        let progress = Spi::get_one::<String>(&format!(
            "
            SELECT phase || ';' ||
                   current_epoch::text || ';' ||
                   chunks_done::text || '/' || chunks_total::text || ';' ||
                   rows_scanned::text || ';' ||
                   bytes_scanned::text || ';' ||
                   (eta IS NOT NULL)::text
            FROM pgl_validate.run_progress
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();

        assert_eq!(progress, "rechecking;2;1/2;20;640;true");
    }

    #[pg_test]
    fn report_and_metrics_include_validation_state() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_report_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table('public.{table_name}'::regclass)).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let report_shape = Spi::get_one::<String>(&format!(
            "
            WITH report AS (
                SELECT pgl_validate.report({run_id}) AS doc
            )
            SELECT concat_ws(
                ';',
                (doc ? 'run')::text,
                (doc ? 'tables')::text,
                (doc ? 'participants')::text,
                (doc ? 'fence')::text,
                jsonb_array_length(doc->'tables')::text,
                COALESCE(doc->'tables'->0->'result'->>'verdict', '<null>')
            )
            FROM report
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(report_shape, "true;true;true;true;1;match");

        let missing_report =
            Spi::get_one::<String>("SELECT pgl_validate.report(-9223372036854775808)->>'error'")
                .unwrap()
                .unwrap();
        assert_eq!(missing_report, "run not found");

        let metrics_ok = Spi::get_one::<bool>(&format!(
            "
            WITH metrics AS (
                SELECT pgl_validate.metrics() AS doc
            )
            SELECT doc ? 'runs'
               AND doc ? 'tables'
               AND doc ? 'io'
               AND doc->'tables'->'by_verdict' ? 'match'
               AND doc->'tables'->'last_successful_by_table' ? 'public.{table_name}'
               AND (doc->'io'->>'rows_scanned')::bigint >= 1
               AND (doc->'io'->>'bytes_transferred')::bigint >= 0
            FROM metrics
            "
        ))
        .unwrap()
        .unwrap();
        assert!(metrics_ok);
    }
}
