-- =============================================================================
-- LA PENDA EXPRESS — meter los insumos nuevos en un conteo YA CONGELADO
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ: `fn_physical_count_freeze` arma las líneas con los insumos activos
-- DEL MOMENTO en que se congela. Los 1,147 que creó la activación de
-- "Inventariable" nacieron después, así que no están en la sesión abierta.
--
-- Si la sesión todavía está en `draft`, NO corras nada de esto: congelá y
-- listo, el congelado los va a tomar a todos.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿Qué sesiones hay y cuántas líneas tienen?
-- ---------------------------------------------------------------------------
select
  s.id,
  s.code,
  s.status,
  w.name                                  as bodega,
  s.frozen_at,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id)            as lineas,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id
      and l.counted_quantity is not null) as ya_contadas
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by s.started_at desc
limit 10;


-- ---------------------------------------------------------------------------
-- 2. RECARGAR — agrega a las sesiones `in_progress` los insumos activos que
--    falten, con el stock actual de esa bodega como snapshot (0 si no tiene
--    fila, el mismo criterio del left join del congelado).
--
--    Es EXACTAMENTE el insert del congelado, acotado a las sesiones abiertas.
--    Idempotente por el unique (session_id, item_id): lo que ya está no se
--    toca, y NINGUNA cantidad ya contada se pierde.
-- ---------------------------------------------------------------------------
insert into public.physical_count_lines (session_id, item_id, snapshot_quantity)
select
  s.id,
  ii.id,
  coalesce(st.quantity, 0)
from public.physical_count_sessions s
join public.inventory_items ii
  on ii.business_id = s.business_id
 and coalesce(ii.is_active, true)
left join public.inventory_stock st
  on st.item_id = ii.id
 and st.warehouse_id = s.warehouse_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
on conflict (session_id, item_id) do nothing;


-- ---------------------------------------------------------------------------
-- 3. VERIFICAR — cuántas líneas quedaron y cuántas están sin contar.
-- ---------------------------------------------------------------------------
select
  s.code,
  count(l.*)                                            as lineas_totales,
  count(l.*) filter (where l.counted_quantity is not null) as contadas,
  count(l.*) filter (where l.counted_quantity is null)     as pendientes
from public.physical_count_sessions s
join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
group by s.code;
