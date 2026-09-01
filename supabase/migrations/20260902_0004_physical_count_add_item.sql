-- =============================================================================
-- Agregar un insumo a un conteo YA CONGELADO.
--
-- EL PROBLEMA (de piso, no de código):
--   `fn_physical_count_freeze` arma las líneas con los insumos activos AL
--   MOMENTO de congelar. Si contando aparece mercancía que no está en el
--   catálogo —lo normal en un conteo de arranque: la ficha nunca se creó, o
--   el código escaneado no existe— no hay dónde anotarla. Darla de alta en
--   Insumos tampoco alcanza: el insumo nuevo NO entra en esa sesión, y
--   `fn_physical_count_set_count` responde `LINE_NOT_FOUND_IN_SESSION`.
--   El operador termina apuntando en un papel, que es justo lo que el
--   módulo vino a eliminar.
--
-- ENTREGA:
--   `fn_physical_count_add_item(session, item)` — inserta la línea que falta,
--   con el stock actual de esa bodega como snapshot (0 si no tiene fila, el
--   mismo criterio del `left join` del congelado).
--
-- POR QUÉ EL SNAPSHOT ES EL STOCK DE AHORA Y NO 0:
--   El snapshot es "lo que el sistema cree que hay". Para un insumo recién
--   creado eso es 0 y da igual, pero esta función también sirve para el que
--   se dio de alta DESPUÉS de congelar y ya recibió mercancía: ahí forzar 0
--   inventaría una diferencia que no existe. Y aunque el ajuste final se
--   calcula contra el stock vivo al completar (20260801_0002), el snapshot
--   es lo que se lee en pantalla y en el reporte de diferencias.
--
-- GUARDAS: mismas que el resto del módulo — rol owner/admin/manager sobre el
--   negocio de la sesión, sesión en `in_progress`, e insumo del MISMO negocio
--   (sin esto se podría colar un item de otro tenant por id).
--
-- IDEMPOTENTE: sí (la llama dos veces y devuelve la línea que ya existía).
-- REVERSIBLE: sí (ver _ROLLBACK).
-- REQUIERE: 20260516_0011.
-- =============================================================================

begin;

create or replace function public.fn_physical_count_add_item(
  p_session_id uuid,
  p_item_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_item_business uuid;
  v_snapshot numeric(14,4);
  v_line public.physical_count_lines;
  v_existed boolean := false;
begin
  if p_session_id is null or p_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_session
  from public.physical_count_sessions
  where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS: la sesión no está en in_progress';
  end if;

  select business_id into v_item_business
  from public.inventory_items
  where id = p_item_id;
  if v_item_business is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;
  if v_item_business <> v_session.business_id then
    raise exception 'ITEM_OTHER_BUSINESS';
  end if;

  select * into v_line
  from public.physical_count_lines
  where session_id = p_session_id and item_id = p_item_id;

  if v_line.id is not null then
    v_existed := true;
  else
    select coalesce(quantity, 0) into v_snapshot
    from public.inventory_stock
    where item_id = p_item_id
      and warehouse_id = v_session.warehouse_id;

    insert into public.physical_count_lines (
      session_id, item_id, snapshot_quantity
    ) values (
      p_session_id, p_item_id, coalesce(v_snapshot, 0)
    )
    returning * into v_line;
  end if;

  return jsonb_build_object(
    'line_id', v_line.id,
    'item_id', v_line.item_id,
    'snapshot_quantity', v_line.snapshot_quantity,
    'already_existed', v_existed
  );
end;
$$;

grant execute on function public.fn_physical_count_add_item(uuid, uuid)
  to authenticated;

comment on function public.fn_physical_count_add_item(uuid, uuid) is
  'Suma un insumo a una sesión de conteo ya congelada (in_progress), con el '
  'stock actual de la bodega como snapshot. Idempotente.';

commit;
