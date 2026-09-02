-- 20260902_0011_fn_delete_item_fiscal_guard.sql
-- Cierra el portillo que dejaba sin efecto al candado de H-3.
--
-- EL PROBLEMA (medido en prod el 1-sep-2026)
--   La migracion 20260902_0010 puso `trg_block_item_delete_on_invoiced`, un
--   BEFORE DELETE que exime a los roles internos para no romper la
--   consolidacion de splits. Pero `fn_delete_item` es SECURITY DEFINER: corre
--   como `postgres`, cae en esa exencion y BORRA IGUAL.
--
--   Y no es un camino marginal:
--     sales_repository.dart:1652          -> respaldo del DELETE directo
--     sales_repository_improved.dart:172  -> CAMINO PRINCIPAL (split de cuentas)
--
--   O sea que con el trigger puesto, la app seguia borrando items de cuentas
--   facturadas. El candado estaba, pero no protegia nada por el lado de la app.
--
-- POR QUE NO SE RESUELVE CON `revoke execute`
--   Romperia el borrado de items del flujo de division de cuentas, donde el RPC
--   no es respaldo sino la unica via.
--
-- QUE HACE ESTA MIGRACION
--   Mete la MISMA verificacion dentro de fn_delete_item, justo despues del
--   chequeo de permisos y antes del delete. Mismo criterio de alcance y mismo
--   errcode MP404, para que la app lo traduzca igual.
--
--   El cuerpo original se conserva TEXTUAL (leido con pg_get_functiondef de la
--   version viva el 1-sep-2026, porque esta funcion no existe en el repo).
--   Lo unico que se agrega es el bloque marcado.
--
-- NOTA, sin arreglar aqui: fn_delete_item resuelve el business_id navegando
--   zonas > mesas > sesiones. Un item que no cuelgue de una mesa (venta rapida)
--   nunca encuentra business_id y muere con ITEM_NOT_FOUND. Es previo a esto y
--   queda anotado.
--
-- ROLLBACK: 20260902_0011_fn_delete_item_fiscal_guard_ROLLBACK.sql
-- Idempotente.

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
