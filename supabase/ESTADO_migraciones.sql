-- =============================================================================
-- ¿Qué de lo escrito estos dos días está realmente aplicado?
-- Una sola consulta. Todo lo que salga `false` está pendiente.
-- =============================================================================

select 'F0  20260901_0001 secciones de bodega' as migracion,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='warehouses'
                  and column_name='production_area_id') as aplicada
union all
select 'F1  20260901_0002 resolvedor de área',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public'
                  and p.proname='fn_resolve_consumption_warehouse')
union all
select 'F1  20260901_0004 disponibilidad por área',
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='warehouses'
                  and column_name='shows_in_pos')
union all
select 'F1b 20260901_0005 bodega del punto de venta',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='fn_resolve_area_warehouse')
       or not exists (select 1 from pg_indexes where schemaname='public'
                       and indexname='uq_warehouses_pos_source')
union all
select 'F1c 20260901_0006 varias bodegas + cascada',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='fn_pos_stock_warehouses')
union all
select 'F2  20260902_0001 requisiciones',
       exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='requisitions')
union all
select '--  20260902_0003 conteo masivo',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='fn_physical_count_zero_pending')
union all
select '--  20260819_0001 mínimo por bodega',
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='inventory_stock'
                  and column_name='min_stock')
union all
select '--  20260819_0002 copiar lista de insumos',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='fn_inventory_copy_warehouse_items')
union all
select '--  20260819_0003 términos y catálogo de suplidores',
       exists (select 1 from information_schema.tables
                where table_schema='public' and table_name='supplier_items');
