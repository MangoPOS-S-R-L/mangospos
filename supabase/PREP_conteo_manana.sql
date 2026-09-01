-- =============================================================================
-- PREPARACIÓN DEL PRIMER CONTEO FÍSICO
-- La base ya está lista (ver VERIFICAR_conteo_fisico.sql, verificado 2026-08-31).
-- Esto revisa el CATÁLOGO, que es lo que tuerce un primer conteo.
--
-- OJO: el SQL Editor de Supabase solo muestra el resultado de la ÚLTIMA
-- sentencia. Corre UNA a la vez.
-- =============================================================================

-- 0) Tu business_id y tu almacén (debe ser uno solo).
select b.id as business_id, b.business_name, w.id as warehouse_id,
       w.name as almacen, w.is_main
  from public.businesses b
  join public.warehouses w on w.business_id = b.id and coalesce(w.is_active, true)
 order by b.business_name, w.is_main desc;

-- 1) Panorama del catálogo a contar.
select count(*)                                          as insumos_activos,
       count(*) filter (where coalesce(cost, 0) = 0)     as sin_costo,
       count(*) filter (where coalesce(min_stock, 0) = 0) as sin_minimo,
       count(*) filter (where sku is null or sku = '')    as sin_sku
  from public.inventory_items
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true);

-- 2) Unidades ambiguas: quien cuenta no sabe si anota botellas, onzas o ml.
--    Estos son los que hay que aclarar ANTES de imprimir la hoja de conteo.
select coalesce(nullif(unit, ''), '(vacía)') as unidad,
       count(*)                              as insumos
  from public.inventory_items
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true)
 group by 1
 order by 2 desc;

-- 3) Insumos con costo cero: el conteo funciona, pero la diferencia sale
--    valuada en cero y se pierde la mitad del valor del ejercicio.
select sku, name, unit, cost
  from public.inventory_items
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true)
   and coalesce(cost, 0) = 0
 order by name
 limit 200;

-- 4) Sesiones de conteo abiertas que estorben mañana.
select id, code, status, warehouse_id, is_blind, created_at
  from public.physical_count_sessions
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and status not in ('completed', 'cancelled')
 order by created_at desc;
