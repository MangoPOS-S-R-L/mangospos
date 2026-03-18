SELECT 
    t.code,
    s.id as session_id,
    s.opened_by
FROM public.dining_tables t
LEFT JOIN LATERAL (
    SELECT s2.id, s2.opened_by
    FROM public.table_sessions s2
    WHERE s2.table_id = t.id AND s2.closed_at IS NULL
    ORDER BY s2.opened_at DESC
    LIMIT 1
) s ON true
WHERE t.code IN ('SP01', 'SP02', 'SP03');

SELECT COUNT(*) as v_status_count FROM v_zone_table_status;
