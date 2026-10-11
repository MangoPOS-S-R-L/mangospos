-- =============================================================================
-- 20261010_0026 — Lo que no se ha enviado a cocina lo quita cualquiera del negocio
-- =============================================================================
--
-- PROBLEMA (reporte 2026-10-10, mesa BAR4 en Windows). El mesero agrega
-- productos, toca la X de un producto «POR CONFIRMAR» y vuelve a aparecer.
--   * La app no pide PIN para lo que no se ha enviado: es como quitarlo del
--     carrito (table_order_screen.dart, _requestRemovalAuthorization).
--   * Hasta la 2.0.20 la app borraba con un DELETE directo a order_items y
--     solo caía a fn_delete_item si ese DELETE no borraba nada.
--   * Desde las ediciones versionadas (T04, 20261010_0006) todo borrado pasa
--     por fn_apply_order_edit → fn_delete_item, que exige
--     `ventas.orden.eliminar_item` a quien está logueado, esté enviado o no.
--     Ese permiso NO lo traen cajero ni mesero (a propósito: con él borrarían
--     lo ya enviado sin PIN). Resultado: PERMISSION_DENIED en cada X.
--
-- DECISIÓN DEL DUEÑO (2026-10-10): «cuando no pueden eliminar es cuando está
-- enviado a cocina». Sin enviar, lo quita cualquiera del negocio.
--
-- QUÉ CAMBIA (solo fn_delete_item; el resto del cuerpo queda textual):
--   1. Línea sin enviar (status 'draft' y sin kitchen_sent_at, el mismo
--      criterio que private.fn_notif_item_was_sent): basta ser del negocio
--      (is_member_of_business). Lo enviado sigue exigiendo el permiso.
--   2. La línea se lee con FOR UPDATE: si cocina la confirma al mismo tiempo,
--      espera y no se cuela un borrado sin permiso de algo ya enviado.
--   3. El negocio sale de la zona y, si la línea no cuelga de una mesa con
--      zona, de la sesión (venta rápida moría con ITEM_NOT_FOUND).
--   El candado fiscal (MP404) aplica igual a lo enviado y a lo no enviado.
--
-- No toca: fn_apply_order_edit, permisos ni roles, triggers. Lo no enviado
-- nunca se registró en order_item_removals (su trigger lo salta), así que la
-- auditoría de eliminaciones no cambia.
--
-- SEGURIDAD: se niega a correr si fn_delete_item en vivo no es la de
-- 20260902_0011 (md5 bfc0c1ad…) ni esta misma (re-ejecución).
-- ROLLBACK: 20261010_0026_delete_unsent_item_any_member_ROLLBACK.sql
-- =============================================================================

begin;

do $$
declare
  v_md5 text;
begin
  select md5(prosrc) into v_md5
    from pg_proc
   where oid = to_regprocedure('public.fn_delete_item(uuid)');
  if v_md5 is distinct from 'bfc0c1ad17a594865fbd4d90ba8dacbf'
     and v_md5 is distinct from 'b962aea9d21f2bedb93269e4a37cd308' then
    raise exception
      'fn_delete_item en vivo no es la esperada (md5 %). No se aplica: '
      'mandar pg_get_functiondef(''public.fn_delete_item(uuid)''::regprocedure).',
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
  v_unsent boolean;
begin
  -- Resolver business_id del item para validar permiso. 20261010_0026: sin
  -- mesa con zona, el de la sesión; y la línea queda tomada hasta el final.
  select coalesce(z.business_id, s.business_id),
         oi.status::text = 'draft'
           and (to_jsonb(oi) ->> 'kitchen_sent_at') is null
    into v_business_id, v_unsent
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions s on s.id = o.session_id
    left join public.dining_tables t on t.id = s.table_id
    left join public.zones z on z.id = t.zone_id
    where oi.id = p_item_id
    for update of oi;

  if v_business_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if coalesce(v_unsent, false) then
    -- ─── 20261010_0026 · sin enviar a cocina: se quita como del carrito ────
    if not coalesce(public.is_member_of_business(v_business_id), false) then
      raise exception 'PERMISSION_DENIED: ventas.orden.eliminar_item'
        using errcode = '42501';
    end if;
  else
    -- Validar permiso ventas.orden.eliminar_item
    select coalesce(bool_or(p.allowed), false)
      into v_allowed
      from public.fn_user_effective_permissions(auth.uid(), v_business_id) p
      where p.code = 'ventas.orden.eliminar_item';

    if not v_allowed then
      raise exception 'PERMISSION_DENIED: ventas.orden.eliminar_item'
        using errcode = '42501';
    end if;
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
  'Elimina un item. Lo no enviado a cocina (draft sin kitchen_sent_at) lo '
  'quita cualquier miembro del negocio (20261010_0026); lo enviado exige '
  'ventas.orden.eliminar_item. Rechaza con MP404 si la cuenta ya tiene '
  'comprobante fiscal activo (20260902_0011).';

commit;
