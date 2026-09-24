-- Rollback de 20260924_0002_external_order_print_queue.sql
--
-- Deja los pedidos externos otra vez sin quién les imprima la comanda: entran,
-- se ven en el KDS, pero no sale papel. Si la app ya tiene el worker corriendo,
-- hay que publicar antes una versión sin él o va a fallar en cada tick.
--
-- Las columnas quedan comentadas: `printed_at` es el registro de qué comanda
-- llegó a las impresoras y qué pedido quedó sin papel. Borrarlo pierde esa
-- traza.

begin;

drop function if exists public.fn_claim_external_orders_to_print(uuid, text, int);
drop function if exists public.fn_mark_external_order_printed(uuid, boolean, text);
drop index if exists public.idx_ext_orders_pending_print;

-- alter table public.external_orders
--   drop column if exists printed_at,
--   drop column if exists print_claimed_by,
--   drop column if exists print_claimed_at,
--   drop column if exists print_attempts,
--   drop column if exists print_error;

commit;
