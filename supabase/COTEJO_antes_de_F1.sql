-- =============================================================================
-- COTEJO OBLIGATORIO ANTES DE APLICAR 20260901_0003_consume_by_area.sql
--
-- La base viva diverge del repositorio. Estas cuatro consultas traen la
-- definición REAL de lo que F1 va a tocar o mirar. Correr UNA a la vez —el
-- SQL Editor solo muestra la última— y pasarme la salida.
--
-- Qué busco en cada una:
--   1. Si `consume_inventory_from_order` viva tiene algo que el repo no
--      tiene, hay que traerlo a la 0003 o se pierde en silencio.
--   2. Si `v_menu_items_stock` suma TODAS las bodegas (esperado), el auto-86
--      va a mentir cuando el stock esté en Cocina y no en la principal.
--   3. Confirmar que el trigger de recálculo existe y sobre qué dispara.
--   4. Confirmar que existen las dependencias de F1.
-- =============================================================================

-- 1) El motor de consumo, tal como está HOY en producción.
select pg_get_functiondef(
  'public.consume_inventory_from_order(uuid)'::regprocedure) as definicion_viva;

-- 2) La vista de stock que alimenta el auto-86.
select pg_get_viewdef('public.v_menu_items_stock'::regclass, true) as vista_viva;

-- 3) La función de recálculo de disponibilidad y su trigger.
select pg_get_functiondef(p.oid) as definicion
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'fn_recompute_menu_items_availability';

-- 4) Dependencias de F1: ¿están las columnas que necesita?
select 'print_areas.display_order' as dependencia,
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='print_areas'
                  and column_name='display_order') as existe
union all
select 'warehouses.production_area_id',
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='warehouses'
                  and column_name='production_area_id')
union all
select 'business_settings.warehouse_sections_enabled',
       exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='business_settings'
                  and column_name='warehouse_sections_enabled')
union all
select 'tabla menu_item_print_areas',
       exists (select 1 from information_schema.tables
                where table_schema='public'
                  and table_name='menu_item_print_areas');
