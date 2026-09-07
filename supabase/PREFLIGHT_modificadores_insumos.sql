-- =============================================================================
-- PREFLIGHT — Modificadores que descuentan insumos (20260907_0001/0002/0003)
--
-- Correr ESTO ANTES de aplicar las migraciones y pegarme la salida.
-- No escribe nada: son 6 consultas de lectura.
-- =============================================================================

-- (1) LA IMPORTANTE. Definición VIVA del motor de consumo. Hay que cotejarla
--     contra supabase/migrations/20260901_0003_consume_by_area.sql. Si la viva
--     tiene algo que el repo no, hay que traerlo a la migración nueva antes de
--     aplicarla o se pierde en silencio.
select pg_get_functiondef(
  'public.consume_inventory_from_order(uuid)'::regprocedure) as def_viva;

-- (2) ¿Existe el resolvedor de almacenes por sección (20260901_0002)?
--     Si devuelve 0 filas, la migración 0003 crea un stub que devuelve NULL
--     (= bodega por defecto, comportamiento histórico). Es lo esperado si
--     nunca se aplicó la tanda de almacenes por sección.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as args,
       p.provolatile,
       p.prosecdef
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'fn_resolve_consumption_warehouse';

-- (3) ¿Ya existen la columna y la tabla nuevas? (deberían devolver 0 filas)
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and (   (table_name = 'order_item_modifiers' and column_name = 'modifier_id')
       or  table_name = 'modifier_ingredients')
order by table_name, column_name;

-- (4) Helpers de RLS que usan las políticas nuevas. Deben existir los dos.
select p.proname, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('user_has_business_access', 'user_business_role');

-- (5) Negocios con inventario prendido: son los únicos donde esto descuenta.
--     `inventory_mode = 'none'` corta el consumo antes de mirar nada.
select b.id, b.legal_name, bs.inventory_mode
from public.business_settings bs
join public.businesses b on b.id = bs.business_id
where coalesce(bs.inventory_mode, 'none') <> 'none'
order by b.legal_name;

-- (6) Foto de los modificadores que hoy existen, para saber cuánto hay que
--     configurar. (Cambia el nombre del negocio o quita el filtro.)
select mg.name as grupo,
       m.name  as modificador,
       m.price_delta,
       m.is_active,
       b.legal_name
from public.modifiers m
left join public.modifier_groups mg on mg.id = m.group_id
join public.businesses b on b.id = m.business_id
order by b.legal_name, mg.name, m.name;
