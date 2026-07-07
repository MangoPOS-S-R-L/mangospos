-- ============================================================================
-- Productos que FALTAN por ITBIS y/o LEY
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84 (Sophisticated Managment SRL)
-- Fuente de verdad: menu_item_taxes (asignación por producto que usa
--   fn_populate_item_tax_lines). Sin la fila → el producto NO cobra ese impuesto.
-- Correr en Supabase Studio (SQL Editor) o psql contra producción.
-- ============================================================================

-- ─── 1) RESUMEN (conteo rápido) ─────────────────────────────────────────────
with tax_itbis as (
  select id from public.taxes
   where business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84' and name = 'ITBIS' limit 1
),
tax_ley as (
  select id from public.taxes
   where business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84' and name = 'LEY' limit 1
),
prod as (
  select
    mi.id,
    exists (select 1 from public.menu_item_taxes m
             where m.item_id = mi.id and m.tax_id = (select id from tax_itbis)) as itbis,
    exists (select 1 from public.menu_item_taxes m
             where m.item_id = mi.id and m.tax_id = (select id from tax_ley))   as ley
  from public.menu_items mi
  where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
    and mi.is_active
)
select
  count(*)                                       as productos_activos,
  count(*) filter (where itbis and ley)          as con_ambos,
  count(*) filter (where not itbis)              as faltan_itbis,
  count(*) filter (where not ley)                as faltan_ley,
  count(*) filter (where not itbis and not ley)  as faltan_ambos
from prod;

-- ─── 2) DETALLE (lista de los que faltan) ──────────────────────────────────
with tax_itbis as (
  select id from public.taxes
   where business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84' and name = 'ITBIS' limit 1
),
tax_ley as (
  select id from public.taxes
   where business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84' and name = 'LEY' limit 1
)
select
  coalesce(c.name, '(sin categoría)') as categoria,
  mi.name                             as producto,
  mi.price,
  exists (select 1 from public.menu_item_taxes m
           where m.item_id = mi.id and m.tax_id = (select id from tax_itbis)) as tiene_itbis,
  exists (select 1 from public.menu_item_taxes m
           where m.item_id = mi.id and m.tax_id = (select id from tax_ley))   as tiene_ley
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  and mi.is_active
  and (
    not exists (select 1 from public.menu_item_taxes m
                 where m.item_id = mi.id and m.tax_id = (select id from tax_itbis))
    or
    not exists (select 1 from public.menu_item_taxes m
                 where m.item_id = mi.id and m.tax_id = (select id from tax_ley))
  )
order by tiene_itbis, tiene_ley, categoria, producto;
