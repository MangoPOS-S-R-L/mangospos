-- =============================================================================
-- Guard: items no pueden quedar asignados a checks cerrados (excepto status
-- terminal paid/void que SÍ pueden — son items históricos del cobro).
--
-- Bug del 2026-05-13:
--   Cajero cobra C3. El backend marca C3 is_closed=true.
--   Frontend mantiene selectedCheckId=C3 (no limpia en time).
--   Cajero agrega producto → item se inserta con check_id=C3 cerrado.
--   Item queda HUÉRFANO en check cerrado. La UI no lo muestra (filtra
--   checks cerrados) pero el item sigue ahí ocupando recursos y
--   confundiendo el conteo "pendiente" de la mesa.
--
-- Defensa profunda: dos triggers para garantizar que esto NUNCA pase a
-- nivel BD, sin importar qué frontend invoque el insert.
--
-- REGLAS:
--   1. Al INSERT de un order_item nuevo: si el check_id apunta a un check
--      cerrado, mover el item a NULL (principal C1 lógico). Loguea NOTICE.
--   2. Al UPDATE de check_id que apunta a cerrado: mismo (NULL).
--   3. EXCEPCIÓN: si el item ya tiene status='paid' o 'void', permitir el
--      check cerrado (son items históricos del cobro original, deben quedar
--      donde estaban para auditoría).
-- =============================================================================

begin;

create or replace function public.fn_guard_item_check_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check_is_closed boolean;
  v_check_position integer;
begin
  -- Si el item es terminal (paid/void), no validamos: son items históricos
  -- que pueden estar en checks cerrados (su check original).
  if new.status in ('paid'::public.item_status, 'void'::public.item_status) then
    return new;
  end if;

  -- Si no tiene check asignado (principal), nada que validar.
  if new.check_id is null then
    return new;
  end if;

  -- Buscar el check destino.
  select is_closed, position
    into v_check_is_closed, v_check_position
  from public.order_checks
  where id = new.check_id;

  -- Check no existe: dejar la asignación pero NULL (defensivo).
  if v_check_position is null then
    new.check_id := null;
    return new;
  end if;

  -- Check cerrado: forzar item al principal (NULL), no permitir ensuciar.
  if v_check_is_closed then
    raise notice 'GUARD: item % iba a check cerrado %, redirigido a C1', new.id, new.check_id;
    new.check_id := null;
  end if;

  return new;
end;
$$;

comment on function public.fn_guard_item_check_open() is
  'Red de seguridad: si un INSERT/UPDATE intenta asignar un item con '
  'status no terminal a un check cerrado, redirige el item a NULL '
  '(principal). Items con status=paid/void pasan sin validación porque '
  'son históricos del cobro original.';

drop trigger if exists trg_guard_item_check_open on public.order_items;

create trigger trg_guard_item_check_open
before insert or update of check_id on public.order_items
for each row execute function public.fn_guard_item_check_open();

-- ---------------------------------------------------------------------------
-- Cleanup one-shot: mover items huérfanos (status no terminal, check cerrado)
-- al principal de su orden. Reporta cuántos arregló.
-- ---------------------------------------------------------------------------

do $$
declare
  v_count int;
begin
  with orphans as (
    select oi.id
    from public.order_items oi
    join public.order_checks oc on oc.id = oi.check_id
    where oc.is_closed = true
      and oi.status not in ('paid'::public.item_status,
                            'void'::public.item_status)
  )
  update public.order_items
  set check_id = null
  where id in (select id from orphans);

  get diagnostics v_count = row_count;

  raise notice 'Cleanup huérfanos: % items movidos de checks cerrados a NULL', v_count;
end$$;

commit;
