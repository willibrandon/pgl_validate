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
