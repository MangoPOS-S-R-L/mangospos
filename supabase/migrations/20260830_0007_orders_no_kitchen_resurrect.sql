-- =====================================================================
-- Una orden cerrada NO vuelve a 'sent_to_kitchen'
--
-- PROBLEMA (medido en f054fbc2 el 2026-08-30): 6,009 ordenes con pago
-- completado quedaron atascadas en status_ext='sent_to_kitchen', la mas
-- vieja del 2026-07-05 y la mas nueva del mismo dia. Causa:
-- `fn_confirm_order_to_kitchen` hace
--     update public.orders set status='sent', status_ext='sent_to_kitchen'
--     where id = p_order_id;
-- SIN condicion y sin tocar closed_at. Cualquier envio a cocina POSTERIOR
-- al cobro le pisa el 'paid' que dejo fn_close_order_and_table y la orden
-- queda hibrida: closed_at puesto + status_ext='sent_to_kitchen'.
-- Los dos llamadores son "Enviar a cocina" (printing_service.dart:291) y
-- el replay de la accion 'confirm_local_order' de la cola offline
-- (offline_pos_service.dart:2174).
--
-- POR QUE UN TRIGGER Y NO REEMPLAZAR LA FUNCION: la BD viva diverge del
-- repo (`supabase/schema.sql` esta stale — comprobado con
-- pg_get_functiondef en fn_close_order_and_table, y el codigo Dart dice
-- que la version viva ademas genera print_jobs de comanda). Un
-- CREATE OR REPLACE a ciegas podria borrar esa parte y romper la
-- impresion. Este trigger no toca la funcion: ataja la transicion
-- ilegal venga de donde venga, incluidos callers futuros.
--
-- QUE HACE: si un UPDATE intenta mover una orden CERRADA (closed_at
-- puesto, o paid/void) a 'sent_to_kitchen', conserva el estado cerrado en
-- vez de rechazar. NO lanza excepcion a proposito: un RAISE abortaria la
-- transaccion del envio a cocina y la comanda no se imprimiria. Asi la
-- cocina recibe su comanda igual y la orden simplemente no resucita.
--
-- QUE NO TOCA:
--   * `order_items` — las vistas del KDS filtran por el estado del ITEM
--     (kds_active_items) y por orders.kitchen_done_at (kds_open_orders),
--     nunca por status_ext. La comanda sigue en el tablero.
--   * La reapertura legitima por anulacion de pago, que escribe
--     status_ext='partially_paid' (no 'sent_to_kitchen') y limpia
--     closed_at: ese camino no entra aqui.
--
-- Idempotente. Ver ROLLBACK al lado.
-- =====================================================================

begin;

create or replace function public.fn_orders_no_kitchen_resurrect()
returns trigger
language plpgsql
as $$
begin
  if new.status_ext = 'sent_to_kitchen'
     and old.status_ext is distinct from new.status_ext
     and (old.closed_at is not null
          or old.status_ext in ('paid'::public.order_status,
                                'void'::public.order_status))
  then
    -- La orden ya cerro. El cobro es el ultimo estado, no un paso mas.
    new.status_ext := old.status_ext;
    new.status     := old.status;
    new.closed_at  := old.closed_at;
  end if;
  return new;
end;
$$;

alter function public.fn_orders_no_kitchen_resurrect() owner to postgres;

drop trigger if exists trg_orders_no_kitchen_resurrect on public.orders;

create trigger trg_orders_no_kitchen_resurrect
  before update of status_ext on public.orders
  for each row
  execute function public.fn_orders_no_kitchen_resurrect();

comment on function public.fn_orders_no_kitchen_resurrect() is
  'Impide que una orden cerrada (closed_at puesto, o paid/void) vuelva a '
  'status_ext=sent_to_kitchen. Conserva el estado cerrado en vez de lanzar '
  'excepcion, para no abortar el envio a cocina ni la impresion de comanda. '
  'Ver migracion 20260830_0007.';

commit;
