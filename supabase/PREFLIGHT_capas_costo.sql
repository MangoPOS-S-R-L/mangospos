-- =============================================================================
-- PREFLIGHT — antes de aplicar 20260902_0012 y 20260902_0013 (capas de costo).
-- Correr COMPLETO en el SQL Editor de Supabase y leer las 8 salidas.
-- No escribe nada.
--
-- La BD viva ha divergido del repo antes, así que esto verifica supuestos,
-- no los asume.
-- =============================================================================

-- 1. ¿Existen ya objetos con estos nombres? Debe devolver 0 filas.
select 'objeto ya existe' as alerta, c.relname, c.relkind
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in (
     'inventory_cost_layers', 'inventory_cost_consumptions',
     'v_inventory_valuation_layers', 'v_inventory_cost_of_sales',
     'v_inventory_cost_shortfalls'
   );

-- 2. Triggers vivos sobre inventory_movements.
--    Esperado: trg_inventory_movement_recost y trg_inventory_stock_sync.
--    NO debe aparecer trg_inventory_cost_layers.
select t.tgname, p.proname as funcion, t.tgenabled
  from pg_trigger t
  join pg_proc p on p.oid = t.tgfoid
 where t.tgrelid = 'public.inventory_movements'::regclass
   and not t.tgisinternal
 order by t.tgname;

-- 3. ¿El trigger de recosteo vivo es el de ÚLTIMO PRECIO?
--    Debe contener 'set cost = round(new.cost_per_unit' y NO 'weighted'.
select pg_get_functiondef('public.fn_inventory_movement_recost'::regproc)
         as cuerpo_vivo_recost;

-- 4. Dependencias de esquema que la migración da por hechas.
select 'business_settings.inventory_costing_method' as objeto,
       to_regclass('public.business_settings') is not null as tabla_existe,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='business_settings'
                  and column_name='inventory_costing_method') as columna_ya_existe
union all
select 'purchase_receptions (mig 20260828_0001)',
       to_regclass('public.purchase_receptions') is not null,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='purchase_receptions'
                  and column_name='ncf')
union all
select 'purchase_orders.ncf (mig 20260814_0003)',
       to_regclass('public.purchase_orders') is not null,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='purchase_orders'
                  and column_name='ncf')
union all
select 'physical_count_lines',
       to_regclass('public.physical_count_lines') is not null,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='physical_count_lines'
                  and column_name='counted_quantity');

-- 5. ¿Existe la fila de business_settings de LA PENDA EXPRESS?
--    Sin fila, el motor queda apagado aunque se aplique todo.
select business_id,
       coalesce(require_goods_receipt, false) as require_goods_receipt,
       cost_variance_threshold_pct
  from public.business_settings
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

-- 6. Sesiones de conteo del 01-09: cuáles sirven de apertura.
select s.id,
       s.code,
       w.name                                   as bodega,
       s.status,
       s.frozen_at,
       s.completed_at,
       count(l.id)                              as lineas_totales,
       count(l.id) filter (where l.counted_quantity is not null)
                                                as lineas_contadas,
       count(l.id) filter (where coalesce(l.counted_quantity,0) > 0)
                                                as lineas_con_existencia,
       round(sum(coalesce(l.counted_quantity,0))::numeric, 2)
                                                as unidades_contadas
  from public.physical_count_sessions s
  join public.warehouses w on w.id = s.warehouse_id
  left join public.physical_count_lines l on l.session_id = s.id
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.status in ('in_progress', 'completed')
 group by s.id, s.code, w.name, s.status, s.frozen_at, s.completed_at
 order by s.frozen_at nulls last;

-- 7. Cuánto respaldo documental hay para valorar la apertura.
--    'con NCF' es lo que el Art. 57 del Regl. 139-98 acepta como sustento.
with compras as (
  select m.item_id,
         max(m.created_at) filter (
           where m.reference_type = 'purchase_reception_line') as ult_recepcion,
         max(m.created_at) filter (
           where coalesce(m.cost_per_unit,0) > 0)              as ult_con_costo
    from public.inventory_movements m
   where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and m.movement_type = 'purchase'
   group by m.item_id
)
select count(*)                                        as items_con_compras,
       count(*) filter (where ult_recepcion is not null) as con_recepcion_conduce,
       count(*) filter (where ult_con_costo is not null) as con_algun_costo
  from compras;

-- 8. Tamaño del trabajo: movimientos que el motor tocará de aquí en adelante.
select count(*)                                          as movimientos_totales,
       count(*) filter (where created_at >= date '2026-09-01')
                                                         as desde_septiembre,
       count(*) filter (where movement_type = 'sale')     as salidas_por_venta,
       count(*) filter (where movement_type = 'sale'
                          and cost_per_unit is not null)  as ventas_con_costo
  from public.inventory_movements
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
