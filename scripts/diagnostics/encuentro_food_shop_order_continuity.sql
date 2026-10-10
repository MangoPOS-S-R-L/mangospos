-- Diagnóstico SOLO LECTURA de órdenes de El Encuentro / Food Shop.
-- Ejecutar cada bloque por separado en el SQL Editor de la base real: el
-- editor muestra SOLO el resultado de la ÚLTIMA sentencia, por eso cada bloque
-- es UNA sola sentencia independiente. Seleccionar el bloque y ejecutarlo.
-- Los UUID provienen del script de acceso existente del proyecto: confirmar
-- nombres en bloque 0. No se presupone que ambos correspondan al incidente.
-- Ventana inicial: últimos 30 días; reducirla al conocer la fecha del caso.
-- Una orden anulada con importe/productos NO demuestra una pérdida: puede
-- ser una anulación válida. Contrastar ID, cobro, motivo y hora con la caja.
-- No contiene UPDATE, DELETE, INSERT ni llamadas al motor de ventas.
-- Antes de aplicar 20261009_0004: correr los bloques 1, 6, 7, 8, 9 y 10 y
-- guardar su salida (el bloque 1 es el rollback REAL de esa migración).

-- 0. Confirmar negocios/sucursales antes de interpretar los resultados.
select b.id as business_id, b.business_name as negocio,
  to_jsonb(b)->>'branch_name' as sucursal
from public.businesses b
where b.id in (
  'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid,
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid
)
order by b.business_name, b.id;

-- 1. Comprobar firmas instaladas, permisos y si abrir quick/manual aún anula
--    órdenes. Global (todas las funciones del esquema, sin filtro de negocio).
--    Guardar la salida ANTES de aplicar 20261009_0004: es su rollback real.
--    Esperado tras aplicar: un solo fn_open_manual_or_quick (4 argumentos),
--    dos fn_open_delivery_order (el de 4 con defaults = 0), anon_ejecuta = false
--    en todas y authenticated_ejecuta = false en fn_sales_* y
--    fn_get_or_create_virtual_table.
select p.proname as funcion,
  pg_get_function_identity_arguments(p.oid) as argumentos,
  p.pronargdefaults as defaults,
  has_function_privilege('anon', p.oid, 'execute') as anon_ejecuta,
  has_function_privilege('authenticated', p.oid, 'execute') as authenticated_ejecuta,
  p.proacl::text as permisos,
  md5(pg_get_functiondef(p.oid)) as huella,
  position('fn_close_order_and_table' in pg_get_functiondef(p.oid)) > 0
    as llama_cierre_automatico,
  position(':sales_virtual' in pg_get_functiondef(p.oid)) > 0
    as serializa_apertura_virtual,
  pg_get_functiondef(p.oid) as definicion
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('fn_open_manual_or_quick', 'fn_open_retail_cart',
    'fn_open_offline_sale', 'fn_open_delivery_order', 'fn_release_empty_tables',
    'fn_release_empty_table', 'fn_get_or_create_virtual_table',
    'current_user_business_ids', 'fn_close_order_and_table',
    'fn_sales_open_actor', 'fn_sales_user_can_open',
    'fn_sales_default_business', 'fn_sales_virtual_open')
order by p.proname, argumentos;

-- 2. Órdenes por día/origen/estado. Los anulados se muestran explícitamente.
select coalesce(nullif(to_jsonb(ts)->>'business_id', '')::uuid, z.business_id)
    as business_id,
  (o.created_at at time zone 'America/Santo_Domingo')::date as dia,
  ts.origin::text as origen, o.status_ext::text as estado,
  count(*) as ordenes, sum(o.total) as importe_registrado
from public.orders o
join public.table_sessions ts on ts.id = o.session_id
join public.dining_tables dt on dt.id = ts.table_id
join public.zones z on z.id = dt.zone_id
where coalesce(nullif(to_jsonb(ts)->>'business_id', '')::uuid, z.business_id)
    in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid,
        'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid)
  and o.created_at >= now() - interval '30 days'
group by 1, 2, 3, 4
order by dia desc, business_id, origen, estado;

-- 3. Candidatas a desaparición visual: anuladas con contenido o con pagos,
--    y órdenes sin cobrar cuya sesión ya fue cerrada.
-- Pagos: suma de registros + estados visibles, sin asumir que todo registro
-- es un cobro confirmado. No es una conciliación de caja ni importe perdido.
with candidatas as (
  select o.*, ts.table_id, ts.closed_at as session_closed_at,
    ts.origin::text as origen,
    coalesce(nullif(to_jsonb(ts)->>'business_id', '')::uuid, z.business_id)
      as business_id,
    dt.code as mesa, to_jsonb(ts)->>'note' as nota_sesion
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
  where coalesce(nullif(to_jsonb(ts)->>'business_id', '')::uuid, z.business_id)
      in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid,
          'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid)
    and o.created_at >= now() - interval '30 days'
    and (o.status_ext::text = 'void' or
      (o.status_ext::text not in ('paid', 'void') and ts.closed_at is not null))
)
select c.business_id, c.id as order_id, c.session_id, c.table_id, c.mesa,
  c.origen, c.status_ext::text as estado, c.total,
  c.created_at at time zone 'America/Santo_Domingo' as creada_rd,
  c.closed_at at time zone 'America/Santo_Domingo' as cerrada_rd,
  c.session_closed_at at time zone 'America/Santo_Domingo' as sesion_cerrada_rd,
  i.renglones, i.importe_items, p.registros_pago, p.suma_registros_pago,
  p.estados_pago, c.nota_sesion
from candidatas c
left join lateral (
  select count(*) as renglones, coalesce(sum(oi.total), 0) as importe_items
  from public.order_items oi where oi.order_id = c.id
) i on true
left join lateral (
  select count(*) as registros_pago, coalesce(sum(pp.amount), 0) as suma_registros_pago,
    string_agg(distinct coalesce(to_jsonb(pp)->>'status', 'sin_estado'), ', ')
      as estados_pago
  from public.payments pp where pp.order_id = c.id
) p on true
where c.status_ext::text <> 'void'
   or c.total <> 0 or i.renglones > 0 or p.registros_pago > 0
order by c.created_at desc
limit 300;

-- 4. Más de una sesión sin cerrar en la misma mesa/slot, o una sesión cuyo
--    business_id no coincide con la zona de su mesa. No reparar a ciegas:
--    puede haber cuentas divididas válidas dentro de UNA misma sesión.
select z.business_id as negocio_zona, dt.id as table_id, dt.code as mesa,
  count(distinct ts.id) as sesiones_abiertas,
  array_agg(distinct ts.id) as session_ids,
  array_agg(distinct o.id) filter (where o.id is not null) as ordenes_abiertas,
  bool_or(nullif(to_jsonb(ts)->>'business_id', '')::uuid is distinct from
    z.business_id) filter (where to_jsonb(ts)->>'business_id' is not null)
    as negocio_sesion_distinto
from public.dining_tables dt
join public.zones z on z.id = dt.zone_id
join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
left join public.orders o on o.session_id = ts.id and o.closed_at is null
  and o.status_ext::text not in ('paid', 'void')
where z.business_id in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid,
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid)
group by z.business_id, dt.id, dt.code
having count(distinct ts.id) > 1
   or bool_or(nullif(to_jsonb(ts)->>'business_id', '')::uuid is distinct from
     z.business_id) filter (where to_jsonb(ts)->>'business_id' is not null)
order by z.business_id, dt.code;

-- 5. Zonas virtuales duplicadas: antes distintas rutas podían crearlas a la
--    vez, con lo cual un slot podía resolverse en otra zona durante replay.
select business_id, name, count(*) as zonas, array_agg(id) as zone_ids
from public.zones
where business_id in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid,
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid)
  and name in ('Ventas rapidas', 'Ventas manuales', 'Delivery')
group by business_id, name
having count(*) > 1;

-- 6. Ventas VIVAS en mesas virtuales de venta: mesa compartida legacy
--    ('quick'/'manual'), carriles de 20261009_0004 ('quick#2', 'manual#3'…) y
--    mesas por slot de carrito retail / venta offline ('quick-…'/'manual-…').
--    Incluye la zona acentuada 'Ventas rápidas' que crearon apps viejas.
--    La migración NO toca estas órdenes: si la compartida está ocupada, la
--    siguiente venta toma 'quick#2'. Resolverlas (cobrar o anular por el flujo
--    normal) es decisión humana; mientras sigan vivas, el cierre de caja las
--    cuenta como mesas abiertas. Para revisar TODOS los negocios, borrar la
--    línea marcada «filtro de negocio».
select b.business_name as negocio, z.business_id, z.name as zona, z.sort_index,
  dt.code as mesa, dt.label as etiqueta,
  case when dt.code in ('quick', 'manual') then 'compartida_legacy'
       when dt.code ~ '^(quick|manual)#[0-9]+$' then 'carril'
       when dt.code ~ '^(quick|manual)-' then 'carrito_u_offline'
       else 'otra' end as tipo,
  ts.id as session_id, ts.origin::text as origen,
  ts.opened_at at time zone 'America/Santo_Domingo' as sesion_abierta_rd,
  coalesce(pr.full_name, ts.opened_by::text) as abierta_por,
  o.id as order_id, o.status_ext::text as estado, o.total,
  o.created_at at time zone 'America/Santo_Domingo' as creada_rd,
  (select count(*) from public.order_items oi
    where oi.order_id = o.id and oi.status::text not in ('void', 'paid'))
    as items_pendientes,
  (select coalesce(sum(pp.amount), 0) from public.payments pp
    where pp.order_id = o.id) as suma_registros_pago
from public.dining_tables dt
join public.zones z on z.id = dt.zone_id
join public.businesses b on b.id = z.business_id
join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
join public.orders o on o.session_id = ts.id
left join public.profiles pr on pr.id = ts.opened_by
where z.name in ('Ventas rapidas', 'Ventas manuales', 'Ventas rápidas')
  and o.closed_at is null
  and o.status_ext::text not in ('paid', 'void')
  and z.business_id in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid, 'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid) -- filtro de negocio
order by tipo, negocio, mesa, o.created_at;

-- 7. Sesiones ABIERTAS sin ninguna orden viva en mesas virtuales de venta
--    (todo cobrado/anulado, o sesión vacía). Antes provocaban el 23505 de
--    uniq_open_session_per_table; tras 20261009_0004, la próxima apertura que
--    elija esa mesa solo les pone closed_at (no toca órdenes). En carriles y
--    mesas compartidas pasa con la siguiente venta; en mesas por slot, solo si
--    ese mismo slot se vuelve a abrir. Para revisar TODOS los negocios, borrar
--    la línea marcada «filtro de negocio».
select b.business_name as negocio, z.business_id, z.name as zona,
  dt.code as mesa, dt.label as etiqueta,
  case when dt.code in ('quick', 'manual') then 'compartida_legacy'
       when dt.code ~ '^(quick|manual)#[0-9]+$' then 'carril'
       when dt.code ~ '^(quick|manual)-' then 'carrito_u_offline'
       else 'otra' end as tipo,
  ts.id as session_id, ts.origin::text as origen,
  ts.opened_at at time zone 'America/Santo_Domingo' as sesion_abierta_rd,
  coalesce(pr.full_name, ts.opened_by::text) as abierta_por,
  count(o.id) as ordenes_en_sesion,
  count(o.id) filter (where o.status_ext::text = 'paid') as cobradas,
  count(o.id) filter (where o.status_ext::text = 'void') as anuladas,
  count(o.id) filter (where o.status_ext::text not in ('paid', 'void'))
    as cerradas_con_otro_estado
from public.dining_tables dt
join public.zones z on z.id = dt.zone_id
join public.businesses b on b.id = z.business_id
join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
left join public.orders o on o.session_id = ts.id
left join public.profiles pr on pr.id = ts.opened_by
where z.name in ('Ventas rapidas', 'Ventas manuales', 'Ventas rápidas')
  and z.business_id in ('f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid, 'af2ec2e7-2cdd-4583-bf5a-7e7476173b72'::uuid) -- filtro de negocio
group by b.business_name, z.business_id, z.name, dt.code, dt.label, ts.id,
  ts.origin, ts.opened_at, pr.full_name, ts.opened_by
having count(o.id) filter (
  where o.closed_at is null and o.status_ext::text not in ('paid', 'void')) = 0
order by negocio, mesa, sesion_abierta_rd;

-- 8. Índices vivos de las tablas que usa la apertura. Esperado:
--    uniq_open_session_per_table (table_sessions, table_id WHERE closed_at IS
--    NULL), dining_tables_zone_id_code_key (zone_id, code) y NINGÚN índice
--    único en zones(business_id, name). Global.
select tablename as tabla, indexname as indice, indexdef as definicion
from pg_indexes
where schemaname = 'public'
  and tablename in ('table_sessions', 'dining_tables', 'zones', 'orders')
order by tabla, indice;

-- 9. Triggers vivos que intervienen al abrir una venta (p. ej. el que fija
--    table_sessions.business_id desde la zona, el que llena orders.business_id
--    y trg_block_items_on_closed_order de 20260819_0004). Global.
select tgrelid::regclass as tabla, tgname as trigger_nombre,
  pg_get_triggerdef(oid) as definicion
from pg_trigger
where not tgisinternal
  and tgrelid in ('public.orders'::regclass, 'public.table_sessions'::regclass,
    'public.order_items'::regclass, 'public.dining_tables'::regclass,
    'public.zones'::regclass)
order by tabla, trigger_nombre;

-- 10. Privilegios por defecto vivos: si las funciones nuevas nacen con EXECUTE
--     para anon (Supabase), 20261009_0004 se lo quita explícitamente. Global.
select pg_get_userbyid(d.defaclrole) as rol,
  d.defaclnamespace::regnamespace as esquema,
  d.defaclobjtype as tipo_objeto, d.defaclacl::text as permisos
from pg_default_acl d
order by rol, esquema, tipo_objeto;
