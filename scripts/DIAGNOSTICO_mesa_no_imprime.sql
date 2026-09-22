-- =============================================================================
-- DIAGNÓSTICO — "Una mesa no imprime y las demás sí"
-- =============================================================================
-- Solo lee. UNA sola consulta (el SQL Editor muestra solo el último
-- resultado). Cambiar solo las líneas marcadas con <<<.
--
-- POR QUÉ ESTAS SECCIONES: la ruta de impresión es la misma para todas las
-- mesas (no hay impresora por mesa ni por zona). Si falla UNA sola, la causa
-- está en algo propio de esa mesa:
--   1 MESA         ¿hay dos mesas con el mismo nombre/código? ¿está activa?
--   2 SESION       ¿la mesa tiene más de una sesión abierta?
--   3 ORDEN        ¿hay más de una orden viva en la cuenta, o una huérfana?
--                  (la app imprime la que cree que es la actual)
--   4 PRODUCTO     productos de la cuenta que la comanda no puede enrutar
--                  (sin área de impresión activa) u otras rarezas.
--   5 COLA         trabajos de impresión de esa cuenta atascados o fallidos,
--                  con el error que devolvió la impresora.
--
-- Encuentra la mesa por su NÚMERO: "2" encuentra "Mesa 2", "MUEBLE02",
-- "MUEBLE2", "M2" y "2", pero no "12" ni "20".
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,   -- <<< negocio
    '2'                                          as numero -- <<< número de mesa
),
mesas as (
  select dt.*, z.name as zona
  from public.dining_tables dt
  join public.zones z on z.id = dt.zone_id
  cross join params p
  where z.business_id = p.bid
    and (
      coalesce(dt.label, '') ~* ('(^|[^0-9])0*' || p.numero || '$')
      or coalesce(dt.code, '') ~* ('(^|[^0-9])0*' || p.numero || '$')
    )
),
sesiones as (
  select ts.*
  from public.table_sessions ts
  join mesas m on m.id = ts.table_id
  where ts.closed_at is null
),
ordenes as (
  select o.*
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join mesas m on m.id = ts.table_id
  -- La sesión abierta, o una orden viva colgando de una sesión ya cerrada
  -- (huérfana): las dos confunden a la pantalla de la mesa.
  where (ts.closed_at is null or o.closed_at is null)
    and coalesce(o.status_ext::text, '') not in ('paid', 'void')
    and o.created_at > now() - interval '3 days'
),
items as (
  select oi.*, o.id as orden
  from public.order_items oi
  join ordenes o on o.id = oi.order_id
)
select * from (
  -- 1. Las mesas que responden a ese número.
  select
    '1 MESA'                                                   as seccion,
    coalesce(m.label, '(sin etiqueta)') || ' · código ' ||
      coalesce(m.code, '—') || ' · zona ' || m.zona            as detalle,
    case
      when count(*) over () > 1
        then 'HAY ' || count(*) over () || ' MESAS CON ESE NÚMERO: confirma que se está abriendo la correcta'
      when coalesce((to_jsonb(m) ->> 'is_active')::boolean, true) = false
        then 'mesa INACTIVA'
      else 'ok'
    end                                                        as alerta
  from mesas m

  union all

  -- 2. Sesiones abiertas.
  select
    '2 SESION',
    'Abierta ' ||
      to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') ||
      ' · cliente: ' || coalesce(nullif(s.customer_name, ''), '—'),
    case
      when count(*) over () > 1 then 'MÁS DE UNA SESIÓN ABIERTA'
      when s.opened_at < now() - interval '18 hours' then 'sesión abierta hace más de 18 h'
      else 'ok'
    end
  from sesiones s

  union all

  -- 3. Órdenes vivas.
  select
    '3 ORDEN',
    '#' || upper(left(o.id::text, 8)) || ' · ' || o.status || '/' ||
      coalesce(o.status_ext::text, '—') || ' · total ' ||
      to_char(coalesce(o.total, 0), 'FM999,999,990.00') || ' · ' ||
      (select count(*) from public.order_items x where x.order_id = o.id) || ' productos',
    case
      when count(*) over () > 1
        then 'HAY ' || count(*) over () || ' ÓRDENES VIVAS EN LA MESA: la pantalla muestra una y la impresión puede tomar otra'
      when not exists (select 1 from sesiones s where s.id = o.session_id)
        then 'ORDEN HUÉRFANA: su sesión ya se cerró'
      else 'ok'
    end
  from ordenes o

  union all

  -- 4. Productos que la comanda no puede enrutar, u otras rarezas.
  select
    '4 PRODUCTO',
    coalesce(nullif(i.product_name, ''), '(sin nombre)') || ' · ' ||
      i.status::text || ' · cant ' || coalesce(i.qty, i.quantity::numeric)::text,
    concat_ws(' · ',
      case when nullif(trim(i.product_name), '') is null then 'SIN NOMBRE' end,
      case when coalesce(nullif(i.qty, 0), i.quantity::numeric, 0) <= 0 then 'CANTIDAD 0 O NEGATIVA' end,
      case when coalesce(i.unit_price, 0) < 0 then 'PRECIO NEGATIVO' end,
      case
        when i.product_id is not null
         and not exists (
           select 1 from public.menu_item_print_areas mipa
           join public.print_areas pa on pa.id = mipa.print_area_id
           where mipa.menu_item_id = i.product_id and pa.is_active)
         and not exists (
           select 1 from public.print_areas pa
           cross join params p
           where pa.business_id = p.bid and pa.is_active
             and pa.code = i.print_area_code)
          then 'SIN ÁREA DE IMPRESIÓN: la comanda no sabe a qué impresora ir'
      end,
      case when i.check_id is not null
            and exists (select 1 from public.order_checks c
                        where c.id = i.check_id and c.is_closed)
          then 'EN UNA SUBCUENTA CERRADA'
      end
    )
  from items i
  where nullif(trim(i.product_name), '') is null
     or coalesce(nullif(i.qty, 0), i.quantity::numeric, 0) <= 0
     or coalesce(i.unit_price, 0) < 0
     or (i.check_id is not null
         and exists (select 1 from public.order_checks c
                     where c.id = i.check_id and c.is_closed))
     or (i.product_id is not null
         and not exists (
           select 1 from public.menu_item_print_areas mipa
           join public.print_areas pa on pa.id = mipa.print_area_id
           where mipa.menu_item_id = i.product_id and pa.is_active)
         and not exists (
           select 1 from public.print_areas pa
           cross join params p
           where pa.business_id = p.bid and pa.is_active
             and pa.code = i.print_area_code))

  union all

  -- 5. La cola de impresión de esas órdenes (el error de la impresora).
  select
    '5 COLA',
    coalesce(to_jsonb(j) ->> 'kind', '(sin tipo)') || ' · ' || j.status ||
      ' · ' || to_char(j.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') ||
      ' · ' || j.ip,
    coalesce(nullif(j.error, ''), 'sin error registrado')
  from public.print_jobs j
  cross join params p
  where j.business_id = p.bid
    and j.created_at > now() - interval '3 days'
    and j.status not in ('done', 'printed', 'completed')
    and exists (
      select 1 from ordenes o
      where coalesce(to_jsonb(j) ->> 'idempotency_key', '') ilike '%' || o.id::text || '%'
    )
) x
order by seccion;
