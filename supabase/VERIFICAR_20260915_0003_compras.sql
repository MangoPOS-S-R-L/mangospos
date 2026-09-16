-- =============================================================================
-- VERIFICAR 20260915_0003 (Compras F0) — SOLO LECTURA
-- Correr DESPUÉS de aplicar la migración, cada bloque por separado.
-- La función del bloque 2 y 3 es de solo lectura (stable): no escribe nada.
-- =============================================================================

-- 1) Piezas de la migración.
select 'fn_purchase_order_create' as pieza,
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'fn_purchase_order_create')::text as esta
union all
select 'fn_purchase_resolve_suppliers',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'fn_purchase_resolve_suppliers')::text
union all
select 'purchase_orders.idempotency_key (+ índice único)',
       (exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'purchase_orders'
                   and column_name = 'idempotency_key')
        and to_regclass('public.idx_purchase_orders_idempotency') is not null)::text
union all
select 'inventory_items.preferred_supplier_id',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'inventory_items'
                  and column_name = 'preferred_supplier_id')::text
union all
select 'purchase_orders: invoice_number, discount, ncf',
       (count(*) = 3)::text
  from information_schema.columns
 where table_schema = 'public' and table_name = 'purchase_orders'
   and column_name in ('invoice_number', 'discount', 'ncf')
union all
select 'purchase_order_items: discount, purchase_unit, pack_size',
       (count(*) = 3)::text
  from information_schema.columns
 where table_schema = 'public' and table_name = 'purchase_order_items'
   and column_name in ('discount', 'purchase_unit', 'pack_size');

-- 2) La Penda: de dónde saldría HOY el suplidor de cada insumo activo.
--    Con el maestro vacío se espera casi todo en «ultima_compra» o «sin suplidor».
select coalesce(r.supplier_source, 'sin suplidor') as de_donde_sale_el_suplidor,
       count(*)                                    as insumos
  from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6') r
  join public.inventory_items ii on ii.id = r.item_id and coalesce(ii.is_active, true)
 group by 1
 order by 2 desc;

-- 3) La Penda: de dónde saldría el costo, y una muestra de lo más reciente.
select coalesce(r.cost_source, 'sin costo') as de_donde_sale_el_costo,
       count(*)                             as insumos
  from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6') r
  join public.inventory_items ii on ii.id = r.item_id and coalesce(ii.is_active, true)
 group by 1
 order by 2 desc;

select ii.name              as insumo,
       r.supplier_name      as suplidor,
       r.supplier_source    as por,
       r.purchase_unit      as unidad_compra,
       r.pack_size          as contenido,
       round(r.unit_cost_base, 4) as costo_base,
       r.cost_source        as costo_de,
       r.last_purchase_at::date as ultima_compra
  from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6') r
  join public.inventory_items ii on ii.id = r.item_id
 where r.supplier_id is not null
 order by r.last_purchase_at desc nulls last
 limit 15;
