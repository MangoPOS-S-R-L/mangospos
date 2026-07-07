-- ============================================================================
-- Activar ITBIS 18% en los productos que lo tienen faltando (son 10)
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84 (Sophisticated Managment SRL)
-- Los 10 sin ITBIS: RABO, FLAN TRADICIONAL, HOOKA, RECARGA LOVE, YUMMI NUTS,
--   y 5 RECARGAS de saldo (RECARGA 10/25/50/PASO RAPIDO 100/500).
-- OJO: las recargas de saldo suelen ser EXENTAS de ITBIS en RD.
-- Correr los pasos EN ORDEN en Supabase Studio.
-- ============================================================================

-- ─── PASO 0) PREVIEW: ver los que faltan (para confirmar cuáles son) ─────────
with tax_itbis as (
  select id from public.taxes
   where business_id='f054fbc2-3fb7-4e34-a020-11341ff11d84' and name='ITBIS' limit 1
)
select coalesce(c.name,'(sin cat)') as categoria, mi.name as producto, mi.price
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id='f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and not exists (select 1 from public.menu_item_taxes m
                  where m.item_id=mi.id and m.tax_id=(select id from tax_itbis))
order by categoria, producto;

-- ════════════════════════════════════════════════════════════════════════════
-- OPCIÓN A — ITBIS a los 10 (incluye las recargas de saldo)
-- ════════════════════════════════════════════════════════════════════════════
-- insert into public.menu_item_taxes (item_id, tax_id)
-- select mi.id, t.id
-- from public.menu_items mi
-- join public.taxes t on t.business_id = mi.business_id and t.name = 'ITBIS'
-- where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
--   and not exists (select 1 from public.menu_item_taxes m
--                   where m.item_id = mi.id and m.tax_id = t.id);

-- ════════════════════════════════════════════════════════════════════════════
-- OPCIÓN B (recomendada) — ITBIS a todos MENOS las recargas de saldo
--   (deja exentas las RECARGA% de PRODUCTOS PERSONALES; sí incluye RECARGA LOVE
--    porque es de HOOKAS, no telefónica)
-- ════════════════════════════════════════════════════════════════════════════
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
from public.menu_items mi
join public.taxes t on t.business_id = mi.business_id and t.name = 'ITBIS'
left join public.categories c on c.id = mi.category_id
where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and not exists (select 1 from public.menu_item_taxes m
                  where m.item_id = mi.id and m.tax_id = t.id)
  and not (coalesce(c.name,'') = 'PRODUCTOS PERSONALES' and mi.name ilike 'recarga%');

-- ─── VERIFICAR: cuántos siguen sin ITBIS (Opción B debe dejar 5 = recargas) ──
with tax_itbis as (
  select id from public.taxes
   where business_id='f054fbc2-3fb7-4e34-a020-11341ff11d84' and name='ITBIS' limit 1
)
select count(*) as siguen_sin_itbis
from public.menu_items mi
where mi.business_id='f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and not exists (select 1 from public.menu_item_taxes m
                  where m.item_id=mi.id and m.tax_id=(select id from tax_itbis));
