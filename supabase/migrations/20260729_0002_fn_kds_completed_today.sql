-- =============================================================================
-- 20260729_0002 — RPC fn_kds_completed_today: historial del KDS sin choque RLS
-- =============================================================================
--
-- Problema: `kds_completed_today` corre con `security_invoker = on`, así que
-- aplica el RLS de `order_items` (`business_id IN current_user_business_ids()`)
-- al usuario de la POS. Filas con `order_items.business_id` NULL (venta
-- rápida/manual — el mismo hueco por el que kds_active_items tiene un fallback
-- en la app) quedan invisibles para `authenticated` aunque el admin las vea →
-- "Completados hoy" salía en 0. Las otras vistas del KDS corren como definer
-- (sin security_invoker), por eso el tablero vivo sí funciona.
--
-- Quitar el security_invoker de la vista abriría el historial de TODOS los
-- negocios a cualquier autenticado (el filtro por business de la app es
-- client-side). Solución: RPC SECURITY DEFINER que exige el business y valida
-- `user_has_business_access` — mismo patrón que fn_sales_by_waiter.
--
-- La membresía se resuelve por `orders.business_id` (siempre poblado), no por
-- `order_items.business_id`. Mismas columnas que la vista para que la app
-- reutilice KitchenItem.fromMap. La vista queda intacta como fallback.
--
-- IDEMPOTENTE: CREATE OR REPLACE (función nueva, sin firma previa).
-- Requiere 20260729_0001 solo conceptualmente (mismo criterio de "completado");
-- esta función es autónoma.
-- =============================================================================

begin;

create or replace function public.fn_kds_completed_today(
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
  is_takeout boolean
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
    oi.is_takeout
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

comment on function public.fn_kds_completed_today(uuid) is
  'Historial "Completados hoy" del KDS. SECURITY DEFINER con validación '
  'user_has_business_access: evita el choque RLS de la vista '
  'kds_completed_today (security_invoker) con order_items.business_id NULL. '
  'Mismo criterio de completado que la vista (20260729_0001).';

commit;
