-- =============================================================================
-- Recargar un conteo en curso: traer los insumos creados DESPUÉS de congelar.
--
-- EL HUECO:
--   `fn_physical_count_freeze` sólo corre desde `draft` y toma los insumos
--   activos de ESE momento. Un insumo dado de alta después —que es
--   exactamente lo que pasa cuando el conteo destapa mercancía que no estaba
--   en el sistema— nunca entra a esa sesión.
--
--   Hoy la única salida es cancelar el conteo y empezar de nuevo, perdiendo
--   todo lo ya contado. En un almacén grande eso es medio día de trabajo.
--
-- ENTREGA:
--   `fn_physical_count_sync_lines(session)` agrega las líneas que faltan y
--   devuelve cuántas. Lo ya contado NO se toca: el `on conflict do nothing`
--   protege cada línea existente con su cantidad.
--
-- EL SNAPSHOT DE LAS LÍNEAS NUEVAS es la existencia de AHORA, no la de
--   cuando se congeló. Es lo correcto: para un insumo que no existía al
--   congelar, "lo que el sistema creía tener" es lo que cree ahora — casi
--   siempre cero, que es justo lo que hace visible el sobrante.
--
-- NO agrega insumos inactivos ni los de otro negocio.
--
-- REQUIERE: 20260516_0011.
-- IDEMPOTENTE: sí — correrla dos veces no duplica nada.
-- REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

create or replace function public.fn_physical_count_sync_lines(
  p_session_id uuid
) returns integer
language plpgsql
security definer
set search_path to 'public'
set statement_timeout = '120s'
as $function$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_count int;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;

  select * into v_session
    from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  -- Sólo en curso: en `draft` todavía no se congeló (usar freeze), y una
  -- sesión completada o cancelada no se toca.
  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se recarga un conteo en curso (status=%)',
      v_session.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  insert into public.physical_count_lines (
    session_id, item_id, snapshot_quantity
  )
  select
    v_session.id,
    ii.id,
    coalesce(ist.quantity, 0)
  from public.inventory_items ii
  left join public.inventory_stock ist
    on ist.item_id = ii.id
   and ist.warehouse_id = v_session.warehouse_id
  where ii.business_id = v_session.business_id
    and coalesce(ii.is_active, true)
  on conflict (session_id, item_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

comment on function public.fn_physical_count_sync_lines(uuid) is
  'Agrega al conteo en curso los insumos activos que todavía no están en él '
  '— los creados después de congelar. Devuelve cuántos agregó. Lo ya '
  'contado no se toca.';

grant execute on function public.fn_physical_count_sync_lines(uuid)
  to authenticated;

commit;
