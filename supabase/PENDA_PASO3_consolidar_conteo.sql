-- =============================================================================
-- LA PENDA EXPRESS · PASO 3 — Cómo consolidar las 5 sesiones del conteo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA.
--
-- CONTEXTO (medido en el paso 1):
--   * 5 sesiones in_progress, TODAS sobre el mismo almacen, cada una con copia
--     completa del catalogo (~2.294 lineas). El area vive en session.notes.
--   * 874 lineas contadas en total, sobre 2.297 insumos activos.
--   * El sistema YA descuenta ventas y suma compras desde el 5-jul: el
--     rollforward manual sobra y seria doble descuento.
--
-- Lo que hay que decidir: si dos equipos contaron el MISMO insumo, se suma o
-- se pisa. Esto lo mide.
-- =============================================================================

-- A ─── ¿Cuántos insumos ÚNICOS se contaron, y cuántos por más de un equipo? ──
--     Si `en_2_o_mas` es alto, NO se puede consolidar sumando a ciegas.
with contadas as (
  select l.item_id, s.code, coalesce(s.notes, '(sin area)') as area, l.counted_quantity
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress'
    and l.counted_quantity is not null
),
por_item as (
  select item_id, count(distinct code) as sesiones, sum(counted_quantity) as suma,
         max(counted_quantity) as maximo
  from contadas group by item_id
)
select
  count(*)                                        as insumos_unicos_contados,
  count(*) filter (where sesiones = 1)            as en_una_sola_sesion,
  count(*) filter (where sesiones >= 2)           as en_2_o_mas_OJO,
  round(sum(suma), 2)                             as si_se_SUMA,
  round(sum(maximo), 2)                           as si_se_toma_el_MAYOR,
  (select count(*) from public.inventory_items i
    where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(i.is_active, true))            as insumos_activos_total
from por_item;


-- B ─── Los que contó más de un equipo, uno por uno ───────────────────────────
--     Si las cantidades son distintas, alguien contó mal o son áreas distintas
--     del mismo insumo (y entonces SÍ se suma).
with contadas as (
  select l.item_id, coalesce(s.notes, '(sin area)') as area, l.counted_quantity
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress' and l.counted_quantity is not null
)
select i.name as insumo, i.unit,
       count(*)                                   as equipos,
       string_agg(c.area || ': ' || c.counted_quantity, '  |  '
                  order by c.counted_quantity desc) as detalle,
       round(sum(c.counted_quantity), 2)          as suma,
       round(max(c.counted_quantity), 2)          as mayor
from contadas c
join public.inventory_items i on i.id = c.item_id
group by i.id, i.name, i.unit
having count(*) >= 2
order by count(*) desc, sum(c.counted_quantity) desc
limit 60;


-- C ─── LO QUE SE VENDE Y NADIE CONTÓ ─────────────────────────────────────────
--     Insumos con movimiento de venta que NO tienen ni una línea contada.
--     Esta es la respuesta directa a tu pregunta, ordenada por rotación.
with contados as (
  select distinct l.item_id
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress' and l.counted_quantity is not null
),
vendidos as (
  select m.item_id,
         round(sum(abs(m.quantity)), 2) as unidades_vendidas,
         count(*)                       as movimientos,
         max(m.created_at)              as ultima_venta
  from public.inventory_movements m
  where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and m.movement_type = 'sale'
  group by m.item_id
)
select i.name as insumo, i.unit, i.cost,
       v.unidades_vendidas, v.movimientos,
       (v.ultima_venta at time zone 'America/Santo_Domingo')::date as ultima_venta,
       coalesce(st.quantity, 0)                                     as stock_que_dice_el_sistema
from vendidos v
join public.inventory_items i on i.id = v.item_id
left join public.inventory_stock st
       on st.item_id = v.item_id
      and st.warehouse_id = 'f0cd4394-3bd9-4889-908c-686fd9ed67d2'
where v.item_id not in (select item_id from contados)
order by v.unidades_vendidas desc
limit 100;


-- D ─── El resumen de C: cuánta rotación quedó sin contar ─────────────────────
with contados as (
  select distinct l.item_id
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress' and l.counted_quantity is not null
),
vendidos as (
  select m.item_id, sum(abs(m.quantity)) as u
  from public.inventory_movements m
  where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and m.movement_type = 'sale'
  group by m.item_id
)
select
  case when v.item_id in (select item_id from contados) then 'contado'
       else 'SIN CONTAR' end                          as estado,
  count(*)                                            as insumos,
  round(sum(v.u), 2)                                  as unidades_vendidas,
  round(100.0 * sum(v.u) / sum(sum(v.u)) over (), 1)   as pct_de_la_rotacion
from vendidos v
group by 1
order by unidades_vendidas desc;


-- E ─── ¿Qué era la sesión cancelada "Articulos no registrados"? ──────────────
--     0 contadas y 2.249 lineas. Ver si dejó algo antes de cancelarse.
select s.code, s.status, s.notes,
       (s.started_at at time zone 'America/Santo_Domingo') as abierta,
       (s.frozen_at  at time zone 'America/Santo_Domingo') as congelada,
       count(l.*)                                          as lineas,
       count(l.*) filter (where l.counted_quantity is not null) as con_dato,
       round(sum(coalesce(l.snapshot_quantity, 0)), 2)     as snapshot_total
from public.physical_count_sessions s
left join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'cancelled'
group by s.id, s.code, s.status, s.notes, s.started_at, s.frozen_at;
