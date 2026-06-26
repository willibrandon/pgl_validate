\set ON_ERROR_STOP on
\pset null '<null>'

DROP TABLE IF EXISTS public.pgl_validate_regress_plan;
DROP TABLE IF EXISTS public.pgl_validate_regress_composite;

CREATE TABLE public.pgl_validate_regress_plan(
    status text,
    id int PRIMARY KEY,
    amount numeric
);

INSERT INTO public.pgl_validate_regress_plan(status, id, amount)
VALUES
    ('before', 1, 9.50),
    ('inside-low', 2, 10.25),
    ('inside-high', 9, 11.50),
    ('after', 10, 12.00);

SELECT pgl_validate.plan_chunk_sql(
    'public.pgl_validate_regress_plan'::regclass,
    ARRAY['id'],
    convert_to('{"id":2}', 'UTF8'),
    convert_to('{"id":10}', 'UTF8'),
    ARRAY['status','id','amount'],
    NULL,
    'id >= 1',
    true,
    'blake3_512'
) AS checksum_sql;

SELECT string_agg(
           chunk_id::text || ':' ||
           COALESCE(convert_from(lo, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
           COALESCE(convert_from(hi, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
           n_rows::text,
           ',' ORDER BY chunk_id
       ) AS planned_ranges
FROM pgl_validate.plan_key_ranges(
    'public.pgl_validate_regress_plan'::regclass,
    ARRAY['id'],
    NULL,
    NULL,
    2
);

CREATE TABLE public.pgl_validate_regress_composite(
    part int NOT NULL,
    code text NOT NULL,
    amount int,
    PRIMARY KEY (part, code)
);

INSERT INTO public.pgl_validate_regress_composite(part, code, amount)
VALUES
    (1, 'a', 10),
    (1, 'b', 20),
    (2, 'a', 30),
    (2, 'b', 40);

SELECT pgl_validate.plan_key_range_predicate(
    'public.pgl_validate_regress_composite'::regclass,
    ARRAY['part','code'],
    convert_to('{"part":1,"code":"b"}', 'UTF8'),
    convert_to('{"part":2,"code":"b"}', 'UTF8')
) AS composite_predicate;

SELECT pgl_validate.plan_localize_sql(
    'public.pgl_validate_regress_composite'::regclass,
    ARRAY['part','code'],
    convert_to('{"part":1,"code":"b"}', 'UTF8'),
    convert_to('{"part":2,"code":"b"}', 'UTF8'),
    ARRAY['part','code','amount'],
    NULL,
    'blake3_256'
) AS localize_sql;
