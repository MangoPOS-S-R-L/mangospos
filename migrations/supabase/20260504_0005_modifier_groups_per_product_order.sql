-- Permitir orden personalizado de grupos de modificadores por producto.
-- La tabla pivote menu_item_groups solo tenía (menu_item_id, group_id);
-- agregamos `position` para que cada producto tenga su propio orden.

begin;

-- 1) Agregar columna position
alter table public.menu_item_groups
  add column if not exists position integer not null default 0;

-- 2) Indice para acelerar queries con order by position
create index if not exists idx_menu_item_groups_position
  on public.menu_item_groups (menu_item_id, position);

-- 3) Inicializar position basado en el orden alfabético actual del nombre
--    del grupo, así ningún producto queda con todos los grupos en 0.
with ordered as (
  select mig.menu_item_id,
         mig.group_id,
         row_number() over (
           partition by mig.menu_item_id
           order by mg.name
         ) as rn
    from public.menu_item_groups mig
    join public.modifier_groups mg on mg.id = mig.group_id
)
update public.menu_item_groups mig
   set position = o.rn
  from ordered o
 where mig.menu_item_id = o.menu_item_id
   and mig.group_id = o.group_id;

-- 4) RPC para reordenar atómicamente los grupos de un producto.
--    Recibe el menu_item_id y un arreglo ordenado de group_ids.
--    Cada group_id queda con position = índice (1-based) en el arreglo.
create or replace function public.fn_reorder_modifier_groups(
  p_menu_item_id uuid,
  p_group_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  i int;
begin
  if p_menu_item_id is null then
    raise exception 'menu_item_id is required';
  end if;
  if p_group_ids is null or array_length(p_group_ids, 1) is null then
    return;
  end if;

  for i in 1..array_length(p_group_ids, 1) loop
    update public.menu_item_groups
       set position = i
     where menu_item_id = p_menu_item_id
       and group_id = p_group_ids[i];
  end loop;
end;
$$;

grant execute on function public.fn_reorder_modifier_groups(uuid, uuid[]) to authenticated;

commit;

-- =============================================================================
-- Smoke checks
-- =============================================================================
-- 1. Verificar que cada producto tiene positions válidas (>0 si tiene grupos):
--    select menu_item_id, count(*), min(position), max(position)
--      from menu_item_groups
--      group by menu_item_id
--      order by menu_item_id;
--
-- 2. Probar el RPC con un producto real:
--    select fn_reorder_modifier_groups(
--      '<menu_item_id>'::uuid,
--      array['<group_id_1>'::uuid, '<group_id_2>'::uuid]
--    );
--    -- Verificar:
--    select group_id, position from menu_item_groups
--      where menu_item_id = '<menu_item_id>'::uuid
--      order by position;
