\set ON_ERROR_STOP on
\pset null '<null>'
\pset format unaligned

DROP TABLE IF EXISTS public.pgl_validate_regress_repair;
DROP SEQUENCE IF EXISTS public.pgl_validate_regress_seq;

CREATE TABLE public.pgl_validate_regress_repair(
    id int PRIMARY KEY,
    value text
);
CREATE SEQUENCE public.pgl_validate_regress_seq CACHE 5;

CREATE TEMP TABLE pgl_validate_regress_seed AS
WITH run AS (
    INSERT INTO pgl_validate.run(
        status, started_at, finished_at, tables_total, tables_matched, tables_differ
    )
    VALUES (
        'completed',
        '2026-01-01 00:00:00+00',
        '2026-01-01 00:00:01+00',
        1,
        0,
        1
    )
    RETURNING run_id
),
participant AS (
    INSERT INTO pgl_validate.run_participant(run_id, node, role, backend, pg_version, status)
    SELECT run_id, 'local', 'reference', 'native', current_setting('server_version_num')::int, 'done'
    FROM run
    UNION ALL
    SELECT run_id, 'target', 'participant', 'native', current_setting('server_version_num')::int, 'done'
    FROM run
),
epoch AS (
    INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
    SELECT run_id, 1
    FROM run
),
plan AS (
    INSERT INTO pgl_validate.table_plan(
        run_id, schema_name, table_name, key_cols, att_list,
        repl_insert, repl_update, repl_delete, repl_truncate,
        validated_property
    )
    SELECT run_id,
           'public',
           'pgl_validate_regress_repair',
           ARRAY['id'],
           ARRAY['id','value'],
           true,
           true,
           true,
           true,
           'full'
    FROM run
),
result AS (
    INSERT INTO pgl_validate.table_result(run_id, schema_name, table_name, verdict, reason, finished_at)
    SELECT run_id,
           'public',
           'pgl_validate_regress_repair',
           'differ',
           'fixture divergence',
           '2026-01-01 00:00:01+00'
    FROM run
),
divergence AS (
    INSERT INTO pgl_validate.divergence(
        run_id, schema_name, table_name, key_text, key_bytes,
        classification, node, status, detected_epoch, tuple, detected_at
    )
    SELECT run_id,
           'public',
           'pgl_validate_regress_repair',
           '{"id": 1}',
           convert_to('{"id":1}', 'UTF8'),
           'differs',
           'target',
           'confirmed',
           1,
           '{"local":{"id":1,"value":"local"},"peer":{"id":1,"value":"remote"}}'::jsonb,
           '2026-01-01 00:00:01+00'
    FROM run
),
issue AS (
    INSERT INTO pgl_validate.schema_issue(run_id, node, schema_name, table_name, issue_code, detail)
    SELECT run_id,
           'target',
           'public',
           'pgl_validate_regress_repair',
           'TABLE_COMPARE_FAILED',
           'fixture detail'
    FROM run
),
sequence AS (
    INSERT INTO pgl_validate.sequence_result(
        run_id, schema_name, seq_name, provider_node, provider_last_value,
        subscriber_node, subscriber_last_value, cache_size, within_contract, verdict
    )
    SELECT run_id,
           'public',
           'pgl_validate_regress_seq',
           'local',
           42,
           'target',
           1,
           5,
           false,
           'behind'
    FROM run
),
conflict AS (
    INSERT INTO pgl_validate.conflict_evidence(
        run_id, schema_name, table_name, key_bytes, node,
        conflict_id, recorded_at, subscription_name, conflict_type, resolution,
        index_name, local_tuple, local_xid, local_origin, local_commit_ts,
        remote_tuple, remote_origin, remote_commit_ts, remote_commit_lsn,
        has_before_triggers, matched_on
    )
    SELECT run_id,
           'public',
           'pgl_validate_regress_repair',
           convert_to('{"id":1}', 'UTF8'),
           'target',
           conflict_id,
           recorded_at,
           'sub',
           'update_update',
           'keep_local',
           'pgl_validate_regress_repair_pkey',
           '{"id":1,"value":"local"}'::jsonb,
           '123',
           1,
           '2026-01-01 00:00:00+00'::timestamptz,
           '{"id":1,"value":"remote"}'::jsonb,
           2,
           remote_commit_ts,
           remote_commit_lsn,
           has_before_triggers,
           ARRAY['local_tuple_key','remote_tuple_key']
    FROM run
    CROSS JOIN (
        VALUES
            (
                10::bigint,
                '2025-12-31 23:59:00+00'::timestamptz,
                '2025-12-31 23:58:59+00'::timestamptz,
                '0/16B6C50'::pg_lsn,
                false
            ),
            (
                11::bigint,
                '2026-01-01 00:00:02+00'::timestamptz,
                '2026-01-01 00:00:02+00'::timestamptz,
                '0/16B6D00'::pg_lsn,
                true
            )
    ) AS evidence(
        conflict_id,
        recorded_at,
        remote_commit_ts,
        remote_commit_lsn,
        has_before_triggers
    )
)
SELECT run_id
FROM run;

SELECT status, tables_total, tables_matched, tables_differ
FROM pgl_validate.run_status((SELECT run_id FROM pgl_validate_regress_seed));

SELECT node, issue_code, detail
FROM pgl_validate.schema_issues
WHERE run_id = (SELECT run_id FROM pgl_validate_regress_seed)
ORDER BY node, issue_code;

SELECT source,
       schema_name,
       table_name,
       node,
       conflict_type,
       resolution,
       evidence_count,
       matched_key_count,
       to_char(first_recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS first_recorded_at,
       to_char(last_recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS last_recorded_at,
       has_before_triggers
FROM pgl_validate.conflict_summary((SELECT run_id FROM pgl_validate_regress_seed));

SELECT regexp_replace(stmt, '\s+', ' ', 'g') AS repair_statement
FROM pgl_validate.generate_repair(
    (SELECT run_id FROM pgl_validate_regress_seed),
    'local'
) AS stmt
ORDER BY stmt;

CREATE TEMP TABLE pgl_validate_regress_repair_check(
    check_name text PRIMARY KEY,
    ok boolean NOT NULL
);

DO $$
DECLARE
    before_count bigint;
    after_count bigint;
    caught_error text;
BEGIN
    SELECT count(*) INTO before_count
    FROM pgl_validate.repair_run;

    PERFORM set_config('session_replication_role', 'replica', true);
    BEGIN
        PERFORM pgl_validate.apply_repair(
            (SELECT run_id FROM pgl_validate_regress_seed),
            'target',
            'local',
            'local'
        );
        PERFORM set_config('session_replication_role', 'origin', true);
        INSERT INTO pgl_validate_regress_repair_check
        VALUES ('session_replication_role_rejected', false);
    EXCEPTION WHEN object_not_in_prerequisite_state THEN
        caught_error := SQLERRM;
        PERFORM set_config('session_replication_role', 'origin', true);
        SELECT count(*) INTO after_count
        FROM pgl_validate.repair_run;
        INSERT INTO pgl_validate_regress_repair_check
        VALUES (
            'session_replication_role_rejected',
            caught_error = 'pgl_validate repair requires session_replication_role = origin'
            AND before_count = after_count
        );
    WHEN others THEN
        PERFORM set_config('session_replication_role', 'origin', true);
        RAISE;
    END;
END
$$;

SELECT check_name, ok
FROM pgl_validate_regress_repair_check
ORDER BY check_name;

CREATE TEMP TABLE pgl_validate_regress_action_case(
    label text PRIMARY KEY,
    validated_property text NOT NULL,
    repl_insert boolean NOT NULL,
    repl_update boolean NOT NULL,
    repl_delete boolean NOT NULL,
    repl_truncate boolean NOT NULL,
    classification text NOT NULL,
    key_id int NOT NULL,
    tuple_doc jsonb NOT NULL
);

INSERT INTO pgl_validate_regress_action_case
VALUES
    (
        'filtered_advisory_differs',
        'filtered_advisory',
        true,
        false,
        true,
        true,
        'differs',
        6,
        '{"local":{"id":6,"value":"local"},"peer":{"id":6,"value":"target"}}'
    ),
    (
        'filtered_intersection_differs',
        'filtered_intersection',
        true,
        true,
        true,
        true,
        'differs',
        7,
        '{"local":{"id":7,"value":"local"},"peer":{"id":7,"value":"target"}}'
    ),
    (
        'filtered_intersection_missing',
        'filtered_intersection',
        true,
        true,
        true,
        true,
        'missing_on',
        8,
        '{"local":{"id":8,"value":"local"},"peer":null}'
    ),
    (
        'keys_only_delete',
        'keys_only',
        true,
        false,
        true,
        true,
        'extra_on',
        2,
        '{"local":null,"peer":{"id":2,"value":"target-only"}}'
    ),
    (
        'keys_only_extra_without_delete',
        'keys_only',
        true,
        false,
        false,
        false,
        'extra_on',
        22,
        '{"local":null,"peer":{"id":22,"value":"target-only"}}'
    ),
    (
        'keys_only_differs',
        'keys_only',
        true,
        false,
        true,
        true,
        'differs',
        3,
        '{"local":{"id":3,"value":"local"},"peer":{"id":3,"value":"target"}}'
    ),
    (
        'keys_only_missing',
        'keys_only',
        true,
        false,
        true,
        true,
        'missing_on',
        23,
        '{"local":{"id":23,"value":"local"},"peer":null}'
    ),
    (
        'superset_extra',
        'superset',
        true,
        true,
        false,
        false,
        'extra_on',
        4,
        '{"local":null,"peer":{"id":4,"value":"target-only"}}'
    ),
    (
        'superset_missing',
        'superset',
        true,
        true,
        false,
        false,
        'missing_on',
        5,
        '{"local":{"id":5,"value":"local"},"peer":null}'
    );

CREATE TEMP TABLE pgl_validate_regress_action_seed(
    label text PRIMARY KEY,
    run_id bigint NOT NULL
);

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'keys_only_delete', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'keys_only_differs', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'keys_only_extra_without_delete', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'keys_only_missing', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'superset_extra', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'superset_missing', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'filtered_advisory_differs', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'filtered_intersection_differs', run_id
FROM run;

WITH run AS (
    INSERT INTO pgl_validate.run(status, started_at, finished_at, tables_total, tables_differ)
    VALUES ('completed', '2026-01-01 00:00:00+00', '2026-01-01 00:00:01+00', 1, 1)
    RETURNING run_id
)
INSERT INTO pgl_validate_regress_action_seed
SELECT 'filtered_intersection_missing', run_id
FROM run;

INSERT INTO pgl_validate.run_participant(run_id, node, role, backend, pg_version, status)
SELECT s.run_id, 'local', 'reference', 'native', current_setting('server_version_num')::int, 'done'
FROM pgl_validate_regress_action_seed s
UNION ALL
SELECT s.run_id, 'target', 'participant', 'native', current_setting('server_version_num')::int, 'done'
FROM pgl_validate_regress_action_seed s;

INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
SELECT s.run_id, 1
FROM pgl_validate_regress_action_seed s;

INSERT INTO pgl_validate.table_plan(
    run_id, schema_name, table_name, key_cols, att_list,
    repl_insert, repl_update, repl_delete, repl_truncate,
    validated_property
)
SELECT s.run_id,
       'public',
       'pgl_validate_regress_repair',
       ARRAY['id'],
       ARRAY['id','value'],
       c.repl_insert,
       c.repl_update,
       c.repl_delete,
       c.repl_truncate,
       c.validated_property
FROM pgl_validate_regress_action_seed s
JOIN pgl_validate_regress_action_case c USING (label);

INSERT INTO pgl_validate.divergence(
    run_id, schema_name, table_name, key_text, key_bytes,
    classification, node, status, detected_epoch, tuple, detected_at
)
SELECT s.run_id,
       'public',
       'pgl_validate_regress_repair',
       format('{"id": %s}', c.key_id),
       convert_to(format('{"id":%s}', c.key_id), 'UTF8'),
       c.classification,
       'target',
       'confirmed',
       1,
       c.tuple_doc,
       '2026-01-01 00:00:01+00'
FROM pgl_validate_regress_action_seed s
JOIN pgl_validate_regress_action_case c USING (label);

SELECT c.label,
       COALESCE(
           string_agg(
               CASE
                   WHEN g.stmt LIKE '% INSERT INTO %' THEN 'insert'
                   WHEN g.stmt LIKE '% UPDATE %' THEN 'update'
                   WHEN g.stmt LIKE '% DELETE FROM %' THEN 'delete'
                   ELSE 'other'
               END,
               ',' ORDER BY g.stmt
           ) FILTER (WHERE g.stmt IS NOT NULL),
           '<none>'
       ) AS repair_actions
FROM pgl_validate_regress_action_case c
JOIN pgl_validate_regress_action_seed s USING (label)
LEFT JOIN LATERAL pgl_validate.generate_repair(s.run_id, 'local') AS g(stmt) ON true
GROUP BY c.label
ORDER BY c.label;

SELECT report.doc->'run'->>'status' AS run_status,
       jsonb_array_length(report.doc->'tables') AS table_count,
       jsonb_array_length(report.doc->'schema_issues') AS issue_count,
       jsonb_array_length(report.doc->'sequences') AS sequence_count,
       jsonb_array_length(report.doc->'conflict_summary') AS conflict_summary_count,
       report.doc->'conflict_summary'->0->>'evidence_count' AS conflict_summary_evidence,
       report.doc->'tables'->0->'result'->>'verdict' AS table_verdict
FROM (
    SELECT pgl_validate.report((SELECT run_id FROM pgl_validate_regress_seed)) AS doc
) report;

SELECT pgl_validate.purge_conflict_evidence(
    '2026-01-01 00:00:00+00',
    (SELECT run_id FROM pgl_validate_regress_seed)
) AS purged_conflict_evidence;

SELECT evidence_count,
       matched_key_count,
       to_char(first_recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS first_recorded_at,
       to_char(last_recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS last_recorded_at,
       has_before_triggers
FROM pgl_validate.conflict_summary((SELECT run_id FROM pgl_validate_regress_seed));
