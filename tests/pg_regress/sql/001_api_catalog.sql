\set ON_ERROR_STOP on
\pset null '<null>'
\pset format unaligned

SELECT 'extension' AS subject, extversion
FROM pg_extension
WHERE extname = 'pgl_validate';

SELECT p.proname,
       p.prokind,
       oidvectortypes(p.proargtypes) AS args,
       p.provolatile,
       p.proparallel
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgl_validate'
  AND p.proname IN (
      'apply_repair',
      'cleanup_fence_barriers',
      'compare',
      'compare_table',
      'generate_repair',
      'hash_digest_array',
      'lthash',
      'metrics',
      'report',
      'row_digest'
  )
ORDER BY p.proname, oidvectortypes(p.proargtypes);

SELECT name, set_config(name, setting, true) AS setting
FROM (
    VALUES
        ('pgl_validate.allow_degraded_fence', 'off'),
        ('pgl_validate.allow_approximate_filters', 'off'),
        ('pgl_validate.chunk_target_rows', '64'),
        ('pgl_validate.fence_timeout_ms', '1000'),
        ('pgl_validate.hash_algorithm', 'blake3_256'),
        ('pgl_validate.recheck_passes', '2'),
        ('pgl_validate.split_fanout', '4')
) AS required_setting(name, setting)
ORDER BY name;

SELECT table_name
FROM information_schema.views
WHERE table_schema = 'pgl_validate'
ORDER BY table_name;

SELECT octet_length(pgl_validate.row_digest(ARRAY[1], 1::int4)) AS row_digest_bytes,
       octet_length(pgl_validate.hash_digest_array(ARRAY[
           pgl_validate.row_digest(ARRAY[1], 1::int4)
       ])) AS set_hash_bytes,
       (
           pgl_validate.row_digest(ARRAY[2], NULL::text)
           <> pgl_validate.row_digest(ARRAY[2], ''::text)
       ) AS null_differs_from_empty;

CREATE TEMP TABLE pgl_validate_regress_control AS
WITH run AS (
    INSERT INTO pgl_validate.run(status)
    VALUES ('running')
    RETURNING run_id
)
SELECT run_id
FROM run;

SELECT pgl_validate.pause(run_id) AS paused
FROM pgl_validate_regress_control;

SELECT pgl_validate.resume(run_id) AS resumed
FROM pgl_validate_regress_control;

SELECT pgl_validate.cancel(run_id) AS canceled
FROM pgl_validate_regress_control;

SELECT r.status AS final_status,
       r.finished_at IS NOT NULL AS finished
FROM pgl_validate.run r
JOIN pgl_validate_regress_control c USING (run_id);
