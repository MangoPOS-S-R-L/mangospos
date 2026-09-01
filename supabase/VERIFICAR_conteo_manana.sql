-- =============================================================================
-- Antes del conteo desde cero. Correr UNA sentencia a la vez.
-- =============================================================================

-- 1) ¿Están las funciones del conteo, con el blindaje del cierre?
select p.proname as funcion,
       pg_get_function_identity_arguments(p.oid) as args,
       coalesce(array_to_string(p.proconfig, ', '), '(sin config)') as ajustes
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname like 'fn_physical_count%'
 order by 1;
-- ESPERADO: fn_physical_count_complete con statement_timeout=300s,
--           fn_physical_count_freeze con 120s,
--           y fn_physical_count_zero_pending presente.

-- 2) Los permisos del conteo, EN LA BASE (si falta el código acá, el gate de
--    la app no deja pasar a nadie y no se entiende por qué).
select code from public.permissions
 where code like 'inventario.conteo%' order by 1;
-- ESPERADO: acceso, anular, completar, crear.

-- 3) Cuántas líneas va a crear el congelado, que es el tamaño del trabajo.
select count(*) as lineas_que_va_a_crear
  from public.inventory_items
 where business_id = '<BUSINESS_ID>' and coalesce(is_active, true);

-- 4) Sesiones abiertas que estorben.
select id, code, status, warehouse_id, is_blind, started_at
  from public.physical_count_sessions
 where business_id = '<BUSINESS_ID>'
   and status not in ('completed','cancelled')
 order by started_at desc;

-- 5) La bodega correcta. El conteo es POR BODEGA: contar en la equivocada
--    ajusta la existencia de la equivocada.
select id, name, is_main, is_active, warehouse_type, shows_in_pos
  from public.warehouses
 where business_id = '<BUSINESS_ID>'
 order by is_main desc, name;
