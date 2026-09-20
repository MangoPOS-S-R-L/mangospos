-- =============================================================================
-- DIAGNÓSTICO: "las ventas de hoy de un mesero no salen en el reporte"
--
-- Hipótesis: el reporte cortaba el día en UTC (oi.created_at::date), o sea a
-- las 8:00 PM hora RD. Todo lo vendido después de esa hora se iba al día
-- siguiente. La caja abierta/cerrada NO es un filtro del reporte.
--
-- OJO: el SQL Editor de Supabase muestra SOLO el último resultado.
--      Corre la CONSULTA 1 sola, mira el resultado, y después la CONSULTA 2.
--
-- Edita el business_id en el único lugar marcado abajo.
-- =============================================================================

-- ############ CONSULTA 1 — ¿cuántos ítems se pierde el reporte por día? #####
-- Negocio 6d13ed3f (el de la caja bloqueada / cotización Vocatus).
-- Últimos 7 días locales = el rango que el reporte trae por defecto.
-- `dia_utc` usa `at time zone 'UTC'` explícito: el veredicto NO depende
-- del timezone de la sesión del SQL Editor.

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    (now() at time zone 'America/Santo_Domingo')::date as hoy
),
items as (
  select
    ((oi.created_at at time zone 'America/Santo_Domingo')::date) as dia_local,
    ((oi.created_at at time zone 'UTC')::date) as dia_utc,
    coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) as emp_id,
    oi.created_at,
    (oi.subtotal + oi.tax - coalesce(oi.discounts, 0)) as neto
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join params p
  where ts.business_id = p.bid
    and oi.status <> 'void'
    and o.status_ext is distinct from 'void'
    and oi.created_at >= ((p.hoy - 6)::timestamp at time zone 'America/Santo_Domingo')
    and oi.created_at <  ((p.hoy + 1)::timestamp at time zone 'America/Santo_Domingo')
)
select
  i.dia_local,
  coalesce(
    nullif(btrim(e.first_name || ' ' || coalesce(e.last_name, '')), ''),
    '(ÍTEMS SIN MESERO ATRIBUIDO)'
  ) as mesero,
  count(*) as items_del_dia,
  count(*) filter (where i.dia_utc =  i.dia_local) as los_ve_el_reporte,
  count(*) filter (where i.dia_utc <> i.dia_local) as se_pierden_por_utc,
  round(sum(i.neto), 2) as neto_del_dia,
  round(sum(i.neto) filter (where i.dia_utc <> i.dia_local), 2) as neto_que_no_sale,
  min(i.created_at at time zone 'America/Santo_Domingo')::time(0) as primer_item,
  max(i.created_at at time zone 'America/Santo_Domingo')::time(0) as ultimo_item,
  current_setting('TimeZone') as tz_de_esta_sesion
from items i
left join public.employees e on e.id = i.emp_id
group by i.dia_local, 2
order by i.dia_local desc, neto_del_dia desc nulls last;

-- Lectura:
--   se_pierden_por_utc > 0  -> es el corte de día; aplica la migración
--                              20260919_0004_sales_by_waiter_local_day.sql
--   fila "(ÍTEMS SIN MESERO ATRIBUIDO)" -> esos ítems NUNCA salen en el
--                              reporte por mesero (ni con el fix): no tienen
--                              created_by_employee_id ni opened_by_employee_id.
--   0 filas -> el problema no es el reporte; revisa que las órdenes tengan
--              session_id (las ventas rápidas sin mesa no entran nunca).


-- ############ CONSULTA 2 — ¿qué versión de la función hay VIVA? ##############
-- (la BD viva puede diverger del repo; confirma antes de aplicar nada)

select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as firma,
  pg_get_functiondef(p.oid) as definicion
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('fn_sales_by_waiter', 'fn_sales_by_waiter_products')
order by p.proname, firma;

-- Si en `definicion` aparece `oi.created_at::date between` -> está el bug.
-- Si aparecen DOS firmas de fn_sales_by_waiter -> PostgREST tira PGRST203;
-- la migración 20260919_0004 ya hace el drop de la vieja de 3 args.
