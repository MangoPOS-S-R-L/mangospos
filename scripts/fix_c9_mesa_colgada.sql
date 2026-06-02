-- =============================================================================
-- Fix mesa C9 colgada (FANTASMA pagado) — Business 33207ebd-985d-455c-bdbb-1b38af8b36ea
-- =============================================================================
-- C9 fue un split bill: sus 4 items están 'paid' y los checks cerrados, pero la
-- orden y la sesión nunca se cerraron, así que la mesa sigue ocupada/azul.
-- fn_close_order_and_table la cierra como 'paid', cierra la sesión y libera la mesa.
--
-- Listo para correr tal cual. Si el "después" no se ve bien, ejecuta ROLLBACK
-- en vez de COMMIT (la transacción queda abierta hasta que confirmes).
-- =============================================================================

begin;

-- 1) ANTES: estado de la orden / sesión / mesa de C9.
select 'ANTES' as momento,
       o.id as order_id, o.status_ext, o.closed_at,
       ts.closed_at as session_closed_at, ts.precheck_printed_at,
       dt.code as mesa, dt.state
from public.orders o
join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
where o.id = 'af942d37-1c6b-4fc8-8ddf-586ad02327a4';

-- 2) Cerrar la orden como pagada + cerrar sesión + liberar mesa.
select public.fn_close_order_and_table(
  'af942d37-1c6b-4fc8-8ddf-586ad02327a4'::uuid,
  'paid'::public.order_status
);

-- 3) DESPUÉS: debe quedar status_ext='paid', closed_at lleno,
--    session_closed_at lleno y state='available'.
select 'DESPUES' as momento,
       o.id as order_id, o.status_ext, o.closed_at,
       ts.closed_at as session_closed_at, ts.precheck_printed_at,
       dt.code as mesa, dt.state
from public.orders o
join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
where o.id = 'af942d37-1c6b-4fc8-8ddf-586ad02327a4';

commit;
-- rollback;  -- usa esto en vez de commit si el "DESPUES" no se ve bien.
