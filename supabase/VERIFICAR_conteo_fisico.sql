-- =============================================================================
-- VERIFICACIÓN PREVIA AL PRIMER CONTEO FÍSICO
-- Correr en Supabase Studio → SQL Editor ANTES de aplicar nada.
-- Dice si `20260801_0002_physical_count_blind_recount.sql` ya está en la base.
-- =============================================================================

-- 1) Firmas de las funciones del conteo.
--    ESPERADO con la migración aplicada:
--      fn_physical_count_create           → p_business_id uuid, p_warehouse_id uuid,
--                                           p_notes text, p_is_blind boolean   <-- 4 args
--      fn_physical_count_request_recount  → DEBE EXISTIR
--    Si `create` sale con 3 argumentos o `request_recount` no aparece,
--    la migración NO está aplicada y el conteo de la app va a fallar.
select p.proname                                  as funcion,
       pg_get_function_identity_arguments(p.oid)  as argumentos
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in (
     'fn_physical_count_create',
     'fn_physical_count_freeze',
     'fn_physical_count_set_count',
     'fn_physical_count_request_recount',
     'fn_physical_count_complete',
     'fn_physical_count_cancel'
   )
 order by p.proname;

-- 2) Columnas que agrega la migración. ESPERADO: 8 filas.
--    sessions: is_blind
--    lines:    first_count_quantity, recount_requested, recounted_at,
--              stock_at_complete, applied_variance, unit_cost, variance_value
--    VERIFICADO 2026-08-31: las columnas están puestas en producción.
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and (
     (table_name = 'physical_count_sessions' and column_name = 'is_blind')
     or (table_name = 'physical_count_lines' and column_name in
         ('first_count_quantity','recount_requested','recounted_at',
          'stock_at_complete','applied_variance','unit_cost','variance_value'))
   )
 order by table_name, column_name;

-- 3) Cuántos almacenes tiene el negocio hoy (debe ser 1) y cuál es el principal.
select w.id, w.name, w.is_main, w.is_active,
       (select count(*) from public.inventory_stock s where s.warehouse_id = w.id) as filas_stock
  from public.warehouses w
 where w.business_id = '<PEGA_AQUI_EL_BUSINESS_ID>'
 order by w.is_main desc, w.created_at;

-- 4) Cuántos insumos activos hay para contar.
select count(*) filter (where coalesce(is_active, true))            as insumos_activos,
       count(*) filter (where coalesce(min_stock, 0) > 0)           as con_minimo_configurado,
       count(*) filter (where coalesce(cost, 0) > 0)                as con_costo
  from public.inventory_items
 where business_id = '<PEGA_AQUI_EL_BUSINESS_ID>';

-- 5) Sesiones de conteo abiertas que puedan estorbar mañana.
select id, status, warehouse_id, created_at
  from public.physical_count_sessions
 where business_id = '<PEGA_AQUI_EL_BUSINESS_ID>'
   and status not in ('completed', 'cancelled')
 order by created_at desc;
