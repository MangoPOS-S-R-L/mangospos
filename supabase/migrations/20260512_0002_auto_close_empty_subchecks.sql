-- =============================================================================
-- Auto-cerrar sub-cuentas que quedaron sin items abiertos.
--
-- Bug raíz (2026-05-12):
--   Reporte del usuario: después de pagar una sub-cuenta y eliminar items
--   de otra, queda una "cuenta fantasma" que aparece en el listado pero
--   al abrirla no muestra productos.
--
--   Causa: `closeEmptyCheckIfApplicable` que agregamos en Fase 1 (Dart)
--   sólo se ejecuta cuando el delete pasa por `currentOrderProvider.
--   deleteItem`. Otros flujos que mueven o borran items NO disparan ese
--   cleanup:
--     - unassignItem (drag & drop en split_bill_modal)
--     - consolidateCheckItems (al re-unir checks)
--     - moveItemToCheck (cuando deja un check origen sin items)
--     - update directo de check_id desde otros RPCs
--
-- Fix:
--   Trigger AFTER INSERT/UPDATE/DELETE en order_items que, para cualquier
--   check afectado (old.check_id o new.check_id), valide si quedó sin
--   items abiertos. Si sí, marca is_closed=true automáticamente.
--
--   El principal (position=1, "C1") NUNCA se cierra por este trigger —
--   ese check representa "items sin asignar a sub-cuenta" y queda abierto
--   mientras la orden esté abierta.
--
--   "Items abiertos" = status NOT IN ('paid','void'). Items pagados se
--   cuentan como NO abiertos (un check con sólo items paid ya cumplió su
--   ciclo y debe cerrarse).
--
-- Idempotente: si el check ya está cerrado, no hace nada. Si tiene items
-- abiertos, no hace nada.
-- =============================================================================

begin;

create or replace function public.fn_auto_close_empty_subcheck()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_affected_check_ids uuid[] := array[]::uuid[];
  v_check_id uuid;
  v_position integer;
  v_is_closed boolean;
  v_open_count bigint;
begin
  -- Recolectar los check_id afectados según operación.
  if tg_op = 'INSERT' then
    if new.check_id is not null then
      v_affected_check_ids := array[new.check_id];
    end if;
  elsif tg_op = 'UPDATE' then
    if old.check_id is not null then
      v_affected_check_ids := array_append(v_affected_check_ids, old.check_id);
    end if;
    if new.check_id is not null
       and (old.check_id is null or new.check_id <> old.check_id) then
      v_affected_check_ids := array_append(v_affected_check_ids, new.check_id);
    end if;
    -- Cambio de status que pasa a paid/void también puede vaciar lógicamente
    -- el check. Lo cubrimos agregando new.check_id si el status cambió.
    if new.check_id is not null
       and old.status is distinct from new.status
       and not (new.check_id = any(v_affected_check_ids)) then
      v_affected_check_ids := array_append(v_affected_check_ids, new.check_id);
    end if;
  elsif tg_op = 'DELETE' then
    if old.check_id is not null then
      v_affected_check_ids := array[old.check_id];
    end if;
  end if;

  -- Para cada check afectado: si es sub-check (position > 1), está
  -- abierto, y no tiene items con status abierto, lo cerramos.
  foreach v_check_id in array v_affected_check_ids loop
    select position, is_closed
      into v_position, v_is_closed
    from public.order_checks
    where id = v_check_id;

    if v_position is null then
      continue;
    end if;
    if v_position <= 1 then
      continue;
    end if;
    if v_is_closed then
      continue;
    end if;

    select count(*)
      into v_open_count
    from public.order_items
    where check_id = v_check_id
      and status not in ('paid'::public.item_status, 'void'::public.item_status);

    if v_open_count = 0 then
      update public.order_checks
      set is_closed = true,
          closed_at = now()
      where id = v_check_id
        and is_closed = false;
    end if;
  end loop;

  return coalesce(new, old);
end;
$$;

comment on function public.fn_auto_close_empty_subcheck() is
  'Cierra automáticamente sub-cuentas (position>1) que quedaron sin items '
  'con status abierto. Trigger AFTER INSERT/UPDATE/DELETE sobre '
  'order_items. El principal (position=1) nunca se cierra por este trigger.';

drop trigger if exists trg_auto_close_empty_subcheck on public.order_items;

create trigger trg_auto_close_empty_subcheck
after insert or update or delete on public.order_items
for each row execute function public.fn_auto_close_empty_subcheck();

-- Limpieza one-shot: cerrar sub-cuentas que ya quedaron fantasma antes
-- de este deploy.
update public.order_checks oc
set is_closed = true,
    closed_at = coalesce(oc.closed_at, now())
where oc.position > 1
  and oc.is_closed = false
  and not exists (
    select 1
    from public.order_items oi
    where oi.check_id = oc.id
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
  );

commit;
