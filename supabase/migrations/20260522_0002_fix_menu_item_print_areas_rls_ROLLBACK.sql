-- Rollback de 20260522_0002_fix_menu_item_print_areas_rls.sql.
-- Vuelve a las policies originales basadas en memberships (con el bug).

begin;

drop policy if exists "menu_item_print_areas_select" on public.menu_item_print_areas;
drop policy if exists "menu_item_print_areas_write"  on public.menu_item_print_areas;

create policy "menu_item_print_areas_select"
  on public.menu_item_print_areas
  for select
  using (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
    )
  );

create policy "menu_item_print_areas_write"
  on public.menu_item_print_areas
  for all
  using (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  )
  with check (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  );

commit;
