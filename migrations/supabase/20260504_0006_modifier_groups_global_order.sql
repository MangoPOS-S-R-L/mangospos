-- Permitir orden GLOBAL de grupos de modificadores por negocio.
-- modifier_groups.sort_order ya existe (migración 20260327_0010); aquí:
--   1) Inicializamos sort_order con orden alfabético del nombre por negocio,
--      para que ningún grupo quede en 0 y haya un orden estable.
--   2) Creamos un trigger BEFORE INSERT en menu_item_groups que hereda
--      `position` desde modifier_groups.sort_order si el caller insertó
--      position = 0 (lo que indica "no me importa, usa el default global").
--      Permite override per-producto: si el caller pasa explícitamente
--      una position > 0, se respeta.
--   3) RPC fn_reorder_modifier_groups_global(p_business_id, p_group_ids[])
--      para reordenar atómicamente todos los grupos del negocio.

begin;

-- 1) Inicializar sort_order por orden alfabético (solo grupos en 0)
with ordered as (
  select id,
         row_number() over (
           partition by business_id
           order by name
         ) as rn
    from public.modifier_groups
   where coalesce(sort_order, 0) = 0
)
update public.modifier_groups mg
   set sort_order = o.rn
  from ordered o
 where mg.id = o.id;

-- 2) Trigger: heredar position desde sort_order al insertar en menu_item_groups
create or replace function public.fn_inherit_modifier_group_position()
returns trigger
language plpgsql
as $$
begin
  if coalesce(new.position, 0) = 0 then
    select coalesce(sort_order, 0)
      into new.position
      from public.modifier_groups
     where id = new.group_id;
    -- Si el grupo no existe (FK falla después) o sort_order es null,
    -- dejar position en 0 (comportamiento previo).
    if new.position is null then
      new.position := 0;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_menu_item_groups_inherit_position
  on public.menu_item_groups;

create trigger trg_menu_item_groups_inherit_position
  before insert on public.menu_item_groups
  for each row
  execute function public.fn_inherit_modifier_group_position();

-- 3) RPC para reordenar grupos globalmente por negocio
create or replace function public.fn_reorder_modifier_groups_global(
  p_business_id uuid,
  p_group_ids   uuid[]
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  i int;
begin
  if p_business_id is null then
    raise exception 'business_id is required';
  end if;
  if p_group_ids is null or array_length(p_group_ids, 1) is null then
    return;
  end if;

  for i in 1..array_length(p_group_ids, 1) loop
    update public.modifier_groups
       set sort_order = i
     where id = p_group_ids[i]
       and business_id = p_business_id;
  end loop;
end;
$$;

grant execute on function public.fn_reorder_modifier_groups_global(uuid, uuid[]) to authenticated;

commit;

-- =============================================================================
-- Smoke checks
-- =============================================================================
-- 1. Verificar que todos los grupos tienen sort_order > 0:
--    select business_id, count(*) filter (where sort_order = 0) as en_cero,
--           count(*) as total
--      from modifier_groups
--      group by business_id;
--    -- en_cero debe ser 0
--
-- 2. Test del trigger: insertar un menu_item_group nuevo sin position
--    debería heredar el sort_order del grupo.
--
-- 3. Test del RPC: reordenar grupos del negocio:
--    select fn_reorder_modifier_groups_global(
--      '<business_id>'::uuid,
--      array['<group_id_1>'::uuid, '<group_id_2>'::uuid]
--    );
