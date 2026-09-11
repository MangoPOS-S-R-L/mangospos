-- =============================================================================
-- LA PENDA EXPRESS · PASO 4 — ¿Existe la infraestructura de almacenes por área?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA.
--
-- Hallazgo: la infraestructura YA ESTA DISENADA en el repo (20260901_0001,
-- _0002, _0003, _0006): bodega por area de produccion, resolvedor de bodega,
-- consumo que reparte en cascada, y una bandera para prenderlo.
-- Falta saber si esta APLICADA en prod, y a que print_areas se mapean las
-- areas del conteo.
-- =============================================================================

-- A ─── ¿Están aplicadas las migraciones de almacenes por sección? ────────────
--     ESPERADO si están: las 4 columnas + la bandera + las 3 funciones.
--     OJO: fn_resolve_consumption_warehouse lleva TRES uuid, no dos.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='warehouses'
      and column_name in ('warehouse_type','production_area_id',
                          'keeper_employee_id','requires_requisition'))  as cols_warehouses_de_4,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='business_settings'
      and column_name = 'warehouse_sections_enabled')                    as tiene_bandera,
  to_regprocedure('public.fn_resolve_consumption_warehouse(uuid,uuid,uuid)') is not null as fn_resolve_consumo,
  to_regprocedure('public.fn_resolve_area_warehouse(uuid,uuid)')        is not null as fn_resolve_area,
  to_regprocedure('public.fn_pos_stock_warehouses(uuid,uuid)')          is not null as fn_pos_stock;


-- B ─── ¿Está prendida la bandera? ───────────────────────────────────────────
--     Tiene que estar APAGADA hasta que los almacenes tengan su stock cargado.
select bs.warehouse_sections_enabled
from public.business_settings bs
where bs.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- C ─── Las áreas de producción que ya existen (print_areas) ─────────────────
--     A ESTAS hay que amarrar los almacenes. Si Cocina/Bar/Food Shop no
--     aparecen aquí, primero hay que crearlas o usar las que haya.
select pa.id, pa.code, pa.name, pa.is_active,
       (select count(*) from public.menu_item_print_areas mpa
         where mpa.print_area_id = pa.id)                    as productos_ruteados
from public.print_areas pa
where pa.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by pa.is_active desc, productos_ruteados desc;


-- D ─── ¿Rosayra y Winnifer contaron lo MISMO o cosas distintas? ─────────────
--     Si el solapamiento es bajo, se repartieron el Food Shop y SUMAR es
--     correcto. Si es alto, contaron lo mismo dos veces y hay que elegir.
with r as (
  select l.item_id, l.counted_quantity
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.code = 'PC-2026-000005' and l.counted_quantity is not null
),
w as (
  select l.item_id, l.counted_quantity
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.code = 'PC-2026-000004' and l.counted_quantity is not null
)
select
  (select count(*) from r)                                   as rosayra,
  (select count(*) from w)                                   as winnifer,
  (select count(*) from r join w on w.item_id = r.item_id)   as EN_LAS_DOS,
  (select count(*) from r join w on w.item_id = r.item_id
     where abs(r.counted_quantity - w.counted_quantity) > 0.001) as con_cantidad_DISTINTA;


-- E ─── Los insumos que contaron las dos, lado a lado ────────────────────────
select i.name as insumo, i.unit,
       r.counted_quantity as rosayra, w.counted_quantity as winnifer,
       round(r.counted_quantity + w.counted_quantity, 2) as si_se_suma
from public.physical_count_lines r
join public.physical_count_sessions sr on sr.id = r.session_id and sr.code = 'PC-2026-000005'
join public.physical_count_lines w on w.item_id = r.item_id
join public.physical_count_sessions sw on sw.id = w.session_id and sw.code = 'PC-2026-000004'
join public.inventory_items i on i.id = r.item_id
where r.counted_quantity is not null and w.counted_quantity is not null
order by (r.counted_quantity + w.counted_quantity) desc
limit 50;


-- F ─── Solapamiento de TODAS contra TODAS ────────────────────────────────────
--     El mapa completo: qué par de áreas contó los mismos insumos.
with c as (
  select s.code, coalesce(s.notes,'(sin area)') as area, l.item_id
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress' and l.counted_quantity is not null
)
select a.area as area_a, b.area as area_b, count(*) as insumos_en_comun
from c a
join c b on b.item_id = a.item_id and b.code > a.code
group by a.area, b.area
order by insumos_en_comun desc;
