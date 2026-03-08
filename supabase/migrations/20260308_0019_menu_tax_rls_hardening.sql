-- 20260308_0019_menu_tax_rls_hardening.sql
-- Scope:
-- 1) Restrict taxes to the active business.
-- 2) Restrict menu_item_taxes to item/tax pairs inside the same business.

begin;

drop policy if exists "read taxes" on public.taxes;
drop policy if exists "write taxes (auth)" on public.taxes;
drop policy if exists "read item taxes" on public.menu_item_taxes;
drop policy if exists "write item taxes (auth)" on public.menu_item_taxes;

drop policy if exists "taxes_read" on public.taxes;
drop policy if exists "taxes_write" on public.taxes;
drop policy if exists "menu_item_taxes_read" on public.menu_item_taxes;
drop policy if exists "menu_item_taxes_write" on public.menu_item_taxes;

create policy "taxes_read"
on public.taxes
for select
to authenticated
using (
  public.user_has_business_access(auth.uid(), business_id)
);

create policy "taxes_write"
on public.taxes
to authenticated
using (
  public.user_business_role(auth.uid(), business_id) = any (
    array['owner'::text, 'admin'::text]
  )
)
with check (
  public.user_business_role(auth.uid(), business_id) = any (
    array['owner'::text, 'admin'::text]
  )
);

create policy "menu_item_taxes_read"
on public.menu_item_taxes
for select
to authenticated
using (
  exists (
    select 1
    from public.menu_items mi
    join public.taxes t
      on t.id = menu_item_taxes.tax_id
    where mi.id = menu_item_taxes.item_id
      and mi.business_id = t.business_id
      and public.user_has_business_access(auth.uid(), mi.business_id)
  )
);

create policy "menu_item_taxes_write"
on public.menu_item_taxes
to authenticated
using (
  exists (
    select 1
    from public.menu_items mi
    join public.taxes t
      on t.id = menu_item_taxes.tax_id
    where mi.id = menu_item_taxes.item_id
      and mi.business_id = t.business_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
)
with check (
  exists (
    select 1
    from public.menu_items mi
    join public.taxes t
      on t.id = menu_item_taxes.tax_id
    where mi.id = menu_item_taxes.item_id
      and mi.business_id = t.business_id
      and public.user_business_role(auth.uid(), mi.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
);

commit;
