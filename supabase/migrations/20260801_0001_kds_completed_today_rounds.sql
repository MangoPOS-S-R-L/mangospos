-- =============================================================================
-- 20260801_0001 — fn_kds_completed_today expone kitchen_sent_at (comandas)
-- =============================================================================
--
-- Pedido: "si hago una orden de 4 productos y luego agrego 2 más a esa mesa,
-- en el historial deberían salir 4 y 2, no las 6 juntas".
--
-- "Completados hoy" agrupa por `order_id`, así que todas las rondas de una
-- misma mesa colapsan en una sola fila. El tablero vivo SÍ las separa porque
-- agrupa por `orderId::kitchen_sent_at::area` (`kitchenCardKey`), pero esta
-- RPC no devuelve `kitchen_sent_at` y la app no tiene con qué separarlas.
--
-- Este cambio es SOLO aditivo: agrega la columna al final del RETURNS TABLE.
-- El cuerpo, el filtro y la validación de acceso quedan idénticos a
-- 20260729_0002. Con la columna disponible, la app agrupa el historial por
-- comanda; sin ella (RPC vieja) los ítems llegan con kitchen_sent_at null y
-- el historial degrada al agrupado por orden de siempre.
--
-- DROP + CREATE (no CREATE OR REPLACE): Postgres no permite cambiar las
-- columnas de salida de una función con REPLACE (42P13).
--
-- NO se toca la vista `kds_completed_today`. Recrearla arrastraría el riesgo
-- de reintroducir `security_invoker = on`, que ya dejó el historial en 0 una
-- vez (ver 20260729_0003). La vista sigue como fallback sin la columna; en
-- ese camino la app degrada al agrupado por orden.
--
-- ANTES DE APLICAR: la BD viva diverge del repo. Verificar que la definición
-- actual coincide con 20260729_0002 y no trae cambios hechos fuera del repo:
--   select pg_get_functiondef('public.fn_kds_completed_today(uuid)'::regprocedure);
--
-- IDEMPOTENTE: DROP IF EXISTS + CREATE.
-- =============================================================================

begin;

drop function if exists public.fn_kds_completed_today(uuid);

create function public.fn_kds_completed_today(
  p_business_id uuid
)
returns table (
  id uuid,
  order_id uuid,
  order_number text,
  product_name text,
  quantity numeric,
  notes text,
  status text,
  created_at timestamptz,
  started_at timestamptz,
  ready_at timestamptz,
  table_name text,
  waiter_name text,
  business_id uuid,
  area_code text,
  area_name text,
  is_takeout boolean,
  -- NUEVA: marca de ronda. Los ítems enviados juntos a cocina la comparten y
  -- forman una comanda; es la misma columna con la que el tablero vivo separa
  -- sus tarjetas. Null en ítems legacy (enviados antes de 20260707_0001) y en
  -- los que entraron por el camino offline sin estampar.
  kitchen_sent_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  return query
  select
    oi.id,
    oi.order_id,
    left(oi.order_id::text, 8) as order_number,
    oi.product_name,
    coalesce(oi.quantity::numeric, oi.qty, 1::numeric) as quantity,
    oi.notes,
    oi.status::text as status,
    oi.created_at,
    oi.started_at,
    coalesce(oi.ready_at, o.closed_at) as ready_at,
    case
      when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
      when ts.origin = 'manual'::public.order_origin then 'Venta manual'
      when ts.origin = 'quick'::public.order_origin  then 'Venta rapida'
      else 'Venta'
    end as table_name,
    p.full_name as waiter_name,
    o.business_id,
    oi.print_area_code as area_code,
    pa.name as area_name,
    oi.is_takeout,
    oi.kitchen_sent_at
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.profiles p       on p.id = ts.waiter_user_id
  left join public.print_areas pa
         on pa.code = oi.print_area_code
        and pa.business_id = o.business_id
  where o.business_id = p_business_id
    and oi.status <> 'void'::public.item_status
    and (
      -- Camino normal: la cocina marcó el ítem hoy (día local RD).
      (oi.ready_at is not null
       and (oi.ready_at at time zone 'America/Santo_Domingo')::date
           = (now() at time zone 'America/Santo_Domingo')::date)
      -- Orden cobrada/cerrada hoy sin que la cocina marcara: ítem enviado a
      -- cocina (kitchen_sent_at) que terminó 'paid'/'served'.
      or (oi.ready_at is null
          and oi.kitchen_sent_at is not null
          and oi.status in ('paid'::public.item_status,
                            'served'::public.item_status)
          and o.closed_at is not null
          and (o.closed_at at time zone 'America/Santo_Domingo')::date
              = (now() at time zone 'America/Santo_Domingo')::date)
    );
end;
$$;

grant execute on function public.fn_kds_completed_today(uuid) to authenticated;

commit;
