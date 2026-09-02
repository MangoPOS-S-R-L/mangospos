-- ROLLBACK de 20260902_0011_fn_delete_item_fiscal_guard.sql
-- Restaura fn_delete_item exactamente como estaba en produccion el 1-sep-2026.
--
-- OJO: al volver atras, la app puede borrar de nuevo items de cuentas ya
-- facturadas, porque esta funcion es SECURITY DEFINER y el trigger
-- trg_block_item_delete_on_invoiced la exime. Se reabre H-3.

CREATE OR REPLACE FUNCTION public.fn_delete_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order_id uuid;
  v_business_id uuid;
  v_allowed boolean;
begin
  -- Resolver business_id del item para validar permiso
  select z.business_id
    into v_business_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where oi.id = p_item_id;

  if v_business_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  -- Validar permiso ventas.orden.eliminar_item
  select coalesce(bool_or(p.allowed), false)
    into v_allowed
    from public.fn_user_effective_permissions(auth.uid(), v_business_id) p
    where p.code = 'ventas.orden.eliminar_item';

  if not v_allowed then
    raise exception 'PERMISSION_DENIED: ventas.orden.eliminar_item'
      using errcode = '42501';
  end if;


  delete from public.order_items
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$function$;

