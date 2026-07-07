-- ============================================================
-- ACTUALIZAR productos YA cargados -> negocio 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--   1) tax_mode -> 'inclusive' en TODO el catalogo
--   2) enlaza ITBIS 18% + LEY 10% a cada producto
--   3) crea el menu 'MENU PRINCIPAL' (si no existe)
--   4) vincula TODO el catalogo al 'MENU PRINCIPAL'
--
-- NO inserta ni borra productos: solo actualiza/enlaza lo existente.
-- => imposible duplicar. Idempotente (re-ejecutable).
-- Correr en Supabase Studio (SQL Editor) o psql.
-- ============================================================
begin;

-- Salvaguarda: el negocio debe tener EXACTAMENTE ITBIS + LEY activos.
do $$
declare n int;
begin
  select count(*) into n from public.taxes
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and name in ('ITBIS','LEY') and coalesce(is_active,true);
  if n <> 2 then
    raise exception 'Se esperaban 2 impuestos activos (ITBIS, LEY), hay %', n;
  end if;
end $$;

-- 1) Todo el catalogo -> inclusive
update public.menu_items
set tax_mode = 'inclusive', updated_at = now()
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
  and tax_mode is distinct from 'inclusive';

-- 2) Enlazar ITBIS + LEY a cada producto (idempotente)
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
from public.menu_items mi
join public.taxes t
  on t.business_id = mi.business_id and t.name in ('ITBIS','LEY')
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
on conflict do nothing;

-- 3) Menu 'MENU PRINCIPAL' (crea si no existe)
insert into public.menus (id, business_id, name, is_active)
select gen_random_uuid(), '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid, 'MENU PRINCIPAL', true
where not exists (
  select 1 from public.menus m
  where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
    and m.name = 'MENU PRINCIPAL'
);

-- 4) Vincular TODO el catalogo al MENU PRINCIPAL (idempotente)
insert into public.menu_item_links (menu_id, item_id, position)
select m.id, mi.id,
       row_number() over (order by mi.category_id nulls last, mi.name)
from public.menu_items mi
join public.menus m
  on m.business_id = mi.business_id and m.name = 'MENU PRINCIPAL'
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
on conflict do nothing;

-- 5) Resumen de control
select
  (select count(*) from public.menu_items
     where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid) as total_items,
  (select count(*) from public.menu_items
     where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
       and tax_mode <> 'inclusive') as no_inclusive,
  (select count(*) from public.menu_item_taxes mit
     join public.menu_items mi on mi.id = mit.item_id
     where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid) as total_links_impuesto,
  (select count(*) from public.menu_item_links mil
     join public.menus m on m.id = mil.menu_id
     where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
       and m.name = 'MENU PRINCIPAL') as items_en_menu_principal;

commit;
