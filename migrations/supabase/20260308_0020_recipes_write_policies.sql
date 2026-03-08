-- 20260308_0020_recipes_write_policies.sql
-- Scope:
-- 1) Allow admins/owners to create/update/delete recipes for their business.
-- 2) Allow admins/owners to manage recipe ingredients linked to those recipes.

begin;

drop policy if exists "rec_write" on public.recipes;
drop policy if exists "ri_write" on public.recipe_ingredients;

create policy "rec_write"
on public.recipes
to authenticated
using (
  exists (
    select 1
    from public.menu_items mi
    where mi.id = recipes.menu_item_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
)
with check (
  exists (
    select 1
    from public.menu_items mi
    where mi.id = recipes.menu_item_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
);

create policy "ri_write"
on public.recipe_ingredients
to authenticated
using (
  exists (
    select 1
    from public.recipes r
    join public.menu_items mi
      on mi.id = r.menu_item_id
    where r.id = recipe_ingredients.recipe_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
)
with check (
  exists (
    select 1
    from public.recipes r
    join public.menu_items mi
      on mi.id = r.menu_item_id
    join public.inventory_items ii
      on ii.id = recipe_ingredients.inventory_item_id
    where r.id = recipe_ingredients.recipe_id
      and ii.business_id = mi.business_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
);

commit;
