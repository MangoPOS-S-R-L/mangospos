-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 6 — Verificación final y limpieza del staging.
--   Corre esto al terminar los pasos 1-5. Si algún 🚩 sale con filas, NO
--   borres el staging todavía: hace falta para reparar.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RESUMEN — todo debe cuadrar con la columna "esperado"
-- ---------------------------------------------------------------------------

select 'categorías'          as concepto, count(*) as encontrado, 4  as esperado
  from public.categories where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'productos activos', count(*), 54
  from public.menu_items where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and is_active
union all
select 'con ITBIS vinculado', count(distinct mit.item_id), 54
  from public.menu_item_taxes mit
  join public.menu_items mi on mi.id = mit.item_id and mi.is_active
  where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'con área de comanda', count(distinct mipa.menu_item_id), 54
  from public.menu_item_print_areas mipa
  join public.menu_items mi on mi.id = mipa.menu_item_id and mi.is_active
  where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'modificadores', count(*), 5
  from public.modifiers m
  join public.modifier_groups g on g.id = m.group_id
  where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and m.is_active
union all
select 'sándwiches con adicionales', count(*), 10
  from public.menu_item_groups mig
  join public.modifier_groups g on g.id = mig.group_id
  where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid;

-- ---------------------------------------------------------------------------
-- 🚩 LAS CUATRO RED FLAGS — todas deben dar 0 filas
-- ---------------------------------------------------------------------------

-- r1: productos SIN impuesto → facturarían ITBIS 0.00 ante la DGII
select 'SIN ITBIS' as problema, mi.name
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and not exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)

union all
-- r2: productos SIN área → no imprimen comanda
select 'SIN ÁREA', mi.name
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and not exists (select 1 from public.menu_item_print_areas x where x.menu_item_id = mi.id)

union all
-- r3: productos en 'exclusive' → cobrarían 18% ENCIMA del precio del menú
select 'PRECIO SIN IMPUESTO DENTRO', mi.name
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and mi.tax_mode <> 'inclusive'

union all
-- r4: nombres duplicados → el cajero no sabría cuál teclear
select 'NOMBRE DUPLICADO', mi.name
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
group by mi.name having count(*) > 1;

-- ---------------------------------------------------------------------------
-- El catálogo completo, para revisar contra el menú impreso
-- ---------------------------------------------------------------------------

select c.position as orden, c.name as categoria, mi.name as producto,
       mi.price as precio, a.name as area,
       case when exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)
            then 'sí' else '🚩 NO' end as itbis
from public.menu_items mi
join public.categories c on c.id = mi.category_id
left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
left join public.print_areas a on a.id = mipa.print_area_id
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
order by c.position, mi.position;

-- ---------------------------------------------------------------------------
-- LIMPIEZA — solo si todo lo de arriba está en verde.
-- OJO: sin el staging, 99_rollback.sql ya no puede identificar qué borrar.
-- Guárdate el listado de arriba antes.
-- ---------------------------------------------------------------------------

-- drop table if exists public._import_e0aef218;
