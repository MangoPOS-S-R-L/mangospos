-- =============================================================================
-- 20260616_0002 — KDS: completar comanda al pagar vs. esperar al cocinero
-- =============================================================================
--
-- Da control por negocio sobre QUÉ saca una comanda del KDS:
--   • kds_complete_on_payment = TRUE  (default, "como ahora"): al pagar, la
--     orden sale del KDS automáticamente.
--   • kds_complete_on_payment = FALSE: la orden se queda en el KDS aunque esté
--     pagada, hasta que un cocinero la marque ("Marcar todo listo").
--
-- Para soportar el modo FALSE sin tocar la función de pago, usamos un flag a
-- nivel de orden: orders.kitchen_done_at. La cocina la "termina" cuando el
-- cocinero la marca; y, en modo TRUE, un trigger aditivo la sella al pagar.
-- La señal por-ítem de "cocinado" sigue siendo order_items.ready_at, que NO se
-- pierde al pagar.
--
-- Piezas (todas ADITIVAS — no modifican fn_process_payment_v3 ni emisión/NCF):
--   1. business_settings.kds_complete_on_payment  (toggle, default true)
--   2. orders.kitchen_done_at                     (sello de cocina terminada)
--   3. backfill: órdenes ya pagadas/cerradas → kitchen_done_at, para que el
--      modo FALSE no refloote historial.
--   4. trigger BEFORE UPDATE OF status_ext: al quedar 'paid' y si el negocio
--      usa modo TRUE, sella kitchen_done_at. No toca la función de pago.
--   5. vista kds_open_orders: ítems de órdenes con kitchen_done_at IS NULL
--      (incluye ítems ya 'paid'), recientes — fuente del KDS en modo FALSE.
--
-- Safe deploy: Flutter cae al default TRUE si la columna no existe, y usa la
-- vista nueva solo si el negocio activó el modo FALSE.
-- =============================================================================

begin;

-- 1. Toggle por negocio.
alter table public.business_settings
  add column if not exists kds_complete_on_payment boolean not null default true;

comment on column public.business_settings.kds_complete_on_payment is
  'TRUE (default): al pagar, la comanda sale del KDS. FALSE: la comanda se '
  'queda en el KDS hasta que un cocinero la marque como lista.';

-- 2. Sello de cocina terminada por orden.
alter table public.orders
  add column if not exists kitchen_done_at timestamptz;

comment on column public.orders.kitchen_done_at is
  'Momento en que la cocina terminó la orden (cocinero la marcó, o pago en '
  'modo kds_complete_on_payment). NULL = sigue abierta en cocina.';

-- Índice parcial: la vista del KDS (modo FALSE) filtra por órdenes abiertas.
create index if not exists idx_orders_kitchen_open
  on public.orders (business_id, created_at)
  where kitchen_done_at is null;

-- 3. Backfill: lo ya pagado/anulado/cerrado se considera cocina terminada,
--    para no reflotar historial al activar el modo "esperar al cocinero".
update public.orders
   set kitchen_done_at = coalesce(closed_at, now())
 where kitchen_done_at is null
   and (status_ext::text in ('paid', 'void') or closed_at is not null);

-- 4. Trigger aditivo: sella kitchen_done_at al quedar la orden 'paid', solo si
--    el negocio usa "sale al pagar". NO modifica fn_process_payment_v3.
create or replace function public.tg_orders_kitchen_done_on_payment()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.kitchen_done_at is null
     and new.status_ext::text = 'paid'
     and (old.status_ext is distinct from new.status_ext) then
    if coalesce((
      select kds_complete_on_payment
      from public.business_settings
      where business_id = new.business_id
    ), true) then
      new.kitchen_done_at := now();
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_orders_kitchen_done_on_payment on public.orders;
create trigger trg_orders_kitchen_done_on_payment
  before update of status_ext on public.orders
  for each row
  execute function public.tg_orders_kitchen_done_on_payment();

-- 5. Vista del KDS para modo "esperar al cocinero": ítems de órdenes cuya
--    cocina NO está terminada (incluye ítems ya 'paid'), recientes. Misma
--    forma de columnas que kds_active_items para reusar KitchenItem.fromMap.
create or replace view public.kds_open_orders with (security_invoker = on) as
select
  oi.id,
  oi.order_id,
  left(oi.order_id::text, 8) as order_number,
  oi.product_name,
  coalesce(oi.quantity::numeric, oi.qty, 1::numeric) as quantity,
  oi.notes,
  oi.status,
  oi.created_at,
  oi.started_at,
  oi.ready_at,
  case
    when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
    when ts.origin = 'manual'::public.order_origin then 'Venta manual'
    when ts.origin = 'quick'::public.order_origin  then 'Venta rapida'
    else 'Venta'
  end as table_name,
  p.full_name as waiter_name,
  o.business_id,
  oi.print_area_code as area_code,
  oi.is_takeout,
  pa.name as area_name
from public.order_items oi
join public.orders o          on o.id = oi.order_id
join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
left join public.profiles p       on p.id = ts.waiter_user_id
left join public.print_areas pa
       on pa.code = oi.print_area_code
      and pa.business_id = o.business_id
where o.kitchen_done_at is null
  and o.created_at >= (now() - interval '2 days')
  and oi.status <> 'void'::public.item_status;

grant select on public.kds_open_orders to authenticated, service_role;

commit;
