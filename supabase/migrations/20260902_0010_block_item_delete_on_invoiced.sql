-- 20260902_0010_block_item_delete_on_invoiced.sql
-- Hallazgo H-3 de la auditoria del 607 de La Penda (DH, 31-ago-2026):
-- facturas emitidas por mas de lo que hay registrado en la mesa.
--
-- CAUSA (localizada 1-sep-2026)
--   La app BORRA items, no los anula:
--     lib/data/repositories/sales_repository.dart:1643  deleteItem()
--        await _client.from('order_items').delete().eq('id', itemId);
--     idem deleteCheck() (linea 2084) y sales_repository_improved.dart:300
--   Un `void` deja la fila y es auditable; un DELETE no deja nada. Por eso las
--   ordenes de H-3 no tienen items anulados: no tienen items.
--
--   Y el candado que ya existe NO cubre esto: `trg_block_items_on_closed_order`
--   (20260819_0004) esta aplicado y habilitado, pero es `before insert`. Impide
--   AGREGAR productos a una cuenta cobrada, no QUITARLOS.
--
--   Casos medidos en agosto:
--     B0200157123  faltan     55,00  (un JUGO RICA DE PERA)
--     B0200159100  faltan  1.092,37
--     B0200158089  CERO items, y la orden ni llego a 'paid'
--
-- QUE HACE
--   Impide borrar un item cuando su alcance ya tiene un comprobante fiscal
--   ACTIVO. El cajero tiene que anularlo (void), que deja rastro, o anular la
--   factura completa.
--
-- POR QUE NO ROMPE NADA QUE HOY FUNCIONE
--   * Cuentas divididas: si el comprobante es de OTRA subcuenta, no aplica.
--     Solo bloquea cuando el comprobante cubre el item (mismo check_id, o
--     comprobante de orden completa con check_id nulo).
--   * Consolidacion de splits fraccionados: `fn_consolidate_order_to_integer`
--     (20260511_0001), `fn_consolidate_keeper_atomic` (20260529_0003) y
--     20260813_0004 BORRAN y recrean items a proposito. Corren como SECURITY
--     DEFINER, o sea con current_user = postgres, y el candado solo se aplica a
--     `authenticated` y `anon`. Siguen funcionando igual.
--   * Mantenimiento desde Studio (postgres / service_role): tampoco se bloquea.
--
-- HUECO QUE NO CIERRA, A PROPOSITO
--   Mover un item a otra orden o a otro check tiene el mismo efecto que
--   borrarlo, y esto no lo cubre. No lo incluyo porque `fn_move_items_to_check_batch`
--   mueve items en cada division de cuenta y bloquear ahi es mucho mas delicado.
--   Queda anotado como pendiente.
--
-- ROLLBACK: 20260902_0010_block_item_delete_on_invoiced_ROLLBACK.sql
-- Idempotente. No toca datos existentes.

begin;

create or replace function public.fn_block_item_delete_on_invoiced()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ncf text;
begin
  if old.order_id is null then
    return old;
  end if;

  -- Solo se le aplica al cliente. Las funciones internas de consolidacion
  -- corren como SECURITY DEFINER (current_user = postgres) y deben poder
  -- borrar y recrear items.
  if current_user not in ('authenticated', 'anon') then
    return old;
  end if;

  -- ¿Hay un comprobante ACTIVO que cubra a este item?
  --   check_id nulo  -> el comprobante es de la orden completa: cubre todo.
  --   check_id igual -> el comprobante es de la subcuenta de este item.
  -- Un comprobante de OTRA subcuenta no lo cubre, asi que dividir cuentas y
  -- borrar de una subcuenta todavia sin facturar sigue permitido.
  select fd.ncf_number into v_ncf
  from public.fiscal_documents fd
  where fd.order_id = old.order_id
    and fd.status = 'active'
    and (fd.check_id is null or fd.check_id = old.check_id)
  limit 1;

  if v_ncf is not null then
    raise exception
      'No se puede eliminar un producto de una cuenta ya facturada (%). '
      'Anúlalo en vez de borrarlo, o anula la factura completa.', v_ncf
      using errcode = 'MP404';
  end if;

  return old;
end;
$function$;

alter function public.fn_block_item_delete_on_invoiced() owner to postgres;

drop trigger if exists trg_block_item_delete_on_invoiced on public.order_items;
create trigger trg_block_item_delete_on_invoiced
  before delete on public.order_items
  for each row
  execute function public.fn_block_item_delete_on_invoiced();

comment on function public.fn_block_item_delete_on_invoiced() is
  'H-3 del 607: impide BORRAR items de una orden/subcuenta con comprobante fiscal '
  'activo. Complementa trg_block_items_on_closed_order, que solo cubre INSERT. '
  'No aplica a roles internos (consolidacion de splits, mantenimiento).';

commit;
