-- ============================================================================
-- PRE-VUELO del bloqueo por falta de pago
--
-- CORRE ESTO ANTES DE ENCENDER EL KILL SWITCH. Mide a cuántos negocios reales
-- dejaría bloqueados el enforcement HOY. El riesgo no es teórico: hay clientes
-- que pagan pero cuyo `billing_status` quedó viejo de las pruebas de Azul, y
-- negocios en `status='inactive'` que hasta ahora no se enteraban porque el POS
-- ignoraba esa columna.
--
-- Requiere la migración 20260825_0001 aplicada. Correr como operador
-- (is_platform_operator) o desde el SQL Editor de Supabase Studio.
--
-- OJO: `orders` NO tiene business_id, y `orders.session_id` apunta a
-- `table_sessions` (NO a cash_register_sessions — ese error da 0 filas y una
-- falsa tranquilidad). El negocio sale de table_sessions.business_id, que es
-- NULLABLE, con respaldo por dining_tables → zones.business_id.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) RESUMEN — cuántos negocios caerían en cada estado si se enciende
-- ---------------------------------------------------------------------------
select s.js->>'state'   as estado,
       s.js->>'reason'  as motivo,
       count(*)         as negocios
  from public.businesses b
  cross join lateral public.fn_business_access_state(b.id) as s(js)
 group by 1, 2
 order by case s.js->>'state'
            when 'locked'  then 0
            when 'grace'   then 1
            when 'warning' then 2
            else 3
          end, 3 desc;

-- ---------------------------------------------------------------------------
-- 2) DETALLE — quiénes quedarían BLOQUEADOS, con su contexto de cobro
--    Revisa esta lista NOMBRE POR NOMBRE antes de encender.
-- ---------------------------------------------------------------------------
with orders_by_business as (
  select coalesce(ts.business_id, z.business_id) as business_id,
         o.id,
         o.created_at
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
)
select b.business_name                as negocio,
       s.js->>'reason'                as motivo,
       s.js->>'billing_status'        as suscripcion,
       b.status                       as estado_cuenta,
       s.js->>'plan_name'             as plan,
       (s.js->>'next_billing_date')::date as proximo_cobro,
       m.current_attempt_number       as intentos_fallidos,
       (select pm.status
          from public.azul_payment_methods pm
         where pm.business_id = b.id and pm.is_default = true
         limit 1)                     as tarjeta,
       (select max(ob.created_at)::date
          from orders_by_business ob
         where ob.business_id = b.id) as ultima_orden
  from public.businesses b
  cross join lateral public.fn_business_access_state(b.id) as s(js)
  left join public.memberships m
         on m.business_id = b.id and m.is_billing_anchor = true
 where s.js->>'state' = 'locked'
 order by ultima_orden desc nulls last;

-- ---------------------------------------------------------------------------
-- 3) SEÑAL DE ALARMA — negocios que se bloquearían PERO siguen facturando.
--    Si acá sale alguien, su estado de billing está viejo, NO es un moroso.
--    Arréglale el billing (o ponle enforcement='off') ANTES de encender.
-- ---------------------------------------------------------------------------
with orders_by_business as (
  select coalesce(ts.business_id, z.business_id) as business_id,
         o.id,
         o.created_at
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
)
select b.business_name          as negocio,
       s.js->>'reason'          as motivo_del_bloqueo,
       s.js->>'billing_status'  as suscripcion,
       count(ob.id)             as ordenes_ultimos_30_dias,
       max(ob.created_at)       as ultima_orden
  from public.businesses b
  cross join lateral public.fn_business_access_state(b.id) as s(js)
  join orders_by_business ob
    on ob.business_id = b.id
   and ob.created_at >= now() - interval '30 days'
 where s.js->>'state' = 'locked'
 group by 1, 2, 3
 order by 4 desc;

-- ---------------------------------------------------------------------------
-- 4) BLINDAJE — dejar fuera del bloqueo a los que salieron en el punto 3.
--    Sustituye los nombres. Corre esto ANTES de encender el switch.
-- ---------------------------------------------------------------------------
-- insert into public.business_access_control (business_id, enforcement)
-- select id, 'off' from public.businesses
--  where business_name in ('Negocio A', 'Negocio B')
-- on conflict (business_id) do update set enforcement = 'off', updated_at = now();

-- ---------------------------------------------------------------------------
-- 5) PILOTO — encender el bloqueo para UN solo negocio, con el switch global
--    todavía apagado. Es la forma recomendada de estrenar la feature.
-- ---------------------------------------------------------------------------
-- insert into public.business_access_control (business_id, enforcement)
-- values ((select id from public.businesses where business_name = 'Negocio piloto'), 'on')
-- on conflict (business_id) do update set enforcement = 'on', updated_at = now();

-- ---------------------------------------------------------------------------
-- 6) ENCENDIDO GLOBAL — solo cuando 2 y 3 estén revisados y el piloto funcione.
-- ---------------------------------------------------------------------------
-- update public.platform_access_policy
--    set enforcement_enabled = true,
--        default_grace_days  = 5,
--        offline_max_days    = 7,
--        contact_name        = 'Soporte MangoPOS',
--        contact_phone       = '809-000-0000',
--        default_customer_message = null,
--        updated_at = now()
--  where id = true;

-- ---------------------------------------------------------------------------
-- 7) APAGADO DE EMERGENCIA — si algo sale mal, esto libera a TODOS al instante.
--    El POS lo recoge en su próximo poll (2 minutos para los bloqueados).
-- ---------------------------------------------------------------------------
-- update public.platform_access_policy set enforcement_enabled = false where id = true;
