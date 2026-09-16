-- =============================================================================
-- VERIFICAR 20260915_0004 (Compras F1, proyección) — SOLO LECTURA
-- Correr DESPUÉS de aplicar 20260915_0003 y 20260915_0004, bloque por bloque.
-- La función es de solo lectura (stable): no escribe nada.
-- =============================================================================

-- 1) La función está.
select exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_purchase_projection'
)::text as fn_purchase_projection;

-- 2) La Penda, Almacén Principal, 7 días de cobertura: resumen.
select count(*)                                              as insumos_evaluados,
       count(*) filter (where suggested_base > 0)            as con_pedido_sugerido,
       count(*) filter (where lead_time_is_default)          as con_entrega_por_defecto,
       count(*) filter (where supplier_id is null and suggested_base > 0) as a_pedir_sin_suplidor,
       count(*) filter (where stock < 0)                     as con_existencia_negativa,
       round(sum(estimated_cost), 2)                         as costo_estimado_total,
       round(avg(window_days), 1)                            as dias_de_ventana_promedio
  from public.fn_purchase_projection(
         '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6',
         'f0cd4394-3bd9-4889-908c-686fd9ed67d2',   -- Almacen Principal
         7, 30, 2, 3, null, false);

-- 3) Los 20 renglones de mayor costo estimado, para revisar a ojo.
select item_name                    as insumo,
       unit                         as unidad,
       stock                        as existencia,
       in_transit                   as en_transito,
       on_order                     as ya_pedido,
       daily_consumption            as consumo_diario,
       window_days                  as dias,
       min_stock                    as minimo,
       lead_time_days               as entrega,
       suggested_base               as sugerido,
       supplier_name                as suplidor,
       purchase_unit                as unidad_compra,
       pack_size                    as contenido,
       estimated_cost               as costo_estimado
  from public.fn_purchase_projection(
         '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6',
         'f0cd4394-3bd9-4889-908c-686fd9ed67d2',
         7, 30, 2, 3, null, true)
 limit 20;
