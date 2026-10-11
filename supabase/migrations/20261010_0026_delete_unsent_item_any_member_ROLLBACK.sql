-- Reversa de 20261010_0026: fn_delete_item vuelve a la de 20260902_0011
-- (exige ventas.orden.eliminar_item también para lo no enviado). Con la app
-- 2.0.21 el cajero/mesero sin ese permiso vuelve a no poder quitar productos
-- «POR CONFIRMAR».
-- Se niega a correr si fn_delete_item en vivo no es la de 0026 ni la de 0011.

begin;

do $$
declare
  v_md5 text;
begin
  select md5(prosrc) into v_md5
    from pg_proc
   where oid = to_regprocedure('public.fn_delete_item(uuid)');
  if v_md5 is distinct from 'b962aea9d21f2bedb93269e4a37cd308'
     and v_md5 is distinct from 'bfc0c1ad17a594865fbd4d90ba8dacbf' then
    raise exception 'fn_delete_item en vivo no es la de 0026 (md5 %). No se revierte.',
      coalesce(v_md5, 'no existe');
  end if;
end $$;

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
  v_ncf text;
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

  -- ─── AGREGADO 20260902_0011 · candado fiscal de H-3 ───────────────────────
  -- Esta funcion es SECURITY DEFINER, asi que el trigger
  -- trg_block_item_delete_on_invoiced la exime (corre como postgres) y el
  -- borrado pasaria igual. La verificacion tiene que vivir aqui dentro.
  --
  -- Mismo alcance que el trigger: un comprobante de OTRA subcuenta no cubre a
  -- este item, asi que borrar de una subcuenta sin facturar sigue permitido.
  select fd.ncf_number
    into v_ncf
    from public.order_items oi
    join public.fiscal_documents fd
      on fd.order_id = oi.order_id
     and fd.status = 'active'
     and (fd.check_id is null or fd.check_id = oi.check_id)
   where oi.id = p_item_id
   limit 1;

  if v_ncf is not null then
    raise exception
      'No se puede eliminar un producto de una cuenta ya facturada (%). '
      'Anúlalo en vez de borrarlo, o anula la factura completa.', v_ncf
      using errcode = 'MP404';
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  delete from public.order_items
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$function$;

COMMENT ON FUNCTION public.fn_delete_item(uuid) IS
  'Elimina un item validando el permiso ventas.orden.eliminar_item. Desde '
  '20260902_0011 rechaza con MP404 si la cuenta ya tiene comprobante fiscal '
  'activo: el trigger no alcanza a esta funcion por ser SECURITY DEFINER.';

commit;
